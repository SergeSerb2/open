import AppKit
import Observation
import OpenBoosts
import OpenEngine
import OpenFeatures
import OpenModel
import OpenSettings
import OpenSiteControl

/// The App's sole owner of per-Profile Boost stores and matcher snapshots.
@MainActor @Observable
final class AppBoosts: BoostsProvider {
  unowned let app: AppDelegate
  private struct State { let store: BoostStore; var matcher: BoostMatcher }
  @ObservationIgnored private var profiles: [ProfileID: State] = [:]
  @ObservationIgnored private var observers: [SiteControlObservationToken: @MainActor () -> Void] = [:]
  @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
  private(set) var revision = 0
  private(set) var boostsGloballyEnabled: Bool
  @ObservationIgnored lazy var adapter = BoostEngineAdapter(boosts: self)
  @ObservationIgnored lazy var editorHost = AppBoostEditorHost(boosts: self)
  @ObservationIgnored private var pendingEditors: [ItemID: BoostID] = [:]

  init(app: AppDelegate) {
    self.app = app
    boostsGloballyEnabled = UserDefaults.standard.object(forKey: "open.advanced.enableBoosts") as? Bool ?? true
    defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.preferencesChanged() }
    }
  }
  isolated deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

  func store(for id: ProfileID) -> BoostStore {
    if let state = profiles[id] { return state.store }
    // Callers resolve a loaded Profile before entering this mutation boundary.
    guard let profile = app.model.profile(id: id) else { preconditionFailure("Boost Profile is not loaded") }
    let store = BoostStore(root: app.directories.root, profileID: id, fileURL: app.directories.boostsFileURL(for: profile))
    let values = store.load() // Exactly once, before editor or Library mutations.
    profiles[id] = State(store: store, matcher: BoostMatcher(boosts: values))
    return store
  }
  func matcher(for id: ProfileID) -> BoostMatcher { _ = store(for: id); return profiles[id]!.matcher }
  func matchingBoosts(url: URL, profileID: ProfileID) -> [Boost] { matcher(for: profileID).matching(url: url) }
  func setBoostEnabled(_ id: BoostID, enabled: Bool, profileID: ProfileID) {
    if store(for: profileID).setEnabled(id: id, enabled: enabled) { refresh(profile: profileID) }
  }
  /// All App mutations, including the editor's commits/undo/delete, end here.
  func refresh(profile: ProfileID) {
    guard app.model.profile(id: profile) != nil else { return }
    let store = store(for: profile)
    profiles[profile]?.matcher.rebuild(boosts: store.allBoosts())
    revision &+= 1
    adapter.refresh(profile: profile)
    for observer in Array(observers.values) { observer() }
  }
  private func preferencesChanged() {
    let enabled = UserDefaults.standard.object(forKey: "open.advanced.enableBoosts") as? Bool ?? true
    guard enabled != boostsGloballyEnabled else { return }
    boostsGloballyEnabled = enabled; revision &+= 1
    adapter.globalSwitchChanged()
    for factory in app.hostFactories.values { factory.controller?.boostEditor?.view?.refresh() }
    for observer in Array(observers.values) { observer() }
  }
  func observeBoostChanges(_ observer: @escaping @MainActor () -> Void) -> SiteControlObservationToken {
    let token = SiteControlObservationToken(); observers[token] = observer; return token
  }
  func removeBoostObserver(_ token: SiteControlObservationToken) { observers[token] = nil }
  func boosts(profileID: ProfileID) -> [BoostItemSnapshot] {
    _ = revision
    guard app.model.profile(id: profileID) != nil else { return [] }
    return store(for: profileID).allBoosts().map { BoostItemSnapshot(id: $0.id.description, name: $0.name, domain: $0.siteMatch.domain, pathPrefix: $0.siteMatch.pathPrefix, isEnabled: $0.isEnabled) }
  }
  func factory(for id: ItemID) -> EngineWebContentHostFactory? {
    app.hostFactories.values.first { $0.hosts[id] != nil }
  }
  func canEdit(tabID: ItemID) -> Bool {
    guard let factory = factory(for: tabID), factory.controller != nil, let host = factory.hosts[tabID], !host.closed,
          !host.content.context.isEphemeral, let url = host.content.url,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
    return true
  }
  func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) {
    guard canEdit(tabID: tabID), let factory = factory(for: tabID), let host = factory.hosts[tabID],
          let controller = factory.controller, let window = controller.window, let url = host.content.url else { return }
    let editor = controller.boostEditor ?? BoostEditorController(host: editorHost)
    controller.boostEditor = editor
    let context = SiteControlContext(tabID: tabID, profileID: host.profileID, url: url, displayHost: url.host ?? "")
    // new-legacy-boost uses simple mode until Step 7 supplies Code mode.
    _ = editor.present(parent: window, contentRect: controller.container.bounds, context: context, boostID: boostID)
  }
  func editCurrent(tabID: ItemID) {
    guard let factory = factory(for: tabID), let host = factory.hosts[tabID], let url = host.content.url else { return }
    openEditor(boostID: matchingBoosts(url: url, profileID: host.profileID).first?.id, tabID: tabID, mode: .simple)
  }
  func pageCommitted(_ host: EngineWebContentHost, url: URL) {
    adapter.committed(host, url: url)
    host.owner?.controller?.boostEditor?.pageDidNavigate(tabID: host.tabID, url: url)
    if let id = pendingEditors.removeValue(forKey: host.tabID) { openEditor(boostID: id, tabID: host.tabID, mode: .simple) }
  }
  func hostClosed(_ host: EngineWebContentHost) {
    pendingEditors[host.tabID] = nil
    host.owner?.controller?.boostEditor?.boundTabDidClose(host.tabID)
    adapter.closed(host)
  }
  func editFromLibrary(id: BoostID, profileID: ProfileID) {
    guard let boost = store(for: profileID).boost(id: id), let space = app.model.spaces.first(where: { $0.profileID == profileID }),
          let url = URL(string: "https://\(boost.siteMatch.targetsIPAddress && boost.siteMatch.domain.contains(":") ? "[\(boost.siteMatch.domain)]" : boost.siteMatch.domain)\(boost.siteMatch.pathPrefix ?? "/")"),
          let controller = app.frontWindowController ?? app.makeWindow(focusedSpaceID: space.id),
          let factory = app.hostFactories[controller.windowID] else { return }
    factory.focus(space: space)
    let before = Set(factory.hosts.keys)
    _ = factory.openNewTab(url: url, background: false)
    if let host = factory.hosts.values.first(where: { !before.contains($0.tabID) && $0.profileID == profileID }) { pendingEditors[host.tabID] = id }
  }
  func saveNow() { for state in profiles.values { state.store.saveNow() } }
  func stop() { adapter.stop(); saveNow() }
}
