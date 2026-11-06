#if OPEN_AUTOMATION
import AppKit
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
    // Compare both through that same representation, in a fixed color space.
    let matchesApplication: Bool
    if let expected = icon.appliedImage, let actual = NSApp.applicationIconImage,
       let expectedPixels = iconPixels(expected), let actualPixels = iconPixels(actual) {
      matchesApplication = expectedPixels == actualPixels
    } else { matchesApplication = icon.appliedID == "openDefault" && icon.appliedImage == nil }
    return ["selected": settings.appIcon.selected, "applied": icon.appliedID,
      "error": settings.appIcon.errorText,
      "matchesApplication": matchesApplication,
      "applicationPixels": NSApp.applicationIconImage?.representations.map { [$0.pixelsWide, $0.pixelsHigh] } ?? [],
      "imageObject": icon.appliedImage.map { String(describing: ObjectIdentifier($0)) } ?? "bundle",
      "pixels": icon.appliedImage?.representations.map { [$0.pixelsWide, $0.pixelsHigh] } ?? [],
      "restoreStartedMs": icon.restoreStartedMs ?? NSNull(),
      "restoreElapsedMs": icon.restoreElapsedMs ?? NSNull()]
  }

  private func iconPixels(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let cg = NSBitmapImageRep(data: tiff)?.cgImage,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 4096, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return Data(bytes: pixels, count: 4_194_304)
  }
}
#endif
