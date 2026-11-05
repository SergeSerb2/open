import AppKit
import OpenEngine

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
          request.kinds.rawValue != 0, request.kinds.rawValue & ~UInt32(0x80000fff) == 0 else {
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
  static func question(origin: URL, kinds: OEPermissionKind) -> String {
    let site = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.host ?? "this website"
    switch kinds {
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
  private func defaultAnchor(for page: OEWebContent) -> Anchor? {
    guard let owner, owner.pageChrome.isVisible(page), let controller = owner.controller else { return nil }
    let sidebar = controller.sidebar
    if owner.windowState.sidebarMode == .anchored, !sidebar.isHidden, sidebar.urlFieldVisible {
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
          owner.window?.attachedSheet == nil, NSApp.isActive,
          let index = entries.firstIndex(where: { owner.pageChrome.isVisible($0.page) }) else { return }
    let entry = entries[index]
    // A permission can arrive in the same turn that creates the toolbar.
    // Resolve native geometry before NSPopover validates the anchor rect.
    owner.controller?.contentView.layoutSubtreeIfNeeded()
    guard let anchor = anchorProvider?(entry.page) ?? defaultAnchor(for: entry.page), anchor.view.window != nil else { return }
    entries.remove(at: index); current = entry
    view.question.stringValue = Self.question(origin: entry.request.origin, kinds: entry.request.kinds)
    let symbol = SitePermissionStore.kinds.first(where: { entry.request.kinds.contains($0.0) })?.2 ?? "lock"
    view.symbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    let screen = anchor.view.window!.convertToScreen(anchor.view.convert(anchor.rect, to: nil))
    anchorState = ["name": anchor.name, "frame": [screen.minX, screen.minY, screen.width, screen.height], "edge": anchor.edge.rawValue]
    popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
    if let promptWindow = view.window {
      if promptWindow.parent == nil { anchor.view.window?.addChildWindow(promptWindow, ordered: .above) }
      promptWindow.makeKeyAndOrderFront(nil)
      promptWindow.makeFirstResponder(view)
    }
    view.window?.defaultButtonCell = view.allow.cell as? NSButtonCell
  }
  func visibilityChanged() {
    if let current, owner?.selectedContent !== current.page { finish(nil) }
    presentPending()
  }
  /// AppKit keeps the parent as NSApp.keyWindow for this NSPopover. Plain
  /// keys arriving at the page's native pre-key hook belong to the prompt.
  func handleKey(_ event: NSEvent) -> Bool {
    guard popover.isShown, current != nil,
          event.window === owner?.window || event.window === view.window,
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    switch event.keyCode {
    case 53: view.notNow.performClick(nil); return true
    case 36, 76: view.allow.performClick(nil); return true
    default: return false
    }
  }
  func owns(_ window: NSWindow) -> Bool { popover.isShown && view.window === window }
  private func finish(_ decision: OEPermissionState?) {
    guard !finishing, let entry = current else { return }
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
        store.set(origin: entry.request.origin, kind: kind, state: decision == .allow ? .allow : entry.previous[kind.rawValue] ?? .ask)
      }
    }
    decisions += 1
    owner?.app.tabSleep.permissionsChanged(context: entry.page.context)
    owner?.record("permissionAnswer", entry.page, ["decision": decision == .allow ? "allow" : decision == .block ? "notnow" : "dismiss"])
    popover.close(); finishing = false; presentPending()
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
  func popoverDidClose(_ notification: Notification) { if !finishing { finish(nil) } }
  @discardableResult func press(_ answer: String) -> Bool {
    guard popover.isShown, current != nil, ["allow", "notnow"].contains(answer) else { return false }
    (answer == "allow" ? view.allow : view.notNow).performClick(nil); return true
  }
  var state: [String: Any] {
    ["visible": popover.isShown, "pending": entries.count + (current == nil ? 0 : 1), "decisions": decisions,
     "question": current == nil ? "" : view.question.stringValue, "kinds": current?.request.kinds.rawValue ?? 0,
     "origin": current?.request.origin.absoluteString ?? "", "anchor": anchorState,
     "keyWindow": NSApp.keyWindow?.windowNumber ?? 0, "promptKey": view.window?.isKeyWindow == true,
     "parent": view.window?.parent?.windowNumber ?? 0, "selectedPage": owner?.selectedContent?.identifier ?? 0,
     "pendingPage": current?.page.identifier ?? 0, "buttons": [view.notNow.title, view.allow.title], "help": view.help.stringValue, "window": view.window?.windowNumber ?? 0]
  }
  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
private final class PermissionPromptView: PageChromePopoverView {
  let symbol = NSImageView()
  let question = NSTextField(wrappingLabelWithString: "")
  let help = NSTextField(labelWithString: "Click the lock to change this any time")
  let allow = PermissionButton(title: "Allow")
  let notNow = PermissionButton(title: "Not Now")
  override var isFlipped: Bool { true }
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 156))
    question.font = .systemFont(ofSize: 13, weight: .semibold); question.maximumNumberOfLines = 3
    help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
    for child in [symbol, question, help, notNow, allow] { addSubview(child) }
    allow.keyEquivalent = "\r"; notNow.keyEquivalent = "\u{1b}"
    onReturn = { [weak self] in self?.allow.performClick(nil) }
    onEscape = { [weak self] in self?.notNow.performClick(nil) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    symbol.frame = CGRect(x: 16, y: 16, width: 20, height: 24)
    question.frame = CGRect(x: 44, y: 16, width: 260, height: 48)
    help.frame = CGRect(x: 16, y: 76, width: 288, height: 16)
    notNow.frame = CGRect(x: 132, y: 112, width: 84, height: 28)
    allow.frame = CGRect(x: 224, y: 112, width: 80, height: 28)
  }
}

@MainActor
private final class PermissionButton: NSButton {
  var onPress: (() -> Void)?
  init(title: String) {
    super.init(frame: .zero); self.title = title; bezelStyle = .rounded
    target = self; action = #selector(pressed)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func pressed() { onPress?() }
}
