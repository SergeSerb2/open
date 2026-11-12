import Foundation

/// Favorite ("Top App") tile badges and subtitles (audit A2; facts in docs/re/favorite-badges.md).
///
/// Arc's tile kind comes from the Favorite URL's host through one string switch with eleven
/// cases (`FUN_102ee14c0` → `FUN_102ee1d50`, Arc 1.170). Badges are unread counts; the
/// subtitle is the Live Calendar "time to next meeting" plate.
public enum FavoriteApp: String, CaseIterable, Sendable {
    case twitter, whatsApp, gmail, googleCalendar, outlook, notionCalendar, spotify, youtube, notion, slack, figma

    public static func match(url: URL) -> FavoriteApp? {
        guard url.scheme == "https" || url.scheme == "http", var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        switch host {
        // x.com: Twitter's current host (GUESS — Arc 1.170's table names twitter.com).
        case "twitter.com", "x.com", "mobile.twitter.com", "mobile.x.com": return .twitter
        case "web.whatsapp.com": return .whatsApp
        case "mail.google.com": return .gmail
        case "calendar.google.com": return .googleCalendar
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com": return .outlook
        case "calendar.notion.so", "calendar.notion.com": return .notionCalendar
        case "open.spotify.com", "spotify.com": return .spotify
        case "youtube.com", "m.youtube.com": return .youtube
        case "notion.so", "notion.com": return .notion
        case "app.slack.com", "slack.com": return .slack
        case "figma.com": return .figma
        default: return host.hasSuffix(".slack.com") ? .slack : nil
        }
    }

    /// The apps with an unread badge: the ones Arc's ARC_AppTray catalog has a badge color for and
    /// whose page title carries a count (GMailBadgeRed, WhatsAppBadgeRed, TwitterBadgeGray).
    /// GithubBadgeBlack also exists, but GitHub's title has no count: no badge (GUESS — capture pending).
    public var hasUnreadBadge: Bool {
        switch self {
        case .twitter, .whatsApp, .gmail: true
        default: false
        }
    }

    /// Badge fill (ARC_AppTray asset catalog, sRGB): GMailBadgeRed / WhatsAppBadgeRed (0.918, 0.263,
    /// 0.208), TwitterBadgeGray (0.267 gray; white in dark).
    public func badgeFill(dark: Bool) -> (red: Double, green: Double, blue: Double) {
        if self == .twitter { return dark ? (1, 1, 1) : (0.267, 0.267, 0.267) }
        return (0.918, 0.263, 0.208)
    }
}

public enum FavoriteBadgeCount {
    /// The unread count in a page title: "(3) Home / X", "Inbox (12) - a@b.c - Gmail". Arc's
    /// binary holds a `\s\(\d+` fragment next to its badging provider (GUESS, strong, that the count
    /// comes from the title). Zero, a missing count or one over 999,999 gives nil.
    public static func parse(_ title: String) -> Int? {
        let scalars = Array(title.unicodeScalars.prefix(512))
        var i = 0
        while i < scalars.count {
            if scalars[i] == "(", i == 0 || scalars[i - 1].properties.isWhitespace {
                var j = i + 1, value = 0, digits = 0
                while j < scalars.count, digits < 7, ("0"..."9").contains(scalars[j]) {
                    value = value * 10 + Int(scalars[j].value - 48); digits += 1; j += 1
                }
                if digits > 0, digits <= 6, j < scalars.count, scalars[j] == ")",
                   j + 1 == scalars.count || scalars[j + 1].properties.isWhitespace {
                    return value > 0 ? value : nil
                }
            }
            i += 1
        }
        return nil
    }

    /// The text the badge shows. GUESS — capture pending: counts over 99 show "99+".
    public static func label(_ count: Int) -> String { count > 99 ? "99+" : String(count) }
}

/// The user's per-host switches. Arc's keys: `topAppsBadgingDisabledHosts`,
/// `topAppsSubtitleDisabledHosts`, `twitterBadgeEnabled`, `whatsAppBadgeEnabled` (strings; the
/// Favorite menu's "Show Unread Badge" / "Show Time to Next Meeting" items test the host sets,
/// `FUN_102ee07bc` → `FUN_10025008c`).
public struct FavoriteTileSettings: Equatable, Sendable {
    public static let badgingDisabledHostsKey = "open.favorites.badgingDisabledHosts"
    public static let subtitleDisabledHostsKey = "open.favorites.subtitleDisabledHosts"
    public static let twitterBadgeKey = "open.favorites.twitterBadgeEnabled"
    public static let whatsAppBadgeKey = "open.favorites.whatsAppBadgeEnabled"
    /// Posted (object: the UserDefaults) after any window changes a switch.
    public static let didChange = Notification.Name("OpenFavoriteTileSettingsDidChange")
    static let maxHosts = 1_000

    public var badgingDisabledHosts: Set<String> = []
    public var subtitleDisabledHosts: Set<String> = []
    /// Arc keeps separate switches for Twitter and WhatsApp. Default on: GUESS — capture pending.
    public var twitterBadgeEnabled = true
    public var whatsAppBadgeEnabled = true

    public init() {}

    public init(defaults: UserDefaults) {
        func hosts(_ key: String) -> Set<String> {
            Set((defaults.stringArray(forKey: key) ?? []).prefix(Self.maxHosts).map { $0.lowercased() })
        }
        badgingDisabledHosts = hosts(Self.badgingDisabledHostsKey)
        subtitleDisabledHosts = hosts(Self.subtitleDisabledHostsKey)
        twitterBadgeEnabled = defaults.object(forKey: Self.twitterBadgeKey) as? Bool ?? true
        whatsAppBadgeEnabled = defaults.object(forKey: Self.whatsAppBadgeKey) as? Bool ?? true
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(badgingDisabledHosts.sorted().prefix(Self.maxHosts).map { $0 }, forKey: Self.badgingDisabledHostsKey)
        defaults.set(subtitleDisabledHosts.sorted().prefix(Self.maxHosts).map { $0 }, forKey: Self.subtitleDisabledHostsKey)
        defaults.set(twitterBadgeEnabled, forKey: Self.twitterBadgeKey)
        defaults.set(whatsAppBadgeEnabled, forKey: Self.whatsAppBadgeKey)
    }

    public static func host(of url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Whether "Show Unread Badge" is checked for this URL. Twitter and WhatsApp use their own
    /// switches (GUESS — capture pending which key Arc's menu writes for them).
    public func showsBadge(url: URL) -> Bool {
        guard let app = FavoriteApp.match(url: url), app.hasUnreadBadge, let host = Self.host(of: url) else { return false }
        switch app {
        case .twitter: return twitterBadgeEnabled
        case .whatsApp: return whatsAppBadgeEnabled
        default: return !badgingDisabledHosts.contains(host)
        }
    }

    public mutating func setShowsBadge(_ on: Bool, url: URL) {
        guard let app = FavoriteApp.match(url: url), let host = Self.host(of: url) else { return }
        switch app {
        case .twitter: twitterBadgeEnabled = on
        case .whatsApp: whatsAppBadgeEnabled = on
        default: if on { badgingDisabledHosts.remove(host) } else { badgingDisabledHosts.insert(host) }
        }
    }

    public func showsSubtitle(url: URL) -> Bool {
        guard let host = Self.host(of: url) else { return true }
        return !subtitleDisabledHosts.contains(host)
    }

    public mutating func setShowsSubtitle(_ on: Bool, url: URL) {
        guard let host = Self.host(of: url) else { return }
        if on { subtitleDisabledHosts.remove(host) } else { subtitleDisabledHosts.insert(host) }
    }
}
