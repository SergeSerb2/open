#if OPEN_AUTOMATION
import AppKit
import OpenEngine

/// Real native windows for the engine's profile proofs. No BrowserModel tabs,
/// history writer, Archive sink or durable window state participate here.
@MainActor
final class ProfileEngineProofWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let browser: OEBrowser
  let page: OEWebContent
  private var closed = false

  init(context: OEBrowserContext, url: URL) {
    window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 800, height: 600),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Profile engine proof"
    browser = OEBrowser(context: context)
    let configuration = OEWebContentConfiguration(context: context)
    configuration.runtimeStyle = .chrome
    page = OEWebContent(configuration: configuration, url: url)
    super.init()
    window.delegate = self
    browser.window = window
    browser.insert(page, at: 0)
    browser.activeWebContent = page
    window.contentView = page.view
    window.makeKeyAndOrderFront(nil)
    page.prepareForDisplay()
  }

  func windowWillClose(_ notification: Notification) { close(closeWindow: false) }
  func close() { close(closeWindow: true) }
  private func close(closeWindow: Bool) {
    guard !closed else { return }
    closed = true
    page.close()
    browser.close()
    window.delegate = nil
    if closeWindow { window.close() }
  }
}

extension AutomationController {
  func runProfileEngineCommand(_ a: [String: Any]) async throws -> Any {
    let action = a["action"] as? String ?? "state"
    let name = a["profile"] as? String ?? "Default"
    let key = a["key"] as? String ?? name
    func regular() throws -> OEBrowserContext {
      if let retained = profileProofContexts[name] { return retained }
      guard let profile = app.model.profiles.first(where: { $0.name == name }),
            let context = try window.context(for: profile.id) else {
        throw Failure(message: "profile context unavailable")
      }
      profileProofContexts[name] = context
      return context
    }
    switch action {
    case "private-open":
      guard key.count <= 64, profileProofWindows.count < 16, profileProofWindows[key] == nil else {
        throw Failure(message: "invalid or duplicate proof window key")
      }
      guard let url = URL(string: a["url"] as? String ?? "about:blank") else { throw Failure(message: "invalid URL") }
      let parent = try regular()
      let context: OEBrowserContext = try await withCheckedThrowingContinuation { continuation in
        OEEngine.shared.makeIncognitoContext(for: parent) { context, error in
          if let error { continuation.resume(throwing: error) }
          else if let context { continuation.resume(returning: context) }
          else { continuation.resume(throwing: Failure(message: "incognito context unavailable")) }
        }
      }
      let proof = ProfileEngineProofWindow(context: context, url: url)
      profileProofWindows[key] = proof
      return ["page": proof.page.identifier, "context": context.identifier,
              "parent": context.originalContext?.identifier ?? "", "ephemeral": context.isEphemeral]
    case "close":
      profileProofWindows.removeValue(forKey: key)?.close()
      return true
    case "clear":
      let context = try regular()
      guard a["kinds"] == nil || a["kinds"] is Int else { throw Failure(message: "invalid browsing-data kinds") }
      let kinds = a["kinds"] as? Int ?? 15
      guard let nativeKinds = UInt32(exactly: kinds) else { throw Failure(message: "invalid browsing-data kinds") }
      func date(_ key: String, fallback: Date) throws -> Date {
        guard let value = a[key] else { return fallback }
        guard let seconds = value as? Double, seconds.isFinite else { throw Failure(message: "invalid browsing-data time") }
        return Date(timeIntervalSince1970: seconds)
      }
      let begin = try date("begin", fallback: .distantPast)
      let end = try date("end", fallback: Date())
      let error: (any Error)? = await withCheckedContinuation { continuation in
        context.clearBrowsingData(OEBrowsingDataKinds(rawValue: nativeKinds), from: begin, to: end) {
          continuation.resume(returning: $0)
        }
      }
      if let error { throw error }
      return true
    case "delete":
      let context = try regular()
      let expected = a["coalesce"] as? Bool == true ? 2 : 1
      var completions = 0
      let error: (any Error)? = await withCheckedContinuation { continuation in
        var firstError: (any Error)?
        for _ in 0..<expected {
          OEEngine.shared.deleteContext(context) { error in
            if firstError == nil { firstError = error }
            completions += 1
            if completions == expected { continuation.resume(returning: firstError) }
          }
        }
      }
      if let error { throw error }
      // This explicit automation action proves the engine deletion barrier.
      // Product ProfileTeardown belongs to the profiles-shell child.
      guard let profile = app.model.profiles.first(where: { $0.name == name }) else { throw Failure(message: "profile missing") }
      await app.stores.flushHistory()
      if let fallback = app.model.spaces.first(where: { $0.profileID != profile.id }) { try window.focus(space: fallback) }
      for space in app.model.spaces.filter({ $0.profileID == profile.id }) {
        app.model.deleteSpace(id: space.id, archiveTabs: false)
      }
      guard try app.model.deleteProfile(id: profile.id) else { throw Failure(message: "model profile deletion refused") }
      try app.directories.deleteProfileData(for: profile)
      return ["closed": context.state == .closed, "directory": profile.dataDirectoryName,
              "completions": completions, "extensionsClosed": !context.extensions.isReady]
    case "state":
      return profileProofWindows.mapValues {
        ["page": $0.page.identifier, "context": $0.browser.context.identifier,
         "parent": $0.browser.context.originalContext?.identifier ?? "",
         "closed": $0.browser.context.state == .closed, "live": $0.page.isLive] as [String: Any]
      }
    default: throw Failure(message: "unknown profile engine action")
    }
  }
}
#endif
