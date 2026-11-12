import AppKit

/// Open's own pull-request glyph (not GitHub's or Arc's art): a branch line with two nodes on
/// the left, and a node on the right whose line curves up into an arrow pointing left.
/// Drawn in `rect` (any size from 7 pt) with one ink colour.
@MainActor
enum PullRequestGlyph {
    static func draw(in rect: CGRect, color: NSColor, flipped: Bool = true) {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: flipped ? oy + y * s : oy + (1 - y) * s) }
        let line = max(1, s * 0.11), r = s * 0.13
        color.setStroke(); color.setFill()
        // Left branch: nodes at top and bottom, joined by a straight line.
        let left = NSBezierPath(); left.lineWidth = line; left.lineCapStyle = .round
        left.move(to: p(0.25, 0.22 + 0.13)); left.line(to: p(0.25, 0.78 - 0.13)); left.stroke()
        for c in [p(0.25, 0.18), p(0.25, 0.82)] {
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        // Right branch: bottom node, a line up and then left, ending in an arrow head.
        let right = NSBezierPath(); right.lineWidth = line; right.lineCapStyle = .round; right.lineJoinStyle = .round
        right.move(to: p(0.75, 0.82 - 0.13))
        right.line(to: p(0.75, 0.38))
        right.curve(to: p(0.58, 0.20), controlPoint1: p(0.75, 0.26), controlPoint2: p(0.68, 0.20))
        right.line(to: p(0.47, 0.20))
        right.stroke()
        let head = NSBezierPath()
        head.move(to: p(0.40, 0.20)); head.line(to: p(0.54, 0.08)); head.line(to: p(0.54, 0.32)); head.close(); head.fill()
        let c = p(0.75, 0.82)
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }
}

/// Image view wrapper for the glyph (intro card).
@MainActor
final class PullRequestGlyphView: NSView {
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { PullRequestGlyph.draw(in: bounds, color: ink) }
}
