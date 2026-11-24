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
    // Dedicated sign-in hosts (not general product or account-settings portals).
    private static let identityHosts: Set<String> = [
        "login.microsoftonline.com", "login.microsoft.com", "login.live.com",
        "login.windows.net", "sts.windows.net",
        "login.microsoftonline.us", "login.chinacloudapi.cn", "login.partner.microsoftonline.cn",
        "accounts.google.com", "appleid.apple.com", "idmsa.apple.com",
    ]
    // Tenant-only identity provider domains: require a non-www subdomain so vendor marketing sites
    // (for example okta.com/pricing or www.auth0.com) still open in Peek.
    private static let identityTenantSuffixes: [String] = [
        "b2clogin.com", "okta.com", "oktapreview.com", "okta-emea.com",
        "auth0.com", "onelogin.com", "duosecurity.com",
        "pingidentity.com", "pingone.com", "jumpcloud.com", "awsapps.com",
    ]
    // Anchored auth endpoint paths (exact/suffix or root prefix) to avoid matching repo/doc paths.
    private static let authPathSuffixes: [String] = [
        "/bridge/fido", "/common/reprocess",
        "/oauth/authorize", "/oauth2/authorize", "/oauth2/v1/authorize",
        "/oauth2/v2/auth", "/oauth2/v2.0/authorize",
        "/connect/authorize", "/protocol/openid-connect/auth",
        "/saml/sso", "/sso/saml",
    ]
    private static let authPathPrefixes: [String] = [
        "/o/oauth2/", "/adfs/ls", "/saml2/",
    ]
    private static func isIdentityHost(_ rawHost: String?) -> Bool {
        guard let rawHost, !rawHost.isEmpty, rawHost.utf8.count <= 255 else { return false }
        let host = HostNormalizer.canonicalHostName(rawHost)
        if identityHosts.contains(host) { return true }
        return identityTenantSuffixes.contains { suffix in
            host.hasSuffix("." + suffix) && host != "www." + suffix
        }
    }
    private static func isProtocolAuthURL(_ url: URL) -> Bool {
        // Bound work even if a caller hands in a URL outside Chromium's 2 MiB URL limit.
        guard url.absoluteString.utf8.count <= 2_097_152 else { return false }
        let pathPrefix = String(url.path.prefix(512)).lowercased()
        let trimmedPath = pathPrefix.count > 1 && pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
        if authPathSuffixes.contains(where: { trimmedPath == $0 || trimmedPath.hasSuffix($0) }) { return true }
        if authPathPrefixes.contains(where: { pathPrefix.hasPrefix($0) }) { return true }
        guard let query = url.query, !query.isEmpty else { return false }
        // Scan query parameter names without decoding values; cap param count to bound work on huge URLs.
        var hasClientID = false, hasRedirectOrResponse = false, paramsScanned = 0
        var i = query.utf8.startIndex
        let end = query.utf8.endIndex
        while i < end && paramsScanned < 128 {
            let amp = query.utf8[i..<end].firstIndex(of: UInt8(ascii: "&")) ?? end
            let eq = query.utf8[i..<amp].firstIndex(of: UInt8(ascii: "=")) ?? amp
            let nameLength = query.utf8.distance(from: i, to: eq)
            if nameLength > 0 && nameLength <= 64, let raw = String(query.utf8[i..<eq]) {
                let name = raw.lowercased()
                if name == "samlrequest" || name == "samlresponse" { return true }
                if name == "client_id" { hasClientID = true }
                else if name == "redirect_uri" || name == "response_type" { hasRedirectOrResponse = true }
                if hasClientID && hasRedirectOrResponse { return true }
            }
            paramsScanned += 1
            i = amp < end ? query.utf8.index(after: amp) : end
        }
        return false
    }
    static func isAuthenticationFlow(source: URL?, target: URL) -> Bool {
        isIdentityHost(source?.host()) || isIdentityHost(target.host()) || isProtocolAuthURL(target)
    }
    public static func shouldPeek(source: URL?, target: URL, pinned: Bool, flags: NSEvent.ModifierFlags, defaults: UserDefaults) -> Bool {
        guard ["http", "https"].contains(target.scheme?.lowercased() ?? ""), !flags.contains(.command),
              !flags.contains(.option), !fragmentOnly(source, target) else { return false }
        return PeekPolicy.decision(for: .init(sourceIsPinnedOrFavorite: pinned, sourceHost: domain(source), targetHost: domain(target),
                                              shiftHeld: flags.contains(.shift), peekOtherSitesEnabled: defaults.object(forKey: "open.links.openPeekOtherSites") as? Bool ?? true,
                                              peekShiftEnabled: defaults.object(forKey: "open.links.openPeekShiftClick") as? Bool ?? true,
                                              isAuthenticationFlow: isAuthenticationFlow(source: source, target: target))) == .peek
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
    /// The source tab and Library Space of the closed Peek that Undo can bring back, if any.
    public var undoSource: (tabID: ItemID, librarySpaceID: SpaceID?)? { undoItem.map { ($0.source, $0.librarySpace) } }
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var expandingGeneration = 0
    public private(set) var isExpanding = false
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var dismissGeneration = 0
    @ObservationIgnored private var motionGeneration = 0
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    public private(set) var isPromotionHandoff = false
    /// The tab a promotion hands its expansion card to, and whether `promote` is still running.
    private var promotionTabID: ItemID?
    /// The destination host the handoff waits for. A different host for the tab (a Profile
    /// change rebuilt it) never finishes the handoff (review r1 #4).
    private weak var promotionHost: (any WebContentHost)?
    private var promoting = false
    public private(set) var isPreparingOpening = false
    @ObservationIgnored private var openingLoadStarted = false
    @ObservationIgnored private weak var openingFocus: NSResponder?
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
        let sourceURL = splitController.container.host(for: tabID)?.currentURL ?? tab.url
        if FeatureSite.shouldPeek(source: sourceURL, target: url, pinned: model.isPinned(tabID: tabID) || favorite, flags: flags, defaults: defaults) {
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
        let sourceColor = stack.last?.host?.pageBackgroundColor
            ?? splitController.container.host(for: sourceTabID)?.pageBackgroundColor
            ?? overlay.style.miniPlayerFill(overlay.style.resolvedAppearance(system: .light)).nsColor
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPreparingOpening = false; openingLoadStarted = false
        isPromotionHandoff = false; overlay.clearExpansionCard(); overlay.restoreExpansionViewport()
        overlay.endHostSnapshot()
        dismissGeneration += 1; isDismissing = false
        expandingGeneration += 1; isExpanding = false
        // At the cap the top Peek's page is reused only for the same Profile and source kind. Another
        // Profile's URL (a Library preview) replaces the top Peek: it must not load with its cookies.
        if stack.count >= 5, let top = stack.last, top.profileID == profile, top.librarySpaceID == librarySpaceID {
            overlay.resetMotion(); stack[stack.count - 1].url = url; top.host?.load(url); refresh(); return
        }
        let hostID = ItemID()
        guard let host = factory.makeHost(tabID: hostID, profileID: profile, url: nil) else { overlay.resetMotion(); return }
        // Only now that the replacement exists: a failed makeHost keeps the top Peek on screen.
        if stack.count >= 5 { stack.removeLast().host?.close() }
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
            if loading { self.openingLoadStarted = true }
            PeekMotionTrace.region("host.onPageChange") { self.onPageChange?() }
            if !loading {
                // The page is attached (covered) from the click on, so its
                // content fades in when it is ready, during card motion too.
                if self.overlay.openingHandoff {
                    // Chromium emits its initial false state before starting
                    // the pending navigation. That is not ready page content.
                    if self.openingLoadStarted { self.finishOpeningHandoff(itemID: itemID, host: host) }
                }
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
                // A nested Peek stays in its source Peek's Profile, whatever Space the window shows.
                self.open(url:target,sourceTabID:source.sourceTabID,librarySpaceID:source.librarySpaceID,profileID:source.profileID); return false
            }
            return true
        }
        let interval = duration(Motion.peekOpen)
        if interval > 0 {
            // The card responds before Chromium has a destination image. Use
            // the source page's known color, never an empty engine/white plate.
            isPreparingOpening = true
            overlay.prepareOpeningPlate(host.view, color: sourceColor)
            // Create and load the page now, under the opaque plate, at the
            // same readiness point as a non-animated open. Only its ready
            // image fades in; the live page never moves uncovered.
            overlay.attachOpeningHost(host.view)
        }
        host.load(url); refresh(); installKeys()
        openingFocus = overlay.window?.firstResponder
        PeekMotionTrace.region("open.onChange") { onChange?() }
        let generation = motionGeneration
        overlay.animatePresentation(true, duration: interval) { [weak self, weak host] in
            guard let self, let host, self.motionGeneration == generation, self.stack.last?.id == itemID else { return }
            self.isPreparingOpening = false
            PeekMotionTrace.mark("opening.cardComplete")
            if interval > 0 { self.refresh() }
            if self.isShown, self.overlay.window?.isKeyWindow == true,
               self.overlay.window?.firstResponder === self.openingFocus { host.focus() }
        }
    }
    private func finishOpeningHandoff(itemID: UUID, host: any WebContentHost) {
        guard snapshotTask == nil, !overlay.isOpeningContentFading else { return }
        let generation = motionGeneration
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == generation,
                  self.stack.last?.id == itemID, self.overlay.openingHandoff else { return }
            guard !host.isLoading else { self.snapshotTask = nil; return }
            // Keep this task as the handoff owner through the fade and live
            // swap, so repeated not-loading callbacks cannot start a second
            // reveal after CA has removed the completed animation.
            self.overlay.finishOpeningHandoff(image: image, duration: self.duration(0.08)) { [weak self] in
                guard let self, self.motionGeneration == generation, self.stack.last?.id == itemID else { return }
                self.snapshotTask = nil; self.refresh()
            }
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
        if isPromotionHandoff {
            // The handoff waits for the promoted tab's page. A tab closed, replaced or left meanwhile
            // never finishes it: end the card now, or it covers the window (bug sweep r6 WL-01).
            guard !promoting, let id = promotionTabID, model.tab(id: id) == nil
                    || splitController.container.host(for: id) == nil || splitController.focusedTab?.id != id
                    || (promotionHost != nil && splitController.container.host(for: id) !== promotionHost) else { return }
            cancelPromotionHandoff()
        }
        if pruneOrphanedItems() { return }
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
    private func cancelPromotionHandoff() {
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPromotionHandoff = false; promotionTabID = nil; promotionHost = nil
        overlay.resetMotion()
    }
    /// A Peek whose source tab left this window's model (closed, archived, moved to a Blank
    /// Window) can never show again: close its page instead of keeping it live until the window
    /// closes (bug sweep r6 WL-05). Library previews have no source tab. Returns true when it
    /// changed the stack; `onChange` then refreshes again.
    private func pruneOrphanedItems() -> Bool {
        let orphaned = Set(stack.filter { $0.librarySpaceID == nil && model.tab(id: $0.sourceTabID) == nil }.map(\.id))
        guard !orphaned.isEmpty else { return false }
        if orphaned.count == stack.count { dismissAll(); return true }
        if let top = stack.last, orphaned.contains(top.id) {
            motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil; isPreparingOpening = false
            expandingGeneration += 1; isExpanding = false; dismissGeneration += 1; isDismissing = false
            overlay.resetMotion(); overlay.clearHost()
        }
        for item in stack where orphaned.contains(item.id) { item.host?.close() }
        stack.removeAll { orphaned.contains($0.id) }
        onChange?(); return true
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
        snapshotTask?.cancel(); snapshotTask = nil; isPreparingOpening = false
        // A close during loading/fading uses the retained plate and cancels
        // its reveal completion. It must not expose an unfinished live page.
        if overlay.openingHandoff { overlay.holdOpeningPlate(); action(); return }
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
    /// A Peek page closed itself (window.close()). Its entry goes wherever it is in the stack,
    /// so dismissing a later Peek never reveals the closed page. A top page that closes during
    /// expansion cancels the expansion; one already closing finishes its own dismissal.
    public func pageClosed(hostTabID: ItemID) {
        guard let index = stack.firstIndex(where: { $0.host?.tabID == hostTabID }) else { return }
        guard index == stack.count - 1 else {
            let item = stack.remove(at: index); item.host?.close(); refresh(); onChange?(); return
        }
        if isDismissing { return }
        if !isExpanding { dismissTop(); return }
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPreparingOpening = false; isPromotionHandoff = false
        expandingGeneration += 1; isExpanding = false
        overlay.clearExpansionCard(); overlay.restoreExpansionViewport(); overlay.endHostSnapshot()
        finishDismiss(); overlay.resetMotion()
    }
    public func undoDismiss() {
        // Live while its toast shows (a hovered toast outlasts the 5 s window), else for 5 s.
        guard let item = undoItem, item.expiry > Date() || undoToast?.isVisible == true else { return }; undoItem = nil; undoTask?.cancel()
        undoToast?.dismiss(); undoToast = nil
        // The Peek comes back in its own Profile: the window may show another Profile's Space now.
        open(url:item.url,sourceTabID:item.source,librarySpaceID:item.librarySpace,profileID:item.profile)
    }
    /// Closing Library also expires Undo for its last dismissed preview.
    public func closeLibraryPreviews() {
        guard stack.contains(where: { $0.librarySpaceID != nil }) || undoItem?.librarySpace != nil else { return }
        dismissAll()
    }
    public func dismissAll() {
        motionGeneration += 1; snapshotTask?.cancel(); snapshotTask = nil
        isPreparingOpening = false
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
        // A closing Peek cannot also move: its dismissal would never clear `isDismissing` (WL-02).
        guard let item = stack.last, let space = splitController.space, !isExpanding, !isDismissing else { return false }
        // GUESS: the alert beeps on refused Peek actions here are not captured (C9; features-advanced SE-2).
        guard splitController.canAddPane else { NSSound.beep(); return false }
        // Guess: PK split semantics, confirmed by lead decision Q4.
        return promote(item, into: space.id, split: true)
    }
    @discardableResult private func promote(_ item: PeekItem, into target: SpaceID, split: Bool) -> Bool {
        guard stack.last?.id == item.id, model.space(id: target) != nil else { return false }; isExpanding = false
        // Favorites cannot be split, even when another tab is now selected.
        if split, case .favorites? = model.parent(of: item.sourceTabID) { NSSound.beep(); return false }
        isPromotionHandoff = !split && overlay.expansionCard != nil
        promoting = true; defer { promoting = false }
        let currentURL = item.host?.currentURL ?? item.url
        // The new tab, its split and its selection are one Undo step (bug sweep r6 WL-10).
        let promoted = model.asOneUndoStep { () -> Tab? in
            let tab = model.newTab(in: target, url: currentURL, title: item.host?.title ?? "", at: 0); tab.live.sleepPhase = .live
            if split {
                let succeeded: Bool
                if let existing = splitController.split {
                    succeeded = model.addPane(splitID: existing.id, tabID: tab.id)
                    // The new pane takes focus; Expand Current Pane would keep it hidden.
                    if succeeded { splitController.clearMaximizedPane(unless: tab.id) }
                } else if let made = model.makeSplit(tabIDs: [item.sourceTabID, tab.id]) {
                    model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: made.id)
                    model.focusSplitPane(splitID: made.id, tabID: tab.id); succeeded = true
                } else { succeeded = false }
                guard succeeded else { model.closeTab(id: tab.id); return nil }
            } else {
                // The promoted tab leaves any split: end Expand Current Pane (this selection does
                // not pass through the window's select, which ends it for other selections).
                splitController.clearMaximizedPane(unless: nil)
                model.focusSpace(windowID: splitController.windowID, spaceID: target)
                model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: tab.id)
            }
            return tab
        }
        guard let tab = promoted else { NSSound.beep(); return false }
        promotionTabID = isPromotionHandoff ? tab.id : nil
        stack.removeLast(); item.host?.view.removeFromSuperview()
        // Bind before show, so showing a new tab cannot create and load a replacement host.
        if let host = item.host {
            // All-Profiles Archive can preview a different Profile. Promotion
            // must create a destination host rather than adopt that context.
            if item.librarySpaceID != nil, model.space(id:target)?.profileID != item.profileID { host.close() }
            else { splitController.container.adopt(host, for:tab.id) }
        }
        splitController.refresh(); splitController.container.focus(tabID: tab.id)
        if isPromotionHandoff, let host = splitController.container.host(for: tab.id) {
            // Alloy Peek pages can be replaced by a Chrome destination. The
            // old host closes during adopt; only the destination can finish
            // this handoff. Its normal container callbacks remain untouched.
            promotionHost = host
            finishPromotionHandoff(host, tabID: tab.id, generation: motionGeneration, waitsForLoad: host !== item.host)
        } else { isPromotionHandoff = false; overlay.resetMotion(); refresh() }
        if stack.isEmpty { removeKeys() }; onChange?(); return true
    }
    private func finishPromotionHandoff(_ host: any WebContentHost, tabID: ItemID, generation: Int, waitsForLoad: Bool) {
        guard motionGeneration == generation, isPromotionHandoff,
              splitController.container.host(for: tabID) === host, let tab = model.tab(id: tabID) else { return }
        let ready = withObservationTracking {
            !tab.live.isLoading && (!waitsForLoad || tab.live.hasLoadedInThisLaunch || tab.live.isCrashed)
        } onChange: { [weak self] in
            // Observation fires before the property write. Resume on the next
            // turn, once the load state and the destination pixels can settle.
            Task { @MainActor [weak self] in
                guard let self, let host = self.splitController.container.host(for: tabID) else { return }
                self.finishPromotionHandoff(host, tabID: tabID, generation: generation, waitsForLoad: waitsForLoad)
            }
        }
        guard ready, snapshotTask == nil else { return }
        PeekMotionTrace.mark("promotion.destinationReady")
        snapshotTask = Task { @MainActor [weak self, weak host] in
            guard let host else { return }
            let image = await PeekHostSnapshot.capture(host)
            guard !Task.isCancelled, let self, self.motionGeneration == generation,
                  self.isPromotionHandoff, self.splitController.container.host(for: tabID) === host,
                  let card = self.overlay.expansionCard else { return }
            self.snapshotTask = nil
            if let image { self.overlay.expansionImage?.contents = image }
            self.overlay.afterSnapshotCommit(card) { [weak self] in
                guard let self, self.motionGeneration == generation, self.isPromotionHandoff else { return }
                self.isPromotionHandoff = false; self.promotionHost = nil; self.overlay.resetMotion(); self.refresh(); self.onChange?()
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
