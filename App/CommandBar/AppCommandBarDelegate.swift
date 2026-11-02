import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenSuggest

/// One lazy native command-bar controller for one standard window.
@MainActor
final class AppCommandBarSession: CommandBarDelegate {
  unowned let factory: EngineWebContentHostFactory
  private(set) var controller: CommandBarController?
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
  func show(_ mode: CommandBarMode, requestedAt: Double, editingPinnedTab: ItemID? = nil) {
    openedAt = requestedAt
    let pinned = editingPinnedTab.flatMap { id in factory.model.tab(id: id).flatMap { $0.pinnedURL == nil ? nil : $0 } }
    pinnedEditTabID = pinned?.id
    guard let windowController = factory.controller, let profile = factory.focusedProfile else { return }
    if factory.window?.isKeyWindow != true || !NSApp.isActive {
      factory.app.focusWindow(factory.windowState.id, activate: true)
    }
    windowController.dismissSidebarReveal()
    let engine = factory.app.stores.suggest(for: profile.id)
    if controller?.engine !== engine {
      controller?.dismiss(reason: .programmatic)
      controller?.view.removeFromSuperview()
      let bar = CommandBarController(engine: engine)
      bar.delegate = self
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
    }
    guard let bar = controller else { return }
    let style = factory.focusedSpace.map { windowController.context.style(for: $0) }
    bar.theme = CommandBarTheme(style: style)
    if let color = factory.hosts.values.first(where: { $0.content === factory.selectedContent })?.pageBackgroundColor?.usingColorSpace(.sRGB) {
      let rgba = RGBA(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
      bar.backdrop = CommandBarBackdrop(color: rgba)
    } else {
      bar.backdrop = CommandBarBackdrop(color: style?.darkPalette?.background ?? CommandBarBackdrop.darkPage.color)
    }
    let peek = windowController.hasPeekController && windowController.peekController.isShown
    openingSelection = factory.selectedNodeID; openingProfile = profile.id
    openFirstResultsMilliseconds = nil; firstResultsMilliseconds = nil
    bar.present(CommandBarRequest(mode: mode, profileID: profile.id, spaceID: factory.focusedSpace?.id,
      currentTabID: pinned?.id ?? (peek ? nil : factory.selectedTab?.id),
      currentTabURL: pinned?.pinnedURL ?? (peek ? factory.selectedContent?.url : factory.selectedTab?.url),
      currentTabTitle: pinned?.displayTitle ?? (peek ? factory.selectedContent?.title : factory.selectedTab?.displayTitle),
      allowsRemoteSuggestions: profile.settings.searchSuggestEnabled && factory.app.settingsPresenter.prepareForRemoteSuggestions(profileID: profile.id), searchEngineID: profile.settings.searchEngineID))
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
    switch intent {
    case .open(let url, let destination, let modifiers),
         .search(_, let url, _, let destination, let modifiers):
      factory.navigateFromCommandBar(url, current: destination == .currentTab, background: modifiers.contains(.command))
    case .switchToTab(let id, let space): factory.selectTabForCommand(id, spaceID: space)
    case .runAction(let id, let space): factory.controller?.performCommand(AppCommand.canonicalID(id), payload: space?.description)
    case .copy(let value):
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
      factory.controller?.showToast("Copied", undo: nil)
    case .openSearchSettings(let profile):
      // Open keeps search engines per Profile: Settings ▸ Profiles for the bar's Profile (CC-42 "Search Settings…").
      factory.app.performCommand("search-settings", payload: (profile ?? factory.focusedProfile?.id)?.description)
    case .dismissed: break // didChangePresentation runs after the bar releases its editor.
    }
  }
  /// The (i) footer's "Dismiss": the same acknowledgement as Settings' notice ("Code 4"), then
  /// remote suggestions for this query when the Profile allows them (CC-42, D14).
  func commandBarDidDismissPrivacyNotice(_ commandBar: CommandBarController) {
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
      "footer": bar.showsPrivacyFooter, "hidden": bar.view.isHidden, "animationKeys": bar.view.debugAnimationKeys,
      "panelOpacity": bar.view.debugPanelPresentationOpacity, "allAnimationKeys": bar.view.debugAllAnimationKeys,
      "panelFrame": { let f = bar.view.convert(bar.view.panelFrame, to: nil); let h = factory.window?.contentView?.bounds.height ?? 0
        return [f.minX, h - f.maxY, f.width, f.height] }(),
      "fieldWidth": bar.view.debugFieldFrame.width, "allowsRemote": bar.request?.allowsRemoteSuggestions ?? false,
      "scope": bar.scope?.title ?? "", "fieldText": bar.fieldText, "pinnedEdit": pinnedEditTabID?.description ?? "",
      "rows": bar.suggestions.map { ["id": $0.id, "kind": $0.kind.rawValue, "title": $0.title,
        "url": $0.url?.absoluteString ?? "", "tab": $0.tabID?.description ?? "",
        "space": $0.spaceID?.description ?? "", "action": $0.actionID ?? ""] }] as [String: Any]
  }
}
