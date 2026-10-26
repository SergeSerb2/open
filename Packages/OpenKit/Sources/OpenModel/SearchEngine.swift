import Foundation

/// Shape of a suggest endpoint response.
public enum SuggestFormat: String, Sendable, Codable, Hashable {
    /// OpenSearch JSON: `["query", ["s1", "s2", …], [descriptions…]?, [urls…]?]`.
    case openSearch
    /// OpenSearch JSON plus Google's `client=chrome` extras: element 4 holds `google:suggesttype`
    /// (`QUERY` / `NAVIGATION` / …) and element 2 holds a title for navigation rows.
    case googleChrome
}

public struct SearchEngine: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Words that enter Site Search for this engine ("ddg" + Tab).
    public var keywords: [String]
    /// `%s` is replaced by the percent-encoded query.
    public var searchURLTemplate: String
    /// `%s` is replaced by the percent-encoded query. Nil: the engine has no suggest endpoint.
    public var suggestURLTemplate: String?
    public var suggestFormat: SuggestFormat

    public init(id: String, name: String, keywords: [String] = [], searchURLTemplate: String,
                suggestURLTemplate: String?, suggestFormat: SuggestFormat = .openSearch) {
        self.id = id; self.name = name; self.keywords = keywords
        self.searchURLTemplate = searchURLTemplate
        self.suggestURLTemplate = suggestURLTemplate
        self.suggestFormat = suggestFormat
    }

    public func searchURL(for query: String) -> URL? { Self.fill(searchURLTemplate, query) }

    public func suggestURL(for query: String) -> URL? { suggestURLTemplate.flatMap { Self.fill($0, query) } }

    /// RFC 3986 unreserved characters only, so `&`, `+`, `#`, `=`, and `/` in the query stay data.
    static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func fill(_ template: String, _ query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

