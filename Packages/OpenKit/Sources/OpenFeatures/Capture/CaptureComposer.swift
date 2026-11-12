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
    /// One capture's image job. `png` is the engine's PNG (visible page or full page).
    public struct Job: Sendable {
        public var kind: Kind
        public var png: Data
        /// Area only: the selection in page-view points, top-left origin.
        public var selection: CGRect?
        /// The page view's size in points (the PNG covers it at device scale).
        public var viewSize: CGSize
        /// Portrait only: background, colour and watermark.
        public var portrait: PortraitStyle
        /// Portrait with the wallpaper source: the wallpaper file's bytes (read by the App only when
        /// the user picks that swatch). Nil or unreadable bytes fall back to the website colour.
        public var wallpaper: Data?
        public init(kind: Kind, png: Data, selection: CGRect? = nil, viewSize: CGSize,
                    portrait: PortraitStyle = .standard, wallpaper: Data? = nil) {
            self.kind = kind; self.png = png; self.selection = selection; self.viewSize = viewSize
            self.portrait = portrait; self.wallpaper = wallpaper
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
            guard let canvas = portrait(page, style: job.portrait, wallpaper: job.wallpaper) else { throw Failure.compose }
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

    /// Portrait canvas: the proportions of Arc's popover preview (239 × 127 pt; the page card
    /// 96 pt tall, about 0.756 of it; PB2 capture `43-pb2-probe`). Output size and margins of the
    /// saved image: GUESS (not captured). The page keeps its own aspect, centred; a page wider than
    /// 86 % of that frame sets the canvas from its width instead.
    public static func portraitLayout(imageSize: CGSize) -> (canvas: CGSize, image: CGRect) {
        let aspect = CaptureMetrics.portraitAspect, heightFraction = CaptureMetrics.portraitImageHeightFraction
        var height = (imageSize.height / heightFraction).rounded(), width = (height * aspect).rounded()
        if imageSize.width > width * CaptureMetrics.portraitImageFraction {
            width = (imageSize.width / CaptureMetrics.portraitImageFraction).rounded(); height = (width / aspect).rounded()
        }
        let origin = CGPoint(x: ((width - imageSize.width) / 2).rounded(), y: ((height - imageSize.height) / 2).rounded())
        return (CGSize(width: width, height: height), CGRect(origin: origin, size: imageSize))
    }

    /// Wallpaper bytes over this size are refused (a 6K HEIC still is about 10 MB).
    public static let maxWallpaperBytes = 64 << 20

    /// The wallpaper as an image no larger than the canvas's long side (ImageIO subsampling: the
    /// full file is never decoded at full size). Nil for a folder, an unreadable file or a set.
    public static func wallpaperImage(_ data: Data, longSide: Int) -> CGImage? {
        guard data.count <= maxWallpaperBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(64, min(longSide, 8_192)),
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public static func portrait(_ image: CGImage, style: PortraitStyle, wallpaper: Data? = nil) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let layout = portraitLayout(imageSize: size)
        let canvasWidth = Int(layout.canvas.width), canvasHeight = Int(layout.canvas.height)
        guard canvasWidth * canvasHeight <= maxPixelCount * 3 / 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        drawBackground(in: context, canvas: canvas, page: image, style: style, wallpaper: wallpaper, space: space)
        // Core Graphics is bottom-up: flip the image rect's y.
        let rect = CGRect(x: layout.image.minX, y: layout.canvas.height - layout.image.maxY, width: size.width, height: size.height)
        let radius = layout.canvas.width * CaptureMetrics.portraitCornerFraction
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -layout.canvas.width * CaptureMetrics.portraitShadowOffsetFraction),
                          blur: layout.canvas.width * CaptureMetrics.portraitShadowBlurFraction,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CaptureMetrics.portraitShadowAlpha))
        context.addPath(path); context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.fillPath()
        context.restoreGState()
        context.saveGState(); context.addPath(path); context.clip(); context.draw(image, in: rect); context.restoreGState()
        // A light frame around the page card (the capture's pale rim; GUESS width).
        context.saveGState(); context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)); context.setLineWidth(max(1, layout.canvas.width * 0.006)); context.strokePath()
        context.restoreGState()
        if !style.hidesWatermark { drawWatermark(in: context, canvas: canvas) }
        return context.makeImage()
    }

    static func drawBackground(in context: CGContext, canvas: CGRect, page: CGImage, style: PortraitStyle, wallpaper: Data?, space: CGColorSpace) {
        if style.source == .wallpaper, let data = wallpaper,
           let image = wallpaperImage(data, longSide: Int(max(canvas.width, canvas.height))) {
            // Aspect fill, centred.
            let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
            return
        }
        let base = style.source == .color ? PortraitStyle.sliderColor(at: style.colorPercentage) : PortraitStyle.websiteColor(of: page)
        let (a, b) = PortraitStyle.gradient(for: base)
        guard let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: a.red, green: a.green, blue: a.blue, alpha: 1), CGColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: 1)] as CFArray,
            locations: [0, 1]) else { return }
        // Top left to bottom right (Core Graphics y is up).
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Open's watermark: our doorway-and-sun mark on a translucent rounded tile at the bottom left
    /// (Arc's tile: 32 pt in a 239 pt preview, inset 3.5 pt; its mark is Arc's own and not used).
    static func drawWatermark(in context: CGContext, canvas: CGRect) {
        let side = canvas.width * CaptureMetrics.portraitWatermarkFraction, inset = canvas.width * CaptureMetrics.portraitWatermarkInsetFraction
        let tile = CGRect(x: inset, y: inset, width: side, height: side)
        context.saveGState()
        context.addPath(CGPath(roundedRect: tile, cornerWidth: side * 0.25, cornerHeight: side * 0.25, transform: nil))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22)); context.fillPath()
        // The doorway: 168 × 248 proportions, centred in the tile.
        let h = side * 0.62, w = h * 168 / 248
        let door = CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h)
        let path = OpenMarkPath.doorway(in: door)
        context.addPath(path); context.setFillColor(CGColor(srgbRed: 1, green: 0.773, blue: 0.431, alpha: 0.95)); context.fillPath()
        context.addPath(path); context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        context.setLineWidth(max(1, w * 0.06)); context.strokePath()
        // The sun: a pale disc at the upper right of the doorway.
        let r = w * 0.17
        context.setFillColor(CGColor(srgbRed: 1, green: 0.945, blue: 0.839, alpha: 1))
        context.fillEllipse(in: CGRect(x: door.maxX - w * 0.29 - r, y: door.maxY - h * 0.30 - r, width: r * 2, height: r * 2))
        context.restoreGState()
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
