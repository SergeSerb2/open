import AppKit

/// Original vectors from D1-design-mockup.html, expressed in a 28-point canvas.
/// No external images, font glyphs, or browser assets are used.
enum LibraryGlyph: String {
    case media, downloads, easels, spaces, boosts, archive, history, search, filter, back, dots, trash, undo

    func draw(in rect: CGRect, color: NSColor, selected: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 28, y: rect.height / 28)
        context.setLineWidth(1.6); context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)
        func fill(_ p: CGPath) { context.setFillColor(color.withAlphaComponent(selected ? 0.30 : 0.14).cgColor); context.addPath(p); context.fillPath() }
        func stroke(_ p: CGPath) { context.addPath(p); context.strokePath() }
        func line(_ points: [CGPoint], close: Bool = false) -> CGPath {
            let p = CGMutablePath(); if let first = points.first { p.move(to: first); for point in points.dropFirst() { p.addLine(to: point) } }; if close { p.closeSubpath() }; return p
        }
        func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2), transform: nil) }
        func points(_ values: [CGFloat]) -> [CGPoint] { stride(from: 0, to: values.count, by: 2).map { CGPoint(x: values[$0], y: values[$0+1]) } }
        switch self {
        case .dots:
            context.scaleBy(x:28/16,y:28/16)
            for x in [CGFloat(3.5),8,12.5] { fill(circle(x,8,0.9)); stroke(circle(x,8,0.9)) }
        case .trash:
            context.scaleBy(x:28/16,y:28/16);context.setLineWidth(1.3)
            for values in [[CGFloat(3),4.5,13,4.5],[6.3,4.5,6.3,3,9.7,3,9.7,4.5],[4.3,4.5,4.9,13,11.1,13,11.7,4.5],[6.8,7,6.8,10.8],[9.2,7,9.2,10.8]] { stroke(line(points(values))) }
        case .undo:
            context.scaleBy(x:28/16,y:28/16);context.setLineWidth(1.4)
            stroke(line(points([6,3.5,3,6.5,6,9.5])));stroke(line(points([3.3,6.5,9,6.5])))
            let arc=CGMutablePath();arc.addArc(center:CGPoint(x:9,y:10),radius:3.5,startAngle:-CGFloat.pi/2,endAngle:CGFloat.pi/2,clockwise:false);stroke(arc);stroke(line(points([9,13.5,7,13.5])))
        case .media:
            let card = round(7.5, 8.5, 17, 13.5, 3); fill(card); stroke(card)
            let back = CGMutablePath(); back.move(to: .init(x: 5, y: 18.5)); back.addLine(to: .init(x: 5, y: 9)); back.addCurve(to: .init(x: 8, y: 6), control1: .init(x: 5, y: 7.34), control2: .init(x: 6.34, y: 6)); back.addLine(to: .init(x: 19, y: 6)); stroke(back)
            stroke(circle(12.6, 13, 1.5)); stroke(line(points([8,20.5,12.6,16.9,15.6,19.1,19,15.5,24,20.1])))
        case .downloads:
            let ring = circle(14,14,9); fill(ring); stroke(ring)
            stroke(line(points([14,9.5,14,17.9]))); stroke(line(points([10.4,14.6,14,18.2,17.6,14.6])))
        case .easels:
            let board = round(5,5.5,18,12.5,2.5); fill(board); stroke(board)
            stroke(line(points([14,18,14,23.5]))); stroke(line(points([9.8,18,7.5,23.5]))); stroke(line(points([18.2,18,20.5,23.5])))
            let mark = CGMutablePath(); mark.move(to: .init(x:9.5,y:13.8)); mark.addCurve(to:.init(x:14.5,y:12.2),control1:.init(x:11.2,y:10.2),control2:.init(x:12.9,y:15.4));mark.addCurve(to:.init(x:18.5,y:12.4),control1:.init(x:15.5,y:10.2),control2:.init(x:16.9,y:11));stroke(mark)
        case .spaces:
            let card = round(10,6.5,12,16,3);fill(card);stroke(card)
            let back = CGMutablePath();back.move(to:.init(x:8.6,y:9.2));back.addLine(to:.init(x:6.7,y:9.7));back.addCurve(to:.init(x:4.9,y:12.9),control1:.init(x:5.2,y:10.1),control2:.init(x:4.5,y:11.5));back.addLine(to:.init(x:7.2,y:21.2));back.addCurve(to:.init(x:10.4,y:23),control1:.init(x:7.6,y:22.7),control2:.init(x:9,y:23.4));back.addLine(to:.init(x:11,y:22.8));stroke(back)
        case .boosts:
            let bolt = line(points([15.5,4.5,7,15.5,13,15.5,11.5,23.5,20.5,12,14.5,12]),close:true);fill(bolt);stroke(bolt)
            let segments: [[CGFloat]] = [[22,5,22,8],[20.5,6.5,23.5,6.5],[6,6.5,6,8.5],[5,7.5,7,7.5]]
            for values in segments {stroke(line(points(values)))}
        case .archive:
            fill(round(6.5,10.5,15,11.5,2.5));stroke(round(5,6,18,4.5,1.8))
            let box=CGMutablePath();box.move(to:.init(x:6.5,y:10.5));box.addLine(to:.init(x:6.5,y:19.5));box.addCurve(to:.init(x:9,y:22),control1:.init(x:6.5,y:20.88),control2:.init(x:7.62,y:22));box.addLine(to:.init(x:19,y:22));box.addCurve(to:.init(x:21.5,y:19.5),control1:.init(x:20.38,y:22),control2:.init(x:21.5,y:20.88));box.addLine(to:.init(x:21.5,y:10.5));stroke(box);stroke(line(points([11.5,14.5,16.5,14.5])))
        case .history:
            fill(circle(14.5,14,8.5))
            let arc=CGMutablePath();arc.addArc(center:.init(x:14.5,y:14),radius:8.5,startAngle:3.355,endAngle:9.425,clockwise:false);stroke(arc)
            stroke(line(points([4.2,9.3,6.1,12.4,9.3,10.7])));stroke(line(points([14.5,9.5,14.5,14,17.7,16])))
        case .search:
            context.scaleBy(x:28/16,y:28/16);stroke(circle(7,7,4.6));stroke(line(points([10.5,10.5,14,14])))
        case .filter:
            context.scaleBy(x:28/16,y:28/16);context.setLineWidth(1.3);stroke(circle(8,8,6.3))
            let segments: [[CGFloat]] = [[4.8,6.3,11.2,6.3],[5.8,8.3,10.2,8.3],[6.9,10.3,9.1,10.3]]
            for values in segments {stroke(line(points(values)))}
        case .back:
            context.scaleBy(x:28/18,y:28/18);stroke(line(points([15,9,3.5,9])));stroke(line(points([8,4.3,3.3,9,8,13.7])))
        }
        context.restoreGState()
    }
}

final class LibraryGlyphView: NSView {
    override var isFlipped: Bool { true }
    var glyph: LibraryGlyph = .downloads { didSet { needsDisplay = true } }
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { glyph.draw(in: bounds, color: color) }
}
