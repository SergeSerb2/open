import AppKit
import OpenEngine
import OpenModel
import OpenScripting

/// H1/H2: the sole OpenScripting/OpenEngine boundary. ItemIDs use the existing host map;
/// engine events own model URLs. OpenEngine evaluation and its completion both require the
/// main thread. Suspend the Cocoa command instead of blocking that thread or pumping its
/// run loop (applescript §7.2's background-completion assumption does not hold).
@MainActor
final class AppScriptEngineBridge: ScriptEngineBridge {
  weak var app: AppDelegate?
  init(app: AppDelegate) { self.app = app }

  private func content(tabID: ItemID) async -> OEWebContent? {
    guard let app, app.engineReady, !app.shutdownPrepared, !app.terminationRequested,
          let tab = app.model?.tab(id: tabID) else { return nil }
    if let host = app.hostFactories.values.compactMap({ $0.hosts[tabID] }).first(where: { !$0.closed }) {
      if host.content.isPageFrozen { _ = host.content.setPageFrozen(false) }
      if host.content.isDiscarded { host.content.reload() }
      tab.live.sleepPhase = .live
      app.tabSleep.controller?.tabUserInteracted(tabID)
      return host.content
    }
    let history = await app.tabSleep.store?.sleepHistory(tabID: tabID)
    guard app.engineReady, !app.shutdownPrepared, app.model?.tab(id: tabID) === tab,
          let factory = app.frontWindowController.flatMap({ app.hostFactories[$0.windowID] }) else { return nil }
    let restore = history.flatMap { OENavigationHistory(container: $0.container) }
    let page = factory.ensureContent(for: tab, history: restore)
    // Restored background pages have no renderer until a navigation starts. Reload
    // the current entry without selecting the tab or exposing its hidden view.
    if restore != nil { page?.reload() }
    return page
  }

  private func perform(tabID: ItemID, _ operation: @escaping @MainActor (OEWebContent) -> Void) {
    Task { @MainActor [weak self] in
      guard let page = await self?.content(tabID: tabID) else { return }
      operation(page)
    }
  }
  func navigate(tabID: ItemID, to url: URL) { perform(tabID: tabID) { $0.load(url) } }
  func goBack(tabID: ItemID) { perform(tabID: tabID) { $0.goBack() } }
  func goForward(tabID: ItemID) { perform(tabID: tabID) { $0.goForward() } }
  func reload(tabID: ItemID) { perform(tabID: tabID) { $0.reload() } }
  func stopLoading(tabID: ItemID) { perform(tabID: tabID) { $0.stopLoading() } }

  func executeJavaScript(tabID: ItemID, script: String) throws -> String {
    guard let app, app.engineReady, !app.shutdownPrepared,
          let command = NSScriptCommand.current() else { throw ScriptEngineError.noLiveContent }
    // A command's handler must return before resumeExecution. Task's main-actor hop
    // guarantees this, even when the engine refuses an evaluation immediately.
    command.suspendExecution()
    let reply = ScriptJavaScriptReply(command: command)
    reply.startTimeout()
    Task { @MainActor [weak self] in
      guard let page = await self?.content(tabID: tabID) else {
        reply.finish(error: .noLiveContent); return
      }
      // A newly created or restored renderer needs a live main frame. This wait exists
      // only for this request, is cancelled by the reply deadline, and does no idle work.
      while !reply.finished && (!page.isLive || page.isLoading) {
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard !reply.finished else { return }
      do {
        // Conversion happens in the page to preserve JS booleans, non-finite numbers,
        // negative zero and BigInt text. Objects/arrays use JSON, null/undefined empty text.
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: script, options: [.fragmentsAllowed]), as: UTF8.self)
        let expression = "new Promise((resolve, reject) => { const timer = setTimeout(() => resolve(null), 10000); Promise.resolve().then(() => (0, eval)(\(literal))).then(v => { clearTimeout(timer); resolve({text: v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v)}); }, e => { clearTimeout(timer); reject(e); }); })"
        reply.evaluate(page, expression: expression)
      } catch { reply.finish(error: .javascriptError("JavaScript execution failed.")) }
    }
    // Cocoa ignores the immediate handler result while suspended. The sender still waits
    // synchronously for the final text or plan error supplied by ScriptJavaScriptReply.
    return ""
  }
}

/// One reply, including when completion arrives after the deadline. No repeating timer.
@MainActor
private final class ScriptJavaScriptReply {
  private var command: NSScriptCommand?
  private var timeout: Task<Void, Never>?
  var finished: Bool { command == nil }
  init(command: NSScriptCommand) { self.command = command }
  func startTimeout() {
    timeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      self?.finish(error: .timedOut)
    }
  }
  func evaluate(_ page: OEWebContent, expression: String) {
    // CDP's timeout stops synchronous infinite loops; the Promise deadline also
    // releases its callback for a never-settling promise. Both are request-only.
    page.sendDevToolsMethod("Runtime.evaluate", parameters: ["expression": expression,
      "awaitPromise": true, "returnByValue": true, "userGesture": true, "timeout": 10_000]) { result, error in
      if let error { self.finish(error: .javascriptError(error.localizedDescription)); return }
      if let exception = result?["exceptionDetails"] as? [String: Any] {
        let detail = exception["exception"] as? [String: Any]
        self.finish(error: .javascriptError(detail?["description"] as? String ?? exception["text"] as? String ?? "JavaScript exception"))
      } else if let remote = result?["result"] as? [String: Any],
                let value = remote["value"] as? [String: Any], let text = value["text"] as? String {
        self.finish(text: text)
      } else { self.finish(error: .timedOut) }
    }
  }
  func finish(text: String? = nil, error: ScriptEngineError? = nil) {
    guard let command else { return }
    self.command = nil
    timeout?.cancel(); timeout = nil
    if let error {
      switch error {
      case .timedOut:
        command.scriptErrorNumber = ScriptError.javascriptTimedOut
        command.scriptErrorString = "JavaScript did not finish in 10 seconds."
      case .noLiveContent:
        command.scriptErrorNumber = ScriptError.engineUnavailable
        command.scriptErrorString = "The page engine is not ready."
      case .javascriptError(let message):
        command.scriptErrorNumber = ScriptError.javascriptFailed
        command.scriptErrorString = "JavaScript error: " + String(message.prefix { !$0.isNewline }.prefix(300))
      }
    }
    command.resumeExecution(withResult: text as NSString?)
  }
}

extension AppDelegate {
  /// Called from applicationDidFinishLaunching after the model and window registry exist.
  /// Weak owner capture reads the current model even if the App later replaces it.
  func installScripting() {
    let host = ScriptHost.shared
    host.modelProvider = { [weak self] in self?.model }
    host.windowStateID = { [weak self] window in
      self?.windowControllers.first { $0.window === window }?.windowID
    }
    host.windowForState = { [weak self] id in
      self?.windowControllers.first { $0.windowID == id }?.window
    }
    host.makeWindow = { [weak self] incognito in
      guard !incognito else { return nil }
      return self?.makeWindow()?.windowID
    }
    // Main has only showLittleOpenStub; no real section 9 executor exists yet.
    host.makeLittleTab = nil
    refreshScriptingEngine()
    host.purgeRemovedWrappers()
  }
  func purgeScriptingWrappers() { ScriptHost.shared.purgeRemovedWrappers() }
  func refreshScriptingEngine() {
    ScriptHost.shared.engineBridge = engineReady ? AppScriptEngineBridge(app: self) : nil
  }
}
