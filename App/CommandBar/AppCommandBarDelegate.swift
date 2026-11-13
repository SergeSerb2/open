import AppKit
import OpenCommandBar
import OpenFeatures
import OpenDesign
import OpenEasel
import OpenModel
import OpenSuggest
import OpenEngine
import OpenStore
import Observation

/// Row and input favicons from the App's stored favicon cache (the sidebar's), never a synchronous
/// disk or network read: a miss returns nil and `loaded` runs once the cache entry fills (plan D3 §3).
@MainActor
final class StoredCommandBarFavicons: CommandBarFaviconSource {
  let cache: StoredFaviconCache
  init(cache: StoredFaviconCache) { self.cache = cache }
  func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage? {
    // Easel rows (sidebar tabs and Library-only Easels) use the Easel glyph, as the sidebar does.
    if EaselTab.matches(pageURL) { return EaselIcon.image }
    var image: NSImage?
    withObservationTracking { image = cache.image(for: pageURL) } onChange: {
      Task { @MainActor in loaded(pageURL) }
    }
    return image
  }
}

/// One lazy native command-bar controller for one standard window.
@MainActor
final class AppCommandBarSession: CommandBarDelegate {
  unowned let factory: EngineWebContentHostFactory
  private(set) var controller: CommandBarController?
  private lazy var extensionSource = EngineCommandBarSource(factory: factory)
  private var welcomeIcons: WelcomeCommandBarIcons?
  private lazy var storedIcons: StoredCommandBarFavicons? = factory.app.stores.sidebarFavicons.map { StoredCommandBarFavicons(cache: $0) }
  private var openedAt = 0.0
  private var queryAt = 0.0
  private var queryRevision = 0
  private var appliedRevision = -1
  private(set) var firstResultsMilliseconds: Double?
  private(set) var openFirstResultsMilliseconds: Double?
  private var openingSelection: ItemID?
  private var openingProfile: ProfileID?
  /// The pinned tab whose pinned URL this presentation edits (Edit Pinned Page ▸ Edit…), else nil.
  private(set) var pinnedEditTabID: ItemID?
  init(factory: EngineWebContentHostFactory) { self.factory = factory }

  var isPresented: Bool { controller?.isPresented == true }
  /// True when the user opened the current presentation (Cmd+T / Cmd+L, menu, sidebar): only then a second key closes it.
  private(set) var openedByUser = false
  func show(_ mode: CommandBarMode, requestedAt: Double, editingPinnedTab: ItemID? = nil, userInitiated: Bool = false) {
    openedAt = requestedAt
    let pinned = editingPinnedTab.flatMap { id in factory.model.tab(id: id).flatMap { $0.pinnedURL == nil ? nil : $0 } }
    pinnedEditTabID = pinned?.id
    guard let windowController = factory.controller, let profile = factory.focusedProfile else { return }
    if factory.window?.isKeyWindow != true || !NSApp.isActive {
      factory.app.focusWindow(factory.windowState.id, activate: true)
    }
    windowController.dismissSidebarReveal()
    guard let engine = factory.suggestEngine() else { return }
    engine.extensionSource = extensionSource
    if controller?.engine !== engine {
      controller?.dismiss(reason: .programmatic)
      controller?.view.removeFromSuperview()
      let bar = CommandBarController(engine: engine)
      bar.delegate = self
      // Footer "Learn more about your data on Open" (LEAD 07:15): the repo page until a public site exists.
      bar.privacyURL = AppCommand.privacyURL
      extensionSource.onRowsChanged = { [weak bar] id in bar?.refreshExtensionSuggestions(extensionID: id) }
      bar.extensionIcon = { [weak self] id in
        self?.factory.focusedBrowser?.extensionActions.first { $0.extensionIdentifier == id }?.icon
      }
      bar.isActionEnabled = { [weak self] id, space in self?.factory.isAppCommandEnabled(id, payload: space?.description) ?? false }
      bar.onQueryStarted = { [weak self] _ in
        guard let self else { return }
        self.queryAt = LaunchTiming.shared.elapsedMilliseconds
        self.queryRevision += 1; self.firstResultsMilliseconds = nil
      }
      bar.onSnapshotApplied = { [weak self] _ in
        guard let self, self.appliedRevision != self.queryRevision else { return }
        self.appliedRevision = self.queryRevision
        self.firstResultsMilliseconds = LaunchTiming.shared.elapsedMilliseconds - self.queryAt
        if self.openFirstResultsMilliseconds == nil {
          self.openFirstResultsMilliseconds = LaunchTiming.shared.elapsedMilliseconds - self.openedAt
        }
      }
      controller = bar
      bar.view.frame = windowController.contentView.bounds
      bar.view.autoresizingMask = [.width, .height]
      windowController.contentView.addSubview(bar.view)
      windowController.commandBarView = bar.view
      bar.view.passesClickThrough = { [weak windowController] point in
        windowController?.sidebar.isTabRow(atWindowPoint: point) ?? false
      }
    }
    guard let bar = controller else { return }
    if WelcomeTab.matches(factory.selectedTab?.url) {
      if welcomeIcons == nil { welcomeIcons = WelcomeCommandBarIcons() }
      bar.favicons = welcomeIcons
    } else { bar.favicons = factory.isIncognito ? nil : storedIcons }
    if !factory.isIncognito { factory.app.easelSearch.refresh() }
    // The Space accent; Light/Dark follows the window (the bar reads its own effective appearance).
    let style = factory.focusedSpace.map { windowController.context.style(for: $0) }
    bar.theme = CommandBarTheme(style: style, isDark: ContentAppearance(bar.view.effectiveAppearance) == .dark)
    let peek = windowController.hasPeekController && windowController.peekController.isShown
    openingSelection = factory.selectedNodeID; openingProfile = profile.id
    openFirstResultsMilliseconds = nil; firstResultsMilliseconds = nil
    // Cmd+L edits the address in place, in a card anchored to the sidebar URL field (plan D3 §2.2).
    // A hidden sidebar, the content toolbar, and Edit Pinned Page keep the centred card.
    var presentation = CommandBarPresentation.overlay
    if mode == .editCurrentURL, pinned == nil, factory.windowState.sidebarMode == .anchored,
       let field = windowController.sidebar.urlFieldFrame(in: bar.view) {
      presentation = .anchored(CGRect(x: field.minX, y: field.minY + CommandCard.inlineTopOffset,
                                      width: max(CommandCard.inlineMinimumWidth, field.width), height: 0))
    }
    // The sidebar behind the card (anchored mode only; a hidden sidebar shows none).
    openedByUser = userInitiated; bar.closesOnModeKey = userInitiated
    bar.view.sidebarMaxX = factory.windowState.sidebarMode == .anchored && !windowController.sidebar.isHidden
      ? windowController.sidebar.convert(windowController.sidebar.bounds, to: bar.view).maxX : nil
    var request = CommandBarRequest(mode: mode, profileID: profile.id, spaceID: factory.focusedSpace?.id,
      currentTabID: pinned?.id ?? (peek ? nil : factory.selectedTab?.id),
      currentTabURL: pinned?.pinnedURL ?? (peek ? factory.selectedContent?.url : factory.selectedTab?.url),
      currentTabTitle: pinned?.displayTitle ?? (peek ? factory.selectedContent?.title : factory.selectedTab?.displayTitle),
      allowsRemoteSuggestions: !factory.isIncognito && profile.settings.searchSuggestEnabled && factory.app.settingsPresenter.prepareForRemoteSuggestions(profileID: profile.id), searchEngineID: profile.settings.searchEngineID)
    // "Undo <name>" / "Redo <name>" (Arc "Action to undo/redo an action by name"): the App's model undo stack.
    let undo = factory.app.undoManager
    // An unnamed step ("" — most model edits register no name) still offers plain "Undo"/"Redo".
    request.undoActionName = undo.canUndo ? undo.undoActionName : nil
    request.redoActionName = undo.canRedo ? undo.redoActionName : nil
    bar.present(request, presentation: presentation)
  }
  func contextDidChange() {
    guard isPresented else { return }
    if openingSelection != factory.selectedNodeID || openingProfile != factory.focusedProfile?.id {
      controller?.dismiss(reason: .programmatic)
    }
  }
  func dismiss() { controller?.dismiss(reason: .programmatic) }
  func commandBar(_ commandBar: CommandBarController, didChangePresentation presented: Bool, mode: CommandBarMode) {
    factory.controller?.isCommandBarPresented = presented
    factory.controller?.context.isNewTabCommandBarOpen = presented && mode == .newTab
    if !presented { factory.restorePageFocusIfUnclaimed() }
    factory.app.scheduleMenuRebuild()
  }
  func commandBar(_ commandBar: CommandBarController, perform intent: CommandBarIntent) {
    if let id = pinnedEditTabID {
      // Edit Pinned URL: a page or a search becomes the tab's pinned URL; any other row acts as usual.
      pinnedEditTabID = nil
      switch intent {
      case .open(let url, _, _), .search(_, let url, _, _, _): factory.updatePinnedURL(id, to: url); return
      default: break
      }
    }
    if commandBar.request?.mode == .editCurrentURL, WelcomeTab.matches(factory.selectedTab?.url),
       commandBar.text == WelcomeTab.title { return }
    switch intent {
    case .open(let url, let destination, let modifiers),
         .search(_, let url, _, let destination, let modifiers):
      // Option+Return: beside the current page in Split View (plan D3 §2.3).
      if modifiers.contains(.option), !modifiers.contains(.command), factory.openFromCommandBarInSplit(url) { break }
      factory.navigateFromCommandBar(url, current: destination == .currentTab, background: modifiers.contains(.command))
    case .switchToTab(let id, let space): factory.selectTabForCommand(id, spaceID: space)
    case .runAction(let id, let space):
      if let url = NewDocumentActions.url(for: id) {
        // "New Google Doc" and siblings (Arc's new-document table): a new foreground tab.
        factory.navigateFromCommandBar(url, current: false, background: false)
      } else if id == NewDocumentActions.undoByNameID {
        factory.app.undoManager.undo()
      } else if id == NewDocumentActions.redoByNameID {
        factory.app.undoManager.redo()
      } else {
        factory.controller?.performCommand(AppCommand.canonicalID(id), payload: space?.description)
      }
    case .copy(let value):
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
      factory.controller?.toasts.show(ToastContent(title: "Copied"))
    case .openSearchSettings(let profile):
      // Open keeps search engines per Profile: Settings ▸ Profiles for the bar's Profile (CC-42 "Search Settings…").
      factory.app.performCommand("search-settings", payload: (profile ?? factory.focusedProfile?.id)?.description)
    case .runExtensionAction(let id):
      factory.focusedBrowser?.executeExtensionAction(id, source: .menuEntry)
    case .extensionOmnibox(let id, let content, let destination, let modifiers):
      let disposition: OEOmniboxDisposition = modifiers.contains(.command) ? .newBackgroundTab
        : destination == .currentTab ? .currentTab : .newForegroundTab
      extensionSource.enter(content, extensionID: id, disposition: disposition)
    case .dismissed: break // didChangePresentation runs after the bar releases its editor.
    }
  }
  /// The (i) footer's "Dismiss": the same acknowledgement as Settings' notice ("Code 4"), then
  /// remote suggestions for this query when the Profile allows them (CC-42, D14).
  func commandBarDidDismissPrivacyNotice(_ commandBar: CommandBarController) {
    guard !factory.isIncognito else { return }
    let presenter = factory.app.settingsPresenter
    presenter.settings.profiles.dismissSuggestNotice()
    guard let profile = commandBar.request?.profileID.flatMap({ factory.app.model.profile(id: $0) }) else { return }
    commandBar.setAllowsRemoteSuggestions(profile.settings.searchSuggestEnabled && presenter.prepareForRemoteSuggestions(profileID: profile.id))
  }
  func stateForAutomation() -> [String: Any] {
    guard let bar = controller else { return ["created": false, "presented": false] }
    let range = (factory.window?.firstResponder as? NSTextView)?.selectedRange
    return ["created": true, "presented": bar.isPresented, "mode": bar.request?.mode.rawValue ?? "",
      "text": bar.text, "editorText": (factory.window?.firstResponder as? NSTextView)?.string ?? "", "editorCanUndo": (factory.window?.firstResponder as? NSTextView)?.undoManager?.canUndo ?? false, "profile": bar.request?.profileID?.description ?? "", "space": bar.request?.spaceID?.description ?? "",
      "selected": bar.selectedIndex ?? -1, "range": [range?.location ?? -1, range?.length ?? 0],
      "firstResultsMs": firstResultsMilliseconds ?? -1, "openFirstResultsMs": openFirstResultsMilliseconds ?? -1,
      "timingScope": "showCommandBar entry to first snapshot applied; excludes preceding key routing, socket transport and frame presentation",
      "final": bar.isSnapshotFinal, "newTabHighlighted": factory.controller?.context.isNewTabCommandBarOpen ?? false,
      "footer": bar.showsPrivacyFooter, "presentation": bar.view.presentationKind, "hidden": bar.view.isHidden, "animationKeys": bar.view.debugAnimationKeys,
      "panelOpacity": bar.view.debugPanelPresentationOpacity, "allAnimationKeys": bar.view.debugAllAnimationKeys,
      "panelFrame": { let f = bar.view.convert(bar.view.panelFrame, to: nil); let h = factory.window?.contentView?.bounds.height ?? 0
        return [f.minX, h - f.maxY, f.width, f.height] }(),
      "panelLayouts": bar.view.debugPanelLayoutCount, "rowDraws": bar.view.debugRowDrawCount,
      "resultsLayouts": bar.view.debugResultsLayoutCount, "rowUpdates": bar.view.debugRowUpdateCount, "snapshotSequence": bar.appliedSequence,
      "fieldWidth": bar.view.debugFieldFrame.width, "allowsRemote": bar.request?.allowsRemoteSuggestions ?? false,
      "scope": bar.scope?.title ?? "", "fieldText": bar.fieldText, "pinnedEdit": pinnedEditTabID?.description ?? "",
      "rows": bar.suggestions.map { ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title, "subtitle": $0.subtitle,
        "url": $0.url?.absoluteString ?? "", "tab": $0.tabID?.description ?? "",
        "space": $0.spaceID?.description ?? "", "action": $0.actionID ?? "",
        "extension": $0.extensionID ?? "", "content": $0.extensionContent ?? "", "keycaps": $0.shortcutKeys] }] as [String: Any]
  }
}
