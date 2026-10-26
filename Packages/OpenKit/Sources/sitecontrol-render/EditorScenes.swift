import AppKit
import OpenModel
import OpenBoosts
import OpenSiteControl
import OpenDesign
import ImageIO
import UniformTypeIdentifiers

/// The host boundary is fake; persistence, normalization, matcher and planner are real.
@MainActor
final class EditorHost: BoostEditorHost {
    let profileID = ProfileID(), tabID = ItemID()
    let root: URL
    let boostStore: BoostStore
    var url = URL(string: "https://news.example.com/news/story")!
    var snapshots: Data?
    var previews: [InjectionPlan] = [], previewTimes: [Double] = []
    var refreshes = 0, exits = 0, libraries = 0
    var refreshedPlans: [InjectionPlan] = []
    var refreshDurations: [Double] = []
    var observers: [SiteControlObservationToken: @MainActor (ItemID,BoostPickerEvent)->Void] = [:]
    var globallyEnabled = true
    init(neutral: Bool = false) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("open-editor-"+UUID().uuidString)
        boostStore = BoostStore(root: root,profileID: profileID); _ = boostStore.load()
        snapshots = Self.png(neutral: neutral)
    }
    isolated deinit { boostStore.flush(); try? FileManager.default.removeItem(at: root) }
    func store(for profile: ProfileID) -> BoostStore { precondition(profile == profileID); return boostStore }
    func preview(_ boost: Boost,tabID: ItemID) {
        precondition(tabID == self.tabID)
        var values = boostStore.allBoosts().filter { $0.id != boost.id }; values.append(boost)
        // This is the App adapter's specified replace route. Live plans never run JS.
        var plan = BoostInjectionPlanner.plan(url: url,profileID: profileID,matcher: BoostMatcher(boosts: values),boostsGloballyEnabled: globallyEnabled)
        plan.combinedJS = ""; plan.containsJS = false
        for i in plan.boosts.indices { plan.boosts[i].js = "" }
        previews.append(plan); previewTimes.append(CACurrentMediaTime())
    }
    func refresh(profile: ProfileID) {
        precondition(profile == profileID); let start = CACurrentMediaTime(); refreshes += 1
        let matcher = BoostMatcher(boosts: boostStore.allBoosts())
        refreshedPlans = (0..<10).map { i in
            let page = URL(string: "https://child\(i).news.example.com/news/story")!
            var plan = BoostInjectionPlanner.plan(url: page,profileID: profileID,matcher: matcher,boostsGloballyEnabled: globallyEnabled)
            plan.combinedJS = ""; plan.containsJS = false
            for j in plan.boosts.indices { plan.boosts[j].js = "" }
            return plan
        }
        refreshDurations.append((CACurrentMediaTime()-start)*1000)
    }
    func pageSnapshot(tabID: ItemID) async -> Data? { snapshots }
    func enterZap(boostID: BoostID,tabID: ItemID) -> Bool { false }
    func exitZap(tabID: ItemID) { exits += 1 }
    func removeZapFromSession(_ selector: String,tabID: ItemID) {}
    func requestZapCounts(tabID: ItemID) {}
    func observePickerEvents(_ observer: @escaping @MainActor (ItemID,BoostPickerEvent)->Void) -> SiteControlObservationToken { let token = SiteControlObservationToken(); observers[token] = observer; return token }
    func removePickerObserver(_ token: SiteControlObservationToken) { observers[token] = nil }
    func setDevToolsVisible(_ visible: Bool,tabID: ItemID) {}
    func reload(tabID: ItemID) {}
    func currentURL(tabID: ItemID) -> URL? { url }
    func showBoostsLibrary(profileID: ProfileID) { libraries += 1 }
    static func png(neutral: Bool = false,width: Int = 2216,height: Int = 1394) -> Data {
        let c = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor((neutral ? NSColor.white : NSColor(srgbRed: 0.2,green: 0.8,blue: 0.35,alpha: 1)).cgColor); c.fill(CGRect(x: 0,y: 0,width: width,height: height))
        let data = NSMutableData(); let dest = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,c.makeImage()!,nil); CGImageDestinationFinalize(dest); return data as Data
    }
}

@MainActor
final class EditorStage {
    let host: EditorHost
    let controller: BoostEditorController
    let defaults: UserDefaults
    let suite: String
    let parent: ScaledWindow
    let backdrop = Backdrop(frame: CGRect(x: 0,y: 0,width: 1000,height: 760))
    let initialID: BoostID
    let scale: CGFloat
    let state: String
    var menuLayer: CALayer?
    var menuFrame = CGRect.zero
    weak var activeMenu: NSMenu?
    var session: BoostEditorSession { controller.session! }
    var view: BoostEditorView { controller.view! }
    var panel: NSPanel { controller.panel! }
    init(state: String = "editor-simple",scale: CGFloat = 1,appearance: ContentAppearance = .light,isNew: Bool = false,url: URL? = nil,boost: Boost? = nil) {
        self.scale = scale; self.state = state
        host = EditorHost(neutral: state == "editor-neutral-page"); if let url { host.url = url }
        suite = "open.harness.editor."+UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
        defaults.set(state != "editor-interstitial",forKey: "open.boosts.hasDismissedInterstitial")
        defaults.set(state != "editor-global-off",forKey: "open.advanced.enableBoosts"); host.globallyEnabled = state != "editor-global-off"
        var seed = boost ?? Boost(id: BoostID(uuidString: "00000000-0000-0000-0000-000000000004"),name: "My Boost",siteMatch: SiteMatch(domain: host.url.host!))
        if state == "editor-not-active" { seed.siteMatch = SiteMatch(domain: "other.example.com") }
        if state == "editor-legacy" { seed.colorAdjustment = ColorAdjustment(brightness: 2,invert: 0.5) }
        initialID = seed.id; if !isNew { _ = host.boostStore.upsert(seed) }
        backdrop.appearance = appearance.nsAppearance
        parent = OffscreenRenderer.host(backdrop,scale: scale); parent.orderFront(nil)
        controller = BoostEditorController(host: host,defaults: defaults,makePanel: { let p = EditorScaledPanel(contentRect: CGRect(x: 0,y: 0,width: 316,height: 452),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false); p.scale = scale; return p })
        let context = SiteControlContext(tabID: host.tabID,profileID: host.profileID,url: host.url,displayHost: host.url.host!,security: .secure)
        precondition(controller.present(parent: parent,contentRect: CGRect(x: 228,y: 10,width: 762,height: 740),context: context,boostID: isNew ? nil : seed.id))
        // Resolve only the real asynchronous snapshot path, never patch the session.
        let deadline = Date().addingTimeInterval(3)
        while !session.colorsReady && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        settle()
        if state == "editor-advanced-color" { tap("editor.color.advanced"); tap("editor.color.invert"); settle(0.3) }
        settle()
    }
    isolated deinit { controller.close(); parent.contentView = nil; parent.close(); defaults.removePersistentDomain(forName: suite); CATransaction.flush() }
    func settle(_ seconds: TimeInterval = 0) {
        if seconds > 0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        if let content = controller.panel?.contentView { OffscreenRenderer.settle(content) }
    }
    func key(_ code: UInt16,_ chars: String,modifiers: NSEvent.ModifierFlags = [],window: NSWindow? = nil) {
        guard let window = window ?? controller.panel else { return }
        let e = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: modifiers,timestamp: CACurrentMediaTime(),windowNumber: window.windowNumber,context: nil,characters: chars,charactersIgnoringModifiers: chars,isARepeat: false,keyCode: code)!
        window.sendEvent(e); settle()
    }
    func mouse(_ type: NSEvent.EventType,point: CGPoint,in target: NSView,modifiers: NSEvent.ModifierFlags = [],clicks: Int = 1) {
        guard let window = target.window else { return }; let p = target.convert(point,to: nil)
        let e = NSEvent.mouseEvent(with: type,location: p,modifierFlags: modifiers,timestamp: CACurrentMediaTime(),windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: clicks,pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(e)
    }
    func tap(_ id: String,modifiers: NSEvent.ModifierFlags = []) {
        guard let target = controller.view?.control(id: id) else { return }
        target.scrollToVisible(target.bounds); settle()
        let p = CGPoint(x: target.bounds.midX,y: target.bounds.midY)
        mouse(.leftMouseDown,point: p,in: target,modifiers: modifiers); mouse(.leftMouseUp,point: p,in: target,modifiers: modifiers); settle()
    }
    func menu(_ title: String) { let menu = controller.makeMenu(); if let i = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) { menu.performActionForItem(at: i); settle(0.3) } }
    func alert(_ title: String) {
        guard let alert = controller.activeAlert, let button = alert.buttons.first(where: { $0.title == title }) else { return }
        let focused = alert.window.makeFirstResponder(button)
        key(49," ",window: alert.window)
        settle(0.35)
        precondition(focused, "native sheet action must accept keyboard focus")
    }
    func drag(events: Int = 40,delay: TimeInterval = 0) {
        let wheel = view.wheel
        mouse(.leftMouseDown,point: CGPoint(x: 64,y: 34),in: wheel)
        for i in 0..<events { let t = Double(i)*0.09; mouse(.leftMouseDragged,point: CGPoint(x: 64+sin(t)*40,y: 64-cos(t)*40),in: wheel); if delay > 0 { RunLoop.main.run(until: Date().addingTimeInterval(delay)) } }
        mouse(.leftMouseUp,point: CGPoint(x: 104,y: 64),in: wheel); settle()
    }
    func render() -> CGImage {
        func mark(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(mark) }
        mark(panel.contentView!); settle()
        if state == "editor-menu" && menuLayer == nil {
            var timer: Timer?
            controller.onMenu = { [weak self] menu in
                self?.activeMenu = menu
                timer = Timer(timeInterval: 0.12,repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let menu = self.activeMenu else { return }
                        let windows = NSApp.windows.filter { $0 !== self.parent && $0 !== self.controller.panel && $0.isVisible }
                        for window in windows {
                            if let content = window.contentView {
                                content.wantsLayer = true; OffscreenRenderer.settle(content)
                                if content.layer != nil {
                                    let captured = OffscreenRenderer().snapshot(content,scale: self.scale)
                                    let layer = CALayer(); layer.contents = captured; layer.contentsScale = self.scale
                                    // CARenderer has no WindowServer backdrop for NSVisualEffectView.
                                    layer.backgroundColor = Core.popoverBackground.cgColor(self.backdrop.contentAppearance)
                                    layer.cornerRadius = 6; layer.masksToBounds = true
                                    self.menuLayer = layer; self.menuFrame = window.frame; break
                                }
                            }
                        }
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(timer!,forMode: .eventTracking)
            }
            tap("editor.more"); timer?.invalidate(); controller.onMenu = nil
        }
        settle(); let surface = panel.contentView!
        let panelImage = OffscreenRenderer().snapshot(surface,scale: scale)
        let panelLayer = CALayer(); panelLayer.contents = panelImage; panelLayer.contentsScale = scale
        let frame = parent.convertFromScreen(panel.frame)
        panelLayer.frame = CGRect(x: frame.minX,y: backdrop.bounds.height-frame.maxY,width: frame.width,height: frame.height)
        backdrop.layer?.addSublayer(panelLayer)
        if let menuLayer {
            // AppKit constrains its menu window to the real display, even when
            // the owning fixture is offscreen. Place its actual captured layers
            // beside the fixture anchor for this contact sheet only.
            menuLayer.frame = CGRect(x: frame.maxX-24-menuFrame.width,y: backdrop.bounds.height-frame.maxY+60,width: menuFrame.width,height: menuFrame.height)
            backdrop.layer?.addSublayer(menuLayer)
        }
        defer { panelLayer.removeFromSuperlayer(); menuLayer?.removeFromSuperlayer() }
        return OffscreenRenderer().snapshot(backdrop,scale: scale)
    }

}

@MainActor
private final class EditorScaledPanel: BoostEditorPanel {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
    override var isKeyWindow: Bool { true }
}
