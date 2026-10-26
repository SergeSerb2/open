import AppKit
import Observation
import OpenModel
import OpenFeatures
import OpenSuggest
import OpenDesign

/// Registrable-domain lookup uses OpenSuggest's bundled ICANN PSL (lead decision Q1).
/// Unknown/local hosts fall back to exact canonical host comparison.
enum FeatureSite {
    static func domain(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return nil }
        guard let count = PublicSuffixList.shared.suffixLabelCount(host: host) else { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return host.split(separator: ".").suffix(count + 1).joined(separator: ".")
    }
    static func fragmentOnly(_ source: URL?, _ target: URL) -> Bool {
        guard let source, target.fragment != nil, var a = URLComponents(url: source, resolvingAgainstBaseURL: false), var b = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return false }
        a.fragment = nil; b.fragment = nil; return a == b
    }
    static func shouldPeek(source: URL?, target: URL, pinned: Bool, flags: NSEvent.ModifierFlags, defaults: UserDefaults) -> Bool {
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
        public let sourceNodeID: ItemID
        public let hostTabID: ItemID
        public var host: (any WebContentHost)?
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
    public var onChange: (() -> Void)?
    public var onToast: ((String, (() -> Void)?) -> Void)?
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
        if stack.count >= 5 { stack.last?.host?.load(url); return }
        let hostID = ItemID(), host = factory.makeHost(tabID: hostID, profileID: space.profileID, url: nil)
        let nodeID: ItemID = if case .splitPane(let id)? = model.parent(of: sourceTabID) { id } else { sourceTabID }
        let item = PeekItem(id: UUID(), url: url, sourceTabID: sourceTabID, sourceNodeID: nodeID, hostTabID: hostID, host: host)
        stack.append(item)
        host.onURLChange = { [weak self, weak host] value in
            guard let self, let host, let i = self.stack.firstIndex(where: { $0.id == item.id }), self.stack[i].host === host else { return }
            self.stack[i].url = value
        }
        host.onLoadingChange = { [weak self, weak host] loading in
            guard let self, let host, self.stack.last?.id == item.id, self.stack.last?.host === host else { return }
            if !loading { NSAnimationContext.runAnimationGroup { c in c.duration = self.duration(0.12); host.view.animator().alphaValue = 1 } }
        }
        host.shouldNavigate = { [weak self, weak host] target, flags in
            guard let self, let host, self.stack.last?.id == item.id, self.stack.last?.host === host else { return false }
            if FeatureSite.shouldPeek(source: host.currentURL, target: target, pinned: true, flags: flags, defaults: self.defaults) && self.stack.count < 5 {
                self.open(url: target, sourceTabID: sourceTabID); return false
            }
            return true
        }
        host.load(url); refresh(); host.focus(); installKeys()
        if duration(Motion.peekOpen) > 0 {
            overlay.alphaValue = 0
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "transform.scale"); animation.fromValue = 0.98; animation.toValue = 1
                animation.duration = Motion.peekOpen; animation.timingFunction = Motion.easeOut; overlay.panel.layer?.add(animation, forKey: "peekOpen")
            }
            NSAnimationContext.runAnimationGroup { c in c.duration = duration(Motion.peekOpen); overlay.animator().alphaValue = 1 }
        }
        onChange?()
    }
    private func duration(_ value: Double) -> Double { overlay.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? value : 0 }
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.overlay.window, self.isShown else { return false }
                if event.keyCode == 53 { self.escape(); return true }
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
        guard let item = stack.last, let selected = splitController.selected, selected.id == item.sourceNodeID else { overlay.isHidden = true; return }
        overlay.isHidden = false; if let host = item.host { overlay.showHost(host) }; overlay.needsLayout = true
    }
    public func escape() {
        if isExpanding { expandingGeneration += 1; isExpanding = false; overlay.panel.layer?.removeAllAnimations(); overlay.buttons.forEach { $0.alphaValue = 1 }; overlay.needsLayout = true; refresh() }
        else { dismissTop() }
    }
    public func dismissTop() {
        guard !isExpanding, let item = stack.popLast() else { return }
        item.host?.close(); undoItem = (item.url, item.sourceTabID, Date().addingTimeInterval(5))
        onToast?("Peek closed", { [weak self] in self?.undoDismiss() })
        undoTask?.cancel(); undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5)); guard !Task.isCancelled else { return }; self?.undoItem = nil; self?.onToast?("", nil)
        }
        refresh(); if stack.isEmpty { removeKeys(); splitController.container.host(for: item.sourceTabID)?.focus() }
        onChange?()
    }
    public func undoDismiss() {
        guard let item = undoItem, item.2 > Date() else { return }; undoItem = nil; undoTask?.cancel()
        open(url: item.0, sourceTabID: item.1); onToast?("", nil)
    }
    public func dismissAll() {
        expandingGeneration += 1; isExpanding = false
        for item in stack { item.host?.close() }; stack.removeAll(); overlay.isHidden = true; removeKeys(); onChange?()
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
    public func openInSplitTop() {
        guard let item = stack.last, let space = splitController.space, !isExpanding else { return }
        guard splitController.canAddPane else { NSSound.beep(); return }
        // Guess: PK split semantics, confirmed by lead decision Q4.
        promote(item, into: space.id, split: true)
    }
    private func promote(_ item: PeekItem, into target: SpaceID, split: Bool) {
        guard stack.last?.id == item.id else { return }; isExpanding = false
        let currentURL = item.host?.currentURL ?? item.url
        let tab = model.newTab(in: target, url: currentURL, title: item.host?.title ?? "", at: 0); tab.live.sleepPhase = .live
        if split, let existing = splitController.split { _ = model.addPane(splitID: existing.id, tabID: tab.id) }
        else if split, let made = model.makeSplit(tabIDs: [item.sourceTabID, tab.id]) {
            model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: made.id); model.focusSplitPane(splitID: made.id, tabID: tab.id)
        } else {
            model.focusSpace(windowID: splitController.windowID, spaceID: target)
            model.selectNode(windowID: splitController.windowID, spaceID: target, nodeID: tab.id)
        }
        stack.removeLast(); item.host?.view.removeFromSuperview()
        // Bind before show, so showing a new tab cannot create and load a replacement host.
        if let host = item.host { splitController.container.adopt(host, for: tab.id) }
        splitController.refresh(); splitController.container.focus(tabID: tab.id)
        overlay.buttons.forEach { $0.alphaValue = 1 }; refresh(); if stack.isEmpty { removeKeys() }; onChange?()
    }
    public func linkMenu(url: URL, source: ItemID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(FeatureMenuItem("Open Link in Peek") { [weak self] in self?.open(url: url, sourceTabID: source) })
        menu.addItem(FeatureMenuItem("Open Link in Split View", enabled: false) {})
        return menu
    }
}
