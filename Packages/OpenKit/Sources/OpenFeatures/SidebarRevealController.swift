import AppKit
import OpenDesign

/// Decides when the hidden sidebar shows as the hover-reveal card, from the pointer alone.
///
/// Arc's model (`WindowHoverTracker`, docs/re/interaction-states.md §13): named zones that
/// count as hovered after a short dwell. The card shows after the pointer has dwelt 0.15 s in
/// a trigger zone (inner left edge, outer left edge, the top-left corner, the traffic-light
/// region). While the card shows, it stays as long as the pointer is over the card or any
/// trigger zone, and it hides once the pointer has been out of all of them for 0.15 s.
/// Zones widen once the pointer is in them (hysteresis), so a pointer that drifts along or
/// slightly off the edge neither flickers nor drops the card.
///
/// The pointer location is the last one an event reported; a pointer at rest sends no events,
/// so timers re-check that location when they fire. Coordinates are the window's flipped
/// root coordinates; points left of the window (x < 0) arrive while the window is key.
@MainActor
final class SidebarRevealController {
    enum Phase: String { case idle, pending, shown, leaving }
    enum Zone: String { case innerEdge, outerEdge, topLeft, trafficLights, card }

    struct Geometry {
        /// Root bounds `[0, 0, W, H]`.
        var bounds: CGRect
        var card: CGRect
        var trafficLights: CGRect
    }

    private(set) var phase: Phase = .idle
    /// The card shows (`true`) or hides (`false`).
    var onChange: ((Bool) -> Void)?
    var geometry: () -> Geometry = { Geometry(bounds: .zero, card: .zero, trafficLights: .zero) }
    /// While false, nothing triggers and a shown card hides at once.
    var isEnabled: () -> Bool = { true }

    private var lastPoint: CGPoint?
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    /// After an explicit dismissal (a tab selection, the command bar), the pointer must leave
    /// the trigger zones before it can reveal again, so the card does not pop back at once.
    private var suppressed = false
    private var pendingSince: CFTimeInterval = 0

    // Diagnostics (window-state): counts and the last dwell, in seconds.
    private(set) var shows = 0
    private(set) var hides = 0
    private(set) var pointerEvents = 0
    private(set) var lastDwell: Double = 0
    private(set) var lastZone: Zone?

    var isShown: Bool { phase == .shown || phase == .leaving }

    func pointerMoved(to point: CGPoint) {
        pointerEvents += 1
        lastPoint = point
        evaluate()
    }

    /// Hides the card at once and stops any pending reveal.
    func dismiss() {
        cancelTimer()
        if isShown { suppressed = true }
        if let point = lastPoint, phase == .pending, zone(at: point, held: true) != nil { suppressed = true }
        setPhase(.idle)
    }

    /// Forgets the pointer (the sidebar became anchored, the window closed).
    func reset() {
        cancelTimer()
        lastPoint = nil
        suppressed = false
        setPhase(.idle)
    }

    private func evaluate() {
        guard isEnabled() else { cancelTimer(); setPhase(.idle); return }
        guard let point = lastPoint else { return }
        switch phase {
        case .idle:
            guard let zone = zone(at: point, held: false) else { suppressed = false; return }
            guard !suppressed else { return }
            lastZone = zone
            pendingSince = CACurrentMediaTime()
            setPhase(.pending)
            schedule(after: zone == .outerEdge ? RevealMetrics.outerEdgeDwell : RevealMetrics.dwell)
        case .pending:
            if zone(at: point, held: true) == nil { cancelTimer(); setPhase(.idle) }
        case .shown:
            if zone(at: point, held: true) == nil { setPhase(.leaving); schedule(after: RevealMetrics.exitDelay) }
        case .leaving:
            if zone(at: point, held: true) != nil { cancelTimer(); setPhase(.shown) }
        }
    }

    private func timerFired() {
        guard isEnabled(), let point = lastPoint else { setPhase(.idle); return }
        switch phase {
        case .pending:
            guard let zone = zone(at: point, held: true) else { setPhase(.idle); return }
            lastZone = zone
            lastDwell = CACurrentMediaTime() - pendingSince
            setPhase(.shown)
        case .leaving:
            if zone(at: point, held: true) != nil { setPhase(.shown) } else { setPhase(.idle) }
        case .idle, .shown:
            break
        }
    }

    private func setPhase(_ next: Phase) {
        let wasShown = isShown
        phase = next
        if isShown != wasShown {
            if isShown { shows += 1 } else { hides += 1 }
            onChange?(isShown)
        }
    }

    private func schedule(after delay: Double) {
        cancelTimer()
        let generation = timerGeneration
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.timerGeneration == generation else { return }
            self.timer = nil
            self.timerFired()
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        timer?.cancel()
        timer = nil
    }

    /// The zone under `point`. `held` widens the edge zones (the pointer is already pending
    /// or the card shows) and adds the card itself.
    func zone(at point: CGPoint, held: Bool) -> Zone? {
        let g = geometry()
        let b = g.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let inWindow = b.contains(point)
        let rows = point.y >= b.minY && point.y <= b.maxY
        if held && g.card.contains(point) { return .card }
        let inner = held || !inWindow ? RevealMetrics.innerEdgeHeldRange : 0...RevealMetrics.innerEdgeWidth
        if rows && point.x >= inner.lowerBound && point.x < inner.upperBound { return .innerEdge }
        let outer = held || inWindow ? RevealMetrics.outerEdgeHeld : RevealMetrics.outerEdgeApproach
        if rows && point.x < b.minX && point.x >= b.minX - outer { return .outerEdge }
        let top = RevealMetrics.topLeftRange
        if point.x >= b.minX && point.x < b.minX + RevealMetrics.topLeftWidth && point.y >= top.lowerBound && point.y < top.upperBound { return .topLeft }
        if g.trafficLights.contains(point) { return .trafficLights }
        return nil
    }
}
