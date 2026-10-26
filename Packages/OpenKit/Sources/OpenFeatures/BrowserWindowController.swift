import AppKit
import Observation
import OpenModel
import OpenDesign
import OpenSidebar
import OpenCommands
import OpenStore

@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, SidebarDelegate, CommandDispatcher {
    public var contentView: NSView { root }
    public let windowID: WindowID
    public let model: BrowserModel
    let root: BrowserRootView
    public let background = ThemeBackgroundView(frame: .zero)
    public let sidebar: SidebarView
    public let context: SidebarContext
    public let container: WebContentContainer
    public let splitController: SplitViewController
    private var peekStorage: PeekController?
    public var peekController: PeekController {
        if let peekStorage { return peekStorage }
        let peek = PeekController(model: model, splitController: splitController, factory: factory, defaults: defaults)
        peekStorage = peek
        root.addSubview(peek.overlay.backdrop, positioned: .below, relativeTo: sidebar)
        root.addSubview(peek.overlay, positioned: .below, relativeTo: toast)
        peek.onChange = { [weak self] in self?.changed() }
        peek.onToast = { [weak self] in self?.showToast($0, undo: $1) }
        peek.onPageChange = { [weak self] in self?.syncPeekSidebar() }
        if let space = context.focusedSpace {
            let style = context.style(for: space)
            peek.overlay.controlsFill = style.lightPalette?.title.nsColor ?? PeekMetrics.defaultControls.nsColor
            peek.overlay.scrimColor = style.darkPalette?.background.withAlpha(PeekMetrics.scrimAlpha).nsColor ?? PeekMetrics.defaultScrim.nsColor
        }
        layoutContent()
        return peek
    }
    private let factory: any WebContentHostFactory
    private let defaults: UserDefaults
    public var onSidebarIntent: ((SidebarIntent) -> Bool?)?
    public var onCommand: ((String) -> Bool)?
    public var onCommandWithPayload: ((String, String?) -> Bool)?
    public var onCommandValidation: ((String, String) -> Bool?)?
    public var ownsAdditionalKeyWindow: ((NSWindow) -> Bool)?
    public var isApplicationActive: (() -> Bool)?
    public var isCommandBarPresented = false
    public var keyBindingOverrides = KeyBindingStore.empty
    private var lastKeyRoute: (window: Int, code: UInt16, flags: UInt, timestamp: TimeInterval, handled: Bool)?
    public var onStateChange: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onFocus: (() -> Void)?
    public var onLayout: (() -> Void)?
    private var fullscreenTransition = false
    public private(set) var fullScreenTransitionCount = 0
    public var isChangingFullScreen: Bool { fullscreenTransition }
    /// Page fullscreen is transient and never changes the saved sidebar mode.
    public var isPageFullscreen = false {
        didSet { if isPageFullscreen { dismissSidebarReveal() }; layoutContent() }
    }
    public private(set) var isSidebarRevealed = false
    private let resizeHandle = SidebarResizeHandle()
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pointerMonitor: Any?
    private var layoutGeneration = 0
    private var resizingSidebar = false
    public var sidebarResizeFrame: CGRect { resizeHandle.frame }
    public var hasPeekController: Bool { peekStorage != nil }
    private let emptyPanel = WebPanelChromeLayer()
    private let emptyPanelHost = NSView()
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
    public init(model: BrowserModel, windowID: WindowID, factory: any WebContentHostFactory, size: CGSize? = nil, defaults: UserDefaults = .standard, snapshotStore: SnapshotStore? = nil) {
        self.model = model; self.windowID = windowID; self.snapshotStore = snapshotStore
        self.factory = factory; self.defaults = defaults
        let state = model.windows.first { $0.id == windowID }
        let dimensions = size ?? CGSize(width: max(640, state?.frameWidth ?? 1280), height: max(480, state?.frameHeight ?? 800))
        root = BrowserRootView(frame: CGRect(origin: .zero, size: dimensions))
        context = SidebarContext(model: model, windowID: windowID)
        context.systemAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        sidebar = SidebarView(context: context); container = WebContentContainer(factory: factory)
        splitController = SplitViewController(model: model, windowID: windowID, container: container)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.title = "Open"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed; window.isMovableByWindowBackground = false
        window.minSize = CGSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary); window.acceptsMouseMovedEvents = true
        super.init(window: window); window.contentView = root; window.delegate = self
        if let state { window.setFrame(CGRect(x: state.frameX, y: state.frameY, width: dimensions.width, height: dimensions.height), display: false) }
        root.onAppearance = { [weak self] in
            guard let self else { return }
            self.context.systemAppearance = self.root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            self.sidebar.themeBackground = self.background
            self.refresh()
        }
        root.addSubview(background)
        emptyPanelHost.wantsLayer = true; emptyPanelHost.layer?.addSublayer(emptyPanel)
        root.addSubview(emptyPanelHost)
        root.addSubview(container); root.addSubview(sidebar); root.addSubview(resizeHandle)
        resizeHandle.onResize = { [weak self] x, ended in self?.resizeSidebar(to: x, ended: ended) }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.trackSidebarPointer(self.root.convert(event.locationInWindow, from: nil)) }
            }
            return event
        }
        sidebar.delegate = self; sidebar.themeBackground = background
        container.onLinkClicked = { [weak self] id, url, flags in
            guard let self else { return true }
            if let peek = self.peekStorage { return peek.intercept(tabID: id, url: url, flags: flags) }
            let favorite: Bool = if case .favorites? = self.model.parent(of: id) { true } else { false }
            guard self.model.tab(id: id) != nil, self.model.isPinned(tabID: id) || favorite else { return true }
            return self.peekController.intercept(tabID: id, url: url, flags: flags)
        }
        container.onFocusedMetadata = { [weak self] in self?.window?.title = $0 }
        container.onURLField = { [weak self] in guard let self else { return }; self.onOpenCommandBar?(.urlField, self.context.currentTab?.url) }
        container.onToast = { [weak self] in self?.showToast($0, undo: nil) }
        splitController.onChange = { [weak self] in self?.changed() }
        toast.wantsLayer = true; toast.layer?.cornerRadius = 8; toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        toastLabel.textColor = .white; toast.addSubview(toastLabel)
        undoButton = ActionButton(symbol: "arrow.uturn.backward", title: "Undo") { [weak self] in self?.toastUndo?() }
        undoButton.contentTintColor = .white; toast.addSubview(undoButton); root.addSubview(toast); toast.isHidden = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDragBackground = { [weak self] event in self?.window?.performDrag(with: event) }
        treeObserver = model.addObserver { [weak self] _ in self?.scheduleRefresh() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return consumed ? nil : event
        }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observing = false; if let treeObserver { model.removeObserver(treeObserver) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; container.closeAll(); hoverTask?.cancel(); dismissTask?.cancel(); toastTask?.cancel(); if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }
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
            _ = context.window?.selectedNodeBySpace; _ = context.window?.sidebarMode; _ = context.window?.sidebarWidth; _ = splitController.split?.focusedPaneID
            _ = splitController.split?.orientation; _ = splitController.split?.fractions
            for tab in splitController.split?.panes ?? context.currentTab.map({ [$0] }) ?? [] { _ = tab.live.sleepPhase }
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observationArmed = false; self?.scheduleRefresh() } }
        }
        // Sidebar's pager owns theme transitions. Never reset its cross-fade here.
        if background.targetStyle != context.style(for: space) { background.crossfade(to: context.style(for: space), animated: window?.isVisible == true) }
        container.style = context.style(for: space)
        let style = context.style(for: space)
        peekStorage?.overlay.controlsFill = style.lightPalette?.title.nsColor ?? PeekMetrics.defaultControls.nsColor
        peekStorage?.overlay.scrimColor = style.darkPalette?.background.withAlpha(PeekMetrics.scrimAlpha).nsColor ?? PeekMetrics.defaultScrim.nsColor
        splitController.refresh()
        // M4 refresh guarantees that every visible split pane is bound. Keep
        // the single-pane path free of its former duplicate refresh.
        if container.slots.count > 1 { container.refreshPlaceholders() }
        peekStorage?.refresh(); layoutContent(); syncPeekSidebar(); onVisibilityChange?()
    }
    private func syncPeekSidebar() {
        var badges: [ItemID: SidebarPeekBadge] = [:]
        for item in peekStorage?.stack ?? [] { badges[item.sourceTabID] = SidebarPeekBadge(url: item.host?.currentURL ?? item.url, faviconPNG: item.faviconPNG) }
        if context.peekBadges != badges { context.peekBadges = badges }
        let shown: SidebarShownPeek?
        if let peek = peekStorage, peek.isShown, let item = peek.stack.last {
            shown = SidebarShownPeek(sourceNodeID: peek.sourceNodeID(of: item), url: item.host?.currentURL ?? item.url,
                canGoBack: item.host?.canGoBack ?? false, canGoForward: item.host?.canGoForward ?? false, isLoading: item.host?.isLoading ?? false)
        } else { shown = nil }
        if context.shownPeek != shown { context.shownPeek = shown }
    }
    public func prepareForInitialDisplay() {
        root.layoutSubtreeIfNeeded()
        background.prepareForSnapshot()
    }
    public func layoutContent(animated: Bool = false) {
        let size = root.bounds.size, hidden = isPageFullscreen || context.window?.sidebarMode == .hidden
        let width = context.sidebarWidth
        let panelFrame = isPageFullscreen ? root.bounds : PanelMetrics.frame(windowSize: size, sidebarWidth: width, sidebarHidden: hidden)
        background.frame = root.bounds
        emptyPanelHost.frame = root.bounds; emptyPanelHost.isHidden = !container.isHidden
        emptyPanel.frame = panelFrame
        let sidebarFrame = isSidebarRevealed ? CGRect(x: 5, y: 5, width: width, height: size.height - 10)
            : CGRect(x: hidden ? -width : 0, y: 0, width: width, height: size.height)
        if isSidebarRevealed {
            if case .anchored = sidebar.presentation { sidebar.presentation = .floatingCard }
        } else if case .floatingCard = sidebar.presentation { sidebar.presentation = .anchored }
        layoutGeneration += 1; let generation = layoutGeneration
        let animate = animated && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            sidebar.isHidden = false
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.22
                container.animator().frame = panelFrame; sidebar.animator().frame = sidebarFrame
                sidebar.animator().alphaValue = hidden && !isSidebarRevealed ? 0 : 1
            } completionHandler: { [weak self] in MainActor.assumeIsolated {
                guard let self, self.layoutGeneration == generation else { return }
                self.sidebar.isHidden = hidden && !self.isSidebarRevealed
            } }
        } else {
            container.frame = panelFrame; sidebar.frame = sidebarFrame
            sidebar.alphaValue = hidden && !isSidebarRevealed ? 0 : 1
            sidebar.isHidden = hidden && !isSidebarRevealed
        }
        resizeHandle.isHidden = hidden
        resizeHandle.frame = CGRect(x: width - 2, y: 0, width: 4, height: size.height)
        if let overlay = peekStorage?.overlay {
            overlay.backdrop.frame = root.bounds
            overlay.frame = root.bounds; overlay.contentRect = panelFrame
            overlay.baseWidth = hidden ? panelFrame.width : size.width - width; overlay.needsLayout = true
        }
        toast.frame = CGRect(x: root.bounds.midX - 140, y: size.height - 58, width: 280, height: 34)
        toastLabel.frame = CGRect(x: 12, y: 7, width: 210, height: 20); undoButton?.frame = CGRect(x: 238, y: 3, width: 32, height: 28)
        positionTrafficLights()
        onLayout?()
    }
    private func positionTrafficLights() {
        guard let window else { return }
        let controls: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, kind) in controls.enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            // System-drawn 12 pt circles: measured centers x=12/35/58, y=16.
            let center = parent.convert(CGPoint(x: 12 + CGFloat(index) * 23, y: 16), from: root)
            let origin = CGPoint(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            button.isHidden = isPageFullscreen || (context.window?.sidebarMode == .hidden && !isSidebarRevealed)
        }
    }
    public func toggleSidebar() {
        guard let state = context.window else { return }
        dismissSidebarReveal()
        model.setSidebarMode(windowID: windowID, mode: state.sidebarMode == .hidden ? .anchored : .hidden)
        layoutContent(animated: true); changed()
    }
    public func resizeSidebar(to x: CGFloat, ended: Bool) {
        guard let state = context.window else { return }
        resizingSidebar = !ended
        context.sidebarWidthOverride = min(500, max(228, x))
        // Below the resize floor, keep 228 pt with a small rubber-band offset.
        layoutContent()
        if x < 228 && !ended { sidebar.frame.origin.x = -(228 - x) * 0.15 }
        if ended {
            model.setSidebarWidth(windowID: windowID, width: Double(context.sidebarWidth))
            if x < 180 { model.setSidebarMode(windowID: windowID, mode: .hidden) }
            context.sidebarWidthOverride = nil
            layoutContent(animated: x < 180 || state.sidebarMode == .hidden); changed()
        }
    }
    public func trackSidebarPointer(_ point: CGPoint) {
        guard !isPageFullscreen, context.window?.sidebarMode == .hidden, peekStorage?.isShown != true,
              !context.isNewTabCommandBarOpen, !resizingSidebar else { dismissSidebarReveal(); return }
        if isSidebarRevealed {
            if sidebar.frame.contains(point) { dismissTask?.cancel(); dismissTask = nil }
            else if dismissTask == nil {
                dismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
                    self?.dismissSidebarReveal()
                }
            }
        } else if point.x >= 0 && point.x < 8 && point.y >= 0 && point.y <= root.bounds.height {
            guard hoverTask == nil else { return }
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled, let self else { return }
                self.hoverTask = nil; self.isSidebarRevealed = true; self.layoutContent()
            }
        } else { hoverTask?.cancel(); hoverTask = nil }
    }
    public func dismissSidebarReveal() {
        hoverTask?.cancel(); hoverTask = nil; dismissTask?.cancel(); dismissTask = nil
        if isSidebarRevealed { isSidebarRevealed = false; layoutContent() }
    }
    public func saveWindowState() {
        guard let window, !fullscreenTransition, !window.styleMask.contains(.fullScreen), let state = context.window else { return }
        let frame = window.frame
        state.frameX = frame.minX; state.frameY = frame.minY
        state.frameWidth = frame.width; state.frameHeight = frame.height
    }
    private func changed() { snapshotStore?.scheduleSave(model: model); peekStorage?.refresh(); syncPeekSidebar(); onStateChange?(); onVisibilityChange?() }
    public func showToast(_ title: String, undo: (() -> Void)?) {
        toastTask?.cancel(); toastUndo = undo; toastLabel.stringValue = title
        undoButton.isHidden = undo == nil; toast.isHidden = title.isEmpty
        if !title.isEmpty { toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5)); guard !Task.isCancelled else { return }
            self?.toast.isHidden = true; self?.toastUndo = nil
        } }
    }
    public var peekBadgeTabIDs: Set<ItemID> { peekStorage?.peekBadgeTabIDs ?? [] }
    /// Shared window-local key path. Focus comes from AppKit's current responder.
    @discardableResult public func handleKeyDown(_ event: NSEvent, unconsumed: Bool = false) -> Bool {
        guard let eventWindow = event.window,
              eventWindow === window || ownsAdditionalKeyWindow?(eventWindow) == true else { return false }
        let flags = event.modifierFlags.rawValue
        if let last = lastKeyRoute, last.window == eventWindow.windowNumber, last.code == event.keyCode,
           last.flags == flags, unconsumed || (event.timestamp > 0 && last.timestamp == event.timestamp) { return last.handled }
        if event.keyCode == 53, !isCommandBarPresented, let peek = peekStorage, peek.isShown {
            peek.escape()
            lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
            return true
        }
        let responder = eventWindow.firstResponder
        let view = responder as? NSView
        let textFocused = responder is NSTextView || responder is NSTextField
        func within(_ ancestor: NSView?) -> Bool {
            guard let view, let ancestor else { return false }
            return view === ancestor || view.isDescendant(of: ancestor)
        }
        let webFocused = !textFocused && (eventWindow !== window || container.slots.contains { within($0.contentHostView) }
            || (peekStorage?.isShown == true && within(peekStorage?.stack.last?.host?.view)))
        // Web editing keys go through Chromium's text system. Its unconsumed
        // hook can still offer them to the menu (for model undo, for example).
        let routing = RoutingContext(isAppActive: isApplicationActive?() ?? true,
            isCommandBarOpen: isCommandBarPresented || context.isNewTabCommandBarOpen,
            isSidebarFocused: within(sidebar), isTextFocused: textFocused || webFocused, isWebContentFocused: webFocused)
        let decision = KeyboardShortcut.from(event: event).map {
            keyboard.route(shortcut: $0, context: routing, overrides: keyBindingOverrides,
                now: Date(timeIntervalSinceReferenceDate: event.timestamp))
        }
        lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, false)
        // CEF can deliver a page event straight to the window. Keep native
        // edit actions on the same nil-target responder path in that layer.
        if case .system? = decision, webFocused, routing.isAppActive,
           let shortcut = KeyboardShortcut.from(event: event),
           let id = SystemCommandActions.command(for: shortcut, overrides: keyBindingOverrides),
           SystemCommandActions.isEnabled(id), SystemCommandActions.perform(id) {
            lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
            return true
        }
        guard case .browserCommand(let id)? = decision,
              handles(id) || onCommand != nil,
              isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) else { return false }
        // These bindings have window scope in the registry; restrict them to the
        // page here so sidebar controls and AppKit field editors retain their keys.
        if id.hasPrefix("focus-split-pane-"), !webFocused { return false }
        performCommand(id)
        lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
        return true
    }
    private func handles(_ id: String) -> Bool { ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space", "go-back", "go-forward"].contains(id) || id.hasPrefix("focus-split-pane-") }
    public func performCommand(_ id: String) {
        if onCommand?(id) == true { return }
        if id == "open-in-current-space", peekStorage?.isShown == true {
            let menu = NSMenu(title: "Open in Space")
            for space in model.spaces { menu.addItem(FeatureMenuItem(context.title(of: space)) { [weak self] in self?.peekStorage?.expandTop(into: space.id) }) }
            pendingMoveMenu = menu
            if window?.isVisible == true { menu.popUp(positioning: nil, at: CGPoint(x: root.bounds.midX, y: root.bounds.midY), in: root) }
        }
        else if id == "go-back", peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goBack() }
        else if id == "go-forward", peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goForward() }
        else { splitController.performCommand(id) }
    }
    public func performCommand(_ id: String, payload: String?) {
        if onCommandWithPayload?(id, payload) == true { return }
        performCommand(id)
    }
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool {
        if let enabled = onCommandValidation?(id, enabledKey) { return enabled }
        if id == "open-in-current-space" { return peekStorage?.isShown == true }
        if id == "go-back" { return peekStorage?.isShown == true ? peekStorage?.stack.last?.host?.canGoBack == true : splitController.focusedTab.flatMap { container.host(for: $0.id) }?.canGoBack == true }
        if id == "go-forward" { return peekStorage?.isShown == true ? peekStorage?.stack.last?.host?.canGoForward == true : splitController.focusedTab.flatMap { container.host(for: $0.id) }?.canGoForward == true }
        return splitController.isCommandEnabled(id, enabledKey: enabledKey)
    }
    public func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        if let handled = onSidebarIntent?(intent) { return handled }
        switch intent {
        case .toggleSidebar: toggleSidebar(); return true
        case .openCommandBar(let source): dismissSidebarReveal(); onOpenCommandBar?(source, context.currentTab?.url); return onOpenCommandBar != nil
        case .newSplitView: splitController.addEmptyPane()
        case .addTabToSplit(let id):
            guard model.node(id: id)?.split != nil else { return false }
            if let space = context.focusedSpace { model.selectNode(windowID: windowID, spaceID: space.id, nodeID: id) }
            splitController.addEmptyPane()
        case .openInSplitView(let id): splitController.openInSplit(id)
        case .addSplitView(let id):
            if let space = context.focusedSpace { model.selectNode(windowID: windowID, spaceID: space.id, nodeID: id) }; splitController.addEmptyPane()
        case .goBack: if peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goBack() } else { context.currentTab.flatMap { container.host(for: $0.id) }?.goBack() }
        case .goForward: if peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goForward() } else { context.currentTab.flatMap { container.host(for: $0.id) }?.goForward() }
        default: guard ModelSidebarActions(context: context).perform(intent) else { return false }
        }
        refresh(); changed(); return true
    }
    public func windowWillClose(_ notification: Notification) { saveWindowState(); visibilityOverride = .closed; dismissSidebarReveal(); container.closeAll(); onClose?(); onVisibilityChange?() }
    public var onTextUndoManager: ((NSWindow) -> UndoManager?)?
    private lazy var nativeTextUndoManager = UndoManager()
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let editor = onTextUndoManager?(window) { return editor }
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField { return nativeTextUndoManager }
        return model.undoManager
    }
    public func windowDidResize(_ notification: Notification) { layoutContent() }
    public func windowDidMove(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowDidEndLiveResize(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowWillEnterFullScreen(_ notification: Notification) { saveWindowState(); fullscreenTransition = true }
    public func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true }
    public func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?() }
    public func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?() }
    public func windowDidBecomeKey(_ notification: Notification) { context.isWindowActive = true; background.isWindowActive = true; onFocus?() }
    public func windowDidResignKey(_ notification: Notification) { context.isWindowActive = false; background.isWindowActive = false }
    public func windowDidBecomeMain(_ notification: Notification) { context.isWindowActive = true }
    public func windowDidResignMain(_ notification: Notification) { context.isWindowActive = window?.isKeyWindow == true }
    public func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidChangeOcclusionState(_ notification: Notification) { onVisibilityChange?() }
}


@MainActor
final class BrowserRootView: NSView {
    var onLayout: (() -> Void)?
    var onAppearance: (() -> Void)?
    var onDragBackground: ((NSEvent) -> Void)?
    override init(frame: CGRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < 10 { onDragBackground?(event) }
    }
}

@MainActor
final class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat, Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        guard let window, let root = window.contentView else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            onResize?(root.convert(next.locationInWindow, from: nil).x, next.type == .leftMouseUp)
            if next.type == .leftMouseUp { break }
        }
    }
}
