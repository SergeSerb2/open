import Foundation

public enum HostNormalizer {
    public static func canonicalHost(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let host: String
        if raw.contains("://") {
            guard let parts = URLComponents(string: raw), let parsed = componentHost(parts) else { return nil }
            host = parsed
        } else {
            let end = raw.firstIndex(where: { "/?#".contains($0) }) ?? raw.endIndex
            let authority = String(raw[..<end])
            // Parse ports only on authorities, never on an already extracted host.
            // Unbracketed IPv6 contains multiple colons and has no separable port.
            if authority.hasPrefix("[") || authority.filter({ $0 == ":" }).count == 1 {
                host = URLComponents(string: "//" + authority).flatMap(componentHost) ?? authority
            } else {
                host = authority
            }
        }
        return ruleHost(host)
    }

    public static func canonicalHost(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = componentHost(parts) else { return nil }
        return ruleHost(host)
    }

    /// A host alone, with no scheme, credentials, port, path, query or fragment.
    /// Used by the explicitly provisional Arc matches import mapping.
    public static func isBareHostPattern(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              !text.contains(where: { "/?#@:*[]".contains($0) }),
              let parts = URLComponents(string: "https://" + text),
              let host = componentHost(parts), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              let canonical = canonicalHost(text), !canonical.isEmpty else { return false }
        return true
    }

    public static func canonicalPattern(_ raw: String) -> String { canonicalHost(raw) ?? "" }

    public static func canonicalURLString(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = componentHost(parts), !host.isEmpty else { return url.absoluteString }
        // Assemble the comparison string ourselves: URLComponents.string can turn
        // a Unicode host back into percent escapes or Punycode.
        let authority = prefixAuthority(host, port: parts.port, scheme: scheme)
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        return scheme + "://" + authority + path + query
    }

    public static func canonicalPrefixPattern(_ raw: String, scheme: String? = nil) -> String {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.contains("://") {
            guard let url = URL(string: pattern) else { return pattern }
            return canonicalURLString(url)
        }
        // Scheme-less patterns match both HTTP and HTTPS; default ports depend
        // on the candidate's scheme. Keep www and the supplied remainder literal.
        let end = pattern.firstIndex(where: { "/?#".contains($0) }) ?? pattern.endIndex
        let authority = String(pattern[..<end])
        guard let parts = URLComponents(string: "//" + authority), let host = componentHost(parts), !host.isEmpty else { return pattern }
        return prefixAuthority(host, port: parts.port, scheme: scheme?.lowercased()) + pattern[end...]
    }

    private static func componentHost(_ parts: URLComponents) -> String? {
        // Foundation can return nil for an invalid ACE label. Retain its encoded
        // spelling so our decoder can leave malformed Punycode unchanged.
        parts.host ?? parts.percentEncodedHost
    }

    private static func ruleHost(_ raw: String) -> String? {
        var host = canonicalHostName(raw)
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    /// Shared DNS/IP spelling, without routing-specific www or wildcard removal.
    public static func canonicalHostName(_ raw: String) -> String {
        var host = (raw.removingPercentEncoding ?? raw).precomposedStringWithCanonicalMapping.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        host = host.split(separator: ".", omittingEmptySubsequences: false).map { label in
            let label = String(label)
            guard label.hasPrefix("xn--") else { return label }
            return Punycode.decode(String(label.dropFirst(4))) ?? label
        }.joined(separator: ".").precomposedStringWithCanonicalMapping.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func prefixAuthority(_ raw: String, port: Int?, scheme: String?) -> String {
        let host = canonicalHostName(raw)
        let authority = host.contains(":") ? "[" + host + "]" : host
        guard let port, !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) else {
            return authority
        }
        return authority + ":" + String(port)
    }
}

/// RFC 3492 sections 6.1–6.2 (https://www.rfc-editor.org/rfc/rfc3492#section-6).
/// Decode one label payload; malformed digits, overflow, or invalid Unicode fail
/// without changing the caller's label. No IDNA dependency or network lookup.
private enum Punycode {
    static func decode(_ payload: String) -> String? {
        let input = Array(payload.utf8)
        guard !input.isEmpty, input.allSatisfy({ $0 < 128 }) else { return nil }
        var output: [Unicode.Scalar] = []
        var cursor = 0
        if let delimiter = input.lastIndex(of: 45) {
            guard delimiter > 0 else { return nil }
            output = input[..<delimiter].map { Unicode.Scalar(UInt32($0))! }
            cursor = delimiter + 1
        }
        var n: UInt32 = 128
        var i: UInt32 = 0
        var bias: UInt32 = 72
        while cursor < input.count {
            let oldI = i
            var weight: UInt32 = 1
            var k: UInt32 = 36
            while true {
                guard cursor < input.count, let digit = digit(input[cursor]),
                      digit <= (UInt32.max - i) / weight else { return nil }
                cursor += 1
                i += digit * weight
                let threshold: UInt32 = k <= bias ? 1 : min(26, k - bias)
                if digit < threshold { break }
                guard weight <= UInt32.max / (36 - threshold), k <= UInt32.max - 36 else { return nil }
                weight *= 36 - threshold
                k += 36
            }
            guard let count = UInt32(exactly: output.count + 1) else { return nil }
            bias = adapt(i - oldI, count: count, first: oldI == 0)
            guard i / count <= 0x10FFFF - n else { return nil }
            n += i / count
            guard let scalar = Unicode.Scalar(n) else { return nil }
            i %= count
            output.insert(scalar, at: Int(i))
            i += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func digit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 97...122: return UInt32(byte - 97)
        case 65...90: return UInt32(byte - 65)
        case 48...57: return UInt32(byte - 48) + 26
        default: return nil
        }
    }

    private static func adapt(_ delta: UInt32, count: UInt32, first: Bool) -> UInt32 {
        var delta = first ? delta / 700 : delta / 2
        delta += delta / count
        var k: UInt32 = 0
        while delta > 455 { delta /= 35; k += 36 }
        return k + (36 * delta) / (delta + 38)
    }
}
