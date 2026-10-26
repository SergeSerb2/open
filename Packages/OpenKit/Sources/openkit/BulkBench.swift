import Foundation
import OpenModel
import OpenStore

/// Seeded generator so bench runs are comparable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func microseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
}

/// True when the incrementally kept index matches a full rebuild.
@MainActor
func indexMatchesRebuild(_ model: BrowserModel) -> Bool {
    let parents = model.parentByID
    let keys = Set(model.index.keys)
    model.rebuildIndex()
    return model.parentByID == parents && Set(model.index.keys) == keys
}

@MainActor
func encodedTree(_ model: BrowserModel) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(SnapshotMapper.dto(from: model))) ?? Data()
}

/// 5,000 items over 10 Spaces. Per Space: 250 pinned tabs, 230 Today tabs, 2 Today folders of 9 tabs.
@MainActor
func makeMoveBenchModel() -> BrowserModel {
    let profile = Profile(name: "Bench")
    var spaces: [Space] = []
    var counter = 0
    func makeTab(pinned: Bool) -> SidebarNode {
        counter += 1
        let url = URL(string: "https://bench-\(counter).example.com/")!
        return .tab(Tab(url: url, title: "Bench \(counter)", pinnedURL: pinned ? url : nil))
    }
    for s in 0..<10 {
        let space = Space(title: "Bench \(s)", profileID: profile.id)
        space.pinned = (0..<250).map { _ in makeTab(pinned: true) }
        var today = (0..<230).map { _ in makeTab(pinned: false) }
        for f in 0..<2 {
            today.append(.folder(Folder(title: "Folder \(f)", children: (0..<9).map { _ in makeTab(pinned: false) })))
        }
        space.today = today
        spaces.append(space)
    }
    return BrowserModel(profiles: [profile], spaces: spaces, windows: [BrowserWindowState(focusedSpaceID: spaces[0].id)])
}

/// 2,000 expired tabs: 1,500 top-level, 400 in 20 folders, 100 as panes of 50 three-pane splits
/// (each split keeps one fresh pane and collapses). Plus 450 fresh tabs.
@MainActor
func makeExpiryBenchModel() -> BrowserModel {
    let profile = Profile(name: "Expiry")
    let space = Space(title: "Expiry", profileID: profile.id)
    var counter = 0
    func makeTab(expired: Bool) -> Tab {
        counter += 1
        return Tab(url: URL(string: "https://expiry-\(counter).example.com/")!, title: "Expiry \(counter)",
                   lastActiveAt: expired ? Date(timeIntervalSince1970: 0) : Date())
    }
    var today: [SidebarNode] = []
    for _ in 0..<1500 { today.append(.tab(makeTab(expired: true))) }
    for _ in 0..<300 { today.append(.tab(makeTab(expired: false))) }
    for f in 0..<20 {
        let children = (0..<25).map { SidebarNode.tab(makeTab(expired: $0 < 20)) }
        today.append(.folder(Folder(title: "Folder \(f)", children: children)))
    }
    for _ in 0..<50 {
        today.append(.split(Split(panes: [makeTab(expired: true), makeTab(expired: true), makeTab(expired: false)])))
    }
    space.today = today
    return BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
}

@MainActor
func runBulkBench() async {
    print("bench: bulk commands")
    let clock = ContinuousClock()

    // moveNode: random tabs to random Pinned / Today / folder slots in random Spaces.
    func plannedMoves(for model: BrowserModel) -> [(id: ItemID, to: NodeParent, at: Int)] {
        var rng = SplitMix64(state: 42)
        let tabIDs = model.index.compactMap { $0.value.tab?.id }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let destinations: [NodeParent] = model.spaces.flatMap { space in
            [.spacePinned(space.id), .spaceToday(space.id)] + space.today.compactMap { $0.folder.map { NodeParent.folder($0.id) } }
        }
        return (0..<10_000).map { _ in
            (tabIDs.randomElement(using: &rng)!, destinations.randomElement(using: &rng)!, Int.random(in: 0...300, using: &rng))
        }
    }

    let withUndo = makeMoveBenchModel()
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.levelsOfUndo = 0
    withUndo.undoManager = undo
    let original = encodedTree(withUndo)
    let moves = plannedMoves(for: withUndo)
    var accepted = 0
    let moveTime = clock.measure {
        for move in moves where withUndo.moveNode(id: move.id, to: move.to, at: move.at) { accepted += 1 }
    }
    let movedIndexOK = indexMatchesRebuild(withUndo)
    let undoTime = clock.measure {
        while undo.canUndo { undo.undo() }
    }
    let restoredOK = encodedTree(withUndo) == original
    let undoneIndexOK = indexMatchesRebuild(withUndo)

    let noUndo = makeMoveBenchModel()
    let movesNoUndo = plannedMoves(for: noUndo)
    let moveTimeNoUndo = clock.measure {
        for move in movesNoUndo { noUndo.moveNode(id: move.id, to: move.to, at: move.at) }
    }

    print(String(format: "  moveNode x10000 on 5000-item model (UndoManager on):  %.1f ms total, %.2f us avg (target < 50 us), accepted=%d",
                 microseconds(moveTime) / 1000, microseconds(moveTime) / 10_000, accepted))
    print(String(format: "  moveNode x10000 on 5000-item model (no UndoManager): %.1f ms total, %.2f us avg",
                 microseconds(moveTimeNoUndo) / 1000, microseconds(moveTimeNoUndo) / 10_000))
    print(String(format: "  undo x%d: %.1f ms; tree equals original: %@; index equals full rebuild: %@ (after moves) %@ (after undo)",
                 accepted, microseconds(undoTime) / 1000, restoredOK ? "OK" : "FAIL", movedIndexOK ? "OK" : "FAIL", undoneIndexOK ? "OK" : "FAIL"))

    // archiveExpiredTabs: model pass alone, then with the real ArchiveStore as sink.
    let bare = makeExpiryBenchModel()
    var bareEvents = 0
    bare.addObserver { _ in bareEvents += 1 }
    var bareArchived = 0
    let bareTime = clock.measure { bareArchived = bare.archiveExpiredTabs(now: Date()) }
    let bareIndexOK = indexMatchesRebuild(bare)

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openkit-bench-archive-\(UUID().uuidString)")
    let directories = ProfileDirectories(root: tmp)
    do { try OpenDataRoot.prepare(root: tmp) }
    catch { profileCLIError("cannot prepare data root: \(error)") }
    try! directories.ensureProfileDirectories(dataDirectoryName: "Default")
    let stored = makeExpiryBenchModel()
    let sink = profileArchiveSink(model: stored, directories: directories)
    let store = sink.store(for: stored.defaultProfile?.id)
    stored.archiveSink = sink
    var storedArchived = 0
    let mainTime = clock.measure { storedArchived = stored.archiveExpiredTabs(now: Date()) }
    let writeTime = clock.measure { store.flushQueue() }
    let rows = await store.count()
    try? FileManager.default.removeItem(at: tmp)

    print(String(format: "  archiveExpiredTabs on 2000 expired tabs (model only):     %.2f ms, archived=%d, events=%d, index equals full rebuild: %@",
                 microseconds(bareTime) / 1000, bareArchived, bareEvents, bareIndexOK ? "OK" : "FAIL"))
    print(String(format: "  archiveExpiredTabs on 2000 expired tabs (ArchiveStore):   %.2f ms on the main actor + %.1f ms background write, rows=%d",
                 microseconds(mainTime) / 1000, microseconds(writeTime) / 1000, rows))
    _ = storedArchived
}
