import OpenSettings

@MainActor
final class AppFirstRunActions: FirstRunActions {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }
  var canImportPasswordsAndCookies: Bool { false }
  func runImport(plan: ImportPlan) async -> ImportOutcome { await app.importRunner.run(plan: plan, firstRun: true) }
  func installImportedExtension(_ candidate: ImportExtensionCandidate) async -> ImportExtensionInstallResult {
    await app.importRunner.installExtension(candidate, window: app.firstRunWindowController?.window)
  }
  func setAsDefaultBrowser() -> String? { app.settingsPresenter.setAsDefaultBrowser() }
  func isDefaultBrowser() -> Bool { app.settingsPresenter.isDefaultBrowser() }
  func finishFirstRun(imported: Bool) { app.finishFirstRun(imported: imported) }
}
