import AppKit
import OpenFeatures
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
  static let introSeenKey = "open.liveFolders.introSeen"
  private unowned let app: AppDelegate
  /// github.com, or a fixture origin set by automation. Static so the per-navigation check in
  /// `EngineWebContentHost` never creates the service.
  static var origin: URL = {
    #if OPEN_AUTOMATION
    // A restored Live Folder can refresh before the socket accepts commands. Keep
    // that first real fetch on the same synthetic origin as the rest of the suite.
    if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_GITHUB_ORIGIN"], let url = URL(string: raw) { return url }
    #endif
    return GitHubQuery.defaultOrigin
  }()
  var origin: URL { get { Self.origin } set { Self.origin = newValue } }
  /// Last origin URL per tab, to see "compare page → new PR page" (PR created).
  private var lastOriginURL: [ItemID: URL] = [:]
  private(set) var autoCreated = 0
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
    UserDefaults.standard.set(true, forKey: BrowserWindowController.liveFolderAutoCreateKey)
    // The intro card shows on the first creation only (Arc `hasSeenGithubLiveFolderEducation`).
    if !UserDefaults.standard.bool(forKey: Self.introSeenKey), let controller = app.frontWindowController,
       controller.context.focusedSpace?.id == spaceID {
      UserDefaults.standard.set(true, forKey: Self.introSeenKey)
      DispatchQueue.main.async { controller.showLiveFolderIntro(folderID: folder.id) }
    }
    Task { await refresh(folderID: folder.id, manual: true) }
    return true
  }

  // MARK: Triggers (live-data §2.5): window foreground, Space focus, PR created / reviewed.

  /// Cheap static test used on every address change: only URLs on the GitHub origin go further.
  static func isOnOrigin(_ url: URL) -> Bool {
    url.host?.lowercased() == origin.host?.lowercased() && url.port == origin.port && url.scheme?.hasPrefix("http") == true
  }

  /// The app became active: refresh Live Folders of the visible Spaces (throttled, 10 s).
  func windowForegrounded() {
    for controller in app.windowControllers { if let space = controller.context.focusedSpace { spaceFocused(space.id) } }
  }

  func spaceFocused(_ spaceID: SpaceID) {
    guard let folder = app.model.liveFolder(in: spaceID) else { return }
    Task { await refresh(folderID: folder.id, manual: false) }
  }

  /// A tab's address changed on the GitHub origin. A compare page followed by a PR page means
  /// "PR created"; a `#pullrequestreview-` fragment means "review submitted" (`S:114542`).
  /// Either one moves the tab into the Space's Live Folder, creating the folder first when
  /// automatic creation is on (Arc: `reparentPullRequestToLiveFolder`).
  func addressChanged(tabID: ItemID, url: URL, space: Space?) {
    let previous = lastOriginURL[tabID]
    lastOriginURL[tabID] = url
    // Closed tabs never report again: drop their entries once the map grows.
    if lastOriginURL.count > 64, let model = app.model {
      lastOriginURL = lastOriginURL.filter { model.tab(id: $0.key) != nil || $0.key == tabID }
    }
    // Sign-in and sign-out on GitHub refetch the Space's Live Folder (live-data §2.4 item 4, Arc
    // refetch reasons `githubUserSignedIn` / `githubUserSignedOut`): leaving a sign-in page for
    // another GitHub page means signed in; reaching the sign-out page means signed out.
    let signedIn = previous.map { Self.isSignInPath($0.path) } == true && !Self.isSignInPath(url.path) && url.path != "/logout"
    let signedOut = url.path == "/logout" && previous?.path != "/logout"
    if signedIn || signedOut, let space, let folder = app.model.liveFolder(in: space.id) {
      signInRefreshes += 1
      Task { await refresh(folderID: folder.id, manual: true) }
    }
    guard let pr = Self.pullRequestURL(url) else { return }
    let created = previous.map { $0.path.contains("/compare/") || $0.path.hasSuffix("/compare") } ?? false
    let reviewed = url.fragment?.hasPrefix("pullrequestreview-") == true
    guard created || reviewed, let model = app.model, let tab = model.tab(id: tabID), let space else { return }
    var folder = model.liveFolder(in: space.id)
    if folder == nil {
      let on = UserDefaults.standard.object(forKey: BrowserWindowController.liveFolderAutoCreateKey) as? Bool ?? true
      guard on, toggle(spaceID: space.id) else { return }
      folder = model.liveFolder(in: space.id); autoCreated += 1
    }
    guard let folder, model.parent(of: tabID) != .folder(folder.id) else { return }
    if folder.children.contains(where: { node in if case .tab(let t) = node { return t.liveItemURL == pr }; return false }) { return }
    tab.liveItemURL = pr
    model.moveNode(id: tabID, to: .folder(folder.id), at: 0)
    Task { await refresh(folderID: folder.id, manual: true) }
  }

  /// GitHub's sign-in pages (live-data §2.4: `/login`, `/session`, the two-factor pages).
  static func isSignInPath(_ path: String) -> Bool {
    path == "/login" || path.hasPrefix("/login/") || path == "/session" || path.hasPrefix("/sessions/")
  }
  /// Refreshes started by a sign-in or sign-out (automation read-back).
  private(set) var signInRefreshes = 0

  /// `origin/owner/repo/pull/N` without query, fragment or sub-page; nil for other URLs.
  static func pullRequestURL(_ url: URL) -> URL? {
    guard isOnOrigin(url) else { return nil }
    let parts = url.path.split(separator: "/")
    guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
    return origin.appendingPathComponent(parts[0...3].joined(separator: "/"))
  }

  /// Folder header/menu action: sign in, the last banner's SSO URL, or the pulls page.
  func stateURL(folderID: ItemID) -> URL? {
    guard let folder = app.model.node(id: folderID)?.folder, let live = folder.live, live.stateMessage != nil else { return nil }
    if live.lastFetch?.outcome == .needsSSO, let url = folder.liveSSOURL { return url }
    return live.lastFetch?.outcome == .signedOut ? origin.appendingPathComponent("login") : origin.appendingPathComponent("pulls")
  }

  /// The Space that holds the folder, also when it was dragged into another folder or Today.
  private func space(of folderID: ItemID) -> Space? {
    var id = folderID
    for _ in 0..<64 {
      switch app.model.parent(of: id) {
      case .spacePinned(let spaceID)?, .spaceToday(let spaceID)?: return app.model.space(id: spaceID)
      case .folder(let parentID)?: id = parentID
      default: return nil
      }
    }
    return nil
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
    var ssoURL: URL?
    search: for kind in LiveFolderConfig.Kind.allCases where config.kinds.contains(kind) {
      do {
        let value = try await app.liveFetch.fetch(profileID: space.profileID,
          url: GitHubQuery.url(kind, teamReviews: config.teamReviews, origin: origin), script: GitHubQuery.extractionScript)
        let (state, items) = GitHubQuery.decode(value, kind: kind)
        switch state {
        case .ok: lists.append(items)
        case .signedOut: outcome = .signedOut; break search
        case .needsSSO:
          outcome = .needsSSO; lists.append(items)
          ssoURL = ssoURL ?? GitHubQuery.ssoURL(from: value, origin: origin)
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
                              retitle: diff.retitle, unread: unread,
                              info: Dictionary(fresh.map { ($0.url, $0.liveItemInfo) }, uniquingKeysWith: { first, _ in first }))
    }
    current.liveSSOURL = outcome == .needsSSO ? ssoURL : nil
    current.live?.lastFetch = .init(date: Date(), outcome: outcome)
    app.scheduleSave()
    return outcome
  }
}
