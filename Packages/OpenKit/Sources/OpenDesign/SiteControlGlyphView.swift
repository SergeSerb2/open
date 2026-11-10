import AppKit

/// Shared URL/pane glyph. The filled SF Symbol supplies transparent slider
/// strokes. The three static sparkles are original vector paths (§3.10).
@MainActor public final class SiteControlGlyphView: NSView {
    public var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true } } }
    public var isBoosted = false { didSet { if isBoosted != oldValue { needsDisplay = true } } }
    public var tint: () -> NSColor = { .labelColor }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        Self.draw(in: bounds, pointSize: Glyph.siteControls.spec.pointSize, isOpen: isOpen, isBoosted: isBoosted, tint: tint())
    }
    public static func draw(in bounds: CGRect, pointSize: CGFloat, isOpen: Bool, isBoosted: Bool, tint: NSColor) {
        guard let image = NSImage(systemSymbolName: isOpen ? "slider.horizontal.2.square.fill" : "slider.horizontal.2.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)), let cg = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: bounds.midX-image.size.width/2, y: bounds.midY-image.size.height/2, width: image.size.width, height: image.size.height)
        let color = isOpen ? SiteControlColors.circleOn.resolved(.dark).nsColor : tint
        cg.saveGState(); cg.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        cg.setBlendMode(.sourceIn); cg.setFillColor(color.cgColor); cg.fill(bounds)
        cg.endTransparencyLayer(); cg.restoreGState()
        guard isBoosted else { return }
        NSColor.white.withAlphaComponent(SiteControlMetrics.buttonSparkleOpacity).setFill()
        let radius = SiteControlMetrics.buttonSparkleSize/2
        for point in [CGPoint(x: rect.minX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.maxY)] {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: point.x,y: point.y-radius))
            path.curve(to: CGPoint(x: point.x+radius,y: point.y), controlPoint1: CGPoint(x: point.x+radius/4,y: point.y-radius/4), controlPoint2: CGPoint(x: point.x+radius/4,y: point.y-radius/4))
            path.curve(to: CGPoint(x: point.x,y: point.y+radius), controlPoint1: CGPoint(x: point.x+radius/4,y: point.y+radius/4), controlPoint2: CGPoint(x: point.x+radius/4,y: point.y+radius/4))
            path.curve(to: CGPoint(x: point.x-radius,y: point.y), controlPoint1: CGPoint(x: point.x-radius/4,y: point.y+radius/4), controlPoint2: CGPoint(x: point.x-radius/4,y: point.y+radius/4))
            path.curve(to: CGPoint(x: point.x,y: point.y-radius), controlPoint1: CGPoint(x: point.x-radius/4,y: point.y-radius/4), controlPoint2: CGPoint(x: point.x-radius/4,y: point.y-radius/4))
            path.close(); path.fill()
        }
    }
}
