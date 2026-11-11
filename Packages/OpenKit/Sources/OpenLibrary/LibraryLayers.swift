import AppKit

/// Counts raster work owned by the Library, not WindowServer or the engine.
@MainActor
enum LibraryRaster {
    static var stores = 0.0
    static var pixels = 0.0
    static var glyphs = 0.0
    static var text = 0.0
    static var events: [String:Double] = [:]
    static func note(_ event:String) { events[event,default:0] += 1 }
    static func record(_ layer: CALayer) {
        stores += 1; pixels += layer.bounds.width * layer.bounds.height * layer.contentsScale * layer.contentsScale
    }
}

final class LibraryTextLayer: CATextLayer {
    override func display() {
        let area = bounds.width*bounds.height*contentsScale*contentsScale
        MainActor.assumeIsolated { LibraryRaster.stores += 1; LibraryRaster.pixels += area; LibraryRaster.text += 1 }
        super.display()
    }
}

/// Attributed strings are immutable and shared by retained row versions.
@MainActor
enum LibraryText {
    private static let cache = NSCache<NSString, NSAttributedString>()
    static func value(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let key = "\(text)|\(size)|\(weight.rawValue)|\(color)" as NSString
        if let value = cache.object(forKey: key) { return value }
        let value = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        cache.countLimit = 4096; cache.setObject(value, forKey: key); return value
    }
    static func layer() -> LibraryTextLayer {
        let layer = LibraryTextLayer(); layer.truncationMode = .end; layer.contentsScale = 2
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "string": NSNull()]
        return layer
    }
}

/// NSImage can rasterize a symbol when asked for CGImage. Reusing the native
/// image alone does not make that conversion a cache-only row operation.
@MainActor
enum LibraryImages {
    private static let cache: NSCache<NSImage,CGImage> = {
        let cache = NSCache<NSImage,CGImage>(); cache.countLimit = 128; cache.totalCostLimit = 16*1024*1024
        return cache
    }()
    static func value(_ image:NSImage?) -> CGImage? {
        guard let image else { return nil }
        if let cached = cache.object(forKey:image) { return cached }
        var rect = CGRect(x:0,y:0,width:48,height:48)
        guard let contents = image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { return nil }
        cache.setObject(contents,forKey:image,cost:contents.bytesPerRow*contents.height)
        return contents
    }
}

@MainActor
extension LibraryGlyph {
    private static var images: [String: CGImage] = [:]
    func image(size: CGFloat, color: NSColor, selected: Bool = false, scale: CGFloat = 2) -> CGImage? {
        let key = "\(rawValue)|\(size)|\(color)|\(selected)|\(scale)"
        if let image = Self.images[key] { return image }
        guard let context = CGContext(data: nil, width: max(1,Int(size*scale)), height: max(1,Int(size*scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale); context.translateBy(x: 0, y: size); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(in: CGRect(x: 0, y: 0, width: size, height: size), color: color, selected: selected)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if Self.images.count > 256 { Self.images.removeAll(keepingCapacity: true) }
        Self.images[key] = image; LibraryRaster.glyphs += 1
        return image
    }
}

/// Native field drawing is counted separately from our explicit text layers.
@MainActor
class LibraryField: NSTextField {
    override func draw(_ dirtyRect:NSRect) {
        LibraryRaster.stores += 1
        let scale = window?.backingScaleFactor ?? 2
        LibraryRaster.pixels += dirtyRect.width*dirtyRect.height*scale*scale
        LibraryRaster.note("nativeFieldDraw")
        LibraryRaster.note("nativeFieldDraw."+(identifier?.rawValue ?? "unidentified"))
        super.draw(dirtyRect)
    }
}
