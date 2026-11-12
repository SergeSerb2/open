import AppKit
import ImageIO

/// Decoded, size-bounded thumbnails of Easel images. Decoding uses ImageIO's thumbnail path,
/// so a 16k-pixel original never decodes at full size: at most 2,048 px on the long side
/// (16 MiB as RGBA). The cache keeps 64 entries.
@MainActor
final class EaselImageCache {
    static let shared = EaselImageCache()
    private var entries: [String: CGImage] = [:]
    private var order: [String] = []
    static let maxPixel = 2_048
    static let capacity = 64

    func image(at url: URL, longSide: CGFloat) -> CGImage? {
        let bucket = min(Self.maxPixel, max(64, Int(pow(2, ceil(log2(max(longSide, 1)))))))
        let key = "\(url.path)#\(bucket)"
        if let hit = entries[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: bucket, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        entries[key] = image; order.append(key)
        if order.count > Self.capacity { entries[order.removeFirst()] = nil }
        return image
    }
}

/// Drawing of picture, web card and link card objects. Card chrome keeps fixed point sizes
/// (findings §3.4 "WebCardConstants": corner 10, bar 36, inset 6, favicon 16).
enum EaselCards {
    static let corner: CGFloat = 10
    static let bar: CGFloat = 36
    static let inset: CGFloat = 6

    /// `ImageFiller` #000 10 % light / #686A6B dark (findings §3.4).
    static func filler(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0x686A6B) : NSColor(white: 0, alpha: 0.1) }
    static func border(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08) }

    static func drawImage(_ image: CGImage?, in rect: CGRect, fill: Bool, dark: Bool) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { filler(dark: dark).setFill(); rect.fill(); return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
        let size = CGSize(width: iw * s, height: ih * s)
        let r = CGRect(x: rect.midX - size.width / 2, y: fill ? rect.minY : rect.midY - size.height / 2, width: size.width, height: size.height)
        ctx.saveGState()
        ctx.clip(to: rect)
        // The view is flipped; CGImage draws bottom-up.
        ctx.translateBy(x: 0, y: r.maxY + r.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        ctx.restoreGState()
    }

    static func host(_ url: String) -> String {
        let h = URL(string: url)?.host() ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func drawWebCard(_ card: EaselWebCard, image: CGImage?, bounds: CGRect, dark: Bool) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawImage(image, in: bounds, fill: true, dark: dark)
        NSGraphicsContext.restoreGraphicsState()
        border(dark: dark).setStroke(); shape.lineWidth = 1; shape.stroke()
    }

    static func drawLink(_ link: EaselLink, image: CGImage?, bounds: CGRect, dark: Bool) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
        EaselStyle.floating(dark: dark).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let textHeight: CGFloat = min(bounds.height, link.summary == nil ? 52 : 72)
        if link.imageFile != nil, bounds.height > textHeight + 20 {
            drawImage(image, in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - textHeight), fill: true, dark: dark)
        }
        NSGraphicsContext.restoreGraphicsState()
        let text = CGRect(x: bounds.minX + 12, y: bounds.maxY - textHeight + 8, width: bounds.width - 24, height: textHeight - 16)
        let primary = EaselStyle.text(dark: dark), secondary = primary.withAlphaComponent(0.55)
        let titlePara = NSMutableParagraphStyle(); titlePara.lineBreakMode = .byTruncatingTail
        var y = text.minY
        let title = NSAttributedString(string: link.title ?? host(link.source), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: primary, .paragraphStyle: titlePara])
        title.draw(with: CGRect(x: text.minX, y: y, width: text.width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += 18
        if let summary = link.summary {
            NSAttributedString(string: summary, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary, .paragraphStyle: titlePara])
                .draw(with: CGRect(x: text.minX, y: y, width: text.width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += 18
        }
        NSAttributedString(string: host(link.source), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary, .paragraphStyle: titlePara])
            .draw(with: CGRect(x: text.minX, y: y, width: text.width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        border(dark: dark).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}
