import AppKit
import OpenEngine
import OpenRouting
import OpenFeatures

/// External `mailto:` links (Arc's Info.plist registers `mailto`, "Email Address URL"). The focused
/// Profile's web protocol handler (a webmail site the user allowed with "Make <site> your default mail
/// app?", engine #471) turns the address into its compose page, which then routes like any external
/// web link (Air Traffic Control rules). GUESS — capture C3-PB1-k pending: what Arc does with no
/// handler (Open opens nothing and says so in a toast) and which Profile it asks.
@MainActor
final class MailtoRouter {
  private unowned let app: AppDelegate
  private var pending: [(URL, RoutingSource)] = []
  private(set) var last: (input: String, output: String?)?
  private(set) var handledCount = 0

  init(app: AppDelegate) { self.app = app }

  static func matches(_ url: URL) -> Bool { url.scheme?.lowercased() == "mailto" }

  func handle(_ url: URL, source: RoutingSource) {
    guard url.absoluteString.utf8.count <= 64 * 1024 else { AppDelegate.commandLog("Ignored an oversized mailto link."); return }
    if app.linkIntake.ready { route(url, source: source) } else { pending.append((url, source)) }
  }

  func markReady() {
    let queued = pending; pending.removeAll()
    for (url, source) in queued { route(url, source: source) }
  }

  private func route(_ url: URL, source: RoutingSource) {
    handledCount += 1
    let factory = app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
    let target = factory?.focusedBrowser(create: true)?.context.protocolHandlerURL(for: url)
    last = (url.scheme ?? "", target?.absoluteString)
    if let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
      app.linkIntake.handle(urls: [target], source: source)
      return
    }
    AppDelegate.commandLog("A mailto link arrived with no mail site set up.")
    factory?.controller?.toasts.show(ToastContent(title: "No email site is set up. Open your webmail and allow it as your mail app."))
  }
}
