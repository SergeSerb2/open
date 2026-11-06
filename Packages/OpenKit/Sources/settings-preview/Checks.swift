import Foundation
import AppKit
import OpenSettings
import SwiftUI
import OpenModel
import OpenStore
import OpenCommands
import OpenRouting
import OpenAdBlock
import OpenSuggest
import SQLite3
import OpenImport

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
        captures = FileCapturesProvider(root: root)
        libraryActions = PreviewLibraryActions(model: settings.model, downloads: downloadFeed, captures: captures, snapshot: settings.snapshot)
        let directories = ProfileDirectories(root: root)
        archives = Dictionary(uniqueKeysWithValues: settings.model.profiles.map { ($0.id, ArchiveStore(fileURL: directories.archiveFileURL(for: $0))) })
        histories = Dictionary(uniqueKeysWithValues: settings.model.profiles.map { ($0.id, HistoryStore(fileURL: directories.historyFileURL(for: $0))) })
        faviconStore = try FaviconStore(databaseURL: root.appendingPathComponent("State/favicons.sqlite3"))
        library = LibraryViewModel(model: settings.model, defaults: defaults, actions: libraryActions, downloads: downloadFeed, captures: captures, archives: archives, histories: histories, snapshot: settings.snapshot, faviconStore: faviconStore, settingsActions: actions)
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
    private(set) var listServer: SyntheticListServer?
    func prepareAdBlock() async throws {
        if listServer == nil { listServer = try SyntheticListServer() }
        var policy = AdBlockDownloadPolicy(); policy.attempts = 1; policy.requestTimeout = 2; policy.resourceTimeout = 3
        let store = try AdBlockStore(root: root, policy: policy)
        for profile in settings.model.profiles { try await store.openProfile(profile.id, scheduleUpdates: false) }
        settings.attach(adBlockStore: store)
        await settings.adBlock?.openSelectedProfile()
    }
    func close() { listServer?.stop(); defaults.removePersistentDomain(forName: suite); defaults.synchronize(); try? FileManager.default.removeItem(at: root) }
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
    let names = ["extension-shortcuts", "essential-shortcuts", "shortcuts-callout", "general-toggles", "default-browser", "profile-search", "profile-archive-scope", "profile-downloads", "clear-data", "profile-guards", "links-rules", "links-toggles", "shortcuts-save", "shortcuts-conflict", "advanced-toggles", "adblock", "app-icon", "import-counts", "library-archive", "library-downloads", "library-captures-history", "empty-states", "archive-save-failure", "archive-owner-partial", "adblock-profile-lifecycle", "suggestion-notice", "shortcuts-recording-admission", "archive-paging", "links-save-failure", "adblock-readiness", "settings-caches", "library-folder-archive", "library-tidy-search", "first-run-actions-and-adapter-gate", "first-run-probe", "first-run-count-parity", "probe-cancel-mid-copy", "sidebar-defaults", "library-spaces", "previews-legacy-migration"]
    if let only { try require(names.contains(only), "Unknown check \(only)") }
    var passed = 0
    for name in names where only == nil || only == name {
        let env = try PreviewEnvironment(); defer { env.close() }
        let vm = env.settings
        let personal=vm.model.profiles[0].id,work=vm.model.profiles[1].id
        do {
            switch name {
            case "extension-shortcuts":
                vm.selectedPane = .shortcuts
                env.actions.extensionConflicts = PreviewActions.sampleExtensionConflicts
                let expected = ["Action Probe: ⇧⌘Y is used by Copy URL, so it is off.", "Search Probe: ⌘T is used by New Tab…, so it is off."]
                try require(vm.shortcuts.extensionConflicts.map(\.notice) == expected, "extension notice copy")
                try require(!vm.shortcuts.commands.contains { ["probe", "conflict"].contains($0.id) }, "dynamic extension commands leaked into registry")
                try await withAccessibleHost(ShortcutsPane(model: vm.shortcuts), size: CGSize(width: 684, height: 600)) { host in
                    let labels = accessibilityLabels(host)
                    try require(expected.allSatisfy { labels.contains($0) }, "extension conflict lines missing from pane: \(labels)")
                    try require(pressAccessibilityElement(host, label: "Extension Shortcuts…"), "extension link missing")
                    @MainActor func menuButton(_ view: NSView) -> NSPopUpButton? {
                        if let button = view as? NSPopUpButton, button.menu?.items.contains(where: { $0.title == "Extension Shortcuts" }) == true { return button }
                        return view.subviews.lazy.compactMap { menuButton($0) }.first
                    }
                    guard let menu = menuButton(host)?.menu else { throw CheckFailure(description: "Shortcuts … menu missing") }
                    try require(menu.items.dropFirst().map(\.title) == ["Revert Unsaved Changes", "Shortcut Help", "Extension Shortcuts"], "Shortcuts … menu order")
                    menu.performActionForItem(at: 3)
                }
                try require(env.actions.openedURLs.count == 2 && env.actions.openedURLs.allSatisfy { $0.0.absoluteString == "chrome://extensions/shortcuts" && $0.1 == vm.selectedProfileID }, "extension link/menu URL or Profile")
                vm.selectedProfileID = work
                vm.shortcuts.openExtensionShortcuts()
                try require(env.actions.openedURLs.last?.1 == work, "extension shortcuts ignored selected Profile")
                env.actions.extensionConflicts = []
                try require(vm.shortcuts.extensionConflicts.isEmpty, "empty extension conflicts retained")
            case "essential-shortcuts":
                // Rows in Arc's order with live keycaps; a custom key shows; a cleared one shows "—" (plan §4.5.2).
                let store = KeyBindingStore.empty
                try require(EssentialShortcuts.items.map(\.title) == ["Open a New Tab", "Switch to a Recent Tab", "Copy Page URL", "Add Split View", "Open Little Open"], "EDU rows or order")
                let caps = EssentialShortcuts.items.map { EssentialShortcuts.keycaps(for: $0.commandID, in: store) }
                try require(caps == [["⌘", "T"], ["⌃", "Tab"], ["⇧", "⌘", "C"], ["⌃", "⇧", "="], ["⌥", "⌘", "N"]], "EDU default keycaps \(caps)")
                var custom = store
                custom.setOverride(KeyBindingOverride(shortcuts: [.init(key: "y", modifiers: [.control, .option, .command])], priority: nil), for: "new-tab")
                custom.setOverride(KeyBindingOverride(shortcuts: [], priority: nil), for: "copy-url")
                try require(EssentialShortcuts.keycaps(for: "new-tab", in: custom) == ["⌃", "⌥", "⌘", "Y"] && EssentialShortcuts.keycaps(for: "copy-url", in: custom).isEmpty, "EDU custom or cleared keycaps")
                try await withAccessibleHost(EssentialShortcutsView(store: custom), size: NSHostingView(rootView: EssentialShortcutsView(store: custom)).fittingSize) { host in
                    let labels = accessibilityLabels(host)
                    try require(EssentialShortcuts.items.allSatisfy { labels.contains($0.title) }, "EDU AX labels \(labels)")
                }
                // The window: Arc's setup (CC-27), one shared instance, Esc and Cmd+W close it.
                let controller = EssentialShortcutsWindowController()
                controller.show(near: nil, store: store)
                guard let w = controller.window else { throw CheckFailure(description: "EDU window not created") }
                try require(w.title == "Essential Keyboard Shortcuts" && w.titleVisibility == .hidden && w.titlebarAppearsTransparent && !w.isOpaque
                            && w.isMovableByWindowBackground && w.level == .floating && w.collectionBehavior.contains(.fullScreenAuxiliary)
                            && w.styleMask == [.titled, .closable, .miniaturizable, .fullSizeContentView] && !w.styleMask.contains(.resizable), "EDU window setup")
                try require(abs(w.frame.width - 440) < 1 && w.frame.height > 300 && w.frame.height < 460, "EDU size \(w.frame.size)")
                w.cancelOperation(nil)
                try require(!w.isVisible, "Esc did not close the EDU window")
                controller.show(near: nil, store: custom)
                try require(controller.window === w && w.isVisible, "EDU window not reused")
                let cmdW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
                try require(w.performKeyEquivalent(with: cmdW) && !w.isVisible, "Cmd+W did not close the EDU window")
            case "shortcuts-callout":
                // The callout's button opens the window through the Settings action (CC-29, CC-30); the
                // list is no longer filtered ("Start with the basics" is a label, not a filter).
                vm.selectedPane = .shortcuts; vm.shortcuts.query = ""
                try require(vm.shortcuts.commands.count == CommandRegistry.active.count, "Shortcuts list hides commands: \(vm.shortcuts.commands.count) of \(CommandRegistry.active.count)")
                let before = env.actions.log.filter { $0 == "openEssentialShortcuts" }.count
                try await withAccessibleHost(ShortcutsPane(model: vm.shortcuts), size: CGSize(width: 684, height: 600)) { host in
                    // Static text reports its string as the AX value; buttons as the label.
                    var texts = Set(accessibilityLabels(host)), seen = Set<ObjectIdentifier>()
                    @MainActor func values(_ node: NSObject) {
                        guard seen.insert(ObjectIdentifier(node)).inserted, seen.count < 4096 else { return }
                        let value = NSSelectorFromString("accessibilityValue"), children = NSSelectorFromString("accessibilityChildren")
                        if node.responds(to: value), let v = node.perform(value)?.takeUnretainedValue() as? String { texts.insert(v) }
                        if node.responds(to: children), let c = node.perform(children)?.takeUnretainedValue() as? [NSObject] { c.forEach(values) }
                        if let view = node as? NSView { view.subviews.forEach(values) }
                    }
                    values(host)
                    try require(texts.contains("Start with the basics") && texts.contains("Learn the Essential Shortcuts"), "callout text missing: \(texts.sorted().prefix(20))")
                    try require(pressAccessibilityElement(host, label: "Learn the Essential Shortcuts"), "callout button not found")
                }
                try require(env.actions.log.filter { $0 == "openEssentialShortcuts" }.count == before + 1, "callout did not call openEssentialShortcuts")
            case "first-run-probe":
                let directory=env.root.appendingPathComponent("Probe Source")
                try SyntheticData.writeProbeFixture(to:directory)
                let started=DispatchTime.now().uptimeNanoseconds
                let probe=await ArcProbe(arcDirectory:directory).run()
                let seconds=Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000_000
                try require(probe.sidebarFound && probe.spaces == 2 && probe.sidebarItems == 4 && probe.archiveItems == 2 && probe.rawArchiveItems == 3 && probe.historyVisits == 3 && probe.secretRows == 4 && probe.savedItems == 4 && probe.settingsCounts["Profiles"] == 1 && probe.settingsCounts["Search settings"] == 1,"probe fixture counts differ")
                try require(seconds < 1,"small fixture probe exceeded one second")
                let receipt=String(decoding:try JSONEncoder().encode(probe),as:UTF8.self)
                try require(!receipt.contains("example.com") && !receipt.contains("Example History"),"probe returned source URLs or titles")
                let shared=ImportWizardViewModel(root:vm,directory:directory);await shared.refreshCounts()
                try require(shared.counts == probe.settingsCounts && shared.probe?.historyVisits == 3 && shared.canContinue && shared.spaceMapping.count == 2,"wizard retained a second counter")
                let actions=PreviewFirstRunActions(),first=FirstRunViewModel(settings:vm,actions:actions,directory:directory)
                await first.refreshProbe();try require(first.probe?.settingsCounts == shared.counts,"first run differs from the shared probe")
                let empty=env.root.appendingPathComponent("Empty Probe");try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
                let absent=await ArcProbe(arcDirectory:empty).run()
                try require(absent.arcDirectoryExists && !absent.sidebarFound && absent.spaces == nil && absent.historyVisits == nil && absent.secretRows == nil && absent.settingsCounts.isEmpty,"empty source manufactured counts")
                await first.choose(directory:empty);first.showImport();try require(first.probe?.sidebarFound == false && actions.events.isEmpty,"empty UI performed an action")
                first.startFresh();try require(actions.events == ["finishFirstRun imported=false"],"empty path did not finish fresh")
                let namedSource=env.root.appendingPathComponent("Named Default Source")
                try SyntheticData.writeImportFixture(to:namedSource)
                let sidebarURL=namedSource.appendingPathComponent("StorableSidebar.json")
                var sidebarRoot=try JSONSerialization.jsonObject(with:Data(contentsOf:sidebarURL)) as! [String:Any]
                var sidebar=sidebarRoot["sidebar"] as! [String:Any],containers=sidebar["containers"] as! [Any]
                var holder=containers[1] as! [String:Any],spaces=holder["spaces"] as! [Any],namedSpace=spaces[1] as! [String:Any]
                namedSpace["profile"]="Default";spaces[1]=namedSpace;holder["spaces"]=spaces;containers[1]=holder;sidebar["containers"]=containers;sidebarRoot["sidebar"]=sidebar
                try JSONSerialization.data(withJSONObject:sidebarRoot).write(to:sidebarURL)
                try JSONSerialization.data(withJSONObject:["profiles":["Default",["id":"Default","name":"Example Named Default","directoryBasename":"Example-Named"]]]).write(to:namedSource.appendingPathComponent("StorableProfiles.json"))
                let namedOutput=env.root.appendingPathComponent("Named Default Output"),process=Process(),pipe=Pipe()
                process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("openkit")
                process.arguments=["import-arc","--arc-dir",namedSource.path,"--out",namedOutput.path]
                process.standardOutput=pipe;process.standardError=pipe
                try process.run();_=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                try require(process.terminationStatus == 0,"named Default CLI import failed")
                let namedModel=try SnapshotStore(root:namedOutput).load()
                try require(namedModel?.profiles.count == 2 && namedModel?.profiles.contains(where:{$0.dataDirectoryName == "Example-Named"}) == true,"probe refactor changed named Default import semantics")
                let pendingSource=env.root.appendingPathComponent("Pending Probe")
                try SyntheticData.writeImportFixture(to:pendingSource)
                try Data("invalid database".utf8).write(to:pendingSource.appendingPathComponent("User Data/Default/History"))
                let earlyActions=PreviewFirstRunActions();earlyActions.nextOutcome=ImportOutcome(counts:["Spaces":2])
                let early=FirstRunViewModel(settings:vm,actions:earlyActions,directory:pendingSource)
                let pendingCount=Task {await early.refreshProbe()};await Task.yield()
                try require(early.wizard.busy && !early.wizard.isImporting,"slow probe fixture was not counting")
                early.startFresh();try require(earlyActions.events == ["finishFirstRun imported=false"],"counting blocked Start fresh")
                early.showImport();early.skipImport();try require(early.step == .defaultBrowser,"counting blocked Not now")
                early.showImport();await early.continueImport();try require(early.step == .report && earlyActions.plans.count == 1,"counting blocked Continue")
                await pendingCount.value;try require(early.step == .report && early.probe?.historyVisits == nil,"late probe changed the import step")
                let history=directory.appendingPathComponent("User Data/Default/History")
                var writer:OpaquePointer?
                guard sqlite3_open(history.path,&writer) == SQLITE_OK else {throw CheckFailure(description:"WAL writer did not open")}
                defer {sqlite3_exec(writer,"ROLLBACK",nil,nil,nil);sqlite3_close(writer)}
                try require(sqlite3_exec(writer,"PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO visits VALUES(7,1,13437000040000000,0,0); BEGIN IMMEDIATE; INSERT INTO visits VALUES(8,1,13437000050000000,0,0);",nil,nil,nil) == SQLITE_OK,"WAL fixture writer failed")
                let dbBefore=try Data(contentsOf:history),walURL=URL(fileURLWithPath:history.path+"-wal"),walBefore=try Data(contentsOf:walURL)
                let locked=await ArcProbe(arcDirectory:directory).run()
                try require(locked.historyVisits == 4 && locked.secretRows == 4,"WAL-locked source lost committed rows or read uncommitted rows")
                try require(try Data(contentsOf:history) == dbBefore && Data(contentsOf:walURL) == walBefore,"probe changed its source")
                print("PROBE fixture spaces=2 items=4 archive=2 raw-archive=3 history=3 saved=4; WAL history=4; empty sidebar=false; seconds=\(seconds)")
            case "first-run-actions-and-adapter-gate":
                let (flow,actions)=try await firstRunPreview(env)
                let bytes=try Data(contentsOf:vm.snapshot.fileURL)
                try require(flow.step == .welcome && flow.includeSpacesAndTabs && flow.includeArchive && !flow.includeHistory && !flow.includeSecrets && actions.events.isEmpty,"first-run defaults performed an action")
                flow.startFresh();try require(actions.events == ["finishFirstRun imported=false"],"fresh path performed import or default-browser work")
                actions.events=[];flow.showImport();flow.includeSpacesAndTabs=false;flow.includeArchive=false;flow.includeSecrets=true
                try require(!flow.hasSelection,"OFF passwords must not enable an empty import")
                await flow.continueImport();try require(actions.plans.isEmpty && flow.step == .importChoices,"OFF passwords navigated to consent")
                flow.includeSpacesAndTabs=true;flow.includeArchive=true;actions.canImportPasswordsAndCookies=true
                await flow.continueImport()
                try require(flow.step == .secretsConsent && actions.plans.isEmpty,"consent did not stop import")
                flow.cancelPasswords();try require(flow.step == .importChoices && actions.plans.isEmpty,"consent cancel ran an action")
                await flow.continueImport();actions.canImportPasswordsAndCookies=false;await flow.allowPasswords()
                try require(flow.step == .secretsConsent && actions.plans.isEmpty,"unavailable capability granted consent")
                actions.canImportPasswordsAndCookies=true;await flow.skipPasswords()
                try require(flow.step == .report && actions.plans.count == 1 && !actions.plans[0].secretsConsented && actions.simulatedKeychainRequests == 0,"skip path requested passwords")
                try require(try Data(contentsOf:vm.snapshot.fileURL) == bytes && vm.defaults.object(forKey:"open.firstRun.completed") == nil,"preview flow wrote completion or snapshot")
                flow.enterDefaultBrowser();try require(!flow.isDefaultBrowser && !actions.events.contains("setAsDefaultBrowser"),"default step prompted on entry")
                actions.defaultError="synthetic failure";flow.makeDefault();try require(flow.errorText != nil && !flow.isDefaultBrowser,"default failure lost finish controls")
                actions.defaultError=nil;actions.declineDefault=true;flow.makeDefault();try require(flow.defaultWasAttempted && !flow.isDefaultBrowser && flow.errorText == nil,"declined default was not shown")
                actions.declineDefault=false;flow.makeDefault();try require(flow.isDefaultBrowser,"default success not refreshed")
                flow.finish();try require(actions.events.last == "finishFirstRun imported=true","finish lost the imported state")
                actions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.tabs:3]);flow.showImport();flow.includeSecrets=false;await flow.continueImport();flow.finish()
                try require(flow.wizard.hasImportedData && flow.wizard.reportCount("Imported tabs") == 3 && actions.events.last == "finishFirstRun imported=true","canonical adapter keys lost the imported finish flag")
                try require(flow.reportValue("History") == "Not selected","unselected History showed zero")
                // Exercise the display copy through the same caller flow, with one-item and large outcomes.
                actions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.spaces:1,ImportOutcomeKeys.tabs:1,"Archive":1,"History":1,"Skipped easels":1,"Duplicates":1])
                flow.showImport();flow.includeHistory=true;await flow.continueImport()
                try require(flow.reportSummary == "1 Space, 1 tab, 1 archived tab imported." && flow.reportNote == "Skipped: 1 Easel" && flow.duplicateSummary == "1 item was already in Open and was not copied again.","singular report copy regressed")
                actions.canImportPasswordsAndCookies=false
                var one=flow.probe!;one.spaces=1;one.sidebarItems=1;one.historyVisits=1;one.savedItems=1;flow.probe=one
                try require(flow.welcomeStatus == "Found data to import: 1 Space, about 1 tab." && flow.found(1,singular:"visit",plural:"visits") == "Found: 1 visit" && flow.passwordsCopy.body == "Open found 1 saved item in Arc. Open didn't read or copy it.","singular found or shared Passwords copy regressed")
                one.historyVisits=184203;one.savedItems=100001;flow.probe=one
                actions.nextOutcome=ImportOutcome(counts:[ImportOutcomeKeys.spaces:120,ImportOutcomeKeys.tabs:12000,"History":184203],errorText:"Your Spaces and tabs are in. Some history could not be read.",failures:["Archive":"unreadable"])
                flow.showImport();await flow.continueImport()
                try require(flow.reportSummary == "120 Spaces, \(12000.formatted()) tabs imported." && flow.reportValue("History") == 184203.formatted() && !flow.reportNoteIsError,"partial summary includes failed data or styles good news as an error")
                try require(flow.found(184203,singular:"visit",plural:"visits") == "Found: \(184203.formatted()) visits" && flow.passwordsCopy.body.contains(100001.formatted()),"large counts are unformatted")
                flow.probe=ArcProbeResult();try require(flow.prefersFreshStart,"no-data Welcome did not prefer Start Fresh")
                flow.probe=one;flow.reportSaveFailure(imported:false);try require(flow.prefersFreshStart,"fresh save error did not prefer Start Fresh")
                actions.nextOutcome=ImportOutcome(errorText:"Open could not read your Arc data.");flow.showImport();flow.includeSecrets=false;await flow.continueImport()
                try require(flow.step == .failed,"failed import did not reach retry")
                flow.skipImport();flow.finish();try require(actions.events.last == "finishFirstRun imported=false","failed import finished as imported")
            case "first-run-count-parity":
                let directory=env.root.appendingPathComponent("Parity Source")
                try SyntheticData.writeProbeFixture(to:directory)
                let archiveURL=directory.appendingPathComponent("StorableArchiveItems.json")
                var archive=try JSONSerialization.jsonObject(with:Data(contentsOf:archiveURL)) as! [String:Any]
                var items=archive["items"] as! [Any]
                let valid=items[1] as! [String:Any]
                items += ["duplicate",valid]
                for (id,change) in [("bad-reason",0),("bad-source",1),("bad-url",2),("example-tab-0",3)] {
                    var row=valid
                    var sidebar=row["sidebarItem"] as! [String:Any];sidebar["id"]=id
                    if change == 0 {row["reason"]="unknown"}
                    if change == 1 {row["source"]=["unknown":[:]]}
                    if change == 2 {sidebar["data"]=["tab":["savedURL":"http://[invalid"]]}
                    row["sidebarItem"]=sidebar;items += [id,row]
                }
                archive["items"]=items;try JSONSerialization.data(withJSONObject:archive).write(to:archiveURL)
                // An unused named Default is distinct from the real default, and its unreadable
                // databases must not hide successful counts from the default profile.
                try JSONSerialization.data(withJSONObject:["profiles":["Default",["id":"Default","name":"Example Named Default","directoryBasename":"Example-Named"]]]).write(to:directory.appendingPathComponent("StorableProfiles.json"))
                let bad=directory.appendingPathComponent("User Data/Example-Named")
                try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:directory.appendingPathComponent("User Data/Default/History"),to:bad.appendingPathComponent("History"))
                var database:OpaquePointer?
                try require(sqlite3_open(bad.appendingPathComponent("History").path,&database) == SQLITE_OK,"partial fixture open")
                let updated=sqlite3_exec(database,"UPDATE meta SET value='80' WHERE key='version';",nil,nil,nil);sqlite3_close(database)
                try require(updated == SQLITE_OK,"partial fixture schema")
                try Data("invalid database".utf8).write(to:bad.appendingPathComponent("Cookies"))
                let probe=await ArcProbe(arcDirectory:directory).run()
                let parsed=try await Task.detached(priority:.utility) {try ArcImporter(arcDirectory:directory).readSidebar()}.value
                let imported=try ArcImporter(arcDirectory:directory).importAll(sidebar:parsed)
                try require(probe.archiveItems == imported.report.archiveImported && probe.archiveItems == imported.archiveRecords.count && probe.archiveItems == 2,"probe Archive differs from actual importer filters")
                try require(imported.report.archiveDuplicatesInFile == 1 && imported.report.archiveAlreadyLive == 1 && imported.report.archiveSkippedUnknownReason == 1 && imported.report.archiveSkippedUnknownSource == 1 && imported.report.archiveSkippedMalformed == 1,"parity fixture did not exercise Archive filters")
                try require(probe.settingsCounts["Profiles"] == imported.report.profiles && imported.report.profiles == 2 && probe.settingsCounts["Search settings"] == 2,"unused metadata profile or engine count differs from importer")
                try require(imported.model.profiles.contains{$0.name == "Example Named Default" && $0.dataDirectoryName == "Example-Named"},"named Default collapsed")
                try require(probe.historyVisits == 3 && probe.secretRows == 4 && probe.savedItems == 4 && probe.historyPartial && probe.savedItemsPartial && probe.profileCounts.count == 2,"bad profile erased successful counts")
                let wizard=ImportWizardViewModel(root:vm,directory:directory);await wizard.refreshCounts()
                try require(wizard.canContinue && wizard.spaceMapping.count == 2 && wizard.countLabel("History") == "Found: 3 (partial)" && wizard.countLabel("Passwords and cookies") == "Found: 4 (partial)","partial counts or mapping not ready before Review")
                print("PARITY actual-import archive=2 profiles=2 engines=2 history=3(partial) saved=4(partial)")
            case "probe-cancel-mid-copy":
                let receipt=try await ArcProbe.verifyCopyCancellation()
                try require(receipt.cancelled && receipt.copyStarted && receipt.copyWasPartial && receipt.privateModes && receipt.temporaryCopyRemoved && receipt.sourceUnchanged,"cancelled partial copy leaked files, changed its source, or bypassed cancellation")
                print("COPY cancelled-mid-file=true private-modes=true temp-removed=true source-unchanged=true")
            case "previews-legacy-migration":
                let cases: [(legacy: Bool, folders: Bool?)] = [(false, nil), (true, false), (false, true)]
                for (legacy, storedFolders) in cases {
                    let expectedFolders = storedFolders ?? legacy
                    let suite = "open.previews.migration.\(UUID().uuidString)"
                    let defaults = UserDefaults(suiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    defaults.set(legacy, forKey: "open.general.previewsOnHover")
                    if let storedFolders { defaults.set(storedFolders, forKey: "open.general.previewsFolders") }
                    let migrated = SettingsViewModel(model: vm.model, actions: env.actions, defaults: defaults, root: env.root, snapshot: vm.snapshot)
                    try require(migrated.bool("open.general.previewsFolders") == expectedFolders && migrated.bool("open.general.previewsPages") == legacy,
                                "legacy preview source choices were reset or an explicit new choice was overwritten")
                    try require(defaults.synchronize(), "migration did not flush to the existing defaults store")
                    let disk = defaults.persistentDomain(forName: suite)!
                    try require(disk["open.general.previewsFolders"] as? Bool == expectedFolders && disk["open.general.previewsPages"] as? Bool == legacy,
                                "preview migration did not persist the source keys")
                    defaults.set(true, forKey: "open.general.previewsPages")
                    defaults.set(false, forKey: "open.general.previewsOnHover")
                    let reloaded = SettingsViewModel(model: vm.model, actions: env.actions, defaults: UserDefaults(suiteName: suite)!, root: env.root, snapshot: vm.snapshot)
                    try require(reloaded.bool("open.general.previewsFolders") == expectedFolders && reloaded.bool("open.general.previewsPages"),
                                "repeat registration overwrote a later per-source choice")
                }
                print("Legacy preview false/true, missing keys, explicit choices, disk writes, and repeat startup passed")
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
            case "library-spaces":
                let library = env.library
                try require(env.actions.spaceManagerMakeCount == 0 && LibrarySection.allCases.first == .spaces,
                            "L1 Space Manager built before entry or Spaces is not first")
                library.section = .spaces
                let manager = library.spaceManagerView
                try require(manager != nil && env.actions.spaceManagerMakeCount == 1, "L1 factory did not supply the native view")
                let labels = try await render(LibraryContent(viewModel: library), size: CGSize(width: 960, height: 640), scale: 1, dark: true,
                                              to: env.root.appendingPathComponent("library-spaces-check.png"))
                try require(labels.contains("Space Manager preview"), "L1 injected view did not render")
                library.section = .archive
                library.statusText = "Folder restored. Click to view."; library.restoredSpaceID = vm.model.spaces[0].id
                library.section = .spaces
                try require(library.statusText.isEmpty && library.restoredSpaceID == nil, "L1 Spaces retained Archive status/View action")
                try require(library.spaceManagerView === manager && env.actions.spaceManagerMakeCount == 1,
                            "L1 section switches rebuilt the injected view")
                let persisted = try env.diskDefaults()
                try require(persisted["open.library.lastSection"] as? String == "spaces", "L1 selected section did not reach the existing defaults file")
                let reloaded = LibraryViewModel(model: vm.model, defaults: env.defaults, actions: env.libraryActions, downloads: env.downloadFeed,
                    captures: env.captures, archives: env.archives, histories: env.histories, snapshot: vm.snapshot, settingsActions: env.actions)
                try require(reloaded.section == .spaces && env.actions.spaceManagerMakeCount == 1, "L1 Spaces selection did not persist or factory was eager")
                env.actions.spaceManagerAvailable = false
                let emptyLabels = try await render(LibraryContent(viewModel: reloaded), size: CGSize(width: 960, height: 640), scale: 1, dark: true,
                                                   to: env.root.appendingPathComponent("library-spaces-unavailable-check.png"))
                try require(emptyLabels.contains("Spaces") && !emptyLabels.contains("Space Manager preview") && reloaded.spaceManagerView == nil, "L1 nil injection has no visible empty state")
                let attempts = env.actions.spaceManagerMakeCount
                env.actions.spaceManagerAvailable = true
                reloaded.section = .downloads; reloaded.section = .spaces
                let recovered = reloaded.spaceManagerView
                try require(recovered != nil && recovered !== manager && env.actions.spaceManagerMakeCount == attempts + 1,
                            "L1 transient nil was cached or a manager was shared across view models")
                try require(reloaded.spaceManagerView === recovered && env.actions.spaceManagerMakeCount == attempts + 1,
                            "L1 recovered manager was not cached")
                let recoveredLabels = try await render(LibraryContent(viewModel: reloaded), size: CGSize(width: 960, height: 640), scale: 1, dark: true,
                                                       to: env.root.appendingPathComponent("library-spaces-recovered-check.png"))
                try require(recoveredLabels.contains("Space Manager preview"), "L1 recovered manager did not render")
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
                let off = ImportWizardViewModel(root:vm,directory:source);await off.refreshCounts()
                off.plan.spaces=false;off.plan.tabs=false;off.plan.favorites=false;off.plan.folders=false;off.plan.archive=false;off.plan.searchSettings=false;off.plan.secretsRequested=true
                try require(!off.canContinue,"OFF Passwords enabled an empty Settings import")
                env.actions.canImportPasswordsAndCookies=true
                let consent = ImportWizardViewModel(root: vm, directory: source); await consent.refreshCounts(); consent.plan.secretsRequested = true; consent.review()
                let calls = env.actions.log.count; await consent.beginImport()
                try require(consent.step == .consent && !consent.plan.secretsConsented && env.actions.log.count == calls, "consent did not gate import")
                consent.finish(); try require(env.actions.importPlansWithConsent == 0 && env.actions.log.count == calls, "wizard gate: cancel called import or granted consent")
                let allowed = ImportWizardViewModel(root: vm, directory: source); await allowed.refreshCounts(); allowed.plan.secretsRequested = true; allowed.review(); await allowed.beginImport(); env.actions.canImportPasswordsAndCookies=false; await allowed.allowAndImportSecrets(); try require(allowed.step == .consent && !allowed.plan.secretsConsented, "count-only capability allowed consent"); await allowed.skipSecrets()
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
            case "library-tidy-search":
                let space = vm.model.spaces[0]
                let raw = "Inbox (3) - accountneedle@example.invalid - Gmail"
                let gmail = vm.model.newTab(in: space.id, url: URL(string: "https://mail.google.com/mail/#inbox")!, title: raw)
                let custom = vm.model.newTab(in: space.id, url: URL(string: "https://docs.google.com/document/d/example")!, title: "Raw - Google Docs")
                vm.model.renameNode(id: custom.id, title: "My literal - Google Docs")
                vm.model.closeTab(id: gmail.id); vm.model.closeTab(id: custom.id)
                (vm.model.archiveSink as? ProfileArchiveSink)?.flushAll()
                let library = env.library
                library.query = "accountneedle"; await library.reloadArchive()
                try require(library.archiveRows.count == 1 && library.archiveRows[0].id == gmail.id && library.archiveRows[0].title == raw,
                            "Gmail archive search lost text removed by tidy")
                try require(library.archivedDisplayTitle(library.archiveRows[0]) == "Inbox", "Library did not tidy the raw Gmail search result")
                library.query = ""; await library.reloadArchive()
                let customRow = library.archiveRows.first { $0.id == custom.id }!
                try require(library.archivedDisplayTitle(customRow) == "My literal - Google Docs", "Library tidied a custom title")
                let directory = env.root.appendingPathComponent("Tidy Import")
                try SyntheticData.writeImportFixture(to: directory)
                let item: [String: Any] = ["sidebarItem": ["id": "tidy-import-gmail", "data": ["tab": ["savedURL": gmail.url.absoluteString, "savedTitle": raw]]],
                                           "reason": "manual", "archivedAt": 800000000, "source": ["space": ["_0": "example-space-0"]]]
                try JSONSerialization.data(withJSONObject: ["items": ["tidy-import-gmail", item]])
                    .write(to: directory.appendingPathComponent("StorableArchiveItems.json"))
                let importer = ArcImporter(arcDirectory: directory)
                let parsed = try importer.readSidebar()
                let imported = try importer.importAll(sidebar: parsed)
                let store = ArchiveStore(fileURL: env.root.appendingPathComponent("tidy-import.sqlite3"))
                let inserted = await store.importRecords(imported.archiveRecords)
                let found = await store.search("accountneedle")
                try require(inserted.inserted == 1 && found.count == 1 && found[0].title == raw,
                            "imported Gmail archive did not retain the raw search title")
                print("T2 archive Gmail raw search, tidy display, custom title, and real Arc import passed")
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
                vm.model.closeTab(id: folder.id)
                (vm.model.archiveSink as? ProfileArchiveSink)?.flushAll()
                await library.reloadArchive()
                try archiveDeleteTrigger(env.archives[space.profileID]!.fileURL, enabled: true)
                await library.restore(id: folder.id)
                try archiveDeleteTrigger(env.archives[space.profileID]!.fileURL, enabled: false)
                try require(library.statusText.hasPrefix("Folder restored, but its Archive entry"), "folder archive-delete failure was called a Tab restore")
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
                let reloaded = FileCapturesProvider(root: env.root)
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
                let emptyCount = await countArchive(env.archives); try require(emptyCount == 0 && (FileCapturesProvider(root: env.root)).captures.isEmpty, "empty stores not on disk")
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
                if ProcessInfo.processInfo.environment["OPEN_SETTINGS_CORRUPT_LIST_FIXTURE"] == "1" {
                    try env.listServer!.corruptFixture()
                }
                let created=vm.profiles.create(name:"Example Loading Profile")!
                let calls=env.actions.log.count
                try require(!ad.isReady && !ad.openedProfiles.contains(created.id),"new Profile was ready before open")
                ad.setExcluded("example.org",excluded:true)
                try require(ad.errorText == "Ad block settings are still loading for this Profile." && env.actions.log.count == calls,"loading host control wrote or showed an internal fault")
                await ad.openSelectedProfile()
                try require(ad.isReady && ad.openedProfiles.contains(created.id),"successful open did not enable edits")
                let directory = ad.store.listDirectory(for: created.id)
                let state = try JSONDecoder().decode(AdBlockProfileState.self, from: Data(contentsOf: directory.appendingPathComponent("catalog-state.json")))
                try require(Set(state.enabledBlockLists) == Set(["EasyList", "EasyPrivacy"]) && Set(state.lists.keys) == Set(state.enabledBlockLists) && state.lists.values.allSatisfy { !$0.sources.isEmpty && $0.bytes > 0 }, "ready Profile did not publish downloaded filter receipts")
                struct Current: Decodable { struct Reference: Decodable { let generation: Int }; let live: Reference }
                let current = try JSONDecoder().decode(Current.self, from: Data(contentsOf: directory.appendingPathComponent("current.json")))
                try require(current.live.generation > 0, "ready Profile has no current filter generation")
                for id in state.enabledBlockLists {
                    let list = try Data(contentsOf: directory.appendingPathComponent("generations/\(current.live.generation)/\(id).txt"))
                    try require(list == SyntheticListServer.validFixture, "ready Profile did not use the local filter fixture")
                }
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
    static let validFixture = Data("[Adblock Plus 2.0]\n! Example synthetic regional list\n||example.org/ad^\n".utf8)
    let process = Process()
    private let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("open-filter-fixture-\(UUID().uuidString).txt")
    private let previous = ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_SOURCE_ROOT"]
    init() throws {
        try Self.validFixture.write(to: fixture)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
import http.server, pathlib, sys
fixture=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=fixture.read_bytes()
  self.send_response(200); self.send_header('Content-Type','text/plain'); self.send_header('ETag','synthetic-v1'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
""", fixture.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else { process.terminate(); throw CheckFailure(description: "could not start synthetic list server") }
        setenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT", "http://127.0.0.1:\(port)", 1)
    }
    func corruptFixture() throws { try Data("<html>invalid filter fixture</html>".utf8).write(to: fixture, options: .atomic) }
    func stop() { try? FileManager.default.removeItem(at: fixture); if process.isRunning { process.terminate(); process.waitUntilExit() }; if let previous { setenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT", previous, 1) } else { unsetenv("OPEN_ADBLOCK_DEBUG_SOURCE_ROOT") } }
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
