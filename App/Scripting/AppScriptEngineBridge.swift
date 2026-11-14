import AppKit
import OpenEngine
import OpenFeatures
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
    guard let app, app.engineReady, !app.shutdownPrepared, !app.terminationRequested else { return nil }
    if let controller = littleController(tabID) {
      // Browser creation follows the native first frame. Wait only for this active
      // execute request; its existing ten-second reply deadline cancels this task.
      while !Task.isCancelled && !app.shutdownPrepared && !app.terminationRequested {
        guard littleController(tabID) === controller else { return nil }
        if let surface = littleHost(tabID)?.view as? LittleOpenSurfaceView,
           let page = surface.owner?.surfacePage { return page }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
      }
      return nil
    }
    guard let tab = app.model?.tab(id: tabID) else { return nil }
    if let host = app.hostFactories.values.compactMap({ $0.hosts[tabID] }).first(where: { !$0.closed }) {
      if host.content.isPageFrozen { _ = host.content.setPageFrozen(false) }
      if host.content.isDiscarded { host.content.reload() }
      tab.live.sleepPhase = .live
      app.tabSleep.controller?.tabUserInteracted(tabID)
      return host.content
    }
    let history = await app.tabSleep.store?.sleepHistory(tabID: tabID)
    guard app.engineReady, !app.shutdownPrepared, app.model?.tab(id: tabID) === tab,
          let factory = app.frontMainModelWindowController.flatMap({ app.hostFactories[$0.windowID] }) else { return nil }
    let restore = history.flatMap { OENavigationHistory(container: $0.container) }
    let page = factory.ensureContent(for: tab, history: restore)
    // Restored background pages have no renderer until a navigation starts. Reload
    // the current entry without selecting the tab or exposing its hidden view.
    if restore != nil { page?.reload() }
    return page
  }

  private func littleController(_ id: ItemID) -> LittleOpenWindowController? {
    guard let app, !app.shutdownPrepared, !app.terminationRequested,
          let session = app.littleOpenCoordinator?.sessions.first(where: { $0.tab.id == id }) else { return nil }
    return app.littleOpenCoordinator.controllers[session.id]
  }
  private func littleHost(_ id: ItemID) -> (any WebContentHost)? {
    littleController(id)?.container.host(for: id)
  }

  private func perform(tabID: ItemID, _ operation: @escaping @MainActor (OEWebContent) -> Void) {
    Task { @MainActor [weak self] in
      guard let page = await self?.content(tabID: tabID) else { return }
      operation(page)
    }
  }
  func navigate(tabID: ItemID, to url: URL) {
    if let host = littleHost(tabID) { host.load(url); return }
    perform(tabID: tabID) { $0.load(url) }
  }
  func goBack(tabID: ItemID) {
    if let host = littleHost(tabID) { host.goBack(); return }
    perform(tabID: tabID) { $0.goBack() }
  }
  func goForward(tabID: ItemID) {
    if let host = littleHost(tabID) { host.goForward(); return }
    perform(tabID: tabID) { $0.goForward() }
  }
  func reload(tabID: ItemID) {
    if let host = littleHost(tabID) { host.reload(); return }
    perform(tabID: tabID) { $0.reload() }
  }
  func stopLoading(tabID: ItemID) {
    if let host = littleHost(tabID) { host.stop(); return }
    perform(tabID: tabID) { $0.stopLoading() }
  }

  private func owns(_ page: OEWebContent, tabID: ItemID) -> Bool {
    guard let app, app.engineReady, !app.shutdownPrepared, !app.terminationRequested else { return false }
    if let surface = littleHost(tabID)?.view as? LittleOpenSurfaceView {
      return surface.owner?.surfacePage === page
    }
    guard app.model?.tab(id: tabID) != nil else { return false }
    return app.hostFactories.values.contains { factory in
      guard let host = factory.hosts[tabID] else { return false }
      return !host.closed && host.content === page
    }
  }

  func executeJavaScript(tabID: ItemID, script: String) throws -> String {
    guard let app, app.engineReady, !app.shutdownPrepared,
          let command = NSScriptCommand.current() else { throw ScriptEngineError.noLiveContent }
    // A command's handler must return before resumeExecution. Task's main-actor hop
    // guarantees this, even when the engine refuses an evaluation immediately.
    command.suspendExecution()
    let reply = ScriptJavaScriptReply(command: command)
    reply.startTimeout()
    reply.readiness = Task { @MainActor [weak self] in
      guard let page = await self?.content(tabID: tabID) else {
        reply.finish(error: .noLiveContent); return
      }
      // Request-only: finish cancels the sleep, and a closed/replaced host ends the
      // wait even if the page never becomes live. There is no polling while idle.
      while !reply.finished && !Task.isCancelled {
        guard self?.owns(page, tabID: tabID) == true else {
          reply.finish(error: .noLiveContent); return
        }
        if page.isLive && !page.isLoading {
          reply.readiness = nil
          reply.evaluate(page, expression: script)
          return
        }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }

    // Cocoa ignores the immediate handler result while suspended. The sender still waits
    // synchronously for the final text or plan error supplied by ScriptJavaScriptReply.
    return ""
  }
}

/// Scripting sees the coordinator's transient session tab, never a sidebar Tab.
/// Page operations stay in AppScriptEngineBridge, the sole engine boundary.
@MainActor
private final class AppScriptLittleTabs: LittleTabProviding {
  private weak var app: AppDelegate?
  init(app: AppDelegate) { self.app = app }
  private func controller(_ id: ItemID) -> LittleOpenWindowController? {
    guard let app, !app.shutdownPrepared, !app.terminationRequested,
          let session = app.littleOpenCoordinator?.sessions.first(where: { $0.tab.id == id }) else { return nil }
    return app.littleOpenCoordinator.controllers[session.id]
  }
  func make(url: URL?) -> ItemID? {
    guard let app, app.engineReady, !app.shutdownPrepared, !app.terminationRequested else { return nil }
    let id = app.littleOpenCoordinator?.create(url: url ?? URL(string: "about:blank")!, focus: url == nil)
    if id != nil { NSApp.activate() }
    return id
  }
  func exists(_ id: ItemID) -> Bool { controller(id) != nil }
  func url(_ id: ItemID) -> URL? { controller(id).map { $0.currentURL ?? $0.session.tab.url } }
  func title(_ id: ItemID) -> String { controller(id)?.session.tab.displayTitle ?? "" }
  func loading(_ id: ItemID) -> Bool { controller(id)?.container.host(for: id)?.isLoading ?? false }
  func canGoBack(_ id: ItemID) -> Bool { controller(id)?.container.host(for: id)?.canGoBack ?? false }
  func canGoForward(_ id: ItemID) -> Bool { controller(id)?.container.host(for: id)?.canGoForward ?? false }
  func close(_ id: ItemID) {
    guard let controller = controller(id) else { return }
    app?.littleOpenCoordinator.close(sessionID: controller.session.id, archiveReason: nil)
  }
}

/// One reply, including when completion arrives after the deadline. No repeating timer.
@MainActor
private final class ScriptJavaScriptReply {
  private var command: NSScriptCommand?
  private var timeout: Task<Void, Never>?
  var readiness: Task<Void, Never>?
  private weak var page: OEWebContent?
  private let objectGroup = "open-applescript-" + UUID().uuidString
  private var serializing = false
  var finished: Bool { command == nil }
  init(command: NSScriptCommand) { self.command = command }
  func startTimeout() {
    // Retain the reply until completion/deadline; finish breaks this ownership.
    // The engine callback is weak because an awaited promise may never settle.
    timeout = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      self.finish(error: .timedOut)
    }
  }
  func evaluate(_ page: OEWebContent, expression: String) {
    self.page = page
    // Evaluate the source directly: nested eval is blocked by a page's CSP.
    // Keep explicit eval inside user source subject to the page policy, too.
    // AppleScript grants no user gesture. Swift owns the promise reply deadline;
    // CDP's timeout also stops synchronous loops. Late callbacks cannot retain us.
    page.sendDevToolsMethod("Runtime.evaluate", parameters: ["expression": expression,
      "awaitPromise": true, "returnByValue": false, "userGesture": false, "timeout": 10_000,
      "allowUnsafeEvalBlockedByCSP": false,
      "objectGroup": objectGroup]) { [weak self, weak page] result, error in
      guard let self, !self.finished else { return }
      guard let remote = self.remoteObject(result, error: error) else { return }
      let type = remote["type"] as? String
      if (type == "object" && remote["subtype"] as? String != "null") || type == "function" || type == "symbol" {
        guard let page else { self.finish(error: .noLiveContent); return }
        self.serialize(page, remote: remote)
      } else {
        do { self.finish(text: try Self.text(remote)) }
        catch { self.finish(error: .javascriptError("JavaScript result is not serializable.")) }
      }
    }
  }

  private func remoteObject(_ result: [String: Any]?, error: (any Error)?) -> [String: Any]? {
    if let error { finish(error: .javascriptError(error.localizedDescription)); return nil }
    if let exception = result?["exceptionDetails"] as? [String: Any] {
      let detail = exception["exception"] as? [String: Any]
      finish(error: .javascriptError(detail?["description"] as? String ?? exception["text"] as? String ?? "JavaScript exception"))
      return nil
    }
    guard let remote = result?["result"] as? [String: Any] else {
      finish(error: .javascriptError("JavaScript result is not serializable.")); return nil
    }
    return remote
  }

  private func serialize(_ page: OEWebContent, remote: [String: Any]) {
    guard !finished, let objectID = remote["objectId"] as? String else {
      finish(error: .javascriptError("JavaScript result is not serializable.")); return
    }
    // Never evaluate the source again. Only stringify the captured result. Strict
    // this preserves symbol primitives. JSON.stringify has its normal toJSON/getter
    // behavior. The original reply deadline covers this call too; no second timer.
    let serializer = remote["type"] as? String == "object"
      ? "function() { 'use strict'; return JSON.stringify(this); }"
      : "function() { 'use strict'; return String(this); }"
    serializing = true
    page.sendDevToolsMethod("Runtime.callFunctionOn", parameters: ["objectId": objectID,
      "functionDeclaration": serializer, "returnByValue": true, "userGesture": false,
      "objectGroup": objectGroup]) { [weak self] result, error in
      guard let self, !self.finished, let value = self.remoteObject(result, error: error) else { return }
      if let text = value["value"] as? String { self.finish(text: text) }
      else { self.finish(error: .javascriptError("JavaScript result is not serializable.")) }
    }
  }

  private static func text(_ remote: [String: Any]) throws -> String {
    switch remote["type"] as? String {
    case "undefined": return ""
    case "string":
      if let value = remote["value"] as? String { return value }
    case "boolean":
      if let value = remote["value"] as? NSNumber { return value.boolValue ? "true" : "false" }
    case "number":
      if let value = remote["unserializableValue"] as? String {
        return value == "-0" ? "0" : value
      }
      if let value = remote["value"] as? NSNumber { return numberText(value) }
    case "bigint":
      if let value = remote["unserializableValue"] as? String, value.hasSuffix("n") {
        return String(value.dropLast())
      }
    case "object":
      if remote["subtype"] as? String == "null" { return "" }
    default: break
    }
    throw ScriptEngineError.javascriptError("JavaScript result is not serializable.")
  }

  /// Swift supplies shortest round-trip digits. JS uses fixed notation in
  /// [1e-6, 1e21), no redundant .0, and no leading zero in an exponent.
  private static func numberText(_ number: NSNumber) -> String {
    let value = number.doubleValue
    if value == 0 { return "0" }
    let parts = String(value).lowercased().split(separator: "e")
    var coefficient = String(parts[0])
    if coefficient.hasSuffix(".0") { coefficient.removeLast(2) }
    guard parts.count == 2, let exponent = Int(parts[1]) else { return coefficient }
    if abs(value) < 1e-6 || abs(value) >= 1e21 {
      return coefficient + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }
    let sign = coefficient.hasPrefix("-") ? "-" : ""
    if !sign.isEmpty { coefficient.removeFirst() }
    let decimal = coefficient.split(separator: ".")
    let digits = decimal.joined()
    let point = decimal[0].count + exponent
    if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
    if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
    let index = digits.index(digits.startIndex, offsetBy: point)
    return sign + String(digits[..<index]) + "." + String(digits[index...])
  }

  func finish(text: String? = nil, error: ScriptEngineError? = nil) {
    guard let command else { return }
    self.command = nil
    timeout?.cancel(); timeout = nil
    readiness?.cancel(); readiness = nil
    // callFunctionOn has no CDP timeout. Stop a stuck toJSON/getter at the shared
    // deadline before releasing its handles. No user source is evaluated again.
    if serializing, case .timedOut? = error {
      page?.sendDevToolsMethod("Runtime.terminateExecution", parameters: nil, completion: nil)
    }
    serializing = false
    // Release the first call's handles on success, error and timeout, without
    // holding the page or reply in a pending callback.
    page?.sendDevToolsMethod("Runtime.releaseObjectGroup", parameters: ["objectGroup": objectGroup], completion: nil)
    page = nil
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
    host.littleTab = AppScriptLittleTabs(app: self)
    refreshScriptingEngine()
    host.purgeRemovedWrappers()
  }
  func purgeScriptingWrappers() { ScriptHost.shared.purgeRemovedWrappers() }
  func refreshScriptingEngine() {
    ScriptHost.shared.engineBridge = engineReady ? AppScriptEngineBridge(app: self) : nil
  }
}
