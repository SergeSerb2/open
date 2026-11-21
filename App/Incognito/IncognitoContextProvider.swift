import AppKit
import OpenEngine
import OpenMedia
import OpenModel
import OpenTranslate

/// Creates the chosen regular Profile's primary OTR without copying its data.
@MainActor
enum IncognitoContextProvider {
  static func makeContext(parent: Profile, app: AppDelegate,
                          completion: @escaping @MainActor (OEBrowserContext?, (any Error)?) -> Void) {
    guard app.engineReady, app.model.profile(id: parent.id) != nil,
      app.engine.result.layout == .engine else {
      completion(nil, NSError(domain: "Open.Incognito", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The parent Profile is unavailable."]))
      return
    }
    let original = EngineWebContentHostFactory.createRegularContext(
      profileID: parent.id, directory: parent.dataDirectoryName, app: app)
    guard let original else {
      completion(nil, NSError(domain: "Open.Incognito", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The parent Profile is unavailable."]))
      return
    }
    OEEngine.shared.makeIncognitoContext(for: original, completion: completion)
  }
}

@MainActor
final class IncognitoSession {
  let parent: Profile
  private weak var app: AppDelegate?
  private(set) var context: OEBrowserContext?
  private var ended = false
  var windows = 0
  /// Site choices made in this session's windows. Memory only: they end with the session and never
  /// reach the regular preferences (PiP "Turn off", "Never Translate This Site", Developer Mode).
  let pipHosts = MediaSettings.PrivateHosts()
  let translateHosts = TranslatePreferences.SessionHosts()
  let developerModeHosts = DeveloperMode.SessionHosts()
  /// Destinations of this session's downloads: shared by its windows, so the window that asked
  /// may close first. Released when the session ends.
  let downloads = IncognitoDownloads()
  init(parent: Profile, app: AppDelegate) {
    self.parent = parent
    self.app = app
    start()
  }
  private var starting = false
  private func start() {
    guard let app else { return }
    starting = true
    let parentID = parent.id
    IncognitoContextProvider.makeContext(parent: parent, app: app) { [weak self, weak app] context, error in
      guard let self, !self.ended else {
        // A late answer for an ended session. The engine shares one private session per parent: when a
        // live session of the same parent exists, it owns (or will receive) this context. Keep it.
        if let context, app?.incognitoSessions.hasSession(parent: parentID) != true {
          OEEngine.shared.releaseContext(context, completion: nil)
        }
        return
      }
      self.starting = false
      guard let context, error == nil else {
        // Fail closed. Never create a page on a different Profile. The engine can answer at once, inside
        // a page request (`liveContext`), so close the windows on the next turn.
        DispatchQueue.main.async { [weak self, weak app] in
          guard let self, let app else { return }
          for controller in app.windowControllers where app.hostFactories[controller.windowID]?.incognitoSession === self {
            controller.window?.close()
          }
        }
        return
      }
      self.context = context
      if let app {
        app.adBlockEngineAdapter.contextCreated(context, profileID: self.parent.id)
        for factory in app.hostFactories.values where factory.incognitoSession === self {
          factory.engineDidBecomeReady()
        }
      }
    }
  }
  /// The session's context for a new page. The engine closes a private session when its last
  /// private Browser closes, that is when every tab of the session is gone (OEEngine.h), while
  /// Open's Incognito windows stay open. With `create`, a new page then starts a fresh session (no
  /// cookies, storage or site choices carry over): nil now, and the windows' pages are made when it
  /// is ready. Without `create` (a lookup), a closed session stays closed.
  func liveContext(create: Bool = true) -> OEBrowserContext? {
    guard let context, context.state == .closed else { return context }
    guard create, !ended, !starting else { return nil }
    context.delegate = nil
    if let app {
      app.adBlockEngineAdapter.contextClosed(context)
      app.extensionPrompts.unregister(context.extensions)
    }
    self.context = nil
    pipHosts.disabled = []; translateHosts.reset(); developerModeHosts.reset()
    start()
    return nil
  }
  func end() {
    guard !ended else { return }
    ended = true
    downloads.close()
    context?.delegate = nil
    if let context {
      app?.adBlockEngineAdapter.contextClosed(context)
      OEEngine.shared.releaseContext(context, completion: nil)
    }
    context = nil
  }
}

/// Sessions are shared by parent; models, undo, and all window state are local.
@MainActor
final class IncognitoSessions {
  private var sessions: [ProfileID: IncognitoSession] = [:]
  func acquire(parent: Profile, app: AppDelegate) -> IncognitoSession {
    let session = sessions[parent.id] ?? IncognitoSession(parent: parent, app: app)
    sessions[parent.id] = session; session.windows += 1
    return session
  }
  func release(_ session: IncognitoSession) {
    session.windows -= 1
    if session.windows == 0 { sessions[session.parent.id] = nil; session.end() }
  }
  func closeAll() { for session in sessions.values { session.end() }; sessions.removeAll() }
  func hasSession(parent: ProfileID) -> Bool { sessions[parent] != nil }
}
