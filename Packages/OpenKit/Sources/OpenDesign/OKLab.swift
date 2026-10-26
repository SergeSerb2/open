import Foundation

/// OKLab color math (Björn Ottosson's published matrices). Arc interpolates
/// theme gradients in OKLab; we do the same so midpoints match.
public enum OKLab {
    public struct Lab: Sendable, Hashable {
        public var L: Double, a: Double, b: Double
        public init(_ L: Double, _ a: Double, _ b: Double) { self.L = L; self.a = a; self.b = b }
        public var chroma: Double { (a * a + b * b).squareRoot() }
    }

    /// Sign-preserving sRGB transfer, so extended-range components stay valid.
    @inline(__always) public static func decode(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return c < 0 ? -v : v
    }

    @inline(__always) public static func encode(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return c < 0 ? -v : v
    }

    /// Gamma-encoded (extended) sRGB → OKLab.
    public static func fromSRGB(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        fromLinear(decode(r), decode(g), decode(b))
    }

    public static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> Lab {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return Lab(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                   1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                   0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    /// OKLab → linear (extended) sRGB.
    public static func toLinear(_ c: Lab) -> (Double, Double, Double) {
        let l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public static func mix(_ x: Lab, _ y: Lab, _ t: Double) -> Lab {
        Lab(x.L + (y.L - x.L) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t)
    }
}
