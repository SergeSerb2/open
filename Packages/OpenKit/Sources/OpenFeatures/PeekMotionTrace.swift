import AppKit
import os.signpost

/// Opt-in socket diagnostic. No observer exists until armed, and stop removes
/// every observer. Capture is bounded to 8,192 numeric records (under 1 MiB).
/// The observer orders bracket CA's implicit before-waiting commit, as in the
/// App's existing RunLoopTurnTrace. They measure that bracket, not GPU duration.
@MainActor
public enum PeekMotionTrace {
    private struct Record {
        let name: String
        let start: Double
        var end: Double
        let value: Double
    }
    private static let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "PeekMotion")
    private static var armed = false
    private static var records: [Record] = []
    private static var observers: [CFRunLoopObserver] = []
    private static var overflow = false
    private static var viewTokens: [NSObjectProtocol] = []
    private static var watchedViews: [(NSView, Bool)] = []

    public static func watch(_ view: NSView) {
        guard armed, watchedViews.count < 1024, !watchedViews.contains(where: { $0.0 === view }) else { return }
        watchedViews.append((view, view.postsFrameChangedNotifications))
        view.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated {
                guard let view else { return }
                mark("nativeFrame." + NSStringFromClass(type(of: view)), value: view.frame.width)
                mark("nativeHeight", value: view.frame.height)
            }
        }
        viewTokens.append(token)
        for child in view.subviews { watch(child) }
    }

    public static func arm() {
        stop(); records = []; records.reserveCapacity(8192); overflow = false; armed = true
        for (activity, order, name) in [
            (CFRunLoopActivity.afterWaiting, CFIndex.min, "main.wake"),
            (.beforeTimers, CFIndex.min, "main.timers"),
            (.beforeSources, CFIndex.min, "main.sources"),
            (.beforeWaiting, CFIndex.min, "main.beforeWaiting"),
            (.beforeWaiting, 1_999_999, "implicitCommit.before"),
            (.beforeWaiting, 2_000_001, "implicitCommit.after"),
            (.beforeWaiting, CFIndex.max, "main.sleep")
        ] {
            if let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order, { _, _ in
                MainActor.assumeIsolated { mark(name) }
            }) {
                observers.append(observer); CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
        }
        mark("trace.arm")
    }

    public static func stop() {
        if armed { mark("trace.stop") }
        armed = false
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        for token in viewTokens { NotificationCenter.default.removeObserver(token) }
        viewTokens.removeAll()
        for (view, original) in watchedViews { view.postsFrameChangedNotifications = original }
        watchedViews.removeAll()
    }

    public static func mark(_ name: String, value: Double = 0) {
        guard armed else { return }
        guard records.count < 8192 else { overflow = true; return }
        let now = CACurrentMediaTime()
        records.append(Record(name: name, start: now, end: now, value: value))
        os_signpost(.event, log: log, name: "PeekPhase", "%{public}@ t=%.9f value=%.3f", name as NSString, now, value)
    }

    public static func region<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard armed, records.count < 8192 else { return try body() }
        let index = records.count, start = CACurrentMediaTime()
        records.append(Record(name: name, start: start, end: start, value: 0))
        let id = OSSignpostID(UInt64(index + 1))
        os_signpost(.begin, log: log, name: "PeekRegion", signpostID: id, "%{public}@", name as NSString)
        defer {
            records[index].end = CACurrentMediaTime()
            os_signpost(.end, log: log, name: "PeekRegion", signpostID: id, "%{public}@", name as NSString)
        }
        return try body()
    }

    public static func json() -> [String: Any] {
        ["clock": "CACurrentMediaTime/mach_absolute_time seconds", "now": CACurrentMediaTime(),
         "armed": armed, "overflow": overflow,
         "records": records.map { ["name": $0.name, "start": $0.start, "end": $0.end, "value": $0.value] as [String: Any] }]
    }
}
