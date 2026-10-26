import Foundation
import OpenModel
import OpenStore

/// Forwards to the real ArchiveStore and counts sink calls, so the demo can show one call per bulk command.
@MainActor
final class CountingSink: ArchiveSink {
    let store: ProfileArchiveSink
    var archiveCalls = 0
    var lastBatch: [ArchiveEntry] = []
    var lastFolders: [ArchiveFolderEntry] = []

    init(store: ProfileArchiveSink) { self.store = store }

    func archive(_ entries: [ArchiveEntry]) {
        archiveCalls += 1
        lastBatch = entries
        store.archive(entries)
    }

    func archiveFolder(_ entry: ArchiveFolderEntry) { archive([], folders: [entry]) }
    func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry]) {
        archiveCalls += 1; lastBatch = entries; lastFolders = folders
        store.archive(entries, folders: folders)
    }

    func archiveForProfileDeletion(_ entries: [ArchiveEntry], directoryName: String) throws {
        archiveCalls += 1
        lastBatch = entries
        try store.archiveForProfileDeletion(entries, directoryName: directoryName)
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
    case .spaceProfileChanged(let space, let from, let to): return "profile(space \(space.rawValue.uuidString.prefix(8)): \(from.rawValue.uuidString.prefix(8))->\(to.rawValue.uuidString.prefix(8)))"
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
    _ = try prepareProfiles(model, root: root)
    guard let space = model.spaces.first, let profile = model.profile(id: space.profileID) else { print("no space"); exit(1) }
    let sid = space.id
    let pid = profile.id
    model.windows.first?.focusedSpaceID = sid

    let composite = profileArchiveSink(model: model, directories: ProfileDirectories(root: root))
    let archive = composite.store(for: pid)
    let sink = CountingSink(store: composite)
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
    check(space.today.first?.id == two.id && space.today.dropFirst().first?.id == one.id,
          "newTab without an index inserts at Today top")
    undo.undo()
    check(model.tab(id: two.id) == nil && space.today.first?.id == one.id, "undo removes the new top tab")
    undo.redo()
    check(space.today.first?.id == two.id && model.tab(id: two.id) === two, "redo restores the same tab at Today top")
    let explicit = model.newTab(in: sid, url: url("explicit"), at: 1)
    check(space.today[1].id == explicit.id, "newTab still honors an explicit index")
    undo.undo()

    step("collapse and mute are undoable property changes")
    let wasCollapsed = space.isPinnedCollapsed
    model.setPinnedSectionCollapsed(spaceID: sid, collapsed: !wasCollapsed)
    check(space.isPinnedCollapsed != wasCollapsed && events.isEmpty, "collapse changes the property without TreeChange")
    model.setPinnedSectionCollapsed(spaceID: sid, collapsed: !wasCollapsed)
    model.setPinnedSectionCollapsed(spaceID: SpaceID(), collapsed: true)
    undo.undo()
    check(space.isPinnedCollapsed == wasCollapsed && events.isEmpty, "collapse undo; same-value and missing-Space commands add no undo")
    undo.redo()
    check(space.isPinnedCollapsed != wasCollapsed && events.isEmpty, "collapse redo without TreeChange")
    undo.undo()
    model.setMuted(tabID: two.id, muted: true)
    check(two.isMuted && events.isEmpty, "mute changes the property without TreeChange")
    model.setMuted(tabID: two.id, muted: true)
    model.setMuted(tabID: ItemID(), muted: true)
    undo.undo()
    check(!two.isMuted && events.isEmpty, "mute undo; same-value and missing-tab commands add no undo")
    undo.redo()
    check(two.isMuted && events.isEmpty, "mute redo without TreeChange")
    undo.undo()
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
    // Before imported activity (Arc uses the 2001 epoch), so only the demo
    // tabs expire even when another Space contains old imported Today tabs.
    let expiryNow = Date(timeIntervalSinceReferenceDate: 0)
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
    let expired = model.archiveExpiredTabs(now: expiryNow)
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
    model.archiveExpiredTabs(now: expiryNow)
    check(model.node(id: staleSplit.id) == nil && model.parent(of: u1.id) == .spaceToday(sid), "auto-archive took U2; the split collapsed to U1")
    undo.undo()
    check(occurrences(of: u1.id, in: model) == 1 && occurrences(of: u2.id, in: model) == 0 && indexMatchesRebuild(model),
          "undo of the dissolved split does nothing: U1 once, U2 stays archived")
    undo.undo()
    undo.undo()
    check(model.tab(id: u1.id) == nil && occurrences(of: u2.id, in: model) == 0 && indexMatchesRebuild(model), "older undo steps still apply cleanly")
    tree("final")

    step("profiles: create, validation, undo and stable directories")
    let uniqueName = "Demo Profile " + UUID().uuidString.prefix(8)
    guard let added = model.createProfile(name: "  \(uniqueName)  ") else { profileCLIError("demo profile creation failed") }
    let addedID = added.id, directory = added.dataDirectoryName
    check(added.name == uniqueName && directory.hasPrefix("Profile-") && events.isEmpty, "createProfile trims its name, mints a directory and emits no event")
    let duplicate = model.createProfile(name: uniqueName.lowercased())
    check(duplicate == nil && events.isEmpty, "duplicate create refuses without events")
    undo.undo()
    check(model.profile(id: addedID) == nil, "duplicate create registered no undo: undo removes the accepted create")
    undo.redo()
    check(model.profile(id: addedID) === added && added.dataDirectoryName == directory && model.profiles.last === added, "redo restores the same Profile, directory and index")
    try ProfileDirectories(root: root).ensureProfileDirectories(for: added)
    check(BrowserModel.profileNameIssue(" ", in: model.profiles) == .empty
          && BrowserModel.profileNameIssue(String(repeating: "a", count: 65), in: model.profiles) == .tooLong
          && [".", "..", "a/b", "a:b", "a\\b", "a\u{0000}b"].allSatisfy { BrowserModel.profileNameIssue($0, in: model.profiles) == .invalidCharacters }, "Profile name validation covers empty, length and unsafe characters")

    step("profiles: rename, icon and whole settings")
    let renamed = uniqueName + " Renamed"
    check(model.renameProfile(id: addedID, to: renamed) && added.name == renamed, "renameProfile applies")
    undo.undo(); check(added.name == uniqueName, "rename undo restores name")
    undo.redo(); check(added.name == renamed && added.dataDirectoryName == directory, "rename redo keeps directory")
    check(!model.renameProfile(id: addedID, to: profile.name) && events.isEmpty, "duplicate rename refuses without events")
    undo.undo(); check(added.name == uniqueName, "duplicate rename registers no undo")
    undo.redo()
    model.setProfileIcon(id: addedID, icon: .emoji("💼"))
    undo.undo(); check(added.icon == nil, "Profile icon undo")
    undo.redo(); check(added.icon == .emoji("💼"), "Profile icon redo")
    let oldSettings = added.settings
    let newSettings = ProfileSettings(autoArchiveAfter: .never, littleOpenAutoArchiveAfter: .oneHour, searchEngineID: "google")
    check(model.updateProfileSettings(id: addedID, settings: newSettings) && added.settings == newSettings, "whole Profile settings apply")
    undo.undo(); check(added.settings == oldSettings, "whole settings undo")
    undo.redo(); check(added.settings == newSettings && events.isEmpty, "whole settings redo without events")

    step("profiles: move Space, preserving tabs and Favorites")
    let keptTabs = model.index.values.compactMap(\.tab).map { ($0.id, $0.url, $0.pinnedURL) }
    let keptFavorites = profile.favorites.map(\.id)
    let expectedMove = "profile(space \(sid.description.prefix(8)): \(pid.description.prefix(8))->\(addedID.description.prefix(8)))"
    check(model.moveSpace(id: sid, toProfile: addedID) && events.map(describe) == [expectedMove], "Space Profile move emits exactly one event")
    check(keptTabs.allSatisfy { model.tab(id: $0.0)?.url == $0.1 && model.tab(id: $0.0)?.pinnedURL == $0.2 }
          && profile.favorites.map(\.id) == keptFavorites && added.favorites.isEmpty, "Space move keeps tab IDs, URLs, pinnedURLs and old Profile Favorites")
    events.removeAll(); undo.undo()
    check(space.profileID == pid && events.map(describe) == ["profile(space \(sid.description.prefix(8)): \(addedID.description.prefix(8))->\(pid.description.prefix(8)))"], "Space Profile undo emits inverse event")
    events.removeAll(); undo.redo()
    check(space.profileID == addedID && events.map(describe) == [expectedMove], "Space Profile redo emits forward event")
    events.removeAll()
    check(!model.moveSpace(id: sid, toProfile: ProfileID()) && !model.moveSpace(id: sid, toProfile: addedID) && events.isEmpty, "missing and same Profile moves refuse without events")
    undo.undo(); check(space.profileID == pid, "refused moves register no undo")
    undo.redo()

    step("profiles: combined Space edit")
    let oldTitle = space.title, oldIcon = space.icon, oldTheme = space.theme
    events.removeAll()
    model.updateSpace(id: sid, title: "Profile Demo Space", icon: .some(.emoji("🧭")), theme: SpaceTheme(), profileID: pid)
    check(space.profileID == pid && space.title == "Profile Demo Space" && events.count == 1, "combined Space editor emits one Profile event")
    events.removeAll(); undo.undo()
    check(space.profileID == addedID && space.title == oldTitle && space.icon == oldIcon && space.theme == oldTheme && events.count == 1, "combined edit undo restores all four values with inverse event")
    events.removeAll(); undo.redo()
    check(space.profileID == pid && space.title == "Profile Demo Space" && events.count == 1, "combined edit redo restores the whole edit")

    events.removeAll()
    model.updateSpace(id: sid, title: "Invalid edit", profileID: ProfileID())
    check(space.profileID == pid && space.title == "Profile Demo Space" && events.isEmpty,
          "stale Profile in updateSpace refuses the whole edit without events")

    step("profiles: deletion refusals register no undo")
    _ = model.moveSpace(id: sid, toProfile: addedID)
    events.removeAll()
    check(!(try model.deleteProfile(id: addedID)) && model.deleteBlockReason(for: addedID) == .spacesAssigned(count: 1) && events.isEmpty, "delete Profile with Spaces refuses without events")
    undo.undo(); check(space.profileID == pid, "assigned-Profile deletion registered no undo")
    events.removeAll()
    check(!(try model.deleteProfile(id: model.defaultProfile!.id)) && events.isEmpty, "delete default Profile refuses without events")
    undo.undo(); check(space.profileID == addedID && space.title == oldTitle, "default deletion registered no undo")
    _ = model.moveSpace(id: sid, toProfile: pid)

    step("profiles: archive Favorites on delete, undo and redo")
    let profileFavorite = model.newTab(in: sid, url: url("profile-favorite"), title: "Profile Favorite")
    model.addFavorite(tabID: profileFavorite.id, to: addedID)
    let profileArchive = composite.store(for: addedID)
    let callsBeforeProfileDelete = sink.archiveCalls
    events.removeAll()
    check((try model.deleteProfile(id: addedID)) && sink.archiveCalls == callsBeforeProfileDelete + 1
          && sink.lastBatch.count == 1 && sink.lastBatch[0].profileID == addedID
          && sink.lastBatch[0].originalLocation == NodeParent.favorites(addedID).archiveLocation
          && events.map(describe) == ["reload(favorites)"], "Profile delete archives Favorites in one sink call and emits one reload")
    var profileRows = await profileArchive.count()
    check(model.profile(id: addedID) == nil && model.tab(id: profileFavorite.id) == nil
          && profileRows == 1, "deleted Favorite is in its own Profile archive")
    events.removeAll(); undo.undo()
    check(model.profile(id: addedID) === added && model.tab(id: profileFavorite.id) === profileFavorite
          && events.map(describe) == ["reload(favorites)"], "delete undo restores Profile, Favorites and index")
    check(await profileArchive.count() == 0, "delete undo discards archived Favorite")
    events.removeAll(); undo.redo()
    profileRows = await profileArchive.count()
    check(model.profile(id: addedID) == nil && events.map(describe) == ["reload(favorites)"]
          && profileRows == 1, "delete redo archives Favorite again")

    step("profiles: dangling reference repair has no undo")
    let missingProfileID = ProfileID()
    space.profileID = missingProfileID
    events.removeAll()
    let repaired = model.repairMissingProfileReferences()
    check(repaired == [sid] && space.profileID == model.defaultProfile?.id
          && events.map(describe) == ["profile(space \(sid.description.prefix(8)): \(missingProfileID.description.prefix(8))->\(model.defaultProfile!.id.description.prefix(8)))"], "missing Profile repairs to default and emits the repair event")
    undo.undo()
    check(model.profile(id: addedID) === added && space.profileID == model.defaultProfile?.id, "repair registered no undo; previous delete is undone")
    undo.redo()
    check(indexMatchesRebuild(model), "Profile section index equals a full rebuild")

    step("optional Space titles, named icons, and runtime-only web content")
    let savedTitle = space.title, savedIcon = space.icon
    space.title = nil
    space.icon = .named("planet")
    one.live.hasWebContent = true
    try snapshots.saveNow(model: model)
    let reloaded = try snapshots.load()
    check(reloaded?.space(id: sid)?.title == nil && reloaded?.space(id: sid)?.icon == .named("planet"),
          "untitled Space and named icon survive the real snapshot store")
    check(reloaded?.tab(id: one.id)?.live.hasWebContent == false,
          "live web content is absent after snapshot reload")
    space.title = savedTitle; space.icon = savedIcon
    try snapshots.saveNow(model: model)
    runTidyTitlesDemo(check: check)
    try await runFolderArchiveDemo(root: root.appendingPathComponent("FolderArchive"), check: check)
    try await runSidebarCommandsDemo(root: root.appendingPathComponent("SidebarCommands"), check: check)
    composite.flushAll()
    print("commands-demo \(failed == 0 ? "OK" : "FAILED"): \(passed) checks passed, \(failed) failed, archive rows=\(await archive.count())")
    if failed > 0 { exit(1) }
}
