import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenStore

@MainActor @Observable public final class AdvancedViewModel {
    unowned let root: SettingsViewModel
    public var statusText = ""
    public init(root: SettingsViewModel) { self.root = root }
    public var sleepMode: TabSleepMode { get { TabSleepMode(rawValue: root.string("open.advanced.tabSleepMode")) ?? .automatic } set { root.set(newValue.rawValue, for: "open.advanced.tabSleepMode") } }
    public func resetTranslate() { statusText = root.actions.resetTranslatePrompts(profileID: root.selectedProfileID) ?? "Done" }
    public func export(to url: URL) async {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshotData = try encoder.encode(SnapshotMapper.dto(from: root.model))
            var archived: [[String: String]] = []
            for profile in root.model.profiles {
                let store = ArchiveStore(fileURL: ProfileDirectories(root: root.root).archiveFileURL(for: profile))
                for item in await store.recent(limit: Int(Int32.max)) { archived.append(["id": item.id.description, "host": item.url.host() ?? "", "title": item.title, "reason": item.reason.rawValue]) }
            }
            let data = try JSONSerialization.data(withJSONObject: ["snapshot": JSONSerialization.jsonObject(with: snapshotData), "archive": archived], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic); statusText = "Exported."
        } catch { statusText = "Export failed. \(error.localizedDescription)" }
    }
}
public struct AdvancedPane: View {
    @Bindable var model: AdvancedViewModel
    public init(model: AdvancedViewModel) { self.model = model }
    public var body: some View {
        SettingsGroup("Browsing") {
            PreferenceToggle(title: "When opening Open, restore windows from previous session", key: "open.advanced.restoreWindowsOnLaunch", root: model.root)
            Divider()
            PreferenceToggle(title: "Enable Picture in Picture when you leave a video tab", key: "open.advanced.enablePictureInPictureOnLeave", root: model.root)
        }
        SettingsGroup("Appearance and Input") {
            PreferenceToggle(title: "Allow window dragging from the top of webpages", key: "open.advanced.allowWindowDraggingFromWebTop", root: model.root)
            PreferenceToggle(title: "Show full URL when Toolbar is enabled", key: "open.advanced.showFullURLWithToolbar", root: model.root)
            PreferenceToggle(title: "Allow websites to get your theme data", key: "open.advanced.allowSitesThemeData", root: model.root)
            PreferenceToggle(title: "Play Open sound effects", key: "open.advanced.playSoundEffects", root: model.root)
            PreferenceToggle(title: "Haptic feedback when reordering tabs", key: "open.advanced.hapticOnTabReorder", root: model.root)
        }
        SettingsGroup("Features") {
            PreferenceToggle(title: "Enable Boosts on websites you visit", key: "open.advanced.enableBoosts", root: model.root)
            PreferenceToggle(title: "Enable Shared Quotes when highlighting text", key: "open.advanced.enableSharedQuotes", root: model.root)
        }
        SettingsGroup("Search") { Button("Manage Search Engines…") { model.root.selectedPane = .profiles; model.root.showsSearchEngines = true } }
        SettingsGroup("Ad Blocking") { Text("Needs the browser engine").foregroundStyle(.secondary) }
        SettingsGroup("Tab Sleeping") { Text("\(model.sleepMode.rawValue.capitalized) — Needs the browser engine").foregroundStyle(.secondary) }
        SettingsGroup("Data and Developer") {
            HStack { Button("More Settings…") { model.root.actions.openMoreSettings() }; Button("Reset Translated-site Prompts") { model.resetTranslate() } }
            Button("Export Data…") {
                let panel = NSSavePanel(); panel.nameFieldStringValue = "Open-export.json"
                if panel.runModal() == .OK, let url = panel.url { Task { await model.export(to: url) } }
            }
            HStack { Button("Show Data Folder") { model.root.actions.revealOpenDataFolder() }; Button("Copy Open Info") { model.root.actions.copyOpenInfoToPasteboard() } }
            Text(model.statusText).foregroundStyle(.secondary)
        }
    }
}
