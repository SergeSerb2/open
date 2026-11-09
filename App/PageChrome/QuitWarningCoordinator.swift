import AppKit
import CoreServices
import OpenModel

/// Open-authored copy (a guess), not a proved Arc warning. Created only on quit.
@MainActor
final class QuitWarningCoordinator {
  private var approved = false
  private var presenting = false
  private var systemQuit = false
  private(set) var withoutPrompts = false
  #if OPEN_AUTOMATION
  var harnessQuit = false
  var buttonForAutomation: String?
  private(set) var alerts: [[String: Any]] = []
  #endif

  func updateQuitReason(relaunch: Bool) {
    // Retain the reason across the async history/sleep shutdown retries.
    let reason = NSAppleEventManager.shared().currentAppleEvent?
      .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    if let reason, [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown].contains(reason) {
      systemQuit = true
    }
    withoutPrompts = systemQuit || relaunch
    #if OPEN_AUTOMATION
    if AutomationOwnerWatch.quittingWithoutPrompts { withoutPrompts = true }
    #endif
  }

  func resetApproval() {
    approved = false
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
    let models = [app.model!] + app.hostFactories.values.map(\.model)
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
    approved = alert.runModal() == .alertFirstButtonReturn
    return !approved
  }
}
