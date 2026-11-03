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

  /// "Capture" and "Capture Full Page" in the page context menu, after the selection items and
  /// before Chromium's Inspect item (§7.3; order guess). Returns the titles it added.
  @discardableResult
  func addCaptureItems(to menu: NSMenu, for webContent: OEWebContent) -> [String] {
    guard hasWebPage, let host = controller?.captureHost() as? EngineWebContentHost, host.content === webContent else { return [] }
    let items = [("Capture", "capture-page"), ("Capture Full Page", "capture-full-page")].map { title, id in
      ClosureMenuItem(title: title) { [weak self] in _ = self?.performAppCommand(id) }
    }
    var index = menu.items.firstIndex { $0.title.hasPrefix("Inspect") } ?? menu.items.count
    if index > 0, !menu.items[index - 1].isSeparatorItem { menu.insertItem(.separator(), at: index); index += 1 }
    for item in items.reversed() { menu.insertItem(item, at: index) }
    if index + items.count < menu.items.count, !menu.items[index + items.count].isSeparatorItem {
      menu.insertItem(.separator(), at: index + items.count)
    }
    return items.map(\.title)
  }
}
