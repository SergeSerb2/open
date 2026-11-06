import AppKit

/// One engine request, answered once. Sheets queue behind the requesting window's
/// current sheet and cancel when that window closes.
@MainActor
final class DownloadDestinationChoice {
  let panel = NSSavePanel()
  private weak var window: NSWindow?
  private var completion: (@MainActor (URL?) -> Void)?
  private var observers: [any NSObjectProtocol] = []
  private var started = false
  init(completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
  func present(in window: NSWindow, filename: String, directory: URL) {
    self.window = window
    panel.nameFieldStringValue = filename
    panel.directoryURL = directory
    panel.canCreateDirectories = true
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancel() }
    })
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
      // didEndSheet can run inside AppKit's close callback.
      DispatchQueue.main.async { self?.presentWhenAvailable() }
    })
    presentWhenAvailable()
  }
  private func presentWhenAvailable() {
    guard completion != nil, !started, let window, window.attachedSheet == nil else { return }
    started = true
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.finish(response == .OK ? self.panel.url : nil)
    }
  }
  private func finish(_ url: URL?) {
    guard let completion else { return }
    self.completion = nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    completion(url)
  }
  func cancel() {
    finish(nil)
    panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    panel.orderOut(nil)
  }
  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
