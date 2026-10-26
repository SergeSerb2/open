import AppKit

/// Capture comparison only: reject the pad's dot lattice before sampling ink.
/// All coordinates are 1x panel points. No private pixels are exported.
@MainActor
enum GlyphInk {
    struct Sample {
        let background: [Double]
        let color: [Double]
        let contrast: Double
        let count: Int
        let masked: Int
        let darkInk: Bool

        func color(over background: [Double]) -> [Double] {
            (0..<3).map { channel in
                let denominator = darkInk ? self.background[channel] : 255 - self.background[channel]
                let coverage = (darkInk ? self.background[channel] - color[channel] : color[channel] - self.background[channel]) / max(1, denominator)
                return darkInk ? background[channel] * (1 - coverage) : background[channel] + (255 - background[channel]) * coverage
            }
        }
    }
    static func median(_ values: [Double]) -> Double {
        let values = values.sorted()
        guard !values.isEmpty else { return 0 }
        return values.count.isMultiple(of: 2) ? (values[values.count / 2 - 1] + values[values.count / 2]) / 2 : values[values.count / 2]
    }
    static func dotPixel(x: Int, y: Int) -> Bool {
        let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        guard CGRect(x: 21, y: 21, width: 340, height: 340).contains(point) else { return false }
        func distance(_ coordinate: Double) -> Double {
            let phase = (coordinate - 23.125).truncatingRemainder(dividingBy: 4.25)
            return abs(phase - (phase / 4.25).rounded() * 4.25)
        }
        // Include antialias support, rather than retaining a dot's edge pixels.
        return distance(point.x) <= 1.25 && distance(point.y) <= 1.25
    }
    static func sample(_ image: Bitmap, rect: CGRect, disabled: Bool = false) -> Sample {
        let (x0, y0, x1, y1) = image.clamp(rect)
        var pixels: [[Double]] = [], masked = 0
        for y in y0..<y1 { for x in x0..<x1 {
            if dotPixel(x: x, y: y) { masked += 1 }
            else { pixels.append(image.pixel(x, y)) }
        } }
        let background = (0..<3).map { channel in median(pixels.map { $0[channel] }) }
        let bg = 0.2126 * background[0] + 0.7152 * background[1] + 0.0722 * background[2]
        let darkInk = bg > 127
        func contrast(_ pixel: [Double]) -> Double {
            let value = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
            return (darkInk ? bg - value : value - bg) / max(1, darkInk ? bg : 255 - bg)
        }
        // R3: stroke-interior median, never a maximum/99%-peak selector.
        let threshold = 0.8 * (disabled ? 0.5 * 0.32 : 0.5)
        let core = pixels.filter { contrast($0) >= threshold }
        return Sample(background: background,
                      color: (0..<3).map { channel in median(core.map { $0[channel] }) },
                      contrast: median(core.map(contrast)), count: core.count, masked: masked, darkInk: darkInk)
    }
}
