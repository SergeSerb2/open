import AppKit
import QuartzCore

/// Window background for a Space theme: the gradient field plus grain, as plain
/// CALayers. Place it behind the sidebar and the web panel so it fills the whole
/// window; the field is defined in window uv space.
///
/// Cost: the field is a 64×64 float image stretched by the GPU, rebuilt only when
/// the theme, the active state, or the window aspect changes. Grain is one 100 pt
/// tile repeated by replicator layers (shared contents, no large bitmaps).
@MainActor
public final class ThemeBackgroundView: NSView {
    public var style: SpaceThemeStyle = .defaultTheme(system: .light) {
        didSet { if style != oldValue { invalidateField(animated: true) } }
    }
    public var isWindowActive: Bool = true {
        didSet { if isWindowActive != oldValue { invalidateField(animated: false) } }
    }

    private let fieldLayer = CALayer()
    private let grainColumns = CAReplicatorLayer()
    private let grainRows = CAReplicatorLayer()
    private let grainTile = CALayer()
    private var fieldKey: FieldKey?
    private var grainKey: GrainKey?

    private struct FieldKey: Equatable { var style: SpaceThemeStyle; var active: Bool; var aspect: Int }
    private struct GrainKey: Equatable { var noise: Double; var scale: CGFloat }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fieldLayer.contentsGravity = .resize
        fieldLayer.magnificationFilter = .linear
        fieldLayer.minificationFilter = .linear
        fieldLayer.needsDisplayOnBoundsChange = false
        grainRows.addSublayer(grainTile)
        grainColumns.addSublayer(grainRows)
        grainColumns.isHidden = true
        layer?.addSublayer(fieldLayer)
        layer?.addSublayer(grainColumns)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fieldLayer.frame = bounds
        layoutGrain()
        CATransaction.commit()
        updateField(animated: false)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Scale used for the grain tile. Set by renderers without a window.
    public var renderScale: CGFloat?
    private var scale: CGFloat { renderScale ?? window?.backingScaleFactor ?? 2 }

    private func invalidateField(animated: Bool) {
        updateField(animated: animated)
        needsLayout = true
    }

    private func updateField(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Rebuild when the aspect ratio moves by more than 0.5 %.
        let key = FieldKey(style: style, active: isWindowActive, aspect: Int((bounds.width / bounds.height * 200).rounded()))
        guard key != fieldKey else { return }
        fieldKey = key
        let image = ThemeField.makeImage(style: style, windowSize: bounds.size, isActive: isWindowActive)
        if animated && fieldLayer.contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.themeCrossfade
            fade.timingFunction = Motion.easeInOut
            fieldLayer.add(fade, forKey: "theme")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        fieldLayer.contents = image
        CATransaction.commit()
    }

    private func layoutGrain() {
        let noise = style.noiseFactor
        guard noise > 0 else { grainColumns.isHidden = true; return }
        let gkey = GrainKey(noise: noise, scale: scale)
        if gkey != grainKey {
            grainKey = gkey
            grainTile.contents = Grain.tile(noiseFactor: noise, scale: scale)
            grainTile.contentsScale = scale
        }
        let t = Grain.tilePoints
        grainTile.frame = CGRect(x: 0, y: 0, width: t, height: t)
        grainRows.frame = CGRect(x: 0, y: 0, width: t, height: bounds.height)
        grainRows.instanceCount = Int((bounds.height / t).rounded(.up))
        grainRows.instanceTransform = CATransform3DMakeTranslation(0, t, 0)
        grainColumns.frame = bounds
        grainColumns.instanceCount = Int((bounds.width / t).rounded(.up))
        grainColumns.instanceTransform = CATransform3DMakeTranslation(t, 0, 0)
        grainColumns.masksToBounds = true
        grainColumns.isHidden = false
    }
}

/// The rounded web content panel frame: radius, shadow, and the empty-state fill.
/// The App owns the real web view; this layer provides the chrome around it.
/// The shadow is masked to the outside of the panel so a translucent (empty)
/// panel is not darkened by its own shadow, as in Arc.
public final class WebPanelChromeLayer: CALayer {
    public var showsEmptyState: Bool = true { didSet { updateFill() } }
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    private let fillLayer = CALayer()

    public override init() {
        super.init()
        shadowLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.shadowOpacity = PanelMetrics.shadowOpacity
        shadowLayer.shadowRadius = PanelMetrics.shadowRadius
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        fillLayer.cornerRadius = PanelMetrics.cornerRadius
        fillLayer.cornerCurve = .circular
        fillLayer.masksToBounds = true
        addSublayer(shadowLayer)
        addSublayer(fillLayer)
        updateFill()
    }

    public override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func updateFill() {
        fillLayer.backgroundColor = showsEmptyState ? CGColor(gray: 1, alpha: PanelMetrics.emptyFillWhiteAlpha) : CGColor(gray: 1, alpha: 1)
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = PanelMetrics.cornerRadius
        let shape = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = shape
        // "1 pt down" on screen, whatever the geometry flip of the host.
        let down: CGFloat = (superlayer?.contentsAreFlipped() ?? false) ? 1 : -1
        shadowLayer.shadowOffset = CGSize(width: 0, height: down * PanelMetrics.shadowOffsetY)
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -24, dy: -24))
        outside.addPath(shape)
        shadowMask.frame = bounds
        shadowMask.path = outside
        fillLayer.frame = bounds
        CATransaction.commit()
    }
}
