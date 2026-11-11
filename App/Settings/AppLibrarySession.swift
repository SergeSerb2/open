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
  private(set) weak var releasedPanel: LibraryPanelView?

  init(model: LibraryViewModel, controller: BrowserWindowController) {
    self.model = model; self.controller = controller
    model.usesLegacySpaceManager = false
  }
  func show(section: LibrarySection?) {
    guard let controller else { return }
    let started = ProcessInfo.processInfo.systemUptime
    releaseTask?.cancel(); releaseTask = nil
    let panel = prepareShell()
    if let section { panel.select(LibraryPanelSection(section), animated: false) }
    panel.isPresented = true
    // Attach before asking the panel for its Spaces width.
    controller.presentLibraryPanel(panel, width: panel.section == .spaces ? (controller.contentView.bounds.width-56) : 417)
    controller.libraryKeyHandler = { [weak panel] in panel?.handleKey($0) ?? false }
    panel.focusRail()
    // This is dispatch/setup cost, not first-pixel or fully-drawn evidence.
    lastShowMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
  }
  @discardableResult func prepareShell() -> LibraryPanelView {
    if let panel { return panel }
    let panel = LibraryPanelView(viewModel:model,context:controller!.context)
    panel.onClose = { [weak self] in self?.close() }
    panel.onWidthChange = { [weak self] width in
      guard let self,let controller = self.controller,controller.isLibraryOpen,controller.libraryWidth != width,let panel = self.panel else { return }
      controller.presentLibraryPanel(panel,width:width)
    }
    self.panel = panel; panelGeneration += 1
    panel.onIdleRefresh = { [weak self] in self?.controller?.onLibraryIdleRefresh?() }
    controller?.prepareLibraryPanel(panel,width:panel.section == .spaces ? max(417,(controller?.contentView.bounds.width ?? 1280)-56) : 417)
    return panel
  }
  func prebuild() async {
    guard controller?.isLibraryOpen == false else { return }
    let panel = prepareShell()
    if let completed = controller?.context.downloadBadge?.completedAt,Date().timeIntervalSince(completed)<60,panel.section != .downloads { panel.select(.downloads,animated:false) }
    await panel.prepareFirstScreen()
  }
  func close() {
    guard let controller, controller.isLibraryOpen else { return }
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
      try? await Task.sleep(for: .seconds(delay))
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
