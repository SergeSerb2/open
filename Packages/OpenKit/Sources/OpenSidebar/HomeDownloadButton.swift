import AppKit
import QuartzCore
import OpenDesign

/// App supplies session state only; the sidebar owns the badge's drawing and
/// finite animations. Geometry is the S11 design's labelled guess.
public struct DownloadBadgeState: Equatable, Sendable {
    public var running: Int
    public var progress: Double
    public var indeterminate: Bool
    public var completedAt: Date?
    public init(running: Int, progress: Double, indeterminate: Bool, completedAt: Date?) {
        self.running = running; self.progress = progress; self.indeterminate = indeterminate; self.completedAt = completedAt
    }
}

@MainActor
final class HomeDownloadButton: PlateButton, CAAnimationDelegate {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let check = NSImageView()
    private var previous: DownloadBadgeState?
    private(set) var completionCount = 0
    private(set) var completing = false

    init() {
        super.init(glyph: .library)
        for shape in [track, ring] {
            shape.fillColor = nil; shape.lineWidth = 2; shape.opacity = 0
            layer?.addSublayer(shape)
        }
        check.wantsLayer = true; check.layer?.opacity = 0
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        addSubview(check)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frame = CGRect(x: (bounds.width - 32) / 2, y: (bounds.height - 32) / 2, width: 32, height: 32)
        for shape in [track, ring] {
            shape.frame = frame
            shape.path = CGPath(ellipseIn: CGRect(x: 3, y: 3, width: 26, height: 26), transform: nil)
            shape.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        }
        check.frame = CGRect(x: bounds.midX - 4.5, y: bounds.midY - 4.5, width: 9, height: 9)
        CATransaction.commit()
    }
    override func updateLayer() {
        super.updateLayer()
        let state = tracked({ context?.downloadBadge }) { [weak self] in self?.needsDisplay = true }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = glyphTint(true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.strokeColor = (dark ? NSColor(srgbRed: 0.443, green: 0.467, blue: 0.510, alpha: 1) : NSColor(srgbRed: 0.808, green: 0.843, blue: 0.906, alpha: 1)).cgColor
        ring.strokeColor = tint.cgColor; check.contentTintColor = tint
        CATransaction.commit()
        guard state != previous else { return }
        let old = previous; previous = state
        if let state, state.running > 0 {
            if completing { interruptCompletion() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.opacity = 1; ring.opacity = 1; ring.strokeEnd = state.indeterminate ? 0.25 : state.progress
            CATransaction.commit()
            if state.indeterminate && ring.animation(forKey: "download-spin") == nil && !Motion.reducesMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = -Double.pi / 2; spin.toValue = 3 * Double.pi / 2
                spin.duration = 1; spin.repeatCount = .infinity
                ring.add(spin, forKey: "download-spin")
            } else if !state.indeterminate || Motion.reducesMotion { ring.removeAnimation(forKey: "download-spin") }
        } else if let date = state?.completedAt, date != old?.completedAt, Date().timeIntervalSince(date) < 2 {
            complete()
        } else if !completing { clearAnimations() }
    }
    private func clearAnimations() {
        completing = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [track, ring] { shape.removeAllAnimations(); shape.opacity = 0 }
        check.layer?.removeAllAnimations(); check.layer?.opacity = 0
        glyphView.layer?.removeAllAnimations(); glyphView.layer?.opacity = 1
        CATransaction.commit()
    }
    private func interruptCompletion() {
        let targets: [(CALayer?, Float)] = [(glyphView.layer, 1), (check.layer, 0), (track, 1), (ring, 1)]
        let opacities = targets.map { $0.0?.presentation()?.opacity ?? $0.1 }
        clearAnimations()
        for (index, target) in targets.enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacities[index]; fade.toValue = target.1; fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.0?.add(fade, forKey: "download-interrupted-completion")
        }
    }
    private func complete() {
        completing = true; completionCount += 1
        let now = CACurrentMediaTime()
        ring.removeAnimation(forKey: "download-spin")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [track, ring] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? 1; fade.toValue = 0
            fade.beginTime = now + 0.15; fade.duration = 0.8; fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.opacity = 0; shape.add(fade, forKey: "download-complete-ring")
        }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0, 1, 1, 0, 0]; opacity.keyTimes = [0.0, 0.15/1.45, 0.3/1.45, 1.15/1.45, 1.3/1.45, 1.0].map { NSNumber(value: $0) }
        opacity.duration = 1.45
        check.layer?.add(opacity, forKey: "download-complete-check")
        if !Motion.reducesMotion {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = check.layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 0.6
            spring.toValue = 1; spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.5, 2); spring.damping = 2 * sqrt(spring.stiffness)
            spring.beginTime = now + 0.15; spring.duration = 0.5; spring.fillMode = .backwards
            check.layer?.add(spring, forKey: "download-complete-spring")
        }
        glyphView.wantsLayer = true
        let home = CAKeyframeAnimation(keyPath: "opacity")
        home.values = [1, 0, 0, 1]; home.keyTimes = [0.0, 0.15/1.45, 1.3/1.45, 1.0].map { NSNumber(value: $0) }; home.duration = 1.45
        home.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        home.delegate = self
        glyphView.layer?.add(home, forKey: "download-complete-home")
        CATransaction.commit()
    }
    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        MainActor.assumeIsolated { clearAnimations() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearAnimations() }
        super.viewWillMove(toWindow: newWindow)
    }
    var evidence: [String: Any] {
        let spring = check.layer?.animation(forKey: "download-complete-spring") as? CASpringAnimation
        let fade = ring.animation(forKey: "download-complete-ring")
        let home = glyphView.layer?.animation(forKey: "download-complete-home")
        return ["reduceMotion": Motion.reducesMotion, "spring": spring.map { ["duration": $0.duration, "mass": $0.mass, "stiffness": $0.stiffness, "damping": $0.damping] } ?? [:],
         "ringFadeDuration": fade?.duration ?? 0, "homeDuration": home?.duration ?? 0,
         "ringBounds": [ring.path?.boundingBox.minX ?? 0, ring.path?.boundingBox.minY ?? 0, ring.path?.boundingBox.width ?? 0, ring.path?.boundingBox.height ?? 0], "lineWidth": ring.lineWidth,
"running": previous?.running ?? 0, "progress": previous?.progress ?? 0,
         "indeterminate": previous?.indeterminate ?? false, "completing": completing,
         "completions": completionCount, "animations": [track, ring, check.layer, glyphView.layer].compactMap { $0 }.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) },
         "trackOpacity": track.opacity, "ringOpacity": ring.opacity, "checkOpacity": check.layer?.opacity ?? 0, "homeOpacity": glyphView.layer?.opacity ?? 1]
    }
}
