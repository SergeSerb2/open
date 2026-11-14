import Foundation
import OpenCommands
import OpenModel
import OpenStore
import OpenSuggest
import OpenAdBlock

/// Shared command-bar backend. Profile stores open on their own actor, on use.
@MainActor
final class AppStores: ProfileDataOwner {
  unowned let app: AppDelegate
  private var histories: [ProfileID: HistoryStore] = [:]
  private var currentProfile: ProfileID?
  private var currentSuggest: SuggestEngine?
  lazy var boosts = AppBoosts(app: app)
  private var adBlockStorage: AdBlockStore?
  private var attemptedAdBlock = false
  private var adBlockPreparation: Task<AdBlockStore?, Never>?
  /// A read of existing settings must not open the store or load its PSL.
  var existingAdBlock: AdBlockStore? { adBlockStorage }
  var adBlock: AdBlockStore? {
    if !attemptedAdBlock {
      attemptedAdBlock = true
      let bundle = Bundle.main.resourceURL?.appendingPathComponent("AdBlock")
      app.startupRegion("adBlock.storeInit") {
        adBlockStorage = try? AdBlockStore(root: app.directories.root,
          bundledDefaultsDirectory: bundle.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
      }
      if let adBlockStorage { app.startupRegion("adBlock.bind") { app.adBlockEngineAdapter.bind(adBlockStorage) } }
    }
    return adBlockStorage
  }
  /// Fresh Profiles need a store before paint. Prepare its files on a worker,
  /// then install/bind on the main actor. Concurrent fresh contexts share it.
  func adBlockForFreshProfile() async -> AdBlockStore? {
    if let adBlockStorage { return adBlockStorage }
    if let adBlockPreparation { return await adBlockPreparation.value }
    guard !attemptedAdBlock, !app.shutdownPrepared else { return nil }
    attemptedAdBlock = true
    let root = app.directories.root
    let bundle = Bundle.main.resourceURL?.appendingPathComponent("AdBlock")
    let prepare = Task.detached(priority: .userInitiated) {
      let existingBundle = bundle.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      return try? AdBlockStore.prepare(root: root, bundledDefaultsDirectory: existingBundle)
    }
    let task = Task<AdBlockStore?, Never> { [weak self] in
      let preparation = await prepare.value
      guard let self else { return nil }
      defer { self.adBlockPreparation = nil }
      guard !self.app.shutdownPrepared else { return nil }
      guard let preparation else { self.app.settingsPresenter.adBlockStoreFailedToOpen(); return nil }
      var store: AdBlockStore!
      // Installing a prepared store performs no file IO on the main actor.
      self.app.startupRegion("adBlock.install") {
        store = AdBlockStore(preparation: preparation)
        self.adBlockStorage = store
        self.app.adBlockEngineAdapter.bind(store)
        self.app.settingsPresenter.adBlockStoreDidOpen(store)
      }
      return store
    }
    adBlockPreparation = task
    return await task.value
  }
  /// After-paint start-up and early Settings use the worker preparation above,
  /// never the synchronous getter: its lease, catalog, pins, resources and PSL
  /// reads cost about 22 ms (M5) to 60 ms (M1) on the main thread. Returns false
  /// when no store can come (an earlier attempt failed or shutdown began).
  @discardableResult
  func prepareAdBlockInBackground() -> Bool {
    if adBlockStorage != nil || adBlockPreparation != nil { return true }
    guard !attemptedAdBlock, !app.shutdownPrepared else { return false }
    Task { _ = await self.adBlockForFreshProfile() }
    return true
  }
  lazy var favicons = try? FaviconStore(databaseURL: app.directories.root.appendingPathComponent("State/favicons.sqlite3"))
  lazy var sidebarFavicons = favicons.map { StoredFaviconCache(store: $0) }
  init(app: AppDelegate) { self.app = app; app.profileTeardown.register(self) }

  func retireProfile(_ profileID: ProfileID, directory: String) async {
    await adBlockStorage?.retireProfile(profileID)
    // Close the history database before its folder is removed. Queued visits
    // for this Profile then find no database instead of reopening the file.
    if let store = histories.removeValue(forKey: profileID) { await store.close() }
    app.archiveSink.retire(directoryName: directory)
  }

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
    engine.providers.append(SettingsSuggestionsProvider())
    engine.providers.append(EaselsProvider(catalog: app.easelSearch.catalog))
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
