import AppKit
import OpenModel
import OpenWeb
import OpenDesign
import OpenExtensionsUI

@MainActor
public final class PaneSlotView: NSView {
    var libraryMotionHidesContent = false
    var fullBleed = false {
        didSet { if fullBleed != oldValue { clip.layer?.cornerRadius = fullBleed ? 0 : PanelMetrics.cornerRadius; layer?.shadowOpacity = fullBleed ? 0 : PanelMetrics.shadowOpacity } }
    }
    public let tabID: ItemID
    public private(set) var paneChrome: PaneChromeView?
    /// Developer Mode's content panel and its network list (DeveloperContentPanel.swift).
    public private(set) var developerPanel: DeveloperContentPanelView?
    public private(set) var placeholderView: PlaceholderContentView?
    public private(set) var sadTabView: SadTabView?
    public private(set) var contentHostView: NSView?
    /// Open's history swipe indicator over this pane's page (page-platform §4.4.3), made on the
    /// first swipe.
    public private(set) var swipeIndicator: SwipeIndicatorView?
    private var style: SpaceThemeStyle = .defaultTheme(system: .light)
    private var lastHostWindowRect: CGRect?
    let clip = NSView()
    public let focusRing = CAShapeLayer()
    var isFocused = false
    init(tabID: ItemID) {
        self.tabID = tabID; super.init(frame: .zero); wantsLayer = true; clip.wantsLayer = true
        layer?.allowsGroupOpacity = false; clip.layer?.allowsGroupOpacity = false
        layer?.needsDisplayOnBoundsChange = false; clip.layer?.needsDisplayOnBoundsChange = false
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = PanelMetrics.shadowOpacity
        layer?.shadowRadius = PanelMetrics.shadowRadius; layer?.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius; clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true; addSubview(clip)
        focusRing.zPosition = 10; focusRing.fillColor = nil; focusRing.lineWidth = SplitMetrics.ringWidth; layer?.addSublayer(focusRing)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(tab: Tab, host: (any WebContentHost)?, split: Bool, toolbar: Bool = false, fullURL: Bool = false, focused: Bool, style: SpaceThemeStyle,
                   close: @escaping () -> Void, menu: @escaping (NSView) -> Void, url: @escaping () -> Void, copy: @escaping (Bool) -> Void,
                   toolbarMenu: (() -> NSMenu?)? = nil, reload: @escaping () -> Void, closeSadTab: @escaping () -> Void,
                   developer: Bool = false, developerActivePanel: DeveloperPanelAction? = nil,
                   developerAction: ((DeveloperPanelAction, NSView) -> Void)? = nil,
                   developerHover: ((DeveloperPanelAction, NSView) -> Void)? = nil) {
        isFocused = split && focused
        self.style = style; swipeIndicator?.style = style
        focusRing.strokeColor = style.accentColor(.light).cgColor
        let developer = developer && !split
        if developer {
            if developerPanel == nil { let panel = DeveloperContentPanelView(); developerPanel = panel; clip.addSubview(panel) }
            // The default theme uses Arc's measured bar colours; a themed Space tints the bar with its accent
            // colour (GUESS, capture s3; LEAD 12:18).
            developerPanel?.themeFills = style.isDefaultTheme || style.accent == nil ? nil
                : (style.accentColor(.light).nsColor, style.accentColor(.dark).nsColor)
            developerPanel?.urlString = tab.url.absoluteString
            developerPanel?.onAction = developerAction
            developerPanel?.onHover = developerHover
            developerPanel?.tooltipStyle = style
            developerPanel?.activePanel = developerActivePanel
        } else { developerPanel?.removeFromSuperview(); developerPanel = nil }
        if split || (toolbar && !developer) {
            if paneChrome == nil { let chrome = PaneChromeView(); paneChrome = chrome; clip.addSubview(chrome) }
            paneChrome?.role = split ? .pane : .toolbar; paneChrome?.showsFullURL = fullURL; paneChrome?.toolbarMenu = split ? nil : toolbarMenu
            // isFocused updates the bar, including when its value is unchanged.
            // Set every display input first so configuration needs one update.
            paneChrome?.fallbackColor = style.lightPalette?.background.nsColor ?? .white
            paneChrome?.host = host; paneChrome?.isFocused = focused; paneChrome?.onClose = close; paneChrome?.onMenu = menu
            paneChrome?.onURL = url; paneChrome?.onCopy = copy
        } else { paneChrome?.removeFromSuperview(); paneChrome = nil }
        // A sleeping tab whose page was discarded in place keeps its page object: showing it
        // reloads its entry (memory-fork §5.5), and the phase turns live at that commit.
        let wasSad = sadTabView != nil
        let hadPageFocus = (window?.firstResponder as? NSView).map { responder in
            [contentHostView, sadTabView].compactMap { $0 }.contains { responder === $0 || responder.isDescendant(of: $0) }
        } ?? false
        // The model is shared between windows; each window owns a different host.
        let isCrashed = host?.liveState.isCrashed ?? tab.live.isCrashed
        // Without a host, show the normal placeholder rather than a dead Reload.
        if isCrashed, host != nil {
            contentHostView?.isHidden = true; contentHostView?.removeFromSuperview()
            contentHostView = nil; lastHostWindowRect = nil
            placeholderView?.removeFromSuperview(); placeholderView = nil
            let sad = sadTabView ?? SadTabView(style: style)
            sadTabView = sad; if sad.style != style { sad.style = style }
            sad.onReload = reload; sad.onClose = closeSadTab
            if sad.superview !== clip { clip.addSubview(sad, positioned: .below, relativeTo: paneChrome) }
            if hadPageFocus && !wasSad { window?.makeFirstResponder(sad) }
        } else if let host, tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen || tab.live.sleepPhase == .sleeping {
            sadTabView?.removeFromSuperview(); sadTabView = nil
            if contentHostView !== host.view { contentHostView?.removeFromSuperview(); lastHostWindowRect = nil }
            placeholderView?.removeFromSuperview(); placeholderView = nil
            contentHostView = host.view; host.view.isHidden = libraryMotionHidesContent
            if host.view.superview !== clip { clip.addSubview(host.view, positioned: .below, relativeTo: paneChrome) }
            if hadPageFocus && wasSad { host.focus() }
        } else {
            sadTabView?.removeFromSuperview(); sadTabView = nil
            contentHostView?.isHidden = true; contentHostView?.removeFromSuperview()
            placeholderView?.removeFromSuperview()
            contentHostView = nil; lastHostWindowRect = nil; let placeholder = PlaceholderContentView(tab: tab, style: style)
            placeholderView = placeholder; clip.addSubview(placeholder, positioned: .below, relativeTo: paneChrome)
        }
        needsLayout = true
    }
    public override func layout() {
        super.layout(); layoutContents()
    }
    /// One engine history swipe event for this pane's page: above the page, below the pane bar.
    public func showHistorySwipe(_ event: SwipeIndicatorView.Event) {
        let indicator: SwipeIndicatorView
        if let swipeIndicator { indicator = swipeIndicator } else {
            indicator = SwipeIndicatorView(frame: .zero); indicator.style = style; swipeIndicator = indicator
        }
        if indicator.superview !== clip {
            if let paneChrome { clip.addSubview(indicator, positioned: .below, relativeTo: paneChrome) } else { clip.addSubview(indicator) }
        }
        let bar = developerPanel != nil ? DeveloperPanelMetrics.height : paneChrome == nil ? 0 : SplitMetrics.barHeight
        indicator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        indicator.update(event)
    }
    func libraryViewportSize(for size: CGSize) -> CGSize {
        let bar = developerPanel != nil ? DeveloperPanelMetrics.height : paneChrome == nil ? 0 : SplitMetrics.barHeight
        return CGSize(width: size.width, height: max(0, size.height - bar))
    }
    /// Updates slot geometry without forcing layout in the embedded web subtree.
    fileprivate func layoutContents() {
        if clip.frame != bounds { clip.frame = bounds }
        let bar = developerPanel != nil ? DeveloperPanelMetrics.height : paneChrome == nil ? 0 : SplitMetrics.barHeight
        let chromeFrame = CGRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        if paneChrome?.frame != chromeFrame { paneChrome?.frame = chromeFrame }
        if developerPanel?.frame != chromeFrame { developerPanel?.frame = chromeFrame }
        let page = CGRect(origin: .zero, size: libraryViewportSize(for: bounds.size))
        // Frame setters enter OpenEngine's geometry bridge even for equal values.
        // A cached slot can move while the page's local frame stays equal: keep
        // that window-coordinate change so Chrome's child window still follows.
        let hostWindowRect = clip.convert(page, to: nil)
        if contentHostView?.frame != page || lastHostWindowRect != hostWindowRect {
            contentHostView?.frame = page; lastHostWindowRect = hostWindowRect
        }
        if placeholderView?.frame != page { placeholderView?.frame = page }
        if sadTabView?.frame != page { sadTabView?.frame = page }
        if swipeIndicator?.frame != page { swipeIndicator?.frame = page }
        if focusRing.frame != bounds {
            // The ring follows the slot's 0.22 s view motion. A reused layer must
            // not add its own default 0.25 s bounds/position animation.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            focusRing.frame = bounds
            CATransaction.commit()
        }
        focusRing.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: PanelMetrics.cornerRadius - 1,
                               cornerHeight: PanelMetrics.cornerRadius - 1, transform: nil)
        focusRing.isHidden = !isFocused
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
    }
}

@MainActor
public final class WebContentContainer: NSView {
    var librarySnapshotReadInFlight = false
    public internal(set) var librarySnapshotStatus = "idle"
    private var libraryMotionHidesContent = false
    public func setLibraryMotionHidesContent(_ hidden: Bool) {
        libraryMotionHidesContent = hidden
        for slot in slots {
            slot.libraryMotionHidesContent = hidden
            slot.contentHostView?.isHidden = hidden
            // The closing snapshot already contains the pane's rounded edge.
            // Keep the ordinary live clip for opening and restore it on cancel.
            slot.clip.layer?.masksToBounds = !hidden
        }
    }
    public static let maxCachedHiddenHosts = 8
    public var fullBleed = false { didSet { if fullBleed != oldValue { for slot in slots { slot.fullBleed = fullBleed } } } }
    public var extensionsUI: ExtensionsUIContext? { didSet { for slot in slots { slot.paneChrome?.extensionsUI = extensionsUI } } }
    /// The render server resizes this background with the panel while page
    /// layout stays at its final width. Clip the wider hide frame temporarily.
    public func setSidebarSliding(_ sliding: Bool) {
        layer?.backgroundColor = sliding ? (focused.flatMap { cache[$0]?.pageBackgroundColor } ?? NSColor.white).cgColor : nil
        layer?.cornerRadius = sliding ? PanelMetrics.cornerRadius : 0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = sliding
    }
    let factory: any WebContentHostFactory
    public var tabProvider: ((ItemID) -> Tab?) = { _ in nil }
    public var style = SpaceThemeStyle.defaultTheme(system: .dark)
    public private(set) var slots: [PaneSlotView] = []
    // Reuse the chrome with its cached host. Rebuilding fourteen AppKit buttons
    // on every single→split switch exceeded the live-tab budget (s9 sample).
    // closeHost evicts the matching parked slot. The host LRU also limits parked
    // views to eight, including when protected hosts must remain alive.
    private var parkedSlots: [ItemID: PaneSlotView] = [:]
    public var retainedSlotCount: Int { slots.count + parkedSlots.count }
    private var cache: [ItemID: any WebContentHost] = [:]
    // Preview hosts leave the display cache, but retain the same metadata bridge.
    private var previewHosts: [ItemID: any WebContentHost] = [:]
    /// Synchronously returns the preview before selection, host acquisition, or teardown.
    public var onReturnPreviewHost: (() -> Void)?
    private var generations: [ItemID: Int] = [:]
    private var hiddenLRU: [ItemID] = []
    private var nextGeneration = 0
    private var showGeneration = 0
    private var currentProfile: ProfileID?
    private var currentSpace: SpaceID?
    private var ids: [ItemID] = []
    private var focused: ItemID?
    private var orientation: SplitOrientation = .horizontal
    private var fractions: [Double] = []
    public var maximizedTabID: ItemID? { didSet { if maximizedTabID != oldValue { needsLayout = true } } }
    /// The optional content toolbar on a single pane (§4.6.2). A split keeps its pane bars.
    public var showsToolbar = false { didSet { if showsToolbar != oldValue { updateSlots(); for slot in slots { slot.needsLayout = true } } } }
    /// Toolbar text: the full URL instead of the host (CC-37).
    public var showsFullURL = false { didSet { if showsFullURL != oldValue { updateSlots() } } }
    /// Right-click menu of the content toolbar.
    public var onToolbarMenu: (() -> NSMenu?)?
    /// Developer Mode sites (lowercased hosts, "file" for files), from the App's Developer Mode store.
    public var developerModeHosts: Set<String> = [] { didSet { if developerModeHosts != oldValue { updateSlots() } } }
    /// The DevTools toggle (Console, Network or Inspect) whose panel is open for a tab; the App answers.
    public var developerActivePanel: ((ItemID) -> DeveloperPanelAction?)?
    public var onDeveloperAction: ((ItemID, DeveloperPanelAction, NSView) -> Void)?
    /// The pointer entered a hover control of a tab's developer bar (Capture Window); the view is the anchor.
    public var onDeveloperHover: ((ItemID, DeveloperPanelAction, NSView) -> Void)?
    /// The App calls this when a tab's DevTools opened, closed or changed panel.
    public func developerPanelStateChanged() { updateSlots() }
    /// The Developer Mode site key of a URL: its lowercased http(s) host, or "file" (App `DeveloperMode.host(for:)`).
    nonisolated public static func developerHost(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return "file" }
        guard scheme == "http" || scheme == "https", let host = url.host()?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        return host
    }
    public var onPaneClicked: ((ItemID) -> Void)?
    public var onLinkClicked: ((ItemID, URL, NSEvent.ModifierFlags) -> Bool)?
    public var onPaneClose: ((ItemID) -> Void)?
    public var onSadTabClose: ((ItemID) -> Void)?
    public var onPaneMenu: ((ItemID, NSView) -> Void)?
    public var onURLField: (() -> Void)?
    public var onSiteControls: ((ItemID) -> Void)?
    /// F6: the window's one availability rule for Site Control buttons.
    public var siteControlsAvailable: ((ItemID) -> Bool)?
    /// The window's toasts (the pane bar's Copy button says what it copied).
    public weak var toasts: ToastCenter?
    public var onTabURLChanged: ((ItemID, URL) -> Void)?
    public var onFocusedMetadata: ((String) -> Void)?
    public var onFractionsCommitted: (([Double]) -> Void)?
    public var onDrop: ((ItemID, SplitDropOverlayView.Zone, Int?) -> Bool)?
    /// True for a hidden host the sleep policy must keep (keep-alive site, audio, capture,
    /// notifications, DevTools, downloads). The hidden-host cap counts only the others.
    public var retainsHiddenHost: ((ItemID) -> Bool)?
    private var dividers: [SplitDividerView] = []
    public let dropOverlay = SplitDropOverlayView()
    private var monitor: Any?
    private var transitioning = false

    public init(factory: any WebContentHostFactory) {
        self.factory = factory; super.init(frame: .zero); wantsLayer = true
        registerForDraggedTypes([NSPasteboard.PasteboardType("com.open.sidebar.node")])
        dropOverlay.isHidden = true; addSubview(dropOverlay)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.observeClick(event) }; return event
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) }; for host in Array(cache.values) + Array(previewHosts.values) { host.close() } }
    public func show(tabIDs: [ItemID], focusedTabID: ItemID, orientation: SplitOrientation, fractions: [Double], spaceID: SpaceID, profileID: ProfileID) {
        guard (1...4).contains(tabIDs.count), Set(tabIDs).count == tabIDs.count, tabIDs.contains(focusedTabID) else { return }
        // Selection may come from keyboard cycling, automation, or model observers.
        // Return the preview before changing slots or refreshing any selected host.
        if ids != tabIDs || focused != focusedTabID || currentSpace != spaceID || currentProfile != profileID { onReturnPreviewHost?() }
        if let currentProfile, currentProfile != profileID { closeAll() }
        self.currentProfile = profileID; currentSpace = spaceID; showGeneration += 1; let generation = showGeneration
        let old = ids, previousFocus = focused
        for id in old where !tabIDs.contains(id) { cache[id]?.view.isHidden = true; cache[id]?.view.removeFromSuperview(); hiddenLRU.removeAll { $0 == id }; hiddenLRU.append(id) }
        for slot in slots where !tabIDs.contains(slot.tabID) {
            slot.removeFromSuperview()
            if cache[slot.tabID] != nil { parkedSlots[slot.tabID] = slot }
        }
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.tabID, $0) })
        slots = tabIDs.map { id in
            let parked = parkedSlots.removeValue(forKey: id)
            return byID[id] ?? parked ?? PaneSlotView(tabID: id)
        }
        for slot in slots { slot.fullBleed = fullBleed }
        for slot in slots where slot.superview == nil { addSubview(slot, positioned: .below, relativeTo: dropOverlay) }
        ids = tabIDs; focused = focusedTabID; self.orientation = orientation
        self.fractions = fractions.count == ids.count ? fractions : Array(repeating: 1 / Double(ids.count), count: ids.count)
        hiddenLRU.removeAll { tabIDs.contains($0) }
        ensureHost(focusedTabID); updateSlots(); trimCache(); layoutPanes(animated: old != ids)
        if previousFocus != focusedTabID { focusContent(focusedTabID) }
        let pending = tabIDs.filter { $0 != focusedTabID && cache[$0] == nil }
        if !pending.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.showGeneration == generation else { return }
                for id in pending { self.ensureHost(id) }
                self.updateSlots()
            }
        }
    }
    private func ensureHost(_ id: ItemID) {
        if previewHosts[id] != nil { onReturnPreviewHost?() }
        // Every selection/refresh path comes here. Never reacquire and load a host
        // that is still in the preview, even if its owner cannot return it.
        guard previewHosts[id] == nil, cache[id] == nil, let tab = tabProvider(id), let profile = currentProfile,
              tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { return }
        guard let host = factory.makeHost(tabID: id, profileID: profile, url: nil) else { return }
        bind(host, as: id); host.load(tab.url)
    }
    private func bind(_ host: any WebContentHost, as id: ItemID) {
        nextGeneration += 1; let generation = nextGeneration
        cache[id] = host; generations[id] = generation; tabProvider(id)?.live.hasWebContent = true
        host.onURLChange = { [weak self, weak host] url in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            // No engine-to-model bridge exists before the App target; property writes are the bridge.
            self.tabProvider(id)?.url = url; self.onTabURLChanged?(id, url); self.metadataChanged(id)
        }
        host.onTitleChange = { [weak self, weak host] title in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            self.tabProvider(id)?.title = title; self.metadataChanged(id)
        }
        host.onLoadingChange = { [weak self, weak host] loading in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            self.tabProvider(id)?.live.isLoading = loading; self.metadataChanged(id)
        }
        host.onFaviconChange = { [weak self, weak host] data in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            self.tabProvider(id)?.live.faviconPNG = data
        }
        host.onPageBackgroundChange = { [weak self, weak host] _ in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            self.slots.first { $0.tabID == id }?.paneChrome?.update()
        }
        host.onLiveStateChange = { [weak self, weak host] state in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return }
            self.applyLiveState(state, for: id); self.metadataChanged(id)
        }
        host.shouldNavigate = { [weak self, weak host] url, flags in
            guard let self, let host, self.generations[id] == generation, self.registeredHost(for: id) === host else { return false }
            return self.onLinkClicked?(id, url, flags) ?? true
        }
        applyLiveState(host.liveState, for: id)
    }
    private func registeredHost(for id: ItemID) -> (any WebContentHost)? { cache[id] ?? previewHosts[id] }
    /// Install the normal callbacks before a new preview starts loading, or renew
    /// them after takeHost invalidated a cached host's generation.
    public func connectPreviewHost(_ host: any WebContentHost, for id: ItemID) {
        bind(host, as: id)
        parkedSlots[id] = nil
        previewHosts[id] = cache.removeValue(forKey: id)
        hiddenLRU.removeAll { $0 == id }
    }
    private func applyLiveState(_ state: WebContentLiveState, for id: ItemID) {
        guard let live = tabProvider(id)?.live else { return }
        live.hasWebContent = true; live.isLoading = state.isLoading; live.progress = state.progress
        live.canGoBack = state.canGoBack; live.canGoForward = state.canGoForward
        // Another window may already have written the same shared model flag.
        // Compare with this window's replacement to catch its own host transition.
        let crashChanged = slots.contains { $0.tabID == id && ($0.sadTabView != nil) != state.isCrashed }
        live.isAudible = state.isAudible; live.isCrashed = state.isCrashed
        if crashChanged { updateSlots() }
    }
    private func metadataChanged(_ id: ItemID) {
        if let tab = tabProvider(id), let host = registeredHost(for: id) {
            tab.live.canGoBack = host.canGoBack; tab.live.canGoForward = host.canGoForward
            if focused == id { onFocusedMetadata?(tab.title) }
        }
        slots.first { $0.tabID == id }?.paneChrome?.update()
        // Developer Mode is per site: a navigation can show, hide or retitle the developer bar.
        if !developerModeHosts.isEmpty, let slot = slots.first(where: { $0.tabID == id }), let tab = tabProvider(id) {
            let wanted = ids.count == 1 && (Self.developerHost(tab.url).map { developerModeHosts.contains($0) } ?? false)
            if wanted != (slot.developerPanel != nil) { updateSlots() } else { slot.developerPanel?.urlString = tab.url.absoluteString }
        }
    }
    private func updateSlots() {
        for slot in slots {
            guard let tab = tabProvider(slot.tabID) else { continue }; let id = slot.tabID
            slot.libraryMotionHidesContent = libraryMotionHidesContent
            slot.configure(tab: tab, host: cache[id], split: ids.count > 1, toolbar: showsToolbar, fullURL: showsFullURL, focused: focused == id, style: style,
                           close: { [weak self] in self?.onPaneClose?(id) }, menu: { [weak self] v in self?.onPaneMenu?(id, v) },
                           url: { [weak self] in self?.onURLField?() }, copy: { [weak self] changed in self?.toasts?.show(ToastContent(title: changed ? URLCleaner.cleanedTitle : URLCleaner.plainTitle)) },
                           toolbarMenu: { [weak self] in self?.onToolbarMenu?() },
                           reload: { [weak self] in self?.reloadContent(id) },
                           closeSadTab: { [weak self] in
                               guard let self else { return }
                               // Read current layout at click time, including a split
                               // that changed after this view was configured.
                               if self.ids.count > 1, self.ids.contains(id) { self.onPaneClose?(id) }
                               else { self.onSadTabClose?(id) }
                           },
                           developer: Self.developerHost(tab.url).map { developerModeHosts.contains($0) } ?? false,
                           developerActivePanel: developerActivePanel?(id),
                           developerAction: { [weak self] action, view in self?.onDeveloperAction?(id, action, view) },
                           developerHover: { [weak self] action, view in self?.onDeveloperHover?(id, action, view) })
            slot.paneChrome?.extensionsUI = extensionsUI
            slot.paneChrome?.onSiteControls = onSiteControls.map { handler in { handler(id) } }
            slot.paneChrome?.siteControlsAvailable = siteControlsAvailable?(id) ?? false
            slot.paneChrome?.update()
        }
    }
    public func refreshPlaceholders() { for id in ids { ensureHost(id) }; updateSlots() }
    public func clearSelection() {
        onReturnPreviewHost?()
        showGeneration += 1
        for id in ids {
            cache[id]?.view.isHidden = true; cache[id]?.view.removeFromSuperview()
            hiddenLRU.removeAll { $0 == id }; hiddenLRU.append(id)
        }
        for slot in slots {
            slot.removeFromSuperview()
            if cache[slot.tabID] != nil { parkedSlots[slot.tabID] = slot }
        }
        slots.removeAll(); ids.removeAll(); focused = nil
        for divider in dividers { divider.removeFromSuperview() }; dividers.removeAll()
        trimCache()
    }
    /// Use the same split geometry as layoutPanes, without moving any live view.
    /// Each engine arms retention before that view receives its sole new width.
    func libraryResizeTargets(for size: CGSize) -> [LibraryClosePresentation.Target]? {
        let content = CGRect(origin: bounds.origin, size: size)
        let frames = SplitLayout.frames(content: content, orientation: orientation,
            fractions: fractions, gap: SplitMetrics.gap, minPane: SplitMetrics.minimumPane)
        var targets: [LibraryClosePresentation.Target] = []
        for (slot, frame) in zip(slots, frames) where !slot.isHidden {
            guard let view = slot.contentHostView else { continue }
            guard let host = host(for: slot.tabID),
                  let source = (host as? WebContentProviding)?.webContent as? any WebContentRetainedSurfaceResizing,
                  let scale = view.window?.backingScaleFactor else { return nil }
            let bounds = maximizedTabID == slot.tabID ? content : frame
            let size = slot.libraryViewportSize(for: bounds.size)
            guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
                  scale > 0, scale.isFinite else { return nil }
            let url = host.currentURL
            targets.append(.init(source: source, view: view, size: size, scale: scale,
                isCurrent: { [weak self, weak slot, weak host, weak view] in
                    guard let self, let slot, let host, let view else { return false }
                    return self.host(for: slot.tabID) === host && slot.contentHostView === view
                        && slot.superview === self && !slot.isHidden && host.currentURL == url
                        && view.window?.backingScaleFactor == scale
                }))
        }
        return targets
    }
    public func host(for tabID: ItemID) -> (any WebContentHost)? { cache[tabID] }
    public func takeHost(for id: ItemID) -> (any WebContentHost)? {
        generations[id] = nil; parkedSlots[id] = nil; hiddenLRU.removeAll { $0 == id }; return cache.removeValue(forKey: id)
    }
    public func adopt(_ host: any WebContentHost, for id: ItemID) {
        previewHosts[id] = nil
        guard factory.adoptHost(host, as: id) else { host.close(); return }
        if cache[id] !== host { cache[id]?.close(); bind(host, as: id) }
        if !ids.contains(id) {
            host.view.isHidden = true
            hiddenLRU.removeAll { $0 == id }; hiddenLRU.append(id)
        }
        refreshPlaceholders(); trimCache()
    }
    public func closeHost(for id: ItemID) {
        if previewHosts[id] != nil { onReturnPreviewHost?() }
        parkedSlots[id] = nil
        generations[id] = nil
        let host = cache.removeValue(forKey: id) ?? previewHosts.removeValue(forKey: id)
        hiddenLRU.removeAll { $0 == id }
        host?.close()
        if host != nil {
            if let remaining = factory.remainingLiveState(for: id) {
                applyLiveState(remaining, for: id); tabProvider(id)?.live.sleepPhase = .live
            } else { resetLiveState(for: id) }
        }
    }
    /// Profile teardown also invalidates metadata that belongs to the old profile.
    public func resetLiveState(for id: ItemID, includingFavicon: Bool = false) {
        guard let live = tabProvider(id)?.live else { return }
        live.hasWebContent = false; live.sleepPhase = .placeholder
        live.isLoading = false; live.progress = 0; live.isAudible = false; live.isCrashed = false
        live.canGoBack = false; live.canGoForward = false; live.isCapturing = false
        live.devToolsOpen = false; live.lastFormInteractionAt = nil
        if includingFavicon { live.faviconPNG = nil }
    }
    public func closeAll() {
        if !previewHosts.isEmpty { onReturnPreviewHost?() }
        for id in Set(cache.keys).union(previewHosts.keys) { closeHost(for: id) }
        parkedSlots.removeAll()
    }
    private func trimCache() {
        guard hiddenLRU.count > Self.maxCachedHiddenHosts else { return }
        var unprotected = hiddenLRU.filter { retainsHiddenHost?($0) != true }
        while unprotected.count > Self.maxCachedHiddenHosts { closeHost(for: unprotected.removeFirst()) }
        let recent = Set(hiddenLRU.suffix(Self.maxCachedHiddenHosts))
        parkedSlots = parkedSlots.filter { recent.contains($0.key) }
    }
    public func focus(tabID: ItemID) {
        guard ids.contains(tabID) else { return }; focused = tabID; updateSlots(); focusContent(tabID); metadataChanged(tabID)
    }
    private func focusContent(_ id: ItemID) {
        if let sad = slots.first(where: { $0.tabID == id })?.sadTabView { window?.makeFirstResponder(sad) }
        else { cache[id]?.focus() }
    }
    private func reloadContent(_ id: ItemID) {
        if let host = registeredHost(for: id) { host.reload() }
        else { ensureHost(id); updateSlots() }
    }
    func observeClick(_ event: NSEvent) {
        guard event.window === window, !transitioning else { return }
        guard let root = window?.contentView else { return }
        let rootPoint = root.convert(event.locationInWindow, from: nil)
        guard let hit = root.hitTest(rootPoint), hit === self || hit.isDescendant(of: self) else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let slot = slots.first(where: { !$0.isHidden && $0.frame.contains(p) }) { onPaneClicked?(slot.tabID) }
    }
    public override func mouseDown(with event: NSEvent) { observeClick(event) }
    public func setLivePaneFrames(_ frames: [CGRect]) {
        guard frames.count == slots.count else { return }
        for (slot, frame) in zip(slots, frames) where slot.frame != frame {
            slot.frame = frame; slot.layoutContents(); slot.paneChrome?.layoutSubtreeIfNeeded()
        }
        layoutDividers()
    }
    /// Routes an engine history swipe to the pane that shows `tabID` (the host under the pointer).
    @discardableResult
    public func showHistorySwipe(tabID: ItemID, _ event: SwipeIndicatorView.Event) -> Bool {
        guard let slot = slots.first(where: { $0.tabID == tabID }) else { return false }
        slot.showHistorySwipe(event); return true
    }

    public func layoutPanes(animated: Bool) {
        let frames = SplitLayout.frames(content: bounds, orientation: orientation, fractions: fractions, gap: SplitMetrics.gap, minPane: SplitMetrics.minimumPane)
        let animate = animated && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transitioning = animate
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? Motion.splitExpand : 0; context.timingFunction = Motion.easeInOut
            for (slot, frame) in zip(slots, frames) {
                slot.isHidden = maximizedTabID != nil && maximizedTabID != slot.tabID
                let target = maximizedTabID == slot.tabID ? bounds : frame
                if slot.frame != target {
                    if animate { slot.animator().frame = target } else { slot.frame = target }
                }
            }
        } completionHandler: { [weak self] in MainActor.assumeIsolated { self?.transitioning = false } }
        layoutDividers()
    }
    public override func layout() {
        let region = WindowSpeedTrace.begin("webContainer.layout")
        defer { region?() }
        super.layout(); dropOverlay.frame = bounds; layoutPanes(animated: false)
    }
    private func layoutDividers() {
        while dividers.count > max(0, slots.count - 1) { dividers.removeLast().removeFromSuperview() }
        while dividers.count < max(0, slots.count - 1) {
            let d = SplitDividerView(); dividers.append(d); addSubview(d, positioned: .below, relativeTo: dropOverlay)
        }
        for (i, d) in dividers.enumerated() {
            d.isHidden = maximizedTabID != nil; d.isEnabled = !transitioning; d.orientation = orientation
            let a = slots[i].frame, b = slots[i + 1].frame
            d.frame = orientation == .horizontal ? CGRect(x: a.maxX, y: bounds.minY, width: max(0, b.minX - a.maxX), height: bounds.height)
                : CGRect(x: bounds.minX, y: b.maxY, width: bounds.width, height: max(0, a.minY - b.maxY))
            d.onBegin = { [weak self] in self?.slots.map(\.frame) ?? [] }
            d.onDrag = { [weak self] frames in self?.setLivePaneFrames(frames) }
            d.onCommit = { [weak self] frames in
                guard let self else { return }; self.fractions = SplitLayout.fractions(forSizes: frames.map { self.orientation == .horizontal ? $0.width : $0.height })
                self.onFractionsCommitted?(self.fractions)
            }
            d.pairIndex = i
        }
    }
    public func divider(at index: Int) -> SplitDividerView? { dividers.indices.contains(index) ? dividers[index] : nil }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOverlay.isHidden = false; return draggingUpdated(sender) }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOverlay.zone = dropOverlay.zone(at: convert(sender.draggingLocation, from: nil)); return .move
    }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropOverlay.isHidden = true }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropOverlay.isHidden = true }
        guard let raw = sender.draggingPasteboard.string(forType: .init("com.open.sidebar.node")), let uuid = UUID(uuidString: raw) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = slots.count > 1 && dropOverlay.zone(at: point) == .center ? slots.firstIndex { $0.frame.contains(point) } : nil
        return handleDrop(ItemID(rawValue: uuid), point: point, paneIndex: index)
    }
    @discardableResult public func handleDrop(_ id: ItemID, point: CGPoint, paneIndex: Int? = nil) -> Bool {
        onDrop?(id, dropOverlay.zone(at: point), paneIndex) ?? false
    }
    public override func cancelOperation(_ sender: Any?) { dropOverlay.isHidden = true; maximizedTabID = nil }
}
