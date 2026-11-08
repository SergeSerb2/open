import AppKit
import QuartzCore
import OpenDesign

@MainActor
private final class IntroButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(isHighlighted ? 0.85 : 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: IntroColors.blue]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22).stroke()
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
    public var onGetStarted: (@MainActor () -> Void)?
    public private(set) var animationStartHostTime = 0.0
    public private(set) var skipped = false
    public private(set) var ambientPaused = false
    public private(set) var handingOff = false
    private let scene = CALayer()
    private let room = CAGradientLayer()
    private let composition = CALayer()
    private let ambient = CALayer()
    private let mark = CALayer()
    private let spillGroup = CALayer()
    private let button = IntroButton(title: "Continue", target: nil, action: nil)
    private var tracks: [IntroTrack] = []
    private var orbs: [CALayer] = []
    private var tasks: [Task<Void, Never>] = []
    private var measureLink: CADisplayLink?
    private var previousFrame: Double?
    private var intervals: [Double] = []
    private var nominalInterval = 1.0/60
    private var renderTime: Double?
    public var elapsed: Double { renderTime ?? (animationStartHostTime == 0 ? 0 : max(0, CACurrentMediaTime()-animationStartHostTime)) }
    public var ready: Bool { skipped || elapsed >= IntroTimeline.beat(reduceMotion ? "reduceButton" : "sellCompleted").start }

    public init(reduceMotion: Bool, scale: CGFloat = 2, increaseContrast: Bool = false) {
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(origin: .zero, size: OnboardingTokens.windowSize))
        wantsLayer = true
        layer?.backgroundColor = IntroColors.room.cgColor
        scene.bounds = NSRect(origin: .zero, size: OnboardingTokens.windowSize)
        scene.isGeometryFlipped = true
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
    isolated deinit { measureLink?.invalidate(); tasks.forEach { $0.cancel() } }

    public override func layout() { super.layout(); layoutScene() }
    private func layoutScene() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = min(bounds.width/1280, bounds.height/800)
        scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
        scene.setAffineTransform(.init(scaleX: scale, y: scale))
        button.frame = NSRect(x: bounds.midX-100*scale, y: bounds.midY+(616-400)*scale, width: 200*scale, height: 44*scale)
        CATransaction.commit()
    }

    private func makeScene(scale: CGFloat, increaseContrast: Bool) {
        let full = CGRect(origin: .zero, size: OnboardingTokens.windowSize)
        room.frame = full
        room.colors = [IntroColors.color(0x1A3FD0).cgColor, IntroColors.room.cgColor]
        room.startPoint = .init(x: 0.2, y: 0); room.endPoint = .init(x: 0.8, y: 1)
        scene.addSublayer(room)
        add(room, "opacity", [0, 1], "room", curve: [0, 0, 0.58, 1])
        ambient.frame = full; scene.addSublayer(ambient)
        let orbSpecs: [(UInt32, CGFloat, CGFloat, CGFloat, Float)] = [
            (0x3D7BFF, 590, 250, 240, 0.35), (0x6A4DFF, 500, 850, 400, 0.25), (0xFF9A3D, 640, 550, 330, 0.22)]
        for (i, spec) in orbSpecs.enumerated() {
            let orb = radial(spec.0, diameter: spec.1)
            orb.position = .init(x: spec.2, y: spec.3); orb.opacity = i == 2 ? 0 : spec.4
            ambient.addSublayer(orb); orbs.append(orb)
        }
        add(ambient, "opacity", [0, 1], "room", curve: [0, 0, 0.58, 1])
        add(orbs[2], "opacity", [0, 0.22], "spill")
        let spill = radial(0xFFD7A0, diameter: 480); spill.position = .init(x: 640, y: 336)
        spillGroup.frame = full; scene.addSublayer(spillGroup); spillGroup.addSublayer(spill)
        add(spill, "transform.scale", [0.2, 3.5], "spill")
        add(spill, "opacity", [0, 0.55, 0.30], "spill", fractions: [0, 0.65, 1])
        let grain = CAReplicatorLayer(); grain.frame = full
        if let image = Grain.tile(noiseFactor: 0.6, scale: scale) {
            let rows = CAReplicatorLayer(); rows.frame = full
            rows.instanceCount = Int(ceil(full.height/Grain.tilePoints)); rows.instanceTransform = CATransform3DMakeTranslation(0, Grain.tilePoints, 0)
            let tile = CALayer(); tile.frame = .init(x: 0, y: 0, width: Grain.tilePoints, height: Grain.tilePoints)
            tile.contents = image; tile.contentsScale = scale
            rows.addSublayer(tile); grain.addSublayer(rows)
            grain.instanceCount = Int(ceil(full.width/Grain.tilePoints)); grain.instanceTransform = CATransform3DMakeTranslation(Grain.tilePoints, 0, 0)
        }
        scene.addSublayer(grain)
        composition.frame = full; scene.addSublayer(composition)
        mark.frame = full; mark.anchorPoint = CGPoint(x: 0.5, y: 0.42); mark.position = CGPoint(x: 640, y: 336); composition.addSublayer(mark)
        add(mark, "position.y", [336, 276], "markMove", spring: true)
        add(mark, "transform.scale", [1, 0.8], "markMove", spring: true)
        let rect = CGRect(x: 596, y: 276, width: 88, height: 120)
        let path = CGPath(roundedRect: rect, cornerWidth: 44, cornerHeight: 44, transform: nil)
        let interior = CAGradientLayer(); interior.frame = full
        interior.colors = [IntroColors.color(0xFFD7A0, alpha: 0.8).cgColor, IntroColors.color(0xFF9A3D, alpha: 0.08).cgColor]
        interior.startPoint = .init(x: 0.5, y: 0.34); interior.endPoint = .init(x: 0.5, y: 0.51)
        let mask = CAShapeLayer(); mask.frame = full; mask.path = path; mask.fillColor = NSColor.white.cgColor
        interior.mask = mask; mark.addSublayer(interior); add(interior, "opacity", [0, 1], "spill")
        for glow in [true, false] {
            let door = CAShapeLayer(); door.frame = full; door.path = path
            door.fillColor = nil; door.strokeColor = NSColor.white.cgColor
            door.lineWidth = 7; door.lineCap = .round; door.strokeStart = 0.08; door.strokeEnd = 0.88
            door.name = glow ? "doorGlow" : "door"
            if glow { door.shadowPath = path.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 0); door.shadowColor = NSColor.white.cgColor; door.shadowRadius = 18; door.shadowOpacity = 0.6; door.shadowOffset = .zero }
            mark.addSublayer(door)
            add(door, "strokeEnd", [0.08, 0.88], "door", curve: [0.65, 0, 0.35, 1])
            if glow { add(door, "opacity", [0, 1], "door", curve: [0.65, 0, 0.35, 1]) }
        }
        let sunClip = CALayer(); sunClip.frame = .init(x: 0, y: 0, width: 1280, height: rect.maxY); sunClip.masksToBounds = true
        mark.addSublayer(sunClip)
        let sun = CALayer(); sun.bounds = .init(x: 0, y: 0, width: 22, height: 22); sun.cornerRadius = 11
        sun.backgroundColor = IntroColors.color(0xFF9F2E).cgColor; sun.position = .init(x: 657, y: 316)
        sun.shadowColor = IntroColors.color(0xFF9F2E).cgColor; sun.shadowRadius = 30; sun.shadowOpacity = 0.9
        sun.shadowOffset = .zero; sun.shadowPath = CGPath(ellipseIn: sun.bounds, transform: nil); sun.name = "sun"
        sunClip.addSublayer(sun)
        add(sun, "position.y", [rect.maxY+42, 316], "sun", spring: true)
        let word = text("Open", size: 56, weight: .semibold, frame: .init(x: 390, y: 352, width: 500, height: 72), scale: scale, alpha: 1)
        composition.addSublayer(word)
        add(word, "opacity", [0, 1], "wordmark"); add(word, "position.y", [word.position.y+12, word.position.y], "wordmark")
        let line = text(OnboardingTokens.line, size: 17, weight: .regular, frame: .init(x: 310, y: 475, width: 660, height: 28), scale: scale, alpha: increaseContrast ? 0.9 : 0.75)
        composition.addSublayer(line); add(line, "opacity", [0, 1], "line")
        for (i, title) in ["Spaces for every part of your life.", "Tabs that tidy themselves.", "Everything stays on this Mac."].enumerated() {
            let value = text(title, size: 15, weight: .regular, frame: .init(x: 310, y: 517+CGFloat(i)*28, width: 660, height: 25), scale: scale, alpha: 0.6)
            composition.addSublayer(value); add(value, "opacity", [0, 1], "value\(i+1)")
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
        let layer = CATextLayer(); layer.frame = frame; layer.contentsScale = scale; layer.alignmentMode = .center
        layer.isGeometryFlipped = true
        layer.string = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        return layer
    }
    private func add(_ layer: CALayer, _ key: String, _ values: [Double], _ beat: String, fractions: [Double] = [0, 1], curve: [Float] = [0.42, 0, 0.58, 1], spring: Bool = false) {
        tracks.append(.init(layer: layer, key: key, values: values, fractions: fractions, beat: beat, curve: curve, spring: spring))
    }

    public func start(at hostTime: Double, measureFrames: Bool) {
        guard animationStartHostTime == 0 else { return }
        animationStartHostTime = hostTime
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
            for (i, orb) in orbs.enumerated() {
                let drift = CAKeyframeAnimation(keyPath: "position")
                let p = orb.position
                drift.values = [p, CGPoint(x: p.x+35, y: p.y-24), CGPoint(x: p.x-18, y: p.y+18), p].map { NSValue(point: $0) }
                drift.keyTimes = [0, 0.35, 0.7, 1]; drift.timingFunctions = (0..<3).map { _ in .init(name: .easeInEaseOut) }
                drift.duration = IntroTimeline.beat(["orbBlue", "orbPurple", "orbWarm"][i]).end
                drift.autoreverses = true; drift.repeatCount = .infinity; drift.beginTime = 0
                orb.add(drift, forKey: "ambient-drift")
            }
        }
        let buttonBeat = IntroTimeline.beat(reduceMotion ? "reduceButton" : "button")
        button.alphaValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        // NSView's layer is outside the scene; convert the common host time.
        fade.beginTime = hostTime+buttonBeat.start; fade.duration = max(0.001, buttonBeat.end-buttonBeat.start)
        fade.fillMode = .both; fade.isRemovedOnCompletion = false
        button.layer?.add(fade, forKey: "button-fade")
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
        CATransaction.commit()
        if skipped { skip() }
        schedule(at: reduceMotion ? buttonBeat.end : buttonBeat.start) { [weak self] in self?.enableButton() }
        schedule(at: IntroTimeline.beat("idlePause").start) { [weak self] in self?.pauseAmbient() }
        if measureFrames {
            nominalInterval = 1/Double(max(1, window?.screen?.maximumFramesPerSecond ?? 60))
            let link = displayLink(target: self, selector: #selector(recordFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(1/nominalInterval), maximum: Float(1/nominalInterval), preferred: Float(1/nominalInterval))
            measureLink = link; link.add(to: .main, forMode: .common)
            schedule(at: IntroTimeline.beat("measureFrames").end) { [weak self] in self?.measureLink?.invalidate(); self?.measureLink = nil }
        }
    }
    private func schedule(at time: Double, action: @escaping @MainActor () -> Void) {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(0, animationStartHostTime+time-CACurrentMediaTime())))
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
        CATransaction.commit(); enableButton()
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
        composition.isHidden = true; button.isHidden = true
    }
    public override func cancelOperation(_ sender: Any?) { skip() }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { skip() }
        else if [36, 76, 49].contains(event.keyCode) { if ready { getStarted() } }
        else { super.keyDown(with: event) }
    }
    public override func mouseDown(with event: NSEvent) { skip() }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Before enabled, even a click in the future button's frame skips.
        if !ready { return bounds.contains(convert(point, from: superview)) ? self : nil }
        return super.hitTest(point)
    }
    public func stop() {
        tasks.forEach { $0.cancel() }; tasks.removeAll(); measureLink?.invalidate(); measureLink = nil
        pauseAmbient()
    }
    private func pauseAmbient() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for orb in orbs { let t = orb.convertTime(CACurrentMediaTime(), from: nil); orb.speed = 0; orb.timeOffset = t }
        CATransaction.commit(); ambientPaused = true
    }
    @objc private func recordFrame(_ link: CADisplayLink) {
        guard link.timestamp >= animationStartHostTime else { return }
        if let previousFrame, intervals.count < 4096 { intervals.append(link.timestamp-previousFrame) }
        previousFrame = link.timestamp
    }
    public var frameStats: [String: Any] {
        let ordered = intervals.sorted()
        func percentile(_ p: Double) -> Double { ordered.isEmpty ? 0 : ordered[min(ordered.count-1, Int(Double(ordered.count-1)*p))]*1000 }
        return ["count": ordered.count, "p50MS": percentile(0.5), "p95MS": percentile(0.95), "maxMS": percentile(1),
                "drops": intervals.filter { $0 > nominalInterval*1.5 }.count, "nominalMS": nominalInterval*1000, "running": measureLink != nil]
    }
    public var state: [String: Any] {
        let animationKeys = tracks.flatMap { t in (t.layer.animationKeys() ?? []).map { "\(t.layer.name ?? t.beat):\($0)" } } + orbs.flatMap { $0.animationKeys() ?? [] } + (composition.animationKeys() ?? [])
        let door = tracks.first { $0.key == "strokeEnd" && $0.layer.name == "door" }!.layer
        let sun = tracks.first { $0.beat == "sun" }!.layer
        return ["phase": skipped ? "sellCompleted" : IntroTimeline.phase(at: elapsed, reduceMotion: reduceMotion), "elapsed": elapsed,
                "animationStartHostTime": animationStartHostTime, "reduceMotion": reduceMotion, "skipped": skipped,
                "ready": ready, "buttonEnabled": button.isEnabled, "buttonDefault": button.keyEquivalent == "\r",
                "buttonLabel": button.accessibilityLabel() ?? "", "ambientPaused": ambientPaused,
                "animations": animationKeys, "frameStats": frameStats,
                "doorStrokeEnd": (door.presentation() ?? door).value(forKeyPath: "strokeEnd") ?? 0,
                "sunY": (sun.presentation() ?? sun).position.y]
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
        CATransaction.commit()
        layoutSubtreeIfNeeded(); displayIfNeeded(); button.displayIfNeeded(); layer?.displayIfNeeded()
        let width = Int(bounds.width*scale), height = Int(bounds.height*scale)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.scaleBy(x: scale, y: scale)
        layer?.render(in: context)
        // An unshown NSButton has no WindowServer backing contents. Ask the
        // real control to draw itself, then composite that exact native bitmap.
        if button.alphaValue > 0,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(button.bounds.width*scale), pixelsHigh: Int(button.bounds.height*scale),
             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = button.bounds.size; button.cacheDisplay(in: button.bounds, to: rep)
            if let image = rep.cgImage {
                context.saveGState(); context.setAlpha(button.alphaValue)
                context.draw(image, in: .init(x: button.frame.minX, y: bounds.height-button.frame.maxY, width: button.frame.width, height: button.frame.height))
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
    private func apply(at time: Double) {
        for track in tracks { track.layer.setValue(track.value(at: reduceMotion ? IntroTimeline.beat("button").end : time), forKeyPath: track.key) }
        if reduceMotion {
            let fade = IntroTimeline.beat("reduceFade")
            let opacity = Float(min(1, max(0, time/fade.end)))
            composition.opacity = opacity; ambient.opacity = opacity; spillGroup.opacity = opacity; room.opacity = opacity
        }
    }
}
