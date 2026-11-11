import Foundation
import OpenSettings
import OpenSuggest

/// The existing command-bar provider contract and action ranking are sufficient.
/// Only public setting metadata is indexed; this never constructs Settings.
@MainActor
struct SettingsSuggestionsProvider: SuggestProvider {
  let id = "settings"
  static let prefix = "settings-link:"
  static func url(for action: String) -> URL? {
    guard action.hasPrefix(prefix) else { return nil }
    let row = String(action.dropFirst(prefix.count))
    return SettingsSearchIndex.entries.first { $0.id == row }?.url
  }
  func localSuggestions(for input: SuggestInput) -> [Suggestion] {
    guard input.context.mode != .searchTabs, input.siteSearch == nil,
      input.context.extensionScopeID == nil else { return [] }
    let query = input.text.lowercased().replacingOccurrences(of: "settings:", with: "").trimmingCharacters(in: .whitespaces)
    guard query.count >= 3 else { return [] }
    let words = query.split(whereSeparator: \.isWhitespace)
    return Array(SettingsSearchIndex.entries.lazy.filter { entry in
      entry.commandID == nil && words.allSatisfy { word in
        (entry.label + " " + entry.help + " " + entry.synonyms + " " + entry.section.title).localizedCaseInsensitiveContains(String(word))
      }
    }.prefix(6)).map { entry in
      Suggestion(id: "settings:" + entry.id, kind: .action, title: "Settings: " + entry.label,
        subtitle: entry.section.title, actionID: Self.prefix + entry.id, icon: .symbol("gearshape"),
        provider: id, scoreDetail: ScoreDetail(quality: entry.label.lowercased().hasPrefix(query) ? MatchQuality.prefix : MatchQuality.substring, weight: Ranking.weight(.action)))
    }
  }
}
