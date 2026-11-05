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
  private let model: BrowserModel
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

  /// Every stored row of every Profile's store (automation evidence).
  func storedTabIDs() async -> [ItemID] {
    var ids: [ItemID] = []
    for profile in model.profiles { ids += await store(named: profile.dataDirectoryName).allTabIDs() }
    return ids
  }
}
