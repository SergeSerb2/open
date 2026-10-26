import Observation
import OpenModel

/// Per-window, transient selection. Rows observe only their own flag.
@MainActor @Observable
public final class SidebarSelection {
    public private(set) var ids: [ItemID] = []
    public private(set) var anchor: ItemID?
    public var isEmpty: Bool { ids.isEmpty }
    @ObservationIgnored private var members: Set<ItemID> = []
    @ObservationIgnored private var states: [ItemID: SidebarRowSelectionState] = [:]
    @ObservationIgnored private var extensionBase: Set<ItemID>?

    public init() {}
    public func contains(_ id: ItemID) -> Bool { members.contains(id) }

    public func toggle(_ id: ItemID, order: [ItemID]) {
        guard order.contains(id) else { return }
        var next = members
        if !next.insert(id).inserted { next.remove(id) }
        select(order.filter { next.contains($0) }, anchor: id)
    }

    public func extend(to id: ItemID, order: [ItemID]) {
        guard let end = order.firstIndex(of: id) else { return }
        let start = anchor.flatMap { order.firstIndex(of: $0) } ?? end
        let base = extensionBase ?? members
        let next = base.union(order[min(start, end)...max(start, end)])
        set(order.filter { next.contains($0) }, anchor: order[start])
        extensionBase = base
    }

    public func select(_ ids: [ItemID], anchor: ItemID?) {
        set(ids, anchor: anchor)
        extensionBase = nil
    }

    public func clear() { select([], anchor: nil) }

    public func prune(keeping visible: Set<ItemID>) {
        let kept = ids.filter { visible.contains($0) }
        let keptAnchor = anchor.flatMap { visible.contains($0) ? $0 : nil } ?? kept.first
        set(kept, anchor: keptAnchor)
        extensionBase = extensionBase.map { $0.intersection(visible) }
    }

    private func set(_ next: [ItemID], anchor: ItemID?) {
        var seen: Set<ItemID> = []
        let ordered = next.filter { seen.insert($0).inserted }
        for id in members.symmetricDifference(seen) { states[id]?.isSelected = seen.contains(id) }
        members = seen
        if ids != ordered { ids = ordered }
        if self.anchor != anchor { self.anchor = anchor }
    }

    func rowState(for id: ItemID) -> SidebarRowSelectionState {
        if let state = states[id] { return state }
        let state = SidebarRowSelectionState(isSelected: members.contains(id))
        states[id] = state
        return state
    }
}

@MainActor @Observable
final class SidebarRowSelectionState {
    var isSelected: Bool
    init(isSelected: Bool) { self.isSelected = isSelected }
}
