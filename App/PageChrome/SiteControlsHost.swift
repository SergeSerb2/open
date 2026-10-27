import AppKit
import OpenEngine
import OpenModel
import OpenSiteControl
import OpenWeb
import OpenBoosts

/// App adapter for the merged Step 1 library. Sections/editor remain #96/#103;
/// unavailable actions refuse explicitly instead of changing model/engine state.
@MainActor
final class SiteControlsHost: SiteControlDataSource, SiteControlActions {
  weak var owner: EngineWebContentHostFactory?
  private var controller: SiteControlController?
  private var observers: [SiteControlObservationToken: @MainActor (ItemID) -> Void] = [:]
  private weak var observedModel: BrowserModel?
  private var modelObserver: UUID?
  private var windowObserver: (any NSObjectProtocol)?
  private weak var boundPage: OEWebContent?
  private var boundURL: URL?
  private var closed = false
  private(set) var requests = 0
  private(set) var lastRequest: [String: Any] = [:]

  init(owner: EngineWebContentHostFactory) {
    self.owner = owner; observedModel = owner.model
    modelObserver = owner.model.addObserver { [weak self] _ in self?.refresh() }
    windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignMainNotification, object: owner.window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }
  private func page(for tabID: ItemID) -> OEWebContent? {
    guard !closed, let owner, owner.app.engineReady, !owner.isClosing, !owner.app.terminationRequested,
          owner.selectedTab?.id == tabID, let page = owner.selectedContent, page.isLive else { return nil }
    return page
  }
  private func origin(_ url: URL) -> URL? {
    var value = URLComponents(url: url, resolvingAgainstBaseURL: false)
    value?.path = ""; value?.query = nil; value?.fragment = nil; return value?.url
  }
  func snapshot(for tabID: ItemID) -> SiteControlSnapshot? {
    guard let owner, let page = page(for: tabID), let url = page.url,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(),
          let profile = owner.app.settingsPresenter.profile(for: page.context), let origin = origin(url) else { return nil }
    let permissions: [(SitePermission, OEPermissionKind, String)] = [(.camera,.camera,"Camera"),(.microphone,.microphone,"Microphone"),
      (.geolocation,.geolocation,"Location"),(.notifications,.notifications,"Notifications"),(.clipboard,.clipboard,"Clipboard")]
    let tiles = permissions.compactMap { permission, kind, title -> SiteSettingTile? in
      let state = page.context.permissionState(for: kind, origin: origin)
      guard state != .ask else { return nil }
      return SiteSettingTile(id: title.lowercased(), kind: .permission(permission), title: title,
        subtitle: state == .allow ? "Allowed" : "Blocked", state: state == .allow ? .on : .off, symbol: "checkmark.shield")
    }
    let extensions = owner.focusedBrowser.map { Array(EngineExtensionHost($0).extensionActions.prefix(64)) } ?? []
    return SiteControlSnapshot(context: SiteControlContext(tabID: tabID, profileID: profile.id, url: url,
      displayHost: host, security: .unknown), tiles: tiles,
      boostsGloballyEnabled: UserDefaults.standard.object(forKey: "open.advanced.enableBoosts") as? Bool ?? true,
      extensions: extensions, capabilities: [.changedSettings],
      commandsEnabled: ["share-page":true,"capture-page":false,"capture-full-page":false,"new-boost":false])
  }
  func observeChanges(_ observer: @escaping @MainActor (ItemID) -> Void) -> SiteControlObservationToken {
    let token = SiteControlObservationToken(); observers[token] = observer; return token
  }
  func removeChangeObserver(_ token: SiteControlObservationToken) { observers[token] = nil }
  func refresh() {
    guard !closed, let id = controller?.tabID else { return }
    if owner?.selectedContent !== boundPage || owner?.selectedContent?.url != boundURL { dismiss(); return }
    for observer in Array(observers.values) { observer(id) }
  }
  @discardableResult func present() -> Bool {
    guard let owner, let window = owner.window, window.isKeyWindow, NSApp.isActive,
          window.attachedSheet == nil, owner.commandBarSession?.isPresented != true,
          let tabID = owner.selectedTab?.id, let snapshot = snapshot(for: tabID), let root = owner.controller?.contentView,
          let anchor = owner.controller?.sidebar.siteControlsAnchorView, !anchor.isHiddenOrHasHiddenAncestor else { return false }
    if controller == nil {
      let presenter = SiteControlController(source: self, actions: self)
      presenter.view.frame = root.bounds; presenter.view.autoresizingMask = [.width,.height]
      presenter.geometry = { [weak self] _ in
        guard let self, let browser = self.owner?.controller, let root = Optional(browser.contentView),
              let anchor = Optional(browser.sidebar.siteControlsAnchorView), !anchor.isHiddenOrHasHiddenAncestor else { return nil }
        return SiteControlGeometry(anchor: root.convert(anchor.bounds, from: anchor),
          content: browser.container.frame)
      }
      root.addSubview(presenter.view); controller = presenter
    }
    boundPage = owner.selectedContent; boundURL = boundPage?.url
    let rect = root.convert(anchor.bounds, from: anchor)
    requests += 1
    lastRequest = ["tab":tabID.description,"profile":snapshot.context.profileID.description,
      "origin":origin(snapshot.context.url)?.absoluteString ?? "", "anchor":[rect.minX,rect.minY,rect.width,rect.height]]
    controller?.toggle(anchor: .urlField, tabID: tabID)
    owner.record("siteControls", boundPage, ["shown":controller?.isPresented == true])
    return controller?.isPresented == true
  }
  func ownsEditingKey(_ event: NSEvent) -> Bool {
    guard let view = event.window?.firstResponder as? NSView, let overlay = controller?.view,
          controller?.isPresented == true, view === overlay || view.isDescendant(of: overlay) else { return false }
    return event.modifierFlags.intersection([.command,.control,.option]).isEmpty
  }
  func dismiss() { controller?.dismiss(reason: .sourceUnavailable, animated: false) }
  func close() {
    guard !closed else { return }; closed = true
    dismiss(); controller = nil // breaks the library's strong source/action references
    if let modelObserver { observedModel?.removeObserver(modelObserver) }; modelObserver = nil
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
    observers.removeAll(); boundPage = nil
  }
  var state: [String: Any] {
    let anchor = owner?.controller.map { $0.contentView.convert($0.sidebar.siteControlsAnchorView.bounds, from: $0.sidebar.siteControlsAnchorView) }
    return ["anchor":anchor.map { [$0.minX,$0.minY,$0.width,$0.height] } ?? [], "available":!closed,"visible":controller?.isPresented == true,"requests":requests,"request":lastRequest,
      "panel":controller.map { [$0.view.panelFrame.minX,$0.view.panelFrame.minY,$0.view.panelFrame.width,$0.view.panelFrame.height] } ?? [],
      "pending":"#96/#103"]
  }
  private func unavailable(_ message: String) { owner?.controller?.showToast(message, undo: nil) }
  func toggle(_ tile: SiteSettingTile, tabID: ItemID) {
    guard let page = page(for: tabID), page === boundPage, page.url == boundURL,
          let url = page.url, let origin = origin(url) else { return }
    if case .permission(let permission) = tile.kind, permission != .screenCapture {
      let profile = EngineWebProfile(page.context)
      profile.setPermission(profile.permission(permission, origin: origin) == .allow ? .block : .allow, for: permission, origin: origin)
      refresh()
    } else { unavailable("This site setting is not available yet.") }
  }
  func setBoostEnabled(_ id: BoostID, enabled: Bool, tabID: ItemID) { unavailable("Boost controls are not available yet.") }
  func openEditor(boostID: BoostID?, tabID: ItemID, mode: BoostEditorMode) { unavailable("The Boost editor is not available yet.") }
  func perform(command: String, tabID: ItemID, anchor: NSRect?) {
    guard page(for: tabID) != nil else { return }
    if owner?.performAppCommand(command) != true { unavailable("This page action is not available yet.") }
  }
  func runExtension(_ id: String, tabID: ItemID, anchor: NSRect) {
    guard page(for: tabID) != nil, let browser = owner?.focusedBrowser, browser.extensionActions.contains(where: { $0.extensionIdentifier == id && $0.isEnabled }) else { return }
    _ = browser.executeExtensionAction(id)
  }
  func setExtensionPinned(_ id: String, pinned: Bool) { unavailable("Extension pinning is not available yet.") }
  func showSecurityDetails(tabID: ItemID) { unavailable("Certificate details are not available yet.") }
  func clearSiteData(_ kinds: SiteDataKinds, tabID: ItemID) {
    guard let page = page(for: tabID), let url = page.url, let origin = origin(url) else { return }
    guard kinds == .cookies else { unavailable("Only site cookies can be cleared in this build."); return }
    page.context.clearBrowsingData(origin: origin) { [weak self] in self?.refresh() }
  }
  func openURLInNewTab(_ url: URL, tabID: ItemID) {
    guard page(for: tabID) != nil, ["http","https","chrome"].contains(url.scheme?.lowercased() ?? "") else { return }
    _ = owner?.openNewTab(url: url, background: false, opener: tabID)
  }
  func reload(tabID: ItemID) { page(for: tabID)?.reload() }
}
