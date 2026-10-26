import AppKit
import OpenModel

extension NSPasteboard.PasteboardType {
    /// One sidebar node (tab, folder, split) by its `ItemID`. Local drags only.
    static let sidebarNode = NSPasteboard.PasteboardType("com.open.sidebar.node")
}

/// Pasteboard content for sidebar drags: our node type plus the URL, so a tab
/// can also be dropped into other apps.
@MainActor
enum SidebarPasteboard {
    static func writer(for tab: Tab) -> any NSPasteboardWriting {
        let item = NSPasteboardItem()
        item.setString(tab.id.description, forType: .sidebarNode)
        item.setString(tab.url.absoluteString, forType: .URL)
        item.setString(tab.url.absoluteString, forType: .string)
        return item
    }

    static func writer(for node: SidebarNode) -> any NSPasteboardWriting {
        if case .tab(let t) = node { return writer(for: t) }
        let item = NSPasteboardItem()
        item.setString(node.id.description, forType: .sidebarNode)
        return item
    }

    /// Nil means external URLs; an empty array means an invalid local payload.
    static func nodeIDs(from pb: NSPasteboard) -> [ItemID]? {
        let items = pb.pasteboardItems ?? []
        guard items.contains(where: { $0.types.contains(.sidebarNode) }) else { return nil }
        var ids: [ItemID] = []
        for item in items {
            guard let value = item.string(forType: .sidebarNode), let uuid = UUID(uuidString: value) else { return [] }
            let id = ItemID(rawValue: uuid)
            guard !ids.contains(id) else { return [] }
            ids.append(id)
        }
        return ids
    }

    static func destination(for id: ItemID, in space: SpaceID, model: BrowserModel) -> NodeParent {
        model.isPinned(tabID: id) ? .spacePinned(space) : .spaceToday(space)
    }

    static func nodeID(from pb: NSPasteboard) -> ItemID? {
        guard let s = pb.pasteboardItems?.first?.string(forType: .sidebarNode), let uuid = UUID(uuidString: s) else { return nil }
        return ItemID(rawValue: uuid)
    }

    static func urls(from pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL]) ?? []
    }
}

/// List edits that turn one ordered list of unique IDs into another.
enum ListDiff {
    struct Move: Equatable { var from: Int; var to: Int }

    /// Batch form (collection view semantics): removals use old indices,
    /// insertions new indices, moves old → new for items outside the longest
    /// run that kept its order.
    struct Plan {
        var removals: [Int] = []
        var insertions: [Int] = []
        var moves: [Move] = []
        var isSimple: Bool { moves.count <= 8 }
    }

    static func plan<ID: Hashable>(old: [ID], new: [ID]) -> Plan {
        var p = Plan()
        let newIndex = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1, $0) })
        let oldIndex = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1, $0) })
        p.removals = old.indices.filter { newIndex[old[$0]] == nil }
        p.insertions = new.indices.filter { oldIndex[new[$0]] == nil }
        // Common items in old order, mapped to their new positions.
        let common = old.compactMap { newIndex[$0] }
        let keep = Set(longestIncreasing(common))
        for (i, id) in old.enumerated() {
            guard let to = newIndex[id], !keep.contains(to) else { continue }
            p.moves.append(Move(from: i, to: to))
        }
        return p
    }

    /// Sequential form (outline view semantics): each step applies to the list
    /// as left by the previous step.
    enum Step: Equatable { case remove(Int), insert(Int), move(Int, Int) }

    static func steps<ID: Hashable>(old: [ID], new: [ID]) -> [Step] {
        var steps: [Step] = []
        let newSet = Set(new)
        var cur = old
        for i in stride(from: cur.count - 1, through: 0, by: -1) where !newSet.contains(cur[i]) {
            cur.remove(at: i)
            steps.append(.remove(i))
        }
        for (j, id) in new.enumerated() {
            if j < cur.count, cur[j] == id { continue }
            if let k = cur.firstIndex(of: id) {
                cur.remove(at: k)
                cur.insert(id, at: j)
                steps.append(.move(k, j))
            } else {
                cur.insert(id, at: j)
                steps.append(.insert(j))
            }
        }
        return steps
    }

    /// Values of a longest strictly increasing subsequence.
    private static func longestIncreasing(_ a: [Int]) -> [Int] {
        var tails: [Int] = [], tailIdx: [Int] = [], prev = [Int](repeating: -1, count: a.count)
        for (i, x) in a.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if tails[mid] < x { lo = mid + 1 } else { hi = mid } }
            if lo == tails.count { tails.append(x); tailIdx.append(i) } else { tails[lo] = x; tailIdx[lo] = i }
            prev[i] = lo > 0 ? tailIdx[lo - 1] : -1
        }
        var out: [Int] = []
        var k = tailIdx.last ?? -1
        while k >= 0 { out.append(a[k]); k = prev[k] }
        return out.reversed()
    }
}
