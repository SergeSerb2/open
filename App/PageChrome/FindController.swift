import AppKit
import OpenEngine
import OpenModel

/// One lazy coordinator per browser window. State belongs to tab IDs, survives
/// hidden-host eviction, and never enters the persisted browser snapshot.
@MainActor
final class FindController {
  private final class State {
    var query = ""
    var open = false
    var revision = 0
    var acceptsResults = false
    var total = 0
    var hasCount = false
    var active = 0
    var final = false
    var requestedActivation = false
    var needsNewSession = true
    var overlay: FindPaneOverlay?
    weak var page: OEWebContent?
  }
  unowned let factory: EngineWebContentHostFactory
  private var states: [ItemID: State] = [:]
  private var selectionTask: Task<Void, Never>?
  private var selectionGeneration = 0
  private var pendingEdits: Set<ItemID> = []
  private var editScheduled = false
  private(set) var requestCount = 0
  private(set) var resultCount = 0
  private(set) var typedRequests = 0
  private(set) var activationRequests = 0
  private(set) var lastPresentationMilliseconds = 0.0
  private(set) var presentationPhases: [String: Double] = [:]
  var hasSelectionTask: Bool { selectionTask != nil }
  var query: String { focusedID.flatMap { states[$0]?.query } ?? "" }
  var visible: Bool { focusedID.flatMap { states[$0]?.overlay }.map { !$0.isHiddenOrHasHiddenAncestor } ?? false }
  var focusedID: ItemID? { factory.hosts.values.first { $0.content === factory.selectedContent }?.tabID }

  init(factory: EngineWebContentHostFactory) { self.factory = factory }
  func owns(_ responder: NSResponder?) -> Bool { states.values.contains { $0.overlay?.bar.owns(responder) == true } }

  private func state(_ id: ItemID) -> State {
    if let state = states[id] { return state }
    let state = State(); states[id] = state; return state
  }
  /// Show and focus synchronously. The bounded selection read may refine the
  /// query later, but can never overwrite a user edit, tab switch, or dismissal.
  func show(seedSelection: Bool = true) {
    guard !factory.isClosing, factory.app.engineReady, !factory.app.terminationRequested,
          let id = focusedID, let page = factory.selectedContent else { return }
    let start = ProcessInfo.processInfo.systemUptime
    let requestedAt = factory.findKeyRequestedAt ?? start
    let state = state(id), wasEditing = owns(factory.window?.firstResponder)
    state.open = true; sync(refreshResults: false)
    // Commit the visible bar before the native text-input context's first-use
    // setup. The editor stays lazy and focus still completes in this action.
    state.overlay?.displayIfNeeded(); CATransaction.flush()
    let visibleAt = ProcessInfo.processInfo.systemUptime
    state.overlay?.bar.focusQuery()
    presentationPhases = ["commit": (visibleAt - requestedAt) * 1000, "view": (visibleAt - start) * 1000, "focus": (ProcessInfo.processInfo.systemUptime - visibleAt) * 1000]
    lastPresentationMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
    if seedSelection, !wasEditing { readSelection(id, page: page, opening: true) }
    else if !state.query.isEmpty { run(id, forward: true) }
  }
  func perform(tag: Int) {
    switch tag {
    case 1, 12: show()
    case 2: advance(forward: true)
    case 3: advance(forward: false)
    case 7:
      guard let id = focusedID, let page = factory.selectedContent else { return }
      readSelection(id, page: page, opening: false)
    default: break
    }
  }
  private func readSelection(_ id: ItemID, page: OEWebContent, opening: Bool) {
    selectionTask?.cancel()
    selectionGeneration += 1; let token = selectionGeneration
    let state = state(id), revision = state.revision
    selectionTask = Task { @MainActor [weak self, weak page, weak state, factory] in
      guard let self, let page, let state else { return }
      defer { withExtendedLifetime(factory) {} }
      defer { if self.selectionGeneration == token { self.selectionTask = nil } }
      await self.factory.app.deferAsyncEngineWorkForAutomation()
      guard !Task.isCancelled, !self.factory.isClosing, !self.factory.app.terminationRequested else { return }
      self.factory.app.noteAsyncEngineCall("findSelection")
      // Bound the decoded result before it crosses the engine bridge. A query
      // owns at most 1,000 UTF-8 bytes (largest explicit query buffer: 1 KB).
      let value = try? await page.evaluateJavaScript("window.getSelection().toString().slice(0,4001)") as? String
      guard !Task.isCancelled, !self.factory.isClosing, !self.factory.app.terminationRequested,
            self.factory.selectedContent === page, self.states[id] === state,
            state.revision == revision, !opening || state.open else { return }
      let normalized = (value ?? "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty, !opening || normalized.count <= 40 { self.setQuery(Self.bounded(normalized), id: id) }
      if opening { self.run(id, forward: true); if state.overlay?.bar.owns(self.factory.window?.firstResponder) == true { state.overlay?.bar.focusQuery() } }
    }
  }
  static func bounded(_ text: String) -> String {
    // Prefix by Unicode scalar so truncation never creates replacement bytes.
    var bytes = 0, end = text.startIndex
    for scalar in text.unicodeScalars {
      let length = scalar.utf8.count
      if bytes + length > 1000 { break }
      bytes += length; end = text.unicodeScalars.index(after: end)
    }
    return String(text[..<end])
  }
  private func setQuery(_ value: String, id: ItemID) {
    let state = state(id)
    guard state.query != value else { state.overlay?.bar.setQuery(value); return }
    state.query = value; state.revision += 1; state.acceptsResults = false
    resetResult(state)
    state.overlay?.bar.setQuery(value); state.overlay?.bar.update(active: 0, total: 0, final: false)
  }
  private func edit(_ value: String, id: ItemID) {
    let bounded = Self.bounded(value)
    guard state(id).query != bounded else { states[id]?.overlay?.bar.setQuery(bounded); return }
    setQuery(bounded, id: id)
    pendingEdits.insert(id)
    guard !editScheduled else { return }; editScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.editScheduled = false
      let pending = self.pendingEdits; self.pendingEdits.removeAll()
      for id in pending where self.states[id]?.open == true { self.typedRequests += 1; self.run(id, forward: true) }
    }
  }
  private func run(_ id: ItemID, forward: Bool) {
    guard !factory.isClosing, !factory.app.terminationRequested,
          let state = states[id], let page = factory.hosts[id]?.content else { return }
    pendingEdits.remove(id)
    if state.query.isEmpty {
      state.acceptsResults = false; page.stopFinding(clearSelection: true)
      state.overlay?.bar.update(active: 0, total: 0, final: false)
    } else {
      if state.needsNewSession { page.stopFinding(clearSelection: true); state.needsNewSession = false }
      state.acceptsResults = true; requestCount += 1
      page.find(state.query, forward: forward, caseSensitive: false)
    }
  }
  func advance(forward: Bool) {
    guard let id = focusedID else { return }
    let state = state(id)
    if !state.open { state.open = true; sync(refreshResults: false); state.overlay?.bar.focusQuery() }
    run(id, forward: forward)
  }
  func close(_ id: ItemID) {
    guard let state = states[id] else { return }
    state.open = false; state.revision += 1; state.acceptsResults = false; pendingEdits.remove(id)
    resetResult(state)
    selectionTask?.cancel(); selectionTask = nil
    factory.hosts[id]?.content.stopFinding(clearSelection: false)
    // End field editing before hiding its ancestor, then focus the actual page.
    if state.overlay?.bar.owns(factory.window?.firstResponder) == true { factory.window?.makeFirstResponder(nil) }
    state.overlay?.isHidden = true
    if focusedID == id { factory.hosts[id]?.content.focusPage() }
  }
  func sync(refreshResults: Bool = true) {
    guard let controller = factory.controller else { return }
    var targets: [ItemID: (NSView, CGFloat)] = [:]
    for slot in controller.container.slots where !slot.isHidden {
      targets[slot.tabID] = (slot, slot.paneChrome == nil ? 10 : 50)
    }
    if controller.hasPeekController, controller.peekController.isShown,
       let host = controller.peekController.stack.last?.host as? EngineWebContentHost {
      targets[host.tabID] = (controller.peekController.overlay.panel, 10)
      controller.peekController.onPageEscape = { [weak self] in
        guard let self, let id = self.focusedID, self.states[id]?.open == true else { return false }
        self.close(id); return true
      }
    }
    for (id, state) in states {
      guard factory.model.tab(id: id) != nil || factory.hosts[id] != nil else {
        state.overlay?.removeFromSuperview(); states[id] = nil; continue
      }
      guard state.open, let (parent, top) = targets[id], let page = factory.hosts[id]?.content else {
        state.overlay?.removeFromSuperview(); continue
      }
      if state.overlay == nil {
        let overlay = FindPaneOverlay(frame: parent.bounds); state.overlay = overlay
        overlay.bar.onEdit = { [weak self] in self?.edit($0, id: id) }
        overlay.bar.onAction = { [weak self] tag in
          guard let self else { return }
          if tag == 2 || tag == 3 { self.run(id, forward: tag != 3) } else { self.perform(tag: tag) }
        }
        overlay.bar.onClose = { [weak self] in self?.close(id) }
        overlay.bar.setQuery(state.query)
      }
      guard let overlay = state.overlay else { continue }
      let changed = overlay.superview !== parent || state.page !== page
      if overlay.superview !== parent { overlay.removeFromSuperview(); overlay.frame = parent.bounds; parent.addSubview(overlay) }
      state.page = page; overlay.topInset = top; overlay.isHidden = false
      overlay.layoutSubtreeIfNeeded()
      if changed, refreshResults, !state.query.isEmpty {
        resetResult(state); page.stopFinding(clearSelection: true); run(id, forward: true)
      }
    }
  }
  func didUpdate(_ result: OEFindResult, page: OEWebContent) {
    guard let id = factory.hosts.values.first(where: { $0.content === page })?.tabID,
          let state = states[id], state.open, state.acceptsResults else { return }
    resultCount += 1
    // Chromium can report count and ordinal separately; -1 means unchanged.
    if result.matchCount >= 0 { state.total = result.matchCount; state.hasCount = true }
    if result.activeMatchIndex > 0 { state.active = result.activeMatchIndex }
    if state.hasCount, state.total == 0 { state.active = 0 }
    state.final = state.final || result.isFinal
    state.overlay?.bar.update(active: state.active, total: state.total, final: state.final && state.hasCount)
    // Ask Chromium to select its first match once. Never invent an ordinal.
    if result.isFinal, state.total > 0, state.active == 0, !state.requestedActivation {
      state.requestedActivation = true
      let revision = state.revision
      DispatchQueue.main.async { [weak self, weak state, weak page] in
        guard let self, let state, let page, self.states[id] === state, state.revision == revision,
          state.open, state.acceptsResults, state.active == 0, self.factory.hosts[id]?.content === page,
          !self.factory.isClosing, !self.factory.app.terminationRequested else { return }
        self.activationRequests += 1; self.run(id, forward: true)
      }
    }
  }
  private func resetResult(_ state: State) {
    state.total = 0; state.hasCount = false; state.active = 0; state.final = false; state.requestedActivation = false
    state.needsNewSession = true
  }
  func didNavigate(_ page: OEWebContent) {
    guard let id = factory.hosts.values.first(where: { $0.content === page })?.tabID, let state = states[id] else { return }
    state.revision += 1; state.acceptsResults = false; pendingEdits.remove(id)
    resetResult(state)
    page.stopFinding(clearSelection: true)
    state.overlay?.bar.update(active: 0, total: 0, final: false)
  }
  func forget(_ id: ItemID) {
    guard let state = states.removeValue(forKey: id) else { return }
    if state.overlay?.bar.owns(factory.window?.firstResponder) == true { factory.window?.makeFirstResponder(nil) }
    pendingEdits.remove(id); state.overlay?.removeFromSuperview()
  }
  func hostClosed(_ id: ItemID) {
    states[id]?.overlay?.removeFromSuperview(); states[id]?.page = nil
    states[id]?.acceptsResults = false
    if factory.model.tab(id: id) == nil { states[id] = nil }
  }
  func closeAll() {
    selectionTask?.cancel(); selectionTask = nil; pendingEdits.removeAll()
    if owns(factory.window?.firstResponder) { factory.window?.makeFirstResponder(nil) }
    states.values.forEach { $0.overlay?.removeFromSuperview() }; states.removeAll()
  }
  func jumpToSelection() {
    guard let page = factory.selectedContent else { return }
    selectionTask?.cancel()
    selectionGeneration += 1; let token = selectionGeneration
    selectionTask = Task { @MainActor [weak self, weak page, factory] in
      guard let self, let page, !Task.isCancelled, !self.factory.isClosing, !self.factory.app.terminationRequested else { return }
      defer { withExtendedLifetime(factory) {} }
      defer { if self.selectionGeneration == token { self.selectionTask = nil } }
      self.factory.app.noteAsyncEngineCall("findSelection")
      _ = try? await page.evaluateJavaScript("""
        (() => { const s = window.getSelection(); if (!s || !s.rangeCount) return false;
          const r = s.getRangeAt(0), n = r.startContainer;
          const e = n.nodeType === 1 ? n : n.parentElement;
          if (!e) return false; e.scrollIntoView({block:'center'}); return true; })()
        """)
    }
  }

  #if OPEN_AUTOMATION
  func observeIdleViews(_ observe: (NSView) -> Void) {
    for state in states.values { if let bar = state.overlay?.bar { observe(bar) } }
  }
  func automationState() -> [String: Any] {
    let panes: [[String: Any]] = states.map { id, state in
      let bar = state.overlay?.bar
      func frame(_ view: NSView?) -> [CGFloat] {
        guard let view, view.window != nil else { return [] }
        let rect = view.convert(view.bounds, to: nil)
        return [rect.minX, rect.minY, rect.width, rect.height]
      }
      return ["tab": id.description, "visible": state.open && state.overlay?.superview != nil && state.overlay?.isHiddenOrHasHiddenAncestor == false,
        "query": state.query, "countText": bar?.countText ?? "", "active": bar?.active ?? 0, "total": bar?.total ?? 0,
        "notFound": bar?.notFound ?? false, "navigationVisible": bar?.navigationVisible ?? false,
        "separatorVisible": bar?.separatorVisible ?? false, "frame": frame(bar), "paneFrame": frame(state.overlay),
        "topInset": state.overlay?.topInset ?? 10, "focused": bar?.owns(factory.window?.firstResponder) ?? false,
        "placeholder": bar?.field.placeholderString ?? "", "radius": bar?.layer?.cornerRadius ?? 0,
        "querySelection": (bar?.field.currentEditor() as? NSTextView).map { [$0.selectedRange().location, $0.selectedRange().length] } ?? [],
        "layouts": bar?.layoutCount ?? 0]
    }
    return ["created": true, "panes": panes, "focusedTab": focusedID?.description ?? "", "requests": requestCount, "results": resultCount,
      "typedRequests": typedRequests, "activationRequests": activationRequests,
      "pending": editScheduled || selectionTask != nil, "presentationMilliseconds": lastPresentationMilliseconds, "presentationPhases": presentationPhases]
  }
  #endif
}

extension EngineWebContentHostFactory {
  func ensureFindController() -> FindController {
    if let findController { return findController }
    let controller = FindController(factory: self); findController = controller; return controller
  }
  @objc override func performTextFinderAction(_ sender: Any?) { ensureFindController().show() }
  @objc override func centerSelectionInVisibleArea(_ sender: Any?) { ensureFindController().jumpToSelection() }
}
