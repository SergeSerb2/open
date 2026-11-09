#if OPEN_AUTOMATION
import OpenOnboarding
#endif
import Foundation
import OpenAdBlock
import OpenEngine
import OpenModel

/// Store events are the only mutation path. Native contexts remain lazy.
@MainActor
final class AdBlockEngineAdapter {
  unowned let app: AppDelegate
  private weak var store: AdBlockStore?
  private var directories: [ProfileID: String] = [:]
  // OEEngine.contexts exposes regular contexts only. Do not retain OTR sessions.
  private let otrContexts = NSHashTable<OEBrowserContext>.weakObjects()
  private var openings: [ProfileID: Task<Void, Never>] = [:]
  private(set) var started = false

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
      self?.openAfterPaint(profile)
    }
    if started { for profile in app.model.profiles { openAfterPaint(profile) } }
  }

  func startAfterPaint() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.startAfterPaint")
    defer { pacingRegion?.end() }
    #endif
    guard !started, !app.shutdownPrepared else { return }
    started = true
    _ = app.stores.adBlock // Binds events before any Profile opens.
    for profile in app.model.profiles { openAfterPaint(profile) }
  }

  private func openAfterPaint(_ profile: Profile) {
    // Without engine support, launch opens nothing (no list update schedule);
    // Settings still opens the Profile it shows, as before.
    guard isSupported, started, !app.shutdownPrepared, let store, !store.isRetired(profile.id),
      openings[profile.id] == nil, !store.isProfileOpen(profile.id) else { return }
    openings[profile.id] = Task { [weak self] in
      guard let self else { return }
      defer { self.openings[profile.id] = nil }
      guard !Task.isCancelled, self.app.model.profile(id: profile.id) != nil else { return }
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
    openAfterPaint(profile)
    guard isSupported, let store, !store.isRetired(profileID), let directory = try? store.listDirectory(for: profileID) else { return }
    configure(context, directory: directory, enabled: store.isEnabled, excluded: store.excludedDomains(for: profileID))
  }

  func contexts(for profile: ProfileID) -> [OEBrowserContext] {
    guard let identifier = directories[profile] ?? app.model.profile(id: profile)?.dataDirectoryName else { return [] }
    return (OEEngine.shared.contexts + otrContexts.allObjects).filter {
      $0.state == .live && ($0.identifier == identifier || $0.originalContext?.identifier == identifier)
    }
  }

  private func configure(_ context: OEBrowserContext, directory: URL, enabled: Bool, excluded: [String]) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("adblock.configure")
    defer { pacingRegion?.end() }
    #endif
    context.adBlockExcludedDomains = excluded
    context.adBlockListDirectory = directory
    context.isAdBlockEnabled = enabled
  }

  private func apply(_ event: AdBlockEngineEvent) {
    guard app.engineReady, !app.shutdownPrepared else { return }
    switch event {
    case let .configure(profile, directory, enabled, excluded):
      guard let model = app.model.profile(id: profile) else { return }
      directories[profile] = model.dataDirectoryName
      for context in contexts(for: profile) { configure(context, directory: directory, enabled: enabled, excluded: excluded) }
    case let .enabled(enabled):
      for profile in app.model.profiles where store?.isRetired(profile.id) == false {
        for context in contexts(for: profile.id) { context.isAdBlockEnabled = enabled }
      }
    case let .exclusions(profile, domains):
      for context in contexts(for: profile) { context.adBlockExcludedDomains = domains }
    case let .reload(profile, _):
      for context in contexts(for: profile) { context.reloadAdBlockLists() }
    case let .closed(profile):
      for context in contexts(for: profile) {
        context.isAdBlockEnabled = false
        context.adBlockListDirectory = nil
      }
      directories[profile] = nil
    }
  }

  func stop() {
    for task in openings.values { task.cancel() }
    openings.removeAll()
  }
}
