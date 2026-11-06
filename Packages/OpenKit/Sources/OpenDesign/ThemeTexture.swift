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
        switch t {
        case .grain:
            guard let grain = Grain.tile(noiseFactor: 1, scale: scale), let data = grain.dataProvider?.data else { return nil }
            let bytes = CFDataGetBytePtr(data)!
            marks = (0..<(n * n)).map { Double(bytes[$0 * 4 + 3]) / 255 }
        case .sand:
            // Dense, even sand: white noise softened by a 0.47 pt Gaussian, so
            // direct neighbours correlate about +0.2 on both axes, as in the
            // session 2 F0114 statistics. The kernel wraps at the tile edge and
            // scales with the backing scale, so grains keep their size.
            let sigma = 0.47 * scale, radius = Int((3 * sigma).rounded(.up))
            var kernel: [(dx: Int, dy: Int, weight: Double)] = []
            for dy in -radius...radius { for dx in -radius...radius {
                kernel.append((dx, dy, exp(-Double(dx * dx + dy * dy) / (2 * sigma * sigma))))
            } }
            let white = (0..<(n * n)).map { random($0 % n, $0 / n, 3) - 0.5 }
            for y in 0..<n { for x in 0..<n {
                var sum = 0.0
                for k in kernel { sum += k.weight * white[((y + k.dy + n) % n) * n + (x + k.dx + n) % n] }
                marks[y * n + x] = sum
            } }
        case .denim:
            // Open's own twill, drawn in points. A fine "\" hatch (wave vector
            // 0.40, −0.44 cycles/pt, lines about 1.7 pt apart) with a soft,
            // uneven strength; vertical warp lines every 2.5 pt with slow shade
            // changes along each thread; a weak 5.3 pt column beat; fine noise.
            // The frequencies, directions, and mix follow the spectrum and lag
            // statistics of session 2 F0116 (no capture pixels are used). All
            // periods divide the 300 pt tile, so it repeats seamlessly.
            for y in 0..<n { for x in 0..<n {
                let u = (Double(x) + 0.5) / scale, v = (Double(y) + 0.5) / scale
                let twill = cos(2 * .pi * (0.40 * u - 0.44 * v)) * (1 + 0.7 * valueNoise(u / 3, v / 3, cells: 100, salt: 61))
                let warp = 0.42 * cos(2 * .pi * 0.40 * u), beat = 0.17 * cos(2 * .pi * 0.19 * u + 1)
                let thread = Int(floor(0.40 * u)) % 120, run = v / 30, step = Int(floor(run))
                let f = run - floor(run), blend = f * f * (3 - 2 * f)
                let shade = 0.8 * (random(thread, step % 10, 5) * (1 - blend) + random(thread, (step + 1) % 10, 5) * blend - 0.5)
                marks[y * n + x] = twill + warp + beat + shade + 1.3 * (random(x, y, 9) - 0.5)
            } }
            denimGenerationCount += 1
        case .tweed:
            // Own fine grain plus a weak, seamless low-frequency term. The
            // capture's low total contrast does not imply a large cloudy tile.
            let cells = 32
            func smooth(_ u: Double, _ v: Double) -> Double { valueNoise(u, v, cells: cells, salt: 91) }
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

    /// Seamless value noise in −0.5…0.5 on a `cells`-periodic lattice.
    private static func valueNoise(_ u: Double, _ v: Double, cells: Int, salt: UInt32) -> Double {
        let gx = Int(floor(u)), gy = Int(floor(v)), fx = u - floor(u), fy = v - floor(v)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func at(_ x: Int, _ y: Int) -> Double { random(x % cells, y % cells, salt) - 0.5 }
        let a = at(gx, gy), b = at(gx + 1, gy), c = at(gx, gy + 1), d = at(gx + 1, gy + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    private static func random(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: y) &* 0xD816_3841 ^ salt &* 0x9E37_79B9
        h ^= h >> 13; h = h &* 0x5BD1_E995; h ^= h >> 15
        return Double(h & 0xFFFF) / 65535
    }
}
