import Foundation
import OpenCommands
import OpenModel
import OpenStore
import OpenSuggest
import OpenAdBlock

/// Shared command-bar backend. Profile stores open on their own actor, on use.
@MainActor
final class AppStores {
  unowned let app: AppDelegate
  private var histories: [ProfileID: HistoryStore] = [:]
  private var currentProfile: ProfileID?
  private var currentSuggest: SuggestEngine?
  /// A read of existing settings must not open the store or load its PSL.
  private(set) var existingAdBlock: AdBlockStore?
  lazy var adBlock: AdBlockStore? = {
    let store = try? AdBlockStore(root: app.directories.root)
    existingAdBlock = store
    return store
  }()
  lazy var favicons = try? FaviconStore(databaseURL: app.directories.root.appendingPathComponent("State/favicons.sqlite3"))
  lazy var sidebarFavicons = favicons.map { StoredFaviconCache(store: $0) }
  init(app: AppDelegate) { self.app = app }

  func history(for profileID: ProfileID?) -> HistoryStore? {
    let profile = profileID == nil ? app.model.defaultProfile : profileID.flatMap { app.model.profile(id: $0) }
    guard let profile else { return nil }
    if let store = histories[profile.id] { return store }
    let store = HistoryStore(fileURL: app.directories.historyFileURL(for: profile))
    histories[profile.id] = store
    return store
  }
  func suggest(for profileID: ProfileID) -> SuggestEngine {
    if currentProfile == profileID, let currentSuggest { return currentSuggest }
    currentSuggest?.cancel()
    let engine = SuggestEngine(model: app.model, historyStore: { [weak self] in self?.history(for: $0) },
      actions: CommandRegistry.makeSuggestRegistry())
    currentProfile = profileID; currentSuggest = engine
    return engine
  }
  func prewarm(profileID: ProfileID) { suggest(for: profileID).prewarm() }
  private var historyTail: Task<Void, Never>?
  private(set) var historyEnqueueSamples: [Double] = []
  private(set) var historyWriteCount = 0
  func noteHistoryEnqueue(milliseconds: Double) {
    #if OPEN_AUTOMATION
    if historyEnqueueSamples.count < 4_096 { historyEnqueueSamples.append(milliseconds) }
    #endif
  }
  func enqueueHistoryVisit(store: HistoryStore, url: URL, time: Date, typed: Bool) -> Task<Int64?, Never> {
    let previous = historyTail
    let visit = Task { await previous?.value
      return await store.recordVisit(url: url, title: "", time: time, transition: typed ? "typed" : "link", typed: typed)
    }
    historyTail = Task { _ = await visit.value; historyWriteCount += 1 }
    return visit
  }
  func enqueueHistoryWrite(_ write: @escaping @Sendable () async -> Void) {
    let previous = historyTail
    historyTail = Task { await previous?.value; await write(); historyWriteCount += 1 }
  }
  func flushHistory() async {
    for host in app.littleOpenHosts.values { await host.historyRecorder.flush() }
    for factory in app.hostFactories.values {
      for host in factory.hosts.values { await host.historyRecorder.flush() }
      for page in factory.auxiliaryPages { await page.historyRecorder?.flush() }
    }
    await historyTail?.value
  }
}
