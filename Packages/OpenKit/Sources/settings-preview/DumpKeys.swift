import Foundation
import OpenSettings
import OpenModel
import OpenStore
import OpenCommands
import OpenAdBlock

@discardableResult @MainActor func dumpKeys(root: URL) throws -> [String] {
    guard (try? String(contentsOf: root.appendingPathComponent("State/settings-preview.marker"), encoding: .utf8)) == "synthetic-settings-v1" else { throw CheckFailure(description: "dump-keys accepts settings-preview synthetic roots only") }
    var lines: [String] = []
    let defaultsURL = root.appendingPathComponent("State/preview-defaults.plist")
    let stored = (try? Data(contentsOf: defaultsURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    for key in Set(SettingsDefaults.values.keys).union(stored.keys).sorted() {
        let value = stored[key] ?? SettingsDefaults.values[key]!
        let formatted: String
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { formatted = number.boolValue ? "true" : "false" } else { formatted = String(describing: value) }
        lines.append("default \(key) = \(formatted)")
    }
    let dto = try JSONDecoder().decode(SnapshotFileDTO.self, from: Data(contentsOf: root.appendingPathComponent("State/browser.json")))
    // Reject changed markers on arbitrary profiles rather than printing user-owned data.
    guard Set(dto.profiles.map(\.name)).isSubset(of: ["Personal", "Work"]) else { throw CheckFailure(description: "root is not the synthetic fixture") }
    let model = SnapshotMapper.model(from: dto)
    for profile in model.profiles {
        let s = profile.settings
        let fields = ["autoArchiveAfter": s.autoArchiveAfter.rawValue, "littleOpenAutoArchiveAfter": s.littleOpenAutoArchiveAfter.rawValue,
                      "searchEngineID": s.searchEngineID, "searchSuggestEnabled": String(s.searchSuggestEnabled), "downloadDirectory": s.downloadDirectory,
                      "askWhereToSaveEachFile": String(s.askWhereToSaveEachFile), "customSearchEngines": s.customSearchEngines.map(\.id).joined(separator: ",")]
        for key in fields.keys.sorted() { lines.append("snapshot profile \(profile.name) \(key) = \(fields[key]!)") }
        let directory = root.appendingPathComponent("Profiles/\(profile.id.description)/adblock")
        let state = try JSONDecoder().decode(AdBlockProfileState.self, from: Data(contentsOf: directory.appendingPathComponent("catalog-state.json")))
        let exclusions = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("exclusions.json")))
        let enabled = ((try? Data(contentsOf: root.appendingPathComponent("adblock-settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] })?["nativeAdBlockEnabled"] ?? true
        lines.append("adblock \(profile.name) enabled=\(enabled) lists=\(state.enabledBlockLists.sorted().joined(separator: ",")) exclusions=\(exclusions.sorted().joined(separator: ","))")
    }
    let bindings = try KeyBindingStore.load(from: root.appendingPathComponent("State/keybindings.json"))
    for key in bindings.bindings.keys.sorted() { let value = bindings.bindings[key]!; lines.append("keybindings \(key) = \(value.shortcuts.map(\.display).joined(separator: ",")) priority=\(value.priority?.rawValue ?? "default")") }
    let sorted = lines.sorted(); sorted.forEach { print($0) }; return sorted
}
