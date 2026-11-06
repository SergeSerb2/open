#if OPEN_AUTOMATION
import AppKit
import Darwin

/// LaunchServices reparents the app to launchd. Keep the runner's lifetime
/// contract explicitly, without polling or any work while the runner is idle.
@MainActor
enum AutomationOwnerWatch {
  private static var source: (any DispatchSourceProcess)?
  private(set) static var quittingWithoutPrompts = false

  static func install() {
    guard let raw = ProcessInfo.processInfo.environment["OPEN_E2E_OWNER_PID"] else { return }
    guard let pid = pid_t(raw), pid > 0 else { exit(0) }
    // Before data preparation there is nothing to flush or close.
    guard kill(pid, 0) == 0 || errno == EPERM else { exit(0) }
    let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source = watch
    watch.setEventHandler {
      MainActor.assumeIsolated { ownerExited(pid) }
    }
    watch.resume()
    // Cover death between the existence check and registration.
    if kill(pid, 0) != 0 && errno == ESRCH { ownerExited(pid) }
  }

  private static func ownerExited(_ pid: pid_t) {
    guard !quittingWithoutPrompts else { return }
    quittingWithoutPrompts = true
    source?.cancel()
    source = nil
    FileHandle.standardError.write(Data("Open: e2e owner \(pid) exited; quitting\n".utf8))
    // A stalled main queue must not defeat the bound. This is scheduled only
    // on owner death; normal quit still flushes stores and closes the engine.
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
    NSApp.terminate(nil)
  }
}
#endif
