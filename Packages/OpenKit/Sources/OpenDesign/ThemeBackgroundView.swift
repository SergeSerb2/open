import AppKit
import QuartzCore
import OpenModel

/// Window background for a Space theme: the gradient field plus grain, as plain
/// CALayers. Place it behind the sidebar and the web panel so it fills the whole
/// window; the field is defined in window uv space.
///
/// Cost: the field is a 64×64 float image stretched by the GPU, rebuilt only when
/// the theme, the active state, or the window aspect changes. Grain is one 100 pt
/// tile repeated by replicator layers (shared contents, no large bitmaps).
///
/// Space switches cross-fade two theme layers. `beginTransition(to:)` +
/// `setTransitionProgress(_:)` drive it from a swipe; `crossfade(to:)` animates it.
@MainActor
public final class ThemeBackgroundView: NSView {
    public var style: SpaceThemeStyle {
        get { current.theme }
        set { crossfade(to: newValue, animated: false) }
    }
    /// The style shown once any running cross-fade ends.
    public var targetStyle: SpaceThemeStyle { incoming?.theme ?? current.theme }

    public var isWindowActive: Bool = true {
        didSet { if isWindowActive != oldValue { refresh() } }
    }
    /// Scale used for the grain tile. Set by renderers without a window.
    public var renderScale: CGFloat? { didSet { refresh() } }

    private var current = ThemeLayer(style: .defaultTheme(system: .light))
    private var incoming: ThemeLayer?
    private var displayLink: CADisplayLink?
    private var displayTarget: ThemeDisplayTarget?
    private var resizing = false
    public private(set) var fieldRebuildCount = 0
    public private(set) var animatedThemeChangeCount = 0
    public var isCrossfading: Bool { incoming?.animation(forKey: "opacity") != nil }

    isolated deinit { displayLink?.invalidate() }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(current)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    private var scale: CGFloat { renderScale ?? window?.backingScaleFactor ?? 2 }

    public override func layout() {
        super.layout()
        refresh()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        resizing = true
        displayLink?.invalidate()
        displayLink = nil
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizing = false
        refresh()
    }

    private func refresh() {
        // Stretch the existing field while resizing. Rebuild only on a display tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [current, incoming].compactMap({ $0 }) {
            layer.frame = bounds
            layer.resize(to: bounds.size)
        }
        CATransaction.commit()
        guard !inLiveResize, !resizing, displayLink == nil, bounds.width > 0, bounds.height > 0 else { return }
        let target = displayTarget ?? ThemeDisplayTarget(owner: self)
        displayTarget = target
        let link = displayLink(target: target, selector: #selector(ThemeDisplayTarget.tick(_:)))
        self.displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func displayFrame() {
        displayLink?.invalidate()
        displayLink = nil
        guard !inLiveResize, !resizing else { return }
        rebuildFields()
    }

    /// Offscreen renderers have no visible display ticks. Flush once after layout.
    public func prepareForSnapshot() {
        displayFrame()
    }

    private func rebuildFields() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [current, incoming].compactMap({ $0 }) {
            l.frame = bounds
            if l.update(size: bounds.size, active: isWindowActive, scale: scale) { fieldRebuildCount += 1 }
        }
        CATransaction.commit()
    }

    /// Starts an interactive cross-fade to `style` at progress 0.
    public func beginTransition(to style: SpaceThemeStyle) {
        if let incoming, incoming.theme == style { return }
        incoming?.removeFromSuperlayer()
        let l = ThemeLayer(style: style)
        l.opacity = 0
        layer?.addSublayer(l)
        incoming = l
        refresh()
    }

    /// Sets the incoming theme's opacity (0…1) without animation.
    public func setTransitionProgress(_ progress: Double) {
        guard let incoming else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.opacity = Float(min(max(progress, 0), 1))
        CATransaction.commit()
    }

    /// Finishes or cancels an interactive transition, animating the rest.
    public func endTransition(commit: Bool, duration: CFTimeInterval = Motion.themeCrossfade) {
        guard let incoming else { return }
        if commit { finish(to: incoming, duration: duration) } else {
            animateOpacity(incoming, to: 0, duration: duration) { [weak self] in
                incoming.removeFromSuperlayer()
                if self?.incoming === incoming { self?.incoming = nil }
            }
        }
    }

    /// Cross-fades to `style`. Without animation it swaps at once.
    public func crossfade(to style: SpaceThemeStyle, animated: Bool, duration: CFTimeInterval = Motion.themeCrossfade) {
        if incoming == nil, current.theme == style { return }
        // Already fading to this style: let the running fade finish.
        if animated, let incoming, incoming.theme == style, incoming.animation(forKey: "opacity") != nil { return }
        if !animated {
            incoming?.removeFromSuperlayer(); incoming = nil
            current.theme = style
            refresh()
            return
        }
        animatedThemeChangeCount += 1
        beginTransition(to: style)
        if let incoming { finish(to: incoming, duration: duration) }
    }

    private func finish(to layer: ThemeLayer, duration: CFTimeInterval) {
        animateOpacity(layer, to: 1, duration: duration) { [weak self] in
            guard let self, self.incoming === layer else { return }
            self.current.removeFromSuperlayer()
            self.current = layer
            self.incoming = nil
        }
    }

    private func animateOpacity(_ layer: CALayer, to value: Float, duration: CFTimeInterval, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Motion.themeCrossfadeTiming)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = value
        layer.opacity = value
        layer.add(a, forKey: "opacity")
        CATransaction.commit()
    }
}

/// The display link retains this target, which holds the view weakly.
@MainActor
private final class ThemeDisplayTarget: NSObject {
    weak var owner: ThemeBackgroundView?
    init(owner: ThemeBackgroundView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.displayFrame() }
}

/// One theme: the gradient field plus the grain tile layers.
final class ThemeLayer: CALayer {
    var theme: SpaceThemeStyle { didSet { if theme != oldValue { fieldKey = nil; grainKey = nil } } }
    private let field = CALayer()
    private let grainColumns = CAReplicatorLayer()
    private let grainRows = CAReplicatorLayer()
    private let grainTile = CALayer()
    private var fieldKey: FieldKey?
    private var grainKey: GrainKey?

    private struct FieldKey: Equatable { var active: Bool; var aspect: Int }
    private struct GrainKey: Equatable { var noise: Double; var scale: CGFloat; var texture: SpaceStyleTexture }

    init(style: SpaceThemeStyle) {
        self.theme = style
        super.init()
        anchorPoint = .zero
        field.contentsGravity = .resize
        field.magnificationFilter = .linear
        field.minificationFilter = .linear
        field.anchorPoint = .zero
        grainRows.addSublayer(grainTile)
        grainColumns.addSublayer(grainRows)
        grainColumns.isHidden = true
        grainColumns.masksToBounds = true
        addSublayer(field)
        addSublayer(grainColumns)
    }

    override init(layer: Any) {
        theme = (layer as? ThemeLayer)?.theme ?? .defaultTheme(system: .light)
        super.init(layer: layer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @MainActor func resize(to size: CGSize) {
        field.frame = CGRect(origin: .zero, size: size)
        let t = theme.usesLegacyIntensity ? Grain.tilePoints : ThemeTexture.period(theme.texture)
        grainTile.frame = CGRect(x: 0, y: 0, width: t, height: t)
        grainRows.frame = CGRect(x: 0, y: 0, width: t, height: size.height)
        grainRows.instanceCount = Int((size.height / t).rounded(.up))
        grainRows.instanceTransform = CATransform3DMakeTranslation(0, t, 0)
        grainColumns.frame = CGRect(origin: .zero, size: size)
        grainColumns.instanceCount = Int((size.width / t).rounded(.up))
        grainColumns.instanceTransform = CATransform3DMakeTranslation(t, 0, 0)
    }

    @MainActor func update(size: CGSize, active: Bool, scale: CGFloat) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        resize(to: size)
        // Rebuild when the aspect ratio moves by more than 0.5 %.
        let key = FieldKey(active: active, aspect: Int((size.width / size.height * 200).rounded()))
        let rebuilt = key != fieldKey
        if rebuilt {
            fieldKey = key
            field.contents = ThemeField.makeImage(style: theme, windowSize: size, isActive: active)
        }
        let noise = theme.noiseFactor
        grainTile.opacity = theme.usesLegacyIntensity ? 1 : Float(ThemeTexture.layerAlpha(theme.texture, noiseFactor: noise))
        guard noise > 0 else { grainColumns.isHidden = true; return rebuilt }
        let gkey = GrainKey(noise: noise, scale: scale, texture: theme.texture)
        if gkey != grainKey {
            grainKey = gkey
            // Legacy snapshots used exact noise, not the editor's 0.05 bucket.
            grainTile.contents = theme.usesLegacyIntensity
                ? Grain.tile(noiseFactor: noise, scale: scale)
                : ThemeTexture.tile(theme.texture, noiseFactor: noise, scale: scale)
            grainTile.contentsScale = scale
        }
        grainColumns.isHidden = false
        return rebuilt
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
