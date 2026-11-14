import Foundation
import Darwin
import QuartzCore
import os.signpost

/// Opt-in, fixed-count constructor probes. No timer or recurring draw probe.
enum WindowSpeedTrace {
    private static let enabled = ProcessInfo.processInfo.environment["OPEN_SPEED_TRACE"] == "1"
    private static let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "SpeedTrace")
    static func begin(_ name: String) -> (() -> Void)? {
        guard enabled else { return nil }
        let id = OSSignpostID(log: log)
        let start = CACurrentMediaTime()
        os_signpost(.begin, log: log, name: "WindowWork", signpostID: id, "%{public}@", name as NSString)
        return {
            let end = CACurrentMediaTime()
            os_signpost(.end, log: log, name: "WindowWork", signpostID: id)
            FileHandle.standardError.write(Data("OpenSpeed work \(name) \(start) \(end)\n".utf8))
        }
    }
    static func mark(_ name: String) {
        guard enabled else { return }
        let ticks = mach_continuous_time()
        os_signpost(.event, log: log, name: "WindowPhase", "%{public}@", name as NSString)
        FileHandle.standardError.write(Data("OpenSpeed window \(name) \(ticks)\n".utf8))
    }
}
