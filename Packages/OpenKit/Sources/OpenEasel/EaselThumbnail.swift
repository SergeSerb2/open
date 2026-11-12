import AppKit

/// A small picture of an Easel for the Library: the top of the page (1000 pt wide, at most
/// 750 pt tall), drawn with the canvas's own object drawing, in the current appearance.
@MainActor
public enum EaselThumbnail {
    public static func render(_ document: EaselDocument, imageURL: @escaping (String) -> URL?, pixels: CGFloat,
                              appearance: NSAppearance? = nil) -> NSImage? {
        let pageHeight = min(750, max(500, document.contentBottom + 40))
        let scale = pixels / max(EaselDocument.width, pageHeight)
        let size = CGSize(width: ceil(EaselDocument.width * scale), height: ceil(pageHeight * scale))
        guard size.width >= 1, size.height >= 1 else { return nil }
        let page = FlippedPage(frame: CGRect(origin: .zero, size: size))
        page.appearance = appearance ?? NSApp.effectiveAppearance
        page.wantsLayer = true
        let dark = EaselStyle.dark(page.effectiveAppearance)
        page.layer?.backgroundColor = EaselStyle.canvas(dark: dark).cgColor
        for object in document.paintOrder where object.frame.minY < pageHeight {
            let view = EaselObjectView(object: object)
            view.palette = document.palette
            view.scale = scale
            view.imageURL = imageURL
            view.frame = CGRect(x: object.frame.minX * scale, y: object.frame.minY * scale,
                                width: object.frame.width * scale, height: object.frame.height * scale)
            page.addSubview(view)
        }
        guard let rep = page.bitmapImageRepForCachingDisplay(in: page.bounds) else { return nil }
        page.cacheDisplay(in: page.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
    private final class FlippedPage: NSView { override var isFlipped: Bool { true } }
}
