import Foundation
import OpenEngine

/// Section 12's Profile-scoped data hook. Values always come from OpenEngine.
/// The small origin index only makes App-written settings enumerable. It never
/// copies Chromium's settings or runs disk work on the main thread.
@MainActor
final class SitePermissionStore {
  struct Decision {
    let origin: URL
    let kind: OEPermissionKind
    let state: OEPermissionState
  }
  static let didChange = Notification.Name("OpenSitePermissionsDidChange")
  static let kinds: [(OEPermissionKind, String, String)] = [
    (.camera, "camera", "video"), (.microphone, "microphone", "mic"),
    (.geolocation, "location", "location"), (.notifications, "notifications", "bell"),
    (.clipboard, "clipboard", "doc.on.clipboard"), (.MIDI, "MIDI devices", "pianokeys"),
    (.screenCapture, "screen", "video"), (.multipleDownloads, "multiple files", "arrow.down.circle"),
    (.storageAccess, "storage", "externaldrive"), (.windowManagement, "windows", "macwindow"),
    (.localFonts, "fonts", "textformat"), (.idleDetection, "activity", "figure.stand"), (.other, "permissions", "lock")]
  private static var stores: [ObjectIdentifier: SitePermissionStore] = [:]
  static func forContext(_ context: OEBrowserContext) -> SitePermissionStore {
    stores = stores.filter { $0.value.context != nil }
    let key = ObjectIdentifier(context)
    if let store = stores[key] { return store }
    let store = SitePermissionStore(context); stores[key] = store; return store
  }
  static func canPersist(_ kind: OEPermissionKind) -> Bool {
    kind != .screenCapture && kind != .other && kinds.contains { $0.0 == kind }
  }
  private weak var context: OEBrowserContext?
  private var origins: Set<String> = []
  private let index: SitePermissionOriginIndex
  private(set) var indexReady = false
  private(set) var persistenceTask: Task<Void, Never>?

  private init(_ context: OEBrowserContext) {
    self.context = context
    index = SitePermissionOriginIndex(directory: context.directory)
    persistenceTask = Task { [weak self, index] in
      let saved = await index.read()
      guard let self else { return }
      self.origins = Set(self.origins.union(saved).sorted().prefix(SitePermissionOriginIndex.limit)); self.indexReady = true
      await index.write(self.origins)
    }
  }
  func state(origin: URL, kind: OEPermissionKind) -> OEPermissionState {
    remember(origin)
    return Self.canPersist(kind) ? context?.permissionState(for: kind, origin: origin) ?? .ask : .ask
  }
  func set(origin: URL, kind: OEPermissionKind, state: OEPermissionState, requestSystemAuthorization: Bool = true) {
    guard Self.canPersist(kind), let context else { return }
    remember(origin)
    context.setPermissionState(state, for: kind, origin: origin)
    if requestSystemAuthorization, kind == .notifications, state == .allow { NotificationAuthorization.shared.userAllowedNotifications() }
    EngineWebProfile.onPermissionChange?(context)
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
  func allDecisions() -> [Decision] {
    guard let context else { return [] }
    return origins.sorted().compactMap(URL.init(string:)).flatMap { origin in
      Self.kinds.compactMap { kind, _, _ in
        guard Self.canPersist(kind) else { return nil }
        let state = context.permissionState(for: kind, origin: origin)
        return state == .ask ? nil : Decision(origin: origin, kind: kind, state: state)
      }
    }
  }
  private func remember(_ url: URL) {
    guard let scheme = url.scheme, let host = url.host(), ["http", "https"].contains(scheme),
          host.utf8.count <= 2048, origins.count < SitePermissionOriginIndex.limit else { return }
    let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    guard origins.insert(origin).inserted, indexReady else { return }
    let previous = persistenceTask, snapshot = origins
    persistenceTask = Task { [index] in
      await previous?.value
      await index.write(snapshot)
    }
  }
}

private actor SitePermissionOriginIndex {
  static let limit = 2048
  let file: URL?
  init(directory: URL?) { file = directory?.appendingPathComponent("OpenPermissionOrigins.json") }
  func read() -> Set<String> {
    guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= 8 * 1024 * 1024, let data = try? Data(contentsOf: file),
          let values = try? JSONDecoder().decode([String].self, from: data), values.count <= Self.limit,
          values.allSatisfy({ $0.utf8.count <= 4096 }) else { return [] }
    return Set(values)
  }
  func write(_ origins: Set<String>) {
    guard let file, origins.count <= Self.limit, let data = try? JSONEncoder().encode(origins.sorted()) else { return }
    try? data.write(to: file, options: .atomic)
  }
}
