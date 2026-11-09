import AppKit
import CoreServices
import OpenModel

/// Open-authored copy (a guess), not a proved Arc warning. Created only on quit.
@MainActor
final class QuitWarningCoordinator {
  private var approved = false
  private(set) var presenting = false
  private var systemQuit = false
  private var relaunchQuit = false
  /// Set when this quit attempt returned `.terminateCancel` only to retry itself (history flush,
  /// sleep capture, page beforeunload replies). The retry keeps the attempt's approval and
  /// reasons; any other entry starts a fresh attempt.
  private(set) var retryPending = false
  private(set) var withoutPrompts = false
  #if OPEN_AUTOMATION
  var harnessQuit = false
  var buttonForAutomation: String?
  private(set) var alerts: [[String: Any]] = []
  #endif

  /// Starts or continues a quit attempt. Returns true for a fresh attempt.
  @discardableResult
  func beginAttempt(relaunch: Bool) -> Bool {
    let fresh = !retryPending
    retryPending = false
    if fresh {
      // A logout another app aborted, or an install quit that was not retried, must not
      // leave later quits prompt-free.
      approved = false; systemQuit = false; relaunchQuit = relaunch
    }
    // Retain the reason across the async history/sleep shutdown retries, which have no
    // Apple event of their own.
    let reason = NSAppleEventManager.shared().currentAppleEvent?
      .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    if let reason, [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown].contains(reason) {
      systemQuit = true
    }
    withoutPrompts = systemQuit || relaunchQuit
    #if OPEN_AUTOMATION
    if AutomationOwnerWatch.quittingWithoutPrompts { withoutPrompts = true }
    #endif
    return fresh
  }

  /// The attempt cancelled itself only to run async work and ask again.
  func markRetryPending() { retryPending = true }

  /// The user or a page ended the attempt (an alert's Cancel, a beforeunload "Stay").
  func resetApproval() {
    approved = false; retryPending = false
    #if OPEN_AUTOMATION
    harnessQuit = false
    #endif
  }

  func shouldKeepBrowsing(app: AppDelegate, downloadsWarned: Bool) -> Bool {
    guard !presenting else { return true }
    #if OPEN_AUTOMATION
    if harnessQuit { return false }
    #endif
    guard !withoutPrompts, !approved else { return false }
    // Downloads own this attempt, even after their accepted alert cancels transfers.
    if downloadsWarned { approved = true; return false }
    guard UserDefaults.standard.bool(forKey: "open.general.warnBeforeQuitting") else { return false }
    presenting = true
    defer { presenting = false }
    let models = (app.model.map { [$0] } ?? []) + app.hostFactories.values.map(\.model)
    let tabs = Set(models.flatMap { $0.index.values.compactMap { $0.tab?.id } })
      .union(app.littleOpenHosts.keys).count
    let windows = app.windowControllers.count + (app.littleOpenCoordinator?.sessions.count ?? 0)
    let alert = NSAlert()
    alert.messageText = "Quit Open?"
    alert.informativeText = "You have \(windows) open \(windows == 1 ? "window" : "windows") and \(tabs) \(tabs == 1 ? "tab" : "tabs")."
    alert.addButton(withTitle: "Quit").keyEquivalent = "\r"
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    #if OPEN_AUTOMATION
    AppDelegate.commandLog("generic-quit-alert-presented")
    if alerts.count >= 64 { alerts.removeFirst() }
    alerts.append(["title": alert.messageText, "body": alert.informativeText,
      "windows": windows, "tabs": tabs, "buttons": alert.buttons.map(\.title),
      "keys": alert.buttons.map(\.keyEquivalent)])
    var observer: (any NSObjectProtocol)?
    if let buttonForAutomation {
      observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
        object: alert.window, queue: .main) { _ in
        MainActor.assumeIsolated {
          RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { alert.buttons[buttonForAutomation == "quit" ? 0 : 1].performClick(nil) }
          }
        }
      }
    }
    defer { if let observer { NotificationCenter.default.removeObserver(observer) } }
    #endif
    // Quit from the Dock or a script can arrive while Open is in the background.
    NSApp.activate()
    approved = alert.runModal() == .alertFirstButtonReturn
    return !approved
  }
}
