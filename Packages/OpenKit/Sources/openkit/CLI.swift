import Foundation
import OpenModel
import OpenStore
import OpenImport

@MainActor
func printTree(model: BrowserModel, showTitles: Bool) {
    func host(of url: URL) -> String { url.host() ?? "•••" }
    func tabLine(_ tab: Tab, indent: String) {
        if showTitles {
            print("\(indent)tab \(tab.id.rawValue.uuidString.prefix(8)) \(tab.displayTitle) <\(tab.url.absoluteString)>")
        } else {
            print("\(indent)tab \(tab.id.rawValue.uuidString.prefix(8)) ••• <\(host(of: tab.url))>")
        }
    }
    func nodeLines(_ nodes: [SidebarNode], indent: String) {
        for node in nodes {
            switch node {
            case .tab(let tab): tabLine(tab, indent: indent)
            case .folder(let folder):
                print("\(indent)folder \(folder.id.rawValue.uuidString.prefix(8)) \(showTitles ? folder.title : "•••") expanded=\(folder.isExpanded)")
                nodeLines(folder.children, indent: indent + "  ")
            case .split(let split):
                print("\(indent)split \(split.id.rawValue.uuidString.prefix(8)) \(split.orientation.rawValue) panes=\(split.panes.count)")
                for pane in split.panes { tabLine(pane, indent: indent + "  ") }
            }
        }
    }
    for profile in model.profiles {
        print("profile \(profile.id.rawValue.uuidString.prefix(8)) \(showTitles ? profile.name : "•••") favorites=\(profile.favorites.count)")
        for tab in profile.favorites { tabLine(tab, indent: "  fav ") }
    }
    for space in model.spaces {
        print("space \(space.id.rawValue.uuidString.prefix(8)) \(showTitles ? model.displayTitle(for: space) : "•••") profile=\(space.profileID.rawValue.uuidString.prefix(8)) pinnedCollapsed=\(space.isPinnedCollapsed)")
        print("  pinned:")
        nodeLines(space.pinned, indent: "    ")
        print("  today:")
        nodeLines(space.today, indent: "    ")
    }
    print("windows=\(model.windows.count) routingRules=\(model.routingRules.count) defaultDestination=\(model.defaultDestination)")
}

@MainActor
func runImportArc(args: [String]) async throws {
    var arcDir: URL?
    var outDir: URL?
    var showTitles = false
    var countsOnly = false
    var idx = 0
    while idx < args.count {
        switch args[idx] {
        case "--arc-dir": idx += 1; arcDir = URL(fileURLWithPath: args[idx])
        case "--out": idx += 1; outDir = URL(fileURLWithPath: args[idx])
        case "--show-titles": showTitles = true
        case "--counts-only": countsOnly = true
        default: break
        }
        idx += 1
    }
    guard let outDir else {
        FileHandle.standardError.write(Data("usage: openkit import-arc [--arc-dir PATH] --out DIR [--show-titles|--counts-only]\n".utf8))
        exit(2)
    }
    let store = SnapshotStore(root: outDir)
    let previous = try store.load()
    let directories = ProfileDirectories(root: outDir)
    let reserved = try directories.unavailableDirectoryNames()
    let existing = Dictionary(uniqueKeysWithValues: (previous?.profiles ?? []).map { ($0.id, $0.dataDirectoryName) })
    let importer = ArcImporter(arcDirectory: arcDir)
    let result = try importer.importAll(directoryNamesToAvoid: reserved, existingDirectories: existing)
    if let importedDefault = result.model.defaultProfile, reserved.contains("default"), existing[importedDefault.id] != "Default" {
        throw NSError(domain: "OpenStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "import refused: Default directory is reserved by existing data"])
    }
    let model = result.model
    var report = result.report
    // Preserve old output stores before opening any new per-Profile archive.
    _ = try prepareProfiles(model, root: outDir)
    try store.saveNow(model: model)
    let archiveSink = profileArchiveSink(model: model, directories: directories)
    for (id, records) in Dictionary(grouping: result.archiveRecords, by: \.profileID) {
        let stored = await archiveSink.store(for: id).importRecords(records)
        report.archiveStoredNew += stored.inserted
        report.archiveStoredDuplicates += stored.duplicates
    }
    var archiveTotalStored = 0
    for profile in model.profiles { archiveTotalStored += await archiveSink.store(for: profile.id).count() }
    print("import report:")
    print("  profiles=\(report.profiles) profilesGuessed=\(report.profilesGuessed) chromiumDirsFound=\(report.chromiumDirsFound) chromiumDirsMissing=\(report.chromiumDirsMissing)")
    for profile in model.profiles where !countsOnly {
        print("  profile dir=\(profile.dataDirectoryName) spaces=\(model.spaces(using: profile.id).count) favorites=\(profile.favorites.count)")
    }
    print("  totalItems=\(report.totalItems) accounted=\(report.accounted) spaces=\(report.spaces)")
    print("  pinnedTabs=\(report.pinnedTabs) todayTabs=\(report.todayTabs) favorites=\(report.favorites)")
    print("  folders=\(report.folders) splits=\(report.splits) routingRules=\(report.routingRules)")
    print("  skipped easels=\(report.skippedEasels) notes=\(report.skippedNotes) unknown=\(report.skippedUnknown)")
    print("  welcome imported=\(report.importedWelcome) skipped=0 untitledSpaces=\(report.untitledSpaces)")
    print("  namedSpaceIcons mapped=\(report.namedSpaceIcons.values.reduce(0, +)) unknown=\(report.unknownNamedSpaceIcons) fallback=\(NamedSpaceIcons.fallbackSymbol)")
    for name in report.namedSpaceIcons.keys.sorted() {
        print("  namedSpaceIcon \(name) count=\(report.namedSpaceIcons[name]!) symbol=\(NamedSpaceIcons.symbolName(for: name))")
    }
    print("  orphans=\(report.orphans) skippedRoutingRules=\(report.skippedRoutingRules)")
    print("  archive: \(report.archiveStatus)")
    if report.archiveFilePresent {
        print("  archive filePresent=true total=\(report.archiveTotal) imported=\(report.archiveImported) storedNew=\(report.archiveStoredNew) storedDuplicates=\(report.archiveStoredDuplicates) storedTotal=\(archiveTotalStored)")
        print("  archive skipped easels=\(report.archiveSkippedEasels) notes=\(report.archiveSkippedNotes) welcome=\(report.archiveSkippedWelcome) unknownKind=\(report.archiveSkippedUnknownKind) unknownReason=\(report.archiveSkippedUnknownReason) unknownSource=\(report.archiveSkippedUnknownSource) malformed=\(report.archiveSkippedMalformed) duplicatesInFile=\(report.archiveDuplicatesInFile) alreadyLive=\(report.archiveAlreadyLive)")
        print("  archive welcome imported=\(report.archiveImportedWelcome)")
        let archiveCheck = report.archiveAccounted == report.archiveTotal ? "OK" : "MISMATCH"
        print("  archive check accounted=\(report.archiveAccounted) total=\(report.archiveTotal) \(archiveCheck)")
    } else {
        print("  archive filePresent=false total=0 imported=0")
    }
    print("  boosts: \(report.boostsStatus)")
    if report.sessionFilePresent {
        print("  session filePresent=true totalPairs=\(report.sessionTotalPairs) mapped=\(report.sessionMapped) unmappedItems=\(report.sessionUnmappedItems) unmappedWindows=\(report.sessionUnmappedWindows) ignoredIncognito=\(report.sessionIgnoredIncognito) windows=\(report.sessionWindows) appliedSelections=\(report.sessionAppliedSelections) distinctChromiumIDs=\(report.sessionDistinctChromiumIDs) malformedPairs=\(report.sessionMalformedPairs)")
    } else {
        print("  session filePresent=false totalPairs=0 mapped=0")
    }
    print("  containers(structural)=\(report.containers) check imported+skipped+containers=\(report.accountedTotal) total=\(report.totalItems)")
    let sidebarCheck = report.accountedTotal == report.totalItems ? "OK" : "MISMATCH"
    print("  accounted check: \(sidebarCheck)")
    if report.accountedTotal != report.totalItems {
        if !countsOnly { printTree(model: model, showTitles: showTitles) }
        exit(1)
    }
    if report.archiveFilePresent && report.archiveAccounted != report.archiveTotal {
        if !countsOnly { printTree(model: model, showTitles: showTitles) }
        exit(1)
    }
    if !countsOnly { printTree(model: model, showTitles: showTitles) }
}

@MainActor
func runArchiveList(args: [String]) async {
    var dirArg: String?
    var limit = 100
    var profileRef: String?
    var idx = 0
    while idx < args.count {
        switch args[idx] {
        case "--limit":
            idx += 1
            guard idx < args.count, let count = Int(args[idx]), count >= 0 else { profileCLIError("invalid limit", code: 2) }
            limit = count
        case "--profile":
            idx += 1
            guard idx < args.count else { profileCLIError("missing profile", code: 2) }
            profileRef = args[idx]
        default:
            if dirArg == nil { dirArg = args[idx] }
        }
        idx += 1
    }
    guard let dirArg else {
        FileHandle.standardError.write(Data("usage: openkit archive-list DIR [--limit N] [--profile PROFILE]\n".utf8))
        exit(2)
    }
    let root = URL(fileURLWithPath: dirArg)
    let model: BrowserModel
    do {
        model = try SnapshotStore(root: root).load() ?? BrowserModel()
        _ = try prepareProfiles(model, root: root)
    } catch { profileCLIError("cannot prepare data root: \(error)") }
    let selected: Profile?
    if let profileRef {
        guard let profile = resolveProfile(profileRef, in: model) else { profileCLIError("unknown profile \(profileRef)", code: 2) }
        selected = profile
    } else { selected = model.defaultProfile }
    let store = ArchiveStore(fileURL: ProfileDirectories(root: root).archiveFileURL(dataDirectoryName: selected?.dataDirectoryName ?? "Default"))
    let rows = await store.recent(limit: max(0, limit))
    let total = await store.count()
    print("archive rows total=\(total) showing=\(rows.count)")
    let formatter = ISO8601DateFormatter()
    for row in rows {
        let host = row.url.host() ?? "•••"
        print("  archive \(row.id.rawValue.uuidString.prefix(8)) ••• <\(host)> reason=\(row.reason.rawValue) archivedAt=\(formatter.string(from: row.archivedAt))")
    }
}

@MainActor
func runDump(args: [String]) throws {
    guard let dirArg = args.first else { FileHandle.standardError.write(Data("usage: openkit dump DIR\n".utf8)); exit(2) }
    let store = SnapshotStore(root: URL(fileURLWithPath: dirArg))
    guard let model = try store.load() else { print("no snapshot at \(dirArg)"); return }
    printTree(model: model, showTitles: false)
}

@MainActor
func runRoundtrip(args: [String]) throws {
    guard let dirArg = args.first else { FileHandle.standardError.write(Data("usage: openkit roundtrip DIR\n".utf8)); exit(2) }
    let root = URL(fileURLWithPath: dirArg)
    let store = SnapshotStore(root: root)
    guard let first = try store.load() else { print("no snapshot at \(dirArg)"); exit(1) }
    try store.saveNow(model: first)
    guard let second = try store.load() else { print("reload failed"); exit(1) }
    if SnapshotMapper.structurallyEqual(first, second) {
        print("roundtrip OK")
    } else {
        print("roundtrip MISMATCH")
        exit(1)
    }
}

func runBench() async throws {
    print("bench: synthetic model (5000 items over 10 spaces)")
    let result = try await MainActor.run { () throws -> (encodeMs: Double, decodeMs: Double, saveMs: Double, loadMs: Double) in
        let profile = Profile(name: "Bench")
        var spaces: [Space] = []
        var counter = 0
        for s in 0..<10 {
            let space = Space(title: "Space \(s)", profileID: profile.id)
            var pinned: [SidebarNode] = []
            var today: [SidebarNode] = []
            for _ in 0..<250 {
                counter += 1
                pinned.append(.tab(Tab(url: URL(string: "https://example-\(counter).com/page")!, title: "Page \(counter)")))
            }
            for _ in 0..<250 {
                counter += 1
                today.append(.tab(Tab(url: URL(string: "https://example-\(counter).com/page")!, title: "Page \(counter)")))
            }
            space.pinned = pinned
            space.today = today
            spaces.append(space)
        }
        let window = BrowserWindowState(focusedSpaceID: spaces[0].id)
        let model = BrowserModel(profiles: [profile], spaces: spaces, windows: [window])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openkit-bench-\(UUID().uuidString)")
        let store = SnapshotStore(root: tmp)
        try OpenDataRoot.prepare(root: tmp, model: model)
        let dto = SnapshotMapper.dto(from: model)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var t0 = Date(); let data = try! encoder.encode(dto); let encodeMs = Date().timeIntervalSince(t0) * 1000
        t0 = Date(); _ = try! JSONDecoder().decode(SnapshotFileDTO.self, from: data); let decodeMs = Date().timeIntervalSince(t0) * 1000
        t0 = Date(); try store.saveNow(model: model); let saveMs = Date().timeIntervalSince(t0) * 1000
        t0 = Date(); _ = try! store.load(); let loadMs = Date().timeIntervalSince(t0) * 1000
        try? FileManager.default.removeItem(at: tmp)
        return (encodeMs, decodeMs, saveMs, loadMs)
    }
    print(String(format: "  snapshot encode: %.1f ms", result.encodeMs))
    print(String(format: "  snapshot decode: %.1f ms", result.decodeMs))
    print(String(format: "  snapshot save:   %.1f ms", result.saveMs))
    print(String(format: "  snapshot load:   %.1f ms", result.loadMs))

    print("bench: history (100k URLs, 1000 searches)")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openkit-bench-hist-\(UUID().uuidString)")
    let directories = ProfileDirectories(root: tmp)
    try await OpenDataRoot.prepare(root: tmp)
    try directories.ensureProfileDirectories(dataDirectoryName: "Default")
    let history = HistoryStore(fileURL: directories.historyFileURL(dataDirectoryName: "Default"))
    var items: [(url: URL, title: String, time: Date)] = []
    items.reserveCapacity(100_000)
    let now = Date()
    for n in 0..<100_000 {
        items.append((URL(string: "https://site-\(n % 5000).example.com/article/\(n)")!, "Article number \(n) about topic \(n % 200)", now.addingTimeInterval(-Double(n))))
    }
    let insertStart = Date()
    // Insert in chunks so progress is visible and memory stays bounded.
    var offset = 0
    while offset < items.count {
        let chunk = Array(items[offset..<min(offset + 10_000, items.count)])
        await history.recordVisitsBulk(chunk)
        offset += chunk.count
    }
    let insertMs = Date().timeIntervalSince(insertStart) * 1000
    print(String(format: "  history insert 100k: %.1f ms (urls=%d)", insertMs, await history.urlCount()))
    var durations: [Double] = []
    for n in 0..<1000 {
        // Selective command-bar-style queries, like a user typing a few letters of a known page.
        let query = ["article 42", "topic 42", "site-123", "number 9999", "article 777"][n % 5]
        let t0 = Date()
        let matches = await history.search(query, limit: 20)
        durations.append(Date().timeIntervalSince(t0) * 1000)
        _ = matches
    }
    durations.sort()
    let p50 = durations[durations.count / 2]
    let p95 = durations[Int(Double(durations.count) * 0.95)]
    print(String(format: "  history search p50: %.3f ms  p95: %.3f ms", p50, p95))
    try? FileManager.default.removeItem(at: tmp)

    await runBulkBench()
}
