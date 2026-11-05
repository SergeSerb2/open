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
                                              shiftHeld: flags.contains(.shift), peekOtherSitesEnabled: defaults.bool(forKey: "open.peek.otherSites"),
                                              peekShiftEnabled: defaults.bool(forKey: "open.peek.shiftClick"))) == .peek
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
    @ObservationIgnored private var undoItem: (URL, ItemID, Date)?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var expandingGeneration = 0
    public private(set) var isExpanding = false
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var dismissGeneration = 0
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
    public var peekBadgeTabIDs: Set<ItemID> { Set(stack.map(\.sourceTabID)) }
    public init(model: BrowserModel, splitController: SplitViewController, factory: any WebContentHostFactory, defaults: UserDefaults) {
        self.model = model; self.splitController = splitController; self.factory = factory; self.defaults = defaults
        defaults.register(defaults: ["open.peek.otherSites": true, "open.peek.shiftClick": true])
        overlay.isHidden = true; overlay.onDismiss = { [weak self] in self?.dismissTop() }
        overlay.onExpand = { [weak self] in self?.expandTop() }; overlay.onSplit = { [weak self] in self?.openInSplitTop() }
    }
    isolated deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; undoTask?.cancel(); for item in stack { item.host?.close() } }
    public func intercept(tabID: ItemID, url: URL, flags: NSEvent.ModifierFlags) -> Bool {
        guard let tab = model.tab(id: tabID) else { return true }
        let favorite: Bool = if case .favorites? = model.parent(of: tabID) { true } else { false }
        if FeatureSite.shouldPeek(source: tab.url, target: url, pinned: model.isPinned(tabID: tabID) || favorite, flags: flags, defaults: defaults) {
            open(url: url, sourceTabID: tabID); return false
        }
        return true
    }
    public func open(url: URL, sourceTabID: ItemID) {
        guard let space = splitController.space else { return }
        dismissGeneration += 1; isDismissing = false; overlay.setOpacity(1, animated: false)
        if stack.count >= 5 { stack.last?.host?.load(url); return }
        let hostID = ItemID()
        guard let host = factory.makeHost(tabID: hostID, profileID: space.profileID, url: nil) else { return }
        let item = PeekItem(id: UUID(), url: url, sourceTabID: sourceTabID, hostTabID: hostID, host: host)
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
            self.onPageChange?()
            if !loading {
                if self.duration(0.12) == 0 { host.view.alphaValue = 1 }
                else { NSAnimationContext.runAnimationGroup { c in c.duration = self.duration(0.12); host.view.animator().alphaValue = 1 } }
            }
        }
        host.shouldNavigate = { [weak self, weak host] target, flags in
            guard let self, let host, self.stack.last?.id == itemID, self.stack.last?.host === host else { return false }
            if FeatureSite.shouldPeek(source: host.currentURL, target: target, pinned: true, flags: flags, defaults: self.defaults) && self.stack.count < 5 {
                guard let source = self.stack.last?.sourceTabID else { return false }
                self.open(url: target, sourceTabID: source); return false
            }
            return true
        }
        host.load(url); refresh(); host.focus(); installKeys()
        if duration(Motion.peekOpen) > 0 {
            overlay.setOpacity(0, animated: false)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "transform.scale"); animation.fromValue = 0.98; animation.toValue = 1
                animation.duration = Motion.peekOpen; animation.timingFunction = Motion.easeOut; overlay.panel.layer?.add(animation, forKey: "peekOpen")
            }
            NSAnimationContext.runAnimationGroup { c in c.duration = duration(Motion.peekOpen); overlay.setOpacity(1, animated: true) }
        }
        onChange?()
    }
    private func duration(_ value: Double) -> Double { overlay.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? value : 0 }
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.overlay.window, self.isShown else { return false }
                if event.keyCode == 53 { if self.onPageEscape?() != true { self.escape() }; return true }
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
        guard let item = stack.last else { overlay.isHidden = true; overlay.clearHost(); return }
        let sourceIsVisible: Bool
        if case .favorites(let profileID)? = model.parent(of: item.sourceTabID) {
            sourceIsVisible = splitController.space?.profileID == profileID
        } else { sourceIsVisible = splitController.selected?.id == sourceNodeID(of: item) }
        guard sourceIsVisible else { overlay.isHidden = true; return }
        overlay.isHidden = false; if let host = item.host { overlay.showHost(host) }; overlay.needsLayout = true
    }
    /// The sidebar row a Peek belongs to, read now: the split that holds the source tab,
    /// else the tab. A split made from the source tab, or dissolved, moves it.
    public func sourceNodeID(of item: PeekItem) -> ItemID {
        if case .splitPane(let splitID)? = model.parent(of: item.sourceTabID) { return splitID }
        return item.sourceTabID
    }
    public func escape() {
        if isExpanding { expandingGeneration += 1; isExpanding = false; overlay.panel.layer?.removeAllAnimations(); overlay.buttons.forEach { $0.alphaValue = 1 }; overlay.needsLayout = true; refresh() }
        else { dismissTop() }
    }
    public func dismissTop() {
        guard !isExpanding, !isDismissing, let item = stack.last else { return }
        let interval = duration(Motion.peekDismiss)
        if interval == 0 { finishDismiss(); return }
        isDismissing = true; dismissGeneration += 1; let generation = dismissGeneration, id = item.id
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 0.98
            scale.duration = interval; overlay.panel.layer?.add(scale, forKey: "peekDismiss")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = interval; overlay.setOpacity(0, animated: true)
        } completionHandler: { [weak self] in MainActor.assumeIsolated {
            guard let self, self.dismissGeneration == generation, self.stack.last?.id == id else { return }
            self.isDismissing = false; self.finishDismiss(); self.overlay.setOpacity(1, animated: false)
        } }
    }
    private func finishDismiss() {
        guard let item = stack.popLast() else { return }
        item.host?.close(); undoItem = (item.url, item.sourceTabID, Date().addingTimeInterval(Self.undoWindow))
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
        guard let item = undoItem, item.2 > Date() || undoToast?.isVisible == true else { return }; undoItem = nil; undoTask?.cancel()
        undoToast?.dismiss(); undoToast = nil
        open(url: item.0, sourceTabID: item.1)
    }
    public func dismissAll() {
        expandingGeneration += 1; isExpanding = false; dismissGeneration += 1; isDismissing = false
        undoTask?.cancel(); undoItem = nil; undoToast?.dismiss(); undoToast = nil
        for item in stack { item.host?.close() }; stack.removeAll(); overlay.isHidden = true; overlay.clearHost(); removeKeys(); onChange?()
    }
    private func removeKeys() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    public func expandTop() { expandTop(into: splitController.space?.id) }
    public func expandTop(into target: SpaceID?) {
        guard !isExpanding, let item = stack.last, let target, model.space(id: target) != nil else { return }
        expandingGeneration += 1; let generation = expandingGeneration; isExpanding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration(Motion.peekExpand); context.timingFunction = Motion.easeInOut
            overlay.buttons.forEach { $0.animator().alphaValue = 0 }
            overlay.panel.animator().frame = overlay.contentRect
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.expandingGeneration == generation else { return }
                if let top = self.stack.last { self.promote(top, into: target, split: false) }
            }
        }
        // Offscreen harnesses have no animation clock; finish the same handoff synchronously.
        if duration(Motion.peekExpand) == 0 && isExpanding { expandingGeneration += 1; promote(item, into: target, split: false) }
    }
    @discardableResult public func openInSplitTop() -> Bool {
        guard let item = stack.last, let space = splitController.space, !isExpanding else { return false }
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
        stack.removeLast(); item.host?.view.removeFromSuperview()
        // Bind before show, so showing a new tab cannot create and load a replacement host.
        if let host = item.host { splitController.container.adopt(host, for: tab.id) }
        splitController.refresh(); splitController.container.focus(tabID: tab.id)
        overlay.buttons.forEach { $0.alphaValue = 1 }; refresh(); if stack.isEmpty { removeKeys() }; onChange?(); return true
    }
    public func linkMenu(url: URL, source: ItemID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(FeatureMenuItem("Open Link in Peek") { [weak self] in self?.open(url: url, sourceTabID: source) })
        menu.addItem(FeatureMenuItem("Open Link in Split View", enabled: false) {})
        return menu
    }
}
