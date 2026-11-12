import CoreGraphics
import Foundation

/// Capture in Portrait Mode settings (PB2 row 4; docs/re/portrait-capture.md). Arc's popover has a
/// "Use Website Color" swatch, a colour slider, a "Use Desktop Wallpaper" swatch and a watermark
/// toggle; its keys are `portraitCaptureBackground`, `portraitCaptureColorPercentage` and
/// `portraitCaptureHidesWatermark`.
public struct PortraitStyle: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable { case website, color, wallpaper }

    public static let sourceKey = "open.capture.portraitBackground"
    public static let colorPercentageKey = "open.capture.portraitColorPercentage"
    public static let hidesWatermarkKey = "open.capture.portraitHidesWatermark"

    public var source: Source
    /// Position on the colour slider, 0…1.
    public var colorPercentage: Double
    public var hidesWatermark: Bool

    /// Defaults: the colour slider near its blue end, as the capture shows (GUESS: Arc's default).
    public static let standard = PortraitStyle(source: .color, colorPercentage: 0.88, hidesWatermark: false)

    public init(source: Source, colorPercentage: Double, hidesWatermark: Bool) {
        self.source = source; self.colorPercentage = min(1, max(0, colorPercentage.isFinite ? colorPercentage : 0)); self.hidesWatermark = hidesWatermark
    }

    /// Unknown or old values (`theme`, `white`, `black` from before PB2) give the standard source.
    public init(defaults: UserDefaults) {
        let source = defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) ?? Self.standard.source
        let percentage = defaults.object(forKey: Self.colorPercentageKey) == nil ? Self.standard.colorPercentage : defaults.double(forKey: Self.colorPercentageKey)
        self.init(source: source, colorPercentage: percentage, hidesWatermark: defaults.bool(forKey: Self.hidesWatermarkKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(source.rawValue, forKey: Self.sourceKey)
        defaults.set(colorPercentage, forKey: Self.colorPercentageKey)
        defaults.set(hidesWatermark, forKey: Self.hidesWatermarkKey)
    }

    // MARK: Colours

    public typealias RGB = (red: Double, green: Double, blue: Double)

    /// The slider's rainbow, left to right (Open's own stops, matched by eye to the capture frame:
    /// pale pink, pink, violet, red, orange, yellow, green, blue, indigo).
    public static let sliderStops: [RGB] = [
        (0.98, 0.84, 0.88), (0.96, 0.55, 0.78), (0.78, 0.45, 0.85), (0.95, 0.30, 0.32), (0.98, 0.58, 0.25),
        (0.98, 0.88, 0.30), (0.45, 0.85, 0.45), (0.35, 0.62, 0.95), (0.36, 0.40, 0.78),
    ]

    public static func sliderColor(at fraction: Double) -> RGB {
        let t = min(1, max(0, fraction)) * Double(sliderStops.count - 1)
        let i = min(sliderStops.count - 2, Int(t)), f = t - Double(i)
        let a = sliderStops[i], b = sliderStops[i + 1]
        return (a.red + (b.red - a.red) * f, a.green + (b.green - a.green) * f, a.blue + (b.blue - a.blue) * f)
    }

    /// The diagonal background for a base colour: lighter at the top left, deeper at the bottom
    /// right (the capture's light-blue-to-blue field). Mix amounts: GUESS.
    public static func gradient(for base: RGB) -> (topLeft: RGB, bottomRight: RGB) {
        func mix(_ c: RGB, _ to: Double, _ t: Double) -> RGB { (c.red + (to - c.red) * t, c.green + (to - c.green) * t, c.blue + (to - c.blue) * t) }
        return (mix(base, 1, 0.40), mix(base, 0, 0.18))
    }

    /// The page's own colour: the average of the image's top 8 % (the site's header or
    /// background). A near-white or near-black page gives a soft grey-blue instead (GUESS).
    public static func websiteColor(of image: CGImage) -> RGB {
        let w = 32, h = 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(1, image.height * 8 / 100))) else {
            return (0.62, 0.70, 0.82)
        }
        context.interpolationQuality = .medium
        context.draw(top, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return (0.62, 0.70, 0.82) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) { r += Double(bytes[i * 4]); g += Double(bytes[i * 4 + 1]); b += Double(bytes[i * 4 + 2]) }
        let n = Double(w * h) * 255
        let color = (r / n, g / n, b / n)
        let lightness = (max(color.0, color.1, color.2) + min(color.0, color.1, color.2)) / 2
        let chroma = max(color.0, color.1, color.2) - min(color.0, color.1, color.2)
        return chroma < 0.06 && (lightness > 0.9 || lightness < 0.1) ? (0.62, 0.70, 0.82) : color
    }
}
