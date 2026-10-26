import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
final class Backdrop: NSView {
    var hits = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { hits += 1 }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.20, alpha: 1) : NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.95, alpha: 1)).setFill(); bounds.fill()
        (dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white).setFill()
        CGRect(x: 228, y: 10, width: bounds.width - 238, height: bounds.height - 20).fill()
        SidebarColors.itemBackground.nsColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: 8, y: 46, width: 212, height: 36), xRadius: 10, yRadius: 10).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Core.foregroundPrimary.nsColor]
        ("Open" as NSString).draw(at: CGPoint(x: 24, y: 22), withAttributes: attrs)
        ("news.example.com" as NSString).draw(at: CGPoint(x: 20, y: 54), withAttributes: attrs)
        ("A page for the Site Control Center harness" as NSString).draw(at: CGPoint(x: 280, y: 220), withAttributes: attrs)
    }
}

@MainActor
final class Stage {
    let source: FakeSource
    let root = Backdrop(frame: CGRect(x: 0, y: 0, width: 1000, height: 760))
    let controller: SiteControlController
    let window: ScaledWindow
    private(set) var openCPU: Double = 0
    private(set) var openWall: Double = 0
    let anchorButton = SiteControlButton(id: "harness.anchor", label: "Site Controls", symbol: "slider.horizontal.2.square", pointSize: 18)
    init(state: String = "scc-basic", scale: CGFloat = 1, appearance: ContentAppearance = .light, source: FakeSource? = nil, open: Bool = true) {
        self.source = source ?? FakeSource()
        root.appearance = appearance.nsAppearance
        anchorButton.frame = CGRect(x: 186, y: 49, width: 30, height: 30)
        root.addSubview(anchorButton)
        window = OffscreenRenderer.host(root, scale: scale)
        window.orderFront(nil); window.makeFirstResponder(root)
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        controller = SiteControlController(source: self.source, actions: self.source)
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.addSubview(controller.view)
        controller.geometry = { [weak root] _ in
            guard let root else { return nil }
            return SiteControlGeometry(anchor: CGRect(x: 186, y: 49, width: 30, height: 30), sidebarMaxX: 228,
                                       content: CGRect(x: 228, y: 10, width: root.bounds.width - 238, height: root.bounds.height - 20))
        }
        anchorButton.invoke = { [weak controller, weak source = self.source] in
            guard let source else { return }
            controller?.toggle(anchor: .urlField, tabID: source.tabID, animated: false)
        }
        // Real NSWindow dispatch in our offscreen harness window, with no global
        // input injection and no desktop or user-window automation.
        if open { click(CGPoint(x: 201, y: 64)) }
        OffscreenRenderer.settle(root)
        openCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000
        openWall = Double(DispatchTime.now().uptimeNanoseconds - wall) / 1_000_000
    }
    isolated deinit { window.close() }
    func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    private var eventNumber = 0
    func click(_ p: CGPoint) {
        eventNumber += 1
        let wp = CGPoint(x: p.x, y: root.bounds.height - p.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }

    }
    func render(scale: CGFloat) -> CGImage {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(root); OffscreenRenderer.settle(root)
        return OffscreenRenderer().snapshot(root, scale: scale)
    }
}
