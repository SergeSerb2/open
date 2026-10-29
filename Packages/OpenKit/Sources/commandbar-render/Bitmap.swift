import AppKit
import ImageIO

/// An RGBA8 bitmap with the few operations the comparison needs. Pixels are sRGB, or Display P3
/// while `ColorMath.space` is `.displayP3` (session-2 captures carry the AW2726DM profile, whose
/// gamut exceeds sRGB; P3 keeps those colors unclipped).
@MainActor
struct Bitmap {
    let width: Int, height: Int
    var data: [UInt8]

    init(width: Int, height: Int, fill: UInt8) {
        self.width = width; self.height = height
        data = [UInt8](repeating: fill, count: width * height * 4)
    }

    /// Loads a PNG and converts it to the working space (`ColorMath.space`) through its embedded color profile.
    init(path: String) throws {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CLIError(description: "cannot read \(path)") }
        width = img.width; height = img.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: ColorMath.space.cgSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func pixel(_ x: Int, _ y: Int) -> [Double] {
        let i = (y * width + x) * 4
        return [Double(data[i]), Double(data[i + 1]), Double(data[i + 2])]
    }

    mutating func set(_ x: Int, _ y: Int, _ c: [Double]) {
        let i = (y * width + x) * 4
        data[i] = UInt8(max(0, min(255, c[0].rounded()))); data[i + 1] = UInt8(max(0, min(255, c[1].rounded())))
        data[i + 2] = UInt8(max(0, min(255, c[2].rounded()))); data[i + 3] = 255
    }

    func lum(_ x: Int, _ y: Int) -> Double { let p = pixel(x, y); return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] }

    func clamp(_ r: CGRect) -> (Int, Int, Int, Int) {
        (max(0, Int(r.minX)), max(0, Int(r.minY)), min(width, Int(r.maxX)), min(height, Int(r.maxY)))
    }

    func mean(_ r: CGRect) -> [Double] {
        let (x0, y0, x1, y1) = clamp(r)
        var s = [0.0, 0, 0], n = 0.0
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) { let p = pixel(x, y); s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n += 1 } }
        return n > 0 ? s.map { $0 / n } : s
    }

    /// Least-squares plane through the luminance of the 1 px ring just outside `r`.
    func plane(_ r: CGRect) -> (Double, Double, Double) {
        let (x0, y0, x1, y1) = clamp(r.insetBy(dx: -1, dy: -1))
        var pts: [(Double, Double, Double)] = []
        for x in x0..<x1 { pts.append((Double(x), Double(y0), lum(x, y0))); pts.append((Double(x), Double(y1 - 1), lum(x, y1 - 1))) }
        for y in y0..<y1 { pts.append((Double(x0), Double(y), lum(x0, y))); pts.append((Double(x1 - 1), Double(y), lum(x1 - 1, y))) }
        // Normal equations for z = a + b·x + c·y.
        var m = [[Double]](repeating: [0, 0, 0], count: 3), v = [0.0, 0, 0]
        for (x, y, z) in pts {
            let row = [1, x, y]
            for i in 0..<3 { for j in 0..<3 { m[i][j] += row[i] * row[j] }; v[i] += row[i] * z }
        }
        let s = ColorMath.solve3(m, v) ?? [pts.map(\.2).reduce(0, +) / Double(max(pts.count, 1)), 0, 0]
        return (s[0], s[1], s[2])
    }

    /// Ink box and core color of a text or glyph region.
    func ink(_ r: CGRect) -> (CGRect?, [Double]?) {
        let (a, b, c) = plane(r)
        let (x0, y0, x1, y1) = clamp(r)
        var peak = 0.0
        for y in y0..<y1 { for x in x0..<x1 { peak = max(peak, abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))) } }
        guard peak > 6 else { return (nil, nil) }
        var box: CGRect?
        var s = [0.0, 0, 0], n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let d = abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))
                if d >= 0.5 * peak { box = (box ?? CGRect(x: x, y: y, width: 0, height: 0)).union(CGRect(x: x, y: y, width: 1, height: 1)) }
                if d >= 0.85 * peak { let p = pixel(x, y); s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n += 1 }
            }
        }
        return (box, n > 0 ? s.map { $0 / n } : nil)
    }

    /// Contrast-weighted centroid of a region (against the ring plane).
    func centroid(_ r: CGRect) -> CGPoint? {
        let (a, b, c) = plane(r)
        let (x0, y0, x1, y1) = clamp(r)
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in y0..<y1 { for x in x0..<x1 {
            let d = abs(lum(x, y) - (a + b * Double(x) + c * Double(y)))
            guard d > 3 else { continue }
            sx += d * Double(x); sy += d * Double(y); sw += d
        } }
        return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : nil
    }

    /// Box of a fill: pixels at least half-way from the ring plane to the sample's level.
    func inkBox(_ r: CGRect, contrastFrom sample: CGRect) -> CGRect? {
        let (a, b, c) = plane(r)
        let m = mean(sample)
        let sl = 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]
        let cx = Double(sample.midX), cy = Double(sample.midY)
        let contrast = sl - (a + b * cx + c * cy)
        guard abs(contrast) > 1.5 else { return nil }
        let (x0, y0, x1, y1) = clamp(r)
        var box: CGRect?
        // Scan the middle row and middle column only: text inside the fill must not count.
        let midY = Int(Double(y0 + y1) / 2), midX = Int(Double(x0 + x1) / 2)
        for x in x0..<x1 where (lum(x, midY) - (a + b * Double(x) + c * Double(midY))) / contrast >= 0.5 {
            box = (box ?? CGRect(x: x, y: midY, width: 0, height: 0)).union(CGRect(x: x, y: midY, width: 1, height: 1))
        }
        for y in y0..<y1 where (lum(midX, y) - (a + b * Double(midX) + c * Double(y))) / contrast >= 0.5 {
            box = (box ?? CGRect(x: midX, y: y, width: 0, height: 0)).union(CGRect(x: midX, y: y, width: 1, height: 1))
        }
        return box
    }

    func write(to url: URL) {
        var copy = data
        let w = width, h = height
        let image: CGImage? = copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        if let image { OffscreenRenderer.writePNG(image, to: url) }
    }
}

enum ColorMath {
    static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { k in
            var mk = m
            for i in 0..<3 { mk[i][k] = v[i] }
            return det(mk) / d
        }
    }

    enum Space {
        case sRGB, displayP3
        var cgSpace: CGColorSpace { CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)! }
    }
    /// Working space of loaded bitmaps and of `lab`. `compare --space p3` sets Display P3.
    nonisolated(unsafe) static var space = Space.sRGB

    /// Working-space RGB (0…255) → CIE Lab (D65). sRGB and Display P3 share the transfer curve.
    static func lab(_ c: [Double]) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c[0]), g = lin(c[1]), b = lin(c[2])
        let m: [Double] = space == .sRGB
            ? [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041]
            : [0.4865709, 0.2656677, 0.1982173, 0.2289746, 0.6917385, 0.0792869, 0.0000000, 0.0451134, 1.0439444]
        let x = (m[0] * r + m[1] * g + m[2] * b) / 0.95047
        let y = m[3] * r + m[4] * g + m[5] * b
        let z = (m[6] * r + m[7] * g + m[8] * b) / 1.08883
        func f(_ t: Double) -> Double { t > pow(6.0 / 29, 3) ? cbrt(t) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func deltaE2000(_ c1: [Double], _ c2: [Double]) -> Double {
        let (L1, a1, b1) = lab(c1), (L2, a2, b2) = lab(c2)
        let rad = Double.pi / 180
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) / rad; return h < 0 ? h + 360 : h }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp = h2p - h1p
        if C1p * C2p == 0 { dhp = 0 } else if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * rad)
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp = h1p + h2p
        if C1p * C2p != 0 { hbp = abs(h1p - h2p) > 180 ? (hbp + (hbp < 360 ? 360 : -360)) / 2 : hbp / 2 }
        let T = 1 - 0.17 * cos((hbp - 30) * rad) + 0.24 * cos(2 * hbp * rad) + 0.32 * cos((3 * hbp + 6) * rad) - 0.20 * cos((4 * hbp - 63) * rad)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * rad) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }
}
