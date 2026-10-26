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
    public var sleepMode: TabSleepMode { get { TabSleepMode(rawValue: root.string("open.advanced.tabSleepMode")) ?? .automatic } set { root.set(newValue.rawValue, for: "open.advanced.tabSleepMode"); root.actions.setTabSleepMode(newValue) } }
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
        SettingsGroup("Search") { Text("Search engine for \(model.root.profiles.profile?.name ?? "Profile"): \(model.root.profiles.engines.first(where: { $0.id == model.root.profiles.searchEngineID })?.name ?? "Google")"); Button("Manage Search Engines…") { model.root.selectedPane = .profiles; model.root.showsSearchEngines = true } }
        if let adBlock = model.root.adBlock { AdBlockControls(model: adBlock) }
        else { SettingsGroup("Ad Blocking") { Text("Loading ad blocking…").foregroundStyle(.secondary) } }
        SettingsGroup("Tab Sleeping") {
            Picker("Mode", selection: $model.sleepMode) { ForEach(TabSleepMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Text("Sleep inactive tabs to save memory").foregroundStyle(.secondary)
            Text("Automatic: 5 min · Conservative: 15 min · Aggressive: 2 min. Pinned tabs freeze but never discard.").font(.caption).foregroundStyle(.secondary)
        }
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

private struct AdBlockControls: View {
    @Bindable var model: AdBlockSettingsModel
    @State private var expanded: Set<String> = ["generic"]
    private var categories: [String] { ["generic", "cookies", "privacy", "regional", "bcny"] }
    var body: some View {
        SettingsGroup("Ad Blocking") {
            Picker("Profile", selection: Binding(get: { model.root.selectedProfileID }, set: { model.root.selectedProfileID = $0 })) { ForEach(model.root.model.profiles, id: \.id) { Text($0.name).tag($0.id) } }.disabled(model.busy)
            SettingsSwitch("Block ads, trackers, and popups", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })).disabled(model.busy)
            Text("The master switch applies to all Profiles. List choices and allowed sites belong to the selected Profile.").font(.caption).foregroundStyle(.secondary)
            TextField("Search block lists", text: $model.query)
            ForEach(categories, id: \.self) { category in
                let lists = model.lists.filter { $0.category.lowercased() == category }
                if !lists.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(category) || !model.query.isEmpty }, set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })) {
                        ForEach(lists) { list in HStack {
                            Toggle(list.displayName, isOn: Binding(get: { model.enabledIDs.contains(list.id) }, set: { value in Task { await model.setList(list.id, enabled: value) } })).disabled(model.busy || list.urls.isEmpty)
                            Spacer(); Text(model.listStatus(list)).font(.caption).foregroundStyle(.secondary)
                            Link(destination: list.infoURL) { Image(systemName: "info.circle") }.help(list.unavailableReason ?? "About this list")
                        } }
                    } label: { Text("\(category == "bcny" ? "Open additions" : category.capitalized) (\(lists.count))") }
                }
            }
            if model.busy { ProgressView() }
            SettingsError(text: model.errorText)
            if let error = model.lastError { SettingsError(text: error) }
            Divider(); Text("Don't block on these sites")
            ForEach(model.domains, id: \.self) { host in HStack { Text(host); Spacer(); Button("Remove") { model.setExcluded(host, excluded: false) } } }
            HStack { TextField("example.com", text: $model.hostDraft).onSubmit { model.setExcluded(model.hostDraft, excluded: true) }; Button("Add") { model.setExcluded(model.hostDraft, excluded: true) }.disabled(model.hostDraft.isEmpty || model.busy) }
            HStack { Button("Copy Ad Block Debug Info") { model.copyDebug() }; Button("Reset List Choices") { Task { await model.reset() } }.disabled(model.busy) }
            if model.hasOtherBlocker { Text("More than one ad blocker is on. Blocking may double-block or break sites.").foregroundStyle(.orange) }
        }
    }
}
