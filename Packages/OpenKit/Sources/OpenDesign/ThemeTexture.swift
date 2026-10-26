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
    private static var order: [Key] = []
    public static let cacheLimit = 32
    public static var cachedTileCount: Int { cache.count }
    private struct GrainKey: Hashable { var bucket: Int; var scale: CGFloat }
    private static var grains: [GrainKey: (CGImage, Double)] = [:]
    private static var grainOrder: [GrainKey] = []
    private static var denimPatterns: [CGFloat: [Double]] = [:]
    private static var denimOrder: [CGFloat] = []
    public private(set) static var denimGenerationCount = 0
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
        let outputScale = scale.isFinite && scale > 0 ? scale : 1
        let side = diameter.isFinite && diameter > 0 ? diameter : 40
        let px = max(1, Int((side * outputScale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let tile = tile(t, noiseFactor: 1, scale: scale) else {
            context.setFillColor(ThemeEditorColors.noisePreviewBase.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: px, height: px))
            return context.makeImage()!
        }
        // Fixed 2× sample, centered on the disc. These are preview pixels only;
        // the procedural Space tiles and their stored-style derivation stay intact.
        context.draw(tile, in: CGRect(x: -Double(px) / 2, y: -Double(px) / 2, width: Double(px) * 2, height: Double(px) * 2))
        let sample = context.data!.assumingMemoryBound(to: UInt8.self)
        var marks = (0..<(px * px)).map { Double(sample[$0 * 4 + 3]) / 255 }
        if t == .tweed {
            // Own soft mottle, not the Space tile's sharply woven marks.
            func smoothNoise(_ x: Double, _ y: Double, cell: Double) -> Double {
                let u = x / cell, v = y / cell, gx = Int(floor(u)), gy = Int(floor(v))
                let fx = u - floor(u), fy = v - floor(v)
                let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
                let a = random(gx, gy, 91), b = random(gx + 1, gy, 91)
                let c = random(gx, gy + 1, 91), d = random(gx + 1, gy + 1, 91)
                return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
            }
            for y in 0..<px { for x in 0..<px {
                let u = Double(x) / outputScale, v = Double(y) / outputScale
                marks[y * px + x] = 0.65 * smoothNoise(u, v, cell: 3) + 0.35 * smoothNoise(u, v, cell: 1.5)
            } }
        }
        let mean = marks.reduce(0, +) / Double(marks.count)
        let deviation = sqrt(marks.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(marks.count))
        let base: Double, contrast: Double, alpha: Double
        switch t {
        case .grain: base = 91; contrast = 14; alpha = 0.29
        case .sand: base = 139; contrast = 7.7; alpha = 1
        case .denim: base = 147; contrast = 5; alpha = 1
        case .tweed: base = 127; contrast = 4.9; alpha = 1
        }
        // Session 2 0112/0114/0116/0118 and light 0159: grain translucency
        // fits both backdrops. Its raw ±19 shade becomes about ±5.5 on screen.
        var pixels = [UInt8](repeating: 0, count: px * px * 4)
        for y in 0..<px { for x in 0..<px {
            let i = y * px + x
            let shade = t == .grain ? 19 * (1 - 2 * Double(y) / Double(max(1, px - 1))) : 0
            let gray = min(255, max(0, base + shade - contrast * (marks[i] - mean) / max(1e-9, deviation)))
            let component = UInt8((gray * alpha).rounded())
            pixels[i * 4] = component; pixels[i * 4 + 1] = component; pixels[i * 4 + 2] = component
            pixels[i * 4 + 3] = UInt8((alpha * 255).rounded())
        } }
        return CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    private static func cached(_ t: SpaceStyleTexture, noise: Double, scale: CGFloat) -> Tile? {
        guard noise.isFinite, noise > 0, scale > 0, scale.isFinite else { return nil }
        let bucket = min(20, max(0, Int((noise * 20).rounded())))
        guard bucket > 0 else { return nil }
        let key = Key(texture: t, noiseBucket: bucket, scale: scale)
        if let tile = cache[key] { return tile }
        let factor = Double(bucket) / 20
        let grainKey = GrainKey(bucket: bucket, scale: scale)
        let grain: CGImage, grainMean: Double
        if let found = grains[grainKey] { (grain, grainMean) = found }
        else {
            guard let image = Grain.tile(noiseFactor: factor, scale: scale), let data = image.dataProvider?.data else { return nil }
            let bytes = CFDataGetBytePtr(data)!
            grain = image
            grainMean = (0..<(image.width * image.height)).reduce(0.0) { $0 + Double(bytes[$1 * 4 + 3]) / 255 } / Double(image.width * image.height)
            if grainOrder.count >= 64 {
                for old in grainOrder.prefix(32) { grains[old] = nil }; grainOrder.removeFirst(32)
            }
            grains[grainKey] = (grain, grainMean); grainOrder.append(grainKey)
        }
        if t == .grain {
            let tile = Tile(image: grain, metrics: Metrics(baseAlpha: 0, patternMean: grainMean, meanAlpha: grainMean,
                                                          peakMarksMeanAlpha: factor * 0.1, markCoverage: 1))
            insert(tile, for: key)
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
            if let pattern = denimPatterns[scale] { marks = pattern.map { $0 * peak } }
            else {
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
                        marks[y * n + x] = 0.4 + 0.6 * (a + (b - a) * smooth)
                    }
                }
            }
            if denimOrder.count >= 4 {
                for old in denimOrder.prefix(2) { denimPatterns[old] = nil }; denimOrder.removeFirst(2)
            }
            denimPatterns[scale] = marks; denimOrder.append(scale); denimGenerationCount += 1
            marks = marks.map { $0 * peak }
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
        insert(tile, for: key)
        return tile
    }

    private static func insert(_ tile: Tile, for key: Key) {
        if order.count >= cacheLimit {
            for old in order.prefix(cacheLimit / 2) { cache[old] = nil }
            order.removeFirst(cacheLimit / 2)
        }
        cache[key] = tile; order.append(key); generationCount += 1
    }

    private static func random(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: y) &* 0xD816_3841 ^ salt &* 0x9E37_79B9
        h ^= h >> 13; h = h &* 0x5BD1_E995; h ^= h >> 15
        return Double(h & 0xFFFF) / 65535
    }
}
