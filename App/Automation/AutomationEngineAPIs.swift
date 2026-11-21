#if OPEN_AUTOMATION
import AppKit
import OpenEngine

/// Real OpenEngine callers with real Chromium documents and native windows.
/// The fixture owns no shell tabs or durable browser state.
@MainActor
final class EngineAPIProof: NSObject, OEWebContentDelegate, OEBrowserDelegate {
  var browsers: [String: OEBrowser] = [:]
  var windows: [String: NSWindow] = [:]
  var pages: [String: OEWebContent] = [:]
  var requests: [Int: OEAuthenticationRequest] = [:]
  var cancelled = 0
  var received = 0
  var inTransfer = false
  var synchronousCallbacks = 0
  var handlesAuth = true
  /// JavaScript dialogs this delegate declined (returned false: the engine's default dialog).
  var dialogsDeclined = 0
  private var nextRequest = 1
  var frameRequests: [String: OEWebContentFrameRequest] = [:]
  var frameReceipts: [[String: Any]] = []
  var armingFrameRequest = false

  init(context: OEBrowserContext, other: OEBrowserContext) {
    super.init()
    for key in ["a", "b", "c", "d"] {
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Engine API proof"
      let browser = OEBrowser(context: key == "c" ? other : context)
      browser.window = window
      browser.delegate = self
      browsers[key] = browser; windows[key] = window
    }
  }

  func add(_ key: String, browser: String, url: URL) throws {
    guard pages.count < 4, pages[key] == nil, let owner = browsers[browser],
      let window = windows[browser] else { throw AutomationController.Failure(message: "invalid proof page") }
    let config = OEWebContentConfiguration(context: owner.context)
    config.runtimeStyle = .chrome
    let page = OEWebContent(configuration: config, url: url)
    pages[key] = page; page.delegate = self
    owner.insert(page, at: UInt(owner.webContents.count))
    owner.activeWebContent = page
    window.contentView = page.view
    window.makeKeyAndOrderFront(nil)
    page.prepareForDisplay()
  }

  func webContent(_ page: OEWebContent, didChange changes: OEWebContentChange) {
    if inTransfer { synchronousCallbacks += 1 }
  }
  func browserDidUpdateExtensionActions(_ browser: OEBrowser) {
    if inTransfer { synchronousCallbacks += 1 }
  }
  func webContent(_ page: OEWebContent, handleAuthenticationRequest request: OEAuthenticationRequest) -> Bool {
    if inTransfer { synchronousCallbacks += 1 }
    received += 1
    guard handlesAuth, requests.count < 16, nextRequest < 1024 else { return false }
    requests[nextRequest] = request; nextRequest += 1
    return true
  }
  func webContent(_ page: OEWebContent, runJavaScriptDialog dialog: OEJavaScriptDialog) -> Bool {
    dialogsDeclined += 1
    return false
  }
  func webContent(_ page: OEWebContent, didCancelAuthenticationRequest request: OEAuthenticationRequest) {
    cancelled += 1
    requests = requests.filter { $0.value !== request }
  }

  func state() -> [String: Any] {
    ["pages": pages.mapValues { page in
      ["id": page.identifier, "tabID": page.chromeTabIdentifier,
       "live": page.isLive, "loading": page.isLoading,
       "framePresentation": page.supportsFramePresentation,
       "url": page.url?.absoluteString ?? "", "title": page.title ?? "",
       "pinned": page.browser?.isPinned(page) ?? false,
       "view": String(describing: ObjectIdentifier(page.view)),
       "browser": page.browser?.identifier ?? -1] as [String: Any]
    }, "browsers": browsers.mapValues {
      ["id": $0.identifier, "windowID": $0.chromeWindowIdentifier,
       "tabs": $0.webContents.map(\.identifier)] as [String: Any]
    }, "requests": requests.keys.sorted().map { id -> [String: Any] in
      let r = requests[id]!
      let pending: Bool = r.isPending
      let proxy: Bool = r.isProxyAuthentication
      return ["id": id, "pending": pending, "origin": r.originURL?.absoluteString ?? "",
        "realm": r.realm, "scheme": r.scheme, "proxy": proxy,
        "host": r.host, "port": r.port] as [String: Any]
    }, "frameReceipts": frameReceipts, "received": received, "cancelled": cancelled,
     "synchronousCallbacks": synchronousCallbacks, "dialogsDeclined": dialogsDeclined,
     "visibleWindows": NSApp.windows.filter(\.isVisible).count]
  }

  func close() {
    for request in frameRequests.values { request.cancel() }
    frameRequests.removeAll()
    for request in requests.values { request.cancel() }
    requests.removeAll()
    for page in pages.values { page.delegate = nil; page.close(); page.view.removeFromSuperview() }
    pages.removeAll()
    for browser in browsers.values { browser.delegate = nil; browser.close() }
    browsers.removeAll()
    for window in windows.values { window.close() }
    windows.removeAll()
  }
}

extension AutomationController {
  func runEngineAPICommand(_ args: [String: Any]) async throws -> Any {
    let action = args["action"] as? String ?? "state"
    if action == "start" {
      engineAPIProof?.close(); engineAPIProof = nil
      let context = OEEngine.shared.defaultContext
      let other: OEBrowserContext = try await withCheckedThrowingContinuation { continuation in
        OEEngine.shared.makeIncognitoContext(for: context) { result, error in
          if let error { continuation.resume(throwing: error) }
          else if let result { continuation.resume(returning: result) }
          else { continuation.resume(throwing: Failure(message: "context unavailable")) }
        }
      }
      engineAPIProof = EngineAPIProof(context: context, other: other)
    }
    guard let proof = engineAPIProof else { throw Failure(message: "proof not started") }
    switch action {
    case "start", "state": return proof.state()
    case "add":
      guard let key = args["page"] as? String, key.count <= 16,
        let owner = args["browser"] as? String,
        let raw = args["url"] as? String, raw.count <= 16384,
        let url = URL(string: raw) else { throw Failure(message: "invalid page") }
      try proof.add(key, browser: owner, url: url)
    case "eval":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let js = args["js"] as? String, js.count <= 16384 else { throw Failure(message: "invalid eval") }
      return try await page.evaluateJavaScript(js) ?? NSNull()
    case "devtools":
      // Raw JSON parameters (including null values) reach the engine unchanged.
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let method = args["method"] as? String, method.count <= 128 else { throw Failure(message: "invalid devtools") }
      return try await page.sendDevToolsMethod(method, parameters: args["params"] as? [String: Any])
    case "presentation-request":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let width = args["pixelWidth"] as? Int,
        let height = args["pixelHeight"] as? Int,
        width > 0, height > 0, width <= 32768, height <= 32768,
        proof.frameRequests.count < 64,
        let requestID = UUID(uuidString: args["requestID"] as? String ?? ""),
        let window = page.view.window else { throw Failure(message: "invalid presentation request") }
      let id = requestID.uuidString
      let scale = args["scale"] as? Double ?? Double(window.backingScaleFactor)
      let started = ProcessInfo.processInfo.systemUptime
      proof.armingFrameRequest = true
      let request = page.requestFramePresentation(pixelSize: NSSize(width: CGFloat(width), height: CGFloat(height)),
        backingScale: scale, requestID: requestID,
        retainingSurfaceForResize: args["retain"] as? Bool ?? false) { [weak proof] receipt in
          guard let proof else { return }
          var row: [String: Any] = ["requestID": id, "success": receipt != nil,
            "startedAt": started, "callbackAt": ProcessInfo.processInfo.systemUptime,
            "synchronous": proof.armingFrameRequest]
          if let receipt {
            row["receiptID"] = receipt.requestID.uuidString
            row["pixelSize"] = [receipt.pixelSize.width, receipt.pixelSize.height]
            row["scale"] = receipt.backingScale
            row["presentedAt"] = receipt.presentedAt
          }
          proof.frameReceipts.append(row)
        }
      proof.armingFrameRequest = false
      if let request { proof.frameRequests[id] = request }
      if let size = args["resizeTo"] as? [Double], size.count == 2,
        size.allSatisfy({ $0 >= 100 && $0 <= 4096 }) {
        window.setContentSize(NSSize(width: size[0], height: size[1]))
      }
      switch args["then"] as? String {
      case "cancel": request?.cancel(); request?.cancel()
      case "detach": page.view.removeFromSuperview()
      case "navigate": page.load(URL(string: "about:blank")!)
      case "same-document":
        if let url = page.url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
          components.fragment = "presentation-cancel"
          if let destination = components.url { page.load(destination) }
        }
      case "close": page.close()
      default: break
      }
      return ["accepted": request != nil, "requestID": id,
        "requestedPixelSize": [width, height], "scale": scale,
        "actualLogicalSize": [page.view.bounds.width, page.view.bounds.height]] as [String: Any]
    case "presentation-cancel":
      guard let id = args["requestID"] as? String else { throw Failure(message: "missing request") }
      proof.frameRequests[id]?.cancel()
    case "presentation-viewport":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let window = page.view.window else { throw Failure(message: "missing viewport") }
      return ["logicalSize": [page.view.bounds.width, page.view.bounds.height],
        "pixelSize": [round(page.view.bounds.width * window.backingScaleFactor),
          round(page.view.bounds.height * window.backingScaleFactor)],
        "scale": window.backingScaleFactor, "window": window.windowNumber] as [String: Any]
    case "transfer":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let source = proof.browsers[args["from"] as? String ?? ""],
        let target = proof.browsers[args["to"] as? String ?? ""],
        let index = args["index"] as? Int, index >= 0 else { throw Failure(message: "invalid transfer") }
      proof.inTransfer = true
      let moved = target.transfer(page, from: source, at: UInt(index))
      proof.inTransfer = false
      if moved && args["attach"] as? Bool != false {
        page.view.removeFromSuperview()
        let window = proof.windows[args["to"] as? String ?? ""]
        window?.contentView = page.view
        window?.makeKeyAndOrderFront(nil)
        target.activeWebContent = page
      }
      return ["moved": moved, "state": proof.state()] as [String: Any]
    case "attach":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let key = args["browser"] as? String, let owner = proof.browsers[key],
        let window = proof.windows[key], page.browser === owner else {
        throw Failure(message: "invalid attachment")
      }
      if page.view.window !== window {
        page.view.removeFromSuperview()
        window.contentView = page.view
      }
      if args["focus"] as? Bool != false {
        window.makeKeyAndOrderFront(nil)
        owner.activeWebContent = page
      }
    case "close-browser":
      guard let key = args["browser"] as? String, let browser = proof.browsers[key] else {
        throw Failure(message: "invalid browser")
      }
      browser.close(); proof.windows[key]?.orderOut(nil)
    case "navigate":
      guard let page = proof.pages[args["page"] as? String ?? ""],
        let raw = args["url"] as? String, raw.count <= 16384, let url = URL(string: raw) else {
        throw Failure(message: "invalid navigation")
      }
      page.load(url)
    case "auth":
      if let handles = args["handles"] as? Bool { proof.handlesAuth = handles }
      if let id = args["id"] as? Int, let request = proof.requests[id] {
        if args["cancel"] as? Bool == true { request.cancel() }
        else if let user = args["username"] as? String, let password = args["password"] as? String {
          request.continue(username: user, password: password)
        } else { throw Failure(message: "missing answer") }
        // Deliberate second completion proves one-shot answers safely no-op.
        request.cancel()
        proof.requests.removeValue(forKey: id)
      }
    case "stop":
      guard let page = proof.pages[args["page"] as? String ?? ""] else {
        throw Failure(message: "invalid page")
      }
      page.stopLoading()
    case "pin":
      guard let page = proof.pages[args["page"] as? String ?? ""], let browser = page.browser else {
        throw Failure(message: "invalid page")
      }
      browser.setPinned(args["pinned"] as? Bool ?? false, for: page)
    case "cleanup":
      proof.close(); engineAPIProof = nil
      return ["remainingWindows": NSApp.windows.filter { $0.isVisible && $0.title == "Engine API proof" }.count,
        "pending": proof.requests.count]
    default: throw Failure(message: "unknown engine API action")
    }
    return proof.state()
  }
}
#endif
