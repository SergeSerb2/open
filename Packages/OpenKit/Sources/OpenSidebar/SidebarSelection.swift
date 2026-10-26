import Observation
import OpenModel

/// Per-window, transient selection. Rows observe only their own flag.
@MainActor @Observable
public final class SidebarSelection {
    public private(set) var ids: [ItemID] = []
    public private(set) var anchor: ItemID?
    public var isEmpty: Bool { ids.isEmpty }
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var members: Set<ItemID> = []
    @ObservationIgnored private var states: [ItemID: WeakRowSelectionState] = [:]
    @ObservationIgnored private var extensionBase: Set<ItemID>?
    @ObservationIgnored private var displayOrder: [ItemID] = []
    @ObservationIgnored private var visible: Set<ItemID> = []

    public init() {}
    public func contains(_ id: ItemID) -> Bool { members.contains(id) }

    public func toggle(_ id: ItemID, order: [ItemID]) {
        guard order.contains(id) else { return }
        remember(order)
        var next = members
        if !next.insert(id).inserted { next.remove(id) }
        select(order.filter { next.contains($0) }, anchor: id)
    }

    public func extend(to id: ItemID, order: [ItemID]) {
        guard let end = order.firstIndex(of: id) else { return }
        remember(order)
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

    public func prune(keeping visible: Set<ItemID>, order: [ItemID]? = nil) {
        let kept = ids.filter { visible.contains($0) }
        let positions = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($1, $0) })
        let oldIndex = anchor.flatMap { positions[$0] }
        let keptSet = Set(kept)
        let known = (order ?? displayOrder).filter { keptSet.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: (known + kept.filter { !known.contains($0) }).enumerated().map { ($1, $0) })
        let nearest = oldIndex.flatMap { index in
            kept.min {
                let left = positions[$0].map { abs($0 - index) } ?? Int.max
                let right = positions[$1].map { abs($0 - index) } ?? Int.max
                return left == right ? ranks[$0, default: Int.max] < ranks[$1, default: Int.max] : left < right
            }
        }
        let keptAnchor = anchor.flatMap { visible.contains($0) ? $0 : nil } ?? nearest ?? kept.first
        self.visible = visible
        displayOrder = order ?? displayOrder.filter { visible.contains($0) }
        set(kept, anchor: keptAnchor)
        extensionBase = extensionBase.map { $0.intersection(visible) }
        releaseHiddenStates()
    }

    private func remember(_ order: [ItemID]) { displayOrder = order; visible = Set(order) }
    private func releaseHiddenStates() {
        let stale = states.keys.filter { !visible.contains($0) && !members.contains($0) }
        for id in stale { states.removeValue(forKey: id) }
    }

    private func set(_ next: [ItemID], anchor: ItemID?) {
        var seen: Set<ItemID> = []
        let ordered = next.filter { seen.insert($0).inserted }
        for id in members.symmetricDifference(seen) { states[id]?.value?.isSelected = seen.contains(id) }
        let shrank = !members.subtracting(seen).isEmpty
        members = seen
        if shrank { releaseHiddenStates() }
        let changed = ids != ordered
        if changed { ids = ordered }
        if self.anchor != anchor { self.anchor = anchor }
        if changed { onChange?() }
    }

    func rowState(for id: ItemID) -> SidebarRowSelectionState {
        if let state = states[id]?.value { return state }
        let state = SidebarRowSelectionState(isSelected: members.contains(id)) { [weak self] in
            if self?.states[id]?.value == nil { self?.states.removeValue(forKey: id) }
        }
        states[id] = WeakRowSelectionState(state)
        return state
    }
}

@MainActor @Observable
final class SidebarRowSelectionState {
    var isSelected: Bool
    @ObservationIgnored private let onRelease: @MainActor () -> Void
    init(isSelected: Bool, onRelease: @escaping @MainActor () -> Void) { self.isSelected = isSelected; self.onRelease = onRelease }
    isolated deinit { onRelease() }
}

@MainActor private final class WeakRowSelectionState {
    weak var value: SidebarRowSelectionState?
    init(_ value: SidebarRowSelectionState) { self.value = value }
}
