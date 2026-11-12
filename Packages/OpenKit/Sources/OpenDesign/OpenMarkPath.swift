import CoreGraphics

/// Open's doorway outline for drawing code without AppKit (the same geometry as
/// `OnboardingBrandMark.path`: full-round crown, lower corners 10/168 of the width).
/// Core Graphics coordinates: y grows upward, the crown at the rect's top.
public enum OpenMarkPath {
    public static func doorway(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height, radius = min(w / 2, h / 2)
        let bottom = min(w * 10 / 168, h / 8)
        let k: CGFloat = 0.5522847498
        let p = CGMutablePath()
        // Built top-down (y down), then flipped into the rect.
        p.move(to: CGPoint(x: 0, y: h - bottom)); p.addLine(to: CGPoint(x: 0, y: radius))
        p.addCurve(to: CGPoint(x: radius, y: 0), control1: CGPoint(x: 0, y: radius * (1 - k)), control2: CGPoint(x: radius * (1 - k), y: 0))
        p.addCurve(to: CGPoint(x: w, y: radius), control1: CGPoint(x: w - radius * (1 - k), y: 0), control2: CGPoint(x: w, y: radius * (1 - k)))
        p.addLine(to: CGPoint(x: w, y: h - bottom))
        p.addQuadCurve(to: CGPoint(x: w - bottom, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: bottom, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - bottom), control: CGPoint(x: 0, y: h)); p.closeSubpath()
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
        return p.copy(using: &t) ?? p
    }
}
