import AppKit

/// Our own procedural grain. Arc multiplies a 100 pt grain tile over the
/// gradient (`overlayFragment` / `renderFragment`, docs/design.md). We do not
/// use Arc's tiles: we generate hashed white noise.
///
/// Monochrome multiply by `g` at strength `a` equals a black overlay of alpha
/// `a·(1 − g)`, so the tile is plain black with noise in alpha and composites
/// with normal source-over. No compositing filter is needed.
public enum Grain {
    /// Tile period in points (measured: the grain repeats every 100 px at 1x).
    public static let tilePoints: CGFloat = 100
    /// Peak darkening per unit `noiseFactor`. Fitted so `noiseFactor` 0.35 gives
    /// ±1 % relative noise (measured 1st/99th percentile 0.975…1.017).
    public static let strength: Double = 0.1

    /// Black tile with noise alpha in `0…noiseFactor·strength`.
    public static func tile(noiseFactor: Double, scale: CGFloat, seed: UInt32 = 0x9E37_79B9) -> CGImage? {
        let px = Int((tilePoints * scale).rounded())
        guard px > 0, noiseFactor > 0 else { return nil }
        let peak = min(max(noiseFactor * strength, 0), 1)
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        for y in 0..<px {
            for x in 0..<px {
                // xorshift-mixed integer hash: stable, seamless (tile wraps at px).
                var h = UInt32(truncatingIfNeeded: x) &* 0x8DA6_B343 ^ UInt32(truncatingIfNeeded: y) &* 0xD816_3841 ^ seed
                h ^= h >> 13; h = h &* 0x5BD1_E995; h ^= h >> 15
                let n = Double(h & 0xFFFF) / 65535.0
                let a = UInt8((n * peak * 255).rounded())
                bytes[(y * px + x) * 4 + 3] = a // premultiplied black: RGB stay 0
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
