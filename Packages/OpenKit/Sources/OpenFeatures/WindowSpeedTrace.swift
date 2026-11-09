import Foundation
import Darwin
import os.signpost

/// Opt-in, fixed-count constructor probes. No timer or recurring draw probe.
enum WindowSpeedTrace {
    private static let enabled = ProcessInfo.processInfo.environment["OPEN_SPEED_TRACE"] == "1"
    private static let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "SpeedTrace")
    static func mark(_ name: String) {
        guard enabled else { return }
        let ticks = mach_continuous_time()
        os_signpost(.event, log: log, name: "WindowPhase", "%{public}@", name as NSString)
        FileHandle.standardError.write(Data("OpenSpeed window \(name) \(ticks)\n".utf8))
    }
}
