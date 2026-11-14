import AppKit
import OpenModel
import OpenCommands

@MainActor
final class FeatureMenuItem: NSMenuItem {
    var perform: (() -> Void)?
    init(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) {
        super.init(title: title, action: #selector(invoke), keyEquivalent: ""); self.perform = perform; target = self; isEnabled = enabled
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
}

@MainActor
public final class SplitViewController: NSViewController, CommandDispatcher {
    public let model: BrowserModel
    public let windowID: WindowID
    public let container: WebContentContainer
    public var onChange: (() -> Void)?
    public private(set) var maximizedPaneID: ItemID?
    public var state: BrowserWindowState? { model.windows.first { $0.id == windowID } }
    public var space: Space? { state.flatMap { model.space(id: $0.focusedSpaceID) } }
    public var selected: SidebarNode? { guard let state, let id = state.selectedNodeBySpace[state.focusedSpaceID] else { return nil }; return model.node(id: id) }
    public var split: Split? { selected?.split }
    public var focusedTab: Tab? { selected?.tab ?? split.flatMap { s in s.panes.first { $0.id == s.focusedPaneID } ?? s.panes.first } }
    public init(model: BrowserModel, windowID: WindowID, container: WebContentContainer) {
        self.model = model; self.windowID = windowID; self.container = container; super.init(nibName: nil, bundle: nil)
        view = container
        container.tabProvider = { [weak model] in model?.tab(id: $0) }
        container.onPaneClicked = { [weak self] in self?.focus($0) }
        container.onPaneClose = { [weak self] in self?.close($0, separate: false, option: NSApp.currentEvent?.modifierFlags.contains(.option) == true) }
        container.onPaneMenu = { [weak self] id, anchor in
            guard let self else { return }; self.focus(id); self.menu().popUp(positioning: nil, at: CGPoint(x: 0, y: anchor.bounds.height), in: anchor)
        }
        container.onFractionsCommitted = { [weak self] fractions in
            guard let self, let split = self.split else { return }; self.model.setSplitFractions(splitID: split.id, fractions: fractions); self.onChange?()
        }
        container.onDrop = { [weak self] id, zone, index in self?.drop(id, zone: zone, paneIndex: index) ?? false }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func refresh() {
        guard let space else { container.clearSelection(); container.isHidden = true; return }
        guard let focused = focusedTab else { container.showEmptySpace(spaceID: space.id, profileID: space.profileID); return }
        let panes = split?.panes ?? [focused]
        container.show(tabIDs: panes.map(\.id), focusedTabID: focused.id, orientation: split?.orientation ?? .horizontal,
                       fractions: split?.fractions ?? [1], spaceID: space.id, profileID: space.profileID)
        container.maximizedTabID = split?.panes.contains { $0.id == maximizedPaneID } == true ? maximizedPaneID : nil
    }
    private func canSplit(_ id: ItemID) -> Bool {
        guard model.tab(id: id) != nil, let parent = model.parent(of: id) else { return false }
        switch parent { case .favorites, .splitPane: return false; default: return true }
    }
    public var canAddPane: Bool { if let split { return split.panes.count < 4 }; return focusedTab.map { canSplit($0.id) } ?? false }
    public func addEmptyPane() {
        // GUESS: the alert beep on a refused split is not captured (C9 tested only the successful split; features-advanced SE-2).
        guard canAddPane, let space, let current = focusedTab else { NSSound.beep(); return }
        let tab = model.newTab(in: space.id, url: URL(string: "about:blank")!, at: 0); tab.live.sleepPhase = .live
        if let split { _ = model.addPane(splitID: split.id, tabID: tab.id) }
        else if let made = model.makeSplit(tabIDs: [current.id, tab.id]) {
            model.focusSplitPane(splitID: made.id, tabID: tab.id); select(made.id)
        }
        refresh(); onChange?()
    }
    public func openInSplit(_ id: ItemID) {
        guard canSplit(id), let current = focusedTab, current.id != id else { return }
        if let split { guard model.addPane(splitID: split.id, tabID: id) else { return } }
        else if let made = model.makeSplit(tabIDs: [id, current.id]) { select(made.id); model.focusSplitPane(splitID: made.id, tabID: id) }
        refresh(); onChange?()
    }
    public func focus(_ id: ItemID) {
        guard let split, split.panes.contains(where: { $0.id == id }) else { return }
        maximizedPaneID = nil; container.maximizedTabID = nil
        model.focusSplitPane(splitID: split.id, tabID: id); container.focus(tabID: id); onChange?()
    }
    public func close(_ id: ItemID, separate: Bool, option: Bool = false) {
        guard let split else { return }
        if option {
            model.unsplit(splitID: split.id); select(id)
        } else {
            // A collapsing split hands the selection to its surviving tab in the model.
            model.removePane(splitID: split.id, tabID: id, archive: !separate)
            // The model retargets a collapsed split. A larger split remains
            // valid, so separating its pane still selects the new sibling.
            if separate, model.node(id: split.id)?.split != nil { select(id) }
        }
        maximizedPaneID = nil; refresh(); onChange?()
    }
    /// Adds an empty pane on one side of the focused page (Developer Mode's Split View Menu: Add Right / Left / Top /
    /// Bottom Split, C-report-s10 PB3-a2), as dropping a tab on that edge would.
    public func addEmptyPane(edge zone: SplitDropOverlayView.Zone) {
        guard canAddPane, let space, focusedTab != nil else { NSSound.beep(); return }
        let tab = model.newTab(in: space.id, url: URL(string: "about:blank")!, at: 0); tab.live.sleepPhase = .live
        maximizedPaneID = nil
        if !drop(tab.id, zone: zone, paneIndex: nil) { model.closeTab(id: tab.id); NSSound.beep() }
    }
    private func select(_ id: ItemID) { if let space { model.selectNode(windowID: windowID, spaceID: space.id, nodeID: id) } }
    public func performCommand(_ id: String) {
        if id == "add-split-view" { addEmptyPane(); return }
        guard let split, let focused = focusedTab else { return }
        switch id {
        case "close-split-pane": close(focused.id, separate: false)
        case "separate-from-split-view": close(focused.id, separate: true)
        case "expand-current-split": maximizedPaneID = maximizedPaneID == nil ? focused.id : nil; container.maximizedTabID = maximizedPaneID
        case "escape": maximizedPaneID = nil; container.maximizedTabID = nil
        case "next-split-pane", "previous-split-pane":
            let index = split.panes.firstIndex { $0.id == focused.id } ?? 0
            let delta = id == "next-split-pane" ? 1 : split.panes.count - 1
            focus(split.panes[(index + delta) % split.panes.count].id)
        default:
            if id.hasPrefix("focus-split-pane-"), let n = Int(id.dropFirst("focus-split-pane-".count)), split.panes.indices.contains(n - 1) { focus(split.panes[n - 1].id) }
        }
    }
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool { id == "add-split-view" ? canAddPane : split != nil }
    public func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(FeatureMenuItem("Add Pane", enabled: canAddPane) { [weak self] in self?.addEmptyPane() })
        if let split {
            let next: SplitOrientation = split.orientation == .horizontal ? .vertical : .horizontal
            menu.addItem(FeatureMenuItem("Convert to \(next == .horizontal ? "Horizontal" : "Vertical") Split View") { [weak self] in
                guard let self else { return }; self.model.setSplitOrientation(splitID: split.id, orientation: next); self.refresh(); self.onChange?()
            })
            for (title, id) in [("Expand Current Pane", "expand-current-split"), ("Separate This Pane", "separate-from-split-view")] {
                menu.addItem(FeatureMenuItem(title) { [weak self] in self?.performCommand(id) })
            }
            menu.addItem(FeatureMenuItem("Separate All Tabs") { [weak self] in
                guard let self else { return }; let focused = self.focusedTab?.id; self.model.unsplit(splitID: split.id)
                if let focused { self.select(focused) }; self.refresh(); self.onChange?()
            })
            menu.addItem(FeatureMenuItem("Close This Pane") { [weak self] in self?.performCommand("close-split-pane") })
            menu.addItem(FeatureMenuItem("Copy Link") { [weak self] in
                let links = split.panes.map { URLCleaner.clean($0.url) }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(links.map { $0.url.absoluteString }.joined(separator: "\n"), forType: .string),
                   links.contains(where: { !$0.removed.isEmpty }) {
                    self?.container.toasts?.show(ToastContent(title: URLCleaner.cleanedTitle(count: links.count)))
                }
            })
        }
        return menu
    }
    @discardableResult public func drop(_ id: ItemID, zone: SplitDropOverlayView.Zone, paneIndex: Int?) -> Bool {
        guard canSplit(id), let current = focusedTab, current.id != id else { return false }
        if zone == .center && paneIndex == nil { select(id); refresh(); onChange?(); return true }
        let orientation: SplitOrientation = zone == .top || zone == .bottom ? .vertical : .horizontal
        let before = zone == .left || zone == .top
        if let split {
            guard model.addPane(splitID: split.id, tabID: id, at: paneIndex ?? (before ? 0 : split.panes.count)) else { return false }
            if paneIndex == nil { model.setSplitOrientation(splitID: split.id, orientation: orientation) }
        } else {
            guard let made = model.makeSplit(tabIDs: before ? [id, current.id] : [current.id, id], orientation: orientation) else { return false }
            select(made.id); model.focusSplitPane(splitID: made.id, tabID: id)
        }
        refresh(); onChange?(); return true
    }
}
