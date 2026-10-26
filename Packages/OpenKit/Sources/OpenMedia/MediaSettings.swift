import Foundation

/// The settings registry is the only persistent store (§5); no registration prerequisite.
@MainActor public final class MediaSettings {
    public static let enabledKey = "open.advanced.enablePictureInPictureOnLeave"
    public static let hostsKey = "open.pip.autoDisabledHosts"
    public static let onTopKey = "open.pip.keepOnTop"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var automaticPiPEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    public var autoDisabledHosts: Set<String> {
        get { Set((defaults.object(forKey: Self.hostsKey) as? [String] ?? []).map(Self.canonicalHost)) }
        set { defaults.set(Set(newValue.map(Self.canonicalHost)).sorted(), forKey: Self.hostsKey) }
    }
    public var keepOnTop: Bool {
        get { defaults.object(forKey: Self.onTopKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.onTopKey) }
    }
    /// Menu actions and policy share this session object in an incognito window.
    @MainActor public final class PrivateHosts {
        public var disabled: Set<String> = []
        public init() {}
    }
    public func disabledHosts(privateSession: PrivateHosts? = nil) -> Set<String> {
        privateSession?.disabled ?? autoDisabledHosts
    }
    public nonisolated static func canonicalHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
    public nonisolated static func isDisabled(host: String, hosts: Set<String>) -> Bool {
        let canonical = canonicalHost(host)
        return hosts.contains { PiPSiteRules.matches(canonical, rule: canonicalHost($0)) }
    }
    public func isAutoDisabled(host: String, privateSession: PrivateHosts? = nil) -> Bool {
        Self.isDisabled(host: host, hosts: disabledHosts(privateSession: privateSession))
    }
    public func setAutomatic(_ enabled: Bool, host: String, privateSession: PrivateHosts? = nil) {
        let host = Self.canonicalHost(host)
        if let privateSession {
            if enabled { privateSession.disabled = privateSession.disabled.filter { !PiPSiteRules.matches(host, rule: Self.canonicalHost($0)) } }
            else { privateSession.disabled.insert(host) }
        } else {
            var hosts = autoDisabledHosts
            if enabled { hosts = hosts.filter { !PiPSiteRules.matches(host, rule: Self.canonicalHost($0)) } }
            else { hosts.insert(host) }
            autoDisabledHosts = hosts
        }
    }
}

/// Engine-free menu description shared by media-demo (MN1) and the phase-2 menu builder.
/// Order and strings follow PP-8; current-state checks follow lead decision Q17.
public struct PiPMenuEntry: Sendable, Equatable {
    public enum Action: Sendable { case keepOnTop, openAutomatically, turnOff, copyURL, toggleMute }
    public var title: String
    public var action: Action?
    public var checked: Bool
    public var isSeparator: Bool
    public init(_ title: String, action: Action? = nil, checked: Bool = false, isSeparator: Bool = false) {
        self.title = title; self.action = action; self.checked = checked; self.isSeparator = isSeparator
    }
    public static func entries(url: URL?, muted: Bool, keepOnTop: Bool, disabledHosts: Set<String>, document: Bool = false) -> [Self] {
        var items: [Self] = [.init("Keep Window on Top", action: .keepOnTop, checked: keepOnTop), .init("", isSeparator: true)]
        if let host = url?.host?.lowercased() {
            let disabled = MediaSettings.isDisabled(host: host, hosts: disabledHosts)
            items.append(.init("Picture-in-picture on " + host + ":"))
            if !document {
                items += [.init("Open automatically", action: .openAutomatically, checked: !disabled),
                          .init("Turn off", action: .turnOff, checked: disabled),
                          .init("", isSeparator: true), .init("Copy URL", action: .copyURL)]
            }
        }
        if !document { items.append(.init(muted ? "Unmute" : "Mute", action: .toggleMute)) }
        return items
    }
}
