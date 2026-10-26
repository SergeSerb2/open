import AppKit

/// A destination request waits for the current document sheet. It answers the
/// engine exactly once, including window/engine teardown before sheet delivery.
@MainActor
final class DownloadDestinationChoice {
  let panel = NSSavePanel()
  private weak var window: NSWindow?
  private var completion: (@MainActor (URL?) -> Void)?
  private var sheetObserver: (any NSObjectProtocol)?
  private var started = false
  init(completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
  func present(in window: NSWindow, filename: String) {
    self.window = window; panel.nameFieldStringValue = filename; presentWhenAvailable()
  }
  private func presentWhenAvailable() {
    guard completion != nil, !started, let window else { return }
    if window.attachedSheet != nil {
      if sheetObserver == nil {
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentWhenAvailable() }
        }
      }
      return
    }
    started = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }; self.finish(response == .OK ? self.panel.url : nil)
    }
  }
  func finish(_ url: URL?) {
    guard let completion else { return }; self.completion = nil
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }; sheetObserver = nil
    completion(url)
  }
  func cancel() {
    finish(nil)
    panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
  }
  isolated deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) } }
}
