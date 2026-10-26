import Foundation
import AppKit
import OpenSettings
import OpenModel
import OpenStore
import OpenCommands
import OpenRouting
import OpenAdBlock

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
        settings = SettingsViewModel(model: SyntheticData.model(), actions: actions, defaults: defaults, root: root)
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
        if let item = captures.captures.first { try await faviconStore.ingest(imageData: Data(contentsOf: captures.directory.appendingPathComponent(item.fileName)), iconURL: URL(string: "https://example.com/favicon.ico"), for: URL(string: "https://example.com/")!, pageSpecific: false) }
        await library.reloadArchive(); await library.reloadHistory()
        for item in captures.captures { await library.loadThumbnail(item) }
    }
    func prepareAdBlock() async throws {
        var policy = AdBlockDownloadPolicy(); policy.attempts = 1; policy.requestTimeout = 2; policy.resourceTimeout = 3
        let store = try AdBlockStore(root: root, policy: policy)
        for profile in settings.model.profiles { try await store.openProfile(profile.id, scheduleUpdates: false) }
        settings.attach(adBlockStore: store)
    }
    func close() { defaults.removePersistentDomain(forName: suite); defaults.synchronize(); try? FileManager.default.removeItem(at: root) }
    /// Read the real CFPreferences file after synchronize, not a second cached defaults object.
    func diskDefaults() throws -> [String: Any] {
        try require(defaults.synchronize(), "UserDefaults synchronize failed")
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
        let expected = defaults.persistentDomain(forName: suite) ?? [:]
        for _ in 0..<200 {
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
    let names = ["general-toggles", "default-browser", "profile-search", "profile-archive-scope", "profile-downloads", "clear-data", "profile-guards", "links-rules", "links-toggles", "shortcuts-save", "shortcuts-conflict", "advanced-toggles", "adblock", "app-icon", "import-counts", "library-archive", "library-downloads", "library-captures-history", "empty-states"]
    if let only { try require(names.contains(only), "Unknown check \(only)") }
    var passed = 0
    for name in names where only == nil || only == name {
        let env = try PreviewEnvironment(); defer { env.close() }
        let vm = env.settings
        do {
            switch name {
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
                let personal = vm.model.profiles[0].id, work = vm.model.profiles[1].id
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
                try require(env.actions.log.isEmpty, "search should be read at use")
            case "profile-archive-scope":
                vm.profiles.proposeArchive(.twentyFourHours); vm.profiles.applyArchive(all: false)
                var disk = try env.diskModel()
                try require(disk.profiles.allSatisfy { $0.settings.autoArchiveAfter == .twentyFourHours }, "profile-only archive mismatch")
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
                vm.shortcuts.clear("zoom-in"); vm.shortcuts.priority(.siteFirst, for: "new-tab")
                let disk = try KeyBindingStore.load(from: vm.shortcuts.fileURL)
                try require(disk.effectiveShortcuts(for: CommandRegistry.byID["new-tab"]!) == [.ctrl("t")] && disk.bindings["zoom-in"]?.shortcuts == [] && disk.effectivePriority(for: CommandRegistry.byID["new-tab"]!) == .siteFirst, "key binding persistence/effective menu keys")
                try require(env.actions.log.allSatisfy { $0 == "keyBindingsDidChange" } && env.actions.log.count == 3, "menu/hotkey notifications")
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
                try require(wizard.outcome?.errorText == nil && wizard.outcome?.counts["Imported Spaces"] == 2 && env.actions.keychainReadCount == 0, "import/action consent")
                var disk = try env.diskModel(); let itemCount = disk.index.count, spaceCount = disk.spaces.count
                let repeatWizard = ImportWizardViewModel(root: vm, directory: source); await repeatWizard.refreshCounts(); repeatWizard.review(); await repeatWizard.beginImport()
                disk = try env.diskModel(); try require(disk.index.count == itemCount && disk.spaces.count == spaceCount && repeatWizard.outcome?.counts["Imported items"] == 0, "re-import added rows")
                let consent = ImportWizardViewModel(root: vm, directory: source); await consent.refreshCounts(); consent.plan.secretsRequested = true; consent.review()
                let calls = env.actions.log.count; await consent.beginImport()
                try require(consent.step == .consent && !consent.plan.secretsConsented && env.actions.log.count == calls, "consent did not gate import")
                consent.finish(); try require(env.actions.keychainReadCount == 0 && env.actions.log.count == calls, "cancel consent touched Keychain")
                let allowed = ImportWizardViewModel(root: vm, directory: source); await allowed.refreshCounts(); allowed.plan.secretsRequested = true; allowed.review(); await allowed.beginImport(); await allowed.allowAndImportSecrets()
                try require(allowed.plan.secretsConsented && allowed.outcome?.counts["Secret copies"] == 0 && env.actions.keychainReadCount == 0, "consented Phase 2 read secrets")
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
                    let labels = try render(LibraryContent(viewModel: env.library), size: CGSize(width: 960, height: 640), scale: 1, dark: false, to: env.root.appendingPathComponent("empty-\(section.rawValue).png"))
                    try require(labels.contains(title), "empty label missing from hosted accessibility tree: \(title) — \(labels)")
                }
                let emptyCount = await countArchive(env.archives); try require(emptyCount == 0 && (try FileCapturesProvider(root: env.root)).captures.isEmpty, "empty stores not on disk")
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
