import Foundation

public enum HostNormalizer {
    public static func canonicalHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        if host.contains("://") {
            guard let parsed = URLComponents(string: host)?.host else { return nil }
            host = parsed
        } else if let end = host.firstIndex(where: { "/?#".contains($0) }) {
            host = String(host[..<end])
        }
        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if let colon = host.lastIndex(of: ":") {
            let suffix = host[host.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                host = String(host[..<colon])
            }
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    public static func canonicalHost(of url: URL) -> String? { canonicalHost(url.host()) }
    public static func canonicalPattern(_ raw: String) -> String { canonicalHost(raw) ?? "" }

    public static func canonicalURLString(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, let host = url.host(), !host.isEmpty else { return url.absoluteString }
        parts.scheme = scheme.lowercased()
        parts.host = prefixHost(host)
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? url.absoluteString
    }

    public static func canonicalPrefixPattern(_ raw: String) -> String {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.contains("://") {
            guard let url = URL(string: pattern) else { return pattern }
            return canonicalURLString(url)
        }
        // Scheme-less patterns match both HTTP and HTTPS; www remains literal.
        guard var parts = URLComponents(string: "//" + pattern), let host = parts.host, !host.isEmpty else { return pattern }
        parts.host = prefixHost(host)
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let result = parts.string, result.hasPrefix("//") else { return pattern }
        return String(result.dropFirst(2))
    }

    private static func prefixHost(_ raw: String) -> String {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}
