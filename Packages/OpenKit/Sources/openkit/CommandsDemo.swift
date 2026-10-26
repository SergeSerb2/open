import Foundation
import OpenModel
import OpenStore

/// Forwards to the real ArchiveStore and counts sink calls, so the demo can show one call per bulk command.
@MainActor
final class CountingSink: ArchiveSink {
    let store: ArchiveStore
    var archiveCalls = 0
    var lastBatch: [ArchiveEntry] = []

    init(store: ArchiveStore) { self.store = store }

    func archive(_ entries: [ArchiveEntry]) {
        archiveCalls += 1
        lastBatch = entries
        store.archive(entries)
    }

    func discardArchived(ids: [ItemID]) { store.discardArchived(ids: ids) }
}

func label(_ parent: NodeParent?) -> String {
    switch parent {
    case .spacePinned?: return "pinned"
    case .spaceToday?: return "today"
    case .folder(let id)?: return "folder \(id.rawValue.uuidString.prefix(8))"
    case .favorites?: return "favorites"
    case .splitPane(let id)?: return "split \(id.rawValue.uuidString.prefix(8))"
    case nil: return "nowhere"
    }
}

func describe(_ change: TreeChange) -> String {
    switch change {
    case .insert(let parent, let index, _): return "insert(\(label(parent))[\(index)])"
    case .remove(let parent, let index, _): return "remove(\(label(parent))[\(index)])"
    case .move(let from, let fromIndex, let to, let toIndex, _): return "move(\(label(from))[\(fromIndex)] -> \(label(to))[\(toIndex)])"
    case .reload(let parent): return "reload(\(label(parent)))"
    }
}

@MainActor
func tabCount(_ nodes: [SidebarNode]) -> Int {
    nodes.reduce(0) { total, node in
        switch node {
        case .tab: return total + 1
        case .folder(let folder): return total + tabCount(folder.children)
        case .split(let split): return total + split.panes.count
        }
    }
}

/// How many times a node ID appears in the tree. Each node must appear once.
@MainActor
func occurrences(of id: ItemID, in model: BrowserModel) -> Int {
    func count(_ nodes: [SidebarNode]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .tab(let tab): return total + (tab.id == id ? 1 : 0)
            case .folder(let folder): return total + (folder.id == id ? 1 : 0) + count(folder.children)
            case .split(let split): return total + (split.id == id ? 1 : 0) + split.panes.filter { $0.id == id }.count
            }
        }
    }
    return model.profiles.reduce(0) { $0 + $1.favorites.filter { $0.id == id }.count }
        + model.spaces.reduce(0) { $0 + count($1.pinned) + count($1.today) }
}

@MainActor
func runCommandsDemo(args: [String]) async throws {
    guard let dirArg = args.first else { FileHandle.standardError.write(Data("usage: openkit commands-demo DIR\n".utf8)); exit(2) }
    let root = URL(fileURLWithPath: dirArg)
    let snapshots = SnapshotStore(root: root)
    let model: BrowserModel
    if let loaded = try snapshots.load() {
        model = loaded
    } else {
        let profile = Profile(name: "Demo")
        let space = Space(title: "Demo Space", profileID: profile.id)
        model = BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
    }
    guard let space = model.spaces.first, let profile = model.profile(id: space.profileID) else { print("no space"); exit(1) }
    let sid = space.id
    let pid = profile.id
    model.windows.first?.focusedSpaceID = sid

    let archive = ArchiveStore(root: root)
    let sink = CountingSink(store: archive)
    model.archiveSink = sink
    let undo = UndoManager()
    // No event loop here, so no per-event groups: the model opens one group per command.
    undo.groupsByEvent = false
    model.undoManager = undo
    var events: [TreeChange] = []
    model.addObserver { events.append($0) }

    var passed = 0
    var failed = 0
    func check(_ ok: Bool, _ text: String) {
        print("  \(ok ? "OK  " : "FAIL") \(text)")
        if ok { passed += 1 } else { failed += 1 }
    }
    func step(_ title: String) {
        print("--- \(title) ---")
        events.removeAll()
    }
    func tree(_ title: String) {
        print("--- tree: \(title) ---")
        printTree(model: model, showTitles: true)
    }
    func todayIndex(_ id: ItemID) -> Int? { space.today.firstIndex { $0.id == id } }
    func isMove(_ change: TreeChange) -> Bool { if case .move = change { return true }; return false }
    func inArchive(_ id: ItemID) async -> Bool { await archive.recent(limit: 100_000).contains { $0.id == id } }
    func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

    tree("initial")

    step("new tabs, pin, folder")
    let one = model.newTab(in: sid, url: url("one"), title: "One")
    check(events.count == 1 && describe(events[0]).hasPrefix("insert(today"), "newTab emits one insert: \(events.map(describe))")
    let two = model.newTab(in: sid, url: url("two"), title: "Two")
    model.pinTab(id: one.id)
    check(model.isPinned(tabID: one.id) && one.pinnedURL == one.url, "pinTab moves One to Pinned and sets pinnedURL")
    guard let folder = model.createFolder(in: .spaceToday(sid), title: "Demo Folder", withNodes: [two.id]) else { print("createFolder failed"); exit(1) }
    check(model.parent(of: two.id) == .folder(folder.id), "createFolder moves Two into the folder")
    let three = model.newTab(in: sid, url: url("three"), title: "Three")

    step("split in a folder (allowed), with undo")
    let threeSlot = todayIndex(three.id)
    guard let split = model.makeSplit(tabIDs: [two.id, three.id]) else { print("makeSplit failed"); exit(1) }
    check(model.parent(of: split.id) == .folder(folder.id), "makeSplit puts the split where Two lived: the folder")
    check(model.parent(of: three.id) == .splitPane(split.id) && todayIndex(three.id) == nil, "Three left Today and is a pane")
    check(indexMatchesRebuild(model), "index equals a full rebuild")
    undo.undo()
    check(model.node(id: split.id) == nil && model.parent(of: two.id) == .folder(folder.id) && todayIndex(three.id) == threeSlot,
          "undo: split gone, Two back in the folder, Three back at today[\(threeSlot ?? -1)]")
    undo.redo()
    check(model.parent(of: split.id) == .folder(folder.id) && split.panes.map(\.id) == [two.id, three.id], "redo: split back in the folder")
    tree("after split in folder")

    step("favorite move (same tab, same ID), with undo")
    let fav = model.newTab(in: sid, url: url("fav"), title: "Fav")
    let favSlot = todayIndex(fav.id)
    events.removeAll()
    check(model.addFavorite(tabID: fav.id, to: pid), "addFavorite accepted")
    check(model.tab(id: fav.id) === fav && model.parent(of: fav.id) == .favorites(pid) && todayIndex(fav.id) == nil,
          "Fav moved into Favorites: same object, same ID, gone from Today")
    check(fav.pinnedURL == fav.url, "pinnedURL set to the current URL")
    check(events.count == 1 && isMove(events[0]), "one event: \(events.map(describe))")
    undo.undo()
    check(todayIndex(fav.id) == favSlot && fav.pinnedURL == nil, "undo: back at today[\(favSlot ?? -1)], pinnedURL nil again")
    undo.redo()
    check(model.parent(of: fav.id) == .favorites(pid) && fav.pinnedURL == fav.url, "redo: in Favorites again")

    step("unfavorite, with undo")
    let marker = model.newTab(in: sid, url: url("marker"), title: "Marker")
    events.removeAll()
    check(model.removeFavorite(tabID: fav.id), "removeFavorite accepted")
    check(space.today.first?.id == fav.id && fav.pinnedURL == nil, "Fav moved to the top of the focused Space's Today; pinnedURL cleared")
    check(events.count == 1 && isMove(events[0]), "one event: \(events.map(describe))")
    undo.undo()
    check(model.parent(of: fav.id) == .favorites(pid) && fav.pinnedURL == fav.url, "undo: back in Favorites with its pinnedURL")
    undo.redo()
    check(space.today.first?.id == fav.id && fav.pinnedURL == nil, "redo: top of Today again")
    tree("after favorites")

    step("placement rules (rejected)")
    let s1 = model.newTab(in: sid, url: url("s1"), title: "S1")
    let s2 = model.newTab(in: sid, url: url("s2"), title: "S2")
    guard let todaySplit = model.makeSplit(tabIDs: [s1.id, s2.id]) else { print("makeSplit failed"); exit(1) }
    let favB = model.newTab(in: sid, url: url("favb"), title: "FavB")
    model.addFavorite(tabID: favB.id, to: pid)
    guard let inner = model.createFolder(in: .folder(folder.id), title: "Inner") else { print("createFolder failed"); exit(1) }
    events.removeAll()
    check(!model.moveNode(id: todaySplit.id, to: .favorites(pid), at: nil), "moveNode split -> Favorites rejected")
    check(!model.addFavorite(tabID: todaySplit.id, to: pid), "addFavorite(split) rejected")
    check(!model.moveNode(id: folder.id, to: .favorites(pid), at: nil), "moveNode folder -> Favorites rejected")
    check(!model.addFavorite(tabID: folder.id, to: pid), "addFavorite(folder) rejected")
    check(!model.addFavorite(tabID: s1.id, to: pid), "addFavorite(split pane) rejected")
    check(model.makeSplit(tabIDs: [favB.id, marker.id]) == nil, "makeSplit with a favorite rejected")
    check(!model.moveNode(id: folder.id, to: .folder(inner.id), at: nil), "folder into its own descendant rejected")
    check(events.isEmpty && model.parent(of: todaySplit.id) == .spaceToday(sid) && model.parent(of: folder.id) == .spaceToday(sid),
          "rejected commands change nothing and emit no events")
    undo.undo()
    check(model.node(id: inner.id) == nil, "rejections register no undo: undo removes Inner, the last accepted command")
    undo.redo()

    step("close a pane: split collapses, undo rebuilds it")
    let splitSlot = todayIndex(todaySplit.id)
    model.closeTab(id: s2.id)
    check(model.node(id: todaySplit.id) == nil && todayIndex(s1.id) == splitSlot, "split with one pane left collapses to S1 in its slot")
    undo.undo()
    check(todayIndex(todaySplit.id) == splitSlot && todaySplit.panes.map(\.id) == [s1.id, s2.id] && model.parent(of: s2.id) == .splitPane(todaySplit.id),
          "undo: split and pane back")
    check(!(await inArchive(s2.id)), "undo: pane's archive row discarded")

    step("pinned ancestry, with undo")
    let pinMe = model.newTab(in: sid, url: url("pinme"), title: "PinMe")
    model.pinTab(id: pinMe.id)
    let savedPinnedURL = pinMe.pinnedURL
    pinMe.url = url("pinme/navigated")
    model.moveNode(id: pinMe.id, to: .spaceToday(sid), at: nil)
    check(pinMe.pinnedURL == nil && !model.isPinned(tabID: pinMe.id), "pinned -> today move clears pinnedURL")
    undo.undo()
    check(model.isPinned(tabID: pinMe.id) && pinMe.pinnedURL == savedPinnedURL, "undo: back in Pinned with the exact old pinnedURL, not the navigated URL")
    undo.redo()
    check(pinMe.pinnedURL == nil && model.parent(of: pinMe.id) == .spaceToday(sid), "redo: cleared again")
    let a = model.newTab(in: sid, url: url("a"), title: "A")
    let b = model.newTab(in: sid, url: url("b"), title: "B")
    let c = model.newTab(in: sid, url: url("c"), title: "C")
    guard let pinnedFolder = model.createFolder(in: .spacePinned(sid), title: "Pinned Folder", withNodes: [a.id]),
          let pinnedSplit = model.makeSplit(tabIDs: [b.id, c.id]) else { print("setup failed"); exit(1) }
    check(a.pinnedURL == a.url && model.isPinned(tabID: a.id), "tab moved into a pinned folder gets pinnedURL")
    model.moveNode(id: pinnedSplit.id, to: .folder(pinnedFolder.id), at: nil)
    check([b, c].allSatisfy { $0.pinnedURL == $0.url && model.isPinned(tabID: $0.id) }, "split moved into the pinned folder: both panes pinned, pinnedURL set")
    model.moveNode(id: pinnedFolder.id, to: .spaceToday(sid), at: nil)
    check([a, b, c].allSatisfy { $0.pinnedURL == nil && !model.isPinned(tabID: $0.id) }, "folder moved pinned -> today: every tab inside cleared, split panes too")
    undo.undo()
    check([a, b, c].allSatisfy { $0.pinnedURL == $0.url && model.isPinned(tabID: $0.id) }, "undo: folder back in Pinned, every pinnedURL restored")
    check(indexMatchesRebuild(model), "index equals a full rebuild")
    tree("after pinned ancestry")

    step("close -> archive -> restore, with undo")
    let restorable = model.newTab(in: sid, url: url("restorable"), title: "Restorable")
    model.closeTab(id: restorable.id)
    var archived = await inArchive(restorable.id)
    check(model.tab(id: restorable.id) == nil && archived, "closeTab removes the tab and archives it")
    guard let record = await archive.restore(id: restorable.id) else { print("archive row missing"); exit(1) }
    print("  archived: \(record.title) reason=\(record.reason.rawValue) location=\(record.originalLocation.prefix { $0 != ":" }) space=\(record.spaceID == sid ? "original" : "?")")
    let restored = model.restoreArchivedTab(record)
    print("  restored: \(restored.displayTitle) id=\(restored.id.rawValue.uuidString.prefix(8)) at \(label(model.parent(of: restored.id)))[\(todayIndex(restored.id) ?? -1)]")
    check(restored.id == restorable.id && todayIndex(restored.id) == 0, "restored with the same ID at the top of its original parent")
    check(!(await inArchive(restorable.id)), "row gone from the archive")
    undo.undo()
    archived = await inArchive(restorable.id)
    check(model.tab(id: restorable.id) == nil && archived, "undo: tab back in the archive")
    undo.redo()
    archived = await inArchive(restorable.id)
    check(model.tab(id: restorable.id) != nil && !archived, "redo: tab back in Today, row discarded")

    step("restore fallback: original folder gone")
    guard let holder = model.createFolder(in: .spaceToday(sid), title: "Holder") else { print("createFolder failed"); exit(1) }
    let x = model.newTab(in: sid, url: url("x"), title: "X")
    model.moveNode(id: x.id, to: .folder(holder.id), at: nil)
    model.closeTab(id: x.id)
    model.closeTab(id: holder.id)
    guard let recordX = await archive.restore(id: x.id) else { print("archive row missing"); exit(1) }
    check(recordX.originalLocation == NodeParent.folder(holder.id).archiveLocation, "record keeps the direct parent (the folder)")
    model.restoreArchivedTab(recordX)
    check(space.today.first?.id == x.id, "folder gone: restored at the top of the original Space's Today")

    step("restore fallback: original Space gone")
    let tempSpace = model.createSpace(title: "Temp Space", profileID: pid)
    let y = model.newTab(in: tempSpace.id, url: url("y"), title: "Y")
    model.closeTab(id: y.id)
    model.deleteSpace(id: tempSpace.id)
    guard let recordY = await archive.restore(id: y.id) else { print("archive row missing"); exit(1) }
    model.restoreArchivedTab(recordY)
    check(model.parent(of: y.id) == .spaceToday(sid) && space.today.first?.id == y.id, "Space gone: restored at the top of the focused Space's Today")

    step("deleteSpace, with undo")
    let goneSpace = model.createSpace(title: "Gone Space", profileID: pid)
    let z = model.newTab(in: goneSpace.id, url: url("z"), title: "Z")
    model.deleteSpace(id: goneSpace.id)
    archived = await inArchive(z.id)
    check(model.space(id: goneSpace.id) == nil && model.tab(id: z.id) == nil && archived, "deleteSpace removes the Space and archives its tab")
    undo.undo()
    archived = await inArchive(z.id)
    check(model.space(id: goneSpace.id) != nil && model.parent(of: z.id) == .spaceToday(goneSpace.id) && !archived, "undo: Space and tab back, row discarded")
    undo.redo()
    archived = await inArchive(z.id)
    check(model.space(id: goneSpace.id) == nil && archived, "redo: deleted and archived again")

    step("restore into a split that still exists")
    let p1 = model.newTab(in: sid, url: url("p1"), title: "P1")
    let p2 = model.newTab(in: sid, url: url("p2"), title: "P2")
    let p3 = model.newTab(in: sid, url: url("p3"), title: "P3")
    guard let split3 = model.makeSplit(tabIDs: [p1.id, p2.id, p3.id]) else { print("makeSplit failed"); exit(1) }
    model.closeTab(id: p3.id)
    guard let recordP = await archive.restore(id: p3.id) else { print("archive row missing"); exit(1) }
    model.restoreArchivedTab(recordP)
    check(model.parent(of: p3.id) == .splitPane(split3.id) && split3.panes.count == 3, "restored as a pane of its split")
    check(indexMatchesRebuild(model), "index equals a full rebuild")
    tree("after archive and restore")

    step("clearToday: one pass, with undo")
    let todayTabs = tabCount(space.today)
    let callsBefore = sink.archiveCalls
    let rowsBefore = await archive.count()
    events.removeAll()
    model.clearToday(space: sid)
    check(space.today.isEmpty && events.count == 1 && describe(events[0]) == "reload(today)", "Today empty, one event: \(events.map(describe))")
    check(sink.archiveCalls == callsBefore + 1 && sink.lastBatch.count == todayTabs, "one sink call for \(todayTabs) tabs")
    let reasons = Set(sink.lastBatch.map(\.reason.rawValue)).sorted()
    let locations = Set(sink.lastBatch.map { String($0.originalLocation.prefix { $0 != ":" }) }).sorted()
    print("  archived reasons=\(reasons) locations=\(locations)")
    check(await archive.count() == rowsBefore + todayTabs, "\(todayTabs) rows archived")
    undo.undo()
    var rows = await archive.count()
    check(tabCount(space.today) == todayTabs && rows == rowsBefore, "undo: Today back, rows discarded")
    check(indexMatchesRebuild(model), "index equals a full rebuild")
    undo.redo()
    rows = await archive.count()
    check(space.today.isEmpty && rows == rowsBefore + todayTabs, "redo: cleared and archived again")

    step("archiveExpiredTabs with a fake clock")
    let old = Date(timeIntervalSince1970: 0)
    let e1 = model.newTab(in: sid, url: url("e1"), title: "E1")
    let e2 = model.newTab(in: sid, url: url("e2"), title: "E2")
    let fresh = model.newTab(in: sid, url: url("fresh"), title: "Fresh")
    let e3 = model.newTab(in: sid, url: url("e3"), title: "E3")
    let k2 = model.newTab(in: sid, url: url("k2"), title: "K2")
    guard let expiryFolder = model.createFolder(in: .spaceToday(sid), title: "Expiry Folder", withNodes: [e3.id, k2.id]) else { print("createFolder failed"); exit(1) }
    let e4 = model.newTab(in: sid, url: url("e4"), title: "E4")
    let k3 = model.newTab(in: sid, url: url("k3"), title: "K3")
    let k4 = model.newTab(in: sid, url: url("k4"), title: "K4")
    guard let expirySplit = model.makeSplit(tabIDs: [e4.id, k3.id, k4.id]) else { print("makeSplit failed"); exit(1) }
    for tab in [e1, e2, e3, e4] { tab.lastActiveAt = old }
    one.lastActiveAt = old
    let callsBeforeExpiry = sink.archiveCalls
    events.removeAll()
    let expired = model.archiveExpiredTabs(now: Date())
    print("  archiveExpiredTabs archived=\(expired) events=\(events.map(describe))")
    check(expired == 4 && sink.archiveCalls == callsBeforeExpiry + 1, "4 expired tabs (top level, folder, split pane) in one sink call")
    let expectedReloads = Set(["reload(today)", "reload(\(label(.folder(expiryFolder.id))))", "reload(\(label(.splitPane(expirySplit.id))))"])
    check(events.count == 3 && Set(events.map(describe)) == expectedReloads, "one .reload per affected parent")
    check([fresh, k2, k3, k4].allSatisfy { model.tab(id: $0.id) != nil } && expirySplit.panes.count == 2, "fresh tabs stay; the split keeps 2 panes")
    check(model.tab(id: one.id) != nil, "old pinned tab does not expire")
    check(indexMatchesRebuild(model), "index equals a full rebuild")

    step("undo after auto-archive changed the tree underneath")
    let u1 = model.newTab(in: sid, url: url("u1"), title: "U1")
    let u2 = model.newTab(in: sid, url: url("u2"), title: "U2")
    guard let staleSplit = model.makeSplit(tabIDs: [u1.id, u2.id]) else { print("makeSplit failed"); exit(1) }
    u2.lastActiveAt = old
    model.archiveExpiredTabs(now: Date())
    check(model.node(id: staleSplit.id) == nil && model.parent(of: u1.id) == .spaceToday(sid), "auto-archive took U2; the split collapsed to U1")
    undo.undo()
    check(occurrences(of: u1.id, in: model) == 1 && occurrences(of: u2.id, in: model) == 0 && indexMatchesRebuild(model),
          "undo of the dissolved split does nothing: U1 once, U2 stays archived")
    undo.undo()
    undo.undo()
    check(model.tab(id: u1.id) == nil && occurrences(of: u2.id, in: model) == 0 && indexMatchesRebuild(model), "older undo steps still apply cleanly")
    tree("final")

    snapshots.saveNow(model: model)
    archive.flushQueue()
    print("commands-demo \(failed == 0 ? "OK" : "FAILED"): \(passed) checks passed, \(failed) failed, archive rows=\(await archive.count())")
    if failed > 0 { exit(1) }
}
