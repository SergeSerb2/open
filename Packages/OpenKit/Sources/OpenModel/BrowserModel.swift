import Foundation
import Observation

public enum ArchiveReason: String, Codable, Sendable {
    case closed, autoArchived, clearedToday, folderDeleted
}

/// One tab that leaves the sidebar for the archive.
public struct ArchiveEntry: Sendable {
    public let tab: Tab
    public let reason: ArchiveReason
    /// The tab's direct parent when it left, in `NodeParent.archiveLocation` form.
    public let originalLocation: String
    public let spaceID: SpaceID?
    public let profileID: ProfileID?
    public let archivedAt: Date

    public init(tab: Tab, reason: ArchiveReason, originalLocation: String, spaceID: SpaceID?, profileID: ProfileID?, archivedAt: Date) {
        self.tab = tab; self.reason = reason; self.originalLocation = originalLocation
        self.spaceID = spaceID; self.profileID = profileID; self.archivedAt = archivedAt
    }
}

/// One stored archive row. Defined in OpenModel so `BrowserModel` can restore it
/// without depending on OpenStore. OpenStore's ArchiveStore produces these.
public struct ArchivedTabRecord: Sendable, Identifiable {
    public var id: ItemID
    public var url: URL
    public var title: String
    public var spaceID: SpaceID?
    public var profileID: ProfileID?
    public var archivedAt: Date
    public var reason: ArchiveReason
    public var originalLocation: String
    /// The tab JSON that ArchiveStore writes (OpenStore's `TabDTO`).
    public var payloadJSON: String

    public init(id: ItemID, url: URL, title: String, spaceID: SpaceID? = nil, profileID: ProfileID? = nil, archivedAt: Date, reason: ArchiveReason, originalLocation: String, payloadJSON: String) {
        self.id = id; self.url = url; self.title = title
        self.spaceID = spaceID; self.profileID = profileID
        self.archivedAt = archivedAt; self.reason = reason
        self.originalLocation = originalLocation; self.payloadJSON = payloadJSON
    }
}

/// Sink for tabs that leave the sidebar. Implemented by OpenStore's ArchiveStore.
/// Called on the main actor; implementations must not block (dispatch async internally).
@MainActor
public protocol ArchiveSink: AnyObject {
    /// Stores tabs that left the sidebar. A bulk command passes all of its tabs in one call.
    func archive(_ entries: [ArchiveEntry])
    /// Drops the rows of tabs that are back in the sidebar (restore, or undo of a close),
    /// so a tab is never in the sidebar and the archive at once.
    func discardArchived(ids: [ItemID])
}

extension NodeParent {
    /// Text form stored as an archive record's `originalLocation`:
    /// `pinned:`, `today:`, `folder:`, `favorites:`, or `split:` followed by the UUID.
    public var archiveLocation: String {
        switch self {
        case .spacePinned(let id): return "pinned:\(id)"
        case .spaceToday(let id): return "today:\(id)"
        case .folder(let id): return "folder:\(id)"
        case .favorites(let id): return "favorites:\(id)"
        case .splitPane(let id): return "split:\(id)"
        }
    }

    public init?(archiveLocation: String) {
        let parts = archiveLocation.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "pinned": self = .spacePinned(SpaceID(rawValue: uuid))
        case "today": self = .spaceToday(SpaceID(rawValue: uuid))
        case "folder": self = .folder(ItemID(rawValue: uuid))
        case "favorites": self = .favorites(ProfileID(rawValue: uuid))
        case "split": self = .splitPane(ItemID(rawValue: uuid))
        default: return nil
        }
    }
}

/// Structural change. Property changes use Observation and need no event.
public enum TreeChange: Sendable {
    case insert(parent: NodeParent, index: Int, nodeID: ItemID)
    case remove(parent: NodeParent, index: Int, nodeID: ItemID)
    case move(fromParent: NodeParent, fromIndex: Int, toParent: NodeParent, toIndex: Int, nodeID: ItemID)
    case reload(parent: NodeParent)
    case spaceProfileChanged(spaceID: SpaceID, from: ProfileID, to: ProfileID)
}

public enum ProfileNameIssue: String, Sendable, Equatable {
    case empty, tooLong, invalidCharacters, duplicate
}

public enum ProfileDeleteBlock: Sendable, Equatable {
    case isDefault
    case spacesAssigned(count: Int)
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

    /// Invalidates derived tab ownership after structural edits or a full import/load.
    @ObservationIgnored public private(set) var treeRevision: UInt64 = 0

    // O(1) lookup. Every command updates both maps in place, in O(size of the changed subtree).
    // rebuildIndex() walks the whole tree and runs only on load and import.
    @ObservationIgnored public private(set) var index: [ItemID: SidebarNode] = [:]
    @ObservationIgnored public private(set) var parentByID: [ItemID: NodeParent] = [:]

    @ObservationIgnored private var observers: [UUID: @MainActor (TreeChange) -> Void] = [:]
    @ObservationIgnored private var spaceByIDCache: [SpaceID: Space] = [:]
    @ObservationIgnored private var profileByIDCache: [ProfileID: Profile] = [:]

    /// Undoes one change and returns true, or returns false and changes nothing when its
    /// nodes are gone. Gets the model from the undo manager, so it captures no `self`.
    private typealias Revert = @MainActor (BrowserModel) -> Bool
    private static let noRevert: Revert = { _ in false }
    private typealias PinnedURLs = [(tab: Tab, url: URL?)]

    public init(profiles: [Profile] = [], spaces: [Space] = [], windows: [BrowserWindowState] = [], routingRules: [RoutingRule] = [], defaultDestination: DefaultDestination = .littleOpen) {
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
        treeRevision &+= 1
        for handler in observers.values { handler(change) }
    }

    // MARK: Lookup

    public func space(id: SpaceID) -> Space? { spaceByIDCache[id] }
    public func profile(id: ProfileID) -> Profile? { profileByIDCache[id] }
    public func node(id: ItemID) -> SidebarNode? { index[id] }
    public func tab(id: ItemID) -> Tab? { index[id]?.tab }
    public func parent(of id: ItemID) -> NodeParent? { parentByID[id] }

    /// True when the tab's ancestor chain reaches a Space's pinned section,
    /// including tabs inside folders and splits there.
    public func isPinned(tabID: ItemID) -> Bool {
        guard let parent = parentByID[tabID], case .spacePinned? = section(of: parent) else { return false }
        return true
    }

    /// Full rebuild from `profiles` and `spaces`. For load and import only.
    public func rebuildIndex() {
        treeRevision &+= 1
        index.removeAll(); parentByID.removeAll()
        spaceByIDCache = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        profileByIDCache = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in profiles {
            for tab in profile.favorites { register(.tab(tab), under: .favorites(profile.id)) }
        }
        for space in spaces {
            for node in space.pinned { register(node, under: .spacePinned(space.id)) }
            for node in space.today { register(node, under: .spaceToday(space.id)) }
        }
    }

    private func register(_ node: SidebarNode, under parent: NodeParent) {
        index[node.id] = node
        parentByID[node.id] = parent
        switch node {
        case .tab: break
        case .folder(let folder):
            for child in folder.children { register(child, under: .folder(folder.id)) }
        case .split(let split):
            for pane in split.panes { register(.tab(pane), under: .splitPane(split.id)) }
        }
    }

    private func unregister(_ node: SidebarNode) {
        index[node.id] = nil
        parentByID[node.id] = nil
        switch node {
        case .tab: break
        case .folder(let folder):
            for child in folder.children { unregister(child) }
        case .split(let split):
            for pane in split.panes { unregister(.tab(pane)) }
        }
    }

    // MARK: Sections and the pinned-URL rule

    /// The section that holds `parent`: `.spacePinned`, `.spaceToday`, or `.favorites`.
    /// Walks up through folders and splits. O(depth).
    private func section(of parent: NodeParent) -> NodeParent? {
        var cursor = parent
        while true {
            switch cursor {
            case .spacePinned, .spaceToday, .favorites: return cursor
            case .folder(let id), .splitPane(let id):
                guard let up = parentByID[id] else { return nil }
                cursor = up
            }
        }
    }

    /// Pinned and Favorites tabs keep a pinned URL. Today tabs do not.
    private func keepsPinnedURL(_ section: NodeParent?) -> Bool {
        switch section {
        case .spacePinned?, .favorites?: return true
        default: return false
        }
    }

    /// Applies the pinned-URL rule to every tab under `node` for a move between sections.
    /// Into Pinned or Favorites: a nil `pinnedURL` becomes the current URL.
    /// Into Today from Pinned or Favorites: `pinnedURL` clears.
    /// Returns the prior values for undo, or [] when the rule cannot change anything.
    private func applyPinnedRule(to node: SidebarNode, from source: NodeParent?, to destination: NodeParent?) -> PinnedURLs {
        let keptBefore = keepsPinnedURL(source)
        let keepsAfter = keepsPinnedURL(destination)
        guard keptBefore || keepsAfter else { return [] }
        let affected = tabs(under: node)
        let prior = affected.map { (tab: $0, url: $0.pinnedURL) }
        for tab in affected {
            if keepsAfter {
                if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
            } else if tab.pinnedURL != nil {
                tab.pinnedURL = nil
            }
        }
        return prior
    }

    private static func restore(_ prior: PinnedURLs) {
        for entry in prior { entry.tab.pinnedURL = entry.url }
    }

    /// The Space and profile that own a parent. Favorites belong to a profile only.
    private func owner(of parent: NodeParent) -> (space: SpaceID?, profile: ProfileID?) {
        switch section(of: parent) {
        case .spacePinned(let s)?, .spaceToday(let s)?: return (s, space(id: s)?.profileID)
        case .favorites(let p)?: return (nil, p)
        default: return (nil, nil)
        }
    }

    /// The Space a favorite of `profileID` goes to when it leaves Favorites: the focused Space
    /// of the first window that shows that profile, else the profile's first Space, else the
    /// first window's focused Space, else the first Space.
    private func targetSpace(forProfile profileID: ProfileID?) -> SpaceID? {
        if let profileID {
            for window in windows {
                if let focused = space(id: window.focusedSpaceID), focused.profileID == profileID { return focused.id }
            }
            if let first = spaces.first(where: { $0.profileID == profileID }) { return first.id }
        }
        if let window = windows.first, space(id: window.focusedSpaceID) != nil { return window.focusedSpaceID }
        return spaces.first?.id
    }

    private func parentExists(_ parent: NodeParent) -> Bool {
        switch parent {
        case .spacePinned(let s), .spaceToday(let s): return space(id: s) != nil
        case .folder(let id): return index[id]?.folder != nil
        case .favorites(let p): return profile(id: p) != nil
        case .splitPane(let id): return index[id]?.split != nil
        }
    }

    private func tabs(under node: SidebarNode) -> [Tab] {
        switch node {
        case .tab(let t): return [t]
        case .folder(let f): return f.children.flatMap { tabs(under: $0) }
        case .split(let s): return s.panes
        }
    }

    // MARK: Child lists (in place, no index, no events)

    /// Runs `body` on the node list of a Space section or folder, in place.
    /// Nil when the container is missing, and for Favorites and splits, which hold tabs only.
    private func withNodeList<R>(_ parent: NodeParent, _ body: (inout [SidebarNode]) -> R?) -> R? {
        switch parent {
        case .spacePinned(let id):
            guard let space = space(id: id) else { return nil }
            return body(&space.pinned)
        case .spaceToday(let id):
            guard let space = space(id: id) else { return nil }
            return body(&space.today)
        case .folder(let id):
            guard let folder = index[id]?.folder else { return nil }
            return body(&folder.children)
        case .favorites, .splitPane:
            return nil
        }
    }

    /// Runs `body` on the tab list of Favorites or a split, in place.
    private func withTabList<R>(_ parent: NodeParent, _ body: (inout [Tab]) -> R?) -> R? {
        switch parent {
        case .favorites(let id):
            guard let profile = profile(id: id) else { return nil }
            return body(&profile.favorites)
        case .splitPane(let id):
            guard let split = index[id]?.split else { return nil }
            return body(&split.panes)
        case .spacePinned, .spaceToday, .folder:
            return nil
        }
    }

    /// Inserts at `position` (clamped; nil appends). Returns the final index, or nil when
    /// the parent is missing or cannot hold the node.
    private func insertChild(_ node: SidebarNode, into parent: NodeParent, at position: Int?) -> Int? {
        func put<T>(_ element: T, _ list: inout [T]) -> Int {
            let i = position.map { max(0, min($0, list.count)) } ?? list.count
            list.insert(element, at: i)
            return i
        }
        switch parent {
        case .favorites, .splitPane:
            guard let tab = node.tab else { return nil }
            return withTabList(parent) { put(tab, &$0) }
        case .spacePinned, .spaceToday, .folder:
            return withNodeList(parent) { put(node, &$0) }
        }
    }

    private func removeChild(_ id: ItemID, from parent: NodeParent) -> (node: SidebarNode, index: Int)? {
        switch parent {
        case .favorites, .splitPane:
            return withTabList(parent) { list in
                list.firstIndex(where: { $0.id == id }).map { (node: SidebarNode.tab(list.remove(at: $0)), index: $0) }
            }
        case .spacePinned, .spaceToday, .folder:
            return withNodeList(parent) { list in
                list.firstIndex(where: { $0.id == id }).map { (node: list.remove(at: $0), index: $0) }
            }
        }
    }

    /// Swaps the node `id` for `node` in a Space section or folder. Collapses a split to a lone tab and back.
    @discardableResult
    private func replaceChild(_ id: ItemID, in parent: NodeParent, with node: SidebarNode) -> Int? {
        withNodeList(parent) { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
            list[i] = node
            return i
        }
    }

    /// Read-only position lookup. Reads never go through the in-place helpers,
    /// which would report a mutation to observers.
    private func position(of id: ItemID, in parent: NodeParent) -> Int? {
        switch parent {
        case .spacePinned(let s): return space(id: s)?.pinned.firstIndex { $0.id == id }
        case .spaceToday(let s): return space(id: s)?.today.firstIndex { $0.id == id }
        case .folder(let f): return index[f]?.folder?.children.firstIndex { $0.id == id }
        case .favorites(let p): return profile(id: p)?.favorites.firstIndex { $0.id == id }
        case .splitPane(let s): return index[s]?.split?.panes.firstIndex { $0.id == id }
        }
    }

    // MARK: Primitives (index upkeep and events, no validation, no undo)

    /// Inserts a node and indexes its subtree. Emits `.insert`.
    /// Refuses a node that is already in the tree, so a stale undo step cannot duplicate it.
    @discardableResult
    private func attach(_ node: SidebarNode, to parent: NodeParent, at position: Int?) -> Int? {
        guard index[node.id] == nil, let i = insertChild(node, into: parent, at: position) else { return nil }
        register(node, under: parent)
        emit(.insert(parent: parent, index: i, nodeID: node.id))
        return i
    }

    /// Removes a node and drops its subtree from the index. Emits `.remove`.
    @discardableResult
    private func detach(_ id: ItemID) -> (node: SidebarNode, parent: NodeParent, index: Int)? {
        guard let parent = parentByID[id], let removed = removeChild(id, from: parent) else { return nil }
        unregister(removed.node)
        emit(.remove(parent: parent, index: removed.index, nodeID: id))
        return (removed.node, parent, removed.index)
    }

    /// Moves a node. The index changes in O(1): only the node's own parent entry moves.
    /// Applies the pinned-URL rule and emits `.move`. Returns the closure that moves it back.
    private func relocate(_ id: ItemID, to destination: NodeParent, at position: Int?) -> Revert? {
        guard let source = parentByID[id] else { return nil }
        let fromSection = section(of: source)
        let toSection = section(of: destination)
        guard let removed = removeChild(id, from: source) else { return nil }
        guard let toIndex = insertChild(removed.node, into: destination, at: position) else {
            _ = insertChild(removed.node, into: source, at: removed.index)
            return nil
        }
        parentByID[id] = destination
        let prior = applyPinnedRule(to: removed.node, from: fromSection, to: toSection)
        emit(.move(fromParent: source, fromIndex: removed.index, toParent: destination, toIndex: toIndex, nodeID: id))
        let fromIndex = removed.index
        return { model in
            guard model.relocate(id, to: source, at: fromIndex) != nil else { return false }
            Self.restore(prior)
            return true
        }
    }

    /// One archive entry per tab under `node`, each with the tab's direct parent.
    private func archiveEntries(for node: SidebarNode, in parent: NodeParent, reason: ArchiveReason, at date: Date = Date()) -> [ArchiveEntry] {
        let owning = owner(of: parent)
        var entries: [ArchiveEntry] = []
        func collect(_ node: SidebarNode, _ parent: NodeParent) {
            switch node {
            case .tab(let tab):
                entries.append(ArchiveEntry(tab: tab, reason: reason, originalLocation: parent.archiveLocation, spaceID: owning.space, profileID: owning.profile, archivedAt: date))
            case .folder(let folder):
                for child in folder.children { collect(child, .folder(folder.id)) }
            case .split(let split):
                for pane in split.panes { collect(.tab(pane), .splitPane(split.id)) }
            }
        }
        collect(node, parent)
        return entries
    }

    private func archive(_ entries: [ArchiveEntry]) {
        guard !entries.isEmpty else { return }
        archiveSink?.archive(entries)
    }

    // MARK: Undo

    /// Registers one undo step. `revert` undoes the change just made. `reapply` redoes the
    /// change and returns its new revert, so redo never replays stale state. Neither closure
    /// may register undo itself: both call primitives only.
    /// Undo runs in stack order, so a revert normally finds the state its command left.
    /// The one exception is `archiveExpiredTabs`, which has no undo and can remove Today tabs
    /// and dissolve Today splits underneath older steps. Every revert therefore checks that
    /// its nodes are still where it expects. A revert that finds nothing to undo registers
    /// no redo, so redo can never bring back a tab that auto-archive took.
    private func registerUndo(_ revert: @escaping Revert, reapply: @escaping @MainActor (BrowserModel) -> Revert) {
        recordUndo { model in
            guard revert(model) else { return }
            model.recordUndo { model in model.registerUndo(reapply(model), reapply: reapply) }
        }
    }

    /// Undo for a plain property change.
    private func registerChange(undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        registerUndo({ _ in undo(); return true }, reapply: { _ in redo(); return { _ in undo(); return true } })
    }

    private func recordUndo(_ handler: @escaping @MainActor (BrowserModel) -> Void) {
        guard let um = undoManager else { return }
        // Each command registers one action. Grouping follows the undo manager: with
        // per-event grouping (the AppKit default) every command of one event forms one step,
        // so a drag of three tabs undoes at once. Without it (CLI, callers off the event
        // loop) registering outside a group is an error, so the model opens one per command.
        let group = !um.groupsByEvent && um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        if group { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { handler(model) }
        }
        if group { um.endUndoGrouping() }
    }

    // MARK: - Commands: tabs

    @discardableResult
    public func newTab(in spaceID: SpaceID, url: URL, title: String = "", at position: Int? = nil) -> Tab {
        let tab = Tab(url: url, title: title)
        let parent = NodeParent.spaceToday(spaceID)
        guard let i = attach(.tab(tab), to: parent, at: position) else { return tab }
        let revert: Revert = { $0.detach(tab.id) != nil }
        registerUndo(revert, reapply: { model in
            model.attach(.tab(tab), to: parent, at: i) != nil ? revert : Self.noRevert
        })
        return tab
    }

    /// Closes (archives) a node. A folder archives every tab inside it. A split pane leaves
    /// its split; a split left with one pane collapses to a lone tab. Undo puts everything
    /// back and drops the archive rows.
    public func closeTab(id: ItemID) {
        guard let parent = parentByID[id] else { return }
        if case .splitPane(let splitID) = parent {
            guard let revert = closePane(id, of: splitID) else { return }
            registerUndo(revert, reapply: { $0.closePane(id, of: splitID) ?? Self.noRevert })
            return
        }
        guard let revert = closeNode(id) else { return }
        registerUndo(revert, reapply: { $0.closeNode(id) ?? Self.noRevert })
    }

    private func closeNode(_ id: ItemID) -> Revert? {
        guard let node = index[id], let parent = parentByID[id] else { return nil }
        let entries = archiveEntries(for: node, in: parent, reason: node.folder != nil ? .folderDeleted : .closed)
        guard let removed = detach(id) else { return nil }
        archive(entries)
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.attach(removed.node, to: removed.parent, at: removed.index) != nil else { return false }
            model.archiveSink?.discardArchived(ids: ids)
            return true
        }
    }

    private func closePane(_ tabID: ItemID, of splitID: ItemID) -> Revert? {
        guard parentByID[tabID] == .splitPane(splitID), let tab = tab(id: tabID), let split = index[splitID]?.split else { return nil }
        let entries = archiveEntries(for: .tab(tab), in: .splitPane(splitID), reason: .closed)
        guard let restorePane = takePane(tabID, from: split) else { return nil }
        archive(entries)
        return { model in
            guard restorePane(model) else { return false }
            model.archiveSink?.discardArchived(ids: [tabID])
            return true
        }
    }

    public func pinTab(id: ItemID) {
        guard let parent = parentByID[id] else { return }
        switch section(of: parent) {
        case .spaceToday(let s)?:
            moveNode(id: id, to: .spacePinned(s), at: nil)
        case .favorites(let p)?:
            if let s = targetSpace(forProfile: p) { moveNode(id: id, to: .spacePinned(s), at: nil) }
        default:
            return
        }
    }

    public func unpinTab(id: ItemID) {
        guard let parent = parentByID[id], case .spacePinned(let s)? = section(of: parent) else { return }
        moveNode(id: id, to: .spaceToday(s), at: nil)
    }

    /// Moves a tab (same ID, same object) into a profile's Favorites. A nil `pinnedURL`
    /// becomes the current URL. Emits one `.move`. Folders, splits, and split panes are rejected.
    @discardableResult
    public func addFavorite(tabID: ItemID, to profileID: ProfileID, at position: Int? = nil) -> Bool {
        guard index[tabID]?.tab != nil else { return false }
        if position == nil, parentByID[tabID] == .favorites(profileID) { return false }
        return moveNode(id: tabID, to: .favorites(profileID), at: position)
    }

    /// Moves a favorite to the top of a Space's Today section, which clears its `pinnedURL`.
    /// Default Space: the focused Space of the first window that shows the favorite's profile.
    @discardableResult
    public func removeFavorite(tabID: ItemID, into spaceID: SpaceID? = nil) -> Bool {
        guard case .favorites(let profileID)? = parentByID[tabID],
              let target = spaceID ?? targetSpace(forProfile: profileID) else { return false }
        return moveNode(id: tabID, to: .spaceToday(target), at: 0)
    }

    // MARK: Restore from archive

    /// Puts an archived tab back with its original ID. Destination, in order:
    /// 1. the original parent, if it still exists (at the top; a split only while it has fewer than 4 panes),
    /// 2. the top of the original Space's Today section,
    /// 3. the top of the focused Space's Today section.
    /// The tab gets `lastActiveAt = now`, so auto-archive does not take it again at once.
    /// The pinned-URL rule applies for the destination. Undo sends the tab back to the archive.
    /// A tab whose ID is already in the sidebar comes back unchanged. With no Space at all,
    /// the tab is returned but not placed.
    @discardableResult
    public func restoreArchivedTab(_ record: ArchivedTabRecord) -> Tab {
        if let existing = tab(id: record.id) { return existing }
        let tab = Self.tab(from: record)
        tab.lastActiveAt = Date()
        guard let destination = restoreDestination(for: record),
              let revert = place(restored: tab, from: record, into: destination) else { return tab }
        registerUndo(revert, reapply: { $0.place(restored: tab, from: record, into: destination) ?? Self.noRevert })
        return tab
    }

    private func restoreDestination(for record: ArchivedTabRecord) -> NodeParent? {
        let original = NodeParent(archiveLocation: record.originalLocation)
        if let original, parentExists(original) {
            if case .splitPane(let id) = original {
                if let split = index[id]?.split, split.panes.count < 4 { return original }
            } else {
                return original
            }
        }
        var spaceID = record.spaceID
        if spaceID == nil, let original {
            switch original {
            case .spacePinned(let s), .spaceToday(let s): spaceID = s
            default: break
            }
        }
        if let spaceID, space(id: spaceID) != nil { return .spaceToday(spaceID) }
        return targetSpace(forProfile: record.profileID).map { .spaceToday($0) }
    }

    private func place(restored tab: Tab, from record: ArchivedTabRecord, into parent: NodeParent) -> Revert? {
        let priorPinnedURL = tab.pinnedURL
        if keepsPinnedURL(section(of: parent)) {
            if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
        } else {
            tab.pinnedURL = nil
        }
        let position: Int?
        if case .splitPane = parent { position = nil } else { position = 0 }
        guard attach(.tab(tab), to: parent, at: position) != nil else {
            tab.pinnedURL = priorPinnedURL
            return nil
        }
        archiveSink?.discardArchived(ids: [tab.id])
        return { model in
            guard model.detach(tab.id) != nil else { return false }
            tab.pinnedURL = priorPinnedURL
            model.archive([ArchiveEntry(tab: tab, reason: record.reason, originalLocation: record.originalLocation,
                                        spaceID: record.spaceID, profileID: record.profileID, archivedAt: record.archivedAt)])
            return true
        }
    }

    /// Keys of the payload JSON (OpenStore's `TabDTO`). All optional, so a partial payload still restores.
    private struct ArchivedTabPayload: Decodable {
        var url: String?
        var title: String?
        var customTitle: String?
        var pinnedURL: String?
        var customIcon: String?
        var createdAt: Double?
        var lastActiveAt: Double?
        var isMuted: Bool?
        var openerID: String?
        var isUnread: Bool?
    }

    /// Rebuilds a tab from a record. Missing payload fields fall back to the record's columns.
    private static func tab(from record: ArchivedTabRecord) -> Tab {
        let payload = record.payloadJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(ArchivedTabPayload.self, from: $0) }
        return Tab(id: record.id,
                   url: payload?.url.flatMap { URL(string: $0) } ?? record.url,
                   title: payload?.title ?? record.title,
                   customTitle: payload?.customTitle,
                   pinnedURL: payload?.pinnedURL.flatMap { URL(string: $0) },
                   customIcon: payload?.customIcon,
                   createdAt: payload?.createdAt.map { Date(timeIntervalSince1970: $0) } ?? record.archivedAt,
                   lastActiveAt: payload?.lastActiveAt.map { Date(timeIntervalSince1970: $0) } ?? record.archivedAt,
                   isMuted: payload?.isMuted ?? false,
                   openerID: payload?.openerID.flatMap { UUID(uuidString: $0) }.map { ItemID(rawValue: $0) },
                   isUnread: payload?.isUnread ?? false)
    }

    // MARK: move / folders / rename / expand

    /// Moves a node. In a same-parent reorder, `position` counts after the node's removal.
    /// Returns false, with no change and no event, when the move breaks a placement rule.
    @discardableResult
    public func moveNode(id: ItemID, to destination: NodeParent, at position: Int?) -> Bool {
        guard let revert = move(id, to: destination, at: position) else { return false }
        registerUndo(revert, reapply: { $0.move(id, to: destination, at: position) ?? Self.noRevert })
        return true
    }

    private func move(_ id: ItemID, to destination: NodeParent, at position: Int?) -> Revert? {
        guard canMove(id, to: destination) else { return nil }
        return relocate(id, to: destination, at: position)
    }

    /// Placement rules: only tabs enter Favorites (folders and splits never do); splits live
    /// in a Space's pinned or Today section or in a folder; panes move only through split
    /// commands; a folder never enters itself or its own descendant.
    private func canMove(_ id: ItemID, to destination: NodeParent) -> Bool {
        guard let node = index[id], let source = parentByID[id] else { return false }
        if case .splitPane = source { return false }
        switch destination {
        case .splitPane:
            return false
        case .favorites(let p):
            return node.tab != nil && profile(id: p) != nil
        case .spacePinned(let s), .spaceToday(let s):
            return space(id: s) != nil
        case .folder(let folderID):
            guard index[folderID]?.folder != nil else { return false }
            var cursor: ItemID? = folderID
            while let current = cursor {
                if current == id { return false }
                if case .folder(let up)? = parentByID[current] { cursor = up } else { cursor = nil }
            }
            return true
        }
    }

    /// Creates a folder at the end of `parent` and moves `nodeIDs` into it, in order.
    /// Nodes that may not move there are skipped. Nil when `parent` cannot hold a folder.
    @discardableResult
    public func createFolder(in parent: NodeParent, title: String = "Folder", withNodes nodeIDs: [ItemID] = []) -> Folder? {
        switch parent {
        case .favorites, .splitPane: return nil
        case .spacePinned, .spaceToday, .folder: break
        }
        let folder = Folder(title: title)
        guard let revert = fill(folder, in: parent, with: nodeIDs) else { return nil }
        registerUndo(revert, reapply: { $0.fill(folder, in: parent, with: nodeIDs) ?? Self.noRevert })
        return folder
    }

    private func fill(_ folder: Folder, in parent: NodeParent, with nodeIDs: [ItemID]) -> Revert? {
        guard attach(.folder(folder), to: parent, at: nil) != nil else { return nil }
        var moves: [Revert] = []
        for id in nodeIDs where canMove(id, to: .folder(folder.id)) {
            if let revert = relocate(id, to: .folder(folder.id), at: nil) { moves.append(revert) }
        }
        let reverts = moves
        return { model in
            for revert in reverts.reversed() { _ = revert(model) }
            return model.detach(folder.id) != nil
        }
    }

    public func renameNode(id: ItemID, title: String) {
        if let tab = tab(id: id) {
            let old = tab.customTitle
            let new = title.isEmpty ? nil : title
            tab.customTitle = new
            registerChange(undo: { tab.customTitle = old }, redo: { tab.customTitle = new })
        } else if let folder = index[id]?.folder {
            let old = folder.title
            folder.title = title
            registerChange(undo: { folder.title = old }, redo: { folder.title = title })
        }
    }

    public func setExpanded(folderID: ItemID, expanded: Bool) {
        guard let folder = index[folderID]?.folder else { return }
        let old = folder.isExpanded
        folder.isExpanded = expanded
        registerChange(undo: { folder.isExpanded = old }, redo: { folder.isExpanded = expanded })
    }

    // MARK: Profiles

    public static func profileNameIssue(_ raw: String, in profiles: [Profile], excluding excludedID: ProfileID? = nil) -> ProfileNameIssue? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.count > 64 { return .tooLong }
        if name == "." || name == ".." || name.contains(where: { "/:\\".contains($0) })
            || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return .invalidCharacters }
        if profiles.contains(where: { $0.id != excludedID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }) { return .duplicate }
        return nil
    }

    public var defaultProfile: Profile? { profiles.first { $0.dataDirectoryName == "Default" } ?? profiles.first }

    public func spaces(using profileID: ProfileID) -> [Space] { spaces.filter { $0.profileID == profileID } }

    public func deleteBlockReason(for id: ProfileID) -> ProfileDeleteBlock? {
        guard profile(id: id) != nil else { return nil }
        if id == defaultProfile?.id { return .isDefault }
        let count = spaces(using: id).count
        return count > 0 ? .spacesAssigned(count: count) : nil
    }

    @discardableResult
    public func createProfile(name: String, icon: SpaceIcon? = nil, settings: ProfileSettings = ProfileSettings()) -> Profile? {
        guard Self.profileNameIssue(name, in: profiles) == nil else { return nil }
        var directory = "Default"
        if !profiles.isEmpty {
            repeat { directory = "Profile-" + UUID().uuidString.prefix(8).uppercased() }
            while profiles.contains { $0.dataDirectoryName.caseInsensitiveCompare(directory) == .orderedSame }
        }
        let profile = Profile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon, settings: settings, dataDirectoryName: directory)
        let slot = profiles.count
        insertProfile(profile, at: slot)
        registerUndo({ model in model.removeProfile(profile.id); return true }, reapply: { model in
            model.insertProfile(profile, at: slot)
            return { model in model.removeProfile(profile.id); return true }
        })
        return profile
    }

    private func insertProfile(_ profile: Profile, at slot: Int) {
        profiles.insert(profile, at: min(slot, profiles.count))
        profileByIDCache[profile.id] = profile
        for tab in profile.favorites { register(.tab(tab), under: .favorites(profile.id)) }
    }

    private func removeProfile(_ id: ProfileID) {
        guard let profile = profile(id: id) else { return }
        for tab in profile.favorites { unregister(.tab(tab)) }
        profiles.removeAll { $0.id == id }
        profileByIDCache[id] = nil
    }

    @discardableResult
    public func renameProfile(id: ProfileID, to name: String) -> Bool {
        guard let profile = profile(id: id), Self.profileNameIssue(name, in: profiles, excluding: id) == nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = profile.name
        guard old != trimmed else { return true }
        profile.name = trimmed
        registerChange(undo: { profile.name = old }, redo: { profile.name = trimmed })
        return true
    }

    public func setProfileIcon(id: ProfileID, icon: SpaceIcon?) {
        guard let profile = profile(id: id), profile.icon != icon else { return }
        let old = profile.icon
        profile.icon = icon
        registerChange(undo: { profile.icon = old }, redo: { profile.icon = icon })
    }

    @discardableResult
    public func updateProfileSettings(id: ProfileID, settings: ProfileSettings) -> Bool {
        guard let profile = profile(id: id) else { return false }
        let old = profile.settings
        guard old != settings else { return true }
        profile.settings = settings
        registerChange(undo: { profile.settings = old }, redo: { profile.settings = settings })
        return true
    }

    @discardableResult
    public func deleteProfile(id: ProfileID) -> Bool {
        guard let revert = removeProfileArchiving(id) else { return false }
        registerUndo(revert, reapply: { $0.removeProfileArchiving(id) ?? Self.noRevert })
        return true
    }

    private func removeProfileArchiving(_ id: ProfileID) -> Revert? {
        guard let profile = profile(id: id), deleteBlockReason(for: id) == nil,
              let slot = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let now = Date()
        let entries = profile.favorites.map {
            ArchiveEntry(tab: $0, reason: .closed, originalLocation: NodeParent.favorites(id).archiveLocation,
                         spaceID: nil, profileID: id, archivedAt: now)
        }
        // Resolve the directory while the Profile is still available to the sink.
        archive(entries)
        removeProfile(id)
        emit(.reload(parent: .favorites(id)))
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.profile(id: id) == nil else { return false }
            model.insertProfile(profile, at: slot)
            model.emit(.reload(parent: .favorites(id)))
            model.archiveSink?.discardArchived(ids: ids)
            return true
        }
    }

    @discardableResult
    public func moveSpace(id: SpaceID, toProfile profileID: ProfileID) -> Bool {
        guard let space = space(id: id), profile(id: profileID) != nil, space.profileID != profileID else { return false }
        let old = space.profileID
        setSpaceProfile(space, to: profileID)
        registerChange(undo: { self.setSpaceProfile(space, to: old) }, redo: { self.setSpaceProfile(space, to: profileID) })
        return true
    }

    private func setSpaceProfile(_ space: Space, to profileID: ProfileID) {
        let old = space.profileID
        guard old != profileID else { return }
        space.profileID = profileID
        emit(.spaceProfileChanged(spaceID: space.id, from: old, to: profileID))
    }

    @discardableResult
    public func repairMissingProfileReferences() -> [SpaceID] {
        guard let fallback = defaultProfile else { return [] }
        var repaired: [SpaceID] = []
        for space in spaces where profile(id: space.profileID) == nil {
            setSpaceProfile(space, to: fallback.id)
            repaired.append(space.id)
        }
        return repaired
    }

    // MARK: Spaces

    @discardableResult
    public func createSpace(title: String, profileID: ProfileID, icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme()) -> Space {
        let resolvedProfile = profile(id: profileID)?.id ?? defaultProfile?.id ?? profileID
        let space = Space(title: title, icon: icon, theme: theme, profileID: resolvedProfile)
        let i = spaces.count
        insertSpace(space, at: i)
        emit(.reload(parent: .spaceToday(space.id)))
        registerUndo({ model in model.removeSpace(space.id); return true }, reapply: { model in
            model.insertSpace(space, at: i)
            return { model in model.removeSpace(space.id); return true }
        })
        return space
    }

    public func updateSpace(id: SpaceID, title: String? = nil, icon: SpaceIcon?? = nil, theme: SpaceTheme? = nil, profileID: ProfileID? = nil) {
        guard let space = space(id: id) else { return }
        let oldTitle = space.title; let oldIcon = space.icon; let oldTheme = space.theme; let oldProfile = space.profileID
        let apply: @MainActor () -> Void = {
            if let title { space.title = title }
            if let icon { space.icon = icon }
            if let theme { space.theme = theme }
            if let profileID { self.setSpaceProfile(space, to: profileID) }
        }
        apply()
        registerChange(undo: {
            space.title = oldTitle; space.icon = oldIcon; space.theme = oldTheme
            self.setSpaceProfile(space, to: oldProfile)
        }, redo: apply)
    }

    /// Deletes a Space and archives its tabs. At least one Space always remains. Windows
    /// focused on it move to the first remaining Space. Undo puts the Space, its tabs, and
    /// the window focus back and drops the archive rows.
    public func deleteSpace(id: SpaceID, archiveTabs: Bool = true) {
        guard let revert = removeSpaceArchiving(id, archiveTabs: archiveTabs) else { return }
        registerUndo(revert, reapply: { $0.removeSpaceArchiving(id, archiveTabs: archiveTabs) ?? Self.noRevert })
    }

    private func removeSpaceArchiving(_ id: SpaceID, archiveTabs: Bool) -> Revert? {
        guard spaces.count > 1, let doomed = space(id: id), let slot = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        var entries: [ArchiveEntry] = []
        if archiveTabs {
            for node in doomed.pinned { entries += archiveEntries(for: node, in: .spacePinned(id), reason: .closed) }
            for node in doomed.today { entries += archiveEntries(for: node, in: .spaceToday(id), reason: .closed) }
        }
        let focusedWindows = windows.filter { $0.focusedSpaceID == id }
        removeSpace(id)
        emit(.reload(parent: .spaceToday(id)))
        archive(entries)
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.space(id: id) == nil else { return false }
            model.insertSpace(doomed, at: slot)
            for window in focusedWindows { window.focusedSpaceID = id }
            model.emit(.reload(parent: .spaceToday(id)))
            model.archiveSink?.discardArchived(ids: ids)
            return true
        }
    }

    private func insertSpace(_ space: Space, at i: Int) {
        spaces.insert(space, at: min(i, spaces.count))
        spaceByIDCache[space.id] = space
        for node in space.pinned { register(node, under: .spacePinned(space.id)) }
        for node in space.today { register(node, under: .spaceToday(space.id)) }
    }

    private func removeSpace(_ id: SpaceID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces.remove(at: i)
        spaceByIDCache[id] = nil
        for node in space.pinned { unregister(node) }
        for node in space.today { unregister(node) }
        if let fallback = spaces.first {
            for window in windows where window.focusedSpaceID == id { window.focusedSpaceID = fallback.id }
        }
    }

    public func moveSpace(id: SpaceID, to newIndex: Int) {
        guard let revert = reorderSpace(id, to: newIndex) else { return }
        registerUndo(revert, reapply: { $0.reorderSpace(id, to: newIndex) ?? Self.noRevert })
    }

    private func reorderSpace(_ id: SpaceID, to newIndex: Int) -> Revert? {
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let space = spaces.remove(at: from)
        spaces.insert(space, at: max(0, min(newIndex, spaces.count)))
        return { model in model.reorderSpace(id, to: from) != nil }
    }

    // MARK: Splits

    /// Joins 2–4 tabs into a split at the first tab's slot. The split lives where the first
    /// tab lived: a Space's pinned or Today section, or a folder. Never in Favorites: tabs in
    /// Favorites, split panes, duplicates, and non-tabs are rejected (nil, no change).
    @discardableResult
    public func makeSplit(tabIDs: [ItemID], orientation: SplitOrientation = .horizontal) -> Split? {
        let split = Split(orientation: orientation, focusedPaneID: tabIDs.first)
        guard let revert = formSplit(split, from: tabIDs) else { return nil }
        registerUndo(revert, reapply: { $0.formSplit(split, from: tabIDs) ?? Self.noRevert })
        return split
    }

    /// Places an empty `split` in the first tab's slot, then moves each tab into it as a pane.
    /// Emits one `.reload` per parent that changed.
    private func formSplit(_ split: Split, from tabIDs: [ItemID]) -> Revert? {
        guard (2...4).contains(tabIDs.count), Set(tabIDs).count == tabIDs.count, index[split.id] == nil else { return nil }
        for id in tabIDs {
            guard index[id]?.tab != nil, let parent = parentByID[id] else { return nil }
            switch parent {
            case .favorites, .splitPane: return nil
            case .spacePinned, .spaceToday, .folder: break
            }
        }
        guard let home = parentByID[tabIDs[0]], let slot = position(of: tabIDs[0], in: home) else { return nil }
        split.panes = []
        guard insertChild(.split(split), into: home, at: slot) != nil else { return nil }
        index[split.id] = .split(split)
        parentByID[split.id] = home
        let homeSection = section(of: home)
        var moved: [(tab: Tab, parent: NodeParent, index: Int, pinned: PinnedURLs)] = []
        var changed: [NodeParent] = [home]
        for id in tabIDs {
            guard let parent = parentByID[id], let removed = removeChild(id, from: parent), let tab = removed.node.tab else { continue }
            let pinned = applyPinnedRule(to: removed.node, from: section(of: parent), to: homeSection)
            split.panes.append(tab)
            parentByID[id] = .splitPane(split.id)
            moved.append((tab, parent, removed.index, pinned))
            if !changed.contains(parent) { changed.append(parent) }
        }
        for parent in changed { emit(.reload(parent: parent)) }
        let origins = moved
        let parents = changed
        return { model in
            // Auto-archive dissolved the split meanwhile: its survivors stay where they are.
            guard model.index[split.id] != nil else { return false }
            // Reverse order puts every tab back at the exact index it left from.
            for origin in origins.reversed() where model.parentByID[origin.tab.id] == .splitPane(split.id) {
                _ = model.removeChild(origin.tab.id, from: .splitPane(split.id))
                _ = model.insertChild(.tab(origin.tab), into: origin.parent, at: origin.index)
                model.parentByID[origin.tab.id] = origin.parent
                Self.restore(origin.pinned)
            }
            if let at = model.parentByID[split.id] { _ = model.removeChild(split.id, from: at) }
            model.index[split.id] = nil
            model.parentByID[split.id] = nil
            for parent in parents { model.emit(.reload(parent: parent)) }
            return true
        }
    }

    /// Replaces a split with its panes as separate rows, in pane order, at the split's slot.
    public func unsplit(splitID: ItemID) {
        guard let revert = dissolve(splitID) else { return }
        registerUndo(revert, reapply: { $0.dissolve(splitID) ?? Self.noRevert })
    }

    private func dissolve(_ splitID: ItemID) -> Revert? {
        guard let split = index[splitID]?.split, let parent = parentByID[splitID],
              let removed = removeChild(splitID, from: parent) else { return nil }
        index[splitID] = nil
        parentByID[splitID] = nil
        let panes = split.panes
        for (offset, pane) in panes.enumerated() {
            _ = insertChild(.tab(pane), into: parent, at: removed.index + offset)
            parentByID[pane.id] = parent
        }
        emit(.reload(parent: parent))
        return { model in
            // Rejoin only panes still in place; auto-archive may have taken some.
            let present = panes.filter { model.parentByID[$0.id] == parent }
            guard present.count >= 2, model.index[splitID] == nil,
                  let slot = model.position(of: present[0].id, in: parent) else { return false }
            for pane in present { _ = model.removeChild(pane.id, from: parent) }
            split.panes = present
            _ = model.insertChild(.split(split), into: parent, at: slot)
            model.index[splitID] = .split(split)
            model.parentByID[splitID] = parent
            for pane in present { model.parentByID[pane.id] = .splitPane(splitID) }
            model.emit(.reload(parent: parent))
            return true
        }
    }

    /// Takes a pane out of a split. With `archive`, the pane is archived. Without it, the pane
    /// becomes its own row right after the split. A split left with one pane collapses.
    public func removePane(splitID: ItemID, tabID: ItemID, archive: Bool = false) {
        guard parentByID[tabID] == .splitPane(splitID) else { return }
        if archive {
            guard let revert = closePane(tabID, of: splitID) else { return }
            registerUndo(revert, reapply: { $0.closePane(tabID, of: splitID) ?? Self.noRevert })
        } else {
            guard let revert = separatePane(tabID, of: splitID) else { return }
            registerUndo(revert, reapply: { $0.separatePane(tabID, of: splitID) ?? Self.noRevert })
        }
    }

    private func separatePane(_ tabID: ItemID, of splitID: ItemID) -> Revert? {
        guard parentByID[tabID] == .splitPane(splitID), let split = index[splitID]?.split, let parent = parentByID[splitID],
              let tab = tab(id: tabID), let restorePane = takePane(tabID, from: split) else { return nil }
        // After a collapse the remaining pane holds the split's slot.
        let anchor = index[splitID] != nil ? splitID : split.panes.first?.id
        let slot = anchor.flatMap { position(of: $0, in: parent) }.map { $0 + 1 }
        attach(.tab(tab), to: parent, at: slot)
        return { model in
            guard let separated = model.detach(tabID) else { return false }
            if !restorePane(model) { model.attach(separated.node, to: separated.parent, at: separated.index) }
            return true
        }
    }

    /// Removes a pane from its split (emits `.remove`). With one pane left the split
    /// collapses: the remaining tab takes the split's slot (emits `.reload` of that parent).
    /// Returns the closure that restores the split and the pane; it returns false and
    /// changes nothing when the split or its remaining tab is gone.
    private func takePane(_ tabID: ItemID, from split: Split) -> (@MainActor (BrowserModel) -> Bool)? {
        let wasFocused = split.focusedPaneID == tabID
        guard let removed = detach(tabID) else { return nil }
        if wasFocused { split.focusedPaneID = split.panes.first?.id }
        let collapsedIn = collapseIfSinglePane(split)
        let paneIndex = removed.index
        return { model in
            if let parent = collapsedIn {
                guard let remaining = split.panes.first, model.parentByID[remaining.id] == parent,
                      model.replaceChild(remaining.id, in: parent, with: .split(split)) != nil else { return false }
                model.index[split.id] = .split(split)
                model.parentByID[split.id] = parent
                model.parentByID[remaining.id] = .splitPane(split.id)
                model.emit(.reload(parent: parent))
            }
            guard model.attach(removed.node, to: .splitPane(split.id), at: paneIndex) != nil else { return false }
            if wasFocused { split.focusedPaneID = tabID }
            return true
        }
    }

    /// Swaps a one-pane split for its tab. Returns the parent it collapsed in.
    private func collapseIfSinglePane(_ split: Split) -> NodeParent? {
        guard split.panes.count == 1, let remaining = split.panes.first, let parent = parentByID[split.id],
              replaceChild(split.id, in: parent, with: .tab(remaining)) != nil else { return nil }
        index[split.id] = nil
        parentByID[split.id] = nil
        parentByID[remaining.id] = parent
        emit(.reload(parent: parent))
        return parent
    }

    // MARK: Pinned URL

    public func resetPinnedTab(id: ItemID) {
        guard let tab = tab(id: id), let pinned = tab.pinnedURL else { return }
        let old = tab.url
        tab.url = pinned
        tab.lastActiveAt = Date()
        registerChange(undo: { tab.url = old }, redo: { tab.url = pinned })
    }

    public func replacePinnedURL(id: ItemID) {
        guard let tab = tab(id: id) else { return }
        let old = tab.pinnedURL
        let new = tab.url
        tab.pinnedURL = new
        registerChange(undo: { tab.pinnedURL = old }, redo: { tab.pinnedURL = new })
    }

    // MARK: Clear / auto-archive

    /// Archives every Today node of a Space in one pass: one sink call, one `.reload`.
    /// Undo puts the section back and drops the archive rows.
    public func clearToday(space spaceID: SpaceID) {
        guard let revert = clearTodayNodes(spaceID) else { return }
        registerUndo(revert, reapply: { $0.clearTodayNodes(spaceID) ?? Self.noRevert })
    }

    private func clearTodayNodes(_ spaceID: SpaceID) -> Revert? {
        guard let space = space(id: spaceID), !space.today.isEmpty else { return nil }
        let parent = NodeParent.spaceToday(spaceID)
        let saved = space.today
        let now = Date()
        var entries: [ArchiveEntry] = []
        for node in saved {
            entries += archiveEntries(for: node, in: parent, reason: .clearedToday, at: now)
            unregister(node)
        }
        space.today = []
        emit(.reload(parent: parent))
        archive(entries)
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.space(id: spaceID) === space else { return false }
            space.today = saved + space.today
            for node in saved { model.register(node, under: parent) }
            model.emit(.reload(parent: parent))
            model.archiveSink?.discardArchived(ids: ids)
            return true
        }
    }

    private struct ExpirySweep {
        let cutoff: Date
        let now: Date
        let spaceID: SpaceID
        let profileID: ProfileID
        var entries: [ArchiveEntry] = []
        var changed: [NodeParent] = []
    }

    /// Archives expired Today tabs in one pass: top-level tabs, split panes, and tabs inside
    /// Today folders. Pinned tabs and favorites never expire. One sink call for all tabs, and
    /// one `.reload` per parent whose list changed. No undo: the archive is the history.
    @discardableResult
    public func archiveExpiredTabs(now: Date) -> Int {
        var entries: [ArchiveEntry] = []
        var changed: [NodeParent] = []
        for space in spaces {
            guard let threshold = profile(id: space.profileID)?.settings.autoArchiveAfter.seconds else { continue }
            var sweep = ExpirySweep(cutoff: now.addingTimeInterval(-threshold), now: now, spaceID: space.id, profileID: space.profileID)
            if let kept = sweepExpired(space.today, in: .spaceToday(space.id), &sweep) { space.today = kept }
            entries += sweep.entries
            changed += sweep.changed
        }
        archive(entries)
        for parent in changed { emit(.reload(parent: parent)) }
        return entries.count
    }

    /// Filters expired tabs out of one node list. Returns the new list, or nil when it is unchanged.
    private func sweepExpired(_ list: [SidebarNode], in parent: NodeParent, _ sweep: inout ExpirySweep) -> [SidebarNode]? {
        var kept: [SidebarNode] = []
        kept.reserveCapacity(list.count)
        var listChanged = false
        for node in list {
            switch node {
            case .tab(let tab):
                if tab.lastActiveAt < sweep.cutoff {
                    expire(tab, from: parent, &sweep)
                    listChanged = true
                } else {
                    kept.append(node)
                }
            case .folder(let folder):
                if let children = sweepExpired(folder.children, in: .folder(folder.id), &sweep) { folder.children = children }
                kept.append(node)
            case .split(let split):
                let cutoff = sweep.cutoff
                let live = split.panes.filter { $0.lastActiveAt >= cutoff }
                guard live.count < split.panes.count else { kept.append(node); continue }
                for tab in split.panes where tab.lastActiveAt < cutoff { expire(tab, from: .splitPane(split.id), &sweep) }
                split.panes = live
                if let focused = split.focusedPaneID, !live.contains(where: { $0.id == focused }) { split.focusedPaneID = live.first?.id }
                if live.count >= 2 {
                    kept.append(node)
                    sweep.changed.append(.splitPane(split.id))
                } else {
                    // Under two panes the split dissolves. A lone survivor takes its slot.
                    index[split.id] = nil
                    parentByID[split.id] = nil
                    if let survivor = live.first {
                        parentByID[survivor.id] = parent
                        kept.append(.tab(survivor))
                    }
                    listChanged = true
                }
            }
        }
        guard listChanged else { return nil }
        sweep.changed.append(parent)
        return kept
    }

    private func expire(_ tab: Tab, from parent: NodeParent, _ sweep: inout ExpirySweep) {
        sweep.entries.append(ArchiveEntry(tab: tab, reason: .autoArchived, originalLocation: parent.archiveLocation,
                                          spaceID: sweep.spaceID, profileID: sweep.profileID, archivedAt: sweep.now))
        index[tab.id] = nil
        parentByID[tab.id] = nil
    }

    // MARK: Focus / selection

    public func focusSpace(windowID: WindowID, spaceID: SpaceID) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        let old = window.focusedSpaceID
        window.focusedSpaceID = spaceID
        registerChange(undo: { window.focusedSpaceID = old }, redo: { window.focusedSpaceID = spaceID })
    }

    /// Every pane is visible when a split is selected or its keyboard focus changes.
    private func stampVisibleTabs(in node: SidebarNode) {
        let date = Date()
        let tabs = node.split?.panes ?? node.tab.map { [$0] } ?? []
        for tab in tabs { tab.lastActiveAt = date; tab.isUnread = false }
    }

    public func focusSplitPane(splitID: ItemID, tabID: ItemID) {
        guard let split = index[splitID]?.split, split.panes.contains(where: { $0.id == tabID }) else { return }
        split.focusedPaneID = tabID
        stampVisibleTabs(in: .split(split))
    }

    public func selectNode(windowID: WindowID, spaceID: SpaceID, nodeID: ItemID?) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        let old = window.selectedNodeBySpace[spaceID]
        window.selectedNodeBySpace[spaceID] = nodeID
        if let nodeID, let node = index[nodeID] {
            stampVisibleTabs(in: node)
        }
        registerChange(undo: { window.selectedNodeBySpace[spaceID] = old },
                       redo: { window.selectedNodeBySpace[spaceID] = nodeID })
    }
}
