import AppKit
import OpenEngine
import OpenRouting
import OpenFeatures
import OpenModel

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

  private func frontLittleOpen() -> LittleOpenWindowController? {
    let browsers = Set(app.windowControllers.compactMap { $0.window.map(ObjectIdentifier.init) })
    for window in NSApp.orderedWindows where window.isVisible {
      if let controller = app.littleOpenCoordinator?.controllers.values.first(where: { $0.window === window }) { return controller }
      if browsers.contains(ObjectIdentifier(window)) { return nil }
    }
    return nil
  }

  private func route(_ url: URL, source: RoutingSource) {
    let factory = app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
    let context: OEBrowserContext?
    // The compose page opens in the Profile whose handler made it. With no window open, ask the Profile
    // of the first saved standard window's Space (else the default Profile). GUESS, as above.
    // A key Little Open window (tracked outside windowControllers) names its own Profile.
    // With Open inactive there is no key window: use a Little Open window in front of every
    // browser window (bug sweep r5 item 4).
    let littleOpen = (app.keyLittleOpen ?? frontLittleOpen()).flatMap { app.model.profile(id: $0.session.profileID) }
    let regular = littleOpen ?? factory?.incognitoSession?.parent ?? (factory == nil ? noWindowProfile() : nil)
    let profile = regular?.id ?? factory?.focusedProfile?.id
    if let regular {
      // A private session sees none of its regular Profile's handlers: ask that Profile. The
      // compose page then routes like any external link, never into the Incognito window.
      context = EngineWebContentHostFactory.createRegularContext(profileID: regular.id, directory: regular.dataDirectoryName, app: app)
    } else {
      context = factory?.focusedBrowser(create: true)?.context
    }
    guard let context else { finish(url, target: nil, source: source, profile: profile, factory: factory); return }
    // A Profile context made just now has no handlers until it is initialized: ask when it is ready.
    context.protocolHandlerURLWhenReady(for: url) { [weak self, weak factory] target in
      MainActor.assumeIsolated { self?.finish(url, target: target, source: source, profile: profile, factory: factory) }
    }
  }

  /// The Profile of the first saved standard window's Space. `model.windows` is not z-order (see
  /// AppLinkExecutor); with no window open it is the window that `makeWindow` would show again.
  private func noWindowProfile() -> Profile? {
    app.model.windows.first { $0.style == .standard }
      .flatMap { app.model.space(id: $0.focusedSpaceID) }.flatMap { app.model.profile(id: $0.profileID) }
      ?? app.model.defaultProfile
  }

  private func finish(_ url: URL, target: URL?, source: RoutingSource, profile: ProfileID?, factory: EngineWebContentHostFactory?) {
    // The lookup can finish while the App quits: open nothing then.
    guard !app.terminationRequested, !app.shutdownPrepared else { return }
    last = (url.scheme ?? "", target?.absoluteString)
    handledCount += 1
    if let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
      app.linkIntake.handle(urls: [target], source: source, profile: profile)
      return
    }
    AppDelegate.commandLog("A mailto link arrived with no mail site set up.")
    (factory ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] })?.controller?.toasts
      .show(ToastContent(title: "No email site is set up. Open your webmail and allow it as your mail app."))
  }
}
