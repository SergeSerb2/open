import OpenSettings

@MainActor
final class AppFirstRunActions: FirstRunActions {
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }
  var canImportPasswordsAndCookies: Bool { app.importRunner.canImportPasswordsAndCookies }
  var hasUnfinishedSecretsImport: Bool { app.importRunner.hasUnfinishedSecretsImport }
  func runImport(plan: ImportPlan) async -> ImportOutcome { await app.importRunner.run(plan: plan, firstRun: true) }
  func setAsDefaultBrowser() -> String? { app.settingsPresenter.setAsDefaultBrowser() }
  func isDefaultBrowser() -> Bool { app.settingsPresenter.isDefaultBrowser() }
  func finishFirstRun(imported: Bool) { app.finishFirstRun(imported: imported) }
}
