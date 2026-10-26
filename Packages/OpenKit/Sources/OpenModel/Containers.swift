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
    public var littleOpenAutoArchiveAfter: AutoArchiveInterval
    public var searchEngineID: String

    public init(autoArchiveAfter: AutoArchiveInterval = .twelveHours, littleOpenAutoArchiveAfter: AutoArchiveInterval = .sixHours, searchEngineID: String = "duckduckgo") {
        self.autoArchiveAfter = autoArchiveAfter
        self.littleOpenAutoArchiveAfter = littleOpenAutoArchiveAfter
        self.searchEngineID = searchEngineID
    }

    private enum CodingKeys: String, CodingKey {
        case autoArchiveAfter, littleOpenAutoArchiveAfter, searchEngineID
        case littleArcAutoArchiveAfter // Legacy snapshots, decode only.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoArchiveAfter = try container.decode(AutoArchiveInterval.self, forKey: .autoArchiveAfter)
        littleOpenAutoArchiveAfter = try container.decodeIfPresent(AutoArchiveInterval.self, forKey: .littleOpenAutoArchiveAfter)
            ?? container.decodeIfPresent(AutoArchiveInterval.self, forKey: .littleArcAutoArchiveAfter)
            ?? .sixHours
        searchEngineID = try container.decode(String.self, forKey: .searchEngineID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoArchiveAfter, forKey: .autoArchiveAfter)
        try container.encode(littleOpenAutoArchiveAfter, forKey: .littleOpenAutoArchiveAfter)
        try container.encode(searchEngineID, forKey: .searchEngineID)
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
    case standard, littleOpen
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
    case littleOpen
    case mostRecentSpace

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RoutingDestinationCodingKey.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "RoutingDestination: expected one key"))
        }
        switch key.stringValue {
        case "space":
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: key)
            self = .space(try nested.decode(SpaceID.self, forKey: .value))
        case "littleOpen", "littleArc": // Legacy snapshots, decode only.
            self = .littleOpen
        case "mostRecentSpace":
            self = .mostRecentSpace
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "RoutingDestination: unknown key \(key.stringValue)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RoutingDestinationCodingKey.self)
        switch self {
        case .space(let id):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: .space)
            try nested.encode(id, forKey: .value)
        case .littleOpen:
            _ = container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: .littleOpen)
        case .mostRecentSpace:
            _ = container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: .mostRecentSpace)
        }
    }
}

// String passthrough keeps unknown and legacy keys visible to the strict decoder.
private struct RoutingDestinationCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static let space = Self(stringValue: "space")
    static let littleOpen = Self(stringValue: "littleOpen")
    static let mostRecentSpace = Self(stringValue: "mostRecentSpace")
}

private enum RoutingDestinationSpaceKey: String, CodingKey { case value = "_0" }

public enum DefaultDestination: Codable, Hashable, Sendable {
    case space(SpaceID)
    case littleOpen
    case mostRecentSpace

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DefaultDestinationCodingKey.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "DefaultDestination: expected one key"))
        }
        switch key.stringValue {
        case "space":
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: key)
            self = .space(try nested.decode(SpaceID.self, forKey: .value))
        case "littleOpen", "littleArc": // Legacy snapshots, decode only.
            self = .littleOpen
        case "mostRecentSpace":
            self = .mostRecentSpace
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "DefaultDestination: unknown key \(key.stringValue)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DefaultDestinationCodingKey.self)
        switch self {
        case .space(let id):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: .space)
            try nested.encode(id, forKey: .value)
        case .littleOpen:
            _ = container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: .littleOpen)
        case .mostRecentSpace:
            _ = container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: .mostRecentSpace)
        }
    }
}

// String passthrough keeps unknown and legacy keys visible to the strict decoder.
private struct DefaultDestinationCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static let space = Self(stringValue: "space")
    static let littleOpen = Self(stringValue: "littleOpen")
    static let mostRecentSpace = Self(stringValue: "mostRecentSpace")
}

private enum DefaultDestinationSpaceKey: String, CodingKey { case value = "_0" }

public struct RoutingRule: Codable, Hashable, Sendable, Identifiable {
    public var id: RuleID
    public var match: RoutingMatch
    public var destination: RoutingDestination
    /// Bundle ids use trimmed lowercase as their canonical form.
    public var sourceBundleID: String?
    public init(id: RuleID = RuleID(), match: RoutingMatch, destination: RoutingDestination, sourceBundleID: String? = nil) {
        self.id = id; self.match = match; self.destination = destination
        let source = sourceBundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sourceBundleID = source?.isEmpty == false ? source : nil
    }
}
