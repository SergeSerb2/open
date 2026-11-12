import AppKit

/// Easel tools, toolbar order of capture s4 `e1-new-easel`.
public enum EaselTool: String, CaseIterable, Sendable {
    case pointer, image, text, ellipse, rectangle, arrow, freehand

    /// Hover hint letter (capture s4 `e1-hover-*`); the pointer shows none.
    public var shortcut: String? {
        switch self {
        case .pointer: nil
        case .image: "i"
        case .text: "t"
        case .ellipse: "o"
        case .rectangle: "r"
        case .arrow: "a"
        case .freehand: "p"
        }
    }
    public var title: String {
        switch self {
        case .pointer: "Pointer"
        case .image: "Image"
        case .text: "Text"
        case .ellipse: "Ellipse"
        case .rectangle: "Rectangle"
        case .arrow: "Arrow"
        case .freehand: "Freehand"
        }
    }
    public var shapeKind: EaselShapeKind? {
        switch self {
        case .ellipse: .circle
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .freehand: .freehand
        default: nil
        }
    }
}

/// Our own glyphs, drawn in a 20 × 20 pt box (flipped: y down). No Arc artwork.
enum EaselGlyphs {
    static func draw(_ tool: EaselTool, in box: CGRect, color: NSColor, onPlate: Bool) {
        let s = box.width / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
        let path = NSBezierPath()
        path.lineWidth = 1.9 * s; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.set()
        switch tool {
        case .pointer:
            path.move(to: p(5, 2.5)); path.line(to: p(5, 16.5)); path.line(to: p(8.6, 13.2))
            path.line(to: p(11, 18)); path.line(to: p(13.4, 16.8)); path.line(to: p(11, 12.2))
            path.line(to: p(15.6, 12.2)); path.close()
            if onPlate { path.stroke() } else { path.stroke() }
        case .image:
            path.appendRoundedRect(CGRect(origin: p(3, 3), size: CGSize(width: 14 * s, height: 14 * s)), xRadius: 2.2 * s, yRadius: 2.2 * s)
            path.stroke()
            let mount = NSBezierPath(); mount.lineWidth = path.lineWidth; mount.lineJoinStyle = .round; mount.lineCapStyle = .round
            mount.move(to: p(3.6, 15)); mount.line(to: p(9, 10)); mount.line(to: p(16.4, 16.4)); mount.stroke()
            NSBezierPath(ovalIn: CGRect(origin: p(6, 5.6), size: CGSize(width: 2.6 * s, height: 2.6 * s))).fill()
        case .text:
            path.move(to: p(4, 17)); path.line(to: p(10, 3)); path.line(to: p(16, 17))
            path.move(to: p(6.4, 12)); path.line(to: p(13.6, 12)); path.stroke()
        case .ellipse:
            path.appendOval(in: CGRect(origin: p(3.2, 3.2), size: CGSize(width: 13.6 * s, height: 13.6 * s))); path.stroke()
        case .rectangle:
            path.appendRect(CGRect(origin: p(3.5, 3.5), size: CGSize(width: 13 * s, height: 13 * s))); path.stroke()
        case .arrow:
            path.move(to: p(3.5, 16.5)); path.line(to: p(15, 5)); path.stroke()
            let head = NSBezierPath()
            head.move(to: p(17, 3)); head.line(to: p(9.6, 4.6)); head.line(to: p(15.4, 10.4)); head.close(); head.fill()
        case .freehand:
            path.move(to: p(3.5, 14))
            path.curve(to: p(8.5, 6.5), controlPoint1: p(5.5, 10), controlPoint2: p(7, 7))
            path.curve(to: p(7.8, 15.5), controlPoint1: p(10, 6), controlPoint2: p(5, 14))
            path.curve(to: p(13, 7), controlPoint1: p(9.5, 16.5), controlPoint2: p(11, 8))
            path.curve(to: p(15.5, 16), controlPoint1: p(15, 6), controlPoint2: p(12.5, 14.5))
            path.stroke()
        }
    }

    /// "Add" (split beside the Easel): two stacked rounded squares with a plus.
    static func drawAdd(in box: CGRect, color: NSColor) {
        let s = box.width / 20
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: box.minX + x * s, y: box.minY + y * s, width: w * s, height: w * s) }
        color.set()
        let back = NSBezierPath(); back.lineWidth = 1.9 * s; back.lineCapStyle = .round
        back.move(to: CGPoint(x: box.minX + 3 * s, y: box.minY + 12 * s))
        back.line(to: CGPoint(x: box.minX + 3 * s, y: box.minY + 5 * s))
        back.appendArc(withCenter: CGPoint(x: box.minX + 5 * s, y: box.minY + 5 * s), radius: 2 * s, startAngle: 180, endAngle: 270)
        back.line(to: CGPoint(x: box.minX + 12 * s, y: box.minY + 3 * s))
        back.stroke()
        let front = NSBezierPath(roundedRect: r(6.5, 6.5, 10.5), xRadius: 2.4 * s, yRadius: 2.4 * s)
        front.lineWidth = 1.9 * s; front.stroke()
        let plus = NSBezierPath(); plus.lineWidth = 1.9 * s; plus.lineCapStyle = .round
        plus.move(to: CGPoint(x: box.minX + 11.75 * s, y: box.minY + 9 * s)); plus.line(to: CGPoint(x: box.minX + 11.75 * s, y: box.minY + 14.5 * s))
        plus.move(to: CGPoint(x: box.minX + 9 * s, y: box.minY + 11.75 * s)); plus.line(to: CGPoint(x: box.minX + 14.5 * s, y: box.minY + 11.75 * s))
        plus.stroke()
    }

    /// Sidebar row / tab icon: an easel stand with a squiggle, own drawing, 32 × 32 px PNG.
    static func faviconPNG(color: NSColor) -> Data? {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { rect in
            let s = rect.width / 20
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            color.set()
            let board = NSBezierPath(roundedRect: CGRect(origin: p(3, 2.5), size: CGSize(width: 14 * s, height: 10.5 * s)), xRadius: 2 * s, yRadius: 2 * s)
            board.lineWidth = 1.8 * s; board.stroke()
            let legs = NSBezierPath(); legs.lineWidth = 1.8 * s; legs.lineCapStyle = .round
            legs.move(to: p(7, 13.5)); legs.line(to: p(5, 18))
            legs.move(to: p(13, 13.5)); legs.line(to: p(15, 18))
            legs.stroke()
            let squiggle = NSBezierPath(); squiggle.lineWidth = 1.6 * s; squiggle.lineCapStyle = .round
            squiggle.move(to: p(6, 9.5))
            squiggle.curve(to: p(10, 6), controlPoint1: p(7.5, 6), controlPoint2: p(9, 5.5))
            squiggle.curve(to: p(14, 7.5), controlPoint1: p(11, 9.5), controlPoint2: p(13, 9))
            squiggle.stroke()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

public enum EaselIcon {
    /// The Easel row icon in the sidebar (own drawing, blue like the toolbar glyphs).
    public static let faviconPNG: Data? = EaselGlyphs.faviconPNG(color: EaselPalette.srgb(0x2930FB))
}
