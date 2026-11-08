import OpenSettings
import Foundation

@MainActor
final class AppFirstRunActions: FirstRunActions {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }
  var canImportPasswordsAndCookies: Bool { false }
  func runImport(plan: ImportPlan) async -> ImportOutcome { await app.importRunner.run(plan: plan, firstRun: true) }
  func installImportedExtension(_ candidate: ImportExtensionCandidate) async -> ImportExtensionInstallResult {
    await app.importRunner.installExtension(candidate, window: app.firstRunWindowController?.window)
  }
  #if OPEN_AUTOMATION
  private var stubDefault = false
  #endif
  func setAsDefaultBrowser() -> String? {
    #if OPEN_AUTOMATION
    if app.options.automationSocket != nil {
      let result = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_DEFAULT_BROWSER"] ?? "declined"
      stubDefault = result == "success" || result == "already"
      return result == "failed" ? "Automation default-browser failure" : nil
    }
    #endif
    return app.settingsPresenter.setAsDefaultBrowser()
  }
  func waitForDefaultBrowserRequest() async {
    #if OPEN_AUTOMATION
    if app.options.automationSocket != nil {
      let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_DEFAULT_BROWSER_DELAY_MS"] ?? "0"
      let delay = min(5_000, max(0, Int(raw) ?? 0))
      try? await Task.sleep(for: .milliseconds(delay))
      return
    }
    #endif
    await app.settingsPresenter.defaultBrowserRequest?.value
  }
  func isDefaultBrowser() -> Bool {
    #if OPEN_AUTOMATION
    if app.options.automationSocket != nil { return stubDefault || ProcessInfo.processInfo.environment["OPEN_AUTOMATION_DEFAULT_BROWSER"] == "already" }
    #endif
    return app.settingsPresenter.isDefaultBrowser()
  }
  func finishFirstRun(imported: Bool) { app.finishFirstRun(imported: imported) }
}
