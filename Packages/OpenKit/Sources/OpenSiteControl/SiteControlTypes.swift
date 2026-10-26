import Foundation
import OpenModel
import OpenBoosts
import OpenWeb

public struct SiteControlContext: Sendable, Equatable {
    public var tabID: ItemID
    public var profileID: ProfileID
    public var url: URL
    public var displayHost: String
    public var isIncognito: Bool
    public var security: SiteSecurity
    public var faviconPNG: Data?
    public init(tabID: ItemID, profileID: ProfileID, url: URL, displayHost: String, isIncognito: Bool = false,
                security: SiteSecurity = .unknown, faviconPNG: Data? = nil) {
        self.tabID = tabID; self.profileID = profileID; self.url = url; self.displayHost = displayHost
        self.isIncognito = isIncognito; self.security = security; self.faviconPNG = faviconPNG
    }
    public var isWebsite: Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }
}

public enum SiteSettingKind: Hashable, Sendable { case contentBlocking, permission(SitePermission), content(String) }
public enum SiteSettingState: Sendable, Equatable { case on, off, unavailable }
public struct SiteSettingTile: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: SiteSettingKind
    public var title: String
    public var subtitle: String
    public var state: SiteSettingState
    public var symbol: String
    public var inUse: Bool
    public var help: String?
    public init(id: String, kind: SiteSettingKind, title: String, subtitle: String, state: SiteSettingState,
                symbol: String, inUse: Bool = false, help: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.state = state; self.symbol = symbol; self.inUse = inUse; self.help = help
    }
}

public struct SiteControlSnapshot: Sendable, Equatable {
    public var context: SiteControlContext
    public var tiles: [SiteSettingTile]
    public var boosts: [Boost]
    public var boostsGloballyEnabled: Bool
    public var capabilities: Set<SiteCapability>
    public var commandsEnabled: [String: Bool]
    public init(context: SiteControlContext, tiles: [SiteSettingTile] = [], boosts: [Boost] = [],
                boostsGloballyEnabled: Bool = true,
                capabilities: Set<SiteCapability> = [], commandsEnabled: [String: Bool] = [:]) {
        self.context = context; self.tiles = tiles; self.boosts = boosts
        self.boostsGloballyEnabled = boostsGloballyEnabled
        self.capabilities = capabilities; self.commandsEnabled = commandsEnabled
    }
    public var canCreateBoost: Bool { context.isWebsite && !context.isIncognito && boostsGloballyEnabled }
}
public enum SiteCapability: Hashable, Sendable { case changedSettings, clearCache, securityState, certificateViewer, extensionPinning, isolatedWorld }
public enum SiteSecurity: Sendable, Equatable { case secure, insecure, unknown }
public struct SiteDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let cookies = SiteDataKinds(rawValue: 1), cache = SiteDataKinds(rawValue: 2), storage = SiteDataKinds(rawValue: 4)
}
public enum BoostCodeTab: Sendable, Equatable { case css, js }
public enum BoostEditorMode: Sendable, Equatable { case simple, code(BoostCodeTab) }
public enum SiteControlPresentationMode: Sendable, Equatable { case standard, extensionPicker }
public enum SiteControlAnchor: Sendable, Equatable { case urlField, paneBar(ItemID), contentTopLeading }
public enum SiteControlDismissReason: Sendable, Equatable { case escape, outside, anchor, action, command, sourceUnavailable }

/// Registration identity, scoped to the source that returned it.
public struct SiteControlObservationToken: Hashable, Sendable {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
}

/// Coordinates are in the overlay's flipped (top-left) coordinate space. The shell
/// supplies geometry; this library never reaches into sidebar or engine views.
public struct SiteControlGeometry: Sendable {
    public var anchor: CGRect
    public var sidebarMaxX: CGFloat
    public var content: CGRect
    public init(anchor: CGRect, sidebarMaxX: CGFloat, content: CGRect) {
        self.anchor = anchor; self.sidebarMaxX = sidebarMaxX; self.content = content
    }
}

/// Adapter events contain no bridge capability. Only the App adapter decodes and
/// validates picker messages with the coordinator before publishing these events.
public enum BoostPickerEvent: Sendable {
    case committed(Boost), removed(Boost), exited, listResult([ZapListEntry])
}
