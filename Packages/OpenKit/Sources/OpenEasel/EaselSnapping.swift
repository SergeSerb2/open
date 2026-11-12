import AppKit

/// Alignment guides while moving (findings §3.4: anchors left/right/centerX/top/bottom/centerY;
/// canvas menu "Use Alignment Guides", on by default, key `easel.useSnapguides` in Arc).
/// Capture s4 `e4-move-guides`: a light line through the shared anchor, ≈ 7 pt past both
/// objects, with short ticks in the selection colour at each object's edge.
struct EaselGuide: Equatable {
    var from: CGPoint
    var to: CGPoint
    var ticks: [CGPoint]
    var vertical: Bool
}

enum EaselSnapping {
    static let defaultsKey = "open.easel.useAlignmentGuides"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    /// Snap distance in view points. GUESS 6 pt — capture pending.
    static let threshold: CGFloat = 6
    static let overhang: CGFloat = 7

    /// Returns the delta (document points) after snapping the moving union to the nearest
    /// anchor of a still object on each axis, and the guides to draw (view points).
    static func snap(moving: CGRect, others: [CGRect], scale: CGFloat, toView: (CGRect) -> CGRect) -> (CGVector, [EaselGuide]) {
        guard enabled, !others.isEmpty else { return (.zero, []) }
        let limit = threshold / max(scale, 0.01)
        func xs(_ r: CGRect) -> [CGFloat] { [r.minX, r.midX, r.maxX] }
        func ys(_ r: CGRect) -> [CGFloat] { [r.minY, r.midY, r.maxY] }
        var bestX: (d: CGFloat, other: CGRect, value: CGFloat)?
        var bestY: (d: CGFloat, other: CGRect, value: CGFloat)?
        for o in others {
            for a in xs(moving) { for b in xs(o) where abs(b - a) <= limit && abs(b - a) < abs(bestX?.d ?? .infinity) { bestX = (b - a, o, b) } }
            for a in ys(moving) { for b in ys(o) where abs(b - a) <= limit && abs(b - a) < abs(bestY?.d ?? .infinity) { bestY = (b - a, o, b) } }
        }
        let delta = CGVector(dx: bestX?.d ?? 0, dy: bestY?.d ?? 0)
        let snapped = moving.offsetBy(dx: delta.dx, dy: delta.dy)
        var guides: [EaselGuide] = []
        if let x = bestX {
            let a = toView(snapped), b = toView(x.other), vx = toView(CGRect(x: x.value, y: 0, width: 0, height: 0)).minX
            let top = min(a.minY, b.minY) - overhang, bottom = max(a.maxY, b.maxY) + overhang
            guides.append(EaselGuide(from: CGPoint(x: vx, y: top), to: CGPoint(x: vx, y: bottom),
                                     ticks: [a.minY, a.maxY, b.minY, b.maxY].map { CGPoint(x: vx, y: $0) }, vertical: true))
        }
        if let y = bestY {
            let a = toView(snapped), b = toView(y.other), vy = toView(CGRect(x: 0, y: y.value, width: 0, height: 0)).minY
            let left = min(a.minX, b.minX) - overhang, right = max(a.maxX, b.maxX) + overhang
            guides.append(EaselGuide(from: CGPoint(x: left, y: vy), to: CGPoint(x: right, y: vy),
                                     ticks: [a.minX, a.maxX, b.minX, b.maxX].map { CGPoint(x: $0, y: vy) }, vertical: false))
        }
        return (delta, guides)
    }
}
