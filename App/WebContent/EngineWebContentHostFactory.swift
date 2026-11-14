#if OPEN_AUTOMATION
import OpenOnboarding
#endif
import AppKit
import OpenEngine
import OpenFeatures
import OpenDocuments
import OpenModel
import OpenStore
import OpenSidebar
import OpenSpaceEditor
import OpenCommands
import OpenCommandBar
import OpenSuggest
import OpenSettings
import OpenSpaceEditor

// App has no window controller of its own.
typealias BrowserWindowController = OpenFeatures.BrowserWindowController

/// A page hosted outside the sidebar's BrowserWindowController.
@MainActor
protocol StandalonePageSurface: AnyObject {
  var surfaceWindow: NSWindow? { get }
  var surfacePage: OEWebContent? { get }
  var isSurfaceVisible: Bool { get }
  func surfaceAnchor() -> (view: NSView, rect: CGRect)?
}

@MainActor
final class AuxiliaryPage {
  let content: OEWebContent
  let panel: NSPanel
  var historyRecorder: AppHistoryRecorder?
  /// The panel's close button closes the page too.
  var closeObserver: NSObjectProtocol?
  init(content: OEWebContent, panel: NSPanel) { self.content = content; self.panel = panel }
}

/// App-owned engine wiring for one OpenFeatures window. The package sees only
/// WebContentHost; it never imports OpenEngine.
@MainActor
final class EngineWebContentHostFactory: NSResponder, WebContentHostFactory {
  unowned let app: AppDelegate
  let windowState: BrowserWindowState
  weak var controller: BrowserWindowController?
  weak var standaloneSurface: (any StandalonePageSurface)?
  weak var standaloneBrowser: OEBrowser?
  weak var littleOpenController: LittleOpenWindowController?
  private weak var littleOpenContent: OEWebContent?
  private weak var littleOpenBrowser: OEBrowser?
  // Unshown extension-created pages awaiting their first real address.
  private var pendingLittleOpenExtensionTabs: [Int: OEWebContent] = [:]
  var window: NSWindow? { controller?.window ?? standaloneSurface?.surfaceWindow ?? littleOpenController?.window }
  private(set) var savePrompts: SavePromptPresenter?
  var autofillToastCenter: ToastCenter?
  func attachSavePrompts() {
    guard savePrompts == nil, let window else { return }
    savePrompts = SavePromptPresenter(window: window) { [weak self] page in
      // This is the focused pane of this presenter's own window, including
      // Little Open. Sheet presentation changes key windows synchronously.
      guard let self, let content = self.standaloneSurface?.surfacePage ?? self.selectedContent else { return false }
      return page == AnyHashable(content.identifier)
    }
    #if OPEN_AUTOMATION
    savePrompts?.onPresent = { sheet in AutomationController.savePromptOwner?.savePromptDidPresent(sheet) }
    savePrompts?.onDiscard = { request in
      guard let prompt = request as? OESavePrompt else { return }
      AutomationController.savePromptOwner?.recordRealSavePrompt(prompt, answer: "ignored")
    }
    #endif
  }
  func savePromptFocusChanged() {
    savePrompts?.pageDidBecomeFocused(AnyHashable((standaloneSurface?.surfacePage ?? selectedContent)?.identifier ?? 0))
  }
  let model: BrowserModel
  let incognitoSession: IncognitoSession?
  /// Section 12's read-only private-state hook (lead ruling 16:12).
  var isIncognito: Bool { incognitoSession != nil }
  func scheduleSave() { if !isIncognito { app.scheduleSave() } }
  private lazy var privateSuggest: SuggestEngine = {
    let engine = SuggestEngine(model: model, historyStore: { _ in nil }, actions: CommandRegistry.makeSuggestRegistry())
    engine.providers.append(SettingsSuggestionsProvider())
    return engine
  }()
  func suggestEngine() -> SuggestEngine? {
    guard let profile = focusedProfile else { return nil }
    return isIncognito ? privateSuggest : app.stores.suggest(for: profile.id)
  }
  var contentContainer: NSView { controller!.container }
  private(set) var hosts: [ItemID: EngineWebContentHost] = [:]
  var welcomeHosts: [ItemID: WelcomeContentHost] = [:]
  /// Native Note pages (`open://note/<uuid>`), one per shown Note tab.
  var noteHosts: [ItemID: NoteContentHost] = [:]
  /// The last Export Note… destination (automation reads it).
  var lastNoteExport: String?
  var easelHosts: [ItemID: EaselContentHost] = [:]
  /// Easel row sheets (save as web page, delete) and the last export path (automation).
  var easelSavePanel: NSSavePanel?
  var easelDeleteAlert: NSAlert?
  var lastEaselExport: String?
  func queueWelcomeDestination(_ id: ItemID, url: URL) { queuedNavigations[id] = url }
  private var developerModeObserver: (any NSObjectProtocol)?
  /// Developer Mode's content panel buttons and network lists (App/Page/DeveloperModePanel.swift).
  lazy var developerPanel = DeveloperModePanel(factory: self)
  /// The Capture overlay is up in this window: history swipes pause (§4.4.1).
  private(set) var captureOverlayUp = false
  private var swipeActivationObserver: (any NSObjectProtocol)?
  private var modelHostIDs: Set<ItemID> = []
  private(set) var contentCreationCount = 0
  private var queuedNavigations: [ItemID: URL] = [:]
  private(set) var earlyHostRequestsRefused: Bool?
  private(set) var treeChangeCount = 0
  private(set) var mirrorSyncCount = 0
  var contents: [ItemID: OEWebContent] { hosts.filter { !$0.value.closed }.mapValues(\.content) }
  private lazy var mirror = TabStripMirror(owner: self)
  private var observerID: UUID?
  private(set) var commandBarSession: AppCommandBarSession?
  private var commandBarNavigationFocus: Set<ItemID> = []
  private var typedNavigationTabs: Set<ItemID> = []
  private(set) var isClosing = false
  var saveCaptureTasks: [UUID: Task<Void, Never>] = [:]
  var pendingSaveChoice: ((URL?) -> Void)?
  var findController: FindController?
  var findKeyRequestedAt: TimeInterval?
  var hasFindSelectionTask: Bool { findController?.hasSelectionTask == true }
  var pendingSpaceProfileAlert: NSAlert?
  var pendingRenameAlert: NSAlert?
  var iconPicker: IconPickerController?
  var iconPickerSpaceID: SpaceID?
  var sidebarSharePicker: NSSharingServicePicker?
  /// The copy toast whose Share picker is open: it stays until the picker closes (page-platform §4.2.2).
  var shareToastHandle: ToastHandle?
  /// Page-command engine work (selection reads for the quote offer and Copy URL as Quote).
  var pageTasks: [UUID: Task<Void, Never>] = [:]
  var spaceProfileMenu: NSMenu?
  #if OPEN_AUTOMATION
  var dismissSidebarShareForAutomation = false
  var sidebarShareRequest: [String: Any] = [:]
  /// The last Shared Quotes offer: how long the page took to answer, whether it showed.
  var lastQuoteOffer: [String: Any] = [:]
  /// The last Join Meeting outcome (`AutomationCalendar`).
  var lastJoinMeeting: [String: Any] = [:]
  var sidebarShareDismissTimerForAutomation: Timer?
  var sidebarShareDismissAttemptsForAutomation = 0
  var profileMenuResponseForAutomation: String?
  var profileMenuRequest: [String: Any] = [:]
  var sidebarMenuTrackingObserverForAutomation: NSObjectProtocol?
  #endif
  private(set) var navigationFocusDecisions = 0
  /// On-device page translation for this window (page-platform Step 10).
  private(set) lazy var translate = TranslateAdapter(factory: self)
  private(set) var lastNavigationFocusRestored = false
  /// `userInitiated`: Cmd+T / Cmd+L, the menu, or the sidebar; false when the App shows the bar by itself (a new window).
  func showCommandBar(_ mode: CommandBarMode, editingPinnedTab: ItemID? = nil, userInitiated: Bool = false) {
    guard !isClosing, !app.terminationRequested else { return }
    iconPicker?.close()
    let requestedAt = LaunchTiming.shared.elapsedMilliseconds
    app.prepareCommandServices()
    if commandBarSession == nil { commandBarSession = AppCommandBarSession(factory: self) }
    // A second Cmd+T while the New Tab bar is open, or a second Cmd+L while the address editor is
    // open, closes it (Arc 06-keys, 12c; plan D3 §2.3).
    if userInitiated, let session = commandBarSession, session.isPresented, session.openedByUser, editingPinnedTab == nil,
       session.pinnedEditTabID == nil, mode == .newTab || mode == .editCurrentURL, session.controller?.request?.mode == mode {
      session.dismiss(); return
    }
    commandBarSession?.show(mode, requestedAt: requestedAt, editingPinnedTab: editingPinnedTab, userInitiated: userInitiated)
  }
  /// Edit Pinned URL confirmed in the command bar (app-shell §4.1): the pinned URL changes; a tab that
  /// was still on its old pinned page also goes to the new one (guess: no capture of Arc's dialog).
  func updatePinnedURL(_ id: ItemID, to url: URL) {
    guard !WelcomeTab.isInternal(url) else { return }
    guard let tab = model.tab(id: id), let old = tab.pinnedURL else { return }
    let onPinnedPage = tab.url.host == old.host && tab.url.path == old.path
    guard model.setPinnedURL(id: id, url: url) else { return }
    if onPinnedPage {
      if let content = hosts[id]?.content { content.load(url) } else { tab.url = url }
    }
    controller?.refresh(); mirror.sync(); scheduleSave()
  }
  private var enteredWindowFullscreenForPage = false
  private(set) var auxiliaryPages: [AuxiliaryPage] = []
  var popupPanel: NSPanel? { extensions.popup.panel }
  private(set) lazy var extensions = WindowExtensions(factory: self)
  private(set) lazy var siteControlSource: AppSiteControlSource = {
    let source = AppSiteControlSource(factory: self)
    source.boostProvider = app.stores.boosts
    return source
  }()
  #if OPEN_AUTOMATION
  var siteControlDrawSamples: [Double] = []
  var siteControlDrawPhaseSamples: [[String: Double]] = []
  var siteControlDrawNativeProbeSamples: [[UInt64]] = []
  var popupCallbackClose: (phase: String, toggle: Bool)?
  func releaseBrowsersForAutomation() -> [String: Any] {
    extensions.releaseBrowserOwnershipForAutomation(); return mirror.releaseWithoutClosingForAutomation()
  }
  #endif

  var dialogPolicy: String?
  var permissionPolicy: String?
  var promptText: String?
  var contextMenuPolicy: String?
  var pageContextMenu: PageContextMenuBuilder?
  lazy var pageContextMenuHooks = PageContextMenuHooks { [weak self] in
    _ = self?.performAppCommand("manage-extensions")
  }
  var fullscreenPolicy: String?
  var pendingSavePanel: NSSavePanel?
  var savePageRequestCount = 0
  private lazy var privateDownloads = IncognitoDownloads()
  var downloadDirectory: URL?
  private(set) var events: [[String: Any]] = []
  var recordedOpenWorldMessages: [[String: Any]] = []
  private(set) var lastFindResult: OEFindResult?
  func standaloneSurfaceVisibilityChanged() {
    // Setting even the same window re-enters Chromium's SetHostView path.
    // Window geometry follows the page view's existing native observers.
    if let browser = standaloneBrowser, browser.window !== standaloneSurface?.surfaceWindow {
      browser.window = standaloneSurface?.surfaceWindow
    }
    pageChrome.visibilityChanged()
    attachSavePrompts(); savePromptFocusChanged()
  }

  lazy var pageChrome = PageChromeCoordinator(owner: self)
  var pendingDialogs: [OEJavaScriptDialog] { pageChrome.dialogs.pendingDialogs }

  /// A Blank Window (App/BlankWindow.swift): its own in-memory model with one Space, a real Profile's data.
  let isBlankWindow: Bool
  init(app: AppDelegate, state: BrowserWindowState, model: BrowserModel? = nil, incognitoSession: IncognitoSession? = nil, blankWindow: Bool = false) {
    isBlankWindow = blankWindow
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("factory.create")
    defer { pacingRegion?.end() }
    #endif
    self.app = app; windowState = state; self.model = model ?? app.model
    self.incognitoSession = incognitoSession
    super.init()
    WelcomeTab.restoreIcons(in: self.model)
    NoteTab.restoreIcons(in: self.model)
    EaselTab.restoreIcons(in: self.model)
    observerID = self.model.addObserver { [weak self] change in self?.treeChanged(change) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { if let observerID { model.removeObserver(observerID) } }

  func attachLittleOpen(_ controller: LittleOpenWindowController, content: OEWebContent) {
    // Section 9 owns creation and closing. Never synthesize a browser here or
    // borrow a main window's active tab while the first frame is pending.
    guard let browser = standaloneBrowser, content.browser === browser else { return }
    guard littleOpenController !== controller || littleOpenContent !== content || littleOpenBrowser !== browser else { return }
    if let previous = littleOpenBrowser, previous !== browser {
      extensions.closeAll()
      if previous.delegate === self { previous.delegate = nil }
    }
    littleOpenController = controller; littleOpenContent = content
    attachSavePrompts()
    littleOpenBrowser = browser; browser.window = controller.window; browser.delegate = self
    controller.onCloseRequested = { [weak self] in
      self?.savePrompts?.cancelAll()
      guard let self, let window = self.window else { return }; self.app.extensionPrompts.cancel(window: window)
    }
    controller.extensionsUI = extensions.context
    extensions.attach()
    controller.titleBar.onExtensions = { [weak self, weak controller] in
      guard let controller else { return }; self?.extensions.showLittleOpenMenu(controller)
    }
    // A Profile without a Space keeps management pages in Little Open (S10 guess).
    extensions.context.manageExtensions = { [weak self] in self?.performLittleOpenExtensionManagement("manage-extensions") }
    extensions.context.addExtension = { [weak self] in self?.performLittleOpenExtensionManagement("add-extension") }
  }
  func performLittleOpenExtensionManagement(_ command: String) {
    guard let profile = littleOpenController?.session.profileID else { return }
    guard let space = model.mostRecentlyFocusedSpace(profileID: profile) else {
      let address = command == "add-extension" ? "https://chromewebstore.google.com/category/extensions" : command == "extension-shortcuts" ? "chrome://extensions/shortcuts" : "chrome://extensions"
      app.openProfilePage(URL(string:address)!,profileID:profile); return
    }
    guard
          let controller = app.windowControllers.first(where: { app.hostFactories[$0.windowID]?.focusedProfile?.id == profile })
            ?? app.makeWindow(focusedSpaceID: space.id), let factory = app.hostFactories[controller.windowID] else { return }
    app.focusWindow(controller.windowID, activate: true); _ = factory.performAppCommand(command)
  }

  func attach(_ controller: BrowserWindowController) {
    self.controller = controller
    attachSavePrompts()
    controller.shouldDeferKeyToFirstResponder = { [weak self] event in
      if let picker = self?.iconPicker, event.window === picker.panel || event.window === picker.toneWindow {
        return event.modifierFlags.intersection([.command, .control]).isEmpty
      }
      guard let self, event.window === self.window, self.findController?.owns(self.window?.firstResponder) == true,
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
      return [36, 76, 53, 125, 126].contains(event.keyCode)
    }
    controller.onTextUndoManager = { [weak self] window in
      self?.commandBarSession?.controller?.editingUndoManager(for: window.firstResponder)
    }
    controller.onSpaceCreationIcon = { [weak self] current, anchor, onPick in
      self?.openDraftSpaceIconPicker(current: current, anchor: anchor, onPick: onPick)
    }
    controller.onExitPageFullscreen = { [weak self] in
      guard let page = self?.selectedContent else { return false }
      do { try page.exitFullscreen(); return true }
      catch { return false }
    }
    controller.keyBindingOverrides = app.keyBindings
    let previousLinkPolicy = controller.container.onLinkClicked
    controller.container.onLinkClicked = { [weak self] id, url, flags in
      guard let self else { return false }
      if flags.contains([.command, .option]) {
        if UserDefaults.standard.object(forKey: "open.links.optionCommandClickLittleOpen") as? Bool ?? true {
          if self.isIncognito { self.openNewTab(url: url, background: false, opener: id) }
          else { self.app.openLittleOpen(url: url, profileHint: self.profile(for: id)?.id ?? self.focusedProfile?.id) }
        } else {
          // The toggle-off contract is in-place navigation, including engines
          // that classify this modifier pair as a new-tab/download request.
          DispatchQueue.main.async { [weak self] in self?.hosts[id]?.load(url) }
        }
        return false
      }
      return previousLinkPolicy?(id, url, flags) ?? true
    }
    controller.isApplicationActive = { [weak self] in NSApp.isActive || self?.window?.isKeyWindow == true }
    controller.ownsAdditionalKeyWindow = { [weak self] in self?.ownsKeyWindow($0) == true }
    extensions.attach()
    extensions.siteControl = controller.siteControl
    #if OPEN_AUTOMATION
    controller.siteControl?.onFirstDraw = { [weak self] ms in
      guard let self else { return }
      self.siteControlDrawSamples.append(ms)
      self.siteControlDrawNativeProbeSamples.append(siteControlNativeDrawProbe())
      if self.siteControlDrawSamples.count > 128 {
        self.siteControlDrawSamples.removeFirst(); self.siteControlDrawNativeProbeSamples.removeFirst()
      }
    }
    controller.siteControl?.onFirstDrawPhases = { [weak self] phases in
      guard let self else { return }
      self.siteControlDrawPhaseSamples.append(phases)
      if self.siteControlDrawPhaseSamples.count > 128 { self.siteControlDrawPhaseSamples.removeFirst() }
    }
    #endif
    pageChrome.permissionAnchorProvider = { [weak self] page in
      guard let self, let id = self.tabID(for: page), let anchor = self.controller?.visibleSiteControlAnchor(tabID: id) else { return nil }
      return PermissionPromptPresenter.Anchor(view: anchor, rect: anchor.bounds)
    }
    controller.onCloseRequested = { [weak self] in
      self?.savePrompts?.cancelAll()
      guard let self, let window = self.window else { return }
      self.app.extensionPrompts.cancel(window: window)
    }
    controller.onExtensionShortcut = { [weak self] event in
      guard let self, let browser = self.focusedBrowser else { return false }
      return self.app.extensionPrompts.table(browser.context.extensions).handle(event, factory: self)
    }
    controller.onCommand = { [weak self] in self?.performAppCommand($0) == true }
    controller.onCommandWithPayload = { [weak self] in self?.performAppCommand($0, payload: $1) == true }
    controller.onCommandValidation = { [weak self] id, key in
      guard !AppCommand.featureIDs.contains(id), !id.hasPrefix("focus-split-pane-") else { return nil }
      return self?.isAppCommandEnabled(id, enabledKey: key) ?? false
    }
    controller.onMenuState = { [weak self] in self?.pageMenuState(for: $0) }  // checkmarks, Cast hidden, Developer Mode title (page-platform §7.1)
    // Developer Mode sites show their full URL in the URL field (§4.10.3).
    controller.context.canCustomizePage = { [weak self] in self?.canCustomizePage($0) == true }
    controller.context.developerModeHosts = DeveloperMode.hosts
    developerPanel.attach(controller.container)
    developerModeObserver = NotificationCenter.default.addObserver(forName: DeveloperMode.didChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let controller = self.controller else { return }
        controller.context.developerModeHosts = DeveloperMode.hosts
        self.developerPanel.hostsChanged()
        self.app.scheduleMenuRebuild()
      }
    }
    controller.onLayout = { [weak self] in self?.findController?.sync() }
    controller.captureLibrary = app.captureLibrary
    controller.captureWallpaperData = { [weak controller] in await PortraitWallpaper.read(screen: controller?.window?.screen) }
    if !isIncognito { controller.captureAddToEasel = { [weak self] result, anchor in self?.showAddToEaselMenu(result, anchor: anchor) } }
    controller.onFocus = { [weak self] in guard let self else { return }; self.app.didFocusWindow(self.windowState.id) }
    controller.nextResponder = self; nextResponder = NSApp
    controller.onSidebarIntent = { [weak self] intent in guard let self else { return false }; return self.performSidebar(intent) }
    controller.showsFullURLWithToolbar = UserDefaults.standard.bool(forKey: AppCommand.showFullURLKey)
    controller.onStateChange = { [weak self] in
      guard let self else { return }
      self.app.stores.boosts.existingEditorHost?.selectionChanged(in: self)
      if let id = self.iconPickerSpaceID, self.focusedSpace?.id != id { self.iconPicker?.close() }
      if self.app.engineReady { self.markVisibleTabsLive(); self.controller?.container.refreshPlaceholders() }
      // BrowserWindowController schedules its SnapshotStore once per committed change.
      self.mirror.sync(); self.extensions.focusChanged(); self.commandBarSession?.contextDidChange(); self.app.scheduleMenuRebuild()
      self.app.media.windowChanged(self)
      self.translate.focusDidChange()
      self.findController?.sync()
      self.pageChrome.visibilityChanged()
      self.savePromptFocusChanged()
    }
    // History swipes (page-platform §4.4.1): macOS's "Swipe between pages" setting, re-read when
    // Open becomes active, and paused while the Capture overlay is up.
    controller.onCaptureOverlayChange = { [weak self] up in self?.captureOverlayUp = up; self?.syncHistorySwipe() }
    swipeActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncHistorySwipe() }
    }
    // Chained: MediaCoordinator.attach wraps this hook later and keeps it.
    let previousVisibility = controller.onVisibilityChange
    controller.onVisibilityChange = { [weak self] in previousVisibility?(); self?.translate.visibilityDidChange(); self?.pageChrome.visibilityChanged(); self?.extensions.sidebarVisibilityChanged(); self?.savePromptFocusChanged() }
    controller.onOpenCommandBar = { [weak self] source, _ in
      if source == .urlField { self?.focusAddressBar(nil) } else { self?.newTab(nil) }
    }
    controller.onClose = { [weak self] in
      guard let self else { return }; self.closeAll(); self.app.windowDidClose(self.windowState.id)
    }
  }
  func engineDidBecomeReady() {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("factory.engineDidBecomeReady")
    defer { pacingRegion?.end() }
    #endif
    for (id, url) in queuedNavigations { model.tab(id: id)?.url = url }
    queuedNavigations.removeAll()
    showSelection(focus: false)
  }
  #if OPEN_AUTOMATION
  func navigateBeforeEngineForAutomation(_ input: String) {
    if !app.engineReady, let tab = selectedTab, let profile = focusedProfile {
      let before = contentCreationCount
      earlyHostRequestsRefused = context(for: profile.id) == nil && ensureContent(for: tab) == nil
        && makeHost(tabID: tab.id, profileID: profile.id, url: nil) == nil && contentCreationCount == before
    }
    if let url = Self.url(forInput: input, profile: focusedProfile) { navigateFromCommandBar(url, current: true) }
  }
  #endif

  var focusedSpace: Space? { model.space(id: windowState.focusedSpaceID) ?? model.spaces.first }
  var focusedProfile: Profile? { littleOpenController.flatMap { model.profile(id: $0.session.profileID) } ?? focusedSpace.flatMap { model.profile(id: $0.profileID) } }
  var selectedNodeID: ItemID? { focusedSpace.flatMap { windowState.selectedNodeBySpace[$0.id] } }
  var selectedTab: Tab? { controller?.splitController.focusedTab ?? littleOpenController?.session.tab }
  var visibleTabs: [Tab] { controller?.splitController.split?.panes ?? selectedTab.map { [$0] } ?? [] }
  var selectedContent: OEWebContent? {
    if let controller, controller.hasPeekController, controller.peekController.isShown {
      return (controller.peekController.stack.last?.host as? EngineWebContentHost)?.content
    }
    return littleOpenContent ?? selectedTab.flatMap { hosts[$0.id]?.content }
  }
  var orderedTabs: [Tab] {
    (focusedProfile?.favorites ?? []) + (focusedSpace.map { flattened($0.pinned) + flattened($0.today) } ?? [])
  }
  /// Cmd+1…9 numbering: the model's one query (commandbar-completion §4.4.1, `goToItemTargets`). Include
  /// Favorites defaults on; "Switch to ninth tab" defaults off, so Cmd+9 is the last item.
  private var includeFavoritesInNumbering: Bool {
    UserDefaults.standard.object(forKey: "open.shortcuts.includeFavoritesInTabNumbering") as? Bool ?? true
  }
  /// Every numbered item (tab or split ids), for the Tabs menu and Go to Last Tab.
  var numberedItems: [ItemID] { model.goToItemCandidates(windowID: windowState.id, includeFavorites: includeFavoritesInNumbering) }
  func numberedItem(_ number: Int) -> ItemID? {
    guard (1...9).contains(number) else { return nil }
    return model.goToItemTargets(windowID: windowState.id, includeFavorites: includeFavoritesInNumbering,
                                 ninthSelectsLast: !UserDefaults.standard.bool(forKey: "open.shortcuts.switchToNinthEnabled"))[number - 1]
  }
  /// A numbered item's menu title: the tab title, or a split's pane titles.
  func numberedTitle(_ id: ItemID) -> String {
    func title(_ tab: Tab) -> String { tab.displayTitle.isEmpty ? tab.url.absoluteString : tab.displayTitle }
    if let tab = model.tab(id: id) { return title(tab) }
    if case .split(let split)? = model.node(id: id) { return split.panes.map(title).joined(separator: " | ") }
    return ""
  }
  /// Selects a numbered item: a tab, or a split (its focused pane).
  func selectNumberedItem(_ id: ItemID) {
    if case .split(let split)? = model.node(id: id), let pane = split.panes.first(where: { $0.id == split.focusedPaneID }) ?? split.panes.first {
      selectTabForCommand(pane.id)
    } else {
      selectTabForCommand(id)
    }
  }
  func flattened(_ nodes: [SidebarNode]) -> [Tab] {
    nodes.flatMap { node in
      switch node { case .tab(let tab): [tab]; case .folder(let folder): flattened(folder.children); case .split(let split): split.panes }
    }
  }
  /// A profile's tabs in tab-strip order: favorites, then every Space's
  /// pinned tabs, then every Space's Today tabs, in Space order (Chromium
  /// keeps one pinned prefix, so chrome.tabs indexes match this order).
  func tabs(in profileID: ProfileID) -> [Tab] {
    let spaces = model.spaces.filter { $0.profileID == profileID }
    return (model.profile(id: profileID)?.favorites ?? []) + spaces.flatMap { flattened($0.pinned) }
      + spaces.flatMap { flattened($0.today) }
  }
  func space(for tabID: ItemID) -> Space? {
    model.spaces.first { (flattened($0.pinned) + flattened($0.today)).contains { $0.id == tabID } }
  }
  func profile(for tabID: ItemID) -> Profile? {
    if let space = space(for: tabID) { return model.profile(id: space.profileID) }
    return model.profiles.first { $0.favorites.contains { $0.id == tabID } }
  }
  func profile(for context: OEBrowserContext) -> Profile? {
    isIncognito ? (context === incognitoSession?.context ? model.profiles.first : nil)
      : (context === OEEngine.shared.defaultContext ? model.defaultProfile : model.profiles.first { $0.dataDirectoryName == context.identifier })
  }
  func context(for profileID: ProfileID, create: Bool = true) -> OEBrowserContext? {
    guard app.engineReady, let profile = model.profile(id: profileID) else { return nil }
    if isIncognito {
      guard let context = incognitoSession?.context else { return nil }
      app.extensionPrompts.register(context.extensions)
      return WebsiteAppearance.prepare(context)
    }
    if !create {
      return OEEngine.shared.contexts.first { $0.identifier == profile.dataDirectoryName }
    }
    // Website appearance is app-wide (page-platform §4.8): every context gets it at creation.
    if profile.id == model.defaultProfile?.id {
      return Self.createRegularContext(profileID: profileID, directory: profile.dataDirectoryName, app: app)
    }
    guard app.engine.result.layout == .engine else {
      // The old layout has no disk folder for other profiles (CEF refused
      // Profiles/<dir>/Engine). Their pages wait for the next launch, whose
      // migration retries; they never run in a memory-only profile.
      if Self.legacyRefusals.insert(profile.dataDirectoryName).inserted {
        FileHandle.standardError.write(Data(
          "Open: profile \(profile.dataDirectoryName) unavailable this launch (engine data still in the old layout)\n".utf8))
      }
      return nil
    }
    return Self.createRegularContext(profileID: profileID, directory: profile.dataDirectoryName, app: app)
  }
  /// Explicit action path for a page, private session, or ordered deletion.
  /// Read-only inspection must use context(for:create: false) instead.
  static func createRegularContext(profileID: ProfileID, directory: String, app: AppDelegate) -> OEBrowserContext? {
    #if OPEN_AUTOMATION
    let pacingRegion = IntroPacingTrace.begin("profile.context.create")
    defer { pacingRegion?.end() }
    #endif
    guard app.engineReady else { return nil }
    let context: OEBrowserContext?
    if profileID == app.model.defaultProfile?.id {
      context = OEEngine.shared.defaultContext
    } else {
      guard app.engine.result.layout == .engine else { return nil }
      context = OEEngine.shared.context(identifier: directory,
        directory: app.directories.engineDirectory(dataDirectoryName: directory))
    }
    guard let context, context.state == .live else { return nil }
    app.profileTeardown.didLoad(profileID: profileID, directory: directory)
    app.adBlockEngineAdapter.contextCreated(context, profileID: profileID)
    app.extensionPrompts.register(context.extensions)
    app.stores.boosts.adapter.record(context, profile: profileID)
    return WebsiteAppearance.prepare(context)
  }
  func retireProfile(_ id: ProfileID, directory: String) {
    for (tab, host) in hosts where host.content.context.identifier == directory {
      host.close(); hosts.removeValue(forKey:tab); modelHostIDs.remove(tab); queuedNavigations.removeValue(forKey:tab)
    }
    mirror.retireProfile(id)
  }
  private static var legacyRefusals: Set<String> = []
  var focusedBrowser: OEBrowser? {
    focusedBrowser(create: false)
  }
  /// A real focus change may attach this window to an already loaded Profile.
  /// This never creates a request context for an empty, unvisited Profile.
  func prepareFocusedExtensionBrowser() -> OEBrowser? {
    if standaloneBrowser != nil || littleOpenController != nil || standaloneSurface != nil { return focusedBrowser }
    guard app.engineReady, let profile = focusedProfile else { return nil }
    return mirror.browser(for: profile.id, loadContext: false)
  }
  /// Focus, menu validation and read-only automation must not load a Profile.
  /// Explicit extension interactions opt in; focus attaches loaded contexts separately.
  func focusedBrowser(create: Bool) -> OEBrowser? {
    if let standaloneBrowser { return standaloneBrowser }
    if littleOpenController != nil || standaloneSurface != nil { return nil }
    guard app.engineReady, let profile = focusedProfile else { return nil }
    let browser = mirror.browser(for: profile.id, create: create)
    if create { extensions.focusChanged() }
    return browser
  }
  func tabID(for content: OEWebContent) -> ItemID? { hosts.first { $0.value.content === content }?.key }
  private func withoutUndo(_ body: () -> Void) {
    let undo = model.undoManager; undo?.disableUndoRegistration(); defer { undo?.enableUndoRegistration() }; body()
  }

  func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> (any WebContentHost)? {
    makeHost(tabID: tabID, profileID: profileID, url: url, history: nil)
  }
  /// `history`: a sleeping tab's stored back/forward list (memory-fork §5.2–§5.3). The page is
  /// created without a renderer and gets the history before it is shown; it loads the current
  /// entry when it shows, or `url` (the fallback) if the engine refuses the history.
  func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?, history: OENavigationHistory?, browser: OEBrowser? = nil) -> (any WebContentHost)? {
    if WelcomeTab.matches(url ?? model.tab(id: tabID)?.url) {
      if let host = welcomeHosts[tabID], !host.closed { return host }
      let host = WelcomeContentHost(tabID: tabID, owner: self)
      welcomeHosts[tabID] = host
      return host
    }
    if let noteID = NoteLink.id(from: url ?? model.tab(id: tabID)?.url), !isIncognito {
      if let host = noteHosts[tabID], !host.closed, host.noteID == noteID { return host }
      let host = NoteContentHost(tabID: tabID, noteID: noteID, store: app.notes, owner: self)
      noteHosts[tabID] = host
      return host
    }
    if let document = EaselTab.documentID(url ?? model.tab(id: tabID)?.url) {
      if let host = easelHosts[tabID], !host.closed { return host }
      let host = EaselContentHost(tabID: tabID, documentID: document, owner: self)
      easelHosts[tabID] = host
      return host
    }
    // No internal URL (including an unknown open:// route) reaches OpenEngine.
    if let target = url ?? model.tab(id: tabID)?.url, WelcomeTab.isInternal(target) { return nil }
    guard let context = context(for: profileID) else {
      if let url, model.tab(id: tabID) != nil { queuedNavigations[tabID] = url }
      return nil
    }
    if let host = hosts[tabID], !host.closed { return host }
    // Synchronous before OEWebContent creation, including restored tabs. This
    // preserves the first document's document-start scripts without delaying
    // the snapshot-backed sidebar or loading Boosts merely for a context.
    if !isIncognito && !context.isEphemeral { app.stores.boosts.adapter.prepare(context, profile: profileID) }
    let config = OEWebContentConfiguration(context: context)
    // Sidebar and Little Open pages attach to a hidden Chrome window (P1).
    // Other non-model hosts (Peek) remain Alloy.
    let isModelTab = model.tab(id: tabID) != nil
    if isModelTab { app.noteLaunchWindowNavigation(windowState.id) }
    config.runtimeStyle = browser != nil ? .chrome : (isModelTab ? app.options.defaultStyle : .alloy)
    config.showsChromeToolbar = app.options.chromeToolbar
    if isModelTab, model.tab(id: tabID)?.url.scheme == "chrome" { config.runtimeStyle = .chrome }
    contentCreationCount += 1
    let content = history.map { OEWebContent(configuration: config, navigationHistory: $0, fallbackURL: url) }
      ?? OEWebContent(configuration: config, url: nil)
    content.isMuted = model.tab(id: tabID)?.isMuted ?? false
    content.view.isHidden = true
    let host = EngineWebContentHost(tabID: tabID, profileID: profileID, content: content, owner: self)
    hosts[tabID] = host
    if let browser {
      // Hosted Chrome creation is synchronous. Seed an already submitted URL
      // before insertion, so it creates the target instead of navigating a
      // throwaway about:blank page first (deferred Little Open).
      if let url, history == nil { host.load(url) }
      browser.insert(content, at: 0)
      browser.activeWebContent = content
    }
    if typedNavigationTabs.remove(tabID) != nil { host.historyRecorder.markTyped() }
    if model.tab(id: tabID) != nil { modelHostIDs.insert(tabID) }
    mirror.sync()
    if let url, history == nil, browser == nil { host.load(url) }
    app.tabSleep.contentCreated(tabID: tabID, host: host)
    return host
  }
  func hostDidClose(_ host: EngineWebContentHost) {
    app.stores.boosts.hostClosed(host)
    savePrompts?.pageDidClose(AnyHashable(host.content.identifier))
    pageChrome.cancel(host.content)
    if pageContextMenu?.belongs(to: host.content) == true { pageContextMenu?.cancel(); pageContextMenu = nil }
    translate.contentDidClose(host.content)
    findController?.hostClosed(host.tabID)
    commandBarNavigationFocus.remove(host.tabID)
    typedNavigationTabs.remove(host.tabID)
    developerPanel.forget(host.tabID)
    app.media.hostClosed(tabID: host.tabID)
    if hosts[host.tabID] === host { hosts[host.tabID] = nil }
    modelHostIDs.remove(host.tabID)
    mirror.sync()
    app.tabSleep.hostClosed(tabID: host.tabID)
  }
  func adoptHost(_ host: any WebContentHost, as tabID: ItemID) -> Bool {
    if let native = host as? WelcomeContentHost {
      return native.owner === self && native.tabID == tabID && !native.closed
    }
    if let native = host as? NoteContentHost {
      return native.owner === self && native.tabID == tabID && !native.closed
    }
    // An Easel host coming back from a hover preview or the hidden cache keeps its canvas
    // (undo history, live cards); refusing it would close and rebuild the Easel.
    if let native = host as? EaselContentHost {
      return native.owner === self && native.tabID == tabID && !native.closed
    }
    guard let host = host as? EngineWebContentHost, host.owner === self, !host.closed,
          profile(for: tabID)?.id == host.profileID else { return false }
    // Sidebar tabs are tabs of the window's hidden Chrome window (fork patch
    // P1); a Peek page is Alloy. The M4 Q5 fallback restores the browser's
    // own history (including saved scroll/form state) in a Chrome host.
    // The container closes the old host after this callback returns.
    if model.tab(id: tabID) != nil, host.content.runtimeStyle != app.options.defaultStyle {
      _ = makeHost(tabID: tabID, profileID: host.profileID, url: host.currentURL,
                   history: host.content.captureNavigationHistory())
      return false
    }
    if host.tabID != tabID {
      let oldID = host.tabID
      if let previous = hosts[tabID], previous !== host { controller?.container.closeHost(for: tabID); previous.close() }
      if hosts[oldID] === host { hosts[oldID] = nil }
      modelHostIDs.remove(oldID)
      host.rebind(tabID: tabID, spaceID: space(for: tabID)?.id)
      hosts[tabID] = host; modelHostIDs.insert(tabID)
      app.tabSleep.contentCreated(tabID: tabID, host: host)
    }
    mirror.sync(); return true
  }
  func didSyncMirror() { mirrorSyncCount += 1 }
  /// A cross-model move commits the real engine owner before either model's
  /// tree observers run. Refusal keeps the existing reload path available.
  func transferLiveTab(_ id: ItemID, from source: EngineWebContentHostFactory,
                       to parent: NodeParent, at index: Int) -> Bool {
    #if OPEN_ENGINE_WEB_CONTENT_TRANSFER
    guard source !== self, !isClosing, !source.isClosing, !isIncognito, !source.isIncognito,
      let sourceController = source.controller, let controller,
      let host = source.hosts[id], !host.closed, host.content.isLive,
      sourceController.container.host(for: id) === host, hosts[id] == nil,
      let from = source.mirror.browser(for: host.profileID, create: false),
      let to = mirror.browser(for: host.profileID), from.context === to.context,
      from.webContents.contains(where: { $0 === host.content }) else { return false }
    return model.transferTab(id: id, from: source.model, to: parent, at: index) {
      let position = tabs(in: host.profileID).prefix { $0.id != id }.filter { hosts[$0.id] != nil }.count
      guard to.transfer(host.content, from: from, at: UInt(position)) else { return false }
      // Engine guarantees no synchronous lifecycle callbacks. All shell owners
      // change in this same main-actor turn; no close or load is performed.
      _ = sourceController.container.takeHost(for: id)
      host.view.removeFromSuperview()
      source.savePrompts?.pageDidClose(AnyHashable(host.content.identifier))
      source.pageChrome.cancel(host.content)
      if source.pageContextMenu?.belongs(to: host.content) == true { source.pageContextMenu?.cancel(); source.pageContextMenu = nil }
      source.translate.contentDidClose(host.content); source.findController?.hostClosed(id)
      source.commandBarNavigationFocus.remove(id); source.typedNavigationTabs.remove(id)
      source.developerPanel.forget(id)
      source.hosts[id] = nil; source.modelHostIDs.remove(id); source.queuedNavigations[id] = nil
      host.owner = self; hosts[id] = host; modelHostIDs.insert(id)
      host.content.historySwipeEnabled = historySwipeAllowed
      host.rebind(tabID: id, spaceID: space(for: id)?.id)
      controller.container.adopt(host, for: id)
      app.tabSleep.contentCreated(tabID: id, host: host)
      return true
    }
    #else
    return false
    #endif
  }
  func remainingLiveState(for tabID: ItemID) -> WebContentLiveState? {
    app.hostFactories.values.compactMap { $0.hosts[tabID] }.first { !$0.closed }?.liveState
  }
  func tabStripState() -> [[String: Any]] { mirror.snapshot() }
  @discardableResult
  func ensureContent(for tab: Tab, history: OENavigationHistory? = nil) -> OEWebContent? {
    guard !WelcomeTab.isInternal(tab.url) else { return nil }
    guard app.engineReady else { queuedNavigations[tab.id] = tab.url; return nil }
    if let host = hosts[tab.id] { return host.content }
    guard let profileID = profile(for: tab.id)?.id else { return nil }
    tab.live.sleepPhase = .live
    guard let host = makeHost(tabID: tab.id, profileID: profileID, url: history == nil ? nil : tab.url, history: history)
      as? EngineWebContentHost else { return nil }
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    if history == nil { host.load(tab.url) }
    return host.content
  }
  private func makeContent(for tab: Tab, url: URL?, requestContext: OEBrowserContext? = nil) -> OEWebContent? {
    guard !WelcomeTab.isInternal(url ?? tab.url) else { return nil }
    guard app.engineReady else { queuedNavigations[tab.id] = url ?? tab.url; return nil }
    guard let profile = profile(for: tab.id) ?? requestContext.flatMap({ self.profile(for: $0) }) else { return nil }
    tab.live.sleepPhase = .live
    guard let host = makeHost(tabID: tab.id, profileID: profile.id, url: nil) as? EngineWebContentHost else { return nil }
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    if let url { host.load(url) }; mirror.sync(); return host.content
  }
  private func dropContent(id: ItemID, content: OEWebContent) { controller?.container.closeHost(for: id); hosts[id]?.close() }
  private func treeChanged(_ change: TreeChange) {
    guard !isClosing, !app.shutdownPrepared else { return }
    treeChangeCount += 1
    for (id, host) in welcomeHosts {
      if model.tab(id: id) == nil { controller?.container.closeHost(for: id); host.close() }
      else { host.page.updateColors() }
    }
    for (id, host) in noteHosts where model.tab(id: id).map({ NoteLink.id(from: $0.url) != host.noteID }) ?? true {
      controller?.container.closeHost(for: id); host.close()
    }
    for (id, host) in easelHosts where model.tab(id: id).map({ EaselTab.documentID($0.url) != host.documentID }) ?? true {
      controller?.container.closeHost(for: id); host.close()
    }
    if let id = iconPickerSpaceID, focusedSpace?.id != id || model.space(id: id) == nil { iconPicker?.close() }
    if case .spaceProfileChanged(let spaceID, _, _) = change, let space = model.space(id: spaceID) {
      let ids = Set((flattened(space.pinned) + flattened(space.today)).map(\.id))
      if let controller, controller.hasPeekController,
         controller.peekController.stack.contains(where: { ids.contains($0.sourceTabID) || ($0.host as? EngineWebContentHost)?.spaceID == spaceID }) { controller.peekController.dismissAll() }
      for (id, host) in hosts where ids.contains(id) || (model.tab(id: id) == nil && host.spaceID == spaceID) {
        controller?.container.closeHost(for: id); host.close()
      }
      for id in ids { controller?.container.resetLiveState(for: id, includingFavicon: true) }
    }
    // Peek hosts are transient until expanded into the model. A sidebar
    // mutation must not close them merely because they have no model row.
    modelHostIDs.formUnion(hosts.keys.filter { model.tab(id: $0) != nil })
    for (id, host) in hosts where modelHostIDs.contains(id) && (model.tab(id: id) == nil || !tabs(in: host.profileID).contains(where: { $0.id == id })) {
      controller?.container.closeHost(for: id); host.close()
    }
    if let id = selectedNodeID, model.node(id: id) == nil, let space = focusedSpace {
      withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nil) }
    }
    if case .spaceProfileChanged(let id, _, _) = change, focusedSpace?.id == id { showSelection(focus: false) }
    else { controller?.refresh(); mirror.sync() }
  }
  /// Shown tabs become live; the sleep controller wakes the ones it put to sleep (or can restore
  /// from a stored back list), so their wake kind and history are right (memory-fork §9.4).
  func markVisibleTabsLive() {
    for tab in visibleTabs {
      if WelcomeTab.matches(tab.url) || NoteTab.matches(tab.url) || EaselTab.matches(tab.url) { tab.live.sleepPhase = .live; continue }
      if app.tabSleep.wakesThroughController(tab, hasHost: hosts[tab.id].map { !$0.closed } ?? false) { app.tabSleep.wake(tab.id) }
      else { tab.live.sleepPhase = .live }
    }
  }
  func showSelection(focus: Bool = true) {
    guard let controller else { return }
    app.stores.boosts.existingEditorHost?.selectionChanged(in: self)
    if app.engineReady { markVisibleTabsLive() }
    controller.refresh(); mirror.sync(); extensions.focusChanged()
    window?.title = selectedTab?.displayTitle.isEmpty == false ? selectedTab!.displayTitle : (isIncognito ? "Incognito" : isBlankWindow ? (focusedSpace.map { model.displayTitle(for: $0) } ?? "Open") : "Open")
    // An open command bar keeps the keyboard (Cmd+Return adds a background tab, plan D3 §2.3). When the
    // selection itself changed, contextDidChange closes the bar and its dismissal restores page focus.
    if focus, commandBarSession?.isPresented != true {
      if let id = selectedTab?.id, let native = welcomeHosts[id] { native.focus() }
      else if let id = selectedTab?.id, let note = noteHosts[id] { note.updateAppearance(); note.focus() }
      else if let id = selectedTab?.id, let easel = easelHosts[id] { easel.focus() }
      else { selectedContent?.focusPage() }
    }
    commandBarSession?.contextDidChange(); app.scheduleMenuRebuild()
    findController?.sync()
    savePromptFocusChanged()
    // Auto-PiP runs in the same turn as the selection change, after the new tab is attached (§4.5.3).
    app.media.windowChanged(self)
  }
  func select(nodeID: ItemID?, focus: Bool = true) {
    controller?.existingTabSwitcher?.cancel()
    guard let space = focusedSpace else { return }
    withoutUndo { model.selectNode(windowID: windowState.id, spaceID: space.id, nodeID: nodeID) }
    controller?.dismissSidebarReveal()
    showSelection(focus: focus); scheduleSave()
  }
  @discardableResult
  func openNewTab(url: URL, background: Bool, opener: ItemID? = nil, typed: Bool = false) -> Tab? {
    guard let space = focusedSpace else { return nil }
    // Lead Q11: a tab opened in the background is unread until it is selected.
    let tab = model.newTab(in: space.id, url: url, at: 0, unread: background); tab.openerID = opener
    if typed { typedNavigationTabs.insert(tab.id) }
    if !background { select(nodeID: tab.id) }
    scheduleSave(); return tab
  }
  func adoptUnownedRequest(_ request: OEOpenRequest) -> OEWebContent? {
    guard app.engineReady else { return nil }
    guard let profile = profile(for: request.context),
      let space = focusedSpace.flatMap({ $0.profileID == profile.id ? $0 : nil }) ?? model.spaces.first(where: { $0.profileID == profile.id }) else { return nil }
    let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0)
    let content = makeContent(for: tab, url: nil, requestContext: request.context); focus(space: space); select(nodeID: tab.id); return content
  }
  func focus(space: Space) {
    if let id = iconPickerSpaceID, id != space.id { iconPicker?.close() }
    controller?.existingTabSwitcher?.cancel()
    withoutUndo { model.focusSpace(windowID: windowState.id, spaceID: space.id) }
    controller?.dismissSidebarReveal(); showSelection(); scheduleSave()
    // Live Folder refresh on Space focus (live-data §2.5; throttled 10 s in the service).
    if !isIncognito, model.liveFolder(in: space.id) != nil { app.liveFolders.spaceFocused(space.id) }
  }

  /// Only model-only cases fall back to the package. Unsupported later-step
  /// editors return false, so no successful no-op reaches the sidebar.
  func performSidebar(_ intent: SidebarIntent) -> Bool? {
    if isIncognito {
      switch intent {
      case .newSpace, .newFolder, .manageSpaces, .showLibrary, .setPinnedCollapsed,
           .selectFavorite, .openProfileSettings, .dismissAutoArchiveBanner,
           .pin, .unpin, .setPinned, .resetToPinnedURL, .replacePinnedURL, .editPinnedURL,
           .newNestedFolder, .turnFolderIntoSpace, .newFolderFromSelection,
           .moveNodesToSpace, .moveNodesToNewSpace, .moveToSpace, .moveToNewSpace,
           .addFavorite, .moveFavorite, .removeFavorite, .changeSpaceIcon, .renameSpace,
           .editSpaceTheme, .setSpaceProfile, .newProfile, .shareSpace,
           .exportSpaceIntoFolder, .deleteSpace, .moveSpace, .toggleLiveFolder, .refreshLiveFolder, .openLiveFolderState, .newEasel, .exportEasel, .deleteEasel, .exportNote, .deleteNote: return false
      case .archiveNodes(let ids): return model.archiveNodes(ids: ids) > 0
      case .close(let id) where model.tab(id: id) == nil:
        guard model.node(id: id) != nil else { return false }
        model.closeTab(id: id); return true
      case .move(_, let parent, _), .moveNodes(_, let parent, _), .openURL(_, let parent, _):
        guard case .spaceToday(let id) = parent, id == focusedSpace?.id else { return false }
      default: break
      }
    }
    switch intent {
    case .customizePage(let id):
      guard canCustomizePage(id) else { return false }
      app.stores.boosts.editCurrent(tabID: id); return true
    case .dismissAutoArchiveBanner: app.dismissAutoArchiveEducation(); return true
    case .openProfileSettings(let id):
      guard model.profile(id: id) != nil else { return false }
      app.dismissAutoArchiveEducation(); app.settingsPresenter.showProfileSettings(profileID: id); return true
    case .toggleSidebar: controller?.toggleSidebar(); return true
    case .select(let id, let spaceID):
      guard model.space(id: spaceID) != nil, model.node(id: id) != nil else { return false }
      if focusedSpace?.id != spaceID { withoutUndo { model.focusSpace(windowID: windowState.id, spaceID: spaceID) } }
      select(nodeID: id); return true
    case .selectFavorite(let id): guard model.tab(id: id) != nil else { return false }; select(nodeID: id); return true
    case .switchSpace(let id): guard let space = model.space(id: id) else { return false }; focus(space: space); return true
    case .openCommandBar(let source): if source == .urlField { focusAddressBar(nil) } else { newTab(nil) }; return true
    case .newTab: newTab(nil); return true
    case .newEasel: return EaselTab.create(in: self) != nil
    case .exportEasel(let id): return exportEasel(tabID: id)
    case .deleteEasel(let id): return confirmDeleteEasel(tabID: id)
    case .exportNote(let id): return exportNote(tabID: id)
    case .deleteNote(let id): return confirmDeleteNote(tabID: id)
    case .moveToSpace(let id, let space) where isBlankWindow: return moveBlankWindowTab(id, toSpace: space)
    case .rename(let id, let title) where model.tab(id: id).map({ NoteTab.matches($0.url) }) == true:
      return renameNote(tabID: id, title: title)
    case .copyLink(let id, _) where model.tab(id: id).map({ NoteTab.matches($0.url) }) == true:
      return false   // a Note has no shareable address (the row item is disabled)
    case .rename(let id, let title) where model.tab(id: id).map({ EaselTab.matches($0.url) }) == true:
      return renameEasel(tabID: id, title: title)
    case .close(let id), .unloadTab(let id):
      guard model.tab(id: id) != nil else { return nil }; closeTab(id: id); return true
    case .unloadFolder(let id):
      guard let folder = model.node(id: id)?.folder, controller?.context.isPinnedFolder(id) == true else { return false }
      func collect(_ nodes: [SidebarNode]) -> [ItemID] {
        nodes.flatMap { node in
          switch node {
          case .tab(let tab): [tab.id]
          case .split(let split): split.panes.map(\.id)
          case .folder(let folder): collect(folder.children)
          }
        }
      }
      let ids = Set(collect(folder.children))
      let loaded = ids.filter { hosts[$0] != nil || controller?.container.host(for: $0) != nil }
      guard !loaded.isEmpty else { return true }
      for id in loaded { controller?.container.closeHost(for: id); hosts[id]?.close() }
      if let selected = selectedTab?.id, ids.contains(selected) {
        select(nodeID: model.sidebarSelectionID(for: orderedTabs.first { !ids.contains($0.id) }?.id))
      } else { controller?.refresh(); mirror.sync(); scheduleSave() }
      return true
    case .goBack: guard let page = selectedContent, page.canGoBack else { return false }; page.goBack(); return true
    case .goForward: guard let page = selectedContent, page.canGoForward else { return false }; page.goForward(); return true
    case .reload: guard let page = selectedContent else { return false }; page.reload(); return true
    case .stopLoading: guard let page = selectedContent else { return false }; page.stopLoading(); return true
    case .copyCurrentURL:
      return copyURL()
    case .toggleMute(let id):
      guard let tab = model.tab(id: id) else { return false }; model.setMuted(tabID: id, muted: !tab.isMuted); hosts[id]?.content.isMuted = tab.isMuted; scheduleSave(); return true
    case .media(let intent): return app.media.perform(intent)
    case .resetToPinnedURL(let id):
      guard let tab = model.tab(id: id), let url = tab.pinnedURL else { return false }; model.resetPinnedTab(id: id); hosts[id]?.load(url); scheduleSave(); return true
    case .renameSpace(let id, let title):
      guard let space = model.space(id: id) else { return false }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard space.title != (trimmed.isEmpty ? nil : trimmed) else { return true }
      app.undoManager.beginUndoGrouping()
      model.renameSpace(id: id, title: title); app.undoManager.setActionName("Rename Space")
      app.undoManager.endUndoGrouping(); scheduleSave(); return true
    case .setSpaceProfile(let space, let profile): return requestSpaceProfileChange(spaceID: space, profileID: profile)
    case .newSpace:
      return controller?.beginSpaceCreation() == true
    case .openURL(let url, let parent, let index):
      let before = Set(model.index.keys)
      guard let context = controller?.context, ModelSidebarActions(context: context).perform(.openURL(url, in: parent, index: index)),
        let tab = model.index.values.compactMap(\.tab).first(where: { !before.contains($0.id) }) else { return false }
      select(nodeID: tab.id); return true
    case .copyLink(let id, _) where model.tab(id: id).map({ EaselTab.matches($0.url) }) == true:
      return copyEaselLink(tabID: id)
    case .copyLink(let id, let markdown):
      return copyLinks(ids: [id], markdown: markdown)
    case .copyLinks(let ids, let markdown): return copyLinks(ids: ids, markdown: markdown)
    case .copyAllLinks(let id, let markdown): return copyLinks(ids: [id], markdown: markdown)
    case .moveNodesToNewSpace(let ids): return moveSelectionToNewSpace(ids: ids)
    case .moveToNewSpace(let id): return moveSelectionToNewSpace(ids: [id])
    case .turnFolderIntoSpace(let id):
      guard let folder = model.node(id: id)?.folder else { return false }
      return controller?.beginSpaceCreation(options: SpaceCreationOptions(moving: folder.children.map(\.id),
        prefillTitle: folder.title, placement: .today, removingEmptyFolder: id)) == true
    case .share(let id): return shareSidebarTab(id)
    case .shareVia(let id, let service): return shareSidebarTab(id, via: service)
    case .shareSplit(let id): return shareSidebarSplit(id)
    case .shareNodes(let ids): return shareSidebarNodes(ids)
    case .duplicate(let id): return model.duplicateNode(id: id) != nil
    case .toggleLibraryMediaSource(let id): return app.settingsPresenter.toggleLibraryMediaSource(id)
    case .showLibrary:
      app.settingsPresenter.toggleLibrary(section: controller.map { app.downloadsCenter.opensDownloads(in: $0.context) } == true ? .downloads : nil); return true
    // The content toolbar (commandbar-completion §4.6): the setting is Settings ▸ Advanced's
    // "Show full URL when Toolbar is enabled"; every window follows it (AppDelegate's defaults observer).
    case .setShowFullURL(let full): app.settingsPresenter.settings.set(full, for: AppCommand.showFullURLKey); app.applyToolbarSettings(); return true
    case .manageExtensions: openExtensionsPage(nil); return true
    case .performCommand(let id): app.performCommand(id); return true
    case .performWindowCommand(let id): controller?.performCommand(id); return controller != nil
    case .setSharedQuotes(let on): UserDefaults.standard.set(on, forKey: SidebarContext.sharedQuotesKey); return true
    case .showTranslation(let anchor): return translate.showPopover(anchor: anchor)
    case .shareQuote: return copyURLQuote()
    case .manageSpaces:
      app.settingsPresenter.showLibrary(section: .spaces); return true
    case .editPinnedURL(let id):
      // The command bar in edit mode, seeded with the pinned URL (app-shell §4.1). Arc's strings name an
      // "Edit Pinned URL dialog" (FC §3.2 r3); Section 2's brief chose the command bar.
      guard let tab = model.tab(id: id), tab.pinnedURL != nil else { return false }
      showCommandBar(.editCurrentURL, editingPinnedTab: tab.id); return true
    case .editSpaceTheme(let id):
      iconPicker?.close(); return controller?.editSpaceTheme(id) == true
    case .changeSpaceIcon(let id): return openSpaceIconPicker(id)
    case .changeIcon(let id): return openNodeIconPicker(id)
    case .newProfile(let space): app.settingsPresenter.showNewProfile(sourceSpace: space); return true
    case .toggleLiveFolder(let id):
      return app.liveFolders.toggle(spaceID: id)
    case .refreshLiveFolder(let id):
      Task { await app.liveFolders.refresh(folderID: id, manual: true) }; return true
    case .openLiveFolderState(let id):
      guard let url = app.liveFolders.stateURL(folderID: id), let space = focusedSpace else { return false }
      let tab = model.newTab(in: space.id, url: url); select(nodeID: tab.id); return true
    case .shareSpace:
      return false // Explicitly deferred UI entries; see docs/app-shell.md Step B.
    default: return nil
    }
  }

  private func copyLinks(ids: [ItemID], markdown: Bool) -> Bool {
    guard let payload = model.cleanLinkPayload(ids: ids, markdown: markdown) else { return false }
    NSPasteboard.general.clearContents()
    let copied = NSPasteboard.general.setString(payload.text, forType: .string)
    // The toast belongs to the window the user acted in: a Library Space Manager copy
    // (this window not key) copies silently.
    if copied, let title = payload.toastTitle, controller?.window?.isKeyWindow == true {
      controller?.toasts.show(ToastContent(title: title))
    }
    return copied
  }

  private func moveSelectionToNewSpace(ids: [ItemID]) -> Bool {
    guard controller?.context.canMoveNodesToNewSpace(ids) == true else { return false }
    return controller?.beginSpaceCreation(options: SpaceCreationOptions(moving: ids, placement: .preserveSection)) == true
  }

  /// One close rule for Cmd-W, the sidebar, window.close() and
  /// chrome.tabs.remove: pinned tabs and favorites stay in the sidebar and
  /// unload; Today tabs close (archived).
  func closeTab(id: ItemID) {
    if let page = hosts[id]?.content, pageChrome.requestClose(page, completion: { [weak self] accepted in
      if accepted { self?.finishClosingTab(id: id) }
    }) { return }
    finishClosingTab(id: id)
  }
  private func finishClosingTab(id: ItemID) {
    guard model.tab(id: id) != nil else { return }
    findController?.forget(id)
    let order = orderedTabs.map(\.id), index = order.firstIndex(of: id) ?? 0
    let wasSelected = selectedTab?.id == id
    var isFavorite = false
    if case .favorites? = model.parent(of: id) { isFavorite = true }
    if model.isPinned(tabID: id) || isFavorite {
      controller?.container.closeHost(for: id); hosts[id]?.close()
    } else { model.closeTab(id: id) }
    if wasSelected {
      let remaining = orderedTabs.map(\.id).filter { $0 != id }
      select(nodeID: remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)])
    } else { controller?.refresh(); mirror.sync(); scheduleSave() }
    // Capture C10: ⌘W on a Blank Window's last tab closes the whole window, with no prompt.
    // C-report-s11 1(b): the other closed tabs are in the Archive, this last one is not.
    if isBlankWindow, orderedTabs.isEmpty {
      model.archiveSink?.discardArchived(ids: [id])
      DispatchQueue.main.async { [weak self] in self?.window?.performClose(nil) }
    }
  }
  func closeAll() {
    guard !isClosing else { return }
    for host in Array(welcomeHosts.values) { host.close() }
    welcomeHosts.removeAll()
    for host in Array(noteHosts.values) { host.close() }
    noteHosts.removeAll()
    for host in Array(easelHosts.values) { host.close() }
    easelHosts.removeAll()
    controller?.boostEditor?.close(returnFocus: false)
    isClosing = true
    savePrompts?.cancelAll()
    iconPicker?.close(); iconPicker = nil
    pageChrome.close()
    privateDownloads.close()
    pageContextMenu?.cancel(); pageContextMenu = nil
    controller?.existingTabSwitcher?.cancel()
    translate.closeAll()
    for task in saveCaptureTasks.values { task.cancel() }
    saveCaptureTasks.removeAll()
    for task in pageTasks.values { task.cancel() }
    pageTasks.removeAll()
    shareToastHandle = nil
    findController?.closeAll()
    pendingSaveChoice = nil
    if let panel = pendingSavePanel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
    pendingSavePanel = nil
    if let sheet = pendingRenameAlert?.window { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
    pendingRenameAlert = nil
    if let sheet = pendingSpaceProfileAlert?.window { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
    pendingSpaceProfileAlert = nil
    sidebarSharePicker?.close(); sidebarSharePicker = nil
    spaceProfileMenu?.cancelTrackingWithoutAnimation(); spaceProfileMenu = nil
    #if OPEN_AUTOMATION
    stopShareDismissalForAutomation()
    stopObservingSidebarMenusForAutomation()
    #endif
    commandBarNavigationFocus.removeAll()
    typedNavigationTabs.removeAll()
    commandBarSession?.dismiss()
    controller?.container.closeAll(); for host in Array(hosts.values) { host.close() }
    for page in auxiliaryPages { closeAuxiliary(page); page.panel.close() }
    extensions.closeAll()
    for content in pendingLittleOpenExtensionTabs.values {
      content.delegate = nil
      DispatchQueue.main.async { content.close() }
    }
    pendingLittleOpenExtensionTabs.removeAll()
    // Clear the delegate before Section 9 closes/replaces the standalone page.
    // A retained old browser must not deliver actions to the new Profile UI.
    if littleOpenBrowser?.delegate === self { littleOpenBrowser?.delegate = nil }
    littleOpenBrowser = nil; littleOpenContent = nil
    mirror.close()
  }
  func content(forAutomationHandle handle: Any?) -> OEWebContent? {
    switch handle {
    case nil: return selectedContent
    case let text as String where text == "popup": return focusedBrowser?.extensionPopup
    case let text as String: return UUID(uuidString: text).map { ItemID(rawValue: $0) }.flatMap { model.tab(id: $0) }.flatMap { ensureContent(for: $0) }
    case let number as Int: return OEEngine.shared.webContent(identifier: number)
    default: return nil
    }
  }
  func record(_ type: String, _ content: OEWebContent?, _ info: [String: Any]) {
    var event = info; event["type"] = type; event["tab"] = content.flatMap { tabID(for: $0)?.description } ?? ""
    event["content"] = content?.identifier ?? 0; event["time"] = Date().timeIntervalSince1970
    events.append(event); if events.count > 2000 { events.removeFirst(events.count - 2000) }
  }
  func drainEvents() -> [[String: Any]] { defer { events.removeAll() }; return events }
  func completePendingDialog(accept: Bool, text: String?) -> Bool {
    pageChrome.dialogs.answer(accepted: accept, text: text)
  }
  private func updateChrome() { window?.title = selectedTab?.displayTitle ?? "Open" }
}

extension EngineWebContentHostFactory {
  // MARK: Panels

  private func makeAuxiliaryPanel(size: NSSize, title: String, titled: Bool = true) -> NSPanel {
    let style: NSWindow.StyleMask = titled ? [.titled, .closable, .resizable] : [.borderless]
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = false
    return panel
  }

  /// Shows a panel even while another app is active (automation drives Open
  /// from a terminal).
  private func present(_ panel: NSPanel) {
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  private func host(_ content: OEWebContent, in panel: NSPanel) {
    let container = NSView(frame: NSRect(origin: .zero, size: panel.contentLayoutRect.size))
    panel.contentView = container
    content.view.frame = container.bounds
    content.view.autoresizingMask = [.width, .height]
    container.addSubview(content.view)
  }

}

extension EngineWebContentHostFactory {
  @objc func newTab(_ sender: Any?) { showCommandBar(.newTab, userInitiated: true) }
  @objc func focusAddressBar(_ sender: Any?) { showCommandBar(.editCurrentURL, userInitiated: true) }

  func ownsKeyWindow(_ candidate: NSWindow) -> Bool {
    if let panel = controller?.boostEditor?.panel, candidate === panel || candidate.sheetParent === panel { return true }
    if let panel = controller?.boostEditor?.view?.advancedPopover?.panel, candidate === panel { return true }
    if candidate === controller?.themeEditor?.panel || candidate === controller?.spaceCreationController?.themeEditor?.panel { return true }
    return candidate === window || candidate === iconPicker?.panel || candidate === iconPicker?.toneWindow || candidate === popupPanel || auxiliaryPages.contains { $0.panel === candidate } || pageChrome.owns(candidate)
  }
  func navigateFromCommandBar(_ url: URL, current: Bool, background: Bool = false) {
    // An Easel's own address (Copy Link) opens that Easel.
    if let document = EaselTab.documentID(url) { showEasel(documentID: document); return }
    // Welcome is created by the hand-off or Help only; arbitrary internal routes
    // typed in the command bar never reach a page or a system URL handler.
    guard !WelcomeTab.isInternal(url) else { return }
    if current, let tab = selectedTab, WelcomeTab.matches(tab.url) {
      leaveWelcome(tabID: tab.id, for: url); return
    }
    if current, NoteTab.matches(selectedTab?.url) { navigateFromCommandBar(url, current: false, background: background); return }
    // An Easel tab is never replaced by a page: the address opens in a new tab.
    if current, let tab = selectedTab, EaselTab.matches(tab.url) {
      _ = openNewTab(url: url, background: background, typed: true); return
    }
    app.noteLaunchWindowNavigation(windowState.id)
    if current, selectedContent != nil || selectedTab != nil {
      if let page = selectedContent, let host = hosts.values.first(where: { $0.content === page }) {
        commandBarNavigationFocus.insert(host.tabID); host.historyRecorder.markTyped()
      } else if let id = selectedTab?.id {
        commandBarNavigationFocus.insert(id)
        typedNavigationTabs.insert(id)
      }
      if !app.engineReady, let tab = selectedTab {
        queuedNavigations[tab.id] = url; tab.url = url; scheduleSave()
      } else { selectedContent?.load(url); selectedContent?.focusPage() }
    } else if let tab = openNewTab(url: url, background: background, typed: true) {
      if background { _ = ensureContent(for: tab) }
      else { commandBarNavigationFocus.insert(tab.id) }
    }
  }
  /// Option+Return in the command bar: the page opens beside the current page in Split View (Arc 11-returns,
  /// plan D3 §2.3). A split that already has the maximum number of panes loads it in the focused pane.
  /// Returns false when no split can be made and nothing is focused (the caller then opens it as usual).
  @discardableResult
  func openFromCommandBarInSplit(_ url: URL) -> Bool {
    guard !WelcomeTab.isInternal(url), let splits = controller?.splitController, let current = splits.focusedTab else { return false }
    guard splits.canAddPane else { navigateFromCommandBar(url, current: true); return true }
    guard let tab = openNewTab(url: url, background: true, opener: current.id, typed: true) else { return false }
    _ = ensureContent(for: tab)
    splits.openInSplit(tab.id)
    return true
  }
  private func finishCommandBarNavigation(_ page: OEWebContent) {
    guard let id = tabID(for: page), commandBarNavigationFocus.remove(id) != nil else { return }
    DispatchQueue.main.async { [weak self, weak page] in
      guard let self, let page else { return }
      // The bar had focused the old document before navigating. A hosted
      // Chrome tab can reuse its native responder while replacing its renderer;
      // give the committed page a real blur/focus transition after strip sync.
      self.lastNavigationFocusRestored = self.restorePageFocusIfUnclaimed(page, resetResponder: true)
      self.navigationFocusDecisions += 1
    }
  }

  /// Async completions may restore the page only while its native focus is
  /// unclaimed. Sidebar controls, field editors, sheets and other windows win.
  @discardableResult
  func restorePageFocusIfUnclaimed(_ page: OEWebContent? = nil, resetResponder: Bool = false) -> Bool {
    guard !isClosing, !app.terminationRequested, app.engineReady, NSApp.isActive,
          let window, window.isKeyWindow, window.attachedSheet == nil,
          commandBarSession?.isPresented != true,
          let page = page ?? selectedContent, selectedContent === page else { return false }
    let responder = window.firstResponder
    let view = responder as? NSView
    guard responder === window
      || view.map({ $0 === page.view || $0.isDescendant(of: page.view) }) == true else { return false }
    if resetResponder { window.makeFirstResponder(nil) }
    page.focusPage()
    return true
  }

  func focusStateForAutomation() -> [String: Any] {
    let responder = window?.firstResponder
    let view = responder as? NSView
    var owner = "other"
    if responder == nil || responder === window { owner = "window" }
    else if findController?.owns(responder) == true { owner = "find" }
    else if commandBarSession?.controller?.editingUndoManager(for: responder) != nil { owner = "commandbar" }
    else if let view, let sidebar = controller?.sidebar,
            view === sidebar || view.isDescendant(of: sidebar)
              || ((responder as? NSTextView)?.delegate as? NSView).map({ $0.isDescendant(of: sidebar) }) == true { owner = "sidebar" }
    else if let page = selectedContent, let view, view === page.view || view.isDescendant(of: page.view) { owner = "page" }
    return ["owner": owner, "responder": responder.map { String(describing: type(of: $0)) } ?? "none",
      "navigationDecisions": navigationFocusDecisions, "lastNavigationRestored": lastNavigationFocusRestored,
      "findVisible": findController?.visible == true,
      "findText": findController?.query ?? "", "sheet": window?.attachedSheet != nil]
  }
  func selectTabForCommand(_ id: ItemID, spaceID: SpaceID? = nil) {
    guard let tab = model.tab(id: id) else { return }
    if let space = spaceID.flatMap({ model.space(id: $0) }) ?? space(for: id) { focus(space: space) }
    var nodeID = tab.id
    var parent = model.parent(of: nodeID)
    while let container = parent {
      switch container {
      case .folder(let folder): model.setExpanded(folderID: folder, expanded: true); parent = model.parent(of: folder)
      case .splitPane(let split): model.focusSplitPane(splitID: split, tabID: tab.id); nodeID = split; parent = model.parent(of: split)
      default: parent = nil
      }
    }
    select(nodeID: nodeID); controller?.sidebar.reveal(nodeID: tab.id)
  }

  @objc func closeTab(_ sender: Any?) {
    // Cmd+W closes the key picker, including its tone panel, before any tab.
    if let picker = iconPicker, NSApp.keyWindow === picker.panel || NSApp.keyWindow === picker.toneWindow {
      picker.close(); return
    }
    if let key = NSApp.keyWindow, let page = pageChrome.permissionPage(in: key) {
      pageChrome.permissions.cancel(page: page)
      if let id = tabID(for: page) { closeTab(id: id) } else { close(page: page) }
      return
    }
    // Cmd+W in the Essential Keyboard Shortcuts window closes that window, never a tab (§4.5.1).
    if let edu = EssentialShortcutsWindowController.shared.window, NSApp.keyWindow === edu { edu.close(); return }
    if let popupPanel, NSApp.keyWindow === popupPanel {
      focusedBrowser?.closeExtensionPopup()
      return
    }
    if let panel = NSApp.keyWindow as? NSPanel, let page = auxiliaryPages.first(where: { $0.panel === panel }) { closeAuxiliary(page); return }
    if let controller, controller.isLibraryOpen, controller.peekController.isShown,
       controller.peekController.stack.last?.librarySpaceID != nil {
      controller.peekController.dismissTop(); return
    }
    // Cmd+W with the in-window Library open closes the Library, never the tab hidden behind it
    // (as before #350, when the Library was its own window; same as Escape). GUESS — capture pending:
    // Arc's Cmd+W with its Library open (C3-PB1-j).
    if let controller, controller.isLibraryOpen, let session = app.settingsPresenter.librarySessions[controller.windowID] {
      session.close(); return
    }
    if let tab = selectedTab { closeTab(id: tab.id) }
  }

  @objc func restoreLastClosedTab(_ sender: Any?) {
    let store = app.archiveSink.store(for: focusedProfile?.id)
    Task { @MainActor in
      guard let recent = await store.recent(limit: 1).first,
        let record = await store.restore(id: recent.id)
      else { return }
      guard !self.isClosing, !self.app.terminationRequested else { return }
      let tab = self.model.restoreArchivedTab(record)
      self.select(nodeID: tab.id)
    }
  }

  @objc func togglePin(_ sender: Any?) {
    guard let tab = selectedTab else { return }
    if model.isPinned(tabID: tab.id) { model.unpinTab(id: tab.id) } else { model.pinTab(id: tab.id) }
  }

  @objc func addSplitView(_ sender: Any?) {
    guard let selected = selectedTab else { return }
    if let split = controller?.splitController.split { model.unsplit(splitID: split.id); showSelection() }
    else if let other = orderedTabs.first(where: { $0.id != selected.id && !model.isPinned(tabID: $0.id) }),
      let split = model.makeSplit(tabIDs: [selected.id, other.id]) { select(nodeID: split.id) }
    else { controller?.splitController.addEmptyPane(); showSelection() }
  }

  @objc func printPage(_ sender: Any?) { selectedContent?.showPrintPanel() }
  @objc func reloadPage(_ sender: Any?) { selectedContent?.reload() }
  @objc func stopLoading(_ sender: Any?) { selectedContent?.stopLoading() }
  @objc func goBack(_ sender: Any?) { selectedContent?.goBack() }
  @objc func goForward(_ sender: Any?) { selectedContent?.goForward() }
  @objc func zoomIn(_ sender: Any?) { selectedContent?.zoomIn() }
  @objc func zoomOut(_ sender: Any?) { selectedContent?.zoomOut() }
  @objc func resetZoom(_ sender: Any?) { selectedContent?.resetZoom() }
  @objc func showDevTools(_ sender: Any?) { selectedContent?.showDevTools() }

  @objc func openExtensionsPage(_ sender: Any?) { _ = performAppCommand("manage-extensions") }
  @objc func toggleSidebar(_ sender: Any?) { controller?.toggleSidebar() }
  @objc func newWindow(_ sender: Any?) { app.newWindow(nil) }

  @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
  @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

  func cycleTab(by delta: Int) {
    let ids = orderedTabs.map(\.id)
    guard !ids.isEmpty else { return }
    // No selection: Next goes to the first tab, Previous to the last.
    let current = selectedTab.flatMap { ids.firstIndex(of: $0.id) } ?? (delta >= 0 ? -1 : 0)
    select(nodeID: ids[((current + delta) % ids.count + ids.count) % ids.count])
  }

  func showTabSwitcher(by delta: Int) {
    guard let controller, let profile = focusedProfile else { return }
    // Freeze MRU for the whole hold-Control session. Highlighting never calls
    // selectNode, stamps lastActiveAt, loads web content, or changes Space.
    if let switcher = controller.existingTabSwitcher, switcher.isActive {
      switcher.advance(by: delta, items: [], current: nil, in: controller.contentView, event: controller.tabSwitcherKeyEvent) { _ in }
      return
    }
    let current = selectedTab?.id
    let candidates = tabs(in: profile.id).enumerated().sorted { a, b in
      if a.element.id == current { return b.element.id != current }
      if b.element.id == current { return false }
      if a.element.lastActiveAt != b.element.lastActiveAt { return a.element.lastActiveAt > b.element.lastActiveAt }
      return a.offset < b.offset
    }.prefix(5).map(\.element)
    guard candidates.count > 1 else { return }
    controller.tabSwitcher.icon = { [weak self] id in
      self?.model.tab(id: id)?.live.faviconPNG.flatMap(NSImage.init(data:))
    }
    controller.tabSwitcher.snapshot = { [weak self] id in
      guard let self, !self.isClosing, let host = self.hosts[id], !host.closed,
        let data = try? await host.content.snapshotPNG(), !Task.isCancelled,
        let image = NSImage(data: data) else { return nil }
      let thumbnail = NSImage(size: NSSize(width: 328, height: 136))
      thumbnail.lockFocus(); image.draw(in: NSRect(origin: .zero, size: thumbnail.size)); thumbnail.unlockFocus()
      return thumbnail
    }
    controller.tabSwitcher.advance(by: delta, items: candidates.map {
      .init(id: $0.id, title: $0.displayTitle.isEmpty ? ($0.url.host ?? "Tab") : $0.displayTitle,
            subtitle: $0.url.host ?? "")
    }, current: current, in: controller.contentView, event: controller.tabSwitcherKeyEvent,
       ownsWindow: { [weak controller] in controller?.ownsAdditionalKeyWindow?($0) == true }) { [weak self] id in
      guard let self, !self.isClosing, self.profile(for: id)?.id == profile.id else { return }
      // Keep the shared selection path: Container.show returns any preview host
      // before it binds the selected page (A2's ownership handoff).
      self.selectTabForCommand(id)
    }
  }

  @objc func nextSpace(_ sender: Any?) { cycleSpace(by: 1) }
  @objc func previousSpace(_ sender: Any?) { cycleSpace(by: -1) }

  func cycleSpace(by delta: Int) {
    guard let i = model.spaces.firstIndex(where: { $0.id == focusedSpace?.id }), model.spaces.count > 1 else {
      return
    }
    focus(space: model.spaces[(i + delta + model.spaces.count) % model.spaces.count])
  }

  @objc func showFind(_ sender: Any?) { ensureFindController().show() }
  func findPrevious() { ensureFindController().advance(forward: false) }
  @objc func findNext(_ sender: Any?) { ensureFindController().advance(forward: true) }
  /// Offer Exit/Esc to the focused pane's Find bar before Peek or split UI.
  func dismissFindForExit() -> Bool {
    guard let findController, findController.visible, let id = findController.focusedID else { return false }
    findController.close(id); return true
  }

  /// URL for address-field input: a URL, a host, or a search.
  static func url(forInput text: String, profile: Profile?) -> URL? {
    if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("chrome:") {
      return URL(string: text)
    }
    if text.contains(".") && !text.contains(" ") {
      return URL(string: "https://\(text)")
    }
    return SearchEngines.resolve(profile: profile).searchURL(for: text)
  }

  /// Closes one page wherever it lives.
  func close(page: OEWebContent) {
    if let aux = auxiliaryPages.first(where: { $0.content === page }) {
      closeAuxiliary(aux)
    } else if page.extensionPopupIdentifier != nil {
      page.browser?.closeExtensionPopup()
      focusedBrowser?.closeExtensionPopup()
    } else if let id = tabID(for: page) {
      closeTab(id: id)
    } else {
      page.close()
    }
  }

  func closeAuxiliary(_ page: AuxiliaryPage) {
    pageChrome.cancel(page.content)
    guard auxiliaryPages.contains(where: { $0 === page }) else { return }
    auxiliaryPages.removeAll { $0 === page }
    if let observer = page.closeObserver { NotificationCenter.default.removeObserver(observer) }
    page.closeObserver = nil
    page.historyRecorder?.close()
    page.content.close()
    page.panel.orderOut(nil)
  }
}

// MARK: - OEWebContentDelegate

extension EngineWebContentHostFactory: OEWebContentDelegate {
  func webContent(_ webContent: OEWebContent, didChange changes: OEWebContentChange) {
    if pendingLittleOpenExtensionTabs[webContent.identifier] === webContent {
      if changes.contains(.URL), let url = webContent.url, url.absoluteString != "about:blank" {
        routeLittleOpenExtensionTab(webContent, url: url)
      } else if changes.contains(.live), !webContent.isLive {
        pendingLittleOpenExtensionTabs[webContent.identifier] = nil; webContent.delegate = nil
      }
      return
    }
    if let popup = auxiliaryPages.first(where: { $0.content === webContent }) {
      if changes.contains(.loading), webContent.isLoading { popup.historyRecorder?.loadingChanged(true) }
      if changes.contains(.URL), let url = webContent.url {
        popup.historyRecorder?.addressChanged(url, isLoading: webContent.isLoading, ephemeral: webContent.context.isEphemeral, title: webContent.title)
      }
      if changes.contains(.loading), !webContent.isLoading { popup.historyRecorder?.loadingChanged(false); popup.historyRecorder?.titleChanged(webContent.title) }
      if changes.contains(.title) { popup.panel.title = webContent.title; popup.historyRecorder?.titleChanged(webContent.title) }
    }
    // Share Quote follows the focused page's selection (page-platform §4.2.5, EP-3).
    if changes.contains(.selection) { translate.syncStatus() }
    record("change", webContent, ["changes": changes.rawValue])
  }
  func webContent(_ page: OEWebContent, didCommitNavigationTo url: URL, isReload: Bool) {
    auxiliaryPages.first { $0.content === page }?.historyRecorder?.committed(url: url, isReload: isReload, ephemeral: page.context.isEphemeral)
  }

  /// Chromium's history swiper (page-platform EP-1). Recorded for automation; Step 12 draws
  /// Open's indicator from it.
  func webContent(_ webContent: OEWebContent, historySwipe phase: OEHistorySwipePhase, direction: OEHistorySwipeDirection, progress: Double) {
    let phases: [SwipeIndicatorView.Phase] = [.began, .changed, .completed, .cancelled]
    let event = SwipeIndicatorView.Event(phase: phases[max(0, min(3, phase.rawValue))],
      direction: direction == .forward ? .forward : .back, progress: progress)
    var shown = false
    if let controller, controller.hasPeekController, controller.peekController.isShown,
       (controller.peekController.stack.last?.host as? EngineWebContentHost)?.content === webContent {
      controller.peekController.overlay.showHistorySwipe(event); shown = true
    } else if let id = tabID(for: webContent) { shown = controller?.container.showHistorySwipe(tabID: id, event) ?? false }
    record("historySwipe", webContent, ["phase": event.phase.rawValue, "direction": event.direction.rawValue,
      "progress": progress, "indicator": shown])
  }

  /// Whether pages of this window may start a history swipe now (page-platform §4.4.1).
  var historySwipeAllowed: Bool { NSEvent.isSwipeTrackingFromScrollEventsEnabled && !captureOverlayUp }

  func syncHistorySwipe() {
    let allowed = historySwipeAllowed
    for host in hosts.values where host.content.historySwipeEnabled != allowed { host.content.historySwipeEnabled = allowed }
  }

  static func pngData(_ image: NSImage) -> Data? {
    // Refuse oversized engine images before asking AppKit to rasterize them.
    // Explicit allocation: 64 * 64 * 4 = 16 KiB, independent of source size.
    guard !image.representations.isEmpty, image.representations.count <= 32,
      image.representations.allSatisfy({ (1...1024).contains($0.pixelsWide) && (1...1024).contains($0.pixelsHigh) }),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let color = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
        space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let scale = min(64 / CGFloat(source.width), 64 / CGFloat(source.height))
    let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2, width: size.width, height: size.height))
    guard let bitmap = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
  }

  func webContent(_ webContent: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    guard app.engineReady, request.url.map({ !WelcomeTab.isInternal($0) }) ?? true else { return nil }
    let config = OEWebContentConfiguration(context: request.context)
    config.runtimeStyle = webContent.runtimeStyle
    switch request.disposition {
    case .newPopup:
      let popup = OEWebContent(configuration: config, url: nil)
      popup.delegate = self
      var size = request.requestedFrame.size
      if size.width < 100 || size.height < 100 { size = NSSize(width: 600, height: 500) }
      let panel = makeAuxiliaryPanel(size: size, title: request.url?.host() ?? "Popup")
      host(popup, in: panel)
      panel.center()
      present(panel)
      let page = AuxiliaryPage(content: popup, panel: panel)
      if let profile = profile(for: request.context) { page.historyRecorder = AppHistoryRecorder(stores: app.stores, profileID: profile.id) }
      page.closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: panel, queue: .main
      ) { [weak self, weak page] _ in
        MainActor.assumeIsolated { if let self, let page { self.closeAuxiliary(page) } }
      }
      auxiliaryPages.append(page)
      record("open", popup, ["disposition": "popup", "url": request.url?.absoluteString ?? ""])
      return popup
    case .newWindow:
      let sourceSpace = tabID(for: webContent).flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let controller = isIncognito ? app.makeIncognitoWindow(parent: incognitoSession?.parent) : app.makeWindow(focusedSpaceID: sourceSpace?.id), let target = app.hostFactories[controller.windowID] else { return nil }
      if webContent.runtimeStyle == .chrome, let url = request.url {
        // The engine would make the page a tab of the opener window's hidden
        // Chrome window (P1), which closes with that window. A new window
        // needs no opener: open the URL as a new tab there instead.
        target.openNewTab(url: url, background: false)
        record("open", webContent, ["disposition": "newWindow", "url": url.absoluteString, "newTab": true])
        return nil
      }
      return target.adoptUnownedRequest(request)
    case .newPictureInPicture:
      // Alloy-style pages only: a Chrome-style page's Document PiP opens through the engine's
      // PiP delegate (MediaCoordinator, EM-7). Alloy pages get none.
      return nil
    case .currentTab, .saveToDisk:
      return nil
    default:
      let opener = tabID(for: webContent)
      if let opener, model.tab(id: opener) == nil, app.options.defaultStyle == .chrome, let url = request.url {
        // A Peek page (a host that is not a model tab) is Alloy, and so would
        // be the page it opens: not a chrome.tabs tab. Open the URL as a tab.
        openNewTab(url: url, background: request.disposition == .newBackgroundTab)
        record("open", webContent, ["disposition": request.disposition.rawValue, "url": url.absoluteString, "fromPeek": true])
        return nil
      }
      let source = opener.flatMap { space(for: $0) } ?? hosts.values.first { $0.content === webContent }?.spaceID.flatMap { model.space(id: $0) }
      guard let space = source ?? focusedSpace, space.profileID == profile(for: request.context)?.id else { return nil }
      let tab = model.newTab(in: space.id, url: request.url ?? URL(string: "about:blank")!, at: 0,
                             unread: request.disposition == .newBackgroundTab)
      tab.openerID = opener
      let content = makeContent(for: tab, url: nil, requestContext: request.context)
      if request.disposition != .newBackgroundTab { focus(space: space); select(nodeID: tab.id) }
      record(
        "open", content,
        ["disposition": request.disposition.rawValue, "url": request.url?.absoluteString ?? ""])
      return content
    }
  }

  /// Key events that reach the page view directly (not through
  /// NSApplication.sendEvent) still get the reserved app shortcuts.
  func webContent(_ webContent: OEWebContent, handleKeyEventBeforePage event: NSEvent) -> Bool {
    if pageChrome.handleKey(event) { return true }
    // An action popup's keys arrive here too (Chrome's ExtensionViewHost
    // pre-handles them through the hidden window, whose delegate is CEF's).
    // Cmd+W closes the popup, not the tab (extensions plan §3.7 F2).
    if let browser = focusedBrowser, webContent === browser.extensionPopup {
      record("popupKey", webContent, ["key": event.charactersIgnoringModifiers ?? "", "phase": "beforePage"])
      if Self.isCommandW(event) {
        browser.closeExtensionPopup()
        return true
      }
    }
    return controller?.handleKeyDown(event) == true
  }

  private static func isCommandW(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "w"
  }

  func webContentDidRequestClose(_ webContent: OEWebContent) {
    if pageChrome.pageRequestedClose(webContent) { return }
    // Chromium has already accepted beforeunload. Do not ask it to close
    // again, or destroy its host from inside the engine delegate callback.
    DispatchQueue.main.async { [weak self, weak webContent] in
      guard let self, let webContent else { return }
      if let id = self.tabID(for: webContent) { self.finishClosingTab(id: id) }
      else { self.close(page: webContent) }
    }
  }

  func webContent(_ webContent: OEWebContent, runJavaScriptDialog dialog: OEJavaScriptDialog) -> Bool {
    pageChrome.run(dialog, page: webContent)
  }

  func webContent(_ webContent: OEWebContent, decidePermissionRequest request: OEPermissionRequest) -> Bool {
    pageChrome.request(request, page: webContent)
  }

  func webContent(_ webContent: OEWebContent, showContextMenu menu: OEContextMenu) -> Bool {
    pageContextMenu?.cancel()
    let session = PageContextMenuBuilder(request: menu, page: webContent, owner: self)
    pageContextMenu = session
    session.buildAndShow()
    return true
  }

  func webContent(_ webContent: OEWebContent, didUpdateFindResult result: OEFindResult) {
    lastFindResult = result
    findController?.didUpdate(result, page: webContent)
  }

  func webContent(_ webContent: OEWebContent, didRequestFullscreen fullscreen: Bool) {
    record("fullscreen", webContent, ["on": fullscreen])
    if fullscreenPolicy == "record" { return }
    controller?.isPageFullscreen = fullscreen
    if let window {
      if fullscreen, !window.styleMask.contains(.fullScreen) {
        enteredWindowFullscreenForPage = true; window.toggleFullScreen(nil)
      } else if !fullscreen, enteredWindowFullscreenForPage {
        enteredWindowFullscreenForPage = false
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      }
    }
  }

  func webContent(_ webContent: OEWebContent, handleUnconsumedKeyEvent event: NSEvent) -> Bool {
    if webContent === focusedBrowser?.extensionPopup {
      record("popupKey", webContent, ["key": event.charactersIgnoringModifiers ?? "", "phase": "unconsumed"])
    }
    return controller?.handleKeyDown(event, unconsumed: true) == true
  }

  private func canCustomizePage(_ id: ItemID) -> Bool {
    !isIncognito && model.tab(id: id)?.live.hasLoadedInThisLaunch == true
      && app.stores.boosts.canEdit(tabID: id)
  }

  func webContent(_ webContent: OEWebContent, didFinishLoadWithStatus status: Int) {
    if pendingLittleOpenExtensionTabs[webContent.identifier] === webContent {
      routeLittleOpenExtensionTab(webContent, url: webContent.url)
      return
    }
    finishCommandBarNavigation(webContent)
    app.prepareCommandsAfterPaint(webContent)
    if let id = tabID(for: webContent) {
      model.tab(id: id)?.live.hasLoadedInThisLaunch = true
      LaunchTiming.shared.mark("firstLoadEnd"); translate.pageDidFinishLoad(webContent, status: status)
    }
    record("load", webContent, ["status": status, "url": webContent.url?.absoluteString ?? ""])
  }

  func webContent(_ webContent: OEWebContent, didFailLoadWithError error: any Error) {
    finishCommandBarNavigation(webContent)
    record("loadError", webContent, ["error": error.localizedDescription])
  }

  func webContent(_ webContent: OEWebContent, didReceiveDevToolsEvent method: String, parameters: [String: Any]) {
    pageChrome.event(method, parameters: parameters, page: webContent)
    record("devtools", webContent, ["method": method, "params": parameters])
  }

  func webContent(_ webContent: OEWebContent, didLogConsoleMessage message: String, level: Int, source: String, line: Int) {
    record("console", webContent, ["message": message, "level": level, "source": source, "line": line])
  }
}

// MARK: - OEBrowserDelegate (extension actions and popups)

extension EngineWebContentHostFactory: OEBrowserDelegate {
  private func closePopupInCallbackForAutomation(_ browser: OEBrowser, popup: OEWebContent, phase: String) {
    #if OPEN_AUTOMATION
    guard let policy = popupCallbackClose, policy.phase == phase else { return }
    popupCallbackClose = nil
    if policy.toggle, let identifier = browser.extensionPopupExtensionIdentifier {
      _ = browser.executeExtensionAction(identifier)
    } else {
      browser.closeExtensionPopup()
      browser.closeExtensionPopup() // repeated requests must remain safe
    }
    record("popupCallbackClose", popup, ["phase": phase, "toggle": policy.toggle,
      "stillOpenInsideCallback": browser.extensionPopup === popup])
    #endif
  }

  func browserDidUpdateExtensionActions(_ browser: OEBrowser) {
    record("extensionActions", nil, ["browser": browser.identifier, "ready": browser.extensionActionsReady])
    if extensions.host?.browser === browser { extensions.host?.reload() }
  }
  func browser(_ browser: OEBrowser, didUpdate action: OEExtensionAction) {
    if extensions.host?.browser === browser { extensions.host?.didUpdate(action) }
  }
  func browser(_ browser: OEBrowser, didOpenExtensionPopup popup: OEWebContent, for action: OEExtensionAction) {
    extensions.popup.opened(browser: browser, page: popup, action: action)
    record("extensionPopup", popup, ["extension": action.extensionIdentifier, "open": true])
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "open")
  }
  func browser(_ browser: OEBrowser, didResizeExtensionPopup popup: OEWebContent, to size: NSSize) {
    record("extensionPopup", popup, ["resize": [size.width, size.height]])
    extensions.popup.resized(popup, size: size)
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "resize")
  }
  func browser(_ browser: OEBrowser, extensionPopupIsReady popup: OEWebContent) {
    record("extensionPopup", popup, ["ready": true])
    extensions.popup.ready(popup)
    closePopupInCallbackForAutomation(browser, popup: popup, phase: "ready")
  }
  func browser(_ browser: OEBrowser, didCloseExtensionPopup popup: OEWebContent) {
    pageChrome.cancel(popup)
    extensions.popup.closed(popup)
    record("extensionPopup", popup, ["open": false])
  }
  func browser(_ browser: OEBrowser, requestsContextMenuForExtensionAction extensionIdentifier: String) {
    record("extensionMenuRequest", nil, ["extension": extensionIdentifier])
    if let anchor = extensions.strips.flatMap(\.buttons).first(where: { $0.action.id == extensionIdentifier && !$0.isHiddenOrHasHiddenAncestor }) {
      extensions.showContextMenu(extensionIdentifier, anchor: anchor)
    }
  }
}

// MARK: - OEBrowserDelegate (tab requests from Chromium, fork patch P1)

/// Tab changes that Chromium asks for on its own: chrome.tabs calls from
/// extensions, and pages extensions open (docs/engine-patches.md, P1). Each
/// arrives as a request; the handler changes OpenModel and then calls
/// mirror.sync(), the only owner of strip order. Handlers never insert, move,
/// pin, or activate in an OEBrowser themselves. Closes arrive as
/// webContentDidRequestClose(_:) and follow closeTab(id:).
extension EngineWebContentHostFactory {
  /// chrome.tabs.create, an extension's welcome or options page: a new Today
  /// tab at the top of the Space (Arc's placement for new tabs). pinned,
  /// index and openerTabId are not applied (documented P1 gap).
  @objc(browser:didOpenWebContent:active:)
  func browser(_ browser: OEBrowser, didOpen webContent: OEWebContent, active: Bool) {
    if controller == nil {
      // guess (child), Section 6 lead ruling: Little Open keeps one page;
      // extra extension tabs open selected in the most recent main window.
      // Hosted Chrome contents cannot change browsers. OnTabCreated can
      // precede navigation, so retain the unshown page until its URL arrives.
      // Arc parity is unconfirmed and needs a capture.
      record("standaloneExtraTabRouted", webContent, ["browser": browser.identifier])
      pendingLittleOpenExtensionTabs[webContent.identifier] = webContent
      webContent.delegate = self
      if let url = webContent.url, url.absoluteString != "about:blank" {
        routeLittleOpenExtensionTab(webContent, url: url)
      }
      return
    }
    guard let space = space(forNewTabIn: browser), let profileID = profile(for: browser.context)?.id else {
      webContent.close()
      return
    }
    let url = webContent.url ?? URL(string: "about:blank")!
    let tab = model.newTab(in: space.id, url: url, at: 0, unread: !active)
    adopt(webContent, for: tab, profileID: profileID)
    record("open", webContent, ["disposition": "chromium", "active": active, "url": url.absoluteString])
    if active {
      if space.id != focusedSpace?.id { focus(space: space) }
      select(nodeID: tab.id)
    }
  }

  private func routeLittleOpenExtensionTab(_ content: OEWebContent, url: URL?) {
    guard pendingLittleOpenExtensionTabs.removeValue(forKey: content.identifier) === content else { return }
    content.delegate = nil
    let sourceProfileID = profile(for: content.context)?.id
    // Recreate the URL in the destination before closing the original, after
    // the source engine callback returns. Close on every failure too, so the
    // unshown source cannot remain in Little Open's Chrome tab strip.
    DispatchQueue.main.async {
      defer { content.close() }
      guard let url, url.absoluteString != "about:blank" else {
        self.record("standaloneExtraTabDropped", content, ["reason": "blank-url"]); return
      }
      guard let profileID = sourceProfileID,
        let space = self.model.mostRecentlyFocusedSpace(profileID: profileID) else {
        self.record("standaloneExtraTabDropped", content, ["reason": "no-profile-space"]); return
      }
      var controller = self.app.linkExecutor.orderedControllers.first {
        $0.context.focusedSpace?.profileID == profileID
      }
      if controller == nil {
        // makeWindow can reuse the retained final main window. Set its Space
        // before composition, so no page is created in a different Profile.
        if self.app.windowControllers.isEmpty,
          let retained = self.model.windows.first(where: { $0.style == .standard }) {
          self.model.focusSpace(windowID: retained.id, spaceID: space.id)
        }
        controller = self.app.makeWindow(focusedSpaceID: space.id)
      }
      guard let controller, controller.context.focusedSpace?.profileID == profileID,
        let target = self.app.hostFactories[controller.windowID],
        target.openNewTab(url: url, background: false) != nil else {
        self.record("standaloneExtraTabDropped", content, ["reason": "target-unavailable"]); return
      }
      self.app.focusWindow(controller.windowID, activate: true)
    }
  }

  /// A page asks to be shown: chrome.tabs.update({active: true}), or the
  /// page's own focus() (window.focus() in a notification click handler, a
  /// service worker's client.focus(), DevTools Page.bringToFront), which all
  /// reach Chromium's ActivateContents (page-platform §4.5.4). Focus the
  /// tab's Space in this window and select the tab. Selecting also wakes
  /// it: showSelection marks the shown tabs live and loads their pages (the
  /// App's only wake path until OpenSleep is wired in the App, s8/sleep-app;
  /// its wake call belongs here). For a page's focus(), Chromium then brings
  /// this window front itself (OpenBrowserWindow::Activate: NSApp activate
  /// and makeKeyAndOrderFront, which also restores a minimized window).
  @objc(browser:requestsActivationOfWebContent:)
  func browser(_ browser: OEBrowser, requestsActivationOf webContent: OEWebContent) {
    defer { mirror.sync() }
    guard let id = requestTabID(for: webContent) else { return }
    let space = space(containing: id)
    if let space, space.id != focusedSpace?.id { focus(space: space) }
    select(nodeID: id)
    NotificationClickRouter.shared.pageRequestedActivation(tab: id)
    record("tab-request", webContent, ["request": "activate", "space": space?.id.description ?? ""])
  }

  /// chrome.tabs.move: applied only when one position in the tab's own
  /// parent (section, folder, or Favorites) puts the tab between exactly the
  /// two strip tabs Chromium put it between. Otherwise nothing changes and
  /// the resync puts Chromium's strip back (folders, splits, other sections
  /// and Spaces cannot be reached by a strip index).
  @objc(browser:requestsMoveOfWebContent:toIndex:)
  func browser(_ browser: OEBrowser, requestsMoveOf webContent: OEWebContent, to index: UInt) {
    defer { mirror.sync() }
    guard let id = requestTabID(for: webContent), let profileID = profile(for: browser.context)?.id,
      let parent = model.parent(of: id), let node = model.node(id: id),
      let current = children(of: parent), let from = current.firstIndex(where: { $0.id == id })
    else {
      record("tab-request", webContent, ["request": "move", "refused": true])
      return
    }
    let siblings = current.filter { $0.id != id }
    let others = browser.webContents.filter { $0 !== webContent }
    let target = Int(index)
    let previous = target > 0 && target - 1 < others.count ? tabID(for: others[target - 1]) : nil
    let next = target < others.count ? tabID(for: others[target]) : nil
    let position = (0...siblings.count).first { candidate in
      var moved = siblings
      moved.insert(node, at: candidate)
      let order = stripOrder(profile: profileID, replacing: parent, with: moved)
      guard let i = order.firstIndex(of: id) else { return false }
      return (i > 0 ? order[i - 1] : nil) == previous && (i + 1 < order.count ? order[i + 1] : nil) == next
    }
    guard let position else {
      record("tab-request", webContent, ["request": "move", "refused": true])
      return
    }
    if position != from { model.moveNode(id: id, to: parent, at: position) }
    record("tab-request", webContent, ["request": "move", "position": position])
  }

  /// chrome.tabs.update({pinned}): pin or unpin the tab. Favorites are
  /// pinned tabs to Chromium and stay Favorites: both are no-ops for them.
  @objc(browser:requestsPinned:forWebContent:)
  func browser(_ browser: OEBrowser, requestsPinned pinned: Bool, for webContent: OEWebContent) {
    defer { mirror.sync() }
    guard !isIncognito, let id = requestTabID(for: webContent), let parent = model.parent(of: id) else { return }
    if case .favorites = parent {
      record("tab-request", webContent, ["request": pinned ? "pin" : "unpin", "refused": true])
      return
    }
    guard model.isPinned(tabID: id) != pinned else { return }
    if pinned { model.pinTab(id: id) } else { model.unpinTab(id: id) }
    record("tab-request", webContent, ["request": pinned ? "pin" : "unpin"])
  }

  /// chrome.tabs.discard: the sleep controller's debug-sleep path (app-shell Step G). It
  /// honors every never-sleep gate (the visible tab, keep-alive sites, audio, capture,
  /// notifications, …); an allowed tab sleeps like a timed discard, stays in the sidebar,
  /// and loads again when shown. The discard runs after the engine's call returns.
  @objc(browser:requestsDiscardOfWebContent:)
  func browser(_ browser: OEBrowser, requestsDiscardOf webContent: OEWebContent) -> Bool {
    guard let id = requestTabID(for: webContent), !visibleTabs.contains(where: { $0.id == id }),
          app.tabSleep.requestDiscard(tabID: id) else {
      record("tab-request", webContent, ["request": "discard", "refused": true])
      return false
    }
    record("tab-request", webContent, ["request": "discard"])
    return true
  }

  /// chrome.windows.remove on this window: refused in v1. The window and its
  /// tabs stay; the user closes windows.
  @objc(browserRequestsClose:)
  func browserRequestsClose(_ browser: OEBrowser) {
    NSLog("Open: refused chrome.windows.remove for window %ld", browser.chromeWindowIdentifier)
    record("window-request", nil, ["request": "close", "refused": true, "window": browser.chromeWindowIdentifier])
  }

  /// Makes `content`, a page the engine opened on its own, the page of `tab`.
  private func adopt(_ content: OEWebContent, for tab: Tab, profileID: ProfileID) {
    let host = EngineWebContentHost(tabID: tab.id, profileID: profileID, content: content, owner: self)
    hosts[tab.id] = host
    modelHostIDs.insert(tab.id)
    tab.live.sleepPhase = .live
    content.isMuted = tab.isMuted
    controller?.container.adopt(host, for: tab.id)
    if host.view.superview == nil { host.view.frame = contentContainer.bounds; contentContainer.addSubview(host.view) }
    mirror.sync()
    app.tabSleep.contentCreated(tabID: tab.id, host: host)
  }

  /// The model tab of a request's page: sidebar tabs only (Peek hosts have
  /// transient ids).
  private func requestTabID(for content: OEWebContent) -> ItemID? {
    guard let id = tabID(for: content), model.tab(id: id) != nil, modelHostIDs.contains(id) else { return nil }
    return id
  }

  /// The focused Space if it belongs to the strip's profile, else that
  /// profile's first Space.
  private func space(forNewTabIn browser: OEBrowser) -> Space? {
    guard let profile = profile(for: browser.context)?.id else { return nil }
    if let space = focusedSpace, space.profileID == profile { return space }
    return model.spaces.first { $0.profileID == profile }
  }

  /// The Space whose sidebar shows `id` (favorites: the focused Space of
  /// that profile, else its first Space).
  func space(containing id: ItemID) -> Space? {
    var current = id
    while let parent = model.parent(of: current) {
      switch parent {
      case .spacePinned(let space), .spaceToday(let space): return model.space(id: space)
      case .folder(let folder), .splitPane(let folder): current = folder
      case .favorites(let profile):
        if let space = focusedSpace, space.profileID == profile { return space }
        return model.spaces.first { $0.profileID == profile }
      }
    }
    return nil
  }

  private func children(of parent: NodeParent) -> [SidebarNode]? {
    switch parent {
    case .spacePinned(let space): return model.space(id: space)?.pinned
    case .spaceToday(let space): return model.space(id: space)?.today
    case .folder(let folder): return model.node(id: folder)?.folder?.children
    case .favorites(let profile): return model.profile(id: profile)?.favorites.map { .tab($0) }
    case .splitPane: return nil
    }
  }

  /// The tab ids of `profile`'s strip in mirror order (tabs(in:), tabs with
  /// a page only), with `parent`'s children replaced by `children`.
  private func stripOrder(profile: ProfileID, replacing parent: NodeParent, with children: [SidebarNode]) -> [ItemID] {
    let loaded = contents
    func ids(_ nodes: [SidebarNode], in container: NodeParent) -> [ItemID] {
      (container == parent ? children : nodes).flatMap { node -> [ItemID] in
        switch node {
        case .tab(let t): return loaded[t.id] == nil ? [] : [t.id]
        case .folder(let f): return ids(f.children, in: .folder(f.id))
        case .split(let s): return ids(s.panes.map { .tab($0) }, in: .splitPane(s.id))
        }
      }
    }
    let spaces = model.spaces.filter { $0.profileID == profile }
    var order = ids((model.profile(id: profile)?.favorites ?? []).map { .tab($0) }, in: .favorites(profile))
    for space in spaces { order += ids(space.pinned, in: .spacePinned(space.id)) }
    for space in spaces { order += ids(space.today, in: .spaceToday(space.id)) }
    return order
  }
}

// MARK: - OEBrowserContextDelegate (downloads)

extension EngineWebContentHostFactory: OEBrowserContextDelegate {
  func browserContext(
    _ context: OEBrowserContext, decideDestinationFor download: OEDownload, suggestedFilename: String,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    if isIncognito {
      privateDownloads.decide(download, filename: suggestedFilename, directory: downloadDirectory,
        profile: incognitoSession?.parent, window: window, completion: completion)
    } else {
      app.downloadsCenter.decide(download, context: context, filename: suggestedFilename, window: window, directoryOverride: downloadDirectory, completion: completion)
    }
  }

  func browserContext(_ context: OEBrowserContext, downloadDidUpdate download: OEDownload) {
    if isIncognito { privateDownloads.updated(download) }
    else { app.tabSleep.downloadUpdated(download, factory: self) }
    record(
      "download", download.webContent,
      [
        "id": download.identifier, "state": download.state.rawValue, "received": download.receivedBytes,
        "path": download.destinationURL?.path ?? "",
      ])
  }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}

// AppKit reaches browser Find only after the text/page responder declines it.
// Undo/Redo use AppKit itself and the window delegate's selected UndoManager.
extension EngineWebContentHostFactory: NSMenuItemValidation {
  /// The selected tab's Note page, when it is a Note.
  var selectedNoteHost: NoteContentHost? {
    guard let id = selectedTab?.id, let host = noteHosts[id], !host.closed else { return nil }
    return host
  }

  @objc func performFindPanelAction(_ sender: Any?) {
    if let note = selectedNoteHost { note.editor.showFind(); return }
    ensureFindController().perform(tag: (sender as? NSMenuItem)?.tag ?? 1)
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)), #selector(centerSelectionInVisibleArea(_:)):
      return selectedContent != nil || selectedNoteHost != nil
    default: return true
    }
  }
}
