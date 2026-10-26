import Foundation
import Observation
import Synchronization
import OpenModel

/// Flat, pre-folded copy of every sidebar tab (today, pinned, folders, split panes, favorites).
///
/// Hot data (masks, offsets, bytes, ordinals) lives in flat arrays so the per-keystroke scan touches
/// no reference-counted fields. `TabIndexer` keeps it current; see there for invalidation.
@MainActor
final class TabIndex {
    struct Entry {
        let tab: Tab
        var title: String
        var url: URL
        var host: String
        let location: TabLocation
        let spaceID: SpaceID?
        let spaceTitle: String?
        let profileOrdinal: Int
    }

    struct SpaceSummary {
        let id: SpaceID
        let title: String
        let profileOrdinal: Int
        let foldedTitle: [UInt8]
        /// "focus on <title>", folded, for the dynamic Space action.
        let foldedFocusTitle: [UInt8]
    }

    fileprivate(set) var entries: [Entry] = []
    /// Live tabs, parallel to `entries`, for reading `lastActiveAt` while scoring.
    fileprivate(set) var tabs: [Tab] = []
    /// Bloom mask of the bytes of title + host + URL, one per entry.
    fileprivate(set) var masks: [UInt64] = []
    /// Six values per entry: title start/length, host start/length, URL start/length in `bytes`.
    fileprivate(set) var offsets: [Int32] = []
    fileprivate(set) var bytes: [UInt8] = []
    fileprivate(set) var profileOrdinals: [Int32] = []
    /// Index into `spaces`, or -1 for favorites.
    fileprivate(set) var spaceOrdinals: [Int32] = []
    fileprivate(set) var locations: [TabLocation] = []
    fileprivate(set) var profiles: [ProfileID] = []
    fileprivate(set) var spaces: [SpaceSummary] = []
    fileprivate(set) var slotByTab: [ObjectIdentifier: Int] = [:]
    /// Bytes no entry points to any more (left behind by in-place patches).
    fileprivate var garbageBytes = 0

    /// Fields longer than this are cut for matching (long query strings, data URLs).
    static let maxFieldBytes = 256

    func ordinal(of profileID: ProfileID?) -> Int? {
        guard let profileID else { return nil }
        return profiles.firstIndex(of: profileID) ?? -2 // unknown Profile: matches nothing
    }

    func spaceOrdinal(of spaceID: SpaceID?) -> Int32 {
        guard let spaceID, let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return -2 }
        return Int32(i)
    }

    /// Appends folded title, host, and URL; returns the mask.
    fileprivate func appendFolded(title: String, host: String, url: URL) -> UInt64 {
        var mask: UInt64 = 0
        for field in [TextMatching.fold(title), TextMatching.fold(host), TextMatching.fold(TextMatching.matchableURL(url))] {
            let cut = field.prefix(TabIndex.maxFieldBytes)
            offsets.append(Int32(bytes.count)); offsets.append(Int32(cut.count))
            bytes.append(contentsOf: cut)
            mask |= TextMatching.mask(cut)
        }
        return mask
    }
}

/// Builds the tab index and keeps it current with two kinds of Observation scopes:
///
/// - One structure scope reads only containers: the Profile and Space lists, each Space's title,
///   Profile, pinned and today lists, folder children, split panes, and favorites. Any change there
///   marks the structure stale, and the next query rebuilds the entry list. A rebuild copies the
///   folded bytes of every unchanged tab, so it never re-reads or re-folds them.
/// - One one-shot scope per tab reads its title, custom title, and URL. A change marks only that
///   tab dirty, and the next query patches that one entry in place.
///
/// `Tab.lastActiveAt` and `Tab.customIcon` are not tracked; they are read live for result rows.
@MainActor
final class TabIndexer {
    var model: BrowserModel? {
        didSet { if model !== oldValue { index = nil } }
    }
    private(set) var index: TabIndex?
    private(set) var buildCount = 0
    private(set) var lastBuildMilliseconds: Double = 0
    /// Tabs read and folded from scratch in the last build or patch.
    private(set) var lastFoldedCount = 0

    private let structureStale = StaleFlag()
    private let dirty = DirtyTabs()
    private var armed: [ObjectIdentifier: WeakTab] = [:]

    init(model: BrowserModel?) { self.model = model }

    func current() -> TabIndex {
        let stale = structureStale.consume()
        if let index, !stale {
            if dirty.hasAny { patch(index) }
            return index
        }
        rebuild()
        return index!
    }

    private struct Placement {
        let tab: Tab
        let location: TabLocation
        let space: Int32
        let profile: Int
    }

    private func rebuild() {
        let start = ContinuousClock.now
        let previous = index
        let next = TabIndex()
        var placements: [Placement] = []
        placements.reserveCapacity(previous?.entries.count ?? 256)
        let flag = structureStale
        let model = model
        withObservationTracking {
            if let model { collect(model, into: next, &placements) }
        } onChange: {
            flag.mark()
        }

        // Entries are built outside the structure scope so tab text never lands in it.
        let dirtyNow = dirty.takeAll()
        let n = placements.count
        next.entries.reserveCapacity(n); next.tabs.reserveCapacity(n); next.masks.reserveCapacity(n)
        next.offsets.reserveCapacity(6 * n); next.bytes.reserveCapacity(previous?.bytes.count ?? 32 * 1024)
        next.profileOrdinals.reserveCapacity(n); next.spaceOrdinals.reserveCapacity(n)
        next.locations.reserveCapacity(n); next.slotByTab.reserveCapacity(n)
        var folded = 0
        var keep: [ObjectIdentifier: WeakTab] = [:]
        keep.reserveCapacity(n)
        for p in placements {
            let id = ObjectIdentifier(p.tab)
            let summary = p.space >= 0 ? next.spaces[Int(p.space)] : nil
            let entry: TabIndex.Entry
            if let previous, let old = previous.slotByTab[id], !dirtyNow.contains(id), armed[id]?.tab === p.tab {
                // Unchanged and still observed: copy the folded fields.
                let o = previous.entries[old]
                entry = TabIndex.Entry(tab: p.tab, title: o.title, url: o.url, host: o.host, location: p.location,
                                       spaceID: summary?.id, spaceTitle: summary?.title, profileOrdinal: p.profile)
                for f in 0..<3 {
                    let s = Int(previous.offsets[old * 6 + f * 2]), length = Int(previous.offsets[old * 6 + f * 2 + 1])
                    next.offsets.append(Int32(next.bytes.count)); next.offsets.append(Int32(length))
                    next.bytes.append(contentsOf: previous.bytes[s..<(s + length)])
                }
                next.masks.append(previous.masks[old])
            } else {
                let (title, url) = read(p.tab)
                let host = TextMatching.displayHost(url)
                entry = TabIndex.Entry(tab: p.tab, title: title, url: url, host: host, location: p.location,
                                       spaceID: summary?.id, spaceTitle: summary?.title, profileOrdinal: p.profile)
                next.masks.append(next.appendFolded(title: title, host: host, url: url))
                folded += 1
            }
            next.slotByTab[id] = next.entries.count
            next.entries.append(entry)
            next.tabs.append(p.tab)
            next.profileOrdinals.append(Int32(p.profile))
            next.spaceOrdinals.append(p.space)
            next.locations.append(p.location)
            keep[id] = armed[id]
        }
        armed = keep // tabs that left the sidebar are forgotten; their one-shot scopes fire at most once
        index = next
        buildCount += 1
        lastFoldedCount = folded
        lastBuildMilliseconds = (ContinuousClock.now - start).milliseconds
    }

    /// Walks containers only (no tab text), inside the structure scope.
    private func collect(_ model: BrowserModel, into next: TabIndex, _ placements: inout [Placement]) {
        func walk(_ nodes: [SidebarNode], _ location: TabLocation, _ space: Int32, _ profile: Int, _ out: inout [Placement]) {
            for node in nodes {
                switch node {
                case .tab(let tab): out.append(Placement(tab: tab, location: location, space: space, profile: profile))
                case .folder(let folder): walk(folder.children, location, space, profile, &out)
                case .split(let split):
                    for pane in split.panes { out.append(Placement(tab: pane, location: .splitPane, space: space, profile: profile)) }
                }
            }
        }
        func profileOrdinal(_ id: ProfileID) -> Int {
            if let i = next.profiles.firstIndex(of: id) { return i }
            next.profiles.append(id)
            return next.profiles.count - 1
        }
        for profile in model.profiles {
            let ordinal = profileOrdinal(profile.id)
            for tab in profile.favorites { placements.append(Placement(tab: tab, location: .favorite, space: -1, profile: ordinal)) }
        }
        for space in model.spaces {
            let ordinal = profileOrdinal(space.profileID)
            let title = model.displayTitle(for: space)
            let folded = TextMatching.fold(title)
            next.spaces.append(TabIndex.SpaceSummary(id: space.id, title: title, profileOrdinal: ordinal,
                                                     foldedTitle: folded, foldedFocusTitle: Array("focus on ".utf8) + folded))
            let s = Int32(next.spaces.count - 1)
            walk(space.pinned, .pinned, s, ordinal, &placements)
            walk(space.today, .today, s, ordinal, &placements)
        }
    }

    /// Re-reads only the tabs whose title or URL changed, appending their new bytes.
    private func patch(_ index: TabIndex) {
        let start = ContinuousClock.now
        var folded = 0
        for id in dirty.takeAll() {
            guard let slot = index.slotByTab[id] else { continue }
            let tab = index.tabs[slot]
            let (title, url) = read(tab)
            let host = TextMatching.displayHost(url)
            for f in 0..<3 { index.garbageBytes += Int(index.offsets[slot * 6 + f * 2 + 1]) }
            let count = index.offsets.count
            let mask = index.appendFolded(title: title, host: host, url: url)
            // appendFolded added six offsets at the end; move them into the slot.
            for k in 0..<6 { index.offsets[slot * 6 + k] = index.offsets[count + k] }
            index.offsets.removeLast(6)
            index.masks[slot] = mask
            index.entries[slot].title = title
            index.entries[slot].url = url
            index.entries[slot].host = host
            folded += 1
        }
        if index.garbageBytes > 64 * 1024 && index.garbageBytes > index.bytes.count / 2 {
            structureStale.mark() // compact on the next query
        }
        lastFoldedCount = folded
        lastBuildMilliseconds = (ContinuousClock.now - start).milliseconds
    }

    /// Reads a tab's text inside its own one-shot scope; a later change marks just this tab dirty.
    private func read(_ tab: Tab) -> (String, URL) {
        let id = ObjectIdentifier(tab)
        let dirty = dirty
        let value = withObservationTracking {
            (tab.displayTitle, tab.url)
        } onChange: {
            dirty.insert(id)
        }
        armed[id] = WeakTab(tab: tab)
        return value
    }
}

private struct WeakTab {
    weak var tab: Tab?
}

/// Set from Observation's `onChange` (any thread); read on the main actor before each query.
final class StaleFlag: Sendable {
    private let value = Atomic<Bool>(true)
    func mark() { value.store(true, ordering: .releasing) }
    /// Returns true if the flag was set, and clears it.
    func consume() -> Bool { value.exchange(false, ordering: .acquiringAndReleasing) }
}

/// Tabs whose title or URL changed since the last read. Filled from `onChange` (any thread).
final class DirtyTabs: Sendable {
    private let ids = Mutex<Set<ObjectIdentifier>>([])

    func insert(_ id: ObjectIdentifier) { ids.withLock { _ = $0.insert(id) } }

    var hasAny: Bool { ids.withLock { !$0.isEmpty } }

    func takeAll() -> Set<ObjectIdentifier> {
        ids.withLock { s in
            defer { s.removeAll(keepingCapacity: true) }
            return s
        }
    }
}
