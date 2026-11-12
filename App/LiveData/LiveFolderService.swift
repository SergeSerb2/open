import AppKit
import OpenLiveData
import OpenModel

/// GitHub Live Folders (LF L2, live-data §2): the Space menu toggle creates "Pull Requests";
/// a refresh runs each search in the Space's Profile through `LiveFetchHost` and applies the
/// difference. No OAuth, no token, no server of Open's: the user's own github.com session.
/// Made on first use only; no timer.
@MainActor
final class LiveFolderService {
  /// Arc's built-in minimum between refreshes of one folder (live-data §2.5: 10 s).
  static let minimumInterval: TimeInterval = 10
  private unowned let app: AppDelegate
  /// github.com, or a fixture origin set by automation.
  var origin = GitHubQuery.defaultOrigin
  private var lastRefresh: [ItemID: Date] = [:]
  private var running: Set<ItemID> = []
  private(set) var refreshCount = 0
  private(set) var throttledCount = 0

  init(app: AppDelegate) { self.app = app }

  /// Space menu ▸ Live Folders ▸ GitHub.
  func toggle(spaceID: SpaceID) -> Bool {
    guard let model = app.model else { return false }
    if let folder = model.liveFolder(in: spaceID) {
      model.removeLiveFolder(id: folder.id); lastRefresh[folder.id] = nil
      return true
    }
    guard let folder = model.createLiveFolder(in: spaceID, config: LiveFolderConfig()) else { return false }
    Task { await refresh(folderID: folder.id, manual: true) }
    return true
  }

  private func space(of folderID: ItemID) -> Space? {
    app.model.spaces.first { $0.pinned.contains { $0.id == folderID } }
  }

  /// One refresh. `manual` (create, menu Refresh) skips the 10 s throttle.
  @discardableResult
  func refresh(folderID: ItemID, manual: Bool) async -> LiveFolderConfig.Outcome? {
    guard let folder = app.model.node(id: folderID)?.folder, let config = folder.live, let space = space(of: folderID),
          !running.contains(folderID) else { return nil }
    if !manual, let last = lastRefresh[folderID], Date().timeIntervalSince(last) < Self.minimumInterval { throttledCount += 1; return nil }
    running.insert(folderID); defer { running.remove(folderID) }
    lastRefresh[folderID] = Date(); refreshCount += 1
    var lists: [[PRSnapshot]] = []
    var outcome = LiveFolderConfig.Outcome.success
    search: for kind in LiveFolderConfig.Kind.allCases where config.kinds.contains(kind) {
      do {
        let value = try await app.liveFetch.fetch(profileID: space.profileID,
          url: GitHubQuery.url(kind, teamReviews: config.teamReviews, origin: origin), script: GitHubQuery.extractionScript)
        let (state, items) = GitHubQuery.decode(value, kind: kind)
        switch state {
        case .ok: lists.append(items)
        case .signedOut: outcome = .signedOut; break search
        case .needsSSO: outcome = .needsSSO; lists.append(items)
        case .unexpected: outcome = .failed; break search
        }
      } catch {
        outcome = .failed; break search
      }
    }
    // The folder may be gone (toggled off, undone) while the fetch ran.
    guard let current = app.model.node(id: folderID)?.folder, let live = current.live else { return nil }
    if outcome == .success || outcome == .needsSSO {
      let fresh = GitHubQuery.merge(lists, config: live)
      let diff = LiveFolderDiff.make(folder: current, fresh: fresh)
      // New rows after the first fill show the unread dot (Arc `showNewItemsAsUnread`).
      let unread = live.lastFetch?.outcome == .success
      app.model.applyLiveRows(folderID: folderID, add: diff.add.map { ($0.url, $0.title) }, remove: diff.remove,
                              retitle: diff.retitle, unread: unread)
    }
    current.live?.lastFetch = .init(date: Date(), outcome: outcome)
    app.scheduleSave()
    return outcome
  }
}
