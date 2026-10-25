import Foundation
import Observation

public enum ArchiveReason: String, Codable, Sendable {
    case closed, autoArchived, clearedToday, folderDeleted
}

/// Sink for tabs that leave the sidebar. Implemented by OpenStore's ArchiveStore.
/// Called on the main actor; implementations must not block (dispatch async internally).
@MainActor
public protocol ArchiveSink: AnyObject {
    func archive(tab: Tab, reason: ArchiveReason, originalLocation: String)
}

/// Structural change. Property changes use Observation and need no event.
public enum TreeChange: Sendable {
    case insert(parent: NodeParent, index: Int, nodeID: ItemID)
    case remove(parent: NodeParent, index: Int, nodeID: ItemID)
    case move(fromParent: NodeParent, fromIndex: Int, toParent: NodeParent, toIndex: Int, nodeID: ItemID)
    case reload(parent: NodeParent)
}

@MainActor
@Observable
public final class BrowserModel {
    public var profiles: [Profile]
    public var spaces: [Space]
    public var windows: [BrowserWindowState]
    public var routingRules: [RoutingRule]
    public var defaultDestination: DefaultDestination

    /// Injected services. Not persisted, not observed.
    @ObservationIgnored public var archiveSink: (any ArchiveSink)?
    @ObservationIgnored public var undoManager: UndoManager?

    // O(1) lookup. Rebuilt after structural mutations.
    @ObservationIgnored public private(set) var index: [ItemID: SidebarNode] = [:]
    @ObservationIgnored public private(set) var parentByID: [ItemID: NodeParent] = [:]

    @ObservationIgnored private var observers: [UUID: @MainActor (TreeChange) -> Void] = [:]
    @ObservationIgnored private var spaceByIDCache: [SpaceID: Space] = [:]
    @ObservationIgnored private var profileByIDCache: [ProfileID: Profile] = [:]

    public init(profiles: [Profile] = [], spaces: [Space] = [], windows: [BrowserWindowState] = [], routingRules: [RoutingRule] = [], defaultDestination: DefaultDestination = .mostRecentSpace) {
        self.profiles = profiles; self.spaces = spaces; self.windows = windows
        self.routingRules = routingRules; self.defaultDestination = defaultDestination
        rebuildIndex()
    }

    // MARK: Observers

    @discardableResult
    public func addObserver(_ handler: @MainActor @escaping (TreeChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ change: TreeChange) {
        for handler in observers.values { handler(change) }
    }

    // MARK: Lookup

    public func space(id: SpaceID) -> Space? { spaceByIDCache[id] }
    public func profile(id: ProfileID) -> Profile? { profileByIDCache[id] }
    public func node(id: ItemID) -> SidebarNode? { index[id] }
    public func tab(id: ItemID) -> Tab? { index[id]?.tab }
    public func parent(of id: ItemID) -> NodeParent? { parentByID[id] }

    public func rebuildIndex() {
        index.removeAll(); parentByID.removeAll()
        spaceByIDCache = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        profileByIDCache = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in profiles {
            for tab in profile.favorites {
                index[tab.id] = .tab(tab)
                parentByID[tab.id] = .favorites(profile.id)
            }
        }
        for space in spaces {
            for node in space.pinned { register(node: node, parent: .spacePinned(space.id)) }
            for node in space.today { register(node: node, parent: .spaceToday(space.id)) }
        }
    }

    private func register(node: SidebarNode, parent: NodeParent) {
        index[node.id] = node
        parentByID[node.id] = parent
        switch node {
        case .folder(let folder):
            for child in folder.children { register(node: child, parent: .folder(folder.id)) }
        case .split(let split):
            for pane in split.panes {
                index[pane.id] = .tab(pane)
                parentByID[pane.id] = .splitPane(split.id)
            }
        case .tab: break
        }
    }

    // MARK: Container access helpers

    private func children(of parent: NodeParent) -> [SidebarNode]? {
        switch parent {
        case .spacePinned(let sid): return space(id: sid)?.pinned
        case .spaceToday(let sid): return space(id: sid)?.today
        case .folder(let fid): return index[fid]?.folder?.children
        case .favorites(let pid):
            guard let p = profile(id: pid) else { return nil }
            return p.favorites.map { .tab($0) }
        case .splitPane: return nil
        }
    }

    @discardableResult
    private func setChildren(_ newChildren: [SidebarNode], of parent: NodeParent) -> Bool {
        switch parent {
        case .spacePinned(let sid):
            guard let s = space(id: sid) else { return false }
            s.pinned = newChildren; return true
        case .spaceToday(let sid):
            guard let s = space(id: sid) else { return false }
            s.today = newChildren; return true
        case .folder(let fid):
            guard let f = index[fid]?.folder else { return false }
            f.children = newChildren; return true
        case .favorites(let pid):
            guard let p = profile(id: pid) else { return false }
            p.favorites = newChildren.compactMap { $0.tab }
            return true
        case .splitPane: return false
        }
    }

    private func insertNode(_ node: SidebarNode, into parent: NodeParent, at insertIndex: Int) {
        var list = children(of: parent) ?? []
        let clamped = max(0, min(insertIndex, list.count))
        list.insert(node, at: clamped)
        setChildren(list, of: parent)
        rebuildIndex()
        emit(.insert(parent: parent, index: clamped, nodeID: node.id))
    }

    @discardableResult
    private func removeFromParent(id: ItemID) -> (node: SidebarNode, parent: NodeParent, index: Int)? {
        guard let parent = parentByID[id], var list = children(of: parent), let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        let node = list.remove(at: idx)
        setChildren(list, of: parent)
        // Note: caller decides whether to rebuild; emit remove here.
        return (node, parent, idx)
    }

    private func allTabs(under node: SidebarNode) -> [Tab] {
        switch node {
        case .tab(let t): return [t]
        case .folder(let f): return f.children.flatMap { allTabs(under: $0) }
        case .split(let s): return s.panes
        }
    }

    private func registerUndo(_ undo: @MainActor @escaping () -> Void, redo: @MainActor @escaping () -> Void) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                undo()
                target.registerUndo(redo, redo: undo)
            }
        }
    }

    // MARK: - Commands: tabs

    @discardableResult
    public func newTab(in spaceID: SpaceID, url: URL, title: String = "", at index: Int? = nil) -> Tab {
        let tab = Tab(url: url, title: title)
        let parent = NodeParent.spaceToday(spaceID)
        let idx = index ?? (children(of: parent)?.count ?? 0)
        insertNode(.tab(tab), into: parent, at: idx)
        registerUndo({ [weak self] in self?.removeNodeWithoutArchive(id: tab.id) },
                      redo: { [weak self] in self?.insertNode(.tab(tab), into: parent, at: idx) })
        return tab
    }

    /// Removes a node without archiving. Internal undo helper.
    public func removeNodeWithoutArchive(id: ItemID) {
        guard let removed = removeFromParent(id: id) else { return }
        rebuildIndex()
        emit(.remove(parent: removed.parent, index: removed.index, nodeID: id))
    }

    /// Closes (archives) a tab. Folders archive every tab inside. Splits remove the split.
    public func closeTab(id: ItemID) {
        guard let parent = parentByID[id], let node = index[id] else { return }
        // Split pane: remove just that pane from the split.
        if case .splitPane(let splitID) = parent, let split = index[splitID]?.split, let tab = node.tab {
            archiveSink?.archive(tab: tab, reason: .closed, originalLocation: describe(parent: parent))
            split.panes.removeAll(where: { $0.id == id })
            if split.panes.count < 2, let splitParent = parentByID[splitID], var list = children(of: splitParent), let si = list.firstIndex(where: { $0.id == splitID }) {
                // Collapse a split with <2 panes back to a lone tab (or remove it).
                if let remaining = split.panes.first {
                    list[si] = .tab(remaining)
                } else {
                    list.remove(at: si)
                }
                setChildren(list, of: splitParent)
            }
            rebuildIndex()
            emit(.reload(parent: parent))
            return
        }
        let tabs = allTabs(under: node)
        let location = describe(parent: parent)
        guard let removed = removeFromParent(id: id) else { return }
        rebuildIndex()
        emit(.remove(parent: removed.parent, index: removed.index, nodeID: id))
        for tab in tabs { archiveSink?.archive(tab: tab, reason: .closed, originalLocation: location) }
        let savedParent = removed.parent
        let savedIndex = removed.index
        let savedNode = node
        registerUndo({ [weak self] in self?.insertNode(savedNode, into: savedParent, at: savedIndex) },
                      redo: { [weak self] in self?.removeNodeWithoutArchive(id: id) })
    }

    private func describe(parent: NodeParent) -> String {
        switch parent {
        case .spacePinned(let s): return "pinned:\(s.rawValue.uuidString)"
        case .spaceToday(let s): return "today:\(s.rawValue.uuidString)"
        case .folder(let f): return "folder:\(f.rawValue.uuidString)"
        case .favorites(let p): return "favorites:\(p.rawValue.uuidString)"
        case .splitPane(let s): return "split:\(s.rawValue.uuidString)"
        }
    }

    public func pinTab(id: ItemID) {
        guard let tab = tab(id: id), let parent = parentByID[id] else { return }
        if case .spacePinned = parent { return }
        if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
        guard let spaceID = spaceID(for: parent) else { return }
        moveNode(id: id, to: .spacePinned(spaceID), at: nil)
    }

    public func unpinTab(id: ItemID) {
        guard let tab = tab(id: id), let parent = parentByID[id] else { return }
        guard case .spacePinned = parent else { return }
        guard let spaceID = spaceID(for: parent) else { return }
        tab.pinnedURL = nil
        moveNode(id: id, to: .spaceToday(spaceID), at: nil)
    }

    private func spaceID(for parent: NodeParent) -> SpaceID? {
        switch parent {
        case .spacePinned(let s), .spaceToday(let s): return s
        case .folder(let fid):
            guard let p = parentByID[fid] else { return nil }
            return spaceID(for: p)
        case .favorites(let pid):
            return spaces.first(where: { $0.profileID == pid })?.id
        case .splitPane(let sid):
            guard let p = parentByID[sid] else { return nil }
            return spaceID(for: p)
        }
    }

    public func addFavorite(tabID: ItemID, to profileID: ProfileID) {
        guard let source = tab(id: tabID) else { return }
        // Favorite is a copy that shares the pinned URL semantics.
        let copy = Tab(url: source.url, title: source.title, customTitle: source.customTitle,
                       pinnedURL: source.pinnedURL ?? source.url, customIcon: source.customIcon,
                       createdAt: source.createdAt, lastActiveAt: source.lastActiveAt, isMuted: source.isMuted)
        insertNode(.tab(copy), into: .favorites(profileID), at: children(of: .favorites(profileID))?.count ?? 0)
    }

    public func removeFavorite(tabID: ItemID) {
        guard let parent = parentByID[tabID], case .favorites = parent else { return }
        removeNodeWithoutArchive(id: tabID)
    }

    // MARK: move / rename / expand

    public func moveNode(id: ItemID, to destination: NodeParent, at destinationIndex: Int?) {
        guard index[id] != nil, let sourceParent = parentByID[id] else { return }
        // Cycle check: never move a folder into its own descendant.
        if case .folder(let destFolder) = destination {
            var cursor: NodeParent? = .folder(destFolder)
            while let c = cursor {
                if case .folder(let fid) = c, fid == id { return }
                cursor = parentByID[destFolder] == nil ? nil : nextParent(after: c)
                // Simple walk via parent chain of the destination folder.
                if case .folder(let fid) = c { cursor = parentByID[fid] } else { break }
            }
        }
        // Splits and split panes are not movable as plain nodes into folders directly; allow split node moves only.
        guard var sourceList = children(of: sourceParent), let fromIndex = sourceList.firstIndex(where: { $0.id == id }) else { return }
        let node = sourceList.remove(at: fromIndex)
        // Same-parent reorder: destination index counts after removal.
        if sourceParent == destination {
            let target = destinationIndex.map { max(0, min($0, sourceList.count)) } ?? sourceList.count
            sourceList.insert(node, at: target)
            setChildren(sourceList, of: sourceParent)
            rebuildIndex()
            emit(.move(fromParent: sourceParent, fromIndex: fromIndex, toParent: destination, toIndex: target, nodeID: id))
            registerUndo({ [weak self] in self?.moveNode(id: id, to: sourceParent, at: fromIndex) },
                          redo: { [weak self] in self?.moveNode(id: id, to: destination, at: target) })
            return
        }
        setChildren(sourceList, of: sourceParent)
        var destList = children(of: destination) ?? []
        let target = destinationIndex.map { max(0, min($0, destList.count)) } ?? destList.count
        destList.insert(node, at: target)
        setChildren(destList, of: destination)
        // Pinning semantics when crossing pinned/today boundary.
        if let tab = node.tab {
            if case .spacePinned = destination, tab.pinnedURL == nil { tab.pinnedURL = tab.url }
            if case .spaceToday = destination, case .spacePinned = sourceParent { tab.pinnedURL = nil }
        }
        rebuildIndex()
        emit(.move(fromParent: sourceParent, fromIndex: fromIndex, toParent: destination, toIndex: target, nodeID: id))
        registerUndo({ [weak self] in self?.moveNode(id: id, to: sourceParent, at: fromIndex) },
                      redo: { [weak self] in self?.moveNode(id: id, to: destination, at: target) })
    }

    private func nextParent(after parent: NodeParent) -> NodeParent? {
        if case .folder(let fid) = parent { return parentByID[fid] }
        return nil
    }

    @discardableResult
    public func createFolder(in parent: NodeParent, title: String = "Folder", withNodes nodeIDs: [ItemID] = []) -> Folder {
        let folder = Folder(title: title)
        // Move requested nodes into the folder first (they keep their objects).
        var moved: [SidebarNode] = []
        for nid in nodeIDs {
            if let removed = removeFromParent(id: nid) { moved.append(removed.node) }
        }
        folder.children = moved
        let idx = children(of: parent)?.count ?? 0
        insertNode(.folder(folder), into: parent, at: idx)
        // insertNode rebuilds, but children moved before insert need re-registration: rebuild covers it.
        registerUndo({ [weak self] in self?.removeNodeWithoutArchive(id: folder.id) },
                      redo: { [weak self] in self?.insertNode(.folder(folder), into: parent, at: idx) })
        return folder
    }

    public func renameNode(id: ItemID, title: String) {
        if let tab = tab(id: id) {
            let old = tab.customTitle
            tab.customTitle = title.isEmpty ? nil : title
            registerUndo({ tab.customTitle = old }, redo: { tab.customTitle = title.isEmpty ? nil : title })
        } else if let folder = index[id]?.folder {
            let old = folder.title
            folder.title = title
            registerUndo({ folder.title = old }, redo: { folder.title = title })
        }
    }

    public func setExpanded(folderID: ItemID, expanded: Bool) {
        guard let folder = index[folderID]?.folder else { return }
        let old = folder.isExpanded
        folder.isExpanded = expanded
        registerUndo({ folder.isExpanded = old }, redo: { folder.isExpanded = expanded })
    }

    // MARK: Spaces

    @discardableResult
    public func createSpace(title: String, profileID: ProfileID, icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme()) -> Space {
        let space = Space(title: title, icon: icon, theme: theme, profileID: profileID)
        spaces.append(space)
        rebuildIndex()
        emit(.reload(parent: .spaceToday(space.id)))
        registerUndo({ [weak self] in self?.deleteSpace(id: space.id, archiveTabs: false) },
                      redo: { [weak self] in self?.spaces.append(space); self?.rebuildIndex() })
        return space
    }

    public func updateSpace(id: SpaceID, title: String? = nil, icon: SpaceIcon?? = nil, theme: SpaceTheme? = nil, profileID: ProfileID? = nil) {
        guard let space = space(id: id) else { return }
        let oldTitle = space.title; let oldIcon = space.icon; let oldTheme = space.theme; let oldProfile = space.profileID
        if let title { space.title = title }
        if let icon { space.icon = icon }
        if let theme { space.theme = theme }
        if let profileID { space.profileID = profileID }
        registerUndo({
            space.title = oldTitle; space.icon = oldIcon; space.theme = oldTheme; space.profileID = oldProfile
        }, redo: {
            if let title { space.title = title }
            if let icon { space.icon = icon }
            if let theme { space.theme = theme }
            if let profileID { space.profileID = profileID }
        })
    }

    public func deleteSpace(id: SpaceID, archiveTabs: Bool = true) {
        guard let idx = spaces.firstIndex(where: { $0.id == id }) else { return }
        guard spaces.count > 1 else { return } // At least one Space always exists.
        let space = spaces[idx]
        if archiveTabs {
            for tab in space.pinned.flatMap({ allTabs(under: $0) }) + space.today.flatMap({ allTabs(under: $0) }) {
                archiveSink?.archive(tab: tab, reason: .closed, originalLocation: "space:\(id.rawValue.uuidString)")
            }
        }
        spaces.remove(at: idx)
        for window in windows where window.focusedSpaceID == id {
            window.focusedSpaceID = spaces[0].id
        }
        rebuildIndex()
        emit(.reload(parent: .spaceToday(id)))
    }

    public func moveSpace(id: SpaceID, to newIndex: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces.remove(at: from)
        let target = max(0, min(newIndex, spaces.count))
        spaces.insert(space, at: target)
        rebuildIndex()
        registerUndo({ [weak self] in self?.moveSpace(id: id, to: from) },
                      redo: { [weak self] in self?.moveSpace(id: id, to: target) })
    }

    // MARK: Splits

    @discardableResult
    public func makeSplit(tabIDs: [ItemID], orientation: SplitOrientation = .horizontal) -> Split? {
        let ids = Array(tabIDs.prefix(4))
        guard ids.count >= 2 else { return nil }
        // Take the parent/index of the first tab as the split's home.
        guard let firstParent = parentByID[ids[0]], let homeList = children(of: firstParent),
              let homeIndex = homeList.firstIndex(where: { $0.id == ids[0] }) else { return nil }
        var panes: [Tab] = []
        for tid in ids {
            if let tab = tab(id: tid) { panes.append(tab) }
        }
        guard panes.count >= 2 else { return nil }
        // Remove all pane tabs from their parents (collect first to avoid index shifts).
        for tid in ids { removeFromParent(id: tid) }
        let split = Split(orientation: orientation, panes: panes, focusedPaneID: panes.first?.id)
        insertNode(.split(split), into: firstParent, at: min(homeIndex, children(of: firstParent)?.count ?? 0))
        return split
    }

    public func unsplit(splitID: ItemID) {
        guard let split = index[splitID]?.split, let parent = parentByID[splitID] else { return }
        guard var list = children(of: parent), let idx = list.firstIndex(where: { $0.id == splitID }) else { return }
        list.remove(at: idx)
        for (offset, pane) in split.panes.enumerated() {
            list.insert(.tab(pane), at: idx + offset)
        }
        setChildren(list, of: parent)
        rebuildIndex()
        emit(.reload(parent: parent))
    }

    public func removePane(splitID: ItemID, tabID: ItemID, archive: Bool = false) {
        guard let split = index[splitID]?.split else { return }
        if let tab = split.panes.first(where: { $0.id == tabID }), archive {
            archiveSink?.archive(tab: tab, reason: .closed, originalLocation: "split:\(splitID.rawValue.uuidString)")
        }
        split.panes.removeAll(where: { $0.id == tabID })
        if split.focusedPaneID == tabID { split.focusedPaneID = split.panes.first?.id }
        if split.panes.count == 1 {
            unsplit(splitID: splitID)
        } else {
            rebuildIndex()
            if let parent = parentByID[splitID] { emit(.reload(parent: parent)) }
        }
    }

    // MARK: Pinned URL

    public func resetPinnedTab(id: ItemID) {
        guard let tab = tab(id: id), let pinned = tab.pinnedURL else { return }
        let old = tab.url
        tab.url = pinned
        tab.lastActiveAt = Date()
        registerUndo({ tab.url = old }, redo: { tab.url = pinned })
    }

    public func replacePinnedURL(id: ItemID) {
        guard let tab = tab(id: id) else { return }
        let old = tab.pinnedURL
        tab.pinnedURL = tab.url
        registerUndo({ tab.pinnedURL = old }, redo: { tab.pinnedURL = tab.url })
    }

    // MARK: Clear / auto-archive

    public func clearToday(space spaceID: SpaceID) {
        guard let space = space(id: spaceID) else { return }
        let tabs = space.today.flatMap { allTabs(under: $0) }
        let saved = space.today
        let parent = NodeParent.spaceToday(spaceID)
        space.today = []
        rebuildIndex()
        emit(.reload(parent: parent))
        for tab in tabs { archiveSink?.archive(tab: tab, reason: .clearedToday, originalLocation: describe(parent: parent)) }
        registerUndo({ [weak self] in space.today = saved; self?.rebuildIndex(); self?.emit(.reload(parent: parent)) },
                      redo: { [weak self] in space.today = []; self?.rebuildIndex(); self?.emit(.reload(parent: parent)) })
    }

    /// Archives expired today tabs. Pinned tabs and favorites never expire.
    /// Tabs inside folders in Today are treated as Today tabs and checked too.
    @discardableResult
    public func archiveExpiredTabs(now: Date) -> Int {
        var archived = 0
        for space in spaces {
            guard let profile = profile(id: space.profileID), let threshold = profile.settings.autoArchiveAfter.seconds else { continue }
            let cutoff = now.addingTimeInterval(-threshold)
            // Collect expired top-level nodes: a node expires only if every tab inside is expired;
            // for folders we archive expired child tabs individually.
            var newToday: [SidebarNode] = []
            for node in space.today {
                switch node {
                case .tab(let tab):
                    if tab.lastActiveAt < cutoff {
                        archiveSink?.archive(tab: tab, reason: .autoArchived, originalLocation: "today:\(space.id.rawValue.uuidString)")
                        archived += 1
                    } else { newToday.append(node) }
                case .split(let split):
                    let expired = split.panes.filter { $0.lastActiveAt < cutoff }
                    for tab in expired {
                        archiveSink?.archive(tab: tab, reason: .autoArchived, originalLocation: "today:\(space.id.rawValue.uuidString)")
                        archived += 1
                    }
                    split.panes.removeAll(where: { $0.lastActiveAt < cutoff })
                    if split.panes.count >= 2 { newToday.append(node) }
                    else if let remaining = split.panes.first { newToday.append(.tab(remaining)) }
                case .folder(let folder):
                    archiveExpired(in: folder, cutoff: cutoff, spaceID: space.id, count: &archived)
                    if !folder.children.isEmpty || true { newToday.append(node) }
                }
            }
            space.today = newToday
        }
        if archived > 0 {
            rebuildIndex()
            for space in spaces { emit(.reload(parent: .spaceToday(space.id))) }
        }
        return archived
    }

    private func archiveExpired(in folder: Folder, cutoff: Date, spaceID: SpaceID, count: inout Int) {
        var kept: [SidebarNode] = []
        for child in folder.children {
            switch child {
            case .tab(let tab):
                if tab.lastActiveAt < cutoff {
                    archiveSink?.archive(tab: tab, reason: .autoArchived, originalLocation: "today:\(spaceID.rawValue.uuidString)")
                    count += 1
                } else { kept.append(child) }
            case .folder(let sub):
                archiveExpired(in: sub, cutoff: cutoff, spaceID: spaceID, count: &count)
                kept.append(child)
            case .split(let split):
                let expired = split.panes.filter { $0.lastActiveAt < cutoff }
                for tab in expired {
                    archiveSink?.archive(tab: tab, reason: .autoArchived, originalLocation: "today:\(spaceID.rawValue.uuidString)")
                    count += 1
                }
                split.panes.removeAll(where: { $0.lastActiveAt < cutoff })
                if split.panes.count >= 2 { kept.append(child) }
                else if let remaining = split.panes.first { kept.append(.tab(remaining)) }
            }
        }
        folder.children = kept
    }

    // MARK: Focus / selection

    public func focusSpace(windowID: WindowID, spaceID: SpaceID) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        let old = window.focusedSpaceID
        window.focusedSpaceID = spaceID
        registerUndo({ window.focusedSpaceID = old }, redo: { window.focusedSpaceID = spaceID })
    }

    public func selectNode(windowID: WindowID, spaceID: SpaceID, nodeID: ItemID?) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        let old = window.selectedNodeBySpace[spaceID]
        window.selectedNodeBySpace[spaceID] = nodeID
        if let nodeID, let tab = tab(id: nodeID) {
            tab.lastActiveAt = Date()
            tab.isUnread = false
        }
        registerUndo({ window.selectedNodeBySpace[spaceID] = old },
                      redo: { window.selectedNodeBySpace[spaceID] = nodeID })
    }
}
