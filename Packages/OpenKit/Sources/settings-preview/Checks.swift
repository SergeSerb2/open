import Foundation
import OpenSettings
import OpenModel
import OpenStore
import OpenCommands

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw CheckFailure(description: message) } }
@MainActor final class PreviewEnvironment {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let actions: PreviewActions
    let settings: SettingsViewModel
    let library: LibraryViewModel
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("open-settings-\(UUID().uuidString)")
        suite = "open.settings.preview.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        actions = PreviewActions()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
        settings = SettingsViewModel(model: SyntheticData.model(), actions: actions, defaults: defaults, root: root)
        library = LibraryViewModel(defaults: defaults)
        try settings.flush()
        try Data("synthetic-settings-v1".utf8).write(to: root.appendingPathComponent("State/settings-preview.marker"))
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
    let names = ["general-toggles", "default-browser", "profile-search", "profile-archive-scope", "profile-downloads", "clear-data", "profile-guards", "advanced-toggles", "app-icon"]
    if let only { try require(names.contains(only), "Unknown check \(only)") }
    var passed = 0
    for name in names where only == nil || only == name {
        let env = try PreviewEnvironment(); defer { env.close() }
        let vm = env.settings
        do {
            switch name {
            case "general-toggles":
                vm.general.warn = false; vm.general.updates = false
                let disk = try env.diskDefaults()
                try require(disk["open.general.warnBeforeQuitting"] as? Bool == false && disk["open.general.automaticallyUpdate"] as? Bool == false, "toggles not on disk: \(disk)")
                let reloaded = SettingsViewModel(model: vm.model, actions: env.actions, defaults: UserDefaults(suiteName: env.suite)!, root: env.root, snapshot: vm.snapshot)
                try require(!reloaded.general.warn && !reloaded.general.updates && env.actions.log.isEmpty, "relaunch/action mismatch")
            case "default-browser":
                env.actions.defaultError = "Default browser request failed."
                vm.general.setDefault()
                try require(vm.general.errorText == env.actions.defaultError && !vm.general.isDefault, "missing inline default error")
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
            case "advanced-toggles":
                vm.set(true, for: "open.advanced.allowWindowDraggingFromWebTop"); vm.advanced.sleepMode = .aggressive
                let disk = try env.diskDefaults()
                try require(disk["open.advanced.allowWindowDraggingFromWebTop"] as? Bool == true && disk["open.advanced.tabSleepMode"] as? String == "aggressive", "advanced persistence")
            case "app-icon":
                vm.appIcon.select(.openColor)
                let disk = try env.diskDefaults()
                try require(disk["open.appIcon.selectedID"] as? String == "openColor", "icon persistence")
                try require(env.actions.log == ["setApplicationIcon openColor"], "icon action missing")
            default: break
            }
            passed += 1; print("PASS \(name)")
        } catch { print("FAIL \(name): \(error)"); throw error }
    }
    print("SUMMARY \(passed) passed, 0 failed")
}
