import Foundation
import OpenModel
import OpenSuggest

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
