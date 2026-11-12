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

public enum SleepMode: String, Codable, CaseIterable, Sendable {
    case off, conservative, balanced, aggressive

    public var discardDelay: TimeInterval? {
        switch self {
        case .off: nil
        case .conservative: 900
        case .balanced: 300
        case .aggressive: 120
        }
    }
}

public struct ProfileSettings: Codable, Hashable, Sendable {
    public var autoArchiveAfter: AutoArchiveInterval
    public var littleOpenAutoArchiveAfter: AutoArchiveInterval
    public var searchSuggestEnabled: Bool
    public var downloadDirectory: String
    public var askWhereToSaveEachFile: Bool
    public var customSearchEngines: [SearchEngine]
    public var searchEngineID: String
    public var sleepMode: SleepMode
    public var keepAliveSites: [String]
    /// What New Note creates in this Profile: "note" or a web document id (DocumentApps).
    public var defaultDocumentApp: String

    public init(autoArchiveAfter: AutoArchiveInterval = .twelveHours, littleOpenAutoArchiveAfter: AutoArchiveInterval = .sixHours, searchEngineID: String = "google", sleepMode: SleepMode = .balanced, searchSuggestEnabled: Bool = true, downloadDirectory: String = "~/Downloads", askWhereToSaveEachFile: Bool = false, customSearchEngines: [SearchEngine] = [], keepAliveSites: [String] = [], defaultDocumentApp: String = "note") {
        self.autoArchiveAfter = autoArchiveAfter
        self.littleOpenAutoArchiveAfter = littleOpenAutoArchiveAfter
        self.searchSuggestEnabled = searchSuggestEnabled
        self.downloadDirectory = downloadDirectory
        self.askWhereToSaveEachFile = askWhereToSaveEachFile
        self.customSearchEngines = customSearchEngines
        self.searchEngineID = searchEngineID
        self.sleepMode = sleepMode
        self.keepAliveSites = keepAliveSites
        self.defaultDocumentApp = defaultDocumentApp
    }

    private enum CodingKeys: String, CodingKey {
        case autoArchiveAfter, littleOpenAutoArchiveAfter, searchEngineID, sleepMode, keepAliveSites, defaultDocumentApp
        case searchSuggestEnabled, downloadDirectory, askWhereToSaveEachFile, customSearchEngines
        case littleArcAutoArchiveAfter // Legacy snapshots, decode only.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoArchiveAfter = try container.decode(AutoArchiveInterval.self, forKey: .autoArchiveAfter)
        littleOpenAutoArchiveAfter = try container.decodeIfPresent(AutoArchiveInterval.self, forKey: .littleOpenAutoArchiveAfter)
            ?? container.decodeIfPresent(AutoArchiveInterval.self, forKey: .littleArcAutoArchiveAfter)
            ?? .sixHours
        searchEngineID = try container.decodeIfPresent(String.self, forKey: .searchEngineID) ?? "google"
        searchSuggestEnabled = try container.decodeIfPresent(Bool.self, forKey: .searchSuggestEnabled) ?? true
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? "~/Downloads"
        askWhereToSaveEachFile = try container.decodeIfPresent(Bool.self, forKey: .askWhereToSaveEachFile) ?? false
        customSearchEngines = try container.decodeIfPresent([SearchEngine].self, forKey: .customSearchEngines) ?? []
        sleepMode = try container.decodeIfPresent(SleepMode.self, forKey: .sleepMode) ?? .balanced
        keepAliveSites = try container.decodeIfPresent([String].self, forKey: .keepAliveSites) ?? []
        defaultDocumentApp = try container.decodeIfPresent(String.self, forKey: .defaultDocumentApp) ?? "note"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoArchiveAfter, forKey: .autoArchiveAfter)
        try container.encode(littleOpenAutoArchiveAfter, forKey: .littleOpenAutoArchiveAfter)
        try container.encode(searchEngineID, forKey: .searchEngineID)
        try container.encode(searchSuggestEnabled, forKey: .searchSuggestEnabled)
        try container.encode(downloadDirectory, forKey: .downloadDirectory)
        try container.encode(askWhereToSaveEachFile, forKey: .askWhereToSaveEachFile)
        try container.encode(customSearchEngines, forKey: .customSearchEngines)
        try container.encode(sleepMode, forKey: .sleepMode)
        try container.encode(keepAliveSites, forKey: .keepAliveSites)
        try container.encode(defaultDocumentApp, forKey: .defaultDocumentApp)
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
    /// The user dismissed the Favorites empty-state card for this Profile (audit A3; Arc keeps
    /// `topAppsEmptyStateDismissedForProfiles`). Stored with the Profile in the snapshot.
    public var favoritesEmptyStateDismissed = false

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
    public var title: String?
    public var icon: SpaceIcon?
    public var theme: SpaceTheme
    public var profileID: ProfileID
    public var pinned: [SidebarNode]
    public var today: [SidebarNode]
    public var isPinnedCollapsed: Bool

    public init(id: SpaceID = SpaceID(), title: String? = nil, icon: SpaceIcon? = nil, theme: SpaceTheme = SpaceTheme(), profileID: ProfileID, pinned: [SidebarNode] = [], today: [SidebarNode] = [], isPinnedCollapsed: Bool = false) {
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
    /// Measured minimum sidebar width (S2 06/0029); below 219 pt the toolbar is compact.
    public nonisolated static let minimumSidebarWidth = 164.0
    public let id: WindowID
    public var focusedSpaceID: SpaceID
    /// A retained closed-window state is not showing content. Snapshot decoding
    /// defaults to true because restored windows are about to be composed.
    public internal(set) var isShowingContent = true
    /// Selected node per Space; only focusedSpaceID is on screen.
    public var selectedNodeBySpace: [SpaceID: ItemID]
    public var sidebarWidth: Double
    public var sidebarMode: SidebarMode
    public var frameX: Double
    public var frameY: Double
    public var frameWidth: Double
    public var frameHeight: Double
    public var style: WindowStyle
    public var stayOnTop: Bool
    /// The optional content toolbar (View ▸ Show Toolbar, Cmd+Shift+D; commandbar-completion §4.6).
    /// Window chrome like `sidebarMode`; Little Open windows never show it.
    public var showsToolbar: Bool
    /// Standard-window focus recency, retained in the existing session snapshot.
    public var lastFocusedAt: Date?

    public init(id: WindowID = WindowID(), focusedSpaceID: SpaceID, selectedNodeBySpace: [SpaceID: ItemID] = [:], sidebarWidth: Double = 228, sidebarMode: SidebarMode = .anchored, frameX: Double = 100, frameY: Double = 100, frameWidth: Double = 1280, frameHeight: Double = 800, style: WindowStyle = .standard, stayOnTop: Bool = false, showsToolbar: Bool = false) {
        self.id = id; self.focusedSpaceID = focusedSpaceID
        self.selectedNodeBySpace = selectedNodeBySpace
        self.sidebarWidth = sidebarWidth; self.sidebarMode = sidebarMode
        self.frameX = frameX; self.frameY = frameY
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.style = style; self.stayOnTop = stayOnTop; self.showsToolbar = showsToolbar
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
    case littleOpen(profile: ProfileID?)
    case mostRecentSpace(profile: ProfileID?)

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
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: key)
            self = .littleOpen(profile: try nested.decodeIfPresent(ProfileID.self, forKey: .profile))
        case "mostRecentSpace":
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: key)
            self = .mostRecentSpace(profile: try nested.decodeIfPresent(ProfileID.self, forKey: .profile))
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
        case .littleOpen(let profile):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: .littleOpen)
            try nested.encodeIfPresent(profile, forKey: .profile)
        case .mostRecentSpace(let profile):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationSpaceKey.self, forKey: .mostRecentSpace)
            try nested.encodeIfPresent(profile, forKey: .profile)
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

private enum RoutingDestinationSpaceKey: String, CodingKey { case value = "_0", profile }

public enum DefaultDestination: Codable, Hashable, Sendable {
    case space(SpaceID)
    case littleOpen(profile: ProfileID?)
    case mostRecentSpace(profile: ProfileID?)

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
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: key)
            self = .littleOpen(profile: try nested.decodeIfPresent(ProfileID.self, forKey: .profile))
        case "mostRecentSpace":
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: key)
            self = .mostRecentSpace(profile: try nested.decodeIfPresent(ProfileID.self, forKey: .profile))
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
        case .littleOpen(let profile):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: .littleOpen)
            try nested.encodeIfPresent(profile, forKey: .profile)
        case .mostRecentSpace(let profile):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationSpaceKey.self, forKey: .mostRecentSpace)
            try nested.encodeIfPresent(profile, forKey: .profile)
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

private enum DefaultDestinationSpaceKey: String, CodingKey { case value = "_0", profile }

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
