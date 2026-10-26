import AppKit
import Observation
import OpenModel
import OpenDesign
import OpenSidebar
import OpenCommands
import OpenStore

@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, SidebarDelegate, CommandDispatcher {
    public let windowID: WindowID
    public let model: BrowserModel
    let root: FeatureRootView
    public let background = ThemeBackgroundView(frame: .zero)
    public let sidebar: SidebarView
    public let context: SidebarContext
    public let container: WebContentContainer
    public let splitController: SplitViewController
    public let peekController: PeekController
    public var visibilityOverride: OpenSleepWindowState?
    public var onOpenCommandBar: ((CommandBarSource, URL?) -> Void)?
    public var onVisibilityChange: (() -> Void)?
    public private(set) var pendingMoveMenu: NSMenu?
    private var treeObserver: UUID?
    private var keyMonitor: Any?
    private let keyboard = KeyboardRouter()
    private var observing = true
    private var observationArmed = false
    private var refreshPending = false
    private let snapshotStore: SnapshotStore?
    private let toast = NSView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var undoButton: ActionButton!
    private var toastUndo: (() -> Void)?
    public init(model: BrowserModel, windowID: WindowID, factory: any WebContentHostFactory, size: CGSize = CGSize(width: 2216, height: 1394), defaults: UserDefaults = .standard, snapshotStore: SnapshotStore? = nil) {
        self.model = model; self.windowID = windowID; self.snapshotStore = snapshotStore
        root = FeatureRootView(frame: CGRect(origin: .zero, size: size))
        context = SidebarContext(model: model, windowID: windowID); context.systemAppearance = .dark
        sidebar = SidebarView(context: context); container = WebContentContainer(factory: factory)
        splitController = SplitViewController(model: model, windowID: windowID, container: container)
        peekController = PeekController(model: model, splitController: splitController, factory: factory, defaults: defaults)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; super.init(window: window); window.contentView = root; window.delegate = self
        root.appearance = NSAppearance(named: .darkAqua)
        root.addSubview(background); root.addSubview(container); root.addSubview(sidebar); root.addSubview(peekController.overlay)
        sidebar.delegate = self; sidebar.themeBackground = background
        container.onLinkClicked = { [weak self] id, url, flags in self?.peekController.intercept(tabID: id, url: url, flags: flags) ?? true }
        container.onFocusedMetadata = { [weak self] in self?.window?.title = $0 }
        container.onURLField = { [weak self] in guard let self else { return }; self.onOpenCommandBar?(.urlField, self.context.currentTab?.url) }
        container.onToast = { [weak self] in self?.showToast($0, undo: nil) }
        splitController.onChange = { [weak self] in self?.changed() }
        peekController.onChange = { [weak self] in self?.changed() }
        peekController.onToast = { [weak self] in self?.showToast($0, undo: $1) }
        toast.wantsLayer = true; toast.layer?.cornerRadius = 8; toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        toastLabel.textColor = .white; toast.addSubview(toastLabel)
        undoButton = ActionButton(symbol: "arrow.uturn.backward", title: "Undo") { [weak self] in self?.toastUndo?() }
        undoButton.contentTintColor = .white; toast.addSubview(undoButton); root.addSubview(toast); toast.isHidden = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        treeObserver = model.addObserver { [weak self] _ in self?.scheduleRefresh() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                if event.keyCode == 53 {
                    if self.peekController.isShown { self.peekController.escape() }
                    else { self.splitController.performCommand("escape"); self.container.cancelOperation(nil) }; return true
                }
                if case .browserCommand(let id)? = self.keyboard.route(event: event, context: RoutingContext(isWebContentFocused: true)), self.handles(id) {
                    self.performCommand(id); return true
                }; return false
            }
            return consumed ? nil : event
        }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observing = false; if let treeObserver { model.removeObserver(treeObserver) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; container.closeAll() }
    private func scheduleRefresh() {
        guard !refreshPending else { return }; refreshPending = true
        DispatchQueue.main.async { [weak self] in guard let self, self.observing else { return }; self.refreshPending = false; self.refresh() }
    }
    public func refresh() {
        guard let space = context.focusedSpace else { return }
        if !observationArmed {
        observationArmed = true
        withObservationTracking {
            _ = context.currentTab?.url; _ = context.currentTab?.title; _ = context.window?.focusedSpaceID
            _ = context.window?.selectedNodeBySpace; _ = splitController.split?.focusedPaneID
            _ = splitController.split?.orientation; _ = splitController.split?.fractions
            for tab in splitController.split?.panes ?? context.currentTab.map({ [$0] }) ?? [] { _ = tab.live.sleepPhase }
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observationArmed = false; self?.scheduleRefresh() } }
        }
        background.style = context.style(for: space); container.style = context.style(for: space)
        let style = context.style(for: space)
        peekController.overlay.controlsFill = style.lightPalette?.title.nsColor ?? PeekMetrics.defaultControls.nsColor
        peekController.overlay.scrimColor = style.darkPalette?.background.withAlpha(PeekMetrics.scrimAlpha).nsColor ?? PeekMetrics.defaultScrim.nsColor
        splitController.refresh(); peekController.refresh(); layoutContent(); container.refreshPlaceholders(); onVisibilityChange?()
    }
    private func layoutContent() {
        let size = root.bounds.size, hidden = context.window?.sidebarMode == .hidden
        background.frame = root.bounds; sidebar.isHidden = hidden
        sidebar.frame = CGRect(x: 0, y: 0, width: context.sidebarWidth, height: size.height)
        container.frame = PanelMetrics.frame(windowSize: size, sidebarWidth: context.sidebarWidth, sidebarHidden: hidden)
        let overlay = peekController.overlay; overlay.frame = root.bounds; overlay.contentRect = container.frame
        overlay.baseWidth = hidden ? container.frame.width : size.width - context.sidebarWidth
        overlay.needsLayout = true
        toast.frame = CGRect(x: root.bounds.midX - 140, y: 24, width: 280, height: 34)
        toastLabel.frame = CGRect(x: 12, y: 7, width: 210, height: 20); undoButton?.frame = CGRect(x: 238, y: 3, width: 32, height: 28)
    }
    private func changed() { snapshotStore?.scheduleSave(model: model); peekController.refresh(); onVisibilityChange?() }
    private func showToast(_ title: String, undo: (() -> Void)?) { toastUndo = undo; toastLabel.stringValue = title; undoButton.isHidden = undo == nil; toast.isHidden = title.isEmpty }
    public var peekBadgeTabIDs: Set<ItemID> { peekController.peekBadgeTabIDs }
    private func handles(_ id: String) -> Bool { ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space", "go-back", "go-forward"].contains(id) || id.hasPrefix("focus-split-pane-") }
    public func performCommand(_ id: String) {
        if id == "open-in-current-space", peekController.isShown {
            let menu = NSMenu(title: "Open in Space")
            for space in model.spaces { menu.addItem(FeatureMenuItem(context.title(of: space)) { [weak self] in self?.peekController.expandTop(into: space.id) }) }
            pendingMoveMenu = menu
            if window?.isVisible == true { menu.popUp(positioning: nil, at: CGPoint(x: root.bounds.midX, y: root.bounds.midY), in: root) }
        }
        else if id == "go-back", peekController.isShown { peekController.stack.last?.host?.goBack() }
        else if id == "go-forward", peekController.isShown { peekController.stack.last?.host?.goForward() }
        else { splitController.performCommand(id) }
    }
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool { splitController.isCommandEnabled(id, enabledKey: enabledKey) }
    public func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        switch intent {
        case .newSplitView: splitController.addEmptyPane()
        case .openInSplitView(let id): splitController.openInSplit(id)
        case .addSplitView(let id):
            if let space = context.focusedSpace { model.selectNode(windowID: windowID, spaceID: space.id, nodeID: id) }; splitController.addEmptyPane()
        case .separateSplit(let id):
            let focused = model.node(id: id)?.split?.focusedPaneID; model.unsplit(splitID: id)
            if let space = context.focusedSpace { model.selectNode(windowID: windowID, spaceID: space.id, nodeID: focused) }
        case .goBack: if peekController.isShown { peekController.stack.last?.host?.goBack() } else { context.currentTab.flatMap { container.host(for: $0.id) }?.goBack() }
        case .goForward: if peekController.isShown { peekController.stack.last?.host?.goForward() } else { context.currentTab.flatMap { container.host(for: $0.id) }?.goForward() }
        default: guard ModelSidebarActions(context: context).perform(intent) else { return false }
        }
        refresh(); changed(); return true
    }
    public func windowWillClose(_ notification: Notification) { visibilityOverride = .closed; onVisibilityChange?() }
    public func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidChangeOcclusionState(_ notification: Notification) { onVisibilityChange?() }
}
