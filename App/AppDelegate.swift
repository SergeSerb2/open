import OpenOnboarding
import AppKit
import OpenEasel
import OpenEngine
import OpenDocuments
import OpenLiveData
import OpenModel
import OpenStore
import OpenFeatures
import QuartzCore
import OpenCommands
import OpenSettings
import OpenLibrary
import OpenSidebar

/// Owns the model, its stores, and the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, OEEngineDelegate, OEBrowserContextDelegate {
  let archiveClock = AppArchiveClock()
  var todayAutoArchive: TodayAutoArchiveController?
  var expirySweeper: ExpirySweeper?
  var options = LaunchOptions(arguments: [])
  private(set) var model: BrowserModel!
  private(set) var isFirstRun = false
  var firstRunSaved = false
  private var firstRunWelcomeID: ItemID?
  var firstRunWindowController: FirstRunWindowController?
  var onboardingWindowController: OnboardingWindowController?
  var preparedOnboardingSound: IntroSound?
  var onboardingStartObserver: CFRunLoopObserver?
  var onboardingEngineSettled = false
  #if OPEN_AUTOMATION
  var onboardingStartup: [String: Any] = [:]
  var onboardingLifetimeState: (() -> [String: Bool])?
  #endif
  var onboardingActivated = false
  var onboardingHandedOff = false
  var onboardingReceipt: [String: Any]?
  var lastFirstRunStep = "none"
  var importInProgress = false
  private var modelSaveObserver: UUID?
  private weak var firstRunDefaultModel: BrowserModel?
  lazy var importRunner = AppImportRunner(app: self)
  var firstContentView: NSView? { onboardingWindowController?.window?.contentView ?? firstRunWindowController?.window?.contentView ?? windowControllers.first?.window?.contentView }
  private(set) var snapshotStore: SnapshotStore!
  private(set) var archiveSink: ProfileArchiveSink!
  private(set) var directories: ProfileDirectories!
  /// Easel documents (`<data root>/Easels`); made on the first Easel open, never at launch.
  private var easelStore: EaselStore?
  var hasEaselStore: Bool { easelStore != nil }
  /// Command bar search over every Easel (made on the first command bar open).
  private(set) lazy var easelSearch = EaselSearch(app: self)
  var easels: EaselStore {
    if let easelStore { return easelStore }
    let store = EaselStore(root: directories.root); easelStore = store; return store
  }
  /// Notes (`<data root>/Notes`). Nothing is read until a Note shows.
  private(set) lazy var notes = NoteStore(root: directories.root)
  /// The engine layout step's outcome (and the data root lock).
  private(set) var engine: OpenDataRoot.EnginePreparation!
  private(set) var hostFactories: [WindowID: EngineWebContentHostFactory] = [:]
  var sidebarDropRails: [SidebarDropRails] = []
  private(set) var windowControllers: [BrowserWindowController] = []
  let incognitoSessions = IncognitoSessions()
  // CEF pumps AppKit without a normal per-event undo group boundary. The
  // model opens one group per command; multi-operation UI actions may nest.
  let undoManager: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
  private(set) var engineReady = false
  private(set) var terminationRequested = false
  /// The Blank Windows open when quit started (C-report-s11 1(c)); written by saveState.
  var blankWindowsAtQuit: [SavedBlankWindow]?
  private var faviconShutdownTask: Task<Void, Never>?
  private var historyQuitTask: Task<Void, Never>?
  /// Uptime of the last quit-time history flush. A quit cancelled later (downloads alert,
  /// beforeunload) must flush again on the next attempt, so the flush is valid only briefly.
  private var historyQuitFlushedAt: TimeInterval?
  private(set) var shutdownPrepared = false
  private var lateAsyncEngineCalls = 0
  private var asyncEngineCalls: [String: Int] = [:]
  private var shutdownTrace: [[String: Any]] = []
  lazy var stores = AppStores(app: self)
  lazy var adBlockEngineAdapter = AdBlockEngineAdapter(app: self)
  lazy var profileTeardown = ProfileTeardown(app: self)
  var pendingMissingProfileTitles: [String] = []
  var missingProfileNotice: NSAlert?
  var missingProfileNoticeTitles: [String] = []
  var missingProfileNoticeCount = 0
  lazy var extensionPrompts = ExtensionPromptPresenter(app: self)
  lazy var extensionsMainMenu = ExtensionsMainMenuProvider(app: self)
  /// Mini players, auto-PiP and the media sleep feed (media-pip §7.2).
  lazy var media = MediaCoordinator(app: self, rulesURL: options.pipSiteRules)
  /// Tab sleep (app-shell §4.7, Step G): one SleepController, started after first paint.
  lazy var tabSleep = AppSleepCoordinator(app: self)
  lazy var handoff = HandoffPublisher(app: self)
  /// Quit order step 1 (app-shell §5.3) runs once, before the snapshot save.
  private var sleepQuitTask: Task<Void, Never>?
  private var sleepQuitCaptured = false
  lazy var settingsPresenter = AppSettingsActions(app: self)
  private(set) var updater: UpdaterController?
  var checkForUpdatesAfterPaint = false
  lazy var applicationIcon = ApplicationIconController(app: self)
  lazy var downloadsCenter = DownloadsCenter(app: self)
  let defaultBrowserService = DefaultBrowserService()
  lazy var linkExecutor = AppLinkExecutor(app: self)
  lazy var deepLinks = DeepLinkRouter(app: self)
  lazy var mailto = MailtoRouter(app: self)
  lazy var linkIntake: ExternalLinkIntake = {
    let intake = ExternalLinkIntake(executor: linkExecutor, snapshot: { [unowned self] in self.linkExecutor.snapshot() })
    let meet = MeetRoute(app: self)
    intake.willRoute = { meet.prepare($0) }
    intake.didRoute = { meet.announce($0) }
    return intake
  }()
  var lastLittleOpenRequest: LittleOpenRequest?
  var executedExternalLink = false
  /// Only a fresh launch fallback is eligible for removal by its first Little Open link.
  /// Saved standard windows are never tagged. Input or navigation clears this tag.
  var autoCreatedLaunchWindowID: WindowID?
  var initialWindowInputMonitor: Any?
  /// Library ▸ Captures writer (page-platform §4.6.6); one per app, shared by every window.
  lazy var captureLibrary = CaptureLibraryWriter(app: self, root: directories.root)
  /// Live Folder / glance fetches (LF L2): made on first use only.
  lazy var liveFetch = LiveFetchHost(app: self)
  lazy var liveFolders = LiveFolderService(app: self)
  /// Calendar data for Join Meeting, the calendar card and Live Calendar; first use only (plan NS §2 CAL).
  var calendar: CalendarService {
    if let loadedCalendar { return loadedCalendar }
    let made = CalendarService(); loadedCalendar = made; return made
  }
  /// The calendar service if a calendar feature already created it. Menu validation reads only this.
  private(set) var loadedCalendar: CalendarService?
  /// Live Calendar Favorite tiles (LD §4); idle until a calendar Favorite tile appears.
  lazy var liveCalendar = LiveCalendarCoordinator(app: self)
  var keyBindings = KeyBindingStore.empty
  let fallbackKeyboard = KeyboardRouter()
  var commandServicesPrepared = false
  var hotkeyService: GlobalHotkeyService?
  var hotkeyError: String?
  var hotkeyAttempts = 0
  var menuRebuildTask: Task<Void, Never>?
  var afterPaintTask: Task<Void, Never>?
  private var cloneCleanupScheduled = false
  #if OPEN_AUTOMATION
  var cloneCleanupCounts: [String: NSNumber]?
  #endif
  var littleOpenCoordinator: LittleOpenCoordinator!
  var pendingLittleOpenBlankStamps: [TimeInterval?] = []
  var littleOpenProfileAlert: NSAlert?
  var littleOpenHosts: [ItemID: EngineWebContentHost] = [:]
  var commandWindowObserver: (any NSObjectProtocol)?
  var commandDefaultsObserver: (any NSObjectProtocol)?
  private var numberedShortcutOptions = ""
  private var currentNumberedShortcutOptions: String {
    "\(UserDefaults.standard.bool(forKey: "open.shortcuts.includeFavoritesInTabNumbering")):\(UserDefaults.standard.bool(forKey: "open.shortcuts.switchToNinthEnabled"))"
  }
  private var activeWindowID: WindowID?
  private(set) var startupEvidence: [String: Any] = [:]
  #if OPEN_AUTOMATION
    let activationTrace = ActivationTrace()
    private var automation: AutomationServer?
  #endif

  var frontWindowController: BrowserWindowController? {
    windowControllers.first { $0.windowID == activeWindowID }
      ?? windowControllers.first { $0.window?.isKeyWindow == true } ?? windowControllers.first
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("app.didFinishLaunching")
    defer { pacingRegion?.end() }
    #endif
    LaunchTiming.shared.mark("didFinishLaunching")
    SettingsDefaults.register(in: .standard)
    LaunchTiming.shared.phase("settingsRegistered")
    _ = importRunner.unfinishedSecretsImportAtLaunch
    NSApp.mainMenu = MainMenu.build()
    LaunchTiming.shared.phase("mainMenuBuilt")
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    LaunchTiming.shared.phase("initialMenuRetargeted")
    NSApp.setActivationPolicy(.regular)
    // The window and sidebar come from the snapshot and do not wait for the
    // engine (docs/architecture.md, launch tactics). Pages created before
    // the engine is ready wait inside OpenEngine.
    showWindowsIfNeeded()
    tabSleep.installSettingsPolicy()
    adBlockEngineAdapter.installProfilePolicy()
    installScripting()
    LaunchTiming.shared.phase("didFinishLaunchingEnd")
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if isFirstRun && !firstRunSaved, let onboarding = onboardingWindowController {
      onboarding.window?.makeKeyAndOrderFront(nil)
      return false
    }
    if let frontWindowController { frontWindowController.showWindow(nil) }
    else { showWindowsIfNeeded(ignoringLittleOpen: true) }
    return false
  }

  private lazy var pageQuit = PageQuitCoordinator(app: self)
  lazy var quitWarning = QuitWarningCoordinator()

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // A Dock or AppleScript quit can re-enter from inside a quit alert's modal loop. One
    // alert at a time; the open alert decides this attempt.
    if quitWarning.presenting || downloadsCenter.presentingQuitAlert { return .terminateCancel }
    // Sparkle may retry after a user cancels or the quit preflight defers.
    defer {
      if !terminationRequested {
        updater?.userDriver.applicationTerminationCancelled()
        // An install quit that ended without a self-retry must not make a later normal quit
        // prompt-free. Sparkle's retry button requests the relaunch again.
        if !quitWarning.retryPending { updater?.userDriver.clearInstallationRelaunchRequest() }
      }
    }
    if historyQuitTask != nil || faviconShutdownTask != nil || sleepQuitTask != nil { return .terminateCancel }
    if quitWarning.beginAttempt(relaunch: updater?.userDriver.installationRelaunchRequested == true) {
      // The downloads approval belongs to one attempt, like the generic one.
      downloadsCenter.resetQuitApproval()
      deepLinks.beginQuitAttempt()
    }
    let downloadsWarned = downloadsCenter.hasRunning
    if downloadsCenter.shouldKeepBrowsing(withoutPrompts: quitWarning.withoutPrompts) {
      quitWarning.resetApproval(); return .terminateCancel
    }
    if quitWarning.shouldKeepBrowsing(app: self, downloadsWarned: downloadsWarned) { return .terminateCancel }
    let now = ProcessInfo.processInfo.systemUptime
    if !shutdownPrepared, downloadsCenter.needsHistoryFlush || importRunner.hasPendingUndo || (historyQuitFlushedAt.map({ now - $0 > 5 }) ?? true) {
      historyQuitTask = Task { @MainActor in
        await self.stores.flushHistory()
        await self.downloadsCenter.flushHistory()
        await self.importRunner.flushUndoForQuit()
        self.historyQuitFlushedAt = ProcessInfo.processInfo.systemUptime; self.historyQuitTask = nil
        NSApp.terminate(nil)
      }
      quitWarning.markRetryPending()
      return .terminateCancel
    }
    if engineReady, !shutdownPrepared, !pageQuit.shouldTerminate() {
      // Page replies retry the quit when every page allows it; a "Stay" resets the attempt.
      quitWarning.markRetryPending()
      return .terminateCancel
    }
    if !sleepQuitCaptured, engineReady, !shutdownPrepared, tabSleep.controller != nil {
      // OEApplication has no terminateLater: capture sleep history first (bounded at 3 s),
      // then ask again. The snapshot save and engine shutdown follow below.
      sleepQuitTask = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.tabSleep.captureForQuit()
        self.sleepQuitCaptured = true; self.sleepQuitTask = nil
        NSApp.terminate(nil)
      }
      quitWarning.markRetryPending()
      return .terminateCancel
    }
    let wasEngineReady = engineReady
    let icons = wasEngineReady && !windowControllers.isEmpty ? stores.sidebarFavicons : nil
    terminationRequested = true
    blankWindowsAtQuit = currentBlankWindows()
    deepLinks.relaunchIfRequested()
    preparedOnboardingSound?.stop(); preparedOnboardingSound = nil
    if let onboardingStartObserver { CFRunLoopObserverInvalidate(onboardingStartObserver); self.onboardingStartObserver = nil }
    onboardingWindowController?.stop()
    for controller in windowControllers { controller.closeThemeEditor() }
    extensionPrompts.cancelAll()
    if let commandWindowObserver { NotificationCenter.default.removeObserver(commandWindowObserver) }; commandWindowObserver = nil
    if let commandDefaultsObserver { NotificationCenter.default.removeObserver(commandDefaultsObserver) }; commandDefaultsObserver = nil
    if let initialWindowInputMonitor { NSEvent.removeMonitor(initialWindowInputMonitor) }; initialWindowInputMonitor = nil
    hotkeyService?.unregister(); afterPaintTask?.cancel(); menuRebuildTask?.cancel()
    stopAutoArchive()
    saveState()
    prepareForEngineShutdown()
    if let icons, !icons.isIdle {
      // OEApplication supports terminateCancel, not terminateLater. Close hosts
      // above, drain accepted cache work, then request shutdown via OpenEngine.
      faviconShutdownTask = Task { @MainActor in
        await icons.flush()
        OEEngine.shared.terminate()
      }
      return .terminateCancel
    }
    if !wasEngineReady { CFRunLoopStop(CFRunLoopGetMain()) }
    return .terminateNow
  }

  // MARK: Model

  /// Prepares the data root (lock, Chromium's layout, Open's stores, profile
  /// folders) and loads the model. Runs before the engine starts.
  @discardableResult
  func prepareData() -> ProfileDirectories {
    if let directories { return directories }
    LaunchTiming.shared.phase("prepareDataBegin")
    let root = options.userDataDirectory
    if options.replayRefused {
      FileHandle.standardError.write(Data("Open: --replay-onboarding requires --user-data-dir in a temporary directory\n".utf8)); exit(64)
    }
    isFirstRun = !options.skipFirstRun && (options.replayOnboarding || !FileManager.default.fileExists(atPath: root.appendingPathComponent("State/browser.json").path))
    // Chromium's data layout is its own step, before the snapshot loads. A
    // migration problem selects the old layout for this launch (retried on
    // the next one); it never touches the model.
    do {
      engine = try OpenDataRoot.prepareEngineLayout(root: root)
      try ProfileTeardown.finishPendingWipes(directories: ProfileDirectories(root: engine.root))
      LaunchTiming.shared.phase("engineLayoutPrepared")
    } catch {
      FileHandle.standardError.write(Data("Open: data root \(root.path) unavailable: \(error)\n".utf8))
      exit(1)
    }
    let layout = engine.result
    if !layout.report.moved.isEmpty || !layout.report.skipped.isEmpty || layout.problem != nil {
      FileHandle.standardError.write(Data(
        "Open: engine layout \(layout.layout) in \(String(format: "%.1f", layout.milliseconds)) ms\n".utf8))
    }
    snapshotStore = SnapshotStore(root: root)
    // Only an unreadable snapshot starts a fresh model, and the unreadable
    // file is kept beside the new one, never overwritten.
    var loaded: BrowserModel?
    do {
      loaded = try snapshotStore.loadData().map(SnapshotMapper.model(from:))
      LaunchTiming.shared.phase("snapshotLoaded")
    } catch {
      let kept = snapshotStore.fileURL.deletingLastPathComponent()
        .appendingPathComponent("browser.unreadable-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: snapshotStore.fileURL, to: kept)
      FileHandle.standardError.write(Data(
        "Open: snapshot unreadable (kept as \(kept.lastPathComponent)), starting fresh: \(error)\n".utf8))
    }
    let model: BrowserModel
    if let loaded { model = loaded }
    else {
      model = Self.makeDefaultModel()
      autoCreatedLaunchWindowID = model.windows.first?.id
    }
    // Audit A7: folders of Profiles that an undone import created go now, if the loaded snapshot does not use
    // them. Never from a fresh fallback model (an unreadable snapshot keeps every folder).
    if loaded != nil {
      do {
        try ProfileTeardown.finishOrphanWipes(directories: ProfileDirectories(root: engine.root),
                                              inUse: Set(model.profiles.map { $0.dataDirectoryName.lowercased() }))
      } catch {
        FileHandle.standardError.write(Data("Open: undone-import Profile cleanup postponed: \(error)\n".utf8))
      }
    }
    applyLaunchWindowPreference(to: model)
    // Repeated IDs in the snapshot were repaired while loading: save the repaired copy.
    let repaired = repairMissingProfiles(in: model) || !model.loadRepairs.isEmpty
    if model.windows.isEmpty, let space = model.spaces.first {
      let state = BrowserWindowState(focusedSpaceID: space.id)
      model.windows.append(state)
      autoCreatedLaunchWindowID = state.id
    }
    do {
      try OpenDataRoot.prepare(root: root, model: model)
      if repaired { try snapshotStore.saveNow(model: model) }
    } catch {
      FileHandle.standardError.write(Data("Open: data root \(root.path) unavailable: \(error)\n".utf8))
      exit(1)
    }
    let directories = ProfileDirectories(root: root.standardizedFileURL.resolvingSymlinksInPath())
    self.directories = directories
    if isFirstRun { firstRunDefaultModel = model }
    installModel(model)
    LaunchTiming.shared.phase("modelInstalled")
    // Launch URLs enter the snapshot-backed model before window composition.
    // Only the final selection gets a page after engine readiness.
    if let state = model.windows.first(where: { $0.style == .standard }),
      let space = model.space(id: state.focusedSpaceID)
    {
      for url in isFirstRun ? [] : options.initialURLs {
        autoCreatedLaunchWindowID = nil
        let tab = model.newTab(in: space.id, url: url, at: 0)
        model.selectNode(windowID: state.id, spaceID: space.id, nodeID: tab.id)
      }
    }
    if !isFirstRun { prepareLittleOpen() }
    if !isFirstRun { startAutoArchiveIfNeeded() }
    LaunchTiming.shared.mark("modelLoaded")
    return directories
  }

  /// One observer/service seam for initial load and the first-run model swap.
  func installModel(_ model: BrowserModel) {
    if repairMissingProfiles(in: model) {
      do { try snapshotStore.saveNow(model: model) }
      catch { FileHandle.standardError.write(Data("Open: repaired Profiles could not be saved: \(error)\n".utf8)); exit(1) }
    }
    if let modelSaveObserver { self.model?.removeObserver(modelSaveObserver) }
    self.model = model
    if isFirstRun { autoCreatedLaunchWindowID = nil }
    archiveSink = ProfileArchiveSink(directories: directories) { [weak model] id in
      let profile = id.flatMap { model?.profile(id: $0) } ?? model?.defaultProfile
      return profile?.dataDirectoryName ?? "Default"
    }
    model.archiveSink = archiveSink; model.undoManager = undoManager
    modelSaveObserver = model.addObserver { [weak self] _ in self?.scheduleSave(); self?.scheduleMenuRebuild(); self?.purgeScriptingWrappers() }
    // Profile creation belongs to the currently installed model, including an import swap.
    tabSleep.installSettingsPolicy()
    adBlockEngineAdapter.installProfilePolicy()
    purgeScriptingWrappers()
  }

  /// Runs at the first of applicationDidFinishLaunching and
  /// engineDidInitialize (their order is not fixed).
  private func showWindowsIfNeeded(ignoringLittleOpen: Bool = false) {
    #if OPEN_AUTOMATION
    // Validate the packaged engine before its first on-screen launch.
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_OFFSCREEN_SMOKE"] == "1" { return }
    let pacingRegion = IntroPacingTrace.begin("browser.showWindowsIfNeeded")
    defer { pacingRegion?.end() }
    #endif
    prepareData()
    if isFirstRun && !firstRunSaved && windowControllers.isEmpty {
      if !onboardingHandedOff {
        showOnboarding(replay: options.replayOnboarding)
        return
      }
      onboardingWindowController?.showWindow(nil)
      return
    }
    guard windowControllers.isEmpty else { return }
    guard ignoringLittleOpen || littleOpenCoordinator?.sessions.isEmpty != false else { return }
    let states = model.windows.filter { $0.style == .standard }
    for state in states.isEmpty ? Array(model.windows.prefix(1)) : states {
      createWindowController(state: state)
    }
    restoreBlankWindows()
    todayAutoArchive?.finishStartupComposition()
    LaunchTiming.shared.mark("windowShown")
  }

  var libraryPrebuildTask: Task<Void,Never>?
  var libraryPrebuildGeneration = 0
  var libraryFirstSidebarDraw: Double?
  var libraryFirstSidebarDraws: [WindowID:Double] = [:]
  var libraryLastInput = 0.0
  var libraryPrebuiltAt: Double?
  func scheduleLibraryPrebuildAfterFirstDraw() {
    guard libraryFirstSidebarDraw == nil else { return }
    libraryFirstSidebarDraw = ProcessInfo.processInfo.systemUptime
    for controller in windowControllers { libraryFirstSidebarDraws[controller.windowID] = libraryFirstSidebarDraw }
    scheduleLibraryPrebuild()
  }
  func noteLibraryInput() {
    LibraryPanelView.noteUserInput()
    libraryLastInput = ProcessInfo.processInfo.systemUptime
    libraryPrebuildTask?.cancel(); libraryPrebuildTask = nil
    settingsPresenter.cancelLibraryIdleWork()
    if libraryFirstSidebarDraw != nil { scheduleLibraryPrebuild() }
  }
  func scheduleLibraryPrebuild() {
    #if OPEN_AUTOMATION
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_LIBRARY_PREBUILD_DISABLED"] == "1" { return }
    #endif
    guard let controller = frontStandardWindowController,let first = libraryFirstSidebarDraws[controller.windowID],!shutdownPrepared,!terminationRequested else { return }
    libraryPrebuildTask?.cancel()
    libraryPrebuildGeneration += 1
    let generation = libraryPrebuildGeneration
    let deadline = max(first+3,libraryLastInput+3)
    libraryPrebuildTask = Task { @MainActor [weak self,weak controller] in
      try? await Task.sleep(for:.seconds(max(0,deadline-ProcessInfo.processInfo.systemUptime)))
      guard let self,!Task.isCancelled,!self.shutdownPrepared,!self.terminationRequested else { return }
      defer { if self.libraryPrebuildGeneration == generation { self.libraryPrebuildTask = nil } }
      guard NSApp.isActive,NSApp.keyWindow?.attachedSheet == nil,let controller,self.frontStandardWindowController === controller,
        controller.window?.isVisible == true else { return }
      self.libraryPrebuiltAt = ProcessInfo.processInfo.systemUptime
      controller.onLibraryIdleRefresh = { [weak self] in self?.scheduleLibraryPrebuild() }
      await self.settingsPresenter.makeLibrarySession(controller).prebuild()
    }
  }

  func drawWindowsBeforeEngine() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("browser.drawWindowsBeforeEngine")
    defer { pacingRegion?.end() }
    #endif
    LaunchTiming.shared.phase("sidebarDisplayBegin")
    showWindowsIfNeeded()
    onboardingWindowController?.window?.contentView?.displayIfNeeded()
    firstRunWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
    firstRunWindowController?.window?.displayIfNeeded()
    for controller in windowControllers {
      controller.prepareForInitialDisplay()
      LaunchTiming.shared.phase("sidebarPrepared")
      controller.window?.contentView?.layoutSubtreeIfNeeded()
      LaunchTiming.shared.phase("sidebarLaidOut")
      controller.window?.displayIfNeeded()
      LaunchTiming.shared.phase("sidebarDisplayed")
    }
    #if OPEN_AUTOMATION
    let flushRegion = IntroPacingTrace.begin("browser.CATransaction.flush")
    #endif
    CATransaction.flush()
    #if OPEN_AUTOMATION
    flushRegion?.end()
    #endif
    LaunchTiming.shared.phase("sidebarFlushed")
    startupEvidence = [
      "sidebarClass": windowControllers.first.map { String(reflecting: type(of: $0.sidebar)) } ?? "",
      "pagesBeforeEngine": OEEngine.shared.allWebContents.count,
      "contextsBeforeEngine": OEEngine.shared.contexts.count,
      "visibleWindows": windowControllers.filter { $0.window?.isVisible == true }.count,
    ]
    #if OPEN_AUTOMATION
    startupEvidence["adBlockOwnerOpenBeforeEngine"] = stores.existingAdBlock != nil
    #endif
  }

  /// Capture shortcuts at the confirmed first frame, after AppKit's native
  /// launch run-loop work, and before Chromium starts.
  func recordFirstFrameMenuProbe() {
    #if OPEN_AUTOMATION
    if ProcessInfo.processInfo.environment["OPEN_SPEED_MENU_PROBE"] == "1" {
      startupEvidence["firstFrameMenuShortcuts"] = MainMenu.shortcutSnapshot(NSApp.mainMenu)
      startupEvidence["firstFrameRegistryRoutes"] = MainMenu.registryShortcutRoutes(self)
    }
    #endif
  }

  @discardableResult
  func createWindowController(state: BrowserWindowState, privateModel: BrowserModel? = nil, session: IncognitoSession? = nil, blankWindow: Bool = false) -> BrowserWindowController {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("browser.windowAndFactory.create")
    defer { pacingRegion?.end() }
    #endif
    LaunchTiming.shared.phase("windowCreateBegin")
    let windowModel = privateModel ?? model!
    windowModel.setWindowContentVisible(windowID: state.id, visible: true)
    let factory = EngineWebContentHostFactory(app: self, state: state, model: windowModel, incognitoSession: session, blankWindow: blankWindow)
    hostFactories[state.id] = factory
    let title = session.map { model.profiles.count > 1 ? "Incognito · " + $0.parent.name : "Incognito" }
    let controller = BrowserWindowController(model: windowModel, windowID: state.id, factory: factory,
      snapshotStore: session == nil && !blankWindow && !(isFirstRun && onboardingWindowController?.replay == true) ? snapshotStore : nil, incognitoTitle: title,
      windowOnlyTitle: blankWindow ? BlankWindow.sidebarTitle : nil,
      siteControlSource: factory.siteControlSource, siteControlActions: factory.siteControlSource)
    LaunchTiming.shared.phase("windowControllerCreated")
    if isFirstRun, !firstRunSaved, let onboarding = onboardingWindowController, !onboarding.replay {
      controller.allowsWindowActivation = false
      controller.window?.alphaValue = 0
    }
    if session == nil {
      // Tab drag between a Blank Window and a normal window (capture C-report-s11 1(a)).
      controller.context.foreignNodeDrop = { [weak self, weak factory] ids, parent, index, perform in
        guard let self, let factory else { return false }
        return self.dropTabs(ids, fromAnotherWindowInto: factory, parent: parent, index: index, perform: perform)
      }
      controller.context.tabDragChanged = { [weak self] ids in self?.sidebarDragChanged(ids) }
      controller.context.storedFavicons = stores.sidebarFavicons
      // Favorites empty-state card (A3): on in the product; a launch option turns it off for older suites.
      controller.context.showsFavoritesEmptyState = !options.hideFavoritesEmptyState
      // Recents hover card (live-data §3.4): read on first hover only, never at launch.
      controller.context.recentPagesSource = { [weak self] profileID, phrases in
        guard let store = self?.stores.history(for: profileID) else { return [] }
        var rows: [(url: URL, title: String, lastVisit: Date)] = []
        for phrase in phrases { rows += await store.recentURLs(matchingURLPhrase: phrase).map { ($0.url, $0.title, $0.lastVisit) } }
        return rows
      }
      // Gmail card (LF L6): the Atom feed in one hidden page of the Profile, on hover only.
      controller.context.mailGlanceSource = { [weak self] profileID, feed, host in
        guard let self else { return .failed }
        do {
          let value = try await self.liveFetch.fetch(profileID: profileID, url: feed, script: GmailGlance.extractionScript(expectedHost: host))
          switch GmailGlance.decode(value) {
          case (.ok, let rows): return .mail(rows)
          case (.signedOut, _): return .signedOut
          case (.unexpected, _): return .failed
          }
        } catch { return .failed }
      }
      // Calendar card (plan NS §2 CAL): closures only; EventKit is touched on first hover.
      controller.context.calendarGlance = makeCalendarGlance(factory)
      controller.context.liveCalendar = liveCalendar.actions()
      // Favorite unread badges from page titles (audit A2); normal windows only.
      controller.context.favoriteBadgesEnabled = true
    }
    // Native Note and Easel rows have no page or stored icon: draw their marks even before they show.
    controller.context.faviconProvider = { tab in
      NoteTab.matches(tab.url) ? NoteTab.faviconImage : EaselTab.matches(tab.url) ? EaselIcon.image : nil
    }
    factory.attach(controller)
    windowControllers.append(controller)
    updater?.userDriver.attach(controller)
    if session == nil { media.attach(factory); tabSleep.attach(factory) }
    // Off the first-paint path: the media source menu reads one small state file.
    DispatchQueue.main.async { [weak self] in self?.settingsPresenter.syncLibraryMediaSources() }
    activeWindowID = state.id
    LaunchTiming.shared.phase("windowServicesAttached")
    MainMenu.targetWindowCommands(factory)
    LaunchTiming.shared.phase("windowMenuBuilt")
    if session == nil { todayAutoArchive?.attach(context: controller.context) }
    controller.showWindow(nil)
    LaunchTiming.shared.phase("windowOrdered")
    if isFirstRun, !firstRunSaved, let onboarding = onboardingWindowController, !onboarding.replay,
      let window = controller.window { onboarding.hidePreparedBrowser(window) }
    if session == nil { showMissingProfileNoticeIfNeeded(on: controller.window) }
    if engineReady { factory.engineDidBecomeReady() }
    if session == nil, libraryFirstSidebarDraw != nil {
      DispatchQueue.main.async { [weak self,weak controller] in
        guard let self,let controller,controller.window?.isVisible == true else { return }
        controller.window?.displayIfNeeded()
        self.libraryFirstSidebarDraws[controller.windowID] = ProcessInfo.processInfo.systemUptime
        self.scheduleLibraryPrebuild()
      }
    }
    return controller
  }

  @discardableResult
  func makeWindow(focusedSpaceID: SpaceID? = nil) -> BrowserWindowController? {
    guard (!isFirstRun || firstRunSaved) else { return nil }
    // Closing the final window keeps its state for reopen and relaunch.
    if frontStandardWindowController == nil, let state = model.windows.first(where: { $0.style == .standard }) {
      return createWindowController(state: state)
    }
    guard let spaceID = focusedSpaceID ?? frontStandardWindowController?.context.focusedSpace?.id ?? model.spaces.first?.id,
      let state = withoutWindowUndo({ model.createWindow(focusedSpaceID: spaceID) }) else { return nil }
    let offset = Double(windowControllers.count * 24)
    state.frameX += offset; state.frameY -= offset
    // A new window copies the key window's toolbar (commandbar-completion §4.6.1; guess).
    state.showsToolbar = frontWindowController?.context.window?.showsToolbar ?? false
    let controller = createWindowController(state: state)
    scheduleSave(); return controller
  }

  var frontStandardWindowController: BrowserWindowController? {
    let normal = windowControllers.filter { hostFactories[$0.windowID]?.isIncognito == false }
    return NSApp.orderedWindows.compactMap { window in normal.first { $0.window === window } }.first ?? normal.first
  }

  /// The front browser window of the main model: not Incognito and not a Blank Window, whose
  /// models hold none of the main model's Spaces.
  var frontMainModelWindowController: BrowserWindowController? {
    let main = windowControllers.filter { hostFactories[$0.windowID].map { !$0.isIncognito && $0.model === model } ?? false }
    return NSApp.orderedWindows.compactMap { window in main.first { $0.window === window } }.first ?? main.first
  }

  @discardableResult
  func makeIncognitoWindow(parent: Profile? = nil, url: URL? = nil) -> BrowserWindowController? {
    guard engineReady, let parent = parent ?? frontStandardWindowController?.context.focusedSpace.flatMap({ model.profile(id: $0.profileID) }) ?? model.defaultProfile else { return nil }
    let session = incognitoSessions.acquire(parent: parent, app: self)
    let profile = Profile(name: parent.name, settings: parent.settings, dataDirectoryName: "Incognito")
    let space = Space(title: "Incognito", icon: .symbol("eyeglasses"), profileID: profile.id)
    let state = BrowserWindowState(focusedSpaceID: space.id)
    let memory = BrowserModel(profiles: [profile], spaces: [space], windows: [state])
    let undo = UndoManager(); undo.groupsByEvent = false; memory.undoManager = undo
    let controller = createWindowController(state: state, privateModel: memory, session: session)
    if let factory = hostFactories[state.id] {
      if let url { factory.openNewTab(url: url, background: false) }
      else { factory.showCommandBar(.newTab) }
    }
    return controller
  }

  @objc func newWindow(_ sender: Any?) { makeUserWindow() }

  /// File ▸ New Window and Blank Window: Arc opens every window the user creates with the command bar
  /// open in New Tab mode (`showCommandBarOnNewlyCreatedWindows`, one Bool in Arc's app state beside its
  /// session-restoration fields; F0098, F0157, A0359, S2 19/0029). Windows restored at launch and windows
  /// made for a moved tab do not (guess for restoration; no launch capture), so cold launch pays nothing.
  @discardableResult
  func makeUserWindow() -> BrowserWindowController? {
    guard let controller = makeWindow() else { return nil }
    hostFactories[controller.windowID]?.showCommandBar(.newTab)
    return controller
  }

  /// Settings ▸ Advanced "Show full URL when Toolbar is enabled" for every browser window.
  func applyToolbarSettings() {
    let full = UserDefaults.standard.bool(forKey: AppCommand.showFullURLKey)
    for controller in windowControllers where controller.showsFullURLWithToolbar != full { controller.showsFullURLWithToolbar = full }
  }

  func focusWindow(_ id: WindowID, activate: Bool = false) {
    if isFirstRun && !firstRunSaved, let onboarding = onboardingWindowController {
      onboarding.window?.makeKeyAndOrderFront(nil)
      if activate { NSApp.activate() }
      return
    }
    didFocusWindow(id)
    windowControllers.first { $0.windowID == id }?.window?.makeKeyAndOrderFront(nil)
    if activate { NSApp.activate() }
  }

  func didFocusWindow(_ id: WindowID) {
    activeWindowID = id
    let standard = model.windows.filter { $0.style == .standard }
    let mostRecent = standard.max { ($0.lastFocusedAt ?? .distantPast) < ($1.lastFocusedAt ?? .distantPast) }
    if let state = standard.first(where: { $0.id == id }), state !== mostRecent || state.lastFocusedAt == nil {
      // Only a switch to another standard window changes recency. Refocusing the
      // current one (for example after a private window) leaves the saved session
      // untouched (e2e incognito no_snapshot_history_change). Memory only: the next
      // ordinary save and the quit save persist it.
      state.lastFocusedAt = Date()
    }
    for (otherID, factory) in hostFactories where otherID != id {
      factory.commandBarSession?.dismiss()
      factory.controller?.boostEditor?.close(returnFocus: false)
    }
    MainMenu.targetWindowCommands(hostFactories[id])
    settingsPresenter.refreshSpaceManagerContext()
  }

  func windowDidClose(_ id: WindowID) {
    sidebarDragChanged(nil)
    libraryFirstSidebarDraws.removeValue(forKey:id)
    settingsPresenter.libraryWindowClosed(id)
    guard let factory = hostFactories[id] else { return }
    if let session = factory.incognitoSession {
      windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
      if session.windows == 1, let context = session.context { extensionPrompts.unregister(context.extensions) }
      incognitoSessions.release(session)
      if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
      MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
      return
    }
    noteLaunchWindowNavigation(id)
    todayAutoArchive?.detach(windowID: id)
    if model.windows.filter({ $0.style == .standard }).count > 1 {
      withoutWindowUndo { model.closeWindow(windowID: id) }
    } else {
      model.setWindowContentVisible(windowID: id, visible: false)
    }
    windowControllers.removeAll { $0.windowID == id }; hostFactories[id] = nil
    purgeScriptingWrappers()
    media.windowClosed(id)
    tabSleep.visibilityChanged()
    if activeWindowID == id { activeWindowID = windowControllers.last?.windowID }
    MainMenu.targetWindowCommands(frontWindowController.flatMap { hostFactories[$0.windowID] })
    scheduleSave()
    settingsPresenter.refreshSpaceManagerContext()
  }

  func discardUnusedLaunchWindow(_ id: WindowID) {
    guard let controller = windowControllers.first(where: { $0.windowID == id }) else { return }
    controller.window?.close()
    // The usual last-window close retains user state. This tagged fallback
    // was absent from the saved session, so do not persist a phantom window.
    withoutWindowUndo { model.closeWindow(windowID: id) }
    scheduleSave()
  }

  static func makeDefaultModel() -> BrowserModel {
    let profile = Profile(name: "Default", dataDirectoryName: "Default")
    let space = Space(title: "Space", profileID: profile.id)
    let window = BrowserWindowState(focusedSpaceID: space.id)
    return BrowserModel(profiles: [profile], spaces: [space], windows: [window])
  }

  /// Shell window lifetime and the setup-created Welcome tab are not sidebar
  /// edits. Preserve an
  /// enclosing caller's disabled registration state, including on early return.
  private func withoutWindowUndo<T>(_ body: () -> T) -> T {
    let wasEnabled = undoManager.isUndoRegistrationEnabled
    if wasEnabled { undoManager.disableUndoRegistration() }
    defer { if wasEnabled { undoManager.enableUndoRegistration() } }
    return body()
  }

  /// Live Folder refresh when the app comes to the front (live-data §2.5). Nothing runs (no
  /// service is made) while no Live Folder exists.
  func applicationDidBecomeActive(_ notification: Notification) {
    guard let model, !model.liveFolders.isEmpty else { return }
    liveFolders.windowForegrounded()
  }

  func scheduleSave() {
    guard let model, (!isFirstRun || firstRunSaved) else { return }
    snapshotStore.scheduleSave(model: model)
  }

  /// Called after the message loop returns, before the engine shuts down.
  func saveState() {
    // Easel edits in progress (a title or a text box) are written before quit.
    for factory in hostFactories.values { for host in factory.easelHosts.values { host.canvas.commitPendingEdits() } }
    easelStore?.flush()
    guard let model, (!isFirstRun || firstRunSaved) else { return }
    for controller in windowControllers { controller.saveWindowState() }
    do {
      try snapshotStore.saveNow(model: model)
    } catch {
      FileHandle.standardError.write(Data("Open: saving the snapshot failed: \(error)\n".utf8))
    }
    archiveSink.flushAll()
    notes.flush()
    if let blankWindowsAtQuit { writeBlankWindows(blankWindowsAtQuit) }
  }

  /// Used after import (including an E-5 save error) so the imported items are
  /// available behind the panel. Saving remains guarded until saveNow succeeds.
  func showFirstRunBrowser() {
    guard windowControllers.isEmpty else { return }
    LaunchTiming.shared.mark("firstRunLandingStarted")
    let states = model.windows.filter { $0.style == .standard }
    for state in states { createWindowController(state: state) }
    if let onboarding = onboardingWindowController, !onboarding.replay, let window = onboarding.window {
      for controller in windowControllers {
        controller.allowsWindowActivation = false
        if let browser = controller.window { onboarding.hidePreparedBrowser(browser) }
      }
      window.makeKeyAndOrderFront(nil)
    } else { firstRunWindowController?.window?.makeKeyAndOrderFront(nil) }
  }

  func finishFirstRun(imported: Bool) {
    guard firstRunWindowController != nil else { return }
    assert(imported || model === firstRunDefaultModel, "A fresh finish must keep the original default model")
    let priorBlocker = stores.adBlock?.isEnabled
    do {
      try onboardingWindowController?.steps?.applyChoices()
      try snapshotStore.saveNow(model: model)
      // Save the choices first, then insert Welcome before any browser is built.
      // Retain its ID across a failed second save so retry cannot add a duplicate.
      if firstRunWelcomeID.flatMap({ model.tab(id: $0) }) == nil,
        let space = onboardingWindowController?.steps?.focusedSpace ?? model.spaces.first {
        // Keep the import's native Undo as the first user action after setup.
        firstRunWelcomeID = withoutWindowUndo { WelcomeTab.insert(into: model, spaceID: space.id) }
      }
      try snapshotStore.saveNow(model: model)
      onboardingWindowController?.steps?.persistName()
      firstRunSaved = true
      UserDefaults.standard.set(true, forKey: "open.firstRun.completed")
    } catch {
      if let priorBlocker { try? stores.adBlock?.setEnabled(priorBlocker) }
      firstRunWindowController?.model.reportSaveFailure(imported: imported)
      return
    }
    lastFirstRunStep = firstRunWindowController?.model.step.rawValue ?? lastFirstRunStep
    firstRunWindowController = nil
    prepareLittleOpen()
    showWindowsIfNeeded()
    if let onboarding = onboardingWindowController?.window {
      for controller in windowControllers {
        controller.allowsWindowActivation = true
        controller.window?.order(.below, relativeTo: onboarding.windowNumber)
        NSAnimationContext.runAnimationGroup { context in
          context.duration = onboardingWindowController?.intro.reduceMotion == true ? 0.3:0.6
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          controller.window?.animator().alphaValue = 1
        }
      }
      frontWindowController?.window?.makeKey()
      onboardingWindowController?.finish()
    } else { frontWindowController?.window?.makeKeyAndOrderFront(nil) }
    settingsPresenter.attachBrowserStores()
    startAutoArchiveIfNeeded(); todayAutoArchive?.finishStartupComposition()
    for url in options.initialURLs {
      _ = frontWindowController.flatMap { hostFactories[$0.windowID] }?.openNewTab(url: url, background: false)
    }
    completeLinkRestoration()
    reloadKeyBindings()
    let pendingLittleOpen = pendingLittleOpenBlankStamps
    pendingLittleOpenBlankStamps.removeAll()
    for timestamp in pendingLittleOpen { openBlankLittleOpen(timestamp: timestamp) }
  }

  // MARK: OEEngineDelegate

  func engineDidInitialize() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("engine.didInitialize")
    defer { pacingRegion?.end() }
    #endif
    LaunchTiming.shared.mark("engineInitialized")
    engineReady = true
    adBlockEngineAdapter.engineDidInitialize()
    showWindowsIfNeeded()
    refreshScriptingEngine()
    for factory in hostFactories.values { factory.engineDidBecomeReady() }
    // A fresh empty Space has no web paint to start T5. Register its shortcut
    // after the native first frame without creating Settings or SuggestEngine.
    if !isFirstRun || firstRunSaved { reloadKeyBindings() }
    if !isFirstRun || firstRunSaved {
      let pendingLittleOpen = pendingLittleOpenBlankStamps
      pendingLittleOpenBlankStamps.removeAll()
      for timestamp in pendingLittleOpen { openBlankLittleOpen(timestamp: timestamp) }
    }
    if !isFirstRun || firstRunSaved { completeLinkRestoration() }
    EngineWebProfile.onPermissionChange = { [weak self] context in self?.tabSleep.permissionsChanged(context: context) }
    scheduleMenuRebuild()
    // Empty Spaces, Welcome, and onboarding have a native first frame but no
    // web paint callback. Leave that frame two seconds before background I/O.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, !self.shutdownPrepared, !self.terminationRequested,
            OEEngine.shared.allWebContents.isEmpty,
            NSApp.windows.contains(where: { $0.isVisible }) else { return }
      self.scheduleCloneCleanupAfterPaint()
    }
    #if OPEN_AUTOMATION
    if !isFirstRun { startAutomationIfNeeded() }
    #endif
  }

  #if OPEN_AUTOMATION
  func startAutomationIfNeeded() {
    guard automation == nil else { return }
    let region = IntroPacingTrace.begin("automation.server.start")
    defer { region?.end() }
    let socket =
      options.automationSocket
      ?? options.userDataDirectory.appendingPathComponent("automation.sock")
    let server = AutomationServer(socketURL: socket, controller: AutomationController(app: self))
    do {
      try server.start()
      automation = server
      FileHandle.standardError.write(Data("Open: automation socket at \(socket.path)\n".utf8))
    } catch {
      FileHandle.standardError.write(Data("Open: automation socket failed: \(error)\n".utf8))
    }
  }
  #endif

  func engineWebContent(forUnownedOpenRequest request: OEOpenRequest) -> OEWebContent? {
    let owner = hostFactories.values.first { $0.isIncognito && $0.incognitoSession?.context === request.context }
      ?? frontStandardWindowController.flatMap { hostFactories[$0.windowID] }
    return owner?.adoptUnownedRequest(request)
  }

  func engineWillShutDown() {
    prepareForEngineShutdown()
    #if OPEN_AUTOMATION
      automation?.stop()
    #endif
  }

  /// Runs before OEApplication starts its engine close sequence, and again
  /// defensively before CefShutdown if the message loop ends by another path.
  func prepareForEngineShutdown() {
    guard !shutdownPrepared else { return }
    ExtensionWindowController.closeAll()
    stopAutoArchive()
    tabSleep.stop()
    adBlockEngineAdapter.stop()
    stores.boosts.stop()
    shutdownPrepared = true
    recordShutdownPhase("prepare")
    libraryPrebuildTask?.cancel(); libraryPrebuildTask = nil
    afterPaintTask?.cancel(); afterPaintTask = nil
    menuRebuildTask?.cancel(); menuRebuildTask = nil
    littleOpenCoordinator?.closeAll()
    downloadsCenter.closeDetachedPages()
    engineReady = false
    refreshScriptingEngine()
    for factory in Array(hostFactories.values) { factory.closeAll() }
    incognitoSessions.closeAll()
    if directories != nil { notes.flush() }
    recordShutdownPhase("hostsClosed")
  }

  func noteAsyncEngineCall(_ operation: String) {
    asyncEngineCalls[operation, default: 0] += 1
    if shutdownPrepared || !engineReady || terminationRequested { lateAsyncEngineCalls += 1 }
  }

  /// A real queued task can be held at its scheduling boundary in e2e builds.
  /// Cancellation interrupts this wait; engine responses are never replaced.
  func deferAsyncEngineWorkForAutomation() async {
    #if OPEN_AUTOMATION
    if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_ASYNC_TASK_DELAY_MS"],
       let milliseconds = Int(raw), milliseconds > 0 {
      try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    #endif
  }

  func recordShutdownPhase(_ phase: String) {
    #if OPEN_AUTOMATION
    guard ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SHUTDOWN_TRACE"] == "1", directories != nil else { return }
    let factories = Array(hostFactories.values)
    shutdownTrace.append(["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime,
      "captureTasks": factories.reduce(0) { $0 + $1.saveCaptureTasks.count },
      "backgroundTasks": factories.reduce(0) { $0 + $1.hosts.values.filter(\.hasBackgroundTask).count },
      "selectionTasks": factories.filter(\.hasFindSelectionTask).count,
      "hosts": factories.reduce(0) { $0 + $1.hosts.count },
      "closedFactories": factories.filter(\.isClosing).count, "factories": factories.count,
      "asyncEngineCalls": asyncEngineCalls,
      "lateAsyncEngineCalls": lateAsyncEngineCalls])
    let file = directories.root.appendingPathComponent("State/shutdown-order.json")
    if let data = try? JSONSerialization.data(withJSONObject: shutdownTrace, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: file, options: .atomic)
    }
    #endif
  }

  private func downloadOwner(_ download: OEDownload) -> EngineWebContentHostFactory? {
    if let page = download.webContent {
      if let host = littleOpenHosts.values.first(where: { $0.content === page }) { return host.owner }
      return hostFactories.values.first { $0.tabID(for: page) != nil || $0.auxiliaryPages.contains { $0.content === page } }
    }
    return frontWindowController.flatMap { hostFactories[$0.windowID] }
  }

  func browserContext(_ context: OEBrowserContext, decideDestinationFor download: OEDownload, suggestedFilename: String, completion: @escaping @MainActor (URL?) -> Void) {
    #if OPEN_AUTOMATION
    if AutomationOwnerWatch.quittingWithoutPrompts { completion(nil); return }
    #endif
    guard let owner = downloadOwner(download) else { completion(nil); return }
    owner.browserContext(context, decideDestinationFor: download, suggestedFilename: suggestedFilename, completion: completion)
  }

  func browserContext(_ context: OEBrowserContext, downloadDidUpdate download: OEDownload) {
    downloadsCenter.updated(download, context: context)
    downloadOwner(download)?.browserContext(context, downloadDidUpdate: download)
  }

  /// A web notification was clicked (EP-6); §4.5.4's 500 ms fallback selects its tab.
  func browserContext(_ context: OEBrowserContext, didClickNotification identifier: String, origin: URL, persistent: Bool) {
    NotificationClickRouter.shared.clicked(app: self, context: context, identifier: identifier, origin: origin, persistent: persistent)
  }
}

extension AppDelegate: CommandDispatcher {
  func factory(forKeyWindow window: NSWindow) -> EngineWebContentHostFactory? {
    hostFactories.values.first { $0.ownsKeyWindow(window) }
  }
  func scheduleMenuRebuild() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("menu.scheduleRebuild")
    defer { pacingRegion?.end() }
    #endif
    guard !shutdownPrepared, menuRebuildTask == nil else { return }
    menuRebuildTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(30))
      guard let self, !Task.isCancelled else { return }
      #if OPEN_AUTOMATION
      let region = IntroPacingTrace.begin("menu.rebuild")
      defer { region?.end() }
      #endif
      self.menuRebuildTask = nil; NSApp.mainMenu = MainMenu.build()
      ThemeData.refreshVisible(app: self)
      // Menu rebuilds follow tab, Space and window changes: the same moments Handoff must follow.
      self.handoff.setNeedsUpdate()
    }
  }
  /// No suggestion index, history, hotkey or settings work before first paint.
  func prepareCommandsAfterPaint(_ page: OEWebContent) {
    guard engineReady, !shutdownPrepared, !terminationRequested,
          !commandServicesPrepared || !tabSleep.isStarted || !FindBarPrewarm.isScheduled, afterPaintTask == nil else { return }
    afterPaintTask = Task { @MainActor [weak self, weak page] in
      defer { self?.afterPaintTask = nil }
      for _ in 0..<40 {
        guard let self, let page, self.engineReady, !self.shutdownPrepared,
              !self.terminationRequested, !Task.isCancelled else { return }
        let painted = (try? await page.evaluateJavaScript("performance.getEntriesByType('paint').length > 0")) as? Bool
        if painted == true {
          self.scheduleCloneCleanupAfterPaint()
          // Each service body gets its own main run-loop turn, so input is
          // handled between them and no turn carries several bodies.
          if !self.commandServicesPrepared {
            self.startupRegion("afterPaint.commandServices") { self.prepareCommandServices() }
            guard await self.nextStartupTurn() else { return }
            // Suggest engine creation and its tab-index build take one turn each.
            if let id = self.frontStandardWindowController?.windowID, let profile = self.hostFactories[id]?.focusedProfile {
              self.startupRegion("afterPaint.suggestEngine") { _ = self.stores.suggest(for: profile.id) }
              guard await self.nextStartupTurn() else { return }
              // The engine is cached for this Profile; this builds its tab index.
              self.startupRegion("afterPaint.suggestIndex") { self.stores.prewarm(profileID: profile.id) }
              guard await self.nextStartupTurn() else { return }
            }
          }
          // Startup T5: the sleep controller starts after first paint, never before.
          self.startupRegion("afterPaint.sleep") { self.tabSleep.start() }
          guard await self.nextStartupTurn() else { return }
          self.startupRegion("afterPaint.adBlock") { self.adBlockEngineAdapter.startAfterPaint() }
          guard await self.nextStartupTurn() else { return }
          self.startupRegion("afterPaint.findPrewarm") { FindBarPrewarm.schedule(afterPaintIn: self) }
          guard await self.nextStartupTurn() else { return }
          self.startupRegion("afterPaint.icon") { self.applicationIcon.restoreAfterContent() }
          guard await self.nextStartupTurn() else { return }
          self.startupRegion("afterPaint.updater") { self.prepareUpdaterAfterPaint() }
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      // A page that never reports a paint (about:blank): start sleep after the same 2 s budget.
      guard let self, self.engineReady, !self.shutdownPrepared, !self.terminationRequested, !Task.isCancelled else { return }
      self.scheduleCloneCleanupAfterPaint()
      self.startupRegion("fallback.sleep") { self.tabSleep.start() }
      guard await self.nextStartupTurn() else { return }
      self.startupRegion("fallback.adBlock") { self.adBlockEngineAdapter.startAfterPaint() }
      guard await self.nextStartupTurn() else { return }
      self.startupRegion("fallback.icon") { self.applicationIcon.restoreAfterContent() }
      guard await self.nextStartupTurn() else { return }
      self.startupRegion("fallback.updater") { self.prepareUpdaterAfterPaint() }
    }
  }
  private func scheduleCloneCleanupAfterPaint() {
    guard !cloneCleanupScheduled, engineReady, !shutdownPrepared, !terminationRequested else { return }
    cloneCleanupScheduled = true
    #if OPEN_AUTOMATION
    LaunchTiming.shared.mark("cloneCleanupScheduled")
    #endif
    OEEngine.shared.pruneUnusedCodeSignClones { [weak self] counts in
      #if OPEN_AUTOMATION
      self?.cloneCleanupCounts = counts
      LaunchTiming.shared.mark("cloneCleanupFinished")
      #endif
    }
  }
  /// Ends this run-loop turn (a 1 ms timer wake, not a queue hop that can run
  /// in the same drain) and reports whether start-up may continue.
  private func nextStartupTurn() async -> Bool {
    try? await Task.sleep(for: .milliseconds(1))
    return engineReady && !shutdownPrepared && !terminationRequested && !Task.isCancelled
  }
  /// Automation builds record a named start-up region; product builds only run the body.
  func startupRegion(_ name: String, _ body: () -> Void) {
    #if OPEN_AUTOMATION
    let region = StartupMainThreadTrace.begin(name)
    body()
    StartupMainThreadTrace.end(region)
    #else
    body()
    #endif
  }
  private func prepareUpdaterAfterPaint() {
    guard updater == nil else { return }
    updater = UpdaterController(app: self)
    if checkForUpdatesAfterPaint { checkForUpdatesAfterPaint = false; updater?.checkForUpdates() }
  }
  func prepareCommandServices() {
    guard !commandServicesPrepared else { return }
    commandServicesPrepared = true
    // The Settings model stays lazy until Settings or a Settings action needs it
    // (its first open is budgeted from a lazy model; launch does not read it).
    numberedShortcutOptions = currentNumberedShortcutOptions
    commandDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.applyToolbarSettings()
        ThemeData.settingMaybeChanged(app: self)
        let options = self.currentNumberedShortcutOptions
        guard options != self.numberedShortcutOptions else { return }
        self.numberedShortcutOptions = options; self.scheduleMenuRebuild()
      }
    }
    commandWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // A window no browser owns (Library, Settings) must stop routing menu keys to the
        // browser at once: a key pressed before a deferred rebuild (or while another one is
        // pending) would otherwise run in the browser behind it (Cmd+L, Cmd+W).
        if let window = NSApp.keyWindow, window.sheetParent == nil, self.factory(forKeyWindow: window) == nil, !self.shutdownPrepared {
          self.menuRebuildTask?.cancel(); self.menuRebuildTask = nil
          NSApp.mainMenu = MainMenu.build()
        } else { self.scheduleMenuRebuild() }
      }
    }
    reloadKeyBindings()
  }
  func reloadKeyBindings() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("menu.reloadKeyBindings")
    defer { pacingRegion?.end() }
    #endif
    let file = options.userDataDirectory.appendingPathComponent("State/keybindings.json")
    do {
      let loaded = FileManager.default.fileExists(atPath: file.path) ? try KeyBindingStore.load(from: file) : .empty
      guard loaded.version == 1, loaded.unknownCommandIDs.isEmpty,
        loaded.bindings.keys.allSatisfy({ CommandRegistry.byID[$0]?.isCustomizable == true }),
        ConflictChecker.unexpected(ConflictChecker.check(overrides: loaded)).isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }
      keyBindings = loaded
      EssentialShortcutsWindowController.shared.update(store: loaded)
    } catch {
      keyBindings = .empty; Self.commandLog("Key bindings could not be loaded: \(error)")
    }
    for controller in windowControllers { controller.keyBindingOverrides = keyBindings }
    extensionPrompts.rebuildShortcuts()
    updateLittleOpenHotkey(); scheduleMenuRebuild()
  }
  func updateLittleOpenHotkey() {
    hotkeyService?.unregister(); hotkeyError = nil
    guard UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true,
      let command = CommandRegistry.byID["little-open-global"],
      let shortcut = keyBindings.effectiveShortcuts(for: command).first else { return }
    if hotkeyService == nil { hotkeyService = GlobalHotkeyService() }
    hotkeyAttempts += 1
    do { try hotkeyService?.register(shortcut: shortcut, actionWithTimestamp: { [weak self] timestamp in
      Task { @MainActor in self?.openBlankLittleOpen(timestamp: timestamp) }
    }) }
    catch { hotkeyError = String(describing: error); Self.commandLog("Little Open hotkey registration failed: \(error)") }
  }
  static func commandLog(_ message: String) { FileHandle.standardError.write(Data("Open: \(message)\n".utf8)) }
  var libraryShowsEasels: Bool { settingsPresenter.libraryWindow != nil && settingsPresenter.activeLibrarySession?.panel?.section == .easels }
  func menuState(for id: String) -> CommandMenuState? {
    if id == "set-default-browser" { return CommandMenuState(isChecked: defaultBrowserService.isDefaultBrowser) }
    // Arc 1.172.2 (capture, C-questions "_NS:451"): "View Library" with no browser window, else "Open Library…".
    if id == "view-library", frontStandardWindowController == nil { return CommandMenuState(title: "View Library") }
    // C-NT1 (C-report-s11): while the Library shows Easels, the item reads "Hide Easels" in Arc.
    if id == "view-easels-notes", libraryShowsEasels { return CommandMenuState(title: "Hide Easels & Notes") }
    if id == "toggle-developer-mode" { return DeveloperMode.menuState(for: frontWindowController.flatMap { hostFactories[$0.windowID] }?.selectedContent?.url) }
    return PageTools.menuState(for: id)
  }
  private static let firstRunCommands: Set<String> = [
    "quit-open", "hide-open", "hide-others", "show-all", "about-open", "archive-tab", "close-window"
  ]
  private func allowsFirstRunCommand(_ id: String) -> Bool {
    !isFirstRun || firstRunSaved || Self.firstRunCommands.contains(id)
  }
  var settingsShortcutCaptured: Bool {
    hostFactories.values.contains { factory in
      factory.commandBarSession?.isPresented == true &&
        factory.commandBarSession?.controller?.editingUndoManager(for: NSApp.keyWindow?.firstResponder) != nil
    }
  }
  func isCommandEnabled(_ id: String, enabledKey: String) -> Bool {
    guard allowsFirstRunCommand(id) else { return false }
    if id == "settings", settingsShortcutCaptured { return false }
    if id == "check-for-updates" { return true }
    if id == "boost-gallery" { return boostGalleryEnabled }
    if let enabled = littleOpenCommandEnabled(id) { return enabled }
    if SystemCommandActions.selectors[id] != nil { return SystemCommandActions.isEnabled(id) }
    if let enabled = PageTools.isAppCommandEnabled(id) { return enabled }  // App/Page/PageToolsCommands.swift
    if ["archive-tab", "close-window"].contains(id) { return NSApp.keyWindow != nil }
    // New Note with no browser window key (a Little Open window, Settings, no key window):
    // the Note goes to the front browser window (NoteTab.create).
    if ["new-note", "new-note-in-split"].contains(id) { return frontStandardWindowController != nil }
    // C-NT1: with no browser window open, Arc's View Easels… does nothing.
    if id == "view-easels-notes" { return frontStandardWindowController != nil }
    return ["new-incognito-window", "new-window", "blank-window", "new-tab", "new-profile", "settings", "search-settings", "air-traffic-control", "import-from-browser", "set-default-browser", "check-for-updates", "view-archive", "view-history", "view-library", "view-downloads", "view-media", "view-easels-notes", "view-boosts", "quit-open", "new-little-open-window", "little-open-global", "about-open", "hide-open", "hide-others", "show-all", "help-center", "keyboard-shortcuts-edu", "getting-started", "release-notes", "contact-team", "manage-spaces"].contains(id)
  }
  func performCommand(_ id: String, payload: String?) {
    guard allowsFirstRunCommand(id) else { return }
    // Search engines live in Settings ▸ Profiles: open the named Profile, else the front window's.
    // An action row's payload is a Space ID, which names no Profile, so it falls back too.
    if id == "search-settings" {
      let named = payload.flatMap(UUID.init(uuidString:)).map { ProfileID(rawValue: $0) }.flatMap { model.profile(id: $0) == nil ? nil : $0 }
      let profile = named ?? frontWindowController.flatMap { hostFactories[$0.windowID]?.focusedProfile?.id }
      if let profile, model.profile(id: profile) != nil { settingsPresenter.show(section: .search, profileID: profile) }
      else { settingsPresenter.show(section: .search) }
      return
    }
    performCommand(id)
  }
  func performCommand(_ id: String) {
    performCommand(id, keyDownTimestamp: nil)
  }
  func performCommand(_ id: String, keyDownTimestamp: TimeInterval?) {
    guard allowsFirstRunCommand(id) else { return }
    noteLaunchWindowInput(NSApp.keyWindow)
    if performLittleOpenCommand(id) { return }
    if SystemCommandActions.selectors[id] != nil { _ = SystemCommandActions.perform(id); return }
    if PageTools.isAppCommandEnabled(id) == true, PageTools.performAppCommand(id) { return }
    switch id {
    case "new-incognito-window": makeIncognitoWindow()
    case "new-window": makeUserWindow()
    case "blank-window": makeBlankWindow()
    case "new-tab":
      let controller = frontWindowController ?? makeWindow()
      controller.flatMap { hostFactories[$0.windowID] }?.newTab(nil)
    case "new-note", "new-note-in-split":
      // The App is the menu's dispatcher while a Little Open window is key (MainMenu.build):
      // create the Note in the front browser window and bring that window forward.
      guard let controller = frontStandardWindowController, let factory = hostFactories[controller.windowID] else { return }
      controller.window?.makeKeyAndOrderFront(nil)
      _ = NoteTab.create(in: factory, split: id == "new-note-in-split")
    case "settings": if !settingsShortcutCaptured { settingsPresenter.show() }
    case "new-profile": settingsPresenter.showNewProfile()
    case "search-settings": performCommand(id, payload: nil)
    case "air-traffic-control": settingsPresenter.show(section: .links, row: "rules")
    case "import-from-browser": settingsPresenter.show(pane: .general); settingsPresenter.settings.showsImport = true
    case "set-default-browser": settingsPresenter.settings.general.setDefault()
    case "check-for-updates": settingsPresenter.checkForUpdates()
    case "view-library": settingsPresenter.showLibrary()
    case "view-downloads": settingsPresenter.showLibrary(section: .downloads)
    // Arc's View Media runs viewScreenshotsAndCaptures: (docs/re/menus-and-hotkeys.md): the Library's
    // Media grid (Captures + Screenshots), not playback.
    case "view-media": settingsPresenter.showLibrary(section: .media)
    case "view-easels-notes":
      // C-NT1: the item toggles; choosing "Hide Easels & Notes" closes the Library again.
      if libraryShowsEasels { settingsPresenter.closeLibrary() } else if frontStandardWindowController != nil { settingsPresenter.showLibraryEasels() }
    case "view-archive": settingsPresenter.showLibrary(section: .archive)
    case "view-history":
      settingsPresenter.showLibrary(section: .history)
    case "view-boosts": settingsPresenter.showLibrary(section: .boosts, boostsPresentation: .list, boostsProfileID: boostLibraryInvokingProfileID)
    case "boost-gallery": if boostGalleryEnabled { settingsPresenter.showLibrary(section: .boosts, boostsPresentation: .gallery, boostsProfileID: boostLibraryInvokingProfileID) }
    case "keyboard-shortcuts-edu":
      // Help ▸ Essential Keyboard Shortcuts: Arc's floating EDU window (commandbar-completion §4.5, CC-27).
      EssentialShortcutsWindowController.shared.show(near: frontWindowController?.window ?? NSApp.keyWindow, store: keyBindings)
    case "archive-tab": NSApp.keyWindow?.performClose(nil)
    case "manage-spaces": settingsPresenter.showLibrary(section: .spaces)
    case "new-little-open-window", "little-open-global": openBlankLittleOpen(timestamp: keyDownTimestamp)
    case "help-center", "getting-started", "release-notes", "contact-team":
      let controller = frontWindowController ?? makeWindow()
      _ = controller.flatMap { hostFactories[$0.windowID] }?.openNewTab(url: AppCommand.helpURL(for: id), background: false)
    default:
      #if DEBUG
      if CommandRegistry.byID[id]?.isReserved != true { Self.commandLog("Unhandled app command: \(id)") }
      #endif
    }
  }
}
