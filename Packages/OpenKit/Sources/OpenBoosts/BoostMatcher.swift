import Foundation

/// Value index. Rebuild after store edits. Queries probe host suffixes, never all boosts.
public struct BoostMatcher: Sendable {
    private var byDomain: [String: [Boost]] = [:]
    private var allDomains: Set<String> = []
    public init(boosts: [Boost]) { rebuild(boosts: boosts) }
    public mutating func rebuild(boosts: [Boost]) {
        byDomain = [:]
        for var boost in boosts where boost.isEnabled {
            boost.siteMatch = .normalized(domain: boost.siteMatch.domain, pathPrefix: boost.siteMatch.pathPrefix)
            guard !boost.siteMatch.domain.isEmpty else { continue }
            byDomain[boost.siteMatch.domain, default: []].append(boost)
        }
        allDomains = Set(byDomain.keys)
    }
    public func matching(url: URL) -> [Boost] {
        guard let rawHost = url.host, !rawHost.isEmpty else { return [] }
        let host = Self.host(rawHost)
        // Use the encoded path explicitly: Foundation's plain .path decodes %20.
        // IDNs are lowercased only; callers must use the browser's host representation.
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        return Self.suffixes(host).flatMap { byDomain[$0] ?? [] }
            .filter { $0.siteMatch.matches(host: host, path: path) }
            .sorted(by: Self.ordered)
    }
    public func hasMatch(host: String) -> Bool { Self.suffixes(Self.host(host)).contains { allDomains.contains($0) } }
    private static func host(_ input: String) -> String {
        var value = input.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value
    }
    private static func suffixes(_ host: String) -> [String] {
        guard !host.isEmpty else { return [] }
        if SiteMatch.isIP(host) { return [host] }
        let labels = host.split(separator: ".")
        return labels.indices.map { labels[$0...].joined(separator: ".") }
    }
    private static func ordered(_ a: Boost, _ b: Boost) -> Bool {
        let ad = a.siteMatch.domain, bd = b.siteMatch.domain
        if ad.count != bd.count { return ad.count < bd.count }
        if ad != bd { return ad < bd }
        let ap = a.siteMatch.pathPrefix?.count ?? 0, bp = b.siteMatch.pathPrefix?.count ?? 0
        if ap != bp { return ap < bp }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.description < b.id.description
    }
}
