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
    /// Automation builds can turn this off to keep a capture-size frame on a smaller screen.
    public static var constrainsFramesToScreen = true
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
        trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissSidebarReveal() }
        })
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window, BrowserWindowController.pointerEventFilter?(event) ?? true {
                    self.trackSidebarPointer(self.root.convert(event.locationInWindow, from: nil))
                }
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
    isolated deinit { observing = false; if let treeObserver { model.removeObserver(treeObserver) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; container.closeAll(); reveal.reset(); toastTask?.cancel(); if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; trafficLightObservers.forEach(NotificationCenter.default.removeObserver) }
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
        layoutGeneration += 1; let generation = layoutGeneration
        let animate = animated && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if cardState != .off {
            // The hover-reveal card owns the sidebar view; only keep its frame current.
            let card = WindowMetrics.revealCardFrame(windowSize: size, sidebarWidth: width)
            if sidebar.frame != card { sidebar.frame = card }
            if cardShadow.frame != card { cardShadow.frame = card }
            container.frame = panelFrame
        } else {
            let sidebarFrame = CGRect(x: hidden ? -width : 0, y: 0, width: width, height: size.height)
            if case .floatingCard = sidebar.presentation { sidebar.presentation = .anchored }
            if animate {
                sidebar.isHidden = false
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0.22
                    container.animator().frame = panelFrame; sidebar.animator().frame = sidebarFrame
                    sidebar.animator().alphaValue = hidden ? 0 : 1
                } completionHandler: { [weak self] in MainActor.assumeIsolated {
                    guard let self, self.layoutGeneration == generation, self.cardState == .off else { return }
                    self.sidebar.isHidden = hidden
                } }
            } else {
                container.frame = panelFrame; sidebar.frame = sidebarFrame
                sidebar.alphaValue = hidden ? 0 : 1
                sidebar.isHidden = hidden
            }
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
        let hidden = isPageFullscreen || cardState == .hiding || (cardState == .off && context.window?.sidebarMode == .hidden)
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
            parent.addSubview(dimmedLights, positioned: .below, relativeTo: buttons[0])
        }
        let group = buttons.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let frame = group.insetBy(dx: -2, dy: -2)
        if dimmedLights.frame != frame { dimmedLights.frame = frame }
        dimmedLights.centers = buttons.map { CGPoint(x: $0.frame.midX - frame.minX, y: $0.frame.midY - frame.minY) }
        dimmedLights.groupRect = group.offsetBy(dx: -frame.minX, dy: -frame.minY)
        dimmedLights.tone = context.focusedSpace.map { context.appearance(for: $0) } ?? context.systemAppearance
        let hidden = buttons[0].isHidden
        if dimmedLights.isHidden != hidden { dimmedLights.isHidden = hidden }
        if hidden, trafficLightsHovered { trafficLightsHovered = false }
        applyTrafficLightDim(animated: false)
    }

    /// At rest the system buttons are transparent (still there for clicks and AX) and the
    /// dimmed circles show; over the group, the reverse. AppKit may reset the buttons'
    /// alpha when it lays the title bar out; this puts it back in the same pass.
    private func applyTrafficLightDim(animated: Bool) {
        guard let window else { return }
        let buttons = Self.trafficLightKinds.compactMap { window.standardWindowButton($0) }
        let dim = !trafficLightsHovered && !fullscreenTransition && !window.styleMask.contains(.fullScreen)
        let buttonAlpha: CGFloat = dim ? 0 : 1, circlesAlpha: CGFloat = dim ? 1 : 0
        let changed = appliedTrafficLightDim != dim
        appliedTrafficLightDim = dim
        if animated && changed && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        let away = -(card.maxX + 3 * WindowMetrics.revealCardShadowRadius)
        let animate = window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = cardState == .off ? away : currentCardOffset()
        cardGeneration += 1
        let generation = cardGeneration
        if shown {
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
        } else {
            guard cardState == .shown else { return }
            cardState = .hiding
            positionTrafficLights()
            if animate {
                slideCard(from: from, to: away, generation: generation) { [weak self] in self?.finishCardHide(generation) }
            } else { finishCardHide(generation) }
        }
    }

    private func currentCardOffset() -> CGFloat {
        sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    private func slideCard(from: CGFloat, to: CGFloat, generation: Int, completion: (@MainActor () -> Void)?) {
        let layers = [sidebar.layer, cardShadow.layer].compactMap { $0 }
        let buttons = Self.trafficLightKinds.compactMap { window?.standardWindowButton($0)?.layer } + [dimmedLights.layer].compactMap { $0 }
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
            let slide = Motion.sidebarToggle.animation(keyPath: "transform.translation.x")
            slide.fromValue = from
            slide.toValue = to
            slide.fillMode = .both
            slide.isRemovedOnCompletion = to == 0
            layer.add(slide, forKey: "reveal")
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
        guard let state = context.window else { return }
        removeRevealCard()
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
    @discardableResult public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        if event.keyCode == 53 {
            if let peek = peekStorage, peek.isShown { peek.escape() }
            else { splitController.performCommand("escape"); container.cancelOperation(nil) }
            return true
        }
        let responder = window?.firstResponder
        let view = responder as? NSView
        let textFocused = responder is NSTextView || responder is NSTextField
        func within(_ ancestor: NSView?) -> Bool {
            guard let view, let ancestor else { return false }
            return view === ancestor || view.isDescendant(of: ancestor)
        }
        let webFocused = !textFocused && (container.slots.contains { within($0.contentHostView) }
            || (peekStorage?.isShown == true && within(peekStorage?.stack.last?.host?.view)))
        let routing = RoutingContext(isCommandBarOpen: context.isNewTabCommandBarOpen,
            isSidebarFocused: within(sidebar), isTextFocused: textFocused, isWebContentFocused: webFocused)
        guard case .browserCommand(let id)? = keyboard.route(event: event, context: routing), handles(id) else { return false }
        // These bindings have window scope in the registry; restrict them to the
        // page here so sidebar controls and AppKit field editors retain their keys.
        if id.hasPrefix("focus-split-pane-"), !webFocused { return false }
        performCommand(id); return true
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
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool { splitController.isCommandEnabled(id, enabledKey: enabledKey) }
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
    public func windowWillClose(_ notification: Notification) { saveWindowState(); visibilityOverride = .closed; removeRevealCard(); container.closeAll(); onClose?(); onVisibilityChange?() }
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }
    public func windowDidResize(_ notification: Notification) { layoutContent() }
    public func windowDidMove(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowDidEndLiveResize(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowWillEnterFullScreen(_ notification: Notification) { saveWindowState(); fullscreenTransition = true; applyTrafficLightDim(animated: false); dimmedLights.isHidden = true }
    public func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true; applyTrafficLightDim(animated: false) }
    public func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?() }
    public func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?() }
    public func windowDidBecomeKey(_ notification: Notification) { context.isWindowActive = true; background.isWindowActive = true; positionTrafficLights(); onFocus?() }
    public func windowDidResignKey(_ notification: Notification) { context.isWindowActive = false; background.isWindowActive = false; positionTrafficLights() }
    public func windowDidChangeBackingProperties(_ notification: Notification) { positionTrafficLights() }
    public func windowDidBecomeMain(_ notification: Notification) { context.isWindowActive = true }
    public func windowDidResignMain(_ notification: Notification) { context.isWindowActive = window?.isKeyWindow == true }
    public func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange?() }
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
