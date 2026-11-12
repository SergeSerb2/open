import AppKit
import OpenFeatures

/// Capture in Portrait Mode, "Use Desktop Wallpaper" (LEAD ruling, PB2-questions "EZ 19:40"):
/// the path comes from `NSWorkspace.desktopImageURL(for:)` and the file is read only when the
/// user picks that swatch, off the main thread. A folder, a dynamic set the decoder cannot read,
/// or no access gives nil; the caller then uses the website colour and logs it (no alert).
@MainActor
enum PortraitWallpaper {
  #if OPEN_AUTOMATION
  /// Automation: the image to use instead of the real wallpaper. Automation builds never read the
  /// real wallpaper (shared and rented test Macs): without an override they give nil.
  static var overrideURL: URL?
  #endif

  static func read(screen: NSScreen?) async -> Data? {
    #if OPEN_AUTOMATION
    guard let url = overrideURL else { return nil }
    #else
    guard let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
    #endif
    return await Task.detached(priority: .userInitiated) { () -> Data? in
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= CaptureComposer.maxWallpaperBytes
      else { return nil }
      return try? Data(contentsOf: url, options: .mappedIfSafe)
    }.value
  }
}
