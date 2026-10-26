import Foundation

/// Match quality levels. They are the `quality` term of the score. See docs/suggest.md "Match quality".
public enum MatchQuality {
    public static let exact: Double = 100
    public static let prefix: Double = 80
    public static let wordPrefix: Double = 60
    /// Every query word starts a word somewhere in the row ("des rev" → "Design Review").
    public static let allWordsPrefix: Double = 50
    /// Actions only: the query is the initials of the title ("ts" → "Toggle Sidebar").
    public static let initials: Double = 50
    public static let substring: Double = 40
    /// Every query word occurs somewhere in the row.
    public static let allWordsSubstring: Double = 30
    /// A mid-word substring needs at least this many bytes. Shorter queries match only at word starts.
    public static let minSubstringLength = 3
}

/// A query folded once per keystroke and shared by all providers.
public struct FoldedQuery: Sendable {
    public let text: String
    public let bytes: [UInt8]
    /// Query words (split on spaces), folded. One element for a one-word query.
    public let tokens: [[UInt8]]
    /// Bloom mask of every non-space byte. A row whose mask lacks a bit cannot match.
    public let mask: UInt64

    public init(_ text: String) {
        self.text = text
        let bytes = TextMatching.fold(text)
        self.bytes = bytes
        self.tokens = bytes.split(separator: 32, omittingEmptySubsequences: true).map(Array.init)
        self.mask = TextMatching.mask(bytes)
    }

    public var isEmpty: Bool { bytes.isEmpty }
}

public enum TextMatching {
    // MARK: Folding

    /// Lowercase, diacritic- and width-insensitive UTF-8 bytes. ASCII takes a fast path with no allocation
    /// beyond the result.
    public static func fold(_ s: some StringProtocol) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if b >= 128 { return foldSlow(String(s)) }
            out.append(b >= 65 && b <= 90 ? b + 32 : b)
        }
        return out
    }

    private static func foldSlow(_ s: String) -> [UInt8] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased().utf8)
    }

    @inline(__always)
    public static func mask(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var m: UInt64 = 0
        for b in bytes where b != 32 { m |= 1 &<< UInt64(b & 63) }
        return m
    }

    /// Letters, digits, and every non-ASCII byte count as word bytes. Everything else separates words.
    @inline(__always)
    static func isWordByte(_ b: UInt8) -> Bool {
        b >= 128 || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || (b >= 65 && b <= 90)
    }

    // MARK: Matching (hot path)

    /// Quality of `query` inside `field`. Both are folded bytes.
    /// exact 100 > prefix 80 > word-prefix 60 > substring 40 (substring only when the query has 3+ bytes).
    @inline(__always)
    static func quality(_ q: UnsafeBufferPointer<UInt8>, in f: UnsafeBufferPointer<UInt8>) -> Double {
        let n = q.count, m = f.count
        guard n > 0, n <= m, let qb = q.baseAddress, let fb = f.baseAddress else { return 0 }
        if memcmp(fb, qb, n) == 0 { return n == m ? MatchQuality.exact : MatchQuality.prefix }
        let first = qb[0]
        let queryStartsWord = isWordByte(first)
        var sawSubstring = false
        var i = 1
        let last = m - n
        while i <= last {
            if fb[i] == first, memcmp(fb + i, qb, n) == 0 {
                if !queryStartsWord || !isWordByte(fb[i - 1]) { return MatchQuality.wordPrefix }
                sawSubstring = true
            }
            i += 1
        }
        return sawSubstring && n >= MatchQuality.minSubstringLength ? MatchQuality.substring : 0
    }

    public static func quality(_ query: [UInt8], in field: [UInt8]) -> Double {
        query.withUnsafeBufferPointer { q in field.withUnsafeBufferPointer { f in quality(q, in: f) } }
    }

    /// Best quality of a query over several weighted fields, with the multi-word fallback.
    /// `fields` holds (bytes, factor). Used for history, remote, and site rows; tabs use the index fast path.
    public static func rowQuality(_ query: FoldedQuery, fields: [([UInt8], Double)]) -> Double {
        var best = 0.0
        for (bytes, factor) in fields {
            best = max(best, quality(query.bytes, in: bytes) * factor)
        }
        guard query.tokens.count > 1, best < MatchQuality.allWordsPrefix else { return best }
        var allWordPrefix = true
        for token in query.tokens {
            var t = 0.0
            for (bytes, _) in fields { t = max(t, quality(token, in: bytes)) }
            if t == 0 { return best }
            if t < MatchQuality.wordPrefix { allWordPrefix = false }
        }
        return max(best, allWordPrefix ? MatchQuality.allWordsPrefix : MatchQuality.allWordsSubstring)
    }

    /// Initials of the words in `title` ("Toggle Sidebar" → "ts"), folded.
    static func initials(of folded: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var previousWasWord = false
        for b in folded {
            let w = isWordByte(b)
            if w && !previousWasWord { out.append(b) }
            previousWasWord = w
        }
        return out
    }

    // MARK: URLs

    /// Host in lowercase without a leading "www.".
    public static func displayHost(_ url: URL) -> String {
        var host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// URL text used for matching: no scheme, no "www.", no fragment.
    public static func matchableURL(_ url: URL) -> String {
        var s = url.absoluteString
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        return s
    }

    /// Dedupe key. http and https are the same; "www." is dropped; the default port, a trailing slash,
    /// and the fragment are ignored; the query string is kept. Other schemes keep their scheme.
    public static func urlKey(_ url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        var key = (scheme == "http" || scheme == "https") ? "" : scheme + ":"
        key += displayHost(url)
        if let port = url.port, !(port == 80 && scheme == "http"), !(port == 443 && scheme == "https") {
            key += ":\(port)"
        }
        var path = url.path(percentEncoded: true)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        key += path
        if let q = url.query(percentEncoded: true), !q.isEmpty { key += "?" + q }
        return key
    }

    /// Origin favicon URL for an icon hint. Nil for URLs without a web host.
    public static func faviconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true), !host.isEmpty else { return nil }
        var s = "\(scheme)://\(host)"
        if let port = url.port { s += ":\(port)" }
        return URL(string: s + "/favicon.ico")
    }

    /// Hosts whose pages often share one URL shape, so rows are deduped by (title, host) instead of URL.
    /// Same host list as Arc's `dedupByTitleAndHostList` (docs/re/features-core.md §4.3 rule 7).
    public static let dedupeByTitleAndHost: Set<String> = [
        "figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us",
        "opentable.com", "zillow.com", "github.com", "app.mode.com", "console.cloud.google.com",
    ]

    // MARK: Frecency

    /// History frecency in 0...30: `8 × ln(1 + (visits + 3 × typed) / (1 + 0.15 × ageDays))`.
    public static func historyFrecency(visits: Int, typed: Int, lastVisit: Date, now: Date) -> Double {
        let base = Double(max(0, visits) + 3 * max(0, typed))
        guard base > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(lastVisit)) / 86_400
        return min(30, 8 * log1p(base / (1 + 0.15 * ageDays)))
    }

    /// Tab recency in 0...6: `6 − ln(1 + ageHours)`.
    public static func tabRecency(lastActiveAt: Date, now: Date) -> Double {
        let ageHours = max(0, now.timeIntervalSince(lastActiveAt)) / 3_600
        return max(0, 6 - log1p(ageHours))
    }
}
