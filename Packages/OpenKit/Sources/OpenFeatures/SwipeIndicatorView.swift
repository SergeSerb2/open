import AppKit
import OpenDesign

/// Open's history swipe indicator over one page (page-platform §4.4.2–§4.4.3). The engine's own
/// arrow overlay is off for pages that show it (`drawsEngineHistorySwipeOverlay = NO`); the shell
/// feeds Chromium's swipe phases through `update(_:)`. It never takes mouse events and does no work
/// while no swipe runs (no timer, no display link).
@MainActor
public final class SwipeIndicatorView: NSView {
    public enum Phase: String, Sendable { case began, changed, completed, cancelled }
    public enum Direction: String, Sendable { case back, forward }
    public struct Event: Sendable, Equatable {
        public var phase: Phase
        public var direction: Direction
        public var progress: Double
        public init(phase: Phase, direction: Direction, progress: Double) {
            self.phase = phase; self.direction = direction; self.progress = progress
        }
    }

    public var style: SpaceThemeStyle = .defaultTheme(system: .light) { didSet { applyColors() } }
    /// The last event (automation and checks).
    public private(set) var last: Event?
    /// True while a swipe is shown or its exit animation runs.
    public private(set) var isActive = false
    private let circle = CALayer()
    private let glyph = CALayer()
    private var direction: Direction = .back
    private var progress: Double = 0
    private var ready = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        circle.cornerRadius = SwipeIndicatorMetrics.diameter / 2
        circle.bounds = CGRect(x: 0, y: 0, width: SwipeIndicatorMetrics.diameter, height: SwipeIndicatorMetrics.diameter)
        circle.opacity = 0
        circle.addSublayer(glyph)
        layer?.addSublayer(circle)
        isHidden = true
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isFlipped: Bool { false }

    /// One engine swipe event.
    public func update(_ event: Event) {
        last = event
        switch event.phase {
        case .began:
            direction = event.direction; ready = false; isActive = true; isHidden = false
            setGlyph()
            place(progress: event.progress, animated: false)
            if Motion.reducesMotion { place(progress: 1, animated: false); fadeIn() }
        case .changed:
            guard isActive else { return }
            if Motion.reducesMotion { return }
            place(progress: event.progress, animated: false)
        case .completed:
            guard isActive else { return }
            finish(fade: SwipeIndicatorMetrics.completedFade, slideBack: false)
        case .cancelled:
            guard isActive else { return }
            finish(fade: SwipeIndicatorMetrics.cancelledSlide, slideBack: !Motion.reducesMotion)
        }
    }

    public override func layout() {
        super.layout()
        if isActive { place(progress: Motion.reducesMotion ? 1 : progress, animated: false) }
    }

    /// The circle's unscaled frame in this view's coordinates (model values; checks).
    public var circleFrame: CGRect {
        let d = SwipeIndicatorMetrics.diameter
        return CGRect(x: circle.position.x - d / 2, y: circle.position.y - d / 2, width: d, height: d)
    }
    public var circleOpacity: Float { circle.opacity }
    public var circleScale: CGFloat { circle.affineTransform().a }
    public func circleHasAnimation(_ key: String) -> Bool { circle.animation(forKey: key) != nil }

    // MARK: Private

    private func place(progress p: Double, animated: Bool) {
        progress = min(1, max(0, p))
        let d = SwipeIndicatorMetrics.diameter
        let offset = SwipeIndicatorMetrics.offset(progress: progress)
        let x = direction == .back ? offset : bounds.width - offset - d
        CATransaction.begin(); CATransaction.setDisableActions(!animated)
        circle.position = CGPoint(x: x + d / 2, y: bounds.midY)
        if !Motion.reducesMotion {
            circle.opacity = Float(SwipeIndicatorMetrics.baseAlpha + (1 - SwipeIndicatorMetrics.baseAlpha) * CGFloat(progress))
        }
        CATransaction.commit()
        let isReady = progress >= 1 && !Motion.reducesMotion
        if isReady != ready { ready = isReady; setReadyScale(isReady) }
    }

    private func setReadyScale(_ isReady: Bool) {
        let scale = isReady ? SwipeIndicatorMetrics.readyScale : 1
        let from = circle.presentation()?.affineTransform() ?? circle.affineTransform()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        guard !Motion.reducesMotion else { return }
        let a = Motion.toastIn.animation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(from))
        a.toValue = NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))
        circle.add(a, forKey: "ready")
    }

    private func fadeIn() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = SwipeIndicatorMetrics.reduceMotionFade
        CATransaction.begin(); CATransaction.setDisableActions(true); circle.opacity = 1; CATransaction.commit()
        circle.add(a, forKey: "fade")
    }

    private func finish(fade duration: CFTimeInterval, slideBack: Bool) {
        isActive = false
        let token = UUID()
        finishToken = token
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        if slideBack {
            let d = SwipeIndicatorMetrics.diameter
            let x = direction == .back ? -d : bounds.width
            circle.position = CGPoint(x: x + d / 2, y: bounds.midY)
        }
        circle.opacity = 0
        CATransaction.commit()
        progress = 0
        if ready { ready = false; CATransaction.begin(); CATransaction.setDisableActions(true); circle.setAffineTransform(.identity); CATransaction.commit() }
        // One-shot hide when the exit animation ends (no timer while idle).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.finishToken == token, !self.isActive else { return }
                self.isHidden = true
            }
        }
    }
    private var finishToken = UUID()

    private func applyColors() {
        circle.backgroundColor = style.toastFillTop.nsColor.cgColor
        setGlyph()
    }

    private func setGlyph() {
        let name = direction == .back ? "chevron.backward" : "chevron.forward"
        let config = NSImage.SymbolConfiguration(pointSize: SwipeIndicatorMetrics.glyphPointSize, weight: .semibold)
            .applying(.init(paletteColors: [style.toastText.nsColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var rect = CGRect(origin: .zero, size: image.size)
        glyph.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        glyph.contentsScale = scale
        let d = SwipeIndicatorMetrics.diameter
        glyph.frame = CGRect(x: (d - image.size.width) / 2, y: (d - image.size.height) / 2, width: image.size.width, height: image.size.height)
    }
}
