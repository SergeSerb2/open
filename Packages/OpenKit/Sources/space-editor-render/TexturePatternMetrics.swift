import Foundation
import CoreGraphics

/// Spatial statistics of the capture gate's P3 L* ROI, measured in pixels.
/// No image bytes are retained. Box ratios measure scale; axis mean deviations
/// measure direction independently of the texture's overall contrast.
@MainActor
struct TexturePatternMetrics {
    let sd: Double
    let boxRatios: [Double]
    let directionSD: [Double]
    let correlation: [Double]
    let skew: Double

    init(_ image: Bitmap, region: CGRect) {
        let (x0, y0, x1, y1) = image.clamp(region)
        let width = x1 - x0, height = y1 - y0
        var values: [Double] = []; values.reserveCapacity(width * height)
        func linear(_ v: Double) -> Double { let v = v / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for y in y0..<y1 { for x in x0..<x1 {
            let p = image.pixel(x, y)
            let luminance = 0.22897456 * linear(p[0]) + 0.69173852 * linear(p[1]) + 0.07928691 * linear(p[2])
            values.append(luminance > 216.0 / 24389 ? 116 * cbrt(luminance) - 16 : 24389.0 / 27 * luminance)
        } }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(1, a.count)) }
        func deviation(_ a: [Double]) -> Double {
            let m = mean(a)
            return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, a.count)))
        }
        let average = mean(values), sd = deviation(values); self.sd = sd
        func at(_ x: Int, _ y: Int) -> Double { values[y * width + x] }
        boxRatios = [2, 4, 8].map { size in
            var boxes: [Double] = []
            for y in stride(from: 0, through: height - size, by: size) {
                for x in stride(from: 0, through: width - size, by: size) {
                    var sum = 0.0
                    for dy in 0..<size { for dx in 0..<size { sum += at(x + dx, y + dy) } }
                    boxes.append(sum / Double(size * size))
                }
            }
            return deviation(boxes) / max(sd, 1e-12)
        }
        let columns = (0..<width).map { x in (0..<height).reduce(0.0) { $0 + at(x, $1) } / Double(height) }
        let rows = (0..<height).map { y in (0..<width).reduce(0.0) { $0 + at($1, y) } / Double(width) }
        var diagonals: [Double] = []
        for difference in (1 - width)..<height {
            var sum = 0.0, count = 0
            for x in 0..<width {
                let y = x + difference
                if (0..<height).contains(y) { sum += at(x, y); count += 1 }
            }
            if count >= min(width, height) / 2 { diagonals.append(sum / Double(count)) }
        }
        directionSD = [deviation(columns), deviation(rows), deviation(diagonals)]
        correlation = [(1, 0), (0, 1), (1, 1), (-1, 1)].map { dx, dy in
            var sum = 0.0, left = 0.0, right = 0.0
            for y in 0..<height { for x in 0..<width {
                guard (0..<width).contains(x + dx), (0..<height).contains(y + dy) else { continue }
                let a = at(x, y) - average, b = at(x + dx, y + dy) - average
                sum += a * b; left += a * a; right += b * b
            } }
            return sum / max(1e-12, sqrt(left * right))
        }
        skew = values.reduce(0) { $0 + pow(($1 - average) / max(sd, 1e-12), 3) } / Double(values.count)
    }
    static func error(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }
    static func text(_ values: [Double]) -> String { values.map { String(format: "%.3f", $0) }.joined(separator: "/") }
}
