#if OPEN_AUTOMATION
import Foundation
import OpenEngine

/// Holds delivery of a real clear's success, never the engine operation itself.
/// One observed page, one continuation, and a ten-second automatic release.
@MainActor
enum PageSiteDataProbe {
  private static var observed: ObjectIdentifier?
  private static var held = false
  private static var continuation: CheckedContinuation<Void, Never>?
  private static var expiry: Task<Void, Never>?
  private static var starts = 0, completions = 0, refreshes = 0

  static func hold(_ page: OEWebContent) -> Bool {
    guard !held, continuation == nil else { return false }
    observed = ObjectIdentifier(page); held = true
    starts = 0; completions = 0; refreshes = 0
    expiry = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      release()
    }
    return true
  }

  static func release() {
    held = false; expiry?.cancel(); expiry = nil
    let pending = continuation; continuation = nil; pending?.resume()
  }
  static func began(_ key: ObjectIdentifier) { if key == observed { starts += 1 } }
  static func refreshed(_ key: ObjectIdentifier) { if key == observed { refreshes += 1 } }
  static func cleared(_ key: ObjectIdentifier) async {
    guard key == observed else { return }
    completions += 1
    if held, continuation == nil { await withCheckedContinuation { continuation = $0 } }
  }
  static var state: [String: Any] {
    ["held": held, "waiting": continuation != nil,
      "starts": starts, "completions": completions, "refreshes": refreshes]
  }
}

extension AutomationController {
  func runPageSiteDataProbe(_ args: [String: Any], page: () throws -> OEWebContent) throws -> Any {
    switch args["action"] as? String ?? "state" {
    case "hold":
      guard PageSiteDataProbe.hold(try page()) else { throw Failure(message: "site-data completion already held") }
    case "release": PageSiteDataProbe.release()
    case "state": break
    default: throw Failure(message: "unknown site-data probe action")
    }
    return PageSiteDataProbe.state
  }
}
#endif
