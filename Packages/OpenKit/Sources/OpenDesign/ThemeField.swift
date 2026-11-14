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
///
/// Legacy snapshots keep the original 0.64/sRGB fit, precomputed by
/// `makeImage`, byte for byte. Editor styles use 0.2 + 0.55·intensity and
/// `composition`: CoreAnimation blends the unblended fill over the underlay
/// in the display's own encoded space (§17 "Display-space blend"). On a
/// Display P3 target this equals the encoded-P3 law of `Evaluator.color`.
public enum ThemeField {
    /// Decoded §17.2 opacity. At intensity 0.8 it retains the fitted 0.64.
    public static func layerAlpha(intensity: Double) -> Double {
        ThemeTuning.intensityAlphaFloor + ThemeTuning.intensityAlphaSlope * min(1, max(0, intensity.isFinite ? intensity : 0))
    }
    /// Underlay gray for `translucencyStyle: light`, active and inactive window. Light
    /// imports and editor themes keep this fit while inactive; the default light theme
    /// and every dark window use `WindowMaterial.inactiveShift` (derived from it).
    public static let lightUnderlayActive: Double = 0.694
    public static let lightUnderlayInactive: Double = 0.83
    /// guess: no `translucencyStyle: dark` theme was observed.
    public static let darkUnderlayActive: Double = 0.16

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
        let solidKey: P3?
        let solidColor: (Double, Double, Double)?
        let translucency: SpaceThemeStyle.Translucency
        let isActive: Bool
        let cardTint: Bool
        /// Light imports and editor themes keep their fitted inactive underlay (0.694 → 0.83
        /// behind the theme's alpha): it fits Arc's inactive light frame better than a constant
        /// backdrop shift (sidebar-compare `static-inactive`, worst ΔE00 1.17 against 1.85).
        let usesInactiveUnderlayFit: Bool
        /// Editor themes in a light window scheme mix the fill and the underlay in
        /// encoded sRGB (capture session 3 fit; `SidebarThemeRules.lightUnderlay`).
        let mixesInSRGB: Bool
        /// True when the fill's coverage is the same everywhere (no overlay stops).
        var hasConstantCoverage: Bool { overlay.count != 2 }

        /// `isActive: false` moves the active field to the inactive backdrop;
        /// `cardTint` gives the tint drawn at `1 − w` over the blurred page
        /// (`WindowMaterial`). The active field is the reference for both.
        public init(style: SpaceThemeStyle, windowSize: CGSize, isActive: Bool, cardTint: Bool = false) {
            translucency = style.backdropScheme
            self.isActive = isActive
            self.cardTint = cardTint
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
            var isCorners = false
            if case .corners = style.fill { isCorners = true }
            // Imports keep their fitted inactive underlay; editor themes use the
            // backdrop shift (guess: Arc 1.172.2's inactive window was not re-measured).
            usesInactiveUnderlayFit = legacy && !isActive && !cardTint && translucency == .light && !isCorners
            mixesInSRGB = !legacy && !isCorners && style.windowColorScheme == .light
            let fitted: Double
            switch style.translucency {
            case .light: fitted = usesInactiveUnderlayFit ? ThemeField.lightUnderlayInactive : ThemeField.lightUnderlayActive
            case .dark: fitted = ThemeField.darkUnderlayActive
            }
            if legacy || isCorners {
                underlay = fitted
            } else if style.windowColorScheme == .dark {
                // §17.2 wash law, preserving U0 at and above the wash cap.
                underlay = SidebarThemeRules.darkUnderlay * (1 - ThemeTuning.darkWashAlpha * min(alpha, ThemeTuning.washOpacityCap))
                    / (1 - ThemeTuning.darkWashAlpha * ThemeTuning.washOpacityCap)
            } else {
                underlay = SidebarThemeRules.lightUnderlay - SidebarThemeRules.lightUnderlaySlope * max(0, ThemeTuning.washOpacityCap - alpha)
            }
            self.solidKey = solidKey
            if let key = solidKey {
                let u0 = underlay * (1 - alpha)
                if mixesInSRGB {
                    let (r, g, b) = P3Transfer.toSRGB(key)
                    solidColor = (r * alpha + u0, g * alpha + u0, b * alpha + u0)
                } else {
                    solidColor = P3Transfer.toSRGB(P3(key.r * alpha + u0, key.g * alpha + u0, key.b * alpha + u0))
                }
            } else { solidColor = nil }
        }

        /// Final color (extended, gamma-encoded sRGB) at window uv. Editor
        /// fills use the encoded Display P3 mix: what a P3 display shows.
        public func color(u: Double, v: Double) -> (Double, Double, Double) {
            let (r, g, b) = activeColor(u: u, v: v)
            if cardTint { return (WindowMaterial.tint(r, translucency), WindowMaterial.tint(g, translucency), WindowMaterial.tint(b, translucency)) }
            if !isActive, !usesInactiveUnderlayFit { return (WindowMaterial.inactive(r, translucency), WindowMaterial.inactive(g, translucency), WindowMaterial.inactive(b, translucency)) }
            return (r, g, b)
        }

        /// The active window's color: every theme fit's reference.
        private func activeColor(u: Double, v: Double) -> (Double, Double, Double) {
            if let solidColor { return solidColor }
            if !legacy, corners.isEmpty {
                let (color, a) = fill(u: u, v: v)
                let u0 = underlay * (1 - a)
                if mixesInSRGB {
                    let (r, g, b) = P3Transfer.toSRGB(color)
                    return (r * a + u0, g * a + u0, b * a + u0)
                }
                return P3Transfer.toSRGB(P3(color.r * a + u0, color.g * a + u0, color.b * a + u0))
            }
            if !corners.isEmpty {
                let c = corners
                func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
                func ch(_ k: KeyPath<RGBA, Double>) -> Double {
                    lerp(lerp(c[0][keyPath: k], c[1][keyPath: k], u), lerp(c[2][keyPath: k], c[3][keyPath: k], u), v)
                }
                return (ch(\.red), ch(\.green), ch(\.blue))
            }
            let (r, g, bl, outA) = linearFill(u: u, v: v)
            let er = OKLab.encode(r), eg = OKLab.encode(g), eb = OKLab.encode(bl)
            let u0 = underlay * (1 - outA)
            return (er * outA + u0, eg * outA + u0, eb * outA + u0)
        }

        /// Unblended editor fill at window uv: encoded Display P3 and its
        /// coverage (`alpha`, raised by an overlay stop).
        public func fill(u: Double, v: Double) -> (P3, Double) {
            if let solidKey { return (solidKey, alpha) }
            let (r, g, b, a) = linearFill(u: u, v: v)
            return (P3Transfer.fromLinearSRGB(r, g, b), a)
        }

        /// Base and overlay gradients in linear sRGB, before the underlay.
        private func linearFill(u: Double, v: Double) -> (Double, Double, Double, Double) {
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
            return (r, g, bl, outA)
        }
    }

    /// Editor fill drawn as layers (§17 "Display-space blend"). CoreAnimation
    /// mixes the unblended fill over the opaque underlay gray in the
    /// destination's encoded space, as Arc's opacity layers do: Display P3
    /// math on a P3 display, the panel's own space elsewhere.
    public struct Composition {
        /// Opaque gray. Equal encoded values in every D65 sRGB-curve space.
        public let underlay: CGColor
        /// One key color at `alpha`; no image.
        public let solid: CGColor?
        /// Gradient fill, premultiplied by its per-pixel coverage.
        public let image: CGImage?
    }

    /// Nil for legacy imports and the default theme: they keep `makeImage`.
    public static func composition(style: SpaceThemeStyle, windowSize: CGSize, isActive: Bool, resolution: Int = 64) -> Composition? {
        guard !style.usesLegacyIntensity, case .blended = style.fill,
              let p3 = CGColorSpace(name: CGColorSpace.displayP3), let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let e = Evaluator(style: style, windowSize: windowSize, isActive: isActive)
        // CoreAnimation blends in the display's encoded space. The light scheme's sRGB
        // mix is drawn from the baked field instead (`makeImage`).
        guard !e.mixesInSRGB else { return nil }
        var underlayGray = e.underlay
        if !isActive, !e.usesInactiveUnderlayFit {
            // The inactive shift moves only the underlay: exact while the fill's coverage is
            // constant and the moved gray stays in range; otherwise draw the baked field.
            guard e.hasConstantCoverage, e.alpha < 1 else { return nil }
            underlayGray += WindowMaterial.inactiveShift(style.backdropScheme) / (1 - e.alpha)
            guard (0...1).contains(underlayGray) else { return nil }
        }
        let gray = CGFloat(underlayGray)
        let underlay = CGColor(colorSpace: srgb, components: [gray, gray, gray, 1])!
        if let key = e.solidKey {
            let solid = CGColor(colorSpace: p3, components: [CGFloat(key.r), CGFloat(key.g), CGFloat(key.b), CGFloat(e.alpha)])
            return Composition(underlay: underlay, solid: solid, image: nil)
        }
        let n = max(resolution, 2)
        var pixels = [Float](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            let v = (Double(y) + 0.5) / Double(n)
            for x in 0..<n {
                let (c, a) = e.fill(u: (Double(x) + 0.5) / Double(n), v: v)
                let i = (y * n + x) * 4
                pixels[i] = Float(c.r * a); pixels[i + 1] = Float(c.g * a); pixels[i + 2] = Float(c.b * a); pixels[i + 3] = Float(a)
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = CGImage(width: n, height: n, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: n * 16,
                            space: p3, bitmapInfo: info, provider: provider, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent)
        return Composition(underlay: underlay, solid: nil, image: image)
    }

    /// Theme tint over the system's behind-window material. The fitted opacity
    /// is retained; the constant underlay is removed. The default dark field
    /// also has a small live tint correction from C14-T. Static
    /// previews continue to use `makeImage` or `composition`.
    public static func makeWindowTint(style: SpaceThemeStyle, windowSize: CGSize) -> CGImage? {
        // Fixed 64×64 RGBA float field: largest allocation is 65,536 bytes.
        let n = 64
        let e = Evaluator(style: style, windowSize: windowSize, isActive: true)
        let correction: (Double, Double, Double)
        if case .corners = style.fill, style.translucency == .dark {
            // Default corners store final fitted pixels, rather than a raw fill.
            // Native-material fit across the three C14-T wallpapers, not an
            // adjustment to the stored theme or to static preview pixels.
            correction = (-0.12938, -0.12318, -0.12659)
        } else { correction = (0, 0, 0) }
        let displaySpace: Bool
        if case .blended = style.fill { displaySpace = !e.legacy && !e.mixesInSRGB }
        else { displaySpace = false }
        var pixels = [Float](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let u = (Double(x) + 0.5) / Double(n), v = (Double(y) + 0.5) / Double(n)
                let i = (y * n + x) * 4
                if displaySpace {
                    // Keep the editor's display-space composition law. Unmixing
                    // after conversion to sRGB would change its fitted colors.
                    let (c, a) = e.fill(u: u, v: v)
                    pixels[i] = Float(c.r * a); pixels[i + 1] = Float(c.g * a)
                    pixels[i + 2] = Float(c.b * a); pixels[i + 3] = Float(a)
                    continue
                }
                let (r, g, b) = e.color(u: u, v: v)
                let a: Double
                if case .corners = style.fill { a = e.alpha } else { a = e.fill(u: u, v: v).1 }
                // Unmix in the field's encoded space. Extended float channels
                // retain colors outside sRGB until the window's ColorSync pass.
                let gray = e.underlay * (1 - a)
                pixels[i] = Float(r - gray + correction.0 * a)
                pixels[i + 1] = Float(g - gray + correction.1 * a)
                pixels[i + 2] = Float(b - gray + correction.2 * a); pixels[i + 3] = Float(a)
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: displaySpace ? CGColorSpace.displayP3 : CGColorSpace.extendedSRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: n, height: n, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: n * 16,
                       space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The whole-window field as a small float image in uv space. Stretch it over
    /// the window with linear filtering; the field is smooth, so 64×64 samples
    /// stay within a fraction of a level of the exact math.
    public static func makeImage(style: SpaceThemeStyle, windowSize: CGSize, isActive: Bool, cardTint: Bool = false, resolution: Int = 64) -> CGImage? {
        let n = max(resolution, 2)
        let e = Evaluator(style: style, windowSize: windowSize, isActive: isActive, cardTint: cardTint)
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
