import Foundation
import Darwin

/// PSL includes private registries, matching the engine's INCLUDE_PRIVATE_REGISTRIES contract.
public struct AdBlockSites: Sendable {
    public static let shared = AdBlockSites()
    private let exact: Set<String>
    private let wildcard: Set<String>
    private let exceptions: Set<String>
    private let hasCompleteSnapshot: Bool

    private init() {
        let url = try? AdBlockCatalog.resource("public_suffix_list.dat")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("//") { continue }
            let rule = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = rule.hasPrefix("*.") ? 2 : (rule.hasPrefix("!") ? 1 : 0)
            let raw = String(rule.dropFirst(prefix))
            guard !raw.isEmpty else { continue }
            let ascii = raw.utf8.allSatisfy({ $0 < 128 }) ? raw :
                (URLComponents(string: "https://\(raw)/")?.encodedHost ?? raw)
            if prefix == 2 { wildcard.insert(ascii) }
            else if prefix == 1 { exceptions.insert(ascii) }
            else { exact.insert(ascii) }
        }
        self.exact = exact; self.wildcard = wildcard; self.exceptions = exceptions
        self.hasCompleteSnapshot = exact.contains("com") && exact.contains("github.io") &&
            text.contains("// ===END PRIVATE DOMAINS===")
    }

    /// Accept a host only, with optional leading *. and one trailing dot. IDNs become ASCII.
    public func normalize(_ input: String) throws -> String {
        guard hasCompleteSnapshot else { throw AdBlockError("allowlist: public suffix resource unavailable") }
        var host = input.lowercased()
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@%")) == nil,
              let url = URL(string: "https://\(host)/"), url.port == nil,
              let ascii = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost,
              !ascii.isEmpty else { throw AdBlockError("allowlist: invalid host") }
        if isIP(ascii) { return ascii }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard ascii.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        }) else { throw AdBlockError("allowlist: invalid host") }
        return ascii
    }

    public func registrableDomain(_ input: String) throws -> String {
        try registrableNormalized(normalize(input))
    }

    /// Fast path for ASCII hosts already normalized at navigation time.
    public func registrableNormalized(_ host: String) throws -> String {
        guard hasCompleteSnapshot else { throw AdBlockError("allowlist: public suffix resource unavailable") }
        if isIP(host) { return host }
        let labels = host.split(separator: ".")
        var suffix = 1 // PSL implicit * rule, also used for unknown registries.
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) { suffix = labels.count - index - 1; break }
            if exact.contains(candidate) { suffix = max(suffix, labels.count - index) }
            if index > 0 && wildcard.contains(candidate) { suffix = max(suffix, labels.count - index + 1) }
        }
        guard labels.count > suffix else { throw AdBlockError("allowlist: a public suffix is not a site") }
        return labels.suffix(suffix + 1).joined(separator: ".")
    }

    private func isIP(_ host: String) -> Bool {
        let raw = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return raw.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

/// Immutable navigation snapshot. Cache one per Profile; no disk access or PSL work per request.
public struct AdBlockSiteSnapshot: Sendable {
    public let isEnabled: Bool
    public let excludedDomains: Set<String>
    private let hostSlices: Set<Substring>

    init(isEnabled: Bool, excludedDomains: Set<String>) {
        self.isEnabled = isEnabled
        self.excludedDomains = excludedDomains
        self.hostSlices = Set(excludedDomains.map { $0[...] })
    }

    /// A stored site covers that registrable domain and its subdomains, with a label boundary.
    /// The store admits only PSL-validated registrable domains or IP literals.
    public func isAllowlisted(normalizedHost host: String) -> Bool {
        var candidate = host[...]
        while true {
            if hostSlices.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    public func isAllowlisted(host: String) throws -> Bool {
        isAllowlisted(normalizedHost: try AdBlockSites.shared.normalize(host))
    }

    public func shouldBlock(host: String) throws -> Bool {
        guard isEnabled else { return false }
        return try !isAllowlisted(host: host)
    }
}
