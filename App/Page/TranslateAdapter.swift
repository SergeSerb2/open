import AppKit
import OpenEngine
import OpenFeatures
import OpenSidebar
import OpenTranslate

/// OpenTranslate ↔ OEWebContent for one window (page-platform §3.1, §4.7, Step 10).
///
/// - Detection runs only for the window's focused tab page, and only while the window is visible:
///   after a 2xx main-frame load, or when a tab whose current document was never probed becomes
///   focused. Background tabs cost nothing (Section 8 decision: the focus-time probe, so a page
///   loaded in the background still offers when the user looks at it).
/// - One `PageTranslationSession` per page, made on first use and closed with the page.
/// - The session's state drives the sidebar status button and the popover; its events become
///   toasts and "Translate" entries in the window's undo manager (PG-7.3).
/// Nothing here runs while idle: no timer; the runtime's `nextBatch()` is an awaited promise.
@MainActor
final class TranslateAdapter {
  unowned let factory: EngineWebContentHostFactory
  let backend: any TranslationBackend
  let preferences = TranslatePreferences()
  private struct Document { var count = 0; var status = 0; var url: URL? }
  private var sessions: [ObjectIdentifier: PageTranslationSession] = [:]
  private var documents: [ObjectIdentifier: Document] = [:]
  private weak var focused: OEWebContent?
  private(set) var popover: TranslatePopoverController?
  private var popoverSession: ObjectIdentifier?
  private var languages: [TranslateLanguageOption]?
  private var languagesTask: Task<Void, Never>?
  /// Sessions whose next event comes from an undo or redo: that path registers its inverse itself.
  private var undoDriven: Set<ObjectIdentifier> = []
  private(set) var toastsShown: [String] = []

  init(factory: EngineWebContentHostFactory) {
    self.factory = factory
    #if OPEN_AUTOMATION
    // e2e on a Mac without Apple's language assets (page-platform §8.4 U-X1): a fixed French →
    // English word list that never touches the network. Real builds always use Apple's backend.
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_TRANSLATE_BACKEND"] == "fixture" {
      backend = FixtureTranslationBackend(); return
    }
    #endif
    backend = AppleTranslationBackend()
  }

  // MARK: Engine events

  /// A main-frame load finished (`EngineWebContentHostFactory.webContent(_:didFinishLoadWithStatus:)`).
  func pageDidFinishLoad(_ content: OEWebContent, status: Int) {
    let id = ObjectIdentifier(content)
    var doc = documents[id] ?? Document()
    doc.count += 1; doc.status = status; doc.url = content.url
    documents[id] = doc
    guard isFocusedAndVisible(content) else {
      // A page that is not focused keeps its old offer until it is probed again on focus.
      sessions[id]?.documentDidLoad(url: nil, status: 0, document: -1)
      return
    }
    session(for: content).documentDidLoad(url: doc.url, status: status, document: doc.count)
  }

  /// The window's focus or state changed (`BrowserWindowController.onStateChange`). Cheap when
  /// the focused page is the same.
  func focusDidChange() {
    let content = focusedContent
    guard content !== focused else { return }
    focused = content
    if let popover, popover.isPresented { popover.dismiss() }
    if let content, let doc = documents[ObjectIdentifier(content)], isFocusedAndVisible(content), !content.isLoading,
       sessions[ObjectIdentifier(content)]?.probedDocument != doc.count {
      session(for: content).documentDidLoad(url: doc.url, status: doc.status, document: doc.count)
    }
    syncStatus()
  }

  func contentDidClose(_ content: OEWebContent) {
    let id = ObjectIdentifier(content)
    if let session = sessions.removeValue(forKey: id) {
      factory.app.undoManager.removeAllActions(withTarget: session)
      session.close()
    }
    documents[id] = nil
    undoDriven.remove(id)
    if popoverSession == id { popover?.dismiss() }
    if focused === content { focused = nil; syncStatus() }
  }

  func closeAll() {
    for content in sessions.keys { if let s = sessions[content] { factory.app.undoManager.removeAllActions(withTarget: s); s.close() } }
    sessions.removeAll(); documents.removeAll(); popover?.dismiss(); languagesTask?.cancel()
  }

  // MARK: Sessions

  private var focusedContent: OEWebContent? {
    guard let tab = factory.selectedTab, let content = factory.hosts[tab.id]?.content else { return nil }
    if let controller = factory.controller, controller.hasPeekController, controller.peekController.isShown { return nil }
    return content
  }

  private func isFocusedAndVisible(_ content: OEWebContent) -> Bool {
    guard content === focusedContent, let window = factory.window else { return false }
    return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
  }

  func existingSession(for content: OEWebContent) -> PageTranslationSession? { sessions[ObjectIdentifier(content)] }

  private func session(for content: OEWebContent) -> PageTranslationSession {
    let id = ObjectIdentifier(content)
    if let s = sessions[id] { return s }
    let s = PageTranslationSession(page: content, backend: backend, preferences: preferences)
    s.onStateChange = { [weak self, weak content] _ in
      guard let self, let content else { return }
      if content === self.focusedContent { self.syncStatus() }
    }
    s.onEvent = { [weak self, weak s] event in
      guard let self, let s else { return }
      self.handle(event, session: s, id: id)
    }
    if let apple = backend as? AppleTranslationBackend {
      // Only from a user action (the popover's Translate button or the context menu item):
      // macOS's download prompt. The SwiftUI host goes into the visible browser window (the
      // popover has closed by then, and a view in a hidden window never runs its task).
      s.prepareLanguages = { [weak self] source, target in
        guard let view = self?.factory.controller?.contentView, view.window?.isVisible == true else {
          throw TranslationFailure("Language not installed")
        }
        try await apple.prepare(from: source, to: target, in: view)
      }
    }
    sessions[id] = s
    return s
  }

  var focusedSession: PageTranslationSession? { focusedContent.flatMap { sessions[ObjectIdentifier($0)] } }

  // MARK: Status button and popover (§4.7.3)

  func syncStatus() {
    let item: URLStatusItem?
    switch focusedSession?.state ?? .idle {
    case .idle: item = nil
    case .offered, .failed:
      item = URLStatusItem(action: .translation, title: "Translation Available", compactTitle: "Translation…", symbol: "translate")
    case .translating: item = URLStatusItem(action: .translation, title: "Translating…", symbol: "translate", isBusy: true)
    case .translated: item = URLStatusItem(action: .translation, title: "Translated", symbol: "translate")
    }
    if factory.controller?.context.urlStatus != item { factory.controller?.context.urlStatus = item }
    if item == nil { popover?.dismiss() }
    if let popover, popover.isPresented, let content = popoverContent() { popover.update(content) }
  }

  private func popoverContent() -> TranslatePopoverContent? {
    guard let session = focusedSession, let offer = session.state.offer else { return nil }
    let target = PageLanguageDetector.displayName(offer.target), source = PageLanguageDetector.displayName(offer.source)
    let langs = (languages ?? []).filter { !PageLanguageDetector.sameLanguage(Locale.Language(identifier: $0.id), offer.source) }
    let current = langs.first { PageLanguageDetector.sameLanguage(Locale.Language(identifier: $0.id), offer.target) }?.id ?? offer.target.minimalIdentifier
    switch session.state {
    case .translated:
      return TranslatePopoverContent(mode: .translated, title: "Translated from \(source).", languages: langs, currentTarget: current)
    case .translating:
      return TranslatePopoverContent(mode: .translating, title: "Translate this page to \(target)?", languages: langs, currentTarget: current)
    case .failed(_, let reason):
      return TranslatePopoverContent(mode: .offer, title: "Translate this page to \(target)?", error: "Translation error (\(reason))",
        languages: langs, currentTarget: current)
    default:
      return TranslatePopoverContent(mode: .offer, title: "Translate this page to \(target)?", languages: langs, currentTarget: current)
    }
  }

  /// `.showTranslation(anchor:)` from the status button. A second click closes the popover.
  func showPopover(anchor: CGRect) -> Bool {
    guard let window = factory.window, let content = focusedContent, let s = sessions[ObjectIdentifier(content)],
      let body = popoverContent() else { return false }
    if let popover, popover.isPresented { popover.dismiss(); return true }
    let p = popover ?? makePopover(body)
    p.update(body)
    popoverSession = ObjectIdentifier(content)
    _ = s
    p.present(in: window, anchor: anchor)
    loadLanguages()
    return true
  }

  private func makePopover(_ content: TranslatePopoverContent) -> TranslatePopoverController {
    let p = TranslatePopoverController(content: content)
    p.view.onAction = { [weak self] action in self?.perform(action) }
    p.onDismiss = { [weak self] in self?.popoverSession = nil }
    factory.controller?.keyInterceptor = { [weak self] event in self?.popover?.handleKey(event) ?? false }
    popover = p
    return p
  }

  private func loadLanguages() {
    guard languages == nil, languagesTask == nil else { return }
    languagesTask = Task { [weak self] in
      guard let self else { return }
      var seen = Set<String>(), out: [TranslateLanguageOption] = []
      for language in await self.backend.supportedLanguages() {
        var key = language.languageCode?.identifier ?? language.minimalIdentifier
        if let script = language.script, key == "zh" { key += "-\(script.identifier)" }
        guard seen.insert(key).inserted else { continue }
        out.append(TranslateLanguageOption(id: key, name: PageLanguageDetector.displayName(Locale.Language(identifier: key))))
      }
      self.languages = out.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
      self.languagesTask = nil
      self.syncStatus()
    }
  }

  /// Every popover action, also from the page context menu (§4.7.3 "Close: … any action").
  func perform(_ action: TranslatePopoverAction) {
    popover?.dismiss()
    guard let session = focusedSession else { return }
    switch action {
    case .translate: Task { await session.translate() }
    case .showOriginal: Task { await session.revert() }
    case .chooseLanguage(let id): Task { await session.translate(to: Locale.Language(identifier: id)) }
    case .neverTranslate: Task { await session.neverTranslateThisSite() }
    case .languageSettings:
      // macOS manages translation languages in System Settings ▸ General ▸ Language & Region.
      if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
    }
  }

  // MARK: Toasts and undo (§4.1.4, §4.7.6)

  private func handle(_ event: PageTranslationSession.Event, session: PageTranslationSession, id: ObjectIdentifier) {
    switch event {
    case .translated(let target, let userAction):
      toast("Translated to \(PageLanguageDetector.displayName(target))")
      if userAction, !undoDriven.contains(id) { registerUndo(session, id: id, inverse: .revert) }
    case .reverted(let source, let userAction):
      toast("Translated back to \(PageLanguageDetector.displayName(source))")
      if userAction, !undoDriven.contains(id), let target = lastTarget[id] { registerUndo(session, id: id, inverse: .translate(target)) }
    case .failed(let reason):
      toast("Translation error (\(reason))")
    }
    if case .translated(let target, _) = event { lastTarget[id] = target }
    undoDriven.remove(id)
  }
  private var lastTarget: [ObjectIdentifier: Locale.Language] = [:]

  private enum Inverse { case revert, translate(Locale.Language) }

  /// "Translate" in the window's undo manager (the model's, `windowWillReturnUndoManager`). The App
  /// turns off grouping by event, so a user action opens its own group; an undo or redo registers
  /// its inverse inside the group the manager opened.
  private func registerUndo(_ session: PageTranslationSession, id: ObjectIdentifier, inverse: Inverse) {
    let manager = factory.app.undoManager
    let explicit = !manager.isUndoing && !manager.isRedoing
    if explicit { manager.beginUndoGrouping() }
    manager.registerUndo(withTarget: session) { [weak self] s in
      guard let self else { return }
      // The inverse of this step, registered now so it lands on the redo (or undo) stack.
      self.undoDriven.insert(id)
      switch inverse {
      case .revert:
        self.registerUndo(s, id: id, inverse: .translate(self.lastTarget[id] ?? s.state.offer?.target ?? Locale.Language(identifier: "en")))
        Task { await s.revert() }
      case .translate(let target):
        self.registerUndo(s, id: id, inverse: .revert)
        Task { await s.translate(to: target) }
      }
    }
    manager.setActionName("Translate")
    if explicit { manager.endUndoGrouping() }
  }

  // TODO(s8/toasts): move onto ToastCenter when Helper A's PR lands (page-platform §4.1.4:
  // "Translated to …" 3 s, "Translated back to …" 3 s, "Translation error (…)" 6 s).
  private func toast(_ title: String) {
    toastsShown.append(title); if toastsShown.count > 20 { toastsShown.removeFirst() }
    factory.controller?.showToast(title, undo: nil)
  }

  // MARK: Page context menu (followups: Translate in the context menu)

  /// "Translate to English" or "Show Original" for the page's context menu while the page has an
  /// offer. Chromium's own item never appears: without a Google API key `CanManuallyTranslate()`
  /// is false (page-platform §2.1 T-1), so Open adds its own item.
  func contextMenuItem(for content: OEWebContent) -> (title: String, action: TranslatePopoverAction)? {
    guard content === focusedContent, let session = sessions[ObjectIdentifier(content)], let offer = session.state.offer else { return nil }
    switch session.state {
    case .translated, .translating: return ("Show Original", .showOriginal)
    default: return ("Translate to \(PageLanguageDetector.displayName(offer.target))", .translate)
    }
  }

  // MARK: Automation

  func stateForAutomation() -> [String: Any] {
    var out: [String: Any] = ["backend": backend is FixtureTranslationBackend ? "fixture" : "apple"]
    let session = focusedSession
    let state = session?.state ?? .idle
    switch state {
    case .idle: out["state"] = "idle"
    case .offered: out["state"] = "offered"
    case .translating: out["state"] = "translating"
    case .translated: out["state"] = "translated"
    case .failed(_, let reason): out["state"] = "failed"; out["reason"] = reason
    }
    if let offer = state.offer {
      func code(_ l: Locale.Language) -> String { l.languageCode?.identifier ?? l.minimalIdentifier }
      out["source"] = code(offer.source); out["target"] = code(offer.target); out["targetIdentifier"] = offer.target.minimalIdentifier
      out["host"] = offer.host
    }
    out["sessions"] = sessions.count
    out["batches"] = session?.batchesApplied ?? 0
    out["pulls"] = session?.batchesPulled ?? 0
    out["fallbackUnits"] = session?.unitsFallback ?? 0
    out["loopRunning"] = session?.isLoopRunning ?? false
    out["sticky"] = session?.stickyTarget?.host ?? ""
    out["probedDocument"] = session?.probedDocument ?? -1
    if let content = focusedContent { out["document"] = documents[ObjectIdentifier(content)]?.count ?? 0 }
    if let sidebar = factory.controller?.sidebar {
      let s = sidebar.urlStatusState
      out["button"] = ["shown": s.shown, "title": s.title, "frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height]]
    }
    if let popover {
      var p: [String: Any] = ["presented": popover.isPresented, "title": popover.view.titleText, "buttons": popover.view.buttonTitles,
        "error": popover.view.errorText ?? NSNull()]
      if let f = popover.panelFrame { p["frame"] = [f.minX, f.minY, f.width, f.height] }
      p["window"] = popover.panelWindowNumber ?? 0
      p["aboveWindow"] = popover.isAboveParent
      p["stacking"] = [popover.stacking.panel ?? -1, popover.stacking.parent ?? -1]
      out["popover"] = p
    } else { out["popover"] = ["presented": false] }
    out["toasts"] = toastsShown
    out["neverTranslateHosts"] = preferences.neverTranslateHosts
    out["undoTitle"] = factory.app.undoManager.canUndo ? factory.app.undoManager.undoActionName : ""
    return out
  }
}
