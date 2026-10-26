import AppKit
import OpenDesign
import OpenSiteControl

@MainActor
final class Backdrop: NSView {
    var hits = 0, rightHits = 0, otherHits = 0
    var sidebarWidth: CGFloat = 228
    var privateBackdrop: CGImage?
    var showsPaneBar = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { hits += 1 }
    override func rightMouseDown(with event: NSEvent) { rightHits += 1 }
    override func otherMouseDown(with event: NSEvent) { otherHits += 1 }
    override func draw(_ dirtyRect: NSRect) {
        if let privateBackdrop { NSImage(cgImage: privateBackdrop,size: bounds.size).draw(in: bounds,from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: nil); return }
        NSColor(srgbRed: 37/255,green: 37/255,blue: 56/255,alpha: 1).setFill(); bounds.fill()
        NSColor.white.setFill(); CGRect(x: sidebarWidth,y: 10,width: bounds.width-sidebarWidth-10,height: bounds.height-20).fill()
        if showsPaneBar {
            NSColor(white: 0.16,alpha: 1).setFill()
            CGRect(x: sidebarWidth,y: 10,width: bounds.width-sidebarWidth-10,height: 48).fill()
        }
        SidebarColors.itemBackground.resolved(contentAppearance).nsColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: 8,y: 46,width: sidebarWidth-16,height: 36),xRadius: 10,yRadius: 10).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),.foregroundColor: Core.foregroundPrimary.resolved(contentAppearance).nsColor]
        ("Open" as NSString).draw(at: CGPoint(x: 24,y: 22),withAttributes: attrs)
        ("news.example.com" as NSString).draw(at: CGPoint(x: 20,y: 54),withAttributes: attrs)
    }
}

@MainActor
final class Stage {
    let source: FakeSource, root: Backdrop, controller: SiteControlController, window: ScaledWindow
    private(set) var openCPU: Double = 0, openWall: Double = 0
    let anchorButton = SiteControlButton(id: "harness.anchor",label: "Site Controls",symbol: "slider.horizontal.2.square",pointSize: 18)
    let scale: CGFloat
    private let materialImage: CGImage
    private var materialFrame: CGRect?
    private let syntheticMaterialKey: String?
    private static var syntheticSurfaces: [String: CGImage] = [:]
    private let appearance: ContentAppearance
    let state: String
    init(state: String = "scc-no-boosts",scale: CGFloat = 1,appearance: ContentAppearance = .dark,source: FakeSource? = nil,open: Bool = true,sidebarWidth: CGFloat = 228,size: CGSize = CGSize(width: 1000,height: 760),privateBackdrop: CGImage? = nil) {
        self.state = state; self.scale = scale; self.appearance = appearance
        self.source = source ?? FakeSource()
        let fixtureSize = state == "scc-clamped" ? CGSize(width: 400,height: 300) : size
        syntheticMaterialKey = privateBackdrop == nil ? "\(state == "scc-pane-anchor")|\(fixtureSize)|\(sidebarWidth)|\(scale)|\(appearance)" : nil
        root = Backdrop(frame: CGRect(origin: .zero,size: fixtureSize)); root.sidebarWidth = sidebarWidth; root.privateBackdrop = privateBackdrop; root.showsPaneBar = state == "scc-pane-anchor"; root.appearance = appearance.nsAppearance
        anchorButton.frame = state == "scc-pane-anchor" ? CGRect(x: root.bounds.width-105,y: 12,width: 32,height: 28) : CGRect(x: sidebarWidth-42,y: 49,width: 30,height: 30); anchorButton.isHidden = privateBackdrop != nil
        root.addSubview(anchorButton); window = OffscreenRenderer.host(root,scale: scale)
        window.orderFront(nil); window.makeFirstResponder(root); OffscreenRenderer.settle(root)
        let background = OffscreenRenderer().snapshot(root,scale: scale)
        materialImage = MaterialFallback.image(background,scale: scale,appearance: appearance)
        let wall = DispatchTime.now().uptimeNanoseconds, cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        controller = SiteControlController(source: self.source,actions: self.source)
        controller.view.frame = root.bounds; controller.view.autoresizingMask = [.width,.height]; root.addSubview(controller.view)
        controller.geometry = { [weak root] anchor in
            guard let root else { return nil }
            let button = anchor == .urlField ? CGRect(x: sidebarWidth-42,y: 49,width: 30,height: 30) : CGRect(x: root.bounds.width-105,y: 12,width: 32,height: 28)
            return SiteControlGeometry(anchor: button,urlFieldMaxY: anchor == .urlField ? 82 : nil,content: CGRect(x: sidebarWidth,y: 10,width: root.bounds.width-sidebarWidth-10,height: root.bounds.height-20))
        }
        anchorButton.invoke = { [weak controller,weak source = self.source] in guard let source else { return }; controller?.toggle(anchor: .urlField,tabID: source.tabID,animated: false) }
        if open {
            if state == "scc-pane-anchor" { controller.present(anchor: .paneBar(self.source.tabID),tabID: self.source.tabID,animated: false) }
            else if privateBackdrop != nil { controller.present(anchor: .urlField,tabID: self.source.tabID,animated: false) }
            else { click(CGPoint(x: sidebarWidth-27,y: 64)) }
        }
        for b in controller.view.panel.controls {
            let id = b.controlID.replacingOccurrences(of: "action.",with: "")
            if let phase = MaterialFallback.phases[id] { b.symbolPhase = phase }
        }
        prepareMaterial(); OffscreenRenderer.settle(root)
        openCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-cpu)/1_000_000; openWall = Double(DispatchTime.now().uptimeNanoseconds-wall)/1_000_000
        if state == "scc-hover-action" { controller.view.panel.controls.first?.mouseEntered(with: NSEvent()); OffscreenRenderer.settle(root); RunLoop.main.run(until: Date().addingTimeInterval(Motion.hoverFade+0.01)) }
    }
    isolated deinit { controller.view.removeFromSuperview(); window.contentView = nil; window.close(); CATransaction.flush() }
    func prepareMaterial() {
        let p = controller.view.panel
        guard p.frame.width>0,p.frame.height>0,materialFrame != p.frame else { return }
        materialFrame = p.frame
        let key = syntheticMaterialKey.map { $0+"|\(p.frame)|\(String(describing: p.arrowX))" }
        if let key,let cached = Self.syntheticSurfaces[key] { p.offscreenMaterial = cached }
        else {
            let image = MaterialFallback.surface(materialImage,panelFrame: p.frame,body: p.bodyRect,shape: p.shape,scale: scale,appearance: appearance)
            p.offscreenMaterial = image
            // Cache only deterministic synthetic backdrop resources. Every native
            // panel is still constructed, laid out and displayed by the benchmark.
            // Capture comparisons always compute a fresh surface.
            if let key { if Self.syntheticSurfaces.count>=32 { Self.syntheticSurfaces.removeAll() }; Self.syntheticSurfaces[key] = image }
        }
        p.offscreenMaterialFrame = p.bounds
        p.needsLayout = true
    }
    func key(code: UInt16,characters: String,modifiers: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: modifiers,timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,characters: characters,charactersIgnoringModifiers: characters,isARepeat: false,keyCode: code)!
        window.sendEvent(e)
    }
    private var eventNumber = 0
    func click(_ p: CGPoint,button: NSEvent.EventType = .leftMouseDown) {
        eventNumber += 1; let wp = CGPoint(x: p.x,y: root.bounds.height-p.y)
        let up: NSEvent.EventType = button == .rightMouseDown ? .rightMouseUp : button == .otherMouseDown ? .otherMouseUp : .leftMouseUp
        for type in [button,up] { let e = NSEvent.mouseEvent(with: type,location: wp,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: eventNumber,clickCount: 1,pressure: type == .leftMouseDown ? 1 : 0)!; window.sendEvent(e) }
    }
    func render(scale: CGFloat,presentation: Bool = false) -> CGImage {
        prepareMaterial(); OffscreenRenderer.settle(root)
        return OffscreenRenderer().snapshot(root,scale: scale,presentation: presentation)
    }
}
