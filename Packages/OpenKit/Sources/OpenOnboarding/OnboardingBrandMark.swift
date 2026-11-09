import AppKit
import QuartzCore

/// The intro's original doorway and sun, shared by setup and exported cards.
/// Geometry is authored in the intro's top-down 88 × 120 coordinate system.
@MainActor
public enum OnboardingBrandMark {
    public struct Components {
        public let doorway: CAShapeLayer
        public let sun: CALayer
    }

    public static func components(in rect: CGRect, flipped: Bool = true) -> Components {
        let scale = min(rect.width / 88, rect.height / 120)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: flipped ? scale : -scale,
            tx: rect.midX - 44 * scale, ty: rect.midY + (flipped ? -60 : 60) * scale)
        let original = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 88, height: 120),
            cornerWidth: 44, cornerHeight: 44, transform: nil)
        let doorway = CAShapeLayer()
        doorway.path = original.copy(using: &transform)
        doorway.fillColor = nil; doorway.strokeColor = NSColor.white.cgColor
        doorway.lineWidth = 7 * scale; doorway.lineCap = .round
        doorway.strokeStart = 0.08; doorway.strokeEnd = 0.88
        let sun = CALayer()
        sun.bounds = CGRect(x: 0, y: 0, width: 22 * scale, height: 22 * scale)
        sun.position = CGPoint(x: 61, y: 40).applying(transform)
        sun.cornerRadius = 11 * scale
        sun.backgroundColor = IntroColors.color(0xFF9F2E).cgColor
        return Components(doorway: doorway, sun: sun)
    }

    /// Uses the same trimmed shape layers as the live intro, including in PNGs.
    public static func draw(in rect: CGRect, opacity: CGFloat = 1, flipped: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0, rect.height > 0 else { return }
        let root = CALayer(); root.bounds = CGRect(origin: .zero, size: rect.size)
        let mark = components(in: root.bounds, flipped: flipped)
        mark.doorway.frame = root.bounds
        root.addSublayer(mark.doorway); root.addSublayer(mark.sun)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.setAlpha(opacity)
        root.render(in: context)
    }
}
