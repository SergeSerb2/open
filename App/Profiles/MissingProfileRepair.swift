import AppKit
import OpenModel

extension AppDelegate {
  @discardableResult
  func repairMissingProfiles(in model: BrowserModel) -> Bool {
    let ids = model.repairMissingProfileReferences()
    pendingMissingProfileTitles += ids.compactMap { model.space(id:$0).map { model.displayTitle(for:$0) } }
    if !ids.isEmpty, let window = windowControllers.first?.window {
      // Model swaps must finish installation before their sheet is presented.
      Task { @MainActor [weak self, weak window] in self?.showMissingProfileNoticeIfNeeded(on:window) }
    }
    return !ids.isEmpty
  }

  func showMissingProfileNoticeIfNeeded(on window: NSWindow?) {
    guard missingProfileNotice == nil, !pendingMissingProfileTitles.isEmpty,
      let window, window.isVisible, window.attachedSheet == nil else { return }
    let titles = pendingMissingProfileTitles; pendingMissingProfileTitles = []
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "One or more of your Profiles is missing from this computer."
    alert.informativeText = "Open has gone back to your Default Profile for these Spaces: \(titles.joined(separator:", "))."
    alert.addButton(withTitle:"OK")
    missingProfileNotice = alert; missingProfileNoticeTitles = titles; missingProfileNoticeCount += 1
    alert.beginSheetModal(for:window) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.missingProfileNotice = nil
        self?.showMissingProfileNoticeIfNeeded(on:window)
      }
    }
  }
}
