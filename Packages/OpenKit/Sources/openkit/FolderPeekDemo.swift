import Foundation
import OpenModel
import OpenStore

/// S6 flows through the public model commands, real undo, SQLite archive and snapshot store.
@MainActor
func runFolderPeekDemo(root: URL, check: (Bool, String) -> Void) async throws {
    func fixture(_ name: String) -> (BrowserModel, Space, Folder, [Tab], UndoManager) {
        let profile = Profile(name: "Peek \(name)")
        let tabs = (0..<4).map { Tab(url: URL(string: "https://example.invalid/peek/\($0)")!, title: "Synthetic \($0)") }
        let folder = Folder(title: "Peek", children: tabs.prefix(3).map { .tab($0) })
        let space = Space(title: "Peek", profileID: profile.id, pinned: [.folder(folder)], today: [.tab(tabs[3])])
        let model = BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        return (model, space, folder, tabs, undo)
    }
    let (model, _, folder, tabs, undo) = fixture("state")
    var events = 0; model.addObserver { _ in events += 1 }
    model.setFolderExpansion(folderID: folder.id, .peeked(tabs[1].id))
    check(!folder.isExpanded && folder.peekedChildID == tabs[1].id && events == 0, "FP1 peek is false + direct child, property-only event semantics")
    undo.undo()
    check(folder.expansion == .expanded && !undo.canUndo && undo.canRedo, "FP1 one undo restores expanded with no extra undo")
    undo.redo()
    check(folder.expansion == .peeked(tabs[1].id), "FP1 redo restores peek")
    undo.removeAllActions()
    model.setFolderExpansion(folderID: folder.id, .peeked(tabs[1].id))
    check(!undo.canUndo, "FP1 identical state is a no-op")
    model.setExpanded(folderID: folder.id, expanded: false)
    check(folder.expansion == .collapsed, "FP1 boolean false clears an existing peek")
    undo.undo()
    check(folder.expansion == .peeked(tabs[1].id), "FP1 boolean-clear undo restores full state")
    model.setExpanded(folderID: folder.id, expanded: true)
    let nested = model.createFolder(in: .folder(folder.id), title: "Nested", withNodes: [tabs[0].id])!
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(SnapshotMapper.dto(from: model))
    for invalid in [tabs[0].id, tabs[3].id, ItemID(), nested.id] {
        undo.removeAllActions(); let count = events
        model.setFolderExpansion(folderID: folder.id, .peeked(invalid))
        check(try encoder.encode(SnapshotMapper.dto(from: model)) == before && !undo.canUndo && events == count,
              "FP2 rejects nested/foreign/missing/folder child without state, undo or events")
    }
    for command in ["close", "move", "moveMany", "archiveMany", "splitFirst", "splitNonfirst", "addPane", "sameParent", "refused"] {
        let (m, s, f, t, u) = fixture(command)
        _ = try prepareProfiles(m, root: root.appendingPathComponent(command))
        let sink = profileArchiveSink(model: m, directories: ProfileDirectories(root: root.appendingPathComponent(command)))
        m.archiveSink = sink
        var split: Split?
        if command == "addPane" { split = m.makeSplit(tabIDs: [t[0].id, t[2].id]) }
        m.setFolderExpansion(folderID: f.id, .peeked(t[1].id)); u.removeAllActions()
        let originalChildren = f.children.map(\.id), pinned = t.map(\.pinnedURL)
        switch command {
        case "close": m.closeTab(id: t[1].id)
        case "move": _ = m.moveNode(id: t[1].id, to: .spaceToday(s.id), at: nil)
        case "moveMany": _ = m.moveNodes(ids: [t[1].id, t[0].id], to: .spaceToday(s.id))
        case "archiveMany": _ = m.archiveNodes(ids: [t[1].id, t[0].id])
        case "splitFirst": _ = m.makeSplit(tabIDs: [t[1].id, t[3].id])
        case "splitNonfirst": _ = m.makeSplit(tabIDs: [t[3].id, t[1].id])
        case "addPane": _ = m.addPane(splitID: split!.id, tabID: t[1].id)
        case "sameParent": _ = m.moveNode(id: t[1].id, to: .folder(f.id), at: 0)
        default: _ = m.moveNode(id: t[1].id, to: .folder(ItemID()), at: nil)
        }
        let keep = command == "sameParent" || command == "refused"
        check(f.expansion == (keep ? .peeked(t[1].id) : .collapsed), "FP3 \(command) maintains direct-child invariant")
        if command == "refused" { check(!u.canUndo, "FP3 refused move adds no undo"); continue }
        u.undo(); sink.flushAll()
        check(f.expansion == .peeked(t[1].id) && f.children.map(\.id) == originalChildren && t.map(\.pinnedURL) == pinned && !u.canUndo,
              "FP3 \(command) one undo restores hierarchy, peek, order and pinned URLs")
        check((await sink.store(for: s.profileID).recent()).isEmpty, "FP3 \(command) undo leaves no archive rows")
        u.redo()
        check(f.expansion == (keep ? .peeked(t[1].id) : .collapsed), "FP3 \(command) redo repeats full transition")
    }
    for command in ["moveTwoFolders", "archiveTwoFolders"] {
        let (m, s, f, t, u) = fixture(command)
        let other = m.createFolder(in: .spacePinned(s.id), title: "Second source", withNodes: [t[0].id])!
        m.setFolderExpansion(folderID: f.id, .peeked(t[1].id))
        m.setFolderExpansion(folderID: other.id, .peeked(t[0].id)); u.removeAllActions()
        let directory = root.appendingPathComponent(command)
        _ = try prepareProfiles(m, root: directory)
        let store = profileArchiveSink(model: m, directories: ProfileDirectories(root: directory))
        let counted = CountingSink(store: store); m.archiveSink = counted
        if command == "moveTwoFolders" { _ = m.moveNodes(ids: [t[1].id, t[0].id], to: .spaceToday(s.id)) }
        else { _ = m.archiveNodes(ids: [t[1].id, t[0].id]) }
        check(f.expansion == .collapsed && other.expansion == .collapsed && (command != "archiveTwoFolders" || counted.archiveCalls == 1),
              "FP3 \(command) clears both peeks in one bulk command/sink batch")
        u.undo(); store.flushAll()
        check(f.expansion == .peeked(t[1].id) && other.expansion == .peeked(t[0].id)
              && f.children.map(\.id) == [t[1].id, t[2].id] && other.children.map(\.id) == [t[0].id] && !u.canUndo,
              "FP3 \(command) one undo restores both source hierarchies and peeks")
        check((await store.store(for: s.profileID).recent()).isEmpty, "FP3 \(command) undo clears persisted archive rows")
    }
    let (m, s, f, t, u) = fixture("extra")
    let split = m.makeSplit(tabIDs: [t[0].id, t[1].id])!
    u.removeAllActions(); m.setFolderExpansion(folderID: f.id, .peeked(split.id))
    u.undo(); check(f.expansion == .expanded && !u.canUndo, "FP1 direct Split peek uses one undo step")
    u.redo(); check(f.expansion == .peeked(split.id), "FP1 direct Split peek redo restores the split row ID")
    u.removeAllActions(); m.removePane(splitID: split.id, tabID: t[0].id, archive: true)
    check(f.expansion == .collapsed, "FP3 removing a pane that dissolves the peeked split clears its old ID")
    u.undo()
    check(f.expansion == .peeked(split.id) && m.node(id: split.id)?.split === split && !u.canUndo, "FP3 one pane undo restores split peek")
    u.removeAllActions(); m.unsplit(splitID: split.id)
    check(f.expansion == .collapsed, "FP3 unsplit clears the removed split row")
    u.undo(); check(f.expansion == .peeked(split.id) && !u.canUndo, "FP3 unsplit undo restores peek in one step")
    let duplicate = m.duplicateNodes(ids: [f.id]).first!
    let copied = m.node(id: duplicate)!.folder!
    check(copied.peekedChildID == copied.children[0].id && copied.peekedChildID != split.id, "FP3 duplicate remaps peek into the copied subtree")
    u.undo(); u.removeAllActions()
    check(m.setAllFoldersExpanded(spaceID: s.id, expanded: false) == 1 && f.expansion == .collapsed, "FP3 Collapse All clears peek even with false bool")
    u.undo(); check(f.expansion == .peeked(split.id) && !u.canUndo, "FP3 Collapse All one undo restores peek")
    _ = m.setAllFoldersExpanded(spaceID: s.id, expanded: true)
    check(f.expansion == .expanded && f.peekedChildID == nil, "FP3 Expand All never keeps a peek")
    m.setFolderExpansion(folderID: f.id, .peeked(split.id))
    let snapshots = SnapshotStore(root: root.appendingPathComponent("persist"))
    try snapshots.saveNow(model: m)
    let loaded = try snapshots.load()!
    check(loaded.node(id: f.id)?.folder?.expansion == .peeked(split.id) && SnapshotMapper.structurallyEqual(m, loaded), "FP4 real snapshot save/load preserves split peek and structural equality")
    func rewrite(_ value: Any, _ replacement: String?) -> Any {
        if var dict = value as? [String: Any] {
            dict.removeValue(forKey: "peekedChildID")
            if dict["isExpanded"] != nil, let replacement { dict["peekedChildID"] = replacement }
            return dict.mapValues { rewrite($0, replacement) }
        }
        if let list = value as? [Any] { return list.map { rewrite($0, replacement) } }
        return value
    }
    let saved = try Data(contentsOf: snapshots.fileURL)
    for value in [nil, "malformed", ItemID().description] as [String?] {
        let raw = try JSONSerialization.jsonObject(with: saved)
        try JSONSerialization.data(withJSONObject: rewrite(raw, value)).write(to: snapshots.fileURL)
        let legacy = try snapshots.load()!
        check(legacy.node(id: f.id)?.folder?.expansion == .collapsed, "FP4 absent/malformed/stale optional ID safely decodes nil")
    }
    func expandedWithPeek(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            if dict["isExpanded"] != nil { dict["isExpanded"] = true }
            return dict.mapValues(expandedWithPeek)
        }
        if let list = value as? [Any] { return list.map(expandedWithPeek) }
        return value
    }
    try JSONSerialization.data(withJSONObject: expandedWithPeek(JSONSerialization.jsonObject(with: saved))).write(to: snapshots.fileURL)
    check(try snapshots.load()?.node(id: f.id)?.folder?.expansion == .expanded, "FP4 expanded + peek snapshot normalizes to expanded/nil")
    try snapshots.saveNow(model: m)
    let nestedArchive = m.createFolder(in: .folder(f.id), title: "Nested archive", withNodes: [t[2].id])!
    m.setFolderExpansion(folderID: nestedArchive.id, .peeked(t[2].id))
    _ = try prepareProfiles(m, root: root.appendingPathComponent("archive"))
    let sink = profileArchiveSink(model: m, directories: ProfileDirectories(root: root.appendingPathComponent("archive")))
    m.archiveSink = sink; u.removeAllActions()
    m.closeTab(id: f.id); sink.flushAll()
    let archived = await sink.store(for: s.profileID).record(id: f.id)!
    check(!archived.payloadJSON.contains("peekedChildID"), "FP3 archive payload omits root and nested peek metadata")
    u.undo(); sink.flushAll()
    check(f.expansion == .peeked(split.id) && !u.canUndo, "FP3 folder deletion undo restores live original peek")
    m.closeTab(id: f.id)
    let restored = m.restoreArchivedFolder(archived)
    check(restored?.expansion == .collapsed && restored?.peekedChildID == nil && m.node(id: nestedArchive.id)?.folder?.expansion == .collapsed,
          "FP3 archive restore drops root and nested peek metadata")
    let (sweepModel, sweepSpace, sweepFolder, sweepTabs, _) = fixture("sweep")
    _ = sweepModel.moveNode(id: sweepFolder.id, to: .spaceToday(sweepSpace.id), at: nil)
    sweepModel.setFolderExpansion(folderID: sweepFolder.id, .peeked(sweepTabs[1].id))
    sweepTabs[1].lastActiveAt = Date(timeIntervalSince1970: 0)
    _ = sweepModel.archiveExpiredTabs(now: Date())
    check(sweepFolder.expansion == .collapsed && sweepModel.tab(id: sweepTabs[1].id) == nil,
          "FP3 auto-archive clears a removed Today peek without substituting a child")
    // Combined S6 / Today-sweeper flow through public commands and real SQLite.
    for asSplit in [false, true] {
        let label = asSplit ? "split" : "tab"
        let profile = Profile(settings: ProfileSettings(autoArchiveAfter: .oneHour))
        let panes = (0..<(asSplit ? 2 : 1)).map { Tab(url: URL(string: "https://example.invalid/shown-peek/\($0)")!) }
        let shown: SidebarNode = asSplit ? .split(Split(panes: panes, focusedPaneID: panes[0].id)) : .tab(panes[0])
        let pin = Tab(url: URL(string: "https://example.invalid/shown-pin")!)
        let folder = Folder(children: [shown])
        let space = Space(profileID: profile.id, pinned: [.tab(pin)], today: [.folder(folder)])
        let window = BrowserWindowState(focusedSpaceID: space.id)
        let live = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        let manager = UndoManager(); manager.groupsByEvent = false; live.undoManager = manager
        let archives = ProfileArchiveSink(directories: ProfileDirectories(root: root.appendingPathComponent("shown-peek-" + label))) { _ in profile.dataDirectoryName }
        live.archiveSink = archives
        live.selectNode(windowID: window.id, spaceID: space.id, nodeID: shown.id)
        manager.removeAllActions()
        live.setFolderExpansion(folderID: folder.id, .peeked(shown.id))
        manager.undo(); let expandedUndo = folder.expansion == .expanded && !manager.canUndo
        manager.redo()
        for tab in panes { tab.lastActiveAt = Date(timeIntervalSince1970: 0) }
        let protected = live.archiveExpiredTabs(now: Date()) == 0 && live.nextAutoArchiveExpiry() == nil
        check(expandedUndo && folder.expansion == .peeked(shown.id) && protected && panes.allSatisfy { live.tab(id: $0.id) != nil },
              "FP-AA \(label) selected peek survives sweep/undo/redo and has no expiry")
        live.undoManager = nil
        let before = Date()
        live.selectNode(windowID: window.id, spaceID: space.id, nodeID: pin.id)
        let after = Date()
        let fresh = panes.allSatisfy { $0.lastActiveAt >= before && $0.lastActiveAt <= after }
        check(fresh && live.nextAutoArchiveExpiry() == panes.map { $0.lastActiveAt.addingTimeInterval(3600) }.min(),
              "FP-AA \(label) leaving selected peek starts fresh inactivity without an UndoManager")
        _ = live.archiveExpiredTabs(now: after.addingTimeInterval(3601)); archives.flushAll()
        let rows = await archives.store(for: profile.id).recent()
        check(folder.expansion == .collapsed && panes.allSatisfy { live.tab(id: $0.id) == nil }
              && Set(panes.map(\.id)).isSubset(of: Set(rows.map(\.id))),
              "FP-AA \(label) unselected Today peek expires through SQLite and clears in the same sweep")
    }

}
