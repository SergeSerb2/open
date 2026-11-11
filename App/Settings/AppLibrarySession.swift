import AppKit
import OpenFeatures
import OpenLibrary
import OpenSettings

/// Data providers are App-owned. Selection, search and presentation belong to
/// one browser window. No session or panel exists on the launch path.
@MainActor
final class AppLibrarySession {
  let model: LibraryViewModel
  let presenter: LibraryPresenter
  weak var controller: BrowserWindowController?
  private(set) var panel: LibraryPanelView?
  private var releaseTask: Task<Void, Never>?
  private(set) var lastShowMilliseconds = 0.0
  #if OPEN_AUTOMATION
  var releaseDelay = 60.0
  #endif
  private(set) var panelGeneration = 0

  init(model: LibraryViewModel, controller: BrowserWindowController) {
    self.model = model; self.controller = controller
    model.usesLegacySpaceManager = false
    presenter = LibraryPresenter(viewModel: model)
    if let window = controller.window { presenter.attach(to: window) }
  }
  func show(section: LibrarySection?) {
    guard let controller else { return }
    let started = ProcessInfo.processInfo.systemUptime
    releaseTask?.cancel(); releaseTask = nil
    let panel: LibraryPanelView
    if let existing = self.panel { panel = existing }
    else {
      panel = LibraryPanelView(viewModel: model, context: controller.context)
      panel.onClose = { [weak self] in self?.close() }
      panel.onWidthChange = { [weak self] width in
        guard let self, let controller = self.controller, controller.isLibraryOpen, let panel = self.panel else { return }
        controller.presentLibraryPanel(panel, width: width)
      }
      self.panel = panel
      panelGeneration += 1
    }
    if let section { panel.select(LibraryPanelSection(section), animated: false) }
    panel.isPresented = true
    // Attach before asking the panel for its Spaces width.
    controller.presentLibraryPanel(panel, width: panel.section == .spaces ? (controller.contentView.bounds.width-56) : 417)
    controller.libraryKeyHandler = { [weak panel] in panel?.handleKey($0) ?? false }
    panel.focusRail()
    // This is dispatch/setup cost, not first-pixel or fully-drawn evidence.
    lastShowMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
  }
  func close() {
    guard let controller, controller.isLibraryOpen else { return }
    panel?.isPresented = false
    controller.dismissLibraryPanel()
    controller.window?.makeFirstResponder(controller.container)
    releaseTask?.cancel()
    #if OPEN_AUTOMATION
    let delay = releaseDelay
    #else
    let delay = 60.0
    #endif
    releaseTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, self.controller?.isLibraryOpen != true else { return }
      self.controller?.releaseLibraryPanel(); self.panel = nil; self.model.releaseContentViews(); self.releaseTask = nil
    }
  }
}
