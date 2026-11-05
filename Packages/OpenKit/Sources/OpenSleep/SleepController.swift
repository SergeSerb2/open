import Foundation
import OpenModel

@MainActor
public final class SleepController {
    public enum Pressure: Int, Sendable { case warning = 1, critical = 2 }
    public var onLog: ((String) -> Void)?
    public var downloading: Set<ItemID> = [] { didSet { if downloading != oldValue { setNeedsPass() } } }
    /// macOS Low Power Mode (Battery Saver). Balanced ("Automatic") then uses the Aggressive
    /// discard delay; other modes keep their own (settings-library, Tab Sleeping group).
    public var lowPowerMode = false { didSet { if lowPowerMode != oldValue { setNeedsPass() } } }
    /// The mode a profile's setting acts as right now.
    public func effectiveMode(_ mode: SleepMode) -> SleepMode { lowPowerMode && mode == .balanced ? .aggressive : mode }
    /// Completed passes (timer, pressure, and explicit ticks). Evidence for the idle checks.
    public private(set) var passCount = 0
    /// True while a pass is scheduled. False while nothing can change without an event.
    public var isPassScheduled: Bool { loop != nil }
    /// True while a pass (timer, pressure or explicit) runs; another `tick()` returns at once.
    public var isRunningPass: Bool { runningPass }
    /// Real seconds until the scheduled pass, or nil while parked.
    public var scheduledPassDelay: TimeInterval? {
        loopWakeAt.map { at in
            let left = ContinuousClock.now.duration(to: at).components
            return max(0, Double(left.seconds) + Double(left.attoseconds) / 1e18)
        }
    }
    public private(set) var liveContent: Set<ItemID>
    public var hiddenAt: [ItemID: Date] { stateValues(\.hiddenAt) }
    public var lastAudibleAt: [ItemID: Date] { stateValues(\.lastAudibleAt) }
    public var lastCommitAt: [ItemID: Date] { stateValues(\.lastCommitAt) }
    public var sleptAt: [ItemID: Date] { stateValues(\.sleptAt) }
    public var unloadCache: [ItemID: Bool] { stateValues(\.unload) }
    public var retryAfter: [ItemID: Date] { stateValues(\.retryAfter) }
    public let maximumUnloadQueriesPerPass: Int

    private let model: BrowserModel
    private let engine: any SleepEngine
    private let store: any SleepHistoryStoring
    private let visibility: any SleepVisibilityProviding
    private let chromiumTag: String
    private let now: () -> Date
    private final class ProfileRules {
        var sites: [String] = []
        var rules = KeepAliveRules.builtIn
        func current(_ current: [String]) -> KeepAliveRules {
            if current != sites {
                sites = current
                rules = current.isEmpty ? .builtIn : KeepAliveRules(userSites: current)
            }
            return rules
        }
    }
    private var profileRules: [ProfileID: ProfileRules] = [:]
    private var loop: Task<Void, Never>?
    private var loopWakeAt: ContinuousClock.Instant?
    private var started = false
    /// The cadence while a transition is pending. Never a per-tab timer.
    public static let passInterval: TimeInterval = 5
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var shown: Set<ItemID> = []
    private var knownVisible: Set<ItemID> = []
    private var waking: Set<ItemID> = []
    private var purged: Set<ItemID> = []
    private var wakeStartedAt: [ItemID: (Date, String)] = [:]
    private var runningPass = false
    private var pendingPressure: Pressure?
    // One stable runtime record per tab. The scan holds references, so it does
    // not hash the same UUID for every timestamp, flag, and membership check.
    private final class State {
        var hasContent = false
        var everVisible = false
        var wasLoading = false
        var wasAudible = false
        var busy = false
        var hiddenAt: Date?
        var lastAudibleAt: Date?
        var lastCommitAt: Date?
        var sleptAt: Date?
        var unload: Bool?
        var retryAfter: Date?
        var retryDelay: TimeInterval?
        var keepAliveURL: URL?
        var keepAliveRules: KeepAliveRules?
        var keepAlive = false
    }
    private var states: [ItemID: State] = [:]
    private func state(_ id: ItemID) -> State {
        if let value = states[id] { return value }
        let value = State(); states[id] = value; return value
    }
    private func stateValues<T>(_ path: KeyPath<State, T?>) -> [ItemID: T] {
        Dictionary(uniqueKeysWithValues: states.compactMap { id, state in state[keyPath: path].map { (id, $0) } })
    }
    private struct Entry { let tab: Tab; let state: State; let owner: NodeParent? }
    private var entries: [Entry] = []
    private var groups: [NodeParent?: [Entry]] = [:]
    private var cachedRevision: UInt64?
    private var unloadCursor = 0

    public init(model: BrowserModel, engine: any SleepEngine, store: any SleepHistoryStoring,
                visibility: any SleepVisibilityProviding, chromiumTag: String,
                maximumUnloadQueriesPerPass: Int = 32, now: @escaping () -> Date = Date.init) {
        self.model = model; self.engine = engine; self.store = store; self.visibility = visibility
        self.chromiumTag = chromiumTag; self.now = now
        self.maximumUnloadQueriesPerPass = max(0, maximumUnloadQueriesPerPass)
        liveContent = Set(model.index.values.compactMap { node in
            guard let tab = node.tab, tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { return nil }
            return tab.id
        })
        for id in liveContent { state(id).hasContent = true }
        knownVisible = visibleTabIDs()
        shown = knownVisible.intersection(liveContent)
        for id in knownVisible { state(id).everVisible = true; model.tab(id: id)?.lastActiveAt = now() }
    }

    public func visibleTabIDs() -> Set<ItemID> { visibility.sleepVisibility().visibleTabIDs(in: model) }

    public func start() {
        guard !started else { return }
        started = true
        setNeedsPass()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let level: Pressure = source.data.contains(.critical) ? .critical : .warning
            Task { @MainActor [weak self] in await self?.handleMemoryPressure(level) }
        }
        pressureSource = source; source.resume()
    }

    public func stop() {
        started = false
        loop?.cancel(); loop = nil; loopWakeAt = nil
        pressureSource?.cancel(); pressureSource = nil
    }

    /// Something may have changed: run a pass within `passInterval`. The loop parks when no
    /// hidden tab can change phase without an event, so an idle app runs no sleep timer.
    /// Every event hook calls this; the App calls it for other inputs (mode, permissions).
    public func setNeedsPass() {
        guard started else { return }
        let soon = ContinuousClock.now.advanced(by: .seconds(Self.passInterval))
        if loop != nil, let at = loopWakeAt, at <= soon { return }
        schedulePass(after: Self.passInterval)
    }

    private func schedulePass(after seconds: TimeInterval) {
        loop?.cancel()
        let delay = Duration.milliseconds(Int64((seconds * 1000).rounded(.up)))
        loopWakeAt = ContinuousClock.now.advanced(by: delay)
        loop = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.loop = nil; self.loopWakeAt = nil
            await self.tick()
            // An event during the pass may already have scheduled the next one.
            guard self.started, self.loop == nil else { return }
            if let next = self.nextPassDelay() { self.schedulePass(after: next) }
        }
    }

    /// Seconds until a pass can change anything, or nil when only an event can (parked).
    /// Event-driven gates (keep-alive, notifications, audio, loading, capture, DevTools,
    /// downloads, a known unload handler on a frozen page) wait for their event.
    public func nextPassDelay() -> TimeInterval? {
        updateEntries()
        let date = now(), visible = visibleTabIDs(), policies = policies()
        var deadline: Date?
        for (owner, entries) in groups {
            let policy = owner.flatMap { policies[$0] } ?? SleepPolicy()
            for entry in entries where entry.state.hasContent && !visible.contains(entry.tab.id) {
                let tab = entry.tab, state = entry.state
                if state.busy { return Self.passInterval }
                switch tab.live.sleepPhase {
                case .placeholder: continue
                case .live:
                    if waitsForEvent(tab, state: state, policy: policy) { continue }
                    return Self.passInterval
                case .frozen:
                    guard policy.mode.discardDelay != nil, !waitsForEvent(tab, state: state, policy: policy),
                          state.unload != true else { continue }
                    if let retry = state.retryAfter, retry > date { deadline = min(deadline ?? retry, retry); continue }
                    return Self.passInterval
                case .sleeping:
                    if let slept = state.sleptAt {
                        let due = slept.addingTimeInterval(policy.destroyDelay)
                        deadline = min(deadline ?? due, due)
                    }
                }
            }
        }
        return deadline.map { max(Self.passInterval, $0.timeIntervalSince(date)) }
    }

    private func waitsForEvent(_ tab: Tab, state: State, policy: SleepPolicy) -> Bool {
        tab.live.notificationsAllowed || tab.live.isAudible || tab.live.isLoading || tab.live.isCapturing
            || tab.live.devToolsOpen || downloading.contains(tab.id) || isKeepAlive(tab, state: state, policy: policy)
    }

    /// The first never-sleep gate that protects this tab now (automation and the App's
    /// hidden-host cache use it). Nil when the tab may sleep.
    public func blockingGate(tabID: ItemID, forDiscard: Bool) -> SleepPolicy.Gate? {
        updateEntries()
        guard let tab = model.tab(id: tabID) else { return nil }
        let owner = entries.first { $0.tab.id == tabID }?.owner
        let policy = owner.flatMap { policies()[$0] } ?? SleepPolicy()
        // Same as debug sleep: an unknown unload state is asked once instead of guessed.
        let state = state(tabID)
        if forDiscard, state.unload == nil, state.hasContent { state.unload = engine.hasUnloadHandlers(tabID: tabID) }
        return gate(tab, policy: policy, visible: visibleTabIDs(), at: now(), discard: forDiscard)
    }

    /// The App is showing retained discarded content or made replacement content
    /// outside the controller's wake task. Latency logs at the page's first commit.
    public func wakeStarted(tabID: ItemID, kind: String) {
        // An unfreeze has no commit; a later discard/destroy wake replaces it.
        if wakeStartedAt[tabID]?.1 != kind { wakeStartedAt[tabID] = (now(), kind) }
    }

    /// Call when the app creates initial engine content outside the wake path.
    public func contentCreated(tabID: ItemID) {
        guard let tab = model.tab(id: tabID) else { return }
        let state = state(tabID)
        purged.remove(tabID); liveContent.insert(tabID); state.hasContent = true; tab.live.sleepPhase = .live
        if state.everVisible && !knownVisible.contains(tabID) { state.hiddenAt = now() }
        setNeedsPass()
    }

    public func tabBecameHidden(_ tabID: ItemID) {
        guard !visibleTabIDs().contains(tabID) else { return }
        hide(tabID, at: now())
        setNeedsPass()
    }

    private func hide(_ id: ItemID, at date: Date) {
        knownVisible.remove(id)
        let state = state(id)
        if state.hiddenAt == nil { state.hiddenAt = date }
        if shown.remove(id) != nil { engine.setVisible(tabID: id, visible: false) }
    }

    public func tabBecameVisible(_ tabID: ItemID) async {
        guard visibleTabIDs().contains(tabID) else { return }
        await makeVisible(tabID)
    }

    private func makeVisible(_ tabID: ItemID) async {
        guard let tab = model.tab(id: tabID), !purged.contains(tabID) else { return }
        let state = state(tabID)
        knownVisible.insert(tabID); state.everVisible = true; state.hiddenAt = nil
        tab.lastActiveAt = now(); tabUserInteracted(tabID)
        guard !waking.contains(tabID) else { return }
        if liveContent.contains(tabID) {
            let phase = tab.live.sleepPhase
            if phase == .frozen { wakeStartedAt[tabID] = (now(), "unfreeze"); tab.live.sleepPhase = .live }
            // The App may already have armed this discard wake before attaching
            // the retained view. Keep that start across repeated visibility hooks.
            if phase == .sleeping { wakeStarted(tabID: tabID, kind: "discard") }
            show(tabID)
            return
        }
        waking.insert(tabID)
        defer { waking.remove(tabID) }
        wakeStartedAt[tabID] = (now(), tab.live.sleepPhase == .placeholder ? "placeholder" : "destroyed")
        let history = await store.sleepHistory(tabID: tabID)
        guard model.tab(id: tabID) === tab, !purged.contains(tabID) else { wakeStartedAt[tabID] = nil; return }
        var restored = await engine.createContent(tabID: tabID, url: history?.currentURL ?? tab.url, history: history)
        var usedHistory = history != nil
        if !restored, let history {
            engine.destroyContent(tabID: tabID)
            onLog?("sleep-restore-fallback \(tabID.rawValue.uuidString.prefix(8))")
            restored = await engine.createContent(tabID: tabID, url: history.currentURL, history: nil)
            usedHistory = false
        }
        guard model.tab(id: tabID) === tab, !purged.contains(tabID) else {
            if restored { engine.destroyContent(tabID: tabID) }
            wakeStartedAt[tabID] = nil; return
        }
        guard restored else { onLog?("sleep-create-failed \(tabID.rawValue.uuidString.prefix(8))"); return }
        liveContent.insert(tabID); state.hasContent = true; tab.live.sleepPhase = .live; state.sleptAt = nil
        if usedHistory, let history { setNavigation(tab, history) }
        else { tab.live.canGoBack = false; tab.live.canGoForward = false }
        // Async restore must validate the current app snapshot, not the pass snapshot.
        if visibleTabIDs().contains(tabID) { show(tabID) }
        else { hide(tabID, at: now()); engine.setVisible(tabID: tabID, visible: false) }
    }

    private func show(_ id: ItemID) {
        if shown.insert(id).inserted { engine.setVisible(tabID: id, visible: true) }
    }

    /// Close/archiving tears down content but keeps history for restore/undo.
    public func tabClosed(_ tabID: ItemID) {
        if liveContent.remove(tabID) != nil { engine.destroyContent(tabID: tabID) }
        let state = state(tabID)
        state.hasContent = false; state.wasLoading = false; state.wasAudible = false
        shown.remove(tabID); knownVisible.remove(tabID); state.hiddenAt = nil
        state.lastAudibleAt = nil; state.lastCommitAt = nil; state.sleptAt = nil
        state.unload = nil; wakeStartedAt[tabID] = nil; downloading.remove(tabID)
        tabUserInteracted(tabID)
        setNeedsPass()
    }

    /// HARD S6 requirement: call on permanent deletion and archive purge, never
    /// on an undoable archive close. Flush the store when purge durability is needed.
    public func tabPurged(tabID: ItemID) {
        purged.insert(tabID); tabClosed(tabID); store.deleteSleepHistory(tabID: tabID)
    }

    public func tabUserInteracted(_ tabID: ItemID) { let state = state(tabID); state.retryAfter = nil; state.retryDelay = nil }
    public func tabUnloadHandlersChanged(_ tabID: ItemID, hasHandlers: Bool) { state(tabID).unload = hasHandlers; setNeedsPass() }

    public func tabDidCommit(_ tabID: ItemID) {
        guard let tab = model.tab(id: tabID), liveContent.contains(tabID) else { return }
        let state = state(tabID)
        state.lastCommitAt = now(); state.wasLoading = false; tabUserInteracted(tabID)
        tab.live.isLoading = false; tab.live.sleepPhase = .live; state.sleptAt = nil
        if let (start, kind) = wakeStartedAt.removeValue(forKey: tabID) {
            onLog?("sleep-wake \(kind) \(tabID.rawValue.uuidString.prefix(8)) ms=\(now().timeIntervalSince(start) * 1000)")
        }
        setNeedsPass()
    }

    /// Mandatory event hook: preserves audio grace even if start/stop fall between ticks.
    /// Set `tab.live.isAudible` first: the event's time then wins over the next pass's sample,
    /// so a stop between passes starts the grace at the stop, not at the next sample.
    public func tabAudioChanged(_ tabID: ItemID) {
        guard let tab = model.tab(id: tabID) else { return }
        let state = state(tabID)
        state.lastAudibleAt = now(); state.wasAudible = tab.live.isAudible; setNeedsPass()
    }

    private func refresh(_ tab: Tab, state: State, at date: Date) {
        let isAudible = tab.live.isAudible, isLoading = tab.live.isLoading
        if isAudible || state.wasAudible { state.lastAudibleAt = date }
        if !isLoading && state.wasLoading { state.lastCommitAt = date }
        state.wasAudible = isAudible; state.wasLoading = isLoading
    }

    /// Resolve each parent once per tree revision. No per-tab parent walks in a tick.
    private func updateEntries() {
        guard cachedRevision != model.treeRevision else { return }
        var owners: [ItemID: NodeParent] = [:]
        func owner(_ id: ItemID) -> NodeParent? {
            if let cached = owners[id] { return cached }
            guard let parent = model.parentByID[id] else { return nil }
            let root: NodeParent?
            switch parent {
            case .favorites, .spacePinned, .spaceToday: root = parent
            case .folder(let parentID), .splitPane(let parentID): root = owner(parentID)
            }
            owners[id] = root
            return root
        }
        entries = model.index.values.compactMap { node in
            guard let tab = node.tab else { return nil }
            return Entry(tab: tab, state: state(tab.id), owner: owner(tab.id))
        }
        // The cached order stays fixed until a structural change; no per-tick sort.
        groups = Dictionary(grouping: entries, by: \.owner)
        cachedRevision = model.treeRevision
        if !entries.isEmpty { unloadCursor %= entries.count }
    }

    private func policies() -> [NodeParent: SleepPolicy] {
        // Read settings every pass, independently of treeRevision, just as for
        // sleepMode. Model edits take effect on the next tick without a restart.
        let profiles = Dictionary(uniqueKeysWithValues: model.profiles.map { profile in
            let cache: ProfileRules
            if let existing = profileRules[profile.id] { cache = existing }
            else {
                cache = ProfileRules(); profileRules[profile.id] = cache
            }
            return (profile.id, SleepPolicy(mode: effectiveMode(profile.settings.sleepMode),
                                           keepAliveRules: cache.current(profile.settings.keepAliveSites)))
        })
        var result: [NodeParent: SleepPolicy] = [:]
        for (id, policy) in profiles { result[.favorites(id)] = policy }
        for space in model.spaces {
            let policy = profiles[space.profileID] ?? SleepPolicy()
            result[.spacePinned(space.id)] = policy; result[.spaceToday(space.id)] = policy
        }
        return result
    }

    private func refreshUnloadHandlers() {
        guard !entries.isEmpty else { return }
        var inspected = 0, queried = 0
        while inspected < entries.count && queried < maximumUnloadQueriesPerPass {
            let entry = entries[unloadCursor], tab = entry.tab
            unloadCursor = (unloadCursor + 1) % entries.count; inspected += 1
            guard entry.state.hasContent, tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { continue }
            entry.state.unload = engine.hasUnloadHandlers(tabID: tab.id); queried += 1
        }
    }

    private func hiddenSince(_ tab: Tab, at date: Date) -> Date {
        // Persisted selection time is only a fallback for tabs never shown this session.
        hiddenSince(tab, state: state(tab.id), at: date)
    }

    private func hiddenSince(_ tab: Tab, state: State, at date: Date) -> Date {
        state.hiddenAt ?? (state.everVisible ? date : tab.lastActiveAt)
    }

    private func gate(_ tab: Tab, policy: SleepPolicy, visible: Set<ItemID>, at date: Date,
                      discard: Bool, critical: Bool = false) -> SleepPolicy.Gate? {
        let state = state(tab.id)
        return policy.blockingReason(tab: tab, visible: visible, now: date,
            lastAudibleAt: state.lastAudibleAt, lastCommitAt: state.lastCommitAt,
            downloading: downloading.contains(tab.id), hasUnloadHandlers: state.unload ?? true,
            forDiscard: discard, keepAlive: isKeepAlive(tab, state: state, policy: policy), criticalPressure: critical)
    }

    private func isKeepAlive(_ tab: Tab, state: State, policy: SleepPolicy) -> Bool {
        if state.keepAliveURL != tab.url || state.keepAliveRules !== policy.keepAliveRules {
            state.keepAliveURL = tab.url; state.keepAliveRules = policy.keepAliveRules
            state.keepAlive = policy.keepAliveRules.matches(tab.url)
        }
        return state.keepAlive
    }

    public func tick() async { await runPass(pressure: nil) }

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
        defer { runningPass = false; passCount += 1 }
        var level = pressure
        repeat {
            pendingPressure = nil
            updateEntries()
            let date = now(), policies = policies()
            var visible = visibleTabIDs()
            let sleepingAtStart: Set<ItemID> = level == .critical ? Set(entries.compactMap {
                $0.state.hasContent && $0.tab.live.sleepPhase == .sleeping ? $0.tab.id : nil
            }) : []
            for id in knownVisible.subtracting(visible) { hide(id, at: date) }
            var restoredContent = false
            for id in visible.subtracting(knownVisible) {
                if !state(id).hasContent { restoredContent = true }
                await makeVisible(id)
            }
            // Restoration can suspend while the app changes windows or surfaces.
            if restoredContent { visible = visibleTabIDs() }
            refreshUnloadHandlers()
            // Decide synchronously before any discard awaits: a newly discarded tab
            // can never become a destroy candidate in this pass, even under pressure.
            var actions: [(Tab, SleepPolicy, SleepPolicy.Action)] = []
            for (owner, entries) in groups {
                let policy = owner.flatMap { policies[$0] } ?? SleepPolicy()
                for entry in entries {
                    let tab = entry.tab, state = entry.state
                    guard state.hasContent, !state.busy else { continue }
                    let phase = tab.live.sleepPhase
                    let action: SleepPolicy.Action
                    if level != nil {
                        let hiddenLongEnough = date.timeIntervalSince(hiddenSince(tab, state: state, at: date)) >= 30
                        if phase == .frozen, hiddenLongEnough { action = .discard }
                        // Notification permission protects from proactive sleep only (Chrome parity,
                        // page-platform §4.5.6): critical pressure freezes and discards such a page.
                        else if level == .critical, phase == .live, tab.live.notificationsAllowed, hiddenLongEnough { action = .discard }
                        else if level == .critical, phase == .sleeping, sleepingAtStart.contains(tab.id) { action = .destroy }
                        else { action = .none }
                    } else {
                        action = policy.timedAction(phase: phase, hiddenAt: hiddenSince(tab, state: state, at: date),
                                                    sleptAt: state.sleptAt, now: date)
                    }
                    // Engine events own precise audio/commit timestamps. Sampling is
                    // a conservative fallback for live tabs and due phase transitions.
                    if phase == .live || action != .none { refresh(tab, state: state, at: date) }
                    guard action != .none,
                          action != .discard || state.retryAfter.map({ date >= $0 }) ?? true,
                          policy.blockingReason(tab: tab, visible: visible, now: date,
                            lastAudibleAt: state.lastAudibleAt, lastCommitAt: state.lastCommitAt,
                            downloading: downloading.contains(tab.id), hasUnloadHandlers: state.unload ?? true,
                            forDiscard: action == .discard, keepAlive: isKeepAlive(tab, state: state, policy: policy),
                            criticalPressure: level == .critical) == nil else { continue }
                    actions.append((tab, policy, action))
                }
            }
            actions.sort { hiddenSince($0.0, at: date) < hiddenSince($1.0, at: date) }
            var currentVisible = visible
            let critical = level == .critical
            for (tab, policy, action) in actions {
                guard model.tab(id: tab.id) === tab, liveContent.contains(tab.id),
                      gate(tab, policy: policy, visible: currentVisible, at: now(), discard: action == .discard, critical: critical) == nil else { continue }
                switch action {
                case .none: break
                case .freeze:
                    if tab.live.sleepPhase == .live, engine.freeze(tabID: tab.id) { tab.live.sleepPhase = .frozen }
                case .discard:
                    if critical, tab.live.sleepPhase == .live, engine.freeze(tabID: tab.id) { tab.live.sleepPhase = .frozen }
                    if tab.live.sleepPhase == .frozen { await discard(tab, policy: policy, visible: currentVisible, critical: critical) }
                    // Async boundaries need fresh visibility for the remaining actions.
                    currentVisible = visibleTabIDs()
                case .destroy:
                    if tab.live.sleepPhase == .sleeping { destroy(tab) }
                }
            }
            if level == .critical { engine.handleCriticalPressure() }
            level = pendingPressure
        } while level != nil
    }

    public func debugSleepNow(tabID: ItemID) async {
        updateEntries()
        guard let tab = model.tab(id: tabID), liveContent.contains(tabID),
              tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { return }
        let date = now(), visible = visibleTabIDs(), policies = policies()
        let owner = entries.first { $0.tab.id == tabID }?.owner
        let policy = owner.flatMap { policies[$0] } ?? SleepPolicy()
        let state = state(tabID)
        refresh(tab, state: state, at: date)
        state.unload = engine.hasUnloadHandlers(tabID: tabID)
        guard gate(tab, policy: policy, visible: visible, at: date, discard: true) == nil,
              state.retryAfter.map({ date >= $0 }) ?? true else { return }
        if tab.live.sleepPhase == .live {
            guard engine.freeze(tabID: tabID) else { return }
            tab.live.sleepPhase = .frozen
        }
        await discard(tab, policy: policy, visible: visible)
    }

    private func failedDiscard(_ id: ItemID) {
        let state = state(id)
        let delay = min(1800, (state.retryDelay ?? 15) * 2)
        state.retryDelay = delay; state.retryAfter = now().addingTimeInterval(delay)
        onLog?("sleep-discard-backoff \(id.rawValue.uuidString.prefix(8)) seconds=\(Int(delay))")
    }

    private func discard(_ tab: Tab, policy: SleepPolicy, visible: Set<ItemID>, critical: Bool = false) async {
        let id = tab.id
        let state = state(id)
        guard !state.busy, gate(tab, policy: policy, visible: visible, at: now(), discard: true, critical: critical) == nil else { return }
        state.busy = true
        defer { state.busy = false }
        guard var envelope = engine.captureHistory(tabID: id) else {
            onLog?("sleep-capture-failed \(id.rawValue.uuidString.prefix(8))"); failedDiscard(id); return
        }
        envelope.chromiumTag = chromiumTag
        do { try await store.save(tabID: id, envelope: envelope) }
        catch { onLog?("sleep-save-failed \(id.rawValue.uuidString.prefix(8))"); failedDiscard(id); return }
        // A permanent purge can race an in-flight save. Remove its row again.
        if purged.contains(id) { store.deleteSleepHistory(tabID: id); return }
        guard model.tab(id: id) === tab, liveContent.contains(id), tab.live.sleepPhase == .frozen,
              gate(tab, policy: policy, visible: visibleTabIDs(), at: now(), discard: true, critical: critical) == nil else { return }
        let discarded = await engine.discard(tabID: id)
        guard model.tab(id: id) === tab, liveContent.contains(id) else { return }
        let visibleNow = visibleTabIDs().contains(id)
        if visibleNow || isKeepAlive(tab, state: state, policy: policy) {
            // A background navigation can reach a keep-alive site while discard
            // awaits the engine. Recover its content without claiming visibility.
            if discarded {
                engine.setVisible(tabID: id, visible: true)
                if !visibleNow { engine.setVisible(tabID: id, visible: false) }
            }
            tab.live.sleepPhase = .live; state.sleptAt = nil; tabUserInteracted(id); return
        }
        guard discarded, engine.wasDiscarded(tabID: id) else { failedDiscard(id); return }
        tab.live.sleepPhase = .sleeping; state.sleptAt = now(); tab.live.isLoading = false
        tabUserInteracted(id); setNavigation(tab, envelope)
    }

    private func setNavigation(_ tab: Tab, _ envelope: SleepHistoryEnvelope) {
        tab.live.canGoBack = envelope.currentIndex > 0
        tab.live.canGoForward = envelope.currentIndex < envelope.entryCount - 1
    }

    private func destroy(_ tab: Tab) {
        guard liveContent.remove(tab.id) != nil else { return }
        state(tab.id).hasContent = false
        engine.destroyContent(tabID: tab.id); shown.remove(tab.id)
    }

    /// The caller must await this before completing quit. Save/flush errors throw
    /// so the app can keep the session open and report the failure.
    public func captureAllForQuit() async throws {
        let start = now()
        for id in liveContent {
            guard let tab = model.tab(id: id), tab.live.sleepPhase == .live || tab.live.sleepPhase == .frozen else { continue }
            if var envelope = engine.captureHistory(tabID: id) {
                envelope.chromiumTag = chromiumTag
                try await store.save(tabID: id, envelope: envelope)
                if purged.contains(id) { store.deleteSleepHistory(tabID: id) }
            } else { onLog?("sleep-capture-failed \(id.rawValue.uuidString.prefix(8))") }
        }
        try await store.flush()
        onLog?("sleep-quit-capture ms=\(now().timeIntervalSince(start) * 1000)")
    }
}
