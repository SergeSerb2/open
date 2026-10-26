import Foundation
import Observation

public enum AutoArchiveInterval: String, Codable, CaseIterable, Sendable {
    case never, oneHour, sixHours, twelveHours, twentyFourHours, sevenDays, thirtyDays

    public var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneHour: return 3600
        case .sixHours: return 6 * 3600
        case .twelveHours: return 12 * 3600
        case .twentyFourHours: return 24 * 3600
        case .sevenDays: return 7 * 86400
        case .thirtyDays: return 30 * 86400
        }
    }
}

public struct ProfileSettings: Codable, Hashable, Sendable {
    public var autoArchiveAfter: AutoArchiveInterval
    public var littleArcAutoArchiveAfter: AutoArchiveInterval
    public var searchEngineID: String

    public init(autoArchiveAfter: AutoArchiveInterval = .twelveHours, littleArcAutoArchiveAfter: AutoArchiveInterval = .twelveHours, searchEngineID: String = "duckduckgo") {
        self.autoArchiveAfter = autoArchiveAfter
        self.littleArcAutoArchiveAfter = littleArcAutoArchiveAfter
        self.searchEngineID = searchEngineID
    }
}

@MainActor
@Observable
public final class Profile {
    public let id: ProfileID
    public var name: String
    public var icon: SpaceIcon?
    public var favorites: [Tab]
    public var settings: ProfileSettings
    public var dataDirectoryName: String

    public init(id: ProfileID = ProfileID(), name: String = "Default", icon: SpaceIcon? = nil, favorites: [Tab] = [], settings: ProfileSettings = ProfileSettings(), dataDirectoryName: String = "Default") {
        self.id = id; self.name = name; self.icon = icon
        self.favorites = favorites; self.settings = settings
        self.dataDirectoryName = dataDirectoryName
    }
}

@MainActor
@Observable
public final class Space {
    public let id: SpaceID
    public var title: String
    public var icon: SpaceIcon?
    public var theme: SpaceTheme
    public var profileID: ProfileID
    public var pinned: [SidebarNode]
    public var today: [SidebarNode]
    public var isPinnedCollapsed: Bool

    public init(id: SpaceID = SpaceID(), title: String = "Space", icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme(), profileID: ProfileID, pinned: [SidebarNode] = [], today: [SidebarNode] = [], isPinnedCollapsed: Bool = false) {
        self.id = id; self.title = title; self.icon = icon; self.theme = theme
        self.profileID = profileID; self.pinned = pinned; self.today = today
        self.isPinnedCollapsed = isPinnedCollapsed
    }
}

public enum SidebarMode: String, Codable, Sendable {
    case anchored, hidden
}

public enum WindowStyle: String, Codable, Sendable {
    case standard, littleArc
}

@MainActor
@Observable
public final class BrowserWindowState {
    public let id: WindowID
    public var focusedSpaceID: SpaceID
    /// Selected node per Space.
    public var selectedNodeBySpace: [SpaceID: ItemID]
    public var sidebarWidth: Double
    public var sidebarMode: SidebarMode
    public var frameX: Double
    public var frameY: Double
    public var frameWidth: Double
    public var frameHeight: Double
    public var style: WindowStyle
    public var stayOnTop: Bool

    public init(id: WindowID = WindowID(), focusedSpaceID: SpaceID, selectedNodeBySpace: [SpaceID: ItemID] = [:], sidebarWidth: Double = 228, sidebarMode: SidebarMode = .anchored, frameX: Double = 100, frameY: Double = 100, frameWidth: Double = 1280, frameHeight: Double = 800, style: WindowStyle = .standard, stayOnTop: Bool = false) {
        self.id = id; self.focusedSpaceID = focusedSpaceID
        self.selectedNodeBySpace = selectedNodeBySpace
        self.sidebarWidth = sidebarWidth; self.sidebarMode = sidebarMode
        self.frameX = frameX; self.frameY = frameY
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.style = style; self.stayOnTop = stayOnTop
    }
}

// MARK: - Link routing (Air Traffic Control)

public enum RoutingMatch: Codable, Hashable, Sendable {
    case hostContains(String)
    case hostEquals(String)
    case urlPrefix(String)
}

public enum RoutingDestination: Codable, Hashable, Sendable {
    case space(SpaceID)
    case littleArc
    case mostRecentSpace
}

public enum DefaultDestination: Codable, Hashable, Sendable {
    case mostRecentSpace
    case littleArc
    case space(SpaceID)
}

public struct RoutingRule: Codable, Hashable, Sendable, Identifiable {
    public var id: RuleID
    public var match: RoutingMatch
    public var destination: RoutingDestination
    public init(id: RuleID = RuleID(), match: RoutingMatch, destination: RoutingDestination) {
        self.id = id; self.match = match; self.destination = destination
    }
}
