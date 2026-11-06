import AppKit
import OpenEngine
import OpenFeatures

/// Capture commands (page-platform §4.6.1, §7.1): File ▸ Capture… (Cmd+Shift+2), Capture Full
/// Page, Capture in Portrait Mode, the Site Control buttons, and the page context menu all run
/// these ids through the window's `CaptureController`.
extension EngineWebContentHostFactory {
  static let captureKinds: [String: CaptureComposer.Kind] = [
    "capture-page": .area, "capture-full-page": .fullPage, "capture-portrait": .portrait,
  ]

  /// Enabled key `hasWebPage` (§7.1): a live http(s), file, or data page in the focused host.
  /// (Section 8 decision: computed here until `EnabledKey.hasWebPage` lands with
  /// `CommandMenuState`; then the registry rows switch to that key.)
  var hasWebPage: Bool {
    guard !isClosing, app.engineReady, let host = controller?.captureHost() as? EngineWebContentHost,
      host.webContent != nil, host.content.isLive, let scheme = host.currentURL?.scheme?.lowercased() else { return false }
    return ["http", "https", "file", "data"].contains(scheme)
  }

  func performCapture(_ id: String) -> Bool {
    guard let kind = Self.captureKinds[id], hasWebPage, let controller else { return false }
    controller.capture.start(kind)
    app.scheduleMenuRebuild()
    return true
  }

}
