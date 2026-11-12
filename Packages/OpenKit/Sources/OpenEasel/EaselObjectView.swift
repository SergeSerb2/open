import AppKit

/// One canvas object. A layer-backed view that redraws only on content or size change;
/// a move changes only its frame (no redraw), so drags stay at display rate.
@MainActor
final class EaselObjectView: NSView {
    var object: EaselObject { didSet { if oldValue.content != object.content { needsDisplay = true } } }
    var palette: EaselPalette = .vibrant { didSet { if oldValue != palette { needsDisplay = true } } }
    var scale: CGFloat = 1 { didSet { if oldValue != scale { needsDisplay = true } } }
    /// Hidden text while the inline editor shows it.
    var editing = false { didSet { if oldValue != editing { needsDisplay = true } } }

    init(object: EaselObject) {
        self.object = object
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// The document view does all hit testing (z order, handles, tools).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func accessibilityLabel() -> String? {
        switch object.content {
        case .text(let t): return t.string.isEmpty ? "Text" : t.string
        case .shape(let kind, let color, _, _): return "\(kind.rawValue.capitalized), \(color.rawValue)"
        }
    }

    /// Shapes: fill 75 % opacity, stroke 2.5 pt, round joins and caps; white gets a 10 % black
    /// stroke (findings §3.4, export viewer facts).
    static let fillOpacity: CGFloat = 0.75
    static let stroke: CGFloat = 2.5

    override func draw(_ dirtyRect: NSRect) {
        let dark = EaselStyle.dark(effectiveAppearance)
        switch object.content {
        case .text(let text):
            guard !editing else { return }
            Self.attributed(text, scale: scale, dark: dark, fitting: bounds.size)?.draw(in: bounds.insetBy(dx: EaselTextMetrics.inset * scale, dy: 0))
        case .shape(let kind, let colorName, let arrow, let points):
            let color = palette.color(colorName, dark: dark)
            let strokeColor = colorName == .white ? NSColor(white: dark ? 1 : 0, alpha: 0.1) : color
            let lw = max(1, Self.stroke * scale)
            let inner = bounds.insetBy(dx: lw / 2, dy: lw / 2)
            switch kind {
            case .rectangle, .circle:
                let path = kind == .rectangle ? NSBezierPath(rect: inner) : NSBezierPath(ovalIn: inner)
                path.lineWidth = lw; path.lineJoinStyle = .round
                color.withAlphaComponent(Self.fillOpacity).setFill(); path.fill()
                strokeColor.setStroke(); path.stroke()
            case .arrow:
                guard let arrow else { return }
                let path = Self.arrowPath(from: point(arrow.start), to: point(arrow.end), scale: scale)
                path.lineWidth = lw; path.lineCapStyle = .round; path.lineJoinStyle = .round
                strokeColor.setStroke(); path.stroke()
            case .freehand:
                guard let points, !points.isEmpty else { return }
                let path = Self.freehandPath(points.map(point))
                path.lineWidth = lw; path.lineCapStyle = .round; path.lineJoinStyle = .round
                strokeColor.setStroke(); path.stroke()
            }
        }
    }
    private func point(_ p: EaselPoint) -> CGPoint { CGPoint(x: p.x * bounds.width, y: p.y * bounds.height) }

    /// Arrow head: two strokes at ±45° from the tip, length min(32, 0.3 × length) (findings §3.4).
    static func arrowPath(from a: CGPoint, to b: CGPoint, scale: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(); path.move(to: a); path.line(to: b)
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 0.5 else { return path }
        let head = min(32 * scale, 0.3 * len), angle = atan2(dy, dx)
        for turn in [CGFloat.pi * 3 / 4, -CGFloat.pi * 3 / 4] {
            path.move(to: b)
            path.line(to: CGPoint(x: b.x + head * cos(angle + turn), y: b.y + head * sin(angle + turn)))
        }
        return path
    }
    static func freehandPath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: pts[0])
        if pts.count == 1 { path.line(to: pts[0]); return path }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.curve(to: mid, controlPoint1: pts[i - 1], controlPoint2: pts[i - 1])
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    /// The text as drawn; shrinks the size until it fits the fixed frame (Arc's export fit loop).
    static func attributed(_ text: EaselText, scale: CGFloat, dark: Bool, fitting size: CGSize?) -> NSAttributedString? {
        guard !text.string.isEmpty else { return nil }
        var factor: CGFloat = 1
        while true {
            let s = NSAttributedString(string: text.string, attributes: EaselTextMetrics.attributes(text, scale: scale * factor, dark: dark))
            guard let size, factor > 0.3 else { return s }
            let needed = s.boundingRect(with: CGSize(width: max(1, size.width - 2 * EaselTextMetrics.inset * scale), height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if needed <= size.height + 1 { return s }
            factor *= 0.92
        }
    }
}

/// Text faces and sizes per family and paragraph style (findings §3.4 table). Fonts: system
/// faces that match the four captured looks (C-report-s6 §1: default sans, serif, wide display
/// sans, monospace) — clean = SF, fancy = New York, hip = SF Expanded, mono = SF Mono. The OFL
/// upstream faces wait for the lead's font decision (F1 Q5).
enum EaselTextMetrics {
    static let inset: CGFloat = 5
    static func size(_ t: EaselText) -> (CGFloat, NSFont.Weight, CGFloat) {
        let table: [EaselParagraphStyle: CGFloat]
        let heavy: NSFont.Weight
        let line: CGFloat
        switch t.fontFamily {
        case .mono: table = [.ultra: 80, .h0: 60, .h1: 44, .h2: 24, .body: 15]; heavy = .bold; line = 1.48
        case .fancy: table = [.ultra: 80, .h0: 60, .h1: 48, .h2: 28, .body: 16]; heavy = .regular; line = 1.32
        case .hip: table = [.ultra: 80, .h0: 60, .h1: 44, .h2: 21, .body: 18]; heavy = .black; line = 1.28
        case .clean: table = [.ultra: 80, .h0: 60, .h1: 44, .h2: 24, .body: 15]; heavy = .heavy; line = 1.2
        }
        let weight: NSFont.Weight = t.paragraphStyle == .body ? .regular : (t.paragraphStyle == .h2 && t.fontFamily != .fancy ? .bold : heavy)
        return (table[t.paragraphStyle] ?? 15, weight, line)
    }
    static func font(_ t: EaselText, scale: CGFloat) -> NSFont {
        let (pt, weight, _) = size(t)
        let base: NSFont
        switch t.fontFamily {
        case .mono: base = .monospacedSystemFont(ofSize: pt * scale, weight: weight)
        case .clean: base = .systemFont(ofSize: pt * scale, weight: weight)
        case .hip: base = .systemFont(ofSize: pt * scale, weight: weight, width: .expanded)
        case .fancy:
            let sys = NSFont.systemFont(ofSize: pt * scale, weight: weight)
            base = sys.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: pt * scale) } ?? sys
        }
        return base
    }
    static func attributes(_ t: EaselText, scale: CGFloat, dark: Bool) -> [NSAttributedString.Key: Any] {
        let (pt, _, line) = size(t)
        let para = NSMutableParagraphStyle()
        para.alignment = t.paragraphStyle == .body ? .left : .center
        para.minimumLineHeight = pt * scale * line; para.maximumLineHeight = pt * scale * line
        return [.font: font(t, scale: scale), .foregroundColor: EaselStyle.text(dark: dark), .paragraphStyle: para]
    }
}
