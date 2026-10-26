import Foundation
import OpenModel
import OpenSleep
import OpenStore

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
    init(root: URL, trace: SleepTrace) {
        disk = SleepStore(root: root); self.trace = trace
        disk.onError = { [weak self] message in
            self?.errors.append(message)
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
    func saveSleepHistory(tabID: ItemID, envelope e: SleepHistoryEnvelope) {
        trace.record("save", tabID)
        disk.save(SleepHistoryRecord(tabID: tabID, container: e.container, currentIndex: e.currentIndex,
            entryCount: e.entryCount, currentURL: e.currentURL, currentTitle: e.currentTitle,
            faviconURL: e.faviconURL, hasPageState: e.hasPageState, containerVersion: e.containerVersion,
            chromiumTag: e.chromiumTag, capturedAt: e.capturedAt))
    }
    func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope? {
        guard let r = await disk.load(tabID: tabID) else { return nil }
        return SleepHistoryEnvelope(container: r.container, currentIndex: r.currentIndex, entryCount: r.entryCount,
            currentURL: r.currentURL, currentTitle: r.currentTitle, faviconURL: r.faviconURL,
            hasPageState: r.hasPageState, containerVersion: r.containerVersion, chromiumTag: r.chromiumTag, capturedAt: r.capturedAt)
    }
    func deleteSleepHistory(tabID: ItemID) { disk.delete(tabID: tabID) }
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
    var pauseDiscard = false
    var continuation: CheckedContinuation<Void, Never>?

    init(model: BrowserModel, clock: SleepClock, trace: SleepTrace) {
        self.model = model; self.clock = clock; self.trace = trace
    }
    func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool {
        trace.record(history == nil ? "create-fresh" : "create-history", tabID)
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
    func hasUnloadHandlers(tabID: ItemID) -> Bool { unloaded.contains(tabID) }
    func handleCriticalPressure() { criticalCount += 1 }
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
    var logs: [String] = []

    init(root: URL, mode: SleepMode = .balanced) {
        profile.settings.sleepMode = mode
        space = Space(profileID: profile.id)
        window = BrowserWindowState(focusedSpaceID: space.id)
        model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        store = CLISleepStore(root: root, trace: trace)
        engine = SimulatedSleepEngine(model: model, clock: clock, trace: trace)
        controller = SleepController(model: model, engine: engine, store: store, chromiumTag: "156.0.8078.48", now: { [clock] in clock.date })
        controller.onLog = { [weak self] in self?.logs.append($0) }
    }
    func tab(age: TimeInterval = 0, pinned: Bool = false) -> Tab {
        let tab = Tab(url: URL(string: "https://example.invalid/sleep")!, title: "Open sleep fixture",
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
            check("off still freezes and never auto-discards", tab.live.sleepPhase == .frozen)
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

    let pressure = scenario("pressure", .off)
    let newest = pressure.tab(age: 40), oldest = pressure.tab(age: 80), protected = pressure.tab(age: 100)
    let pressureAudio = pressure.tab(age: 100), pressureCapture = pressure.tab(age: 100)
    await pressure.controller.tick()
    await pressure.select(protected); pressureAudio.live.isAudible = true; pressureCapture.live.isCapturing = true
    pressure.trace.calls.removeAll()
    await pressure.controller.handleMemoryPressure(.warning)
    check("warning pressure overrides delay/off; oldest first; gates honored", pressure.trace.ids("discard") == [oldest.id, newest.id])
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
    check("per-profile mode lookup covers favorites and nested pinned tabs", offTab.live.sleepPhase == .frozen && favorite.live.sleepPhase == .sleeping && nested.live.sleepPhase == .sleeping)
    other.settings.sleepMode = .off
    await ownership.controller.tick()
    check("switching off leaves already sleeping tabs asleep", favorite.live.sleepPhase == .sleeping && nested.live.sleepPhase == .sleeping)
    await ownership.select(offTab)
    ownership.controller.tabDidCommit(offTab.id)
    check("unfreeze wake shows retained content and logs on commit", offTab.live.sleepPhase == .live && ownership.logs.contains { $0.contains("sleep-wake unfreeze") })
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
    cap.store.saveSleepHistory(tabID: capID, envelope: exact)
    check("exact 2 MiB boundary stored intact", await cap.store.sleepHistory(tabID: capID) == exact)
    var over = exact; over.container.append(0)
    cap.store.saveSleepHistory(tabID: capID, envelope: over)
    let retained = await cap.store.sleepHistory(tabID: capID)
    check("over-cap write rejected and logged; old record retained", cap.store.errors.count == 1 && retained == exact)
    let bytes = await cap.store.disk.totalBytes()
    let storedIDs = Set(await cap.store.disk.allTabIDs())
    check("totalBytes and allTabIDs report stored blobs", bytes == exact.container.count + (retryBlob?.container.count ?? 0) && storedIDs == [capID, retry.id])
    cap.store.disk.delete(tabIDs: [capID, retry.id]); cap.store.disk.flushQueue()
    check("batch delete works", await cap.store.disk.allTabIDs().isEmpty)
    cap.store.saveSleepHistory(tabID: capID, envelope: exact); cap.store.deleteSleepHistory(tabID: capID)
    check("single delete and missing load work", await cap.store.sleepHistory(tabID: capID) == nil)

    let corrupt = scenario("corrupt")
    let bad = corrupt.tab(age: 400)
    await corrupt.controller.debugSleepNow(tabID: bad.id)
    var badBlob = (await corrupt.store.sleepHistory(tabID: bad.id))!
    badBlob.container[0] ^= 1
    corrupt.store.saveSleepHistory(tabID: bad.id, envelope: badBlob)
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
    oldStore.saveNow(model: oldModel)
    let reloaded = try oldStore.load()!
    let schema = try oldStore.loadData()?.schemaVersion
    check("pre-change schema-1 fixture defaults balanced; roundtrip OK", defaultMode && SnapshotMapper.structurallyEqual(oldModel, reloaded) && schema == 1)
    for mode in SleepMode.allCases {
        oldModel.profiles[0].settings.sleepMode = mode; oldStore.saveNow(model: oldModel)
        check("snapshot persists \(mode.rawValue) mode", try oldStore.load()?.profiles.first?.settings.sleepMode == mode)
    }

    let splitScenario = scenario("split")
    let left = splitScenario.tab(age: 400), right = splitScenario.tab(age: 400)
    let split = splitScenario.model.makeSplit(tabIDs: [left.id, right.id])!
    splitScenario.window.selectedNodeBySpace[splitScenario.space.id] = split.id
    await splitScenario.controller.tick()
    check("selected split protects every pane", splitScenario.controller.visibleTabIDs() == [left.id, right.id] && left.live.sleepPhase == .live && right.live.sleepPhase == .live)
    await splitScenario.controller.captureAllForQuit()
    check("quit capture includes both split panes", Set(await splitScenario.store.disk.allTabIDs()) == [left.id, right.id])
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
    invalidStore.saveSleepHistory(tabID: ItemID(), envelope: exact)
    _ = await invalidStore.disk.allTabIDs()
    await Task.yield()
    check("SQLite/open failures surface onError and keep CLI running", !invalidStore.errors.isEmpty)

    try runSleepPolicyBench(check: check)
    print("sleep-demo \(failed == 0 ? "OK" : "FAIL"): \(passed) checks passed, \(failed) failed")
    if failed != 0 { throw SleepCLIError.checksFailed(failed) }
}

@MainActor
private func runSleepPolicyBench(check: (String, Bool) -> Void) throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tabs = (0..<5000).map { i in
        let tab = Tab(url: URL(string: "https://example.invalid/bench")!, lastActiveAt: now.addingTimeInterval(-Double(i)))
        tab.live.sleepPhase = i.isMultiple(of: 2) ? .live : .frozen
        return tab
    }
    let policy = SleepPolicy(), visible: Set<ItemID> = [tabs[0].id]
    var samples: [Double] = [], decisions = 0
    for _ in 0..<101 {
        let start = ContinuousClock.now
        var count = 0
        for tab in tabs {
            if policy.action(tab: tab, visible: visible, now: now) != .none { count += 1 }
        }
        let elapsed = start.duration(to: .now).components
        decisions += count
        samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    samples.removeFirst(); samples.sort()
    print(String(format: "policy tick 5000 tabs: p50=%.3f ms p95=%.3f ms max=%.3f ms; decisions=%d", samples[50], samples[95], samples[99], decisions))
    check("policy tick over 5000 tabs < 2 ms (maximum)", samples[99] < 2 && decisions > 0)
}

@MainActor
func runSleepSimulation(args: [String]) async throws {
    guard args.count == 1 else { throw SleepCLIError.usage }
    guard let model = try SnapshotStore(root: URL(fileURLWithPath: args[0])).load() else { throw SleepCLIError.missingSnapshot }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-sleep-sim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SleepClock(), trace = SleepTrace(), store = CLISleepStore(root: root, trace: trace)
    let tabs = model.index.values.compactMap(\.tab).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    let engine = SimulatedSleepEngine(model: model, clock: clock, trace: trace)
    for tab in tabs { tab.live.sleepPhase = .live; tab.lastActiveAt = clock.date }
    for profile in model.profiles { profile.settings.sleepMode = .balanced }
    let controller = SleepController(model: model, engine: engine, store: store, chromiumTag: "156.0.8078.48", now: { clock.date })
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
    print("48h checks: never-sleep gates=\(gateOK ? "OK" : "FAIL") quiet freeze-discard-destroy=\(quietOK ? "OK" : "FAIL") storedRows=\(await store.disk.allTabIDs().count) bytes=\(await store.disk.totalBytes())")
    guard gateOK && quietOK else { throw SleepCLIError.checksFailed(1) }
}
