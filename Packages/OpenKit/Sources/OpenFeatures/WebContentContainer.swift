import AppKit
import OpenModel
import OpenDesign

@MainActor
public final class PaneSlotView: NSView {
    public let tabID: ItemID
    public private(set) var paneChrome: PaneChromeView?
    public private(set) var placeholderView: PlaceholderContentView?
    public private(set) var contentHostView: NSView?
    /// Open's history swipe indicator over this pane's page (page-platform §4.4.3), made on the
    /// first swipe.
    public private(set) var swipeIndicator: SwipeIndicatorView?
    private var style: SpaceThemeStyle = .defaultTheme(system: .light)
    let clip = NSView()
    public let focusRing = CAShapeLayer()
    var isFocused = false
    init(tabID: ItemID) {
        self.tabID = tabID; super.init(frame: .zero); wantsLayer = true; clip.wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = PanelMetrics.shadowOpacity
        layer?.shadowRadius = PanelMetrics.shadowRadius; layer?.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius; clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true; addSubview(clip)
        focusRing.zPosition = 10; focusRing.fillColor = nil; focusRing.lineWidth = SplitMetrics.ringWidth; layer?.addSublayer(focusRing)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(tab: Tab, host: (any WebContentHost)?, split: Bool, toolbar: Bool = false, fullURL: Bool = false, focused: Bool, style: SpaceThemeStyle,
                   close: @escaping () -> Void, menu: @escaping (NSView) -> Void, url: @escaping () -> Void, copy: @escaping (Bool) -> Void,
                   toolbarMenu: (() -> NSMenu?)? = nil) {
        isFocused = split && focused
        self.style = style; swipeIndicator?.style = style
        focusRing.strokeColor = style.accentColor(.light).cgColor
        if split || toolbar {
            if paneChrome == nil { let chrome = PaneChromeView(); paneChrome = chrome; clip.addSubview(chrome) }
            paneChrome?.role = split ? .pane : .toolbar; paneChrome?.showsFullURL = fullURL; paneChrome?.toolbarMenu = split ? nil : toolbarMenu
            paneChrome?.host = host; paneChrome?.isFocused = focused; paneChrome?.onClose = close; paneChrome?.onMenu = menu
            paneChrome?.onURL = url; paneChrome?.onCopy = copy
            // The bar takes the page's color (host.pageBackgroundColor); the Space's light background is the fallback.
            paneChrome?.fallbackColor = style.lightPalette?.background.nsColor ?? .white
            paneChrome?.update()
        } else { paneChrome?.removeFromSuperview(); paneChrome = nil }
        // A sleeping tab whose page was discarded in place keeps its page object: showing it
        // reloads its entry (memory-fork §5.5), and the phase turns live at that commit.
        if let host, tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen || tab.live.sleepPhase == .sleeping {
            if contentHostView !== host.view { contentHostView?.removeFromSuperview() }
            placeholderView?.removeFromSuperview(); placeholderView = nil
            contentHostView = host.view; host.view.isHidden = false
            if host.view.superview !== clip { clip.addSubview(host.view, positioned: .below, relativeTo: paneChrome) }
        } else {
            contentHostView?.isHidden = true; contentHostView?.removeFromSuperview()
            placeholderView?.removeFromSuperview()
            contentHostView = nil; let placeholder = PlaceholderContentView(tab: tab, style: style)
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
        let bar = paneChrome == nil ? 0 : SplitMetrics.barHeight
        indicator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        indicator.update(event)
    }
    /// Updates slot geometry without forcing layout in the embedded web subtree.
    fileprivate func layoutContents() {
        clip.frame = bounds
        let bar = paneChrome == nil ? 0 : SplitMetrics.barHeight
        paneChrome?.frame = CGRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        let page = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        contentHostView?.frame = page; placeholderView?.frame = page
        swipeIndicator?.frame = page
        focusRing.frame = bounds
        focusRing.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: PanelMetrics.cornerRadius - 1,
                               cornerHeight: PanelMetrics.cornerRadius - 1, transform: nil)
        focusRing.isHidden = !isFocused
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: PanelMetrics.cornerRadius, cornerHeight: PanelMetrics.cornerRadius, transform: nil)
    }
}

@MainActor
public final class WebContentContainer: NSView {
    public static let maxCachedHiddenHosts = 8
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
    public var maximizedTabID: ItemID? { didSet { needsLayout = true } }
    /// The optional content toolbar on a single pane (§4.6.2). A split keeps its pane bars.
    public var showsToolbar = false { didSet { if showsToolbar != oldValue { updateSlots(); for slot in slots { slot.needsLayout = true } } } }
    /// Toolbar text: the full URL instead of the host (CC-37).
    public var showsFullURL = false { didSet { if showsFullURL != oldValue { updateSlots() } } }
    /// Right-click menu of the content toolbar.
    public var onToolbarMenu: (() -> NSMenu?)?
    public var onPaneClicked: ((ItemID) -> Void)?
    public var onLinkClicked: ((ItemID, URL, NSEvent.ModifierFlags) -> Bool)?
    public var onPaneClose: ((ItemID) -> Void)?
    public var onPaneMenu: ((ItemID, NSView) -> Void)?
    public var onURLField: (() -> Void)?
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
        for slot in slots where !tabIDs.contains(slot.tabID) { slot.removeFromSuperview() }
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.tabID, $0) })
        slots = tabIDs.map { id in byID[id] ?? PaneSlotView(tabID: id) }
        for slot in slots where slot.superview == nil { addSubview(slot, positioned: .below, relativeTo: dropOverlay) }
        ids = tabIDs; focused = focusedTabID; self.orientation = orientation
        self.fractions = fractions.count == ids.count ? fractions : Array(repeating: 1 / Double(ids.count), count: ids.count)
        hiddenLRU.removeAll { tabIDs.contains($0) }
        ensureHost(focusedTabID); updateSlots(); trimCache(); layoutPanes(animated: old != ids)
        if previousFocus != focusedTabID { cache[focusedTabID]?.focus() }
        if tabIDs.count > 1 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.showGeneration == generation else { return }
                for id in tabIDs where id != focusedTabID { self.ensureHost(id) }
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
        previewHosts[id] = cache.removeValue(forKey: id)
        hiddenLRU.removeAll { $0 == id }
    }
    private func applyLiveState(_ state: WebContentLiveState, for id: ItemID) {
        guard let live = tabProvider(id)?.live else { return }
        live.hasWebContent = true; live.isLoading = state.isLoading; live.progress = state.progress
        live.canGoBack = state.canGoBack; live.canGoForward = state.canGoForward
        live.isAudible = state.isAudible; live.isCrashed = state.isCrashed
    }
    private func metadataChanged(_ id: ItemID) {
        if let tab = tabProvider(id), let host = registeredHost(for: id) {
            tab.live.canGoBack = host.canGoBack; tab.live.canGoForward = host.canGoForward
            if focused == id { onFocusedMetadata?(tab.title) }
        }
        slots.first { $0.tabID == id }?.paneChrome?.update()
    }
    private func updateSlots() {
        for slot in slots {
            guard let tab = tabProvider(slot.tabID) else { continue }; let id = slot.tabID
            slot.configure(tab: tab, host: cache[id], split: ids.count > 1, toolbar: showsToolbar, fullURL: showsFullURL, focused: focused == id, style: style,
                           close: { [weak self] in self?.onPaneClose?(id) }, menu: { [weak self] v in self?.onPaneMenu?(id, v) },
                           url: { [weak self] in self?.onURLField?() }, copy: { [weak self] changed in self?.toasts?.show(ToastContent(title: changed ? URLCleaner.cleanedTitle : URLCleaner.plainTitle)) },
                           toolbarMenu: { [weak self] in self?.onToolbarMenu?() })
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
        for slot in slots { slot.removeFromSuperview() }
        slots.removeAll(); ids.removeAll(); focused = nil
        for divider in dividers { divider.removeFromSuperview() }; dividers.removeAll()
        trimCache()
    }
    public func host(for tabID: ItemID) -> (any WebContentHost)? { cache[tabID] }
    public func takeHost(for id: ItemID) -> (any WebContentHost)? {
        generations[id] = nil; hiddenLRU.removeAll { $0 == id }; return cache.removeValue(forKey: id)
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
    }
    private func trimCache() {
        guard hiddenLRU.count > Self.maxCachedHiddenHosts else { return }
        var unprotected = hiddenLRU.filter { retainsHiddenHost?($0) != true }
        while unprotected.count > Self.maxCachedHiddenHosts { closeHost(for: unprotected.removeFirst()) }
    }
    public func focus(tabID: ItemID) {
        guard ids.contains(tabID) else { return }; focused = tabID; updateSlots(); cache[tabID]?.focus(); metadataChanged(tabID)
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
                if animate { slot.animator().frame = target } else { slot.frame = target }
            }
        } completionHandler: { [weak self] in MainActor.assumeIsolated { self?.transitioning = false } }
        layoutDividers()
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
