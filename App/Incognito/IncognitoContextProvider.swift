import AppKit
import OpenEngine
import OpenModel

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
    OEEngine.shared.makeIncognitoContext(for: original) { [weak app] context, error in
      if let context, let app { app.adBlockEngineAdapter.contextCreated(context, profileID: parent.id) }
      completion(context, error)
    }
  }
}

@MainActor
final class IncognitoSession {
  let parent: Profile
  private(set) var context: OEBrowserContext?
  private var ended = false
  var windows = 0
  init(parent: Profile, app: AppDelegate) {
    self.parent = parent
    IncognitoContextProvider.makeContext(parent: parent, app: app) { [weak self, weak app] context, error in
      guard let self, !self.ended else {
        if let context { OEEngine.shared.releaseContext(context, completion: nil) }
        return
      }
      guard let context, error == nil else {
        // Fail closed. Never create a page on a different Profile.
        for controller in app?.windowControllers ?? [] where
          app?.hostFactories[controller.windowID]?.incognitoSession === self {
          controller.window?.close()
        }
        return
      }
      self.context = context
      if let app {
        for factory in app.hostFactories.values where factory.incognitoSession === self {
          factory.engineDidBecomeReady()
        }
      }
    }
  }
  func end() {
    guard !ended else { return }
    ended = true
    context?.delegate = nil
    if let context { OEEngine.shared.releaseContext(context, completion: nil) }
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
}
