import AppKit
import OpenDesign

/// The overlay. The App adds it above the web content and the sidebar, filling the
/// window's content view. It is transparent: Arc does not dim the page (interaction-states
/// §9.1); only the panel's wide shadow darkens it. A click outside the panel closes the bar.
@MainActor
public final class CommandBarView: NSView {
    let container = PanelContainerView(frame: .zero)
    var panel: PanelView { container.panel }
    /// Called for a mouse-down outside the panel.
    var onClickOutside: (() -> Void)?
    /// False while hidden: the overlay then passes every event through.
    var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }

    /// Visible rows; sets the panel height.
    var visibleRowCount = 0 { didSet { if visibleRowCount != oldValue { needsLayout = true } } }

    public var panelFrame: CGRect { CommandBarMetrics.panelFrame(windowSize: bounds.size, rows: visibleRowCount) }

    public override func layout() {
        super.layout()
        let f = panelFrame
        if container.frame != f { container.frame = f }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        if container.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) { onClickOutside?() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Diagnostics (renders and checks)

    /// The trailing item: "info", "hint <Site>", "hint+space <Site>", or "none".
    public var debugTrailing: String {
        switch panel.input.input.trailing {
        case .info: "info"
        case .siteSearchHint(let name, let space): "\(space ? "hint+space" : "hint") \(name)"
        case .none: "none"
        }
    }
    /// The input row as drawn.
    public var debugInput: CommandBarInput { panel.input.input }
    /// Row draw passes since creation.
    public var debugRowDrawCount: Int { panel.results.rowDrawCount }
    /// True when the input is being edited by the bar's own field editor.
    public var debugUsesOwnFieldEditor: Bool { window?.firstResponder === panel.input.editor }
}

/// Holds the shadow and the panel; the open and close animations scale and fade it.
@MainActor
final class PanelContainerView: NSView {
    let panel = PanelView(frame: .zero)
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.shadowOpacity = CommandBarShadow.opacity
        shadowLayer.shadowRadius = CommandBarShadow.radius
        shadowLayer.actions = ["position": NSNull(), "bounds": NSNull(), "shadowPath": NSNull()]
        shadowMask.fillRule = .evenOdd
        shadowMask.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        shadowLayer.mask = shadowMask
        layer?.addSublayer(shadowLayer)
        addSubview(panel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        panel.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The shadow never darkens what shows through the translucent panel: the mask cuts the panel out
        // (Arc's fill over a white page is uniform up to the edge, A0120).
        let r = CommandBarMetrics.cornerRadius
        let path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        // Downward in the flipped view (checked: the comparison measures the bottom and top shadow, ΔE ≤ 0.5).
        shadowLayer.shadowOffset = CGSize(width: 0, height: (shadowLayer.isGeometryFlipped || layer?.isGeometryFlipped == true) ? -CommandBarShadow.offsetY : CommandBarShadow.offsetY)
        let margin = CommandBarShadow.radius * 4 + CommandBarShadow.offsetY
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds.insetBy(dx: -margin, dy: -margin))
        maskPath.addPath(path)
        shadowMask.frame = bounds
        shadowMask.path = maskPath
        CATransaction.commit()
        updateScaleTransform()
    }

    // MARK: Motion (provisional constants in OpenDesign `Motion.commandBar*`)

    /// Current animation scale, applied around the panel center.
    private var scale: CGFloat = 1

    private func transform(for scale: CGFloat) -> CATransform3D {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }

    private func updateScaleTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = transform(for: scale)
        CATransaction.commit()
    }

    func animateIn(animated: Bool) {
        guard let layer else { return }
        layer.removeAllAnimations()
        scale = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.sublayerTransform = transform(for: 1)
        CATransaction.commit()
        guard animated else { return }
        let spring = Motion.commandBarOpen
        let s = spring.animation(keyPath: "sublayerTransform")
        s.fromValue = NSValue(caTransform3D: transform(for: Motion.commandBarOpenScale))
        s.toValue = NSValue(caTransform3D: transform(for: 1))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = spring.response * 0.6
        fade.timingFunction = Motion.easeOut
        layer.add(s, forKey: "open.scale")
        layer.add(fade, forKey: "open.fade")
    }

    func animateOut(animated: Bool, completion: @escaping @MainActor () -> Void) {
        guard let layer, animated else { completion(); return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let d = Motion.commandBarClose
        let s = CABasicAnimation(keyPath: "sublayerTransform")
        s.fromValue = NSValue(caTransform3D: transform(for: 1))
        s.toValue = NSValue(caTransform3D: transform(for: Motion.commandBarCloseScale))
        s.duration = d
        s.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = d
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.sublayerTransform = transform(for: Motion.commandBarCloseScale)
        layer.add(s, forKey: "close.scale")
        layer.add(fade, forKey: "close.fade")
        CATransaction.commit()
    }
}
