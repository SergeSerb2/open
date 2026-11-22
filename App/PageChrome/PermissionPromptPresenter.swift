import AppKit
import OpenEngine
import OpenDesign

@MainActor
final class PermissionPromptPresenter: NSObject, NSPopoverDelegate {
  struct Anchor {
    let view: NSView
    let rect: CGRect
    let edge: NSRectEdge
    let name: String
    init(view: NSView, rect: CGRect, edge: NSRectEdge = .maxY, name: String = "site-control") {
      self.view = view; self.rect = rect; self.edge = edge; self.name = name
    }
  }
  /// Section 12 replaces this with the Site Control button's bounds.
  var anchorProvider: ((OEWebContent) -> Anchor?)?
  private struct Entry {
    let page: OEWebContent
    let request: OEPermissionRequest
    let previous: [UInt32: OEPermissionState]
  }
  weak var owner: EngineWebContentHostFactory?
  private var entries: [Entry] = []
  private var current: Entry?
  var presentedPage: OEWebContent? { current?.page }
  private let popover = NSPopover()
  private let view = PermissionPromptView()
  private var card: PermissionPromptCard?
  private var presentedWindow: NSWindow? { card?.window ?? (popover.isShown ? view.window : nil) }
  private var isShown: Bool { card?.superview != nil || popover.isShown }
  private var finishing = false
  private var closed = false
  private var observers: [any NSObjectProtocol] = []
  private var anchorState: [String: Any] = [:]
  private(set) var decisions = 0
  init(owner: EngineWebContentHostFactory) {
    self.owner = owner; super.init()
    let controller = NSViewController(); controller.view = view
    popover.contentViewController = controller; popover.contentSize = view.frame.size
    popover.behavior = .applicationDefined; popover.animates = false; popover.delegate = self
    view.allow.onPress = { [weak self] in self?.finish(.allow) }
    view.notNow.onPress = { [weak self] in self?.finish(.block) }
    view.onFocusRequest = { [weak self] in self?.focusPrompt() }
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.presentPending() }
      })
    }
  }
  func request(_ request: OEPermissionRequest, page: OEWebContent) {
    guard !closed, let owner, !owner.isClosing else { request.dismiss(); return }
    guard entries.filter({ $0.page === page }).count + (current?.page === page ? 1 : 0) < PageChromeLimits.pendingRequests,
          request.origin.absoluteString.utf8.count <= PageChromeLimits.urlBytes,
          request.kinds.rawValue != 0, request.kinds.rawValue & ~UInt32(0x80001fff) == 0,
          (request.protocolHandlerScheme ?? "").utf8.count <= 64 else {
      owner.record("pageChromeRefused", page, ["reason": "Permission request exceeds queue, origin or kind limits."])
      request.dismiss(); return
    }
    let store = SitePermissionStore.forContext(page.context)
    let kinds = SitePermissionStore.kinds.filter { request.kinds.contains($0.0) }
    let previous = Dictionary(uniqueKeysWithValues: kinds.map { ($0.0.rawValue, store.state(origin: request.origin, kind: $0.0)) })
    if previous.values.contains(.block) { request.deny(); return }
    if previous.values.allSatisfy({ $0 == .allow }) { request.grant(); return }
    entries.append(Entry(page: page, request: request, previous: previous)); presentPending()
  }
  static func question(origin: URL, kinds: OEPermissionKind, protocolScheme: String? = nil) -> String {
    let site = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.host ?? "this website"
    switch kinds {
    // navigator.registerProtocolHandler. The mail wording is Arc's (PB1, E-questions 07:05).
    case .protocolHandler where protocolScheme == "mailto": return "Make \(site) your default mail app?"
    case .protocolHandler: return "Allow \(site) to open all \(protocolScheme ?? "these") links?"
    case .notifications: return "Allow \(site) to send you notifications?"
    case .idleDetection: return "Allow \(site) to know when you’re actively using this device?"
    case .multipleDownloads: return "Allow \(site) to download multiple files?"
    case .storageAccess: return "Allow \(site) to store files on your device?"
    default:
      let nouns = SitePermissionStore.kinds.filter { kinds.contains($0.0) }.map(\.1)
      let joined = nouns.count > 1 ? nouns.dropLast().joined(separator: ", ") + " and " + nouns.last! : nouns.first ?? "permissions"
      return "Allow \(site) to access your \(joined)?"
    }
  }
  /// One rule for showing and for keeping a prompt (bug sweep r4 WC-08): the page is on screen
  /// (the focused page, any Split pane, Little Open's page, a shown popup panel's page). An
  /// unfocused pane's prompt used to show and then be dismissed by the next visibility update.
  private func canShow(_ page: OEWebContent) -> Bool {
    guard let owner, owner.pageChrome.isVisible(page) else { return false }
    // A shown Peek covers the window's tabs and panes: only the Peek's page (or a popup, or
    // Little Open's page) may prompt; a covered tab's prompt waits (it used to stay over the Peek).
    if let controller = owner.controller, controller.hasPeekController, controller.peekController.isShown,
       owner.selectedContent !== page, !isPopupPage(page), owner.standaloneSurface?.surfacePage !== page { return false }
    return true
  }
  private func isPopupPage(_ page: OEWebContent) -> Bool { owner?.auxiliaryPages.contains { $0.content === page } == true }
  private func defaultAnchor(for page: OEWebContent) -> Anchor? {
    guard let owner, owner.pageChrome.isVisible(page) else { return nil }
    // A popup panel's prompt points into that panel, not at the browser window's address field.
    // Before the controller check: Little Open's popups have no window controller.
    if isPopupPage(page) {
      let target = page.view
      return Anchor(view: target, rect: CGRect(x: 24, y: target.isFlipped ? 0 : target.bounds.maxY - 1, width: 1, height: 1),
                    edge: target.isFlipped ? .maxY : .minY, name: "popup-content-top-left")
    }
    guard let controller = owner.controller else { return nil }
    let sidebar = controller.sidebar
    // The sidebar's address field shows the focused page: an unfocused Split pane's prompt
    // points at its own toolbar or into the pane.
    if owner.selectedContent === page, owner.windowState.sidebarMode == .anchored, !sidebar.isHidden, sidebar.urlFieldVisible {
      return Anchor(view: sidebar, rect: sidebar.chromeGeometry.urlField, name: "sidebar-url")
    }
    if let bar = controller.container.slots.first(where: { $0.tabID == owner.tabID(for: page) })?.paneChrome, bar.role == .toolbar {
      return Anchor(view: bar, rect: bar.urlAreaFrame, name: "toolbar-url")
    }
    let target = page.view
    return Anchor(view: target, rect: CGRect(x: 24, y: target.isFlipped ? 0 : target.bounds.maxY - 1, width: 1, height: 1),
                  edge: target.isFlipped ? .maxY : .minY, name: "content-top-left")
  }
  func presentPending() {
    guard !closed, !finishing, current == nil, let owner, !owner.isClosing,
          NSApp.isActive,
          let index = entries.firstIndex(where: { canShow($0.page) }) else { return }
    let entry = entries[index]
    guard let targetWindow = entry.page.view.window ?? owner.window, targetWindow.attachedSheet == nil else { return }
    // A permission can arrive in the same turn that creates the toolbar.
    // Resolve native geometry before NSPopover validates the anchor rect.
    owner.controller?.contentView.layoutSubtreeIfNeeded()
    let surface = owner.standaloneSurface
    let standalone = surface?.surfacePage === entry.page
    let anchor: Anchor
    if standalone {
      guard let surfaceAnchor = surface?.surfaceAnchor(),
            let root = entry.page.view.superview else { return }
      // A title-bar capsule is outside the page. In that case use its surface root.
      let contentRoot = entry.page.view.isDescendant(of: surfaceAnchor.view) ? surfaceAnchor.view : root
      anchor = Anchor(view: contentRoot, rect: contentRoot.bounds, name: "little-open-content")
    } else {
      guard let normal = anchorProvider?(entry.page) ?? defaultAnchor(for: entry.page) else { return }
      anchor = normal
    }
    guard anchor.view.window != nil else { return }
    entries.remove(at: index); current = entry
    view.hasKeyboard = false
    view.question.stringValue = Self.question(origin: entry.request.origin, kinds: entry.request.kinds,
                                                  protocolScheme: entry.request.protocolHandlerScheme)
    let symbol = SitePermissionStore.kinds.first(where: { entry.request.kinds.contains($0.0) })?.2 ?? "lock"
    view.symbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    let screen = anchor.view.window!.convertToScreen(anchor.view.convert(anchor.rect, to: nil))
    anchorState = ["name": anchor.name, "frame": [screen.minX, screen.minY, screen.width, screen.height], "edge": anchor.edge.rawValue]
    // The prompt does not take the keyboard when it shows (bug sweep r6 V-05): a page could time
    // a request so the Return the user types into it grants. A click into the prompt gives it the
    // keyboard; then Return and Escape answer it. VoiceOver no longer follows a focus change, so
    // the question is announced.
    NSAccessibility.post(element: view, notification: .announcementRequested,
                         userInfo: [.announcement: view.question.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    if standalone {
      card = PermissionPromptCard(prompt: view, root: anchor.view)
      return
    }
    popover.contentViewController?.view = view
    popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
    if let promptWindow = view.window {
      // This NSPopover is ours; its native window class alone cannot prove
      // ownership to the browser's child-window appearance policy.
      (anchor.view.window as? any WindowContentAppearanceHost)?.contentAppearanceDidChange(for: promptWindow, inheritsAppearance: popover.appearance == nil)
      if promptWindow.parent == nil { anchor.view.window?.addChildWindow(promptWindow, ordered: .above) }
      // No default button yet: AppKit would send it the Return typed into the page.
      promptWindow.defaultButtonCell = nil
    }
  }
  func visibilityChanged() {
    if let current {
      if !canShow(current.page) { finish(nil) }
    }
    presentPending()
  }
  /// Only a key the prompt itself has answers it (bug sweep r6 V-05): one in its own popover
  /// window, or in Little Open's card while the card holds the keyboard. A plain Return or Escape
  /// typed into a page (any Split pane, a popup) belongs to that page: a page could otherwise
  /// time a prompt so the user's Enter grants it.
  func handleKey(_ event: NSEvent) -> Bool {
    guard isShown, current != nil, promptHasKeyboard(event),
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    switch event.keyCode {
    case 53: view.notNow.performClick(nil); return true
    case 36, 76: view.allow.performClick(nil); return true
    default: return false
    }
  }
  /// What a click into the prompt does: it takes the keyboard, so Return and Escape answer it.
  @discardableResult func focusPrompt() -> Bool {
    guard isShown, current != nil else { return false }
    view.hasKeyboard = true
    if let card {
      card.window?.makeFirstResponder(view)
      return card.window?.firstResponder === view
    }
    guard let window = view.window else { return false }
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
    window.defaultButtonCell = view.allow.cell as? NSButtonCell
    return window.firstResponder === view
  }
  private func promptHasKeyboard(_ event: NSEvent) -> Bool {
    if let card {
      guard let window = card.window, event.window === window, let responder = window.firstResponder as? NSView else { return false }
      return responder === card || responder.isDescendant(of: card)
    }
    return event.window != nil && event.window === view.window
  }
  func owns(_ window: NSWindow) -> Bool { isShown && presentedWindow === window }
  private func finish(_ decision: OEPermissionState?) {
    guard !finishing, let entry = current else { return }
    let promptWindow = card == nil ? view.window : nil
    finishing = true; current = nil
    // Remove ownership before the engine callback, which may navigate/close.
    if decision == .allow { entry.request.grant() }
    else if decision == .block { entry.request.deny() }
    else { entry.request.dismiss() }
    let store = SitePermissionStore.forContext(entry.page.context)
    if let decision {
      // Chromium persists deny as well as grant synchronously. Not Now must
      // restore the previous content setting after resolving this request.
      for (kind, _, _) in SitePermissionStore.kinds where entry.request.kinds.contains(kind) && SitePermissionStore.canPersist(kind) {
        store.set(origin: entry.request.origin, kind: kind, state: decision == .allow ? .allow : entry.previous[kind.rawValue] ?? .ask,
                  requestSystemAuthorization: decision == .allow)
      }
    }
    decisions += 1
    owner?.app.tabSleep.permissionsChanged(context: entry.page.context)
    owner?.record("permissionAnswer", entry.page, ["decision": decision == .allow ? "allow" : decision == .block ? "notnow" : "dismiss"])
    if let card {
      self.card = nil
      card.dismiss(animated: decision != nil && !closed)
      if !closed, owner?.pageChrome.isVisible(entry.page) == true { entry.page.focusPage() }
    } else {
      popover.close()
      if let promptWindow, let parent = promptWindow.parent { parent.removeChildWindow(promptWindow) }
    }
    finishing = false; presentPending()
  }
  /// The engine dismissed this request (navigation, a closed frame, the page closing): its
  /// prompt goes, unanswered (bug sweep r5; it stayed on screen).
  func engineDismissed(_ request: OEPermissionRequest) {
    if let index = entries.firstIndex(where: { $0.request === request }) {
      let entry = entries.remove(at: index); decisions += 1
      owner?.record("permissionAnswer", entry.page, ["decision": "dismiss", "engine": true])
    }
    if current?.request === request { finish(nil) }
  }
  func cancel(page: OEWebContent) {
    let removed = entries.filter { $0.page === page }; entries.removeAll { $0.page === page }
    for entry in removed {
      entry.request.dismiss(); decisions += 1
      owner?.record("permissionAnswer", entry.page, ["decision": "dismiss"])
    }
    if current?.page === page { finish(nil) }
  }
  func close() {
    closed = true
    for entry in entries {
      entry.request.dismiss(); decisions += 1
      owner?.record("permissionAnswer", entry.page, ["decision": "dismiss"])
    }; entries.removeAll()
    finish(nil)
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
  }
  func popoverDidClose(_ notification: Notification) { if !finishing, !popover.isShown { finish(nil) } }
  @discardableResult func press(_ answer: String) -> Bool {
    guard isShown, current != nil, ["allow", "notnow"].contains(answer) else { return false }
    (answer == "allow" ? view.allow : view.notNow).performClick(nil); return true
  }
  var state: [String: Any] {
    ["visible": isShown, "presentation": card == nil ? "popover" : "card",
     "animationDuration": card?.animationDuration ?? 0, "opacity": card?.alphaValue ?? 1,
     "shadowPath": card?.layer?.shadowPath != nil,
     "frame": card.map { let r = $0.convert($0.bounds, to: nil); return [r.minX, r.minY, r.width, r.height] } ?? [], "pending": entries.count + (current == nil ? 0 : 1), "decisions": decisions,
     "question": current == nil ? "" : view.question.stringValue, "kinds": current?.request.kinds.rawValue ?? 0,
     "origin": current?.request.origin.absoluteString ?? "", "anchor": anchorState,
     "keyWindow": NSApp.keyWindow?.windowNumber ?? 0, "promptKey": view.window?.isKeyWindow == true,
     "promptFirstResponder": view.window?.firstResponder === view && (card != nil || view.window?.isKeyWindow == true),
     "parent": view.window?.parent?.windowNumber ?? 0, "selectedPage": owner?.selectedContent?.identifier ?? 0,
     "pendingPage": current?.page.identifier ?? 0, "buttons": [view.notNow.title, view.allow.title], "help": view.help.stringValue, "window": view.window?.windowNumber ?? 0]
  }
  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
