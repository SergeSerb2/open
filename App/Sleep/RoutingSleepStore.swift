import Foundation
import OpenModel
import OpenSleep
import OpenStore

/// The controller's one `SleepHistoryStoring` (app-shell §4.7): one `SleepStore` per Profile
/// (`Profiles/<dir>/State/sleep.sqlite3`), each opened on first use. A call goes to the store
/// of the tab's owning Profile; a tab with no known Profile uses the default Profile's store.
/// The App's data-root lock (taken in `prepareData`) covers every store for the whole run.
@MainActor
final class RoutingSleepStore: SleepHistoryStoring {
  let model: BrowserModel
  private let directories: ProfileDirectories
  private var stores: [String: SleepStore] = [:]
  /// The Profile folder each tab last saved into, so a purge after the tab left the model
  /// still deletes from the right store.
  private var savedIn: [ItemID: String] = [:]
  var onError: ((String) -> Void)?
  /// Tabs with a stored back/forward list (this launch's saves plus the rows found at start).
  private(set) var knownStored: Set<ItemID> = []
  func loadKnownStored() async { knownStored.formUnion(await storedTabIDs()) }

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

  private func store(named name: String) -> SleepStore {
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
    try await store(named: name).save(SleepHistoryRecord(
      tabID: tabID, container: e.container, currentIndex: e.currentIndex, entryCount: e.entryCount,
      currentURL: e.currentURL, currentTitle: e.currentTitle, faviconURL: e.faviconURL,
      hasPageState: e.hasPageState, containerVersion: e.containerVersion, chromiumTag: e.chromiumTag,
      capturedAt: e.capturedAt))
    savedIn[tabID] = name
    knownStored.insert(tabID)
  }

  func flush() async throws {
    for store in stores.values { try await store.flush() }
  }

  func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope? {
    guard let r = await store(named: directoryName(for: tabID)).load(tabID: tabID) else { return nil }
    return SleepHistoryEnvelope(
      container: r.container, currentIndex: r.currentIndex, entryCount: r.entryCount, currentURL: r.currentURL,
      currentTitle: r.currentTitle, faviconURL: r.faviconURL, hasPageState: r.hasPageState,
      containerVersion: r.containerVersion, chromiumTag: r.chromiumTag, capturedAt: r.capturedAt)
  }

  func deleteSleepHistory(tabID: ItemID) {
    store(named: directoryName(for: tabID)).delete(tabID: tabID)
    savedIn[tabID] = nil
    knownStored.remove(tabID)
  }

  /// Launch cleanup: deletes the stored back/forward lists of tabs that were already gone
  /// when this run started: not in the sidebar model and not in their Profile's Archive
  /// (Library Delete or Clear in an earlier run, a tab that left for another window).
  /// docs/sleep.md: permanent delete and archive purge remove the row. An archived tab,
  /// also one inside an archived folder, keeps its row: Restore brings it back with its ID.
  /// Tabs in `present` (the model when the controller started) are never touched, so a tab
  /// that left later and that Undo can still bring back keeps its row.
  @discardableResult
  func removeOrphanedRows(present: Set<ItemID>, archive: (ProfileID) -> ArchiveStore) async -> Int {
    var removed = 0
    for profile in model.profiles {
      let store = store(named: profile.dataDirectoryName)
      let missing = Set(await store.allTabIDs()).subtracting(present).filter { model.tab(id: $0) == nil }
      // A Profile deleted during a query has its folder removed; never touch it again.
      guard !missing.isEmpty, model.profile(id: profile.id) === profile,
        let archived = try? await archive(profile.id).archivedIDs(in: missing),
        model.profile(id: profile.id) === profile else { continue }
      // An Archive restore can bring a tab back while the queries run.
      let orphans = missing.subtracting(archived).filter { model.tab(id: $0) == nil }
      guard !orphans.isEmpty else { continue }
      forget(orphans.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }, in: store)
      removed += orphans.count
    }
    return removed
  }

  /// The Archive of the Profile in `directoryName` deleted these rows for good (Library
  /// Delete or Clear). Their tabs' stored lists go too, unless a tab is in the sidebar.
  /// Returns how many of them had a known stored row.
  @discardableResult
  func removeRows(of ids: [ItemID], directoryName: String) -> Int {
    guard model.profiles.contains(where: { $0.dataDirectoryName == directoryName }) else { return 0 }
    let gone = ids.filter { model.tab(id: $0) == nil }
    guard !gone.isEmpty else { return 0 }
    let known = gone.filter { knownStored.contains($0) }.count
    forget(gone, in: store(named: directoryName))
    return known
  }

  private func forget(_ ids: [ItemID], in store: SleepStore) {
    store.delete(tabIDs: ids)
    for id in ids { savedIn[id] = nil; knownStored.remove(id) }
  }

  /// Every stored row of every Profile's store (automation evidence).
  func storedTabIDs() async -> [ItemID] {
    var ids: [ItemID] = []
    for profile in model.profiles { ids += await store(named: profile.dataDirectoryName).allTabIDs() }
    return ids
  }
}
