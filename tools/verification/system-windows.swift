// Read-only CoreGraphics inventory. Never sends Apple events or answers a dialog.
import Foundation
import CoreGraphics

guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
      !windows.isEmpty, windows.count <= 8192 else {
    fputs("Cannot read bounded window inventory\n", stderr)
    exit(1)
}
let owners: Set<String> = ["UserNotificationCenter", "ReportCrash", "Problem Reporter",
    "CrashReporter", "universalAccessAuthWarn", "SecurityAgent", "authorizationhost"]
var result: [[String: Any]] = []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let title = window[kCGWindowName as String] as? String ?? ""
    guard owner.utf8.count <= 1024, title.utf8.count <= 4096 else { exit(1) }
    if owners.contains(owner) || title.range(of: "quit unexpectedly|Screen Recording|Accessibility Access|Allow.*access", options: .regularExpression) != nil {
        result.append(["owner": owner, "pid": window[kCGWindowOwnerPID as String] as? Int ?? -1])
    }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
