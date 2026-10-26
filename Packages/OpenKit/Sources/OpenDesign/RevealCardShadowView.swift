import AppKit

/// The hover-reveal card's shadow. The card clips its content to its rounded shape, and a
/// layer that clips cannot draw its own shadow, so this view sits right below the card with
/// the same frame and motion. It draws nothing but the shadow of a rounded-rect path, on a
/// sublayer: AppKit owns the shadow properties of a view's backing layer and resets them.
@MainActor
public final class RevealCardShadowView: NSView {
    private let shadowLayer = CALayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = WindowMetrics.revealCardShadowOpacity
        shadowLayer.shadowRadius = WindowMetrics.revealCardShadowRadius
        shadowLayer.shadowOffset = .zero
        layer?.addSublayer(shadowLayer)
        updateShadow()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadow()
    }

    private func updateShadow() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r = WindowMetrics.revealCardRadius
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
    }
}
