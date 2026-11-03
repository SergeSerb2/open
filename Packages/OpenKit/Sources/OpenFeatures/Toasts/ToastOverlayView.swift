import AppKit

/// The one view that holds a window's toasts (page-platform D-1): its frame is the toast anchor
/// (the web panel; the window content in HTML fullscreen; the page view in Little Open). Toasts sit
/// at its top-right corner. The overlay is hidden while no toast exists, and only toast buttons
/// take clicks: everything else reaches the page below.
@MainActor
public final class ToastOverlayView: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; isHidden = true
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    /// The anchor moved or resized (sidebar hide, split, window resize): toasts keep their
    /// top-right place without animating.
    var onResize: (() -> Void)?
    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Newest first: the top toast's button wins where two overlap.
        for case let toast as ToastView in subviews.reversed() {
            if let hit = toast.hitTest(local) { return hit }
        }
        return nil
    }
}
