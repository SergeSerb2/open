import CoreGraphics
import Foundation
import OpenModel

/// Display P3 components for theme math (docs/re/design-tokens.md §6.5).
public struct P3: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

public struct PrimaryPalette: Hashable, Sendable {
    public var tintedLight: P3
    public var midTone: P3
    public var shaded: P3
    public var shadedDark: P3
}

public enum ThemeTuning {
    public static let automaticBias: Double = 0
    public static let forcedBias: Double = 21
}

public enum ThemeColorMath {
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let srgb = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    public static func toP3(_ c: RGBAColor) -> P3 {
        let source = CGColor(colorSpace: srgb, components: [c.red, c.green, c.blue, 1])!
        let values = source.converted(to: p3, intent: .relativeColorimetric, options: nil)!.components!
        return P3(clamp(values[0]), clamp(values[1]), clamp(values[2]))
    }

    public static func toExtendedSRGB(_ c: P3) -> RGBAColor {
        let source = CGColor(colorSpace: p3, components: [c.r, c.g, c.b, 1])!
        let values = source.converted(to: srgb, intent: .relativeColorimetric, options: nil)!.components!
        return RGBAColor(red: values[0], green: values[1], blue: values[2])
    }

    public static func hsl(_ c: P3) -> (h: Double, s: Double, l: Double) {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b)
        let delta = high - low, l = (high + low) / 2
        guard delta > 1e-12 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        let h: Double
        if high == c.r { h = (c.g - c.b) / delta }
        else if high == c.g { h = (c.b - c.r) / delta + 2 }
        else { h = (c.r - c.g) / delta + 4 }
        return (fract(h / 6), s, l)
    }

    public static func rgb(h: Double, s: Double, l: Double) -> P3 {
        let h = fract(h), s = clamp(s), l = clamp(l)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let result: P3
        switch Int(h * 6) {
        case 0: result = P3(chroma, x, 0)
        case 1: result = P3(x, chroma, 0)
        case 2: result = P3(0, chroma, x)
        case 3: result = P3(0, x, chroma)
        case 4: result = P3(x, 0, chroma)
        default: result = P3(chroma, 0, x)
        }
        return P3(result.r + m, result.g + m, result.b + m)
    }

    public static func luminance(_ c: P3) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func contrast(_ a: P3, _ b: P3) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    public static func rotate(_ c: P3, degrees: Double) -> P3 {
        let v = hsl(c)
        return rgb(h: v.h + degrees / 360, s: v.s, l: v.l)
    }

    public static func band(_ c: P3, _ lo: Double, _ hi: Double) -> P3 {
        let v = hsl(c)
        var l = v.l, result = c
        if luminance(c) < lo {
            while luminance(result) < lo && l < 1 { l = min(1, l + 0.01); result = rgb(h: v.h, s: v.s, l: l) }
        } else if luminance(c) > hi {
            while luminance(result) > hi && l > 0 { l = max(0, l - 0.01); result = rgb(h: v.h, s: v.s, l: l) }
        }
        return result
    }

    public static func harmony(key: P3, count: Int, wheel: SpaceStyleWheel) -> [P3] {
        guard count > 0 else { return [] }
        let angles: [Double]
        if count >= 4 { angles = (0..<count).map { Double($0) * 360 / Double(count) } }
        else if wheel == .analogous { angles = [0, 40, -40] }
        else { angles = count == 2 ? [0, 180] : [0, 150, 210] }
        return angles.prefix(count).map { rotate(key, degrees: $0) }
    }

    public static func primaryPalette(key: P3) -> PrimaryPalette {
        PrimaryPalette(tintedLight: band(key, 0.85, 0.95), midTone: band(key, 0.30, 0.50),
                       shaded: band(key, 0, 0.50), shadedDark: band(key, 0, 0.10))
    }

    public static func semanticPalettes(_ p: PrimaryPalette) -> (light: SemanticPalette, dark: SemanticPalette) {
        // Primary roles leave the HSL/P3 math as extended sRGB. Source-over
        // operates on those output components; all 4 stored semantic palettes
        // match exactly (runtime-observations.md §3.3; harness M1).
        let tinted = RGBA(rgba: toExtendedSRGB(p.tintedLight))
        let mid = RGBA(rgba: toExtendedSRGB(p.midTone))
        let shaded = RGBA(rgba: toExtendedSRGB(p.shaded))
        let s = RGBA(rgba: toExtendedSRGB(p.shadedDark))
        func over(_ source: RGBA, _ alpha: Double, _ gray: Double, _ backgroundAlpha: Double = 1) -> RGBA {
            let a = alpha + backgroundAlpha * (1 - alpha)
            let b = gray * backgroundAlpha * (1 - alpha)
            return RGBA((source.red * alpha + b) / a, (source.green * alpha + b) / a,
                        (source.blue * alpha + b) / a, a, .extendedSRGB)
        }
        let light = SemanticPalette(
            background: over(s, 0.10, 1), backgroundExtra: over(s, 0.01, 1), title: over(s, 0.30, 0),
            subtitle: over(s, 0.40, 1), hover: over(s, 0.20, 1), focus: over(s, 0.50, 1),
            foregroundPrimary: shaded, foregroundSecondary: mid, foregroundTertiary: tinted,
            minContrast: tinted, maxContrast: s, cutout: tinted)
        let dark = SemanticPalette(
            background: over(s, 0.30, 0), backgroundExtra: over(s, 0.15, 0), title: over(s, 0.15, 1),
            subtitle: over(tinted, 0.50, 0), hover: over(s, 0.35, 1, 0.20), focus: over(s, 0.65, 1, 0.45),
            foregroundPrimary: tinted, foregroundSecondary: mid, foregroundTertiary: shaded,
            minContrast: s, maxContrast: tinted, cutout: s)
        return (light, dark)
    }

    public static func contentAppearance(key: P3, light: SemanticPalette, dark: SemanticPalette, bias: Double) -> ContentAppearance {
        contrast(key, toP3(dark.title.modelColor)) + bias >= contrast(key, toP3(light.title.modelColor)) ? .dark : .light
    }

    public static func lightnessRange(_ mode: SpaceStyleAppearance) -> ClosedRange<Double> {
        switch mode { case .automatic: 0.01...0.97; case .light: 0.575...0.97; case .dark: 0.01...0.425 }
    }

    public static func knob(for color: P3, range: ClosedRange<Double>) -> CGPoint {
        let v = hsl(color), r = 0.99 * clamp((v.l - range.lowerBound) / (range.upperBound - range.lowerBound))
        return CGPoint(x: cos(2 * .pi * v.h) * r, y: sin(2 * .pi * v.h) * r)
    }

    public static func color(at knob: CGPoint, saturation: Double, range: ClosedRange<Double>) -> P3 {
        let h = fract(atan2(knob.y, knob.x) / (2 * .pi)), t = min(hypot(knob.x, knob.y) / 0.99, 1)
        return rgb(h: h, s: saturation, l: range.lowerBound + t * (range.upperBound - range.lowerBound))
    }

    private static func fract(_ v: Double) -> Double { v - floor(v) }
    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

extension RGBA {
    public var modelColor: RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: alpha) }
}
