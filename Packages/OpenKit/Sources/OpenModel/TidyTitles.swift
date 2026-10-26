import Foundation

public struct TidySite: Sendable {
    public let host: String
    public let siteName: String
    public let rules: [TidyRule]
    public init(host: String, siteName: String, rules: [TidyRule]) { self.host = host; self.siteName = siteName; self.rules = rules }
}
public struct TidyRule: Sendable {
    public let match: TidyMatch
    public let title: TidyTitle
    public init(match: TidyMatch, title: TidyTitle) { self.match = match; self.title = title }
}
public enum TidyMatch: Sendable {
    case any, pathEquals(String), pathMatches(String), fragmentEquals(String), fragmentMatches(String)
}
public enum TidyTitle: Sendable { case always(String), removing([String]) }

/// Open-written title rules from sidebar-completion §3.7. No reference-app data is used.
@MainActor
public enum TidyTitles {
    public static let sites: [TidySite] = [
        TidySite(host: "mail.google.com", siteName: "Gmail", rules: [
            TidyRule(match: .fragmentEquals("inbox"), title: .always("Inbox")),
            TidyRule(match: .fragmentEquals("starred"), title: .always("Starred")),
            TidyRule(match: .fragmentEquals("sent"), title: .always("Sent")),
            TidyRule(match: .fragmentEquals("drafts"), title: .always("Drafts")),
            TidyRule(match: .any, title: .removing([#" - [^ ]+@[^ ]+ - Gmail$"#]))
        ]),
        TidySite(host: "docs.google.com", siteName: "Google Docs", rules: [TidyRule(match: .any, title: .removing([#" - Google (Docs|Sheets|Slides|Forms)$"#]))]),
        TidySite(host: "drive.google.com", siteName: "Google Drive", rules: [TidyRule(match: .any, title: .removing([#" - Google Drive$"#]))]),
        TidySite(host: "calendar.google.com", siteName: "Google Calendar", rules: [TidyRule(match: .any, title: .removing([#"^Google Calendar - "#]))]),
        TidySite(host: "youtube.com", siteName: "YouTube", rules: [TidyRule(match: .any, title: .removing([#"^\(\d+\) "#, #" - YouTube$"#]))]),
        TidySite(host: "github.com", siteName: "GitHub", rules: [TidyRule(match: .any, title: .removing([#" · GitHub$"#]))]),
        TidySite(host: "x.com", siteName: "X", rules: [TidyRule(match: .any, title: .removing([#" / X$"#, #"^\(\d+\) "#]))]),
        TidySite(host: "twitter.com", siteName: "Twitter", rules: [TidyRule(match: .any, title: .removing([#" / X$"#, #"^\(\d+\) "#]))]),
        TidySite(host: "linkedin.com", siteName: "LinkedIn", rules: [TidyRule(match: .any, title: .removing([#"^\(\d+\) "#, #" \| LinkedIn$"#]))]),
        TidySite(host: "en.wikipedia.org", siteName: "Wikipedia", rules: [TidyRule(match: .any, title: .removing([#" - Wikipedia$"#]))]),
        TidySite(host: "stackoverflow.com", siteName: "Stack Overflow", rules: [TidyRule(match: .any, title: .removing([#" - Stack Overflow$"#]))]),
        TidySite(host: "figma.com", siteName: "Figma", rules: [TidyRule(match: .any, title: .removing([#" – Figma$"#]))]),
        TidySite(host: "app.slack.com", siteName: "Slack", rules: [TidyRule(match: .any, title: .removing([#" - Slack$"#]))]),
        TidySite(host: "outlook.live.com", siteName: "Outlook", rules: [TidyRule(match: .any, title: .removing([#" - Outlook$"#]))]),
        TidySite(host: "outlook.office.com", siteName: "Outlook", rules: [TidyRule(match: .any, title: .removing([#" - Outlook$"#]))]),
        TidySite(host: "amazon.com", siteName: "Amazon", rules: [TidyRule(match: .any, title: .removing([#"^Amazon\.com ?: ?"#]))])
    ]

    private enum Match {
        case any, path(String), fragment(String), pathRegex(NSRegularExpression), fragmentRegex(NSRegularExpression)
        func accepts(path: String, fragment: String) -> Bool {
            switch self {
            case .any: return true
            case .path(let value): return path == value
            case .fragment(let value): return fragment == value
            case .pathRegex(let regex): return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
            case .fragmentRegex(let regex): return regex.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)) != nil
            }
        }
    }
    private struct CompiledRule {
        let match: Match
        let fixedTitle: String?
        let removals: [NSRegularExpression]
        init(_ rule: TidyRule) {
            switch rule.match {
            case .any: match = .any
            case .pathEquals(let value): match = .path(value)
            case .fragmentEquals(let value): match = .fragment(value)
            case .pathMatches(let value): match = .pathRegex(try! NSRegularExpression(pattern: value))
            case .fragmentMatches(let value): match = .fragmentRegex(try! NSRegularExpression(pattern: value))
            }
            switch rule.title {
            case .always(let value): fixedTitle = value; removals = []
            case .removing(let patterns): fixedTitle = nil; removals = patterns.map { try! NSRegularExpression(pattern: $0) }
            }
        }
    }
    private struct Key: Hashable { let title: String; let host: String; let path: String; let fragment: String }
    private static let compiled = Dictionary(uniqueKeysWithValues: sites.map { ($0.host, $0.rules.map(CompiledRule.init)) })
    private static var cache: [Key: String] = [:]
    private static var order: [Key] = []
    private static var next = 0

    public static func tidy(title: String, url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard let rules = compiled[host] else { return title }
        let key = Key(title: title, host: host, path: url.path, fragment: url.fragment ?? "")
        if let value = cache[key] { return value }
        var result = title
        if let rule = rules.first(where: { $0.match.accepts(path: key.path, fragment: key.fragment) }) {
            if let fixed = rule.fixedTitle { result = fixed }
            else {
                for regex in rule.removals {
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
                }
                if result != title { result = result.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        if result.isEmpty { result = title }
        if order.count == 512 { cache[order[next]] = nil; order[next] = key; next = (next + 1) % 512 }
        else { order.append(key) }
        cache[key] = result
        return result
    }
}
