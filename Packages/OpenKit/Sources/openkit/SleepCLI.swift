import Foundation
import Darwin
import OpenModel
import OpenSleep
import OpenStore
import SQLite3

@MainActor
private final class SleepTrace {
    var calls: [(String, ItemID)] = []
    func record(_ kind: String, _ id: ItemID) { calls.append((kind, id)) }
    func ids(_ kind: String) -> [ItemID] { calls.filter { $0.0 == kind }.map(\.1) }
}

/// CLI-only mapping. OpenSleep has no dependency on SQLite or OpenStore.
@MainActor
private final class CLISleepStore: SleepHistoryStoring {
    let disk: SleepStore
    let trace: SleepTrace
    var errors: [String] = []
    let root: URL
    weak var model: BrowserModel?
    private var stores: [String: SleepStore] = [:]
    private var bootstrapError: Error?
    private let defaultDirectoryName: String
    private let dataRoot: OpenDataRoot.Preparation?
    init(root: URL, trace: SleepTrace, model: BrowserModel? = nil) {
        var preparedModel = model
        var preparationError: Error?
        var preparation: OpenDataRoot.Preparation?
        do {
            // Keep the preparation across every async store operation, including
            // the interval before its first SQLite connection opens.
            let snapshot = SnapshotStore(root: root)
            if model == nil { preparedModel = try snapshot.load() }
            preparation = try OpenDataRoot.prepare(root: root, model: preparedModel)
        } catch { preparationError = error }
        dataRoot = preparation
        self.root = root; self.trace = trace; self.model = preparedModel
        let name = preparedModel?.defaultProfile?.dataDirectoryName ?? "Default"
        defaultDirectoryName = name
        disk = SleepStore(fileURL: ProfileDirectories(root: root).sleepFileURL(dataDirectoryName: name))
        stores[name] = disk
        bootstrapError = preparationError
        if let preparationError { errors.append("SleepStore bootstrap failed: \(preparationError)") }
        disk.onError = { [weak self] message in self?.report(message) }
    }
    private func report(_ message: String) {
        errors.append(message)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    private func store(for tabID: ItemID) -> SleepStore {
        var parent = model?.parentByID[tabID]
        var name = model?.defaultProfile?.dataDirectoryName ?? defaultDirectoryName
        while let current = parent {
            switch current {
            case .favorites(let id): name = model?.profile(id: id)?.dataDirectoryName ?? name; parent = nil
            case .spacePinned(let id), .spaceToday(let id):
                name = model?.space(id: id).flatMap { model?.profile(id: $0.profileID)?.dataDirectoryName } ?? name
                parent = nil
            case .folder(let id), .splitPane(let id): parent = model?.parentByID[id]
            }
        }
        if let store = stores[name] { return store }
        let store = SleepStore(fileURL: ProfileDirectories(root: root).sleepFileURL(dataDirectoryName: name))
        store.onError = { [weak self] in self?.report($0) }
        stores[name] = store
        return store
    }
    func allTabIDs() async -> [ItemID] {
        var ids: [ItemID] = []
        for store in stores.values { ids += await store.allTabIDs() }
        return ids
    }
    func save(tabID: ItemID, envelope e: SleepHistoryEnvelope) async throws {
        trace.record("save-start", tabID)
        if let bootstrapError { throw bootstrapError }
        try await store(for: tabID).save(SleepHistoryRecord(tabID: tabID, container: e.container, currentIndex: e.currentIndex,
            entryCount: e.entryCount, currentURL: e.currentURL, currentTitle: e.currentTitle,
            faviconURL: e.faviconURL, hasPageState: e.hasPageState, containerVersion: e.containerVersion,
            chromiumTag: e.chromiumTag, capturedAt: e.capturedAt))
        trace.record("save", tabID)
    }
    var flushStarted = false
    var flushFinished = false
    func flush() async throws {
        flushStarted = true
        if let bootstrapError { throw bootstrapError }
        for store in stores.values { try await store.flush() }
        flushFinished = true
    }
    func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope? {
        guard bootstrapError == nil, let r = await store(for: tabID).load(tabID: tabID) else { return nil }
        return SleepHistoryEnvelope(container: r.container, currentIndex: r.currentIndex, entryCount: r.entryCount,
            currentURL: r.currentURL, currentTitle: r.currentTitle, faviconURL: r.faviconURL,
            hasPageState: r.hasPageState, containerVersion: r.containerVersion, chromiumTag: r.chromiumTag, capturedAt: r.capturedAt)
    }
    func deleteSleepHistory(tabID: ItemID) { store(for: tabID).delete(tabID: tabID) }
}

@MainActor
private final class SleepClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

/// Records the engine contract only. Payload bytes are synthetic, never Chromium pickles.
@MainActor
private final class SimulatedSleepEngine: SleepEngine {
    let model: BrowserModel
    let clock: SleepClock
    let trace: SleepTrace
    var unloaded: Set<ItemID> = []
    var discarded: Set<ItemID> = []
    var failCapture: Set<ItemID> = []
    var failFreeze: Set<ItemID> = []
    var failDiscard: Set<ItemID> = []
    var falseCompletion: Set<ItemID> = []
    var oversized: Set<ItemID> = []
    var stillOversized: Set<ItemID> = []
    var createdURLs: [ItemID: URL] = [:]
    var retryCount = 0
    var criticalCount = 0
    var pauseCreate = false
    var createContinuation: CheckedContinuation<Void, Never>?
    var pauseDiscard = false
    var continuation: CheckedContinuation<Void, Never>?

    init(model: BrowserModel, clock: SleepClock, trace: SleepTrace) {
        self.model = model; self.clock = clock; self.trace = trace
    }
    func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool {
        trace.record(history == nil ? "create-fresh" : "create-history", tabID)
        if pauseCreate { await withCheckedContinuation { createContinuation = $0 } }
        if let history {
            guard let decoded = try? SleepHistoryContainer(data: history.container),
                  decoded.currentIndex == history.currentIndex, decoded.entries.count == history.entryCount,
                  decoded.hasPageState == history.hasPageState, history.containerVersion == 1 else { return false }
        }
        createdURLs[tabID] = url
        discarded.remove(tabID)
        return true
    }
    func destroyContent(tabID: ItemID) { trace.record("destroy", tabID); discarded.remove(tabID) }
    func setVisible(tabID: ItemID, visible: Bool) {
        trace.record(visible ? "show" : "hide", tabID)
        if visible { discarded.remove(tabID) }
    }
    func freeze(tabID: ItemID) -> Bool { trace.record("freeze", tabID); return !failFreeze.contains(tabID) }
    func discard(tabID: ItemID) async -> Bool {
        trace.record("discard", tabID)
        if pauseDiscard { await withCheckedContinuation { continuation = $0 } }
        if failDiscard.contains(tabID) { return false }
        if !falseCompletion.contains(tabID) { discarded.insert(tabID) }
        return true
    }
    func wasDiscarded(tabID: ItemID) -> Bool { discarded.contains(tabID) }
    func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope? {
        trace.record("capture", tabID)
        guard !failCapture.contains(tabID), let tab = model.tab(id: tabID) else { return nil }
        let ordinary = [Data("opaque-A".utf8), Data("opaque-B".utf8), Data("opaque-C".utf8)]
        guard let packed = try? SleepHistoryContainer.capture(currentIndex: 1, defaultEntries: {
            oversized.contains(tabID) ? [Data(repeating: 1, count: 1_048_576), Data(repeating: 2, count: 1_048_576), ordinary[2]] : ordinary
        }, excludingPageState: {
            retryCount += 1
            return stillOversized.contains(tabID) ? [Data(repeating: 1, count: 1_048_576), Data(repeating: 2, count: 1_048_576), ordinary[2]] : ordinary
        }) else { return nil }
        return SleepHistoryEnvelope(container: packed.encoded(), currentIndex: 1, entryCount: 3,
            currentURL: tab.url, currentTitle: tab.title, faviconURL: URL(string: "https://example.invalid/favicon.ico"),
            hasPageState: packed.hasPageState, chromiumTag: "adapter-tag-overridden", capturedAt: clock.date)
    }
    func hasUnloadHandlers(tabID: ItemID) -> Bool { trace.record("unload-query", tabID); return unloaded.contains(tabID) }
    func handleCriticalPressure() { criticalCount += 1 }
}

/// The CLI plays the app role: window state is explicit, independent of selection.
@MainActor
private final class CLISleepVisibility: SleepVisibilityProviding {
    let model: BrowserModel
    var states: [WindowID: SleepVisibilitySnapshot.WindowState] = [:]
    var peek: Set<ItemID> = [], littleOpen: Set<ItemID> = []
    var splitPanes: Set<ItemID> = [], pictureInPicture: Set<ItemID> = []
    var reads = 0
    init(model: BrowserModel) { self.model = model }
    func sleepVisibility() -> SleepVisibilitySnapshot {
        reads += 1
        return SleepVisibilitySnapshot(windows: Dictionary(uniqueKeysWithValues: model.windows.map {
            ($0.id, states[$0.id] ?? .visible)
        }), peek: peek, littleOpen: littleOpen, splitPanes: splitPanes, pictureInPicture: pictureInPicture)
    }
}

@MainActor
private final class SleepScenario {
    let clock = SleepClock()
    let profile = Profile(name: "Open sleep fixture")
    let space: Space
    let window: BrowserWindowState
    let model: BrowserModel
    let trace = SleepTrace()
    let store: CLISleepStore
    let engine: SimulatedSleepEngine
    let controller: SleepController
    let visibility: CLISleepVisibility
    var logs: [String] = []

    init(root: URL, mode: SleepMode = .balanced) {
        profile.settings.sleepMode = mode
        space = Space(profileID: profile.id)
        window = BrowserWindowState(focusedSpaceID: space.id)
        model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        store = CLISleepStore(root: root, trace: trace, model: model)
        engine = SimulatedSleepEngine(model: model, clock: clock, trace: trace)
        visibility = CLISleepVisibility(model: model)
        controller = SleepController(model: model, engine: engine, store: store, visibility: visibility, chromiumTag: "156.0.8078.48", now: { [clock] in clock.date })
        controller.onLog = { [weak self] in self?.logs.append($0) }
    }
    func tab(age: TimeInterval = 0, pinned: Bool = false, url: String = "https://example.invalid/sleep") -> Tab {
        let tab = Tab(url: URL(string: url)!, title: "Open sleep fixture",
                      pinnedURL: pinned ? URL(string: "https://example.invalid/pin") : nil,
                      lastActiveAt: clock.date.addingTimeInterval(-age))
        if pinned { space.pinned.append(.tab(tab)) } else { space.today.append(.tab(tab)) }
        model.rebuildIndex(); controller.contentCreated(tabID: tab.id)
        return tab
    }
    func select(_ tab: Tab?) async {
        let prior = controller.visibleTabIDs()
        window.selectedNodeBySpace[space.id] = tab?.id
        for id in prior.subtracting(controller.visibleTabIDs()) { controller.tabBecameHidden(id) }
        if let tab { await controller.tabBecameVisible(tab.id) }
    }
}

private enum SleepCLIError: Error { case usage, directoryNotEmpty, missingSnapshot, checksFailed(Int) }

@MainActor
func runSleepDemo(args: [String]) async throws {
    guard args.count == 1 else { throw SleepCLIError.usage }
    let root = URL(fileURLWithPath: args[0])
    if FileManager.default.fileExists(atPath: root.path), !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty {
        throw SleepCLIError.directoryNotEmpty
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "OK" : "FAIL") \(name)")
        if ok { passed += 1 } else { failed += 1 }
    }
    func scenario(_ name: String, _ mode: SleepMode = .balanced) -> SleepScenario {
        SleepScenario(root: root.appendingPathComponent(name), mode: mode)
    }

    let timing = scenario("timing")
    let quiet = timing.tab(pinned: true)
    timing.clock.advance(29); await timing.controller.tick()
    check("hidden tab stays live before 30 s", quiet.live.sleepPhase == .live)
    timing.clock.advance(1); await timing.controller.tick()
    check("hidden tab freezes at 30 s", quiet.live.sleepPhase == .frozen)
    timing.clock.advance(269); await timing.controller.tick()
    check("balanced waits before 300 s", quiet.live.sleepPhase == .frozen)
    timing.clock.advance(1); await timing.controller.tick()
    let order = timing.trace.calls.filter { $0.1 == quiet.id && ["capture", "save", "discard"].contains($0.0) }.map(\.0)
    check("quiet pinned tab discards at 300 s; capture-save-discard order", quiet.live.sleepPhase == .sleeping && order == ["capture", "save", "discard"])
    check("sleep preserves navigation sidecars", quiet.live.canGoBack && quiet.live.canGoForward && !quiet.live.isLoading)
    let stored = await timing.store.sleepHistory(tabID: quiet.id)
    check("SleepStore equal-field round trip and controller tag stamp", stored == timing.engine.captureHistory(tabID: quiet.id).map { e in var e = e; e.chromiumTag = "156.0.8078.48"; return e })
    let reopened = CLISleepStore(root: root.appendingPathComponent("timing"), trace: SleepTrace())
    check("second SQLite connection reloads the same history", await reopened.sleepHistory(tabID: quiet.id) == stored)
    timing.clock.advance(86400 - 1); await timing.controller.tick()
    check("discarded content retained before 24 h", timing.controller.liveContent.contains(quiet.id))
    timing.clock.advance(1); await timing.controller.tick()
    check("sleeping content destroyed at 24 h", !timing.controller.liveContent.contains(quiet.id) && quiet.live.sleepPhase == .sleeping)
    await timing.select(quiet)
    check("destroyed wake restores history and both navigation directions", timing.trace.ids("create-history") == [quiet.id] && quiet.live.canGoBack && quiet.live.canGoForward)
    timing.controller.tabDidCommit(quiet.id)
    check("wake latency logged at first commit", timing.logs.contains { $0.contains("sleep-wake destroyed") })
    await timing.select(nil)
    await timing.controller.debugSleepNow(tabID: quiet.id)
    check("recent commit protects debug sleep", quiet.live.sleepPhase == .live)

    for mode in SleepMode.allCases {
        let s = scenario("mode-\(mode.rawValue)", mode), tab = s.tab()
        s.clock.advance(30); await s.controller.tick()
        if let delay = mode.discardDelay {
            s.clock.advance(delay - 31); await s.controller.tick()
            let before = tab.live.sleepPhase == .frozen
            s.clock.advance(1); await s.controller.tick()
            check("\(mode.rawValue) delay boundary", before && tab.live.sleepPhase == .sleeping)
        } else {
            s.clock.advance(48 * 3600); await s.controller.tick()
            check("Never stays live past 48 hours", tab.live.sleepPhase == .live)
        }
    }

    let gates = scenario("gates")
    let visible = gates.tab(age: 1000), audio = gates.tab(age: 1000), capture = gates.tab(age: 1000)
    let pip = gates.tab(age: 1000), devtools = gates.tab(age: 1000), download = gates.tab(age: 1000), load = gates.tab(age: 1000)
    await gates.select(visible)
    audio.live.isAudible = true; capture.live.isCapturing = true; pip.live.isCapturing = true
    devtools.live.devToolsOpen = true; gates.controller.downloading.insert(download.id); load.live.isLoading = true
    await gates.controller.tick()
    for (name, tab) in [("visible", visible), ("audible", audio), ("capturing", capture), ("PiP", pip), ("DevTools", devtools), ("downloading", download), ("loading", load)] {
        await gates.controller.debugSleepNow(tabID: tab.id)
        check("\(name) blocks freeze and debug discard", tab.live.sleepPhase == .live && !gates.trace.ids("discard").contains(tab.id))
    }
    audio.live.isAudible = false; load.live.isLoading = false
    await gates.controller.tick(); gates.clock.advance(9); await gates.controller.tick()
    check("recent loading completion protects for 10 s", load.live.sleepPhase == .live)
    gates.clock.advance(1); await gates.controller.tick()
    check("loading protection expires at 10 s", load.live.sleepPhase == .frozen)
    gates.clock.advance(49); await gates.controller.tick()
    check("audio remains protected for full 60 s after stop", audio.live.sleepPhase == .live)
    gates.clock.advance(1); await gates.controller.tick(); await gates.controller.tick()
    check("audio protection expires then permits discard", audio.live.sleepPhase == .sleeping)

    let proxies = scenario("proxies")
    let unload = proxies.tab(age: 400), form = proxies.tab(age: 400)
    proxies.engine.unloaded.insert(unload.id); form.live.lastFormInteractionAt = proxies.clock.date
    await proxies.controller.tick(); await proxies.controller.tick()
    check("unload and form block discard but allow freeze", unload.live.sleepPhase == .frozen && form.live.sleepPhase == .frozen)
    proxies.clock.advance(300); await proxies.controller.tick()
    check("form protection expires at 300 s", form.live.sleepPhase == .sleeping)
    proxies.engine.unloaded.remove(unload.id); await proxies.controller.tick()
    check("unload cache refresh allows later discard", unload.live.sleepPhase == .sleeping)
    await proxies.select(unload)
    check("discard-in-place wake keeps shell until first commit", unload.live.sleepPhase == .sleeping && proxies.trace.ids("create-history").isEmpty)
    proxies.controller.tabDidCommit(unload.id)
    check("discard wake becomes live on commit", unload.live.sleepPhase == .live)

    let pressure = scenario("pressure", .conservative)
    let newest = pressure.tab(age: 40), oldest = pressure.tab(age: 80), protected = pressure.tab(age: 100)
    let pressureAudio = pressure.tab(age: 100), pressureCapture = pressure.tab(age: 100)
    await pressure.controller.tick()
    await pressure.select(protected); pressureAudio.live.isAudible = true; pressureCapture.live.isCapturing = true
    pressure.trace.calls.removeAll()
    await pressure.controller.handleMemoryPressure(.warning)
    check("warning pressure overrides delay; oldest first; gates honored", pressure.trace.ids("discard") == [oldest.id, newest.id])
    await pressure.controller.handleMemoryPressure(.critical)
    check("critical pressure destroys sleeping shells and invokes engine hook", pressure.trace.ids("destroy") == [oldest.id, newest.id] && pressure.engine.criticalCount == 1 && pressure.controller.liveContent.contains(protected.id))
    pressure.controller.start(); pressure.controller.start(); pressure.controller.stop(); pressure.controller.stop()
    check("timer and OS source start/stop completes", true)

    let ownership = scenario("ownership", .off)
    let offTab = ownership.tab(age: 1000)
    let other = Profile(name: "Other fixture", settings: ProfileSettings(sleepMode: .aggressive))
    let favorite = Tab(url: URL(string: "https://example.invalid/favorite")!, lastActiveAt: ownership.clock.date.addingTimeInterval(-1000))
    let nested = Tab(url: URL(string: "https://example.invalid/nested")!, lastActiveAt: ownership.clock.date.addingTimeInterval(-1000))
    other.favorites = [favorite]
    let otherSpace = Space(profileID: other.id, pinned: [.folder(Folder(children: [.tab(nested)]))])
    ownership.model.profiles.append(other); ownership.model.spaces.append(otherSpace); ownership.model.rebuildIndex()
    ownership.controller.contentCreated(tabID: favorite.id); ownership.controller.contentCreated(tabID: nested.id)
    await ownership.controller.tick(); await ownership.controller.tick()
    check("per-profile mode lookup covers favorites and nested pinned tabs", offTab.live.sleepPhase == .live && favorite.live.sleepPhase == .sleeping && nested.live.sleepPhase == .sleeping)
    other.settings.sleepMode = .off
    await ownership.controller.tick()
    check("switching off leaves already sleeping tabs asleep", favorite.live.sleepPhase == .sleeping && nested.live.sleepPhase == .sleeping)
    await ownership.select(offTab)
    ownership.controller.tabDidCommit(offTab.id)
    check("Never keeps retained content live on selection", offTab.live.sleepPhase == .live)
    let secondWindow = BrowserWindowState(focusedSpaceID: ownership.space.id, selectedNodeBySpace: [ownership.space.id: offTab.id])
    ownership.model.windows.append(secondWindow)
    await ownership.select(nil)
    check("tab visible in another window is never hidden", ownership.controller.visibleTabIDs().contains(offTab.id) && !ownership.trace.ids("hide").contains(offTab.id))

    let failures = scenario("failures")
    let noCapture = failures.tab(age: 400), noDiscard = failures.tab(age: 400), falseCompletion = failures.tab(age: 400), noFreeze = failures.tab(age: 400)
    failures.engine.failCapture.insert(noCapture.id); failures.engine.failDiscard.insert(noDiscard.id)
    failures.engine.falseCompletion.insert(falseCompletion.id); failures.engine.failFreeze.insert(noFreeze.id)
    await failures.controller.tick(); await failures.controller.tick()
    check("capture failure keeps frozen and logs", noCapture.live.sleepPhase == .frozen && failures.logs.contains { $0.contains("sleep-capture-failed") })
    check("discard failure and false completion keep frozen; freeze failure stays live", noDiscard.live.sleepPhase == .frozen && falseCompletion.live.sleepPhase == .frozen && noFreeze.live.sleepPhase == .live)

    let cap = scenario("cap")
    let retry = cap.tab(age: 400), tooBig = cap.tab(age: 400)
    cap.engine.oversized = [retry.id, tooBig.id]; cap.engine.stillOversized = [tooBig.id]
    await cap.controller.tick(); await cap.controller.tick()
    let retryBlob = await cap.store.sleepHistory(tabID: retry.id)
    check("2 MiB capture retries EXCLUDE_PAGE_STATE without truncation", retry.live.sleepPhase == .sleeping && retryBlob?.hasPageState == false && cap.engine.retryCount == 2)
    check("still-over-cap capture keeps tab frozen", tooBig.live.sleepPhase == .frozen)
    let maxPacked = try SleepHistoryContainer(entries: [Data(repeating: 7, count: SleepHistoryContainer.maximumBytes - 24)], currentIndex: 0, hasPageState: true)
    let capID = ItemID()
    let exact = SleepHistoryEnvelope(container: maxPacked.encoded(), currentIndex: 0, entryCount: 1,
        currentURL: URL(string: "https://example.invalid/cap")!, currentTitle: "Cap", hasPageState: true,
        chromiumTag: "156.0.8078.48", capturedAt: cap.clock.date)
    try await cap.store.save(tabID: capID, envelope: exact)
    check("exact 2 MiB boundary stored intact", await cap.store.sleepHistory(tabID: capID) == exact)
    var over = exact; over.container.append(0)
    do { try await cap.store.save(tabID: capID, envelope: over) } catch {}
    let retained = await cap.store.sleepHistory(tabID: capID)
    check("over-cap write rejected and logged; old record retained", cap.store.errors.count == 1 && retained == exact)
    let bytes = await cap.store.disk.totalBytes()
    let storedIDs = Set(await cap.store.allTabIDs())
    check("totalBytes and allTabIDs report stored blobs", bytes == exact.container.count + (retryBlob?.container.count ?? 0) && storedIDs == [capID, retry.id])
    cap.store.disk.delete(tabIDs: [capID, retry.id]); cap.store.disk.flushQueue()
    check("batch delete works", await cap.store.allTabIDs().isEmpty)
    try await cap.store.save(tabID: capID, envelope: exact); cap.store.deleteSleepHistory(tabID: capID)
    check("single delete and missing load work", await cap.store.sleepHistory(tabID: capID) == nil)

    let corrupt = scenario("corrupt")
    let bad = corrupt.tab(age: 400)
    await corrupt.controller.debugSleepNow(tabID: bad.id)
    var badBlob = (await corrupt.store.sleepHistory(tabID: bad.id))!
    badBlob.container[0] ^= 1
    try await corrupt.store.save(tabID: bad.id, envelope: badBlob)
    bad.url = URL(string: "https://example.invalid/stale-snapshot")!
    await corrupt.controller.handleMemoryPressure(.critical); await corrupt.select(bad)
    check("corrupt SQLite blob wake falls back to sidecar URL with Back disabled", corrupt.trace.ids("create-fresh") == [bad.id] && corrupt.engine.createdURLs[bad.id] == badBlob.currentURL && !bad.live.canGoBack && !bad.live.canGoForward && corrupt.logs.contains { $0.contains("sleep-restore-fallback") })

    let valid = try SleepHistoryContainer(entries: [Data([1]), Data([2])], currentIndex: 1, hasPageState: true).encoded()
    var malformed: [Data] = []
    for offset in [0, 4, 8, 12, 16, 17, 18, 19, 20] {
        var blob = valid; blob[offset] = 0xff; malformed.append(blob)
    }
    malformed += [Data(valid.prefix(19)), Data(valid.dropLast()), valid + Data([0])]
    var zeroLength = valid; zeroLength[20] = 0; malformed.append(zeroLength)
    check("OPNH rejects malformed header, counts, flags, reserved bytes, lengths, truncation and trailing bytes", malformed.allSatisfy { (try? SleepHistoryContainer(data: $0)) == nil })
    let decoded = try SleepHistoryContainer(data: valid)
    check("OPNH little-endian round trip", decoded.currentIndex == 1 && decoded.entries == [Data([1]), Data([2])] && decoded.encoded() == valid)

    let oldRoot = root.appendingPathComponent("schema1")
    let oldStore = SnapshotStore(root: oldRoot)
    try FileManager.default.createDirectory(at: oldStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Bundle.module.url(forResource: "sleep-schema1", withExtension: "json")!, to: oldStore.fileURL)
    let oldModel = try oldStore.load()!
    let defaultMode = oldModel.profiles.first?.settings.sleepMode == .balanced
    try oldStore.saveNow(model: oldModel)
    let reloaded = try oldStore.load()!
    let schema = try oldStore.loadData()?.schemaVersion
    check("pre-change schema-1 fixture defaults balanced; roundtrip OK", defaultMode && SnapshotMapper.structurallyEqual(oldModel, reloaded) && schema == 1)
    check("pre-change snapshot without keepAliveSites defaults to an empty list", oldModel.profiles.allSatisfy { $0.settings.keepAliveSites.isEmpty })
    for mode in SleepMode.allCases {
        oldModel.profiles[0].settings.sleepMode = mode; try oldStore.saveNow(model: oldModel)
        check("snapshot persists \(mode.rawValue) mode", try oldStore.load()?.profiles.first?.settings.sleepMode == mode)
    }

    let splitScenario = scenario("split")
    let left = splitScenario.tab(age: 400), right = splitScenario.tab(age: 400)
    let split = splitScenario.model.makeSplit(tabIDs: [left.id, right.id])!
    splitScenario.window.selectedNodeBySpace[splitScenario.space.id] = split.id
    await splitScenario.controller.tick()
    check("selected split protects every pane", splitScenario.controller.visibleTabIDs() == [left.id, right.id] && left.live.sleepPhase == .live && right.live.sleepPhase == .live)
    try await splitScenario.controller.captureAllForQuit()
    check("quit capture includes both split panes", Set(await splitScenario.store.allTabIDs()) == [left.id, right.id])
    splitScenario.model.closeTab(id: left.id); splitScenario.controller.tabClosed(left.id)
    check("archive close retains sleep row", await splitScenario.store.sleepHistory(tabID: left.id) != nil)

    let race = scenario("race")
    let racing = race.tab(age: 400)
    race.engine.pauseDiscard = true
    let pending = Task { await race.controller.debugSleepNow(tabID: racing.id) }
    while race.engine.continuation == nil { await Task.yield() }
    await race.select(racing)
    race.engine.continuation?.resume(); race.engine.continuation = nil
    await pending.value
    check("selection during async discard recovers visible tab", racing.live.sleepPhase == .live && race.trace.ids("show").count == 2)

    // Use an invalid root to exercise error surfacing without crashing or mocking SQLite.
    let invalidRoot = root.appendingPathComponent("not-a-directory")
    try Data([0]).write(to: invalidRoot)
    let invalidStore = CLISleepStore(root: invalidRoot, trace: SleepTrace())
    do { try await invalidStore.save(tabID: ItemID(), envelope: exact) } catch {}
    _ = await invalidStore.allTabIDs()
    await Task.yield()
    check("SQLite/open failures surface onError and keep CLI running", !invalidStore.errors.isEmpty)

    try await runSleepReviewScenarios(root: root, check: check)
    try await runKeepAliveScenarios(root: root.appendingPathComponent("keep-alive"), check: check)
    try await runAppWiringScenarios(root: root.appendingPathComponent("app-wiring"), check: check)
    try await runSleepControllerBench(root: root.appendingPathComponent("bench"), check: check)
    print("sleep-demo \(failed == 0 ? "OK" : "FAIL"): \(passed) checks passed, \(failed) failed")
    if failed != 0 { throw SleepCLIError.checksFailed(failed) }
}

/// App-shell Step G inputs (S6): the notification gate (page-platform §4.5.6), Battery Saver
/// (settings-library Tab Sleeping group) and the parked pass loop (no idle timer).
@MainActor
private func runAppWiringScenarios(root: URL, check: (String, Bool) -> Void) async throws {
    for mode in SleepMode.allCases {
        let s = SleepScenario(root: root.appendingPathComponent("notify-\(mode.rawValue)"), mode: mode)
        let tab = s.tab(); tab.live.notificationsAllowed = true
        s.clock.advance(max(30, mode.discardDelay ?? 0) + 60); await s.controller.tick(); await s.controller.tick()
        check("notifications allowed: stays live past the \(mode.rawValue) discard time", tab.live.sleepPhase == .live
              && !s.trace.ids("freeze").contains(tab.id) && !s.trace.ids("discard").contains(tab.id))
    }
    let n = SleepScenario(root: root.appendingPathComponent("notify"))
    let notified = n.tab(age: 1000); notified.live.notificationsAllowed = true
    let gateOrder = n.controller.blockingGate(tabID: notified.id, forDiscard: true)
    await n.controller.debugSleepNow(tabID: notified.id)
    check("notifications gate refuses debug sleep with reason notifications", gateOrder == .notifications && notified.live.sleepPhase == .live)
    check("notifications gate comes right after keepAlive", Array(SleepPolicy.Gate.allCases.prefix(3)) == [.visible, .keepAlive, .notifications])
    await n.controller.handleMemoryPressure(.warning)
    check("warning pressure keeps a notification tab live", notified.live.sleepPhase == .live)
    notified.live.notificationsAllowed = false
    await n.controller.tick()
    check("Block lets the tab freeze on the next pass", notified.live.sleepPhase == .frozen)
    let critical = n.tab(age: 1000); critical.live.notificationsAllowed = true
    await n.controller.handleMemoryPressure(.critical)
    check("critical pressure may still freeze and discard a notification tab", critical.live.sleepPhase == .sleeping
          && n.trace.ids("freeze").contains(critical.id) && n.trace.ids("discard").contains(critical.id))

    let expected: [SleepMode: SleepMode] = [.balanced: .aggressive, .conservative: .conservative, .aggressive: .aggressive, .off: .off]
    for mode in SleepMode.allCases {
        let s = SleepScenario(root: root.appendingPathComponent("battery-\(mode.rawValue)"), mode: mode)
        s.controller.lowPowerMode = true
        let tab = s.tab()
        s.clock.advance(30); await s.controller.tick()
        s.clock.advance(90); await s.controller.tick()
        let atTwoMinutes = tab.live.sleepPhase
        check("Battery Saver maps \(mode.rawValue) to \(expected[mode]!.rawValue)", s.controller.effectiveMode(mode) == expected[mode]
              && (mode == .off ? atTwoMinutes == .live : expected[mode] == .aggressive ? atTwoMinutes == .sleeping : atTwoMinutes == .frozen))
    }
    let battery = SleepScenario(root: root.appendingPathComponent("battery-off"))
    let plugged = battery.tab()
    battery.controller.lowPowerMode = true; battery.controller.lowPowerMode = false
    battery.clock.advance(30); await battery.controller.tick()
    battery.clock.advance(90); await battery.controller.tick()
    let beforeFive = plugged.live.sleepPhase
    battery.clock.advance(180); await battery.controller.tick()
    check("Battery Saver off: Automatic waits the balanced 300 s again", beforeFive == .frozen && plugged.live.sleepPhase == .sleeping)

    let audio = SleepScenario(root: root.appendingPathComponent("audio-event"))
    let sound = audio.tab(age: 1000); sound.live.isAudible = true
    await audio.controller.tick()
    audio.clock.advance(10); sound.live.isAudible = false; audio.controller.tabAudioChanged(sound.id)
    audio.clock.advance(59); await audio.controller.tick()
    let inGrace = sound.live.sleepPhase
    audio.clock.advance(2); await audio.controller.tick()
    check("audio stop event between passes: the 60 s grace starts at the stop, not at the next sample",
          inGrace == .live && sound.live.sleepPhase == .frozen)

    let idle = SleepScenario(root: root.appendingPathComponent("idle"))
    let shown = idle.tab(); await idle.select(shown)
    check("parked: no pass due with only the visible tab", idle.controller.nextPassDelay() == nil)
    idle.controller.setNeedsPass()
    check("setNeedsPass before start schedules nothing", !idle.controller.isPassScheduled)
    let quiet = idle.tab()
    check("a hidden live quiet tab needs the 5 s pass", idle.controller.nextPassDelay() == SleepController.passInterval)
    let keep = idle.tab(url: "https://mail.google.com/mail/u/0"), loud = idle.tab(), notify = idle.tab()
    loud.live.isAudible = true; notify.live.notificationsAllowed = true
    idle.model.closeTab(id: quiet.id); idle.controller.tabClosed(quiet.id)
    check("keep-alive, audible and notification tabs wait for their event (parked)", idle.controller.nextPassDelay() == nil)
    loud.live.isAudible = false
    check("audio stop needs a pass for the 60 s grace", idle.controller.nextPassDelay() == SleepController.passInterval)
    idle.clock.advance(400); await idle.controller.tick(); await idle.controller.tick()
    let destroyDue = idle.controller.nextPassDelay()
    check("only sleeping tabs left: one deadline at their 24 h destroy, no 5 s cadence", loud.live.sleepPhase == .sleeping && keep.live.sleepPhase == .live
          && destroyDue.map { abs($0 - (86400 - 0)) < 1 } == true)
    let off = SleepScenario(root: root.appendingPathComponent("idle-off"), mode: .off)
    let offTab = off.tab(age: 100); await off.controller.tick()
    check("off mode: a live tab parks the loop", offTab.live.sleepPhase == .live && off.controller.nextPassDelay() == nil)
    idle.controller.start()
    check("start schedules one pass", idle.controller.isPassScheduled && (idle.controller.scheduledPassDelay ?? 99) <= SleepController.passInterval)
    idle.controller.stop()
    check("stop leaves no scheduled pass", !idle.controller.isPassScheduled)
}

@MainActor
private func runKeepAliveScenarios(root: URL, check: (String, Bool) -> Void) async throws {
    let s = SleepScenario(root: root)
    // Independent service URLs exercise the shipped resource through the controller.
    let liveURLs = [
        "https://twitter.com/", "https://x.com/", "https://app.slack.com/client/team",
        "https://mail.google.com/mail/u/0", "https://calendar.google.com/calendar/u/0",
        "https://notion.so/", "https://www.notion.so/", "https://dev.notion.so/", "https://stg.notion.so/",
        "https://app.notion.com/", "https://dropbox.com/", "https://aws.amazon.com/",
        "https://open.spotify.com/", "https://linear.app/", "https://instagram.com/",
        "https://messenger.com/", "https://facebook.com/", "https://web.whatsapp.com/",
        "https://sentry.io/", "https://figma.com/file/design", "https://figma.com/file/",
        "https://docs.google.com/document/d/doc", "https://docs.google.com/presentation/d/deck",
        "https://docs.google.com/spreadsheets/d/sheet", "https://outlook.live.com/mail/0",
        "https://outlook.live.com/calendar/0", "http://www.mail.google.co.uk:8080/mail/u/0",
        "https://www.app.slack.net/client/team", "https://www.twitter.net/",
    ]
    let live = liveURLs.map { s.tab(url: $0) }
    let normalURLs = [
        "https://mail.google.com/", "https://mail.google.com/search?next=/mail",
        "https://google.com/mail", "https://app.slack.com/other", "https://calendar.google.com/other",
        "https://figma.com/file", "https://figma.com/files/design", "https://docs.google.com/forms",
        "https://outlook.live.com/other", "https://notion.net/", "https://notion.com/",
        "https://linear.com/", "https://sentry.net/", "https://x.net/",
        "https://evilmail.google.com/mail", "https://mail.google/mail", "https://mail.google.com/Mail",
        "https://example.invalid/mail.google.com/mail", "file://mail.google.com/mail",
    ]
    let normal = normalURLs.map { s.tab(url: $0) }
    var settings = s.profile.settings
    settings.keepAliveSites = ["notify.example.invalid/inbox", "", "https://bad.invalid", "*.invalid", "bad..invalid"]
    s.model.updateProfileSettings(id: s.profile.id, settings: settings)
    let userTab = s.tab(url: "https://team.notify.example.invalid/inbox/messages")
    let userOutside = s.tab(url: "https://notify.example.invalid/other")
    // Same host and path in another profile must use that profile's empty list.
    let other = Profile(name: "Keep-alive isolation", dataDirectoryName: "Keep-alive-isolation")
    let otherTab = Tab(url: userTab.url, lastActiveAt: s.clock.date)
    other.favorites = [otherTab]
    s.model.profiles.append(other); s.model.rebuildIndex(); s.controller.contentCreated(tabID: otherTab.id)
    for seconds in [0, 30, 300, 86700, 172800] {
        s.clock.date = Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))
        await s.controller.tick()
        if seconds == 30 {
            check("outside-scope URLs and user path exclusion freeze normally", (normal + [userOutside, otherTab]).allSatisfy { $0.live.sleepPhase == .frozen })
        }
    }
    for (url, tab) in zip(liveURLs, live) {
        check("keep-alive stays live through 48 h: \(url)", tab.live.sleepPhase == .live && s.controller.liveContent.contains(tab.id)
              && !s.trace.ids("freeze").contains(tab.id) && !s.trace.ids("discard").contains(tab.id))
    }
    check("outside-scope URLs sleep and destroy normally", normal.allSatisfy { $0.live.sleepPhase == .sleeping && !s.controller.liveContent.contains($0.id) })
    let snapshot = SnapshotStore(root: root.appendingPathComponent("profile-snapshot"))
    try snapshot.saveNow(model: s.model)
    let reloaded = try snapshot.load()
    check("snapshot-persisted per-profile user rule stays live for 48 h", userTab.live.sleepPhase == .live
          && reloaded?.profile(id: s.profile.id)?.settings.keepAliveSites == settings.keepAliveSites
          && reloaded?.profile(id: other.id)?.settings.keepAliveSites == [])
    check("user rules preserve path scope and profile isolation", userOutside.live.sleepPhase == .sleeping && otherTab.live.sleepPhase == .sleeping)
    for tab in live + [userTab] { await s.controller.debugSleepNow(tabID: tab.id) }
    await s.controller.handleMemoryPressure(.warning); await s.controller.handleMemoryPressure(.critical)
    check("keep-alive blocks debug discard and both pressure levels", (live + [userTab]).allSatisfy { $0.live.sleepPhase == .live && !s.trace.ids("freeze").contains($0.id) && !s.trace.ids("discard").contains($0.id) })

    let navigated = live[3]
    navigated.url = URL(string: "https://example.invalid/after-mail")!
    s.controller.tabDidCommit(navigated.id)
    // Reset the normal hide clock through the same show/hide hooks used by the app.
    await s.select(navigated); await s.select(nil)
    s.clock.advance(29); await s.controller.tick()
    check("leaving Gmail stays live before the normal freeze delay", navigated.live.sleepPhase == .live)
    s.clock.advance(1); await s.controller.tick()
    check("leaving Gmail freezes at the normal 30 s delay", navigated.live.sleepPhase == .frozen)
    s.clock.advance(269); await s.controller.tick()
    check("leaving Gmail waits for the normal discard delay", navigated.live.sleepPhase == .frozen)
    s.clock.advance(1); await s.controller.tick()
    check("leaving Gmail discards at the normal 300 s delay", navigated.live.sleepPhase == .sleeping)

    settings.keepAliveSites = []
    s.model.updateProfileSettings(id: s.profile.id, settings: settings)
    await s.controller.tick(); await s.controller.tick()
    check("removing a user rule invalidates the cached match", userTab.live.sleepPhase == .sleeping)
    let added = s.tab(age: 400, url: "https://new.example.invalid/chat")
    await s.controller.tick()
    settings.keepAliveSites = ["new.example.invalid/chat"]
    s.model.updateProfileSettings(id: s.profile.id, settings: settings)
    await s.controller.tick(); await s.controller.handleMemoryPressure(.warning)
    check("adding a user rule protects an already frozen tab from discard", added.live.sleepPhase == .frozen && !s.trace.ids("discard").contains(added.id))

    let liveAdded = s.tab(url: "https://live.example.invalid/chat")
    await s.controller.tick()
    let revision = s.model.treeRevision
    settings.keepAliveSites.append("live.example.invalid/chat")
    let updated = s.model.updateProfileSettings(id: s.profile.id, settings: settings)
    s.clock.advance(30); await s.controller.tick()
    s.clock.advance(48 * 3600 - 30); await s.controller.tick()
    await s.controller.debugSleepNow(tabID: liveAdded.id)
    await s.controller.handleMemoryPressure(.warning)
    check("model settings edit keeps a live tab awake without a restart or tree change", updated
          && s.model.treeRevision == revision && liveAdded.live.sleepPhase == .live
          && !s.trace.ids("freeze").contains(liveAdded.id) && !s.trace.ids("discard").contains(liveAdded.id))

    let race = SleepScenario(root: root.appendingPathComponent("navigation-race"))
    let racing = race.tab(age: 400)
    race.engine.pauseDiscard = true
    let pending = Task { await race.controller.debugSleepNow(tabID: racing.id) }
    while race.engine.continuation == nil { await Task.yield() }
    racing.url = URL(string: "https://mail.google.com/mail/u/0")!
    race.controller.tabDidCommit(racing.id)
    race.engine.continuation?.resume(); race.engine.continuation = nil
    await pending.value
    check("navigation to Gmail during async discard recovers background content", racing.live.sleepPhase == .live
          && !race.engine.discarded.contains(racing.id) && race.trace.ids("show") == [racing.id]
          && race.trace.ids("hide") == [racing.id])
}

@MainActor
private func runSleepReviewScenarios(root: URL, check: (String, Bool) -> Void) async throws {
    func scenario(_ name: String) -> SleepScenario { SleepScenario(root: root.appendingPathComponent("review-" + name)) }
    let read = scenario("hide-clock"), tab = read.tab()
    await read.select(tab); read.clock.advance(600); await read.controller.tick()
    await read.select(nil)
    let hidden = read.clock.date
    await read.controller.tick(); read.clock.advance(29); await read.controller.tick()
    check("10-minute read then hide stays live through hide+29 s", tab.live.sleepPhase == .live && read.controller.hiddenAt[tab.id] == hidden)
    read.clock.advance(1); await read.controller.tick()
    check("10-minute read freezes at hide+30 s", tab.live.sleepPhase == .frozen)
    read.clock.advance(269); await read.controller.tick()
    let before = tab.live.sleepPhase == .frozen
    read.clock.advance(1); await read.controller.tick()
    check("10-minute read discards at hide+300 s", before && tab.live.sleepPhase == .sleeping)
    await read.select(tab)
    check("show clears hiddenAt", read.controller.hiddenAt[tab.id] == nil)

    let splitRead = scenario("split-clock")
    let left = splitRead.tab(age: 900), right = splitRead.tab(age: 900)
    let split = splitRead.model.makeSplit(tabIDs: [left.id, right.id])!
    splitRead.model.selectNode(windowID: splitRead.window.id, spaceID: splitRead.space.id, nodeID: split.id)
    check("model split selection stamps every pane", left.lastActiveAt == right.lastActiveAt && left.lastActiveAt > splitRead.clock.date)
    for id in [left.id, right.id] { await splitRead.controller.tabBecameVisible(id) }
    splitRead.clock.advance(600)
    splitRead.model.focusSplitPane(splitID: split.id, tabID: right.id)
    check("model split focus stamps every visible pane", split.focusedPaneID == right.id && left.lastActiveAt == right.lastActiveAt && left.lastActiveAt > splitRead.clock.date)
    for id in [left.id, right.id] { await splitRead.controller.tabBecameVisible(id) }
    await splitRead.select(nil); await splitRead.controller.tick()
    let panesWait = left.live.sleepPhase == .live && right.live.sleepPhase == .live
    splitRead.clock.advance(30); await splitRead.controller.tick()
    check("both split panes freeze from hide time after a long read", panesWait && left.live.sleepPhase == .frozen && right.live.sleepPhase == .frozen)

    let critical = scenario("one-phase"), frozen = critical.tab(age: 400), live = critical.tab(age: 400)
    frozen.live.sleepPhase = .frozen
    await critical.controller.handleMemoryPressure(.critical)
    check("critical pressure discards frozen tab but keeps its shell for this pass", frozen.live.sleepPhase == .sleeping && critical.controller.liveContent.contains(frozen.id) && critical.trace.ids("destroy").isEmpty)
    check("critical pressure never skips live directly to sleeping", live.live.sleepPhase == .live)
    await critical.controller.handleMemoryPressure(.critical)
    check("next critical pass destroys only a tab already sleeping", critical.trace.ids("destroy") == [frozen.id])

    let restoreRace = scenario("pressure-restore-race")
    let priorSleep = restoreRace.tab(age: 400), newSleep = restoreRace.tab(age: 400), creating = restoreRace.tab(age: 400)
    await restoreRace.controller.debugSleepNow(tabID: priorSleep.id)
    newSleep.live.sleepPhase = .frozen
    restoreRace.controller.tabClosed(creating.id)
    restoreRace.window.selectedNodeBySpace[restoreRace.space.id] = creating.id
    restoreRace.engine.pauseCreate = true
    let restoring = Task { await restoreRace.controller.handleMemoryPressure(.critical) }
    while restoreRace.engine.createContinuation == nil { await Task.yield() }
    await restoreRace.controller.debugSleepNow(tabID: newSleep.id)
    await restoreRace.select(priorSleep)
    restoreRace.engine.createContinuation?.resume(); restoreRace.engine.createContinuation = nil
    await restoring.value
    check("critical pass rechecks visibility after async restore and preserves start-phase boundary", restoreRace.controller.liveContent.contains(priorSleep.id) && restoreRace.controller.liveContent.contains(newSleep.id) && !restoreRace.trace.ids("destroy").contains(priorSleep.id) && !restoreRace.trace.ids("destroy").contains(newSleep.id))

    for state in [SleepVisibilitySnapshot.WindowState.minimized, .occluded, .closed] {
        let s = scenario("window-\(state)"), selected = s.tab(age: 1000)
        await s.select(selected); s.clock.advance(600)
        s.visibility.states[s.window.id] = state
        await s.controller.tick()
        let hiddenNow = s.controller.hiddenAt[selected.id] == s.clock.date && selected.live.sleepPhase == .live
        s.clock.advance(30); await s.controller.tick()
        let froze = selected.live.sleepPhase == .frozen
        s.clock.advance(270); await s.controller.tick()
        check("\(state) selected window tab uses hide timers then sleeps", hiddenNow && froze && selected.live.sleepPhase == .sleeping)
    }
    let removed = scenario("removed-window"), removedTab = removed.tab(age: 1000)
    await removed.select(removedTab); removed.model.windows = []
    await removed.controller.tick(); removed.clock.advance(30); await removed.controller.tick()
    removed.clock.advance(270); await removed.controller.tick()
    check("removed window's selected tab becomes eligible", removedTab.live.sleepPhase == .sleeping)

    let surfaces = scenario("surfaces")
    let peek = surfaces.tab(age: 1000), little = surfaces.tab(age: 1000)
    let pip = surfaces.tab(age: 1000), pane = surfaces.tab(age: 1000)
    surfaces.visibility.states[surfaces.window.id] = .minimized
    surfaces.visibility.peek = [peek.id]; surfaces.visibility.littleOpen = [little.id]
    surfaces.visibility.pictureInPicture = [pip.id]; surfaces.visibility.splitPanes = [pane.id]
    await surfaces.controller.tick(); surfaces.clock.advance(48 * 3600)
    await surfaces.controller.tick(); await surfaces.controller.handleMemoryPressure(.critical)
    for (name, protected) in [("Peek", peek), ("Little Open", little), ("PiP", pip), ("explicit split pane", pane)] {
        await surfaces.controller.debugSleepNow(tabID: protected.id)
        check("\(name) remains live under time, critical pressure and debug sleep", protected.live.sleepPhase == .live && !surfaces.trace.ids("freeze").contains(protected.id))
    }
    surfaces.visibility.peek = []; await surfaces.controller.tick()
    surfaces.clock.advance(29); await surfaces.controller.tick()
    let peekWait = peek.live.sleepPhase == .live
    surfaces.clock.advance(1); await surfaces.controller.tick()
    check("closing Peek starts a fresh 30 s hide timer", peekWait && peek.live.sleepPhase == .frozen)

    let queries = scenario("unload-budget")
    let tabs = (0..<67).map { _ in queries.tab(age: 400) }
    queries.engine.unloaded.insert(tabs[0].id)
    var bounded = true, unknownProtected = true
    for _ in 0..<3 {
        let count = queries.trace.ids("unload-query").count
        await queries.controller.tick()
        bounded = bounded && queries.trace.ids("unload-query").count - count <= queries.controller.maximumUnloadQueriesPerPass
        let known = Set(queries.trace.ids("unload-query"))
        unknownProtected = unknownProtected && tabs.filter { !known.contains($0.id) }.allSatisfy { $0.live.sleepPhase == .frozen }
    }
    let sampled = Set(queries.trace.ids("unload-query"))
    check("unload queries are bounded at 32/pass and cover all 67 tabs round-robin", bounded && sampled == Set(tabs.map(\.id)))
    check("unknown unload state cannot permit discard; true handler blocks discard", unknownProtected && tabs[0].live.sleepPhase == .frozen)
    queries.engine.unloaded.remove(tabs[0].id)
    queries.controller.tabUnloadHandlersChanged(tabs[0].id, hasHandlers: false)
    await queries.controller.tick()
    check("unload event updates cache without waiting for sampling", tabs[0].live.sleepPhase == .sleeping)
    let reads = queries.visibility.reads
    await queries.controller.tick()
    check("a settled pass reads the visibility provider exactly once", queries.visibility.reads == reads + 1)


    let moving = scenario("ownership-revision"), moved = moving.tab(age: 400)
    moving.profile.settings.sleepMode = .off
    let targetProfile = Profile(settings: ProfileSettings(sleepMode: .aggressive))
    let targetSpace = Space(profileID: targetProfile.id)
    moving.model.profiles.append(targetProfile); moving.model.spaces.append(targetSpace); moving.model.rebuildIndex()
    await moving.controller.tick()
    moving.model.moveNode(id: moved.id, to: .spaceToday(targetSpace.id), at: nil)
    await moving.controller.tick()
    await moving.controller.tick()
    check("tree revision invalidates cached ownership after a profile move", moved.live.sleepPhase == .sleeping)

    let backoff = scenario("backoff"), failing = backoff.tab(age: 400)
    backoff.engine.failDiscard.insert(failing.id)
    let start = backoff.clock.date
    await backoff.controller.debugSleepNow(tabID: failing.id)
    var timelineOK = backoff.controller.retryAfter[failing.id] == start.addingTimeInterval(30)
    for (boundary, next) in [(30.0, 90.0), (90.0, 210.0), (210.0, 450.0)] {
        backoff.clock.date = start.addingTimeInterval(boundary - 1)
        let attempts = backoff.trace.ids("discard").count
        await backoff.controller.tick(); await backoff.controller.handleMemoryPressure(.critical)
        timelineOK = timelineOK && backoff.trace.ids("discard").count == attempts
        backoff.clock.advance(1); await backoff.controller.tick()
        timelineOK = timelineOK && backoff.trace.ids("discard").count == attempts + 1 && backoff.controller.retryAfter[failing.id] == start.addingTimeInterval(next)
    }
    check("failed discard attempts at 0/30/90/210 s; pressure respects backoff", timelineOK)
    for _ in 0..<6 {
        backoff.clock.date = backoff.controller.retryAfter[failing.id]!
        await backoff.controller.tick()
    }
    check("exponential backoff caps at 30 min", backoff.controller.retryAfter[failing.id]!.timeIntervalSince(backoff.clock.date) == 1800)
    backoff.controller.tabUserInteracted(failing.id)
    await backoff.controller.tick()
    check("user interaction resets failed-discard backoff to 30 s", backoff.controller.retryAfter[failing.id]!.timeIntervalSince(backoff.clock.date) == 30)
    backoff.engine.failDiscard.remove(failing.id)
    backoff.clock.advance(30); await backoff.controller.tick()
    check("successful discard clears all backoff", failing.live.sleepPhase == .sleeping && backoff.controller.retryAfter[failing.id] == nil)
    print("backoff timeline: attempts=0,30,90,210 s; next=450 s; cap=1800 s")

    // A real SQLite writer lock holds the real store queue, not a mocked seam.
    let durable = scenario("durable"), quitTab = durable.tab(age: 400)
    try await durable.store.disk.flush()
    var connection: OpaquePointer?
    guard sqlite3_open(durable.store.disk.fileURL.path, &connection) == SQLITE_OK else { throw SleepCLIError.checksFailed(1) }
    defer { sqlite3_close(connection) }
    func sql(_ statement: String) throws {
        guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw SleepCLIError.checksFailed(1) }
    }
    try sql("BEGIN IMMEDIATE")
    var quitDone = false
    let quit = Task { try await durable.controller.captureAllForQuit(); quitDone = true }
    try await Task.sleep(for: .milliseconds(25))
    check("quit capture stays suspended while the real save transaction is blocked", !quitDone && durable.trace.ids("save-start") == [quitTab.id] && durable.trace.ids("save").isEmpty)
    try sql("COMMIT"); try await quit.value
    // Read through a second connection immediately after return, without draining the writer queue.
    var stmt: OpaquePointer?
    let prepared = sqlite3_prepare_v2(connection, "SELECT count(*) FROM sleep_history", -1, &stmt, nil) == SQLITE_OK
    let committed = prepared && sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
    sqlite3_finalize(stmt)
    check("quit returns after save and flush; second connection sees committed row", quitDone && committed && durable.store.flushFinished)
    durable.store.flushStarted = false; durable.store.flushFinished = false
    try sql("BEGIN IMMEDIATE")
    let flush = Task { try await durable.store.flush() }
    try await Task.sleep(for: .milliseconds(25))
    check("async flush waits for its real transaction commit", durable.store.flushStarted && !durable.store.flushFinished)
    try sql("COMMIT"); try await flush.value

    try sql("BEGIN IMMEDIATE")
    let sleep = Task { await durable.controller.debugSleepNow(tabID: quitTab.id) }
    try await Task.sleep(for: .milliseconds(25))
    check("discard cannot release the renderer before durable save", durable.trace.ids("discard").isEmpty && quitTab.live.sleepPhase == .frozen)
    try sql("COMMIT"); await sleep.value
    check("discard follows committed save", quitTab.live.sleepPhase == .sleeping && durable.trace.calls.last(where: { ["save", "discard"].contains($0.0) })?.0 == "discard")
    durable.model.closeTab(id: quitTab.id); durable.controller.tabClosed(quitTab.id)
    check("undoable close retains committed history", await durable.store.sleepHistory(tabID: quitTab.id) != nil)
    durable.controller.tabPurged(tabID: quitTab.id); try await durable.store.flush()
    check("permanent purge deletes the sleep row", await durable.store.sleepHistory(tabID: quitTab.id) == nil)


    let purgeRace = durable.tab(age: 400)
    try sql("BEGIN IMMEDIATE")
    let purging = Task { await durable.controller.debugSleepNow(tabID: purgeRace.id) }
    try await Task.sleep(for: .milliseconds(25))
    durable.model.closeTab(id: purgeRace.id); durable.controller.tabPurged(tabID: purgeRace.id)
    try sql("COMMIT"); await purging.value; try await durable.store.flush()
    check("purge during an awaited save cannot resurrect history", await durable.store.sleepHistory(tabID: purgeRace.id) == nil)

    let badRoot = root.appendingPathComponent("review-storage-failure")
    try Data([0]).write(to: badRoot)
    let broken = SleepScenario(root: badRoot), unsaved = broken.tab(age: 400)
    await broken.controller.debugSleepNow(tabID: unsaved.id)
    check("failed durable save prevents engine discard and applies backoff", broken.trace.ids("discard").isEmpty && unsaved.live.sleepPhase == .frozen && broken.controller.retryAfter[unsaved.id] != nil)
    var quitThrew = false
    do { try await broken.controller.captureAllForQuit() } catch { quitThrew = true }
    check("quit capture propagates save failure to its caller", quitThrew)
    broken.controller.tabClosed(unsaved.id)
    var flushThrew = false
    do { try await broken.controller.captureAllForQuit() } catch { flushThrew = true }
    check("quit capture propagates flush failure even with no captures", flushThrew)

    let events = scenario("short-events"), short = events.tab(age: 400)
    short.live.isAudible = true; events.controller.tabAudioChanged(short.id)
    short.live.isAudible = false; events.controller.tabAudioChanged(short.id)
    events.clock.advance(59); await events.controller.tick()
    check("audio start/stop entirely between ticks retains the full grace", short.live.sleepPhase == .live)
    events.clock.advance(1); await events.controller.tick()
    events.controller.tabDidCommit(short.id)
    events.clock.advance(9); await events.controller.tick()
    check("background commit event protects without a sampled loading transition", short.live.sleepPhase == .live)
    events.clock.advance(1); await events.controller.tick()
    check("event protection expires at the exact boundary", short.live.sleepPhase == .frozen)
}

@MainActor
private func runSleepControllerBench(root: URL, check: (String, Bool) -> Void) async throws {
    let clock = SleepClock(), trace = SleepTrace()
    let tabs = (0..<5000).map { i in
        let tab = Tab(url: URL(string: "https://example.invalid/bench")!, lastActiveAt: clock.date.addingTimeInterval(i.isMultiple(of: 250) ? -400 : -Double(40 + i % 70)))
        tab.live.sleepPhase = .live
        if i % 47 == 1 { tab.live.isAudible = true }
        if i % 61 == 2 { tab.live.isCapturing = true }
        if i % 79 == 3 { tab.live.isLoading = true }
        if i % 101 == 4 { tab.live.devToolsOpen = true }
        return tab
    }
    let profiles = (0..<4).map { Profile(name: "Bench \($0)", settings: ProfileSettings(sleepMode: $0 == 0 ? .conservative : $0 == 3 ? .aggressive : .balanced), dataDirectoryName: "Bench-\($0)") }
    var spaces: [Space] = []
    for (p, profile) in profiles.enumerated() {
        profile.favorites = Array(tabs[(p * 1250)..<(p * 1250 + 10)])
        for i in 0..<3 {
            let first = p * 1250 + 10 + i * 413
            let end = i == 2 ? (p + 1) * 1250 : first + 413
            let split = Split(panes: Array(tabs[first..<(first + 4)]), focusedPaneID: tabs[first].id)
            let nested = Folder(children: [.folder(Folder(children: tabs[(first + 4)..<end].map { .tab($0) }))])
            spaces.append(Space(profileID: profile.id, pinned: [.split(split)], today: [.folder(nested)]))
        }
    }
    let windows = spaces.prefix(8).map { space in
        BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: space.pinned[0].id])
    }
    let model = BrowserModel(profiles: profiles, spaces: spaces, windows: windows)
    let visibility = CLISleepVisibility(model: model)
    for window in windows.suffix(2) { visibility.states[window.id] = .minimized }
    visibility.states[windows[5].id] = .occluded
    visibility.peek = [tabs[90].id, tabs[1300].id]; visibility.littleOpen = [tabs[2600].id]
    visibility.pictureInPicture = [tabs[3900].id]; visibility.splitPanes = [tabs[4998].id, tabs[4999].id]
    let store = CLISleepStore(root: root, trace: trace, model: model)
    let engine = SimulatedSleepEngine(model: model, clock: clock, trace: trace)
    let controller = SleepController(model: model, engine: engine, store: store, visibility: visibility,
                                     chromiumTag: "156.0.8078.48", now: { clock.date })
    await controller.tick() // One warm-up: builds derived ownership and freezes eligible tabs.
    var cpuSamples: [Double] = [], wallSamples: [Double] = []
    func threadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
    }
    for pass in 0..<200 {
        // App visibility changes still enter the measured controller through the provider.
        visibility.peek = [tabs[90 + pass % 4].id, tabs[1300].id]
        let start = ContinuousClock.now
        let cpuStart = threadCPUMilliseconds()
        await controller.tick()
        cpuSamples.append(threadCPUMilliseconds() - cpuStart)
        let elapsed = start.duration(to: .now).components
        wallSamples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    cpuSamples.sort(); wallSamples.sort()
    let p95 = cpuSamples[189]
    print(String(format: "FULL controller pass 5000 tabs / 200 passes, thread CPU: p50=%.3f ms p95=%.3f ms max=%.3f ms", cpuSamples[99], p95, cpuSamples[199]))
    print(String(format: "FULL controller pass wall time (informational): p50=%.3f ms p95=%.3f ms max=%.3f ms", wallSamples[99], wallSamples[189], wallSamples[199]))
    print("bench workload: profiles=4 spaces=12 windows=8 visibleWindows=5; unloadQueries=\(trace.ids("unload-query").count) discards=\(trace.ids("discard").count) committedRows=\(await store.allTabIDs().count)")
    check("full controller pass over 5000 tabs < 2 ms thread CPU p95 (200 measured passes)", p95 < 2 && trace.ids("discard").count > 0 && model.index.values.compactMap(\.tab).count == 5000)
}

@MainActor
func runSleepSimulation(args: [String]) async throws {
    guard args.count == 1 else { throw SleepCLIError.usage }
    guard let model = try SnapshotStore(root: URL(fileURLWithPath: args[0])).load() else { throw SleepCLIError.missingSnapshot }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-sleep-sim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SleepClock(), trace = SleepTrace(), store = CLISleepStore(root: root, trace: trace, model: model)
    let tabs = model.index.values.compactMap(\.tab).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    let engine = SimulatedSleepEngine(model: model, clock: clock, trace: trace)
    for tab in tabs { tab.live.sleepPhase = .live; tab.lastActiveAt = clock.date }
    for profile in model.profiles { profile.settings.sleepMode = .balanced }
    let visibility = CLISleepVisibility(model: model)
    let controller = SleepController(model: model, engine: engine, store: store, visibility: visibility, chromiumTag: "156.0.8078.48", now: { clock.date })
    let initiallyVisible = controller.visibleTabIDs()
    var pool = tabs.filter { !initiallyVisible.contains($0.id) }
    // Keep model counts intact. Assign runtime gates to distinct imported tabs.
    guard pool.count >= 7, let window = model.windows.first, let visibleTab = pool.popLast() else { throw SleepCLIError.missingSnapshot }
    window.selectedNodeBySpace[window.focusedSpaceID] = visibleTab.id
    let visible = controller.visibleTabIDs()
    let names = ["audible", "capturing", "PiP", "DevTools", "downloading"]
    var protected: [(String, Tab)] = []
    for name in names {
        let tab = pool.removeLast(); protected.append((name, tab))
        switch name {
        case "audible": tab.live.isAudible = true
        case "capturing", "PiP": tab.live.isCapturing = true
        case "DevTools": tab.live.devToolsOpen = true
        default: controller.downloading.insert(tab.id)
        }
    }
    let protectedIDs = Set(protected.map { $0.1.id }).union(visible)
    print("sleep-sim imported snapshot: profiles=\(model.profiles.count) spaces=\(model.spaces.count) tabs=\(tabs.count) splitPanes=\(model.index.values.compactMap(\.split).reduce(0) { $0 + $1.panes.count })")
    print("runtime assignments: visible=\(visible.count) audible=1 capturing=1 PiP=1 DevTools=1 downloading=1")
    for seconds in [0, 30, 300, 24 * 3600 + 300, 48 * 3600] {
        clock.date = Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))
        await controller.tick()
        let frozen = tabs.filter { $0.live.sleepPhase == .frozen }.count
        let sleeping = tabs.filter { $0.live.sleepPhase == .sleeping }.count
        let destroyed = tabs.filter { $0.live.sleepPhase == .sleeping && !controller.liveContent.contains($0.id) }.count
        print("t=\(seconds)s live=\(tabs.filter { $0.live.sleepPhase == .live }.count) frozen=\(frozen) sleeping=\(sleeping) destroyed=\(destroyed)")
    }
    let gateOK = protectedIDs.allSatisfy { model.tab(id: $0)?.live.sleepPhase == .live }
    let quietOK = tabs.filter { !protectedIDs.contains($0.id) }.allSatisfy { $0.live.sleepPhase == .sleeping && !controller.liveContent.contains($0.id) }
    store.disk.flushQueue()
    print("48h checks: never-sleep gates=\(gateOK ? "OK" : "FAIL") quiet freeze-discard-destroy=\(quietOK ? "OK" : "FAIL") storedRows=\(await store.allTabIDs().count) bytes=\(await store.disk.totalBytes())")
    guard gateOK && quietOK else { throw SleepCLIError.checksFailed(1) }
}
