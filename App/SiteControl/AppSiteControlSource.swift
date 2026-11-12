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
  /// Content tiles toggled on this tab's origin (kind → allowed). A row set back to its
  /// default leaves the engine's changed list; it stays until the tab leaves the origin,
  /// so the tile under the pointer does not vanish.
  private var toggledContent: [ItemID: (origin: String, allowed: [String: Bool])] = [:]
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
  var capturedContentBlockingTile: (tile: SiteSettingTile, tabID: ItemID)?
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
      security: ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        ? (url.scheme?.lowercased() == "https" && host.content.securityLevel == .secure ? .secure : .insecure) : .unknown)
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
      let adBlockProfileID = factory.incognitoSession?.parent.id ?? profileID
      let privateSession = factory.isIncognito ? factory.incognitoSession?.context?.identifier : nil
      let sessionAvailable = !factory.isIncognito || privateSession.map {
        store?.isPrivateSessionOpen($0, profile: adBlockProfileID) == true
      } == true
      let available = store?.onEngineEvent != nil && store?.isProfileOpen(adBlockProfileID) == true
        && store?.isEnabled == true && sessionAvailable
      let on = available && (try? store?.siteSnapshot(for: adBlockProfileID, privateSession: privateSession).shouldBlock(host: url.host() ?? "")) == true
      tiles.append(SiteSettingTile(id: "contentBlocking", kind: .contentBlocking, title: "Block Ads & Trackers",
        subtitle: on ? "On" : "Off", state: available ? (on ? .on : .off) : .unavailable,
        symbol: "hand.raised.fill", help: available ? (on ? "The built-in ad blocker is on for this site." : "The built-in ad blocker is off for this site.") : "The built-in ad blocker is off. You can turn it on in Settings."))
      if let engineContext = factory.hosts[tabID]?.content.context {
        let permissions = SitePermissionStore.forContext(engineContext)
        for row in Self.permissionRows {
          let state = permissions.currentState(origin: url, kind: row.engine)
          guard state != .ask else { continue }
          tiles.append(SiteSettingTile(id: "permission.\(row.id)", kind: .permission(row.permission), title: row.title,
            subtitle: state == .allow ? "Allowed" : "Blocked", state: state == .allow ? .on : .off, symbol: row.symbol))
        }
        // E1 (SC-11/SC-12): the origin's changed content settings, in Arc's name-table order.
        let changed = Dictionary(EngineWebProfile(engineContext).changedSiteSettings(origin: url).map { ($0.kind, $0.state) },
                                 uniquingKeysWith: { first, _ in first })
        let toggled = toggledContent[tabID].flatMap { $0.origin == Self.originKey(url) ? $0.allowed : nil } ?? [:]
        for row in Self.contentRows {
          guard let allowed = changed[row.kind].map({ $0 == .allow || $0 == .session }) ?? toggled[row.kind] else { continue }
          tiles.append(SiteSettingTile(id: "content.\(row.kind)", kind: .content(row.kind), title: row.title,
            subtitle: allowed ? "Allowed" : "Blocked", state: allowed ? .on : .off, symbol: row.symbol))
        }
      }
    }
    // Matching is read-only. Private windows keep disabled matching rows;
    // the view and the action guards refuse creation, editing and toggles.
    // Private windows have a separate model Profile. Read matching rows from
    // the parent owner's store; private controls and actions remain disabled.
    let boostProfileID = factory.incognitoSession?.parent.id ?? profileID
    let boosts = context.isWebsite ? boostProvider?.matchingBoosts(url: url, profileID: boostProfileID) ?? [] : []
    return SiteControlSnapshot(context: context, tiles: tiles, boosts: boosts,
      boostsGloballyEnabled: boostProvider?.boostsGloballyEnabled ?? true,
      capabilities: factory.extensions.host == nil ? [.clearCache, .securityState] : [.clearCache, .securityState, .extensionPinning],
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
      let adBlockProfileID = factory.incognitoSession?.parent.id ?? snapshot.context.profileID
      let privateSession = factory.isIncognito ? factory.incognitoSession?.context?.identifier : nil
      guard let store = adBlockStore, store.onEngineEvent != nil, store.isEnabled, store.isProfileOpen(adBlockProfileID),
            !factory.isIncognito || privateSession.map({ store.isPrivateSessionOpen($0, profile: adBlockProfileID) }) == true,
            let host = snapshot.context.url.host() else { openAdBlockSettings(tabID: tabID); return }
      do {
        let currentlyBlocking = try store.siteSnapshot(for: adBlockProfileID, privateSession: privateSession).shouldBlock(host: host)
        try store.setExcluded(host, excluded: currentlyBlocking, profile: adBlockProfileID, privateSession: privateSession)
      }
      catch { factory.controller?.toasts.show(.init(title: "Ad blocking settings could not be saved.")) }
    case .permission(let permission):
      guard let row = Self.permissionRows.first(where: { $0.permission == permission }),
            let context = factory.hosts[tabID]?.content.context else { return }
      let store = SitePermissionStore.forContext(context)
      store.set(origin: snapshot.context.url, kind: row.engine,
        state: store.state(origin: snapshot.context.url, kind: row.engine) == .allow ? .block : .allow)
      factory.app.tabSleep.permissionsChanged(context: context)
    case .content(let kind):
      guard Self.contentRows.contains(where: { $0.kind == kind }),
            let context = factory.hosts[tabID]?.content.context else { return }
      let profile = EngineWebProfile(context), origin = snapshot.context.url
      let current = profile.changedSiteSettings(origin: origin).first { $0.kind == kind }?.state
      let key = Self.originKey(origin)
      var entry = toggledContent[tabID].flatMap { $0.origin == key ? $0 : nil } ?? (origin: key, allowed: [:])
      if current == .allow || current == .session || (current == nil && entry.allowed[kind] == true) {
        if profile.setSiteSetting(.block, kind: kind, origin: origin) { entry.allowed[kind] = false }
      } else if profile.setSiteSetting(.allow, kind: kind, origin: origin) {
        entry.allowed[kind] = true
      } else {
        // Guard kinds (USB, HID, …) refuse "allow": back to the default ("ask"); the row leaves.
        profile.setSiteSetting(.ask, kind: kind, origin: origin); entry.allowed[kind] = nil
      }
      toggledContent[tabID] = entry
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
  func showSecurityDetails(tabID: ItemID) {} // Certificate viewer is post-v1.
  func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID) {
    guard kinds == .cookies || kinds == .cache,
          let snapshot = snapshot(for: tabID), snapshot.context.isWebsite,
          let page = factory?.hosts[tabID]?.content else { return }
    PageSiteDataCommands.clearAndRefresh(page, kinds: kinds == .cache ? .cache : .cookies)
  }
  func openURLInNewTab(_ url: URL, tabID: ItemID) {
    guard factory?.selectedTab?.id == tabID else { return }; _ = factory?.openNewTab(url: url, background: false)
  }
  func reload(tabID: ItemID) { factory?.hosts[tabID]?.content.reload() }
  func openAdBlockSettings(tabID: ItemID) {
    #if OPEN_AUTOMATION
    openAdBlockSettingsCallCount += 1
    #endif
    factory?.app.settingsPresenter.show(section: .adBlocking, row: "lists", profileID: factory?.focusedProfile?.id)
  }

  private static func originKey(_ url: URL) -> String {
    "\(url.scheme ?? "")://\(url.host() ?? ""):\(url.port.map(String.init) ?? "")"
  }
  private struct ContentRow { let kind: String, title: String, symbol: String }
  /// Chromium content-setting names shown as tiles when changed for the origin (SC-12 name table
  /// `FUN_10055c864`, same order). Kinds that already have a permission tile are not repeated.
  /// Title case follows the permission tiles (GUESS: Arc's keys are lowercase; capture C-LF-6).
  private static let contentRows: [ContentRow] = [
    .init(kind: "sensors", title: "Motion Sensors", symbol: "gyroscope"),
    .init(kind: "javascript", title: "JavaScript", symbol: "curlybraces"),
    .init(kind: "images", title: "Images", symbol: "photo.fill"),
    .init(kind: "popups", title: "Pop-ups", symbol: "macwindow.badge.plus"),
    .init(kind: "subresource-filter", title: "Intrusive Ads", symbol: "rectangle.slash.fill"),
    .init(kind: "background-sync", title: "Background Sync", symbol: "arrow.triangle.2.circlepath"),
    .init(kind: "sound", title: "Sound", symbol: "speaker.wave.2.fill"),
    .init(kind: "usb-guard", title: "USB Devices", symbol: "cable.connector"),
    .init(kind: "hid-guard", title: "HID Devices", symbol: "keyboard.fill"),
    .init(kind: "serial-guard", title: "Serial Ports", symbol: "cable.connector.horizontal"),
    .init(kind: "bluetooth-guard", title: "Bluetooth Devices", symbol: "antenna.radiowaves.left.and.right"),
    .init(kind: "hand-tracking", title: "Hand Tracking", symbol: "hand.raised.fill"),
    .init(kind: "keyboard-lock", title: "Keyboard Lock", symbol: "lock.fill"),
    .init(kind: "pointer-lock", title: "Pointer Lock", symbol: "cursorarrow"),
    .init(kind: "local-network-access", title: "Local Network", symbol: "network")]

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
