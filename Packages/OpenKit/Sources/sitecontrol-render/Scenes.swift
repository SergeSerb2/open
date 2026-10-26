import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
final class Backdrop: NSView {
    var spaceDark = false, showsPaneBar = false
    private let paneBar = CALayer()
    var keys: [UInt16] = []
    var hits = 0
    var rightHits = 0, otherHits = 0
    private let page = CALayer()
    private let urlField = CALayer()
    private let openLabel = NSTextField(labelWithString: "Open")
    private let hostLabel = NSTextField(labelWithString: "news.example.com")
    private let pageLabel = NSTextField(labelWithString: "A page for the Site Control Center harness")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for child in [page, urlField, paneBar] {
            child.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(child)
        }
        urlField.cornerRadius = 10; urlField.cornerCurve = .continuous
        for label in [openLabel, hostLabel, pageLabel] {
            label.font = NSFont.systemFont(ofSize: 14); label.textColor = Core.foregroundPrimary.nsColor
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            addSubview(label)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    override func mouseDown(with event: NSEvent) { hits += 1 }
    override func rightMouseDown(with event: NSEvent) { rightHits += 1 }
    override func otherMouseDown(with event: NSEvent) { otherHits += 1 }
    override func layout() {
        super.layout()
        paneBar.frame = CGRect(x: 228,y: 10,width: bounds.width-238,height: 32); paneBar.isHidden = !showsPaneBar
        page.frame = CGRect(x: 228, y: 10, width: bounds.width-238, height: bounds.height-20)
        urlField.frame = CGRect(x: 8, y: 46, width: 212, height: 36)
        for (label, x, baseline, width) in [(openLabel, CGFloat(22), CGFloat(36), CGFloat(180)),
                                           (hostLabel, 18, 69, 164), (pageLabel, 278, 234, 500)] {
            label.frame = CGRect(x: x, y: baseline-label.font!.ascender, width: width, height: label.intrinsicContentSize.height)
        }
    }
    override func updateLayer() {
        let dark = contentAppearance == .dark, sidebarDark = spaceDark || dark
        layer?.backgroundColor = (sidebarDark ? NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.20, alpha: 1) : NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.95, alpha: 1)).cgColor
        page.backgroundColor = (dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white).cgColor
        urlField.backgroundColor = SidebarColors.itemBackground.cgColor(sidebarDark ? .dark : .light)
        paneBar.backgroundColor = SidebarColors.itemBackground.cgColor(contentAppearance)
        for label in [openLabel,hostLabel] { label.textColor = Core.foregroundPrimary.resolved(sidebarDark ? .dark : .light).nsColor }
    }
}

@MainActor
final class Stage {
    let state: String
    private let overlay = NativeOverlayCapture()
    var hasOverlay: Bool { overlay.hasImage }
    let source: FakeSource
    let root = Backdrop(frame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    let controller: SiteControlController
    let window: ScaledWindow
    private(set) var openCPU: Double = 0
    private(set) var openWall: Double = 0
    let anchorButton = SiteControlButton(id: "harness.anchor", label: "Site Controls", symbol: "slider.horizontal.2.square", pointSize: 18)
    init(state: String = "scc-basic", scale: CGFloat = 1, appearance: ContentAppearance = .light, source: FakeSource? = nil, open: Bool = true) {
        self.state = state
        self.source = source ?? FakeSource()
        if source == nil {
            let aliases = ["scc-tooltip-off":"scc-adblock-excluded","scc-tooltip-unavailable":"scc-adblock-unavailable","scc-tooltip-private":"scc-incognito"]
            self.source.configure(aliases[state] ?? state)
        }
        root.appearance = appearance.nsAppearance
        root.spaceDark = state == "scc-dark"; root.showsPaneBar = state == "scc-pane-anchor"
        anchorButton.frame = CGRect(x: 186, y: 49, width: 30, height: 30)
        root.addSubview(anchorButton)
        window = OffscreenRenderer.host(root, scale: scale)
        window.orderFront(nil); window.makeFirstResponder(root)
        if state == "scc-pane-anchor" { let pane = SiteControlButton(id: "harness.pane",label: "Site Controls",symbol: "slider.horizontal.2.square",pointSize: 18); pane.frame = CGRect(x: 879,y: 12,width: 32,height: 28); root.addSubview(pane) }
        // The browser page is already painted when its Site Controls are clicked.
        // Prepare that fixture before measuring creation of the panel itself.
        OffscreenRenderer.settle(root)
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        controller = SiteControlController(source: self.source, actions: self.source)
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.addSubview(controller.view)
        controller.geometry = { [weak root] anchor in
            guard let root else { return nil }
            let rect = anchor == .urlField ? CGRect(x: 186, y: 49, width: 30, height: 30) : CGRect(x: 879, y: 12, width: 32, height: 28)
            return SiteControlGeometry(anchor: rect, sidebarMaxX: 228,
                                       content: CGRect(x: 228, y: 10, width: root.bounds.width - 238, height: root.bounds.height - 20))
        }
        anchorButton.invoke = { [weak controller, weak source = self.source] in
            guard let source else { return }
            controller?.toggle(anchor: .urlField, tabID: source.tabID, animated: false)
        }
        // Real NSWindow dispatch in our offscreen harness window, with no global
        // input injection and no desktop or user-window automation.
        if open {
            if state == "scc-pane-anchor" { controller.present(anchor: .paneBar(self.source.tabID), tabID: self.source.tabID, animated: false) }
            else { click(CGPoint(x: 201, y: 64)) }
        }
        OffscreenRenderer.settle(root)
        if state == "scc-reload" { tap("contentBlocking"); RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        if state == "scc-keyboard-focus" { key(code: 48,characters: "\t") }
        if state == "scc-picker" { controller.present(anchor: .urlField,tabID: self.source.tabID,mode: .extensionPicker,animated: false) }
        if state == "scc-hover" {
            controller.view.panel.control(id: "section.settings")?.mouseEntered(with: NSEvent())
            controller.view.panel.control(id: "boost.\(self.source.value!.boosts[0].id).edit")?.superview?.mouseEntered(with: NSEvent())
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        if state.hasPrefix("scc-tooltip") {
            let target = state == "scc-tooltip-private" ? "boost.\(self.source.value!.boosts[0].id).switch" : "contentBlocking"
            controller.view.panel.control(id: target)?.mouseEntered(with: NSEvent())
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        }
        openCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000
        openWall = Double(DispatchTime.now().uptimeNanoseconds - wall) / 1_000_000
    }
    isolated deinit {
        controller.view.removeFromSuperview()
        window.contentView = nil
        window.close()
        CATransaction.flush()
    }
    func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    private var eventNumber = 0
    func click(_ p: CGPoint, button: NSEvent.EventType = .leftMouseDown) {
        eventNumber += 1
        let wp = CGPoint(x: p.x, y: root.bounds.height - p.y)
        let up: NSEvent.EventType = button == .rightMouseDown ? .rightMouseUp : button == .otherMouseDown ? .otherMouseUp : .leftMouseUp
        for type in [button, up] {
            let event = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }

    }
    func tap(_ id: String) {
        guard let control = controller.view.panel.control(id: id) else { return }
        let rect = control.convert(control.bounds, to: root)
        click(CGPoint(x: rect.midX, y: rect.midY))
    }
    func menu(_ title: String) {
        let menu = controller.makeMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else { return }
        menu.performActionForItem(at: index)
    }
    var focusedID: String? { (window.firstResponder as? NSView)?.identifier?.rawValue }
    func render(scale: CGFloat) -> CGImage {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(root); OffscreenRenderer.settle(root)
        if state == "scc-menu" {
            controller.onMenu = { [weak self] menu,_ in
                guard let self else { return }
                self.overlay.captureMenu(menu,excluding: self.window,scale: scale)
            }
            tap("more"); controller.onMenu = nil
            controller.present(anchor: .urlField,tabID: source.tabID,animated: false); OffscreenRenderer.settle(root)
        } else if state.hasPrefix("scc-tooltip") { overlay.captureVisible(excluding: window,scale: scale) }
        let panel = controller.view.panelFrame
        return overlay.composite(root,scale: scale,at: CGPoint(x: panel.maxX+8,y: state == "scc-menu" ? panel.maxY-44 : panel.minY+90))
    }
}
