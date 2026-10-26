import AppKit

@MainActor
public final class SplitDropOverlayView: NSView {
    public enum Zone { case left, right, top, bottom, center }
    public var zone: Zone = .center { didSet { needsDisplay = true } }
    public func zone(at point: CGPoint) -> Zone {
        let x = min(bounds.width / 2, max(80, bounds.width * 0.25)), y = min(bounds.height / 2, max(80, bounds.height * 0.25))
        if point.x < x { return .left }; if point.x > bounds.width - x { return .right }
        if point.y > bounds.height - y { return .top }; if point.y < y { return .bottom }; return .center
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        var r = bounds
        switch zone { case .left: r.size.width /= 2; case .right: r.origin.x = bounds.midX; r.size.width /= 2
        case .top: r.origin.y = bounds.midY; r.size.height /= 2; case .bottom: r.size.height /= 2; case .center: return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6).fill()
    }
}
