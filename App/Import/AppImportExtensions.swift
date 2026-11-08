import AppKit
import OpenEngine
import OpenSettings

/// One operation, retained until its completion. The prompt presenter remains
/// the manager's sole delegate; the attempt routes consent to the import window.
@MainActor
final class AppImportExtensionAttempt {
  let manager: OEExtensionManager
  let identifier: String
  weak var window: NSWindow?
  var cancelled = false
  init(manager: OEExtensionManager, identifier: String, window: NSWindow) {
    self.manager = manager; self.identifier = identifier; self.window = window
  }
  func matches(_ manager: OEExtensionManager, _ identifier: String) -> Bool {
    self.manager === manager && self.identifier == identifier
  }
  func answered(_ accepted: Bool) {
    if !accepted { cancelled = true }
  }
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
    // Readiness has no deadline either: elapsed time is not an install error.
    while !manager.isReady && !app.terminationRequested && window.isVisible {
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return .skipped("cancelled") }
    }
    guard !app.terminationRequested, !Task.isCancelled, window.isVisible else { return .skipped("cancelled") }
    if manager.extension(identifier: candidate.extensionID) != nil { return .skipped("already installed") }
    let attempt = AppImportExtensionAttempt(manager: manager, identifier: candidate.extensionID, window: window)
    extensionAttempt = attempt
    defer { extensionAttempt = nil }
    #if OPEN_AUTOMATION
    if let file = extensionFixtures[candidate.extensionID] {
      guard FileManager.default.isReadableFile(atPath: file.path) else {
        return .failed("The local fixture file is missing or unreadable.")
      }
      // The engine completes exactly once on a later main-queue turn, even
      // for rejection or context closure. Consent has no deadline.
      return await withCheckedContinuation { continuation in
        manager.installLocalCRX(file) { result, identifier, error in
          let outcome: ImportExtensionInstallResult
          switch result {
          case .installed:
            outcome = identifier == candidate.extensionID ? .installed
              : .failed("The installed extension ID does not match the import candidate.")
          case .cancelled: outcome = .skipped("cancelled")
          case .failed: outcome = .failed(error ?? "The extension could not be installed.")
          @unknown default: outcome = .failed("The engine returned an unknown extension install result.")
          }
          continuation.resume(returning: outcome)
        }
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
