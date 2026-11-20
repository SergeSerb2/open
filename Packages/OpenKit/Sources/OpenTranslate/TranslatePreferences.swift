import Foundation

/// App-scope translation settings (page-platform §5, §4.7.7; PG-7.4).
///
/// - `open.translate.enabled` (Bool, default true): the offer runs at all. No Settings row in v1.
/// - `open.translate.neverTranslateHosts` ([String], default []): lowercase hosts without `www.`.
///   "Never Translate This Site" appends; Settings ▸ Advanced ▸ "Reset Translated-site Prompts"
///   clears it (`reset()`).
public struct TranslatePreferences: @unchecked Sendable {
    public static let enabledKey = "open.translate.enabled"
    public static let neverTranslateHostsKey = "open.translate.neverTranslateHosts"
    /// The list grows only through a user action, but it is read from a plist anyone can edit:
    /// keep at most this many hosts (the newest win) and ignore longer entries.
    public static let maxHosts = 1_000
    public static let maxHostLength = 253

    /// An Incognito session's own "Never Translate This Site" hosts. Memory only: they end with the
    /// session. The session still honors the regular list; its own choices never reach `defaults`.
    public final class SessionHosts: @unchecked Sendable {
        public fileprivate(set) var hosts: [String] = []
        public init() {}
    }

    public let defaults: UserDefaults
    /// Set for an Incognito window: "Never Translate This Site" writes here, not to `defaults`.
    public let session: SessionHosts?
    public init(defaults: UserDefaults = .standard, session: SessionHosts? = nil) {
        self.defaults = defaults; self.session = session
    }

    public var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Lowercase, without a leading `www.` (§4.7.7). Nil for an empty or oversized host.
    public static func normalizedHost(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty, h.utf8.count <= maxHostLength else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// The regular list, then the session's own hosts (Incognito).
    public var neverTranslateHosts: [String] {
        let raw = defaults.array(forKey: Self.neverTranslateHostsKey) as? [String] ?? []
        let regular = raw.suffix(Self.maxHosts).filter { !$0.isEmpty && $0.utf8.count <= Self.maxHostLength }
        guard let session, !session.hosts.isEmpty else { return regular }
        let seen = Set(regular)
        return regular + session.hosts.filter { !seen.contains($0) }
    }

    public func neverTranslates(host: String?) -> Bool {
        guard let h = Self.normalizedHost(host) else { return false }
        return neverTranslateHosts.contains(h)
    }

    /// Appends the host once; the oldest entries drop past `maxHosts`.
    public func addNeverTranslate(host: String?) {
        guard let h = Self.normalizedHost(host) else { return }
        if let session {
            session.hosts = Array((session.hosts.filter { $0 != h } + [h]).suffix(Self.maxHosts))
            return
        }
        var list = neverTranslateHosts.filter { $0 != h }
        list.append(h)
        defaults.set(Array(list.suffix(Self.maxHosts)), forKey: Self.neverTranslateHostsKey)
    }

    /// "Reset Translated-site Prompts": every site offers translation again.
    public func reset() { defaults.removeObject(forKey: Self.neverTranslateHostsKey) }
}
