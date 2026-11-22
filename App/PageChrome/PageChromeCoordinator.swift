import AppKit
import OpenEngine
import OpenModel

/// Event-driven ownership for one browser window. No launch work or idle timer.
@MainActor
final class PageChromeCoordinator {
  unowned let owner: EngineWebContentHostFactory
  let dialogs = PageDialogPresenter()
  private var existingPermissions: PermissionPromptPresenter?
  /// Bind Site Control geometry without constructing permission UI at launch.
  var permissionAnchorProvider: ((OEWebContent) -> PermissionPromptPresenter.Anchor?)? {
    didSet { existingPermissions?.anchorProvider = permissionAnchorProvider }
  }
  var permissions: PermissionPromptPresenter {
    if let existingPermissions { return existingPermissions }
    let presenter = PermissionPromptPresenter(owner: owner)
    presenter.anchorProvider = permissionAnchorProvider
    existingPermissions = presenter
    return presenter
  }
  func owns(_ window: NSWindow) -> Bool { existingPermissions?.owns(window) == true }
  func permissionPage(in window: NSWindow) -> OEWebContent? {
    window === owner.window || existingPermissions?.owns(window) == true ? existingPermissions?.presentedPage : nil
  }
  func handleKey(_ event: NSEvent) -> Bool { existingPermissions?.handleKey(event) == true }
  private var observed: Set<ObjectIdentifier> = []
  private var closeRequests: [ObjectIdentifier: (Bool) -> Void] = [:]
  /// Pages whose shell-started close (a tab close, Quit) waits on their beforeunload sheet while
  /// they are not on screen (a Peek under another Peek). The sheet shows anyway: a hidden one
  /// blocked the renderer and the close (or Quit) for good (bug sweep r4 WC-02, WC-03).
  private var closingOffscreen: Set<ObjectIdentifier> = []
  init(owner: EngineWebContentHostFactory) {
    self.owner = owner
    dialogs.isVisible = { [weak self] in self?.isVisible($0) == true }
    dialogs.record = { [weak owner] in owner?.record($0, $1, $2) }
    dialogs.onDecision = { [weak self] page, kind, accepted in
      if kind == .beforeUnload || self?.dialogs.hasPending(page) == false { self?.closingOffscreen.remove(ObjectIdentifier(page)) }
      if kind == .beforeUnload, !accepted { self?.closeRequests.removeValue(forKey: ObjectIdentifier(page))?(false) }
      self?.existingPermissions?.presentPending()
    }
  }
  func isVisible(_ page: OEWebContent) -> Bool {
    if closingOffscreen.contains(ObjectIdentifier(page)) { return true }
    if let surface = owner.standaloneSurface, surface.surfacePage === page {
      return surface.isSurfaceVisible
    }
    if owner.visibleTabs.contains(where: { owner.contents[$0.id] === page }) { return true }
    return owner.selectedContent === page || owner.auxiliaryPages.contains { $0.content === page && $0.panel.isVisible }
  }
  private func observe(_ page: OEWebContent) {
    guard observed.insert(ObjectIdentifier(page)).inserted else { return }
    // Start only on first use. Main-frame commits (including reload) have a
    // new loader; same-document history changes must not reset suppression.
    page.sendDevToolsMethod("Page.enable", parameters: nil, completion: nil)
  }
  func run(_ dialog: OEJavaScriptDialog, page: OEWebContent) -> Bool {
    dialogs.window = page.view.window ?? owner.window
    observe(page)
    if owner.dialogPolicy == "accept" || owner.dialogPolicy == "dismiss" {
      owner.record("dialog", page, ["kind": dialog.kind.rawValue, "message": dialog.message,
        "default": dialog.defaultPromptText, "title": PageDialogPresenter.title(dialog),
        "buttons": PageDialogPresenter.buttons(dialog), "suppressible": false, "queued": false])
      let accepted = owner.dialogPolicy == "accept"
      dialog.complete(accepted: accepted, text: accepted ? owner.promptText ?? dialog.defaultPromptText : nil)
      if dialog.kind == .beforeUnload, !accepted { closeRequests.removeValue(forKey: ObjectIdentifier(page))?(false) }
    } else {
      // A close the user started asks now, over the page it closes: show that page (a
      // background tab), or show the sheet over this window when the page cannot be shown.
      let key = ObjectIdentifier(page)
      if dialog.kind == .beforeUnload, closeRequests[key] != nil, !isVisible(page) {
        owner.revealPageForClose(page)
        if !isVisible(page) { closingOffscreen.insert(key) }
      }
      dialogs.enqueue(dialog, page: page, held: owner.dialogPolicy == "hold")
    }
    return true
  }
  func request(_ request: OEPermissionRequest, page: OEWebContent) -> Bool {
    var event: [String: Any] = ["origin": request.origin.absoluteString, "kinds": request.kinds.rawValue]
    if let scheme = request.protocolHandlerScheme { event["protocolScheme"] = scheme }
    if let template = request.protocolHandlerURLTemplate { event["protocolURLTemplate"] = template }
    owner.record("permission", page, event)
    switch owner.permissionPolicy {
    case "grant": request.grant(); owner.app.tabSleep.permissionsChanged(context: page.context)
    case "deny": request.deny(); owner.app.tabSleep.permissionsChanged(context: page.context)
    default: observe(page); permissions.request(request, page: page)
    }
    return true
  }
  func visibilityChanged() { dialogs.presentNext(); existingPermissions?.visibilityChanged() }
  func event(_ method: String, parameters: [String: Any], page: OEWebContent) {
    guard method == "Page.frameNavigated", let frame = parameters["frame"] as? [String: Any], frame["parentId"] == nil else { return }
    dialogs.navigated(page); existingPermissions?.cancel(page: page)
  }
  /// CEF cancelled the page's pending dialogs (navigation, close; also after each closed
  /// dialog): their sheets go. Suppression state stays (that is per document).
  func engineResetDialogs(_ page: OEWebContent) {
    if dialogs.hasPending(page) { owner.record("dialogReset", page, [:]); dialogs.cancel(page: page) }
  }
  func engineDismissed(_ request: OEPermissionRequest) { existingPermissions?.engineDismissed(request) }
  func cancel(_ page: OEWebContent) {
    observed.remove(ObjectIdentifier(page)); closingOffscreen.remove(ObjectIdentifier(page))
    dialogs.navigated(page); existingPermissions?.cancel(page: page)
    closeRequests.removeValue(forKey: ObjectIdentifier(page))?(false)
  }
  func close() {
    dialogs.close(); existingPermissions?.close(); observed.removeAll(); closingOffscreen.removeAll()
    // A window closing while its page's beforeunload reply is pending answers "stay" to every waiter.
    // Dropping them left the quit preflight running forever, so every later quit was refused.
    let pending = closeRequests; closeRequests.removeAll()
    for completion in pending.values { completion(false) }
  }

  /// Page.close enters Chromium's own beforeunload path. Destruction and model
  /// mutation occur only after its close delegate callback, on the next turn.
  @discardableResult
  func requestClose(_ page: OEWebContent, completion: @escaping (Bool) -> Void) -> Bool {
    // Every close path shares this preflight. A terminated or unresponsive page
    // must not hold closing behind a DevTools beforeunload round trip.
    guard !owner.isClosing, page.crashState == .none else { return false }
    let key = ObjectIdentifier(page)
    // A close already waits on this page's beforeunload (a tab close, then Quit): both callers
    // get the one answer. Dropping the second completion left the quit preflight running forever.
    if let pending = closeRequests[key] {
      closeRequests[key] = { accepted in pending(accepted); completion(accepted) }
      return true
    }
    guard page.hasUnloadHandlers, !dialogs.hasPending(page) else { return false }
    closeRequests[key] = completion
    page.sendDevToolsMethod("Page.close", parameters: nil) { [weak self] _, error in
      if error != nil { self?.closeRequests.removeValue(forKey: key)?(false) }
    }
    return true
  }
  /// An open or queued dialog that is not this close's own beforeunload: the page cannot run
  /// beforeunload until it is answered.
  func dialogBlocksClose(_ page: OEWebContent) -> Bool {
    closeRequests[ObjectIdentifier(page)] == nil && dialogs.hasPending(page)
  }
  /// A live page with unload handlers and such a dialog: a close must not skip its beforeunload.
  func closeBlockedByDialog(_ page: OEWebContent) -> Bool {
    page.crashState == .none && page.hasUnloadHandlers && dialogBlocksClose(page)
  }
  /// Shows a page's queued dialogs over its window even though the page is not on screen (a
  /// Peek under another Peek), until they are answered: a stopped Quit or close must never
  /// leave nothing to answer.
  func showDialogsOffscreen(_ page: OEWebContent) {
    if !isVisible(page) { closingOffscreen.insert(ObjectIdentifier(page)) }
    visibilityChanged()
  }
  func pageRequestedClose(_ page: OEWebContent) -> Bool {
    closingOffscreen.remove(ObjectIdentifier(page))
    guard let completion = closeRequests.removeValue(forKey: ObjectIdentifier(page)) else { return false }
    DispatchQueue.main.async { completion(true) }
    return true
  }
}

/// Quit preflight uses the same engine-owned close flow, without deleting any
/// sidebar tabs. Cancel returns to the running App; accepted sidebar pages are
/// rebuilt on selection, while accepted standalone windows finish closing.
@MainActor
final class PageQuitCoordinator {
  unowned let app: AppDelegate
  private var running = false
  private var accepted = false
  private var remaining: [(EngineWebContentHostFactory, OEWebContent)] = []
  private struct Selection {
    weak var owner: EngineWebContentHostFactory?
    let focusedSpaceID: SpaceID
    let selectedNodeBySpace: [SpaceID: ItemID]
  }
  private var selections: [Selection] = []
  init(app: AppDelegate) { self.app = app }
  func shouldTerminate() -> Bool {
    if app.quitWarning.withoutPrompts { return true }
    #if OPEN_AUTOMATION
    // A dead runner cannot answer a new beforeunload request. Normal quit
    // still runs the page preflight; owner shutdown closes hosts directly.
    if AutomationOwnerWatch.quittingWithoutPrompts { return true }
    #endif
    if accepted { return true }
    if running { return false }
    var seen: Set<ObjectIdentifier> = []
    let owners = (Array(app.hostFactories.values) + app.littleOpenHosts.values.compactMap(\.owner))
      .filter { !$0.isIncognito && seen.insert(ObjectIdentifier($0)).inserted }
    remaining = owners.flatMap { owner in
      owner.contents.values.filter(\.hasUnloadHandlers).map { (owner, $0) }
    }
    if remaining.isEmpty { return true }
    selections = owners.map { Selection(owner: $0, focusedSpaceID: $0.windowState.focusedSpaceID,
      selectedNodeBySpace: $0.windowState.selectedNodeBySpace) }
    running = true; next(); return false
  }
  private func next() {
    guard !remaining.isEmpty else {
      // Preflight selects background pages to show their dialogs. Persist the
      // user's selection, without rebuilding an engine page already closed by
      // Page.close. The final quit snapshot follows this restoration.
      for selection in selections {
        guard let owner = selection.owner,
          owner.model.windows.contains(where: { $0 === owner.windowState }) else { continue }
        owner.windowState.selectedNodeBySpace = selection.selectedNodeBySpace.filter {
          owner.model.space(id: $0.key) != nil && owner.model.node(id: $0.value) != nil
        }
        if owner.model.space(id: selection.focusedSpaceID) != nil {
          owner.windowState.focusedSpaceID = selection.focusedSpaceID
        }
      }
      selections.removeAll()
      running = false; accepted = true; NSApp.terminate(nil); return
    }
    let (owner, page) = remaining.removeFirst()
    // A window or tab closed while an earlier page was asked: nothing left to ask here.
    guard !owner.isClosing, owner.contents.values.contains(where: { $0 === page }) else { next(); return }
    if let window = owner.standaloneSurface?.surfaceWindow {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil); owner.standaloneSurfaceVisibilityChanged()
    }
    else if let window = owner.window {
      // A sheet on a minimized or hidden window is never seen: Quit would wait for ever.
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    if let id = owner.tabID(for: page), let space = owner.space(containing: id) { owner.focus(space: space); owner.select(nodeID: id) }
    // Page.close destroys an accepted page before the normal quit snapshot.
    // Preserve its browser-owned history first, without stopping tab sleep
    // (the user may still cancel this quit).
    Task { @MainActor [weak self, weak owner, weak page] in
      guard let self else { return }
      // A page or window closed meanwhile has nothing left to ask; keep the preflight
      // moving, or `running` stays set and every later quit attempt is refused.
      guard let owner, let page else { self.next(); return }
      if let id = owner.tabID(for: page), let envelope = self.app.tabSleep.adapter?.captureHistory(tabID: id) {
        try? await self.app.tabSleep.store?.save(tabID: id, envelope: envelope)
      }
      // The save can suspend: a close meanwhile already ran pageChrome.close()/cancel(), so a new
      // close request would never be answered.
      guard !owner.isClosing, owner.contents.values.contains(where: { $0 === page }) else { self.next(); return }
      self.askClose(owner: owner, page: page)
    }
  }
  private func askClose(owner: EngineWebContentHostFactory, page: OEWebContent) {
    // The page shows a dialog (or has one queued): its beforeunload cannot run until that
    // dialog is answered, and requestClose would skip the page, so Quit lost its unsaved
    // changes without asking. Stop this Quit and leave the page and its dialog on screen
    // (bug sweep r4 WC-02); the next Quit asks again.
    if owner.pageChrome.closeBlockedByDialog(page) {
      running = false; remaining.removeAll(); selections.removeAll()
      app.quitWarning.resetApproval()
      // This ends the quit, as "Stay" does: report the cancel (the attempt was waiting to retry).
      app.updater?.userDriver.applicationTerminationCancelled()
      app.updater?.userDriver.clearInstallationRelaunchRequest()
      owner.pageChrome.showDialogsOffscreen(page)
      return
    }
    let waits = owner.pageChrome.requestClose(page) { [weak self, weak owner, weak page] allowed in
      guard let self else { return }
      if allowed {
        if let owner, let page, let id = owner.tabID(for: page) {
          if owner.standaloneSurface?.surfacePage === page {
            // Page.close has destroyed the browser. On this deferred turn its
            // unload handlers are gone, so the normal session close completes
            // without another preflight or a stranded standalone host.
            owner.hosts[id]?.onCloseRequest?()
          } else { owner.controller?.container.closeHost(for: id) }
        }
        self.next()
      } else {
        self.running = false; self.remaining.removeAll(); self.selections.removeAll()
        self.app.quitWarning.resetApproval()
        // The quit returned "cancel" only to wait for this reply; this is the real cancel.
        self.app.updater?.userDriver.applicationTerminationCancelled()
        self.app.updater?.userDriver.clearInstallationRelaunchRequest()
      }
    }
    if !waits { next() }
  }
}

/// One beforeunload round for a close of many pages at once: a window close, or a bulk archive
/// or delete in the sidebar (bug sweep r6 WL-04, P-01). These used to destroy every page with a
/// forced close, so unsaved input went without a prompt. As Chrome's window close does, each
/// page with a beforeunload handler asks in turn, through the same `requestClose` as Cmd+W and
/// Quit. "Stay" on any page cancels the whole action and keeps every tab. A page that already
/// agreed has closed (Page.close destroys it): its tab stays and rebuilds on selection, from the
/// back list stored before it asked, as after Quit's preflight.
@MainActor
final class PageCloseBatch {
  /// Weak: a save of the page's history can suspend while the window closes and its factory
  /// goes (review r1 #1). The factory also cancels its batch when it closes.
  private weak var owner: EngineWebContentHostFactory?
  private var remaining: [ItemID]
  private var action: (() -> Void)?
  private let restoresSelection: Bool
  private let focusedSpaceID: SpaceID
  private let selectedNodeBySpace: [SpaceID: ItemID]
  private(set) var isRunning = false

  /// The tabs among `ids` whose live page in this window would ask before it closes.
  static func asking(_ ids: [ItemID], in owner: EngineWebContentHostFactory) -> [ItemID] {
    var seen: Set<ItemID> = []
    return ids.filter { id in
      guard seen.insert(id).inserted, let host = owner.hosts[id], !host.closed else { return false }
      return host.content.crashState == .none && host.content.hasUnloadHandlers
    }
  }

  init(owner: EngineWebContentHostFactory, ids: [ItemID], restoresSelection: Bool, action: @escaping () -> Void) {
    self.owner = owner; remaining = ids; self.action = action; self.restoresSelection = restoresSelection
    focusedSpaceID = owner.windowState.focusedSpaceID; selectedNodeBySpace = owner.windowState.selectedNodeBySpace
  }

  func start() { isRunning = true; next() }
  /// The window closes: nothing more is asked and the action never runs.
  func cancel() { isRunning = false; remaining.removeAll(); action = nil }

  private func next() {
    guard isRunning else { return }
    // The window closed meanwhile (its pageChrome answered every waiter "stay"): nothing to do.
    guard let owner, !owner.isClosing else { end(); return }
    guard !remaining.isEmpty else { finish(); return }
    let id = remaining.removeFirst()
    guard let host = owner.hosts[id], !host.closed, host.content.crashState == .none,
          host.content.hasUnloadHandlers else { next(); return }
    let page = host.content
    Task { @MainActor [weak self, weak page] in
      guard let self, self.isRunning else { return }
      guard let page, let owner = self.owner, !owner.isClosing else { self.next(); return }
      // Page.close destroys an accepted page before the action runs. Keep its browser-owned
      // history first, so a later "Stay" keeps the tab with its back list (as Quit does).
      let app = owner.app
      if owner.model === app.model, let tab = app.model.tab(id: id),
         let envelope = app.tabSleep.adapter?.captureHistory(host: host, tab: tab) {
        try? await app.tabSleep.store?.save(tabID: id, envelope: envelope)
      }
      // The save can suspend: a close meanwhile already answered or cancelled this page.
      guard self.isRunning, let owner = self.owner, !owner.isClosing, owner.hosts[id] === host, !host.closed else { self.next(); return }
      self.ask(id: id, host: host, page: page, owner: owner)
    }
  }

  private func ask(id: ItemID, host: EngineWebContentHost, page: OEWebContent, owner: EngineWebContentHostFactory) {
    // A page that also shows a dialog cannot run beforeunload until it is answered: stop the
    // action and leave the page and its dialog on screen, as a tab close does (bug sweep r4 WC-02).
    if owner.pageChrome.closeBlockedByDialog(page) {
      owner.revealPageForClose(page); owner.pageChrome.showDialogsOffscreen(page); end(); return
    }
    let waits = owner.pageChrome.requestClose(page) { [weak self] accepted in
      guard let self, self.isRunning else { return }
      guard accepted else { self.end(); return }
      // Page.close has destroyed the browser: the tab shows a placeholder from now on. A Peek
      // page leaves its Peek stack, as after its own window.close() (review r1 #5).
      if let owner = self.owner, owner.hosts[id] === host {
        if owner.model.tab(id: id) == nil, let controller = owner.controller, controller.hasPeekController,
           controller.peekController.stack.contains(where: { $0.host?.tabID == id }) {
          controller.peekController.pageClosed(hostTabID: id)
        } else { owner.controller?.container.closeHost(for: id); host.close() }
      }
      self.next()
    }
    if !waits { next() }
  }

  private func finish() {
    if restoresSelection, let owner, owner.model.windows.contains(where: { $0 === owner.windowState }) {
      // A sheet selected each background page that asked. The action acts on the user's own
      // selection, as before it asked. Written directly: a selection here would wake a page
      // for a tab the action is about to archive.
      owner.windowState.selectedNodeBySpace = selectedNodeBySpace.filter {
        owner.model.space(id: $0.key) != nil && owner.model.node(id: $0.value) != nil
      }
      if owner.model.space(id: focusedSpaceID) != nil { owner.windowState.focusedSpaceID = focusedSpaceID }
    }
    let action = self.action
    end()
    action?()
  }

  private func end() {
    isRunning = false; remaining.removeAll(); action = nil
    owner?.closeBatchEnded(self)
  }
}
