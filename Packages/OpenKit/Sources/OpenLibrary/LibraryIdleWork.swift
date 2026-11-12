import AppKit

/// One row per turn bounds cold native raster work as well as configuration.
/// Sleeping lets AppKit service input and finish the preceding transaction;
/// Task.yield alone can keep draining the main executor in the same turn.
@MainActor
enum LibraryIdleWork {
    static var notBefore = 0.0
    static var lastInput = ProcessInfo.processInfo.systemUptime
    static var intervals: [[String:Double]] = []
    private static let tracePhases = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LIBRARY_PREPARATION_TRACE"] == "1"
    private static var detail: [String:Double]?
    static func record(_ name:String,milliseconds:Double) {
        guard detail != nil else { return }
        detail![name,default:0] += milliseconds
        detail![name+".count",default:0] += 1
    }
    static func measure<T>(_ name:String,_ body: () -> T) -> T {
        guard detail != nil else { return body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            record(name,milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        return body()
    }
    static func row(_ index:Int,kind:String,operation:Int) {
        guard detail != nil else { return }
        detail!["row.index"] = Double(index)
        detail!["row.type"] = Double((["download","archive","history","capture","boost","boostGallery","heading"].firstIndex(of:kind) ?? -1)+1)
        detail!["row.operation"] = Double(operation)
    }
    static func realizedRow(_ index:Int) {
        guard detail != nil else { return }
        detail!["row.index"] = Double(index)
        detail!["row.operation"] = 3
    }
    static func noteInput() { lastInput = ProcessInfo.processInfo.systemUptime }
    static func perform(rowKind:Int = 0, phase:Int = 0, firstUse:Bool = false,
        flush:Bool = true, _ body: () -> Void) async -> Bool {
        let delay = max(0.008,max(notBefore,lastInput+0.5)-ProcessInfo.processInfo.systemUptime)
        do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
        guard !Task.isCancelled else { return false }
        let input: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel]
        guard NSApp.nextEvent(matching: input, until: .distantPast,
            inMode: .default, dequeue: false) == nil else { return false }
        let start = ProcessInfo.processInfo.systemUptime
        if tracePhases { detail = [:] }
        measure("body",body)
        if flush { measure("flush") { CATransaction.flush() } }
        let milliseconds = (ProcessInfo.processInfo.systemUptime-start)*1000
        var interval = detail ?? [:]; detail = nil
        interval.merge(["startUptime":start,"endUptime":ProcessInfo.processInfo.systemUptime,
            "milliseconds":milliseconds,"rowKind":Double(rowKind),
            "phase":Double(phase),"firstUse":firstUse ? 1 : 0]) { _,new in new }
        intervals.append(interval)
        if intervals.count > 2048 { intervals.removeFirst(1024) }
        LibraryRaster.events["idleSlice"] = (LibraryRaster.events["idleSlice"] ?? 0)+1
        LibraryRaster.events["idleSliceMaximumMilliseconds"] = max(
            LibraryRaster.events["idleSliceMaximumMilliseconds"] ?? 0,milliseconds)
        return true
    }
}
