import CoreGraphics
import Foundation
import OpenModel

/// Open's procedural art. No Arc texture or knob asset is used.
@MainActor
public enum ThemeTexture {
    public struct Metrics: Sendable {
        public var baseAlpha: Double
        public var patternMean: Double
        public var meanAlpha: Double
        public var peakMarksMeanAlpha: Double
        public var markCoverage: Double
    }
    private struct Key: Hashable { var texture: SpaceStyleTexture; var noiseBucket: Int; var scale: CGFloat }
    private struct Tile { var image: CGImage; var metrics: Metrics }
    private static var cache: [Key: Tile] = [:]
    public private(set) static var generationCount = 0

    public static func period(_ t: SpaceStyleTexture) -> CGFloat {
        switch t { case .grain: 100; case .sand: 96; case .denim: 300; case .tweed: 128 }
    }

    public static func tile(_ t: SpaceStyleTexture, noiseFactor: Double, scale: CGFloat) -> CGImage? {
        cached(t, noise: noiseFactor, scale: scale)?.image
    }

    public static func metrics(_ t: SpaceStyleTexture, noiseFactor: Double, scale: CGFloat) -> Metrics? {
        cached(t, noise: noiseFactor, scale: scale)?.metrics
    }

    public static func knobPreview(_ t: SpaceStyleTexture, diameter: CGFloat, scale: CGFloat) -> CGImage {
        let tile = tile(t, noiseFactor: 1, scale: scale)!
        let px = max(1, Int((diameter * scale).rounded()))
        let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(ThemeEditorColors.noisePreviewBase.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: px, height: px))
        // Our own enlarged pattern preview, clipped to a disc by the editor view.
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        return context.makeImage()!
    }

    private static func cached(_ t: SpaceStyleTexture, noise: Double, scale: CGFloat) -> Tile? {
        guard noise > 0, scale > 0, scale.isFinite else { return nil }
        let bucket = min(20, max(0, Int((noise * 20).rounded())))
        guard bucket > 0 else { return nil }
        let key = Key(texture: t, noiseBucket: bucket, scale: scale)
        if let tile = cache[key] { return tile }
        let factor = Double(bucket) / 20
        guard let grain = Grain.tile(noiseFactor: factor, scale: scale), let grainData = grain.dataProvider?.data else { return nil }
        let grainBytes = CFDataGetBytePtr(grainData)!
        let grainMean = (0..<(grain.width * grain.height)).reduce(0.0) { $0 + Double(grainBytes[$1 * 4 + 3]) / 255 } / Double(grain.width * grain.height)
        if t == .grain {
            let tile = Tile(image: grain, metrics: Metrics(baseAlpha: 0, patternMean: grainMean, meanAlpha: grainMean,
                                                          peakMarksMeanAlpha: factor * 0.1, markCoverage: 1))
            cache[key] = tile; generationCount += 1
            return tile
        }
        let n = max(1, Int((period(t) * scale).rounded())), peak = factor * 0.1
        var marks = [Double](repeating: 0, count: n * n)
        func put(_ x: Int, _ y: Int, _ alpha: Double) {
            let x = (x % n + n) % n, y = (y % n + n) % n
            marks[y * n + x] = max(marks[y * n + x], alpha)
        }
        switch t {
        case .sand:
            // 48% of 2×2 cells have a one- or two-pixel dot: 18% coverage.
            for y in stride(from: 0, to: n, by: 2) {
                for x in stride(from: 0, to: n, by: 2) where random(x, y, 1) < 0.48 {
                    let dx = Int(random(x, y, 2) * 2), dy = Int(random(x, y, 3) * 2)
                    let alpha = peak * (0.4 + 0.6 * random(x, y, 4))
                    put(x + dx, y + dy, alpha)
                    if random(x, y, 5) < 0.5 { put(x + 1 - dx, y + dy, alpha) }
                }
            }
        case .denim:
            for y in 0..<n {
                for x in 0..<n {
                    let u = Double(x) / scale, v = Double(y) / scale
                    let across = ((v - u).truncatingRemainder(dividingBy: 3) + 3).truncatingRemainder(dividingBy: 3)
                    if across < 1 {
                        let along = (u + v).truncatingRemainder(dividingBy: 300) / 10
                        let cell = Int(floor(along)), fraction = along - floor(along)
                        let line = Int(floor((v - u) / 3))
                        let a = random(cell, line, 6), b = random((cell + 1) % 30, line, 6)
                        let smooth = fraction * fraction * (3 - 2 * fraction)
                        marks[y * n + x] = peak * (0.4 + 0.6 * (a + (b - a) * smooth))
                    }
                }
            }
        case .tweed:
            let cells = Int(ceil(period(t) / 3))
            for gy in 0..<cells {
                for gx in 0..<cells {
                    let x = Int((Double(gx) * 3 + random(gx, gy, 7) - 0.5) * scale)
                    let y = Int((Double(gy) * 3 + random(gx, gy, 8) - 0.5) * scale)
                    let length = Int((4 + 3 * random(gx, gy, 9)) * scale)
                    let horizontal = random(gx, gy, 10) < 0.5
                    let alpha = peak * (0.4 + 0.6 * random(gx, gy, 11))
                    for d in 0..<length {
                        for width in 0..<max(1, Int(scale.rounded())) {
                            put(x + (horizontal ? d : width), y + (horizontal ? width : d), alpha)
                        }
                    }
                }
            }
        case .grain: break
        }
        let patternMean = marks.reduce(0, +) / Double(marks.count)
        // Open design, lead decision 2026-10-25 23:58 PDT. Calibrate in Step 9.
        let base = max(0, grainMean - patternMean)
        // Black grayscale + 16-bit alpha keeps the shared cache at four bytes
        // per pixel, without rounding the low-noise uniform base to 8-bit alpha.
        var pixels = [UInt16](repeating: 0, count: marks.count * 2)
        var total = 0.0, peakTotal = 0.0, peakCount = 0, markCount = 0
        for (i, mark) in marks.enumerated() {
            let alpha = base + mark * (1 - base)
            pixels[i * 2 + 1] = UInt16((alpha * 65535).rounded())
            let storedAlpha = Double(pixels[i * 2 + 1]) / 65535
            total += storedAlpha
            if mark > 0 { markCount += 1 }
            if mark >= peak * 0.9 { peakTotal += storedAlpha; peakCount += 1 }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 16, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let tile = Tile(image: image, metrics: Metrics(baseAlpha: base, patternMean: patternMean,
            meanAlpha: total / Double(marks.count), peakMarksMeanAlpha: peakCount > 0 ? peakTotal / Double(peakCount) : base,
            markCoverage: Double(markCount) / Double(marks.count)))
        cache[key] = tile; generationCount += 1
        return tile
    }

    private static func random(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: y) &* 0xD816_3841 ^ salt &* 0x9E37_79B9
        h ^= h >> 13; h = h &* 0x5BD1_E995; h ^= h >> 15
        return Double(h & 0xFFFF) / 65535
    }
}
