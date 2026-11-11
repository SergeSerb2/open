import AppKit
import QuartzCore
import Metal
import OpenDesign

#if DEBUG || OPEN_AUTOMATION
/// CATextLayer draws synchronously by default. Keep that default and measure
/// its first rasterization separately from constructing the attributed text.
private final class IntroMeasuredTextLayer: CATextLayer {
    override func display() {
        guard Thread.isMainThread else { super.display(); return }
        let region = MainActor.assumeIsolated { IntroPacingTrace.begin("intro.text.display") }
        defer { MainActor.assumeIsolated { region?.end() } }
        super.display()
    }
}
#endif

@MainActor
private final class IntroButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("intro.button.draw")
        defer { pacingRegion?.end() }
        #endif
        OnboardingTokens.Room.white.withAlphaComponent(isHighlighted ? 0.85 : 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 26, yRadius: 26).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: OnboardingTokens.Room.ink]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 26, yRadius: 26).stroke()
        }
    }
}

/// Each scalar track supplies both the real CA animation and offscreen sampling.
/// The renderer has no second scene or independent set of timing constants.
@MainActor
private struct IntroTrack {
    let layer: CALayer
    let key: String
    let values: [Double]
    let fractions: [Double]
    let beat: String
    var curve: [Float] = [0.42, 0, 0.58, 1]
    var spring = false

    func animation() -> CAAnimation {
        let b = IntroTimeline.beat(beat)
        let result: CAPropertyAnimation
        if spring {
            let a = CASpringAnimation(keyPath: key)
            a.fromValue = values.first; a.toValue = values.last
            a.damping = 14; a.stiffness = 120; a.mass = 1; a.initialVelocity = 0
            result = a
        } else if values.count > 2 {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values; a.keyTimes = fractions.map { NSNumber(value: $0) }
            a.timingFunctions = (1..<values.count).map { _ in timingFunction }
            result = a
        } else {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = values.first; a.toValue = values.last; a.timingFunction = timingFunction
            result = a
        }
        result.beginTime = b.start; result.duration = b.end-b.start
        result.fillMode = .both; result.isRemovedOnCompletion = false
        return result
    }
    private var timingFunction: CAMediaTimingFunction { .init(controlPoints: curve[0], curve[1], curve[2], curve[3]) }
    func value(at t: Double) -> Double {
        let b = IntroTimeline.beat(beat)
        if t <= b.start { return values[0] }
        if t >= b.end { return values.last! }
        let u = (t-b.start)/(b.end-b.start)
        if spring {
            // The same damped harmonic oscillator as CASpringAnimation.
            let seconds = t-b.start, damp = 7.0, frequency = sqrt(120-49.0)
            let progress = 1-exp(-damp*seconds)*(cos(frequency*seconds)+damp/frequency*sin(frequency*seconds))
            return values[0]+(values.last!-values[0])*progress
        }
        let segment = (0..<fractions.count-1).first { u <= fractions[$0+1] } ?? fractions.count-2
        let x = (u-fractions[segment])/(fractions[segment+1]-fractions[segment])
        func cubic(_ s: Double, _ a: Float, _ b: Float) -> Double { 3*(1-s)*(1-s)*s*Double(a)+3*(1-s)*s*s*Double(b)+s*s*s }
        var low = 0.0, high = 1.0
        for _ in 0..<24 { let mid = (low+high)/2; if cubic(mid, curve[0], curve[2]) < x { low = mid } else { high = mid } }
        let y = cubic((low+high)/2, curve[1], curve[3])
        return values[segment]+(values[segment+1]-values[segment])*y
    }
}

/// Core Animation owns every visual frame. Only opt-in measurement uses a
/// display link. The few Tasks below are one-shot lifecycle deadlines.
@MainActor
public final class IntroView: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public let reduceMotion: Bool
    private let useScreenBlend: Bool
    private var roomSubmittedHostTime = 0.0
    private var roomLink: CADisplayLink?
    public var onFirstPresentation: (@MainActor () -> Void)?
    public var onGetStarted: (@MainActor () -> Void)?
    public private(set) var animationStartHostTime = 0.0
    public private(set) var skipped = false
    public private(set) var ambientPaused = false
    public private(set) var handingOff = false
    private let scene = CALayer()
    private let room = OnboardingRoomLayer(artwork: true)
    private let composition = CALayer()
    private let ambient = CALayer()
    private let mark = CALayer()
    private let spillGroup = CALayer()
    private let button = IntroButton(title: "Continue", target: nil, action: nil)
    private var tracks: [IntroTrack] = []
    private var orbTracks: [IntroTrack] = []
    private var orbs: [CALayer] = []
    private var tasks: [Task<Void, Never>] = []
    private var measureLink: CADisplayLink?
    private var previousFrame: Double?
    public private(set) var firstFrameHostTime: Double?
    private var measurementDeadline: Task<Void, Never>?
    private var intervals: [Double] = []
    private var nominalInterval = 1.0/60
    private var renderTime: Double?
    public var elapsed: Double { renderTime ?? (animationStartHostTime == 0 ? 0 : max(0, CACurrentMediaTime()-animationStartHostTime)) }
    public var ready: Bool { skipped || elapsed >= IntroTimeline.beat(reduceMotion ? "reduceButton" : "sellCompleted").start }

    public init(reduceMotion: Bool, scale: CGFloat = 2, increaseContrast: Bool = false, useScreenBlend: Bool = true) {
        self.reduceMotion = reduceMotion
        self.useScreenBlend = useScreenBlend
        super.init(frame: NSRect(origin: .zero, size: OnboardingTokens.windowSize))
        wantsLayer = true
        layer?.backgroundColor = IntroColors.room.cgColor
        scene.bounds = NSRect(origin: .zero, size: OnboardingTokens.windowSize)
        // AppKit already flips the backing layer for this top-down NSView.
        // Flipping a second time here would invert the entire live scene.
        layer?.addSublayer(scene)
        makeScene(scale: scale, increaseContrast: increaseContrast)
        button.isBordered = false; button.bezelStyle = .regularSquare
        button.wantsLayer = true; button.target = self; button.action = #selector(getStarted)
        button.setAccessibilityLabel("Continue"); button.setAccessibilityIdentifier("onboarding-continue")
        button.isEnabled = false; button.alphaValue = 0
        addSubview(button)
        layoutScene()
    }
    required init?(coder: NSCoder) { return nil }
    isolated deinit { roomLink?.invalidate(); measureLink?.invalidate(); measurementDeadline?.cancel(); tasks.forEach { $0.cancel() } }

    public override func layout() { super.layout(); layoutScene() }
    private func layoutScene() {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("intro.layout")
        defer { pacingRegion?.end() }
        #endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = min(bounds.width/1280, bounds.height/800)
        scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
        scene.setAffineTransform(.init(scaleX: scale, y: scale))
        button.frame = NSRect(x: bounds.midX-80*scale, y: 646*scale+(bounds.height-800*scale)/2, width: 160*scale, height: 52*scale)
        button.layer?.shadowColor = OnboardingTokens.Room.bloom.cgColor
        button.layer?.shadowOpacity = 0.35; button.layer?.shadowRadius = 20
        button.layer?.shadowOffset = CGSize(width: 0, height: 10)
        button.layer?.shadowPath = CGPath(roundedRect: button.bounds, cornerWidth: 26, cornerHeight: 26, transform: nil)
        commitIntroTransaction()
    }

    private func makeScene(scale: CGFloat, increaseContrast: Bool) {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("intro.layers.create")
        defer { pacingRegion?.end() }
        #endif
        let full = CGRect(origin: .zero, size: OnboardingTokens.windowSize)
        let rect = CGRect(x: 556, y: 140, width: 168, height: 248)
        room.frame = full; room.configure(size: full.size, doorway: rect)
        scene.addSublayer(room)
        add(room, "opacity", [0, 1], "room", curve: [0, 0, 0.58, 1])
        add(room.haze, "opacity", [0, 1], "spill")
        add(room.spill, "opacity", [0, 0.85, 0.7], "spill", fractions: [0, 0.65, 1])
        if useScreenBlend {
            room.haze.compositingFilter = "screenBlendMode"
            room.spill.compositingFilter = "screenBlendMode"
        }
        ambient.frame = full; scene.addSublayer(ambient)
        spillGroup.frame = full; scene.addSublayer(spillGroup)
        composition.frame = full; scene.addSublayer(composition)
        mark.frame = full; mark.anchorPoint = CGPoint(x: 0.5, y: 274.0/800)
        mark.position = CGPoint(x: 640, y: 274); composition.addSublayer(mark)
        add(mark, "position.y", [334, 274], "markMove", spring: true)
        add(mark, "transform.scale", [1.12, 1], "markMove", spring: true)
        let brand = OnboardingBrandMark.components(in: rect)
        mark.addSublayer(brand.bloom); add(brand.bloom, "opacity", [0, 1], "spill")
        mark.addSublayer(brand.light); add(brand.light, "opacity", [0, 1], "spill")
        let door = brand.doorway; door.frame = full; door.name = "door"
        mark.addSublayer(door)
        add(door, "strokeEnd", [0.08, 1], "door", curve: [0.65, 0, 0.35, 1])
        add(door, "opacity", [0, 1], "door")
        let sunClip = CALayer(); sunClip.frame = CGRect(x: 0, y: 0, width: 1280, height: rect.maxY); sunClip.masksToBounds = true
        mark.addSublayer(sunClip)
        let sun = brand.sun; sun.name = "sun"; sunClip.addSublayer(sun)
        add(sun, "position.y", [rect.maxY+42, Double(sun.position.y)], "sun", spring: true)
        let wordFrame = CGRect(x: 390, y: 448, width: 500, height: 130)
        let word = CAGradientLayer(); word.frame = wordFrame
        word.colors = [OnboardingTokens.Room.sunTop.cgColor,OnboardingTokens.Room.white.cgColor]
        word.locations = [0.3,1]; word.startPoint = CGPoint(x: 0.5,y: 0); word.endPoint = CGPoint(x: 0.5,y: 1)
        word.mask = text("Open", size: 104, weight: .semibold, frame: word.bounds, scale: scale, alpha: 1)
        composition.addSublayer(word)
        add(word, "opacity", [0, 1], "wordmark"); add(word, "position.y", [word.position.y+12, word.position.y], "wordmark")
        let line = text(OnboardingTokens.line, size: 22, weight: .regular,
            frame: CGRect(x: 270, y: 577, width: 740, height: 34), scale: scale, alpha: increaseContrast ? 0.9 : 0.78)
        composition.addSublayer(line)
        // The identity line yields its one position to each value, then returns.
        // All times still derive from the unchanged timeline anchors.
        let sell = IntroTimeline.beat("sellIntro"), span = sell.end-sell.start
        let lineStart = IntroTimeline.beat("line"), first = IntroTimeline.beat("value1"), last = IntroTimeline.beat("value3")
        let times = [sell.start,lineStart.start,lineStart.end,first.start-0.2,first.start,last.end,sell.end]
        add(line, "opacity", [0,0,1,1,0,0,1], "sellIntro", fractions: times.map { ($0-sell.start)/span })
        for (i,title) in ["Spaces for every part of your life.","Tabs that tidy themselves.","Everything stays on this Mac."].enumerated() {
            let value = text(title,size: 22,weight: .regular,frame: CGRect(x: 270,y: 577,width: 740,height: 34),scale: scale,alpha: 0.78)
            composition.addSublayer(value)
            add(value,"opacity",[0,1,1,0],"value\(i+1)",fractions: [0,0.18,0.82,1])
            add(value,"position.y",[value.position.y+8,value.position.y],"value\(i+1)")
        }
        apply(at: 0)
    }
    private func radial(_ color: UInt32, diameter: CGFloat) -> CAGradientLayer {
        let layer = CAGradientLayer(); layer.type = .radial
        layer.bounds = .init(x: 0, y: 0, width: diameter, height: diameter)
        layer.colors = [IntroColors.color(color).cgColor, IntroColors.color(color, alpha: 0).cgColor]
        layer.locations = [0, 1]; layer.startPoint = .init(x: 0.5, y: 0.5); layer.endPoint = .init(x: 1, y: 1)
        return layer
    }
    private func text(_ title: String, size: CGFloat, weight: NSFont.Weight, frame: CGRect, scale: CGFloat, alpha: CGFloat) -> CATextLayer {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("intro.text.fontAndLayer")
        defer { pacingRegion?.end() }
        #endif
        #if DEBUG || OPEN_AUTOMATION
        let layer = IntroMeasuredTextLayer()
        #else
        let layer = CATextLayer()
        #endif
        layer.frame = frame; layer.contentsScale = scale; layer.alignmentMode = .center
        layer.string = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: OnboardingTokens.Room.white.withAlphaComponent(alpha), .kern: size * (size > 50 ? -0.045 : -0.01)])
        return layer
    }
    private func add(_ layer: CALayer, _ key: String, _ values: [Double], _ beat: String, fractions: [Double] = [0, 1], curve: [Float] = [0.42, 0, 0.58, 1], spring: Bool = false) {
        tracks.append(.init(layer: layer, key: key, values: values, fractions: fractions, beat: beat, curve: curve, spring: spring))
    }

    public func start(at hostTime: Double, measureFrames: Bool) {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("intro.timeline.install")
        defer { pacingRegion?.end() }
        #endif
        guard animationStartHostTime == 0 else { return }
        animationStartHostTime = hostTime
        if measureFrames { beginFrameMeasurement(at: hostTime) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.beginTime = hostTime
        if reduceMotion {
            apply(at: IntroTimeline.beat("button").end)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.beginTime = IntroTimeline.beat("reduceFade").start; fade.duration = IntroTimeline.beat("reduceFade").end
            fade.fillMode = .both; fade.isRemovedOnCompletion = false
            composition.add(fade, forKey: "reduce-crossfade")
            ambient.add(fade, forKey: "reduce-crossfade")
            spillGroup.add(fade, forKey: "reduce-crossfade")
            room.add(fade, forKey: "reduce-crossfade")
        } else {
            for track in tracks {
                track.layer.setValue(track.values.last, forKeyPath: track.key)
                track.layer.add(track.animation(), forKey: track.key)
            }
            for track in orbTracks {
                let drift = track.animation()
                drift.autoreverses = true; drift.repeatCount = .infinity
                track.layer.add(drift, forKey: track.key)
            }
        }
        let buttonBeat = IntroTimeline.beat(reduceMotion ? "reduceButton" : "button")
        button.alphaValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        // NSView's layer is outside the scene; convert the common host time.
        fade.beginTime = hostTime+buttonBeat.start; fade.duration = max(0.001, buttonBeat.end-buttonBeat.start)
        fade.fillMode = .both; fade.isRemovedOnCompletion = false
        button.layer?.add(fade, forKey: reduceMotion ? "reduce-crossfade" : "button-fade")
        if !reduceMotion {
            let spring = CASpringAnimation(keyPath: "transform.translation.y")
            let response = IntroTimeline.beat("buttonSpring").end-IntroTimeline.beat("buttonSpring").start
            let frequency = 2*Double.pi/response
            spring.mass = 1; spring.stiffness = frequency*frequency; spring.damping = 2*0.9*frequency
            spring.fromValue = 24; spring.toValue = 0
            spring.beginTime = hostTime+buttonBeat.start; spring.duration = response
            spring.fillMode = .both; spring.isRemovedOnCompletion = false
            button.layer?.add(spring, forKey: "button-spring")
        }
        button.isEnabled = false
        commitIntroTransaction()
        if skipped { skip() }
        schedule(at: reduceMotion ? buttonBeat.end : buttonBeat.start) { [weak self] in self?.enableButton() }
        schedule(at: IntroTimeline.beat("idlePause").start) { [weak self] in self?.pauseAmbient() }

    }

    /// Confirm the first display refresh after the animated window is submitted.
    public func observeRoomPresentation() {
        guard firstFrameHostTime == nil, roomLink == nil else { return }
        roomSubmittedHostTime = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(roomPresented(_:)))
        roomLink = link; link.add(to: .main, forMode: .common)
    }
    @objc private func roomPresented(_ link: CADisplayLink) {
        if link.timestamp >= roomSubmittedHostTime { recordFirstPresentation(at: link.timestamp) }
    }
    public func recordFirstPresentation(at hostTime: Double) {
        guard firstFrameHostTime == nil else { return }
        firstFrameHostTime = hostTime; roomLink?.invalidate(); roomLink = nil
        onFirstPresentation?(); onFirstPresentation = nil
    }

    private func beginFrameMeasurement(at hostTime: Double) {
        guard measureLink == nil else { return }
        previousFrame = hostTime
        nominalInterval = 1/Double(max(1, window?.screen?.maximumFramesPerSecond ?? 60))
        let link = displayLink(target: self, selector: #selector(recordFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(1/nominalInterval), maximum: Float(1/nominalInterval), preferred: Float(1/nominalInterval))
        measureLink = link; link.add(to: .main, forMode: .common)
        #if DEBUG || OPEN_AUTOMATION
        IntroPacingTrace.current?.start(at: hostTime)
        #endif
        measurementDeadline = Task { [weak self] in
            let end = hostTime+IntroTimeline.beat("measureFrames").end
            try? await Task.sleep(for: .seconds(max(0, end-CACurrentMediaTime())), tolerance: .zero)
            guard !Task.isCancelled, let self else { return }
            measureLink?.invalidate(); measureLink = nil
            #if DEBUG || OPEN_AUTOMATION
            IntroPacingTrace.current?.finish()
            #endif
        }
    }

    #if DEBUG || OPEN_AUTOMATION
    /// Inspect the real backing tree, including masks and the native button.
    /// A missing presentation layer is reported, never replaced by the model.
    public static func staticLayerState(_ root: CALayer?) -> [String: Any] {
        var count = 0, missing = 0, differences = 0, keys: [String] = []
        func inspect(_ layer: CALayer) {
            count += 1; keys += layer.animationKeys() ?? []
            if let p = layer.presentation() {
                if p.opacity != layer.opacity || p.position != layer.position || p.bounds != layer.bounds
                    || p.anchorPoint != layer.anchorPoint || p.isHidden != layer.isHidden
                    || !CATransform3DEqualToTransform(p.transform, layer.transform)
                    || !CATransform3DEqualToTransform(p.sublayerTransform, layer.sublayerTransform) { differences += 1 }
                if let shape = layer as? CAShapeLayer, let displayed = p as? CAShapeLayer,
                   shape.strokeStart != displayed.strokeStart || shape.strokeEnd != displayed.strokeEnd { differences += 1 }
            } else { missing += 1 }
            (layer.sublayers ?? []).forEach(inspect)
            if let mask = layer.mask { inspect(mask) }
        }
        if let root { inspect(root) }
        return ["layerCount": count, "animationKeys": keys, "missingPresentation": missing,
                "presentationDifferences": differences, "static": count > 0 && missing == 0 && differences == 0 && keys.isEmpty]
    }
    public var staticSceneState: [String: Any] { Self.staticLayerState(layer) }
    #endif

    private func schedule(at time: Double, action: @escaping @MainActor () -> Void) {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(0, animationStartHostTime+time-CACurrentMediaTime())), tolerance: .zero)
            guard !Task.isCancelled else { return }; action()
        })
    }
    private func enableButton() {
        guard !handingOff else { return }
        button.isEnabled = true; button.keyEquivalent = "\r"; window?.defaultButtonCell = button.cell as? NSButtonCell
        NSAccessibility.post(element: button, notification: .layoutChanged)
    }
    public func skip() {
        guard !handingOff else { return }
        skipped = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for track in tracks { track.layer.removeAllAnimations() }
        composition.removeAllAnimations(); ambient.removeAllAnimations(); spillGroup.removeAllAnimations(); room.removeAllAnimations(); button.layer?.removeAllAnimations()
        apply(at: IntroTimeline.beat("button").end); button.alphaValue = 1
        commitIntroTransaction(); enableButton()
    }
    @objc public func getStarted() {
        guard ready, !handingOff else { return }
        handingOff = true; button.isEnabled = false; button.keyEquivalent = ""
        onGetStarted?()
    }
    public func fadeForHandoff() {
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = layer?.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = IntroTimeline.beat("handoff").end
        composition.opacity = 0; composition.add(fade, forKey: "handoff")
        button.alphaValue = 0; button.layer?.add(fade, forKey: "handoff")
    }
    /// Later screens reuse the room/orbs without rebuilding or restarting sound.
    public func showBackgroundOnly() {
        composition.isHidden = true; button.isHidden = true; ambient.opacity = 0.4
    }
    public override func cancelOperation(_ sender: Any?) { skip() }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { skip() }
        else if [36, 76, 49].contains(event.keyCode) { if ready { getStarted() } }
        else { super.keyDown(with: event) }
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        if !reduceMotion { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)) }
    }
    public override func mouseMoved(with event: NSEvent) {
        guard !reduceMotion else { return }
        let p = convert(event.locationInWindow, from: nil)
        room.parallax(x: min(3,max(-3,(p.x/max(1,bounds.width)-0.5)*6)),y: min(3,max(-3,(p.y/max(1,bounds.height)-0.5)*6)))
    }
    public override func mouseExited(with event: NSEvent) { room.parallax(x: 0,y: 0) }
    public override func mouseDown(with event: NSEvent) { skip() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Before enabled, even a click in the future button's frame skips.
        if !ready { return bounds.contains(convert(point, from: superview)) ? self : nil }
        return super.hitTest(point)
    }
    public func stop() {
        roomLink?.invalidate(); roomLink = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll(); measureLink?.invalidate(); measureLink = nil
        measurementDeadline?.cancel(); measurementDeadline = nil
        #if DEBUG || OPEN_AUTOMATION
        IntroPacingTrace.current?.finish()
        #endif
        pauseAmbient()
    }
    private func pauseAmbient() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for orb in orbs { let t = orb.convertTime(CACurrentMediaTime(), from: nil); orb.speed = 0; orb.timeOffset = t }
        commitIntroTransaction(); ambientPaused = true
    }
    @objc private func recordFrame(_ link: CADisplayLink) {
        guard link.timestamp > (previousFrame ?? animationStartHostTime),
              link.timestamp <= animationStartHostTime+IntroTimeline.beat("measureFrames").end else { return }
        if let previousFrame, intervals.count < 4096 {
            intervals.append(link.timestamp-previousFrame)
            #if DEBUG || OPEN_AUTOMATION
            IntroPacingTrace.current?.recordInterval(start: previousFrame, end: link.timestamp,
                nominal: nominalInterval, callback: CACurrentMediaTime())
            #endif
        }
        previousFrame = link.timestamp
    }
    public var frameStats: [String: Any] {
        let ordered = intervals.sorted()
        func percentile(_ p: Double) -> Double { ordered.isEmpty ? 0 : ordered[min(ordered.count-1, Int(Double(ordered.count-1)*p))]*1000 }
        return ["count": ordered.count, "p50MS": percentile(0.5), "p95MS": percentile(0.95), "maxMS": percentile(1),
                "drops": intervals.filter { $0 > nominalInterval*1.5 }.count, "nominalMS": nominalInterval*1000, "running": measureLink != nil,
                "startHostTime": animationStartHostTime, "duration": IntroTimeline.beat("measureFrames").end]
    }
    public var state: [String: Any] {
        func keys(_ root: CALayer) -> [String] {
            (root.animationKeys() ?? []) + (root.sublayers ?? []).flatMap(keys) + (root.mask.map(keys) ?? [])
        }
        func blendFilters(_ root: CALayer) -> [String] {
            ((root.compositingFilter as? String).map { [$0] } ?? [])
                + (root.sublayers ?? []).flatMap(blendFilters)
        }
        let animationKeys = layer.map(keys) ?? []
        let door = tracks.first { $0.key == "strokeEnd" && $0.layer.name == "door" }!.layer
        let sun = tracks.first { $0.beat == "sun" }!.layer
        var result: [String: Any] = ["phase": skipped ? "sellCompleted" : IntroTimeline.phase(at: elapsed, reduceMotion: reduceMotion), "elapsed": elapsed,
                "animationStartHostTime": animationStartHostTime,
                "firstFrameHostTime": firstFrameHostTime as Any? ?? NSNull(),
                "animationDelayMS": firstFrameHostTime.map { max(0, animationStartHostTime-$0)*1000 } as Any? ?? NSNull(),
                "reduceMotion": reduceMotion, "skipped": skipped,
                "ready": ready, "buttonEnabled": button.isEnabled, "buttonDefault": button.keyEquivalent == "\r",
                "buttonLabel": button.accessibilityLabel() ?? "", "ambientPaused": ambientPaused,
                "animations": animationKeys, "blendFilters": blendFilters(scene), "frameStats": frameStats,
                "doorStrokeEnd": (door.presentation() ?? door).value(forKeyPath: "strokeEnd") ?? 0,
                "sunY": (sun.presentation() ?? sun).position.y]
        #if DEBUG || OPEN_AUTOMATION
        if let trace = IntroPacingTrace.current { result.merge(trace.state) { _, new in new } }
        #endif
        return result
    }

    /// CLI only: sample the very same CA tracks into their model values. A
    /// bounded 2560x1600 RGBA bitmap is 16,384,000 bytes at the requested 2x.
    public func renderPNG(at time: Double, scale: CGFloat, to url: URL) throws {
        renderTime = time
        CATransaction.begin(); CATransaction.setDisableActions(true)
        apply(at: time)
        button.alphaValue = ready ? 1 : 0
        button.isEnabled = ready
        if !reduceMotion {
            let b = IntroTimeline.beat("button")
            button.alphaValue = CGFloat(min(1, max(0, (time-b.start)/(b.end-b.start))))
        }
        commitIntroTransaction()
        layoutSubtreeIfNeeded(); displayIfNeeded(); button.displayIfNeeded(); layer?.displayIfNeeded()
        let width = Int(bounds.width*scale), height = Int(bounds.height*scale)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.scaleBy(x: scale, y: scale)
        // CALayer.render(in:) has a different radial-gradient fallback from
        // the render server. CARenderer uses the real CA/Metal scene instead.
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.fileWriteUnknown) }
        let canvas = CALayer()
        let pixelBounds = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.frame = pixelBounds; canvas.isGeometryFlipped = true
        canvas.backgroundColor = IntroColors.room.cgColor
        let oldPosition = scene.position, oldTransform = scene.affineTransform()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.addSublayer(scene)
        scene.position = CGPoint(x: CGFloat(width)/2, y: CGFloat(height)/2)
        scene.setAffineTransform(oldTransform.scaledBy(x: scale, y: scale))
        commitIntroTransaction()
        defer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.insertSublayer(scene, at: 0); scene.position = oldPosition; scene.setAffineTransform(oldTransform)
            commitIntroTransaction()
        }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: space, kCARendererMetalCommandQueue: queue])
        renderer.layer = canvas; renderer.bounds = pixelBounds
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(pixelBounds); renderer.render(); renderer.endFrame()
        guard let fence = queue.makeCommandBuffer() else { throw CocoaError(.fileWriteUnknown) }
        fence.commit(); fence.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        pixels.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { texture.getBytes(base, bytesPerRow: width*4, from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)), mipmapLevel: 0) }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let rendered = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                space: space, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CocoaError(.fileWriteUnknown) }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.draw(rendered, in: bounds)
        context.restoreGState()
        // An unshown NSButton has no WindowServer backing contents. Ask the
        // real control to draw itself, then composite that exact native bitmap.
        if button.alphaValue > 0,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(button.bounds.width*scale), pixelsHigh: Int(button.bounds.height*scale),
             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = button.bounds.size; button.cacheDisplay(in: button.bounds, to: rep)
            if let image = rep.cgImage {
                context.saveGState(); context.setAlpha(button.alphaValue)
                let b = IntroTimeline.beat("buttonSpring")
                let seconds = max(0, time-b.start), frequency = 2*Double.pi/(b.end-b.start)
                let damp = 0.9*frequency, oscillation = frequency*sqrt(1-0.9*0.9)
                let offset = reduceMotion || time >= b.end ? 0 : 24*exp(-damp*seconds)*(cos(oscillation*seconds)+damp/oscillation*sin(oscillation*seconds))
                context.draw(image, in: .init(x: button.frame.minX, y: bounds.height-button.frame.maxY-offset, width: button.frame.width, height: button.frame.height))
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
    @inline(__always) private func commitIntroTransaction() {
        #if DEBUG || OPEN_AUTOMATION
        let region = IntroPacingTrace.begin("intro.CATransaction.commit")
        defer { region?.end() }
        #endif
        CATransaction.commit()
    }
    private func apply(at time: Double) {
        for track in tracks { track.layer.setValue(track.value(at: reduceMotion ? IntroTimeline.beat("button").end : time), forKeyPath: track.key) }
        for track in orbTracks {
            let period = IntroTimeline.beat(track.beat).end
            var t = reduceMotion ? 0 : min(time, IntroTimeline.beat("idlePause").start).truncatingRemainder(dividingBy: 2*period)
            if t > period { t = 2*period-t }
            track.layer.setValue(track.value(at: t), forKeyPath: track.key)
        }
        if reduceMotion {
            let fade = IntroTimeline.beat("reduceFade")
            let opacity = Float(min(1, max(0, time/fade.end)))
            composition.opacity = opacity; ambient.opacity = opacity; spillGroup.opacity = opacity; room.opacity = opacity
        }
    }
}
