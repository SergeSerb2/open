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

    static func fill(_ template: String, _ query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

/// Built-in engines. Google is the default, as in Arc (docs/re/features-core.md §4.5 rule 11).
/// Every suggest endpoint was checked by hand on 2026-10-24 (`curl`, see docs/suggest.md).
public enum SearchEngines {
    public static let google = SearchEngine(
        id: "google", name: "Google", keywords: ["google", "g"],
        searchURLTemplate: "https://www.google.com/search?q=%s",
        suggestURLTemplate: "https://www.google.com/complete/search?client=chrome&ie=UTF-8&oe=UTF-8&q=%s",
        suggestFormat: .googleChrome)
    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo", name: "DuckDuckGo", keywords: ["duckduckgo", "ddg"],
        searchURLTemplate: "https://duckduckgo.com/?q=%s",
        suggestURLTemplate: "https://duckduckgo.com/ac/?q=%s&type=list")
    public static let bing = SearchEngine(
        id: "bing", name: "Bing", keywords: ["bing"],
        searchURLTemplate: "https://www.bing.com/search?q=%s",
        suggestURLTemplate: "https://www.bing.com/osjson.aspx?query=%s")
    public static let brave = SearchEngine(
        id: "brave", name: "Brave Search", keywords: ["brave"],
        searchURLTemplate: "https://search.brave.com/search?q=%s",
        suggestURLTemplate: "https://search.brave.com/api/suggest?q=%s")
    public static let ecosia = SearchEngine(
        id: "ecosia", name: "Ecosia", keywords: ["ecosia"],
        searchURLTemplate: "https://www.ecosia.org/search?q=%s",
        suggestURLTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list")
    public static let kagi = SearchEngine(
        id: "kagi", name: "Kagi", keywords: ["kagi"],
        searchURLTemplate: "https://kagi.com/search?q=%s",
        suggestURLTemplate: "https://kagi.com/api/autosuggest?q=%s")
    public static let perplexity = SearchEngine(
        id: "perplexity", name: "Perplexity", keywords: ["perplexity", "pplx"],
        searchURLTemplate: "https://www.perplexity.ai/search/new?q=%s",
        suggestURLTemplate: nil)
    public static let yahoo = SearchEngine(
        id: "yahoo", name: "Yahoo", keywords: ["yahoo"],
        searchURLTemplate: "https://search.yahoo.com/search?p=%s",
        suggestURLTemplate: "https://search.yahoo.com/sugg/ff?output=fxjson&appid=ffd&command=%s")

    public static let all: [SearchEngine] = [google, duckDuckGo, bing, brave, ecosia, kagi, perplexity, yahoo]
    public static let defaultID = google.id

    public static func engine(id: String?, in engines: [SearchEngine] = all) -> SearchEngine {
        guard let id else { return engines.first(where: { $0.id == defaultID }) ?? google }
        return engines.first(where: { $0.id == id }) ?? engines.first(where: { $0.id == defaultID }) ?? google
    }
}

/// One parsed suggest entry.
public enum RemoteItem: Sendable, Hashable {
    case query(String)
    case navigation(URL, title: String)
}

public enum SuggestResponseParser {
    /// Parses an OpenSearch or `client=chrome` body. Unknown shapes give an empty list.
    public static func parse(_ data: Data, format: SuggestFormat) -> [RemoteItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2,
              let texts = root[1] as? [Any] else { return [] }
        let descriptions = root.count > 2 ? (root[2] as? [Any] ?? []) : []
        var types: [Any] = []
        if format == .googleChrome, root.count > 4, let extras = root[4] as? [String: Any] {
            types = extras["google:suggesttype"] as? [Any] ?? []
        }
        var items: [RemoteItem] = []
        for (i, value) in texts.enumerated() {
            guard let text = value as? String, !text.isEmpty else { continue }
            let type = i < types.count ? types[i] as? String : nil
            if type == "NAVIGATION", let url = URL(string: text), url.host() != nil {
                let title = i < descriptions.count ? (descriptions[i] as? String ?? "") : ""
                items.append(.navigation(url, title: title))
            } else if type != "CALCULATOR" { // the local calculator answers arithmetic
                items.append(.query(text))
            }
        }
        return items
    }
}
