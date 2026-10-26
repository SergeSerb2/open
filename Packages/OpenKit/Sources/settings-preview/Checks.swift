import Foundation
import AppKit
import OpenSettings
import OpenModel
import OpenStore
import OpenCommands
import OpenRouting
import OpenAdBlock
import OpenSuggest
import SQLite3

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw CheckFailure(description: message) } }
@MainActor final class PreviewEnvironment {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let actions: PreviewActions
    let settings: SettingsViewModel
    let library: LibraryViewModel
    let libraryActions: PreviewLibraryActions
    let downloadFeed: PreviewDownloads
    let captures: FileCapturesProvider
    let archives: [ProfileID: ArchiveStore]
    let histories: [ProfileID: HistoryStore]
    let faviconStore: FaviconStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("open-settings-\(UUID().uuidString)")
        suite = "open.settings.preview.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        actions = PreviewActions()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
        settings = SettingsViewModel(model: SyntheticData.model(), actions: actions, defaults: defaults, root: root, snapshot: SnapshotStore(root: root))
        downloadFeed = PreviewDownloads(try SyntheticData.downloads(root: root, profiles: settings.model.profiles))
        captures = try FileCapturesProvider(root: root)
        libraryActions = PreviewLibraryActions(model: settings.model, downloads: downloadFeed, captures: captures, snapshot: settings.snapshot)
        let directories = ProfileDirectories(root: root)
        archives = Dictionary(uniqueKeysWithValues: settings.model.profiles.map { ($0.id, ArchiveStore(fileURL: directories.archiveFileURL(for: $0))) })
        histories = Dictionary(uniqueKeysWithValues: settings.model.profiles.map { ($0.id, HistoryStore(fileURL: directories.historyFileURL(for: $0))) })
        faviconStore = try FaviconStore(databaseURL: root.appendingPathComponent("State/favicons.sqlite3"))
        library = LibraryViewModel(model: settings.model, defaults: defaults, actions: libraryActions, downloads: downloadFeed, captures: captures, archives: archives, histories: histories, snapshot: settings.snapshot, faviconStore: faviconStore)
        let library = self.library
        libraryActions.selectedHistoryProfile = { [weak library] in library?.historyProfileID }
        let settings = self.settings
        settings.model.archiveSink = ProfileArchiveSink(directories: directories, directoryNameFor: { [weak model = settings.model] id in id.flatMap { model?.profile(id: $0)?.dataDirectoryName } ?? "Default" })
        try SyntheticData.seedSettings(root: root, model: settings.model)
        try settings.flush()
        actions.importHandler = { [weak settings] plan in guard let settings else { return ImportOutcome(errorText: "Settings closed.") }; return await applySyntheticImport(plan, settings: settings) }
        try Data("synthetic-settings-v1".utf8).write(to: root.appendingPathComponent("State/settings-preview.marker"))
    }
    func prepareLibrary() async throws {
        try await SyntheticData.seedLibrary(root: root, model: settings.model, archives: archives, histories: histories)
        try captures.reload()
        if let item=captures.captures.first {for domain in ["example.com","example.org","example.net"] {try await faviconStore.ingest(imageData:Data(contentsOf:captures.directory.appendingPathComponent(item.fileName)),iconURL:URL(string:"https://\(domain)/favicon.ico"),for:URL(string:"https://\(domain)/")!,pageSpecific:false)}}
        await library.reloadArchive(); await library.reloadHistory()
        for item in captures.captures { await library.loadThumbnail(item) }
    }
    func prepareAdBlock() async throws {
        var policy = AdBlockDownloadPolicy(); policy.attempts = 1; policy.requestTimeout = 2; policy.resourceTimeout = 3
        let store = try AdBlockStore(root: root, policy: policy)
        for profile in settings.model.profiles { try await store.openProfile(profile.id, scheduleUpdates: false) }
        settings.attach(adBlockStore: store)
        await settings.adBlock?.openSelectedProfile()
    }
    func close() { defaults.removePersistentDomain(forName: suite); defaults.synchronize(); try? FileManager.default.removeItem(at: root) }
    /// Read the real CFPreferences file after synchronize, not a second cached defaults object.
    func diskDefaults() throws -> [String: Any] {
        try require(defaults.synchronize(), "UserDefaults synchronize failed")
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
        let expected = defaults.persistentDomain(forName: suite) ?? [:]
        for _ in 0..<600 {
            defaults.synchronize()
            if let data = try? Data(contentsOf: url),
               let disk = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               NSDictionary(dictionary: disk).isEqual(to: expected) {
                try data.write(to: root.appendingPathComponent("State/preview-defaults.plist"), options: .atomic)
                return disk
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw CheckFailure(description: "CFPreferences did not publish: expected=\(expected) disk=\((try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)) ?? [:])")
    }
    func diskModel() throws -> BrowserModel { try settings.flush(); return try settings.snapshot.load()! }
}

@MainActor func runChecks(only: String?) async throws {
    let names = ["general-toggles", "default-browser", "profile-search", "profile-archive-scope", "profile-downloads", "clear-data", "profile-guards", "links-rules", "links-toggles", "shortcuts-save", "shortcuts-conflict", "advanced-toggles", "adblock", "app-icon", "import-counts", "library-archive", "library-downloads", "library-captures-history", "empty-states", "archive-save-failure", "archive-owner-partial", "adblock-profile-lifecycle", "suggestion-notice", "shortcuts-recording-admission", "archive-paging", "links-save-failure", "adblock-readiness", "settings-caches", "library-folder-archive", "sidebar-defaults"]
    if let only { try require(names.contains(only), "Unknown check \(only)") }
    var passed = 0
    for name in names where only == nil || only == name {
        let env = try PreviewEnvironment(); defer { env.close() }
        let vm = env.settings
        let personal=vm.model.profiles[0].id,work=vm.model.profiles[1].id
        do {
            switch name {
            case "sidebar-defaults":
                try require(!vm.bool("open.sidebar.hideHintShown") && !vm.bool("open.sidebar.autoArchiveBannerDismissed")
                            && vm.bool("open.sidebar.autoArchiveBannerEligible") && !vm.bool("open.advanced.playSoundEffects")
                            && vm.bool("open.general.previewsFolders") && vm.bool("open.general.previewsPages"), "sidebar app defaults differ")
                vm.set(true, for: "open.sidebar.hideHintShown")
                vm.set(true, for: "open.sidebar.autoArchiveBannerDismissed")
                vm.set(false, for: "open.sidebar.autoArchiveBannerEligible")
                vm.set(false, for: "open.general.previewsFolders")
                vm.set(false, for: "open.general.previewsPages")
                let disk = try env.diskDefaults()
                try require(disk["open.sidebar.hideHintShown"] as? Bool == true && disk["open.sidebar.autoArchiveBannerDismissed"] as? Bool == true
                            && disk["open.sidebar.autoArchiveBannerEligible"] as? Bool == false && disk["open.general.previewsFolders"] as? Bool == false
                            && disk["open.general.previewsPages"] as? Bool == false, "sidebar settings did not reach the existing UserDefaults store")
                let reloaded = SettingsViewModel(model: vm.model, actions: env.actions, defaults: UserDefaults(suiteName: env.suite)!, root: env.root, snapshot: vm.snapshot)
                try require(reloaded.bool("open.sidebar.hideHintShown") && !reloaded.bool("open.general.previewsPages"), "sidebar settings did not survive reload")
            case "general-toggles":
                vm.general.warn = false; _ = try env.diskDefaults(); vm.general.updates = false
                let disk = try env.diskDefaults()
                try require(disk["open.general.warnBeforeQuitting"] as? Bool == false && disk["open.general.automaticallyUpdate"] as? Bool == false, "toggles not on disk: \(disk)")
                let dumped = try dumpKeys(root: env.root)
                try require(dumped.contains("default open.general.warnBeforeQuitting = false") && dumped.contains("default open.general.automaticallyUpdate = false"), "dump-keys did not show persisted false values")
                let reloaded = SettingsViewModel(model: vm.model, actions: env.actions, defaults: UserDefaults(suiteName: env.suite)!, root: env.root, snapshot: vm.snapshot)
                try require(!reloaded.general.warn && !reloaded.general.updates && env.actions.log.isEmpty, "relaunch/action mismatch")
            case "default-browser":
                env.actions.defaultError = "Default browser request failed."
                vm.general.setDefault()
                try require(vm.general.errorText == "Default browser request failed." && !vm.general.isDefault, "missing inline default error")
                try require(env.actions.log == ["setAsDefaultBrowser"], "default action missing")
                _ = try env.diskModel()
            case "profile-search":
                vm.profiles.select(work); vm.profiles.searchEngineID = "bing"
                var disk = try env.diskModel()
                try require(disk.profile(id: work)?.settings.searchEngineID == "bing", "Work engine not saved")
                try require(vm.profiles.saveEngine(name: "Example Search", keyword: "ex", template: "https://example.org/?q=%s"), "custom engine refused")
                disk = try env.diskModel()
                let custom = disk.profile(id: work)!.settings.customSearchEngines.last!
                try require(custom.name == "Example Search", "custom engine not on disk")
                vm.profiles.searchEngineID = custom.id; vm.profiles.removeEngine(custom.id)
                disk = try env.diskModel()
                try require(disk.profile(id: work)?.settings.searchEngineID == "google" && disk.profile(id: personal)?.settings.searchEngineID == "google", "custom delete reset or scope failed")
                var engine=OpenModel.SearchEngine(id:"edited-custom",name:"Before",keywords:["docs","reference"],searchURLTemplate:"https://example.com/?q=%s",suggestURLTemplate:"https://example.com/suggest?q=%s",suggestFormat:.googleChrome)
                vm.profiles.update {$0.customSearchEngines.append(engine);$0.searchEngineID=engine.id}
                try require(vm.profiles.saveEngine(id:engine.id,name:"After",keyword:"manual",template:"https://example.org/find?q=%s"), "edit failed")
                engine=try env.diskModel().profile(id:work)!.settings.customSearchEngines.first{$0.id == engine.id}!
                try require(engine.keywords == ["manual","reference"] && engine.suggestURLTemplate == "https://example.com/suggest?q=%s" && engine.suggestFormat == .googleChrome,"editing dropped endpoint/format/aliases")
                let suggest=SuggestEngine(model:vm.model,fetcher:nil)
                var searchURL:URL?
                for await snapshot in suggest.query("example query",context:SuggestContext(mode:.newTab,profileID:work,allowsRemoteSuggestions:false)) {
                    for row in snapshot.suggestions {if row.kind == .search {searchURL=row.url;break}}
                }
                try require(searchURL?.host() == "example.org","real suggestion consumer ignored custom default")
                try require(env.actions.log.isEmpty, "search should be read at use")
            case "profile-archive-scope":
                vm.profiles.proposeArchive(.oneHour); vm.profiles.applyArchive(all: false)
                var disk = try env.diskModel()
                try require(disk.profile(id: personal)?.settings.autoArchiveAfter == .oneHour && disk.profile(id: work)?.settings.autoArchiveAfter == .twentyFourHours, "profile-only archive mismatch")
                vm.profiles.proposeArchive(.sevenDays); vm.profiles.applyArchive(all: true)
                disk = try env.diskModel()
                try require(disk.profiles.allSatisfy { $0.settings.autoArchiveAfter == .sevenDays }, "all-profile archive mismatch")
                let before = try Data(contentsOf: vm.snapshot.fileURL)
                vm.profiles.proposeArchive(.never); vm.profiles.cancelArchive(); try vm.flush()
                try require(try Data(contentsOf: vm.snapshot.fileURL) == before, "cancel wrote a value")
            case "profile-downloads":
                let folder = env.root.appendingPathComponent("Example Downloads").path
                vm.profiles.downloadDirectory = folder; vm.profiles.askWhereToSave = true
                let disk = try env.diskModel()
                try require(disk.profiles[0].settings.downloadDirectory == folder && disk.profiles[0].settings.askWhereToSaveEachFile && !disk.profiles[1].settings.askWhereToSaveEachFile, "download profile scope")
                try require(vm.profiles.nextDownloadSettings().directory == folder && vm.profiles.nextDownloadSettings().ask, "next-download reader")
            case "clear-data":
                vm.profiles.showClear(); vm.profiles.clearKinds = [.history, .cookies]; await vm.profiles.clear()
                try require(env.actions.log.count == 1 && env.actions.log[0].contains("clearBrowsingData \(vm.selectedProfileID)") && env.actions.log[0].contains("kinds=3"), "clear action profile/kinds")
                _ = try env.diskModel()
            case "profile-guards":
                try require(!vm.profiles.delete(id: vm.model.profiles[0].id), "default delete allowed")
                try require(!vm.profiles.delete(id: vm.model.profiles[1].id), "in-use delete allowed")
                try require(vm.profiles.create(name: "Work") == nil && vm.profiles.create(name: "bad/name") == nil, "invalid name allowed")
                let created = vm.profiles.create(name: "Example Test")!
                try require(created.settings.searchEngineID == "google" && vm.profiles.delete(id: created.id), "unused profile lifecycle")
                let disk = try env.diskModel(); try require(disk.profiles.count == 2, "profile deletion not on disk")
            case "links-rules":
                vm.links.addRule(); let newID = vm.links.drafts.last!.id
                vm.links.drafts[vm.links.drafts.count - 1].pattern = "example.com"
                vm.links.drafts[vm.links.drafts.count - 1].destinationKind = .space
                vm.links.drafts[vm.links.drafts.count - 1].spaceID = vm.model.spaces[2].id
                vm.links.moveRule(from: vm.links.drafts.count - 1, to: 0); vm.commitLinks()
                var disk = try env.diskModel(); try require(disk.routingRules.first?.id == newID, "route order not persisted")
                vm.links.testURLString = "example.com/x"; vm.links.runTest()
                try require(vm.links.testDecision?.resolved == .space(spaceID: vm.model.spaces[2].id, profileID: vm.model.profiles[1].id), "test target differs")
                let routeRoot = env.root.appendingPathComponent("route-copy")
                try FileManager.default.createDirectory(at: routeRoot.appendingPathComponent("State"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: vm.snapshot.fileURL, to: routeRoot.appendingPathComponent("State/browser.json"))
                let cli = Process(); cli.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("openkit")
                cli.arguments = ["route", routeRoot.path, "example.com/x", "--external-little-open", "on", "--expect-destination", "space:" + vm.model.spaces[2].id.description]
                let output = Pipe(); cli.standardOutput = output; cli.standardError = output; try cli.run()
                let routeText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); cli.waitUntilExit()
                try require(cli.terminationStatus == 0 && routeText.contains("Office"), "openkit route disagreed: \(routeText)")
                vm.links.drafts[0].pattern = ""; vm.commitLinks(); disk = try env.diskModel()
                try require(vm.links.drafts[0].pattern.isEmpty && disk.routingRules.first?.match == .hostEquals("example.com"), "invalid draft reached disk or disappeared")
                vm.links.drafts[0].pattern = "example.com"; vm.links.spaces.removeAll { $0.id == vm.model.spaces[2].id }; vm.links.runTest()
                try require(vm.links.testDecision?.resolved == .space(spaceID: vm.model.spaces[0].id, profileID: vm.model.profiles[0].id), "stale target did not fall through")
            case "links-toggles":
                vm.links.externalLinksInLittleOpen = false; vm.links.littleOpenHotkeyEnabled = false; vm.commitLinks()
                let disk = try env.diskDefaults()
                try require(disk["open.links.externalInLittleOpen"] as? Bool == false && disk["open.links.littleOpenHotkeyEnabled"] as? Bool == false, "link toggles not persisted")
                try require(env.actions.log == ["keyBindingsDidChange"], "hotkey owner not notified")
                vm.links.testURLString = "https://example.net/a"; vm.links.runTest()
                if case .littleOpen = vm.links.testDecision?.resolved {} else { throw CheckFailure(description: "explicit Little Open route lost with external OFF") }
                _ = try env.diskModel()
            case "shortcuts-save":
                vm.set("site", for: "open.shortcuts.defaultPriority")
                vm.shortcuts.record(.ctrl("t"), for: "new-tab")
                try require(try KeyBindingStore.load(from: vm.shortcuts.fileURL).bindings["new-tab"]?.priority == nil, "new-binding default rewrote an existing priority")
                let freshCommand = "new-window"
                try require(vm.shortcuts.store.bindings[freshCommand] == nil, "priority check must start without a seeded override")
                vm.shortcuts.record(.init(key:"p",modifiers:[.control,.option,.command]),for:freshCommand)
                try require(try KeyBindingStore.load(from:vm.shortcuts.fileURL).bindings[freshCommand]?.priority?.rawValue == vm.string("open.shortcuts.defaultPriority"), "new override ignored picker priority")
                vm.shortcuts.clear("zoom-in"); vm.shortcuts.priority(.siteFirst, for: "new-tab")
                let disk = try KeyBindingStore.load(from: vm.shortcuts.fileURL)
                try require(disk.effectiveShortcuts(for: CommandRegistry.byID["new-tab"]!) == [.ctrl("t")] && disk.bindings["zoom-in"]?.shortcuts == [] && disk.effectivePriority(for: CommandRegistry.byID["new-tab"]!) == .siteFirst, "key binding persistence/effective menu keys")
                try require(env.actions.log.allSatisfy { $0 == "keyBindingsDidChange" } && env.actions.log.count == 4, "menu/hotkey notifications")
            case "shortcuts-conflict":
                vm.shortcuts.record(.init(key: "y", modifiers: [.control, .option, .command]), for: "new-tab")
                let before = try Data(contentsOf: vm.shortcuts.fileURL), beforeCalls = env.actions.log.count
                vm.shortcuts.record(.init(key: "y", modifiers: [.control, .option, .command]), for: "new-window")
                try require(!vm.shortcuts.unexpected.isEmpty && vm.shortcuts.banner.contains("New Tab") && vm.shortcuts.banner.contains("New Window"), "conflict banner lacks owners")
                try require(try Data(contentsOf: vm.shortcuts.fileURL) == before && env.actions.log.count == beforeCalls, "conflicted draft wrote/called action")
                vm.shortcuts.revert(); try require(vm.shortcuts.unexpected.isEmpty, "revert did not restore saved draft")
                vm.shortcuts.resetAll(confirmed: false); try require(vm.shortcuts.confirmsReset, "reset needs confirm")
                vm.shortcuts.resetAll(confirmed: true); try require(try KeyBindingStore.load(from: vm.shortcuts.fileURL).bindings.isEmpty, "reset not saved")
            case "adblock":
                let server = try SyntheticListServer(); defer { server.stop() }
                try await env.prepareAdBlock(); let ad = vm.adBlock!
                ad.setEnabled(false)
                let regional = ad.store.catalog.lists.first { $0.category == "regional" && !$0.urls.isEmpty }!
                await ad.setList(regional.id, enabled: true)
                try require(ad.errorText.isEmpty, "regional list failed: \(ad.errorText)")
                let directory = ad.store.listDirectory(for: vm.selectedProfileID)
                let catalog = try JSONDecoder().decode(AdBlockProfileState.self, from: Data(contentsOf: directory.appendingPathComponent("catalog-state.json")))
                try require(catalog.enabledBlockLists.contains(regional.id), "regional choice not on disk")
                let allowFile = directory.appendingPathComponent("exclusions.json"), before = try Data(contentsOf: allowFile)
                ad.setExcluded("https://x/path", excluded: true)
                try require(!ad.errorText.isEmpty && (try Data(contentsOf: allowFile)) == before, "bad host changed file")
                ad.setExcluded("example.org", excluded: true)
                let domains = try JSONDecoder().decode([String].self, from: Data(contentsOf: allowFile))
                try require(domains.contains("example.org"), "host not on disk")
                let global = try JSONSerialization.jsonObject(with: Data(contentsOf: env.root.appendingPathComponent("adblock-settings.json"))) as! [String: Any]
                try require(global["nativeAdBlockEnabled"] as? Bool == false && env.actions.log.contains { $0.hasPrefix("setAdBlockEnabled false") } && env.actions.log.contains { $0.hasPrefix("setEnabledBlockLists") && $0.contains(regional.id) }, "adblock master/action persistence")
                await ad.reset(); try require(ad.errorText.isEmpty && Set(ad.enabledIDs) == Set(["EasyList", "EasyPrivacy"]), "reset choices failed")
                ad.openInfo(regional); try require(env.actions.log.last?.hasPrefix("openURL host=") == true, "list info bypassed the app action")
            case "advanced-toggles":
                vm.set(true, for: "open.advanced.allowWindowDraggingFromWebTop"); _ = try env.diskDefaults(); vm.advanced.sleepMode = .aggressive
                let disk = try env.diskDefaults()
                try require(disk["open.advanced.allowWindowDraggingFromWebTop"] as? Bool == true && disk["open.advanced.tabSleepMode"] as? String == "aggressive", "advanced persistence")
                try require(env.actions.log == ["setTabSleepMode aggressive"], "sleep action missing")
            case "import-counts":
                let source = env.root.appendingPathComponent("Example Import")
                try SyntheticData.writeImportFixture(to: source)
                let wizard = ImportWizardViewModel(root: vm, directory: source)
                await wizard.refreshCounts()
                try require(wizard.canContinue && wizard.counts["Spaces"] == 2 && wizard.counts["Pinned and Today tabs"] == 3 && wizard.counts["Skipped easels"] == 1 && wizard.counts["Passwords and cookies"] == 2, "fixture counts differ: \(wizard.counts)")
                wizard.review(); await wizard.beginImport()
                try require(wizard.outcome?.errorText == nil && wizard.outcome?.counts["Imported Spaces"] == 2 && env.actions.importPlansWithConsent == 0, "wizard gate: unrequested passwords granted no consent")
                let historyOnly = ImportWizardViewModel(root:vm,directory:source); await historyOnly.refreshCounts(); historyOnly.plan.history=true;historyOnly.review();await historyOnly.beginImport()
                try require(historyOnly.step == .report, "History incorrectly showed the Passwords step")
                var disk = try env.diskModel(); let itemCount = disk.index.count, spaceCount = disk.spaces.count
                let repeatWizard = ImportWizardViewModel(root: vm, directory: source); await repeatWizard.refreshCounts(); repeatWizard.review(); await repeatWizard.beginImport()
                disk = try env.diskModel(); try require(disk.index.count == itemCount && disk.spaces.count == spaceCount && repeatWizard.outcome?.counts["Imported items"] == 0, "re-import added rows")
                let consent = ImportWizardViewModel(root: vm, directory: source); await consent.refreshCounts(); consent.plan.secretsRequested = true; consent.review()
                let calls = env.actions.log.count; await consent.beginImport()
                try require(consent.step == .consent && !consent.plan.secretsConsented && env.actions.log.count == calls, "consent did not gate import")
                consent.finish(); try require(env.actions.importPlansWithConsent == 0 && env.actions.log.count == calls, "wizard gate: cancel called import or granted consent")
                let allowed = ImportWizardViewModel(root: vm, directory: source); await allowed.refreshCounts(); allowed.plan.secretsRequested = true; allowed.review(); await allowed.beginImport(); await allowed.allowAndImportSecrets(); try require(allowed.step == .consent && !allowed.plan.secretsConsented, "count-only capability allowed consent"); await allowed.skipSecrets()
                try require(!allowed.plan.secretsConsented && allowed.outcome?.counts["Password and cookie copies"] == 0 && env.actions.importPlansWithConsent == 0, "wizard gate: count-only continuation must not grant consent")
                let failed = ImportWizardViewModel(root: vm, directory: source); await failed.refreshCounts(); failed.review()
                let before = try Data(contentsOf: vm.snapshot.fileURL)
                try Data("{}".utf8).write(to: source.appendingPathComponent("StorableSidebar.json"))
                await failed.beginImport()
                try require(failed.outcome?.errorText != nil && (try Data(contentsOf: vm.snapshot.fileURL)) == before, "failure changed old snapshot")
            case "library-archive":
                try await env.prepareLibrary(); let library = env.library
                library.query = "Example"; library.archiveSpaceFilter = vm.model.spaces[0].id; await library.reloadArchive()
                try require(library.archiveRows.count == 2 && !library.favicons.isEmpty, "search/Space filter or favicon store")
                let restored = library.archiveRows[0].id; await library.restore(id: restored)
                let disk = try env.diskModel()
                try require(disk.spaces.contains { $0.today.contains { $0.id == restored } } && env.libraryActions.log.contains("restoreArchived \(restored)"), "restore did not reach Today on disk")
                try require(vm.model.undoManager?.canUndo == true, "restore did not register Undo")
                vm.model.undoManager?.undo(); (vm.model.archiveSink as? ProfileArchiveSink)?.flushAll()
                try require(vm.model.tab(id: restored) == nil, "Undo did not return tab to Archive")
                vm.model.undoManager?.redo(); (vm.model.archiveSink as? ProfileArchiveSink)?.flushAll()
                try require(vm.model.tab(id: restored) != nil, "Redo did not restore tab")
                _ = try env.diskModel()
                library.query = ""; library.archiveSpaceFilter = nil; await library.reloadArchive()
                let removed = library.archiveRows[0].id; library.requestDeleteArchive([removed]); try require(library.pendingArchiveDeletes == [removed], "delete confirmation missing")
                await library.deleteArchiveConfirmed(); try require(!library.archiveRows.contains { $0.id == removed }, "delete stayed in archive")
                let storedCount = await countArchive(env.archives); try require(storedCount == 4, "delete not in SQLite")
                library.requestClearArchive(); let beforeClear = await countArchive(env.archives); try require(library.confirmsClear && beforeClear == 4, "clear did not ask first")
                await library.clearArchiveConfirmed(); let after = await countArchive(env.archives); try require(after == 0 && env.libraryActions.log.contains("clearArchive"), "clear not on disk")
            case "library-folder-archive":
                try await env.prepareLibrary()
                let space = vm.model.spaces[0], library = env.library
                let first = vm.model.newTab(in: space.id, url: URL(string: "https://example.invalid/folder-a")!, title: "Folder A")
                let second = vm.model.newTab(in: space.id, url: URL(string: "https://example.invalid/folder-b")!, title: "Folder B")
                let third = vm.model.newTab(in: space.id, url: URL(string: "https://example.invalid/folder-c")!, title: "Folder C")
                let split = vm.model.makeSplit(tabIDs: [second.id, third.id])!
                let nested = vm.model.createFolder(in: .spaceToday(space.id), title: "Nested", withNodes: [split.id])!
                let folder = vm.model.createFolder(in: .spaceToday(space.id), title: "Restorable folder", withNodes: [first.id, nested.id])!
                vm.model.closeTab(id: folder.id)
                (vm.model.archiveSink as? ProfileArchiveSink)?.flushAll()
                await library.reloadArchive()
                let row = library.archiveRows.first { $0.id == folder.id }!
                try require(row.kind == .folder && library.archivedChildCount(row) == 3, "L2 nested tab count must include split panes")
                let oldActionCount = env.libraryActions.log.count
                let before = try Data(contentsOf: vm.snapshot.fileURL)
                vm.model.undoManager?.removeAllActions()
                setenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL", "1", 1)
                await library.restore(id: folder.id)
                unsetenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL")
                let retained = await env.archives[space.profileID]!.record(id: folder.id)
                try require(vm.model.node(id: folder.id) == nil && retained?.kind == .folder && vm.model.undoManager?.canUndo == false
                            && env.libraryActions.log.count == oldActionCount && (try Data(contentsOf: vm.snapshot.fileURL)) == before,
                            "L3 failed save lost folder archive or published undo/action")
                await library.restore(id: folder.id)
                let disk = try env.diskModel()
                try require(disk.node(id: folder.id)?.folder?.children.count == 2 && disk.node(id: nested.id)?.folder?.children.first?.id == split.id,
                            "L3 folder restore did not persist the subtree")
                try require(library.statusText == "Folder restored to \(vm.model.displayTitle(for: space)). Click to view." && library.restoredSpaceID == space.id,
                            "L3 folder restore text/View destination mismatch")
                library.actions.viewSpace(id: library.restoredSpaceID!)
                try require(env.libraryActions.log.suffix(2) == ["restoreArchived \(folder.id)", "viewSpace \(space.id)"], "L3 View action missing")
                let oldTab = ArchivedTabRecord(id: ItemID(), url: URL(string: "https://example.invalid/old")!, title: "Old tab", archivedAt: Date(), reason: .folderDeleted, originalLocation: "today:\(space.id)", payloadJSON: "{}")
                try require(oldTab.kind == .tab && library.archivedChildCount(oldTab) == 0, "L2 legacy folderDeleted tabs were relabeled as folders")
            case "library-downloads":
                try await env.prepareLibrary(); let library = env.library
                let active = env.downloadFeed.downloads.first { $0.state == .inProgress }!, failed = env.downloadFeed.downloads.first { $0.state == .failed }!, done = env.downloadFeed.downloads.first { $0.state == .completed }!
                try require(active.progress == 0.4 && library.fileAvailable(done), "progress or completed file on disk")
                library.retryDownload(failed); library.revealDownload(done)
                try require(env.libraryActions.log == ["retryDownload download-failed", "revealDownload download-done"], "download action IDs")
                try FileManager.default.removeItem(atPath: done.filePath!); library.revealDownload(done)
                try require(library.statusText == "File moved or deleted." && env.libraryActions.log.count == 2, "moved-file guard")
                _ = try env.diskModel()
            case "library-captures-history":
                try await env.prepareLibrary(); let library = env.library
                library.section = .captures; try require(library.captureItems.count == 3 && library.thumbnails.count == 3, "capture grid/thumbs")
                let item = library.captureItems[0], output = env.root.appendingPathComponent("Example Saved.png")
                library.saveCapture(item, to: output); try require(FileManager.default.fileExists(atPath: output.path), "Save As did not write")
                library.pendingCaptureDelete = item.id; library.deleteCaptureConfirmed()
                let reloaded = try FileCapturesProvider(root: env.root)
                try require(reloaded.captures.count == 2 && !FileManager.default.fileExists(atPath: env.captures.directory.appendingPathComponent(item.fileName).path), "capture index/file deletion")
                library.section = .history; library.query = "Example"; await library.reloadHistory()
                try require(library.historyRows.count == 3, "profile history isolation")
                library.actions.openHistoryItem(url: library.historyRows[0].url)
                var disk = try env.diskModel(); try require(disk.spaces.contains { !$0.today.isEmpty } && env.libraryActions.log.contains("openHistoryItem"), "history open action")
                library.historyProfileID = vm.model.profiles[1].id; await library.reloadHistory()
                try require(library.historyRows.count == 2, "Work history profile scope")
                let workURL = library.historyRows[0].url; library.actions.openHistoryItem(url: workURL)
                disk = try env.diskModel(); try require(disk.spaces[2].today.contains { $0.tab?.url == workURL }, "history opened in the wrong profile")
            case "empty-states":
                try await env.prepareLibrary(); env.downloadFeed.downloads = []
                for store in env.archives.values { try await store.deleteAll() }
                for item in env.captures.captures { try env.captures.remove(id: item.id) }
                for (section, title) in [(LibrarySection.archive, "No archived tabs"), (.downloads, "No downloads"), (.captures, "No captures")] {
                    env.library.section = section; await env.library.reload()
                    let labels = try await render(LibraryContent(viewModel: env.library), size: CGSize(width: 960, height: 640), scale: 1, dark: false, to: env.root.appendingPathComponent("empty-\(section.rawValue).png"))
                    try require(labels.contains(title), "empty label missing from hosted accessibility tree: \(title) — \(labels)")
                }
                let emptyCount = await countArchive(env.archives); try require(emptyCount == 0 && (try FileCapturesProvider(root: env.root)).captures.isEmpty, "empty stores not on disk")
            case "archive-save-failure":
                try await env.prepareLibrary();let library=env.library
                let row=library.archiveRows[0];let before=try Data(contentsOf:vm.snapshot.fileURL)
                let priorUndo=vm.model.undoManager?.canUndo
                setenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL","1",1)
                await library.restore(id:row.id)
                unsetenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL")
                let retained=await env.archives[row.profileID!]!.record(id:row.id)
                try require(vm.model.tab(id:row.id) == nil && retained != nil,"failed snapshot left a live tab or lost archive")
                try require(try Data(contentsOf:vm.snapshot.fileURL) == before,"failed restore changed durable snapshot")
                try require(library.statusText.contains("Saving failed") && env.libraryActions.log.isEmpty && vm.model.undoManager?.canUndo == priorUndo,"failed restore published action/Undo")
            case "archive-owner-partial":
                try await env.prepareLibrary();let library=env.library
                let personalStore=env.archives[personal]!,workStore=env.archives[work]!
                let personalRows=library.archiveRows.filter{$0.profileID == personal},workRows=library.archiveRows.filter{$0.profileID == work}
                try archiveDeleteTrigger(workStore.fileURL,enabled:true)
                library.requestDeleteArchive([personalRows[0].id]);await library.deleteArchiveConfirmed()
                try require(library.archiveResults.count == 1 && library.archiveResults[personal]?.hasPrefix("Deleted") == true,"delete touched an unrelated profile store")
                let workCount=await workStore.count();try require(workCount == 3,"unowned rows changed")
                library.requestDeleteArchive([personalRows[1].id,workRows[0].id]);await library.deleteArchiveConfirmed()
                let kept=await workStore.record(id:workRows[0].id),removed=await personalStore.record(id:personalRows[1].id)
                try require(removed == nil && kept != nil && library.archiveResults[work]?.hasPrefix("Failed:") == true,"partial deletion was not reported by owning profile")
                library.requestClearArchive();await library.clearArchiveConfirmed()
                let personalCount=await personalStore.count(),remaining=await workStore.count()
                try require(personalCount == 0 && remaining == 3 && library.archiveResults[personal] == "Archive cleared." && library.archiveResults[work]?.hasPrefix("Failed:") == true && !env.libraryActions.log.contains("clearArchive"),"partial clear hid failures")
                try archiveDeleteTrigger(workStore.fileURL,enabled:false)
            case "adblock-profile-lifecycle":
                try await env.prepareAdBlock();let ad=vm.adBlock!
                let created=vm.profiles.create(name:"Example New Profile")!
                await ad.openSelectedProfile();ad.setExcluded("example.org",excluded:true)
                let file=ad.store.listDirectory(for:created.id).appendingPathComponent("exclusions.json")
                try require(try JSONDecoder().decode([String].self,from:Data(contentsOf:file)).contains("example.org"),"new profile was not attached")
                try ad.store.closeProfile(created.id);ad.setExcluded("example.net",excluded:true)
                try require(ad.errorText == "Ad block settings are still loading for this Profile.","store fault was mislabeled as invalid host")
                await ad.openSelectedProfile();try require(vm.profiles.delete(id:created.id),"new profile delete failed")
                do {try ad.store.setExcluded("example.com",excluded:true,profile:created.id);throw CheckFailure(description:"deleted profile state stayed open")}
                catch let error as CheckFailure {throw error} catch {try require(String(describing:error).contains("profile is not open"),"wrong deletion failure")}
                try require(try env.diskModel().profile(id:created.id) == nil,"deleted profile stayed on disk")
                var closed: [ProfileID] = []
                ad.store.onEngineEvent = { [weak ad] event in
                    if case .closed(let id) = event { closed.append(id) }
                    ad?.refresh()
                }
                let external = vm.profiles.create(name:"Example External Profile")!
                await ad.openSelectedProfile()
                try require(try vm.profiles.dataModel.deleteProfile(in:vm.model,id:external.id),"external owner delete failed")
                vm.profiles.select(personal); ad.refresh()
                try require(closed.filter{$0 == external.id}.count == 1,"reentrant store callback repeated external closure")
                do {try ad.store.setExcluded("example.com",excluded:true,profile:external.id);throw CheckFailure(description:"externally deleted profile stayed open")}
                catch let error as CheckFailure {throw error} catch {try require(String(describing:error).contains("profile is not open"),"wrong external close failure")}
                try require(try env.diskModel().profile(id:external.id) == nil,"external deletion did not persist")
            case "suggestion-notice":
                vm.profiles.paneDidAppear()
                try require(vm.profiles.suggestions && vm.profiles.showsSuggestNotice && !vm.profiles.allowsRemoteSuggestions,"fresh ON pane dead-ended without notice")
                try require(!vm.profiles.prepareForRemoteSuggestions(profileID:personal),"app first query bypassed notice")
                vm.profiles.dismissSuggestNotice()
                let disk=try env.diskDefaults();try require(disk["open.general.searchSuggestNoticeDismissed"] as? Bool == true && vm.profiles.allowsRemoteSuggestions,"notice acknowledgement not persisted")
                let reopened=SettingsViewModel(model:vm.model,actions:env.actions,defaults:UserDefaults(suiteName:env.suite)!,root:env.root,snapshot:vm.snapshot)
                try require(reopened.profiles.prepareForRemoteSuggestions(profileID:personal) && !reopened.profiles.showsSuggestNotice,"notice repeated after restart")
                let oldProfile=vm.selectedProfileID,oldRevision=vm.preferenceRevision
                let oldLinks=vm.links
                try require(!vm.profiles.prepareForRemoteSuggestions(profileID:work) && vm.selectedProfileID == oldProfile && vm.links === oldLinks && vm.preferenceRevision == oldRevision,"an OFF query changed Settings selection or routing")
                vm.profiles.update{$0.searchSuggestEnabled=false};vm.profiles.select(work)
                var workSettings=vm.model.profile(id:work)!.settings;workSettings.searchSuggestEnabled=true;vm.model.updateProfileSettings(id:work,settings:workSettings)
                vm.set(false,for:"open.general.searchSuggestNoticeDismissed")
                vm.profiles.select(personal)
                try require(!vm.profiles.prepareForRemoteSuggestions(profileID:work) && vm.selectedProfileID == personal && !vm.profiles.showsSuggestNotice,"gate opened or selected another Profile")
                let presenter=SettingsPresenter(viewModel:vm)
                try require(!presenter.prepareForRemoteSuggestions(profileID:work) && vm.selectedProfileID == personal && presenter.window == nil,"presenter query gate changed selection or opened a window")
                vm.profiles.presentSuggestNotice(profileID:work)
                try require(vm.selectedProfileID == work && vm.profiles.showsSuggestNotice,"explicit notice presentation did not select the requested Profile")
            case "shortcuts-recording-admission":
                let id="new-window",before=try Data(contentsOf:vm.shortcuts.fileURL)
                let keys:[OpenCommands.KeyboardShortcut]=[.init(key:"a"),.init(key:"a",modifiers:[.shift]),.init(key:"space"),.init(key:"tab"),.init(key:"return")]
                vm.shortcuts.beginRecording(id)
                for key in keys {
                    vm.shortcuts.record(key,for:id)
                    try require(vm.shortcuts.recordingCommandID == id && vm.shortcuts.statusText == "Use ⌘, ⌃, or ⌥ with a key.","unsafe key stopped recording")
                    try require(try Data(contentsOf:vm.shortcuts.fileURL) == before && env.actions.log.isEmpty,"unsafe recording changed disk or menus")
                }
                vm.shortcuts.record(.init(key:"f20"),for:id)
                try require(try KeyBindingStore.load(from:vm.shortcuts.fileURL).bindings[id]?.shortcuts == [.init(key:"f20")] && vm.shortcuts.recordingCommandID == nil,"bare function key did not persist")
                vm.shortcuts.beginRecording(id);vm.shortcuts.record(.init(key:"left"),for:id)
                try require(try KeyBindingStore.load(from:vm.shortcuts.fileURL).bindings[id]?.shortcuts == [.init(key:"left")] && vm.shortcuts.recordingCommandID == nil,"bare arrow key did not persist")
                vm.shortcuts.beginRecording(id);vm.shortcuts.record(.init(key:"b",modifiers:[.control,.option]),for:id)
                try require(try KeyBindingStore.load(from:vm.shortcuts.fileURL).bindings[id]?.shortcuts == [.init(key:"b",modifiers:[.control,.option])],"modified printable key failed")
                vm.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:"new-tab")
                vm.shortcuts.record(.init(key:"y",modifiers:[.control,.option,.command]),for:id)
                try require(!vm.shortcuts.banner.isEmpty,"conflict fixture was not active")
                let conflictBytes=try Data(contentsOf:vm.shortcuts.fileURL),calls=env.actions.log.count
                vm.shortcuts.beginRecording(id);vm.shortcuts.record(.init(key:"a"),for:id)
                try require(vm.shortcuts.statusMessage == "Use ⌘, ⌃, or ⌥ with a key." && vm.shortcuts.recordingCommandID == id,"old conflict hid the unsafe-key instruction")
                try require(try Data(contentsOf:vm.shortcuts.fileURL) == conflictBytes && env.actions.log.count == calls,"unsafe key changed a conflicted draft on disk")
            case "archive-paging":
                try await env.prepareLibrary()
                for store in env.archives.values {try await store.deleteAll()}
                var ids:Set<ItemID>=[]
                for index in 0..<225 {
                    let profile=vm.model.profiles[index % 2],space=vm.model.spaces.first{$0.profileID == profile.id}!
                    let tab=Tab(id:ItemID(),url:URL(string:"https://example.com/page/\(index)")!,title:"Example Page \(index)")
                    ids.insert(tab.id)
                    env.archives[profile.id]!.archive([ArchiveEntry(tab:tab,reason:.closed,originalLocation:"today:\(space.id)",spaceID:space.id,profileID:profile.id,archivedAt:SyntheticData.fixtureDate.addingTimeInterval(-Double(index)))])
                }
                for store in env.archives.values {store.flushQueue()}
                let library=env.library
                let first=Task {await library.reloadArchive()}
                let deadline=Date().addingTimeInterval(10)
                while library.archiveRows.count < 100 && Date() < deadline {await Task.yield()}
                try require(library.archiveRows.count == 100,"initial Archive page did not finish")
                // Reproduce the sentinel request while the first page still loads favicons.
                await library.loadNextArchivePage();await first.value
                try require(library.archiveRows.count >= 200,"paging request was lost behind favicon loading")
                while library.archiveHasMore {await library.loadNextArchivePage()}
                try require(library.archiveRows.count == 225 && Set(library.archiveRows.map(\.id)) == ids && library.archiveRows.last?.title == "Example Page 224","Archive did not reach the final cross-profile row")
                let persisted=await countArchive(env.archives);try require(persisted == 225,"paged rows were not in the real stores")
                library.requestDeleteArchive([ItemID()]);await library.deleteArchiveConfirmed()
                try require(library.statusText == "This archived tab is no longer available.","missing owner vanished silently")
            case "links-save-failure":
                let before=try Data(contentsOf:vm.snapshot.fileURL)
                vm.links.drafts[0].spaceID=SpaceID()
                var edited=vm.links.drafts[1];edited.pattern="guide"
                let accepted=vm.saveLinkRule(edited)
                try require(!accepted && !vm.linksError.isEmpty,"invalid sibling route closed the editor without an error")
                try require(try Data(contentsOf:vm.snapshot.fileURL) == before,"invalid routing reached disk")
                vm.refreshLinks();edited=vm.links.drafts[1];edited.pattern="guide"
                setenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL","1",1)
                let saved=vm.saveLinkRule(edited)
                unsetenv("OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL")
                try require(!saved && vm.linksError.contains("could not be saved") && (try Data(contentsOf:vm.snapshot.fileURL)) == before,"write failure claimed success")
                try require(vm.saveLinkRule(edited),"valid retry was refused")
                let disk=try env.diskModel();try require(disk.routingRules[1].match == .hostContains("guide"),"valid route retry did not persist")
                vm.links.testURLString="https://guide.example.org/";vm.links.runTest()
                try require(vm.linkTestSummary == "Opens in Office · matched “guide” (Host contains)","plain test summary differs from evaluator")
            case "adblock-readiness":
                try await env.prepareAdBlock();let ad=vm.adBlock!
                let created=vm.profiles.create(name:"Example Loading Profile")!
                let calls=env.actions.log.count
                try require(!ad.isReady && !ad.openedProfiles.contains(created.id),"new Profile was ready before open")
                ad.setExcluded("example.org",excluded:true)
                try require(ad.errorText == "Ad block settings are still loading for this Profile." && env.actions.log.count == calls,"loading host control wrote or showed an internal fault")
                await ad.openSelectedProfile()
                try require(ad.isReady && ad.openedProfiles.contains(created.id),"successful open did not enable edits")
                ad.setExcluded("example.org",excluded:true)
                let file=ad.store.listDirectory(for:created.id).appendingPathComponent("exclusions.json")
                try require(try JSONDecoder().decode([String].self,from:Data(contentsOf:file)).contains("example.org"),"ready host change did not persist")
                try require(vm.profiles.delete(id:created.id) && !ad.openedProfiles.contains(created.id),"deleted Profile remained ready")
            case "settings-caches":
                _=vm.shortcutsStore;let reads=vm.keyBindingLoadCount
                for _ in 0..<20 {_=vm.shortcutsStore}
                try require(vm.keyBindingLoadCount == reads,"unchanged key file was parsed on redraw")
                vm.shortcuts.record(.init(key:"f20"),for:"new-window")
                try require(vm.shortcutsStore.bindings["new-window"]?.shortcuts == [.init(key:"f20")] && vm.keyBindingLoadCount == reads+1,"changed key file was not reloaded once")
                try await env.prepareLibrary();let library=env.library,item=env.captures.captures[0]
                let image=library.thumbnailImages[item.id]
                await library.loadThumbnail(item)
                try require(image != nil && image === library.thumbnailImages[item.id] && library.faviconImages.count > 0 && library.historyFaviconImages.count > 0,"decoded Library images were not retained")
            case "app-icon":
                vm.appIcon.select(.openColor)
                let disk = try env.diskDefaults()
                try require(disk["open.appIcon.selectedID"] as? String == "openColor", "icon persistence")
                try require(env.actions.log == ["setApplicationIcon openColor"], "icon action missing")
            default: break
            }
            passed += 1; print("PASS \(name)")
        } catch { print("FAIL \(name): \(error)"); print("SUMMARY \(passed) checks passed, 1 failed"); throw error }
    }
    print("SUMMARY \(passed) checks passed, 0 failed")
}

/// A real loopback HTTP server feeds synthetic filter text through URLSession and generation IO.
/// It exercises the existing explicit debug-source override; no store or downloader is replaced.
@MainActor final class SyntheticListServer {
    let process = Process()
    private let previous = ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_SOURCE_ROOT"]
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=b'[Adblock Plus 2.0]\\n! Example synthetic regional list\\n||example.org/ad^\\n'
  self.send_response(200); self.send_header('Content-Type','text/plain'); self.send_header('ETag','synthetic-v1'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else { process.terminate(); throw CheckFailure(description: "could not start synthetic list server") }
        setenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT", "http://127.0.0.1:\(port)", 1)
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; if let previous { setenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT", previous, 1) } else { unsetenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT") } }
}

@MainActor func countArchive(_ stores: [ProfileID: ArchiveStore]) async -> Int {
    var result = 0; for store in stores.values { result += await store.count() }; return result
}

/// Real SQLite trigger creates a durable per-profile deletion failure, without a fake store.
func archiveDeleteTrigger(_ url:URL,enabled:Bool) throws {
    var db:OpaquePointer?
    guard sqlite3_open(url.path,&db) == SQLITE_OK else {throw CheckFailure(description:"cannot open synthetic archive")}
    defer {sqlite3_close(db)}
    let sql=enabled ? "CREATE TRIGGER review_block_delete BEFORE DELETE ON archived_tabs BEGIN SELECT RAISE(ABORT, 'synthetic deletion failure'); END;":"DROP TRIGGER review_block_delete;"
    guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else {throw CheckFailure(description:"cannot configure real archive failure")}
}
