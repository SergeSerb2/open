import AppKit

/// Split row construction and raster work before attaching prepared cells.
/// Sleeping lets AppKit service input and finish the preceding transaction;
/// Task.yield alone can keep draining the main executor in the same turn.
@MainActor
enum LibraryIdleWork {
    static var notBefore = 0.0
    static var lastInput = ProcessInfo.processInfo.systemUptime
    static var intervals: [[String:Double]] = []
    private static let tracePhases = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LIBRARY_PREPARATION_TRACE"] == "1"
    private static var detail: [String:Double]?
    private static var sliceStarted = 0.0
    // Reserve time below the 8.3ms ceiling for transaction submission and
    // scheduling variation. A text raster gets its own turn when necessary.
    private static let bodyBudgetMilliseconds = 6.0
    private static var textRasterEstimate = 5.0
    private static var layerEstimate = 0.5
    static func canBegin(estimatedMilliseconds:Double) -> Bool {
        (ProcessInfo.processInfo.systemUptime-sliceStarted)*1000+estimatedMilliseconds <= bodyBudgetMilliseconds
    }
    static func record(_ name:String,milliseconds:Double) {
        guard detail != nil else { return }
        detail![name,default:0] += milliseconds
        detail![name+".count",default:0] += 1
        detail![name+".maximum"] = max(detail![name+".maximum"] ?? 0,milliseconds)
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
    /// An unattached cell cannot submit all dirty text layers implicitly at
    /// once. Finish each layer, checking the next body's estimate, then attach.
    static func prepareLayers(of view:NSView,scale:CGFloat,row:Int,operation:Int,isCurrent:() -> Bool) async -> Bool {
        var layers:[CALayer] = []
        func collect(_ layer:CALayer) {
            layers.append(layer)
            for child in layer.sublayers ?? [] { collect(child) }
        }
        if let layer = view.layer { collect(layer) }
        for layer in layers where layer is LibraryTextLayer { layer.contentsScale = scale }
        var index = 0
        while index < layers.count {
            guard isCurrent(),!Task.isCancelled else { return false }
            let completed = await perform {
                guard isCurrent() else { return }
                realizedRow(row)
                if detail != nil { detail!["row.operation"] = Double(operation) }
                while index < layers.count {
                    let layer = layers[index],text = layer is LibraryTextLayer
                    let estimate = text ? textRasterEstimate : layerEstimate
                    guard canBegin(estimatedMilliseconds:estimate) else { break }
                    let start = ProcessInfo.processInfo.systemUptime
                    measure("layer.display") { layer.displayIfNeeded() }
                    let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                    // A single unexpectedly expensive raster is never used to
                    // justify putting another body in this turn.
                    if text { textRasterEstimate = max(textRasterEstimate,min(5.5,elapsed)) }
                    else { layerEstimate = max(layerEstimate,min(5.5,elapsed)) }
                    index += 1
                }
            }
            guard completed else { return false }
        }
        return true
    }
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
        sliceStarted = start
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
