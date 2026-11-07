import Foundation
import OpenEngine
import OpenModel
import OpenStore
import Darwin

/// Deletion waits for native Profile destruction before removing its folders.
/// The pending list covers interrupted or failed cleanup only.
@MainActor
final class ProfileTeardown {
  unowned let app: AppDelegate
  private var loaded: [ProfileID: String] = [:]
  private var unloaded: Set<ProfileID> = []
  init(app: AppDelegate) { self.app = app }

  func didLoad(_ profile: Profile) { loaded[profile.id] = profile.dataDirectoryName }
  func wasLoaded(_ id: ProfileID) -> Bool { loaded[id] != nil }

  func unload(profileID: ProfileID) async throws {
    guard let directory = loaded[profileID], !unloaded.contains(profileID) else { return }
    for session in app.littleOpenCoordinator?.sessions.filter({ $0.profileID == profileID }) ?? [] {
      app.littleOpenCoordinator.close(sessionID: session.id, archiveReason: nil)
    }
    for controller in app.windowControllers where
      app.hostFactories[controller.windowID]?.incognitoSession?.parent.id == profileID {
      controller.window?.close()
    }
    for factory in app.hostFactories.values where !factory.isIncognito { factory.retireProfile(profileID, directory: directory) }
    guard let context = OEEngine.shared.contexts.first(where: { $0.identifier == directory }),
      context !== OEEngine.shared.defaultContext else {
      throw Self.failure("The Profile context is unavailable for deletion.")
    }
    try await OEEngine.shared.deleteContext(context)
    unloaded.insert(profileID)
  }

  func wipe(profileID: ProfileID, directory: String) async throws {
    // Journal before teardown so any engine or filesystem failure remains
    // recoverable. Errors preserve all folders until a later safe launch.
    try Self.enqueue(directory, directories: app.directories)
    await app.stores.flushHistory()
    app.archiveSink.flushAll()
    try await unload(profileID: profileID)
    try Self.removeIfPresent(app.directories.profileDirectory(dataDirectoryName: directory))
    try Self.wipeEngine(directory, directories: app.directories)
    try Self.dequeue(directory, directories: app.directories)
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
  private static func dequeue(_ directory: String, directories: ProfileDirectories) throws {
    let remaining = try pending(directories).filter { $0 != directory }
    if remaining.isEmpty { try removeIfPresent(pendingURL(directories)) }
    else { try writeAtomically(JSONEncoder().encode(remaining), to: pendingURL(directories)) }
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
    for name in names {
      // The process may have stopped between journaling and the immediate wipe.
      try removeIfPresent(directories.profileDirectory(dataDirectoryName:name))
      try wipeEngine(name,directories:directories)
    }
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
