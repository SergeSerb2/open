import AppKit

/// Five-point diagonal comparison. Captures and numeric reports stay in .re.
@MainActor
enum PresetCompare {
    static func pixelSample(_ image: Bitmap, at point: CGPoint) -> [Double] {
        let x = point.x - 0.5, y = point.y - 0.5
        let x0 = max(0, min(image.width - 2, Int(floor(x)))), y0 = max(0, min(image.height - 2, Int(floor(y))))
        let fx = x - Double(x0), fy = y - Double(y0)
        let a = image.pixel(x0, y0), b = image.pixel(x0 + 1, y0), c = image.pixel(x0, y0 + 1), d = image.pixel(x0 + 1, y0 + 1)
        return (0..<3).map { i in (a[i] * (1 - fx) + b[i] * fx) * (1 - fy) + (c[i] * (1 - fx) + d[i] * fx) * fy }
    }
    /// A 2×2 pt mean suppresses per-pixel capture dithering. The five gate
    /// locations stop at t=±8, so their support stays inside the dark rim.
    static func sample(_ image: Bitmap, at point: CGPoint) -> [Double] {
        let points = [-0.5, 0.5].flatMap { y in [-0.5, 0.5].map { x in pixelSample(image, at: CGPoint(x: point.x + x, y: point.y + y)) } }
        return (0..<3).map { channel in points.reduce(0) { $0 + $1[channel] } / 4 }
    }
    static func run(arc: Bitmap, ours: Bitmap, out: String, sampleStops: Bool) throws {
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func point(_ index: Int, _ t: Double) -> CGPoint {
            CGPoint(x: floor(61 + Double(index) * 29.5) + 12 + t / sqrt(2), y: 393 + t / sqrt(2))
        }
        if sampleStops {
            let stops = (0..<9).map { index in [-9.0, 0, 9].map { t in pixelSample(arc, at: point(index, t)).map { Int($0.rounded()) } } }
            try JSONSerialization.data(withJSONObject: stops, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("stops.json"))
            print("F0016 diagonal stop facts (sRGB), t=-9/0/+9, inside the rim:")
            for (i, row) in stops.enumerated() { print("swatch \(i + 1): " + row.map { String(format: "0x%02X%02X%02X", $0[0], $0[1], $0[2]) }.joined(separator: ", ")) }
            return
        }
        let rows = (0..<9).flatMap { index in [-8.0, -4, 0, 4, 8].map { t -> Compare.Result in
            var row = Compare.Result(name: "page-2 swatch \(index + 1), t=\(Int(t))")
            row.arcColor = sample(arc, at: point(index, t)); row.oursColor = sample(ours, at: point(index, t))
            row.deltaE = ColorMath.deltaE2000(row.arcColor!, row.oursColor!)
            return row
        } }
        try SessionTwoCompare.write(rows, title: "Session 2 page-two five-point diagonals (2×2 pt samples)", out: out)
        if rows.count != 45 || rows.contains(where: { ($0.deltaE ?? .infinity) > 2 }) { throw CLIError(description: "page-two five-point color gate failed") }
    }
}
