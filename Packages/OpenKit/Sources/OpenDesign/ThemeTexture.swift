import CoreGraphics
import Foundation
import OpenModel

/// Open's procedural art. No Arc texture or knob asset is used.
@MainActor
public enum ThemeTexture {
    public struct Metrics: Sendable {
        public var meanAlpha: Double
        public var standardDeviation: Double
    }
    private struct Key: Hashable { var texture: SpaceStyleTexture; var scale: CGFloat }
    private struct Tile { var image: CGImage; var metrics: Metrics }
    private static var cache: [Key: Tile] = [:]
    private static var order: [Key] = []
    public static let cacheLimit = 32
    public static var cachedTileCount: Int { cache.count }
    public private(set) static var denimGenerationCount = 0
    public private(set) static var generationCount = 0

    public static func layerAlpha(_ texture: SpaceStyleTexture, noiseFactor: Double) -> Double {
        let noise = noiseFactor.isFinite ? min(1, max(0, noiseFactor)) : 0
        return noise * ThemeTuning.textureNoiseScale[texture]!
    }

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
            // Own disc-sized mottle, normalized separately from the Space tile.
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
        if t == .sand {
            // Open art: sparse horizontal 2–3 pt dashes, not copied capture pixels.
            marks = [Double](repeating: 0, count: px * px)
            for gy in stride(from: 0.0, to: side, by: 3) { for gx in stride(from: 0.0, to: side, by: 4) {
                let ix = Int(gx), iy = Int(gy)
                guard random(ix, iy, 71) < 0.8 else { continue }
                let x = gx + random(ix, iy, 72), y = gy + random(ix, iy, 73)
                let length = 2 + random(ix, iy, 74), strength = 0.4 + 0.6 * random(ix, iy, 75)
                for py in max(0, Int(y * outputScale))..<min(px, Int(ceil((y + 0.75) * outputScale))) {
                    for px0 in max(0, Int(x * outputScale))..<min(px, Int(ceil((x + length) * outputScale))) { marks[py * px + px0] = strength }
                }
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
        // §17.3: noise affects layer opacity only. One intrinsic tile per
        // texture and scale; there is no noise bucket in the cache key.
        let key = Key(texture: t, scale: scale)
        if let tile = cache[key] { return tile }
        let n = max(1, Int((period(t) * scale).rounded()))
        var marks = [Double](repeating: 0, count: n * n)
        func put(_ x: Int, _ y: Int, _ alpha: Double) {
            let x = (x % n + n) % n, y = (y % n + n) % n
            marks[y * n + x] = max(marks[y * n + x], alpha)
        }
        switch t {
        case .grain:
            guard let grain = Grain.tile(noiseFactor: 1, scale: scale), let data = grain.dataProvider?.data else { return nil }
            let bytes = CFDataGetBytePtr(data)!
            marks = (0..<(n * n)).map { Double(bytes[$0 * 4 + 3]) / 255 }
        case .sand:
            // Our own sparse dots, with the captured mean and contrast below.
            for y in stride(from: 0, to: n, by: 2) {
                for x in stride(from: 0, to: n, by: 2) where random(x, y, 1) < 0.48 {
                    let dx = Int(random(x, y, 2) * 2), dy = Int(random(x, y, 3) * 2)
                    let alpha = 0.4 + 0.6 * random(x, y, 4)
                    put(x + dx, y + dy, alpha)
                    if random(x, y, 5) < 0.5 { put(x + 1 - dx, y + dy, alpha) }
                }
            }
        case .denim:
            for y in 0..<n { for x in 0..<n {
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
            } }
            denimGenerationCount += 1
        case .tweed:
            // Own fine grain plus a weak, seamless low-frequency term. The
            // capture's low total contrast does not imply a large cloudy tile.
            let cells = 32
            func smooth(_ u: Double, _ v: Double) -> Double {
                let gx = Int(floor(u)), gy = Int(floor(v)), fx = u - floor(u), fy = v - floor(v)
                let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
                func at(_ x: Int, _ y: Int) -> Double { random(x % cells, y % cells, 91) - 0.5 }
                let a = at(gx, gy), b = at(gx + 1, gy), c = at(gx, gy + 1), d = at(gx + 1, gy + 1)
                return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
            }
            func fine(_ x: Int, _ y: Int) -> Double { random((x + n) % n, (y + n) % n, 92) - 0.5 }
            for y in 0..<n { for x in 0..<n {
                marks[y * n + x] = fine(x, y) + 0.18 * fine(x - 1, y) + 0.38 * fine(x, y - 1)
                    + 0.65 * smooth(Double(x) * Double(cells) / Double(n), Double(y) * Double(cells) / Double(n))
            } }
        }
        let mean = marks.reduce(0, +) / Double(marks.count)
        let deviation = sqrt(marks.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(marks.count))
        let darkness = ThemeTuning.textureTileDarkness[t]!
        // Alpha spreads are Open's capture fit; the means and layer multipliers
        // follow §17.3. Grain retains its hashed marks, with contrast tuning.
        let spread: Double
        switch t { case .grain: spread = 1.25 * deviation * darkness / mean; case .sand: spread = 0.167; case .denim: spread = 0.0353; case .tweed: spread = 0.0371 }
        let alphas = marks.map { min(1, max(0, darkness + ($0 - mean) * spread / max(1e-12, deviation))) }
        // Contrast tuning may clip the lowest grain values. Normalize its mean
        // again, keeping the same hashed marks and the required 0.060 darkness.
        let normalization = darkness / (alphas.reduce(0, +) / Double(alphas.count))
        var pixels = [UInt16](repeating: 0, count: marks.count * 2)
        var total = 0.0, squared = 0.0
        for (i, alpha) in alphas.enumerated() {
            pixels[i * 2 + 1] = UInt16((min(1, alpha * normalization) * 65535).rounded())
            let stored = Double(pixels[i * 2 + 1]) / 65535
            total += stored; squared += stored * stored
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 16, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let average = total / Double(marks.count)
        let tile = Tile(image: image, metrics: Metrics(meanAlpha: average,
            standardDeviation: sqrt(max(0, squared / Double(marks.count) - average * average))))
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
