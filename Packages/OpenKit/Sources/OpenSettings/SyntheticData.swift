import Foundation
import OpenModel
import OpenSuggest
import OpenCommands
import CryptoKit

@MainActor public enum SyntheticData {
    public static func model() -> BrowserModel {
        let personal = Profile(id: ProfileID(uuidString: "10000000-0000-0000-0000-000000000001"), name: "Personal")
        let work = Profile(id: ProfileID(uuidString: "10000000-0000-0000-0000-000000000002"), name: "Work", dataDirectoryName: "Profile 1")
        personal.settings.searchEngineID = "google"
        work.settings.searchEngineID = "duckduckgo"; work.settings.searchSuggestEnabled = false
        work.settings.autoArchiveAfter = .twentyFourHours
        work.settings.customSearchEngines = [SearchEngine(id: "custom-docs", name: "Docs Search", keywords: ["docs"], searchURLTemplate: "https://example.com/search?q=%s", suggestURLTemplate: nil)]
        let spaces = ["Home", "Reading", "Office"].enumerated().map { i, name in Space(id: SpaceID(uuidString: "20000000-0000-0000-0000-00000000000\(i+1)"), title: name, profileID: i == 2 ? work.id : personal.id) }
        let rules = [RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000001"), match: .hostEquals("example.com"), destination: .space(spaces[0].id)), RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000002"), match: .hostContains("docs"), destination: .space(spaces[2].id)), RoutingRule(id: RuleID(uuidString: "30000000-0000-0000-0000-000000000003"), match: .urlPrefix("https://example.net/a"), destination: .littleOpen)]
        return BrowserModel(profiles: [personal, work], spaces: spaces, windows: [BrowserWindowState(id: WindowID(uuidString: "40000000-0000-0000-0000-000000000001"), focusedSpaceID: spaces[0].id)], routingRules: rules)
    }
}

extension SyntheticData {
    /// Tiny synthetic filter generations use the real store's receipt format, never bundled art/data.
    public static func seedSettings(root: URL, model: BrowserModel) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
        try KeyBindingStore(bindings: ["new-tab": .init(shortcuts: [.ctrl("t")]), "zoom-in": .init(shortcuts: [])]).save(to: root.appendingPathComponent("State/keybindings.json"))
        let lists = ["EasyList", "EasyPrivacy"]
        for profile in model.profiles {
            let directory = root.appendingPathComponent("Profiles/\(profile.id.description)/adblock")
            let generation = directory.appendingPathComponent("generations/1")
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            var receipts: [String: Any] = [:], files: [[String: Any]] = []
            for id in lists {
                let data = Data("[Adblock Plus 2.0]\n! Example synthetic \(id)\n||example.net/advert^\n".utf8)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try data.write(to: generation.appendingPathComponent("\(id).txt"))
                receipts[id] = ["sha256": hash, "bytes": data.count, "sources": [], "lastCheck": 0]
                files.append(["file": "\(id).txt", "bytes": data.count, "sha256": hash, "listID": id, "sourceRevision": [hash], "generation": 1])
            }
            let state: [String: Any] = ["catalogVersion": 1, "enabledBlockLists": lists, "lists": receipts]
            let manifest = try JSONSerialization.data(withJSONObject: ["generation": 1, "files": files, "state": state], options: .sortedKeys)
            try manifest.write(to: generation.appendingPathComponent("manifest.json"))
            let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: ["live": ["generation": 1, "manifestSHA256": hash]], options: .sortedKeys).write(to: directory.appendingPathComponent("current.json"))
            try JSONSerialization.data(withJSONObject: state, options: .sortedKeys).write(to: directory.appendingPathComponent("catalog-state.json"))
            try JSONEncoder().encode(profile.id == model.profiles.first?.id ? ["example.com"] : []).write(to: directory.appendingPathComponent("exclusions.json"))
        }
    }
}
