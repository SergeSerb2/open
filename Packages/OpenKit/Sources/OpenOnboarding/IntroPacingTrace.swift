#if DEBUG || OPEN_AUTOMATION
import Foundation
import QuartzCore
import os.signpost

/// Opt-in automation evidence. Production builds contain no recorder, hooks or
/// run-loop observers. Names describe measured regions, not inferred causes.
@MainActor
public final class IntroPacingTrace {
    public static var current: IntroPacingTrace?
    private static let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "IntroPacing")
    private struct Span {
        let name: String
        let start: Double
        var end: Double?
        let id: OSSignpostID
    }
    public struct Region: Sendable {
        fileprivate let trace: IntroPacingTrace
        fileprivate let index: Int
        @MainActor public func end() { trace.end(index) }
    }
    private struct Stall {
        let start: Double
        let end: Double
        let callback: Double
        var regions: [String]?
        var overlapMS: [String: Double]?
    }
    // At most 16,384 small spans and 4,096 stalls (under 2 MiB of value
    // storage). No file, URL, title or other personal data enters the trace.
    private var spans: [Span] = []
    private var stalls: [Stall] = []
    private var overflow = false
    private var finished = false
    private var startHostTime: Double?
    private var endHostTime: Double?
    private var observers: [CFRunLoopObserver] = []
    private var sources: Region?
    private var commit: Region?
    private var engineTurn: Region?
    private var engineTurnsRemaining = 0

    public init() {
        spans.reserveCapacity(4096)
        stalls.reserveCapacity(128)
        observeRunLoop()
    }

    public static func begin(_ name: String) -> Region? { current?.beginRegion(name) }
    private func beginRegion(_ name: String) -> Region? {
        guard !finished else { return nil }
        guard spans.count < 16_384 else { overflow = true; return nil }
        let id = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "IntroMainThread", signpostID: id, "%{public}@", name as NSString)
        let index = spans.count
        spans.append(Span(name: name, start: CACurrentMediaTime(), id: id))
        return Region(trace: self, index: index)
    }
    private func end(_ index: Int) {
        guard spans.indices.contains(index), spans[index].end == nil else { return }
        spans[index].end = CACurrentMediaTime()
        os_signpost(.end, log: Self.log, name: "IntroMainThread", signpostID: spans[index].id)
    }

    public func start(at hostTime: Double) {
        guard startHostTime == nil else { return }
        startHostTime = hostTime
        endHostTime = hostTime + IntroTimeline.beat("measureFrames").end
    }

    private func observeRunLoop() {
        // AppKit and CEF use run-loop sources and before-waiting observers.
        // These broad regions distinguish otherwise unattributed native work.
        // The before-waiting span includes the implicit CA commit; only an
        // explicit commit hook can attribute time to CATransaction itself.
        installObserver([.afterWaiting, .beforeSources, .beforeWaiting, .exit], order: CFIndex.min) { trace, activity in
            if activity == .afterWaiting || activity == .beforeSources {
                if trace.sources == nil { trace.sources = trace.beginRegion("runloop.sources") }
                if trace.engineTurnsRemaining > 0, trace.engineTurn == nil {
                    trace.engineTurn = trace.beginRegion("engine.messageLoop.turn")
                    trace.engineTurnsRemaining -= 1
                }
            } else {
                trace.sources?.end(); trace.sources = nil
                trace.engineTurn?.end(); trace.engineTurn = nil
                if activity == .beforeWaiting { trace.commit = trace.beginRegion("runloop.beforeWaiting") }
                else { trace.commit?.end(); trace.commit = nil }
            }
        }
        installObserver(.beforeWaiting, order: CFIndex.max) { trace, _ in
            trace.commit?.end(); trace.commit = nil
        }
    }

    private func installObserver(_ activities: CFRunLoopActivity, order: CFIndex,
                                 action: @escaping @MainActor (IntroPacingTrace, CFRunLoopActivity) -> Void) {
        guard let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, order, { [weak self] _, activity in
            MainActor.assumeIsolated { if let self, !self.finished { action(self, activity) } }
        }) else { return }
        observers.append(observer)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    public func engineMessageLoopWillStart() { engineTurnsRemaining = 8 }

    /// Uses the exact display timestamps used by frameStats. Work is matched
    /// by overlap in host time, including regions that ended before delivery.
    public func recordInterval(start: Double, end: Double, nominal: Double, callback: Double) {
        guard !finished, end-start > 1.5*nominal else { return }
        guard stalls.count < 4096 else { overflow = true; return }
        stalls.append(Stall(start: start, end: end, callback: callback))
    }

    public func finish() {
        guard !finished else { return }
        for index in spans.indices where spans[index].end == nil { end(index) }
        finished = true
        observers.forEach { CFRunLoopObserverInvalidate($0) }; observers.removeAll()
        sources = nil; commit = nil; engineTurn = nil
    }

    public var state: [String: Any] {
        let origin = startHostTime ?? CACurrentMediaTime()
        let end = min(CACurrentMediaTime(), endHostTime ?? origin)
        func overlap(_ span: Span, _ low: Double, _ high: Double) -> Double {
            max(0, min(span.end ?? end, high)-max(span.start, low))
        }
        var totals: [String: Double] = [:]
        var preparation: [String: Double] = [:]
        for span in spans {
            let ms = overlap(span, origin, end)*1000
            if ms > 0 { totals[span.name, default: 0] += ms }
            let before = max(0, min(span.end ?? end, origin)-span.start)*1000
            if before > 0 { preparation[span.name, default: 0] += before }
        }
        // A later region cannot overlap an earlier interval. Resolve each
        // interval once so polling the automation state cannot repeatedly
        // scan all spans for all previous stalls inside the measured window.
        for index in stalls.indices where stalls[index].regions == nil {
            let stall = stalls[index]
            var times: [String: Double] = [:]
            for span in spans {
                let ms = overlap(span, stall.start, stall.end)*1000
                if ms > 0 { times[span.name, default: 0] += ms }
            }
            stalls[index].overlapMS = times
            stalls[index].regions = times.isEmpty ? ["unattributed"] : times.keys.sorted()
        }
        let rows: [[String: Any]] = stalls.map { stall in
            return ["start": stall.start-origin, "end": stall.end-origin, "ms": (stall.end-stall.start)*1000,
                    "regions": stall.regions ?? ["unattributed"], "regionOverlapMS": stall.overlapMS ?? [:],
                    "callbackDelayMS": max(0, stall.callback-stall.end)*1000]
        }
        return ["stalls": rows, "regionMainThreadMS": totals, "preparationMainThreadMS": preparation, "traceOverflow": overflow,
                "traceStartHostTime": startHostTime as Any? ?? NSNull(),
                "regionTotalsAreInclusive": true]
    }
}
#endif
