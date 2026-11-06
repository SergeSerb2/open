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
        root.addSubview(peek.overlay, positioned: .below, relativeTo: toastOverlay)
        peek.onChange = { [weak self] in self?.changed() }
        peek.toasts = toasts
        peek.onPageChange = { [weak self] in self?.syncPeekSidebar() }
        if let space = context.focusedSpace {
            let style = context.style(for: space)
            peek.overlay.style = style
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
    /// Runtime menu state from the App (page-platform §7.1); nil keeps the item as built.
    public var onMenuState: ((String) -> CommandMenuState?)?
    /// Sees every key event of this window first (after the tab switcher); true consumes it.
    public var keyInterceptor: ((NSEvent) -> Bool)?
    /// A native field editor retains plain editing keys before Peek/window routes.
    public var shouldDeferKeyToFirstResponder: ((NSEvent) -> Bool)?
    public var ownsAdditionalKeyWindow: ((NSWindow) -> Bool)?
    public var isApplicationActive: (() -> Bool)?
    public var isCommandBarPresented = false
    public var keyBindingOverrides = KeyBindingStore.empty
    /// The actual key only while dispatching a switcher command; menu actions have none.
    public private(set) var tabSwitcherKeyEvent: NSEvent?
    private var lastKeyRoute: (window: Int, code: UInt16, flags: UInt, timestamp: TimeInterval, handled: Bool)?
    public var onStateChange: (() -> Void)?
    public var onClose: (() -> Void)?
    /// Ordinary keys, selection and window layout never create switcher state.
    public private(set) var existingTabSwitcher: TabSwitcherController?
    public var tabSwitcher: TabSwitcherController {
        if let existingTabSwitcher { return existingTabSwitcher }
        let switcher = TabSwitcherController()
        existingTabSwitcher = switcher
        return switcher
    }
    public var onFocus: (() -> Void)?
    public var onLayout: (() -> Void)?
    private var fullscreenTransition = false
    public private(set) var fullScreenTransitionCount = 0
    public var isChangingFullScreen: Bool { fullscreenTransition }
    /// Page fullscreen is transient and never changes the saved sidebar mode.
    public var isPageFullscreen = false {
        didSet { if isPageFullscreen { dismissSidebarReveal() }; layoutContent() }
    }
    /// The hover-reveal card shows (or is sliding out).
    public var isSidebarRevealed: Bool { reveal.isShown }
    private let resizeHandle = SidebarResizeHandle()
    private let reveal = SidebarRevealController()
    private let cardShadow = RevealCardShadowView()
    private enum CardState { case off, shown, hiding }
    private var cardState = CardState.off
    private var cardGeneration = 0
    private var trafficLightObservers: [NSObjectProtocol] = []
    private var placingTrafficLights = false
    /// Arc's window buttons at rest (docs/design.md §2.2): the system buttons fade out and
    /// this view shows the dimmed circles; the pointer over the group shows the system
    /// buttons again (colors, glyphs, the tiling menu, Option-click).
    private let dimmedLights = DimmedTrafficLightsView()
    private var trafficLightsHovered = false
    private var appliedTrafficLightDim: Bool?
    private struct WeakView { weak var view: NSView? }
    private var observedTrafficLightViews: [WeakView] = []
    /// Automation builds drive the pointer with tagged events; this lets them ignore the
    /// hardware pointer so a test is not disturbed by someone using the Mac. nil: accept all.
    public static var pointerEventFilter: ((NSEvent) -> Bool)?
    /// The automation pointer's position (window number, window base coordinates), set with
    /// `pointerEventFilter`. While automation drives the pointer, the window buttons' hover
    /// state reads this instead of the hardware pointer.
    public static var automationPointer: (window: Int, location: NSPoint)?
    /// Automation builds can turn this off to keep a capture-size frame on a smaller screen.
    public static var constrainsFramesToScreen = true
    private var pointerMonitor: Any?
    private var captureMonitor: Any?
    private var captureStorage: CaptureController?
    /// The Capture tool (page-platform §4.6), made on first use.
    /// The Capture tool's selection overlay came up or went away (page swipes pause meanwhile).
    public var onCaptureOverlayChange: ((Bool) -> Void)?
    public var capture: CaptureController {
        if let captureStorage { return captureStorage }
        let capture = CaptureController(root: root, defaults: defaults)
        captureStorage = capture
        capture.onOverlayChange = { [weak self] up in self?.onCaptureOverlayChange?(up) }
        capture.library = captureLibrary
        capture.pageTarget = { [weak self] in self?.capturePageTarget() }
        capture.anchor = { [weak self] in
            guard let self else { return .zero }
            let panel = self.container.frame
            return CGPoint(x: panel.maxX - CaptureMetrics.anchorTrailing, y: panel.minY + CaptureMetrics.anchorTop)
        }
        capture.style = { [weak self] in
            guard let self, let space = self.context.focusedSpace else { return .defaultTheme(system: .dark) }
            return self.context.style(for: space)
        }
        // The window's toasts (page-platform §4.1.4 catalog).
        var hooks = CaptureToastHooks()
        hooks.progress = { [weak self] in
            let handle = self?.toasts.show(ToastContent(title: "Capture in Progress", isSticky: true))
            return { handle?.dismiss() }
        }
        hooks.copied = { [weak self] in self?.toasts.show(ToastContent(title: "Copied Image")) }
        hooks.shortcutHint = { [weak self] in
            self?.toasts.show(ToastContent(title: "and drag your mouse to capture any time.", accessory: .keycaps(["⌘", "⇧"])))
        }
        hooks.failed = { [weak self] in self?.toasts.show(ToastContent(title: $0)) }
        hooks.dismissAll = { [weak self] in self?.toasts.dismissAll() }
        capture.toasts = hooks
        return capture
    }
    /// Where captures are saved (the App's Library writer); nil saves nothing.
    public weak var captureLibrary: (any CaptureLibrary)? { didSet { captureStorage?.library = captureLibrary } }
    /// The capture overlay shows: history swipes must not navigate (EP-1 reads this, §4.4).
    public var captureOverlayActive: Bool { captureStorage?.isOverlayActive == true }
    /// The page a capture takes: the top Peek page while Peek shows, else the focused pane.
    public func captureHost() -> (any WebContentHost)? {
        if let peek = peekStorage, peek.isShown { return peek.stack.last?.host }
        return splitController.focusedTab.flatMap { container.host(for: $0.id) }
    }
    private func capturePageTarget() -> CaptureController.PageTarget? {
        guard let host = captureHost(), let provider = host as? WebContentProviding, let content = provider.webContent,
              host.view.window != nil, !host.view.isHidden else { return nil }
        return .init(url: host.currentURL, title: host.title, content: content, view: host.view, isPrivate: provider.isPrivateBrowsing)
    }
    private var sidebarAnimationGeneration = 0
    private var anchoredSliding = false
    private var sidebarMotionRequestedAt: CFTimeInterval?
    private var dragStartWidth: CGFloat?
    /// Actual animations read back from the layer when scheduled, retained after completion.
    public private(set) var sidebarAnimations: [String: CAAnimation] = [:]
    public private(set) var cardAnimations: [String: CAAnimation] = [:]
    public private(set) var sidebarWidthCommits = 0
    public private(set) var sidebarGestureHides = 0
    public private(set) var sidebarGeometryChanges = 0
    public var samplesCardMotion = false
    public private(set) var cardMotionSamples: [(time: Double, offset: Double)] = []
    private var cardSampleTask: Task<Void, Never>?
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
    /// Toasts over the web panel (page-platform §4.1, D-1): one center per window.
    public let toastOverlay = ToastOverlayView()
    public private(set) lazy var toasts = ToastCenter(overlay: toastOverlay) { [weak self] in
        guard let self else { return .defaultTheme(system: .dark) }
        if let space = self.context.focusedSpace { return self.context.style(for: space) }
        return .defaultTheme(system: self.context.systemAppearance)
    }
    /// First-hide hint (completion §3.12); `open.sidebar.hideHintShown` records that it showed.
    public static let hideHintShownKey = "open.sidebar.hideHintShown"
    public private(set) var hintToast: HintToastView?
    public private(set) var hintShows = 0
    /// Scheduled fade-out time of the shown hint (CACurrentMediaTime), for checks.
    public private(set) var hintFadeDeadline: CFTimeInterval?
    public private(set) var hintShownAt: CFTimeInterval?
    public private(set) var hintAnimations: [String: CAAnimation] = [:]
    /// The hint's one pending deadline (fade-out, then removal); a work item, not a timer.
    private var hintWork: DispatchWorkItem?
    /// Hover Previews of folders, pinned tabs, and Favorites (completion §3.6, A2).
    public private(set) lazy var hoverPreview = HoverPreviewController(root: root, container: container, factory: factory, context: context) { [weak self] id in
        guard let self, let space = self.context.focusedSpace else { return }
        _ = self.sidebar(self.sidebar, didRequest: .select(nodeID: id, space: space.id))
    }
    /// The delete confirmation sheet currently shown on this window (completion §3.3).
    public private(set) var pendingConfirmation: NSAlert?
    /// Title of the newest toast shown, for checks.
    public var lastToastTitle: String { toasts.lastTitle }
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
        let window = BrowserWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.title = "Open"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed; window.isMovableByWindowBackground = false
        window.minSize = CGSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary); window.acceptsMouseMovedEvents = true
        super.init(window: window); window.contentView = root; window.delegate = self
        window.onLayoutPass = { [weak self] in self?.placeTrafficLights() }
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
        root.addSubview(container); root.addSubview(cardShadow); root.addSubview(sidebar); root.addSubview(resizeHandle)
        cardShadow.isHidden = true
        resizeHandle.onBegin = { [weak self] in self?.beginSidebarResize() }
        resizeHandle.onCancel = { [weak self] in
            self?.resizingSidebar = false; self?.dragStartWidth = nil
        }
        resizeHandle.onReset = { [weak self] in self?.resetSidebarWidth() }
        resizeHandle.onResize = { [weak self] x, ended in self?.resizeSidebar(to: x, ended: ended) }
        reveal.geometry = { [weak self] in
            guard let self else { return .init(bounds: .zero, card: .zero, trafficLights: .zero) }
            let lights = ChromeMetrics.trafficLightFrames
            return .init(bounds: self.root.bounds,
                card: WindowMetrics.revealCardFrame(windowSize: self.root.bounds.size, sidebarWidth: self.context.sidebarWidth),
                trafficLights: CGRect(x: 0, y: 0, width: lights[2].maxX + lights[0].minX, height: RevealMetrics.trafficLightRegionHeight))
        }
        reveal.isEnabled = { [weak self] in
            guard let self else { return false }
            return !self.isPageFullscreen && self.context.window?.sidebarMode == .hidden && self.peekStorage?.isShown != true
                && !self.context.isNewTabCommandBarOpen && !self.resizingSidebar
        }
        reveal.onChange = { [weak self] shown in self?.setRevealCard(shown) }
        // Another app took the pointer: no more pointer events will come to hide the card.
        // Not while automation drives the pointer: then the hardware pointer is ignored, and
        // a deactivation comes from someone using the Mac, not from the check.
        trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard BrowserWindowController.pointerEventFilter == nil else { return }
                self?.dismissSidebarReveal()
            }
        })
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window, BrowserWindowController.pointerEventFilter?(event) ?? true {
                    self.trackSidebarPointer(self.root.convert(event.locationInWindow, from: nil))
                }
            }
            return event
        }
        // Cmd+Shift drag to capture (§4.6.2). Returns at once unless the press has exactly
        // Cmd+Shift, or a held press is in progress; the capture controller is made lazily.
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // A plain press also ends a held one whose mouse-up never came (another app took it).
                if self.captureStorage?.isHoldingPress != true {
                    guard event.type == .leftMouseDown, event.window === self.window,
                          event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift] else { return false }
                }
                return self.capture.handleMouse(event)
            }
            return consumed ? nil : event
        }
        sidebar.delegate = self; sidebar.themeBackground = background
        container.onLinkClicked = { [weak self] id, url, flags in
            guard let self else { return true }
            if let peek = self.peekStorage { return peek.intercept(tabID: id, url: url, flags: flags) }
            let favorite: Bool = if case .favorites? = self.model.parent(of: id) { true } else { false }
            guard self.model.tab(id: id) != nil, self.model.isPinned(tabID: id) || favorite || flags.contains(.shift) else { return true }
            return self.peekController.intercept(tabID: id, url: url, flags: flags)
        }
        container.onReturnPreviewHost = { [weak self] in
            self?.hoverPreview.hide(animated: false); self?.context.hoverPreviews.dismiss()
        }
        container.onFocusedMetadata = { [weak self] in self?.window?.title = $0 }
        container.onURLField = { [weak self] in guard let self else { return }; self.onOpenCommandBar?(.urlField, self.context.currentTab?.url) }
        container.toasts = toasts
        container.onToolbarMenu = { [weak self] in self?.makeToolbarMenu() }
        splitController.onChange = { [weak self] in self?.changed() }
        root.addSubview(toastOverlay)
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDragBackground = { [weak self] event in self?.window?.performDrag(with: event) }
        treeObserver = model.addObserver { [weak self] _ in self?.scheduleRefresh() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyDown(event)
            }
            return consumed ? nil : event
        }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { hintWork?.cancel(); observing = false; if let treeObserver { model.removeObserver(treeObserver) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; container.closeAll(); reveal.reset(); cardSampleTask?.cancel(); if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }; captureStorage?.tearDown(); trafficLightObservers.forEach(NotificationCenter.default.removeObserver) }
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
            _ = context.window?.selectedNodeBySpace; _ = context.window?.sidebarMode; _ = context.window?.sidebarWidth; _ = context.window?.showsToolbar; _ = splitController.split?.focusedPaneID
            _ = splitController.split?.orientation; _ = splitController.split?.fractions
            for tab in splitController.split?.panes ?? context.currentTab.map({ [$0] }) ?? [] { _ = tab.live.sleepPhase }
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observationArmed = false; self?.scheduleRefresh() } }
        }
        // Sidebar's pager owns theme transitions. Never reset its cross-fade here.
        if background.targetStyle != context.style(for: space) { background.crossfade(to: context.style(for: space), animated: window?.isVisible == true && !Motion.reducesMotion) }
        container.style = context.style(for: space)
        container.showsToolbar = context.window?.showsToolbar == true
        let style = context.style(for: space)
        peekStorage?.overlay.style = style
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
        if background.frame != root.bounds { background.frame = root.bounds }
        if let hint = hintToast {
            let w = hint.frame.width
            hint.setFrameOrigin(CGPoint(x: size.width - HintToastMetrics.trailingInset - w, y: HintToastMetrics.topInset))
        }
        if emptyPanelHost.frame != root.bounds { emptyPanelHost.frame = root.bounds }
        emptyPanelHost.isHidden = !container.isHidden
        let animate = animated && window?.isVisible == true && !Motion.reducesMotion
        let requestedAt = sidebarMotionRequestedAt ?? CACurrentMediaTime()
        if animate { sidebarMotionRequestedAt = nil }
        // Presentation reads are needed only to start/reverse a visible animation,
        // never while building the first window or following a plain width/resize tick.
        let oldPanel = animate ? (container.layer?.presentation()?.frame ?? container.frame) : container.frame
        let modelOffset = sidebar.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let oldOffset = animate ? (sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? modelOffset) : modelOffset
        if cardState != .off {
            let card = WindowMetrics.revealCardFrame(windowSize: size, sidebarWidth: width)
            if sidebar.frame != card { sidebar.frame = card }
            if cardShadow.frame != card { cardShadow.frame = card }
            if container.frame != panelFrame { container.frame = panelFrame }
            if emptyPanel.frame != panelFrame { emptyPanel.frame = panelFrame }
        } else {
            // Set geometry once. Core Animation moves the panel and the sidebar layers;
            // no row layout or model width write runs on the animation's display ticks.
            let sidebarFrame = CGRect(x: 0, y: 0, width: width, height: size.height)
            let targetOffset: CGFloat = hidden ? -width : 0
            let geometryChanged = container.frame != panelFrame || sidebar.frame != sidebarFrame
            if geometryChanged { sidebarGeometryChanges += 1 }
            let targetChanged = (sidebar.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0) != targetOffset
            if case .floatingCard = sidebar.presentation { sidebar.presentation = .anchored }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if container.frame != panelFrame { container.frame = panelFrame }
            if emptyPanel.frame != panelFrame { emptyPanel.frame = panelFrame }
            if sidebar.frame != sidebarFrame { sidebar.frame = sidebarFrame }
            sidebar.alphaValue = 1
            sidebar.layer?.setValue(targetOffset, forKeyPath: "transform.translation.x")
            CATransaction.commit()
            if animate || geometryChanged || targetChanged || Motion.reducesMotion {
                sidebarAnimationGeneration += 1
                let generation = sidebarAnimationGeneration
                anchoredSliding = animate
                container.setSidebarSliding(animate)
                sidebarAnimations = [:]
                sidebar.isHidden = animate ? false : hidden
                positionTrafficLights()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
                    guard let self, self.sidebarAnimationGeneration == generation else { return }
                    self.anchoredSliding = false
                    self.container.setSidebarSliding(false)
                    if self.cardState == .off {
                        self.sidebar.isHidden = hidden
                        // Keep the live width through a flick's hide animation. Restoring
                        // the stored width before completion would cancel the slide.
                        if hidden && !self.resizingSidebar && self.context.sidebarWidthOverride != nil {
                            self.context.sidebarWidthOverride = nil
                            self.layoutContent()
                        }
                        self.positionTrafficLights()
                    }
                } }
                let layers = [sidebar.layer, dimmedLights.layer].compactMap { $0 }
                    + Self.trafficLightKinds.compactMap { window?.standardWindowButton($0)?.layer }
                for (index, layer) in layers.enumerated() {
                    layer.removeAnimation(forKey: "sidebarToggle")
                    layer.setValue(targetOffset, forKeyPath: "transform.translation.x")
                    if animate {
                        let spring = Motion.sidebarToggle.animation(keyPath: "transform.translation.x")
                        spring.fromValue = oldOffset; spring.toValue = targetOffset
                        addMotion(spring, to: layer, key: "sidebarToggle", requestedAt: requestedAt)
                        if index == 0 { sidebarAnimations["sidebar"] = layer.animation(forKey: "sidebarToggle") }
                    }
                }
                for (name, layer) in [("panel", container.layer), ("emptyPanel", Optional(emptyPanel))] {
                    layer?.removeAnimation(forKey: "sidebarToggle")
                    if animate, let layer {
                        let group = CAAnimationGroup()
                        let fromPosition = CGPoint(x: oldPanel.minX + oldPanel.width * layer.anchorPoint.x,
                            y: oldPanel.minY + oldPanel.height * layer.anchorPoint.y)
                        group.animations = [
                            frameSpring("position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position)),
                            frameSpring("bounds.size", from: NSValue(size: oldPanel.size), to: NSValue(size: panelFrame.size))]
                        group.duration = group.animations!.map(\.duration).max() ?? 0
                        addMotion(group, to: layer, key: "sidebarToggle", requestedAt: requestedAt)
                        sidebarAnimations[name] = layer.animation(forKey: "sidebarToggle")
                    }
                }
                CATransaction.commit()
            } else if !anchoredSliding { sidebar.isHidden = hidden }
        }
        resizeHandle.isHidden = hidden && !resizingSidebar
        resizeHandle.frame = CGRect(x: width - 2, y: 0, width: 4, height: size.height)
        if let overlay = peekStorage?.overlay {
            overlay.backdrop.frame = root.bounds
            overlay.frame = root.bounds; overlay.contentRect = panelFrame
            overlay.baseWidth = hidden ? panelFrame.width : size.width - width; overlay.needsLayout = true
        }
        // Toasts anchor at the web panel's top-right (PG-1.1); the whole panel in Split View (lead Q10).
        if toastOverlay.frame != panelFrame { toastOverlay.frame = panelFrame }
        positionTrafficLights()
        hoverPreview.layout()
        captureStorage?.layout()
        onLayout?()
    }
    private func frameSpring(_ key: String, from: NSValue, to: NSValue) -> CASpringAnimation {
        let spring = Motion.sidebarToggle.animation(keyPath: key)
        spring.fromValue = from; spring.toValue = to
        return spring
    }
    private func addMotion(_ animation: CAAnimation, to layer: CALayer, key: String, requestedAt: CFTimeInterval? = nil) {
        let request = requestedAt ?? CACurrentMediaTime()
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            + (key == "sidebarToggle" ? Motion.sidebarDelayOverride ?? 0 : 0)
        animation.setValue(layer.convertTime(request, from: nil), forKey: "openRequestedAt")
        layer.add(animation, forKey: key)
    }

    private static let trafficLightKinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// The system traffic lights, centered at x 20 / 43 / 66, y 24 (Arc AX frames `[12/35/58,
    /// 16, 16, 16]`, F0001/F0131), and 5 pt further in on the hover-reveal card (F0129). Hidden
    /// while the sidebar is hidden and no card shows (F0128).
    ///
    /// AppKit lays the title bar out again on resize, key changes, full-screen exit, and when
    /// the pointer crosses the buttons, and during that layout it moves a button's siblings
    /// back when one is moved. So the buttons are placed after AppKit's layout pass and before
    /// the window draws (`BrowserWindow.onLayoutPass`), where AppKit leaves them be; frame
    /// observers place a moved button at once as well.
    private func positionTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        observeTrafficLights(window)
        let hidden = isPageFullscreen || (cardState == .off && context.window?.sidebarMode == .hidden && !anchoredSliding)
        for kind in Self.trafficLightKinds {
            guard let button = window.standardWindowButton(kind) else { continue }
            if button.isHidden != hidden { button.isHidden = hidden }
        }
        placeTrafficLights()
    }

    private func placeTrafficLights() {
        guard !placingTrafficLights, let window, !window.styleMask.contains(.fullScreen) else { return }
        placingTrafficLights = true
        defer { placingTrafficLights = false }
        let inset = cardState == .off ? 0 : WindowMetrics.revealCardInset
        for (index, kind) in Self.trafficLightKinds.enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let target = ChromeMetrics.trafficLightCenters[index]
            let center = parent.convert(CGPoint(x: target.x + inset, y: target.y + inset), from: root)
            let size = button.frame.size
            let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        placeDimmedLights(window)
    }

    /// The dimmed circles sit right under the buttons, in their title bar view, and follow
    /// them (anchored, on the card, hidden with them). In full screen the system buttons show.
    private func placeDimmedLights(_ window: NSWindow) {
        let buttons = Self.trafficLightKinds.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let parent = buttons[0].superview, !fullscreenTransition else { return }
        if dimmedLights.superview !== parent {
            dimmedLights.onHoverChange = { [weak self] inside in
                self?.trafficLightsHovered = inside
                self?.applyTrafficLightDim(animated: true)
            }
            dimmedLights.pointerLocation = { [weak self] in
                guard let window = self?.window else { return nil }
                guard BrowserWindowController.pointerEventFilter != nil else { return window.mouseLocationOutsideOfEventStream }
                guard let pointer = BrowserWindowController.automationPointer, pointer.window == window.windowNumber else {
                    return NSPoint(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude) // in another window
                }
                return pointer.location
            }
            parent.addSubview(dimmedLights, positioned: .below, relativeTo: buttons[0])
        }
        let group = buttons.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let frame = group.insetBy(dx: -2, dy: -2)
        if dimmedLights.frame != frame { dimmedLights.frame = frame }
        dimmedLights.centers = buttons.map { CGPoint(x: $0.frame.midX - frame.minX, y: $0.frame.midY - frame.minY) }
        dimmedLights.groupRect = group.offsetBy(dx: -frame.minX, dy: -frame.minY)
        dimmedLights.tone = context.focusedSpace.map { context.appearance(for: $0) } ?? context.systemAppearance
        dimmedLights.showsRing = window.isKeyWindow
        let hidden = buttons[0].isHidden
        // Hiding clears the hover state and showing reads it from the pointer (the view).
        if dimmedLights.isHidden != hidden { dimmedLights.isHidden = hidden }
        applyTrafficLightDim(animated: false)
    }

    /// At rest the system buttons are all but transparent (still there for clicks and AX)
    /// and the dimmed circles show; over the group, the reverse. Not alpha 0: AppKit ignores
    /// a window button at alpha 0, so `performClose:`, `performZoom:`, and an AX press would
    /// stop working; 0.001 draws nothing visible (under 0.3 of one 8-bit level). AppKit may
    /// reset the buttons' alpha when it lays the title bar out; this puts it back in the same pass.
    private static let restButtonAlpha: CGFloat = 0.001

    private func applyTrafficLightDim(animated: Bool) {
        guard let window else { return }
        let buttons = Self.trafficLightKinds.compactMap { window.standardWindowButton($0) }
        let dim = !trafficLightsHovered && !fullscreenTransition && !window.styleMask.contains(.fullScreen)
        let buttonAlpha: CGFloat = dim ? Self.restButtonAlpha : 1, circlesAlpha: CGFloat = dim ? 1 : 0
        let changed = appliedTrafficLightDim != dim
        appliedTrafficLightDim = dim
        if animated && changed && window.isVisible && !Motion.reducesMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.hoverFade
                for button in buttons { button.animator().alphaValue = buttonAlpha }
                dimmedLights.animator().alphaValue = circlesAlpha
            }
        } else if changed || buttons.contains(where: { $0.alphaValue != buttonAlpha }) || dimmedLights.alphaValue != circlesAlpha {
            for button in buttons where button.alphaValue != buttonAlpha { button.alphaValue = buttonAlpha }
            if dimmedLights.alphaValue != circlesAlpha { dimmedLights.alphaValue = circlesAlpha }
        }
    }

    /// The window buttons show Arc's dimmed look (checks and automation).
    public var trafficLightsDimmed: Bool { appliedTrafficLightDim == true }
    public var trafficLightsHoveredState: Bool { trafficLightsHovered }

    /// Observes each button once per instance (AppKit can replace them, for example around
    /// full screen). Weak references, not ObjectIdentifier: a replacement can reuse a freed address.
    private func observeTrafficLights(_ window: NSWindow) {
        observedTrafficLightViews.removeAll { $0.view == nil }
        for button in Self.trafficLightKinds.compactMap({ window.standardWindowButton($0) })
        where !observedTrafficLightViews.contains(where: { $0.view === button }) {
            observedTrafficLightViews.append(WeakView(view: button))
            button.postsFrameChangedNotifications = true
            trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeTrafficLights() }
            })
        }
    }

    /// Layout passes the window reported (checks: the traffic lights are placed in them).
    public var layoutPasses: Int { (window as? BrowserWindow)?.layoutPasses ?? 0 }

    /// Traffic-light frames in root coordinates and their visibility (checks and automation).
    public var trafficLightFrames: [(frame: CGRect, hidden: Bool)] {
        Self.trafficLightKinds.compactMap { kind in
            guard let button = window?.standardWindowButton(kind) else { return nil }
            return (root.convert(button.bounds, from: button), button.isHiddenOrHasHiddenAncestor)
        }
    }

    /// Hover-reveal state for checks: phase, counts, the last dwell in seconds, the zone that
    /// revealed, and the card's on-screen horizontal offset (0 when in place).
    public var revealState: (phase: String, shows: Int, hides: Int, pointerEvents: Int, dwell: Double, zone: String, offset: CGFloat, card: CGRect) {
        let offset = cardState == .off ? -.infinity : (sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
        return (reveal.phase.rawValue, reveal.shows, reveal.hides, reveal.pointerEvents, reveal.lastDwell, reveal.lastZone?.rawValue ?? "",
                offset, cardState == .off ? .zero : sidebar.frame)
    }

    /// Shows or hides the hover-reveal card. The sidebar view becomes the card (frame and
    /// presentation set once, one layout); only the card's layer and its shadow move, by a
    /// transform animation on the render server, so nothing lays out while it slides.
    private func setRevealCard(_ shown: Bool) {
        let size = root.bounds.size
        let card = WindowMetrics.revealCardFrame(windowSize: size, sidebarWidth: context.sidebarWidth)
        let away = -(card.maxX - PanelMetrics.inset)
        let animate = window?.isVisible == true && !Motion.reducesMotion
        let from = cardState == .off ? away : currentCardOffset()
        cardGeneration += 1
        let generation = cardGeneration
        if shown {
            // Clear anchored-hide transforms before the same layers become a card.
            for layer in [sidebar.layer, dimmedLights.layer].compactMap({ $0 }) + Self.trafficLightKinds.compactMap({ window?.standardWindowButton($0)?.layer }) {
                layer.removeAnimation(forKey: "sidebarToggle")
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.setValue(0, forKeyPath: "transform.translation.x"); CATransaction.commit()
            }
            anchoredSliding = false
            sidebarAnimationGeneration += 1
            cardState = .shown
            sidebar.prepareFloatingCard(size: card.size)
            sidebar.presentation = .floatingCard
            sidebar.frame = card
            sidebar.alphaValue = 1
            cardShadow.frame = card
            sidebar.layoutSubtreeIfNeeded()
            cardShadow.layoutSubtreeIfNeeded()
            sidebar.isHidden = false
            cardShadow.isHidden = false
            positionTrafficLights()
            slideCard(from: animate ? from : 0, to: 0, generation: generation, completion: nil)
            if samplesCardMotion {
                cardSampleTask?.cancel(); cardMotionSamples = []
                let start = CACurrentMediaTime()
                cardSampleTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled, CACurrentMediaTime() - start < 0.32 {
                        guard let self, self.cardGeneration == generation else { return }
                        self.cardMotionSamples.append((CACurrentMediaTime() - start, Double(self.currentCardOffset())))
                        try? await Task.sleep(for: .milliseconds(4))
                    }
                }
            }
        } else {
            guard cardState == .shown else { return }
            cardState = .hiding
            positionTrafficLights()
            if animate {
                slideCard(from: from, to: away, generation: generation) { [weak self] in self?.finishCardHide(generation) }
            } else { cardAnimations = [:]; finishCardHide(generation) }
        }
    }

    private func currentCardOffset() -> CGFloat {
        sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    private func slideCard(from: CGFloat, to: CGFloat, generation: Int, completion: (@MainActor () -> Void)?) {
        let layers = [sidebar.layer, cardShadow.layer].compactMap { $0 }
        let buttons = Self.trafficLightKinds.compactMap { window?.standardWindowButton($0)?.layer } + [dimmedLights.layer].compactMap { $0 }
        cardAnimations = [:]
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.cardGeneration == generation else { return }
                completion?()
            }
        }
        for layer in layers + buttons {
            layer.removeAnimation(forKey: "reveal")
            guard from != to else { continue }
            let slide: CABasicAnimation
            if to == 0 { slide = Motion.revealCardIn.animation(keyPath: "transform.translation.x") }
            else {
                slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.duration = Motion.revealCardOut; slide.timingFunction = Motion.easeInOut
            }
            slide.fromValue = from
            slide.toValue = to
            slide.fillMode = .both
            slide.isRemovedOnCompletion = to == 0
            addMotion(slide, to: layer, key: "reveal")
            if layer === sidebar.layer { cardAnimations["card"] = layer.animation(forKey: "reveal") }
            if layer === cardShadow.layer { cardAnimations["shadow"] = layer.animation(forKey: "reveal") }
        }
        CATransaction.commit()
    }

    private func finishCardHide(_ generation: Int) {
        guard generation == cardGeneration, cardState == .hiding else { return }
        cardState = .off
        sidebar.isHidden = true
        cardShadow.isHidden = true
        for layer in [sidebar.layer, cardShadow.layer, dimmedLights.layer].compactMap({ $0 }) + Self.trafficLightKinds.compactMap({ window?.standardWindowButton($0)?.layer }) {
            layer.removeAnimation(forKey: "reveal")
        }
        sidebar.presentation = .anchored
        layoutContent()
    }

    /// Drops the card at once, without the slide (the sidebar becomes anchored, the window closes).
    private func removeRevealCard() {
        reveal.reset()
        guard cardState != .off else { return }
        cardGeneration += 1
        cardState = .hiding
        finishCardHide(cardGeneration)
    }
    public func toggleSidebar() {
        sidebarMotionRequestedAt = CACurrentMediaTime()
        guard let state = context.window else { return }
        if !resizingSidebar { context.sidebarWidthOverride = nil }
        removeRevealCard()
        model.setSidebarMode(windowID: windowID, mode: state.sidebarMode == .hidden ? .anchored : .hidden)
        layoutContent(animated: true); changed()
        // Toolbar button, Cmd+S, View ▸ Hide Sidebar, and "More options" all land here.
        if state.sidebarMode == .hidden { noteSidebarHidden() }
    }
    /// View ▸ Show Toolbar / Hide Toolbar (Cmd+Shift+D, `toggle-toolbar`; §4.6). No animation (D11):
    /// the container lays out once and the page resizes once.
    public func toggleToolbar() { setToolbarShown(!(context.window?.showsToolbar ?? false)) }
    @discardableResult public func setToolbarShown(_ shown: Bool) -> Bool {
        guard model.setToolbarShown(windowID: windowID, shown) else { return false }
        refresh(); changed(); return true
    }
    /// The toolbar's text shows the full URL (`open.advanced.showFullURLWithToolbar`); the App sets it from Settings.
    public var showsFullURLWithToolbar: Bool {
        get { container.showsFullURL }
        set { container.showsFullURL = newValue }
    }
    /// Right-click on the content toolbar (CC-36; order guess): Show/Hide Full URL, Hide Toolbar,
    /// a separator, Manage Extensions. Each item is a sidebar intent, so the App sees it first.
    func makeToolbarMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let full = showsFullURLWithToolbar
        menu.addItem(FeatureMenuItem(full ? "Hide Full URL" : "Show Full URL") { [weak self] in
            guard let self else { return }; _ = self.sidebar(self.sidebar, didRequest: .setShowFullURL(!full))
        })
        menu.addItem(FeatureMenuItem("Hide Toolbar") { [weak self] in
            guard let self else { return }; _ = self.sidebar(self.sidebar, didRequest: .setToolbarShown(false))
        })
        menu.addItem(.separator())
        menu.addItem(FeatureMenuItem("Manage Extensions") { [weak self] in
            guard let self else { return }; _ = self.sidebar(self.sidebar, didRequest: .manageExtensions)
        })
        return menu
    }
    /// The content toolbar's right-click menu, built as a click would build it (harness).
    public func toolbarMenu() -> NSMenu? { container.slots.first?.paneChrome?.role == .toolbar ? makeToolbarMenu() : nil }
    private func beginSidebarResize() {
        guard dragStartWidth == nil else { return }
        dragStartWidth = context.sidebarWidth
        resizingSidebar = true
        removeRevealCard()
    }
    public func resizeSidebar(to x: CGFloat, ended: Bool) {
        guard x.isFinite, let state = context.window else { return }
        if dragStartWidth == nil { beginSidebarResize() }
        let hidden = x < WindowMetrics.sidebarDragHidePoint
        context.sidebarWidthOverride = min(WindowMetrics.maxSidebarWidth, max(WindowMetrics.minSidebarWidth, x))
        let crossed = (state.sidebarMode == .hidden) != hidden
        if crossed {
            sidebarMotionRequestedAt = CACurrentMediaTime()
            model.setSidebarMode(windowID: windowID, mode: hidden ? .hidden : .anchored)
        }
        layoutContent(animated: crossed)
        guard ended else { return }
        if hidden {
            // Width in the model still equals the drag-start width. Do not commit the floor.
            sidebarGestureHides += 1
            _ = self.sidebar(sidebar, didRequest: .sidebarHiddenByGesture)
        } else {
            sidebarWidthCommits += 1
            model.setSidebarWidth(windowID: windowID, width: Double(context.sidebarWidth))
        }
        resizingSidebar = false; dragStartWidth = nil
        resizeHandle.isHidden = hidden
        if !hidden || !anchoredSliding { context.sidebarWidthOverride = nil }
        // A hidden flick keeps the live width until the running slide completes.
        changed()
    }
    private func resetSidebarWidth() {
        guard context.window != nil else { return }
        sidebarWidthCommits += 1
        context.sidebarWidthOverride = WindowMetrics.defaultSidebarWidth
        model.setSidebarWidth(windowID: windowID, width: Double(WindowMetrics.defaultSidebarWidth))
        layoutContent()
        context.sidebarWidthOverride = nil
        changed()
    }
    public var sidebarResizeActive: Bool { resizingSidebar }
    /// Pointer location in root coordinates (also left of the window while it is key).
    public func trackSidebarPointer(_ point: CGPoint) { reveal.pointerMoved(to: point) }
    /// Hides the hover-reveal card (a tab selection, the command bar) with its slide.
    public func dismissSidebarReveal() { reveal.dismiss() }
    public func saveWindowState() {
        guard let window, !fullscreenTransition, !window.styleMask.contains(.fullScreen), let state = context.window else { return }
        let frame = window.frame
        state.frameX = frame.minX; state.frameY = frame.minY
        state.frameWidth = frame.width; state.frameHeight = frame.height
    }
    private func changed() { snapshotStore?.scheduleSave(model: model); peekStorage?.refresh(); syncPeekSidebar(); onStateChange?(); onVisibilityChange?() }
    /// Sidebar undo toasts ("Folder deleted", "Cleared Tabs", …) stay as long as the old bottom
    /// toast did (sidebar-completion §3; page-platform §4.1.4).
    public static let undoToastLifetime: TimeInterval = 5
    /// Undo belongs to the model step that just completed, never a newer command.
    public func showModelUndoToast(_ title: String) {
        guard let manager = model.undoManager, manager.canUndo else {
            toasts.show(ToastContent(title: title, lifetime: Self.undoToastLifetime)); return
        }
        let generation = model.undoGeneration
        toasts.show(.undo(title, lifetime: Self.undoToastLifetime)) { [weak self, weak manager] handle in
            handle.dismiss()
            guard let self, let manager, self.model.undoManager === manager,
                  self.model.undoGeneration == generation, manager.canUndo else { return }
            manager.undo()
        }
    }

    public var peekBadgeTabIDs: Set<ItemID> { peekStorage?.peekBadgeTabIDs ?? [] }
    public var canExitModal: Bool { peekStorage?.isShown == true || container.maximizedTabID != nil }
    /// View > Exit and Esc share this priority. The App validates the key standard window.
    @discardableResult public func exitModal() -> Bool {
        if let peek = peekStorage, peek.isShown { peek.escape(); return true }
        if container.maximizedTabID != nil {
            splitController.performCommand("escape"); container.cancelOperation(nil); return true
        }
        return false
    }
    /// Shared window-local key path. Focus comes from AppKit's current responder.
    @discardableResult public func handleKeyDown(_ event: NSEvent, unconsumed: Bool = false) -> Bool {
        guard let eventWindow = event.window,
              eventWindow === window || ownsAdditionalKeyWindow?(eventWindow) == true
                || existingTabSwitcher?.acceptsEventWindow(eventWindow) == true else { return false }
        if existingTabSwitcher?.handle(event) == true { return true }
        // A window-anchored popover the App shows (the translate popover, page-platform §4.7.3)
        // takes Esc and Return before any other route.
        if let keyInterceptor, keyInterceptor(event) { return true }
        // Esc and Return for the capture overlay; Esc and Cmd+C for its result card (§4.6.3, §4.6.5).
        if eventWindow === window, let capture = captureStorage, capture.phase == .selecting || capture.phase == .showing,
           capture.handleKey(event) { return true }
        let flags = event.modifierFlags.rawValue
        if shouldDeferKeyToFirstResponder?(event) == true {
            // The editor may close itself and change focus. A re-offered copy
            // of that same key must still stay away from the page and Peek.
            lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
            return false
        }
        if let last = lastKeyRoute, last.window == eventWindow.windowNumber, last.code == event.keyCode,
           last.flags == flags, unconsumed || (event.timestamp > 0 && last.timestamp == event.timestamp) { return last.handled }
        if event.keyCode == 53, !isCommandBarPresented,
           (onCommand?("exit-modal") ?? exitModal()) {
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
        if id == "tab-switcher-forward" || id == "tab-switcher-backward" {
            let previous = tabSwitcherKeyEvent
            tabSwitcherKeyEvent = event
            defer { tabSwitcherKeyEvent = previous }
            performCommand(id)
        } else { performCommand(id) }
        lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
        return true
    }
    private func handles(_ id: String) -> Bool { ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space", "go-back", "go-forward"].contains(id) || id.hasPrefix("focus-split-pane-") }
    public func performCommand(_ id: String) {
        if id != "tab-switcher-forward", id != "tab-switcher-backward" { existingTabSwitcher?.cancel() }
        if onCommand?(id) == true { return }
        if id == "toggle-toolbar" { toggleToolbar(); return }
        if id == "open-in-current-space", peekStorage?.isShown == true {
            let menu = NSMenu(title: "Open in Space")
            for space in model.spaces { menu.addItem(FeatureMenuItem(context.title(of: space)) { [weak self] in self?.peekStorage?.expandTop(into: space.id) }) }
            pendingMoveMenu = menu
            if window?.isVisible == true { menu.popUp(positioning: nil, at: CGPoint(x: root.bounds.midX, y: root.bounds.midY), in: root) }
            pendingMoveMenu = nil
        }
        else if id == "go-back", peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goBack() }
        else if id == "go-forward", peekStorage?.isShown == true { peekStorage?.stack.last?.host?.goForward() }
        else { splitController.performCommand(id) }
    }
    public func performCommand(_ id: String, payload: String?) {
        if onCommandWithPayload?(id, payload) == true { return }
        performCommand(id)
    }
    /// Runtime menu titles (CC-32): the View menu names the action the item performs.
    public func menuTitle(for id: String) -> String? {
        switch id {
        case "toggle-toolbar": context.window?.showsToolbar == true ? "Hide Toolbar" : "Show Toolbar"
        case "toggle-sidebar": context.window?.sidebarMode == .hidden ? "Show Sidebar" : "Hide Sidebar"
        default: nil
        }
    }
    public func menuState(for id: String) -> CommandMenuState? { onMenuState?(id) }
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool {
        if let enabled = onCommandValidation?(id, enabledKey) { return enabled }
        if id == "toggle-toolbar" { return context.window?.style == .standard }
        if id == "open-in-current-space" { return peekStorage?.isShown == true }
        if id == "go-back" { return peekStorage?.isShown == true ? peekStorage?.stack.last?.host?.canGoBack == true : splitController.focusedTab.flatMap { container.host(for: $0.id) }?.canGoBack == true }
        if id == "go-forward" { return peekStorage?.isShown == true ? peekStorage?.stack.last?.host?.canGoForward == true : splitController.focusedTab.flatMap { container.host(for: $0.id) }?.canGoForward == true }
        return splitController.isCommandEnabled(id, enabledKey: enabledKey)
    }
    public func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        // Any other intent ends a preview first, so its host is back in the container cache
        // before a selection shows it (SidebarContext.send does the same for sidebar input).
        if case .hoverPreview = intent {} else if hoverPreview.card != nil {
            hoverPreview.hide(animated: false); context.hoverPreviews.dismiss()
        }
        if let handled = onSidebarIntent?(intent) { return handled }
        switch intent {
        case .toggleSidebar: toggleSidebar(); return true
        case .setToolbarShown(let shown): return setToolbarShown(shown)
        case .setShowFullURL(let full): showsFullURLWithToolbar = full; return true
        case .sidebarHiddenByGesture: noteSidebarHidden(); return true
        case .hoverPreview(let request): hoverPreview.update(request); return true
        case .unloadFolder(let id):
            guard context.isPinnedFolder(id), let folder = model.node(id: id)?.folder else { return false }
            func tabs(_ nodes: [SidebarNode]) -> [Tab] {
                nodes.flatMap { node in
                    switch node { case .tab(let tab): [tab]; case .split(let split): split.panes; case .folder(let f): tabs(f.children) }
                }
            }
            let ids = Set(tabs(folder.children).map(\.id))
            let loaded = ids.filter { container.host(for: $0) != nil }
            guard !loaded.isEmpty else { return true }
            for id in loaded { container.closeHost(for: id) }
            if let selected = context.currentTab?.id, ids.contains(selected) {
                if let space = context.focusedSpace {
                    let next = tabs(space.pinned + space.today).first { !ids.contains($0.id) }
                    model.selectNode(windowID: windowID, spaceID: space.id, nodeID: model.sidebarSelectionID(for: next?.id))
                }
            }
            refresh(); return true
        case .separateFromPinned(let id): return separateFromPinned(id)
        case .deleteSpace(let id): return confirmDeleteSpace(id)
        case .deleteFolder(let id): return confirmDeleteFolders([id])
        case .deleteFolders(let ids): return confirmDeleteFolders(ids)
        case .clearToday(let space), .clearTodayKeeping(let space, _):
            let before = model.space(id: space)?.today.count ?? 0
            guard ModelSidebarActions(context: context).perform(intent) else { return false }
            if (model.space(id: space)?.today.count ?? 0) < before { showClearedToast() }
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
    public func windowWillClose(_ notification: Notification) {
        existingTabSwitcher?.cancel()
        saveWindowState(); visibilityOverride = .closed; removeRevealCard(); hintWork?.cancel(); hintWork = nil
        hoverPreview.hide(animated: false); captureStorage?.tearDown()
        container.closeAll(); onClose?(); onVisibilityChange?()
    }
    public var onTextUndoManager: ((NSWindow) -> UndoManager?)?
    private lazy var nativeTextUndoManager = UndoManager()
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let editor = onTextUndoManager?(window) { return editor }
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField { return nativeTextUndoManager }
        return model.undoManager
    }
    public func windowDidResize(_ notification: Notification) { layoutContent(); existingTabSwitcher?.layout() }
    public func windowDidMove(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowDidEndLiveResize(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowWillEnterFullScreen(_ notification: Notification) { saveWindowState(); fullscreenTransition = true; applyTrafficLightDim(animated: false); dimmedLights.isHidden = true }
    public func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true; applyTrafficLightDim(animated: false) }
    public func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?() }
    public func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?()
        // The window is back at its frame; the pointer may or may not be over the buttons.
        dimmedLights.syncWithPointer()
    }
    public func windowDidBecomeKey(_ notification: Notification) {
        context.isWindowActive = true; background.isWindowActive = true; positionTrafficLights(); onFocus?()
        // Back from another app or a hide (Cmd+H): the pointer may have left the buttons meanwhile.
        dimmedLights.syncWithPointer()
    }
    public func windowDidResignKey(_ notification: Notification) { existingTabSwitcher?.cancel(); context.isWindowActive = false; background.isWindowActive = false; positionTrafficLights() }
    public func windowDidChangeBackingProperties(_ notification: Notification) { positionTrafficLights() }
    public func windowDidBecomeMain(_ notification: Notification) { context.isWindowActive = true }
    public func windowDidResignMain(_ notification: Notification) { context.isWindowActive = window?.isKeyWindow == true }
    public func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChange?()
        // The pointer was on the yellow button when the window left, and has moved since.
        dimmedLights.syncWithPointer()
    }
    public func windowDidChangeOcclusionState(_ notification: Notification) { onVisibilityChange?() }
}


/// The standard browser window. It reports the end of each layout pass, before the window
/// draws, so the traffic lights can be placed after AppKit's own title bar layout.
@MainActor
final class BrowserWindow: NSWindow {
    var onLayoutPass: (() -> Void)?
    private(set) var layoutPasses = 0
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutPasses += 1
        onLayoutPass?()
    }
    override func displayIfNeeded() {
        super.layoutIfNeeded()
        layoutPasses += 1
        onLayoutPass?()
        super.displayIfNeeded()
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        BrowserWindowController.constrainsFramesToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
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
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResize: ((CGFloat, Bool) -> Void)?
    var onReset: (() -> Void)?
    private var dragging = false
    private var moved = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        dragging = true; moved = false; onBegin?()
    }
    override func mouseDragged(with event: NSEvent) { moved = true; resize(event, ended: false) }
    override func mouseUp(with event: NSEvent) {
        if dragging && !moved { dragging = false; onCancel?(); return }
        resize(event, ended: true)
    }
    private func resize(_ event: NSEvent, ended: Bool) {
        guard dragging, let root = window?.contentView else { return }
        if ended { dragging = false }
        onResize?(root.convert(event.locationInWindow, from: nil).x, ended)
    }
}

// MARK: Sidebar completion A1: confirmations, toasts, first-hide hint

extension BrowserWindowController {
    /// Delete Space: the alert first; "Delete" archives the Space (one undo step).
    func confirmDeleteSpace(_ id: SpaceID) -> Bool {
        guard let window, pendingConfirmation == nil, let alert = SidebarConfirmations.deleteSpaceAlert(model: model, spaceID: id) else { return false }
        let restoreKeyboardFocus = context.keyboardFocusAfterDeletion()
        pendingConfirmation = alert
        let shown = SidebarConfirmations.present(alert, on: window) { [weak self] confirmed in
            guard let self else { return }
            self.pendingConfirmation = nil
            guard confirmed, self.model.space(id: id) != nil else { return }
            if ModelSidebarActions(context: self.context).perform(.deleteSpace(id)) {
                self.refresh(); restoreKeyboardFocus(); self.changed()
            }
        }
        if !shown { pendingConfirmation = nil }
        return shown
    }

    /// Delete folder(s): the alert first; "Delete Folder" archives the selection (folders as
    /// folder records) in one undo step, then the toast with Undo.
    func confirmDeleteFolders(_ ids: [ItemID]) -> Bool {
        guard let window, pendingConfirmation == nil, let alert = SidebarConfirmations.deleteFoldersAlert(model: model, ids: ids) else { return false }
        let folders = ids.filter { model.node(id: $0)?.folder != nil }.count
        let restoreKeyboardFocus = context.keyboardFocusAfterDeletion()
        pendingConfirmation = alert
        let shown = SidebarConfirmations.present(alert, on: window) { [weak self] confirmed in
            guard let self else { return }
            self.pendingConfirmation = nil
            guard confirmed else { return }
            var archived = 0
            self.keepingSelection { archived = self.model.archiveNodes(ids: ids) }
            guard archived > 0 else { return }
            self.refresh(); restoreKeyboardFocus(); self.changed()
            self.showModelUndoToast(SidebarConfirmations.folderToast(count: folders))
        }
        if !shown { pendingConfirmation = nil }
        return shown
    }

    /// Runs a removal; when it took the window's current tab, selects the tab that now holds
    /// its place in the Space (the next one, else the previous), as Cmd+W does.
    public func keepingSelection(_ removal: () -> Void) {
        guard let space = context.focusedSpace, let state = context.window else { removal(); return }
        func tabs() -> [ItemID] {
            func walk(_ nodes: [SidebarNode]) -> [ItemID] {
                nodes.flatMap { node -> [ItemID] in
                    switch node { case .tab(let tab): [tab.id]; case .folder(let folder): walk(folder.children); case .split(let split): [split.id] }
                }
            }
            return walk(space.pinned) + walk(space.today)
        }
        let before = tabs(), selected = state.selectedNodeBySpace[space.id]
        let index = selected.flatMap { before.firstIndex(of: $0) }
        removal()
        guard let selected, model.node(id: selected) == nil, let index else { return }
        let remaining = Set(tabs())
        guard !remaining.isEmpty else { return }
        let next = before.suffix(from: index).first(where: remaining.contains) ?? before.prefix(index).last(where: remaining.contains)
        guard let next else { return }
        // The removal is the undo step; moving the selection is not. Detach the manager:
        // disabled registration would still leave an empty per-command group on top.
        let undo = model.undoManager
        model.undoManager = nil; defer { model.undoManager = undo }
        _ = sidebar(sidebar, didRequest: .select(nodeID: next, space: space.id))
    }

    /// Separate From Pinned Tab (completion §3.9): the navigated page becomes a Today tab with
    /// the same live host (its history intact); the pinned tab goes back to its pinned URL,
    /// unloaded. A factory that cannot rebind closes the host; the new tab then loads its URL.
    func separateFromPinned(_ id: ItemID) -> Bool {
        // The model emits synchronously. Keep the host cached while observers refresh
        // the still-selected pinned tab, so they cannot reacquire and reload its page.
        guard let tab = model.separateFromPinnedTab(id: id) else { return false }
        let live = container.takeHost(for: id)
        container.resetLiveState(for: id)
        if let live {
            live.view.removeFromSuperview()
            container.adopt(live, for: tab.id)
        }
        // Refused (or no live page): the new tab loads its URL when it shows.
        if live == nil || container.host(for: tab.id) !== live { tab.live.sleepPhase = .live }
        if let space = context.focusedSpace { _ = sidebar(sidebar, didRequest: .select(nodeID: tab.id, space: space.id)) }
        refresh(); changed()
        return true
    }

    /// Clicks the shown toast's Undo button (automation and checks use the real button).
    @discardableResult public func pressToastUndo() -> Bool { toasts.performUndo() }

    /// "Cleared Tabs" with Undo after any Clear (`FUN_102a68e2c`).
    public func showClearedToast() {
        showModelUndoToast("Cleared Tabs")
    }

    /// The first hide by any path shows the hint once; the key is set when it shows.
    func noteSidebarHidden() {
        guard context.window?.sidebarMode == .hidden, defaults.object(forKey: Self.hideHintShownKey) as? Bool != true else { return }
        defaults.set(true, forKey: Self.hideHintShownKey)
        showHintToast()
    }

    private func showHintToast() {
        hintWork?.cancel(); hintToast?.removeFromSuperview(); hintAnimations = [:]
        let command = CommandRegistry.byID["toggle-sidebar"]
        let keys = command.flatMap { keyBindingOverrides.effectiveShortcuts(for: $0).first?.symbolDisplay } ?? "⌘S"
        let style = context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        let hint = HintToastView(keys: keys, style: style)
        root.addSubview(hint, positioned: .below, relativeTo: toastOverlay)
        hintToast = hint; hintShows += 1
        layoutContent()
        let m = HintToastMetrics.self
        if let layer = hint.layer, !Motion.reducesMotion, window?.isVisible == true || SidebarDiagnostics.forceAnimations {
            let w = hint.bounds.width / 2, h = hint.bounds.height / 2
            var start = CATransform3DMakeTranslation(-w, -h, 0)
            start = CATransform3DConcat(start, CATransform3DMakeScale(m.inScale, m.inScale, 1))
            start = CATransform3DConcat(start, CATransform3DMakeTranslation(w, h, 0))
            let scale = CABasicAnimation(keyPath: "transform"); scale.fromValue = start; scale.toValue = CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let group = CAAnimationGroup(); group.animations = [scale, fade]
            group.duration = m.inDuration; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "hintIn"); hintAnimations["in"] = layer.animation(forKey: "hintIn")
        }
        let shownAt = CACurrentMediaTime()
        hintShownAt = shownAt; hintFadeDeadline = shownAt + m.lifetime
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.expireHintToast() } }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + m.lifetime, execute: work)
    }

    /// Fades the hint out now (its lifetime ended, or a check drives the clock).
    public func expireHintToast() {
        hintWork?.cancel(); hintWork = nil; hintFadeDeadline = nil
        guard let hint = hintToast else { return }
        let animates = !Motion.reducesMotion && (window?.isVisible == true || SidebarDiagnostics.forceAnimations)
        guard animates, let layer = hint.layer else { hint.removeFromSuperview(); hintToast = nil; return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.duration = HintToastMetrics.outDuration; fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(fade, forKey: "hintOut"); hintAnimations["out"] = layer.animation(forKey: "hintOut")
        // Remove on a scheduled deadline, not a render callback (an occluded window may not render).
        let work = DispatchWorkItem { [weak self, weak hint] in
            MainActor.assumeIsolated {
                hint?.removeFromSuperview()
                if let self, self.hintToast === hint { self.hintToast = nil }
            }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HintToastMetrics.outDuration, execute: work)
    }
}
