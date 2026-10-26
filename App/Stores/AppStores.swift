import Foundation
import OpenCommands
import OpenModel
import OpenStore
import OpenSuggest

/// Shared command-bar backend. Profile stores open on their own actor, on use.
@MainActor
final class AppStores {
  unowned let app: AppDelegate
  private var histories: [ProfileID: HistoryStore] = [:]
  private var currentProfile: ProfileID?
  private var currentSuggest: SuggestEngine?
  init(app: AppDelegate) { self.app = app }

  func history(for profileID: ProfileID?) -> HistoryStore? {
    let profile = profileID == nil ? app.model.defaultProfile : profileID.flatMap { app.model.profile(id: $0) }
    guard let profile else { return nil }
    if let store = histories[profile.id] { return store }
    let store = HistoryStore(fileURL: app.directories.historyFileURL(for: profile))
    histories[profile.id] = store
    return store
  }
  func suggest(for profileID: ProfileID) -> SuggestEngine {
    if currentProfile == profileID, let currentSuggest { return currentSuggest }
    currentSuggest?.cancel()
    let engine = SuggestEngine(model: app.model, historyStore: { [weak self] in self?.history(for: $0) },
      actions: CommandRegistry.makeSuggestRegistry())
    currentProfile = profileID; currentSuggest = engine
    return engine
  }
  func prewarm(profileID: ProfileID) { suggest(for: profileID).prewarm() }
  func recordTyped(url: URL, title: String, profileID: ProfileID) {
    guard let history = history(for: profileID) else { return }
    Task { await history.open(); await history.recordVisit(url: url, title: title, transition: "typed", typed: true) }
  }
}
