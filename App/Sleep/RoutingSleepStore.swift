import Foundation
import OpenModel
import OpenSleep
import OpenStore

/// The controller's one `SleepHistoryStoring` (app-shell §4.7): one `SleepStore` per Profile
/// (`Profiles/<dir>/State/sleep.sqlite3`), each opened on first use. A call goes to the store
/// of the tab's owning Profile; a tab with no known Profile uses the default Profile's store.
/// The App's data-root lock (taken in `prepareData`) covers every store for the whole run.
@MainActor
final class RoutingSleepStore: SleepHistoryStoring, ProfileDataOwner {
  private let model: BrowserModel
  private let directories: ProfileDirectories
  private var stores: [String: SleepStore] = [:]
  /// Folders of deleted Profiles (lowercased): never opened, written or read again this run.
  private var retired: Set<String> = []
  /// The Profile folder each tab last saved into, so a purge after the tab left the model
  /// still deletes from the right store.
  private var savedIn: [ItemID: String] = [:]
  /// Every Profile folder that may hold a row of the tab (rows found at start, and this launch's
  /// saves): a tab that moved between Profiles can have a row in each. A purge deletes from all.
  private var storedIn: [ItemID: Set<String>] = [:]
  var onError: ((String) -> Void)?
  /// Tabs with a stored back/forward list (this launch's saves plus the rows found at start).
  private(set) var knownStored: Set<ItemID> = []
  /// Rows deleted (a pinned reset) while the start-up scan runs: its older answer must not add
  /// them back (review r1 #9). Nil when no scan runs.
  private var deletedDuringLoad: Set<ItemID>?
  func loadKnownStored() async {
    deletedDuringLoad = []
    defer { deletedDuringLoad = nil }
    for profile in model.profiles {
      let name = profile.dataDirectoryName
      guard var ids = await store(named: name)?.allTabIDs(), !retired.contains(name.lowercased()) else { continue }
      if let deleted = deletedDuringLoad, !deleted.isEmpty { ids.removeAll { deleted.contains($0) } }
      // A Profile deleted while this query ran keeps nothing.
      knownStored.formUnion(ids)
      for id in ids {
        storedIn[id, default: []].insert(name)
        if savedIn[id] == nil { savedIn[id] = name }
      }
    }
  }

  init(model: BrowserModel, directories: ProfileDirectories) {
    self.model = model; self.directories = directories
  }

  private func directoryName(for tabID: ItemID) -> String {
    var parent = model.parentByID[tabID]
    while let current = parent {
      switch current {
      case .favorites(let id):
        if let name = model.profile(id: id)?.dataDirectoryName { return name }
        parent = nil
      case .spacePinned(let id), .spaceToday(let id):
        if let name = model.space(id: id).flatMap({ model.profile(id: $0.profileID)?.dataDirectoryName }) { return name }
        parent = nil
      case .folder(let id), .splitPane(let id): parent = model.parentByID[id]
      }
    }
    return savedIn[tabID] ?? model.defaultProfile?.dataDirectoryName ?? "Default"
  }

  private func store(named name: String) -> SleepStore? {
    guard !retired.contains(name.lowercased()) else { return nil }
    if let store = stores[name] { return store }
    let store = SleepStore(fileURL: directories.sleepFileURL(dataDirectoryName: name))
    store.onError = { [weak self] in self?.onError?($0) }
    stores[name] = store
    return store
  }

  /// The store file of a tab (automation reads it to prove quit capture).
  func fileURL(for tabID: ItemID) -> URL { directories.sleepFileURL(dataDirectoryName: directoryName(for: tabID)) }

  func save(tabID: ItemID, envelope e: SleepHistoryEnvelope) async throws {
    let name = directoryName(for: tabID)
    guard let store = store(named: name) else { throw CancellationError() }
    try await store.save(SleepHistoryRecord(
      tabID: tabID, container: e.container, currentIndex: e.currentIndex, entryCount: e.entryCount,
      currentURL: e.currentURL, currentTitle: e.currentTitle, faviconURL: e.faviconURL,
      hasPageState: e.hasPageState, containerVersion: e.containerVersion, chromiumTag: e.chromiumTag,
      capturedAt: e.capturedAt))
    // The Profile may have been deleted while the save ran.
    guard !retired.contains(name.lowercased()) else { return }
    savedIn[tabID] = name
    storedIn[tabID, default: []].insert(name)
    knownStored.insert(tabID)
    deletedDuringLoad?.remove(tabID)
  }

  func flush() async throws {
    for (name, store) in stores {
      guard !retired.contains(name.lowercased()) else { continue }
      do { try await store.flush() }
      // A Profile deleted during an earlier await: its closed store is not a quit failure.
      catch where retired.contains(name.lowercased()) { continue }
    }
  }

  func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope? {
    guard let r = await store(named: directoryName(for: tabID))?.load(tabID: tabID) else { return nil }
    return SleepHistoryEnvelope(
      container: r.container, currentIndex: r.currentIndex, entryCount: r.entryCount, currentURL: r.currentURL,
      currentTitle: r.currentTitle, faviconURL: r.faviconURL, hasPageState: r.hasPageState,
      containerVersion: r.containerVersion, chromiumTag: r.chromiumTag, capturedAt: r.capturedAt)
  }

  /// Deletes the tab's row from the store of its current Profile and from every store that may hold
  /// one (a tab that moved to another Profile's Space after a save keeps its row there, also across
  /// a relaunch).
  func deleteSleepHistory(tabID: ItemID) {
    var names = [directoryName(for: tabID)]
    for name in storedIn[tabID] ?? [] where !names.contains(where: { $0.lowercased() == name.lowercased() }) { names.append(name) }
    for name in names { store(named: name)?.delete(tabID: tabID) }
    savedIn[tabID] = nil; storedIn[tabID] = nil
    knownStored.remove(tabID)
    deletedDuringLoad?.insert(tabID)
  }

  /// Every stored row of every Profile's store (automation evidence).
  func storedTabIDs() async -> [ItemID] {
    var ids: [ItemID] = []
    for profile in model.profiles { ids += await store(named: profile.dataDirectoryName)?.allTabIDs() ?? [] }
    return ids
  }

  /// ProfileDataOwner: close the deleted Profile's sleep database before its folder goes, and
  /// never open, write or read it again (a late save, purge or lookup routed to it is dropped).
  func retireProfile(_ profileID: ProfileID, directory: String) async {
    retired.insert(directory.lowercased())
    for (name, store) in stores where name.lowercased() == directory.lowercased() {
      stores[name] = nil
      store.retire()
    }
    // A tab whose row is also in another (live) Profile's store stays known, and saves there now.
    for (id, names) in storedIn where names.contains(where: { $0.lowercased() == directory.lowercased() }) {
      let left = names.filter { $0.lowercased() != directory.lowercased() }
      storedIn[id] = left.isEmpty ? nil : left
      if left.isEmpty { knownStored.remove(id) }
    }
    for (id, name) in savedIn where name.lowercased() == directory.lowercased() {
      savedIn[id] = storedIn[id]?.first
      if storedIn[id] == nil { knownStored.remove(id) }
    }
  }

  /// Open sleep databases (automation evidence: a deleted Profile's store is closed).
  var openDirectoryNames: [String] { stores.keys.sorted() }
}
