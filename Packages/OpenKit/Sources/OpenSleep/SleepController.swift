import Foundation
import OpenModel

@MainActor
public final class SleepController {
    public enum Pressure: Int, Sendable { case warning = 1, critical = 2 }
    public var onLog: ((String) -> Void)?
    public var downloading: Set<ItemID> = []
    public private(set) var liveContent: Set<ItemID>
    public private(set) var lastAudibleAt: [ItemID: Date] = [:]
    public private(set) var lastCommitAt: [ItemID: Date] = [:]
    public private(set) var sleptAt: [ItemID: Date] = [:]
    public private(set) var unloadCache: [ItemID: Bool] = [:]

    private let model: BrowserModel
    private let engine: any SleepEngine
    private let store: any SleepHistoryStoring
    private let chromiumTag: String
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var loading: Set<ItemID> = []
    private var audible: Set<ItemID> = []
    private var shown: Set<ItemID> = []
    private var waking: Set<ItemID> = []
    private var busy: Set<ItemID> = []
    private var wakeStartedAt: [ItemID: (Date, String)] = [:]
    private var runningPass = false
    private var pendingPressure: Pressure?

    public init(model: BrowserModel, engine: any SleepEngine, store: any SleepHistoryStoring,
                chromiumTag: String, now: @escaping () -> Date = Date.init) {
        self.model = model; self.engine = engine; self.store = store
        self.chromiumTag = chromiumTag; self.now = now
        liveContent = Set(model.index.values.compactMap { node in
            guard let tab = node.tab, tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { return nil }
            return tab.id
        })
        shown = visibleTabIDs().intersection(liveContent)
    }

    /// The app calls visibility hooks after it updates window selection. All panes
    /// of a selected split are visible, including panes that do not own keyboard focus.
    public func visibleTabIDs() -> Set<ItemID> {
        var result: Set<ItemID> = []
        for window in model.windows {
            guard let id = window.selectedNodeBySpace[window.focusedSpaceID], let node = model.node(id: id) else { continue }
            if let split = node.split { result.formUnion(split.panes.map(\.id)) }
            else if node.tab != nil { result.insert(id) }
        }
        return result
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let level: Pressure = source.data.contains(.critical) ? .critical : .warning
            Task { @MainActor [weak self] in await self?.handleMemoryPressure(level) }
        }
        pressureSource = source
        source.resume()
    }

    public func stop() {
        loop?.cancel(); loop = nil
        pressureSource?.cancel(); pressureSource = nil
    }

    /// Call when the app creates initial engine content outside the wake path.
    public func contentCreated(tabID: ItemID) {
        guard let tab = model.tab(id: tabID) else { return }
        liveContent.insert(tabID); tab.live.sleepPhase = .live
    }

    public func tabBecameHidden(_ tabID: ItemID) {
        guard !visibleTabIDs().contains(tabID), liveContent.contains(tabID) else { return }
        if shown.remove(tabID) != nil { engine.setVisible(tabID: tabID, visible: false) }
        // lastActiveAt is owned by BrowserModel.selectNode, not a second clock here.
    }

    public func tabBecameVisible(_ tabID: ItemID) async {
        guard let tab = model.tab(id: tabID), visibleTabIDs().contains(tabID), !waking.contains(tabID) else { return }
        if liveContent.contains(tabID) {
            let phase = tab.live.sleepPhase
            if phase == .frozen { wakeStartedAt[tabID] = (now(), "unfreeze"); tab.live.sleepPhase = .live }
            if phase == .sleeping { wakeStartedAt[tabID] = (now(), "discard") }
            show(tabID)
            return
        }
        waking.insert(tabID)
        defer { waking.remove(tabID) }
        wakeStartedAt[tabID] = (now(), tab.live.sleepPhase == .placeholder ? "placeholder" : "destroyed")
        let history = await store.sleepHistory(tabID: tabID)
        guard model.tab(id: tabID) === tab else { wakeStartedAt[tabID] = nil; return }
        var restored = await engine.createContent(tabID: tabID, url: history?.currentURL ?? tab.url, history: history)
        var usedHistory = history != nil
        if !restored, let history {
            // Failed adapters must close partial content; this call is also safe when none exists.
            engine.destroyContent(tabID: tabID)
            onLog?("sleep-restore-fallback \(tabID.rawValue.uuidString.prefix(8))")
            restored = await engine.createContent(tabID: tabID, url: history.currentURL, history: nil)
            usedHistory = false
        }
        guard model.tab(id: tabID) === tab else {
            if restored { engine.destroyContent(tabID: tabID) }
            wakeStartedAt[tabID] = nil
            return
        }
        guard restored else { onLog?("sleep-create-failed \(tabID.rawValue.uuidString.prefix(8))"); return }
        liveContent.insert(tabID); tab.live.sleepPhase = .live; sleptAt[tabID] = nil
        if usedHistory, let history { setNavigation(tab, history) }
        else { tab.live.canGoBack = false; tab.live.canGoForward = false }
        if visibleTabIDs().contains(tabID) { show(tabID) }
        else { engine.setVisible(tabID: tabID, visible: false) }
    }

    private func show(_ id: ItemID) {
        if shown.insert(id).inserted { engine.setVisible(tabID: id, visible: true) }
    }

    /// Close/archiving tears down content but keeps history for restore/undo.
    public func tabClosed(_ tabID: ItemID) {
        if liveContent.remove(tabID) != nil { engine.destroyContent(tabID: tabID) }
        shown.remove(tabID); loading.remove(tabID); audible.remove(tabID)
        lastAudibleAt[tabID] = nil; lastCommitAt[tabID] = nil; sleptAt[tabID] = nil
        unloadCache[tabID] = nil; wakeStartedAt[tabID] = nil; downloading.remove(tabID)
    }

    public func tabDidCommit(_ tabID: ItemID) {
        guard let tab = model.tab(id: tabID), liveContent.contains(tabID) else { return }
        lastCommitAt[tabID] = now(); loading.remove(tabID)
        tab.live.isLoading = false; tab.live.sleepPhase = .live; sleptAt[tabID] = nil
        if let (start, kind) = wakeStartedAt.removeValue(forKey: tabID) {
            onLog?("sleep-wake \(kind) \(tabID.rawValue.uuidString.prefix(8)) ms=\(now().timeIntervalSince(start) * 1000)")
        }
    }

    /// Optional event hook preserves the full audio grace period between ticks.
    public func tabAudioChanged(_ tabID: ItemID) { lastAudibleAt[tabID] = now() }

    private func refresh(_ tab: Tab) {
        let id = tab.id
        if tab.live.isAudible {
            audible.insert(id); lastAudibleAt[id] = now()
        } else if audible.remove(id) != nil { lastAudibleAt[id] = now() }
        if tab.live.isLoading { loading.insert(id) }
        else if loading.remove(id) != nil { lastCommitAt[id] = now() }
        if tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen {
            unloadCache[id] = engine.hasUnloadHandlers(tabID: id)
        }
    }

    private func policy(_ tab: Tab) -> SleepPolicy {
        var parent = model.parent(of: tab.id)
        while let current = parent {
            switch current {
            case .favorites(let id): return SleepPolicy(mode: model.profile(id: id)?.settings.sleepMode ?? .balanced)
            case .spacePinned(let id), .spaceToday(let id):
                let profile = model.space(id: id).flatMap { model.profile(id: $0.profileID) }
                return SleepPolicy(mode: profile?.settings.sleepMode ?? .balanced)
            case .folder(let id), .splitPane(let id): parent = model.parent(of: id)
            }
        }
        return SleepPolicy()
    }

    private func gate(_ tab: Tab, discard: Bool) -> SleepPolicy.Gate? {
        policy(tab).blockingReason(tab: tab, visible: visibleTabIDs(), now: now(),
            lastAudibleAt: lastAudibleAt[tab.id], lastCommitAt: lastCommitAt[tab.id],
            downloading: downloading.contains(tab.id), hasUnloadHandlers: unloadCache[tab.id] ?? false,
            forDiscard: discard)
    }

    public func tick() async { await runPass(pressure: nil) }

    /// Same path used by the OS source and the CLI pressure simulation.
    public func handleMemoryPressure(_ level: Pressure) async {
        if runningPass {
            if (pendingPressure?.rawValue ?? 0) < level.rawValue { pendingPressure = level }
            return
        }
        await runPass(pressure: level)
    }

    private func runPass(pressure: Pressure?) async {
        guard !runningPass else { return }
        runningPass = true
        defer { runningPass = false }
        var level = pressure
        repeat {
            pendingPressure = nil
            let tabs = model.index.values.compactMap(\.tab).sorted { $0.lastActiveAt < $1.lastActiveAt }
            for tab in tabs where liveContent.contains(tab.id) && !busy.contains(tab.id) {
                refresh(tab)
                if level != nil {
                    // Pressure shortens the mode delay, including .off, but never gates.
                    if tab.live.sleepPhase == .frozen, now().timeIntervalSince(tab.lastActiveAt) >= 30,
                       gate(tab, discard: true) == nil { await discard(tab) }
                    if level == .critical, tab.live.sleepPhase == .sleeping, gate(tab, discard: false) == nil { destroy(tab) }
                } else {
                    let action = policy(tab).action(tab: tab, visible: visibleTabIDs(), now: now(),
                        lastAudibleAt: lastAudibleAt[tab.id], lastCommitAt: lastCommitAt[tab.id],
                        downloading: downloading.contains(tab.id), hasUnloadHandlers: unloadCache[tab.id] ?? false,
                        sleptAt: sleptAt[tab.id])
                    switch action {
                    case .none: break
                    case .freeze:
                        if engine.freeze(tabID: tab.id) { tab.live.sleepPhase = .frozen }
                    case .discard: await discard(tab)
                    case .destroy: destroy(tab)
                    }
                }
            }
            if level == .critical { engine.handleCriticalPressure() }
            level = pendingPressure
        } while level != nil
    }

    public func debugSleepNow(tabID: ItemID) async {
        guard let tab = model.tab(id: tabID), liveContent.contains(tabID),
              tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { return }
        refresh(tab)
        guard gate(tab, discard: true) == nil else { return }
        if tab.live.sleepPhase == .live {
            guard engine.freeze(tabID: tabID) else { return }
            tab.live.sleepPhase = .frozen
        }
        await discard(tab)
    }

    private func discard(_ tab: Tab) async {
        let id = tab.id
        guard !busy.contains(id), gate(tab, discard: true) == nil else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        guard var envelope = engine.captureHistory(tabID: id) else {
            onLog?("sleep-capture-failed \(id.rawValue.uuidString.prefix(8))"); return
        }
        envelope.chromiumTag = chromiumTag
        store.saveSleepHistory(tabID: id, envelope: envelope)
        let discarded = await engine.discard(tabID: id)
        guard model.tab(id: id) === tab, liveContent.contains(id) else { return }
        // Selection can change while the adapter waits for discard completion.
        guard !visibleTabIDs().contains(id) else {
            if discarded { engine.setVisible(tabID: id, visible: true) }
            tab.live.sleepPhase = .live
            return
        }
        guard discarded, engine.wasDiscarded(tabID: id) else { return }
        tab.live.sleepPhase = .sleeping; sleptAt[id] = now(); tab.live.isLoading = false
        setNavigation(tab, envelope)
    }

    private func setNavigation(_ tab: Tab, _ envelope: SleepHistoryEnvelope) {
        tab.live.canGoBack = envelope.currentIndex > 0
        tab.live.canGoForward = envelope.currentIndex < envelope.entryCount - 1
    }

    private func destroy(_ tab: Tab) {
        guard liveContent.remove(tab.id) != nil else { return }
        engine.destroyContent(tabID: tab.id); shown.remove(tab.id)
    }

    public func captureAllForQuit() async {
        let start = now()
        // No trusted cheap entry-count callback exists yet: when in doubt capture.
        // Discarded shells already have the sleep-time history; include all live split panes.
        for id in liveContent {
            guard let tab = model.tab(id: id), tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { continue }
            if var envelope = engine.captureHistory(tabID: id) {
                envelope.chromiumTag = chromiumTag
                store.saveSleepHistory(tabID: id, envelope: envelope)
            } else { onLog?("sleep-capture-failed \(id.rawValue.uuidString.prefix(8))") }
        }
        onLog?("sleep-quit-capture ms=\(now().timeIntervalSince(start) * 1000)")
    }
}
