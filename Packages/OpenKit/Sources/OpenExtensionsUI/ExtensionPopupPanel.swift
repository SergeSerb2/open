import AppKit
import OpenDesign

@MainActor public final class ExtensionPopupPanel: NSPanel {
    public var onResignKey: (() -> Void)?
    public var onCloseRequest: (() -> Void)?
    public var onReady: (() -> Void)?
    public private(set) weak var hostedView: NSView?
    public private(set) var isReady = false
    public override var canBecomeKey: Bool { isReady }
    public override var canBecomeMain: Bool { false }
    public init() {
        super.init(contentRect: CGRect(origin: .zero, size: ExtensionsMetrics.popupMinimum), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; hidesOnDeactivate = false; hasShadow = true
        isOpaque = false; backgroundColor = .clear
        let host = NSView(); host.wantsLayer = true
        host.layer?.cornerRadius = ExtensionsMetrics.popupCornerRadius
        host.layer?.cornerCurve = .continuous; host.layer?.masksToBounds = true
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = ExtensionsRole.popupStroke.cgColor(ContentAppearance(effectiveAppearance))
        contentView = host
        prepareNotReady()
    }
    public func host(view: NSView) {
        hostedView?.removeFromSuperview(); hostedView = view
        guard let contentView else { return }
        view.frame = contentView.bounds; view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        // A separate top layer keeps the inner edge above opaque engine content.
        contentView.layer?.borderColor = ExtensionsRole.popupStroke.cgColor(ContentAppearance(effectiveAppearance))
    }
    public func hosts(view: NSView) -> Bool { view === hostedView || (hostedView.map { view.isDescendant(of: $0) } ?? false) }
    public func prepareNotReady() { isReady = false; alphaValue = 0; ignoresMouseEvents = true }
    public func orderNotReady(parent: NSWindow? = nil) {
        prepareNotReady()
        if let parent, self.parent !== parent { self.parent?.removeChildWindow(self); parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }
    public func showWhenReady() {
        guard !isReady else { return }
        isReady = true; alphaValue = 1; ignoresMouseEvents = false
        makeKeyAndOrderFront(nil); onReady?()
    }
    public func detach() {
        hostedView?.removeFromSuperview(); hostedView = nil
        parent?.removeChildWindow(self); orderOut(nil); prepareNotReady()
    }
    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let changed = frame.size != frameRect.size
        super.setFrame(frameRect, display: flag)
        if changed { invalidateShadow() }
    }
    public override func resignKey() { super.resignKey(); onResignKey?() }
    public override func cancelOperation(_ sender: Any?) { onCloseRequest?() }
    public override func performClose(_ sender: Any?) { onCloseRequest?() }
}
