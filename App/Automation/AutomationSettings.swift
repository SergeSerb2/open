#if OPEN_AUTOMATION
import AppKit
import ImageIO
import OpenModel
import OpenSettings

extension AutomationController {
  func settingsProfile(_ args: [String: Any]) throws -> [String: Any] {
    let adapter = app.settingsPresenter
    let profiles = adapter.settings.profiles
    if args["cancel"] as? Bool == true { profiles.showsCreate = false }
    let sheet = adapter.settingsPresenter.window?.attachedSheet
    return ["creating": profiles.showsCreate, "sheet": sheet?.windowNumber ?? 0,
      "pane": adapter.settings.selectedPane.rawValue,
      "spaces": profiles.assignedSpaces.map(\.description).sorted(),
      "error": profiles.errorText]
  }

  func settingsIcon(_ args: [String: Any]) throws -> [String: Any] {
    let settings = app.settingsPresenter.settings
    if let id = args["select"] as? String {
      guard let option = AppIconOption(rawValue: id) else { throw Failure(message: "unknown icon") }
      settings.appIcon.select(option)
    }
    let icon = app.applicationIcon
    // AppKit copies the assigned NSImage through its bitmap representation.
    // Compare in AppKit's output color space: converting its display-profile
    // copy back to sRGB would add a second, lossy color transform to that side.
    let matchesApplication: Bool
    if let expected = icon.appliedImage.flatMap(iconCGImage),
       let actual = NSApp.applicationIconImage.flatMap(iconCGImage),
       let expectedPixels = iconPixels(expected, matching: actual), let actualPixels = iconPixels(actual, matching: actual) {
      matchesApplication = expectedPixels == actualPixels
    } else { matchesApplication = icon.appliedID == "openDefault" && icon.appliedImage == nil }
    return ["selected": settings.appIcon.selected, "applied": icon.appliedID,
      "error": settings.appIcon.errorText,
      "matchesApplication": matchesApplication,
      "applicationPixels": NSApp.applicationIconImage?.representations.map { [$0.pixelsWide, $0.pixelsHigh] } ?? [],
      "imageObject": icon.appliedImage.map { String(describing: ObjectIdentifier($0)) } ?? "bundle",
      "pixels": icon.appliedImage?.representations.map { [$0.pixelsWide, $0.pixelsHigh] } ?? [],
      "restoreStartedMs": icon.restoreStartedMs ?? NSNull(),
      "restoreDecodeMs": icon.restoreDecodeMs ?? NSNull(),
      "restoreElapsedMs": icon.restoreElapsedMs ?? NSNull()]
  }

  private func iconCGImage(_ image: NSImage) -> CGImage? {
    guard let tiff = image.tiffRepresentation,
      let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private func iconPixels(_ image: CGImage, matching actual: CGImage) -> Data? {
    // AppKit can copy the icon as float16 in the monitor's profile. That
    // extended color space cannot make an 8-bit context. Preserve its format.
    guard image.width == 1024, image.height == 1024,
      actual.width == 1024, actual.height == 1024, let space = actual.colorSpace,
      space.model == .rgb, [8, 16, 32].contains(actual.bitsPerComponent) else { return nil }
    let bytesPerRow = 1024 * 4 * (actual.bitsPerComponent / 8)
    let format = actual.bitmapInfo.intersection([.floatComponents, .byteOrderMask]).rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    // Fixed 1024 px RGBA; the largest permitted read-back allocation is 16 MiB.
    guard let context = CGContext(data: nil, width: 1024, height: 1024,
      bitsPerComponent: actual.bitsPerComponent, bytesPerRow: bytesPerRow,
      space: space, bitmapInfo: format) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    guard let pixels = context.data else { return nil }
    return Data(bytes: pixels, count: bytesPerRow * 1024)
  }
}
#endif
