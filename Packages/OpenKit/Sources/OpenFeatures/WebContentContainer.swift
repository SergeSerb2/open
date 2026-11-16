import AppKit
import OpenModel
import OpenDesign
import OpenExtensionsUI

@MainActor
public final class PaneSlotView: NSView {
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
    /// Split motion (C14-6): while this pane's box shrinks, its page keeps the size
    /// it had before the change, pinned to the top-left corner, and the moving box
    /// crops it. The page then resizes once, just before the motion ends.
    fileprivate var heldPageSize: CGSize?
    /// The page colour of a host that closed while this pane was on screen. A
    /// departing pane fills its box with it while the box collapses.
    fileprivate var closedPageColor: CGColor?
    private var motionFill = false
    public var isHoldingPage: Bool { heldPageSize != nil }
    public var clipAnimationKeys: [String] { clip.layer?.animationKeys() ?? [] }
    init(tabID: ItemID) {
        self.tabID = tabID; super.init(frame: .zero); wantsLayer = true; clip.wantsLayer = true
        // Split motion sets each slot frame once and moves its box on the render
        // server. Never redraw these layers during a resize.
        layerContentsRedrawPolicy = .beforeViewResize
        clip.layerContentsRedrawPolicy = .beforeViewResize
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = PanelMetrics.shadowOpacity
        layer?.shadowRadius = PanelMetrics.shadowRadius; layer?.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius; clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true; addSubview(clip)
        focusRing.zPosition = 10; focusRing.fillColor = nil; focusRing.lineWidth = SplitMetrics.ringWidth; layer?.addSublayer(focusRing)
        // layoutContents sets the path on every pass. An implicit path animation would
        // replace the split motion's ring animation and leave the ring at its final box.
        focusRing.actions = ["path": NSNull()]
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
            contentHostView = host.view; host.view.isHidden = false; closedPageColor = nil
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
    /// Updates slot geometry without forcing layout in the embedded web subtree.
    fileprivate func layoutContents() {
        if clip.frame != bounds { clip.frame = bounds }
        let bar = developerPanel != nil ? DeveloperPanelMetrics.height : paneChrome == nil ? 0 : SplitMetrics.barHeight
        var chromeFrame = CGRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        var page = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        if let held = heldPageSize {
            // Same top-left corner, old size. The moving box crops the rest.
            page = CGRect(x: 0, y: page.maxY - held.height, width: held.width, height: held.height)
            chromeFrame.size.width = max(chromeFrame.width, held.width)
        }
        if paneChrome?.frame != chromeFrame { paneChrome?.frame = chromeFrame }
        if developerPanel?.frame != chromeFrame { developerPanel?.frame = chromeFrame }
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
            // Split motion animates only the ring path. A reused layer must
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

    // MARK: Split motion (render server only)

    private static let motionKey = "open.split."
    /// The box this pane shows now, in its own coordinates (presentation value).
    fileprivate func presentedBox() -> CGRect {
        guard let model = clip.layer else { return bounds }
        let layer = model.presentation() ?? model
        let size = layer.bounds.size
        return CGRect(x: layer.position.x - layer.anchorPoint.x * size.width,
                      y: layer.position.y - layer.anchorPoint.y * size.height, width: size.width, height: size.height)
    }
    /// The clip layer geometry that shows `box` (own coordinates). The clip keeps
    /// its content pinned to the top-left corner, so the page is cropped, never scaled.
    private func clipGeometry(_ box: CGRect) -> (bounds: CGRect, position: CGPoint) {
        let anchor = clip.layer?.anchorPoint ?? .zero
        return (CGRect(x: 0, y: clip.frame.height - box.height, width: box.width, height: box.height),
                CGPoint(x: box.minX + anchor.x * box.width, y: box.minY + anchor.y * box.height))
    }
    /// Moves this pane's visible box from `start` to `end` (own coordinates) on the
    /// render server. No frame, layout or page geometry changes during the motion.
    fileprivate func moveBox(from start: CGRect, to end: CGRect, duration: CFTimeInterval, timing: CAMediaTimingFunction,
                             holdEnd: Bool, fill: CGColor?) {
        guard let clipLayer = clip.layer, let slotLayer = layer else { return }
        func add(_ target: CALayer, _ keyPath: String, _ from: Any, _ to: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from; animation.toValue = to
            animation.duration = duration; animation.timingFunction = timing
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            if holdEnd { animation.fillMode = .forwards; animation.isRemovedOnCompletion = false }
            target.add(animation, forKey: Self.motionKey + keyPath)
        }
        let from = clipGeometry(start), to = clipGeometry(end)
        add(clipLayer, "bounds", NSValue(rect: from.bounds), NSValue(rect: to.bounds))
        add(clipLayer, "position", NSValue(point: from.position), NSValue(point: to.position))
        let radius = fullBleed ? 0 : PanelMetrics.cornerRadius
        if slotLayer.shadowOpacity > 0 {
            add(slotLayer, "shadowPath", Self.motionPath(start, radius: radius), Self.motionPath(end, radius: radius))
        }
        if !focusRing.isHidden {
            // insetBy returns CGRect.null for a collapsed (zero-width) box; CA then drops the animation.
            func ringBox(_ box: CGRect) -> CGRect {
                CGRect(x: box.minX + min(1, box.width / 2), y: box.minY + min(1, box.height / 2),
                       width: max(0, box.width - 2), height: max(0, box.height - 2))
            }
            add(focusRing, "path", Self.motionPath(ringBox(start), radius: radius - 1), Self.motionPath(ringBox(end), radius: radius - 1))
        }
        if let fill = fill ?? closedPageColor { clipLayer.backgroundColor = fill; motionFill = true }
    }
    fileprivate func endMotion() {
        for keyPath in ["bounds", "position"] { clip.layer?.removeAnimation(forKey: Self.motionKey + keyPath) }
        layer?.removeAnimation(forKey: Self.motionKey + "shadowPath")
        focusRing.removeAnimation(forKey: Self.motionKey + "path")
        if motionFill { clip.layer?.backgroundColor = nil; motionFill = false }
    }
    /// A rounded rectangle with the same path elements for every size, so the
    /// render server can interpolate between a full box and a collapsed one.
    private static func motionPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2)), k = r * 0.4477
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control1: CGPoint(x: rect.maxX - k, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + k))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.maxY - k),
                      control2: CGPoint(x: rect.maxX - k, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control1: CGPoint(x: rect.minX + k, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.maxY - k))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.minY + k),
                      control2: CGPoint(x: rect.minX + k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

@MainActor
public final class WebContentContainer: NSView {
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
    /// Panes that left the layout stay drawn under the motion until it ends. Their
    /// bookkeeping (ids, slots, cache, parked slots, LRU) is already final.
    private var retiringSlots: [PaneSlotView] = []
    private var paneMotionGeneration = 0
    /// A shrinking pane releases its held page this long before the motion ends, so
    /// the engine's one rewrap lands inside the motion while the box is within a few
    /// points of its final size. GUESS (no engine frame-presented callback yet):
    /// three 120 Hz frames of engine layout + present latency.
    static let heldPageReleaseLead: CFTimeInterval = 0.025
    private var paneMotionAllowed: Bool { window?.isVisible == true && !Motion.reducesMotion }
    public var retiringPaneCount: Int { retiringSlots.count }

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
        let old = ids, previousFocus = focused, oldOrientation = orientation
        // Split add/remove/convert moves panes. A plain tab switch shares no pane and stays instant.
        let movesPanes = paneMotionAllowed && old != tabIDs && (old.count > 1 || tabIDs.count > 1) && old.contains(where: tabIDs.contains)
        // Read every on-screen box first, so an interrupted motion continues from where it is.
        let starts = movesPanes ? visiblePaneBoxes() : [:]
        // A refresh with the same panes (model observers, focus) keeps a running motion;
        // layoutPanes ends it only if a target frame changes.
        if old != tabIDs { finishPaneMotion() }
        for slot in slots where !tabIDs.contains(slot.tabID) {
            if cache[slot.tabID] != nil { parkedSlots[slot.tabID] = slot }
            if starts[slot.tabID] != nil { retiringSlots.append(slot) } else { slot.removeFromSuperview() }
        }
        for id in old where !tabIDs.contains(id) {
            // A departing pane keeps its page drawn until its box has collapsed.
            if !retiringSlots.contains(where: { $0.tabID == id }) { cache[id]?.view.isHidden = true; cache[id]?.view.removeFromSuperview() }
            hiddenLRU.removeAll { $0 == id }; hiddenLRU.append(id)
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
        ensureHost(focusedTabID); updateSlots(); trimCache()
        layoutPanes(animated: movesPanes, starts: starts, oldIDs: old, oldOrientation: oldOrientation)
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
        if retiringSlots.contains(where: { $0.tabID == id }) { finishPaneMotion() }
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
        finishPaneMotion()
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
    public func host(for tabID: ItemID) -> (any WebContentHost)? { cache[tabID] }
    public func takeHost(for id: ItemID) -> (any WebContentHost)? {
        generations[id] = nil; parkedSlots[id] = nil; hiddenLRU.removeAll { $0 == id }; return cache.removeValue(forKey: id)
    }
    public func adopt(_ host: any WebContentHost, for id: ItemID) {
        if retiringSlots.contains(where: { $0.tabID == id }) { finishPaneMotion() }
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
        // Close This Pane closes the page before the layout changes. Its box then
        // collapses with the page's colour instead of exposing the Space behind it.
        if let host, let slot = (slots + retiringSlots).first(where: { $0.tabID == id && $0.contentHostView === host.view }) {
            slot.closedPageColor = host.pageBackgroundColor?.cgColor
        }
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
        finishPaneMotion()
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
        layoutPanes(animated: animated && paneMotionAllowed, starts: animated ? visiblePaneBoxes() : [:], oldIDs: ids, oldOrientation: orientation)
    }
    /// ANIMATION-PASS rule 1 / C14-6. Every slot frame and page size is set once, in
    /// the same commit that starts the motion. Only clip layer bounds/position, the
    /// shadow path and the ring path move, on the render server; pages are cropped,
    /// never scaled or resized per frame. Growing and entering panes lay out their
    /// page at its final size at the start. A shrinking pane holds its old page
    /// size until just before the end (`heldPageReleaseLead`). Departing panes keep
    /// their page drawn while their box collapses toward the pane that takes their place.
    private func layoutPanes(animated: Bool, starts: [ItemID: CGRect], oldIDs: [ItemID], oldOrientation: SplitOrientation) {
        let frames = SplitLayout.frames(content: bounds, orientation: orientation, fractions: fractions, gap: SplitMetrics.gap, minPane: SplitMetrics.minimumPane)
        let targets = zip(slots, frames).map { slot, frame in (slot: slot, frame: maximizedTabID == slot.tabID ? bounds : frame) }
        for (slot, _) in targets { slot.isHidden = maximizedTabID != nil && maximizedTabID != slot.tabID }
        let changed = targets.contains { $0.slot.frame != $0.frame }
        guard animated, changed || !retiringSlots.isEmpty else {
            // A layout pass during a motion with unchanged targets keeps the motion.
            if changed { finishPaneMotion() }
            for (slot, target) in targets where slot.frame != target { slot.frame = target }
            layoutDividers(); return
        }
        paneMotionGeneration += 1; let generation = paneMotionGeneration
        let duration = Motion.splitExpand, timing = Motion.easeInOut
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Must precede the animations it waits for.
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.finishPaneMotion(generation) } }
        // Entering panes start collapsed at the trailing edge of the pane before them.
        var boxes: [(slot: PaneSlotView, start: CGRect, end: CGRect)] = []
        var previous: CGRect?
        for (slot, target) in targets where !slot.isHidden {
            let edge = previous.map { Self.endEdge($0, orientation) } ?? Self.startEdge(bounds, orientation)
            let start = starts[slot.tabID] ?? Self.collapsed(target, at: edge, orientation)
            boxes.append((slot, start, target)); previous = start
            let shrinks = start.width >= target.width - 0.5 && start.height >= target.height - 0.5
                && (start.width > target.width + 0.5 || start.height > target.height + 0.5)
            if shrinks, starts[slot.tabID] != nil, let page = slot.contentHostView?.frame.size, page.width > 0, page.height > 0 {
                slot.heldPageSize = page
            }
            if slot.frame != target { slot.frame = target }
            slot.needsLayout = true; slot.layoutSubtreeIfNeeded()
        }
        let fill = { (id: ItemID) in (self.cache[id] ?? self.previewHosts[id])?.pageBackgroundColor?.cgColor }
        for (slot, start, end) in boxes where start != end {
            let origin = end.origin
            slot.moveBox(from: start.offsetBy(dx: -origin.x, dy: -origin.y), to: slot.bounds, duration: duration, timing: timing,
                         holdEnd: false, fill: fill(slot.tabID))
        }
        // A departing pane collapses toward the end edge of the surviving pane before
        // it (old order), or toward the start edge when none precedes it.
        let endByID = Dictionary(boxes.map { ($0.slot.tabID, $0.end) }, uniquingKeysWith: { first, _ in first })
        // Collapse along the axis the panes are drawn in now. A refresh in the same turn
        // can already have changed `orientation` (Separate passes .horizontal) before
        // anything was drawn in it.
        let shown = oldIDs.compactMap { starts[$0] }
        let stacked = shown.count > 1 && shown.allSatisfy { abs($0.minX - shown[0].minX) < 1 && abs($0.width - shown[0].width) < 1 }
        let collapseAxis: SplitOrientation = shown.count > 1 ? (stacked ? .vertical : .horizontal) : oldOrientation
        for slot in retiringSlots {
            guard let start = starts[slot.tabID], let index = oldIDs.firstIndex(of: slot.tabID) else { continue }
            let edge = oldIDs[..<index].reversed().compactMap { endByID[$0] }.first.map { Self.endEdge($0, collapseAxis) }
                ?? Self.startEdge(bounds, collapseAxis)
            let origin = slot.frame.origin
            slot.moveBox(from: start.offsetBy(dx: -origin.x, dy: -origin.y),
                         to: Self.collapsed(start, at: edge, collapseAxis).offsetBy(dx: -origin.x, dy: -origin.y),
                         duration: duration, timing: timing, holdEnd: true, fill: fill(slot.tabID))
        }
        CATransaction.commit()
        transitioning = true
        if slots.contains(where: { $0.heldPageSize != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - Self.heldPageReleaseLead)) { [weak self] in
                MainActor.assumeIsolated { self?.releaseHeldPages(generation) }
            }
        }
        layoutDividers()
    }
    /// The one web resize of each shrinking pane.
    private func releaseHeldPages(_ generation: Int) {
        guard generation == paneMotionGeneration else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for slot in slots where slot.heldPageSize != nil { slot.heldPageSize = nil; slot.needsLayout = true; slot.layoutSubtreeIfNeeded() }
        CATransaction.commit()
    }
    /// Ends any pane motion at its final state: departing panes leave the window,
    /// held pages take their final size, and pointer input routes again.
    private func finishPaneMotion(_ generation: Int? = nil) {
        if let generation, generation != paneMotionGeneration { return }
        paneMotionGeneration += 1
        let moving = transitioning || !retiringSlots.isEmpty || slots.contains { $0.heldPageSize != nil }
        transitioning = false
        guard moving else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for slot in retiringSlots {
            slot.endMotion()
            if let view = slot.contentHostView, view.superview === slot.clip, !ids.contains(slot.tabID) {
                view.isHidden = true; view.removeFromSuperview()
            }
            if !slots.contains(where: { $0 === slot }) { slot.removeFromSuperview() }
        }
        retiringSlots.removeAll()
        for slot in slots {
            slot.endMotion()
            if slot.heldPageSize != nil { slot.heldPageSize = nil; slot.needsLayout = true; slot.layoutSubtreeIfNeeded() }
        }
        CATransaction.commit()
        layoutDividers()
    }
    /// On-screen pane boxes in container coordinates, including any motion in flight.
    private func visiblePaneBoxes() -> [ItemID: CGRect] {
        var boxes: [ItemID: CGRect] = [:]
        for slot in retiringSlots + slots where slot.superview === self && !slot.isHidden && !slot.frame.isEmpty {
            boxes[slot.tabID] = slot.presentedBox().offsetBy(dx: slot.frame.minX, dy: slot.frame.minY)
        }
        return boxes
    }
    // Panes run left to right, or top to bottom (unflipped: from maxY down).
    private static func startEdge(_ box: CGRect, _ orientation: SplitOrientation) -> CGFloat { orientation == .horizontal ? box.minX : box.maxY }
    private static func endEdge(_ box: CGRect, _ orientation: SplitOrientation) -> CGFloat { orientation == .horizontal ? box.maxX : box.minY }
    private static func collapsed(_ box: CGRect, at edge: CGFloat, _ orientation: SplitOrientation) -> CGRect {
        orientation == .horizontal ? CGRect(x: edge, y: box.minY, width: 0, height: box.height)
            : CGRect(x: box.minX, y: edge, width: box.width, height: 0)
    }
    public override func layout() { super.layout(); dropOverlay.frame = bounds; layoutPanes(animated: false) }
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
