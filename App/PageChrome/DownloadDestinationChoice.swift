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
  /// A modeless panel's session is open (hidden or not).
  private var modeless = false
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
  /// No window can parent the panel: ask in a modeless panel.
  func presentModeless(filename: String, directory: URL) {
    panel.nameFieldStringValue = filename
    panel.directoryURL = directory
    panel.canCreateDirectories = true
    started = true; modeless = true
    panel.begin { [weak self] response in
      guard let self else { return }
      self.modeless = false
      self.finish(response == .OK ? self.panel.url : nil)
    }
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
    if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
    // A modeless panel (begin) ends its session with cancel(_:), which hiding it does not
    // (bug sweep r5 item 1). Its completion then finds `completion` already nil.
    // Hidden (Open hidden, panel miniaturized) still counts: track the session, not visibility.
    else if modeless { modeless = false; panel.cancel(nil) }
    panel.orderOut(nil)
  }
  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
