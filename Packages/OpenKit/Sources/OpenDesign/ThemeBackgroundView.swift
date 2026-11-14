import AppKit
import QuartzCore
import OpenModel

/// Window background for a Space theme: the gradient field plus grain, as plain
/// CALayers. Place it behind the sidebar and the web panel so it fills the whole
/// window; the field is defined in window uv space.
///
/// Cost: the field is one solid color or a 64×64 float image stretched by the
/// GPU, rebuilt only when the theme, the active state, or the window aspect
/// changes. Static editor previews sit over an opaque underlay layer, so the window
/// server blends them in the display's space. Grain is one tile repeated by
/// replicator layers (shared contents, no large bitmaps).
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
        didSet {
            guard isWindowActive != oldValue else { return }
            // The key change and the new field land in one transaction: no display-tick wait.
            // A 64×64 field (or one solid color) is cheap; a live resize still defers it.
            if inLiveResize || resizing || bounds.isEmpty { refresh() } else { rebuildFields() }
        }
    }

    /// What lies under the theme (`WindowMaterial`).
    public enum Material: Sendable, Equatable {
        /// The window background: the active field, or the inactive one.
        case window
        /// The hover-reveal card: the theme tint at `1 − w` over the blurred page under it.
        case overPage
    }
    /// `.overPage` falls back to `.window` where no backdrop layer exists.
    public var material: Material = .window {
        didSet { if material != oldValue { applyMaterial() } }
    }
    /// Where the field lies in this view, when it is a window's field seen through a
    /// smaller view (the hover-reveal card shows the window's own field at its place,
    /// as Arc's card matches the anchored sidebar). Nil: the field fills the view.
    public var fieldFrame: CGRect? {
        didSet { if fieldFrame != oldValue { refresh() } }
    }
    private var fieldRect: CGRect { fieldFrame ?? bounds }
    /// True while a page blur sits under the theme (`.overPage` and the backdrop exists).
    public var drawsPageBlur: Bool { pageBlur?.superlayer != nil }
    /// Scale used for the grain tile. Set by renderers without a window.
    public var renderScale: CGFloat? { didSet { refresh() } }
    /// Static embedded previews must also finish updates while hidden. Rebuild
    /// their cached field at each input change instead of arming a display link.
    public var updatesFieldsSynchronously = false {
        didSet { if updatesFieldsSynchronously { displayFrame() } }
    }
    /// Editor fills blend in the destination's space (§17). `false` restores
    /// #120's precomputed Display P3 mix for the harness's A/B diagnostics.
    public var composesInDisplaySpace = true {
        didSet { if composesInDisplaySpace != oldValue { [current, incoming].compactMap { $0 }.forEach { $0.invalidateField() }; refresh() } }
    }

    /// Only real browser windows opt in. Embedded previews and the page card
    /// retain their fitted constant underlay.
    public var usesWindowBackdrop = false {
        didSet { if usesWindowBackdrop != oldValue { applyMaterial() } }
    }
    public var drawsWindowBackdrop: Bool { windowBlur?.isHidden == false }
    public var windowBackdropMaterial: Int? { drawsWindowBackdrop ? windowBlur?.material.rawValue : nil }
    public var isWindowBackdropActive: Bool { drawsWindowBackdrop && windowBlur?.state == .active }
    private let themeSurface = ThemeSurfaceView()
    private var windowBlur: NSVisualEffectView?
    private var windowWash: NSView?
    private struct WashKey: Equatable { var gray: Double; var opacity: Float }
    private var appliedWash: WashKey?

    private var current = ThemeLayer(style: .defaultTheme(system: .light))
    /// Holds the theme layers. Its opacity is `1 − w` over the page blur, else 1.
    private let themeHost = CALayer()
    private var pageBlur: CALayer?
    private var incoming: ThemeLayer?
    private var displayLink: CADisplayLink?
    private var displayTarget: ThemeDisplayTarget?
    private var resizing = false
    public private(set) var fieldRebuildCount = 0
    /// Read-only state for native lifecycle checks; this link is always one-shot.
    public var hasPendingDisplayUpdate: Bool { displayLink != nil }

    isolated deinit { displayLink?.invalidate() }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        themeHost.anchorPoint = .zero
        themeHost.allowsGroupOpacity = true
        themeHost.addSublayer(current)
        layer?.addSublayer(themeHost)
    }

    private func applyMaterial() {
        updateWindowMaterial()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if material == .overPage, let blur = pageBlur ?? PageBlurLayer.make() {
            pageBlur = blur
            blur.frame = bounds
            if blur.superlayer == nil { (themeSurface.superview == nil ? layer : themeSurface.layer)?.insertSublayer(blur, below: themeHost) }
            themeHost.opacity = Float(1 - WindowMaterial.backdropWeight)
        } else {
            pageBlur?.removeFromSuperlayer()
            themeHost.opacity = 1
        }
        CATransaction.commit()
        [current, incoming].compactMap { $0 }.forEach { $0.invalidateField() }
        refresh()
    }

    private func updateWindowMaterial() {
        if usesWindowBackdrop, themeSurface.superview == nil {
            // A sibling surface keeps the tint above AppKit's material layer.
            // Static previews retain their original layer tree byte for byte.
            themeSurface.wantsLayer = true
            themeSurface.layerContentsRedrawPolicy = .never
            themeSurface.frame = bounds
            addSubview(themeSurface)
            themeHost.removeFromSuperlayer()
            themeSurface.layer?.addSublayer(themeHost)
        }
        let style = targetStyle
        let enabled = usesWindowBackdrop && material == .window && style.isVibrant
        if enabled, windowBlur == nil {
            let blur = NSVisualEffectView(frame: bounds)
            blur.blendingMode = .behindWindow
            // The material sits below the theme. It must not apply vibrancy to
            // the sidebar's already fitted text and semantic role colors.
            blur.isEmphasized = false
            addSubview(blur, positioned: .below, relativeTo: themeSurface)
            windowBlur = blur
            let wash = NSView(frame: bounds)
            wash.wantsLayer = true
            wash.layerContentsRedrawPolicy = .never
            addSubview(wash, positioned: .above, relativeTo: blur)
            windowWash = wash
        }
        if let blur = windowBlur, blur.isHidden == enabled { blur.isHidden = !enabled }
        if let wash = windowWash, wash.isHidden == enabled { wash.isHidden = !enabled }
        guard enabled, let blur = windowBlur else { return }
        // The imported JSON is unchanged when macOS appearance changes (C14-T).
        // Its stored translucency selects the material; window appearance selects
        // the wash. Editor themes carry their explicit window scheme themselves.
        let dark = style.usesLegacyIntensity ? ContentAppearance(effectiveAppearance) == .dark : style.windowColorScheme == .dark
        let material: NSVisualEffectView.Material = style.translucency == .dark ? .dark : .light
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let state: NSVisualEffectView.State = isWindowActive ? .active : .inactive
        // Reapplying an appearance can invalidate AppKit's material subtree.
        // A field flush with unchanged inputs must not create another update.
        if blur.material != material { blur.material = material }
        if blur.appearance?.name != appearance { blur.appearance = NSAppearance(named: appearance) }
        if blur.state != state { blur.state = state }
        let isDefault: Bool
        if case .corners = style.fill { isDefault = true } else { isDefault = false }
        // Real-window C14-T output fit, with the existing theme coverage retained.
        // This constant wash leaves the system material to perform the blur and
        // saturation. Inactive windows cover it completely, as Arc's clear patches
        // are invariant across all three wallpapers. See window-translucency.md.
        let fit: (opacity: Float, gray: Double, inactiveGray: Double)
        switch (isDefault, dark) {
        case (false, false): fit = (0.4764, 1, 1)
        case (false, true): fit = (0.1701, 0, 0.8292)
        case (true, false): fit = (0.2319, 0.2641, 0.8366)
        case (true, true): fit = (0.1729, 0, 0.1023)
        }
        let key = WashKey(gray: isWindowActive ? fit.gray : fit.inactiveGray, opacity: isWindowActive ? fit.opacity : 1)
        if appliedWash != key {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            windowWash?.layer?.backgroundColor = NSColor(srgbRed: key.gray, green: key.gray, blue: key.gray, alpha: 1).cgColor
            windowWash?.layer?.opacity = key.opacity
            CATransaction.commit()
            appliedWash = key
        }
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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if usesWindowBackdrop { rebuildFields() }
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
        // Stretch the existing field while resizing. Ordinary windows coalesce
        // field rebuilds on a display tick; static previews finish them below.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if themeSurface.frame != bounds { themeSurface.frame = bounds }
        if let blur = windowBlur, blur.frame != bounds { blur.frame = bounds }
        if let wash = windowWash, wash.frame != bounds { wash.frame = bounds }
        themeHost.frame = themeSurface.bounds
        pageBlur?.frame = bounds
        for layer in [current, incoming].compactMap({ $0 }) {
            layer.frame = fieldRect
            layer.resize(to: fieldRect.size)
        }
        CATransaction.commit()
        if updatesFieldsSynchronously { displayFrame(); return }
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
        updateWindowMaterial()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [current, incoming].compactMap({ $0 }) {
            l.frame = fieldRect
            if l.update(size: fieldRect.size, active: isWindowActive, cardTint: drawsPageBlur, scale: scale, displaySpace: composesInDisplaySpace, windowTint: drawsWindowBackdrop) { fieldRebuildCount += 1 }
        }
        CATransaction.commit()
    }

    /// Starts an interactive cross-fade to `style` at progress 0.
    public func beginTransition(to style: SpaceThemeStyle) {
        if let incoming, incoming.theme == style { return }
        incoming?.removeFromSuperlayer()
        let l = ThemeLayer(style: style)
        l.opacity = 0
        themeHost.addSublayer(l)
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
                if self?.incoming === incoming { self?.incoming = nil; self?.refresh() }
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
        beginTransition(to: style)
        if let incoming { finish(to: incoming, duration: duration) }
    }

    private func finish(to layer: ThemeLayer, duration: CFTimeInterval) {
        animateOpacity(layer, to: 1, duration: duration) { [weak self] in
            guard let self, self.incoming === layer else { return }
            self.current.removeFromSuperlayer()
            self.current = layer
            self.incoming = nil
            self.refresh()
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

@MainActor
private final class ThemeSurfaceView: NSView {
    override var isFlipped: Bool { true }
}

/// The blurred page under the hover-reveal card: a backdrop layer with a Gaussian
/// blur (σ = `WindowMaterial.pageBlurSigma`), rendered by the window server from
/// whatever the window draws below it, including the engine's page layers. It does
/// work only while it is visible and the content under it changes.
/// CoreAnimation has no public backdrop layer; `NSVisualEffectView` adds its own
/// material tint and saturation, which would break the fitted 0.115 page share.
/// Returns nil (the card stays opaque) if the classes or keys are missing.
@MainActor
enum PageBlurLayer {
    /// Downsampling of the backdrop before the blur (cheaper; the blur hides it).
    static let scale: CGFloat = 0.25

    static func make() -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: make),
              let blur = filterClass.perform(make, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        let layer = layerClass.init()
        guard layer.responds(to: NSSelectorFromString("setScale:")) else { return nil }
        blur.setValue(WindowMaterial.pageBlurSigma, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        layer.filters = [blur]
        layer.setValue(scale, forKey: "scale")
        layer.anchorPoint = .zero
        return layer
    }
}

/// The display link retains this target, which holds the view weakly.
@MainActor
private final class ThemeDisplayTarget: NSObject {
    weak var owner: ThemeBackgroundView?
    init(owner: ThemeBackgroundView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.displayFrame() }
}

/// One theme: the underlay, gradient field, and grain tile layers. Static
/// previews include the opaque fitted underlay. Live windows instead draw the
/// fitted tint over the system material; each theme cross-fades as one group.
final class ThemeLayer: CALayer {
    var theme: SpaceThemeStyle { didSet { if theme != oldValue { fieldKey = nil; grainKey = nil } } }
    /// Constant neutral underlay for embedded previews and opaque themes.
    private let underlay = CALayer()
    private let field = CALayer()
    private let grainColumns = CAReplicatorLayer()
    private let grainRows = CAReplicatorLayer()
    private let grainTile = CALayer()
    private var fieldKey: FieldKey?
    private var grainKey: GrainKey?

    private struct FieldKey: Equatable { var active: Bool; var cardTint: Bool; var aspect: Int; var displaySpace: Bool; var windowTint: Bool }
    private struct GrainKey: Equatable { var noise: Double; var scale: CGFloat; var texture: SpaceStyleTexture }

    init(style: SpaceThemeStyle) {
        self.theme = style
        super.init()
        anchorPoint = .zero
        allowsGroupOpacity = true
        underlay.anchorPoint = .zero
        underlay.isHidden = true
        field.contentsGravity = .resize
        field.magnificationFilter = .linear
        field.minificationFilter = .linear
        field.anchorPoint = .zero
        grainRows.addSublayer(grainTile)
        grainColumns.addSublayer(grainRows)
        grainColumns.isHidden = true
        grainColumns.masksToBounds = true
        addSublayer(underlay)
        addSublayer(field)
        addSublayer(grainColumns)
    }

    override init(layer: Any) {
        theme = (layer as? ThemeLayer)?.theme ?? .defaultTheme(system: .light)
        super.init(layer: layer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func invalidateField() { fieldKey = nil }

    @MainActor func resize(to size: CGSize) {
        underlay.frame = CGRect(origin: .zero, size: size)
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

    @MainActor func update(size: CGSize, active: Bool, cardTint: Bool, scale: CGFloat, displaySpace: Bool, windowTint: Bool) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        resize(to: size)
        // Rebuild when the aspect ratio moves by more than 0.5 %.
        // The system material owns the live window's active state. Its tint,
        // like the page-card tint, is independent of that state.
        let key = FieldKey(active: (windowTint && theme.isVibrant) || active || cardTint, cardTint: cardTint, aspect: Int((size.width / size.height * 200).rounded()), displaySpace: displaySpace, windowTint: windowTint)
        let rebuilt = key != fieldKey
        if rebuilt {
            fieldKey = key
            if windowTint, theme.isVibrant {
                underlay.isHidden = true
                underlay.backgroundColor = nil
                field.backgroundColor = nil
                field.contents = ThemeField.makeWindowTint(style: theme, windowSize: size)
            } else if displaySpace, !cardTint, let c = ThemeField.composition(style: theme, windowSize: size, isActive: active) {
                underlay.backgroundColor = c.underlay
                underlay.isHidden = false
                field.backgroundColor = c.solid
                field.contents = c.image
            } else {
                underlay.isHidden = true
                underlay.backgroundColor = nil
                field.backgroundColor = nil
                field.contents = ThemeField.makeImage(style: theme, windowSize: size, isActive: key.active, cardTint: cardTint)
            }
        }
        let noise = theme.noiseFactor
        grainTile.opacity = theme.usesLegacyIntensity ? 1 : Float(ThemeTexture.layerAlpha(theme.texture, noiseFactor: noise))
        guard noise > 0 else { grainColumns.isHidden = true; return rebuilt }
        let gkey = GrainKey(noise: noise, scale: scale, texture: theme.texture)
        if gkey != grainKey {
            grainKey = gkey
            // Legacy snapshots keep exact-noise grain bytes; editor noise
            // changes only the intrinsic texture layer's opacity.
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
