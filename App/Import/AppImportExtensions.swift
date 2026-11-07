import AppKit
import OpenEngine
import OpenSettings

/// One operation, retained until its completion. The prompt presenter remains
/// the manager's sole delegate; these hooks only observe this import install.
@MainActor
final class AppImportExtensionAttempt {
  let manager: OEExtensionManager
  let identifier: String
  weak var window: NSWindow?
  var cancelled = false
  #if OPEN_AUTOMATION
  var localFile: URL?
  var localCompletion: ((ImportExtensionInstallResult) -> Void)?
  #endif
  init(manager: OEExtensionManager, identifier: String, window: NSWindow) {
    self.manager = manager; self.identifier = identifier; self.window = window
  }
  func matches(_ manager: OEExtensionManager, _ identifier: String) -> Bool {
    self.manager === manager && self.identifier == identifier
  }
  func answered(_ accepted: Bool) {
    if !accepted { cancelled = true }
    #if OPEN_AUTOMATION
    if !accepted { completeLocal(.skipped("cancelled")) }
    #endif
  }
  #if OPEN_AUTOMATION
  func completeLocal(_ result: ImportExtensionInstallResult) {
    guard let completion = localCompletion else { return }; localCompletion = nil
    // Never release a context or advance the queue in a Chromium notification.
    Task { @MainActor in await Task.yield(); completion(result) }
  }
  #endif
}

extension AppImportRunner {
  func installExtension(_ candidate: ImportExtensionCandidate, window: NSWindow?) async -> ImportExtensionInstallResult {
    guard !installingExtension, !app.terminationRequested,
      lastOutcome?.extensions.contains(where: { $0.id == candidate.id }) == true,
      let window, window.isVisible else { return .failed("The import report is no longer available.") }
    installingExtension = true
    defer { installingExtension = false }
    guard candidate.extensionID.utf8.count == 32,
      candidate.extensionID.utf8.allSatisfy({ (97...112).contains($0) }) else { return .failed("Invalid extension ID.") }
    if app.firstRunWindowController?.window === window,
      !app.hostFactories.values.contains(where: { !$0.isIncognito }) { app.showFirstRunBrowser() }
    guard let factory = app.hostFactories.values.first(where: { !$0.isIncognito }),
      let context = factory.context(for: candidate.profileID) else { return .failed("The Profile is no longer available.") }
    let manager = context.extensions
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !manager.isReady && ContinuousClock.now < readyDeadline && !app.terminationRequested {
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return .skipped("cancelled") }
    }
    guard !app.terminationRequested, !Task.isCancelled, window.isVisible else { return .skipped("cancelled") }
    guard manager.isReady else { return .failed("Extension system is not ready") }
    if manager.extension(identifier: candidate.extensionID) != nil { return .skipped("already installed") }
    let attempt = AppImportExtensionAttempt(manager: manager, identifier: candidate.extensionID, window: window)
    extensionAttempt = attempt
    defer { extensionAttempt = nil }
    #if OPEN_AUTOMATION
    if let file = extensionFixtures[candidate.extensionID] {
      // An initiation failure belongs to the App. Once Chromium starts an
      // install, only its answer/event may complete it; consent has no deadline.
      guard FileManager.default.isReadableFile(atPath: file.path) else {
        return .failed("The local fixture file is missing or unreadable.")
      }
      // A fresh, hidden page in precisely the target context lets Chromium's
      // existing automation-only local installer run its real consent flow.
      let content = OEWebContent(configuration: OEWebContentConfiguration(context: context), url: URL(string: "about:blank"))
      let browser = OEBrowser(context: context); browser.window = window
      browser.insert(content, at: 0); browser.activeWebContent = content
      content.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
      content.view.isHidden = true; window.contentView?.addSubview(content.view)
      defer { content.view.removeFromSuperview(); content.close(); browser.close() }
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !content.isLive && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(25))
      }
      guard content.isLive else { return .failed("The fixture page did not become ready.") }
      attempt.localFile = file
      return await withCheckedContinuation { continuation in
        attempt.localCompletion = { continuation.resume(returning: $0) }
        if !manager.installLocalCRX(file, webContent: content) { attempt.completeLocal(.failed("The local fixture could not be installed.")) }
      }
    }
    #endif
    #if OPEN_AUTOMATION
    extensionWebStoreCompletion = nil
    #endif
    return await withCheckedContinuation { continuation in
      manager.install(fromWebStore: candidate.extensionID, window: window) { installed, error in
        Task { @MainActor in
          await Task.yield()
          #if OPEN_AUTOMATION
          self.extensionWebStoreCompletion = (installed, error)
          #endif
          manager.reload()
          if installed, manager.extension(identifier: candidate.extensionID) != nil { continuation.resume(returning: .installed) }
          else if attempt.cancelled { continuation.resume(returning: .skipped("cancelled")) }
          else { continuation.resume(returning: .failed(error ?? "The extension could not be installed.")) }
        }
      }
    }
  }
}
