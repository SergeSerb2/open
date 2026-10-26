import Foundation
import OpenModel

/// Immutable, compiled host suffixes and case-sensitive path prefixes. No regex.
public final class KeepAliveRules: Sendable {
    public static let settingsKey = "open.sleep.keepAliveSites"

    /// This key has a separate array in each profile's suite, never an app-wide list.
    public static func defaults(for profileID: ProfileID) -> UserDefaults {
        UserDefaults(suiteName: "open.profile.\(profileID.rawValue.uuidString)")!
    }

    private struct SourceRule: Decodable {
        let host: String
        let path: String?
    }
    private struct Resource: Decodable { let rules: [SourceRule] }
    private struct Rule: Sendable {
        let labels: [Substring]
        let path: String?
        let anyTLD: Bool

        init?(host: String, path: String?) {
            var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            anyTLD = labels.last == "*"
            if anyTLD { labels.removeLast() }
            guard labels.count >= (anyTLD ? 1 : 2), labels.allSatisfy({ label in
                !label.isEmpty && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }
            }) else { return nil }
            if let path, !path.hasPrefix("/") || path.contains("?") || path.contains("#") { return nil }
            self.labels = labels; self.path = path
        }

        func matches(_ host: [Substring], path: String) -> Bool {
            if let prefix = self.path, !path.hasPrefix(prefix) { return false }
            if !anyTLD { return host.suffix(labels.count).elementsEqual(labels) }
            // The trailing * consumes one or more TLD labels, including co.uk.
            guard host.count > labels.count else { return false }
            for start in 0..<(host.count - labels.count) {
                if host[start..<(start + labels.count)].elementsEqual(labels) { return true }
            }
            return false
        }
    }

    public static let builtIn: KeepAliveRules = {
        // A missing or malformed shipped table is a packaging error, not an empty list.
        let url = Bundle.module.url(forResource: "keep-alive-sites", withExtension: "json")!
        let source = try! JSONDecoder().decode(Resource.self, from: Data(contentsOf: url))
        return KeepAliveRules(rules: source.rules.map { Rule(host: $0.host, path: $0.path)! })
    }()

    private let rules: [Rule]
    private init(rules: [Rule]) { self.rules = rules }

    /// User entries extend the built-in list. Invalid entries have no effect.
    public convenience init(userSites: [String]) {
        let userRules = userSites.compactMap { site -> Rule? in
            let parts = site.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            return Rule(host: String(parts[0]), path: parts.count == 2 ? "/" + parts[1] : nil)
        }
        self.init(rules: Self.builtIn.rules + userRules)
    }

    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        let path = url.path(percentEncoded: true)
        return rules.contains { $0.matches(labels, path: path) }
    }
}
