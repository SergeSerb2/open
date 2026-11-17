import Foundation
import OpenModel

extension ArcImporter {
    /// Arc's `automaticLiveFolderData` → Open's `LiveFolderConfig` (live-data §2.7). The JSON
    /// spelling of Arc's enum cases is a GUESS (no Arc data here has a Live Folder), so the reader
    /// accepts the plausible forms: `{"github": {}}` or `"github"` for the source; hidden items as
    /// URL strings at any depth (`LiveItem.ID`); hidden repositories as "owner/name" strings or
    /// objects with `owner`/`name` (or `fullName`). The `attributes` option set is not mapped
    /// (its bit order is a guess): every kind stays on. `lastFetch` is dropped: Open refetches.
    static func liveFolderConfig(_ data: [String: Any]) -> LiveFolderConfig? {
        let source = data["dataSource"]
        let isGitHub = (source as? String)?.lowercased() == "github" || (source as? [String: Any])?.keys.contains("github") == true
        guard isGitHub else { return nil }
        var config = LiveFolderConfig()
        config.hiddenItems = Set(urls(in: data["hiddenItems"] as Any, limit: 500).map(\.absoluteString))
        let filter = (data["filter"] as? [String: Any])?["github"] as? [String: Any]
        for value in (filter?["hiddenRepositories"] as? [Any] ?? []).prefix(200) {
            if let repo = repository(value) { config.hiddenRepositories.insert(repo) }
        }
        return config
    }

    private static func repository(_ value: Any) -> String? {
        func valid(_ text: String) -> String? {
            let parts = text.split(separator: "/")
            return parts.count == 2 && text.count <= 200 ? text : nil
        }
        if let text = value as? String { return valid(text) }
        guard let object = value as? [String: Any] else { return nil }
        if let full = object["fullName"] as? String ?? object["nameWithOwner"] as? String { return valid(full) }
        let owner = object["owner"] as? String ?? (object["owner"] as? [String: Any])?["login"] as? String
        if let owner, let name = object["name"] as? String { return valid(owner + "/" + name) }
        return nil
    }

    /// http(s) URL strings anywhere in `value` (depth ≤ 4).
    private static func urls(in value: Any, limit: Int, depth: Int = 0) -> [URL] {
        guard depth <= 4 else { return [] }
        if let text = value as? String {
            // Scheme and host are case-insensitive (RFC 3986 §3.1, §3.2.2). Normalize them, because
            // hidden items match fetched rows by exact `absoluteString`.
            guard text.count <= 2_048, var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return [] }
            components.scheme = scheme
            components.percentEncodedHost = components.percentEncodedHost?.lowercased()
            return components.url.map { [$0] } ?? []
        }
        var out: [URL] = []
        let children: [Any] = (value as? [Any]).map { Array($0.prefix(limit)) } ?? (value as? [String: Any]).map { Array($0.values) } ?? []
        for child in children where out.count < limit { out += urls(in: child, limit: limit - out.count, depth: depth + 1) }
        return out
    }
}
