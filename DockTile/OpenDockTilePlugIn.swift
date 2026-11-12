import AppKit

/// Draws Open's chosen app icon in the Dock while Open is not running (Arc ships the same kind of plug-in:
/// `Contents/PlugIns/DockTilePlugIn.plugin`, `NSDockTilePlugIn` in Arc's Info.plist; docs/re/bundle-anatomy.md).
/// While Open runs, `ApplicationIconController` sets the icon itself. The Dock loads this bundle in its own
/// process: it reads only Open's preference `open.appIcon.dockTileFile` (the cached icon PNG Open wrote) and
/// never writes anything. No file → the bundle icon (Open's default).
@objc(OpenDockTilePlugIn)
final class OpenDockTilePlugIn: NSObject, NSDockTilePlugIn {
  static let fileKey = "open.appIcon.dockTileFile"
  /// The PNG is a 1024 px icon from Open's cache; refuse anything much larger.
  static let maxBytes = 16 << 20

  func setDockTile(_ dockTile: NSDockTile?) {
    guard let dockTile else { return }
    if let image = Self.selectedIcon() {
      let view = NSImageView(image: image)
      view.imageScaling = .scaleProportionallyUpOrDown
      dockTile.contentView = view
    } else {
      dockTile.contentView = nil
    }
    dockTile.display()
  }

  /// The host app's bundle identifier: this plug-in lives in `<App>.app/Contents/PlugIns/`.
  static var hostBundleIdentifier: String? {
    let app = Bundle(for: OpenDockTilePlugIn.self).bundleURL
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: app)?.bundleIdentifier
  }

  /// The icon to draw, or nil for the bundle icon. Exposed to Objective-C for the verification harness.
  @objc static func selectedIcon() -> NSImage? {
    guard let domain = hostBundleIdentifier as CFString? else { return nil }
    CFPreferencesAppSynchronize(domain)
    guard let path = CFPreferencesCopyAppValue(fileKey as CFString, domain) as? String, path.hasSuffix(".png"),
          let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), size > 0, size <= maxBytes
    else { return nil }
    return NSImage(contentsOfFile: path)
  }
}
