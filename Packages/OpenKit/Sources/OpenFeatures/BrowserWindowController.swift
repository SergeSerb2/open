import AppKit
import Observation
import OpenModel
import OpenDesign
import OpenSidebar
import OpenSpaceEditor
import OpenCommands
import OpenStore
import OpenSiteControl

@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, SidebarDelegate, CommandDispatcher {
    public var contentView: NSView { root }
    public let windowID: WindowID
    /// Setup can prepare engine hosts without allowing its hidden browser to activate.
    public var allowsWindowActivation: Bool {
        get { (window as? BrowserWindow)?.allowsActivation ?? true }
        set { (window as? BrowserWindow)?.allowsActivation = newValue }
    }
    public let model: BrowserModel
    let root: BrowserRootView
    public let background = ThemeBackgroundView(frame: .zero)
    public private(set) var spaceCreationController: SpaceCreationController?
    public var onSpaceCreationIcon: (@MainActor (SpaceIcon?, CGRect, @escaping @MainActor (SpaceIcon?) -> Void) -> Void)?
    /// The App requests the real engine exit. Present only after its callback
    /// and any native fullscreen transition, outside the engine delegate call.
    public var onExitPageFullscreen: (@MainActor () -> Bool)?
    private var pendingSpaceCreationOptions: SpaceCreationOptions?
    public private(set) var themeEditor: ThemeEditorController?
    public let sidebar: SidebarView
    public let context: SidebarContext
    public let container: WebContentContainer
    public private(set) var libraryPanel: NSView?
    public private(set) var isLibraryOpen = false
    public var libraryKeyHandler: ((NSEvent) -> Bool)?
    public var libraryWidth: CGFloat = 417
    private var libraryUsesWideLayout = false
    private var librarySidebarFadeUntil: CFTimeInterval = 0
    private var libraryMotionGeneration = 0
    public let splitController: SplitViewController
    private var boostEditorSpaceID: SpaceID?
    public var boostEditor: BoostEditorController? { didSet { boostEditorSpaceID = context.focusedSpace?.id } }
    private var peekStorage: PeekController?
    public var peekController: PeekController {
        if let peekStorage { return peekStorage }
        let peek = PeekController(model: model, splitController: splitController, factory: factory, defaults: defaults)
        peekStorage = peek
        root.addSubview(peek.overlay.backdrop, positioned: .below, relativeTo: sidebar)
        root.addSubview(peek.overlay, positioned: .below, relativeTo: toastOverlay)
        // F6: a shown Peek makes every Site Control button unavailable; refresh both kinds.
        peek.onChange = { [weak self] in self?.changed(); self?.scheduleSiteControlButtonsRefresh() }
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
    public private(set) var siteControl: SiteControlController?
    let siteControlSource: (any SiteControlDataSource)?
    private var siteControlToken: SiteControlObservationToken?
    var siteControlSpace: SpaceID?
    var siteControlButtonsRefreshPending = false
    private let factory: any WebContentHostFactory
    private let defaults: UserDefaults
    public var onSidebarIntent: ((SidebarIntent) -> Bool?)?
    public var onCommand: ((String) -> Bool)?
    public var onCommandWithPayload: ((String, String?) -> Bool)?
    public var onCommandValidation: ((String, String) -> Bool?)?
    /// Runtime menu state from the App (page-platform §7.1); nil keeps the item as built.
    public var onMenuState: ((String) -> CommandMenuState?)?
    /// Extension commands run after Open's bindings and before page delivery.
    public var onExtensionShortcut: ((NSEvent) -> Bool)?
    /// Sees every key event of this window first (after the tab switcher); true consumes it.
    public var keyInterceptor: ((NSEvent) -> Bool)?
    /// A native field editor retains plain editing keys before Peek/window routes.
    public var shouldDeferKeyToFirstResponder: ((NSEvent) -> Bool)?
    public var ownsAdditionalKeyWindow: ((NSWindow) -> Bool)?
    public var isApplicationActive: (() -> Bool)?
    public var isCommandBarPresented = false
    /// The command bar overlay (the App adds it). While the bar is open, only views inside it take the
    /// keyboard unless a mouse click asks: a page created behind the bar (Cmd+Return) must not take it.
    public weak var commandBarView: NSView?
    public var keyBindingOverrides = KeyBindingStore.empty
    /// The actual key only while dispatching a switcher command; menu actions have none.
    public private(set) var tabSwitcherKeyEvent: NSEvent?
    private var lastKeyRoute: (window: Int, code: UInt16, flags: UInt, timestamp: TimeInterval, handled: Bool)?
    public var onStateChange: (() -> Void)?
    public var onClose: (() -> Void)?
    /// Cancel window-owned extension consent before AppKit checks attached sheets.
    public var onCloseRequested: (() -> Void)?
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
        didSet {
            if isPageFullscreen { dismissSidebarReveal() }
            layoutContent()
            if !isPageFullscreen, pendingSpaceCreationOptions != nil {
                DispatchQueue.main.async { [weak self] in self?.resumePendingSpaceCreation() }
            }
        }
    }
    /// The hover-reveal card shows (or is sliding out).
    public var isSidebarRevealed: Bool { reveal.isShown }
    private let resizeHandle = SidebarResizeHandle()
    private let reveal = SidebarRevealController()
    private let cardShadow = RevealCardShadowView()
    private enum CardState { case off, shown, hiding }
    private var cardState = CardState.off
    private var cardGeneration = 0
    private var sidebarPanelTarget: CGRect?
    private var sidebarPanelRootSize: CGSize?
    private let sidebarPanelClip = CALayer()
    private let sidebarPanelShadow = SidebarPanelShadowView()
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
        capture.addToEasel = captureAddToEasel
        capture.wallpaperData = { [weak self] in await self?.captureWallpaperData?() }
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
    /// Capture → Easel (the App's Easel menu); nil hides the card's Add to Easel button.
    public var captureAddToEasel: ((CaptureController.Result, NSView) -> Void)? { didSet { captureStorage?.addToEasel = captureAddToEasel } }
    /// Portrait Mode "Use Desktop Wallpaper": the wallpaper bytes for this window's screen (App).
    public var captureWallpaperData: (@MainActor () async -> Data?)?
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
    private var dragStartMode: SidebarMode?
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
    private var systemAppearanceObservation: NSKeyValueObservation?
    private var increaseContrastObserver: NSObjectProtocol?
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
    public private(set) lazy var hoverPreview: HoverPreviewController = {
        let preview = HoverPreviewController(root: root, container: container, factory: factory, context: context) { [weak self] id in
            guard let self, let space = self.context.focusedSpace else { return }
            _ = self.sidebar(self.sidebar, didRequest: .select(nodeID: id, space: space.id))
        }
        // A Peek shows over its selected source row; a Pinned source is selected first (a Favorite
        // source is visible in its whole Profile). GUESS — capture pending (F2 capture items 9-10).
        preview.openPeek = { [weak self] url, source in
            guard let self else { return }
            let favorite: Bool = if case .favorites? = self.model.parent(of: source) { true } else { false }
            if !favorite, let space = self.context.focusedSpace {
                _ = self.sidebar(self.sidebar, didRequest: .select(nodeID: source, space: space.id))
            }
            self.peekController.open(url: url, sourceTabID: source)
        }
        return preview
    }()
    /// Live Folder intro card (capture s5 b3) beside the new folder row; one at a time.
    public private(set) var liveFolderIntro: LiveFolderIntroView?
    private var liveFolderIntroMonitor: Any?
    public func showLiveFolderIntro(folderID: ItemID) {
        dismissLiveFolderIntro()
        sidebar.layoutSubtreeIfNeeded()
        guard let row = sidebar.rowFrame(nodeID: folderID) else { return }
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        let view = LiveFolderIntroView(appearance: appearance)
        let rowInRoot = root.convert(row, from: sidebar)
        let size = view.fittingSize
        view.frame = CGRect(x: context.sidebarWidth + HoverPreviewMetrics.folderSidebarGap, y: rowInRoot.midY - size.height / 2, width: size.width, height: size.height)
        root.addSubview(view, positioned: .below, relativeTo: toastOverlay)
        liveFolderIntro = view
        // Any click or key dismisses it (capture s5: Esc closes it); the event still goes on.
        liveFolderIntroMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { if event.window === self?.window { self?.dismissLiveFolderIntro() } }
            return event
        }
    }
    public func dismissLiveFolderIntro() {
        if let liveFolderIntroMonitor { NSEvent.removeMonitor(liveFolderIntroMonitor); self.liveFolderIntroMonitor = nil }
        liveFolderIntro?.removeFromSuperview(); liveFolderIntro = nil
    }
    /// The delete confirmation sheet currently shown on this window (completion §3.3).
    public private(set) var pendingConfirmation: NSAlert?
    /// Title of the newest toast shown, for checks.
    public var lastToastTitle: String { toasts.lastTitle }
    public init(model: BrowserModel, windowID: WindowID, factory: any WebContentHostFactory, size: CGSize? = nil, defaults: UserDefaults = .standard, snapshotStore: SnapshotStore? = nil, incognitoTitle: String? = nil, windowOnlyTitle: String? = nil, siteControlSource: (any SiteControlDataSource)? = nil, siteControlActions: (any SiteControlActions)? = nil) {
        WindowSpeedTrace.mark("controllerInitBody")
        self.model = model; self.windowID = windowID; self.snapshotStore = snapshotStore
        self.factory = factory; self.defaults = defaults
        self.siteControlSource = siteControlSource
        let state = model.windows.first { $0.id == windowID }
        let dimensions = size ?? CGSize(width: max(640, state?.frameWidth ?? 1280), height: max(480, state?.frameHeight ?? 800))
        root = BrowserRootView(frame: CGRect(origin: .zero, size: dimensions))
        // Only the frame follows the Space; private content keeps its fixed dark appearance.
        root.appearance = incognitoTitle == nil ? NSApp.effectiveAppearance : NSAppearance(named: .darkAqua)
        context = SidebarContext(model: model, windowID: windowID, incognitoTitle: incognitoTitle, windowOnlyTitle: windowOnlyTitle)
        context.systemAppearance = context.isIncognito ? .dark : ContentAppearance(NSApp.effectiveAppearance)
        context.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        WindowSpeedTrace.mark("sidebarInitBegin")
        sidebar = SidebarView(context: context); container = WebContentContainer(factory: factory)
        WindowSpeedTrace.mark("sidebarAndContainerCreated")
        splitController = SplitViewController(model: model, windowID: windowID, container: container)
        let window = BrowserWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        if incognitoTitle != nil { window.contentAppearanceOverride = NSAppearance(named: .darkAqua) }
        WindowSpeedTrace.mark("nativeWindowCreated")
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.title = incognitoTitle == nil ? "Open" : "Incognito";
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed; window.isMovableByWindowBackground = false
        window.minSize = CGSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary); window.acceptsMouseMovedEvents = true
        super.init(window: window); window.contentView = root; window.delegate = self
        window.refusesFirstResponder = { [weak self] responder in
            guard let self, self.isCommandBarPresented, let bar = self.commandBarView, let view = responder as? NSView else { return false }
            if let type = NSApp.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { return false }
            return !(view === bar || view.isDescendant(of: bar))
        }
        container.onSadTabClose = { [weak self] id in
            guard let self else { return }
            _ = self.sidebar(self.sidebar, didRequest: .close(nodeID: id))
        }
        window.onLayoutPass = { [weak self] in self?.placeTrafficLights() }
        window.onCloseRequest = { [weak self] in self?.onCloseRequested?() }
        if let state { window.setFrame(CGRect(x: state.frameX, y: state.frameY, width: dimensions.width, height: dimensions.height), display: false) }
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // assumeIsolated requires every NSApp.appearance write to run on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                let appearance = NSApp.effectiveAppearance
                let content = self.window.flatMap { ($0 as? SpaceThemeWindow)?.contentAppearanceOverride } ?? appearance
                if self.root.appearance?.name != content.name { self.root.appearance = content }
                let system: ContentAppearance = self.context.isIncognito ? .dark : ContentAppearance(appearance)
                if self.context.systemAppearance != system { self.context.systemAppearance = system }
                self.refresh()
            }
        }
        // macOS Increase Contrast (plan D2 §2.8): the sidebar roles follow it live.
        increaseContrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                if self.context.increaseContrast != value { self.context.increaseContrast = value; self.refresh() }
            }
        }
        root.addSubview(background)
        emptyPanelHost.wantsLayer = true; emptyPanelHost.layer?.addSublayer(emptyPanel)
        root.addSubview(emptyPanelHost)
        root.addSubview(sidebarPanelShadow); root.addSubview(container); root.addSubview(cardShadow); root.addSubview(sidebar); root.addSubview(resizeHandle)
        WindowSpeedTrace.mark("windowViewsAttached")
        cardShadow.isHidden = true
        resizeHandle.onBegin = { [weak self] in self?.beginSidebarResize() }
        resizeHandle.onCancel = { [weak self] in self?.cancelSidebarResize() }
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
            return !self.isLibraryOpen && self.spaceCreationController == nil && !self.isPageFullscreen && self.context.window?.sidebarMode == .hidden && self.peekStorage?.isShown != true
                && !self.context.isNewTabCommandBarOpen && !self.resizingSidebar
        }
        reveal.onChange = { [weak self] shown in self?.setRevealCard(shown) }
        // Another app took the pointer: no more pointer events will come to hide the card.
        // Not while automation drives the pointer: then the hardware pointer is ignored, and
        // a deactivation comes from someone using the Mac, not from the check.
        trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelSidebarResize()
                guard BrowserWindowController.pointerEventFilter == nil else { return }
                self?.dismissSidebarReveal()
            }
        })
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited]) { [weak self] event in
            let accepted = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return true }
                // Native menu teardown can queue tracking events from the hardware
                // cursor. While the socket owns the pointer, reject those events
                // before AppKit routes them to views, not just for sidebar reveal.
                // The socket reconciles enter/exit at its tagged motion's point.
                guard BrowserWindowController.pointerEventFilter?(event) ?? true else { return false }
                if event.type == .mouseMoved || event.type == .leftMouseDragged {
                    self.trackSidebarPointer(self.root.convert(event.locationInWindow, from: nil))
                }
                return true
            }
            return accepted ? event : nil
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
        container.onFocusedMetadata = { [weak self] title in
            self?.window?.title = title.isEmpty && self?.context.isIncognito == true ? "Incognito" : title
        }
        container.onURLField = { [weak self] in guard let self else { return }; self.onOpenCommandBar?(.urlField, self.context.currentTab?.url) }
        container.toasts = toasts
        container.onToolbarMenu = { [weak self] in self?.makeToolbarMenu() }
        splitController.onChange = { [weak self] in self?.changed() }
        if let siteControlSource, let siteControlActions {
            let controller = SiteControlController(source: siteControlSource, actions: siteControlActions)
            siteControl = controller
            root.addSubview(controller.view)
            controller.geometry = { [weak self] in self?.siteControlGeometry($0) }
            controller.onDismiss = { [weak self] _ in self?.refreshSiteControlButtons() }
            siteControlToken = siteControlSource.observeChanges { [weak self] _ in self?.scheduleSiteControlButtonsRefresh() }
            container.onSiteControls = { [weak self] id in self?.toggleSiteControls(anchor: .paneBar(id), tabID: id) }
            container.siteControlsAvailable = { [weak self] id in self?.siteControlsAvailable(tabID: id) ?? false }
        }
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
        WindowSpeedTrace.mark("initialRefreshBegin")
        refresh()
        WindowSpeedTrace.mark("controllerInitEnd")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let siteControlToken { siteControlSource?.removeChangeObserver(siteControlToken) }; hintWork?.cancel(); observing = false; if let treeObserver { model.removeObserver(treeObserver) }; if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; container.closeAll(); reveal.reset(); cardSampleTask?.cancel(); if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }; captureStorage?.tearDown(); trafficLightObservers.forEach(NotificationCenter.default.removeObserver) }
    private func scheduleRefresh() {
        guard !refreshPending else { return }; refreshPending = true
        DispatchQueue.main.async { [weak self] in guard let self, self.observing else { return }; self.refreshPending = false; self.refresh() }
    }
    public func refresh() {
        updateWindowAppearance()
        spaceCreationController?.closeThemeEditorIfSpaceChanged()
        if let editor = themeEditor, let id = editor.session?.spaceID,
           model.space(id: id) == nil || context.window?.focusedSpaceID != id { closeThemeEditor() }
        guard let space = context.focusedSpace else { return }
        if !observationArmed {
        observationArmed = true
        withObservationTracking {
            _ = context.currentTab?.url; _ = context.currentTab?.title; _ = context.window?.focusedSpaceID
            _ = context.focusedSpace?.theme
            _ = context.window?.selectedNodeBySpace; _ = context.window?.sidebarMode; _ = context.window?.sidebarWidth; _ = context.window?.showsToolbar; _ = splitController.split?.focusedPaneID
            _ = splitController.split?.orientation; _ = splitController.split?.fractions
            for tab in splitController.split?.panes ?? context.currentTab.map({ [$0] }) ?? [] { _ = tab.live.sleepPhase }
        } onChange: { [weak self] in Task { @MainActor [weak self] in self?.observationArmed = false; self?.scheduleRefresh() } }
        }
        // Sidebar's pager owns theme transitions. Never reset its cross-fade here.
        if spaceCreationController == nil, background.targetStyle != context.style(for: space) { background.crossfade(to: context.style(for: space), animated: window?.isVisible == true && !Motion.reducesMotion && !context.isLiveThemePreview(space.id)) }
        container.style = context.style(for: space)
        container.showsToolbar = context.window?.showsToolbar == true
        let style = context.style(for: space)
        peekStorage?.overlay.style = style
        peekStorage?.overlay.controlsFill = style.lightPalette?.title.nsColor ?? PeekMetrics.defaultControls.nsColor
        peekStorage?.overlay.scrimColor = style.darkPalette?.background.withAlpha(PeekMetrics.scrimAlpha).nsColor ?? PeekMetrics.defaultScrim.nsColor
        splitController.refresh()
        if siteControl?.isPresented == true,
           siteControl?.tabID != splitController.focusedTab?.id || siteControlSpace != context.focusedSpace?.id {
            siteControl?.dismiss(reason: .sourceUnavailable, animated: false)
        }
        refreshSiteControlButtons()
        if let session = boostEditor?.session {
            if context.focusedSpace?.id != boostEditorSpaceID || context.focusedSpace?.profileID != session.context.profileID || splitController.focusedTab?.id != session.context.tabID {
                boostEditor?.close()
            }
        }
        // show() binds the focused host now and defers other panes one turn (§5.4).
        // Refreshing placeholders here repeats every pane's chrome/layout work.
        peekStorage?.refresh(); layoutContent(); syncPeekSidebar(); onVisibilityChange?()
    }
    private func updateWindowAppearance() {
        let appearance: ContentAppearance = context.isIncognito ? .dark
            : context.focusedSpace.map { context.appearance(for: $0) } ?? context.systemAppearance
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        if window?.appearance?.name != name { window?.appearance = appearance.nsAppearance }
    }
    private func syncPeekSidebar() {
        if peekStorage?.isShown == true { siteControl?.dismiss(reason: .sourceUnavailable, animated: false) }
        var badges: [ItemID: SidebarPeekBadge] = [:]
        for item in peekStorage?.stack ?? [] where item.librarySpaceID == nil { badges[item.sourceTabID] = SidebarPeekBadge(url: item.host?.currentURL ?? item.url, faviconPNG: item.faviconPNG) }
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
        defer { updateThemeEditorAnchor() }
        if isLibraryOpen, let libraryPanel {
            let size = root.bounds.size
            if background.frame != root.bounds { background.frame = root.bounds }
            let edge = libraryUsesWideLayout ? size.width - 56 : min(libraryWidth, size.width - 56)
            // Spaces pushes the ordinary Library page past the window's right
            // edge. Keep its width: exactly 56 points remain visible, and the
            // engine does not reflow into a tiny 46-point viewport.
            let pageWidth = libraryUsesWideLayout ? size.width - 427 : size.width - edge - 10
            let panel = CGRect(x: edge, y: 10, width: max(46, pageWidth), height: max(0, size.height - 20))
            finishSidebarPanelLayout(at: panel)
            let libraryFrame = CGRect(x: 0, y: 0, width: edge, height: size.height)
            if libraryPanel.frame != libraryFrame { libraryPanel.frame = libraryFrame; libraryPanel.needsLayout = true }
            if container.frame != panel { container.frame = panel }
            emptyPanel.frame = panel
            emptyPanelHost.frame = root.bounds
            emptyPanelHost.isHidden = !container.isHidden
            sidebar.isHidden = CACurrentMediaTime() >= librarySidebarFadeUntil
            cardShadow.isHidden = true
            resizeHandle.isHidden = true
            toastOverlay.frame = panel
            if let overlay = peekStorage?.overlay {
                overlay.backdrop.frame = root.bounds; overlay.frame = root.bounds
                overlay.contentRect = panel; overlay.needsLayout = true
            }
            siteControl?.view.frame = root.bounds
            siteControl?.layout()
            positionTrafficLights()
            captureStorage?.layout()
            onLayout?()
            return
        }
        let size = root.bounds.size, hidden = isPageFullscreen || (spaceCreationController == nil && context.window?.sidebarMode == .hidden)
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
        let continuingPanelMotion = anchoredSliding && !animated && !Motion.reducesMotion
            && sidebarPanelTarget == panelFrame && sidebarPanelRootSize == size
        let requestedAt = sidebarMotionRequestedAt ?? CACurrentMediaTime()
        if animate { sidebarMotionRequestedAt = nil }
        // Presentation reads are needed only to start/reverse a visible animation,
        // never while building the first window or following a plain width/resize tick.
        var oldPanel = animate ? (container.layer?.presentation()?.frame ?? container.frame) : container.frame
        if animate, container.layer?.mask === sidebarPanelClip {
            oldPanel.size = sidebarPanelClip.presentation()?.bounds.size ?? sidebarPanelClip.bounds.size
        }
        let modelOffset = sidebar.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let oldOffset = animate ? (sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? modelOffset) : modelOffset
        if cardState != .off {
            let card = WindowMetrics.revealCardFrame(windowSize: size, sidebarWidth: width)
            sidebar.cardFieldFrame = CGRect(x: -card.minX, y: -card.minY, width: size.width, height: size.height)
            if sidebar.frame != card { sidebar.frame = card }
            if cardShadow.frame != card { cardShadow.frame = card }
            if container.frame != panelFrame { container.frame = panelFrame }
            if emptyPanel.frame != panelFrame { emptyPanel.frame = panelFrame }
        } else {
            // Set geometry once. Core Animation moves the panel and the sidebar layers;
            // no row layout or model width write runs on the animation's display ticks.
            let sidebarFrame = CGRect(x: 0, y: 0, width: width, height: size.height)
            let targetOffset: CGFloat = hidden ? -width : 0
            // A shrinking clip still needs the old, wider backing until it has
            // finished. Growing can prepare the wider viewport once at entry.
            let defersViewport = animate && panelFrame.width < container.frame.width
            let geometryChanged = (!continuingPanelMotion && container.frame != panelFrame) || sidebar.frame != sidebarFrame
            if geometryChanged && (!defersViewport || sidebar.frame != sidebarFrame) { sidebarGeometryChanges += 1 }
            let targetChanged = (sidebar.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0) != targetOffset
            if case .floatingCard = sidebar.presentation { sidebar.presentation = .anchored }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if animate {
                sidebarPanelTarget = panelFrame
                sidebarPanelRootSize = size
                // One native viewport resize: at entry when growing, at rest
                // when shrinking. The clip never exposes missing backing pixels.
                if !defersViewport && container.frame != panelFrame { container.frame = panelFrame }
                if emptyPanel.frame != panelFrame { emptyPanel.frame = panelFrame }
                container.layoutSubtreeIfNeeded()
            } else if !continuingPanelMotion {
                finishSidebarPanelLayout(at: panelFrame)
                if container.frame != panelFrame { container.frame = panelFrame }
                if emptyPanel.frame != panelFrame { emptyPanel.frame = panelFrame }
            }
            if sidebar.frame != sidebarFrame { sidebar.frame = sidebarFrame }
            sidebar.alphaValue = 1
            sidebar.layer?.setValue(targetOffset, forKeyPath: "transform.translation.x")
            CATransaction.commit()
            if animate || geometryChanged || targetChanged || Motion.reducesMotion {
                sidebarAnimationGeneration += 1
                let generation = sidebarAnimationGeneration
                anchoredSliding = animate
                container.setSidebarSliding(false)
                sidebarAnimations = [:]
                sidebar.isHidden = animate ? false : hidden
                positionTrafficLights()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
                    guard let self, self.sidebarAnimationGeneration == generation else { return }
                    self.anchoredSliding = false
                    self.finishSidebarPanelLayout()
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
                        let spring = Motion.sidebarAnimation(keyPath: "transform.translation.x", showing: !hidden)
                        spring.fromValue = oldOffset; spring.toValue = targetOffset
                        addMotion(spring, to: layer, key: "sidebarToggle", requestedAt: requestedAt)
                        if index == 0 { sidebarAnimations["sidebar"] = layer.animation(forKey: "sidebarToggle") }
                    }
                }
                if animate, let layer = container.layer {
                    let fromTranslation = oldPanel.minX - container.frame.minX
                    let targetTranslation = panelFrame.minX - container.frame.minX
                    layer.removeAnimation(forKey: "sidebarToggle")
                    layer.setValue(targetTranslation, forKeyPath: "transform.translation.x")
                    sidebarPanelClip.anchorPoint = .zero
                    sidebarPanelClip.position = .zero
                    sidebarPanelClip.bounds = CGRect(origin: .zero, size: panelFrame.size)
                    sidebarPanelClip.backgroundColor = NSColor.black.cgColor
                    sidebarPanelClip.cornerRadius = PanelMetrics.cornerRadius
                    sidebarPanelClip.cornerCurve = .continuous
                    layer.mask = sidebarPanelClip
                    let move = Motion.sidebarAnimation(keyPath: "transform.translation.x", showing: !hidden)
                    move.fromValue = fromTranslation; move.toValue = targetTranslation
                    addMotion(move, to: layer, key: "sidebarToggle", requestedAt: requestedAt)
                    sidebarAnimations["panel"] = layer.animation(forKey: "sidebarToggle")
                    let clip = Motion.sidebarAnimation(keyPath: "bounds.size", showing: !hidden)
                    clip.fromValue = NSValue(size: oldPanel.size); clip.toValue = NSValue(size: panelFrame.size)
                    addMotion(clip, to: sidebarPanelClip, key: "sidebarToggle", requestedAt: requestedAt)
                    sidebarPanelShadow.prepare(frame: panelFrame)
                    sidebarPanelShadow.isHidden = container.isHidden
                    for (shadowLayer, key, from, to) in sidebarPanelShadow.motion(from: oldPanel.size, translation: oldPanel.minX - panelFrame.minX) {
                        let spring = Motion.sidebarAnimation(keyPath: key, showing: !hidden)
                        spring.fromValue = from; spring.toValue = to
                        addMotion(spring, to: shadowLayer, key: "sidebarToggle", requestedAt: requestedAt)
                    }
                    // An empty panel has no live text or web surface to stretch.
                    emptyPanel.removeAnimation(forKey: "sidebarToggle")
                    let emptyGroup = CAAnimationGroup()
                    let emptyMove = Motion.sidebarAnimation(keyPath: "position", showing: !hidden)
                    emptyMove.fromValue = NSValue(point: CGPoint(x: oldPanel.midX, y: oldPanel.midY))
                    emptyMove.toValue = NSValue(point: emptyPanel.position)
                    let emptySize = Motion.sidebarAnimation(keyPath: "bounds.size", showing: !hidden)
                    emptySize.fromValue = NSValue(size: oldPanel.size); emptySize.toValue = NSValue(size: panelFrame.size)
                    emptyGroup.animations = [emptyMove, emptySize]
                    emptyGroup.duration = max(emptyMove.duration, emptySize.duration)
                    addMotion(emptyGroup, to: emptyPanel, key: "sidebarToggle", requestedAt: requestedAt)
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
        siteControl?.view.frame = root.bounds
        siteControl?.layout()
        positionTrafficLights()
        hoverPreview.layout()
        captureStorage?.layout()
        onLayout?()
    }
    /// Retire the temporary render-server clip; the native endpoint is already laid out.
    private func finishSidebarPanelLayout(at finalFrame: CGRect? = nil) {
        guard let pending = sidebarPanelTarget else { return }
        let target = finalFrame ?? pending
        sidebarPanelTarget = nil; sidebarPanelRootSize = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.layer?.removeAnimation(forKey: "sidebarToggle")
        sidebarPanelClip.removeAnimation(forKey: "sidebarToggle")
        container.layer?.mask = nil
        sidebarPanelShadow.isHidden = true
        emptyPanel.removeAnimation(forKey: "sidebarToggle")
        container.layer?.transform = CATransform3DIdentity
        emptyPanel.transform = CATransform3DIdentity
        if container.frame != target { container.frame = target; sidebarGeometryChanges += 1 }
        if emptyPanel.frame != target { emptyPanel.frame = target }
        CATransaction.commit()
    }
    /// Delayed idle work attaches only the hidden shell; it never moves the page.
    public var onLibraryIdleRefresh: (() -> Void)?
    public func prepareLibraryPanel(_ panel:NSView,width:CGFloat) {
        guard !isLibraryOpen else { return }
        if libraryPanel !== panel { libraryPanel?.removeFromSuperview(); libraryPanel = panel; root.addSubview(panel,positioned:.below,relativeTo:container) }
        panel.isHidden = true; panel.frame = CGRect(x:0,y:0,width:width,height:contentView.bounds.height)
        panel.layoutSubtreeIfNeeded()
    }
    /// Transient geometry only: the saved sidebar and its live view stay intact.
    public func presentLibraryPanel(_ panel: NSView, width: CGFloat, animated: Bool = true) {
        let wasOpen = isLibraryOpen
        let fadesSidebar = !wasOpen && !sidebar.isHidden && animated && window?.isVisible == true
        let oldFrame = container.layer?.presentation()?.frame ?? container.frame
        dismissSidebarReveal()
        cancelSidebarResize()
        libraryMotionGeneration += 1
        isLibraryOpen = true; libraryWidth = width; libraryUsesWideLayout = width > 417
        librarySidebarFadeUntil = fadesSidebar ? CACurrentMediaTime() + (Motion.reducesMotion ? 0.10 : 0.12) : 0
        if libraryPanel !== panel {
            libraryPanel?.removeFromSuperview(); libraryPanel = panel
            root.addSubview(panel, positioned: .below, relativeTo: container)
        }
        panel.isHidden = false
        layoutContent()
        panel.layoutSubtreeIfNeeded()
        animateLibrary(from: oldFrame, opening: true, duration: wasOpen ? 0.20 : 0.12, animated: animated)
        if !wasOpen, animated { fadeLibrary(panel, from: 0, to: 1, duration: Motion.reducesMotion ? 0.10 : 0.12) }
        if fadesSidebar {
            let generation = libraryMotionGeneration
            let duration = Motion.reducesMotion ? 0.10 : 0.12
            fadeLibrary(sidebar, from: 1, to: 0, duration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.isLibraryOpen, self.libraryMotionGeneration == generation else { return }
                self.sidebar.isHidden = true
            }
        }
    }
    public func dismissLibraryPanel(animated: Bool = true) {
        guard isLibraryOpen else { return }
        let oldFrame = container.layer?.presentation()?.frame ?? container.frame
        libraryMotionGeneration += 1
        let generation = libraryMotionGeneration
        isLibraryOpen = false
        layoutContent()
        animateLibrary(from: oldFrame, opening: false, duration: 0.20, animated: animated)
        guard let panel = libraryPanel else { return }
        if animated, window?.isVisible == true {
            let duration = Motion.reducesMotion ? 0.10 : 0.20
            fadeLibrary(panel, from: 1, to: 0, duration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
                guard let self, self.libraryMotionGeneration == generation, !self.isLibraryOpen else { return }
                panel?.isHidden = true
            }
        } else { panel.isHidden = true }
    }
    public func releaseLibraryPanel() {
        guard !isLibraryOpen else { return }
        libraryPanel?.removeFromSuperview(); libraryPanel = nil; libraryKeyHandler = nil
    }
    private func fadeLibrary(_ view: NSView, from: Float, to: Float, duration: Double) {
        view.wantsLayer = true
        view.layer?.removeAnimation(forKey: "libraryFade")
        view.alphaValue = CGFloat(to)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = to; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        view.layer?.add(fade, forKey: "libraryFade")
    }
    private func animateLibrary(from old: CGRect, opening: Bool, duration: Double, animated: Bool) {
        for layer in [container.layer, Optional(emptyPanel)] {
            layer?.removeAnimation(forKey: "libraryFrame")
            guard animated, !Motion.reducesMotion, window?.isVisible == true, let layer else { continue }
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: CGPoint(x: old.minX + old.width * layer.anchorPoint.x, y: old.minY + old.height * layer.anchorPoint.y))
            position.toValue = NSValue(point: layer.position)
            let size = CABasicAnimation(keyPath: "bounds.size")
            size.fromValue = NSValue(size: old.size); size.toValue = NSValue(size: layer.bounds.size)
            let group = CAAnimationGroup(); group.animations = [position, size]; group.duration = duration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            layer.add(group, forKey: "libraryFrame")
        }
        if !opening, animated, !sidebar.isHidden { fadeLibrary(sidebar, from: 0, to: 1, duration: Motion.reducesMotion ? 0.10 : duration) }
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
        let hidden = !isLibraryOpen && (isPageFullscreen || (spaceCreationController == nil && cardState == .off && context.window?.sidebarMode == .hidden && !anchoredSliding))
        for kind in Self.trafficLightKinds {
            guard let button = window.standardWindowButton(kind) else { continue }
            if button.isHidden != hidden { button.isHidden = hidden }
            if isLibraryOpen { button.layer?.removeAnimation(forKey: "sidebarToggle"); button.layer?.setValue(0, forKeyPath: "transform.translation.x") }
        }
        if isLibraryOpen { dimmedLights.layer?.removeAnimation(forKey: "sidebarToggle"); dimmedLights.layer?.setValue(0, forKeyPath: "transform.translation.x") }
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
        // Move the whole card and its shadow past the window edge. Leaving the
        // panel inset visible makes the later native hide pop those pixels away.
        let away = -(card.maxX + WindowMetrics.revealCardShadowOutset)
        let animate = window?.isVisible == true && !Motion.reducesMotion
        let from = cardState == .off ? away : currentCardOffset()
        cardGeneration += 1
        let generation = cardGeneration
        if shown {
            finishSidebarPanelLayout()
            container.setSidebarSliding(false)
            // Clear anchored-hide transforms before the same layers become a card.
            for layer in [sidebar.layer, dimmedLights.layer].compactMap({ $0 }) + Self.trafficLightKinds.compactMap({ window?.standardWindowButton($0)?.layer }) {
                layer.removeAnimation(forKey: "sidebarToggle")
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.setValue(0, forKeyPath: "transform.translation.x"); CATransaction.commit()
            }
            anchoredSliding = false
            sidebarAnimationGeneration += 1
            cardState = .shown
            sidebar.cardFieldFrame = CGRect(x: -card.minX, y: -card.minY, width: size.width, height: size.height)
            sidebar.prepareFloatingCard(size: card.size)
            sidebar.presentation = .floatingCard
            if sidebar.frame != card { sidebar.frame = card }
            sidebar.alphaValue = 1
            if cardShadow.frame != card { cardShadow.frame = card }
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
        sidebar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
            ?? sidebar.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    private func slideCard(from: CGFloat, to: CGFloat, generation: Int, completion: (@MainActor () -> Void)?) {
        let layers = [sidebar.layer, cardShadow.layer].compactMap { $0 }
        let buttons = Self.trafficLightKinds.compactMap { window?.standardWindowButton($0)?.layer } + [dimmedLights.layer].compactMap { $0 }
        cardAnimations = [:]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.cardGeneration == generation else { return }
                completion?()
            }
        }
        for layer in layers + buttons {
            layer.removeAnimation(forKey: "reveal")
            layer.setValue(to, forKeyPath: "transform.translation.x")
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
            slide.isRemovedOnCompletion = true
            addMotion(slide, to: layer, key: "reveal")
            if layer === sidebar.layer { cardAnimations["card"] = layer.animation(forKey: "reveal") }
            if layer === cardShadow.layer { cardAnimations["shadow"] = layer.animation(forKey: "reveal") }
        }
        CATransaction.commit()
    }

    private func finishCardHide(_ generation: Int) {
        guard generation == cardGeneration, cardState == .hiding else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cardState = .off
        sidebar.isHidden = true
        cardShadow.isHidden = true
        for layer in [sidebar.layer, cardShadow.layer, dimmedLights.layer].compactMap({ $0 }) + Self.trafficLightKinds.compactMap({ window?.standardWindowButton($0)?.layer }) {
            layer.removeAnimation(forKey: "reveal")
        }
        // Keep the offscreen model transforms until the next show or anchored
        // layout. Resetting them before AppKit commits button visibility briefly
        // draws the three dimmed circles over the page at the hide endpoint.
        positionTrafficLights()
        CATransaction.commit()
        // Keep the hidden card's prepared geometry. Re-anchoring every dismissal
        // lays out all sidebar rows twice per reveal, although the page never moves.
        // An actual anchored layout restores the sidebar's presentation once.
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
        dragStartMode = context.window?.sidebarMode
        resizingSidebar = true
        removeRevealCard()
    }
    public func resizeSidebar(to x: CGFloat, ended: Bool) {
        guard resizingSidebar, x.isFinite, let state = context.window else { return }
        let hidden = x < WindowMetrics.sidebarDragHidePoint
        context.sidebarWidthOverride = min(WindowMetrics.maxSidebarWidth, max(WindowMetrics.minSidebarWidth, x))
        let crossed = (state.sidebarMode == .hidden) != hidden
        if crossed {
            sidebarMotionRequestedAt = CACurrentMediaTime()
            model.setSidebarMode(windowID: windowID, mode: hidden ? .hidden : .anchored, registerUndo: false)
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
        if let dragStartMode { model.registerSidebarModeUndo(windowID: windowID, from: dragStartMode) }
        resizingSidebar = false; dragStartWidth = nil; dragStartMode = nil
        resizeHandle.isHidden = hidden
        if !hidden || !anchoredSliding { context.sidebarWidthOverride = nil }
        // A hidden flick keeps the live width until the running slide completes.
        changed()
    }
    /// All interruptions share this path. The stored width has never changed; dropping
    /// the live override restores it. Reset the handle too, so late drag/up events do nothing.
    private func cancelSidebarResize() {
        resizeHandle.cancelDrag()
        guard resizingSidebar else { return }
        if let dragStartMode { model.setSidebarMode(windowID: windowID, mode: dragStartMode, registerUndo: false) }
        resizingSidebar = false; dragStartWidth = nil; dragStartMode = nil
        context.sidebarWidthOverride = nil
        removeRevealCard()
        layoutContent()
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
    public var sidebarResizeHandleDragging: Bool { resizeHandle.dragging }
    public var sidebarResizeHandleVisible: Bool { !resizeHandle.isHidden }
    public var sidebarResizeHasStart: Bool { dragStartWidth != nil || dragStartMode != nil }
    /// True while the hover-reveal card draws its tint over the blurred page (automation).
    public var cardDrawsPageBlur: Bool { cardState != .off && sidebar.cardDrawsPageBlur }
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
    public var canExitModal: Bool { !isCommandBarPresented && (isLibraryOpen || spaceCreationController != nil || peekStorage?.isShown == true || container.maximizedTabID != nil) }
    /// View > Exit and Esc share this priority. The App validates the key standard window.
    @discardableResult public func exitModal() -> Bool {
        // Its field editor owns Esc; an underlying Peek must not enable Exit.
        guard !isCommandBarPresented else { return false }
        if isLibraryOpen, peekStorage?.isShown != true, !isCommandBarPresented, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53), libraryKeyHandler?(event) == true { return true }
        if !isCommandBarPresented, let creation = spaceCreationController { creation.cancel(); return true }
        if let peek = peekStorage, peek.isShown { peek.escape(); return true }
        if container.maximizedTabID != nil {
            splitController.performCommand("escape"); container.cancelOperation(nil); return true
        }
        return false
    }
    /// Shared window-local key path. Focus comes from AppKit's current responder.
    @discardableResult public func handleKeyDown(_ event: NSEvent, unconsumed: Bool = false) -> Bool {
        // Window-less events belong here only while this controller's theme
        // panel is key. Engine events from other windows must keep their owner.
        let keyEditor = spaceCreationController?.themeEditor ?? themeEditor
        let eventWindow = event.window ?? keyEditor.flatMap { NSApp.keyWindow === $0.panel ? $0.panel : nil }
        guard let eventWindow,
              eventWindow === window || eventWindow === keyEditor?.panel || ownsAdditionalKeyWindow?(eventWindow) == true
                || existingTabSwitcher?.acceptsEventWindow(eventWindow) == true else { return false }
        if eventWindow === keyEditor?.panel {
            if event.modifierFlags.contains(.command), [13, 17, 37].contains(event.keyCode) {
                keyEditor?.close()
            } else { return false }
        }
        if existingTabSwitcher?.handle(event) == true { return true }
        // A command bar opened above Library owns its keys until it dismisses.
        if isLibraryOpen, peekStorage?.isShown != true, !isCommandBarPresented, libraryKeyHandler?(event) == true { return true }
        // Toggle before SCC's generic Command-key dismissal. Otherwise the
        // same key closes the picker here and reopens it through the menu.
        // Use the effective binding so user overrides keep the same behavior.
        if eventWindow === window, siteControl?.isPresented == true, siteControl?.mode == .extensionPicker,
           let command = CommandRegistry.byID["open-extensions-picker"],
           let shortcut = KeyboardShortcut.from(event: event),
           keyBindingOverrides.effectiveShortcuts(for: command).contains(shortcut) {
            return presentExtensionPicker()
        }
        if eventWindow === window, siteControl?.handleKey(event) == true { return true }
        // A window-anchored popover the App shows (the translate popover, page-platform §4.7.3)
        // takes Esc and Return before any other route.
        if let keyInterceptor, keyInterceptor(event) { return true }
        if boostEditor?.handleKeyDown(event) == true { return true }
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
        // Sad Tab controls qualify only for pane switching, never web editing.
        let paneFocused = webFocused || container.slots.contains { within($0.sadTabView) }
            || (peekStorage?.isShown == true && within(peekStorage?.overlay.sadTabView))
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
        // Extensions run after Open's reserved and non-page-first bindings, before the page.
        // The App drops conflicts with every Open default/user binding from this table.
        if !routing.isCommandBarOpen, onExtensionShortcut?(event) == true {
            lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
            return true
        }
        guard case .browserCommand(let id)? = decision,
              handles(id) || onCommand != nil,
              isCommandEnabled(id, enabledKey: CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always) else { return false }
        // These bindings have window scope in the registry; restrict them to the
        // page here so sidebar controls and AppKit field editors retain their keys.
        if id.hasPrefix("focus-split-pane-"), !paneFocused { return false }
        if id == "tab-switcher-forward" || id == "tab-switcher-backward" {
            let previous = tabSwitcherKeyEvent
            tabSwitcherKeyEvent = event
            defer { tabSwitcherKeyEvent = previous }
            performCommand(id)
        } else { performCommand(id) }
        lastKeyRoute = (eventWindow.windowNumber, event.keyCode, flags, event.timestamp, true)
        return true
    }
    private func handles(_ id: String) -> Bool { ["edit-theme", "add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view", "next-split-pane", "previous-split-pane", "open-in-current-space", "go-back", "go-forward"].contains(id) || id.hasPrefix("focus-split-pane-") }
    public func performCommand(_ id: String) {
        if id == "edit-theme" { if let space = context.focusedSpace { _ = editSpaceTheme(space.id) }; return }
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
        if id == "edit-theme" { return context.focusedSpace != nil }
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
        case .showSiteControls:
            guard NSApp.currentEvent?.modifierFlags.contains(.option) != true,
                  let id = splitController.focusedTab?.id else { return false }
            toggleSiteControls(anchor: .urlField, tabID: id)
            return siteControl != nil
        case .editSpaceTheme(let id): return editSpaceTheme(id)
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
        case .dismissFavoritesEmptyState(let id):
            guard let profile = model.profile(id: id) else { return false }
            profile.favoritesEmptyStateDismissed = true; changed(); return true
        case .deleteFolder(let id): return confirmDeleteFolders([id])
        case .deleteLiveFolder(let id): return confirmDeleteLiveFolder(id)
        case .setLiveRepository(let id, let repository, let hidden):
            model.setLiveRepository(folderID: id, repository: repository, hidden: hidden); changed(); return true
        case .deleteFolders(let ids, let archiveFolderTabs): return confirmDeleteFolders(ids, archiveFolderTabs: archiveFolderTabs)
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
    /// One controller per window. A repeated entry focuses the existing panel.
    @discardableResult public func editSpaceTheme(_ id: SpaceID) -> Bool {
        guard model.space(id: id) != nil, let window else { return false }
        if let editor = themeEditor, editor.session?.spaceID == id, !editor.isClosed {
            editor.panel.makeKeyAndOrderFront(nil); return true
        }
        if let editor = themeEditor { _ = editor.retarget(to: id) }
        if context.window?.focusedSpaceID != id {
            let undo = model.undoManager; undo?.disableUndoRegistration()
            model.focusSpace(windowID: windowID, spaceID: id)
            undo?.enableUndoRegistration(); refresh(); snapshotStore?.scheduleSave(model: model)
        }
        if let editor = themeEditor {
            updateThemeEditorAnchor(); editor.panel.makeKeyAndOrderFront(nil); return true
        }
        // Hidden and hover-revealed sidebars use the window's leading edge +8.
        let frame = context.window?.sidebarMode == .hidden
            ? CGRect(x: 8, y: 0, width: 0, height: root.bounds.height)
            : root.convert(sidebar.bounds, from: sidebar)
        let editor = ThemeEditorController(model: model, spaceID: id, window: window,
                                          anchor: .sidebarTrailingEdge(sidebarFrameInWindow: frame))
        themeEditor = editor
        editor.onCommit = { [weak model, store = snapshotStore] in
            guard let model else { return }; store?.scheduleSave(model: model)
        }
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.themeEditor === editor else { return }
            self.themeEditor = nil
            // Return keyboard focus to browser chrome. A page responder would
            // otherwise consume Cmd+Z without reaching the shared model undo.
            self.window?.makeFirstResponder(self.sidebar.focusedOutline)
            if editor?.panel.isKeyWindow == true, NSApp.isActive { self.window?.makeKey() }
        }
        editor.show(); context.isWindowActive = true; background.isWindowActive = true; return true
    }
    private func updateThemeEditorAnchor() {
        guard let editor = themeEditor else { return }
        let frame = context.window?.sidebarMode == .hidden
            ? CGRect(x: 8, y: 0, width: 0, height: root.bounds.height)
            : root.convert(sidebar.bounds, from: sidebar)
        editor.updateAnchor(.sidebarTrailingEdge(sidebarFrameInWindow: frame))
    }
    public func closeThemeEditor() { themeEditor?.close(); themeEditor = nil }
    public func windowWillClose(_ notification: Notification) {
        siteControl?.dismiss(reason: .sourceUnavailable, animated: false)
        // Tear down this controller's appearance observation once at window close.
        systemAppearanceObservation = nil
        if let increaseContrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(increaseContrastObserver) }
        increaseContrastObserver = nil
        boostEditor?.close(returnFocus: false)
        pendingSpaceCreationOptions = nil
        cancelSidebarResize()
        spaceCreationController?.onFinish = nil
        spaceCreationController?.cancel(); spaceCreationController = nil
        closeThemeEditor()
        existingTabSwitcher?.cancel()
        saveWindowState(); visibilityOverride = .closed; removeRevealCard(); hintWork?.cancel(); hintWork = nil
        hoverPreview.hide(animated: false); captureStorage?.tearDown()
        container.closeAll(); onClose?(); onVisibilityChange?()
    }
    public var onTextUndoManager: ((NSWindow) -> UndoManager?)?
    private lazy var nativeTextUndoManager = UndoManager()
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let editor = onTextUndoManager?(window) { return editor }
        if let creation = spaceCreationController { return creation.localUndoManager }
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField { return nativeTextUndoManager }
        return model.undoManager
    }
    public func windowDidResize(_ notification: Notification) { layoutContent(); existingTabSwitcher?.layout() }
    public func windowDidMove(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowDidEndLiveResize(_ notification: Notification) { saveWindowState(); snapshotStore?.scheduleSave(model: model) }
    public func windowWillEnterFullScreen(_ notification: Notification) { saveWindowState(); fullscreenTransition = true; applyTrafficLightDim(animated: false); dimmedLights.isHidden = true }
    public func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true; applyTrafficLightDim(animated: false) }
    public func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?(); resumePendingSpaceCreation() }
    public func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false; fullScreenTransitionCount += 1; layoutContent(); onVisibilityChange?()
        // The window is back at its frame; the pointer may or may not be over the buttons.
        dimmedLights.syncWithPointer()
        resumePendingSpaceCreation()
    }
    public func windowDidBecomeKey(_ notification: Notification) {
        context.isWindowActive = true; background.isWindowActive = true; positionTrafficLights(); onFocus?()
        // Back from another app or a hide (Cmd+H): the pointer may have left the buttons meanwhile.
        dimmedLights.syncWithPointer()
    }
    public func windowWillBeginSheet(_ notification: Notification) { cancelSidebarResize() }
    public func windowDidResignKey(_ notification: Notification) { cancelSidebarResize(); existingTabSwitcher?.cancel(); let active = (themeEditor != nil || spaceCreationController?.themeEditor != nil) && NSApp.isActive; context.isWindowActive = active; background.isWindowActive = active; positionTrafficLights() }
    public func windowDidChangeBackingProperties(_ notification: Notification) { positionTrafficLights() }
    public func windowDidBecomeMain(_ notification: Notification) { context.isWindowActive = true }
    public func windowDidResignMain(_ notification: Notification) { siteControl?.dismiss(reason: .sourceUnavailable, animated: false); context.isWindowActive = window?.isKeyWindow == true }
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
final class BrowserWindow: SpaceThemeWindow {
    var allowsActivation = true
    var refusesFirstResponder: ((NSResponder?) -> Bool)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if refusesFirstResponder?(responder) == true { return false }
        return super.makeFirstResponder(responder)
    }
    override var canBecomeKey: Bool { allowsActivation && super.canBecomeKey }
    override var canBecomeMain: Bool { allowsActivation && super.canBecomeMain }
    var onLayoutPass: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    override func performClose(_ sender: Any?) {
        onCloseRequest?()
        super.performClose(sender)
    }
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
    var onDragBackground: ((NSEvent) -> Void)?
    override init(frame: CGRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
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
    private(set) var dragging = false
    private var moved = false
    func cancelDrag() { dragging = false; moved = false }
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

    /// Delete folder(s): alert, one undo step, then the toast. The captured normal mixed menu
    /// archives each contained tab separately; other callers retain folder records.
    func confirmDeleteFolders(_ ids: [ItemID], archiveFolderTabs: Bool = false) -> Bool {
        guard let window, pendingConfirmation == nil, let alert = SidebarConfirmations.deleteFoldersAlert(model: model, ids: ids, quoteTitle: archiveFolderTabs) else { return false }
        let folders = ids.filter { model.node(id: $0)?.folder != nil }.count
        let restoreKeyboardFocus = context.keyboardFocusAfterDeletion()
        pendingConfirmation = alert
        let shown = SidebarConfirmations.present(alert, on: window) { [weak self] confirmed in
            guard let self else { return }
            self.pendingConfirmation = nil
            guard confirmed else { return }
            var archived = 0
            self.keepingSelection { archived = self.model.archiveNodes(ids: ids, archiveFolderTabs: archiveFolderTabs) }
            guard archived > 0 else { return }
            self.refresh(); restoreKeyboardFocus(); self.changed()
            self.showModelUndoToast(SidebarConfirmations.folderToast(count: folders))
        }
        if !shown { pendingConfirmation = nil }
        return shown
    }

    /// Live Folder delete: the alert, then the folder and its rows go (no Archive), and automatic
    /// creation turns off until the user turns it on from the Space menu (live-data §2.1, W2).
    public static let liveFolderAutoCreateKey = "open.liveFolders.githubAutoCreate"
    func confirmDeleteLiveFolder(_ id: ItemID) -> Bool {
        guard let window, pendingConfirmation == nil, model.node(id: id)?.folder?.live != nil else { return false }
        let alert = SidebarConfirmations.deleteLiveFolderAlert()
        pendingConfirmation = alert
        let shown = SidebarConfirmations.present(alert, on: window) { [weak self] confirmed in
            guard let self else { return }
            self.pendingConfirmation = nil
            guard confirmed else { return }
            self.keepingSelection { self.model.removeLiveFolder(id: id) }
            self.defaults.set(false, forKey: Self.liveFolderAutoCreateKey)
            self.refresh(); self.changed()
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


extension BrowserWindowController {
    @discardableResult
    public func beginSpaceCreation(options: SpaceCreationOptions = SpaceCreationOptions()) -> Bool {
        if !isPageFullscreen, let creation = spaceCreationController { creation.focus(); return true }
        guard let window, model.canCreateSpace(at: options.insertionIndex, moving: options.moving,
                                               removingEmptyFolder: options.removingEmptyFolder) else { return false }
        if isPageFullscreen {
            pendingSpaceCreationOptions = options
            guard onExitPageFullscreen?() == true else { pendingSpaceCreationOptions = nil; return false }
            return true
        }
        closeThemeEditor()
        dismissSidebarReveal()
        let previousSpaceID = context.focusedSpace?.id
        let creation = SpaceCreationController(model: model, windowID: windowID, options: options)
        creation.creationView.systemAppearance = context.systemAppearance
        creation.onPickIcon = { [weak self] icon, rect, pick in
            self?.onSpaceCreationIcon?(icon, rect, pick)
        }
        creation.onDraftStyle = { [weak self] style in self?.sidebar.previewSpaceCreation(style) }
        creation.onFinish = { [weak self, weak creation] space in
            guard let self, self.spaceCreationController === creation else { return }
            if space == nil, let previousSpaceID, self.model.space(id: previousSpaceID) != nil,
               self.context.focusedSpace?.id != previousSpaceID {
                self.model.undoManager?.disableUndoRegistration()
                self.model.focusSpace(windowID: self.windowID, spaceID: previousSpaceID)
                self.model.undoManager?.enableUndoRegistration()
            }
            self.sidebar.endSpaceCreation(focus: space?.id ?? previousSpaceID)
            self.spaceCreationController = nil; window.makeFirstResponder(nil)
            self.refresh(); if space != nil { self.changed() }
        }
        spaceCreationController = creation; layoutContent(animated: true)
        sidebar.beginSpaceCreation(page: creation.view); creation.updatePreview(); creation.focus()
        return true
    }
    private func resumePendingSpaceCreation() {
        guard !isPageFullscreen, !fullscreenTransition, window?.isVisible == true,
              let options = pendingSpaceCreationOptions else { return }
        pendingSpaceCreationOptions = nil
        _ = beginSpaceCreation(options: options)
    }
}

/// A prepared shadow outside the animated panel clip. Only its layer paths move.
@MainActor
private final class SidebarPanelShadowView: NSView {
    private let shadowLayer = CALayer()
    private let outside = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; isHidden = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = PanelMetrics.shadowOpacity
        shadowLayer.shadowRadius = PanelMetrics.shadowRadius
        shadowLayer.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)
        outside.fillRule = .evenOdd; shadowLayer.mask = outside
        layer?.addSublayer(shadowLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func prepare(frame: CGRect) {
        self.frame = frame
        shadowLayer.frame = bounds; outside.frame = bounds
        shadowLayer.shadowPath = shape(bounds.size)
        outside.path = exterior(bounds.size)
        layer?.setValue(0, forKeyPath: "transform.translation.x")
        isHidden = false
    }
    func motion(from size: CGSize, translation: CGFloat) -> [(CALayer, String, Any, Any)] {
        guard let layer else { return [] }
        return [(layer, "transform.translation.x", translation, CGFloat(0)),
                (shadowLayer, "shadowPath", shape(size), shape(bounds.size)),
                (outside, "path", exterior(size), exterior(bounds.size))]
    }
    private func shape(_ size: CGSize) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: PanelMetrics.cornerRadius,
               cornerHeight: PanelMetrics.cornerRadius, transform: nil)
    }
    private func exterior(_ size: CGSize) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24))
        path.addPath(shape(size)); return path
    }
}
