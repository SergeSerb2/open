import AppKit

/// Arc's window buttons at rest: three muted circles that let the window background
/// through (`WindowControlColors`), each with a faint ring in its button's color while the
/// window is active. It only draws; the system buttons above it do everything else.
/// Clicks pass through.
@MainActor
public final class DimmedTrafficLightsView: NSView {
    /// Button centers in this view's coordinates.
    public var centers: [CGPoint] = [] { didSet { if centers != oldValue { rebuild() } } }
    /// Light or dark content (the Space's text appearance, as for the sidebar).
    public var tone: ContentAppearance = .light { didSet { if tone != oldValue { rebuild() } } }
    /// The colored rings show only while the window is active: inactive Arc draws the same
    /// fill without them (capture session 2, 03 step 4).
    public var showsRing = true { didSet { if showsRing != oldValue { circles.forEach { $0.ring.isHidden = !showsRing } } } }
    /// Called when the pointer enters or leaves the group (`groupRect`), also while the
    /// app is inactive.
    public var onHoverChange: ((Bool) -> Void)?
    /// The group's hover region in this view's coordinates.
    public var groupRect: CGRect = .zero { didSet { if groupRect != oldValue { updateTrackingAreas() } } }
    public private(set) var isPointerInside = false
    private var tracking: NSTrackingArea?
    private var circles: [(fill: CAShapeLayer, ring: CAShapeLayer)] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !groupRect.isEmpty else { return }
        let area = NSTrackingArea(rect: groupRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        onHoverChange?(inside)
    }

    private func rebuild() {
        guard let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circles.forEach { $0.fill.removeFromSuperlayer(); $0.ring.removeFromSuperlayer() }
        circles = []
        let dark = tone == .dark
        let fill = WindowControlColors.dimmed.resolved(tone)
            .withAlpha(dark ? WindowControlColors.fillOpacity.dark : WindowControlColors.fillOpacity.light)
        let ringAlpha = dark ? WindowControlColors.ringOpacity.dark : WindowControlColors.ringOpacity.light
        let colors = [WindowControlColors.closeRing, WindowControlColors.minimizeRing, WindowControlColors.zoomRing].map { $0.resolved(tone) }
        let r = ChromeMetrics.trafficLightDiameter / 2
        for (index, center) in centers.enumerated() {
            let f = CAShapeLayer()
            f.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
            f.fillColor = fill.cgColor
            let ring = CAShapeLayer()
            let annulus = CGMutablePath()
            annulus.addEllipse(in: CGRect(x: center.x - r - 1, y: center.y - r - 1, width: 2 * r + 2, height: 2 * r + 2))
            annulus.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            ring.path = annulus
            ring.fillRule = .evenOdd
            ring.fillColor = colors[index % colors.count].withAlpha(ringAlpha).cgColor
            ring.isHidden = !showsRing
            layer.addSublayer(f); layer.addSublayer(ring)
            circles.append((f, ring))
        }
        CATransaction.commit()
    }
}
