#if OPEN_AUTOMATION
import OpenOnboarding
#endif
import AppKit
import OpenEngine
import OpenExtensionsUI
import OpenFeatures
import OpenWeb

@MainActor
private final class EngineExtensionPrompt: ExtensionPromptModel {
  let source: OEExtensionPrompt
  let type: ExtensionPromptType
  let icon: OpenWeb.ExtensionImage?
  private var answered = false
  var onAnswer: ((Bool) -> Void)?
  init(_ source: OEExtensionPrompt) {
    self.source = source
    type = switch source.type {
      case .install: .install; case .externalInstall: .externalInstall; case .remoteInstall: .remoteInstall
      case .repair: .repair; case .permissions: .permissions; case .reEnable: .reEnable; case .uninstall: .uninstall
      @unknown default: .repair
    }
    icon = EngineExtensionImages.shared.image(source.icon)
  }
  var extensionName: String { source.extensionName }
  var chromiumTitle: String { source.chromiumTitle }
  var chromiumAcceptLabel: String { source.chromiumAcceptLabel }
  var chromiumCancelLabel: String { source.chromiumCancelLabel }
  var triggeringExtensionName: String? { source.triggeringExtensionName }
  var permissions: [ExtensionPermissionMessage] {
    source.permissions.map { ExtensionPermissionMessage(Self.shown($0.message), details: $0.details.map(Self.shown)) }
  }
  /// Open has no accounts or sync: Chromium's history lines ("… on all your signed-in devices")
  /// would promise a reach that does not exist here (UX round 1 X4).
  static func shown(_ line: String) -> String {
    line.replacingOccurrences(of: " on all your signed-in devices", with: "")
  }
  func accept() { finish(true) }
  func cancel() { finish(false) }
  private func finish(_ accepted: Bool) {
    guard !answered else { return }; answered = true
    if accepted { source.accept() } else { source.cancel() }; onAnswer?(accepted); onAnswer = nil
  }
  isolated deinit { if !answered { source.cancel() } }
}

/// OEExtensionManager's sole App delegate, shared by the real sheets and automation.
@MainActor
final class ExtensionPromptPresenter: NSObject, OEExtensionManagerDelegate {
  unowned let app: AppDelegate
  private var queues: [ObjectIdentifier: ExtensionPromptQueue] = [:]
  private var windowObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]
  private var requests: [ObjectIdentifier: EngineExtensionPrompt] = [:]
  private(set) var pending: [OEExtensionPrompt] = []
  private var tables: [ObjectIdentifier: ExtensionShortcutTable] = [:]
  var events: [[String: Any]] = []
  #if OPEN_AUTOMATION
  var handlesPrompts = true
  var omniboxReply: [String: Any]?
  #endif
  init(app: AppDelegate) { self.app = app }
  func registerContexts() { for context in OEEngine.shared.contexts { register(context.extensions) } }
  func register(_ manager: OEExtensionManager) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("extensions.register")
    defer { pacingRegion?.end() }
    #endif
    #if OPEN_AUTOMATION
    guard handlesPrompts else { if manager.delegate === self { manager.delegate = nil }; return }
    #endif
    manager.delegate = self
    _ = table(manager)
  }
  /// Private sessions do not leave shortcut snapshots keyed by a dead manager.
  func unregister(_ manager: OEExtensionManager) {
    if manager.delegate === self { manager.delegate = nil }
    tables[ObjectIdentifier(manager)] = nil
  }
  func table(_ manager: OEExtensionManager) -> ExtensionShortcutTable {
    let key = ObjectIdentifier(manager)
    if let table = tables[key] { return table }
    let table = ExtensionShortcutTable(); table.rebuild(manager, overrides: app.keyBindings); tables[key] = table; return table
  }
  func rebuildShortcuts() {
    // OEEngine.contexts lists regular Profiles only: drop every snapshot so an Incognito
    // manager's table is built again (table(_:)) at its next key event or Settings read.
    tables.removeAll()
    for context in OEEngine.shared.contexts { _ = table(context.extensions) }
  }
  func extensionManager(_ manager: OEExtensionManager, show prompt: OEExtensionPrompt) {
    let key = ObjectIdentifier(prompt)
    guard requests[key] == nil else { return }
    guard pending.count < 32, !app.terminationRequested, let window = requestingWindow(prompt, manager: manager) else { prompt.cancel(); return }
    let model = EngineExtensionPrompt(prompt)
    guard ExtensionPromptSheet.accepts(model) else { prompt.cancel(); return }
    requests[key] = model; pending.append(prompt)
    model.onAnswer = { [weak self, weak prompt, weak manager] accepted in
      if let manager, let prompt, let attempt = self?.app.importRunner.extensionAttempt,
        attempt.matches(manager, prompt.extensionIdentifier) { attempt.answered(accepted) }
      self?.requests[key] = nil
      if let prompt { self?.pending.removeAll { $0 === prompt } }
    }
    let windowKey = ObjectIdentifier(window)
    let queue = queues[windowKey] ?? ExtensionPromptQueue(window: window); queues[windowKey] = queue
    if windowObservers[windowKey] == nil {
      windowObservers[windowKey] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.queues.removeValue(forKey: windowKey)?.cancelAll()
          if let observer = self.windowObservers.removeValue(forKey: windowKey) { NotificationCenter.default.removeObserver(observer) }
        }
      }
    }
    queue.enqueue(model)
  }
  private func requestingWindow(_ prompt: OEExtensionPrompt, manager: OEExtensionManager) -> NSWindow? {
    if let attempt = app.importRunner.extensionAttempt, attempt.matches(manager, prompt.extensionIdentifier) {
      guard let window = attempt.window, window.isVisible else { attempt.answered(false); return nil }
      return window
    }
    if let window = prompt.webContent?.view.window { return window }
    if let window = prompt.browser?.window { return window }
    // A Blank Window or Little Open window shows the Profile's context but closes on its own: never
    // a page-less prompt's host (below), or closing it would cancel the prompt.
    if let key = NSApp.keyWindow, let factory = app.factory(forKeyWindow: key), !factory.isBlankWindow,
      factory.standaloneSurface == nil, factory.littleOpenController == nil,
      factory.focusedBrowser?.context === manager.context { return factory.window }
    let ordered = NSApp.orderedWindows.compactMap { app.factory(forKeyWindow: $0) }
    if let window = ordered.first(where: { !$0.isBlankWindow && $0.standaloneSurface == nil && $0.littleOpenController == nil
      && $0.focusedBrowser?.context === manager.context })?.window { return window }
    // A prompt without a page (install, repair, re-enable, permissions) belongs to its Profile:
    // only a regular window that shows a Space of that Profile may host it. Never an Incognito
    // window, a Blank Window (its stand-in Profile has the real Profile's ID; it closes with its
    // last tab) or another Profile's window; with none, the caller cancels the prompt.
    guard let context = manager.context, !context.isEphemeral else { return nil }
    return ordered.first(where: { factory in
      !factory.isIncognito && !factory.isBlankWindow && factory.standaloneSurface == nil && factory.littleOpenController == nil
        && factory.focusedProfile.map { $0.id == factory.profile(for: context)?.id } == true
    })?.window
  }
  func extensionManagerDidChange(_ manager: OEExtensionManager) {
    app.settingsPresenter.refreshAdBlockWarning()
    record(["event": "changed", "context": manager.context?.identifier ?? ""])
  }
  func extensionManagerDidBecomeReady(_ manager: OEExtensionManager) {
    app.settingsPresenter.refreshAdBlockWarning()
    record(["event": "ready", "context": manager.context?.identifier ?? ""])
    table(manager).rebuild(manager, overrides: app.keyBindings)
  }
  func extensionManagerDidChangeCommands(_ manager: OEExtensionManager) {
    table(manager).rebuild(manager, overrides: app.keyBindings)
    record(["event": "commands", "context": manager.context?.identifier ?? ""])
  }
  func extensionManager(_ manager: OEExtensionManager, didInstall extensionInfo: OEExtension, byUser: Bool) {
    record(["event": "installed", "id": extensionInfo.identifier, "byUser": byUser])
    guard byUser else { return }
    // Registry delivery precedes action-list delivery. Read after Chromium completes this turn.
    DispatchQueue.main.async { [weak self, weak manager] in
      guard let self, let manager, !self.app.terminationRequested,
        let factory = self.app.frontWindowController.flatMap({ self.app.hostFactories[$0.windowID] }).flatMap({ $0.focusedBrowser?.context === manager.context ? $0 : nil })
          ?? self.app.hostFactories.values.first(where: { $0.focusedBrowser?.context === manager.context }),
        let browser = factory.focusedBrowser else { return }
      let pin = extensionInfo.hasAction && browser.extensionActions.contains { $0.extensionIdentifier == extensionInfo.identifier && !$0.isPinned }
      factory.controller?.toasts.show(ToastContent(title: "Added \(extensionInfo.name)",
        accessory: pin ? .button(symbol: "pin", accessibilityLabel: "Pin") : .none, lifetime: 3, coalescingKey: "extension-install")) { [weak browser] handle in
          browser?.setExtensionAction(extensionInfo.identifier, pinned: true); handle.dismiss()
      }
    }
  }
  func extensionManager(_ manager: OEExtensionManager, didFailToLoadExtensionAt path: URL, error: String) {
    record(["event": "loadFailed", "error": error])
    app.frontWindowController?.toasts.show(ToastContent(title: "Couldn't load extension", subtitle: error, lifetime: 6))
  }
  func record(_ event: [String: Any]) {
    if events.count >= 256 { events.removeFirst() }; events.append(event)
  }
  func cancelAll() {
    // Answers can synchronously remove requests; iterate a stable queue snapshot.
    Array(queues.values).forEach { $0.cancelAll() }; queues.removeAll(); pending.removeAll(); requests.removeAll()
    windowObservers.values.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
  }
  func cancel(window: NSWindow) {
    queues.removeValue(forKey: ObjectIdentifier(window))?.cancelAll()
  }
  isolated deinit { windowObservers.values.forEach { NotificationCenter.default.removeObserver($0) } }
  #if OPEN_AUTOMATION
  /// How the sheet's scrolling body ends, read from its real labels (UX round 1 X1): whether a text line is
  /// cut by the visible bottom edge, and whether anything marks that more of the list follows.
  func promptBodyState(_ view: ExtensionPromptView, scrollToEnd: Bool = false) -> [String: Any] {
    let scroll = view.bodyScroll
    guard let document = scroll.documentView, scroll.superview != nil else { return ["present": false] }
    if scrollToEnd {
      scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    let visible = scroll.contentView.bounds
    var cut: [String] = []
    var lastWholeLine = ""
    for case let label as NSTextField in document.subviews where label.stringValue != "•" {
      let font = label.font ?? .systemFont(ofSize: 13)
      let count = max(1, Int((label.frame.height / NSLayoutManager().defaultLineHeight(for: font)).rounded()))
      for k in 0..<count {
        let top = label.frame.minY + label.frame.height * CGFloat(k) / CGFloat(count)
        let bottom = label.frame.minY + label.frame.height * CGFloat(k + 1) / CGFloat(count)
        if top < visible.maxY - 0.5 && bottom > visible.maxY + 0.5 { cut.append(label.stringValue) }
        if bottom <= visible.maxY + 0.5 { lastWholeLine = label.stringValue }
      }
    }
    return ["present": true, "documentHeight": document.frame.height, "visibleHeight": visible.height,
      "visibleMaxY": visible.maxY, "overflows": document.frame.height > visible.height + 0.5,
      "lineCutAtBottom": !cut.isEmpty, "cutLines": cut, "lastVisibleLabel": lastWholeLine,
      "fadeMask": scroll.layer?.mask != nil, "hasScroller": scroll.hasVerticalScroller]
  }
  func scrollActiveBodyToEnd() -> [String: Any] {
    guard let view = queues.values.compactMap(\.active).first?.promptView else { return ["present": false] }
    return promptBodyState(view, scrollToEnd: true)
  }
  func answer(_ prompt: OEExtensionPrompt, accepted: Bool) {
    let key = ObjectIdentifier(prompt)
    for queue in queues.values where (queue.active?.promptView.model as? EngineExtensionPrompt)?.source === prompt {
      queue.active?.answer(accepted); return
    }
    // Waiting prompts keep FIFO order; automation cannot answer a hidden later sheet.
    if let model = requests[key], pending.first === prompt { if accepted { model.accept() } else { model.cancel() } }
  }
  func describe(_ prompt: OEExtensionPrompt) -> [String: Any] {
    guard let model = requests[ObjectIdentifier(prompt)] else { return ["pending": false] }
    let text = ExtensionPromptText(model)
    let sheet = queues.values.compactMap(\.active).first { ($0.promptView.model as? EngineExtensionPrompt)?.source === prompt }
    return ["pending": true, "type": model.type.rawValue, "extension": prompt.extensionIdentifier, "name": model.extensionName,
      "title": text.title, "buttons": [text.cancel, text.accept], "chromiumTitle": prompt.chromiumTitle,
      "chromiumButtons": [prompt.chromiumCancelLabel, prompt.chromiumAcceptLabel],
      "permissions": prompt.permissions.map { ["message": $0.message, "details": $0.details] },
      "permissionLines": prompt.permissions.flatMap { [$0.message] + $0.details },
      // The lines the sheet shows (after Open's wording), and how its scrolling body ends.
      "shownPermissionLines": model.permissions.flatMap { [$0.message] + $0.details },
      "body": sheet.map { promptBodyState($0.promptView) } ?? [:],
      "retainedFiles": prompt.retainedFiles, "retainedDevices": prompt.retainedDevices,
      "triggeringExtensionName": prompt.triggeringExtensionName ?? "", "webContent": prompt.webContent?.identifier ?? 0,
      "browser": prompt.browser?.identifier ?? 0, "sheetVisible": sheet?.isVisible == true,
      "sheet": sheet?.windowNumber ?? 0, "parentWindow": sheet?.sheetParent?.windowNumber ?? 0,
      "sheetClass": sheet.map { String(describing: type(of: $0)) } ?? ""]
  }
  #endif
}
