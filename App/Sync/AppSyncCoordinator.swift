import AppKit
import Foundation
import Observation
import OpenAdBlock
import OpenCommands
import OpenFeatures
import OpenModel
import OpenSettings
import OpenSidebar
import OpenStore
import OpenSync

/// Owns the App's one `SyncEngine` and connects it to live state: local change signals schedule
/// pushes, the engine's status drives the sidebar banner, and quit flushes a pending push.
///
/// Cold launch never makes this object unless `State/sync-state.json` exists (one `stat` in the
/// post-paint `afterPaint.sync` slice). Settings ▸ Account & Sync, onboarding, the `account-sync`
/// and `sync-now` commands and automation make it on demand (`AppDelegate.ensureSyncCoordinator`).
@MainActor
final class AppSyncCoordinator {
  unowned let app: AppDelegate
  let engine: SyncEngine
  /// The engine holds its adapter weakly: this coordinator keeps it alive.
  let adapter: AppSyncDataAdapter

  private var modelObserver: UUID?
  private weak var observedModel: BrowserModel?
  private var notificationTokens: [any NSObjectProtocol] = []
  private var workspaceGeneration = 0
  private var statusGeneration = 0
  private var boostsGeneration = 0
  private var stopped = false
  private var preferenceCheckPending = false
  /// Uptime of the last quit flush. A quit cancelled later (downloads alert, a page's "Stay")
  /// may flush again on the next attempt, as the history flush does.
  private var quitFlushedAt: TimeInterval?

  /// The banner the engine status asks for, before dismissal.
  private(set) var requestedBanner: SyncBannerState?
  /// The banner the user dismissed. It stays hidden until the status text or kind changes.
  private var dismissedBanner: SyncBannerState?
  /// What the sidebar shows now.
  var bannerState: SyncBannerState? { requestedBanner == dismissedBanner ? nil : requestedBanner }

  /// Last portable preference values seen locally (or written by a remote apply). Only a real
  /// difference schedules a push, so window frames and other device-local keys never do.
  var lastPortablePreferences: [String: SyncPreferenceValue]?
  /// Last key bindings seen by `keyBindingsDidReload` (nil until the first load).
  var lastKeyBindings: KeyBindingStore?

  init(app: AppDelegate) {
    self.app = app
    // Ad-hoc, Debug and isolated end-to-end builds never touch the macOS Keychain: no prompt,
    // and no collision between parallel runs that share one login Keychain.
    let fileCredentials = !CodeSignature.hasTeamIdentifier
      || ProcessInfo.processInfo.environment["OPEN_SYNC_FILE_CREDENTIALS"] == "1"
    engine = SyncEngine(dataRoot: app.directories.root, useFileCredentialStore: fileCredentials)
    adapter = AppSyncDataAdapter(app: app)
    adapter.coordinator = self
    engine.dataAdapter = adapter
    lastPortablePreferences = AppSyncDataAdapter.portablePreferences()
    lastKeyBindings = app.commandServicesPrepared ? app.keyBindings : nil
    installObservers()
    modelDidInstall()
    observeStatus()
  }

  /// One `stat` when no account is saved; otherwise loads state off the main thread and syncs.
  func startIfSignedIn() {
    guard !stopped else { return }
    engine.startIfSignedIn()
  }

  // MARK: Local change signals

  /// A local change that sync should push. Ignored while the engine installs remote data
  /// (its own writes are not local edits) and while signed out.
  func noteLocalChange(_ reason: String) {
    guard !stopped, engine.isSignedIn, !engine.isApplyingRemote else { return }
    engine.schedulePush(reason: reason)
  }

  /// `AppDelegate.installModel` ran (launch, or the first-run import swap): observe the new model.
  func modelDidInstall() {
    if let modelObserver, let observedModel { observedModel.removeObserver(modelObserver) }
    modelObserver = nil
    guard !stopped, let model = app.model else { return }
    observedModel = model
    modelObserver = model.addObserver { [weak self] _ in self?.noteLocalChange("workspace") }
    observeWorkspaceMetadata()
  }

  /// `AppDelegate.reloadKeyBindings` finished. The first call records the baseline only.
  func keyBindingsDidReload(_ store: KeyBindingStore) {
    defer { lastKeyBindings = store }
    guard let previous = lastKeyBindings, previous != store else { return }
    noteLocalChange("keybindings")
  }

  private func installObservers() {
    let center = NotificationCenter.default
    // `queue: nil`: delivered on the posting thread, so a change made while a remote apply runs
    // still sees `isApplyingRemote == true`.
    notificationTokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
      if Thread.isMainThread { MainActor.assumeIsolated { self?.preferencesMaybeChanged() } }
      else { Task { @MainActor [weak self] in self?.preferencesMaybeChanged() } }
    })
    notificationTokens.append(center.addObserver(forName: AdBlockStore.didChange, object: nil, queue: nil) { [weak self] _ in
      if Thread.isMainThread { MainActor.assumeIsolated { self?.noteLocalChange("adblock") } }
      else { Task { @MainActor [weak self] in self?.noteLocalChange("adblock") } }
    })
    notificationTokens.append(center.addObserver(forName: SitePermissionStore.didChange, object: nil, queue: nil) { [weak self] _ in
      if Thread.isMainThread { MainActor.assumeIsolated { self?.noteLocalChange("sitePermissions") } }
      else { Task { @MainActor [weak self] in self?.noteLocalChange("sitePermissions") } }
    })
    observeBoosts()
  }

  /// Defaults change often (window frames, Library state): one coalesced comparison per 250 ms.
  /// A remote apply records the values it wrote in `lastPortablePreferences`, so it never echoes.
  private func preferencesMaybeChanged() {
    guard !stopped, engine.isSignedIn, !preferenceCheckPending else { return }
    preferenceCheckPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.preferenceCheckPending = false
        self.comparePreferences()
      }
    }
  }

  private func comparePreferences() {
    guard !stopped, engine.isSignedIn else { return }
    let current = AppSyncDataAdapter.portablePreferences()
    let previous = lastPortablePreferences
    lastPortablePreferences = current
    guard previous != current, !engine.isApplyingRemote else { return }
    engine.schedulePush(reason: "preferences")
  }

  /// Profile, Space, rule and window-layout fields that change without a tree event
  /// (renames, themes, icons, Profile settings, sidebar width). Tree edits use `addObserver`.
  private func observeWorkspaceMetadata() {
    workspaceGeneration &+= 1
    let generation = workspaceGeneration
    guard !stopped, let model = observedModel else { return }
    withObservationTracking {
      _ = model.profiles; _ = model.spaces; _ = model.routingRules; _ = model.defaultDestination
      for profile in model.profiles {
        _ = profile.name; _ = profile.icon; _ = profile.settings; _ = profile.dataDirectoryName; _ = profile.favorites
      }
      for space in model.spaces {
        _ = space.title; _ = space.icon; _ = space.theme; _ = space.profileID; _ = space.isPinnedCollapsed
      }
      for window in model.windows where window.style == .standard {
        _ = window.sidebarWidth; _ = window.sidebarMode; _ = window.showsToolbar
      }
    } onChange: { [weak self] in
      // Mutations of the main-actor model run on the main thread, before the new value is set.
      MainActor.assumeIsolated {
        guard let self, self.workspaceGeneration == generation else { return }
        self.noteLocalChange("workspace")
        Task { @MainActor [weak self] in
          guard let self, self.workspaceGeneration == generation else { return }
          self.observeWorkspaceMetadata()
        }
      }
    }
  }

  /// Boost saves from the editor, Library and Site Control all end in `AppBoosts.refresh`.
  private func observeBoosts() {
    boostsGeneration &+= 1
    let generation = boostsGeneration
    guard !stopped else { return }
    let boosts = app.stores.boosts
    withObservationTracking { _ = boosts.revision } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.boostsGeneration == generation else { return }
        self.noteLocalChange("boosts")
        Task { @MainActor [weak self] in
          guard let self, self.boostsGeneration == generation else { return }
          self.observeBoosts()
        }
      }
    }
  }

  // MARK: Sidebar banner

  private func observeStatus() {
    statusGeneration &+= 1
    let generation = statusGeneration
    guard !stopped else { return }
    updateBanner()
    withObservationTracking { _ = engine.snapshot } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.statusGeneration == generation else { return }
        self.observeStatus()
      }
    }
  }

  private static func banner(for snapshot: SyncAccountSnapshot) -> SyncBannerState? {
    switch snapshot.status {
    case .error(let message): return .error(message)
    case .needsReauth(let message): return .needsReauth(message)
    case .awaitingInitialChoice: return .awaitingInitialChoice
    case .signedOut: return nil
    case .idle, .syncing: return snapshot.pendingInitialChoice != nil ? .awaitingInitialChoice : nil
    }
  }

  private func updateBanner() {
    let next = stopped ? nil : Self.banner(for: engine.snapshot)
    if next != requestedBanner {
      requestedBanner = next
      // A new problem (other text or kind) shows again after an earlier dismissal.
      if next != dismissedBanner { dismissedBanner = nil }
    }
    let shown = bannerState
    for controller in standardWindowControllers where controller.sidebar.syncBannerState != shown {
      controller.sidebar.syncBannerState = shown
    }
  }

  private var standardWindowControllers: [BrowserWindowController] {
    app.windowControllers.filter { app.hostFactories[$0.windowID]?.isIncognito == false }
  }

  /// Wires the banner of a new (non-Incognito) browser window.
  func attach(_ controller: BrowserWindowController) {
    controller.sidebar.onSyncBannerAction = { [weak self] in self?.openAccountSettings() }
    controller.sidebar.onSyncBannerDismiss = { [weak self] in self?.dismissBanner() }
    controller.sidebar.syncBannerState = bannerState
  }

  func openAccountSettings() {
    app.settingsPresenter.show(section: .accountSync, row: "account")
  }

  func dismissBanner() {
    dismissedBanner = requestedBanner
    updateBanner()
  }

  // MARK: Shutdown

  /// The quit's history step should also flush sync (signed in, not flushed in the last 5 s).
  var needsQuitFlush: Bool {
    guard !stopped, engine.isSignedIn else { return false }
    return quitFlushedAt.map { ProcessInfo.processInfo.systemUptime - $0 > 5 } ?? true
  }

  /// Runs a pending debounced push (bounded) and writes the sync state. Quit never waits longer
  /// than `timeoutSeconds` for the network.
  func stopAndFlush(timeoutSeconds: Double = 3.0) async {
    quitFlushedAt = ProcessInfo.processInfo.systemUptime
    await engine.stopAndFlush(timeoutSeconds: timeoutSeconds)
  }

  /// `prepareForEngineShutdown`: no more pushes from local signals. A quit through
  /// `applicationShouldTerminate` already flushed; other paths get a best-effort flush.
  func stopForShutdown() {
    guard !stopped else { return }
    let flushed = quitFlushedAt != nil
    stop()
    if !flushed { Task { @MainActor [engine] in await engine.stopAndFlush(timeoutSeconds: 1.0) } }
  }

  /// Removes every observer and the banner. The engine keeps its account.
  func stop() {
    guard !stopped else { return }
    stopped = true
    workspaceGeneration &+= 1; statusGeneration &+= 1; boostsGeneration &+= 1
    if let modelObserver, let observedModel { observedModel.removeObserver(modelObserver) }
    modelObserver = nil; observedModel = nil
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    notificationTokens.removeAll()
    requestedBanner = nil
    for controller in app.windowControllers where controller.sidebar.syncBannerState != nil {
      controller.sidebar.syncBannerState = nil
    }
  }
}
