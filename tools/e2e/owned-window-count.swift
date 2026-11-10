import CoreGraphics
import Foundation
import QuartzCore

/// Read only window numbers for the supplied owned PIDs. Never read titles,
/// pixels, or another process's UI. This is the suite's final cleanup receipt.
@main
struct OwnedWindowCount {
    static func main() throws {
        let pids = Set(CommandLine.arguments.dropFirst().compactMap(Int32.init))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw NSError(domain: "OpenE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate owned on-screen windows"])
        }
        let owned = windows.compactMap { window -> [String: Int]? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let number = window[kCGWindowNumber as String] as? Int else { return nil }
            return ["pid": Int(pid), "number": number]
        }
        let data = try JSONSerialization.data(withJSONObject: ["count": owned.count, "windows": owned, "hostTime": CACurrentMediaTime()], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
