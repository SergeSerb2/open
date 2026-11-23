import AppKit
import Observation
import OpenModel
import OpenSuggest
import OpenCommands
import OpenDesign
import OpenCommandBar
import OpenExtensionsUI

@MainActor
final class FeatureRootView: NSView {
    var onLayout: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
private final class LittleOpenNativeWindow: SpaceThemeWindow {
    var redirectPageFocus: ((NSResponder?) -> NSResponder?)?
    var onLayoutPass: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var onDownloadsKey: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onDownloadsKey?(event) == true { return }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) { onCloseRequest?(); super.performClose(sender) }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        super.makeFirstResponder(redirectPageFocus?(responder) ?? responder)
    }
    override func layoutIfNeeded() { super.layoutIfNeeded(); onLayoutPass?() }
    override func displayIfNeeded() { super.layoutIfNeeded(); onLayoutPass?(); super.displayIfNeeded() }
}

@MainActor
public final class LittleOpenWindowController: NSWindowController, NSWindowDelegate, CommandBarDelegate {
    public var contentView: NSView { root }
    public var onCloseRequested: (() -> Void)?
    /// Edit ▸ Find (Find…, Find Next, Find Previous, Use Selection for Find) for the shown page, by
    /// menu tag. The App routes it to the page's find bar; nil leaves the items disabled (UX1 D7).
    public var onFind: ((Int) -> Void)?
    public var onCloseDownloads: (() -> Void)?
    public var onDownloadsKey: ((NSEvent) -> Bool)?
    public let session: LittleOpenSession
    public private(set) var state: LittleOpenWindowState = .bar
    public private(set) var container: WebContentContainer
    public let titleBar = LittleOpenTitleBarView(frame: .zero)
    public let commandBar: CommandBarController
    /// Compatibility for callers that focus the URL field; the real bar owns the editor.
    public var urlField: NSTextField { commandBar.view.inputField }
    public var pillSpaceID: SpaceID? { coordinator?.model.mostRecentlyFocusedSpace(profileID: session.profileID)?.id }
    public private(set) var spacePicker: LittleOpenSpacePicker?
    public private(set) var spacePopover: NSPopover?
    /// The App supplies the context of this window's profile; no engine dependency here.
    public var extensionsUI: ExtensionsUIContext? {
        didSet {
            if let extensionObservation { oldValue?.removeObserver(extensionObservation) }
            extensionObservation = extensionsUI?.observe { [weak self] change in
                if case .list = change { self?.refreshExtensions() }
            }
            refreshExtensions()
        }
    }
    public var extensionsButton: NSButton { titleBar.extensionsButton }
    private var extensionObservation: UUID?
    private var extensionsMenu: NSMenu?
    private weak var coordinator: LittleOpenCoordinator?
    private let factory: any WebContentHostFactory
    private let defaults: UserDefaults
    private let screen: LittleOpenScreen
    let root = FeatureRootView(frame: CGRect(origin: .zero, size: LittleOpenMetrics.barSize))
    private let banner = NSView()
    private let bannerLabel = NSTextField(labelWithString: LittleOpenMetrics.bannerText)
    private let bannerButton = NSButton(title: "Got it", target: nil, action: nil)
    private var closed = false
    private var hasPresented = false
    private var opening = true
    private var placingTrafficLights = false
    private var actionBindings: KeyBindingStore?
    private var systemAppearanceObservation: NSKeyValueObservation?
    public var currentURL: URL? { container.host(for: session.tab.id)?.currentURL }
    public var showsIntro: Bool { !banner.isHidden }
    /// A page in HTML fullscreen fills the window: no title bar, intro banner or rounded corners
    /// over the video (bug sweep r6 WL-07).
    public var isPageFullscreen = false {
        didSet {
            guard isPageFullscreen != oldValue else { return }
            root.layer?.cornerRadius = isPageFullscreen ? 0 : LittleOpenMetrics.windowCornerRadius
            layoutContent()
        }
    }

    public init(session: LittleOpenSession, coordinator: LittleOpenCoordinator, factory: any WebContentHostFactory, defaults: UserDefaults) {
        self.session = session; self.coordinator = coordinator; self.factory = factory; self.defaults = defaults
        screen = coordinator.screenProvider()
        container = WebContentContainer(factory: factory)
        commandBar = CommandBarController(engine: SuggestEngine(model: coordinator.model, fetcher: nil))
        let window = LittleOpenNativeWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The App lists sessions itself, with stable ids and MRU ordering.
        window.isExcludedFromWindowsMenu = true
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        // The root paints the normal fill. An opaque WindowServer background
        // would remain as a white rectangle while the native frame fades out.
        window.isOpaque = false; window.backgroundColor = .clear
        window.isMovableByWindowBackground = true; window.animationBehavior = .none
        super.init(window: window)
        window.onDownloadsKey = { [weak self] in self?.onDownloadsKey?($0) ?? false }
        root.appearance = NSApp.effectiveAppearance
        window.contentView = root; window.delegate = self; window.title = "Little Open"
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // assumeIsolated requires every NSApp.appearance write to run on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                let appearance = NSApp.effectiveAppearance
                if self.root.appearance?.name != appearance.name { self.root.appearance = appearance }
                self.updateChrome()
            }
        }
        // Alloy can finish creating its renderer after the embedded field was
        // focused. Keep that late native focus request behind the open bar.
        window.redirectPageFocus = { [weak self] responder in
            guard let self, self.commandBar.isPresented, let view = responder as? NSView,
                  view === self.container || view.isDescendant(of: self.container) else { return nil }
            return self.urlField
        }
        window.onLayoutPass = { [weak self] in self?.placeTrafficLights() }
        window.onCloseRequest = { [weak self] in self?.onCloseRequested?() }
        // S2 19/0003: top-right on the pointer's screen. No autosave or cascade.
        let size = LittleOpenMetrics.barSize, visible = screen.visibleFrame, inset = LittleOpenMetrics.screenInset
        window.setFrame(CGRect(x: visible.maxX - inset - size.width, y: visible.maxY - inset - size.height, width: size.width, height: size.height), display: false)
        root.layer?.backgroundColor = LittleOpenMetrics.titleBarFill.cgColor
        root.layer?.cornerRadius = LittleOpenMetrics.windowCornerRadius; root.layer?.cornerCurve = .continuous; root.layer?.masksToBounds = true
        root.addSubview(container); root.addSubview(titleBar)
        titleBar.onExtensions = { [weak self] in self?.showExtensionsMenu() }
        banner.wantsLayer = true; banner.layer?.backgroundColor = LittleOpenMetrics.titleBarFill.cgColor
        bannerLabel.font = .systemFont(ofSize: LittleOpenMetrics.fontSize); bannerLabel.textColor = LittleOpenMetrics.text.nsColor
        bannerButton.target = self; bannerButton.action = #selector(dismissIntro)
        bannerButton.isBordered = false; bannerButton.font = .systemFont(ofSize: LittleOpenMetrics.fontSize)
        bannerButton.contentTintColor = LittleOpenMetrics.text.nsColor; bannerButton.wantsLayer = true
        bannerButton.layer?.backgroundColor = LittleOpenMetrics.capsuleFill.cgColor
        bannerButton.layer?.cornerRadius = LittleOpenMetrics.keycapRadius
        banner.addSubview(bannerLabel); banner.addSubview(bannerButton); banner.isHidden = true; root.addSubview(banner)
        commandBar.delegate = self; commandBar.allowsSearchHelp = false
        commandBar.isActionEnabled = { [weak coordinator] id, space in coordinator?.isActionEnabled?(id, space) ?? false }
        root.addSubview(commandBar.view)
        titleBar.onEditURL = { [weak self] in self?.focusURL() }
        titleBar.onCopy = { [weak self] in self?.copyURL() }
        titleBar.onProfile = { [weak self] in guard let self else { return }; self.profileMenu().popUp(positioning: nil, at: .zero, in: self.titleBar.profileButton) }
        titleBar.onOpenInSpace = { [weak self] in self?.openInCurrentSpace() }
        titleBar.onMoreSpaces = { [weak self] in self?.showSpacePicker() }
        root.onLayout = { [weak self] in self?.layoutContent() }
        configureContainer(); opening = false
        layoutContent(); observeChrome(); if state == .bar { presentCommandBar() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private func configureContainer() {
        container.fullBleed = true
        container.tabProvider = { [weak session] id in session?.tab.id == id ? session?.tab : nil }
        container.onFocusedMetadata = { [weak self] title in
            guard let self else { return }
            self.window?.title = self.state == .bar ? "Little Open" : title
            self.updateChrome(); self.coordinator?.onChange?()
            self.barLoadChanged()
        }
        // E3 URL change is the committed-URL boundary (routing §7). Ignore about:blank.
        container.onTabURLChanged = { [weak self] _, url in
            guard let self else { return }
            if url.absoluteString != "about:blank" { self.commitPage() }
            self.coordinator?.recordActivity(self.session.id)
        }
        container.show(tabIDs: [session.tab.id], focusedTabID: session.tab.id, orientation: .horizontal, fractions: [1], spaceID: SpaceID(), profileID: session.profileID)
    }
    /// A blank bar's submitted address: true from Return until the page commits or its load ends.
    private var barLoadPending = false
    private var barLoadStarted = false
    /// A load from the blank bar that ended without a commit (a download, `about:blank`) brings the
    /// embedded bar back, so the window keeps its input, Esc, and close control.
    private func barLoadChanged() {
        guard barLoadPending, state == .bar, !closed else { barLoadPending = false; return }
        if session.tab.live.isLoading { barLoadStarted = true; return }
        guard barLoadStarted else { return }
        barLoadPending = false
        restoreEmbeddedBarIfNeeded()
    }
    private func commitPage() {
        guard state == .bar, let window else { return }
        barLoadPending = false
        state = .page
        commandBar.dismiss(reason: .programmatic)
        window.styleMask.insert(.resizable); window.minSize = LittleOpenMetrics.minimumPageSize
        let available = screen.visibleFrame.insetBy(dx: LittleOpenMetrics.screenInset, dy: LittleOpenMetrics.screenInset)
        let size = CGSize(width: min(LittleOpenMetrics.pageSize.width, available.width), height: min(LittleOpenMetrics.pageSize.height, available.height))
        let right = min(available.maxX, max(available.minX + size.width, window.frame.maxX))
        let top = min(available.maxY, max(available.minY + size.height, window.frame.maxY))
        window.setFrame(CGRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height), display: false, animate: false)
        banner.isHidden = !(coordinator?.claimIntro() ?? false)
        layoutContent(); updateChrome()
        if !opening { container.focus(tabID: session.tab.id) }
        coordinator?.onChange?()
    }
    private func layoutContent() {
        // Metadata, root layout and window notifications may request the same
        // layout. Equal frame writes still enter the engine geometry bridge.
        func setFrame(_ view: NSView, _ frame: CGRect) { if view.frame != frame { view.frame = frame } }
        let m = LittleOpenMetrics.self, w = root.bounds.width, h = root.bounds.height
        let isPage = state == .page, full = isPage && isPageFullscreen
        titleBar.isHidden = !isPage || full; container.isHidden = !isPage
        let titleHeight = full ? 0 : m.titleBarHeight
        setFrame(titleBar, CGRect(x: 0, y: h - m.titleBarHeight, width: w, height: m.titleBarHeight))
        let introHeight = isPage && !full && !banner.isHidden ? m.bannerHeight : 0
        setFrame(banner, CGRect(x: 0, y: h - titleHeight - introHeight, width: w, height: introHeight))
        setFrame(bannerLabel, CGRect(x: m.bannerInset, y: m.bannerLabelY, width: max(0, w - 3 * m.bannerInset - m.bannerButtonWidth), height: m.hostHeight))
        setFrame(bannerButton, CGRect(x: w - m.bannerInset - m.bannerButtonWidth, y: m.bannerButtonY, width: m.bannerButtonWidth, height: m.bannerHeight - 2 * m.bannerButtonY))
        setFrame(container, CGRect(x: 0, y: 0, width: w, height: max(0, h - titleHeight - introHeight)))
        setFrame(commandBar.view, root.bounds)
        commandBar.view.overlayPanelWidth = isPage ? min(CommandBarMetrics.panelWidth, max(0, w - 2 * m.screenInset)) : nil
        placeTrafficLights()
    }
    private func placeTrafficLights() {
        // In full screen AppKit owns the buttons in its title bar at the top of the screen.
        guard !placingTrafficLights, window?.styleMask.contains(.fullScreen) != true else { return }
        placingTrafficLights = true; defer { placingTrafficLights = false }
        for (kind, frame) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton], LittleOpenMetrics.trafficLights) {
            guard let button = window?.standardWindowButton(kind) else { continue }
            if button.isHidden != (state != .page) { button.isHidden = state != .page }
            if state == .page, let parent = button.superview {
                let target = parent.convert(CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height), from: root)
                if button.frame != target { button.frame = target }
            }
        }
    }
    public func refreshExtensions() {
        titleBar.showsExtensions = !(extensionsUI?.actions.isEmpty ?? true)
    }
    public func makeExtensionsMenu() -> NSMenu {
        ExtensionsMenuBuilder.menu(actions: extensionsUI?.actions ?? [], kind: .littleOpen,
            run: { [weak self] id, source in
                guard let self else { return }; self.extensionsUI?.run?(id, source, self.extensionsButton)
            }, command: { [weak self] id in
                if id == "manage-extensions" { self?.extensionsUI?.manageExtensions?() }
                else { self?.extensionsUI?.addExtension?() }
            })
    }
    @objc private func showExtensionsMenu() {
        guard !extensionsButton.isHidden else { return }
        let menu = makeExtensionsMenu(); extensionsMenu = menu
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: extensionsButton.bounds.maxY), in: extensionsButton)
        extensionsMenu = nil
    }
    private func observeChrome() {
        guard !closed else { return }
        withObservationTracking { updateChrome() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeChrome() }
        }
    }
    private func updateChrome() {
        guard let model = coordinator?.model else { return }
        let space = model.mostRecentlyFocusedSpace(profileID: session.profileID)
        let system = ContentAppearance(NSApp.effectiveAppearance)
        let appearance = space.map { SpaceThemeStyle(theme: $0.theme, system: system).resolvedAppearance(system: system) } ?? system
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        if window?.appearance?.name != name { window?.appearance = appearance.nsAppearance }
        titleBar.update(url: currentURL ?? session.tab.url, profile: model.profile(id: session.profileID),
                        showsProfile: model.profiles.count >= 2, spaceTitle: space.map { model.displayTitle(for: $0) })
    }
    @objc public func performFindPanelAction(_ sender: Any?) {
        guard state == .page else { return }
        onFind?((sender as? NSMenuItem)?.tag ?? 1)
    }
    public override func responds(to selector: Selector!) -> Bool {
        // Only a shown page can be searched: the blank bar keeps the menu items disabled.
        if selector == #selector(performFindPanelAction(_:)) { return onFind != nil && state == .page }
        return super.responds(to: selector)
    }
    @objc public func dismissIntro() { banner.isHidden = true; layoutContent() }
    /// A fresh container on profile switch prevents host/cache reuse across Profile data contexts.
    func replaceProfile() {
        let url = currentURL ?? session.tab.url
        container.closeAll(); container.removeFromSuperview(); container = WebContentContainer(factory: factory)
        session.tab.url = url
        // closeAll marks the old host as a placeholder; this standalone page
        // must acquire a new host (and Browser) in the replacement Profile.
        session.tab.live.sleepPhase = .live
        root.addSubview(container, positioned: .below, relativeTo: titleBar)
        configureContainer(); updateChrome(); layoutContent()
        if state == .bar || commandBar.isPresented { presentCommandBar() }
    }
    public func focusURL() { presentCommandBar() }
    /// Keycaps show the user's bindings, as in the main window's bar and the menus. An open
    /// bar runs its text again, so a binding change shows without a new keystroke.
    public func refreshKeyBindings() {
        let bindings = coordinator?.keyBindings?() ?? .empty
        guard bindings != actionBindings else { return }
        commandBar.engine.setActions(CommandRegistry.rekeyed(.arcDefaults, overrides: bindings))
        actionBindings = bindings
        commandBar.refreshResults()
    }
    private func presentCommandBar() {
        refreshKeyBindings()
        commandBar.present(CommandBarRequest(mode: state == .bar ? .littleOpen : .editCurrentURL,
            profileID: session.profileID, spaceID: pillSpaceID, currentTabID: session.tab.id,
            currentTabURL: currentURL ?? session.tab.url, currentTabTitle: session.tab.title,
            allowsRemoteSuggestions: false, searchEngineID: coordinator?.model.profile(id: session.profileID)?.settings.searchEngineID),
            presentation: state == .bar ? .embedded(width: LittleOpenMetrics.barSize.width) : .overlay)
    }
    public func commandBar(_ commandBar: CommandBarController, perform intent: CommandBarIntent) {
        switch intent {
        case .open(let url, _, _), .search(_, let url, _, _, _):
            commandBar.dismiss(reason: .programmatic)
            // An internal open:// address (or no page) starts no load, so no load end would
            // bring the bar back: keep the bar, or the window is left with no input or close
            // control (bug sweep r6 REG-01).
            guard let host = container.host(for: session.tab.id), url.scheme?.lowercased() != "open" else {
                restoreEmbeddedBarIfNeeded(); return
            }
            if state == .bar { barLoadPending = true; barLoadStarted = false }
            host.load(url)
        case .switchToTab(let id, let spaceID):
            // The callback may close this session itself. close is idempotent and all state is Swift-owned.
            let coordinator = coordinator
            coordinator?.onSwitchToTab?(id, spaceID)
            coordinator?.close(sessionID: session.id, archiveReason: nil)
        case .runAction(let id, let spaceID):
            coordinator?.performCommand?(id, spaceID)
            restoreEmbeddedBarIfNeeded()
        case .copy(let text):
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            restoreEmbeddedBarIfNeeded()
        case .dismissed(.escape):
            if state == .bar { coordinator?.close(sessionID: session.id, archiveReason: nil) }
            else { commandBar.dismiss(reason: .programmatic); container.focus(tabID: session.tab.id) }
        case .dismissed(.clickOutside): if state == .page { container.focus(tabID: session.tab.id) }
        default: break
        }
    }
    private func restoreEmbeddedBarIfNeeded() {
        // Selection dismisses the bar before calling its delegate. A surviving blank
        // window must keep its input and close control; an action may have closed it.
        guard state == .bar, !closed else { return }
        presentCommandBar()
    }
    public func openInCurrentSpace() {
        guard state == .page, let spaceID = pillSpaceID else { return }
        coordinator?.moveToSpace(sessionID: session.id, spaceID: spaceID)
    }
    public func copyURL() {
        let url = URLCleaner.clean(currentURL ?? session.tab.url).url
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    public func showSpacePicker() {
        guard state == .page, let coordinator else { return }
        let picker = LittleOpenSpacePicker(model: coordinator.model, profileID: session.profileID, currentSpaceID: pillSpaceID)
        picker.onChoose = { [weak self] id in
            guard let self else { return }; self.spacePopover?.close()
            self.coordinator?.moveToSpace(sessionID: self.session.id, spaceID: id)
        }
        picker.onCancel = { [weak self] in self?.spacePopover?.close(); self?.spacePicker = nil }
        spacePicker = picker; picker.loadView()
        // Offscreen harnesses exercise the same content and callbacks without an on-screen popover.
        if coordinator.presentWindows {
            let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
            popover.appearance = NSAppearance(named: .darkAqua); popover.contentViewController = picker
            popover.contentSize = picker.preferredContentSize; spacePopover = popover
            popover.show(relativeTo: titleBar.chevronButton.bounds, of: titleBar.chevronButton, preferredEdge: .maxY)
        }
    }
    public func moveMenu() -> NSMenu {
        let menu = NSMenu(title: "Open in Space")
        for space in coordinator?.model.spaces.filter({ $0.profileID == session.profileID }) ?? [] {
            menu.addItem(FeatureMenuItem(coordinator?.model.displayTitle(for: space) ?? "Space") { [weak self] in
                guard let self else { return }; self.coordinator?.moveToSpace(sessionID: self.session.id, spaceID: space.id)
            })
        }
        return menu
    }
    private func profileMenu() -> NSMenu {
        let menu = NSMenu(title: "Profile")
        for profile in coordinator?.model.profiles ?? [] {
            menu.addItem(FeatureMenuItem(profile.name) { [weak self] in
                guard let self else { return }; self.coordinator?.switchProfile(sessionID: self.session.id, profileID: profile.id)
            })
        }
        return menu
    }
    private func presentationView() -> NSView {
        // Include the native frame and its background, not only our content.
        // Fading the content alone leaves an opaque empty window until close.
        let frame = root.superview ?? root
        frame.wantsLayer = true
        return frame
    }
    /// Paint the final geometry once before revealing the native window layer.
    /// Subsequent MRU resurfacing must not restart the initial fade.
    func presentWindow() {
        guard !closed, let window else { return }
        let first = !hasPresented; hasPresented = true
        let view = first && !Motion.reducesMotion ? presentationView() : nil
        let layer = view?.layer
        if let layer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            view?.alphaValue = 0
            layer.opacity = 0
            CATransaction.commit()
        }
        window.makeKeyAndOrderFront(nil)
        guard let layer else { return }
        window.displayIfNeeded(); CATransaction.flush()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Keep AppKit's model alpha in sync with its backing layer. A later
        // native display pass must not restore the unfaded window contents.
        view?.alphaValue = 1
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = Motion.littleOpenFade
        fade.timingFunction = Motion.easeOut
        layer.add(fade, forKey: "littleOpen.opacity")
        CATransaction.commit()
    }
    /// Retain the live page through the exit fade. The coordinator has already
    /// removed the session, so a second close cannot schedule another teardown.
    /// The teardown a running exit fade still owes; `finishClosing()` runs it at once (shutdown).
    private var pendingCloseFinish: (() -> Void)?
    /// Called once the page and window are closed.
    var onClosed: (() -> Void)?
    /// Runs a pending exit-fade teardown now (review r1 #1: shutdown during the fade). Idempotent.
    func finishClosing() { let finish = pendingCloseFinish; pendingCloseFinish = nil; finish?() }
    func closeWindow(immediate: Bool = false) {
        let finish = { [self] in
            // Page teardown can take several display intervals. Remove the
            // finished window first. Still cancel deferred host creation on
            // this turn: an immediate close must never create a Browser.
            window?.orderOut(nil)
            CATransaction.flush()
            commandBar.dismiss(reason: .programmatic)
            container.closeAll(); window?.delegate = nil; window?.close()
            let closed = onClosed; onClosed = nil; closed?()
        }
        pendingCloseFinish = finish
        guard !immediate, window?.isVisible == true, !Motion.reducesMotion else { finishClosing(); return }
        let view = presentationView()
        guard let layer = view.layer else { finishClosing(); return }
        window?.ignoresMouseEvents = true
        let start = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Restore the next window's key/main appearance with the first fade
        // transaction. Waiting for orderOut leaves a second visible change
        // after the Little window is transparent. Do not change window order.
        if let window, window.isKeyWindow,
           let next = NSApp.orderedWindows.first(where: {
               $0 !== window && $0.isVisible && !$0.isMiniaturized && !$0.ignoresMouseEvents && $0.isOnActiveSpace
                   && $0.canBecomeKey && $0.canBecomeMain
           }) {
            (next.attachedSheet ?? next).makeKey(); next.makeMain()
        }
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { self.finishClosing() } }
        layer.removeAnimation(forKey: "littleOpen.opacity")
        view.alphaValue = 0
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start; fade.toValue = 0; fade.duration = Motion.littleOpenFade
        fade.timingFunction = Motion.easeInOut
        layer.add(fade, forKey: "littleOpen.opacity")
        CATransaction.commit()
    }
    func prepareToClose() {
        container.host(for: session.tab.id)?.prepareToClose()
        onCloseDownloads?(); onCloseDownloads = nil; onDownloadsKey = nil
        // Tear down this controller's appearance observation once during close preparation.
        systemAppearanceObservation = nil
        closed = true; extensionsMenu?.cancelTrackingWithoutAnimation(); extensionsMenu = nil
        if let extensionObservation { extensionsUI?.removeObserver(extensionObservation) }; extensionObservation = nil
        // Keep the command-bar pixels alive until the root's exit fade ends.
        // Submission is already guarded by `closed`.
        spacePopover?.close(); spacePicker = nil
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { coordinator?.close(sessionID: session.id, archiveReason: nil); return false }
    func updateVisibility() { session.windowIsVisible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false }
    public func windowDidResize(_ notification: Notification) { layoutContent() }
    /// AppKit gave up a full-screen transition: no did-enter/did-exit notification follows, only this
    /// delegate call. The page factory hears it here, or its transition flag (and a page fullscreen
    /// waiting on it) stayed set (bug sweep r6). userInfo "entering": which transition failed.
    public static let fullScreenTransitionDidFail = Notification.Name("LittleOpenWindowController.fullScreenTransitionDidFail")
    public private(set) var isChangingFullScreen = false
    private var leaveFullScreenAfterTransition = false
    public func windowWillEnterFullScreen(_ notification: Notification) { isChangingFullScreen = true }
    public func windowWillExitFullScreen(_ notification: Notification) { isChangingFullScreen = true }
    public func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        if leaveFullScreenAfterTransition { leaveFullScreenAfterTransition = false; leaveFullScreen() }
    }
    public func windowDidExitFullScreen(_ notification: Notification) { isChangingFullScreen = false; leaveFullScreenAfterTransition = false }
    public func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransitionFailed(window, entering: true) }
    public func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransitionFailed(window, entering: false) }
    private func fullScreenTransitionFailed(_ window: NSWindow, entering: Bool) {
        isChangingFullScreen = false; leaveFullScreenAfterTransition = false
        NotificationCenter.default.post(name: Self.fullScreenTransitionDidFail, object: window, userInfo: ["entering": entering])
    }
    /// The page that took this window into full screen is gone (a Profile switch replaces it): leave
    /// full screen now, or when the running transition ends (AppKit ignores a toggle during one).
    public func leaveFullScreen() {
        guard let window, window.isVisible else { return }
        if isChangingFullScreen { leaveFullScreenAfterTransition = true; return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    public func windowDidBecomeKey(_ notification: Notification) { refreshKeyBindings(); updateVisibility(); coordinator?.recordActivity(session.id) }
    public func windowDidResignKey(_ notification: Notification) { updateVisibility(); coordinator?.onChange?() }
    public func windowDidMiniaturize(_ notification: Notification) { updateVisibility(); coordinator?.onChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) { updateVisibility(); coordinator?.onChange?() }
    public func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility(); coordinator?.onChange?() }
}
