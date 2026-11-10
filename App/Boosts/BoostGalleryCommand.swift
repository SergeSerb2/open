import AppKit
import OpenModel

extension AppDelegate {
  /// App-level menus can also run with Library, Settings or no browser key.
  /// Read the preference without initializing the Boost owner or a Profile.
  var boostGalleryEnabled: Bool {
    guard UserDefaults.standard.object(forKey: BoostPreferences.globallyEnabledKey) as? Bool ?? true else { return false }
    if let window = NSApp.keyWindow, let factory = factory(forKeyWindow: window) { return !factory.isIncognito }
    return true
  }
  /// An app-level Library command has no browser Profile to override the picker.
  var boostLibraryInvokingProfileID: ProfileID? {
    if let littleOpen = keyLittleOpen { return littleOpen.session.profileID }
    return NSApp.keyWindow.flatMap { factory(forKeyWindow: $0)?.focusedProfile?.id }
  }
}
