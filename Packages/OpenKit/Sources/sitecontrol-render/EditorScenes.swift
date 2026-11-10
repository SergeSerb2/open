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
    var snapshotDelay: TimeInterval = 0
    var snapshots: Data?
    var previews: [InjectionPlan] = [], previewTimes: [Double] = []
    var refreshes = 0, exits = 0, libraries = 0, reloads = 0
    var loadedScripts: [BoostID: String] = [:], reloadScripts: [BoostID: String] = [:]
    var devTools: [Bool] = []
    var calls: [String] = []
    var refreshedPlans: [InjectionPlan] = []
    var refreshDurations: [Double] = []
    var observers: [SiteControlObservationToken: @MainActor (ItemID,BoostPickerEvent)->Void] = [:]
    var globallyEnabled = true
    var zapEnabled = false
    var failedZapEntries = 0
    var pickerCalls: [String] = []
    lazy var coordinator = BoostPickerCoordinator(store: boostStore)
    var pickerCommand: PickerOutbound?
    func deliver(_ type: String, selector: String = "#promo-banner", matches: Int = 1, tab: ItemID? = nil) {
        guard let command = pickerCommand else { return }
        let wire = BridgeDecode.encode(command)
        var payload = (try? JSONSerialization.jsonObject(with: Data(wire.payloadJSON.utf8))) as? [String: Any] ?? [:]
        payload["selector"] = selector; payload["label"] = "div#promo-banner"; payload["matches"] = matches
        payload["reason"] = "done"; payload["via"] = "undo"
        let data = try! JSONSerialization.data(withJSONObject: payload)
        guard let inbound = BridgeDecode.decode(type: type, payloadJSON: String(decoding: data, as: UTF8.self)) else { return }
        if coordinator.handle(inbound, from: "fixture-document") { refresh(profile: profileID) }
        if let event = coordinator.lastEvent { for observer in Array(observers.values) { observer(tab ?? tabID, event) } }
    }
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
    func pageSnapshot(tabID: ItemID) async -> Data? { if snapshotDelay > 0 { try? await Task.sleep(for: .seconds(snapshotDelay)) }; return snapshots }
    func zapAvailability(tabID: ItemID) -> Bool { zapEnabled }
    func enterZap(boostID: BoostID,tabID: ItemID) -> Bool {
        pickerCalls.append("enter")
        guard zapEnabled else { return false }
        if failedZapEntries > 0 { failedZapEntries -= 1; return false }
        pickerCommand = coordinator.enterZap(boostID: boostID, for: "fixture-document"); return pickerCommand != nil
    }
    func enterSelectorPicker(boostID: BoostID,tabID: ItemID) -> Bool {
        pickerCalls.append("select")
        guard zapEnabled else { return false }
        pickerCommand = coordinator.enterZap(boostID: boostID, for: "fixture-document", mode: .select); return pickerCommand != nil
    }
    func exitZap(tabID: ItemID) { exits += 1; pickerCalls.append("exit"); _ = coordinator.exitZap(for: "fixture-document") }
    func removeZapFromSession(_ selector: String,tabID: ItemID) {}
    func requestZapCounts(tabID: ItemID) { pickerCalls.append("list") }
    func observePickerEvents(_ observer: @escaping @MainActor (ItemID,BoostPickerEvent)->Void) -> SiteControlObservationToken { let token = SiteControlObservationToken(); observers[token] = observer; return token }
    func removePickerObserver(_ token: SiteControlObservationToken) { observers[token] = nil }
    func loadedJS(boostID: BoostID,tabID: ItemID) -> String? { loadedScripts[boostID] }
    func setDevToolsVisible(_ visible: Bool,tabID: ItemID) { devTools.append(visible);calls.append("devtools") }
    func reload(tabID: ItemID) { reloadScripts = Dictionary(uniqueKeysWithValues:boostStore.allBoosts().map { ($0.id,$0.js) });reloads += 1;calls.append("reload") }
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
    let host: EditorHost,controller: BoostEditorController,defaults: UserDefaults,suite: String
    let parent: EditorParentWindow
    let backdrop = Backdrop(frame: CGRect(x: 0,y: 0,width: 1000,height: 760))
    let initialID: BoostID,scale: CGFloat,state: String
    private(set) var nativeParentReady = true
    let overlay = NativeOverlayCapture()
    var session: BoostEditorSession { controller.session! }
    var view: BoostEditorView { controller.view! }
    var panel: NSPanel { controller.panel! }
    var editorOrigin: CGPoint { let f = parent.convertFromScreen(panel.frame);return CGPoint(x: f.minX,y: 760-f.maxY) }
    init(state: String = "editor-no-color",scale: CGFloat = 1,appearance: ContentAppearance = .light,isNew: Bool = false,url: URL? = nil,boost: Boost? = nil,waitForColors: Bool = true,onScreen: Bool = false) {
        self.scale = scale;self.state = state
        host = EditorHost(neutral: state == "editor-neutral-page");if let url { host.url = url };if !waitForColors { host.snapshotDelay = 0.2 }
        suite = "open.harness.editor."+UUID().uuidString;defaults = UserDefaults(suiteName: suite)!
        defaults.set(state != "editor-first-run",forKey: "open.boosts.hasDismissedInterstitial")
        defaults.set(!["editor-global-off","editor-double-banner"].contains(state),forKey: BoostPreferences.globallyEnabledKey);host.globallyEnabled = defaults.bool(forKey: BoostPreferences.globallyEnabledKey)
        var seed = boost ?? Boost(id: BoostID(uuidString: "00000000-0000-0000-0000-000000000004"),name: "My Boost",siteMatch: SiteMatch(domain: host.url.host!))
        if ["editor-not-active","editor-double-banner"].contains(state) { seed.siteMatch = SiteMatch(domain: "other.example.com") }
        if state == "editor-legacy" { seed.colorAdjustment = ColorAdjustment(brightness: 2,invert: 0.5) }
        if ["editor-color","editor-dragging","editor-advanced","editor-font-selected","editor-zap-on","editor-zap-count"].contains(state) {
            seed.colorWheel = BoostColorWheel(hue: 252.3,intensity: 46.2/(66.5*0.99),baseHue: 125);seed.colorAdjustment = seed.colorWheel?.adjustment
        }
        if state == "editor-code-css" { seed.css = "/* Make this site your own. */\nbody {\n  color: #326d74;\n  font-size: 16px;\n}\n" }
        if state == "editor-code-js-dirty" { seed.js = "// Runs when you refresh this page.\nconst heading = document.querySelector(\"h1\");\nif (heading) {\n  heading.textContent = \"Hello!\";\n}\n" }
        if state == "editor-font-selected" { seed.fontFamily = BoostEditorFonts.available[9].css }
        if state == "editor-zap-count" { seed.zaps = [ZappedElement(selector: ".ad")] }
        initialID = seed.id;if !isNew { _ = host.boostStore.upsert(seed) }
        backdrop.appearance = appearance.nsAppearance
        parent = EditorParentWindow(contentRect: CGRect(x: -20000,y: -20000,width: 1000,height: 760),styleMask: onScreen ? [.titled] : [.borderless],backing: .buffered,defer: false)
        if onScreen,let screen = NSScreen.screens.first { parent.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX+40,y: screen.visibleFrame.minY+20)) }
        parent.scale = scale;parent.isReleasedWhenClosed = false;parent.colorSpace = .sRGB;parent.contentView = backdrop;parent.makeKeyAndOrderFront(nil)
        controller = BoostEditorController(host: host,defaults: defaults,makePanel: { let p = EditorScaledPanel(contentRect: CGRect(origin: .zero,size: BoostEditorMetrics.window),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false);p.scale = scale;return p })
        let screen = CGRect(x: -20100,y: -20200,width: 1600,height: 1200)
        controller.screens = onScreen ? { NSScreen.screens.map { BoostEditorScreen(frame: $0.frame,visibleFrame: $0.visibleFrame) } } : { [BoostEditorScreen(frame: screen,visibleFrame: screen)] }
        let context = SiteControlContext(tabID: host.tabID,profileID: host.profileID,url: host.url,displayHost: host.url.host!,security: .secure)
        if onScreen {
            // The native fixture models an already active browser. An app with
            // no window need not become frontmost; create the activating parent
            // first, then finish activation before showing a nonactivating panel.
            NSApp.activate();parent.makeKeyAndOrderFront(nil);parent.makeMain()
            let deadline = ProcessInfo.processInfo.systemUptime+3
            func ready() -> Bool {
                NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier && parent.isKeyWindow && parent.isMainWindow
            }
            while !ready() && ProcessInfo.processInfo.systemUptime<deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            nativeParentReady = ready()
            if !nativeParentReady { return }
        }
        precondition(controller.present(parent: parent,contentRect: backdrop.bounds,context: context,boostID: isNew ? nil : seed.id))
        let deadline = Date().addingTimeInterval(3)
        while waitForColors && !session.colorsReady && Date()<deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        settle(waitForColors ? 0.2 : 0)
        if state.hasPrefix("editor-code-") { controller.setCodeMode(true,animated: false);if state == "editor-code-js-dirty" { view.codeView?.select(.js) };settle() }
        if ["editor-zap-on", "editor-zap-count"].contains(state) { host.zapEnabled = true; session.toggleZap() }
        if state == "editor-color",let button = view.control(id: "editor.color.advanced") { mouse(.leftMouseDown,point: CGPoint(x: button.bounds.midX,y: button.bounds.midY),in: button);settle() }
        if state == "editor-advanced" { tap("editor.color.advanced");configureAdvancedFallback();settle(0.35) }
        if state == "editor-dragging" { mouse(.leftMouseDown,point: view.pad.primaryKnobCenter ?? CGPoint(x: 90,y: 74),in: view.pad);mouse(.leftMouseDragged,point: CGPoint(x: 60,y: 29.5),in: view.pad);settle(0.3) }
        if state == "editor-delete-alert" { menu("Delete this Boost");settle(0.3) }
    }
    isolated deinit { controller.close();parent.contentView = nil;parent.close();defaults.removePersistentDomain(forName: suite);CATransaction.flush() }
    func settle(_ seconds: TimeInterval = 0) {
        if seconds>0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        if let v = controller.panel?.contentView { OffscreenRenderer.settle(v) }
        if let v = controller.view?.advancedPopover?.panel.contentView { OffscreenRenderer.settle(v) }
    }
    func key(_ code: UInt16,_ chars: String,modifiers: NSEvent.ModifierFlags = [],window: NSWindow? = nil) {
        guard let window = window ?? controller.panel else { return }
        if !window.isKeyWindow { window.makeKey() }
        let e = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: modifiers,timestamp: CACurrentMediaTime(),windowNumber: window.windowNumber,context: nil,characters: chars,charactersIgnoringModifiers: chars,isARepeat: false,keyCode: code)!
        NSApp.sendEvent(e);settle()
    }
    func mouse(_ type: NSEvent.EventType,point: CGPoint,in target: NSView,modifiers: NSEvent.ModifierFlags = [],clicks: Int = 1) {
        guard let window = target.window else { return };let p = target.convert(point,to: nil)
        let e = NSEvent.mouseEvent(with: type,location: p,modifierFlags: modifiers,timestamp: CACurrentMediaTime(),windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: clicks,pressure: type == .leftMouseUp ? 0 : 1)!
        NSApp.sendEvent(e)
    }
    func tap(_ id: String,modifiers: NSEvent.ModifierFlags = []) {
        guard let target = controller.view?.control(id: id) else { return };settle()
        let p = CGPoint(x: target.bounds.midX,y: target.bounds.midY)
        mouse(.leftMouseDown,point: p,in: target,modifiers: modifiers);mouse(.leftMouseUp,point: p,in: target,modifiers: modifiers);settle()
    }
    func menu(_ title: String) { let menu = controller.makeMenu();if let i = menu.items.firstIndex(where: { $0.title == title && $0.isEnabled }) { menu.performActionForItem(at: i);settle(0.3) } }
    func alert(_ title: String) {
        guard let alert = controller.activeAlert,let button = alert.buttons.first(where: { $0.title == title }) else { return }
        let focused = alert.window.makeFirstResponder(button);key(49," ",window: alert.window);settle(0.35);precondition(focused)
    }
    func drag(events: Int = 40,delay: TimeInterval = 0) {
        let pad = view.pad
        mouse(.leftMouseDown,point: CGPoint(x: 110,y: 73.5),in: pad)
        for i in 0..<events { let t = Double(i)*0.09;mouse(.leftMouseDragged,point: CGPoint(x: 73.5+sin(t)*40,y: 73.5-cos(t)*40),in: pad);if delay>0 { RunLoop.main.run(until: Date().addingTimeInterval(delay)) } }
        mouse(.leftMouseUp,point: CGPoint(x: 113.5,y: 73.5),in: pad);settle()
    }
    func slider(_ component: Int) -> NSControl? { view.advancedPopover?.panel.contentView?.subviews.first { $0.identifier?.rawValue == "editor.slider.\(component)" } as? NSControl }
    func configureAdvancedFallback() {
        guard let popup = view.advancedPopover else { return }
        let c = CGContext(data: nil,width: Int(250*scale),height: Int(232*scale),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor(srgbRed: 237/255,green: 237/255,blue: 237/255,alpha: 1).cgColor);c.fill(CGRect(x: 0,y: 0,width: c.width,height: c.height));popup.offscreenMaterial = c.makeImage()
    }
    func editorImage() -> CGImage { settle();return OffscreenRenderer().snapshot(view,scale: scale) }
    func render() -> CGImage {
        if ["editor-name-menu","editor-scope-menu"].contains(state),!overlay.hasImage {
            controller.onMenu = { [weak self] menu in guard let self else { return };self.overlay.captureMenu(menu,excluding: self.parent,scale: self.scale) }
            if state == "editor-scope-menu" {
                let menu = view.scopeMenu();overlay.captureMenu(menu,excluding: parent,scale: scale)
                menu.popUp(positioning: menu.items.first { $0.state == .on },at: CGPoint(x: 0,y: 24),in: view.control(id: "editor.name"))
            } else { tap("editor.name") };controller.onMenu = nil
        }
        let canvas = EditorCanvas(frame: CGRect(x: 0,y: 0,width: 1200,height: 900));canvas.wantsLayer = true
        let host = OffscreenRenderer.host(canvas,scale: scale);defer { host.contentView = nil;host.close() }
        func add(_ image: CGImage,_ frame: CGRect) { let l = CALayer();l.contents = image;l.contentsScale = scale;l.frame = frame;canvas.layer?.addSublayer(l) }
        add(OffscreenRenderer().snapshot(backdrop,scale: scale),backdrop.bounds)
        let origin = editorOrigin;add(editorImage(),CGRect(origin: origin,size: panel.frame.size))
        if let popup = view.advancedPopover,let content = popup.panel.contentView {
            configureAdvancedFallback();settle();let f = parent.convertFromScreen(popup.panel.frame)
            add(OffscreenRenderer().snapshot(content,scale: scale),CGRect(x: f.minX,y: 760-f.maxY,width: f.width,height: f.height))
        }
        if let alert = controller.activeAlert,let content = alert.window.contentView { content.wantsLayer = true;OffscreenRenderer.settle(content);add(OffscreenRenderer().snapshot(content,scale: scale),CGRect(x: 450,y: 220,width: content.bounds.width,height: content.bounds.height)) }
        if let image = overlay.image { add(image,CGRect(x: origin.x-CGFloat(image.width)/scale-12,y: origin.y+40,width: CGFloat(image.width)/scale,height: CGFloat(image.height)/scale)) }
        OffscreenRenderer.settle(canvas);return OffscreenRenderer().snapshot(canvas,scale: scale)
    }
}

@MainActor private final class EditorCanvas: NSView {
    override var isFlipped: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor(srgbRed: 244/255,green: 244/255,blue: 246/255,alpha: 1).cgColor }
    override var wantsUpdateLayer: Bool { true }
}
@MainActor final class EditorParentWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
@MainActor private final class EditorScaledPanel: BoostEditorPanel {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}
