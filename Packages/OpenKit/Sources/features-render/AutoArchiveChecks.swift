import AppKit
import OpenDesign
import OpenFeatures
import OpenModel
import OpenSidebar
import OpenStore
import OpenSettings
import OpenCommands

/// Whole flows through saved snapshots, the production scheduler, real windows,
/// Settings actions, and Profile SQLite archives. Only page hosts are fake.
@MainActor
enum AutoArchiveChecks {
    @MainActor private final class Clock {
        var value = Date()
        var advancing = false
        var realStart = Date()
        func now() -> Date { advancing ? value.addingTimeInterval(Date().timeIntervalSince(realStart)) : value }
    }
    @MainActor private final class Scene {
        let root: URL, defaults: UserDefaults, domain: String
        let model: BrowserModel, snapshot: SnapshotStore, sink: ProfileArchiveSink
        let clock = Clock()
        let today: TodayAutoArchiveController, scheduler: ExpirySweeper
        let undo = UndoManager()
        var controllers: [BrowserWindowController] = []
        lazy var settings = SettingsViewModel(model: model, actions: SettingsObserver(), defaults: defaults, root: root, snapshot: snapshot)
        var settingsProfile: ProfileID?
        init(profiles: [Profile], spaces: [Space], windows: [BrowserWindowState]? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("open-autoarchive-\(UUID())")
            domain = "open.autoarchive.\(UUID())"; defaults = UserDefaults(suiteName: domain)!
            defaults.set(false, forKey: "open.general.previewsEnabled")
            snapshot = SnapshotStore(root: root)
            let states = windows ?? [BrowserWindowState(focusedSpaceID: spaces[0].id,
                selectedNodeBySpace: spaces[0].pinned.first.map { [spaces[0].id: $0.id] } ?? [:])]
            try snapshot.saveNow(model: BrowserModel(profiles: profiles, spaces: spaces, windows: states))
            model = try snapshot.load()!
            let loaded = model
            sink = ProfileArchiveSink(directories: ProfileDirectories(root: root)) { id in
                id.flatMap { loaded.profile(id: $0)?.dataDirectoryName } ?? "Default"
            }
            model.archiveSink = sink; undo.groupsByEvent = false; model.undoManager = undo
            today = TodayAutoArchiveController(model: model, preferences: defaults)
            let time = clock, service = today
            scheduler = ExpirySweeper(now: { time.now() }, nextExpiry: { service.nextExpiry(now: $0) }, sweep: { service.sweep(now: $0) })
            today.onScheduleInvalidated = { [weak scheduler] in scheduler?.rearm() }
            today.startObserving()
        }
        func start() { scheduler.start() }
        func openWindows() {
            for state in model.windows where !controllers.contains(where: { $0.windowID == state.id }) {
                let c = BrowserWindowController(model: model, windowID: state.id, factory: FakeWebContentHostFactory(),
                    size: CGSize(width: 1200, height: 800), defaults: defaults, snapshotStore: snapshot)
                c.onSidebarIntent = { [weak self] intent in
                    guard let self else { return nil }
                    switch intent {
                    case .dismissAutoArchiveBanner: self.today.dismissEducation(); self.refresh(); return true
                    case .openProfileSettings(let id): self.today.dismissEducation(); self.settingsProfile = id; self.refresh(); return true
                    default: return nil
                    }
                }
                controllers.append(c); today.attach(context: c.context)
                OffscreenRenderer.settle(c.contentView, runLoop: 0.001)
            }
            today.finishStartupComposition(); refresh()
        }
        func refresh() { for c in controllers { c.sidebar.refreshAutoArchiveBanner(); c.contentView.layoutSubtreeIfNeeded() } }
        func rows(_ id: ProfileID? = nil) async -> [ArchivedTabRecord] { await sink.store(for: id ?? model.profiles[0].id).recent(limit: 1000) }
        func close() {
            scheduler.stop(); today.stopObserving()
            for c in controllers { today.detach(windowID: c.windowID); c.container.closeAll(); c.window?.close() }
            sink.flushAll(); snapshot.flush()
            defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root)
        }
    }
    private static func tab(_ name: String, age: Double = 0, base: Date = Date()) -> Tab {
        Tab(url: URL(string: "https://\(name).example.com")!, title: name, lastActiveAt: base.addingTimeInterval(-age))
    }
    private static func scene(age: Double = 13*3600, interval: AutoArchiveInterval = .twelveHours) throws -> Scene {
        let p = Profile(settings: ProfileSettings(autoArchiveAfter: interval)), pin = tab("pin", age: 99*86400), old = tab("old", age: age)
        p.favorites = [tab("favorite", age: 99*86400)]
        return try Scene(profiles: [p], spaces: [Space(profileID: p.id, pinned: [.tab(pin)], today: [.tab(old)])])
    }
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    static func run(_ check: (Bool, String) -> Void) async throws {
        do {
            let s = try scene(); defer { s.close() }
            let old = s.model.spaces[0].today[0].id, space = s.model.spaces[0], profile = s.model.profiles[0]
            s.start(); s.start(); s.openWindows()
            let rows = await s.rows()
            check(s.model.tab(id: old) == nil && rows.count == 1 && rows[0].id == old && rows[0].reason == .autoArchived
                && rows[0].spaceID == space.id && rows[0].profileID == profile.id && rows[0].archivedAt.timeIntervalSince1970 == s.clock.value.timeIntervalSince1970
                && space.pinned.count == 1 && profile.favorites.count == 1 && s.scheduler.state.countsByReason["launch"] == 1,
                "AA1_launch_archives_real_store")
        }
        do {
            let base = Date(), profiles = AutoArchiveInterval.allCases.enumerated().map { i, interval in
                Profile(name: interval.rawValue, settings: ProfileSettings(autoArchiveAfter: interval), dataDirectoryName: "Profile\(i)")
            }
            let spaces = profiles.map { Space(profileID: $0.id, today: [.tab(tab($0.name, base: base))]) }
            let s = try Scene(profiles: profiles, spaces: spaces); defer { s.close() }
            s.clock.value = base; s.start(); s.openWindows()
            var ok = ProfileSettings().autoArchiveAfter == .twelveHours
            for p in s.model.profiles where p.settings.autoArchiveAfter != .never {
                let interval = p.settings.autoArchiveAfter.seconds!, id = s.model.spaces.first { $0.profileID == p.id }!.today[0].id
                s.clock.value = base.addingTimeInterval(interval); s.scheduler.fire(reason: .automation)
                ok = ok && s.model.tab(id: id) != nil
                s.clock.value = base.addingTimeInterval(interval + 0.001); s.scheduler.fire(reason: .automation)
                let rows = await s.rows(p.id)
                ok = ok && rows.count == 1 && rows[0].id == id && rows[0].profileID == p.id
            }
            s.clock.value = base.addingTimeInterval(31*86400); s.scheduler.fire(reason: .automation)
            let never = s.model.profiles.first { $0.settings.autoArchiveAfter == .never }!
            let neverRows = await s.rows(never.id)
            check(ok && neverRows.isEmpty && s.model.spaces.first { $0.profileID == never.id }!.today.count == 1
                && !s.scheduler.state.timerArmed, "AA2_profile_thresholds_and_never")
        }
        do {
            let p = Profile(), base = Date(), a = tab("pane-a", age: 14*3600), b = tab("pane-b", age: 13*3600), live = tab("live")
            let split = Split(panes: [a,b,live]), nested = Folder(children: [.split(split)]), folder = Folder(children: [.folder(nested)])
            p.favorites = [tab("favorite", age: 15*3600)]
            let s = try Scene(profiles: [p], spaces: [Space(profileID: p.id, pinned: [.tab(tab("pin", age: 15*3600))], today: [.folder(folder), .tab(tab("top", age: 13*3600))])]); defer { s.close() }
            let next = s.model.nextAutoArchiveExpiry(), expected = s.model.tab(id: a.id)!.lastActiveAt.addingTimeInterval(12*3600); s.clock.value = base; s.start(); s.openWindows()
            let rows = await s.rows()
            print("AA3 receipt deadline=\(next == expected) rows=\(rows.count) folder=\(s.model.node(id: folder.id)?.folder != nil) splitGone=\(s.model.node(id: split.id) == nil) live=\(s.model.tab(id: live.id) != nil) splitRows=\(rows.filter { $0.originalLocation == "split:\(split.id)" }.count) undo=\(s.undo.canUndo)")
            check(next == expected && rows.count == 3
                && s.model.node(id: folder.id)?.folder != nil && s.model.node(id: split.id) == nil
                && s.model.tab(id: live.id) != nil && rows.filter { $0.originalLocation == "split:\(split.id)" }.count == 2
                && !s.undo.canUndo && s.model.spaces[0].pinned.count == 1 && s.model.profiles[0].favorites.count == 1,
                "AA3_today_folder_split_deadline")
        }
        do {
            let s = try scene(age: 0); defer { s.close() }
            let old = s.model.spaces[0].today[0].tab!, deadline = old.lastActiveAt.addingTimeInterval(12*3600)
            s.clock.value = deadline.addingTimeInterval(-0.2); s.clock.realStart = Date(); s.clock.advancing = true
            s.start(); s.openWindows(); let armed = s.scheduler.state.armedTimerCount
            try await Task.sleep(for: .milliseconds(350))
            let rows = await s.rows()
            check(armed == 1 && s.model.tab(id: old.id) == nil && rows.count == 1
                && s.scheduler.state.lastReason == .timer && !s.scheduler.state.timerArmed, "AA4_one_timer_then_disarmed")
        }
        do {
            let s = try scene(age: 0); defer { s.close() }; s.start(); s.openWindows()
            s.clock.value = s.clock.value.addingTimeInterval(13*3600)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await settle(); let rows = await s.rows()
            check(rows.count == 1 && s.model.spaces[0].today.isEmpty && s.scheduler.state.countsByReason["wake"] == 1
                && !s.scheduler.state.timerArmed, "AA5_wake_catches_overdue_once")
        }
        do {
            let s = try scene(age: 2*3600); defer { s.close() }; s.start(); s.openWindows()
            let id = s.model.profiles[0].id, original = s.scheduler.state.nextExpiry
            s.settings.profiles.select(id); s.settings.profiles.proposeArchive(.thirtyDays); s.settings.profiles.applyArchive(all: false)
            try await settle(); let extended = s.scheduler.state.nextExpiry! > original! && s.scheduler.state.armedTimerCount == 1
            s.undo.undo(); try await settle(); let undone = s.scheduler.state.nextExpiry == original
            s.settings.profiles.proposeArchive(.never); s.settings.profiles.applyArchive(all: true)
            try await settle(); let never = !s.scheduler.state.timerArmed && !s.model.spaces[0].today.isEmpty
            s.settings.profiles.proposeArchive(.oneHour); s.settings.profiles.applyArchive(all: false)
            try await settle(); let rows = await s.rows()
            check(extended && undone && never && rows.count == 1 && s.model.spaces[0].today.isEmpty, "AA6_setting_change_rearms_and_undo")
        }
        do {
            let s = try scene(age: 2*3600); defer { s.close() }; s.start(); s.openWindows()
            let space = s.model.spaces[0], tab = space.today[0].tab!, previous = s.scheduler.state.nextExpiry!
            let c = s.controllers[0]
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)); try await settle()
            let selected = s.scheduler.state.nextExpiry! > previous
            _ = c.sidebar(c.sidebar, didRequest: .pin(tabID: tab.id)); try await settle()
            let pinned = !s.scheduler.state.timerArmed
            s.model.unpinTab(id: tab.id); try await settle()
            let p2 = s.model.createProfile(name: "Six")!, target = s.model.createSpace(title: "Target", profileID: p2.id)
            var settings = p2.settings; settings.autoArchiveAfter = .sixHours; s.model.updateProfileSettings(id: p2.id, settings: settings)
            _ = s.model.moveNodes(ids: [tab.id], to: .spaceToday(target.id)); try await settle()
            let moved = s.scheduler.state.nextExpiry == tab.lastActiveAt.addingTimeInterval(6*3600)
            s.clock.value = Date().addingTimeInterval(7*3600); s.scheduler.fire(reason: .automation)
            let rows = await s.rows(p2.id)
            s.clock.value = Date()
            if let row = rows.first { _ = s.model.restoreArchivedTab(row) }
            try await settle()
            check(selected && pinned && moved && rows.first?.id == tab.id && s.scheduler.state.timerArmed
                && s.model.tab(id: tab.id) != nil, "AA7_activity_and_moves_rearm")
        }
        do {
            let p = Profile(), q = Profile(name: "Six", settings: ProfileSettings(autoArchiveAfter: .sixHours), dataDirectoryName: "Six"), n = Profile(name: "Never", settings: ProfileSettings(autoArchiveAfter: .never), dataDirectoryName: "Never")
            let spaces = [p,q,n].map { Space(profileID: $0.id, pinned: [.tab(tab("pin"))], today: [.tab(tab("old", age: 13*3600))]) }
            let s = try Scene(profiles: [p,q,n], spaces: spaces, windows: spaces.map { BrowserWindowState(focusedSpaceID: $0.id) }); defer { s.close() }
            s.start(); s.openWindows(); try await settle(); s.refresh()
            let shown = s.controllers[0].sidebar.autoArchiveBanner?.thresholdText == "12 hours" && s.controllers[1].sidebar.autoArchiveBanner?.thresholdText == "6 hours" && s.controllers[2].sidebar.autoArchiveBanner == nil
            let hidden = try scene(age: 0); defer { hidden.close() }
            hidden.start(); hidden.openWindows()
            let unseen = hidden.model.createSpace(title: "Hidden", profileID: hidden.model.profiles[0].id)
            let t = hidden.model.newTab(in: unseen.id, url: URL(string: "https://hidden.example.com")!); t.lastActiveAt = Date().addingTimeInterval(-13*3600)
            hidden.scheduler.fire(reason: .automation)
            let hiddenRows = await hidden.rows()
            for c in hidden.controllers { hidden.today.detach(windowID: c.windowID); c.container.closeAll(); c.window?.close() }
            hidden.controllers = []
            let closed = hidden.model.newTab(in: hidden.model.spaces[0].id, url: URL(string: "https://closed.example.com")!)
            closed.lastActiveAt = Date().addingTimeInterval(-13*3600)
            let closedCount = hidden.scheduler.fire(reason: .automation)
            check(shown && s.today.educationRequested && hiddenRows.count == 1 && closedCount == 1
                && !hidden.today.educationRequested, "AA8_banner_shown_space_and_all_windows")
            s.controllers[0].sidebar.autoArchiveBanner?.dismissButton.performClick(nil); try await settle(); s.refresh()
            let later = s.model.newTab(in: s.model.spaces[0].id, url: URL(string: "https://later.example.com")!)
            later.lastActiveAt = Date().addingTimeInterval(-13*3600)
            let laterCount = s.scheduler.fire(reason: .automation)
            let persisted = UserDefaults(suiteName: s.domain)!.bool(forKey: "open.sidebar.autoArchiveBannerDismissed")
            // Recompose actual controllers against the same preference domain.
            for c in s.controllers { s.today.detach(windowID: c.windowID); c.container.closeAll(); c.window?.close() }
            s.controllers = []; s.openWindows()
            check(persisted && laterCount == 1 && !s.today.educationRequested && s.controllers.allSatisfy { $0.sidebar.autoArchiveBanner == nil }, "AA9_banner_once_got_it")
        }
        do {
            let s = try scene(); defer { s.close() }; s.start()
            let beforeAttach = s.today.educationRequested; s.openWindows()
            let banner = s.controllers[0].sidebar.autoArchiveBanner
            if let banner { _ = banner.textView(banner.messageView, clickedOnLink: "open-profile-settings", at: (banner.message as NSString).range(of: "Settings").location) }
            check(beforeAttach && banner != nil && s.settingsProfile == s.model.profiles[0].id
                && !s.today.educationRequested && s.controllers[0].sidebar.autoArchiveBanner == nil,
                "AA10_banner_settings_link_and_launch_attach")
        }
        do {
            let s = try scene(age: 0); defer { s.close() }; s.start(); s.openWindows()
            let t = s.model.spaces[0].today[0].tab!
            s.clock.value = t.lastActiveAt.addingTimeInterval(12*3600 - 0.1); s.clock.realStart = Date(); s.clock.advancing = true
            s.scheduler.rearm(); t.lastActiveAt = t.lastActiveAt.addingTimeInterval(-1)
            let count = s.scheduler.state.sweepCount
            s.today.stopObserving(); s.scheduler.stop()
            try await Task.sleep(for: .milliseconds(200)); NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await settle(); let rows = await s.rows()
            check(s.scheduler.state.sweepCount == count && !s.scheduler.state.timerArmed && rows.isEmpty
                && s.model.tab(id: t.id) != nil, "AA11_stop_cancels_pending_work")
        }
        do {
            let s = try scene(age: 0, interval: .never); defer { s.close() }; s.start(); s.openWindows()
            let count = s.scheduler.state.sweepCount
            try await Task.sleep(for: .milliseconds(300)); let rows = await s.rows()
            let never = !s.scheduler.state.timerArmed && rows.isEmpty && s.scheduler.state.sweepCount == count
            s.settings.profiles.proposeArchive(.thirtyDays); s.settings.profiles.applyArchive(all: true)
            try await settle(); let farCount = s.scheduler.state.sweepCount
            try await Task.sleep(for: .milliseconds(300))
            check(never && s.scheduler.state.armedTimerCount == 1 && s.scheduler.state.sweepCount == farCount, "AA12_idle_has_no_periodic_sweeps")
        }
    }
}

/// Unrelated external Settings actions are unavailable in this offscreen scene.
/// Archive settings still use the real SettingsViewModel and snapshot writer.
@MainActor private final class SettingsObserver: SettingsActions {
    func setAsDefaultBrowser() -> String? { "unavailable" }
    func isDefaultBrowser() -> Bool { false }
    func checkForUpdates() {}
    func openMoreSettings() {}
    func revealOpenDataFolder() {}
    func copyOpenInfoToPasteboard() {}
    func deleteProfileData(profileID: ProfileID) -> String? { "unavailable" }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String? { "unavailable" }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String? { "unavailable" }
    func openProfileSubpage(profileID: ProfileID, page: ProfilePage) {}
    func openPreviewsSettings() {}
    func keyBindingsDidChange(store: KeyBindingStore) {}
    func runImport(plan: ImportPlan) async -> ImportOutcome { ImportOutcome(errorText: "unavailable") }
    func setAdBlockEnabled(_ on: Bool, profileID: ProfileID) {}
    func setEnabledBlockLists(_ ids: [String], profileID: ProfileID) {}
    func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID) {}
    func adBlockDebugInfo(profileID: ProfileID) -> String { "" }
    func setTabSleepMode(_ mode: TabSleepMode) {}
    func setApplicationIcon(id: String) {}
    func resetTranslatePrompts(profileID: ProfileID) -> String? { "unavailable" }
    func openURL(_ url: URL, profileID: ProfileID) {}
    func openHelp(topic: String) {}
    func copyText(_ text: String) {}
    func openLibrary() {}
}
