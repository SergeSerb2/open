import Foundation
import Synchronization

/// Fetches suggestions for one engine. Plug in a different fetcher per engine through
/// `RemoteSuggestionsProvider(fetchers:)`.
public protocol SuggestionFetcher: Sendable {
    func fetch(_ query: String, engine: SearchEngine) async throws -> [RemoteItem]
}

/// HTTP GET of the engine's suggest template. Ephemeral session: no cookies, no cache, no credentials.
public struct HTTPSuggestionFetcher: SuggestionFetcher {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 1
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(_ query: String, engine: SearchEngine) async throws -> [RemoteItem] {
        guard let url = engine.suggestURL(for: query) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        return SuggestResponseParser.parse(data, format: engine.suggestFormat)
    }
}

/// Last results per (engine, query). Exact hits skip the network; the latest result also seeds
/// "carry-over" rows for the next keystroke ("gith" → "githu" keeps "github …" until the new answer).
final class RemoteSuggestCache: Sendable {
    private struct State {
        var entries: [String: (items: [RemoteItem], time: ContinuousClock.Instant)] = [:]
        var order: [String] = []
        var last: (engine: String, query: [UInt8], items: [RemoteItem])?
    }

    private let state = Mutex(State())
    let capacity: Int
    let lifetime: Duration

    init(capacity: Int = 64, lifetime: Duration = .seconds(300)) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    private static func key(_ engine: String, _ query: String) -> String { engine + "\u{1}" + query }

    func exact(engine: String, query: String) -> [RemoteItem]? {
        let now = ContinuousClock.now
        return state.withLock { s in
            guard let hit = s.entries[Self.key(engine, query)], now - hit.time < lifetime else { return nil }
            return hit.items
        }
    }

    /// Query suggestions from the previous answer that still start with the new query.
    func carryOver(engine: String, query: FoldedQuery) -> [RemoteItem] {
        state.withLock { s in
            guard let last = s.last, last.engine == engine, query.bytes.count > last.query.count,
                  query.bytes.starts(with: last.query) else { return [] }
            return last.items.filter { item in
                guard case .query(let text) = item else { return false }
                return TextMatching.fold(text).starts(with: query.bytes)
            }
        }
    }

    func store(engine: String, query: String, folded: [UInt8], items: [RemoteItem]) {
        let now = ContinuousClock.now
        state.withLock { s in
            let k = Self.key(engine, query)
            if s.entries[k] == nil { s.order.append(k) }
            s.entries[k] = (items, now)
            if s.order.count > capacity { s.entries[s.order.removeFirst()] = nil }
            s.last = (engine, folded, items)
        }
    }
}

/// 4. Search engine suggestions. Debounced, cancelled by the next keystroke, 300 ms timeout.
///
/// Privacy: nothing is sent when remote suggestions are off, in the Tabs or Actions scope, for URL-like
/// input (the typed URL never leaves the machine), for calculator input, for text over 200
/// characters, or in a Site Search scope that is not a search engine.
public struct RemoteSuggestionsProvider: SuggestProvider {
    public let id = "remote"
    public var debounce: Duration
    public var timeout: Duration
    public var maxRows = 5
    let defaultFetcher: any SuggestionFetcher
    let fetchers: [String: any SuggestionFetcher]
    let engines: [SearchEngine]
    let cache = RemoteSuggestCache()

    public init(fetcher: any SuggestionFetcher = HTTPSuggestionFetcher(), fetchers: [String: any SuggestionFetcher] = [:],
                engines: [SearchEngine] = SearchEngines.all,
                debounce: Duration = .milliseconds(80), timeout: Duration = .milliseconds(300)) {
        self.defaultFetcher = fetcher
        self.fetchers = fetchers
        self.engines = engines
        self.debounce = debounce
        self.timeout = timeout
    }

    /// The engine to ask, or nil when this input must not go to the network.
    func engine(for input: SuggestInput) -> SearchEngine? {
        // The Tabs and Actions scopes list only tabs or actions (commandbar-completion §4.3.3).
        guard input.context.allowsRemoteSuggestions, !input.context.mode.isScoped,
              case .text(let text) = input.typed, text.count <= 200,
              Calculator.evaluate(text) == nil else { return nil }
        let engine: SearchEngine
        if let site = input.siteSearch {
            guard let engineID = site.engineID else { return nil }
            engine = SearchEngines.resolve(id: engineID, custom: input.customSearchEngines, in: engines)
        } else {
            engine = input.searchEngine
        }
        return engine.suggestURLTemplate == nil ? nil : engine
    }

    public func localSuggestions(for input: SuggestInput) -> [Suggestion] {
        guard let engine = engine(for: input) else { return [] }
        let items = cache.exact(engine: engine.id, query: input.text) ?? cache.carryOver(engine: engine.id, query: input.query)
        return Self.rows(items, input: input, engine: engine, provider: id, maxRows: maxRows)
    }

    public func asyncOperation(for input: SuggestInput) -> (@Sendable () async -> [Suggestion]?)? {
        guard let engine = engine(for: input), cache.exact(engine: engine.id, query: input.text) == nil else { return nil }
        let fetcher = fetchers[engine.id] ?? defaultFetcher
        let cache = cache, debounce = debounce, timeout = timeout, provider = id, maxRows = maxRows
        let text = input.text, folded = input.query.bytes
        return {
            // Debounce: the next keystroke cancels this task while it sleeps, so no request goes out.
            do { try await Task.sleep(for: debounce) } catch { return nil }
            guard let items = try? await withTimeout(timeout, { try await fetcher.fetch(text, engine: engine) }) else {
                return nil // timeout, offline, or cancelled: keep the carry-over rows
            }
            cache.store(engine: engine.id, query: text, folded: folded, items: items)
            if Task.isCancelled { return nil }
            return Self.rows(items, input: input, engine: engine, provider: provider, maxRows: maxRows)
        }
    }

    /// Rows keep the server order and score below the typed search row (50):
    /// `100 × 0.45 − 0.5 × rank`, so the network never moves the top hit.
    nonisolated static func rows(_ items: [RemoteItem], input: SuggestInput, engine: SearchEngine, provider: String, maxRows: Int) -> [Suggestion] {
        var rows: [Suggestion] = []
        let site = input.siteSearch
        for item in items {
            if rows.count >= maxRows { break }
            let rank = Double(rows.count)
            let detail = ScoreDetail(quality: MatchQuality.exact, weight: Ranking.weight(.searchSuggestion), boost: -0.5 * rank)
            switch item {
            case .query(let text):
                if TextMatching.fold(text) == input.query.bytes { continue } // same as the typed search row
                let url = site?.searchURL(for: text) ?? engine.searchURL(for: text)
                rows.append(Suggestion(
                    id: "remote:\(text)", kind: .searchSuggestion, title: text, subtitle: "Search \(site?.name ?? engine.name)",
                    url: url, icon: .symbol("magnifyingglass"), siteSearchID: site?.id, provider: provider, scoreDetail: detail))
            case .navigation(let url, let title):
                guard site == nil else { continue }
                rows.append(Suggestion(
                    id: "remote-nav:\(TextMatching.urlKey(url))", kind: .navigate,
                    title: title.isEmpty ? TextMatching.matchableURL(url) : title, subtitle: TextMatching.matchableURL(url),
                    url: url, icon: TextMatching.faviconURL(for: url).map(IconHint.favicon), provider: provider, scoreDetail: detail))
            }
        }
        return rows
    }
}
