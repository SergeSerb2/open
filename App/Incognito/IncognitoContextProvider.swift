import AppKit
import OpenEngine
import OpenModel

/// The single engine seam. After 0701 the lead replaces only context creation
/// with makeIncognitoContext(for:completion:); the requested parent is retained.
@MainActor
enum IncognitoContextProvider {
  static func makeContext(parent: Profile) -> OEBrowserContext {
    OEEngine.shared.makeEphemeralContext()
  }
}

@MainActor
final class IncognitoSession {
  let parent: Profile
  private(set) var context: OEBrowserContext?
  var windows = 0
  init(parent: Profile) {
    self.parent = parent
    context = IncognitoContextProvider.makeContext(parent: parent)
  }
  func end() { context?.delegate = nil; context = nil }
}

/// Sessions are shared by parent; models, undo, and all window state are local.
@MainActor
final class IncognitoSessions {
  private var sessions: [ProfileID: IncognitoSession] = [:]
  func acquire(parent: Profile) -> IncognitoSession {
    let session = sessions[parent.id] ?? IncognitoSession(parent: parent)
    sessions[parent.id] = session; session.windows += 1
    return session
  }
  func release(_ session: IncognitoSession) {
    session.windows -= 1
    if session.windows == 0 { sessions[session.parent.id] = nil; session.end() }
  }
  func closeAll() { for session in sessions.values { session.end() }; sessions.removeAll() }
}
