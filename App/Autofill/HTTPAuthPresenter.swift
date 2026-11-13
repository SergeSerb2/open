#if OPEN_HTTP_AUTH
import AppKit

/// Per-window queue. UI work and network answers leave the engine's delegate
/// stack first; begin/endSheet may themselves pump a nested run loop.
@MainActor
final class HTTPAuthPresenter {
  private struct Entry {
    let request: any HTTPAuthRequest
    let page: AnyHashable
  }
  private var pending: [Entry] = []
  private weak var window: NSWindow?
  private let isFocused: (AnyHashable) -> Bool
  private let text: (any HTTPAuthRequest) -> HTTPAuthSheetText
  private var activeEntry: Entry?
  private(set) var active: HTTPAuthSheet?
  private var dim: NSPanel?
  var onPresent: ((HTTPAuthSheet) -> Void)?
  var queuedCount: Int { pending.count }
  private var closing = false
  private var scheduled = false
  private var changingSheet = false
  private var needsUpdate = false
  private var activeInvalid = false
  private var observers: [any NSObjectProtocol] = []

  init(window: NSWindow, isFocused: @escaping (AnyHashable) -> Bool,
       text: @escaping (any HTTPAuthRequest) -> HTTPAuthSheetText) {
    self.window = window; self.isFocused = isFocused; self.text = text
    for name in [NSWindow.didEndSheetNotification, NSWindow.didBecomeKeyNotification,
                 NSWindow.didDeminiaturizeNotification, NSWindow.didMoveNotification,
                 NSWindow.didResizeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedule() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelAll() }
    })
  }

  func enqueue(_ request: any HTTPAuthRequest, page: AnyHashable) {
    guard !request.isAnswered, activeEntry?.request !== request,
          !pending.contains(where: { $0.request === request }) else { return }
    guard !closing, window != nil,
          [request.origin, request.realm, request.scheme].allSatisfy({ $0.utf8.count <= HTTPAuthSheet.maximumMetadataBytes }) else {
      DispatchQueue.main.async { if !request.isAnswered { request.cancel() } }
      return
    }
    // At most four retained requests including the active sheet. Metadata is
    // <=12 KiB per request; network credentials are never copied into the queue.
    if pending.count >= (active == nil ? 4 : 3) {
      let oldest = pending.removeFirst().request
      DispatchQueue.main.async { if !oldest.isAnswered { oldest.cancel() } }
    }
    pending.append(Entry(request: request, page: page))
    schedule()
  }

  func withdraw(_ request: any HTTPAuthRequest) {
    pending.removeAll { $0.request === request }
    if activeEntry?.request === request { activeInvalid = true }
    schedule()
  }

  func autofill(_ request: any HTTPAuthRequest, username: String, password: String) {
    guard activeEntry?.request === request else { return }
    active?.autofill(username: username, password: password)
  }

  func focusChanged() { schedule() }

  func pageDidClose(_ page: AnyHashable) {
    let removed = pending.filter { $0.page == page }
    pending.removeAll { $0.page == page }
    for entry in removed {
      DispatchQueue.main.async { if !entry.request.isAnswered { entry.request.cancel() } }
    }
    if activeEntry?.page == page { activeInvalid = true }
    schedule()
  }

  func cancelAll() {
    closing = true
    removeDim()
    let removed = pending; pending.removeAll()
    for entry in removed {
      DispatchQueue.main.async { if !entry.request.isAnswered { entry.request.cancel() } }
    }
    activeInvalid = true
    schedule()
  }

  private func schedule() {
    needsUpdate = true
    guard !changingSheet else { return }
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      guard !self.changingSheet else { return }
      self.needsUpdate = false
      self.update()
    }
  }

  private func update() {
    changingSheet = true
    defer {
      changingSheet = false
      if needsUpdate { schedule() }
    }
    if let entry = activeEntry,
       closing || activeInvalid || entry.request.isAnswered || !isFocused(entry.page) {
      let preserve = !closing && !activeInvalid && !entry.request.isAnswered
      let sheet = active
      active = nil; activeEntry = nil; activeInvalid = false
      sheet?.onFinished = nil
      sheet?.releaseRequest()
      if let sheet {
        if let parent = sheet.sheetParent { parent.endSheet(sheet) }
        sheet.orderOut(nil)
      }
      removeDim()
      if preserve { pending.insert(entry, at: 0) }
      else if !entry.request.isAnswered { entry.request.cancel() }
    }
    positionSheet()
    guard !closing, active == nil, let window, window.isVisible,
          !window.isMiniaturized, window.attachedSheet == nil else { return }
    pending.removeAll { $0.request.isAnswered }
    guard let index = pending.firstIndex(where: { isFocused($0.page) }) else { return }
    let entry = pending.remove(at: index)
    let sheet = HTTPAuthSheet(request: entry.request, text: text(entry.request))
    activeEntry = entry; active = sheet
    showDim(in: window)
    sheet.onFinished = { [weak self, weak sheet] in
      guard let self, self.active === sheet else { return }
      self.activeInvalid = true; self.schedule()
    }
    window.beginSheet(sheet) { [weak self, weak sheet] _ in
      guard let self, self.active === sheet else { return }
      self.activeInvalid = true; self.schedule()
    }
    positionSheet()
    sheet.makeFirstResponder(sheet.initialFirstResponder)
    sheet.announce()
    onPresent?(sheet)
    fillSavedCredential(for: entry.request, sheet: sheet)
  }

  private func fillSavedCredential(for request: any HTTPAuthRequest, sheet: HTTPAuthSheet) {
    guard let source = request as? any HTTPAuthPasswordManagerRequest,
          let protectionSpace = HTTPAuthProtectionSpace(request) else { return }
    source.fetchSavedCredential { [weak self, weak request, weak sheet] credential in
      guard let self, let request, let sheet, let credential,
            self.active === sheet, self.activeEntry?.request === request,
            !self.closing, !self.activeInvalid, !request.isAnswered,
            credential.protectionSpace == protectionSpace,
            HTTPAuthProtectionSpace(request) == protectionSpace else { return }
      // HTTPAuthSheet also refuses a late result after the user starts typing.
      sheet.autofill(username: credential.username, password: credential.password)
    }
  }

  private func positionSheet() {
    guard let window, let sheet = active else { return }
    // C13-AUTH centers over the entire window, including its sidebar.
    sheet.setFrameOrigin(NSPoint(x: window.frame.midX - sheet.frame.width / 2,
      y: window.frame.midY - sheet.frame.height / 2))
    dim?.setFrame(window.frame, display: true)
  }

  private func showDim(in window: NSWindow) {
    let panel = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.hasShadow = false
    panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
    // Recreated veil from C13-AUTH's paired dialog/cancel frames: a white
    // page becomes sRGB 204 in light appearance and about 114 in dark.
    panel.backgroundColor = NSColor(name: nil) { appearance in
      let value: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 20 / 255 : 170 / 255
      return NSColor(srgbRed: value, green: value, blue: value, alpha: 0.6)
    }
    panel.identifier = .init("http-auth-dim"); panel.setAccessibilityElement(false)
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    dim = panel
  }

  private func removeDim() {
    guard let panel = dim else { return }
    dim = nil
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil); panel.close()
  }

  isolated deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    for entry in pending where !entry.request.isAnswered { entry.request.cancel() }
    if let entry = activeEntry, !entry.request.isAnswered { entry.request.cancel() }
    active?.onFinished = nil; active?.releaseRequest()
    if let sheet = active {
      sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil)
    }
    removeDim()
  }
}
#endif
