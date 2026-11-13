import Foundation
import OpenEngine
import OpenModel
import OpenStore
import Darwin

/// An App-side store that keeps data in a Profile's folder (Boosts, passwords,
/// ad-block lists, ...). Register once with `ProfileTeardown.register(_:)`.
///
/// Contract for `retireProfile`:
/// - Called once per deleted Profile, after the Profile left the model and
///   before any of its folders are removed (in-session delete), on the main actor.
/// - Stop all work for that Profile and DISCARD its unsaved state: after this
///   returns, the owner never creates, writes or saves anything for that Profile
///   or directory again in this process (including the save on quit).
/// - Close open file handles/databases in that folder before returning.
/// - Must be idempotent and must not throw; also called for a Profile that the
///   owner never loaded. Do not delete the folder yourself: ProfileTeardown does.
@MainActor
protocol ProfileDataOwner: AnyObject {
  func retireProfile(_ profileID: ProfileID, directory: String) async
}

/// Deletion waits for native Profile destruction before removing its folders.
/// The pending list covers interrupted or failed cleanup only.
@MainActor
final class ProfileTeardown {
  unowned let app: AppDelegate
  private var loaded: [ProfileID: String] = [:]
  private var unloaded: Set<ProfileID> = []
  private var owners: [WeakOwner] = []
  private struct WeakOwner { weak var owner: (any ProfileDataOwner)? }
  init(app: AppDelegate) { self.app = app }
  /// The step a running wipe is in (verification: a delete that never finishes names the step it waits in).
  private(set) var stage = ""

  /// The single registration point for per-Profile App stores (weakly held).
  func register(_ owner: any ProfileDataOwner) {
    owners.removeAll { $0.owner == nil || $0.owner === owner }
    owners.append(WeakOwner(owner: owner))
  }
  private func retireOwners(profileID: ProfileID, directory: String) async {
    for entry in owners {
      stage = "retireOwners:" + (entry.owner.map { String(describing: type(of: $0)) } ?? "nil")
      await entry.owner?.retireProfile(profileID, directory: directory)
    }
    owners.removeAll { $0.owner == nil }
  }

  func didLoad(_ profile: Profile) { didLoad(profileID: profile.id, directory: profile.dataDirectoryName) }
  func didLoad(profileID: ProfileID, directory: String) { loaded[profileID] = directory }
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
    stage = "deleteContext"
    try await OEEngine.shared.deleteContext(context)
    unloaded.insert(profileID)
  }

  func wipe(profileID: ProfileID, directory: String) async throws {
    // Journal before teardown so any engine or filesystem failure remains
    // recoverable. Errors preserve all folders until a later safe launch.
    stage = "enqueue"
    try Self.enqueue(directory, directories: app.directories)
    // Registered App stores stop and drop dirty state before any folder goes.
    stage = "retireOwners"
    await retireOwners(profileID: profileID, directory: directory)
    stage = "flushHistory"
    await app.stores.flushHistory()
    app.archiveSink.flushAll()
    // An unopened Profile may still have native data/attributes from a prior
    // launch. Load that context for Chromium's ordered metadata cleanup too.
    if loaded[profileID] == nil,
      FileManager.default.fileExists(atPath: app.directories.engineDirectory(dataDirectoryName: directory).path) {
      guard app.engineReady, app.engine.result.layout == .engine,
        EngineWebContentHostFactory.createRegularContext(
          profileID: profileID, directory: directory, app: app) != nil else {
        throw Self.failure("The Profile context is unavailable for deletion.")
      }
      loaded[profileID] = directory
    }
    stage = "unload"
    try await unload(profileID: profileID)
    stage = "removeFolders"
    try Self.removeIfPresent(app.directories.profileDirectory(dataDirectoryName: directory))
    try Self.wipeEngine(directory, directories: app.directories)
    try Self.dequeue(directory, directories: app.directories)
    stage = "done"
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

  // MARK: Orphans of an undone import (audit A7)

  /// Undo of an import removes the Profiles it created from the model, but Redo and a re-import in the same
  /// session can bring the same Profile IDs back, and a wiped Profile's stores refuse to write again in this
  /// process (`ProfileDataOwner` contract). So the folders are journaled here and wiped at the next launch,
  /// before the engine starts, when no Profile of the loaded snapshot uses them.
  private static func orphansURL(_ directories: ProfileDirectories) -> URL {
    directories.root.appendingPathComponent("Profiles/.pending-orphans.json")
  }
  private static func orphans(_ directories: ProfileDirectories) throws -> [String] {
    let url = orphansURL(directories)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    // Same bounds as the pending-wipe list: 64 KiB, 1024 valid names.
    let names = try JSONDecoder().decode([String].self, from: boundedData(url, maximum: 65_536))
    guard names.count <= 1024, names.allSatisfy(valid), Set(names).count == names.count else {
      throw failure("Invalid orphan Profile list.")
    }
    return names
  }
  private static func writeOrphans(_ names: [String], directories: ProfileDirectories) throws {
    if names.isEmpty { try removeIfPresent(orphansURL(directories)); return }
    let data = try JSONEncoder().encode(names)
    guard names.count <= 1024, data.count <= 65_536 else { throw failure("Orphan Profile list is full.") }
    let url = orphansURL(directories)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try writeAtomically(data, to: url)
  }
  /// Undo: these folders lost their Profile. Invalid names ("Default", paths) are never journaled.
  static func journalOrphans(_ names: [String], directories: ProfileDirectories) throws {
    var list = try orphans(directories)
    for name in names where valid(name) && !list.contains(name) { list.append(name) }
    try writeOrphans(list, directories: directories)
  }
  /// Redo: the Profiles are back.
  static func unjournalOrphans(_ names: [String], directories: ProfileDirectories) throws {
    let list = try orphans(directories)
    let remaining = list.filter { !names.contains($0) }
    if remaining != list { try writeOrphans(remaining, directories: directories) }
  }
  #if OPEN_AUTOMATION
  static func journaledOrphans(directories: ProfileDirectories) -> [String] { (try? orphans(directories)) ?? [] }
  #endif
  /// Launch, after the snapshot loaded and before OEEngine.start: wipe every journaled folder that no Profile
  /// of the loaded model uses (folders, engine data, Local State entries), through the pending-wipe journal.
  static func finishOrphanWipes(directories: ProfileDirectories, inUse: Set<String>) throws {
    let names = try orphans(directories)
    guard !names.isEmpty else { return }
    for name in names where !inUse.contains(name.lowercased()) { try enqueue(name, directories: directories) }
    try finishPendingWipes(directories: directories)
    try writeOrphans([], directories: directories)
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
