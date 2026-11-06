import Foundation
import OpenEngine
import OpenModel
import OpenStore
import Darwin

/// The only deletion adapter that releases engine contexts. releaseContext is
/// a page-close barrier, not proof of Chromium Profile destruction. Until the
/// engine supplies that proof, a previously loaded directory waits for launch.
@MainActor
final class ProfileTeardown {
  unowned let app: AppDelegate
  private var loaded: [ProfileID: String] = [:]
  init(app: AppDelegate) { self.app = app }

  func didLoad(_ profile: Profile) { loaded[profile.id] = profile.dataDirectoryName }
  func wasLoaded(_ id: ProfileID) -> Bool { loaded[id] != nil }

  func unload(profileID: ProfileID) async -> Bool {
    guard let directory = loaded[profileID] else { return true }
    for session in app.littleOpenCoordinator?.sessions.filter({ $0.profileID == profileID }) ?? [] {
      app.littleOpenCoordinator.close(sessionID: session.id, archiveReason: nil)
    }
    for factory in app.hostFactories.values { factory.retireProfile(profileID, directory: directory) }
    guard let context = OEEngine.shared.contexts.first(where: { $0.identifier == directory }) else { return true }
    guard context !== OEEngine.shared.defaultContext else { return false }
    await withCheckedContinuation { continuation in
      OEEngine.shared.releaseContext(context) { continuation.resume() }
    }
    return true
  }

  func wipe(profileID: ProfileID, directory: String) async throws {
    guard await unload(profileID: profileID) else { throw Self.failure("The Profile context could not be released.") }
    await app.stores.flushHistory()
    app.archiveSink.flushAll()
    // Queue first so an interrupted wipe is retried. Even an unloaded Profile
    // needs a launch-time Local State edit: Chromium owns that file in-session.
    try Self.enqueue(directory, directories: app.directories)
    try Self.removeIfPresent(app.directories.profileDirectory(dataDirectoryName: directory))
    if !wasLoaded(profileID) { try Self.wipeEngine(directory, directories: app.directories) }
  }

  private static func pendingURL(_ directories: ProfileDirectories) -> URL {
    directories.root.appendingPathComponent("Profiles/.pending-wipe.json")
  }
  private static func failure(_ message: String) -> NSError {
    NSError(domain:"Open.ProfileTeardown",code:1,userInfo:[NSLocalizedDescriptionKey:message])
  }
  private static func valid(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 255 && ![".","..","default"].contains(name.lowercased())
      && !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
  }
  private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom:url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount:maximum + 1) ?? Data()
    guard data.count <= maximum else { throw failure("Profile cleanup file exceeds its size limit.") }
    return data
  }
  private static func pending(_ directories: ProfileDirectories) throws -> [String] {
    let url = pendingURL(directories)
    guard FileManager.default.fileExists(atPath:url.path) else { return [] }
    // At most 64 KiB input (under 2 MiB even at 24x decoding overhead),
    // 1024 names, each at most one filesystem component of 255 UTF-8 bytes.
    let names = try JSONDecoder().decode([String].self,from:boundedData(url,maximum:65_536))
    guard names.count <= 1024, names.allSatisfy(valid), Set(names).count == names.count else {
      throw failure("Invalid pending Profile cleanup list.")
    }
    return names
  }
  private static func enqueue(_ directory: String, directories: ProfileDirectories) throws {
    guard valid(directory) else { throw failure("Invalid Profile cleanup directory.") }
    var names = try pending(directories)
    if !names.contains(directory) { names.append(directory) }
    let data = try JSONEncoder().encode(names)
    guard names.count <= 1024, data.count <= 65_536 else { throw failure("Pending Profile cleanup list is full.") }
    let url = pendingURL(directories)
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    try writeAtomically(data,to:url)
  }
  private static func removeIfPresent(_ url: URL) throws {
    if FileManager.default.fileExists(atPath:url.path) {
      try FileManager.default.removeItem(at:url)
      try sync(url.deletingLastPathComponent())
    }
  }
  private static func sync(_ url: URL) throws {
    let fd=Darwin.open(url.path,O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw failure("Could not open Profile cleanup file for sync.") }
    defer {Darwin.close(fd)}
    guard fsync(fd) == 0 else {throw failure("Could not sync Profile cleanup file.")}
  }
  private static func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to:url,options:.atomic)
    try sync(url)
    try sync(url.deletingLastPathComponent())
  }
  private static func wipeEngine(_ directory: String, directories: ProfileDirectories) throws {
    let engine = directories.engineDirectory(dataDirectoryName:directory)
    let cache = directories.engineCacheDirectory(dataDirectoryName:directory)
    if cache != engine { try removeIfPresent(cache) }
    try removeIfPresent(engine)
  }

  /// Call only while the data-root lock is held, before OEEngine.start.
  static func finishPendingWipes(directories: ProfileDirectories) throws {
    let names = try pending(directories)
    guard !names.isEmpty else { return }
    for name in names { try wipeEngine(name,directories:directories) }
    let url = directories.engineRoot.appendingPathComponent("Local State")
    if FileManager.default.fileExists(atPath:url.path) {
      // A 16 MiB Local State cap bounds decoding at approximately 384 MiB at
      // 24x expansion; no single allocation approaches PartitionAlloc's 2 GiB.
      guard var state = try JSONSerialization.jsonObject(with:boundedData(url,maximum:16_777_216)) as? [String:Any] else {
        throw failure("Engine Local State is not a JSON object.")
      }
      if var profile = state["profile"] as? [String:Any] {
        if var cache = profile["info_cache"] as? [String:Any] {
          for name in names { cache.removeValue(forKey:name) }; profile["info_cache"] = cache
        }
        if let last = profile["last_used"] as? String, names.contains(last) { profile["last_used"] = "Default" }
        if let active = profile["last_active_profiles"] as? [String] { profile["last_active_profiles"] = active.filter { !names.contains($0) } }
        state["profile"] = profile
      }
      try writeAtomically(JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]),to:url)
    }
    try removeIfPresent(pendingURL(directories))
  }
}
