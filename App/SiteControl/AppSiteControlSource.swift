import AppKit
import OpenAdBlock
import OpenBoosts
import OpenEngine
import OpenModel
import OpenSiteControl
import OpenWeb

/// The Boost runtime owns matching, persistence and the editor. The SCC only
/// reads its values and forwards actions. Nil is the supported interim state.
@MainActor protocol SiteControlBoostProvider: AnyObject {
  var boostsGloballyEnabled: Bool { get }
  func matchingBoosts(url: URL, profileID: ProfileID) -> [Boost]
  func setBoostEnabled(_ id: BoostID, enabled: Bool, profileID: ProfileID)
  func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode)
  func observeBoostChanges(_ observer: @escaping @MainActor () -> Void) -> SiteControlObservationToken
  func removeBoostObserver(_ token: SiteControlObservationToken)
}

@MainActor
final class AppSiteControlSource: SiteControlDataSource, SiteControlActions {
  weak var factory: EngineWebContentHostFactory?
  weak var boostProvider: (any SiteControlBoostProvider)? {
    willSet { if let boostToken { boostProvider?.removeBoostObserver(boostToken) }; boostToken = nil }
    didSet { boostToken = boostProvider?.observeBoostChanges { [weak self] in self?.refresh() }; refresh() }
  }
  private var boostToken: SiteControlObservationToken?
  private var observers: [SiteControlObservationToken: @MainActor (ItemID) -> Void] = [:]
  private var notifications: [any NSObjectProtocol] = []
  private var modelToken: UUID?
  private var pendingTabs: Set<ItemID> = []
  private var refreshPending = false
  // Keep the token's owner alive until removal. The weak factory can already
  // be nil when its stored source is released during window teardown.
  private let model: BrowserModel
  #if OPEN_AUTOMATION
  private(set) var snapshotReadCount = 0
  private(set) var buttonReadCount = 0
  private(set) var changeDeliveryCount = 0
  private(set) var toggleCallCount = 0
  private(set) var openAdBlockSettingsCallCount = 0
  #endif
  private var adBlockStore: AdBlockStore? { factory?.app.stores.existingAdBlock }
  init(factory: EngineWebContentHostFactory) {
    self.factory = factory
    model = factory.model
    // Read only the existing owner. The unavailable row needs no store, so
    // creating this source must not load the catalog and PSL during launch.
    // Settings or the engine adapter opens it; its notifications refresh us.
    // Structural edits and page title/favicon/loading changes do not change
    // SCC rows. The window owns selection/dismissal; only a Profile rebind
    // needs a data-source notification here.
    modelToken = model.addObserver { [weak self] change in
      guard case .spaceProfileChanged(let id, _, _) = change,
            self?.factory?.focusedSpace?.id == id else { return }
      self?.refresh()
    }
    for name in [SitePermissionStore.didChange, AdBlockStore.didChange] {
      notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    }
  }
  isolated deinit {
    if let modelToken { model.removeObserver(modelToken) }
    if let boostToken { boostProvider?.removeBoostObserver(boostToken) }
    notifications.forEach(NotificationCenter.default.removeObserver)
  }
  func refresh(tabID: ItemID? = nil) {
    guard let factory, !factory.isClosing else { return }
    let visible = Set(factory.visibleTabs.map(\.id))
    pendingTabs.formIntersection(visible)
    if let tabID { if visible.contains(tabID) { pendingTabs.insert(tabID) } }
    else { pendingTabs.formUnion(visible) }
    guard !pendingTabs.isEmpty, !refreshPending else { return }
    refreshPending = true
    // Store/URL events can arrive in a burst. Never rebuild the same bound
    // panel once per event or fan out a full snapshot through button updates.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshPending = false
      let changed = self.pendingTabs; self.pendingTabs.removeAll(keepingCapacity: true)
      guard let factory = self.factory, !factory.isClosing else { return }
      let visible = Set(factory.visibleTabs.map(\.id))
      let callbacks = Array(self.observers.values)
      for id in changed.intersection(visible) {
        #if OPEN_AUTOMATION
        self.changeDeliveryCount += 1
        #endif
        for observer in callbacks { observer(id) }
      }
    }
  }
  func observeChanges(_ observer: @escaping @MainActor (ItemID) -> Void) -> SiteControlObservationToken {
    let token = SiteControlObservationToken(); observers[token] = observer; return token
  }
  func removeChangeObserver(_ token: SiteControlObservationToken) { observers.removeValue(forKey: token) }
  private func context(for tabID: ItemID) -> SiteControlContext? {
    guard let factory, !factory.isClosing, factory.standaloneSurface == nil,
          let tab = factory.model.tab(id: tabID), let host = factory.hosts[tabID], !host.closed,
          factory.model.profile(id: host.profileID) != nil else { return nil }
    let url = host.content.url ?? tab.url
    guard url.scheme != "about", !url.absoluteString.isEmpty else { return nil }
    return SiteControlContext(tabID: tabID, profileID: host.profileID, url: url,
      displayHost: url.host() ?? url.absoluteString,
      isIncognito: factory.isIncognito,
      security: url.scheme == "https" ? .secure : url.scheme == "http" ? .insecure : .unknown)
  }
  func buttonState(for tabID: ItemID) -> (available: Bool, boosted: Bool) {
    #if OPEN_AUTOMATION
    buttonReadCount += 1
    #endif
    guard let context = context(for: tabID) else { return (false, false) }
    let boosted = context.isWebsite && !context.isIncognito && boostProvider?.boostsGloballyEnabled == true
      && boostProvider?.matchingBoosts(url: context.url, profileID: context.profileID).contains(where: \.isEnabled) == true
    return (true, boosted)
  }
  func snapshot(for tabID: ItemID) -> SiteControlSnapshot? {
    #if OPEN_AUTOMATION
    snapshotReadCount += 1
    #endif
    guard let factory, let context = context(for: tabID) else { return nil }
    let url = context.url, profileID = context.profileID
    var tiles: [SiteSettingTile] = []
    if context.isWebsite {
      let store = adBlockStore
      // Settings can open the store before the App has an engine adapter.
      // Configuration alone must never claim that requests are being blocked.
      let available = store?.onEngineEvent != nil && store?.isProfileOpen(profileID) == true && store?.isEnabled == true
      let on = available && (try? store?.siteSnapshot(for: profileID).shouldBlock(host: url.host() ?? "")) == true
      tiles.append(SiteSettingTile(id: "contentBlocking", kind: .contentBlocking, title: "Block Ads & Trackers",
        subtitle: on ? "On" : "Off", state: available ? (on ? .on : .off) : .unavailable,
        symbol: "hand.raised.fill", help: available ? (on ? "The built-in ad blocker is on for this site." : "The built-in ad blocker is off for this site.") : "The built-in ad blocker is off. You can turn it on in Settings."))
      if let engineContext = factory.hosts[tabID]?.content.context {
        let permissions = SitePermissionStore.forContext(engineContext)
        for row in Self.permissionRows {
          let state = permissions.state(origin: url, kind: row.engine)
          guard state != .ask else { continue }
          tiles.append(SiteSettingTile(id: "permission.\(row.id)", kind: .permission(row.permission), title: row.title,
            subtitle: state == .allow ? "Allowed" : "Blocked", state: state == .allow ? .on : .off, symbol: row.symbol))
        }
      }
    }
    let boosts = context.isWebsite && !context.isIncognito ? boostProvider?.matchingBoosts(url: url, profileID: profileID) ?? [] : []
    return SiteControlSnapshot(context: context, tiles: tiles, boosts: boosts,
      boostsGloballyEnabled: boostProvider?.boostsGloballyEnabled ?? true,
      capabilities: factory.extensions.host == nil ? [] : [.extensionPinning],
      commandsEnabled: ["new-boost": boostProvider != nil && !context.isIncognito, "share-page": true,
        "capture-page": context.isWebsite, "capture-full-page": context.isWebsite])
  }
  func toggle(_ tile: SiteSettingTile, tabID: ItemID) {
    #if OPEN_AUTOMATION
    toggleCallCount += 1
    #endif
    guard let factory, let snapshot = snapshot(for: tabID), snapshot.context.isWebsite else { return }
    switch tile.kind {
    case .contentBlocking:
      guard let store = adBlockStore, store.onEngineEvent != nil, store.isEnabled, store.isProfileOpen(snapshot.context.profileID),
            let host = snapshot.context.url.host() else { openAdBlockSettings(tabID: tabID); return }
      do { try store.setExcluded(host, excluded: tile.state == .on, profile: snapshot.context.profileID) }
      catch { factory.controller?.toasts.show(.init(title: "Ad blocking settings could not be saved.")) }
    case .permission(let permission):
      guard let row = Self.permissionRows.first(where: { $0.permission == permission }),
            let context = factory.hosts[tabID]?.content.context else { return }
      let store = SitePermissionStore.forContext(context)
      store.set(origin: snapshot.context.url, kind: row.engine,
        state: store.state(origin: snapshot.context.url, kind: row.engine) == .allow ? .block : .allow)
      factory.app.tabSleep.permissionsChanged(context: context)
    case .content: break // E1 is not available in this distribution.
    }
  }
  func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID) {
    guard let context = snapshot(for: tabID)?.context, context.isWebsite, !context.isIncognito else { return }
    boostProvider?.setBoostEnabled(id, enabled: enabled, profileID: context.profileID)
  }
  func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) {
    guard snapshot(for: tabID)?.canCreateBoost == true else { return }
    boostProvider?.openEditor(boostID: boostID, tabID: tabID, mode: mode)
  }
  func perform(command: String, tabID: ItemID, anchor: NSRect?) {
    guard let factory, factory.selectedTab?.id == tabID,
          ["share-page", "capture-page", "capture-full-page", "view-boosts", "manage-extensions", "add-extension"].contains(command) else { return }
    _ = factory.performAppCommand(command)
  }
  func runExtension(_ id: String, tabID: ItemID, anchor: NSRect) {
    guard factory?.selectedTab?.id == tabID else { return }; factory?.extensions.run(id, source: .menuEntry)
  }
  func setExtensionPinned(_ id: String, pinned: Bool) { factory?.extensions.host?.setPinned(pinned, extensionID: id) }
  func showSecurityDetails(tabID: ItemID) {} // E3: the footer is a static label.
  func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID) {
    guard kinds == .cookies, let snapshot = snapshot(for: tabID), snapshot.context.isWebsite,
          let page = factory?.hosts[tabID]?.content else { return }
    // Main's non-nil-origin API clears host cookies only (not Domain= cookies).
    // Keep Clear Cache hidden until E2 supplies a scoped cache operation.
    page.context.clearBrowsingData(origin: snapshot.context.url) {}
  }
  func openURLInNewTab(_ url: URL, tabID: ItemID) {
    guard factory?.selectedTab?.id == tabID else { return }; _ = factory?.openNewTab(url: url, background: false)
  }
  func reload(tabID: ItemID) { factory?.hosts[tabID]?.content.reload() }
  func openAdBlockSettings(tabID: ItemID) {
    #if OPEN_AUTOMATION
    openAdBlockSettingsCallCount += 1
    #endif
    factory?.app.settingsPresenter.show(pane: .advanced)
  }

  private struct PermissionRow {
    let permission: SitePermission, engine: OEPermissionKind, id: String, title: String, symbol: String
  }
  private static let permissionRows: [PermissionRow] = [
    .init(permission: .camera, engine: .camera, id: "camera", title: "Camera", symbol: "video.fill"),
    .init(permission: .microphone, engine: .microphone, id: "microphone", title: "Microphone", symbol: "mic.fill"),
    .init(permission: .geolocation, engine: .geolocation, id: "geolocation", title: "Location", symbol: "location.fill"),
    .init(permission: .notifications, engine: .notifications, id: "notifications", title: "Notifications", symbol: "bell.fill"),
    .init(permission: .clipboard, engine: .clipboard, id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard.fill"),
    .init(permission: .midi, engine: .MIDI, id: "midi", title: "MIDI Devices", symbol: "pianokeys"),
    .init(permission: .screenCapture, engine: .screenCapture, id: "screenCapture", title: "Screen Sharing", symbol: "rectangle.on.rectangle"),
    .init(permission: .automaticDownloads, engine: .multipleDownloads, id: "automaticDownloads", title: "Automatic Downloads", symbol: "arrow.down.circle.fill"),
    .init(permission: .storageAccess, engine: .storageAccess, id: "storageAccess", title: "Storage Access", symbol: "externaldrive.fill"),
    .init(permission: .windowManagement, engine: .windowManagement, id: "windowManagement", title: "Window Management", symbol: "macwindow.on.rectangle"),
    .init(permission: .localFonts, engine: .localFonts, id: "localFonts", title: "Fonts", symbol: "textformat"),
    .init(permission: .idleDetection, engine: .idleDetection, id: "idleDetection", title: "Idle Detection", symbol: "moon.zzz.fill")]
}
