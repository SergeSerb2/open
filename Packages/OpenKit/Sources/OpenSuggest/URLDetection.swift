import Foundation

/// How the command bar reads the typed text. See docs/suggest.md "What you typed".
public enum TypedInput: Sendable, Hashable {
    case empty
    case url(URL, URLReason)
    case text(String)

    public var url: URL? { if case .url(let u, _) = self { return u }; return nil }
    public var isURL: Bool { url != nil }
}

public enum URLReason: String, Sendable, Hashable {
    /// `https://…`, `about:blank`, `mailto:…`, or any `app-scheme://…`.
    case explicitScheme
    /// Starts with `/` or `~/`.
    case filePath
    /// `localhost`, `*.localhost`.
    case localhost
    /// IPv4 dotted quad or bracketed IPv6.
    case ipAddress
    /// A host with an explicit port (`myserver:8080`, `dev.box:3000`).
    case hostWithPort
    /// A host that ends in a known public suffix and has a name in front of it (`github.com`).
    case knownSuffix
    /// Special-use names that are not in the PSL: `.local`, `.test`, `.internal`, `.localhost`.
    case specialUseName
    /// One word followed by `/` (`intranet/`), the usual way to force a URL.
    case singleWordWithSlash
}

/// Classifies typed text as a URL to open or text to search. Synchronous; no I/O.
public struct InputClassifier: Sendable {
    public var suffixList: PublicSuffixList

    public init(suffixList: PublicSuffixList = .shared) {
        self.suffixList = suffixList
    }

    /// Schemes that navigate even without `//`.
    static let knownSchemes: Set<String> = [
        "http", "https", "file", "ftp", "about", "chrome", "chrome-extension", "view-source", "mailto",
    ]
    static let specialUseTLDs: Set<String> = ["local", "localhost", "test", "internal"]

    public func classify(_ raw: String) -> TypedInput {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }

        if let url = explicitSchemeURL(s) { return .url(url, .explicitScheme) }
        // Never run script from the command bar.
        if s.lowercased().hasPrefix("javascript:") { return .text(s) }

        if s.hasPrefix("/") && !s.hasPrefix("//") { return .url(URL(filePath: s), .filePath) }
        if s == "~" || s.hasPrefix("~/") {
            return .url(URL(filePath: (s as NSString).expandingTildeInPath), .filePath)
        }

        // Split "authority" from "/path?query#fragment".
        let authorityEnd = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? s.endIndex
        let authority = s[..<authorityEnd]
        let rest = s[authorityEnd...]
        // Whitespace inside the authority means words, not a host ("what is github.com").
        if authority.contains(where: \.isWhitespace) || authority.isEmpty { return .text(s) }
        // "name@example.com" is an e-mail address, not a page.
        if authority.contains("@") { return .text(s) }

        guard let parsed = Self.splitHostPort(authority) else { return .text(s) }
        var host = parsed.host.lowercased()
        if host.hasSuffix(".") && !host.hasPrefix("[") { host.removeLast() }
        guard !host.isEmpty else { return .text(s) }

        let reason: URLReason
        let scheme: String
        if host == "localhost" || host.hasSuffix(".localhost") {
            reason = .localhost; scheme = "http"
        } else if Self.isIPv4(host) || (host.hasPrefix("[") && Self.isIPv6(host.dropFirst().dropLast())) {
            reason = .ipAddress; scheme = "http"
        } else {
            guard Self.isValidHostSyntax(host) else { return .text(s) }
            let labels = host.split(separator: ".")
            if labels.count == 1 {
                if parsed.port != nil { reason = .hostWithPort }
                else if rest.hasPrefix("/") { reason = .singleWordWithSlash }
                else { return .text(s) }
                scheme = "http"
            } else if let tld = labels.last, Self.specialUseTLDs.contains(String(tld)) {
                reason = .specialUseName; scheme = "http"
            } else if suffixList.isRegistrableHost(host) {
                reason = .knownSuffix; scheme = "https"
            } else if parsed.port != nil {
                reason = .hostWithPort; scheme = "http"
            } else {
                return .text(s)
            }
        }

        var urlString = "\(scheme)://\(host)"
        if let port = parsed.port { urlString += ":\(port)" }
        urlString += rest.isEmpty ? "/" : Self.encodeRest(rest)
        guard let url = URL(string: urlString), url.host() != nil else { return .text(s) }
        return .url(url, reason)
    }

    // MARK: Pieces

    private func explicitSchemeURL(_ s: String) -> URL? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = s[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        let lower = scheme.lowercased()
        if lower == "javascript" { return nil }
        let afterColon = s[s.index(after: colon)...]
        // "localhost:3000" and "example.com:8080/x" have a port, not a scheme: they fail this check.
        guard Self.knownSchemes.contains(lower) || afterColon.hasPrefix("//") else { return nil }
        var text = s
        if lower == "http" || lower == "https" {
            // Keep spaces in the path ("https://example.com/a b"); reject spaces in the host.
            let afterSlashes = afterColon.drop(while: { $0 == "/" })
            let hostEnd = afterSlashes.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterSlashes.endIndex
            if afterSlashes[..<hostEnd].contains(where: \.isWhitespace) { return nil }
            text = String(s[..<hostEnd]) + Self.encodeRest(afterSlashes[hostEnd...])
        } else if s.contains(where: \.isWhitespace) && lower != "file" {
            return nil
        }
        guard let url = URL(string: text) ?? URL(string: text, encodingInvalidCharacters: true) else { return nil }
        if (lower == "http" || lower == "https"), (url.host() ?? "").isEmpty { return nil }
        return url
    }

    /// Splits `host[:port]` and `[v6][:port]`. Nil when the port is not a number in 0...65535.
    static func splitHostPort(_ authority: Substring) -> (host: String, port: Int?)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[...close])
            let after = authority[authority.index(after: close)...]
            if after.isEmpty { return (host, nil) }
            guard after.hasPrefix(":"), let port = parsePort(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = authority.lastIndex(of: ":") else { return (String(authority), nil) }
        guard let port = parsePort(authority[authority.index(after: colon)...]) else { return nil }
        return (String(authority[..<colon]), port)
    }

    private static func parsePort(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(s), p <= 65_535 else { return nil }
        return p
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), n <= 255 else { return false }
            return part.count == 1 || part.first != "0"
        }
    }

    static func isIPv6(_ s: Substring) -> Bool {
        guard s.contains(":") else { return false }
        var addr = in6_addr()
        return inet_pton(AF_INET6, String(s), &addr) == 1
    }

    /// Letters, digits, hyphens, and non-ASCII letters; labels 1...63 long and not starting or ending
    /// with a hyphen; at least one letter somewhere (all-digit hosts are numbers, not names).
    static func isValidHostSyntax(_ host: String) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        var sawLetter = false
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            for ch in label {
                if ch == "-" || ch == "_" { continue }
                if ch.isASCII {
                    guard ch.isLetter || ch.isNumber else { return false }
                    if ch.isLetter { sawLetter = true }
                } else {
                    guard ch.isLetter || ch.isNumber else { return false }
                    sawLetter = true
                }
            }
        }
        return sawLetter
    }

    /// Percent-encodes characters that are not valid in a path, query, or fragment, and keeps
    /// existing escapes.
    static func encodeRest(_ rest: Substring) -> String {
        rest.addingPercentEncoding(withAllowedCharacters: restAllowed) ?? String(rest)
    }

    private static let restAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.formUnion(.urlQueryAllowed)
        set.formUnion(.urlFragmentAllowed)
        set.insert(charactersIn: "%#")
        return set
    }()
}
