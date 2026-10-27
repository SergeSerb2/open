import AppKit
import OpenEngine

@MainActor
final class PermissionPromptPresenter: NSObject, NSPopoverDelegate {
  struct Pending {
    let page: OEWebContent
    let request: OEPermissionRequest
    let previous: [UInt32: OEPermissionState]
  }
  weak var owner: EngineWebContentHostFactory?
  private(set) var pending: [Pending] = []
  private let popover = NSPopover()
  private let view = PermissionPromptView()
  private var finishing = false
  private var presentedRequest: OEPermissionRequest?
  private var activationObserver: (any NSObjectProtocol)?
  private var windowObservers: [any NSObjectProtocol] = []
  private(set) var decisions = 0

  init(owner: EngineWebContentHostFactory) {
    self.owner = owner
    super.init()
    let controller = NSViewController(); controller.view = view
    popover.contentViewController = controller; popover.contentSize = NSSize(width: 320, height: 174)
    popover.behavior = .semitransient; popover.animates = false; popover.delegate = self
    view.allow.onPress = { [weak self] in self?.answer(.allow) }
    view.block.onPress = { [weak self] in self?.answer(.block) }
    view.close.onPress = { [weak self] in self?.answer(nil) }
    activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.presentPending() }
    }
    for notification in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
      windowObservers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.presentPending() }
      })
    }
  }
  static let kinds: [(OEPermissionKind, String)] = [(.camera, "camera"), (.microphone, "microphone"),
    (.geolocation, "location"), (.notifications, "notifications"), (.clipboard, "clipboard"), (.MIDI, "MIDI devices"),
    (.screenCapture, "screen capture"), (.multipleDownloads, "multiple downloads"), (.storageAccess, "storage"),
    (.windowManagement, "window placement"), (.localFonts, "local fonts"), (.idleDetection, "idle detection"), (.other, "additional access")]

  // Screen capture is a transient system picker, not a Chromium content
  // setting. Passing DISPLAY_CAPTURE to the engine settings API is invalid.
  static func canPersist(_ kind: OEPermissionKind) -> Bool { kind != .screenCapture && kind != .other }
  func request(_ request: OEPermissionRequest, page: OEWebContent) {
    guard let owner, !owner.isClosing, owner.app.engineReady else { request.dismiss(); return }
    guard pending.count < PageChromeLimits.pendingRequests, request.origin.absoluteString.utf8.count <= PageChromeLimits.urlBytes,
          request.kinds.rawValue != 0, request.kinds.rawValue & ~UInt32(0x80000fff) == 0 else {
      owner.record("pageChromeRefused", page, ["reason": "Permission request exceeds queue, origin or kind limits."]); request.dismiss(); return
    }
    let previous = Dictionary(uniqueKeysWithValues: Self.kinds.filter { request.kinds.contains($0.0) && Self.canPersist($0.0) }.map {
      ($0.0.rawValue, page.context.permissionState(for: $0.0, origin: request.origin))
    })
    let states = Self.kinds.filter { request.kinds.contains($0.0) }.map { previous[$0.0.rawValue] ?? .ask }
    if states.contains(.block) { request.deny(); return }
    if !states.isEmpty, states.allSatisfy({ $0 == .allow }) { request.grant(); return }
    pending.append(Pending(page: page, request: request, previous: previous)); presentPending()
  }
  func presentPending() {
    guard !popover.isShown, let owner, !owner.isClosing, owner.window?.attachedSheet == nil, NSApp.isActive else { return }
    func anchor(for page: OEWebContent) -> NSView? {
      let view: NSView?
      if owner.selectedContent === page { view = owner.controller?.container }
      else if owner.extensionPopup.owns(page) || owner.auxiliaryPages.contains(where: { $0.content === page }) { view = page.view }
      else { view = nil }
      return view?.window?.isKeyWindow == true ? view : nil
    }
    // A background request must not block a later request from the visible page.
    guard let index = pending.firstIndex(where: { anchor(for: $0.page) != nil }) else { return }
    let first = pending.remove(at: index); pending.insert(first, at: 0)
    guard let anchor = anchor(for: first.page) else { return }
    let origin = first.request.origin
    view.origin.stringValue = (origin.host() ?? origin.absoluteString) + (origin.port.map { ":\($0)" } ?? "")
    let names = Self.kinds.filter { first.request.kinds.contains($0.0) }.map(\.1)
    view.message.stringValue = "Wants to use \(names.isEmpty ? "additional permissions" : names.joined(separator: " and "))"
    view.remember.state = .off; view.remember.isEnabled = !first.previous.isEmpty; presentedRequest = first.request
    popover.show(relativeTo: CGRect(x: min(160, anchor.bounds.midX), y: anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1, width: 1, height: 1), of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
  }
  func answer(_ state: OEPermissionState?) {
    guard !finishing, !pending.isEmpty else { return }
    finishing = true
    let first = pending.removeFirst(); presentedRequest = nil
    let remember = view.remember.state == .on
    if state == .allow { first.request.grant() }
    else if state == .block { first.request.deny() }
    else { first.request.dismiss() }
    // Native button delivery occurs after the engine prompt callback returns.
    // Chromium synchronously persists its answer. Restore prior settings for a
    // one-shot answer; preserve the current page's permission response.
    if let state {
      for (kind, _) in Self.kinds where first.request.kinds.contains(kind) && Self.canPersist(kind) {
        first.page.context.setPermissionState(remember ? state : first.previous[kind.rawValue] ?? .ask, for: kind, origin: first.request.origin)
      }
    }
    decisions += 1
    popover.close(); finishing = false; presentPending()
  }
  func cancel(page: OEWebContent) {
    let wasFirst = pending.first?.page === page
    let removed = pending.filter { $0.page === page }; pending.removeAll { $0.page === page }
    for item in removed { item.request.dismiss() }
    if wasFirst { presentedRequest = nil; finishing = true; popover.close(); finishing = false }
    presentPending()
  }
  func close() {
    finishing = true; presentedRequest = nil
    for item in pending { item.request.dismiss() }; pending.removeAll(); popover.close()
    finishing = false
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }; activationObserver = nil
    windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
  }
  func popoverDidClose(_ notification: Notification) {
    if !finishing, !popover.isShown, let presentedRequest, pending.first?.request === presentedRequest { answer(nil) }
  }
  @discardableResult func press(allow: Bool, remember: Bool) -> Bool {
    guard popover.isShown else { return false }
    view.remember.state = remember ? .on : .off
    (allow ? view.allow : view.block).performClick(nil); return true
  }
  var state: [String: Any] {
    ["visible": popover.isShown, "pending": pending.count, "decisions": decisions,
      "origin": pending.first?.request.origin.absoluteString ?? "", "kinds": pending.first?.request.kinds.rawValue ?? 0,
      "remember": view.remember.state == .on, "window": view.window?.windowNumber ?? 0,
      "appActive": NSApp.isActive, "ownerKey": owner?.window?.isKeyWindow == true,
      "ownerSheet": owner?.window?.attachedSheet != nil,
      "containerWindow": owner?.controller?.container.window?.windowNumber ?? 0,
      "containerKey": owner?.controller?.container.window?.isKeyWindow == true,
      "selectedPage": owner?.selectedContent?.identifier ?? 0, "pendingPage": pending.first?.page.identifier ?? 0,
      "keyWindow": NSApp.keyWindow?.windowNumber ?? 0]
  }
  isolated deinit {
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    windowObservers.forEach(NotificationCenter.default.removeObserver)
  }
}

/// No permission prompt appears in the supplied captures. These dimensions,
/// charcoal fill and spacing are explicit Arc-like guesses (app-shell §4.9).
@MainActor
private final class PermissionPromptView: NSView {
  let origin = NSTextField(labelWithString: "")
  let message = NSTextField(wrappingLabelWithString: "")
  let remember = NSButton(checkboxWithTitle: "Remember for this site", target: nil, action: nil)
  let allow = PageChromeButton(title: "Allow")
  let block = PageChromeButton(title: "Block")
  let close = PageChromeButton(symbol: "xmark", title: "Dismiss Permission")
  override var isFlipped: Bool { true }
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 174))
    appearance = NSAppearance(named: .darkAqua); wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
    origin.font = .systemFont(ofSize: 14, weight: .semibold); origin.lineBreakMode = .byTruncatingMiddle
    message.font = .systemFont(ofSize: 13); message.textColor = .secondaryLabelColor
    remember.font = .systemFont(ofSize: 12)
    for v in [origin, message, remember, allow, block, close] { addSubview(v) }
    allow.keyEquivalent = "\r"; close.keyEquivalent = "\u{1b}"
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    origin.frame = CGRect(x: 16, y: 15, width: 260, height: 20)
    close.frame = CGRect(x: 286, y: 13, width: 20, height: 22)
    message.frame = CGRect(x: 16, y: 43, width: 288, height: 42)
    remember.frame = CGRect(x: 16, y: 93, width: 288, height: 22)
    block.frame = CGRect(x: 132, y: 132, width: 80, height: 28)
    allow.frame = CGRect(x: 220, y: 132, width: 84, height: 28)
  }
}
