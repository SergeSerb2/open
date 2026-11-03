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

    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Lowercase, without a leading `www.` (§4.7.7). Nil for an empty or oversized host.
    public static func normalizedHost(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty, h.utf8.count <= maxHostLength else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    public var neverTranslateHosts: [String] {
        let raw = defaults.array(forKey: Self.neverTranslateHostsKey) as? [String] ?? []
        return raw.suffix(Self.maxHosts).filter { !$0.isEmpty && $0.utf8.count <= Self.maxHostLength }
    }

    public func neverTranslates(host: String?) -> Bool {
        guard let h = Self.normalizedHost(host) else { return false }
        return neverTranslateHosts.contains(h)
    }

    /// Appends the host once; the oldest entries drop past `maxHosts`.
    public func addNeverTranslate(host: String?) {
        guard let h = Self.normalizedHost(host) else { return }
        var list = neverTranslateHosts.filter { $0 != h }
        list.append(h)
        defaults.set(Array(list.suffix(Self.maxHosts)), forKey: Self.neverTranslateHostsKey)
    }

    /// "Reset Translated-site Prompts": every site offers translation again.
    public func reset() { defaults.removeObject(forKey: Self.neverTranslateHostsKey) }
}
