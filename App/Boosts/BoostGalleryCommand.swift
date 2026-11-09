import AppKit

extension AppDelegate {
  /// App-level menus can also run with Library, Settings or no browser key.
  /// Read the preference without initializing the Boost owner or a Profile.
  var boostGalleryEnabled: Bool {
    guard UserDefaults.standard.object(forKey: "open.advanced.enableBoosts") as? Bool ?? true else { return false }
    if let window = NSApp.keyWindow, let factory = factory(forKeyWindow: window) { return !factory.isIncognito }
    return true
  }
}
