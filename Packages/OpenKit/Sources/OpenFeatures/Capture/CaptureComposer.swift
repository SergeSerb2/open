import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import OpenDesign

/// Image work for the Capture tool (page-platform §4.6.4): crop an area out of the visible
/// page, put a page on the portrait canvas, encode PNG. Pure Core Graphics on plain data, so
/// it runs off the main actor (`render(_:)`); nothing here touches AppKit views.
public enum CaptureComposer {
    public enum Kind: String, Sendable, CaseIterable { case area, fullPage, portrait }
    public enum PortraitBackground: String, Sendable, CaseIterable {
        case theme, white, black
        /// `open.capture.portraitBackground` (§5): unknown values fall back to `theme`.
        public init(defaultsValue: String?) { self = defaultsValue.flatMap(Self.init(rawValue:)) ?? .theme }
    }

    /// One capture's image job. `png` is the engine's PNG (visible page or full page).
    public struct Job: Sendable {
        public var kind: Kind
        public var png: Data
        /// Area only: the selection in page-view points, top-left origin.
        public var selection: CGRect?
        /// The page view's size in points (the PNG covers it at device scale).
        public var viewSize: CGSize
        public var portraitBackground: PortraitBackground
        public var themeStyle: SpaceThemeStyle
        public init(kind: Kind, png: Data, selection: CGRect? = nil, viewSize: CGSize,
                    portraitBackground: PortraitBackground = .theme, themeStyle: SpaceThemeStyle = .defaultTheme(system: .dark)) {
            self.kind = kind; self.png = png; self.selection = selection; self.viewSize = viewSize
            self.portraitBackground = portraitBackground; self.themeStyle = themeStyle
        }
    }

    public struct Output: Sendable {
        public var png: Data
        public var pixelWidth: Int
        public var pixelHeight: Int
        /// A small PNG for the result card (long side ≤ `thumbnailMaxPixels`).
        public var thumbnailPNG: Data
    }
    /// The card shows the thumbnail at most 224 × 160 pt; 2x on the long side.
    public static let thumbnailMaxPixels = 448

    public enum Failure: Error, CustomStringConvertible {
        case decode, emptySelection, compose, encode, tooLarge
        public var description: String {
            switch self {
            case .decode: "The page image could not be read."
            case .emptySelection: "The selection is empty."
            case .compose: "The capture could not be drawn."
            case .encode: "The capture could not be saved as PNG."
            case .tooLarge: "The page image is too large."
            }
        }
    }

    /// Largest image this composer decodes: 8,192 px wide (a visible page on a 6K display at 2x),
    /// 32,768 px tall (the full-page cap, EP-8), and at most 4,096 × 32,768 pixels in all (the
    /// full-page engine output's own width cap). Worst single allocation: one decoded RGBA
    /// bitmap of 134,217,728 px × 4 B = 512 MiB, under the 2 GiB allocator ceiling. The portrait
    /// canvas only takes visible-page snapshots (≤ 8,192 × 8,192 px in practice) and refuses a
    /// canvas over the same pixel budget × 1.5.
    public static let maxPixelWidth = 8_192
    public static let maxPixelHeight = CaptureMetrics.fullPageMaxDevicePixels
    public static let maxPixelCount = 4_096 * CaptureMetrics.fullPageMaxDevicePixels

    /// Runs the job at utility priority, off the main actor. Only plain data crosses actors.
    public static func render(_ job: Job) async throws -> Output {
        try await Task.detached(priority: .utility) { try compose(job) }.value
    }

    /// Synchronous body of `render`; the offscreen checks call it directly.
    public static func compose(_ job: Job) throws -> Output {
        if job.kind == .fullPage {
            // The engine already stitched and encoded it (EP-8): keep its bytes, read only the header.
            guard let size = pixelSize(job.png), let thumb = thumbnail(job.png) else { throw Failure.decode }
            return Output(png: job.png, pixelWidth: size.width, pixelHeight: size.height, thumbnailPNG: thumb)
        }
        guard let page = decode(job.png) else { throw Failure.decode }
        let image: CGImage
        switch job.kind {
        case .area:
            guard let selection = job.selection, let cropped = crop(page, selection: selection, viewSize: job.viewSize) else { throw Failure.emptySelection }
            image = cropped
        case .fullPage: image = page
        case .portrait:
            guard let canvas = portrait(page, background: job.portraitBackground, style: job.themeStyle) else { throw Failure.compose }
            image = canvas
        }
        guard let png = encodePNG(image), let thumb = thumbnail(png) else { throw Failure.encode }
        return Output(png: png, pixelWidth: image.width, pixelHeight: image.height, thumbnailPNG: thumb)
    }

    /// Pixel size from the PNG header, within the decode limits.
    public static func pixelSize(_ png: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              withinLimits(width: width, height: height) else { return nil }
        return (width, height)
    }
    public static func withinLimits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxPixelWidth && height <= maxPixelHeight && width * height <= maxPixelCount
    }

    /// ImageIO's subsampled thumbnail: never decodes the full image at full size.
    public static func thumbnail(_ png: Data) -> Data? {
        guard pixelSize(png) != nil, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return encodePNG(image)
    }

    /// Decodes a PNG and refuses images over the pixel limits (checked from the header, before
    /// any pixel is decoded).
    public static func decode(_ png: Data) -> CGImage? {
        guard pixelSize(png) != nil, let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// The selection (page-view points, top-left origin) in the page image's pixels:
    /// selection × `image.width / viewSize.width`, rounded outward and clamped to the image.
    public static func pixelRect(selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let sx = imageSize.width / viewSize.width, sy = imageSize.height / viewSize.height
        let raw = CGRect(x: selection.minX * sx, y: selection.minY * sy, width: selection.width * sx, height: selection.height * sy)
        let rect = CGRect(x: raw.minX.rounded(.down), y: raw.minY.rounded(.down),
                          width: raw.maxX.rounded(.up) - raw.minX.rounded(.down), height: raw.maxY.rounded(.up) - raw.minY.rounded(.down))
            .intersection(CGRect(origin: .zero, size: imageSize))
        return rect.isNull || rect.width < 1 || rect.height < 1 ? nil : rect
    }

    public static func crop(_ image: CGImage, selection: CGRect, viewSize: CGSize) -> CGImage? {
        guard let rect = pixelRect(selection: selection, viewSize: viewSize, imageSize: CGSize(width: image.width, height: image.height)) else { return nil }
        return image.cropping(to: rect)
    }

    /// Portrait canvas (§4.6.4, guess pending C-C2): 4:5, canvas width = image width ÷ 0.86, the
    /// image centered. A page taller than the 4:5 frame allows grows the canvas from its height
    /// instead, so the image always keeps the 86 % margin rule on its longer fit.
    public static func portraitLayout(imageSize: CGSize) -> (canvas: CGSize, image: CGRect) {
        let f = CaptureMetrics.portraitImageFraction, aspect = CaptureMetrics.portraitAspect
        var width = (imageSize.width / f).rounded(), height = (width / aspect).rounded()
        if imageSize.height > height * f {
            height = (imageSize.height / f).rounded(); width = (height * aspect).rounded()
        }
        let origin = CGPoint(x: ((width - imageSize.width) / 2).rounded(), y: ((height - imageSize.height) / 2).rounded())
        return (CGSize(width: width, height: height), CGRect(origin: origin, size: imageSize))
    }

    public static func portrait(_ image: CGImage, background: PortraitBackground, style: SpaceThemeStyle) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let layout = portraitLayout(imageSize: size)
        let canvasWidth = Int(layout.canvas.width), canvasHeight = Int(layout.canvas.height)
        guard canvasWidth * canvasHeight <= maxPixelCount * 3 / 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        switch background {
        case .white: context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.fill(canvas)
        case .black: context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); context.fill(canvas)
        case .theme:
            // The Space's theme field (`ThemeField`, the window background's own math), stretched smooth.
            if let field = ThemeField.makeImage(style: style, windowSize: layout.canvas, isActive: true, resolution: CaptureMetrics.portraitThemeResolution) {
                context.interpolationQuality = .high; context.draw(field, in: canvas)
            } else { context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.fill(canvas) }
        }
        // Core Graphics is bottom-up: flip the image rect's y.
        let rect = CGRect(x: layout.image.minX, y: layout.canvas.height - layout.image.maxY, width: size.width, height: size.height)
        let radius = size.width * CaptureMetrics.portraitCornerFraction
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size.width * CaptureMetrics.portraitShadowOffsetFraction),
                          blur: size.width * CaptureMetrics.portraitShadowBlurFraction,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptureMetrics.portraitShadowAlpha))
        context.addPath(path); context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.fillPath()
        context.restoreGState()
        context.saveGState(); context.addPath(path); context.clip(); context.draw(image, in: rect); context.restoreGState()
        return context.makeImage()
    }

    public static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Save… default name (§4.6.5, PG-6.4 literals `[^a-zA-Z0-9\-_ ]`, `' MM-dd`, `' h.mma '`;
    /// assembly guess): `<title> <MM-dd> at <h.mma>.png`, title with other characters removed.
    public static func fileName(title: String, date: Date, locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        var cleaned = String(title.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "Capture" }
        // Keep the name under the file system's 255-byte limit with room for the date part.
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)).trimmingCharacters(in: .whitespaces) }
        let day = DateFormatter(), time = DateFormatter()
        for f in [day, time] { f.locale = locale; f.timeZone = timeZone }
        day.dateFormat = "MM-dd"; time.dateFormat = "h.mma"
        return "\(cleaned) \(day.string(from: date)) at \(time.string(from: date)).png"
    }
}
