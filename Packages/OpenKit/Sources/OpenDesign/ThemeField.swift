import CoreGraphics
import Foundation
import OpenModel

/// Computes the Space background color at any point of the window.
///
/// Gradient geometry retains the capture fit (docs/design.md, "Theme
/// rendering"). Editor opacity, wash, and final blend follow plan §17.2:
///
/// 1. Two linear gradients in window uv space (0…1, y down): the base gradient
///    and an overlay gradient. Each gets a start and end point. The projection is
///    clamped at the four window corners and interpolated across the two
///    triangles of the window quad (split along the bottom-left → top-right
///    diagonal), like a per-vertex varying.
/// 2. Colors interpolate in OKLab. The base parameter is scaled by 4/3, so the
///    base reaches its end color at 75 % of its line.
/// 3. The overlay (its own color fading in from alpha 0) is composited over the
///    base in linear light, the result is encoded to sRGB (sign-preserving).
/// 4. The gradient is drawn with `layerAlpha` over a neutral underlay. The
///    underlay is darker while the window is key/active and lighter when it is not.
///    Editor styles mix in encoded Display P3; legacy styles retain sRGB.
///
/// Legacy snapshots keep the original 0.64/sRGB fit byte for byte. Editor
/// styles use 0.2 + 0.55·intensity and encoded Display P3; F0139
/// remains a documented 1.89 ΔE00 regression versus the older 0.84 fit.
public enum ThemeField {
    /// Decoded §17.2 opacity. At intensity 0.8 it retains the fitted 0.64.
    public static func layerAlpha(intensity: Double) -> Double {
        ThemeTuning.intensityAlphaFloor + ThemeTuning.intensityAlphaSlope * min(1, max(0, intensity.isFinite ? intensity : 0))
    }
    /// Underlay gray for `translucencyStyle: light`, active and inactive window.
    public static let lightUnderlayActive: Double = 0.694
    public static let lightUnderlayInactive: Double = 0.83
    /// guess: no `translucencyStyle: dark` theme was observed.
    public static let darkUnderlayActive: Double = 0.16
    public static let darkUnderlayInactive: Double = 0.10

    /// CSS-style lines through the window center. Angle 0° points up, 90° right.
    public struct Line: Sendable, Hashable {
        public var angleDegrees: Double
        public var lengthScale: Double
        public var centerOffset: Double
    }
    public static let baseLine = Line(angleDegrees: 111.0, lengthScale: 1.015, centerOffset: 0.021)
    public static let overlayLine = Line(angleDegrees: 146.3, lengthScale: 0.332, centerOffset: 0.0)
    public static let baseParameterScale: Double = 4.0 / 3.0

    /// Start and end of a line in uv space for a window size.
    static func endpoints(_ line: Line, size: CGSize) -> (Double, Double, Double, Double) {
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let t = line.angleDegrees * .pi / 180
        let dx = sin(t), dy = -cos(t)
        let length = (abs(w * sin(t)) + abs(h * cos(t))) * line.lengthScale
        let cx = w / 2 + dx * line.centerOffset * length, cy = h / 2 + dy * line.centerOffset * length
        return ((cx - dx * length / 2) / w, (cy - dy * length / 2) / h,
                (cx + dx * length / 2) / w, (cy + dy * length / 2) / h)
    }

    /// Clamped corner projections, interpolated over the window's two triangles.
    struct Param {
        let tl, bl, tr, br: Double
        init(_ e: (Double, Double, Double, Double)) {
            let (x0, y0, x1, y1) = e
            let dx = x1 - x0, dy = y1 - y0, l2 = max(dx * dx + dy * dy, 1e-12)
            func s(_ u: Double, _ v: Double) -> Double { min(max(((u - x0) * dx + (v - y0) * dy) / l2, 0), 1) }
            tl = s(0, 0); bl = s(0, 1); tr = s(1, 0); br = s(1, 1)
        }
        func at(_ u: Double, _ v: Double) -> Double {
            u + v <= 1 ? tl + (tr - tl) * u + (bl - tl) * v
                       : br + (bl - br) * (1 - u) + (tr - br) * (1 - v)
        }
    }

    /// Precomputed per-style values for fast evaluation.
    public struct Evaluator {
        let base: [OKLab.Lab]
        let overlay: [(OKLab.Lab, Double)]
        let corners: [RGBA]
        let baseParam: Param
        let overlayParam: Param
        let alpha: Double
        let underlay: Double
        let legacy: Bool
        let solidColor: (Double, Double, Double)?

        public init(style: SpaceThemeStyle, windowSize: CGSize, isActive: Bool) {
            legacy = style.usesLegacyIntensity
            let solidKey: P3?
            switch style.fill {
            case .blended(let b, let o):
                solidKey = !legacy && b.count == 1 && o.isEmpty ? ThemeColorMath.toP3(b[0].modelColor) : nil
                base = b.map { OKLab.fromSRGB($0.red, $0.green, $0.blue) }
                var ov = o.map { (OKLab.fromSRGB($0.red, $0.green, $0.blue), $0.alpha) }
                // A clear first stop fades in the second stop's own color
                // (no darkening through black; measured).
                if ov.count == 2, ov[0].1 == 0 { ov[0].0 = ov[1].0 }
                overlay = ov
                corners = []
            case .corners(let c):
                base = []; overlay = []; corners = c; solidKey = nil
            }
            baseParam = Param(ThemeField.endpoints(ThemeField.baseLine, size: windowSize))
            overlayParam = Param(ThemeField.endpoints(ThemeField.overlayLine, size: windowSize))
            alpha = style.usesLegacyIntensity ? 0.64 : ThemeField.layerAlpha(intensity: style.intensityFactor)
            let fitted: Double
            switch style.translucency {
            case .light: fitted = isActive ? ThemeField.lightUnderlayActive : ThemeField.lightUnderlayInactive
            case .dark: fitted = isActive ? ThemeField.darkUnderlayActive : ThemeField.darkUnderlayInactive
            }
            // §17.2: preserve U0 at and above the wash cap. Light's uncaptured
            // white-wash branch remains today's fitted underlay (documented guess).
            underlay = !legacy && style.windowColorScheme == .dark
                ? fitted * (1 - ThemeTuning.darkWashAlpha * min(alpha, ThemeTuning.washOpacityCap))
                    / (1 - ThemeTuning.darkWashAlpha * ThemeTuning.washOpacityCap)
                : fitted
            if let key = solidKey {
                let u0 = underlay * (1 - alpha)
                solidColor = P3Transfer.toSRGB(P3(key.r * alpha + u0, key.g * alpha + u0, key.b * alpha + u0))
            } else { solidColor = nil }
        }

        /// Final color (extended, gamma-encoded sRGB) at window uv.
        public func color(u: Double, v: Double) -> (Double, Double, Double) {
            func mixP3(_ color: P3, alpha: Double) -> (Double, Double, Double) {
                let u0 = underlay * (1 - alpha)
                return P3Transfer.toSRGB(P3(color.r * alpha + u0, color.g * alpha + u0, color.b * alpha + u0))
            }
            if let solidColor { return solidColor }
            if !corners.isEmpty {
                let c = corners
                func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
                func ch(_ k: KeyPath<RGBA, Double>) -> Double {
                    lerp(lerp(c[0][keyPath: k], c[1][keyPath: k], u), lerp(c[2][keyPath: k], c[3][keyPath: k], u), v)
                }
                return (ch(\.red), ch(\.green), ch(\.blue))
            }
            let b: OKLab.Lab
            if base.count >= 2 {
                let t = min(max(baseParam.at(u, v) * ThemeField.baseParameterScale, 0), 1)
                b = OKLab.mix(base[0], base[1], t)
            } else {
                b = base.first ?? OKLab.Lab(0.5, 0, 0)
            }
            var (r, g, bl) = OKLab.toLinear(b)
            var outA = alpha
            if overlay.count == 2 {
                let t = overlayParam.at(u, v)
                let o = OKLab.mix(overlay[0].0, overlay[1].0, t)
                let oa = (overlay[0].1 + (overlay[1].1 - overlay[0].1) * t) * alpha
                let (orr, og, ob) = OKLab.toLinear(o)
                let ba = alpha
                outA = oa + (1 - oa) * ba
                if outA > 0 {
                    r = (orr * oa + r * ba * (1 - oa)) / outA
                    g = (og * oa + g * ba * (1 - oa)) / outA
                    bl = (ob * oa + bl * ba * (1 - oa)) / outA
                }
            }
            if !legacy { return mixP3(P3Transfer.fromLinearSRGB(r, g, bl), alpha: outA) }
            let er = OKLab.encode(r), eg = OKLab.encode(g), eb = OKLab.encode(bl)
            let u0 = underlay * (1 - outA)
            return (er * outA + u0, eg * outA + u0, eb * outA + u0)
        }
    }

    /// The whole-window field as a small float image in uv space. Stretch it over
    /// the window with linear filtering; the field is smooth, so 64×64 samples
    /// stay within a fraction of a level of the exact math.
    public static func makeImage(style: SpaceThemeStyle, windowSize: CGSize, isActive: Bool, resolution: Int = 64) -> CGImage? {
        let n = max(resolution, 2)
        let e = Evaluator(style: style, windowSize: windowSize, isActive: isActive)
        var pixels = [Float](repeating: 1, count: n * n * 4)
        for y in 0..<n {
            let v = (Double(y) + 0.5) / Double(n)
            for x in 0..<n {
                let u = (Double(x) + 0.5) / Double(n)
                let (r, g, b) = e.color(u: u, v: v)
                let i = (y * n + x) * 4
                pixels[i] = Float(r); pixels[i + 1] = Float(g); pixels[i + 2] = Float(b); pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: n, height: n, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: n * 16,
                       space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Cache ColorSync's two linear primary matrices once. Transfer curves are
/// shared by sRGB and Display P3. No per-pixel CGColor/profile allocation.
private enum P3Transfer {
    private struct Matrix: Sendable {
        let red, green, blue: SIMD3<Double>
        func apply(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> { red * r + green * g + blue * b }
    }
    private static func matrix(from: CFString, to: CFString) -> Matrix {
        let source = CGColorSpace(name: from)!, destination = CGColorSpace(name: to)!
        func primary(_ column: Int) -> SIMD3<Double> {
            var values = [CGFloat](repeating: 0, count: 4); values[column] = 1; values[3] = 1
            let c = CGColor(colorSpace: source, components: values)!.converted(to: destination, intent: .relativeColorimetric, options: nil)!.components!
            return SIMD3(Double(c[0]), Double(c[1]), Double(c[2]))
        }
        return Matrix(red: primary(0), green: primary(1), blue: primary(2))
    }
    private static let p3 = matrix(from: CGColorSpace.extendedLinearSRGB, to: CGColorSpace.extendedLinearDisplayP3)
    private static let srgb = matrix(from: CGColorSpace.extendedLinearDisplayP3, to: CGColorSpace.extendedLinearSRGB)
    static func fromLinearSRGB(_ r: Double, _ g: Double, _ b: Double) -> P3 {
        let c = p3.apply(r, g, b)
        return P3(min(1, max(0, OKLab.encode(c.x))), min(1, max(0, OKLab.encode(c.y))), min(1, max(0, OKLab.encode(c.z))))
    }
    static func toSRGB(_ c: P3) -> (Double, Double, Double) {
        let c = srgb.apply(OKLab.decode(c.r), OKLab.decode(c.g), OKLab.decode(c.b))
        return (OKLab.encode(c.x), OKLab.encode(c.y), OKLab.encode(c.z))
    }
}
