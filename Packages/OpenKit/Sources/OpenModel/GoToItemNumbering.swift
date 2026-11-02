import Foundation

/// Cmd+1…9 numbering (commandbar-completion §4.4.1, D7). One model query for the key handler, the
/// Tabs menu's numbered section, and "Go to Last Tab"; Arc shows no hold-Command hints (CC-39, D13).
///
/// Order: the Favorites of the focused Space's Profile in grid order (when `includeFavorites`), then the
/// focused Space's pinned section, then Today, in sidebar row order. An expanded folder contributes its
/// visible children (recursively); a peeked folder its one visible child; a collapsed folder nothing;
/// folder rows are never targets; a collapsed pinned section contributes nothing; a split counts once
/// (its id). Open choice: Arc's exact numbering is not captured (CC-25).
extension BrowserModel {
    /// Every numbered item for `windowID`, in order (ids of tabs or splits).
    public func goToItemCandidates(windowID: WindowID, includeFavorites: Bool) -> [ItemID] {
        guard let window = windows.first(where: { $0.id == windowID }) ?? windows.first,
              let space = space(id: window.focusedSpaceID) ?? spaces.first else { return [] }
        var out: [ItemID] = []
        if includeFavorites, let profile = profile(id: space.profileID) { out += profile.favorites.map(\.id) }
        if !space.isPinnedCollapsed { Self.visibleTargets(space.pinned, into: &out) }
        Self.visibleTargets(space.today, into: &out)
        return out
    }

    /// Targets of go-to-tab-1…9 for this window. Index 0 = Cmd+1. Nil = no target. Slot 9 is the ninth
    /// item, or the last item when `ninthSelectsLast` (Settings: NOT `open.shortcuts.switchToNinthEnabled`).
    public func goToItemTargets(windowID: WindowID, includeFavorites: Bool, ninthSelectsLast: Bool) -> [ItemID?] {
        let all = goToItemCandidates(windowID: windowID, includeFavorites: includeFavorites)
        var slots: [ItemID?] = (0..<9).map { $0 < all.count ? all[$0] : nil }
        if ninthSelectsLast { slots[8] = all.last }
        return slots
    }

    private static func visibleTargets(_ nodes: [SidebarNode], into out: inout [ItemID]) {
        for node in nodes {
            switch node {
            case .tab(let tab): out.append(tab.id)
            case .split(let split): out.append(split.id)
            case .folder(let folder):
                switch folder.expansion {
                case .expanded: visibleTargets(folder.children, into: &out)
                case .peeked(let child): if folder.children.contains(where: { $0.id == child }) { out.append(child) }
                case .collapsed: break
                }
            }
        }
    }
}
