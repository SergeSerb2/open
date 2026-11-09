#if OPEN_AUTOMATION
import AppKit
import ImageIO
import OpenModel
import OpenSettings
import OpenEngine

extension AutomationController {
  #if DEBUG
  /// Lifecycle seam for a real-App fixture that keeps Site Control presented.
  func settingsAdBlockProfile(_ args: [String: Any]) async throws -> [String: Any] {
    guard Set(args.keys).isSubset(of: ["profile", "action", "privateSession"]),
      let raw = args["profile"] as? String,
      let profile = app.model.profiles.first(where: { $0.id.description == raw }),
      let store = app.stores.existingAdBlock else { throw Failure(message: "expected an existing Profile and store") }
    switch args["action"] as? String ?? "state" {
    case "state": break
    case "close": try store.closeProfile(profile.id)
    case "open": try await store.openProfile(profile.id,
      directory: app.directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName), scheduleUpdates: false)
    case "retire": await store.retireProfile(profile.id)
    default: throw Failure(message: "unknown ad-block Profile action")
    }
    return ["open": store.isProfileOpen(profile.id), "retired": store.isRetired(profile.id),
      "privateSessionOpen": (args["privateSession"] as? String).map { store.isPrivateSessionOpen($0, profile: profile.id) } ?? false]
  }
  #endif

  /// Exercise the production per-site API on the real page's context. Does not
  /// instantiate Settings or create a store, Profile, or private session.
  func settingsAdBlockSite(_ args: [String: Any]) throws -> [String: Any] {
    guard Set(args.keys).isSubset(of: ["tab", "excluded"]),
      let raw = args["tab"] as? String,
      let factory = app.hostFactories.values.first(where: { $0.hosts.keys.contains { $0.description == raw } }),
      let entry = factory.hosts.first(where: { $0.key.description == raw }), !entry.value.closed,
      let host = entry.value.content.url?.host(),
      let store = app.stores.existingAdBlock else { throw Failure(message: "expected a live website tab and store") }
    let profile = factory.incognitoSession?.parent.id ?? entry.value.profileID
    let context = entry.value.content.context
    let session = context.originalContext == nil ? nil : context.identifier
    if args["excluded"] != nil {
      guard let excluded = args["excluded"] as? Bool else { throw Failure(message: "expected exclusion state") }
      try store.setExcluded(host, excluded: excluded, profile: profile, privateSession: session)
    }
    let snapshot = store.siteSnapshot(for: profile, privateSession: session)
    return ["profile": profile.description, "privateSession": session ?? "",
      "available": store.onEngineEvent != nil && store.isProfileOpen(profile) && store.isEnabled
        && (session.map { store.isPrivateSessionOpen($0, profile: profile) } ?? true),
      "shouldBlock": try snapshot.shouldBlock(host: host),
      "excludedDomains": snapshot.excludedDomains.sorted()]
  }

  func settingsAdBlock(_ args: [String: Any]) async throws -> [String: Any] {
    let adapter = app.settingsPresenter
    guard let model = adapter.settings.adBlock else { throw Failure(message: "ad blocking unavailable") }
    if let enabled = args["enabled"] as? Bool { model.setEnabled(enabled) }
    if let list = args["list"] as? String {
      guard model.lists.contains(where: { $0.id == list }),
        let enabled = args["listEnabled"] as? Bool else { throw Failure(message: "expected a known list and enabled state") }
      await model.setList(list, enabled: enabled)
    }
    if args["resetLists"] as? Bool == true { await model.reset() }
    if let host = args["host"] as? String {
      guard host.utf8.count <= 253, let excluded = args["excluded"] as? Bool else { throw Failure(message: "expected a site host and exclusion state") }
      model.setExcluded(host, excluded: excluded)
    }
    var copiedDebug: String?
    if args["copyDebug"] as? Bool == true {
      // Exercise the real copy action and restore all clipboard formats locally.
      let board = NSPasteboard.general
      let saved = (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
      }
      defer {
        board.clearContents()
        let items = saved.map { values in
          let item = NSPasteboardItem()
          for (type, data) in values { item.setData(data, forType: type) }
          return item
        }
        board.writeObjects(items)
      }
      model.copyDebug()
      copiedDebug = board.string(forType: .string)
    }
    // SwiftUI exposes its static text only after enhanced AX is requested,
    // as in the existing Profiles automation. This changes only this process.
    let write = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    if NSApp.responds(to: write) { NSApp.perform(write, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
    return ["enabled": model.enabled, "hasOtherBlocker": model.hasOtherBlocker,
      "ready": model.isReady, "error": model.errorText,
      "copiedDebugInfo": copiedDebug ?? "",
      "lists": model.lists.map { ["id": $0.id, "enabled": model.enabledIDs.contains($0.id)] as [String: Any] },
      "listStatus": model.lists.filter(\.bundled).map { model.listStatus($0) },
      "text": adapter.settingsPresenter.window.map { windowText($0) } ?? []]
  }

  /// Read-only: does not instantiate Settings, open a store, or create a context.
  func settingsAdBlockEngine() -> [String: Any] {
    let store = app.stores.existingAdBlock
    return ["started": app.adBlockEngineAdapter.started,
      "nativeSupported": OEBrowserContext.adBlockSupported,
      "adapterSupported": app.adBlockEngineAdapter.isSupported,
      "bindingInstalled": store?.onEngineEvent != nil,
      "profiles": app.model.profiles.map { profile -> [String: Any] in
        let expected = app.directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName)
          .appendingPathComponent("lists", isDirectory: true).standardizedFileURL
        let contexts = app.adBlockEngineAdapter.contexts(for: profile.id)
        return ["profile": profile.id.description,
          "storeReady": store?.isProfileOpen(profile.id) ?? false,
          "storeEnabled": store?.isEnabled ?? false,
          "storeExcludedDomains": store?.excludedDomains(for: profile.id) ?? [],
          "contexts": contexts.map { context -> [String: Any] in
            ["identifier": context.identifier, "offTheRecord": context.originalContext != nil,
              "storePrivateSessionOpen": store?.isPrivateSessionOpen(context.identifier, profile: profile.id) ?? false,
              "storeEffectiveExcludedDomains": store?.excludedDomains(for: profile.id,
                privateSession: context.originalContext == nil ? nil : context.identifier) ?? [],
              "adBlockEnabled": context.isAdBlockEnabled,
              "listDirectorySet": context.adBlockListDirectory != nil,
              "listDirectoryMatchesProfile": context.adBlockListDirectory?.standardizedFileURL == expected,
              "excludedDomains": context.adBlockExcludedDomains, "adBlockStatus": context.adBlockStatus,
              "pages": OEEngine.shared.allWebContents.filter { $0.context === context }.map {
                ["identifier": $0.identifier, "blockedCount": $0.adBlockBlockedCount] as [String: Any]
              }]
          }]
      }]
  }

  func settingsProfilePage(_ args: [String: Any]) throws -> Bool {
    guard Set(args.keys).isSubset(of: ["profile", "page"]),
      let raw = args["profile"] as? String,
      let profile = app.model.profiles.first(where: { $0.id.description == raw }),
      let name = args["page"] as? String, let page = ProfilePage(rawValue: name) else {
      throw Failure(message: "expected an existing profile ID and ProfilePage")
    }
    // The same Profiles row action, with Section 10's target selection intact.
    let profiles = app.settingsPresenter.settings.profiles
    profiles.select(profile.id)
    profiles.open(page)
    return true
  }

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
      "restorePreparationMs": icon.restorePreparationMs ?? NSNull(),
      "restoreSetterMs": icon.restoreSetterMs ?? NSNull(),
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
