import AppKit
import Observation
import OpenModel
import OpenSuggest
import OpenDesign
import OpenRouting
import Darwin

/// Registrable-domain lookup uses OpenSuggest's bundled ICANN PSL (lead decision Q1).
/// Unknown suffixes use the last two labels; IP literals and localhost stay exact.
public enum FeatureSite {
    public static func domain(_ url: URL?) -> String? {
        guard let raw = url?.host(), !raw.isEmpty else { return nil }
        let host = HostNormalizer.canonicalHostName(raw)
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let isIP = host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
        // Scoped IPv6 literals include a zone suffix that inet_pton does not accept.
        if isIP || host.contains(":") || host == "localhost" { return host }
        let suffixCount = PublicSuffixList.shared.suffixLabelCount(host: host) ?? 1
        return host.split(separator: ".").suffix(suffixCount + 1).joined(separator: ".")
    }
    public static func fragmentOnly(_ source: URL?, _ target: URL) -> Bool {
        guard let source, target.fragment != nil, var a = URLComponents(url: source, resolvingAgainstBaseURL: false), var b = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return false }
        a.fragment = nil; b.fragment = nil; return a == b
    }
    public static func shouldPeek(source: URL?, target: URL, pinned: Bool, flags: NSEvent.ModifierFlags, defaults: UserDefaults) -> Bool {
        guard ["http", "https"].contains(target.scheme?.lowercased() ?? ""), !flags.contains(.command),
              !flags.contains(.option), !fragmentOnly(source, target) else { return false }
        return PeekPolicy.decision(for: .init(sourceIsPinnedOrFavorite: pinned, sourceHost: domain(source), targetHost: domain(target),
                                              shiftHeld: flags.contains(.shift), peekOtherSitesEnabled: defaults.object(forKey: "open.links.openPeekOtherSites") as? Bool ?? true,
                                              peekShiftEnabled: defaults.object(forKey: "open.links.openPeekShiftClick") as? Bool ?? true)) == .peek
    }
}

@MainActor
@Observable
public final class PeekController {
    public struct PeekItem {
        public let id: UUID
        public var url: URL
        public let sourceTabID: ItemID
        public let hostTabID: ItemID
        /// Library previews belong to the current Space, without requiring a live source tab.
        public let librarySpaceID: SpaceID?
        public let profileID: ProfileID
        public var host: (any WebContentHost)?
        /// The Peek page's favicon, for the source row's badge.
        public var faviconPNG: Data?
    }
    public private(set) var stack: [PeekItem] = []
    public var isOpen: Bool { !stack.isEmpty }
    public var isShown: Bool { !overlay.isHidden && isOpen }
    public let overlay = PeekOverlayView()
    @ObservationIgnored private let model: BrowserModel
    @ObservationIgnored private let splitController: SplitViewController
    @ObservationIgnored private let factory: any WebContentHostFactory
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var undoItem: (url: URL, source: ItemID, librarySpace: SpaceID?, profile: ProfileID, expiry: Date)?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var expandingGeneration = 0
    public private(set) var isExpanding = false
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var dismissGeneration = 0
    @ObservationIgnored private var motionGeneration = 0
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    public private(set) var isPromotionHandoff = false
    public var onChange: (() -> Void)?
    /// The window's toasts: "Peek closed" with Undo (M4).
    @ObservationIgnored public weak var toasts: ToastCenter?
    @ObservationIgnored private var undoToast: ToastHandle?
    /// How long a closed Peek can come back (M4); the toast lasts as long.
    public static let undoWindow: TimeInterval = 5
    /// The top Peek's URL, history, loading state, or favicon changed (sidebar badge, URL field, toolbar).
    public var onPageChange: (() -> Void)?
    /// App-owned page overlays can consume Esc before the Peek itself closes.
    public var onPageEscape: (() -> Bool)?
    public var peekBadgeTabIDs: Set<ItemID> { Set(stack.filter { $0.librarySpaceID == nil }.map(\.sourceTabID)) }
    public init(model: BrowserModel, splitController: SplitViewController, factory: any WebContentHostFactory, defaults: UserDefaults) {
        self.model = model; self.splitController = splitController; self.factory = factory; self.defaults = defaults
        defaults.register(defaults: ["open.links.openPeekOtherSites": true, "open.links.openPeekShiftClick": true])
        overlay.isHidden = true; overlay.onDismiss = { [weak self] in self?.dismissTop() }
        overlay.onExpand = { [weak self] in self?.expandTop() }; overlay.onSplit = { [weak self] in self?.openInSplitTop() }
    }
    isolated deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; undoTask?.cancel(); snapshotTask?.cancel(); for item in stack { item.host?.close() } }
    public func intercept(tabID: ItemID, url: URL, flags: NSEvent.ModifierFlags) -> Bool {
        guard let tab = model.tab(id: tabID) else { return true }
        let favorite: Bool = if case .favorites? = model.parent(of: tabID) { true } else { false }
        if FeatureSite.shouldPeek(source: tab.url, target: url, pinned: model.isPinned(tabID: tabID) || favorite, flags: flags, defaults: defaults) {
            open(url: url, sourceTabID: tabID); return false
        }
        return true
    }
    public func open(url: URL, sourceTabID: ItemID) {
        open(url:url,sourceTabID:sourceTabID,librarySpaceID:nil,profileID:nil)
    }
    public func openLibraryPreview(url: URL, profileID: ProfileID) {
        guard let space = splitController.space else { return }
        open(url:url,sourceTabID:splitController.focusedTab?.id ?? ItemID(),librarySpaceID:space.id,profileID:profileID)
    }
    private func open(url: URL, sourceTabID: ItemID, librarySpaceID: SpaceID?, profileID: ProfileID?) {
        PeekMotionTrace.mark("request.open")
        guard let space = splitController.space else { return }
        let profile = profileID ?? space.profileID
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPromotionHandoff = false; overlay.clearExpansionCard(); overlay.restoreExpansionViewport()
        overlay.endHostSnapshot()
        dismissGeneration += 1; isDismissing = false
        expandingGeneration += 1; isExpanding = false
        if stack.count >= 5 { overlay.resetMotion(); stack.last?.host?.load(url); refresh(); return }
        let hostID = ItemID()
        guard let host = factory.makeHost(tabID: hostID, profileID: profile, url: nil) else { overlay.resetMotion(); return }
        let item = PeekItem(id: UUID(), url: url, sourceTabID: sourceTabID, hostTabID: hostID, librarySpaceID: librarySpaceID, profileID: profile, host: host)
        stack.append(item)
        let itemID = item.id
        host.onURLChange = { [weak self, weak host] value in
            guard let self, let host, let i = self.stack.firstIndex(where: { $0.id == itemID }), self.stack[i].host === host else { return }
            self.stack[i].url = value; self.onPageChange?()
        }
        host.onFaviconChange = { [weak self, weak host] data in
            guard let self, let host, let i = self.stack.firstIndex(where: { $0.id == itemID }), self.stack[i].host === host else { return }
            self.stack[i].faviconPNG = data; self.onPageChange?()
        }
        host.onLoadingChange = { [weak self, weak host] loading in
            guard let self, let host, self.stack.last?.id == itemID, self.stack.last?.host === host else { return }
            PeekMotionTrace.mark("host.loading", value: loading ? 1 : 0)
            PeekMotionTrace.region("host.onPageChange") { self.onPageChange?() }
            if !loading {
                if self.overlay.openingHandoff { self.finishOpeningHandoff(itemID: itemID, host: host) }
                else { self.overlay.revealHost(host.view, duration: self.duration(0.12)) }
            }
        }
        host.onLiveStateChange = { [weak self, weak host] state in
            guard let self, let host, self.stack.last?.id == itemID, self.stack.last?.host === host else { return }
            if state.isCrashed != (self.overlay.sadTabView != nil) { self.refresh(); self.onPageChange?() }
        }
        host.shouldNavigate = { [weak self, weak host] target, flags in
            guard let self, let host, self.stack.last?.id == itemID, self.stack.last?.host === host else { return false }
            if FeatureSite.shouldPeek(source: host.currentURL, target: target, pinned: true, flags: flags, defaults: self.defaults) && self.stack.count < 5 {
                guard let source = self.stack.last else { return false }
                self.open(url:target,sourceTabID:source.sourceTabID,librarySpaceID:source.librarySpaceID,profileID:source.librarySpaceID == nil ? nil : source.profileID); return false
            }
            return true
        }
        let interval = duration(Motion.peekOpen), generation = motionGeneration
        if interval > 0 {
            // A new engine page is created when its view first enters a
            // window. Keep that startup and navigation out of the motion.
            overlay.clearHost()
            overlay.layoutSubtreeIfNeeded()
            overlay.freezeHost(host.view, image: nil)
        }
        host.load(url); refresh(); host.focus(); installKeys()
        let focusAfterFreeze = overlay.window?.firstResponder
        overlay.animatePresentation(true, duration: interval) { [weak self, weak host] in
            guard let self, let host, self.motionGeneration == generation, self.stack.last?.id == itemID else { return }
            self.overlay.attachOpeningHost(host.view)
            self.refresh()
            if self.isShown, self.overlay.window?.isKeyWindow == true,
               self.overlay.window?.firstResponder === focusAfterFreeze { host.focus() }
        }
        PeekMotionTrace.region("open.onChange") { onChange?() }
    }
    private func finishOpeningHandoff(itemID: UUID, host: any WebContentHost) {
        guard snapshotTask == nil else { return }
        let generation = motionGeneration
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == generation,
                  self.stack.last?.id == itemID, self.overlay.openingHandoff else { return }
            self.snapshotTask = nil
            guard !host.isLoading else { return }
            self.overlay.finishOpeningHandoff(image: image) { [weak self] in self?.refresh() }
        }
    }
    private func duration(_ value: Double) -> Double { overlay.window?.isVisible == true && !Motion.reducesMotion ? value : 0 }
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.overlay.window, self.isShown else { return false }
                if event.modifierFlags.contains(.command) {
                    if event.charactersIgnoringModifiers == "[" { self.stack.last?.host?.goBack(); return true }
                    if event.charactersIgnoringModifiers == "]" { self.stack.last?.host?.goForward(); return true }
                }
                return false
            }
            return consumed ? nil : event
        }
    }
    public func refresh() {
        PeekMotionTrace.mark("refresh.begin")
        defer { PeekMotionTrace.mark("refresh.end") }
        if isPromotionHandoff { return }
        guard let item = stack.last else { overlay.isHidden = true; overlay.clearHost(); return }
        let sourceIsVisible: Bool
        if let space = item.librarySpaceID {
            sourceIsVisible = splitController.space?.id == space
        } else if case .favorites(let profileID)? = model.parent(of: item.sourceTabID) {
            sourceIsVisible = splitController.space?.profileID == profileID
        } else { sourceIsVisible = splitController.selected?.id == sourceNodeID(of: item) }
        // Factories create transient pages hidden. Only the shown top page is
        // visible; a refresh must not hide/show a page that stays on screen.
        for candidate in stack {
            let frozen = candidate.host.map { overlay.isHostFrozen($0.view) } ?? false
            let hidden = !sourceIsVisible || candidate.id != item.id || candidate.host?.liveState.isCrashed == true || frozen
            if candidate.host?.view.isHidden != hidden { candidate.host?.view.isHidden = hidden }
        }
        guard sourceIsVisible else { overlay.isHidden = true; return }
        overlay.isHidden = false
        if let host = item.host {
            overlay.showHost(host) { [weak self] in
                guard self?.stack.last?.id == item.id else { return }; self?.dismissTop()
            }
        }
        overlay.needsLayout = true
    }
    /// The sidebar row a Peek belongs to, read now: the split that holds the source tab,
    /// else the tab. A split made from the source tab, or dissolved, moves it.
    public func sourceNodeID(of item: PeekItem) -> ItemID {
        if case .splitPane(let splitID)? = model.parent(of: item.sourceTabID) { return splitID }
        return item.sourceTabID
    }
    public func escape() {
        if onPageEscape?() == true { return }
        if isExpanding {
            motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
            expandingGeneration += 1; isExpanding = false
            let item = stack.last
            overlay.cancelExpansion(duration: duration(Motion.peekOpen)) { [weak self] in
                guard let self, let item, let host = item.host, self.stack.last?.id == item.id else { return }
                self.overlay.attachOpeningHost(host.view)
                self.finishOpeningHandoff(itemID: item.id, host: host)
            }
            refresh()
        }
        else { dismissTop() }
    }
    public func dismissTop() {
        PeekMotionTrace.mark("request.close")
        guard !isExpanding, !isDismissing, let item = stack.last else { return }
        let interval = duration(Motion.peekDismiss)
        if interval == 0 { finishDismiss(); overlay.resetMotion(); return }
        isDismissing = true; dismissGeneration += 1; let generation = dismissGeneration, id = item.id
        prepareMotionSnapshot(for: item) { [weak self] in
            guard let self, self.dismissGeneration == generation, self.stack.last?.id == id else { return }
            self.overlay.animatePresentation(false, duration: interval) { [weak self] in
                guard let self, self.dismissGeneration == generation, self.stack.last?.id == id else { return }
                self.isDismissing = false; self.finishDismiss(); self.overlay.resetMotion()
            }
        }
    }
    private func prepareMotionSnapshot(for item: PeekItem, action: @escaping @MainActor () -> Void) {
        motionGeneration += 1; let generation = motionGeneration
        snapshotTask?.cancel(); snapshotTask = nil
        guard let host = item.host, !overlay.isHostFrozen(host.view) else { action(); return }
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == generation, self.stack.last?.id == item.id else { return }
            self.snapshotTask = nil
            if let image {
                self.overlay.stageHostSnapshot(host.view, image: image) { [weak self] in
                    guard let self, self.motionGeneration == generation, self.stack.last?.id == item.id else { return }
                    action()
                }
            } else { action() }
        }
    }
    private func finishDismiss() {
        guard let item = stack.popLast() else { return }
        item.host?.close(); undoItem = (item.url, item.sourceTabID, item.librarySpaceID, item.profileID, Date().addingTimeInterval(Self.undoWindow))
        undoToast?.dismiss()
        undoToast = toasts?.show(.undo("Peek closed", lifetime: Self.undoWindow)) { [weak self] _ in self?.undoDismiss() }
        undoTask?.cancel(); undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow)); guard !Task.isCancelled, let self else { return }
            // The pointer over the toast pauses it (ToastCenter): its Undo stays live while it shows.
            if self.undoToast?.isVisible != true { self.undoItem = nil }
        }
        refresh(); if stack.isEmpty { removeKeys(); splitController.container.host(for: item.sourceTabID)?.focus() }
        onChange?()
    }
    public func undoDismiss() {
        // Live while its toast shows (a hovered toast outlasts the 5 s window), else for 5 s.
        guard let item = undoItem, item.expiry > Date() || undoToast?.isVisible == true else { return }; undoItem = nil; undoTask?.cancel()
        undoToast?.dismiss(); undoToast = nil
        open(url:item.url,sourceTabID:item.source,librarySpaceID:item.librarySpace,profileID:item.librarySpace == nil ? nil : item.profile)
    }
    /// Closing Library also expires Undo for its last dismissed preview.
    public func closeLibraryPreviews() {
        guard stack.contains(where: { $0.librarySpaceID != nil }) || undoItem?.librarySpace != nil else { return }
        dismissAll()
    }
    public func dismissAll() {
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPromotionHandoff = false
        expandingGeneration += 1; isExpanding = false; dismissGeneration += 1; isDismissing = false
        undoTask?.cancel(); undoItem = nil; undoToast?.dismiss(); undoToast = nil
        for item in stack { item.host?.close() }; stack.removeAll(); overlay.isHidden = true; overlay.resetMotion(); overlay.clearHost(); removeKeys(); onChange?()
    }
    private func removeKeys() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    public func expandTop() { expandTop(into: splitController.space?.id) }
    public func expandTop(into target: SpaceID?) {
        PeekMotionTrace.mark("request.expand")
        guard !isExpanding, !isDismissing, let item = stack.last, let target, model.space(id: target) != nil else { return }
        expandingGeneration += 1; let generation = expandingGeneration; isExpanding = true
        let interval = duration(Motion.peekExpand)
        if interval == 0 { promote(item, into: target, split: false); return }
        prepareMotionSnapshot(for: item) { [weak self] in
            guard let self, self.expandingGeneration == generation, self.stack.last?.id == item.id else { return }
            self.prepareExpandedImage(item, target: target, generation: generation, duration: interval)
        }
    }
    private func prepareExpandedImage(_ item: PeekItem, target: SpaceID, generation: Int, duration: Double) {
        guard let host = item.host else { return }
        let rect = overlay.contentRect, motion = motionGeneration
        overlay.prepareExpansionViewport(rect)
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == motion,
                  self.expandingGeneration == generation, self.stack.last?.id == item.id else { return }
            self.snapshotTask = nil
            guard let image else {
                self.overlay.restoreExpansionViewport(); self.isExpanding = false
                self.overlay.attachOpeningHost(host.view)
                self.finishOpeningHandoff(itemID: item.id, host: host)
                return
            }
            self.overlay.stageExpansionImage(image, target: rect) { [weak self] in
                guard let self, self.motionGeneration == motion, self.expandingGeneration == generation,
                      self.stack.last?.id == item.id else { return }
                self.overlay.animateExpansionCard(to: rect, duration: duration) { [weak self] in
                    guard let self, self.expandingGeneration == generation, self.stack.last?.id == item.id else { return }
                    self.promote(item, into: target, split: false)
                }
            }
        }
    }
    @discardableResult public func openInSplitTop() -> Bool {
        guard let item = stack.last, let space = splitController.space, !isExpanding else { return false }
        // GUESS: the alert beeps on refused Peek actions here are not captured (C9; features-advanced SE-2).
        guard splitController.canAddPane else { NSSound.beep(); return false }
        // Guess: PK split semantics, confirmed by lead decision Q4.
        return promote(item, into: space.id, split: true)
    }
    @discardableResult private func promote(_ item: PeekItem, into target: SpaceID, split: Bool) -> Bool {
        guard stack.last?.id == item.id, model.space(id: target) != nil else { return false }; isExpanding = false
        // Favorites cannot be split, even when another tab is now selected.
        if split, case .favorites? = model.parent(of: item.sourceTabID) { NSSound.beep(); return false }
        let currentURL = item.host?.currentURL ?? item.url
        let tab = model.newTab(in: target, url: currentURL, title: item.host?.title ?? "", at: 0); tab.live.sleepPhase = .live
        if split {
            let succeeded: Bool
            if let existing = splitController.split {
                succeeded = model.addPane(splitID: existing.id, tabID: tab.id)
            } else if let made = model.makeSplit(tabIDs: [item.sourceTabID, tab.id]) {
                model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: made.id)
                model.focusSplitPane(splitID: made.id, tabID: tab.id); succeeded = true
            } else { succeeded = false }
            guard succeeded else {
                model.closeTab(id: tab.id); NSSound.beep(); return false
            }
        } else {
            model.focusSpace(windowID: splitController.windowID, spaceID: target)
            model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: tab.id)
        }
        isPromotionHandoff = !split && overlay.expansionCard != nil
        stack.removeLast(); item.host?.view.removeFromSuperview()
        // Bind before show, so showing a new tab cannot create and load a replacement host.
        if let host = item.host {
            // All-Profiles Archive can preview a different Profile. Promotion
            // must create a destination host rather than adopt that context.
            if item.librarySpaceID != nil, model.space(id:target)?.profileID != item.profileID { host.close() }
            else { splitController.container.adopt(host, for:tab.id) }
        }
        splitController.refresh(); splitController.container.focus(tabID: tab.id)
        if isPromotionHandoff, let host = item.host {
            finishPromotionHandoff(host, tabID: tab.id)
        } else { overlay.resetMotion(); refresh() }
        if stack.isEmpty { removeKeys() }; onChange?(); return true
    }
    private func finishPromotionHandoff(_ host: any WebContentHost, tabID: ItemID) {
        let generation = motionGeneration
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == generation,
                  self.isPromotionHandoff, self.model.tab(id: tabID) != nil,
                  let card = self.overlay.expansionCard else { return }
            self.snapshotTask = nil
            if let image { self.overlay.expansionImage?.contents = image }
            self.overlay.afterSnapshotCommit(card) { [weak self] in
                guard let self, self.motionGeneration == generation, self.isPromotionHandoff else { return }
                self.isPromotionHandoff = false; self.overlay.resetMotion(); self.refresh(); self.onChange?()
            }
        }
    }
    public func linkMenu(url: URL, source: ItemID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(FeatureMenuItem("Open Link in Peek") { [weak self] in self?.open(url: url, sourceTabID: source) })
        menu.addItem(FeatureMenuItem("Open Link in Split View", enabled: false) {})
        return menu
    }
}
