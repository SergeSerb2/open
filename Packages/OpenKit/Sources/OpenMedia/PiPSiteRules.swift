import Foundation

/// Recreated facts from PP-11/PP-12 in Open's own format; never copied bundle data.
public struct PiPSiteRules: Sendable, Decodable {
    public struct Site: Sendable, Decodable, Equatable {
        public var hosts: [String]
        public var hide: Set<String>?
        public var activatesWhenInaudible: Bool?
    }
    public let version: Int
    public let disallow: [String]
    public let sites: [Site]
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard version == 1 else { throw CocoaError(.coderReadCorrupt) }
    }
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "pip-site-rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Self(data: Data(contentsOf: url))
    }
    public func isDisallowed(_ url: URL) -> Bool { disallow.contains { Self.matches(url.host, rule: $0) } }
    public func configuration(for url: URL) -> Site? { sites.first { $0.hosts.contains { Self.matches(url.host, rule: $0) } } }
    public static func matches(_ host: String?, rule: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let rule = rule.lowercased()
        return host == rule || host.hasSuffix("." + rule)
    }
}
