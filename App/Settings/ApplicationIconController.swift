import AppKit
import ImageIO
import OpenSettings

/// Changes only this process's icon. The signed application bundle is never written.
@MainActor final class ApplicationIconController {
  unowned let app: AppDelegate
  private var restoreScheduled = false
  private var selectionGeneration = 0
  private static let artworkVersion = 1
  /// Read by `OpenDockTilePlugIn` (in the Dock's process) — keep the key in sync.
  static let dockTileFileKey = "open.appIcon.dockTileFile"
  private(set) var appliedID = "openDefault"
  private(set) var errorText = ""
  private(set) var restoreStartedMs: Double?
  /// Main-actor work only. File reading and PNG decoding are measured separately.
  private(set) var restoreElapsedMs: Double?
  private(set) var restoreDecodeMs: Double?
  private(set) var restorePreparationMs: Double?
  private(set) var restoreSetterMs: Double?
  private(set) var appliedImage: NSImage?
  init(app: AppDelegate) { self.app = app }

  private func cacheFile(_ option: AppIconOption) -> URL {
    app.directories.root.appendingPathComponent("Cache/AppIcons", isDirectory: true)
      .appendingPathComponent("\(option.rawValue)-v\(Self.artworkVersion).png")
  }

  @discardableResult func apply(id: String) -> String? {
    selectionGeneration += 1
    guard let option = AppIconOption(rawValue: id) else {
      errorText = "This application icon is not available."; return errorText
    }
    let image: NSImage?
    if option == .openDefault { image = nil }
    else {
      guard let rendered = AppIconArtwork.image(for: option),
            let bitmap = rendered.representations.first as? NSBitmapImageRep,
            let png = bitmap.representation(using: .png, properties: [:]) else {
        errorText = "The application icon could not be rendered. Try selecting it again."; return errorText
      }
      do {
        let file = cacheFile(option)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try png.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      } catch {
        errorText = "The application icon could not be saved. Try selecting it again."; return errorText
      }
      image = rendered
    }
    NSApp.applicationIconImage = image
    appliedImage = image; appliedID = id; errorText = ""
    // The Dock tile plug-in (DockTile/) draws this file while Open is not running; no file = bundle icon.
    if option == .openDefault { UserDefaults.standard.removeObject(forKey: Self.dockTileFileKey) }
    else { UserDefaults.standard.set(cacheFile(option).path, forKey: Self.dockTileFileKey) }
    return nil
  }

  /// Restore only after content. Decode the cached 1024 px PNG on a worker;
  /// constructing Settings or rendering SwiftUI is never part of this path.
  func restoreAfterContent() {
    guard !restoreScheduled, app.windowControllers.contains(where: { $0.window?.isVisible == true }) else { return }
    restoreScheduled = true
    let id = UserDefaults.standard.string(forKey: "open.appIcon.selectedID") ?? "openDefault"
    // The bundle icon needs no task, cache lookup, image allocation, or setter.
    guard id != "openDefault" else { return }
    let generation = selectionGeneration
    guard let option = AppIconOption(rawValue: id) else {
      restoreStartedMs = LaunchTiming.shared.elapsedMilliseconds
      restoreElapsedMs = 0; restorePreparationMs = 0; restoreSetterMs = 0
      errorText = "This application icon is not available."
      app.settingsPresenter.settings.appIcon.errorText = errorText
      return
    }
    let file = cacheFile(option)
    // Selections made before the Dock tile plug-in existed: point it at the same cached file.
    if UserDefaults.standard.string(forKey: Self.dockTileFileKey) != file.path {
      UserDefaults.standard.set(file.path, forKey: Self.dockTileFileKey)
    }
    Task { [weak self] in
      let decoded = await Task.detached(priority: .utility) { Self.decode(file) }.value
      guard let self, generation == self.selectionGeneration,
            !self.app.shutdownPrepared, !self.app.terminationRequested else { return }
      self.restoreDecodeMs = decoded.milliseconds
      // One low-priority turn, outside the launch burst and at least one second
      // after the paint hook. No repeating timer or idle polling remains.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1, qos: .utility, flags: .enforceQoS) { [weak self] in
        guard let self, generation == self.selectionGeneration,
              !self.app.shutdownPrepared, !self.app.terminationRequested else { return }
        self.restoreStartedMs = LaunchTiming.shared.elapsedMilliseconds
        LaunchTiming.shared.mark("appIconRestoreStarted")
        let started = ProcessInfo.processInfo.systemUptime
        self.restorePreparationMs = 0; self.restoreSetterMs = 0
        if let image = decoded.image {
          self.restorePreparationMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
          let setterStarted = ProcessInfo.processInfo.systemUptime
          NSApp.applicationIconImage = image
          self.restoreSetterMs = (ProcessInfo.processInfo.systemUptime - setterStarted) * 1_000
          self.appliedImage = image; self.appliedID = id; self.errorText = ""
        } else {
          self.errorText = "The application icon could not be restored. Try selecting it again."
        }
        self.restoreElapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        LaunchTiming.shared.mark("appIconRestored")
        if !self.errorText.isEmpty { self.app.settingsPresenter.settings.appIcon.errorText = self.errorText }
      }
    }
  }

  private struct DecodedIcon: Sendable {
    // Fully prepared on the worker, which never touches it after publication.
    let image: NSImage?
    let milliseconds: Double
  }
  nonisolated private static func decode(_ file: URL) -> DecodedIcon {
    let started = ProcessInfo.processInfo.systemUptime
    func result(_ image: NSImage? = nil) -> DecodedIcon {
      DecodedIcon(image: image, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
    }
    // Bound both encoded bytes and decoded dimensions before allocating pixels.
    // PNG's largest pixel format is 16-bit RGBA: 1024 * 1024 * 8 = 8,388,608 bytes.
    guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
          size.intValue > 0, size.intValue <= 16 * 1024 * 1024,
          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          properties[kCGImagePropertyPixelWidth] as? Int == 1024,
          properties[kCGImagePropertyPixelHeight] as? Int == 1024,
          let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
          let tiff = NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]),
          let representation = NSBitmapImageRep(data: tiff) else { return result() }
    let prepared = NSImage(size: .init(width: 1024, height: 1024))
    prepared.addRepresentation(representation)
    return result(prepared)
  }
}
