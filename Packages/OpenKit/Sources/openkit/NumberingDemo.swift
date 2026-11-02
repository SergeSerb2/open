import Foundation
import OpenModel

/// N1–N7 (commandbar-completion §4.4.1, §5.1): `goToItemTargets` against hand-written expected lists.
@MainActor
func runNumberingDemo(check: (Bool, String) -> Void) {
    func tab(_ n: String) -> Tab { Tab(url: URL(string: "https://\(n).example/")!, title: n) }
    let profile = Profile(name: "Numbering")
    let f1 = tab("fav1"), f2 = tab("fav2")
    profile.favorites = [f1, f2]
    let p1 = tab("pin1"), pf1 = tab("pinfolder1"), pf2 = tab("pinfolder2")
    let pinFolder = Folder(title: "Pinned folder", isExpanded: true, children: [.tab(pf1), .tab(pf2)])
    let t1 = tab("today1"), s1 = tab("split1"), s2 = tab("split2"), t2 = tab("today2"), c1 = tab("closed1"), k1 = tab("peek1"), k2 = tab("peek2"), t3 = tab("today3"), t4 = tab("today4"), t5 = tab("today5")
    let split = Split(panes: [s1, s2], focusedPaneID: s2.id)
    let closed = Folder(title: "Closed", isExpanded: false, children: [.tab(c1)])
    let peeked = Folder(title: "Peeked", isExpanded: false, children: [.tab(k1), .tab(k2)])
    peeked.applyExpansion(.peeked(k2.id))
    let nested = Folder(title: "Nested", isExpanded: true, children: [.folder(Folder(title: "Inner closed", isExpanded: false, children: [.tab(tab("hidden"))])), .tab(t3)])
    let space = Space(title: "Main", profileID: profile.id)
    space.pinned = [.tab(p1), .folder(pinFolder)]
    space.today = [.tab(t1), .split(split), .tab(t2), .folder(closed), .folder(peeked), .folder(nested), .tab(t4), .tab(t5)]
    let model = BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
    let w = model.windows[0].id
    let pinned: [ItemID] = [p1.id, pf1.id, pf2.id]
    let today: [ItemID] = [t1.id, split.id, t2.id, k2.id, t3.id, t4.id, t5.id]
    func slots(_ all: [ItemID], ninthLast: Bool) -> [ItemID?] {
        var s: [ItemID?] = (0..<9).map { $0 < all.count ? all[$0] : nil }
        if ninthLast { s[8] = all.last }
        return s
    }
    let favOn = [f1.id, f2.id] + pinned + today
    // N1: defaults (Favorites on, ninth = last).
    check(model.goToItemTargets(windowID: w, includeFavorites: true, ninthSelectsLast: true) == slots(favOn, ninthLast: true),
          "N1 numbering: Favorites, pinned (expanded folder children), Today; Cmd+9 = last item")
    // N2: "Switch to ninth tab" on → slot 9 is the ninth item.
    check(model.goToItemTargets(windowID: w, includeFavorites: true, ninthSelectsLast: false) == slots(favOn, ninthLast: false),
          "N2 numbering: switch-to-ninth on → Cmd+9 is the ninth item")
    // N3: Favorites off.
    check(model.goToItemTargets(windowID: w, includeFavorites: false, ninthSelectsLast: true) == slots(pinned + today, ninthLast: true),
          "N3 numbering: Include Favorites off → pinned and Today only")
    // N4: a collapsed folder contributes nothing; folder rows are never targets; a nested collapsed folder hides its children.
    let all = model.goToItemCandidates(windowID: w, includeFavorites: true)
    check(!all.contains(c1.id) && !all.contains(closed.id) && !all.contains(nested.id) && !all.contains(pinFolder.id) && all.contains(t3.id),
          "N4 numbering: collapsed folders give nothing; folder rows are not targets")
    // N5: a peeked folder gives only its visible child.
    check(all.contains(k2.id) && !all.contains(k1.id), "N5 numbering: a peeked folder gives its one visible child")
    // N6: a split counts once (its id), not per pane.
    check(all.filter { $0 == split.id }.count == 1 && !all.contains(s1.id) && !all.contains(s2.id), "N6 numbering: a split counts once")
    // N7: a collapsed pinned section gives nothing; fewer than nine items leave empty slots.
    space.isPinnedCollapsed = true
    let collapsed = model.goToItemTargets(windowID: w, includeFavorites: false, ninthSelectsLast: false)
    check(collapsed == slots(today, ninthLast: false) && collapsed[7] == nil && collapsed[8] == nil, "N7 numbering: collapsed pinned section gives nothing; missing slots are nil")
}
