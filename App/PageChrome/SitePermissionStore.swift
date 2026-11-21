import AppKit
import Foundation
import OpenEngine
import OpenModel

/// Section 12's Profile-scoped data hook. Values always come from OpenEngine.
/// The small origin index only makes App-written settings enumerable. It never
/// copies Chromium's settings or runs disk work on the main thread.
@MainActor
final class SitePermissionStore: ProfileDataOwner {
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
    (.screenCapture, "screen", "lock"), (.multipleDownloads, "multiple files", "arrow.down.circle"),
    (.storageAccess, "storage", "externaldrive"), (.windowManagement, "windows", "lock"),
    (.localFonts, "fonts", "lock"), (.idleDetection, "activity", "figure.stand"),
    (.protocolHandler, "links", "envelope"), (.other, "permissions", "lock")]
  private static var stores: [ObjectIdentifier: SitePermissionStore] = [:]
  static func forContext(_ context: OEBrowserContext) -> SitePermissionStore {
    stores = stores.filter { $0.value.context != nil }
    let key = ObjectIdentifier(context)
    if let store = stores[key] { return store }
    let store = SitePermissionStore(context); stores[key] = store; return store
  }
  static func canPersist(_ kind: OEPermissionKind) -> Bool {
    // A protocol handler is stored by Chromium's handler registry on grant, not as a site setting.
    kind != .screenCapture && kind != .other && kind != .protocolHandler && kinds.contains { $0.0 == kind }
  }
  private weak var context: OEBrowserContext?
  private var origins: Set<String> = []
  private let index: SitePermissionOriginIndex
  private(set) var indexReady = false
  private(set) var persistenceTask: Task<Void, Never>?

  private var retired = false
  private init(_ context: OEBrowserContext) {
    self.context = context
    index = SitePermissionOriginIndex(directory: context.directory)
    let app = NSApp.delegate as? AppDelegate
    app?.profileTeardown.register(self)
    // Made after its Profile left the model (deletion removes it first, then retires owners):
    // retired from the start, so no index write can race the folder's removal (review r1 of #651).
    if let app, !context.isEphemeral, context !== OEEngine.shared.defaultContext,
      !app.model.profiles.contains(where: { $0.dataDirectoryName == context.identifier }) {
      retired = true
      return
    }
    persistenceTask = Task { [weak self, index] in
      let saved = await index.read()
      guard let self else { return }
      self.origins = Set(self.origins.union(saved).sorted().prefix(SitePermissionOriginIndex.limit)); self.indexReady = true
      // A read-only panel may be the first caller. Only persist decisions
      // remembered while the index was loading, not the unchanged saved set.
      if self.origins != saved, !self.retired { await index.write(self.origins) }
    }
  }
  /// Profile deletion: no index write after this, and the pending one finishes before the
  /// Profile's folder goes (a late write could recreate the file; bug sweep r5 item 6).
  func retireProfile(_ profileID: ProfileID, directory: String) async {
    guard context?.identifier == directory else { return }
    retired = true
    await persistenceTask?.value
  }
  func state(origin: URL, kind: OEPermissionKind) -> OEPermissionState {
    // Index only an origin that has a decision. A prompt or a read of an undecided site
    // filled the 2048-origin index, and later real decisions were no longer listed
    // (bug sweep r4 WC-13).
    let value = currentState(origin: origin, kind: kind)
    if value != .ask { remember(origin) }
    return value
  }
  /// Reads the engine without adding an origin to the on-disk decision index.
  func currentState(origin: URL, kind: OEPermissionKind) -> OEPermissionState {
    return Self.canPersist(kind) ? context?.permissionState(for: kind, origin: origin) ?? .ask : .ask
  }
  func set(origin: URL, kind: OEPermissionKind, state: OEPermissionState, requestSystemAuthorization: Bool = true) {
    guard Self.canPersist(kind), let context else { return }
    // "Not Now" writes back .ask: no decision, so no index entry (an earlier one stays).
    if state != .ask { remember(origin) }
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
    // The encoded host keeps an IPv6 literal's brackets: "http://::1:8080" does not parse back
    // (bug sweep r3 E13), so that decision could never be listed. One canonical origin per entry:
    // lowercase scheme and host, no default port (review r1 item 5).
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
          let scheme = parts.scheme?.lowercased(), let host = parts.percentEncodedHost?.lowercased(),
          !host.isEmpty, ["http", "https"].contains(scheme),
          host.utf8.count <= 2048, origins.count < SitePermissionOriginIndex.limit else { return }
    let port = parts.port.flatMap { (scheme == "http" && $0 == 80) || (scheme == "https" && $0 == 443) ? nil : $0 }
    let origin = "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    guard !retired, origins.insert(origin).inserted, indexReady else { return }
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
