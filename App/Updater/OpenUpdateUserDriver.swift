import AppKit
import Sparkle
import OpenFeatures
import OpenSidebar

/// One event-driven driver. Sparkle and its reply blocks never leave the App.
@MainActor
final class OpenUpdateUserDriver: NSObject, SPUUserDriver {
  private unowned let app: AppDelegate
  private(set) var status: UpdateWindowController?
  private(set) var updateWindow: UpdateWindowController?
  private(set) var alert: NSAlert?
  private(set) var phase = "idle"
  var userInitiated = false
  private var cancel: (() -> Void)?
  private var choice: ((SPUUserUpdateChoice) -> Void)?
  private var readyReply: ((SPUUserUpdateChoice) -> Void)?
  private var installOnQuit: (() -> Void)?
  private var acknowledgement: (() -> Void)?
  private var received: UInt64 = 0
  private var expected: UInt64 = 0
  private var errorShown = false
  private var availableDismissed = false
  private var summaryPending = false
  private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  var available = false

  init(app: AppDelegate) {
    self.app = app; super.init()
    let defaults = UserDefaults.standard
    if let previous = defaults.string(forKey: "open.updates.lastInstalledBuild"),
      build.compare(previous, options: .numeric) == .orderedDescending,
      defaults.string(forKey: "open.updates.summaryShownBuild") != build { summaryPending = true }
    defaults.set(build, forKey: "open.updates.lastInstalledBuild")
    for controller in app.windowControllers { attach(controller) }
  }

  func attach(_ controller: BrowserWindowController) {
    controller.sidebar.onUpdateBannerAction = { [weak self, weak controller] in self?.bannerAction(on: controller?.window) }
    controller.sidebar.onUpdateBannerDismiss = { [weak self] in self?.dismissBanner() }
    controller.sidebar.updateBannerState = bannerState
  }
  var bannerState: UpdateBannerState? {
    if ((readyReply != nil && !userInitiated) || installOnQuit != nil), !availableDismissed { return .available }
    return summaryPending ? .summary : nil
  }
  private func refreshBanners() {
    for controller in app.windowControllers { controller.sidebar.updateBannerState = bannerState }
  }
  private func dismissBanner() {
    if bannerState == .available {
      availableDismissed = true
      if !(UserDefaults.standard.object(forKey: UpdaterController.automaticKey) as? Bool ?? true) {
        let defaults = UserDefaults.standard
        defaults.set(min(defaults.integer(forKey: "open.updates.bannerDismissalCount"), Int.max - 1) + 1,
          forKey: "open.updates.bannerDismissalCount")
      }
    } else if bannerState == .summary {
      summaryPending = false; UserDefaults.standard.set(build, forKey: "open.updates.summaryShownBuild")
    }
    refreshBanners()
  }
  private func bannerAction(on window: NSWindow?) {
    if bannerState == .summary {
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
      let template = Bundle.main.object(forInfoDictionaryKey: "OpenReleaseNotesURLTemplate") as? String
        ?? "https://github.com/SergeSerb2/open/releases/tag/v{version}"
      if let url = URL(string: template.replacingOccurrences(of: "{version}", with: version)) { open(url) }
      dismissBanner(); return
    }
    guard bannerState == .available, alert == nil, let window else { return }
    let alert = NSAlert(); alert.messageText = "Open is ready to update!"; alert.informativeText = "Restart required."
    alert.addButton(withTitle: "Restart"); alert.addButton(withTitle: "Cancel")
    self.alert = alert
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }; self.alert = nil
      if response == .alertFirstButtonReturn {
        let reply = self.readyReply; self.readyReply = nil
        if let reply { reply(.install) } else { self.installOnQuit?() }
      } else { self.toast(.cancelledInstall) }
    }
  }
  func open(_ url: URL) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let controller = app.frontStandardWindowController ?? app.makeWindow(),
      let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true)
    _ = factory.openNewTab(url: url, background: false)
  }
  enum Toast: String {
    case failedToDownloadUpdate, updateAlreadyInProgress, failedToInstall, cancelledInstall, newUpdatePending
    var copy: String {
      switch self {
      case .failedToDownloadUpdate: "Something went wrong downloading the update to Open.\nWe’ll try again later…"
      case .updateAlreadyInProgress: "Update in progress. Hang tight!"
      case .failedToInstall: "Something went wrong installing a new update.\nWe’ll try again later…"
      case .cancelledInstall: "Restart at a later time to finish installing the new update!"
      case .newUpdatePending: "A new update is pending! It will be ready soon"
      }
    }
  }
  private(set) var lastToast: String?
  func toast(_ kind: Toast) {
    lastToast = kind.rawValue
    let lines = kind.copy.split(separator: "\n", maxSplits: 1).map(String.init)
    app.frontWindowController?.toasts.show(ToastContent(title: lines[0], subtitle: lines.count > 1 ? lines[1] : nil))
  }
  func beginUserCheck() { userInitiated = true; errorShown = false; phase = "checking" }
  func beginBackgroundCheck() { userInitiated = false; errorShown = false; phase = "checking" }
  func backgroundDownloading() { if !userInitiated { phase = "downloading" } }
  func backgroundPreparing() { if !userInitiated { phase = "extracting" } }
  func backgroundError(_ error: any Error) {
    guard !userInitiated, !errorShown else { return }
    let error = error as NSError
    if error.domain == SUSparkleErrorDomain,
      [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
        .contains(where: { Int($0.rawValue) == error.code }) { return }
    errorShown = true
    toast(["extracting", "ready", "installing"].contains(phase) ? .failedToInstall : .failedToDownloadUpdate)
  }
  func readyOnQuit(_ install: @escaping () -> Void) {
    installOnQuit = install; available = true; phase = "ready"; refreshBanners()
  }
  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    let enabled = UserDefaults.standard.object(forKey: UpdaterController.automaticKey) as? Bool ?? true
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: enabled, automaticUpdateDownloading: NSNumber(value: enabled), sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    beginUserCheck(); cancel = cancellation
    showStatus("Checking for updates...", button: "Cancel", progress: nil)
  }
  private func showStatus(_ label: String, button: String, progress: Double?, enabled: Bool = true, hidden: Bool = false) {
    if status == nil { status = UpdateWindowController(title: "Open Update Status", status: true) }
    guard let status else { return }
    status.column.prompt.stringValue = label
    status.column.primary.title = button; status.column.primary.isEnabled = enabled; status.column.primary.isHidden = hidden
    status.column.primary.keyEquivalent = phase == "ready" ? "\r" : ""
    status.column.primary.bezelColor = phase == "ready" ? .controlAccentColor : nil
    status.column.progress.isHidden = false
    status.column.progress.isIndeterminate = progress == nil
    if let progress { status.column.progress.stopAnimation(nil); status.column.progress.doubleValue = min(1, max(0, progress)) }
    else { status.column.progress.startAnimation(nil) }
    status.onPrimary = { [weak self] in self?.statusAction() }
    status.allowsClose = enabled && !hidden
    status.onClose = { [weak self] in
      guard let self else { return }
      if self.phase == "ready" {
        let reply = self.readyReply; self.readyReply = nil; self.closeStatus(); reply?(.dismiss)
      } else { self.statusAction() }
    }
    status.column.needsLayout = true; status.show()
  }
  private func statusAction() {
    if phase == "ready" { let reply = readyReply; readyReply = nil; reply?(.install) }
    else if let cancel { self.cancel = nil; closeStatus(); cancel() }
  }
  private func closeStatus() { status?.closeSilently(); status = nil }
  private func closeUpdateWindow() { updateWindow?.closeSilently(); updateWindow = nil }
  private func acknowledge() {
    let reply = acknowledgement; acknowledgement = nil
    closeUpdateWindow(); reply?()
  }
  func dismissUserInitiatedUpdateCheck() { closeStatus(); cancel = nil }
  func showUpdateInFocus() {
    if let alert { alert.window.makeKeyAndOrderFront(nil) }
    else if let updateWindow { updateWindow.show() }
    else if let status { status.show() }
    else if !userInitiated, phase == "downloading" { toast(.newUpdatePending) }
    else if !userInitiated, phase == "extracting" || phase == "installing" { toast(.updateAlreadyInProgress) }
  }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    closeStatus(); cancel = nil; closeUpdateWindow()
    userInitiated = state.userInitiated; choice = reply; available = true; phase = "found"
    let minimum = appcastItem.minimumAutoupdateVersion.map { build.compare($0, options: .numeric) == .orderedAscending } ?? false
    let required = appcastItem.isCriticalUpdate || (!appcastItem.isInformationOnlyUpdate && minimum)
    let window = UpdateWindowController(title: "Open Update", closable: !required)
    window.allowsClose = !required
    updateWindow = window
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    window.column.version.stringValue = "Version \(installed) (\(build))"
    window.column.prompt.stringValue = "You have v\(installed) (\(build)).\nWould you like to download\n v\(UpdateReleaseNotesView.boundedUTF8(appcastItem.displayVersionString, limit: 128)) (\(UpdateReleaseNotesView.boundedUTF8(appcastItem.versionString, limit: 128))) now?"
    window.column.primary.title = state.stage == .notDownloaded || appcastItem.isInformationOnlyUpdate ? "Download" : "Install and Relaunch"
    window.column.primary.keyEquivalent = "\r"; window.column.primary.bezelColor = .controlAccentColor
    window.column.secondary.title = "Remind me Later"; window.column.secondary.isHidden = required
    window.onPrimary = { [weak self] in
      guard let self else { return }
      if appcastItem.isInformationOnlyUpdate { if let url = appcastItem.infoURL { self.open(url) }; self.answer(.dismiss) }
      else { self.answer(.install) }
    }
    if !required {
      window.onSecondary = { [weak self] in self?.answer(.dismiss) }
      window.onClose = { [weak self] in self?.answer(.dismiss) }
    }
    if !(appcastItem.itemDescription ?? "").isEmpty || appcastItem.releaseNotesURL != nil {
      window.addNotes(title: appcastItem.title ?? "", source: appcastItem.itemDescription ?? "",
        format: appcastItem.itemDescriptionFormat ?? "markdown", openLink: { [weak self] in self?.open($0) })
    }
    window.show()
  }
  private func answer(_ value: SPUUserUpdateChoice) {
    let reply = choice; choice = nil; closeUpdateWindow(); reply?(value)
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    let source = String(decoding: downloadData.data.prefix(UpdateReleaseNotesView.inputLimit), as: UTF8.self)
    let format = downloadData.mimeType?.lowercased().contains("html") == true ? "html" : "markdown"
    updateWindow?.notes?.setNotes(source, format: format)
  }
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { updateWindow?.notes?.setNotes("", format: "markdown") }
  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    closeStatus(); closeUpdateWindow(); cancel = nil; available = false; phase = "upToDate"
    let window = UpdateWindowController(title: "Open Update")
    updateWindow = window; window.column.prompt.stringValue = "Your browser is up to date"
    window.column.primary.title = "Close"; window.column.primary.keyEquivalent = "\r"
    self.acknowledgement = acknowledgement
    let close: () -> Void = { [weak self] in self?.acknowledge() }
    window.onPrimary = close; window.onClose = close; window.show()
  }
  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    closeStatus(); closeUpdateWindow(); cancel = nil
    if !userInitiated { backgroundError(error); acknowledgement(); return }
    errorShown = true
    let alert = NSAlert(); alert.messageText = "Update error!"; alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Download manually"); self.alert = alert
    guard let parent = app.frontWindowController?.window else { self.alert = nil; acknowledgement(); return }
    alert.beginSheetModal(for: parent) { [weak self] response in
      guard let self else { acknowledgement(); return }; self.alert = nil
      if response == .alertSecondButtonReturn,
        let url = URL(string: Bundle.main.object(forInfoDictionaryKey: "OpenUpdateDownloadPageURL") as? String ?? "https://github.com/SergeSerb2/open/releases/latest") { self.open(url) }
      acknowledgement()
    }
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    phase = "downloading"; cancel = cancellation; received = 0; expected = 0
    showStatus("\(bytes(received)) of \(bytes(expected))", button: "Cancel", progress: 0)
  }
  private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength; downloadProgress() }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    let (sum, overflow) = received.addingReportingOverflow(length); received = overflow ? UInt64.max : sum; downloadProgress()
  }
  private func downloadProgress() {
    status?.column.prompt.stringValue = "\(bytes(received)) of \(bytes(expected))"
    status?.column.progress.doubleValue = expected > 0 ? min(1, Double(received) / Double(expected)) : 0
  }
  func showDownloadDidStartExtractingUpdate() {
    phase = "extracting"; cancel = nil
    showStatus("Preparing…", button: "Cancel", progress: nil, enabled: false)
  }
  func showExtractionReceivedProgress(_ progress: Double) {
    status?.column.progress.isIndeterminate = false; status?.column.progress.stopAnimation(nil)
    status?.column.progress.doubleValue = progress.isFinite ? min(1, max(0, progress)) : 0
  }
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    phase = "ready"; readyReply = reply; cancel = nil
    if userInitiated { showStatus("Ready to Install", button: "Install and Relaunch", progress: 1); NSApp.requestUserAttention(.informationalRequest) }
    else { closeStatus(); refreshBanners() }
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    phase = "installing"; cancel = nil; readyReply = nil
    showStatus("Installing update... ", button: "Cancel", progress: nil, enabled: false, hidden: true)
  }
  func showSendingTerminationSignal() { cancel = nil }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    available = false; dismissUpdateInstallation(); acknowledgement()
  }
  func dismissUpdateInstallation() {
    closeStatus(); closeUpdateWindow(); cancel = nil; choice = nil; readyReply = nil; installOnQuit = nil
    if let alert { if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }; alert.window.orderOut(nil) }
    alert = nil; phase = "idle"; refreshBanners()
  }

  #if OPEN_AUTOMATION
  var automationState: [String: Any] {
    ["phase": phase, "userInitiated": userInitiated, "available": available,
      "statusWindow": status?.window?.windowNumber ?? 0, "updateWindow": updateWindow?.window?.windowNumber ?? 0,
      "alertWindow": alert?.window.windowNumber ?? 0, "banner": bannerState?.rawValue ?? "",
      "received": received, "expected": expected, "progress": status?.column.progress.doubleValue ?? 0,
      "indeterminate": status?.column.progress.isIndeterminate ?? false,
      "statusText": status?.column.prompt.stringValue ?? "", "notes": updateWindow?.notes?.text.string ?? "",
      "lastToast": lastToast ?? "", "primary": (status ?? updateWindow)?.column.primary.title ?? ""]
  }
  func performAutomationAction(_ action: String) -> Bool {
    switch action {
    case "settings-help": app.settingsPresenter.settings.general.openUpdatesHelp()
    case "settings-check": app.settingsPresenter.settings.general.checkForUpdates()
    case "primary": (status ?? updateWindow)?.column.primary.performClick(nil)
    case "later":
      guard let window = updateWindow, !window.column.secondary.isHidden else { return false }
      window.column.secondary.performClick(nil)
    case "close": (status ?? updateWindow)?.window?.performClose(nil)
    case "banner": app.frontWindowController?.sidebar.updateBanner?.actionButton.performClick(nil)
    case "dismiss-banner": app.frontWindowController?.sidebar.updateBanner?.performDismiss()
    case "notes-link":
      guard let notes = updateWindow?.notes, let storage = notes.text.textStorage else { return false }
      var found: (Any, Int)?
      storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { link, range, stop in
        if let link { found = (link, range.location); stop.pointee = true }
      }
      guard let (link, index) = found else { return false }
      _ = notes.textView(notes.text, clickedOnLink: link, at: index)
    case "alert-first", "alert-second":
      guard let alert, alert.buttons.count >= 2 else { return false }
      alert.buttons[action == "alert-first" ? 0 : 1].performClick(nil)
    case "cleanup":
      // End the real Sparkle operation before releasing callback ownership.
      acknowledge()
      let cancellation = cancel; cancel = nil; cancellation?()
      let pendingChoice = choice; choice = nil; pendingChoice?(.skip)
      let ready = readyReply; readyReply = nil; ready?(.skip)
      dismissUpdateInstallation()
    default: return false
    }
    return true
  }
  #endif
}
