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

    private static func structuralVisibility(_ check: (Bool, String) -> Void) async throws {
        for dissolve in [false, true] {
            let p = Profile(), a = tab("structural-a", age: 13*3600), b = tab("structural-b", age: 13*3600), pin = tab("pin")
            let split = Split(panes: [a,b], focusedPaneID: a.id)
            let space = Space(profileID: p.id, pinned: [.tab(pin)], today: [.split(split)])
            let window = BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: split.id])
            let s = try Scene(profiles: [p], spaces: [space], windows: [window]); defer { s.close() }
            let panes = [s.model.tab(id: a.id)!, s.model.tab(id: b.id)!]
            s.start(); s.openWindows(); s.undo.removeAllActions()
            let generation = s.model.undoGeneration, before = Date(), c = s.controllers[0]
            c.splitController.close(a.id, separate: !dissolve, option: dissolve)
            let structuralActions = s.model.undoGeneration - generation
            s.undo.disableUndoRegistration()
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: pin.id, space: space.id))
            s.undo.enableUndoRegistration()
            let after = Date()
            try await settle()
            let fresh = panes.allSatisfy { $0.lastActiveAt >= before && $0.lastActiveAt <= after }
            let deadlines = panes.map { $0.lastActiveAt.addingTimeInterval(12*3600) }
            let nextMatches = s.scheduler.state.nextExpiry == deadlines.min()
            let noExtraUndo = s.model.undoGeneration == generation + structuralActions && structuralActions == (dissolve ? 2 : 1)
            s.clock.value = Date(); s.scheduler.fire(reason: .automation)
            let rows = await s.rows()
            let survived = panes.allSatisfy { s.model.tab(id: $0.id) != nil } && rows.isEmpty
            let name = dissolve ? "AA-visible-dissolve" : "AA-visible-takePane"
            print("\(name) receipt freshBoth=\(fresh) nextMatches=\(nextMatches) survived=\(survived) noExtraUndo=\(noExtraUndo) rows=\(rows.count)")
            check(fresh && nextMatches && survived && noExtraUndo,
                  "\(name) previously shown panes start fresh inactivity after structural separation")
        }
        for moveFolder in [false, true] {
            let p = Profile(), a = tab("moved-visible", age: 13*3600), pin = tab("pin")
            let folder = Folder(children: [.tab(a)])
            let source = Space(profileID: p.id, pinned: [.tab(pin)], today: [moveFolder ? .folder(folder) : .tab(a)])
            let target = Space(profileID: p.id)
            let window = BrowserWindowState(focusedSpaceID: source.id, selectedNodeBySpace: [source.id: a.id])
            let s = try Scene(profiles: [p], spaces: [source,target], windows: [window]); defer { s.close() }
            let loaded = s.model.tab(id: a.id)!
            s.start(); s.openWindows(); s.undo.removeAllActions()
            let before = Date(), generation = s.model.undoGeneration
            let moved = s.model.moveNode(id: moveFolder ? folder.id : a.id, to: .spaceToday(target.id), at: 0)
            let after = Date(); try await settle()
            let fresh = loaded.lastActiveAt >= before && loaded.lastActiveAt <= after
            let deadline = s.scheduler.state.nextExpiry == loaded.lastActiveAt.addingTimeInterval(12*3600)
            let noExtraUndo = s.model.undoGeneration == generation + 1
            s.clock.value = Date(); s.scheduler.fire(reason: .automation)
            let rows = await s.rows()
            s.undo.undo(); let oneUndo = !s.undo.canUndo
            loaded.lastActiveAt = Date().addingTimeInterval(-13*3600)
            let beforeRedo = Date(); s.undo.redo(); let afterRedo = Date(); try await settle()
            let redoFresh = loaded.lastActiveAt >= beforeRedo && loaded.lastActiveAt <= afterRedo
                && s.scheduler.state.nextExpiry == loaded.lastActiveAt.addingTimeInterval(12*3600)
            let name = moveFolder ? "AA-visible-move-folder" : "AA-visible-move-space"
            print("\(name) receipt moved=\(moved) fresh=\(fresh) deadline=\(deadline) redoFresh=\(redoFresh) rows=\(rows.count) noExtraUndo=\(noExtraUndo && oneUndo)")
            check(moved && fresh && deadline && redoFresh && noExtraUndo && oneUndo && rows.isEmpty && s.model.tab(id: a.id) != nil,
                  "\(name) selected tab or ancestor moved out of the shown Space gets a fresh deadline, including redo")
        }
        for undoCreation in [true, false] {
            let p = Profile(), a = tab("undo-pane-a"), b = tab("undo-pane-b"), pin = tab("pin")
            let space = Space(profileID: p.id, pinned: [.tab(pin)], today: [.tab(a), .tab(b)])
            let s = try Scene(profiles: [p], spaces: [space]); defer { s.close() }
            s.start(); s.openWindows(); s.undo.removeAllActions()
            let split = s.model.makeSplit(tabIDs: [a.id,b.id])!, c = s.controllers[0]
            s.undo.disableUndoRegistration()
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: split.id, space: space.id))
            s.undo.enableUndoRegistration()
            let panes = split.panes
            if !undoCreation {
                s.undo.removeAllActions(); s.model.unsplit(splitID: split.id); s.undo.undo()
            }
            for tab in panes { tab.lastActiveAt = Date().addingTimeInterval(-13*3600) }
            let before = Date()
            if undoCreation { s.undo.undo() } else { s.undo.redo() }
            s.undo.disableUndoRegistration()
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: pin.id, space: space.id))
            s.undo.enableUndoRegistration()
            let after = Date(); try await settle()
            let fresh = panes.allSatisfy { $0.lastActiveAt >= before && $0.lastActiveAt <= after }
            let deadline = s.scheduler.state.nextExpiry == panes.map { $0.lastActiveAt.addingTimeInterval(12*3600) }.min()
            s.clock.value = Date(); s.scheduler.fire(reason: .automation)
            let rows = await s.rows()
            check(fresh && deadline && rows.isEmpty && panes.allSatisfy { s.model.tab(id: $0.id) != nil },
                  undoCreation ? "AA-visible-undo-split undoing split creation stamps all formerly shown panes" : "AA-visible-redo-dissolve redoing dissolution stamps formerly shown panes")
        }
        for deleteSpace in [false, true] {
            let p = Profile(), a = tab("deleted-visible", age: 13*3600)
            let source = Space(profileID: p.id, today: [.tab(a)]), fallback = Space(profileID: p.id)
            let window = BrowserWindowState(focusedSpaceID: source.id, selectedNodeBySpace: [source.id: a.id])
            let s = try Scene(profiles: [p], spaces: [source,fallback], windows: [window]); defer { s.close() }
            s.start(); s.openWindows(); s.undo.removeAllActions()
            let loaded = s.model.tab(id: a.id)!, before = Date(), generation = s.model.undoGeneration
            if deleteSpace { s.model.deleteSpace(id: source.id) } else { _ = s.model.archiveNodes(ids: [a.id]) }
            let after = Date()
            let fresh = loaded.lastActiveAt >= before && loaded.lastActiveAt <= after
            let oneAction = s.model.undoGeneration == generation + 1
            s.undo.undo(); let oneUndo = !s.undo.canUndo
            loaded.lastActiveAt = Date().addingTimeInterval(-13*3600)
            let beforeRedo = Date(); s.undo.redo(); let afterRedo = Date()
            let redoFresh = loaded.lastActiveAt >= beforeRedo && loaded.lastActiveAt <= afterRedo
            let rows = await s.rows()
            check(fresh && redoFresh && oneAction && oneUndo && rows.count == 1 && rows[0].id == a.id && rows[0].reason == .closed,
                  deleteSpace ? "AA-visible-delete-space Space deletion and redo stamp removed shown tabs" : "AA-visible-archive archiving and redo stamp removed shown tabs")
        }
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        try await structuralVisibility(check)
        do {
            let p = Profile(), visible = tab("visible", age: 13*3600), pin = tab("pin")
            let space = Space(profileID: p.id, pinned: [.tab(pin)], today: [.tab(visible)])
            let window = BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: visible.id])
            let s = try Scene(profiles: [p], spaces: [space], windows: [window]); defer { s.close() }
            let loaded = s.model.tab(id: visible.id)!
            s.start(); s.openWindows()
            let count = s.scheduler.state.sweepCount
            try await Task.sleep(for: .milliseconds(200))
            let rows = await s.rows()
            let protected = s.model.tab(id: visible.id) != nil && rows.isEmpty
                && s.model.nextAutoArchiveExpiry() == nil && !s.scheduler.state.timerArmed
                && s.scheduler.state.sweepCount == count
            s.undo.removeAllActions()
            let before = Date()
            _ = s.controllers[0].sidebar(s.controllers[0].sidebar, didRequest: .select(nodeID: pin.id, space: space.id))
            let after = Date()
            try await settle()
            let fresh = loaded.lastActiveAt >= before && loaded.lastActiveAt <= after
                && s.scheduler.state.nextExpiry == loaded.lastActiveAt.addingTimeInterval(12*3600)
            s.undo.undo()
            let oneUndo = s.model.windows[0].selectedNodeBySpace[space.id] == visible.id && !s.undo.canUndo
            print("AA-visible receipt protected=\(protected) freshDeadline=\(fresh) oneUndo=\(oneUndo) sweepCount=\(count)->\(s.scheduler.state.sweepCount)")
            check(protected && fresh && oneUndo, "AA-visible selected Today survives; no busy loop; deselection starts threshold in one undo step")
        }
        do {
            let p = Profile(), a = tab("split-visible-a", age: 13*3600), b = tab("split-visible-b", age: 14*3600), pin = tab("pin")
            let split = Split(panes: [a,b]), space = Space(profileID: p.id, pinned: [.tab(pin)], today: [.split(split)])
            let states = (0..<2).map { _ in BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: [space.id: split.id]) }
            let s = try Scene(profiles: [p], spaces: [space], windows: states); defer { s.close() }
            let panes = s.model.node(id: split.id)!.split!.panes, dates = panes.map(\.lastActiveAt)
            s.start(); s.openWindows()
            let initiallyProtected = s.model.nextAutoArchiveExpiry() == nil && s.model.node(id: split.id)?.split?.panes.count == 2
            _ = s.controllers[0].sidebar(s.controllers[0].sidebar, didRequest: .select(nodeID: pin.id, space: space.id))
            try await settle()
            let stillShown = panes.map(\.lastActiveAt) == dates && s.model.nextAutoArchiveExpiry() == nil
            let beforeClose = Date(), second = s.controllers.removeLast()
            s.today.detach(windowID: second.windowID); s.model.closeWindow(windowID: second.windowID)
            second.container.closeAll(); second.window?.close()
            let afterClose = Date(); try await settle()
            let closed = panes.allSatisfy { $0.lastActiveAt >= beforeClose && $0.lastActiveAt <= afterClose }
                && s.scheduler.state.nextExpiry == panes[0].lastActiveAt.addingTimeInterval(12*3600)
            let controller = s.controllers[0], windowID = controller.windowID
            _ = controller.sidebar(controller.sidebar, didRequest: .select(nodeID: split.id, space: space.id))
            s.undo.removeAllActions()
            let beforeRetain = Date()
            s.model.setWindowContentVisible(windowID: windowID, visible: false)
            let afterRetain = Date(); try await settle()
            let retained = !s.model.windows[0].isShowingContent && !s.undo.canUndo && s.scheduler.state.timerArmed
                && panes.allSatisfy { $0.lastActiveAt >= beforeRetain && $0.lastActiveAt <= afterRetain }
            try s.snapshot.saveNow(model: s.model)
            let restoredShows = try s.snapshot.load()!.windows[0].isShowingContent
            s.model.setWindowContentVisible(windowID: windowID, visible: true); try await settle()
            let reopened = s.model.nextAutoArchiveExpiry() == nil && !s.scheduler.state.timerArmed && !s.undo.canUndo
            let other = s.model.createSpace(title: "Other", profileID: p.id)
            _ = s.model.newTab(in: other.id, url: URL(string: "https://other.example.com")!)
            let beforeSwitch = Date()
            _ = controller.sidebar(controller.sidebar, didRequest: .switchSpace(other.id))
            let afterSwitch = Date(); try await settle()
            let switched = panes.allSatisfy { $0.lastActiveAt >= beforeSwitch && $0.lastActiveAt <= afterSwitch }
            let rows = await s.rows()
            check(initiallyProtected && stillShown && closed && retained && restoredShows && reopened && switched && rows.isEmpty,
                  "AA-visible-split all panes and windows; last deselection, Space switch, close and reopen")
        }
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
            // Snapshots store Unix-seconds Doubles. A source Date can move one
            // reference-time ULP on reload. Exercise both rounding directions
            // and an exact value; expiry boundaries must use the loaded activity.
            let referenceSecond = Date().timeIntervalSinceReferenceDate.rounded(.down)
            let phases = [("roundsDown", referenceSecond.nextUp), ("exact", referenceSecond), ("roundsUp", referenceSecond.nextDown)]
            var phaseResults: [Bool] = []
            func receipt(_ kind: String, _ report: [String: Any]) throws {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                // One short record per Profile, on stderr, so CLI failure output
                // cannot splice itself into a buffered multi-Profile JSON line.
                FileHandle.standardError.write(Data(("AA2 \(kind) receipt " + String(decoding: data, as: UTF8.self) + "\n").utf8))
            }
            for (phase, reference) in phases {
                let sourceBase = Date(timeIntervalSinceReferenceDate: reference)
                let profiles = AutoArchiveInterval.allCases.enumerated().map { i, interval in
                    Profile(name: interval.rawValue, settings: ProfileSettings(autoArchiveAfter: interval), dataDirectoryName: "Profile\(i)")
                }
                let spaces = profiles.map { Space(profileID: $0.id, today: [.tab(tab($0.name, base: sourceBase))]) }
                let s = try Scene(profiles: profiles, spaces: spaces); defer { s.close() }
                s.clock.value = sourceBase; s.start(); s.openWindows()
                let defaultIsTwelveHours = ProfileSettings().autoArchiveAfter == .twelveHours
                var profileResults: [Bool] = [], receipts: [[String: Any]] = []
                func schedulerReceipt() -> [String: Any] {
                    let state = s.scheduler.state
                    return ["sweepCount": state.sweepCount, "countsByReason": state.countsByReason,
                            "timerArmed": state.timerArmed, "timerGeneration": state.timerGeneration,
                            "lastCount": state.lastCount, "lastReason": state.lastReason?.rawValue ?? "none"]
                }
                for p in s.model.profiles where p.settings.autoArchiveAfter != .never {
                    let interval = p.settings.autoArchiveAfter.seconds!, space = s.model.spaces.first { $0.profileID == p.id }!
                    guard let candidate = space.today.first?.tab else {
                        let rows = await s.rows(p.id)
                        profileResults.append(false)
                        receipts.append(["phase": phase, "interval": p.settings.autoArchiveAfter.rawValue,
                                         "candidateMissingBeforeBoundary": true, "rowsCount": rows.count,
                                         "rowsIDs": rows.map { $0.id.description }, "rowsProfiles": rows.map { $0.profileID?.description ?? "none" },
                                         "scheduler": schedulerReceipt()])
                        continue
                    }
                    let id = candidate.id, activity = candidate.lastActiveAt
                    let boundary = activity.addingTimeInterval(interval), cutoff = boundary.addingTimeInterval(-interval)
                    let stateBefore = schedulerReceipt()
                    s.clock.value = boundary; s.scheduler.fire(reason: .automation)
                    let keptAtBoundary = s.model.tab(id: id) != nil
                    s.clock.value = boundary.addingTimeInterval(0.001); s.scheduler.fire(reason: .automation)
                    let archivedAfterMargin = s.model.tab(id: id) == nil
                    let stateBeforeRead = schedulerReceipt()
                    let rows = await s.rows(p.id)
                    let oneRow = rows.count == 1, correctID = rows.first?.id == id, correctProfile = rows.first?.profileID == p.id
                    profileResults.append(keptAtBoundary && archivedAfterMargin && oneRow && correctID && correctProfile)
                    receipts.append(["phase": phase, "interval": p.settings.autoArchiveAfter.rawValue, "keptAtBoundary": keptAtBoundary,
                                     "archivedAfterPlus001": archivedAfterMargin, "rowsCount": rows.count,
                                     "rowsIDMatches": correctID, "rowsProfileMatches": correctProfile,
                                     "expectedID": id.description, "expectedProfile": p.id.description,
                                     "rowsIDs": rows.map { $0.id.description }, "rowsProfiles": rows.map { $0.profileID?.description ?? "none" },
                                     "sourceBaseReferenceSeconds": sourceBase.timeIntervalSinceReferenceDate,
                                     "activityReferenceSeconds": activity.timeIntervalSinceReferenceDate,
                                     "cutoffReferenceSeconds": cutoff.timeIntervalSinceReferenceDate,
                                     "activityMinusSource": activity.timeIntervalSince(sourceBase), "activityMinusCutoff": activity.timeIntervalSince(cutoff),
                                     "sourceBaseBits": String(sourceBase.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
                                     "activityBits": String(activity.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
                                     "schedulerBefore": stateBefore, "schedulerBeforeRead": stateBeforeRead,
                                     "schedulerAfterRead": schedulerReceipt(),
                                     "shown": s.model.windows.contains { $0.isShowingContent && $0.selectedNodeBySpace[$0.focusedSpaceID] == id }])
                }
                s.clock.value = sourceBase.addingTimeInterval(31*86400); s.scheduler.fire(reason: .automation)
                let never = s.model.profiles.first { $0.settings.autoArchiveAfter == .never }!
                let neverRows = await s.rows(never.id), neverTodayCount = s.model.spaces.first { $0.profileID == never.id }!.today.count
                let timerArmed = s.scheduler.state.timerArmed
                let ok = defaultIsTwelveHours && profileResults.allSatisfy { $0 } && neverRows.isEmpty && neverTodayCount == 1 && !timerArmed
                phaseResults.append(ok)
                if !ok {
                    for report in receipts { try receipt("profile", report) }
                    try receipt("summary", ["phase": phase, "defaultTwelveHours": defaultIsTwelveHours,
                        "order": s.model.profiles.map { $0.settings.autoArchiveAfter.rawValue }, "neverRowsCount": neverRows.count,
                        "neverRowsIDs": neverRows.map { $0.id.description }, "neverTodayCount": neverTodayCount,
                        "timerArmed": timerArmed, "scheduler": schedulerReceipt()])
                }
            }
            check(phaseResults.allSatisfy { $0 }, "AA2_profile_thresholds_and_never")
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
            let space = s.model.spaces[0], tab = space.today[0].tab!, control = space.pinned[0].id
            let c = s.controllers[0]
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: tab.id, space: space.id)); try await settle()
            let selected = s.scheduler.state.nextExpiry == nil && !s.scheduler.state.timerArmed
            _ = c.sidebar(c.sidebar, didRequest: .pin(tabID: tab.id)); try await settle()
            let pinned = !s.scheduler.state.timerArmed
            s.model.unpinTab(id: tab.id)
            _ = c.sidebar(c.sidebar, didRequest: .select(nodeID: control, space: space.id)); try await settle()
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
    func deleteProfileData(profileID: ProfileID, dataDirectoryName: String) async -> String? { "unavailable" }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String? { "unavailable" }
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String? { "unavailable" }
    func openProfileSubpage(profileID: ProfileID, page: ProfilePage) {}
    func openPreviewsSettings() {}
    func keyBindingsDidChange(store: KeyBindingStore) {}
    func openEssentialShortcuts() {}
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
