import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
final class Backdrop: NSView {
    var hits = 0
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { hits += 1 }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.95, alpha: 1).setFill(); bounds.fill()
        NSColor.white.setFill(); CGRect(x: 228, y: 10, width: bounds.width - 238, height: bounds.height - 20).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray]
        ("Open" as NSString).draw(at: CGPoint(x: 24, y: 22), withAttributes: attrs)
        ("news.example.com" as NSString).draw(at: CGPoint(x: 20, y: 54), withAttributes: attrs)
        ("A page for the Site Control Center harness" as NSString).draw(at: CGPoint(x: 280, y: 180), withAttributes: attrs)
    }
}

@MainActor
final class Stage {
    let source = FakeSource()
    let root = Backdrop(frame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    let controller: SiteControlController
    let window: ScaledWindow
    let anchorButton = SiteControlButton(id: "harness.anchor", label: "Site Controls", symbol: "slider.horizontal.2.square", pointSize: 18)
    init(state: String = "scc-basic", scale: CGFloat = 1, appearance: ContentAppearance = .light) {
        controller = SiteControlController(source: source, actions: source)
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.appearance = appearance.nsAppearance
        anchorButton.frame = CGRect(x: 186, y: 49, width: 30, height: 30)
        root.addSubview(anchorButton)
        root.addSubview(controller.view)
        window = OffscreenRenderer.host(root, scale: scale)
        controller.geometry = { [weak root] _ in
            guard let root else { return nil }
            return SiteControlGeometry(anchor: CGRect(x: 186, y: 49, width: 30, height: 30), sidebarMaxX: 228,
                                       content: CGRect(x: 228, y: 10, width: root.bounds.width - 238, height: root.bounds.height - 20))
        }
        anchorButton.invoke = { [weak controller, weak source] in
            guard let source else { return }
            controller?.toggle(anchor: .urlField, tabID: source.tabID, animated: false)
        }
        // Opening goes through the native anchor's target/action path.
        anchorButton.performClick(nil)
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
    func render(scale: CGFloat) -> CGImage {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(root); OffscreenRenderer.settle(root)
        return OffscreenRenderer().snapshot(root, scale: scale)
    }
}
