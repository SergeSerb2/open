import Foundation
import OpenModel
import OpenStore
import SQLite3

@MainActor
func runFolderArchiveDemo(root: URL, check: (Bool, String) -> Void) async throws {
    let profile = Profile(name: "Folder archive")
    let space = Space(title: "Archive Source", profileID: profile.id)
    let fallback = Space(title: "Fallback", profileID: profile.id)
    let window = BrowserWindowState(focusedSpaceID: fallback.id)
    let model = BrowserModel(profiles: [profile], spaces: [space, fallback], windows: [window])
    _ = try prepareProfiles(model, root: root)
    let snapshots = SnapshotStore(root: root)
    let sink = profileArchiveSink(model: model, directories: ProfileDirectories(root: root))
    let store = sink.store(for: profile.id); model.archiveSink = sink
    let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
    var events: [TreeChange] = []; model.addObserver { events.append($0) }
    func url(_ name: String) -> URL { URL(string: "https://example.invalid/\(name)")! }
    let a = model.newTab(in: space.id, url: url("A"), title: "A")
    let b = model.newTab(in: space.id, url: url("B"), title: "B")
    let c = model.newTab(in: space.id, url: url("C"), title: "C")
    a.customTitle = "A custom"; a.customIcon = "star"; a.isUnread = true; b.isMuted = true
    let split = model.makeSplit(tabIDs: [b.id, c.id], orientation: .vertical)!
    model.setSplitFractions(splitID: split.id, fractions: [0.3, 0.7])
    let deep = model.createFolder(in: .spacePinned(space.id), title: "Deep", withNodes: [split.id])!
    let folder = model.createFolder(in: .spacePinned(space.id), title: "Archived", withNodes: [a.id, deep.id])!
    folder.customIcon = "folder.badge.plus"; folder.isExpanded = false
    let parent = model.createFolder(in: .spacePinned(space.id), title: "Parent", withNodes: [folder.id])!
    let originalIDs = [folder.id, a.id, deep.id, split.id, b.id, c.id]
    undo.removeAllActions(); events = []
    check(model.archiveFolder(id: folder.id), "FA1 folder Delete archive accepted")
    sink.flushAll()
    let rows = await store.recent()
    check(rows.count == 1 && rows[0].kind == .folder && rows[0].reason == .folderDeleted && rows[0].id == folder.id
          && originalIDs.allSatisfy { model.node(id: $0) == nil } && events.count == 1,
          "FA1 one folder row and one remove, no child tab rows")
    print("    FA1 events=\(events.map(describe))")
    let record = await store.restore(id: folder.id)!
    undo.removeAllActions(); events = []
    let restored = model.restoreArchivedFolder(record)
    let restoredSplit = model.node(id: split.id)?.split
    check(restored?.children.map(\.id) == [a.id, deep.id] && model.node(id: deep.id)?.folder?.children.first?.id == split.id
          && restoredSplit?.panes.map(\.id) == [b.id, c.id] && restoredSplit?.orientation == .vertical
          && restoredSplit?.fractions == [0.3, 0.7] && model.tab(id: a.id)?.customTitle == "A custom"
          && restored?.customIcon == folder.customIcon && restored?.isExpanded == false
          && originalIDs.allSatisfy { model.node(id: $0) != nil } && events.count == 1,
          "FA2 restore reconstructs nested folders, split, metadata, original IDs and order")
    check(model.tab(id: b.id)?.pinnedURL == b.url && model.tab(id: b.id)!.lastActiveAt > record.archivedAt,
          "FA2 restore reapplies pinned URLs and refreshes activity")
    undo.undo(); sink.flushAll()
    let undoRow = await store.record(id: folder.id)
    check(model.node(id: folder.id) == nil && undoRow?.kind == .folder && !undo.canUndo,
          "FA5 one undo of restore writes a folder row back")
    undo.redo(); sink.flushAll()
    let redoRow = await store.record(id: folder.id)
    check(model.node(id: folder.id) != nil && redoRow == nil, "FA5 redo restores folder and drops row")
    undo.removeAllActions()
    model.closeTab(id: folder.id); sink.flushAll()
    check((await store.record(id: folder.id))?.kind == .folder, "FA1 existing closeTab Delete path writes a folder record")
    undo.undo(); sink.flushAll()
    let deleteUndoRow = await store.record(id: folder.id)
    check(model.node(id: folder.id) != nil && deleteUndoRow == nil, "FA5 undo of Delete restores folder and discards row")

    _ = model.archiveFolder(id: folder.id); sink.flushAll()
    let fallbackRecord = await store.record(id: folder.id)!
    model.closeTab(id: parent.id)
    let sectionRestored = model.restoreArchivedFolder(fallbackRecord)
    check(sectionRestored != nil && space.pinned.first?.id == folder.id, "FA3 missing parent falls back to the original Pinned section")
    _ = model.archiveFolder(id: folder.id); sink.flushAll()
    let missingSpaceRecord = await store.record(id: folder.id)!
    model.deleteSpace(id: space.id)
    let focusedRestored = model.restoreArchivedFolder(missingSpaceRecord)
    check(focusedRestored != nil && fallback.today.first?.id == folder.id && model.tab(id: b.id)?.pinnedURL == nil,
          "FA3 missing Space falls back to focused Today and clears pinned URLs")

    let profileB = model.createProfile(name: "Profile B")!
    let sourceB = model.createSpace(title: "B archive source", profileID: profileB.id)
    let survivingB = model.createSpace(title: "B surviving Space", profileID: profileB.id)
    let tabB = model.newTab(in: sourceB.id, url: url("Profile-B"), title: "Profile B tab")
    let folderB = model.createFolder(in: .spacePinned(sourceB.id), title: "Profile B folder", withNodes: [tabB.id])!
    _ = model.archiveFolder(id: folderB.id); sink.flushAll()
    let profileBStore = sink.store(for: profileB.id)
    let recordB = await profileBStore.record(id: folderB.id)!
    model.deleteSpace(id: sourceB.id)
    window.focusedSpaceID = fallback.id // Profile A is visible in the first window.
    let restoredB = model.restoreArchivedFolder(recordB)
    check(restoredB != nil && model.parent(of: folderB.id) == .spaceToday(survivingB.id)
          && model.space(id: survivingB.id)?.profileID == profileB.id && window.focusedSpaceID == fallback.id,
          "FA3 missing Space keeps the archived Profile B when the first window shows Profile A")

    _ = model.archiveFolder(id: folder.id); sink.flushAll()
    let duplicateRecord = await store.record(id: folder.id)!
    var existingA = duplicateRecord
    existingA.kind = .tab; existingA.id = a.id; existingA.url = a.url; existingA.payloadJSON = "{}"
    let liveA = model.restoreArchivedTab(existingA)
    var existingPane = duplicateRecord
    existingPane.kind = .tab; existingPane.id = b.id; existingPane.url = b.url; existingPane.payloadJSON = "{}"
    let livePane = model.restoreArchivedTab(existingPane)
    let companion = model.newTab(in: fallback.id, url: url("Live-pane-companion"))
    let liveSplit = model.makeSplit(tabIDs: [livePane.id, companion.id])!
    let skipped = model.restoreArchivedFolder(duplicateRecord)
    check(skipped != nil && skipped?.children.map(\.id) == [deep.id] && model.tab(id: a.id) === liveA
          && occurrences(of: a.id, in: model) == 1 && occurrences(of: b.id, in: model) == 1
          && model.tab(id: b.id) === livePane && model.parent(of: b.id) == .splitPane(liveSplit.id)
          && model.node(id: deep.id)?.folder?.children.first?.id == c.id && model.node(id: split.id) == nil,
          "FA4 live child and live split pane are skipped; a single remaining archived pane restores as a tab")
    undo.removeAllActions(); events = []
    check(model.restoreArchivedFolder(duplicateRecord) == nil && events.isEmpty && !undo.canUndo,
          "FA4 live root refuses restore without undo or events")
    _ = model.archiveFolder(id: folder.id); sink.flushAll()
    try snapshots.saveNow(model: model)
    let reloaded = try snapshots.load()!
    check(SnapshotMapper.structurallyEqual(model, reloaded) && reloaded.node(id: folder.id) == nil,
          "FA7 snapshot roundtrip preserves the live tree with the archived folder absent")

    // Open a genuine pre-kind SQLite archive, including an old folderDeleted TAB row.
    let legacyRoot = root.appendingPathComponent("Legacy")
    let file = ProfileDirectories(root: legacyRoot).archiveFileURL(dataDirectoryName: "Default")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(file.path, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    let legacyID = ItemID()
    let sql = """
    CREATE TABLE archived_tabs(id TEXT PRIMARY KEY,url TEXT NOT NULL,title TEXT NOT NULL,space_id TEXT,profile_id TEXT,archived_at REAL NOT NULL,reason TEXT NOT NULL,original_location TEXT NOT NULL,payload TEXT NOT NULL);
    INSERT INTO archived_tabs VALUES('\(legacyID)','https://example.invalid/legacy','Legacy tab',NULL,NULL,1,'folderDeleted','today:\(fallback.id)','{}');
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(database); throw CocoaError(.fileWriteUnknown) }
    sqlite3_close(database)
    let legacy = ArchiveStore(fileURL: file)
    let old = await legacy.recent()
    let reopened = await ArchiveStore(fileURL: file).recent()
    check(old.count == 1 && old[0].id == legacyID && old[0].kind == .tab && old[0].reason == .folderDeleted
          && old[0].payloadJSON == "{}" && reopened.first?.id == legacyID,
          "FA6 migration and repeat open preserve every legacy row as a tab")
    check(indexMatchesRebuild(model), "FA7 folder archive index equals a full rebuild")
}
