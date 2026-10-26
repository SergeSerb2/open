import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
final class Backdrop: NSView {
    var hits = 0
    private let page = CALayer()
    private var labels: [CATextLayer] = []
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        page.backgroundColor = NSColor.white.cgColor
        page.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(page)
        for (text, rect) in [("Open", CGRect(x: 24, y: 22, width: 180, height: 22)),
                             ("news.example.com", CGRect(x: 20, y: 54, width: 180, height: 22)),
                             ("A page for the Site Control Center harness", CGRect(x: 280, y: 180, width: 500, height: 22))] {
            let label = CATextLayer(); label.string = text; label.font = NSFont.systemFont(ofSize: 14); label.fontSize = 14
            label.foregroundColor = NSColor.darkGray.cgColor; label.frame = rect; label.contentsScale = 2
            labels.append(label); layer?.addSublayer(label)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { hits += 1 }
    override func updateLayer() { layer?.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.95, alpha: 1).cgColor }
    override func layout() { super.layout(); page.frame = CGRect(x: 228, y: 10, width: bounds.width - 238, height: bounds.height - 20) }
}

@MainActor
final class Stage {
    let source = FakeSource()
    let root = Backdrop(frame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    let controller: SiteControlController
    let window: ScaledWindow
    let anchorButton = SiteControlButton(id: "harness.anchor", label: "Site Controls", symbol: "slider.horizontal.2.square", pointSize: 18)
    init(state: String = "scc-basic", scale: CGFloat = 1, appearance: ContentAppearance = .light) {
        source.configure(state)
        controller = SiteControlController(source: source, actions: source)
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.appearance = (state == "scc-dark" ? ContentAppearance.dark : appearance).nsAppearance
        anchorButton.frame = CGRect(x: 186, y: 49, width: 30, height: 30)
        root.addSubview(anchorButton)
        root.addSubview(controller.view)
        window = OffscreenRenderer.host(root, scale: scale)
        controller.geometry = { [weak root] anchor in
            guard let root else { return nil }
            let rect = anchor == .urlField ? CGRect(x: 186, y: 49, width: 30, height: 30) : CGRect(x: 850, y: 12, width: 32, height: 28)
            return SiteControlGeometry(anchor: rect, sidebarMaxX: 228,
                                       content: CGRect(x: 228, y: 10, width: root.bounds.width - 238, height: root.bounds.height - 20))
        }
        anchorButton.invoke = { [weak controller, weak source] in
            guard let source else { return }
            controller?.toggle(anchor: .urlField, tabID: source.tabID, animated: false)
        }
        // Opening goes through the native anchor's target/action path.
        if state == "scc-pane-anchor" { controller.present(anchor: .paneBar(source.tabID), tabID: source.tabID, animated: false) }
        else { anchorButton.performClick(nil) }
        OffscreenRenderer.settle(root)
    }
    func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    func click(_ p: CGPoint) {
        let wp = CGPoint(x: p.x, y: root.bounds.height - p.y)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let parentPoint = root.superview?.convert(wp, from: nil) ?? wp
        let hit = root.hitTest(parentPoint)
        hit?.mouseDown(with: event)
    }
    func tap(_ id: String) { controller.view.panel.control(id: id)?.performClick(nil) }
    func menu(_ title: String) {
        let menu = controller.makeMenu()
        guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else { return }
        menu.performActionForItem(at: index)
    }
    var focusedID: String? { (window.firstResponder as? NSView)?.identifier?.rawValue }
    func render(scale: CGFloat) -> CGImage {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(root); OffscreenRenderer.settle(root)
        return OffscreenRenderer().snapshot(root, scale: scale)
    }
}
