import AppKit
import QuartzCore

/// The row speaker's mute / unmute spring choreography (Arc `ARCUI.SpeakerIcon`,
/// docs/re/features-advanced.md PP-23): waves spring with response 0.3, damping 0.6 and
/// delays 0 / 0.03 / 0.06 s on mute, 0.06 / 0.09 / 0.12 s on unmute; the base glyph the
/// same spring 0.072 s after a mute starts; the slash (0.3, 0.65) after 0.072 s on mute and
/// (0.25, 0.7) at once on unmute.
///
/// Open does not copy Arc's drawing. The parts come from the same SF Symbols the static row
/// shows (`speaker.wave.3`, `speaker.slash`): the audible image is cut at its empty pixel
/// columns into the speaker body and its three waves, so both ends of the animation are the
/// static glyphs exactly. GUESS (not in the static evidence): which properties each spring
/// drives — here opacity, plus scale for the waves and the slash.
@MainActor
public enum SpeakerSpring {
    struct Spring { let response: Double; let damping: Double }
    static let wave = Spring(response: 0.3, damping: 0.6)
    static let slashOn = Spring(response: 0.3, damping: 0.65)
    static let slashOff = Spring(response: 0.25, damping: 0.7)
    static let muteWaveDelays: [Double] = [0, 0.03, 0.06]
    static let unmuteWaveDelays: [Double] = [0.06, 0.09, 0.12]
    static let muteBaseDelay = 0.072
    static let waveHiddenScale: CGFloat = 0.6
    static let slashHiddenScale: CGFloat = 0.8
    static let layerName = "media.speakerSpring"

    /// SwiftUI-style spring(response:dampingFraction:) as a Core Animation spring (mass 1).
    static func animation(_ keyPath: String, from: Any, to: Any, spring: Spring, delay: Double, start: CFTimeInterval) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / spring.response, 2)
        a.damping = 4 * .pi * spring.damping / spring.response
        a.fromValue = from; a.toValue = to
        a.duration = a.settlingDuration
        a.beginTime = start + delay
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        return a
    }

    /// The image drawn centered in `size`, tinted, at `scale` (top row first).
    public static func bitmap(_ image: NSImage, tint: NSColor, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = image.size
        let rect = NSRect(x: ((size.width - s.width) / 2 * scale).rounded() / scale, y: ((size.height - s.height) / 2 * scale).rounded() / scale,
                          width: s.width, height: s.height)
        image.draw(in: rect)
        tint.setFill(); rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Column ranges that hold ink, split at fully empty columns.
    public static func bands(_ image: CGImage) -> [Range<Int>] {
        let w = image.width, h = image.height
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let row = image.bytesPerRow, step = image.bitsPerPixel / 8
        var ranges: [Range<Int>] = [], start: Int?
        for x in 0..<w {
            var ink = false
            for y in 0..<h where bytes[y * row + x * step + 3] > 8 { ink = true; break }
            if ink, start == nil { start = x }
            if !ink, let s = start { ranges.append(s..<x); start = nil }
        }
        if let s = start { ranges.append(s..<w) }
        return ranges
    }

    /// Splits the glyph into the speaker body (its first column band) and the three waves
    /// (the three largest connected ink regions to the right; specks join the nearest wave).
    /// Each part is a full-size image holding only that part's pixels.
    static func parts(_ glyph: CGImage) -> (body: CGImage, waves: [CGImage])? {
        let w = glyph.width, h = glyph.height
        guard let first = bands(glyph).first, let data = glyph.dataProvider?.data, let src = CFDataGetBytePtr(data) else { return nil }
        let row = glyph.bytesPerRow, step = glyph.bitsPerPixel / 8
        func ink(_ x: Int, _ y: Int) -> Bool { src[y * row + x * step + 3] > 8 }
        var label = [Int](repeating: -1, count: w * h)
        var regions: [[Int]] = []
        for y in 0..<h { for x in first.upperBound..<w where ink(x, y) && label[y * w + x] < 0 {
            var stack = [y * w + x], members: [Int] = []
            label[y * w + x] = regions.count
            while let i = stack.popLast() {
                members.append(i)
                let px = i % w, py = i / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = px + dx, ny = py + dy
                    guard nx >= first.upperBound, nx < w, ny >= 0, ny < h, label[ny * w + nx] < 0, ink(nx, ny) else { continue }
                    label[ny * w + nx] = regions.count; stack.append(ny * w + nx)
                } }
            }
            regions.append(members)
        } }
        guard regions.count >= 3 else { return nil }
        let order = regions.indices.sorted { regions[$0].count > regions[$1].count }
        var waves = Array(order.prefix(3)).map { [regions[$0]] }
        func centerX(_ members: [Int]) -> Double { Double(members.reduce(0) { $0 + $1 % w }) / Double(max(1, members.count)) }
        let centers = waves.map { centerX($0[0]) }
        for index in order.dropFirst(3) {
            let c = centerX(regions[index])
            let nearest = centers.indices.min { abs(centers[$0] - c) < abs(centers[$1] - c) }!
            waves[nearest].append(regions[index])
        }
        let sorted = waves.sorted { centerX($0.flatMap { $0 }) < centerX($1.flatMap { $0 }) }
        func image(keeping keep: (Int) -> Bool) -> CGImage? {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w where keep(y * w + x) {
                for c in 0..<4 { bytes[(y * w + x) * 4 + c] = src[y * row + x * step + c] }
            } }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let body = image(keeping: { $0 % w < first.upperBound }) else { return nil }
        var waveImages: [CGImage] = []
        for wave in sorted {
            let set = Set(wave.flatMap { $0 })
            guard let part = image(keeping: { set.contains($0) }) else { return nil }
            waveImages.append(part)
        }
        return (body, waveImages)
    }

    /// Runs the choreography in a temporary layer over the button. Returns false when the
    /// glyph cannot be cut into a body and three waves (the caller keeps its fallback).
    @discardableResult
    static func run(in host: CALayer, bounds: CGRect, scale: CGFloat, audible: NSImage, muted: NSImage, tint: NSColor,
                    toMuted: Bool, completion: @escaping @MainActor () -> Void) -> CALayer? {
        guard let full = bitmap(audible, tint: tint, size: bounds.size, scale: scale),
              let mutedImage = bitmap(muted, tint: tint, size: bounds.size, scale: scale) else { return nil }
        guard let cut = parts(full) else { return nil }
        let container = CALayer()
        container.name = layerName
        container.frame = bounds
        container.contentsScale = scale
        func part(_ image: CGImage) -> CALayer {
            let layer = CALayer()
            layer.contents = image; layer.contentsScale = scale
            layer.frame = CGRect(origin: .zero, size: bounds.size)
            return layer
        }
        let base = part(cut.body)
        let waves = cut.waves.map(part)
        let slash = CALayer()
        slash.contents = mutedImage; slash.contentsScale = scale; slash.frame = CGRect(origin: .zero, size: bounds.size)
        for layer in [base] + waves + [slash] { container.addSublayer(layer) }
        host.addSublayer(container)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let start = container.convertTime(CACurrentMediaTime(), from: nil)
        var end: CFTimeInterval = 0
        func add(_ layer: CALayer, _ animation: CASpringAnimation) {
            layer.add(animation, forKey: "speaker." + (animation.keyPath ?? "x"))
            end = max(end, animation.beginTime - start + animation.duration)
        }
        let hidden = CATransform3DMakeScale(waveHiddenScale, waveHiddenScale, 1)
        let slashHidden = CATransform3DMakeScale(slashHiddenScale, slashHiddenScale, 1)
        if toMuted {
            for (i, layer) in waves.enumerated() {
                layer.opacity = 0; layer.transform = hidden
                add(layer, animation("opacity", from: 1, to: 0, spring: wave, delay: muteWaveDelays[i], start: start))
                add(layer, animation("transform", from: CATransform3DIdentity, to: hidden, spring: wave, delay: muteWaveDelays[i], start: start))
            }
            base.opacity = 0
            add(base, animation("opacity", from: 1, to: 0, spring: wave, delay: muteBaseDelay, start: start))
            slash.opacity = 1
            add(slash, animation("opacity", from: 0, to: 1, spring: slashOn, delay: muteBaseDelay, start: start))
            add(slash, animation("transform", from: slashHidden, to: CATransform3DIdentity, spring: slashOn, delay: muteBaseDelay, start: start))
        } else {
            slash.opacity = 0; slash.transform = slashHidden
            add(slash, animation("opacity", from: 1, to: 0, spring: slashOff, delay: 0, start: start))
            add(slash, animation("transform", from: CATransform3DIdentity, to: slashHidden, spring: slashOff, delay: 0, start: start))
            base.opacity = 1
            add(base, animation("opacity", from: 0, to: 1, spring: wave, delay: 0, start: start))
            for (i, layer) in waves.enumerated() {
                layer.opacity = 1
                add(layer, animation("opacity", from: 0, to: 1, spring: wave, delay: unmuteWaveDelays[i], start: start))
                add(layer, animation("transform", from: hidden, to: CATransform3DIdentity, spring: wave, delay: unmuteWaveDelays[i], start: start))
            }
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            MainActor.assumeIsolated {
                guard container.superlayer != nil else { return }
                container.removeFromSuperlayer(); completion()
            }
        }
        return container
    }
}
