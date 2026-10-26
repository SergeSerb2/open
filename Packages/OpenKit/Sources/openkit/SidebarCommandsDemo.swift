import Foundation
import OpenModel
import OpenStore

/// The sidebar command flow uses the production model, undo manager, and SQLite sink.
@MainActor
func runSidebarCommandsDemo(root: URL, check: (Bool, String) -> Void) async throws {
    func fingerprint(_ model: BrowserModel) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(SnapshotMapper.dto(from: model))
    }
    let profile = Profile(name: "Sidebar commands")
    let source = Space(title: "Source", profileID: profile.id)
    let destination = Space(title: "Destination", profileID: profile.id)
    let window = BrowserWindowState(focusedSpaceID: source.id)
    let model = BrowserModel(profiles: [profile], spaces: [source, destination], windows: [window])
    let snapshots = SnapshotStore(root: root)
    _ = try prepareProfiles(model, root: root)
    let composite = profileArchiveSink(model: model, directories: ProfileDirectories(root: root))
    let sink = CountingSink(store: composite)
    let archive = composite.store(for: profile.id)
    model.archiveSink = sink
    let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
    var events: [TreeChange] = []
    model.addObserver { events.append($0) }
    func reset() { undo.removeAllActions(); events.removeAll() }
    func url(_ name: String) -> URL { URL(string: "https://example.invalid/\(name)")! }
    func tab(_ name: String) -> Tab { model.newTab(in: source.id, url: url(name), title: name, at: nil) }
    func moves() -> [ItemID] { events.compactMap { if case .move(_, _, _, _, let id) = $0 { return id }; return nil } }
    func inserts() -> [ItemID] { events.compactMap { if case .insert(_, _, let id) = $0 { return id }; return nil } }
    func removals() -> [ItemID] { events.compactMap { if case .remove(_, _, let id) = $0 { return id }; return nil } }
    func receipt(_ id: String) { print("    \(id) events=\(events.map(describe))") }

    let a = tab("A"), b = tab("B"), c = tab("C")
    model.pinTab(id: a.id); a.url = url("A/navigated")
    let target = model.createFolder(in: .spaceToday(source.id), title: "Target")!
    let prior = fingerprint(model)
    reset()
    check(model.moveNodes(ids: [a.id, b.id, c.id], to: .folder(target.id)) == 3 && moves() == [a.id, b.id, c.id]
          && target.children.map(\.id) == [a.id, b.id, c.id] && a.pinnedURL == nil, "B1 bulk move sends ordered per-node events")
    receipt("B1")
    undo.undo()
    check(fingerprint(model) == prior && !undo.canUndo, "B1 one undo restores exact order and pinned URLs")
    undo.redo(); check(target.children.count == 3, "B1 redo repeats the bulk move")
    undo.undo()

    let p1 = tab("Pane1"), p2 = tab("Pane2")
    let split = model.makeSplit(tabIDs: [p1.id, p2.id])!
    let nested = model.createFolder(in: .spaceToday(source.id), title: "Nested", withNodes: [b.id])!
    reset()
    check(model.moveNodes(ids: [p1.id, nested.id, b.id], to: .spacePinned(destination.id)) == 1
          && moves() == [nested.id] && model.parent(of: b.id) == .folder(nested.id), "B2 pane and selected-folder descendant are skipped")
    undo.undo()

    let order = source.today.map(\.id)
    reset()
    let moving = [c.id, p2.id, b.id] // A pane is refused; B is currently inside Nested.
    check(model.moveNodes(ids: moving, to: .spaceToday(source.id), at: order.count) == 2
          && Array(source.today.suffix(2)).map(\.id) == [c.id, b.id], "B3 pre-removal drop index keeps selection order")
    undo.undo()
    check(source.today.map(\.id) == order && model.parent(of: b.id) == .folder(nested.id), "B3 undo restores both parents")
    reset()
    check(model.moveNodes(ids: [nested.id, b.id, p1.id], to: .spacePinned(destination.id)) == 1, "B3 mixed input moves only its top-level eligible node")
    undo.undo()

    reset()
    let calls = sink.archiveCalls
    let oldRows = await archive.count()
    let count = model.archiveNodes(ids: [a.id, nested.id, c.id])
    let batch = sink.lastBatch
    check(count == 3 && sink.archiveCalls == calls + 1 && batch.contains { $0.tab.id == b.id && $0.reason == .folderDeleted }
          && batch.contains { $0.tab.id == a.id && $0.reason == .closed } && removals().count == 3, "B4 archive uses one sink batch and per-node removes")
    receipt("B4")
    undo.undo(); composite.flushAll()
    check(await archive.count() == oldRows && model.node(id: nested.id) != nil && !undo.canUndo, "B4 undo restores nodes and discards archive rows")

    reset()
    let folder = model.createFolder(in: .spaceToday(source.id), at: 0, title: "Selection", withNodes: [b.id, c.id])!
    check(source.today.first?.id == folder.id && inserts() == [folder.id] && moves() == [b.id, c.id], "B5 folder inserts at the requested slot and moves its children")
    undo.undo(); check(model.node(id: folder.id) == nil && model.parent(of: b.id) == .folder(nested.id), "B5 one undo removes folder and restores children")

    let fav = tab("Favorite"); model.addFavorite(tabID: fav.id, to: profile.id)
    reset()
    check(model.setPinned(ids: [c.id, split.id, fav.id, nested.id], pinned: true) == 2
          && moves() == [c.id, split.id] && model.parent(of: fav.id) == .favorites(profile.id), "B6 pin skips favorites and folders")
    undo.undo(); undo.redo(); reset()
    check(model.setPinned(ids: [c.id, split.id, fav.id, nested.id], pinned: false) == 2
          && Array(source.today.prefix(2)).map(\.id) == [c.id, split.id] && c.pinnedURL == nil && p1.pinnedURL == nil, "B6 unpin puts rows at Today top in order")
    undo.undo()

    a.customTitle = "Custom A"; a.customIcon = "star"; a.isMuted = true
    a.iconOverride = .emoji("🧭"); nested.iconOverride = .named("planet")
    p1.iconOverride = .symbol("heart"); b.iconOverride = .named("leaf")
    reset()
    let copies = model.duplicateNodes(ids: [a.id, split.id, nested.id, fav.id])
    let copiedTab = copies.first.flatMap { model.tab(id: $0) }
    let copiedSplit = copies.dropFirst().first.flatMap { model.node(id: $0)?.split }
    let copiedFolder = copies.dropFirst(2).first.flatMap { model.node(id: $0)?.folder }
    check(copies.count == 4 && inserts() == copies && copiedTab?.pinnedURL == a.pinnedURL
          && copiedTab?.url == a.url && copiedTab?.customTitle == a.customTitle && copiedTab?.customIcon == a.customIcon && copiedTab?.isMuted == true
          && copiedTab?.iconOverride == a.iconOverride && copiedFolder?.iconOverride == nested.iconOverride
          && copiedSplit?.panes.first?.iconOverride == p1.iconOverride && copiedFolder?.children.first?.tab?.iconOverride == b.iconOverride
          && copiedSplit?.panes.count == 2 && copiedSplit?.panes.first?.id != p1.id
          && copiedFolder?.children.first?.id != b.id && copies.last == source.today.first?.id,
          "B7 duplicate tab/split/folder/favorite has fresh IDs and preserves stored fields")
    undo.undo(); check(copies.allSatisfy { model.node(id: $0) == nil } && !undo.canUndo, "B7 one undo removes every copy")
    undo.redo(); check(copies.allSatisfy { model.node(id: $0) != nil }, "B7 redo restores the same copy IDs")
    undo.undo()

    reset()
    check(model.moveNodes(ids: [p1.id, nested.id], to: .favorites(profile.id)) == 0
          && model.archiveNodes(ids: [ItemID()]) == 0 && model.duplicateNodes(ids: [p1.id]).isEmpty
          && model.createFolder(in: .favorites(profile.id)) == nil
          && model.setPinned(ids: [fav.id, nested.id], pinned: true) == 0 && events.isEmpty && !undo.canUndo,
          "B8 refused bulk commands leave tree, events, and undo unchanged")
    let deep = model.createFolder(in: .folder(nested.id), title: "Deep")!
    reset()
    let expanded = model.setAllFoldersExpanded(spaceID: source.id, expanded: false)
    check(expanded == 3 && !deep.isExpanded && !nested.isExpanded && !target.isExpanded && events.isEmpty, "B9 collapse reaches every depth without structural events")
    undo.undo(); check(deep.isExpanded && nested.isExpanded && target.isExpanded, "B9 one undo restores expansion")
    reset(); check(model.setAllFoldersExpanded(spaceID: source.id, expanded: true) == 0 && !undo.canUndo, "B9 same-value expand registers no undo")

    p1.url = url("Pane1/navigated"); c.url = url("C?q=ignored")
    fav.url = url("Favorite/navigated")
    reset()
    let resetIDs = model.resetPinnedTabs(spaceID: source.id)
    check(Set(resetIDs) == Set([a.id, p1.id]) && a.url == a.pinnedURL && p1.url == p1.pinnedURL && events.isEmpty,
          "B10 reset reaches pinned split panes, excludes favorites and query-only changes")
    undo.undo(); check(a.url == url("A/navigated") && p1.url == url("Pane1/navigated"), "B10 undo restores navigated URLs")

    let oldSnapshot = fingerprint(model)
    let oldPinned = source.pinned.map(\.id), oldToday = source.today.map(\.id)
    reset()
    let exported = model.turnSpaceIntoFolder(id: source.id, destination: destination.id)
    check(exported?.children.map(\.id) == oldPinned + oldToday && destination.pinned.first?.id == exported?.id
          && model.space(id: source.id) == nil && window.focusedSpaceID == destination.id && inserts().count == 1,
          "B11 export keeps Pinned then Today order and moves window focus")
    receipt("B11")
    undo.undo()
    check(fingerprint(model) == oldSnapshot && !undo.canUndo, "B12 undo restores Space slot, lists, exact pins, and focus")
    undo.redo(); undo.undo()
    reset()
    check(model.turnSpaceIntoFolder(id: source.id, destination: source.id) == nil
          && model.turnSpaceIntoFolder(id: source.id, destination: SpaceID()) == nil && events.isEmpty && !undo.canUndo,
          "B13 same-Space and missing destination refuse without changes")
    let single = BrowserModel(profiles: [profile], spaces: [destination])
    check(single.turnSpaceIntoFolder(id: destination.id, destination: SpaceID()) == nil, "B13 last-Space export refuses")

    reset()
    let separated = model.separateFromPinnedTab(id: a.id)
    check(separated?.url == url("A/navigated") && separated?.isMuted == true && separated?.customIcon == nil
          && separated?.customTitle == nil && source.today.first?.id == separated?.id && a.url == a.pinnedURL,
          "B14 separate creates Today tab at zero and resets pin without copying customization")
    undo.undo(); check(a.url == url("A/navigated") && separated.map { model.tab(id: $0.id) == nil } == true && !undo.canUndo, "B14 undo removes separated tab and restores pin URL")
    reset(); check(model.separateFromPinnedTab(id: fav.id) == nil && events.isEmpty && !undo.canUndo, "B14 favorite separation refuses")

    reset()
    let unread = model.newTab(in: source.id, url: url("Unread"), unread: true)
    check(unread.isUnread, "Unread background creation sets the persisted flag")
    undo.undo(); undo.redo()
    reset()
    check(model.moveNodes(ids: [a.id, unread.id], toSpace: destination.id, markUnread: true) == 2 && a.isUnread && unread.isUnread
          && destination.pinned.first?.id == a.id && destination.today.first?.id == unread.id,
          "Move to Space uses matching sections, ordered slots, and unread flags")
    undo.undo(); check(!a.isUnread && unread.isUnread && window.focusedSpaceID == source.id, "Move undo restores original unread values")
    reset()
    let keep = Set([b.id, unread.id])
    let beforeClear = fingerprint(model)
    model.clearToday(space: source.id, keeping: keep)
    check(source.today.contains { $0.id == nested.id } && source.today.contains { $0.id == unread.id }
          && events.count == 1, "Clear keeping preserves top-level ancestors of selected descendants")
    undo.undo(); check(fingerprint(model) == beforeClear, "Clear keeping undo restores exact positions")
    check(indexMatchesRebuild(model), "Sidebar commands index equals a full rebuild")
    try snapshots.saveNow(model: model)
    let loaded = try snapshots.load()!
    check(fingerprint(loaded) == fingerprint(model), "Sidebar command snapshot roundtrip preserves the result")
    composite.flushAll()
}
