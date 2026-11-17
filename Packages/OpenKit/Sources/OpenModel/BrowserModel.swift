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

public enum ArchiveRecordKind: String, Codable, Sendable { case tab, folder }

/// A folder removed by Delete. Section preserves the fallback when its parent disappears.
public struct ArchiveFolderEntry: Sendable {
    public let folder: Folder
    public let originalLocation: String
    public let spaceID: SpaceID?
    public let profileID: ProfileID?
    public let archivedAt: Date
    public let originalSection: String?
    public let reason: ArchiveReason

    public init(folder: Folder, originalLocation: String, spaceID: SpaceID?, profileID: ProfileID?, archivedAt: Date,
                originalSection: String? = nil, reason: ArchiveReason = .folderDeleted) {
        self.folder = folder; self.originalLocation = originalLocation; self.spaceID = spaceID
        self.profileID = profileID; self.archivedAt = archivedAt; self.originalSection = originalSection; self.reason = reason
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
    public var kind: ArchiveRecordKind
    public var payloadJSON: String

    public init(id: ItemID, url: URL, title: String, spaceID: SpaceID? = nil, profileID: ProfileID? = nil, archivedAt: Date, reason: ArchiveReason, originalLocation: String, payloadJSON: String, kind: ArchiveRecordKind = .tab) {
        self.id = id; self.url = url; self.title = title
        self.spaceID = spaceID; self.profileID = profileID
        self.archivedAt = archivedAt; self.reason = reason
        self.originalLocation = originalLocation; self.payloadJSON = payloadJSON; self.kind = kind
    }
}

/// Sink for tabs that leave the sidebar. Implemented by OpenStore's ArchiveStore.
/// Called on the main actor. Normal archive/discard calls dispatch asynchronously;
/// confirmed Profile deletion may wait for the durable commit.
@MainActor
public protocol ArchiveSink: AnyObject {
    /// Stores tabs that left the sidebar. A bulk command passes all of its tabs in one call.
    func archiveFolder(_ entry: ArchiveFolderEntry)
    /// One command batch, including folder deletions. Stores override this for one transaction.
    func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry])
    func archive(_ entries: [ArchiveEntry])
    /// Waits for durable archive commit; a failure must leave the model unchanged.
    func archiveForProfileDeletion(_ entries: [ArchiveEntry], directoryName: String) throws
    /// Drops the rows of tabs that are back in the sidebar (restore, or undo of a close),
    /// so a tab is never in the sidebar and the archive at once.
    func discardArchived(ids: [ItemID])
}

public enum ProfileArchiveError: Error { case confirmationUnavailable }

public extension ArchiveSink {
    func archiveFolder(_ entry: ArchiveFolderEntry) {}
    func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry]) {
        if !entries.isEmpty { archive(entries) }
        for entry in folders { archiveFolder(entry) }
    }

    func archiveForProfileDeletion(_ entries: [ArchiveEntry], directoryName: String) throws {
        throw ProfileArchiveError.confirmationUnavailable
    }
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
    /// What loading repaired in the snapshot (repeated IDs). Non-empty: the App saves at once.
    @ObservationIgnored public var loadRepairs: [String] = []
    public var windows: [BrowserWindowState] { didSet { commitMutation() } }
    public var routingRules: [RoutingRule]
    public var defaultDestination: DefaultDestination
    /// Session-only Space focus order; never persisted in a snapshot.
    private var focusedSpaceOrder: [SpaceID] = []

    /// Injected services. Not persisted, not observed.
    @ObservationIgnored public var archiveSink: (any ArchiveSink)?
    @ObservationIgnored public var undoManager: UndoManager?
    /// Changes on every registered model action and every undo/redo execution. A UI
    /// action may use this to refuse an Undo after its original stack target changed.
    @ObservationIgnored public private(set) var undoGeneration: UInt64 = 0
    #if DEBUG
    /// Debug CLI seam for the rollback code; absent from release builds.
    @ObservationIgnored public var diagnosticRollbackFailureAtMove: Int?
    #endif
    @ObservationIgnored private var spaceCreationEvents: [TreeChange]?
    @ObservationIgnored private var importReloadParents: [NodeParent]?
    @ObservationIgnored private var importReloadParentSet = Set<NodeParent>()
    @ObservationIgnored private var importBatchDepth = 0

    /// Invalidates derived tab ownership after structural edits or a full import/load.
    @ObservationIgnored public private(set) var treeRevision: UInt64 = 0

    // O(1) lookup. Every command updates both maps in place, in O(size of the changed subtree).
    // rebuildIndex() walks the whole tree and runs only on load and import.
    @ObservationIgnored public private(set) var index: [ItemID: SidebarNode] = [:]
    @ObservationIgnored public private(set) var parentByID: [ItemID: NodeParent] = [:]

    /// Strong references preserve the last shown set even after a structural edit
    /// removes its nodes from the index. At most four tabs per showing window.
    @ObservationIgnored private var shownTabs: [ItemID: Tab] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (TreeChange) -> Void] = [:]
    @ObservationIgnored private var spaceByIDCache: [SpaceID: Space] = [:]
    @ObservationIgnored private var profileByIDCache: [ProfileID: Profile] = [:]

    /// Undoes one change and returns true, or returns false and changes nothing when its
    /// nodes are gone. Gets the model from the undo manager, so it captures no `self`.
    private typealias Revert = @MainActor (BrowserModel) -> Bool
    private static let noRevert: Revert = { _ in false }
    private typealias PinnedURLs = [(tab: Tab, url: URL?)]

    public init(profiles: [Profile] = [], spaces: [Space] = [], windows: [BrowserWindowState] = [], routingRules: [RoutingRule] = [], defaultDestination: DefaultDestination = .littleOpen(profile: nil)) {
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
        if spaceCreationEvents != nil { spaceCreationEvents?.append(change); return }
        if importReloadParents != nil {
            switch change {
            case .insert(let parent, _, _), .remove(let parent, _, _), .reload(let parent):
                queueImportReload(parent); return
            case .move(let from, _, let to, _, _):
                queueImportReload(from); queueImportReload(to); return
            case .spaceProfileChanged: break
            }
        }
        treeRevision &+= 1
        commitMutation()
        for handler in observers.values { handler(change) }
    }

    /// Import edits are synchronous. Observers need each parent's final graph,
    /// rather than a sidebar rebuild and engine mirror sync for every item.
    private func beginImportBatch() {
        if importBatchDepth == 0 { importReloadParents = []; importReloadParentSet.removeAll(keepingCapacity: true) }
        importBatchDepth += 1
    }

    private func queueImportReload(_ parent: NodeParent) {
        if importReloadParentSet.insert(parent).inserted { importReloadParents?.append(parent) }
    }

    private func endImportBatch() {
        importBatchDepth -= 1
        guard importBatchDepth == 0 else { return }
        let parents = importReloadParents ?? []
        importReloadParents = nil
        importReloadParentSet.removeAll(keepingCapacity: true)
        for parent in parents { emit(.reload(parent: parent)) }
    }

    // MARK: Lookup

    public func space(id: SpaceID) -> Space? { spaceByIDCache[id] }
    public func profile(id: ProfileID) -> Profile? { profileByIDCache[id] }
    public func node(id: ItemID) -> SidebarNode? { index[id] }
    public func tab(id: ItemID) -> Tab? { index[id]?.tab }
    public func parent(of id: ItemID) -> NodeParent? { parentByID[id] }

    /// Resolve a flattened tab traversal result to its selectable sidebar node.
    /// Selecting a split pane as a plain tab would hide the other panes.
    public func sidebarSelectionID(for id: ItemID?) -> ItemID? {
        guard let id else { return nil }
        if case .splitPane(let splitID)? = parent(of: id) { return splitID }
        return id
    }

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
        // Never trap on a repeated ID (a damaged snapshot or import): the first one wins.
        spaceByIDCache = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        profileByIDCache = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for profile in profiles {
            for tab in profile.favorites { register(.tab(tab), under: .favorites(profile.id)) }
        }
        for space in spaces {
            for node in space.pinned { register(node, under: .spacePinned(space.id)) }
            for node in space.today { register(node, under: .spaceToday(space.id)) }
        }
        commitMutation()
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

    private func removeChild(_ id: ItemID, from parent: NodeParent, at knownPosition: Int? = nil) -> (node: SidebarNode, index: Int)? {
        if let i = knownPosition {
            switch parent {
            case .favorites, .splitPane:
                return withTabList(parent) { list in
                    guard list.indices.contains(i), list[i].id == id else { return nil }
                    return (node: SidebarNode.tab(list.remove(at: i)), index: i)
                }
            case .spacePinned, .spaceToday, .folder:
                return withNodeList(parent) { list in
                    guard list.indices.contains(i), list[i].id == id else { return nil }
                    return (node: list.remove(at: i), index: i)
                }
            }
        }
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
    private func attach(_ node: SidebarNode, to parent: NodeParent, at position: Int?, restoringPeek: ClearedFolderPeek? = nil) -> Int? {
        guard index[node.id] == nil, let i = insertChild(node, into: parent, at: position) else { return nil }
        register(node, under: parent)
        restorePeek(restoringPeek)
        emit(.insert(parent: parent, index: i, nodeID: node.id))
        return i
    }

    private struct ClearedFolderPeek {
        let folderID: ItemID
        let childID: ItemID
    }

    private func clearPeek(in parent: NodeParent, removing id: ItemID) -> ClearedFolderPeek? {
        guard case .folder(let folderID) = parent, let folder = index[folderID]?.folder,
              folder.peekedChildID == id else { return nil }
        folder.peekedChildID = nil
        return ClearedFolderPeek(folderID: folderID, childID: id)
    }

    private func restorePeek(_ cleared: ClearedFolderPeek?) {
        guard let cleared, let folder = index[cleared.folderID]?.folder, !folder.isExpanded,
              parentByID[cleared.childID] == .folder(folder.id), index[cleared.childID]?.folder == nil else { return }
        folder.peekedChildID = cleared.childID
    }

    /// Removes a node and drops its subtree from the index. Emits `.remove`.
    @discardableResult
    private func detach(_ id: ItemID, at knownPosition: Int? = nil) -> (node: SidebarNode, parent: NodeParent, index: Int, clearedPeek: ClearedFolderPeek?)? {
        guard let parent = parentByID[id], let removed = removeChild(id, from: parent, at: knownPosition) else { return nil }
        let cleared = clearPeek(in: parent, removing: id)
        unregister(removed.node)
        emit(.remove(parent: parent, index: removed.index, nodeID: id))
        return (removed.node, parent, removed.index, cleared)
    }

    /// Moves a node. The index changes in O(1): only the node's own parent entry moves.
    /// Applies the pinned-URL rule and emits `.move`. Returns the closure that moves it back.
    private func relocate(_ id: ItemID, to destination: NodeParent, at position: Int?, fromIndex knownPosition: Int? = nil, restoringPeek: ClearedFolderPeek? = nil) -> Revert? {
        guard let source = parentByID[id] else { return nil }
        let fromSection = section(of: source)
        let toSection = section(of: destination)
        guard let removed = removeChild(id, from: source, at: knownPosition) else { return nil }
        guard let toIndex = insertChild(removed.node, into: destination, at: position) else {
            _ = insertChild(removed.node, into: source, at: removed.index)
            return nil
        }
        let cleared = source == destination ? nil : clearPeek(in: source, removing: id)
        parentByID[id] = destination
        let prior = applyPinnedRule(to: removed.node, from: fromSection, to: toSection)
        restorePeek(restoringPeek)
        emit(.move(fromParent: source, fromIndex: removed.index, toParent: destination, toIndex: toIndex, nodeID: id))
        let fromIndex = removed.index
        return { model in
            guard model.relocate(id, to: source, at: fromIndex, restoringPeek: cleared) != nil else { return false }
            Self.restore(prior)
            return true
        }
    }

    /// One archive entry per tab under `node`, each with the tab's direct parent.
    private func archiveEntries(for node: SidebarNode, in parent: NodeParent, reason: ArchiveReason, at date: Date = Date(),
                                ownership: (space: SpaceID?, profile: ProfileID?)? = nil) -> [ArchiveEntry] {
        let owning = ownership ?? owner(of: parent)
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
        // Property-only commands share the structural emission commit path,
        // including callers with no UndoManager or disabled registration.
        commitMutation()
        guard let um = undoManager else { return }
        // Each command registers one action. Grouping follows the undo manager: with
        // per-event grouping (the AppKit default) every command of one event forms one step,
        // so a drag of three tabs undoes at once. Without it (CLI, callers off the event
        // loop) registering outside a group is an error, so the model opens one per command.
        let group = !um.groupsByEvent && um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        if group { um.beginUndoGrouping() }
        if um.isUndoRegistrationEnabled { undoGeneration &+= 1 }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.undoGeneration &+= 1
                defer { model.commitMutation() }
                handler(model)
            }
        }
        if group { um.endUndoGrouping() }
    }

    /// Counts from an ID-preserving sidebar merge. Archive/history belong to stores.
    public struct ImportCounts {
        public var spaces = 0, tabs = 0, favorites = 0, folders = 0, searchSettings = 0, duplicates = 0
        public init() {}
    }
    public enum ProfileImportError: Error { case invalidProfile }

    /// First run installs a complete model before the first browser window.
    /// Its inverse keeps that installed model object so live observers retain
    /// their owner. Physical Profile directories are outside model Undo.
    public func registerImportedReplacementUndo(restoring previous: BrowserModel) {
        let before = (previous.profiles, previous.spaces, previous.routingRules, previous.defaultDestination)
        let after = (profiles, spaces, routingRules, defaultDestination)
        func restore(_ model: BrowserModel, _ state: ([Profile], [Space], [RoutingRule], DefaultDestination)) {
            let oldProfiles = model.profiles, oldSpaces = model.spaces
            model.profiles = state.0; model.spaces = state.1
            model.routingRules = state.2; model.defaultDestination = state.3
            model.rebuildIndex()
            for window in model.windows {
                if model.space(id: window.focusedSpaceID) == nil, let first = model.spaces.first { window.focusedSpaceID = first.id }
                window.selectedNodeBySpace = window.selectedNodeBySpace.filter { model.space(id: $0.key) != nil && model.node(id: $0.value) != nil }
            }
            for id in Set((oldProfiles + model.profiles).map(\.id)) { model.emit(.reload(parent: .favorites(id))) }
            for id in Set((oldSpaces + model.spaces).map(\.id)) {
                model.emit(.reload(parent: .spacePinned(id))); model.emit(.reload(parent: .spaceToday(id)))
            }
        }
        registerUndo({ model in restore(model, before); return true }, reapply: { model in
            restore(model, after); return { model in restore(model, before); return true }
        })
    }

    /// Imports into the live model without changing existing Space metadata, item
    /// order or selection. Source objects are copied with their stable IDs. The
    /// durable save is part of the command: failure reverses edits and registers
    /// no undo. Success registers the whole merge as one undo step.
    @discardableResult
    public func mergeImportedSidebar(_ source: BrowserModel, profileMapping: [ProfileID: ProfileID],
                                     spaces includeSpaces: Bool, tabs includeTabs: Bool,
                                     favorites includeFavorites: Bool, folders includeFolders: Bool,
                                     searchSettings includeSearch: Bool,
                                     profiles includeProfiles: Bool = false,
                                     archivedIDsByProfile: [ProfileID: Set<ItemID>] = [:],
                                     importedAt: Date = Date(), saving: () throws -> Void) throws -> ImportCounts {
        beginImportBatch()
        defer { endImportBatch() }
        typealias Edit = (apply: @MainActor (BrowserModel) -> Void, undo: Revert)
        var edits: [Edit] = []
        var counts = ImportCounts()
        let newSpaceIDs = Set(source.spaces.filter { space(id: $0.id) == nil }.map(\.id))
        func perform(_ apply: @escaping @MainActor (BrowserModel) -> Void,
                     undo: @escaping Revert) {
            apply(self); edits.append((apply, undo))
        }
        func copyTab(_ tab: Tab, into parent: NodeParent) -> Tab {
            let activity: Date
            if case .spaceToday? = section(of: parent) { activity = importedAt }
            else { activity = tab.lastActiveAt }
            let copy = Tab(id: tab.id, url: tab.url, title: tab.title, customTitle: tab.customTitle,
                pinnedURL: tab.pinnedURL, customIcon: tab.customIcon, iconOverride: tab.iconOverride,
                createdAt: tab.createdAt, lastActiveAt: activity, isMuted: tab.isMuted,
                openerID: tab.openerID, isUnread: tab.isUnread)
            if case .folder(let id) = parent, index[id]?.folder?.live != nil { copy.liveItemURL = tab.liveItemURL; copy.liveItem = tab.liveItem }
            return copy
        }
        func duplicate(_ id: ItemID, into parent: NodeParent) -> Bool {
            node(id: id) != nil || owner(of: parent).profile.map { archivedIDsByProfile[$0]?.contains(id) == true } == true
        }
        func add(_ node: SidebarNode, to parent: NodeParent) {
            let slot: Int
            switch parent {
            case .spacePinned(let id): slot = space(id: id)?.pinned.count ?? 0
            case .spaceToday(let id): slot = space(id: id)?.today.count ?? 0
            case .favorites(let id): slot = profile(id: id)?.favorites.count ?? 0
            case .folder(let id): slot = self.node(id: id)?.folder?.children.count ?? 0
            case .splitPane(let id): slot = self.node(id: id)?.split?.panes.count ?? 0
            }
            perform({ _ = $0.attach(node, to: parent, at: slot) }, undo: { model in
                guard model.parent(of: node.id) == parent else { return false }
                return model.detach(node.id) != nil
            })
        }
        func merge(_ nodes: [SidebarNode], into parent: NodeParent) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    if let existing = self.node(id: folder.id)?.folder {
                        if includeFolders { counts.duplicates += 1 }
                        merge(folder.children, into: .folder(existing.id))
                    } else if includeFolders, self.node(id: folder.id) == nil {
                        let copy = Folder(id: folder.id, title: folder.title, isExpanded: folder.isExpanded,
                                          customIcon: folder.customIcon, iconOverride: folder.iconOverride)
                        // An imported Live Folder stays live unless its Space already has one (LF L7).
                        if folder.live != nil, case .spacePinned(let space) = parent, liveFolder(in: space) == nil { copy.live = folder.live }
                        add(.folder(copy), to: parent); counts.folders += 1
                        merge(folder.children, into: .folder(copy.id))
                    } else { merge(folder.children, into: parent) }
                case .tab(let tab):
                    guard includeTabs else { continue }
                    if duplicate(tab.id, into: parent) { counts.duplicates += 1 }
                    else { add(.tab(copyTab(tab, into: parent)), to: parent); counts.tabs += 1 }
                case .split(let split):
                    guard includeTabs else { continue }
                    let panes = split.panes.filter { tab in
                        if duplicate(tab.id, into: parent) { counts.duplicates += 1; return false }
                        return true
                    }.map { copyTab($0, into: parent) }
                    if self.node(id: split.id) != nil {
                        for tab in panes { add(.tab(tab), to: parent); counts.tabs += 1 }
                    } else if panes.count >= 2 {
                        let focused = panes.contains { $0.id == split.focusedPaneID } ? split.focusedPaneID : panes.first?.id
                        add(.split(Split(id: split.id, orientation: split.orientation, fractions: panes.count == split.panes.count ? split.fractions : [], panes: panes, focusedPaneID: focused, customTitle: split.customTitle, iconOverride: split.iconOverride)), to: parent)
                        counts.tabs += panes.count
                    } else if let tab = panes.first { add(.tab(tab), to: parent); counts.tabs += 1 }
                }
            }
        }
        for imported in source.profiles {
            let id = profileMapping[imported.id] ?? imported.id
            if profile(id: id) == nil {
                guard includeSpaces || includeFavorites || includeProfiles else { continue }
                var name = imported.name
                var suffix = 2
                while profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = imported.name + " (" + String(suffix) + ")"; suffix += 1
                }
                // Use the normal creation path and its directory allocator.
                // The source ID is the import identity, never a name match.
                // This enclosing command owns the one Undo registration.
                let enabled = undoManager?.isUndoRegistrationEnabled == true
                if enabled { undoManager?.disableUndoRegistration() }
                let created = createProfile(name: name, icon: imported.icon, id: id)
                if enabled { undoManager?.enableUndoRegistration() }
                guard let copy = created else {
                    for edit in edits.reversed() { _ = edit.undo(self) }
                    throw ProfileImportError.invalidProfile
                }
                let slot = profiles.count - 1
                emit(.reload(parent: .favorites(id)))
                edits.append((apply: { model in model.insertProfile(copy, at: slot); model.emit(.reload(parent: .favorites(id))) },
                        undo: { model in
                            guard model.profile(id: id) === copy else { return false }
                            model.removeProfile(id); model.emit(.reload(parent: .favorites(id))); return true
                        }))
            }
            guard let target = profile(id: id) else { continue }
            // Arc's dismissed Favorites empty-state card (A3) comes with the Profile's Favorites; undoable.
            if includeFavorites, imported.favoritesEmptyStateDismissed, !target.favoritesEmptyStateDismissed {
                perform({ _ in target.favoritesEmptyStateDismissed = true }, undo: { _ in target.favoritesEmptyStateDismissed = false; return true })
            }
            if includeSearch {
                var settings = target.settings
                settings.searchEngineID = imported.settings.searchEngineID
                settings.customSearchEngines = imported.settings.customSearchEngines
                if settings != target.settings {
                    let old = target.settings, new = settings
                    perform({ _ in target.settings = new }, undo: { _ in target.settings = old; return true })
                    counts.searchSettings += 1
                }
            }
            if includeFavorites {
                for tab in imported.favorites {
                    if duplicate(tab.id, into: .favorites(id)) { counts.duplicates += 1 }
                    else { add(.tab(copyTab(tab, into: .favorites(id))), to: .favorites(id)); counts.favorites += 1 }
                }
            }
        }
        for imported in source.spaces {
            if space(id: imported.id) != nil {
                if includeSpaces { counts.duplicates += 1 }
            } else if includeSpaces, let profile = profile(id: profileMapping[imported.profileID] ?? imported.profileID) {
                let copy = Space(id: imported.id, title: imported.title, icon: imported.icon, theme: imported.theme,
                                 profileID: profile.id, isPinnedCollapsed: imported.isPinnedCollapsed)
                let slot = spaces.count
                perform({ model in model.insertSpace(copy, at: slot); model.emit(.reload(parent: .spaceToday(copy.id))) },
                        undo: { model in
                            guard model.space(id: copy.id) === copy else { return false }
                            model.removeSpace(copy.id); model.emit(.reload(parent: .spaceToday(copy.id))); return true
                        })
                counts.spaces += 1
            }
            // If Spaces is off, only an existing Space with the same ID can gain items.
            guard space(id: imported.id) != nil else { continue }
            merge(imported.pinned, into: .spacePinned(imported.id))
            merge(imported.today, into: .spaceToday(imported.id))
        }
        if includeSpaces {
            // Preserve the live windows and every existing selection. Newly
            // imported Spaces can still resume their source session when the
            // user first switches to them in an existing browser window.
            for window in windows where window.style == .standard {
                for imported in source.windows where imported.style == .standard {
                    for (spaceID, itemID) in imported.selectedNodeBySpace
                        where newSpaceIDs.contains(spaceID) && window.selectedNodeBySpace[spaceID] == nil && node(id: itemID) != nil {
                        perform({ _ in window.selectedNodeBySpace[spaceID] = itemID }, undo: { _ in
                            guard window.selectedNodeBySpace[spaceID] == itemID else { return false }
                            window.selectedNodeBySpace[spaceID] = nil; return true
                        })
                    }
                }
            }
            let ids = Set(routingRules.map(\.id))
            // Arc's importer assigns fresh rule IDs. Treat the same rule body
            // as a duplicate too, so a Settings re-import remains idempotent.
            let rules = source.routingRules.map { rule in
                var mapped = rule
                switch rule.destination {
                case .space: break
                case .littleOpen(let id): mapped.destination = .littleOpen(profile: id.map { profileMapping[$0] ?? $0 })
                case .mostRecentSpace(let id): mapped.destination = .mostRecentSpace(profile: id.map { profileMapping[$0] ?? $0 })
                }
                return mapped
            }.filter { candidate in
                !ids.contains(candidate.id) && !routingRules.contains {
                    $0.match == candidate.match && $0.destination == candidate.destination && $0.sourceBundleID == candidate.sourceBundleID
                }
            }
            if !rules.isEmpty {
                perform({ $0.routingRules += rules }, undo: { model in
                    let added = Set(rules.map(\.id)); model.routingRules.removeAll { added.contains($0.id) }
                    return true
                })
            }
        }
        do { try saving() }
        catch { for edit in edits.reversed() { _ = edit.undo(self) }; throw error }
        guard !edits.isEmpty else { return counts }
        // Auto-archive has no undo step and can remove imported Today tabs
        // beneath this command. Redo only the edits that this undo reversed.
        var reversible = edits
        let revert: Revert = { model in
            model.beginImportBatch()
            defer { model.endImportBatch() }
            reversible = reversible.reversed().filter { $0.undo(model) }.reversed()
            return !reversible.isEmpty
        }
        registerUndo(revert, reapply: { model in
            model.beginImportBatch()
            defer { model.endImportBatch() }
            for edit in reversible { edit.apply(model) }
            return revert
        })
        return counts
    }

    // MARK: - Commands: tabs

    /// Copies a whole sidebar subtree immediately after its source, with fresh
    /// IDs and runtime state. One undo step removes the complete copy.
    @discardableResult
    public func duplicateNode(id: ItemID) -> ItemID? {
        guard let source = node(id: id), let parent = parent(of: id), let position = position(of: id, in: parent) else { return nil }
        if case .splitPane(let splitID) = parent, (node(id: splitID)?.split?.panes.count ?? 4) >= 4 { return nil }
        func copyTab(_ tab: Tab) -> Tab {
            Tab(url: tab.url, title: tab.title, customTitle: tab.customTitle, pinnedURL: tab.pinnedURL,
                customIcon: tab.customIcon, isMuted: tab.isMuted)
        }
        func copyNode(_ node: SidebarNode) -> SidebarNode {
            switch node {
            case .tab(let tab): return .tab(copyTab(tab))
            case .folder(let folder):
                let children = folder.children.map(copyNode)
                let peek = folder.children.firstIndex { $0.id == folder.peekedChildID }.map { children[$0].id }
                return .folder(Folder(title: folder.title, isExpanded: folder.isExpanded,
                    customIcon: folder.customIcon, iconOverride: folder.iconOverride, children: children, peekedChildID: peek))
            case .split(let split):
                let panes = split.panes.map(copyTab)
                let focused = split.panes.firstIndex { $0.id == split.focusedPaneID }.map { panes[$0].id }
                return .split(Split(orientation: split.orientation, fractions: split.fractions, panes: panes, focusedPaneID: focused, customTitle: split.customTitle, iconOverride: split.iconOverride))
            }
        }
        let copied = copyNode(source)
        let oldFractions: [Double]?
        if case .splitPane(let splitID) = parent { oldFractions = node(id: splitID)?.split?.fractions }
        else { oldFractions = nil }
        guard let index = attach(copied, to: parent, at: position + 1) else { return nil }
        func updateFractions(_ model: BrowserModel, restoring: Bool) {
            guard case .splitPane(let splitID) = parent, let split = model.node(id: splitID)?.split else { return }
            split.fractions = restoring ? (oldFractions ?? []) : Array(repeating: 1 / Double(split.panes.count), count: split.panes.count)
        }
        updateFractions(self, restoring: false)
        let revert: Revert = { model in
            guard model.detach(copied.id) != nil else { return false }
            updateFractions(model, restoring: true); return true
        }
        registerUndo(revert, reapply: { model in
            guard model.attach(copied, to: parent, at: index) != nil else { return Self.noRevert }
            updateFractions(model, restoring: false); return revert
        })
        return copied.id
    }

    @discardableResult
    public func newTab(in spaceID: SpaceID, url: URL, title: String = "", at position: Int? = nil, unread: Bool = false) -> Tab {
        let tab = Tab(url: url, title: title, isUnread: unread)
        let parent = NodeParent.spaceToday(spaceID)
        guard let i = attach(.tab(tab), to: parent, at: position ?? 0) else { return tab }
        let revert: Revert = { $0.detach(tab.id) != nil }
        registerUndo(revert, reapply: { model in
            model.attach(.tab(tab), to: parent, at: i) != nil ? revert : Self.noRevert
        })
        return tab
    }

    /// Untitled Spaces use their current 1-based position, without storing a title.
    public func displayTitle(for space: Space) -> String {
        if let title = space.title, !title.isEmpty { return title }
        return "Space \((spaces.firstIndex { $0.id == space.id } ?? 0) + 1)"
    }

    /// Property-only changes: Observation updates readers; no TreeChange is emitted.
    public func setPinnedSectionCollapsed(spaceID: SpaceID, collapsed: Bool) {
        guard let space = space(id: spaceID), space.isPinnedCollapsed != collapsed else { return }
        let old = space.isPinnedCollapsed
        space.isPinnedCollapsed = collapsed
        registerChange(undo: { space.isPinnedCollapsed = old }, redo: { space.isPinnedCollapsed = collapsed })
    }

    public func setMuted(tabID: ItemID, muted: Bool) {
        guard let tab = tab(id: tabID), tab.isMuted != muted else { return }
        let old = tab.isMuted
        tab.isMuted = muted
        registerChange(undo: { tab.isMuted = old }, redo: { tab.isMuted = muted })
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
        // A Live Folder row the user deletes stays hidden on later refreshes (live-data §2.7,
        // Arc `liveFolderChildItemManuallyDeleted`). Undo un-hides it, or the next refresh
        // would remove the restored row again.
        let live = noteLiveRowLeaving(id)
        guard let revert = closeNode(id) else { live?(); return }
        registerUndo(Self.restoringLive(revert, [live]), reapply: { model in
            let live = model.noteLiveRowLeaving(id)
            guard let revert = model.closeNode(id) else { live?(); return Self.noRevert }
            return Self.restoringLive(revert, [live])
        })
    }

    private func closeNode(_ id: ItemID) -> Revert? {
        if index[id]?.folder != nil { return archiveFolderNode(id) }
        guard let node = index[id], let parent = parentByID[id] else { return nil }
        let entries = archiveEntries(for: node, in: parent, reason: node.folder != nil ? .folderDeleted : .closed)
        guard let removed = detach(id) else { return nil }
        archive(entries)
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.attach(removed.node, to: removed.parent, at: removed.index, restoringPeek: removed.clearedPeek) != nil else { return false }
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

    /// Stages a restore around the caller's durable snapshot commit. Failure rolls back the
    /// live insertion and publishes neither archive deletion nor an Undo action.
    @discardableResult
    public func restoreArchivedTab(_ record: ArchivedTabRecord, saving: () throws -> Void) throws -> Tab {
        if let existing = tab(id: record.id) { return existing }
        let tab = Self.tab(from: record)
        tab.lastActiveAt = Date()
        guard let destination = restoreDestination(for: record),
              let revert = place(restored: tab, from: record, into: destination, discardArchive: false) else { return tab }
        do { try saving() }
        catch { _ = detach(tab.id); throw error }
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

    private func place(restored tab: Tab, from record: ArchivedTabRecord, into parent: NodeParent, discardArchive: Bool = true) -> Revert? {
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
        if discardArchive { archiveSink?.discardArchived(ids: [tab.id]) }
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
        var id: String?
        var url: String?
        var title: String?
        var customTitle: String?
        var pinnedURL: String?
        var customIcon: String?
        var iconOverride: SpaceIcon?
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
                   iconOverride: payload?.iconOverride,
                   createdAt: payload?.createdAt.map { Date(timeIntervalSince1970: $0) } ?? record.archivedAt,
                   lastActiveAt: payload?.lastActiveAt.map { Date(timeIntervalSince1970: $0) } ?? record.archivedAt,
                   isMuted: payload?.isMuted ?? false,
                   openerID: payload?.openerID.flatMap { UUID(uuidString: $0) }.map { ItemID(rawValue: $0) },
                   isUnread: payload?.isUnread ?? false)
    }

    // MARK: Folder archive (Delete retains the subtree as one record)

    private func folderEntry(_ folder: Folder, parent: NodeParent, archivedAt: Date = Date()) -> ArchiveFolderEntry {
        let owner = owner(of: parent)
        return ArchiveFolderEntry(folder: folder, originalLocation: parent.archiveLocation,
                                  spaceID: owner.space, profileID: owner.profile, archivedAt: archivedAt,
                                  originalSection: section(of: parent)?.archiveLocation)
    }

    @discardableResult
    public func archiveFolder(id: ItemID) -> Bool {
        guard let revert = archiveFolderNode(id) else { return false }
        registerUndo(revert, reapply: { $0.archiveFolderNode(id) ?? Self.noRevert })
        return true
    }

    private func archiveFolderNode(_ id: ItemID) -> Revert? {
        guard let folder = index[id]?.folder, let parent = parentByID[id] else { return nil }
        let entry = folderEntry(folder, parent: parent)
        guard let removed = detach(id) else { return nil }
        archiveSink?.archiveFolder(entry)
        return { model in
            guard model.attach(removed.node, to: removed.parent, at: removed.index, restoringPeek: removed.clearedPeek) != nil else { return false }
            model.archiveSink?.discardArchived(ids: [id])
            return true
        }
    }

    /// Mirrors SnapshotDTOs' enum envelope and keys. Only folder records enter this path.
    private indirect enum ArchivedNodePayload: Decodable {
        case tab(ArchivedTabPayload), folder(ArchivedFolderPayload), split(ArchivedSplitPayload)
    }
    private struct ArchivedFolderPayload: Decodable {
        var kind: ArchiveRecordKind?
        var id: String
        var title: String
        var isExpanded: Bool
        var customIcon: String?
        var iconOverride: SpaceIcon?
        var children: [ArchivedNodePayload]
        var originalSection: String?
    }
    private struct ArchivedSplitPayload: Decodable {
        var id: String
        var orientation: SplitOrientation
        var fractions: [Double]
        var panes: [ArchivedTabPayload]
        var focusedPaneID: String?
        var customTitle: String?
        var iconOverride: SpaceIcon?
    }

    private func decodedFolder(_ record: ArchivedTabRecord) -> (Folder, String?)? {
        guard record.kind == .folder, index[record.id] == nil,
              let data = record.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ArchivedFolderPayload.self, from: data),
              payload.kind == .folder, UUID(uuidString: payload.id) == record.id.rawValue else { return nil }
        var used = Set(index.keys)
        func identity(_ raw: String?) -> ItemID? {
            guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
            let id = ItemID(rawValue: uuid)
            return used.insert(id).inserted ? id : nil
        }
        func tab(_ payload: ArchivedTabPayload) -> Tab? {
            guard let id = identity(payload.id) else { return nil }
            return Tab(id: id, url: payload.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!,
                       title: payload.title ?? "", customTitle: payload.customTitle,
                       pinnedURL: payload.pinnedURL.flatMap(URL.init(string:)), customIcon: payload.customIcon,
                       iconOverride: payload.iconOverride,
                       createdAt: payload.createdAt.map(Date.init(timeIntervalSince1970:)) ?? record.archivedAt,
                       lastActiveAt: Date(), isMuted: payload.isMuted ?? false,
                       openerID: payload.openerID.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) },
                       isUnread: payload.isUnread ?? false)
        }
        func folder(_ payload: ArchivedFolderPayload) -> Folder? {
            guard let id = identity(payload.id) else { return nil }
            return Folder(id: id, title: payload.title, isExpanded: payload.isExpanded, customIcon: payload.customIcon,
                          iconOverride: payload.iconOverride,
                          children: payload.children.compactMap(node))
        }
        func node(_ payload: ArchivedNodePayload) -> SidebarNode? {
            switch payload {
            case .tab(let payload): return tab(payload).map(SidebarNode.tab)
            case .folder(let payload): return folder(payload).map(SidebarNode.folder)
            case .split(let payload):
                guard let id = identity(payload.id) else { return nil }
                let panes = payload.panes.compactMap(tab)
                if panes.count == 1 { return .tab(panes[0]) }
                guard (2...4).contains(panes.count) else { return nil }
                let shares = panes.map { pane in
                    payload.panes.firstIndex { $0.id.flatMap(UUID.init(uuidString:)) == pane.id.rawValue }
                        .flatMap { payload.fractions.indices.contains($0) ? payload.fractions[$0] : nil } ?? 0
                }
                let sum = shares.reduce(0, +)
                let fractions = shares.allSatisfy { $0.isFinite && $0 >= 0 } && sum.isFinite && sum > 0
                    ? shares.map { $0 / sum } : Array(repeating: 1 / Double(panes.count), count: panes.count)
                let focused = payload.focusedPaneID.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) }
                return .split(Split(id: id, orientation: payload.orientation, fractions: fractions, panes: panes,
                                    focusedPaneID: panes.first { $0.id == focused }?.id ?? panes.first?.id,
                                    customTitle: payload.customTitle, iconOverride: payload.iconOverride))
            }
        }
        guard let result = folder(payload) else { return nil }
        return (result, payload.originalSection)
    }

    private func folderRestoreDestination(_ record: ArchivedTabRecord, section originalSection: String?) -> NodeParent? {
        if let original = NodeParent(archiveLocation: record.originalLocation), parentExists(original) {
            switch original {
            case .spacePinned, .spaceToday, .folder: return original
            case .favorites, .splitPane: break
            }
        }
        if let spaceID = record.spaceID, space(id: spaceID) != nil {
            if let originalSection, case .spacePinned? = NodeParent(archiveLocation: originalSection) { return .spacePinned(spaceID) }
            if case .spacePinned? = NodeParent(archiveLocation: record.originalLocation) { return .spacePinned(spaceID) }
            return .spaceToday(spaceID)
        }
        return targetSpace(forProfile: record.profileID).map(NodeParent.spaceToday)
    }

    @discardableResult
    public func restoreArchivedFolder(_ record: ArchivedTabRecord) -> Folder? {
        // This overload has no I/O; the Library uses the durable-save overload below.
        try? restoreArchivedFolder(record, saving: {}, discardArchive: true)
    }

    @discardableResult
    public func restoreArchivedFolder(_ record: ArchivedTabRecord, saving: () throws -> Void) throws -> Folder? {
        try restoreArchivedFolder(record, saving: saving, discardArchive: false)
    }

    private func restoreArchivedFolder(_ record: ArchivedTabRecord, saving: () throws -> Void, discardArchive: Bool) throws -> Folder? {
        guard let (folder, originalSection) = decodedFolder(record),
              let destination = folderRestoreDestination(record, section: originalSection) else { return nil }
        func place(_ model: BrowserModel, discard: Bool) -> Revert? {
            guard model.index[folder.id] == nil, model.parentExists(destination) else { return nil }
            let prior = model.applyPinnedRule(to: .folder(folder), from: .spacePinned(record.spaceID ?? SpaceID()),
                                              to: model.section(of: destination))
            for tab in model.tabs(under: .folder(folder)) { tab.lastActiveAt = Date() }
            guard model.attach(.folder(folder), to: destination, at: 0) != nil else { Self.restore(prior); return nil }
            if discard { model.archiveSink?.discardArchived(ids: [folder.id]) }
            return { model in
                guard model.detach(folder.id) != nil else { return false }
                Self.restore(prior)
                model.archiveSink?.archiveFolder(ArchiveFolderEntry(folder: folder, originalLocation: record.originalLocation,
                    spaceID: record.spaceID, profileID: record.profileID, archivedAt: record.archivedAt, originalSection: originalSection,
                    reason: record.reason))
                return true
            }
        }
        guard let revert = place(self, discard: false) else { return nil }
        do { try saving() } catch { _ = detach(folder.id); throw error }
        if discardArchive { archiveSink?.discardArchived(ids: [folder.id]) }
        registerUndo(revert, reapply: { place($0, discard: true) ?? Self.noRevert })
        return folder
    }

    // MARK: move / folders / rename / expand

    /// Moves one plain tab between independent window models, keeping the Tab
    /// and its ID/live state. No Archive or Undo entry: the tab still exists.
    /// `adopt` commits external ownership synchronously, before tree observers
    /// run. It must not mutate either model; false rolls back without events.
    @discardableResult
    public func transferTab(id: ItemID, from source: BrowserModel, to destination: NodeParent,
                            at position: Int, adopt: @MainActor () -> Bool) -> Bool {
        guard source !== self, position >= 0, index[id] == nil,
              let node = source.index[id], node.tab != nil,
              let parent = source.parentByID[id], source.parentExists(parent), parentExists(destination),
              source.owner(of: parent).profile == owner(of: destination).profile else { return false }
        if case .splitPane = parent { return false }
        if case .splitPane = destination { return false }
        guard let removed = source.removeChild(id, from: parent) else { return false }
        guard let inserted = insertChild(node, into: destination, at: position) else {
            _ = source.insertChild(node, into: parent, at: removed.index); return false
        }
        source.unregister(node); register(node, under: destination)
        let pinned = applyPinnedRule(to: node, from: source.section(of: parent), to: section(of: destination))
        guard adopt() else {
            Self.restore(pinned); _ = removeChild(id, from: destination, at: inserted)
            unregister(node); _ = source.insertChild(node, into: parent, at: removed.index)
            source.register(node, under: parent); return false
        }
        _ = source.clearPeek(in: parent, removing: id)
        // Both graphs and the external owner are final before either callback.
        source.emit(.remove(parent: parent, index: removed.index, nodeID: id))
        emit(.insert(parent: destination, index: inserted, nodeID: id))
        return true
    }

    /// Moves a node. In a same-parent reorder, `position` counts after the node's removal.
    /// Returns false, with no change and no event, when the move breaks a placement rule.
    @discardableResult
    public func moveNode(id: ItemID, to destination: NodeParent, at position: Int?) -> Bool {
        // A refused move must not hide the row; Undo puts the row back as a live row.
        let live = noteLiveRowLeaving(id, to: destination)
        guard let revert = move(id, to: destination, at: position) else { live?(); return false }
        registerUndo(Self.restoringLive(revert, [live]), reapply: { model in
            let live = model.noteLiveRowLeaving(id, to: destination)
            guard let revert = model.move(id, to: destination, at: position) else { live?(); return Self.noRevert }
            return Self.restoringLive(revert, [live])
        })
        return true
    }

    private func move(_ id: ItemID, to destination: NodeParent, at position: Int?) -> Revert? {
        guard canMoveNode(id: id, to: destination) else { return nil }
        return relocate(id, to: destination, at: position)
    }

    /// Placement rules: only tabs enter Favorites (folders and splits never do); splits live
    /// in a Space's pinned or Today section or in a folder; panes move only through split
    /// commands; a folder never enters itself or its own descendant.
    public func canMoveNode(id: ItemID, to destination: NodeParent) -> Bool {
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

    /// Removes duplicates and descendants of selected containers, preserving display order.
    private func topLevelSelection(_ ids: [ItemID]) -> [ItemID] {
        let selected = Set(ids)
        var seen = Set<ItemID>()
        return ids.filter { id in
            guard index[id] != nil, seen.insert(id).inserted else { return false }
            var parent = parentByID[id]
            while let current = parent {
                switch current {
                case .folder(let ancestor), .splitPane(let ancestor):
                    if selected.contains(ancestor) { return false }
                    parent = parentByID[ancestor]
                default: return true
                }
            }
            return true
        }
    }

    private static func combined(_ reverts: [Revert]) -> Revert? {
        guard !reverts.isEmpty else { return nil }
        return { model in
            var changed = false
            for revert in reverts.reversed() { if revert(model) { changed = true } }
            return changed
        }
    }

    private func childIDs(in parent: NodeParent) -> [ItemID] {
        switch parent {
        case .spacePinned(let id): return space(id: id)?.pinned.map(\.id) ?? []
        case .spaceToday(let id): return space(id: id)?.today.map(\.id) ?? []
        case .folder(let id): return index[id]?.folder?.children.map(\.id) ?? []
        case .favorites(let id): return profile(id: id)?.favorites.map(\.id) ?? []
        case .splitPane(let id): return index[id]?.split?.panes.map(\.id) ?? []
        }
    }

    /// Bulk drop positions count in the destination before removal, unlike moveNode.
    @discardableResult
    public func moveNodes(ids: [ItemID], to destination: NodeParent, at position: Int? = nil) -> Int {
        let result = moveMany(ids, to: destination, at: position)
        if let revert = result.revert {
            registerUndo(revert, reapply: { $0.moveMany(ids, to: destination, at: position).revert ?? Self.noRevert })
        }
        return result.count
    }

    /// Prefix counts of removed original slots. Keeps bulk positions in O(log n),
    /// without rescanning a changing source or destination list for each node.
    private struct RemovalOffsets {
        var sums: [Int]
        init(count: Int) { sums = Array(repeating: 0, count: count + 1) }
        mutating func remove(at position: Int) {
            var i = position + 1
            while i < sums.count { sums[i] += 1; i += i & -i }
        }
        func before(_ position: Int) -> Int {
            var i = position, result = 0
            while i > 0 { result += sums[i]; i -= i & -i }
            return result
        }
    }

    private func moveMany(_ ids: [ItemID], to destination: NodeParent, at position: Int?) -> (count: Int, revert: Revert?, moved: [ItemID]) {
        let moving = topLevelSelection(ids).filter { canMoveNode(id: $0, to: destination) }
        guard !moving.isEmpty else { return (0, nil, []) }
        let old = childIDs(in: destination), selected = Set(moving)
        let requested = max(0, min(position ?? old.count, old.count))
        let start = requested - old.prefix(requested).filter { selected.contains($0) }.count
        let remaining = old.filter { !selected.contains($0) }
        var target = remaining
        target.insert(contentsOf: moving, at: start)
        guard old != target else { return (0, nil, []) }
        let sources = Dictionary(uniqueKeysWithValues: moving.compactMap { id in parentByID[id].map { (id, $0) } })
        let parents = Set(sources.values).union([destination])
        let positions = Dictionary(uniqueKeysWithValues: parents.map { parent in
            (parent, Dictionary(uniqueKeysWithValues: childIDs(in: parent).enumerated().map { ($0.element, $0.offset) }))
        })
        var offsets = Dictionary(uniqueKeysWithValues: positions.map { ($0.key, RemovalOffsets(count: $0.value.count)) })
        let boundary = start < remaining.count ? positions[destination]?[remaining[start]] : nil
        var reverts: [Revert] = [], moved: [ItemID] = []
        var processed = 0, destinationCount = old.count
        for id in moving {
            guard let source = sources[id], let original = positions[source]?[id] else { continue }
            let fromIndex = original - (offsets[source]?.before(original) ?? 0)
                + (source == destination && boundary.map { original >= $0 } == true ? processed : 0)
            var slot = boundary.map { $0 - (offsets[destination]?.before($0) ?? 0) + processed } ?? destinationCount
            if source == destination && fromIndex < slot { slot -= 1 }
            if source != destination || fromIndex != slot {
                guard let revert = relocate(id, to: destination, at: slot, fromIndex: fromIndex) else { continue }
                reverts.append(revert); moved.append(id)
            }
            // Even a same-slot item joins the logical inserted block. It emits no move.
            offsets[source]?.remove(at: original)
            processed += 1
            if source != destination { destinationCount += 1 }
        }
        return (moved.count, Self.combined(reverts), moved)
    }

    @discardableResult
    public func moveNodes(ids: [ItemID], toSpace spaceID: SpaceID, markUnread: Bool = false) -> Int {
        let result = moveManyToSpace(ids, spaceID: spaceID, markUnread: markUnread)
        if let revert = result.revert {
            registerUndo(revert, reapply: { $0.moveManyToSpace(ids, spaceID: spaceID, markUnread: markUnread).revert ?? Self.noRevert })
        }
        return result.count
    }

    private func moveManyToSpace(_ ids: [ItemID], spaceID: SpaceID, markUnread: Bool) -> (count: Int, revert: Revert?) {
        guard space(id: spaceID) != nil else { return (0, nil) }
        let selected = topLevelSelection(ids).filter { canMoveNode(id: $0, to: .spaceToday(spaceID)) }
        var pinned: [ItemID] = [], today: [ItemID] = []
        for id in selected {
            guard let parent = parentByID[id] else { continue }
            if case .spacePinned? = section(of: parent) { pinned.append(id) } else { today.append(id) }
        }
        let p = moveMany(pinned, to: .spacePinned(spaceID), at: 0)
        let t = moveMany(today, to: .spaceToday(spaceID), at: 0)
        guard let structural = Self.combined([p.revert, t.revert].compactMap { $0 }) else { return (0, nil) }
        let unread = markUnread ? (p.moved + t.moved).compactMap { index[$0] }.flatMap { tabs(under: $0) }.map { ($0, $0.isUnread) } : []
        for (tab, _) in unread { tab.isUnread = true }
        return (p.count + t.count, { model in
            guard structural(model) else { return false }
            for (tab, old) in unread where model.tab(id: tab.id) === tab { tab.isUnread = old }
            return true
        })
    }

    @discardableResult
    public func archiveNodes(ids: [ItemID], archiveFolderTabs: Bool = false) -> Int {
        let live = ids.map { noteLiveRowLeaving($0) }
        let result = archiveMany(ids, archiveFolderTabs: archiveFolderTabs)
        guard let revert = result.revert else { live.forEach { $0?() }; return result.count }
        registerUndo(Self.restoringLive(revert, live), reapply: { model in
            let live = ids.map { model.noteLiveRowLeaving($0) }
            guard let revert = model.archiveMany(ids, archiveFolderTabs: archiveFolderTabs).revert else { live.forEach { $0?() }; return Self.noRevert }
            return Self.restoringLive(revert, live)
        })
        return result.count
    }

    private func archiveMany(_ ids: [ItemID], archiveFolderTabs: Bool = false) -> (count: Int, revert: Revert?) {
        let selected = topLevelSelection(ids)
        // Stable parent grouping; remove the highest indexes first in each list.
        var parents: [NodeParent] = []
        var groups: [NodeParent: [ItemID]] = [:]
        for id in selected {
            guard let parent = parentByID[id] else { continue }
            if groups[parent] == nil { parents.append(parent) }
            groups[parent, default: []].append(id)
        }
        let positions = Dictionary(uniqueKeysWithValues: parents.map { parent in
            (parent, Dictionary(uniqueKeysWithValues: childIDs(in: parent).enumerated().map { ($0.element, $0.offset) }))
        })
        let sources = Dictionary(uniqueKeysWithValues: selected.compactMap { id in parentByID[id].map { (id, $0) } })
        let ordered = parents.flatMap { parent in
            (groups[parent] ?? []).sorted { (positions[parent]?[$0] ?? 0) > (positions[parent]?[$1] ?? 0) }
        }
        let now = Date()
        let ownership = Dictionary(uniqueKeysWithValues: parents.map { ($0, owner(of: $0)) })
        var entries: [ArchiveEntry] = []
        var folders: [ArchiveFolderEntry] = []
        var reverts: [Revert] = []
        for id in ordered {
            guard let node = index[id], let originalParent = sources[id] else { continue }
            // Preserve the original location before a pane collapse, but publish
            // archive records only after this node actually leaves the tree.
            let nodeEntries = node.folder == nil || archiveFolderTabs ? archiveEntries(for: node, in: originalParent, reason: .closed, at: now, ownership: ownership[originalParent]) : []
            let folder = archiveFolderTabs ? nil : node.folder.map { folderEntry($0, parent: originalParent, archivedAt: now) }
            let revert: Revert?
            if case .splitPane(let splitID)? = parentByID[id], let split = index[splitID]?.split,
               let taken = takePane(id, from: split) { revert = taken }
            else {
                let slot = sources[id].flatMap { parent in parentByID[id] == parent ? positions[parent]?[id] : nil }
                if let removed = detach(id, at: slot) {
                    revert = { model in
                        guard model.attach(removed.node, to: removed.parent, at: removed.index, restoringPeek: removed.clearedPeek) != nil else { return false }
                        return true
                    }
                } else { revert = nil }
            }
            guard let revert else { continue }
            reverts.append(revert)
            entries.append(contentsOf: nodeEntries)
            if let folder { folders.append(folder) }
        }
        guard let structural = Self.combined(reverts) else { return (0, nil) }
        archiveSink?.archive(entries, folders: folders)
        return (reverts.count, { model in
            guard structural(model) else { return false }
            model.archiveSink?.discardArchived(ids: (entries.map { $0.tab.id } + folders.map { $0.folder.id }).filter { model.index[$0] != nil })
            return true
        })
    }

    @discardableResult
    public func setPinned(ids: [ItemID], pinned: Bool) -> Int {
        let result = pinMany(ids, pinned: pinned)
        if let revert = result.revert { registerUndo(revert, reapply: { $0.pinMany(ids, pinned: pinned).revert ?? Self.noRevert }) }
        return result.count
    }

    private func pinMany(_ ids: [ItemID], pinned: Bool) -> (count: Int, revert: Revert?) {
        var groups: [SpaceID: [ItemID]] = [:], order: [SpaceID] = []
        for id in topLevelSelection(ids) {
            guard let node = index[id], node.folder == nil, let parent = parentByID[id] else { continue }
            if case .splitPane = parent { continue }
            let spaceID: SpaceID
            switch section(of: parent) {
            case .spaceToday(let id)? where pinned: spaceID = id
            case .spacePinned(let id)? where !pinned: spaceID = id
            default: continue
            }
            if groups[spaceID] == nil { order.append(spaceID) }
            groups[spaceID, default: []].append(id)
        }
        var reverts: [Revert] = [], count = 0
        for spaceID in order {
            let result = moveMany(groups[spaceID] ?? [], to: pinned ? .spacePinned(spaceID) : .spaceToday(spaceID), at: pinned ? nil : 0)
            count += result.count
            if let revert = result.revert { reverts.append(revert) }
        }
        return (count, Self.combined(reverts))
    }

    @discardableResult
    public func duplicateNodes(ids: [ItemID]) -> [ItemID] {
        var copies: [(node: SidebarNode, parent: NodeParent, source: ItemID)] = []
        for id in topLevelSelection(ids) {
            guard let node = index[id], let parent = parentByID[id] else { continue }
            if case .splitPane = parent { continue }
            let destination: NodeParent
            if case .favorites(let profileID) = parent {
                guard let spaceID = targetSpace(forProfile: profileID) else { continue }
                destination = .spaceToday(spaceID)
            } else { destination = parent }
            copies.append((copyNode(node), destination, id))
        }
        func insert(_ model: BrowserModel) -> Revert? {
            var inserted: [ItemID] = []
            for copy in copies {
                let slot = model.parentByID[copy.source] == copy.parent ? model.position(of: copy.source, in: copy.parent).map { $0 + 1 } : 0
                guard model.parentExists(copy.parent), model.index[copy.node.id] == nil else { continue }
                _ = model.applyPinnedRule(to: copy.node, from: model.parentByID[copy.source].flatMap { model.section(of: $0) }, to: model.section(of: copy.parent))
                if model.attach(copy.node, to: copy.parent, at: slot) != nil { inserted.append(copy.node.id) }
            }
            let ids = inserted
            guard !ids.isEmpty else { return nil }
            return { model in
                var changed = false
                for id in ids.reversed() { if model.detach(id) != nil { changed = true } }
                return changed
            }
        }
        guard let revert = insert(self) else { return [] }
        registerUndo(revert, reapply: { insert($0) ?? Self.noRevert })
        return copies.map { $0.node.id }
    }

    private func copyNode(_ node: SidebarNode) -> SidebarNode {
        func copyTab(_ tab: Tab) -> Tab {
            Tab(url: tab.url, title: tab.title, customTitle: tab.customTitle, pinnedURL: tab.pinnedURL,
                customIcon: tab.customIcon, iconOverride: tab.iconOverride, isMuted: tab.isMuted)
        }
        switch node {
        case .tab(let tab): return .tab(copyTab(tab))
        case .folder(let folder):
            let children = folder.children.map { copyNode($0) }
            let peek = folder.children.firstIndex { $0.id == folder.peekedChildID }.map { children[$0].id }
            return .folder(Folder(title: folder.title, isExpanded: folder.isExpanded, customIcon: folder.customIcon,
                                  iconOverride: folder.iconOverride, children: children, peekedChildID: peek))
        case .split(let split):
            let panes = split.panes.map(copyTab)
            let focus = split.panes.firstIndex { $0.id == split.focusedPaneID }.map { panes[$0].id }
            return .split(Split(orientation: split.orientation, fractions: split.fractions, panes: panes, focusedPaneID: focus, customTitle: split.customTitle, iconOverride: split.iconOverride))
        }
    }

    @discardableResult
    public func setAllFoldersExpanded(spaceID: SpaceID, expanded: Bool) -> Int {
        guard let space = space(id: spaceID) else { return 0 }
        var changed: [(Folder, FolderExpansion)] = []
        let target: FolderExpansion = expanded ? .expanded : .collapsed
        func visit(_ nodes: [SidebarNode]) {
            for node in nodes {
                guard let folder = node.folder else { continue }
                if folder.expansion != target { changed.append((folder, folder.expansion)) }
                visit(folder.children)
            }
        }
        visit(space.pinned); visit(space.today)
        guard !changed.isEmpty else { return 0 }
        for (folder, _) in changed { folder.applyExpansion(target) }
        registerChange(undo: { for (folder, old) in changed { folder.applyExpansion(old) } },
                       redo: { for (folder, _) in changed { folder.applyExpansion(target) } })
        return changed.count
    }

    @discardableResult
    public func resetPinnedTabs(spaceID: SpaceID) -> [ItemID] {
        guard let space = space(id: spaceID) else { return [] }
        let changed = space.pinned.flatMap { tabs(under: $0) }.filter { Self.leftPinnedURL($0) }
        guard !changed.isEmpty else { return [] }
        let old = changed.map { ($0, $0.url, $0.lastActiveAt) }, now = Date()
        for tab in changed { if let pinned = tab.pinnedURL { tab.url = pinned }; tab.lastActiveAt = now }
        registerChange(undo: { for (tab, url, date) in old { tab.url = url; tab.lastActiveAt = date } },
                       redo: { for tab in changed { if let pinned = tab.pinnedURL { tab.url = pinned }; tab.lastActiveAt = Date() } })
        return changed.map(\.id)
    }

    private static func leftPinnedURL(_ tab: Tab) -> Bool {
        guard let pinned = tab.pinnedURL else { return false }
        return tab.url.host != pinned.host || tab.url.path != pinned.path
    }

    @discardableResult
    public func separateFromPinnedTab(id: ItemID) -> Tab? {
        guard let tab = tab(id: id), isPinned(tabID: id), Self.leftPinnedURL(tab),
              let parent = parentByID[id], let spaceID = owner(of: parent).space else { return nil }
        let copy = Tab(url: tab.url, title: tab.title, isMuted: tab.isMuted)
        func separate(_ model: BrowserModel) -> Revert? {
            guard model.tab(id: id) === tab, model.isPinned(tabID: id), let pinned = tab.pinnedURL else { return nil }
            let oldURL = tab.url, oldDate = tab.lastActiveAt
            guard model.attach(.tab(copy), to: .spaceToday(spaceID), at: 0) != nil else { return nil }
            tab.url = pinned; tab.lastActiveAt = Date()
            return { model in
                guard model.detach(copy.id) != nil else { return false }
                if model.tab(id: id) === tab { tab.url = oldURL; tab.lastActiveAt = oldDate }
                return true
            }
        }
        guard let revert = separate(self) else { return nil }
        registerUndo(revert, reapply: { separate($0) ?? Self.noRevert })
        return copy
    }

    @discardableResult
    public func turnFolderIntoSpace(id: ItemID) -> Space? {
        guard let folder = index[id]?.folder, let parent = parentByID[id],
              let sourceID = owner(of: parent).space, let source = space(id: sourceID) else { return nil }
        // Menu evidence: docs/re/sidebar-completion.md §6, FUN_102eb4d38 / F0119.
        // Children + folder removal in one step: space-theme-editor §8. Today
        // placement is the Section 1 items 9–10 implementation brief's rule.
        let created = Space(title: folder.title, profileID: source.profileID)
        func turn(_ model: BrowserModel) -> Revert? {
            guard model.index[id]?.folder === folder, model.space(id: sourceID) != nil,
                  model.space(id: created.id) == nil, let parent = model.parentByID[id],
                  let position = model.position(of: id, in: parent) else { return nil }
            let children = folder.children, section = model.section(of: parent)
            // Observers must see the final ownership, so a live page is not
            // closed during the brief interval between removal and insertion.
            model.spaceCreationEvents = []
            guard model.detach(id) != nil else { model.spaceCreationEvents = nil; return nil }
            folder.children = []
            created.today = children
            let childPrior = children.flatMap { model.applyPinnedRule(to: $0, from: section, to: .spaceToday(created.id)) }
            model.insertSpace(created, at: model.spaces.count)
            model.emit(.reload(parent: .spaceToday(created.id)))
            let events = model.spaceCreationEvents ?? []; model.spaceCreationEvents = nil
            for event in events { model.emit(event) }
            return { model in
                guard model.space(id: created.id) === created, model.index[id] == nil,
                      model.space(id: sourceID) != nil, created.pinned.isEmpty,
                      created.today.map(\.id) == children.map(\.id) else { return false }
                // A Today sweep can remove nodes without an undo entry. Never
                // resurrect those nodes or detach a Space into a missing parent.
                if case .folder(let parentID) = parent, model.index[parentID]?.folder == nil { return false }
                let focused = model.windows.filter { $0.focusedSpaceID == created.id }
                model.spaceCreationEvents = []
                model.removeSpace(created.id)
                created.today = []
                folder.children = children
                Self.restore(childPrior)
                _ = model.attach(.folder(folder), to: parent, at: position)
                for window in focused { window.focusedSpaceID = sourceID }
                model.emit(.reload(parent: .spaceToday(created.id)))
                let events = model.spaceCreationEvents ?? []; model.spaceCreationEvents = nil
                for event in events { model.emit(event) }
                return true
            }
        }
        guard let revert = turn(self) else { return nil }
        registerUndo(revert, reapply: { turn($0) ?? Self.noRevert })
        return created
    }

    @discardableResult
    public func turnSpaceIntoFolder(id: SpaceID, destination: SpaceID) -> Folder? {
        guard id != destination, spaces.count > 1, let source = space(id: id), space(id: destination) != nil else { return nil }
        let folder = Folder(title: displayTitle(for: source))
        func turn(_ model: BrowserModel) -> Revert? {
            guard let source = model.space(id: id), model.space(id: destination) != nil, model.spaces.count > 1,
                  let slot = model.spaces.firstIndex(where: { $0.id == id }), model.index[folder.id] == nil else { return nil }
            let pinned = source.pinned, today = source.today
            let focused = model.windows.filter { $0.focusedSpaceID == id }
            model.removeSpace(id)
            source.pinned = []; source.today = []
            folder.children = pinned + today
            let prior = model.applyPinnedRule(to: .folder(folder), from: .spaceToday(id), to: .spacePinned(destination))
            model.attach(.folder(folder), to: .spacePinned(destination), at: 0)
            for window in focused { window.focusedSpaceID = destination }
            model.emit(.reload(parent: .spaceToday(id)))
            return { model in
                guard model.space(id: id) == nil, model.parentByID[folder.id] == .spacePinned(destination),
                      model.detach(folder.id) != nil else { return false }
                folder.children = []
                source.pinned = pinned; source.today = today
                Self.restore(prior)
                model.insertSpace(source, at: slot)
                for window in focused { window.focusedSpaceID = id }
                model.emit(.reload(parent: .spaceToday(id)))
                return true
            }
        }
        guard let revert = turn(self) else { return nil }
        registerUndo(revert, reapply: { turn($0) ?? Self.noRevert })
        return folder
    }

    /// Creates a folder at the end of `parent` and moves `nodeIDs` into it, in order.
    /// Nodes that may not move there are skipped. Nil when `parent` cannot hold a folder.
    @discardableResult
    // MARK: Live Folders (LF L2, live-data §2)

    /// The Space's GitHub Live Folder (top level of Pinned), if any.
    public func liveFolder(in spaceID: SpaceID) -> Folder? {
        space(id: spaceID)?.pinned.lazy.compactMap(\.folder).first { $0.live != nil }
    }

    /// Creates "Pull Requests" at the end of the Space's Pinned section (capture s5 b3). Undoable like New Folder.
    @discardableResult
    public func createLiveFolder(in spaceID: SpaceID, config: LiveFolderConfig, title: String = "Pull Requests") -> Folder? {
        guard liveFolder(in: spaceID) == nil, let space = space(id: spaceID),
              let folder = createFolder(in: .spacePinned(spaceID), at: space.pinned.count, title: title) else { return nil }
        folder.live = config
        return folder
    }

    /// Removes a Live Folder and its rows without Archive entries (rows are fetched data, not the
    /// user's tabs; a tab the user moved in by hand is moved out to Today first).
    public func removeLiveFolder(id: ItemID) {
        guard let folder = index[id]?.folder, folder.live != nil, let parent = parentByID[id] else { return }
        let spaceID: SpaceID? = { if case .spacePinned(let s)? = section(of: parent) { return s }; return nil }()
        for node in folder.children {
            if case .tab(let tab) = node, tab.liveItemURL != nil { continue }
            if let spaceID { _ = relocate(node.id, to: .spaceToday(spaceID), at: 0) }
        }
        _ = detach(id)
    }

    /// A fetched row leaves its Live Folder by the user's action (archive, Remove Pin, drag out):
    /// remember it as hidden so later refreshes do not bring it back, and make it a normal tab.
    /// Returns the closure that undoes the note (un-hides the row and makes it live again), or nil
    /// when `id` is not a fetched row leaving its Live Folder.
    func noteLiveRowLeaving(_ id: ItemID, to destination: NodeParent? = nil) -> LiveRowRestore? {
        guard let tab = tab(id: id), let url = tab.liveItemURL, case .folder(let folderID)? = parentByID[id],
              destination != .folder(folderID), let folder = index[folderID]?.folder, folder.live != nil else { return nil }
        let key = url.absoluteString
        let hid = folder.live?.hiddenItems.insert(key).inserted == true
        let cleared = destination != nil
        if cleared { tab.liveItemURL = nil }
        return {
            if hid { folder.live?.hiddenItems.remove(key) }
            if cleared, tab.liveItemURL == nil { tab.liveItemURL = url }
        }
    }

    typealias LiveRowRestore = @MainActor () -> Void

    /// Runs `restores` after `revert` puts the nodes back.
    private static func restoringLive(_ revert: @escaping Revert, _ restores: [LiveRowRestore?]) -> Revert {
        let restores = restores.compactMap { $0 }
        guard !restores.isEmpty else { return revert }
        return { model in
            guard revert(model) else { return false }
            restores.forEach { $0() }
            return true
        }
    }

    /// Every Live Folder in the model (any Space).
    public var liveFolders: [Folder] { spaces.compactMap { liveFolder(in: $0.id) } }

    /// Hides or shows a repository's rows (folder menu ▸ Repositories). The next refresh applies it.
    public func setLiveRepository(folderID: ItemID, repository: String, hidden: Bool) {
        guard let folder = index[folderID]?.folder, folder.live != nil else { return }
        if hidden { folder.live?.hiddenRepositories.insert(repository) } else { folder.live?.hiddenRepositories.remove(repository) }
        if hidden {
            for node in folder.children {
                if case .tab(let tab) = node, let url = tab.liveItemURL, LiveFolderConfig.repository(of: url) == repository { _ = detach(tab.id) }
            }
        }
    }

    /// Applies one refresh to a Live Folder: no undo step, no Archive (a merged PR just leaves).
    /// Only rows with `liveItemURL` are removed or retitled. Returns the IDs of added rows.
    @discardableResult
    public func applyLiveRows(folderID: ItemID, add: [(url: URL, title: String)], remove: [ItemID], retitle: [ItemID: String],
                              unread: Bool, info: [URL: LiveItemInfo] = [:]) -> [ItemID] {
        guard let folder = index[folderID]?.folder, folder.live != nil else { return [] }
        for id in remove where tab(id: id)?.liveItemURL != nil && parentByID[id] == .folder(folderID) { _ = detach(id) }
        for (id, title) in retitle { if let tab = tab(id: id), tab.liveItemURL != nil, tab.customTitle == nil { tab.title = title } }
        var added: [ItemID] = []
        for item in add.reversed() {
            let tab = Tab(url: item.url, title: item.title, pinnedURL: item.url, isUnread: unread)
            tab.liveItemURL = item.url
            if attach(.tab(tab), to: .folder(folderID), at: 0) != nil { added.append(tab.id) }
        }
        // Each row's PR facts follow the fetch (glyph and hover card, C-LF-1).
        if !info.isEmpty {
            for case .tab(let tab) in folder.children {
                if let url = tab.liveItemURL, let fresh = info[url], tab.liveItem != fresh { tab.liveItem = fresh }
            }
        }
        // A new unread PR peeks out of a collapsed folder (live-data §2.2, W2).
        if unread, let first = added.first, !folder.isExpanded { folder.applyExpansion(.peeked(first)) }
        return added
    }

    public func createFolder(in parent: NodeParent, at position: Int? = nil, title: String = "Folder", withNodes nodeIDs: [ItemID] = []) -> Folder? {
        switch parent {
        case .favorites, .splitPane: return nil
        case .spacePinned, .spaceToday, .folder: break
        }
        let folder = Folder(title: title)
        guard let revert = fill(folder, in: parent, at: position, with: nodeIDs) else { return nil }
        registerUndo(revert, reapply: { $0.fill(folder, in: parent, at: position, with: nodeIDs) ?? Self.noRevert })
        return folder
    }

    private func fill(_ folder: Folder, in parent: NodeParent, at position: Int?, with nodeIDs: [ItemID]) -> Revert? {
        guard attach(.folder(folder), to: parent, at: position) != nil else { return nil }
        var moves: [Revert] = []
        for id in topLevelSelection(nodeIDs) where canMoveNode(id: id, to: .folder(folder.id)) {
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
            guard title != (old ?? tab.title), new != old else { return }
            tab.customTitle = new
            registerChange(undo: { tab.customTitle = old }, redo: { tab.customTitle = new })
        } else if let split = index[id]?.split {
            let old = split.customTitle, new = title.isEmpty ? nil : title
            guard old != new, title != split.displayTitle else { return }
            split.customTitle = new
            registerChange(undo: { split.customTitle = old }, redo: { split.customTitle = new })
        } else if let folder = index[id]?.folder {
            let old = folder.title
            guard title != old else { return }
            folder.title = title
            registerChange(undo: { folder.title = old }, redo: { folder.title = title })
        }
    }

    public func setExpanded(folderID: ItemID, expanded: Bool) {
        setFolderExpansion(folderID: folderID, expanded ? .expanded : .collapsed)
    }

    public func setFolderExpansion(folderID: ItemID, _ expansion: FolderExpansion) {
        guard let folder = index[folderID]?.folder else { return }
        if case .peeked(let child) = expansion {
            guard parentByID[child] == .folder(folderID), let node = index[child], node.folder == nil else { return }
        }
        let old = folder.expansion
        guard old != expansion else { return }
        folder.applyExpansion(expansion)
        // registerChange reaches commitMutation even without undo registration;
        // a selected peek child remains in the window's shown-tab set.
        registerChange(undo: { folder.applyExpansion(old) }, redo: { folder.applyExpansion(expansion) })
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

    /// Filled by OpenDataRoot from disk and tombstones; model commands do no I/O.
    @ObservationIgnored public var unavailableProfileDirectoryNames: Set<String> = []
    @ObservationIgnored public var onArchiveError: ((Error) -> Void)?
    /// App policy initialization, including Undo/Redo reinsertion. Must not register Undo.
    @ObservationIgnored public var onProfileCreated: ((Profile) -> Void)?

    public var defaultProfile: Profile? { profiles.first { $0.dataDirectoryName == "Default" } ?? profiles.first }

    public func spaces(using profileID: ProfileID) -> [Space] { spaces.filter { $0.profileID == profileID } }

    public func deleteBlockReason(for id: ProfileID) -> ProfileDeleteBlock? {
        guard profile(id: id) != nil else { return nil }
        if id == defaultProfile?.id { return .isDefault }
        let count = spaces(using: id).count
        return count > 0 ? .spacesAssigned(count: count) : nil
    }

    @discardableResult
    public func createProfile(name: String, icon: SpaceIcon? = nil, settings: ProfileSettings = ProfileSettings(), id: ProfileID = ProfileID()) -> Profile? {
        guard profile(id: id) == nil, Self.profileNameIssue(name, in: profiles) == nil else { return nil }
        let profile = makeProfile(name: name, icon: icon, settings: settings, id: id)
        unavailableProfileDirectoryNames.insert(profile.dataDirectoryName.lowercased())
        let slot = profiles.count
        insertProfile(profile, at: slot)
        registerUndo({ model in model.removeProfile(profile.id); return true }, reapply: { model in
            model.insertProfile(profile, at: slot)
            return { model in model.removeProfile(profile.id); return true }
        })
        return profile
    }

    private func makeProfile(name: String, icon: SpaceIcon? = nil, settings: ProfileSettings = ProfileSettings(), id: ProfileID = ProfileID()) -> Profile {
        var directory = "Default"
        if !profiles.isEmpty || unavailableProfileDirectoryNames.contains("default") {
            repeat { directory = "Profile-" + UUID().uuidString.prefix(8).uppercased() }
            while unavailableProfileDirectoryNames.contains(directory.lowercased()) || profiles.contains { $0.dataDirectoryName.caseInsensitiveCompare(directory) == .orderedSame }
        }
        return Profile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon, settings: settings, dataDirectoryName: directory)
    }

    private func insertProfile(_ profile: Profile, at slot: Int, notify: Bool = true) {
        if notify { onProfileCreated?(profile) }
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
    public func deleteProfile(id: ProfileID) throws -> Bool {
        guard let revert = try removeProfileArchiving(id) else { return false }
        registerUndo(revert, reapply: { model in
            do { return try model.removeProfileArchiving(id) ?? Self.noRevert }
            catch { model.onArchiveError?(error); return Self.noRevert }
        })
        return true
    }

    private func removeProfileArchiving(_ id: ProfileID) throws -> Revert? {
        guard let profile = profile(id: id), deleteBlockReason(for: id) == nil,
              let slot = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let now = Date()
        let entries = profile.favorites.map {
            ArchiveEntry(tab: $0, reason: .closed, originalLocation: NodeParent.favorites(id).archiveLocation,
                         spaceID: nil, profileID: id, archivedAt: now)
        }
        // Commit the archive and its directory tombstone before any model mutation.
        if let archiveSink { try archiveSink.archiveForProfileDeletion(entries, directoryName: profile.dataDirectoryName) }
        else if !entries.isEmpty { throw ProfileArchiveError.confirmationUnavailable }
        unavailableProfileDirectoryNames.insert(profile.dataDirectoryName.lowercased())
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

    /// Requires an ID obtained from a live Profile. Data/import/automation IDs
    /// must use the failable at:moving: overload. A refusal is a programmer error.
    @discardableResult
    public func createSpace(title: String, profileID: ProfileID, icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme()) -> Space {
        guard let space = createSpace(title: title, profileID: profileID, icon: icon, theme: theme, at: nil, moving: []) else {
            preconditionFailure("createSpace requires a live Profile ID; invalid profileID: \(profileID)")
        }
        return space
    }

    public enum SpaceCreationPlacement: Sendable { case pinned, today, preserveSection }

    /// Use for IDs supplied by data, import, automation, or restored state.
    /// The complete transaction refuses without writes, undo, events, or save.
    @discardableResult
    public func createSpace(title: String, profileID: ProfileID, icon: SpaceIcon?, theme: SpaceTheme,
                            at index: Int?, moving nodeIDs: [ItemID],
                            placement: SpaceCreationPlacement = .pinned, removingEmptyFolder: ItemID? = nil,
                            creatingProfileNamed: String? = nil) -> Space? {
        guard creatingProfileNamed.map({ Self.profileNameIssue($0, in: profiles) == nil }) ?? (profile(id: profileID) != nil),
              canCreateSpace(at: index, moving: nodeIDs, removingEmptyFolder: removingEmptyFolder) else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newProfile = creatingProfileNamed.map { makeProfile(name: $0) }
        let profileSlot = profiles.count
        let space = Space(title: title.isEmpty ? nil : title, icon: icon, theme: theme, profileID: newProfile?.id ?? profileID)
        let i = index ?? spaces.count
        func insert(_ model: BrowserModel) -> Revert? {
            guard model.canCreateSpace(at: i, moving: nodeIDs, removingEmptyFolder: removingEmptyFolder) else { return nil }
            if let newProfile {
                guard model.profile(id: newProfile.id) == nil else { return nil }
                model.insertProfile(newProfile, at: profileSlot, notify: false)
            }
            guard let revert = model.insertSpaceMoving(space, at: i, moving: nodeIDs, placement: placement,
                removingEmptyFolder: removingEmptyFolder, beforePublishing: {
                    if let newProfile { model.onProfileCreated?(newProfile) }
                }) else {
                if let newProfile { model.removeProfile(newProfile.id) }
                return nil
            }
            if let newProfile { model.unavailableProfileDirectoryNames.insert(newProfile.dataDirectoryName.lowercased()) }
            return { model in
                guard revert(model) else { return false }
                if let newProfile { model.removeProfile(newProfile.id) }
                return true
            }
        }
        guard let revert = insert(self) else { return nil }
        registerUndo(revert, reapply: { insert($0) ?? Self.noRevert })
        return space
    }

    public func canCreateSpace(at insertion: Int? = nil, moving ids: [ItemID], removingEmptyFolder: ItemID? = nil) -> Bool {
        guard insertion.map({ (0...spaces.count).contains($0) }) ?? true,
              Set(ids).count == ids.count else { return false }
        if let folderID = removingEmptyFolder {
            guard let folder = index[folderID]?.folder, let parent = parentByID[folderID],
                  owner(of: parent).space != nil, folder.children.map(\.id) == ids,
                  !ids.contains(folderID) else { return false }
        }
        let moving = Set(ids)
        for id in ids {
            guard index[id] != nil, let parent = parentByID[id], position(of: id, in: parent) != nil else { return false }
            if case .splitPane = parent { return false }
            var ancestor = parent
            while case .folder(let parentID) = ancestor {
                guard !moving.contains(parentID), let next = parentByID[parentID] else { return false }
                ancestor = next
            }
        }
        return true
    }

    private func insertSpaceMoving(_ space: Space, at i: Int, moving ids: [ItemID],
                                   placement: SpaceCreationPlacement, removingEmptyFolder folderID: ItemID?,
                                   beforePublishing: () -> Void) -> Revert? {
        guard self.space(id: space.id) == nil, profile(id: space.profileID) != nil,
              canCreateSpace(at: i, moving: ids, removingEmptyFolder: folderID) else { return nil }
        let previousFocus = windows.map { ($0.id, $0.focusedSpaceID) }
        let originalParents = ids.compactMap { parentByID[$0] }
        let folder = folderID.flatMap { index[$0]?.folder }
        let folderParent = folderID.flatMap { parentByID[$0] }
        let folderPosition = folderID.flatMap { id in folderParent.flatMap { position(of: id, in: $0) } }
        // Resolve section kinds before any relocation, including children of folders.
        let destinations = ids.map { id -> NodeParent in
            if case .today = placement { return .spaceToday(space.id) }
            if case .preserveSection = placement,
               let parent = parentByID[id], case .spaceToday? = section(of: parent) { return .spaceToday(space.id) }
            return .spacePinned(space.id)
        }
        spaceCreationEvents = []
        insertSpace(space, at: i)
        var moves: [Revert] = []
        func rollback() {
            for revert in moves.reversed() { _ = revert(self) }
            removeSpace(space.id); spaceCreationEvents = nil
        }
        for (id, destination) in zip(ids, destinations) {
            #if DEBUG
            if diagnosticRollbackFailureAtMove == moves.count { rollback(); return nil }
            #endif
            guard let revert = relocate(id, to: destination, at: nil) else { rollback(); return nil }
            moves.append(revert)
        }
        if let folderID, detach(folderID) == nil { rollback(); return nil }
        // Announce an inline Profile only after the last failable relocation,
        // and before consumers receive this Space's buffered tree events.
        beforePublishing()
        emit(.reload(parent: .spaceToday(space.id)))
        let committedEvents = spaceCreationEvents ?? []; spaceCreationEvents = nil
        for event in committedEvents { emit(event) }
        let reverts = moves
        let committedPinned = space.pinned.map(\.id), committedToday = space.today.map(\.id)
        return { model in
            // A Today sweep can dissolve a moved split into its surviving tab.
            // Refuse stale Undo before restoring the folder or moving anything;
            // removing the Space after a failed relocation would lose survivors.
            guard model.space(id: space.id) === space,
                  space.pinned.map(\.id) == committedPinned, space.today.map(\.id) == committedToday,
                  zip(ids, destinations).allSatisfy({ model.index[$0.0] != nil && model.parentByID[$0.0] == $0.1 }),
                  originalParents.allSatisfy({ parent in
                      if let folderID, parent == .folder(folderID) { return true }
                      return model.parentExists(parent)
                  }) else { return false }
            if let folder, let folderParent, let folderPosition {
                guard model.index[folder.id] == nil, model.parentExists(folderParent) else { return false }
                guard model.attach(.folder(folder), to: folderParent, at: folderPosition) != nil else { return false }
            }
            for revert in reverts.reversed() { guard revert(model) else { return false } }
            let focused = Set(model.windows.filter { $0.focusedSpaceID == space.id }.map(\.id))
            model.removeSpace(space.id)
            for (id, old) in previousFocus where focused.contains(id) && model.space(id: old) != nil {
                model.windows.first { $0.id == id }?.focusedSpaceID = old
            }
            model.emit(.reload(parent: .spaceToday(space.id)))
            return true
        }
    }

    /// Live preview deliberately registers neither undo nor a structural event.
    public func previewSpaceTheme(id: SpaceID, theme: SpaceTheme) {
        guard let space = space(id: id), space.theme != theme else { return }
        space.theme = theme
        commitMutation()
    }

    @discardableResult
    public func commitSpaceTheme(id: SpaceID, from baseline: SpaceTheme) -> Bool {
        guard let space = space(id: id), space.theme != baseline else { return false }
        let current = space.theme
        registerChange(undo: { space.theme = baseline }, redo: { space.theme = current })
        return true
    }

    public func setSpaceIcon(id: SpaceID, icon: SpaceIcon?) {
        guard let space = space(id: id), space.icon != icon else { return }
        let old = space.icon
        space.icon = icon
        registerChange(undo: { space.icon = old }, redo: { space.icon = icon })
    }

    @discardableResult
    public func setNodeIcon(id: ItemID, icon: SpaceIcon?) -> Bool {
        if let tab = index[id]?.tab {
            guard tab.iconOverride != icon || tab.customIcon != nil else { return false }
            let old = tab.iconOverride, legacy = tab.customIcon
            tab.iconOverride = icon; tab.customIcon = nil
            registerChange(undo: { tab.iconOverride = old; tab.customIcon = legacy },
                           redo: { tab.iconOverride = icon; tab.customIcon = nil })
        } else if let folder = index[id]?.folder {
            guard folder.iconOverride != icon || folder.customIcon != nil else { return false }
            let old = folder.iconOverride, legacy = folder.customIcon
            folder.iconOverride = icon; folder.customIcon = nil
            registerChange(undo: { folder.iconOverride = old; folder.customIcon = legacy },
                           redo: { folder.iconOverride = icon; folder.customIcon = nil })
        } else if let split = index[id]?.split {
            guard split.iconOverride != icon else { return false }
            let old = split.iconOverride
            split.iconOverride = icon
            registerChange(undo: { split.iconOverride = old }, redo: { split.iconOverride = icon })
        } else { return false }
        return true
    }

    /// Session 12 C12-D2-2: reset both values in one undo step, leaving the panes untouched.
    @discardableResult
    public func resetSplitCustomization(id: ItemID) -> Bool {
        guard let split = index[id]?.split, split.isCustomized else { return false }
        let title = split.customTitle, icon = split.iconOverride
        split.customTitle = nil; split.iconOverride = nil
        registerChange(undo: { split.customTitle = title; split.iconOverride = icon },
                       redo: { split.customTitle = nil; split.iconOverride = nil })
        return true
    }

    public func renameSpace(id: SpaceID, title: String) {
        guard let space = space(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard space.title != value else { return }
        let old = space.title
        space.title = value
        registerChange(undo: { space.title = old }, redo: { space.title = value })
    }

    public func updateSpace(id: SpaceID, title: String? = nil, icon: SpaceIcon?? = nil, theme: SpaceTheme? = nil, profileID: ProfileID? = nil) {
        guard let space = space(id: id) else { return }
        if let profileID, profile(id: profileID) == nil { return }
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
        var clearedPeeks: [ClearedFolderPeek] = []
        for id in tabIDs {
            guard let parent = parentByID[id], let removed = removeChild(id, from: parent), let tab = removed.node.tab else { continue }
            if let cleared = clearPeek(in: parent, removing: id) { clearedPeeks.append(cleared) }
            let pinned = applyPinnedRule(to: removed.node, from: section(of: parent), to: homeSection)
            split.panes.append(tab)
            parentByID[id] = .splitPane(split.id)
            moved.append((tab, parent, removed.index, pinned))
            if !changed.contains(parent) { changed.append(parent) }
        }
        for parent in changed { emit(.reload(parent: parent)) }
        let origins = moved
        let parents = changed
        let peeks = clearedPeeks
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
            for peek in peeks { model.restorePeek(peek) }
            for parent in parents { model.emit(.reload(parent: parent)) }
            return true
        }
    }

    /// Inserts a non-favorite, non-pane tab. A refused command changes nothing.
    @discardableResult
    public func addPane(splitID: ItemID, tabID: ItemID, at: Int? = nil) -> Bool {
        guard let revert = insertPane(splitID: splitID, tabID: tabID, at: at) else { return false }
        registerUndo(revert, reapply: { $0.insertPane(splitID: splitID, tabID: tabID, at: at) ?? Self.noRevert })
        return true
    }

    private func insertPane(splitID: ItemID, tabID: ItemID, at: Int?) -> Revert? {
        guard let split = index[splitID]?.split, split.panes.count < 4,
              let tab = tab(id: tabID), let source = parentByID[tabID],
              let home = parentByID[splitID] else { return nil }
        switch source { case .favorites, .splitPane: return nil; default: break }
        let oldFractions = split.fractions, oldFocus = split.focusedPaneID
        guard let removed = removeChild(tabID, from: source) else { return nil }
        let cleared = clearPeek(in: source, removing: tabID)
        let pinned = applyPinnedRule(to: .tab(tab), from: section(of: source), to: section(of: home))
        split.panes.insert(tab, at: max(0, min(at ?? split.panes.count, split.panes.count)))
        parentByID[tabID] = .splitPane(splitID)
        split.fractions = Array(repeating: 1 / Double(split.panes.count), count: split.panes.count)
        split.focusedPaneID = tabID
        let changed = source == home ? [home] : [source, home]
        for parent in changed { emit(.reload(parent: parent)) }
        return { model in
            guard model.parentByID[tabID] == .splitPane(splitID), model.index[splitID]?.split === split,
                  model.insertChild(.tab(tab), into: source, at: removed.index) != nil else { return false }
            split.panes.removeAll { $0.id == tabID }
            model.parentByID[tabID] = source
            split.fractions = oldFractions; split.focusedPaneID = oldFocus
            Self.restore(pinned)
            model.restorePeek(cleared)
            for parent in changed { model.emit(.reload(parent: parent)) }
            return true
        }
    }

    /// One write on divider release; no structural event and no per-tick undo.
    public func setSplitFractions(splitID: ItemID, fractions: [Double]) {
        guard let split = index[splitID]?.split, fractions.count == split.panes.count,
              fractions.allSatisfy({ $0.isFinite && $0 >= 0 }),
              abs(fractions.reduce(0, +) - 1) <= 0.001 else { return }
        let old = split.fractions
        guard old != fractions else { return }
        split.fractions = fractions
        registerChange(undo: { split.fractions = old }, redo: { split.fractions = fractions })
    }

    public func setSplitOrientation(splitID: ItemID, orientation: SplitOrientation) {
        guard let split = index[splitID]?.split, split.orientation != orientation else { return }
        let old = split.orientation
        split.orientation = orientation
        registerChange(undo: { split.orientation = old }, redo: { split.orientation = orientation })
    }

    /// Replaces a split with its panes as separate rows, in pane order, at the split's slot.
    public func unsplit(splitID: ItemID) {
        guard let revert = dissolve(splitID) else { return }
        registerUndo(revert, reapply: { $0.dissolve(splitID) ?? Self.noRevert })
    }

    private func dissolve(_ splitID: ItemID) -> Revert? {
        guard let split = index[splitID]?.split, let parent = parentByID[splitID],
              let removed = removeChild(splitID, from: parent) else { return nil }
        let cleared = clearPeek(in: parent, removing: splitID)
        index[splitID] = nil
        parentByID[splitID] = nil
        let panes = split.panes
        for (offset, pane) in panes.enumerated() {
            _ = insertChild(.tab(pane), into: parent, at: removed.index + offset)
            parentByID[pane.id] = parent
        }
        // A window that showed the split now shows its focused pane.
        let survivor = split.focusedPaneID.flatMap { id in panes.first { $0.id == id } } ?? panes.first
        let reselected = survivor.map { retargetSelection(from: splitID, to: $0.id) } ?? []
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
            model.restorePeek(cleared)
            if let survivor { model.restoreSelection(reselected, from: survivor.id, to: splitID) }
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
        let previousFractions = split.fractions, previousCount = split.panes.count
        guard let removed = detach(tabID) else { return nil }
        var surviving = previousFractions
        if surviving.count == previousCount, surviving.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            surviving.remove(at: removed.index)
        } else { surviving = [] }
        let total = surviving.reduce(0, +)
        split.fractions = total.isFinite && total > 0 ? surviving.map { $0 / total }
            : Array(repeating: 1 / Double(split.panes.count), count: split.panes.count)
        // Point minimums depend on the current viewport; SplitLayout applies the
        // 200 pt clamp and narrow-window equal scaling to these normalized shares.
        if wasFocused { split.focusedPaneID = split.panes.first?.id }
        let collapsed = collapseIfSinglePane(split)
        let paneIndex = removed.index
        return { model in
            if let collapsed {
                let parent = collapsed.parent
                guard let remaining = split.panes.first, model.parentByID[remaining.id] == parent,
                      model.replaceChild(remaining.id, in: parent, with: .split(split)) != nil else { return false }
                model.index[split.id] = .split(split)
                model.parentByID[split.id] = parent
                model.parentByID[remaining.id] = .splitPane(split.id)
                model.restoreSelection(collapsed.reselected, from: remaining.id, to: split.id)
                model.restorePeek(collapsed.clearedPeek)
                model.emit(.reload(parent: parent))
            }
            guard model.attach(removed.node, to: .splitPane(split.id), at: paneIndex) != nil else { return false }
            split.fractions = previousFractions
            if wasFocused { split.focusedPaneID = tabID }
            return true
        }
    }

    /// Swaps a one-pane split for its tab. Returns the parent it collapsed in and the
    /// window selections that moved from the split to the remaining tab.
    private func collapseIfSinglePane(_ split: Split) -> (parent: NodeParent, reselected: [SelectionSlot], clearedPeek: ClearedFolderPeek?)? {
        guard split.panes.count == 1, let remaining = split.panes.first, let parent = parentByID[split.id],
              replaceChild(split.id, in: parent, with: .tab(remaining)) != nil else { return nil }
        let cleared = clearPeek(in: parent, removing: split.id)
        index[split.id] = nil
        parentByID[split.id] = nil
        parentByID[remaining.id] = parent
        let reselected = retargetSelection(from: split.id, to: remaining.id)
        emit(.reload(parent: parent))
        return (parent, reselected, cleared)
    }

    /// One window's selection in one Space.
    typealias SelectionSlot = (window: BrowserWindowState, space: SpaceID)

    /// Every window that selected `oldID` (a split that is going away) selects `newID`
    /// instead, so the window keeps showing a page. Returns the moved slots for undo.
    private func retargetSelection(from oldID: ItemID, to newID: ItemID) -> [SelectionSlot] {
        var moved: [SelectionSlot] = []
        for window in windows {
            for (space, id) in window.selectedNodeBySpace where id == oldID {
                window.selectedNodeBySpace[space] = newID
                moved.append((window, space))
            }
        }
        return moved
    }

    /// Undoes `retargetSelection` where the selection still points at `newID`.
    private func restoreSelection(_ slots: [SelectionSlot], from newID: ItemID, to oldID: ItemID) {
        for slot in slots where slot.window.selectedNodeBySpace[slot.space] == newID {
            slot.window.selectedNodeBySpace[slot.space] = oldID
        }
    }

    // MARK: Pinned URL

    public func resetPinnedTab(id: ItemID) {
        guard let tab = tab(id: id), let pinned = tab.pinnedURL else { return }
        let old = tab.url
        tab.url = pinned
        tab.lastActiveAt = Date()
        registerChange(undo: { tab.url = old }, redo: { tab.url = pinned })
    }

    /// Edit Pinned URL (app-shell §4.1): a new pinned URL for a pinned tab, one undo step.
    @discardableResult
    public func setPinnedURL(id: ItemID, url: URL) -> Bool {
        guard let tab = tab(id: id), let old = tab.pinnedURL else { return false }
        guard old != url else { return true }
        tab.pinnedURL = url
        registerChange(undo: { tab.pinnedURL = old }, redo: { tab.pinnedURL = url })
        return true
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
        clearToday(space: spaceID, keeping: [])
    }

    public func clearToday(space spaceID: SpaceID, keeping: Set<ItemID>) {
        guard let revert = clearTodayNodes(spaceID, keeping: keeping) else { return }
        registerUndo(revert, reapply: { $0.clearTodayNodes(spaceID, keeping: keeping) ?? Self.noRevert })
    }

    private func clearTodayNodes(_ spaceID: SpaceID, keeping: Set<ItemID>) -> Revert? {
        guard let space = space(id: spaceID) else { return nil }
        let parent = NodeParent.spaceToday(spaceID)
        func retained(_ node: SidebarNode) -> Bool {
            if keeping.contains(node.id) { return true }
            switch node {
            case .tab: return false
            case .folder(let folder): return folder.children.contains(where: retained)
            case .split(let split): return split.panes.contains { keeping.contains($0.id) }
            }
        }
        let saved = space.today.enumerated().filter { !retained($0.element) }
        guard !saved.isEmpty else { return nil }
        let now = Date()
        let entries = saved.flatMap { archiveEntries(for: $0.element, in: parent, reason: .clearedToday, at: now) }
        let removedIDs = Set(saved.map { $0.element.id })
        space.today.removeAll { removedIDs.contains($0.id) }
        for entry in saved { unregister(entry.element) }
        emit(.reload(parent: parent))
        archive(entries)
        let ids = entries.map { $0.tab.id }
        return { model in
            guard model.space(id: spaceID) === space else { return false }
            var restored = false
            for entry in saved where model.index[entry.element.id] == nil {
                let i = min(entry.offset, space.today.count)
                space.today.insert(entry.element, at: i)
                model.register(entry.element, under: parent)
                restored = true
            }
            guard restored else { return false }
            model.emit(.reload(parent: parent))
            model.archiveSink?.discardArchived(ids: ids.filter { model.index[$0] != nil })
            return true
        }
    }

    private struct ExpirySweep {
        let cutoff: Date
        let now: Date
        let spaceID: SpaceID
        let profileID: ProfileID
        let shownTabIDs: Set<ItemID>
        var entries: [ArchiveEntry] = []
        var changed: [NodeParent] = []
    }

    /// The focused Space's selected tab, or every pane of its selected split,
    /// is on screen. Remembered selections in other Spaces are not on screen.
    /// A closed last window can retain its state for reopen without showing it.
    private func tabsShownInWindows() -> [ItemID: Tab] {
        var shown: [ItemID: Tab] = [:]
        for window in windows where window.isShowingContent {
            guard let space = space(id: window.focusedSpaceID),
                  let id = window.selectedNodeBySpace[space.id], let node = index[id],
                  let parent = parentByID[id] else { continue }
            // A remembered ID moved to another Space/Profile is no longer shown
            // here. Resolve only this selected node's indexed ancestor chain;
            // never flatten the Space's tabs or a selected folder's children.
            switch section(of: parent) {
            case .spacePinned(let owner)?, .spaceToday(let owner)?: guard owner == space.id else { continue }
            case .favorites(let profile)?: guard profile == space.profileID else { continue }
            default: continue
            }
            for tab in node.split?.panes ?? node.tab.map({ [$0] }) ?? [] { shown[tab.id] = tab }
        }
        return shown
    }

    /// The sole visibility transition policy. Structural emissions run it before
    /// observers or archive writers; the common command/undo path covers changes
    /// without tree events. Compare cached Tab references, not the already-mutated
    /// tree, so dissolved or detached panes still receive their departure time.
    /// The shown-set work visits windows and at most four panes per window.
    private func commitMutation() {
        let current = tabsShownInWindows()
        let departed = shownTabs.filter { current[$0.key] == nil }
        shownTabs = current
        guard !departed.isEmpty else { return }
        let now = Date()
        for tab in departed.values { tab.lastActiveAt = now }
    }

    /// Earliest Today activity deadline across all Profiles. Pinned and Favorites
    /// are excluded by ancestry; tabs shown in any window are excluded by the
    /// same visibility rule as the sweep. Read all inputs for Observation.
    public func nextAutoArchiveExpiry() -> Date? {
        let shown = tabsShownInWindows()
        let thresholds = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.settings.autoArchiveAfter.seconds) })
        var earliest: Date?
        for space in spaces {
            let threshold = thresholds[space.profileID] ?? nil
            for tab in space.today.flatMap({ tabs(under: $0) }) {
                let activity = tab.lastActiveAt
                guard let threshold, shown[tab.id] == nil else { continue }
                let deadline = activity.addingTimeInterval(threshold)
                earliest = earliest.map { min($0, deadline) } ?? deadline
            }
        }
        return earliest
    }

    /// Archives expired Today tabs in one pass: top-level tabs, split panes, and tabs inside
    /// Today folders. Pinned tabs, favorites, and tabs shown in any window never
    /// expire. One sink call for all tabs, and
    /// one `.reload` per parent whose list changed. No undo: the archive is the history.
    @discardableResult
    public func archiveExpiredTabs(now: Date) -> Int {
        let shown = Set(tabsShownInWindows().keys)
        var entries: [ArchiveEntry] = []
        var changed: [NodeParent] = []
        for space in spaces {
            guard let threshold = profile(id: space.profileID)?.settings.autoArchiveAfter.seconds else { continue }
            var sweep = ExpirySweep(cutoff: now.addingTimeInterval(-threshold), now: now, spaceID: space.id, profileID: space.profileID, shownTabIDs: shown)
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
                if !sweep.shownTabIDs.contains(tab.id), tab.lastActiveAt < sweep.cutoff {
                    expire(tab, from: parent, &sweep)
                    listChanged = true
                } else {
                    kept.append(node)
                }
            case .folder(let folder):
                if let children = sweepExpired(folder.children, in: .folder(folder.id), &sweep) {
                    folder.children = children
                    folder.applyExpansion(folder.expansion)
                }
                kept.append(node)
            case .split(let split):
                let cutoff = sweep.cutoff
                let live = split.panes.filter { sweep.shownTabIDs.contains($0.id) || $0.lastActiveAt >= cutoff }
                guard live.count < split.panes.count else { kept.append(node); continue }
                for tab in split.panes where !sweep.shownTabIDs.contains(tab.id) && tab.lastActiveAt < cutoff { expire(tab, from: .splitPane(split.id), &sweep) }
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

    @discardableResult
    public func createWindow(focusedSpaceID: SpaceID) -> BrowserWindowState? {
        guard space(id: focusedSpaceID) != nil else { return nil }
        let state = BrowserWindowState(focusedSpaceID: focusedSpaceID)
        windows.append(state)
        registerChange(undo: { [weak self] in _ = self?.removeWindowState(windowID: state.id) },
                       redo: { [weak self] in self?.windows.append(state) })
        return state
    }

    private func removeWindowState(windowID: WindowID) -> BrowserWindowState? {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return nil }
        return windows.remove(at: index)
    }

    public func closeWindow(windowID: WindowID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }),
              let state = removeWindowState(windowID: windowID) else { return }
        registerChange(undo: { [weak self] in guard let self else { return }; self.windows.insert(state, at: min(index, self.windows.count)) },
                       redo: { [weak self] in _ = self?.removeWindowState(windowID: windowID) })
    }

    /// Shell lifetime only. The retained last-window snapshot is not on screen.
    /// Transient visibility is not persisted and does not register an undo action.
    public func setWindowContentVisible(windowID: WindowID, visible: Bool) {
        guard let state = windows.first(where: { $0.id == windowID }), state.isShowingContent != visible else { return }
        state.isShowingContent = visible
        commitMutation()
    }

    public func setSidebarWidth(windowID: WindowID, width: Double) {
        guard width.isFinite, let state = windows.first(where: { $0.id == windowID }) else { return }
        let old = state.sidebarWidth, value = min(500, max(BrowserWindowState.minimumSidebarWidth, width))
        guard value != old else { return }; state.sidebarWidth = value
        registerChange(undo: { state.sidebarWidth = old }, redo: { state.sidebarWidth = value })
    }

    /// Live resize crossings update chrome without adding undo steps. The controller
    /// records the start-to-final mode once at mouse-up, and records nothing on cancel.
    public func setSidebarMode(windowID: WindowID, mode: SidebarMode, registerUndo: Bool = true) {
        guard let state = windows.first(where: { $0.id == windowID }), state.sidebarMode != mode else { return }
        let old = state.sidebarMode; state.sidebarMode = mode
        if registerUndo { registerSidebarModeUndo(windowID: windowID, from: old) }
        else { commitMutation() }
    }

    /// Registers an already applied gesture's mode change. Equal modes add no undo step.
    public func registerSidebarModeUndo(windowID: WindowID, from old: SidebarMode) {
        guard let state = windows.first(where: { $0.id == windowID }), state.sidebarMode != old else { return }
        let mode = state.sidebarMode
        registerChange(undo: { state.sidebarMode = old }, redo: { state.sidebarMode = mode })
    }

    /// Shows or hides the content toolbar (§4.6.1). No undo step: window chrome, like the
    /// sidebar width while dragging; the caller schedules the snapshot save. Little Open refuses.
    @discardableResult
    public func setToolbarShown(windowID: WindowID, _ shown: Bool) -> Bool {
        guard let state = windows.first(where: { $0.id == windowID }), state.style == .standard else { return false }
        if state.showsToolbar != shown { state.showsToolbar = shown }
        return true
    }

    /// The Little Open pill asks the model for this Profile's last focused Space.
    public func mostRecentlyFocusedSpace(profileID: ProfileID) -> Space? {
        for id in focusedSpaceOrder {
            if let space = space(id: id), space.profileID == profileID { return space }
        }
        for window in windows where window.style == .standard {
            if let space = space(id: window.focusedSpaceID), space.profileID == profileID { return space }
        }
        return spaces.first { $0.profileID == profileID }
    }

    private func recordFocusedSpace(_ id: SpaceID) {
        focusedSpaceOrder.removeAll { $0 == id || space(id: $0) == nil }
        if space(id: id) != nil { focusedSpaceOrder.insert(id, at: 0) }
    }

    public func focusSpace(windowID: WindowID, spaceID: SpaceID) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        recordFocusedSpace(spaceID)
        let old = window.focusedSpaceID
        window.focusedSpaceID = spaceID
        registerChange(undo: { [weak self] in window.focusedSpaceID = old; self?.recordFocusedSpace(old) },
                       redo: { [weak self] in window.focusedSpaceID = spaceID; self?.recordFocusedSpace(spaceID) })
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
        commitMutation()
    }

    public func selectNode(windowID: WindowID, spaceID: SpaceID, nodeID: ItemID?) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        let old = window.selectedNodeBySpace[spaceID]
        setSelection(nodeID, in: spaceID, window: window)
        registerChange(undo: { [weak self] in self?.setSelection(old, in: spaceID, window: window) },
                       redo: { [weak self] in self?.setSelection(nodeID, in: spaceID, window: window) })
    }

    private func setSelection(_ id: ItemID?, in spaceID: SpaceID, window: BrowserWindowState) {
        window.selectedNodeBySpace[spaceID] = id
        if let id, let node = index[id] { stampVisibleTabs(in: node) }
    }
}
