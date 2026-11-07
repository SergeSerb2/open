import AppKit

extension AppDelegate {
  /// Resolve only the standalone window's owner. A main browser is never a fallback.
  func littleOpenExtensionFactory(window: NSWindow? = NSApp.keyWindow) -> EngineWebContentHostFactory? {
    guard let window else { return nil }
    return littleOpenHosts.values.lazy.compactMap(\.owner).first { $0.littleOpenController != nil && $0.ownsKeyWindow(window) }
  }
}
