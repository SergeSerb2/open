import AppKit

/// Arc's window buttons at rest: three muted circles that let the window background
/// through (`WindowControlColors`), each with a faint ring in its button's color while the
/// window is active. It only draws; the system buttons above it do everything else.
/// Clicks pass through.
@MainActor
public final class DimmedTrafficLightsView: NSView {
    /// Explicit motion belongs to this child layer. AppKit synchronizes the
    /// view's backing layer when it lays out the native title bar.
    public let motionLayer = CALayer()
    /// Button centers in this view's coordinates.
    public var centers: [CGPoint] = [] { didSet { if centers != oldValue { rebuild() } } }
    /// Light or dark content (the Space's text appearance, as for the sidebar).
    public var tone: ContentAppearance = .light { didSet { if tone != oldValue { rebuild() } } }
    /// The colored rings show only while the window is active: inactive Arc draws the same
    /// fill without them (capture session 2, 03 step 4).
    public var showsRing = true {
        didSet {
            guard showsRing != oldValue else { return }
            // At once, as macOS changes its own buttons on a key change (no implicit fade).
            CATransaction.begin(); CATransaction.setDisableActions(true)
            circles.forEach { $0.ring.isHidden = !showsRing }
            CATransaction.commit()
        }
    }
    /// Called when the pointer enters or leaves the group (`groupRect`), also while the
    /// app is inactive.
    public var onHoverChange: ((Bool) -> Void)?
    /// Where the pointer is now, in window base coordinates, or nil when unknown. The
    /// default reads the hardware pointer; automation substitutes its own pointer.
    public var pointerLocation: (() -> NSPoint?)?
    /// The group's hover region in this view's coordinates.
    public var groupRect: CGRect = .zero { didSet { if groupRect != oldValue { updateTrackingAreas() } } }
    /// The view owns the hover state. A tracking area that AppKit re-creates (unhide, frame
    /// change, full-screen exit) sends no exit for a pointer that left meanwhile, and a hidden
    /// view gets none at all, so the state is cleared on hide and read again from the
    /// pointer whenever the area is rebuilt or the window comes back.
    public private(set) var isPointerInside = false
    private var tracking: NSTrackingArea?
    private var circles: [(fill: CAShapeLayer, ring: CAShapeLayer)] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        motionLayer.anchorPoint = .zero
        layer?.addSublayer(motionLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        let size = bounds.size
        guard motionLayer.bounds.size != size else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        motionLayer.bounds = CGRect(origin: .zero, size: size)
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !groupRect.isEmpty else { setPointerInside(false); return }
        let area = NSTrackingArea(rect: groupRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
        syncWithPointer()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        setPointerInside(false)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        syncWithPointer()
    }

    /// Sets the hover state from where the pointer is now (after a full-screen exit, a
    /// restore from the Dock, or when the group shows again).
    public func syncWithPointer() {
        guard let window, !isHiddenOrHasHiddenAncestor, !groupRect.isEmpty else { setPointerInside(false); return }
        let location = pointerLocation.map { $0() } ?? window.mouseLocationOutsideOfEventStream
        guard let location else { return }
        setPointerInside(groupRect.contains(convert(location, from: nil)))
    }

    public override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        onHoverChange?(inside)
    }

    private func rebuild() {
        let layer = motionLayer
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
