import AppKit
import OpenFeatures
import OpenLibrary
import OpenSettings

/// Data providers are App-owned. Selection, search and presentation belong to
/// one browser window. No session or panel exists on the launch path.
@MainActor
final class AppLibrarySession {
  let model: LibraryViewModel
  weak var controller: BrowserWindowController?
  private(set) var panel: LibraryPanelView?
  private var releaseTask: Task<Void, Never>?
  private(set) var lastShowMilliseconds = 0.0
  #if OPEN_AUTOMATION
  var releaseDelay = 60.0
  private(set) var releaseScheduledAt = 0.0
  private(set) var releaseFiredAt = 0.0
  var releasePending: Bool { releaseTask != nil }
  #endif
  private(set) var panelGeneration = 0
  /// Library › Easels data (EZ); the panel holds it weakly.
  private(set) var easelsProvider: EaselLibraryProvider?
  private(set) var notesProvider: NoteLibraryProvider?
  private(set) weak var releasedPanel: LibraryPanelView?

  init(model: LibraryViewModel, controller: BrowserWindowController) {
    self.model = model; self.controller = controller
    model.usesLegacySpaceManager = false
    // Idle preparation must build the owner's first screen, not an All
    // Profiles snapshot which the first outside entry immediately replaces.
    if let owner = controller.context.focusedSpace?.profileID {
      model.downloadProfileFilter = owner
      if model.historyProfileID != owner { model.historyProfileID = owner }
    }
  }
  func show(section: LibrarySection?) {
    guard let controller else { return }
    let started = ProcessInfo.processInfo.systemUptime
    releaseTask?.cancel(); releaseTask = nil
    let panel = prepareShell()
    if let section, !controller.isLibraryOpen || panel.section != LibraryPanelSection(section) {
      panel.select(LibraryPanelSection(section), animated: false)
    }
    panel.isPresented = true
    // Easels change outside the Library (new, renamed, deleted): read them again on each open.
    panel.reloadEasels()
    // Attach before asking the panel for its Spaces width.
    controller.presentLibraryPanel(panel, width: panel.section == .spaces ? (controller.contentView.bounds.width-56) : 417)
    controller.libraryKeyHandler = { [weak panel] in panel?.handleKey($0) ?? false }
    panel.focusRail()
    // This is dispatch/setup cost, not first-pixel or fully-drawn evidence.
    lastShowMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
  }
  @discardableResult func prepareShell() -> LibraryPanelView {
    if let panel { return panel }
    LibraryPanelView.deferIdlePreparation(until:ProcessInfo.processInfo.systemUptime+max(0,2-LaunchTiming.shared.elapsedMilliseconds/1000))
    let panel = LibraryPanelView(viewModel:model,context:controller!.context)
    panel.onClose = { [weak self] in self?.close() }
    panel.onWidthChange = { [weak self] width in
      guard let self,let controller = self.controller,controller.isLibraryOpen,controller.libraryWidth != width,let panel = self.panel else { return }
      controller.presentLibraryPanel(panel,width:width)
    }
    self.panel = panel; panelGeneration += 1
    panel.onIdleRefresh = { [weak self] in self?.controller?.onLibraryIdleRefresh?() }
    if let app = NSApp.delegate as? AppDelegate {
      let easels = easelsProvider ?? EaselLibraryProvider(app: app)
      easels.controller = controller
      easelsProvider = easels
      panel.easelsProvider = easels
      let notes = notesProvider ?? NoteLibraryProvider(app: app)
      notes.controller = controller
      notesProvider = notes
      panel.notesProvider = notes
    }
    controller?.prepareLibraryPanel(panel,width:panel.section == .spaces ? max(417,(controller?.contentView.bounds.width ?? 1280)-56) : 417)
    return panel
  }
  func prebuild() async {
    if controller?.isLibraryOpen == true { await panel?.warmSectionPages(); return }
    let panel = prepareShell()
    if let completed = controller?.context.downloadBadge?.completedAt,Date().timeIntervalSince(completed)<60,panel.section != .downloads { panel.select(.downloads,animated:false) }
    await panel.prepareFirstScreen()
  }
  func cancelIdleWork() { panel?.cancelIdleWork() }
  func close() {
    guard let controller, controller.isLibraryOpen else { return }
    if controller.hasPeekController, controller.peekController.stack.last?.librarySpaceID != nil {
      controller.peekController.dismissAll()
    }
    panel?.isPresented = false
    controller.dismissLibraryPanel()
    panel?.onIdleRefresh?()
    controller.window?.makeFirstResponder(controller.container)
    releaseTask?.cancel()
    #if OPEN_AUTOMATION
    let delay = releaseDelay
    releaseScheduledAt = ProcessInfo.processInfo.systemUptime; releaseFiredAt = 0
    #else
    let delay = 60.0
    #endif
    releaseTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay), tolerance: .zero)
      guard !Task.isCancelled, let self, self.controller?.isLibraryOpen != true else { return }
      #if OPEN_AUTOMATION
      self.releaseFiredAt = ProcessInfo.processInfo.systemUptime
      #endif
      self.releasedPanel = self.panel
      self.controller?.releaseLibraryPanel(); self.panel = nil; self.model.releaseContentViews(); self.releaseTask = nil
    }
  }
  /// The window-close delegate defers this until its callback has returned.
  func dispose() {
    releaseTask?.cancel(); releaseTask = nil
    panel?.isPresented = false
    controller?.dismissLibraryPanel(animated: false)
    controller?.releaseLibraryPanel()
    panel?.removeFromSuperview(); panel = nil
    model.releaseContentViews()
  }
}
