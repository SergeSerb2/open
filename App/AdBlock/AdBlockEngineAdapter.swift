#if OPEN_AUTOMATION
import OpenOnboarding
#endif
import Foundation
import OpenAdBlock
import OpenEngine
import OpenModel

/// Context configuration precedes requests. Fresh Profiles seed immediately;
/// existing generations keep their store opening after paint.
@MainActor
final class AdBlockEngineAdapter {
  unowned let app: AppDelegate
  private weak var store: AdBlockStore?
  private var directories: [ProfileID: String] = [:]
  // OEEngine.contexts exposes regular contexts only. Do not retain OTR sessions.
  private let otrContexts = NSHashTable<OEBrowserContext>.weakObjects()
  private var openings: [ProfileID: Task<Void, Never>] = [:]
  private var startupReads: [ProfileID: Task<Void, Never>] = [:]
  private var startupConfigurations: [ProfileID: AdBlockStartupConfiguration] = [:]
  private var startupDirectoryNames: [ProfileID: String] = [:]
  private var startupGenerationMissing: [ProfileID: Bool] = [:]
  private(set) var started = false
  /// Scriptlets and `:style()` rules (PB2 row 1); the engine applies the rest.
  private(set) lazy var extras = AdBlockExtrasAdapter(app: app)

  init(app: AppDelegate) { self.app = app }

  var isSupported: Bool {
    #if OPEN_AUTOMATION && DEBUG
    // Binding verification only: never changes the engine's support claim.
    if ProcessInfo.processInfo.environment["OPEN_ADBLOCK_AUTOMATION_FORCE_SUPPORTED"] == "1" { return true }
    #endif
    return OEBrowserContext.adBlockSupported
  }

  func bind(_ store: AdBlockStore) {
    self.store = store
    guard isSupported else { store.onEngineEvent = nil; return }
    store.onEngineEvent = { [weak self] event in self?.apply(event) }
    if started { for profile in app.model.profiles { openAfterPaint(profile) } }
  }

  /// Compose with the sleep policy, which owns onProfileCreated. The task runs
  /// after BrowserModel inserts the Profile, including Undo and import swaps.
  func installProfilePolicy() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.installProfilePolicy")
    defer { pacingRegion?.end() }
    #endif
    let previous = app.model.onProfileCreated
    app.model.onProfileCreated = { [weak self] profile in
      previous?(profile)
      self?.readStartupConfiguration(profile)
      self?.openAfterPaint(profile)
    }
    for profile in app.model.profiles { readStartupConfiguration(profile) }
    if started { for profile in app.model.profiles { openAfterPaint(profile) } }
  }

  private func readStartupConfiguration(_ profile: Profile) {
    guard isSupported, !app.shutdownPrepared,
      startupDirectoryNames[profile.id] != profile.dataDirectoryName else { return }
    let id = profile.id
    let name = profile.dataDirectoryName
    startupReads.removeValue(forKey: id)?.cancel()
    startupConfigurations[id] = nil
    startupGenerationMissing[id] = nil
    startupDirectoryNames[id] = name
    let root = app.directories.root
    let directory = app.directories.adBlockDirectory(dataDirectoryName: name)
    let read = Task.detached(priority: .userInitiated) {
      let fresh = AdBlockStore.hasNoGeneration(directory: directory)
      let configuration = try? AdBlockStore.startupConfiguration(root: root, directory: directory)
      return (fresh, configuration)
    }
    startupReads[id] = Task { [weak self] in
      let (fresh, configuration) = await read.value
      guard let self else { return }
      guard !Task.isCancelled, self.startupDirectoryNames[id] == name else { return }
      self.startupReads[id] = nil
      guard !self.app.shutdownPrepared,
        self.app.model.profile(id: id)?.dataDirectoryName == name,
        self.store?.isRetired(id) != true else { return }
      self.startupGenerationMissing[id] = fresh
      if let configuration { self.startupConfigurations[id] = configuration }
      for context in self.contexts(for: id) { self.configureBeforeRequests(context, profileID: id) }
      if fresh, !self.contexts(for: id).isEmpty, let profile = self.app.model.profile(id: id) {
        self.openProfile(profile, beforePaint: true)
      }
    }
  }

  /// Also configure Default when launch has no selected page yet. No context is created here.
  func engineDidInitialize() {
    guard let profile = app.model.defaultProfile else { return }
    contextCreated(OEEngine.shared.defaultContext, profileID: profile.id)
  }

  func startAfterPaint() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.startAfterPaint")
    defer { pacingRegion?.end() }
    #endif
    guard !started, !app.shutdownPrepared else { return }
    started = true
    // A store that already exists is bound; open its Profiles now. Otherwise
    // prepare it on a worker: bind(_:) opens every Profile once it is installed.
    if app.stores.existingAdBlock != nil {
      for profile in app.model.profiles { openAfterPaint(profile) }
    } else {
      app.stores.prepareAdBlockInBackground()
    }
  }

  private func openAfterPaint(_ profile: Profile) {
    guard started else { return }
    openProfile(profile, beforePaint: false)
  }

  private func openProfile(_ profile: Profile, beforePaint: Bool) {
    // Without engine support, launch opens nothing (no list update schedule);
    // Settings still opens the Profile it shows, as before.
    guard isSupported, !app.shutdownPrepared, store?.isRetired(profile.id) != true,
      openings[profile.id] == nil, store?.isProfileOpen(profile.id) != true else { return }
    openings[profile.id] = Task { [weak self] in
      guard let self else { return }
      defer { self.openings[profile.id] = nil }
      guard !Task.isCancelled, self.app.model.profile(id: profile.id) != nil else { return }
      let openedStore: AdBlockStore?
      if beforePaint { openedStore = await self.app.stores.adBlockForFreshProfile() }
      else { openedStore = self.store }
      guard !Task.isCancelled, !self.app.shutdownPrepared,
        self.app.model.profile(id: profile.id)?.dataDirectoryName == profile.dataDirectoryName,
        let store = openedStore, !store.isRetired(profile.id) else { return }
      do {
        try await store.openProfile(profile.id,
          directory: self.app.directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName))
      } catch {
        // Settings reports the store error when opened. Do not log a path or site.
        if !store.isRetired(profile.id) && !Task.isCancelled {
          FileHandle.standardError.write(Data("Open: ad-block Profile configuration could not be opened.\n".utf8))
        }
      }
    }
  }

  func contextCreated(_ context: OEBrowserContext, profileID: ProfileID) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.contextCreated")
    defer { pacingRegion?.end() }
    #endif
    if context.originalContext != nil { otrContexts.add(context) }
    guard let profile = app.model.profile(id: profileID) else { return }
    configureBeforeRequests(context, profileID: profileID)
    if isSupported { extras.contextCreated(context, profileID: profileID) }
    readStartupConfiguration(profile)
    if startupGenerationMissing[profileID] == true { openProfile(profile, beforePaint: true) }
    openAfterPaint(profile)
  }

  func contextClosed(_ context: OEBrowserContext) {
    guard context.originalContext != nil else { return }
    otrContexts.remove(context)
    store?.closePrivateSession(context.identifier)
  }

  private func configureBeforeRequests(_ context: OEBrowserContext, profileID: ProfileID) {
    guard isSupported, store?.isRetired(profileID) != true,
      let profile = app.model.profile(id: profileID) else { return }
    let startup = startupConfigurations[profileID]
    // Do not construct the IO-backed store before paint. Until the async read
    // arrives, use the existing in-memory setting, or the product default (on).
    let enabled = store?.isEnabled ?? startup?.isEnabled ?? true
    let excluded: [String]
    if let store, store.isProfileOpen(profileID) { excluded = store.excludedDomains(for: profileID) }
    else { excluded = startup?.excludedDomains ?? [] }
    let directory = (try? store?.listDirectory(for: profileID))
      ?? app.directories.adBlockListsDirectory(dataDirectoryName: profile.dataDirectoryName)
    configure(context, profile: profileID, directory: directory, enabled: enabled, excluded: excluded)
  }

  func contexts(for profile: ProfileID) -> [OEBrowserContext] {
    guard let identifier = directories[profile] ?? app.model.profile(id: profile)?.dataDirectoryName else { return [] }
    return (OEEngine.shared.contexts + otrContexts.allObjects).filter {
      $0.state == .live && ($0.identifier == identifier || $0.originalContext?.identifier == identifier)
    }
  }

  private func configure(_ context: OEBrowserContext, profile: ProfileID, directory: URL, enabled: Bool, excluded: [String]) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.configure")
    defer { pacingRegion?.end() }
    #endif
    var effective = excluded
    // Before the store opens, keep #287's read-only startup configuration.
    // Register a private session only after its parent's configuration exists.
    if let store, store.isProfileOpen(profile) {
      let session = context.originalContext == nil ? nil : context.identifier
      if let session {
        do { try store.openPrivateSession(session, profile: profile) }
        catch {
          context.isAdBlockEnabled = false
          context.adBlockListDirectory = nil
          return
        }
      }
      effective = store.excludedDomains(for: profile, privateSession: session)
    }
    context.adBlockExcludedDomains = effective
    context.adBlockListDirectory = directory
    context.isAdBlockEnabled = enabled
  }

  private func apply(_ event: AdBlockEngineEvent) {
    guard app.engineReady, !app.shutdownPrepared else { return }
    #if OPEN_AUTOMATION
    let region = StartupMainThreadTrace.begin("adBlock.apply")
    defer { StartupMainThreadTrace.end(region) }
    #endif
    switch event {
    case let .configure(profile, directory, enabled, excluded):
      guard let model = app.model.profile(id: profile) else { return }
      directories[profile] = model.dataDirectoryName
      for context in contexts(for: profile) {
        let alreadySet = context.adBlockListDirectory == directory
        configure(context, profile: profile, directory: directory, enabled: enabled, excluded: excluded)
        // Early loading may have found no current.json. Setting the same path
        // is a native no-op, so explicitly retry after the store has seeded it.
        if alreadySet { context.reloadAdBlockLists() }
      }
    case let .enabled(enabled):
      for profile in app.model.profiles where store?.isProfileOpen(profile.id) == true {
        for context in contexts(for: profile.id) { context.isAdBlockEnabled = enabled }
      }
    case let .exclusions(profile, _):
      for context in contexts(for: profile) {
        context.adBlockExcludedDomains = store?.excludedDomains(for: profile,
          privateSession: context.originalContext == nil ? nil : context.identifier) ?? []
      }
    case let .privateExclusions(profile, session, domains):
      for context in contexts(for: profile) where context.originalContext != nil && context.identifier == session {
        context.adBlockExcludedDomains = domains
      }
    case let .reload(profile, _):
      for context in contexts(for: profile) { context.reloadAdBlockLists() }
    case let .closed(profile):
      startupReads.removeValue(forKey: profile)?.cancel()
      startupConfigurations[profile] = nil
      startupDirectoryNames[profile] = nil
      startupGenerationMissing[profile] = nil
      for context in contexts(for: profile) {
        context.isAdBlockEnabled = false
        context.adBlockListDirectory = nil
      }
      directories[profile] = nil
    }
    extras.storeChanged(event, store: store)
  }

  func stop() {
    for task in startupReads.values { task.cancel() }
    startupReads.removeAll()
    for task in openings.values { task.cancel() }
    openings.removeAll()
  }
}
