import Foundation
import OpenModel

/// Versioned persisted snapshot. Separate from the live classes.
public struct SnapshotFileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profiles: [ProfileDTO]
    public var spaces: [SpaceDTO]
    public var windows: [WindowDTO]
    public var routingRules: [RoutingRuleDTO]
    public var defaultDestination: DefaultDestinationDTO

    public init(schemaVersion: Int = 1, profiles: [ProfileDTO], spaces: [SpaceDTO], windows: [WindowDTO], routingRules: [RoutingRuleDTO], defaultDestination: DefaultDestinationDTO) {
        self.schemaVersion = schemaVersion; self.profiles = profiles; self.spaces = spaces
        self.windows = windows; self.routingRules = routingRules; self.defaultDestination = defaultDestination
    }
}

public struct ProfileDTO: Codable, Sendable {
    public var id: String
    public var name: String
    public var icon: SpaceIconDTO?
    public var favorites: [NodeDTO]
    public var settings: ProfileSettingsDTO
    public var dataDirectoryName: String
    /// Favorites empty-state card dismissed (A3); absent in older snapshots.
    public var favoritesEmptyStateDismissed: Bool? = nil
}

public struct ProfileSettingsDTO: Codable, Sendable {
    public var autoArchiveAfter: String
    public var littleOpenAutoArchiveAfter: String
    public var searchSuggestEnabled: Bool
    public var downloadDirectory: String
    public var askWhereToSaveEachFile: Bool
    public var customSearchEngines: [SearchEngine]
    public var searchEngineID: String
    public var sleepMode: String?
    public var keepAliveSites: [String]
    /// What New Note creates in this Profile: "note" or a web document id (DocumentApps).
    public var defaultDocumentApp: String

    public init(autoArchiveAfter: String, littleOpenAutoArchiveAfter: String, searchEngineID: String, sleepMode: String? = nil, searchSuggestEnabled: Bool = true, downloadDirectory: String = "~/Downloads", askWhereToSaveEachFile: Bool = false, customSearchEngines: [SearchEngine] = [], keepAliveSites: [String] = [], defaultDocumentApp: String = "note") {
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
        autoArchiveAfter = try container.decode(String.self, forKey: .autoArchiveAfter)
        littleOpenAutoArchiveAfter = try container.decodeIfPresent(String.self, forKey: .littleOpenAutoArchiveAfter)
            ?? container.decodeIfPresent(String.self, forKey: .littleArcAutoArchiveAfter)
            ?? AutoArchiveInterval.sixHours.rawValue
        searchEngineID = try container.decodeIfPresent(String.self, forKey: .searchEngineID) ?? "google"
        searchSuggestEnabled = try container.decodeIfPresent(Bool.self, forKey: .searchSuggestEnabled) ?? true
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? "~/Downloads"
        askWhereToSaveEachFile = try container.decodeIfPresent(Bool.self, forKey: .askWhereToSaveEachFile) ?? false
        customSearchEngines = try container.decodeIfPresent([SearchEngine].self, forKey: .customSearchEngines) ?? []
        sleepMode = try container.decodeIfPresent(String.self, forKey: .sleepMode)
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
        try container.encodeIfPresent(sleepMode, forKey: .sleepMode)
        try container.encode(keepAliveSites, forKey: .keepAliveSites)
        try container.encode(defaultDocumentApp, forKey: .defaultDocumentApp)
    }
}

public enum SpaceIconDTO: Codable, Sendable {
    case emoji(String)
    case symbol(String)
    case named(String)
}

public struct SpaceDTO: Codable, Sendable {
    public var id: String
    public var title: String?
    public var icon: SpaceIconDTO?
    public var theme: SpaceTheme
    public var profileID: String
    public var pinned: [NodeDTO]
    public var today: [NodeDTO]
    public var isPinnedCollapsed: Bool
}

public enum NodeDTO: Codable, Sendable {
    case tab(TabDTO)
    case folder(FolderDTO)
    case split(SplitDTO)
}

public struct TabDTO: Codable, Sendable {
    public var id: String
    public var url: String
    public var title: String
    public var customTitle: String?
    public var pinnedURL: String?
    public var customIcon: String?
    public var iconOverride: SpaceIconDTO?
    public var createdAt: Double
    public var lastActiveAt: Double
    public var isMuted: Bool
    public var openerID: String?
    public var isUnread: Bool
    /// Live Folder row's pull request URL (LF L2); absent for normal tabs.
    public var liveItemURL: String? = nil
    /// Live Folder row's pull request facts (C-LF-1); absent for normal tabs and older snapshots.
    public var liveItem: LiveItemInfo? = nil
}

public struct FolderDTO: Codable, Sendable {
    public var peekedChildID: String? = nil
    public var id: String
    public var title: String
    public var isExpanded: Bool
    public var customIcon: String?
    public var iconOverride: SpaceIconDTO?
    public var children: [NodeDTO]
    /// Live Folder settings (LF L2); absent in older snapshots and for normal folders.
    public var live: LiveFolderConfig? = nil
}

public struct SplitDTO: Codable, Sendable {
    public var id: String
    public var orientation: String
    public var fractions: [Double]
    public var panes: [TabDTO]
    public var focusedPaneID: String?
    public var customTitle: String? = nil
    public var iconOverride: SpaceIconDTO? = nil
}

public struct WindowDTO: Codable, Sendable {
    public var id: String
    public var focusedSpaceID: String
    public var selectedNodeBySpace: [String: String]
    public var sidebarWidth: Double
    public var sidebarMode: String
    public var frameX: Double
    public var frameY: Double
    public var frameWidth: Double
    public var frameHeight: Double
    public var style: String
    public var stayOnTop: Bool
    /// Absent in snapshots written before the toolbar (= false); written only when true.
    public var showsToolbar: Bool?
    public var lastFocusedAt: Date?
}

public enum RoutingMatchDTO: Codable, Sendable {
    case hostContains(String)
    case hostEquals(String)
    case urlPrefix(String)
}

/// Schema version stays 1. The `mostRecentSpace` case was added after v1 shipped;
/// Legacy destination spellings decode explicitly; new saves use `littleOpen`.
public enum RoutingDestinationDTO: Codable, Sendable {
    case space(String)
    case littleOpen(profile: String?)
    case mostRecentSpace(profile: String?)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RoutingDestinationDTOCodingKey.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "RoutingDestinationDTO: expected one key"))
        }
        switch key.stringValue {
        case "space":
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: key)
            self = .space(try nested.decode(String.self, forKey: .value))
        case "littleOpen", "littleArc": // Legacy snapshots, decode only.
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: key)
            self = .littleOpen(profile: try nested.decodeIfPresent(String.self, forKey: .profile))
        case "mostRecentSpace":
            let nested = try container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: key)
            self = .mostRecentSpace(profile: try nested.decodeIfPresent(String.self, forKey: .profile))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "RoutingDestinationDTO: unknown key \(key.stringValue)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RoutingDestinationDTOCodingKey.self)
        switch self {
        case .space(let id):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: .space)
            try nested.encode(id, forKey: .value)
        case .littleOpen(let profile):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: .littleOpen)
            try nested.encodeIfPresent(profile, forKey: .profile)
        case .mostRecentSpace(let profile):
            var nested = container.nestedContainer(keyedBy: RoutingDestinationDTOSpaceKey.self, forKey: .mostRecentSpace)
            try nested.encodeIfPresent(profile, forKey: .profile)
        }
    }
}

// String passthrough keeps unknown and legacy keys visible to the strict decoder.
private struct RoutingDestinationDTOCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static let space = Self(stringValue: "space")
    static let littleOpen = Self(stringValue: "littleOpen")
    static let mostRecentSpace = Self(stringValue: "mostRecentSpace")
}

private enum RoutingDestinationDTOSpaceKey: String, CodingKey { case value = "_0", profile }

public enum DefaultDestinationDTO: Codable, Sendable {
    case space(String)
    case littleOpen(profile: String?)
    case mostRecentSpace(profile: String?)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DefaultDestinationDTOCodingKey.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "DefaultDestinationDTO: expected one key"))
        }
        switch key.stringValue {
        case "space":
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: key)
            self = .space(try nested.decode(String.self, forKey: .value))
        case "littleOpen", "littleArc": // Legacy snapshots, decode only.
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: key)
            self = .littleOpen(profile: try nested.decodeIfPresent(String.self, forKey: .profile))
        case "mostRecentSpace":
            let nested = try container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: key)
            self = .mostRecentSpace(profile: try nested.decodeIfPresent(String.self, forKey: .profile))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "DefaultDestinationDTO: unknown key \(key.stringValue)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DefaultDestinationDTOCodingKey.self)
        switch self {
        case .space(let id):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: .space)
            try nested.encode(id, forKey: .value)
        case .littleOpen(let profile):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: .littleOpen)
            try nested.encodeIfPresent(profile, forKey: .profile)
        case .mostRecentSpace(let profile):
            var nested = container.nestedContainer(keyedBy: DefaultDestinationDTOSpaceKey.self, forKey: .mostRecentSpace)
            try nested.encodeIfPresent(profile, forKey: .profile)
        }
    }
}

// String passthrough keeps unknown and legacy keys visible to the strict decoder.
private struct DefaultDestinationDTOCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static let space = Self(stringValue: "space")
    static let littleOpen = Self(stringValue: "littleOpen")
    static let mostRecentSpace = Self(stringValue: "mostRecentSpace")
}

private enum DefaultDestinationDTOSpaceKey: String, CodingKey { case value = "_0", profile }

public struct RoutingRuleDTO: Codable, Sendable {
    public var id: String
    public var match: RoutingMatchDTO
    public var destination: RoutingDestinationDTO
    public var sourceBundleID: String?
}

// MARK: - Mapping (call on MainActor for live model)

@MainActor
public enum SnapshotMapper {
    public static func dto(from model: BrowserModel) -> SnapshotFileDTO {
        SnapshotFileDTO(
            profiles: model.profiles.map { profileDTO($0) },
            spaces: model.spaces.map { spaceDTO($0) },
            windows: model.windows.map { windowDTO($0) },
            routingRules: model.routingRules.map { ruleDTO($0) },
            defaultDestination: defaultDestinationDTO(model.defaultDestination)
        )
    }

    public static func model(from dto: SnapshotFileDTO) -> BrowserModel {
        let (dto, repairs) = removingDuplicateIDs(dto)
        for line in repairs { FileHandle.standardError.write(Data("Open: snapshot repair: \(line)\n".utf8)) }
        let profiles = dto.profiles.map { profile(from: $0) }
        let spaces = dto.spaces.map { space(from: $0) }
        let windows = dto.windows.map { window(from: $0) }
        let rules = dto.routingRules.map { rule(from: $0) }
        let model = BrowserModel(profiles: profiles, spaces: spaces, windows: windows, routingRules: rules, defaultDestination: defaultDestination(from: dto.defaultDestination))
        model.loadRepairs = repairs
        return model
    }

    /// A damaged snapshot can repeat an ID. The first Profile or Space with an ID wins and later
    /// ones are dropped. A repeated node ID: a tab identical to the first one is dropped, any
    /// other node (a different tab, a folder or a split) keeps its contents under a fresh ID.
    static func removingDuplicateIDs(_ input: SnapshotFileDTO) -> (SnapshotFileDTO, [String]) {
        var dto = input, repairs: [String] = []
        func key(_ id: String) -> String? { UUID(uuidString: id)?.uuidString }
        var profileIDs = Set<String>(), spaceIDs = Set<String>()
        dto.profiles = dto.profiles.filter { profile in
            guard let id = key(profile.id), !profileIDs.insert(id).inserted else { return true }
            repairs.append("dropped duplicate Profile \(id)"); return false
        }
        dto.spaces = dto.spaces.filter { space in
            guard let id = key(space.id), !spaceIDs.insert(id).inserted else { return true }
            repairs.append("dropped duplicate Space \(id)"); return false
        }
        var seen: [String: Data] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func fresh() -> String { UUID().uuidString }
        func tab(_ tab: TabDTO) -> TabDTO? {
            var tab = tab
            let body = (try? encoder.encode(tab)) ?? Data()
            guard let id = key(tab.id) else { return tab }
            guard let first = seen[id] else { seen[id] = body; return tab }
            if first == body { repairs.append("dropped duplicate tab \(id)"); return nil }
            tab.id = fresh(); seen[key(tab.id)!] = body
            repairs.append("gave tab \(id) a new ID \(tab.id)")
            return tab
        }
        func claim(_ id: inout String, _ kind: String) {
            guard let current = key(id) else { return }
            guard seen[current] != nil else { seen[current] = Data(); return }
            id = fresh(); seen[key(id)!] = Data()
            repairs.append("gave \(kind) \(current) a new ID \(id)")
        }
        func nodes(_ list: [NodeDTO]) -> [NodeDTO] {
            list.compactMap { node in
                switch node {
                case .tab(let t): return tab(t).map(NodeDTO.tab)
                case .folder(var folder):
                    claim(&folder.id, "folder")
                    folder.children = nodes(folder.children)
                    return .folder(folder)
                case .split(var split):
                    claim(&split.id, "split")
                    split.panes = split.panes.compactMap(tab)
                    return split.panes.isEmpty ? nil : .split(split)
                }
            }
        }
        for index in dto.profiles.indices { dto.profiles[index].favorites = nodes(dto.profiles[index].favorites) }
        for index in dto.spaces.indices {
            dto.spaces[index].pinned = nodes(dto.spaces[index].pinned)
            dto.spaces[index].today = nodes(dto.spaces[index].today)
        }
        return (dto, repairs)
    }

    static func iconDTO(_ icon: SpaceIcon?) -> SpaceIconDTO? {
        switch icon {
        case .emoji(let s): return .emoji(s)
        case .symbol(let s): return .symbol(s)
        case .named(let s): return .named(s)
        case nil: return nil
        }
    }

    static func icon(from dto: SpaceIconDTO?) -> SpaceIcon? {
        switch dto {
        case .emoji(let s): return .emoji(s)
        case .symbol(let s): return .symbol(s)
        case .named(let s): return .named(s)
        case nil: return nil
        }
    }

    static func profileDTO(_ p: Profile) -> ProfileDTO {
        ProfileDTO(id: p.id.rawValue.uuidString, name: p.name, icon: iconDTO(p.icon),
                   favorites: p.favorites.map { .tab(tabDTO($0)) },
                   settings: ProfileSettingsDTO(autoArchiveAfter: p.settings.autoArchiveAfter.rawValue, littleOpenAutoArchiveAfter: p.settings.littleOpenAutoArchiveAfter.rawValue, searchEngineID: p.settings.searchEngineID, sleepMode: p.settings.sleepMode.rawValue, searchSuggestEnabled: p.settings.searchSuggestEnabled, downloadDirectory: p.settings.downloadDirectory, askWhereToSaveEachFile: p.settings.askWhereToSaveEachFile, customSearchEngines: p.settings.customSearchEngines, keepAliveSites: p.settings.keepAliveSites, defaultDocumentApp: p.settings.defaultDocumentApp),
                   dataDirectoryName: p.dataDirectoryName,
                   favoritesEmptyStateDismissed: p.favoritesEmptyStateDismissed ? true : nil)
    }

    static func profile(from dto: ProfileDTO) -> Profile {
        let profile = Profile(id: ProfileID(uuidString: dto.id), name: dto.name, icon: icon(from: dto.icon),
                favorites: dto.favorites.compactMap { if case .tab(let t) = $0 { return tab(from: t) }; return nil },
                settings: ProfileSettings(autoArchiveAfter: AutoArchiveInterval(rawValue: dto.settings.autoArchiveAfter) ?? .twelveHours, littleOpenAutoArchiveAfter: AutoArchiveInterval(rawValue: dto.settings.littleOpenAutoArchiveAfter) ?? .sixHours, searchEngineID: dto.settings.searchEngineID, sleepMode: dto.settings.sleepMode.flatMap(SleepMode.init(rawValue:)) ?? .balanced, searchSuggestEnabled: dto.settings.searchSuggestEnabled, downloadDirectory: dto.settings.downloadDirectory, askWhereToSaveEachFile: dto.settings.askWhereToSaveEachFile, customSearchEngines: dto.settings.customSearchEngines, keepAliveSites: dto.settings.keepAliveSites, defaultDocumentApp: dto.settings.defaultDocumentApp),
                dataDirectoryName: dto.dataDirectoryName)
        profile.favoritesEmptyStateDismissed = dto.favoritesEmptyStateDismissed ?? false
        return profile
    }

    static func spaceDTO(_ s: Space) -> SpaceDTO {
        SpaceDTO(id: s.id.rawValue.uuidString, title: s.title, icon: iconDTO(s.icon), theme: s.theme,
                 profileID: s.profileID.rawValue.uuidString,
                 pinned: s.pinned.map { nodeDTO($0) }, today: s.today.map { nodeDTO($0) },
                 isPinnedCollapsed: s.isPinnedCollapsed)
    }

    static func space(from dto: SpaceDTO) -> Space {
        Space(id: SpaceID(uuidString: dto.id), title: dto.title, icon: icon(from: dto.icon), theme: dto.theme,
              profileID: ProfileID(uuidString: dto.profileID),
              pinned: dto.pinned.map { node(from: $0) }, today: dto.today.map { node(from: $0) },
              isPinnedCollapsed: dto.isPinnedCollapsed)
    }

    static func nodeDTO(_ node: SidebarNode) -> NodeDTO {
        switch node {
        case .tab(let t): return .tab(tabDTO(t))
        case .folder(let f): return .folder(FolderDTO(peekedChildID: f.peekedChildID?.description, id: f.id.rawValue.uuidString, title: f.title, isExpanded: f.isExpanded, customIcon: f.customIcon, iconOverride: iconDTO(f.iconOverride), children: f.children.map { nodeDTO($0) }, live: f.live))
        case .split(let s): return .split(SplitDTO(id: s.id.rawValue.uuidString, orientation: s.orientation.rawValue, fractions: s.fractions, panes: s.panes.map { tabDTO($0) }, focusedPaneID: s.focusedPaneID?.rawValue.uuidString, customTitle: s.customTitle, iconOverride: iconDTO(s.iconOverride)))
        }
    }

    /// Archive payloads deliberately omit live-tree peek metadata at every depth.
    static func archivedNodeDTO(_ node: SidebarNode) -> NodeDTO {
        guard case .folder(let folder) = node else { return nodeDTO(node) }
        return .folder(FolderDTO(id: folder.id.description, title: folder.title, isExpanded: folder.isExpanded,
                                 customIcon: folder.customIcon, iconOverride: iconDTO(folder.iconOverride),
                                 children: folder.children.map { archivedNodeDTO($0) }))
    }

    static func node(from dto: NodeDTO) -> SidebarNode {
        switch dto {
        case .tab(let t): return .tab(tab(from: t))
        case .folder(let f):
            let folder = Folder(id: ItemID(uuidString: f.id), title: f.title, isExpanded: f.isExpanded, customIcon: f.customIcon, iconOverride: icon(from: f.iconOverride), children: f.children.map { node(from: $0) }, peekedChildID: f.peekedChildID.flatMap { UUID(uuidString: $0) }.map { ItemID(rawValue: $0) })
            folder.live = f.live
            return .folder(folder)
        case .split(let s): return .split(Split(id: ItemID(uuidString: s.id), orientation: SplitOrientation(rawValue: s.orientation) ?? .horizontal, fractions: s.fractions, panes: s.panes.map { tab(from: $0) }, focusedPaneID: s.focusedPaneID.map { ItemID(uuidString: $0) }, customTitle: s.customTitle, iconOverride: icon(from: s.iconOverride)))
        }
    }

    static func tabDTO(_ t: Tab) -> TabDTO {
        TabDTO(id: t.id.rawValue.uuidString, url: t.url.absoluteString, title: t.title, customTitle: t.customTitle,
               pinnedURL: t.pinnedURL?.absoluteString, customIcon: t.customIcon, iconOverride: iconDTO(t.iconOverride),
               createdAt: t.createdAt.timeIntervalSince1970, lastActiveAt: t.lastActiveAt.timeIntervalSince1970,
               isMuted: t.isMuted, openerID: t.openerID?.rawValue.uuidString, isUnread: t.isUnread, liveItemURL: t.liveItemURL?.absoluteString, liveItem: t.liveItem)
    }

    static func tab(from dto: TabDTO) -> Tab {
        let tab = Tab(id: ItemID(uuidString: dto.id), url: URL(string: dto.url) ?? URL(string: "about:blank")!, title: dto.title,
            customTitle: dto.customTitle, pinnedURL: dto.pinnedURL.flatMap { URL(string: $0) }, customIcon: dto.customIcon, iconOverride: icon(from: dto.iconOverride),
            createdAt: Date(timeIntervalSince1970: dto.createdAt), lastActiveAt: Date(timeIntervalSince1970: dto.lastActiveAt),
            isMuted: dto.isMuted, openerID: dto.openerID.map { ItemID(uuidString: $0) }, isUnread: dto.isUnread)
        tab.liveItemURL = dto.liveItemURL.flatMap(URL.init(string:))
        tab.liveItem = tab.liveItemURL == nil ? nil : dto.liveItem
        return tab
    }

    static func windowDTO(_ w: BrowserWindowState) -> WindowDTO {
        var sel: [String: String] = [:]
        for (k, v) in w.selectedNodeBySpace { sel[k.rawValue.uuidString] = v.rawValue.uuidString }
        return WindowDTO(id: w.id.rawValue.uuidString, focusedSpaceID: w.focusedSpaceID.rawValue.uuidString,
                         selectedNodeBySpace: sel, sidebarWidth: w.sidebarWidth, sidebarMode: w.sidebarMode.rawValue,
                         frameX: w.frameX, frameY: w.frameY, frameWidth: w.frameWidth, frameHeight: w.frameHeight,
                         style: w.style.rawValue, stayOnTop: w.stayOnTop, showsToolbar: w.showsToolbar ? true : nil,
                         lastFocusedAt: w.lastFocusedAt)
    }

    static func window(from dto: WindowDTO) -> BrowserWindowState {
        var sel: [SpaceID: ItemID] = [:]
        for (k, v) in dto.selectedNodeBySpace { sel[SpaceID(uuidString: k)] = ItemID(uuidString: v) }
        let state = BrowserWindowState(id: WindowID(uuidString: dto.id), focusedSpaceID: SpaceID(uuidString: dto.focusedSpaceID),
                                  selectedNodeBySpace: sel, sidebarWidth: dto.sidebarWidth,
                                  sidebarMode: SidebarMode(rawValue: dto.sidebarMode) ?? .anchored,
                                  frameX: dto.frameX, frameY: dto.frameY, frameWidth: dto.frameWidth, frameHeight: dto.frameHeight,
                                  style: WindowStyle(rawValue: dto.style) ?? (dto.style == "littleArc" ? .littleOpen : .standard), stayOnTop: dto.stayOnTop,
                                  showsToolbar: dto.showsToolbar ?? false)
        state.lastFocusedAt = dto.lastFocusedAt
        return state
    }

    private static func normalizedSourceBundleID(_ value: String?) -> String? {
        let source = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source?.isEmpty == false ? source : nil
    }

    static func ruleDTO(_ r: RoutingRule) -> RoutingRuleDTO {
        let m: RoutingMatchDTO
        switch r.match {
        case .hostContains(let s): m = .hostContains(s)
        case .hostEquals(let s): m = .hostEquals(s)
        case .urlPrefix(let s): m = .urlPrefix(s)
        }
        let d: RoutingDestinationDTO
        switch r.destination {
        case .space(let id): d = .space(id.rawValue.uuidString)
        case .littleOpen(let profile): d = .littleOpen(profile: profile.map { $0.description })
        case .mostRecentSpace(let profile): d = .mostRecentSpace(profile: profile.map { $0.description })
        }
        return RoutingRuleDTO(id: r.id.rawValue.uuidString, match: m, destination: d, sourceBundleID: normalizedSourceBundleID(r.sourceBundleID))
    }

    static func rule(from dto: RoutingRuleDTO) -> RoutingRule {
        let m: RoutingMatch
        switch dto.match {
        case .hostContains(let s): m = .hostContains(s)
        case .hostEquals(let s): m = .hostEquals(s)
        case .urlPrefix(let s): m = .urlPrefix(s)
        }
        let d: RoutingDestination
        switch dto.destination {
        case .space(let s): d = .space(SpaceID(uuidString: s))
        case .littleOpen(let profile): d = .littleOpen(profile: profile.map { ProfileID(uuidString: $0) })
        case .mostRecentSpace(let profile): d = .mostRecentSpace(profile: profile.map { ProfileID(uuidString: $0) })
        }
        return RoutingRule(id: RuleID(uuidString: dto.id), match: m, destination: d, sourceBundleID: normalizedSourceBundleID(dto.sourceBundleID))
    }

    static func defaultDestinationDTO(_ d: DefaultDestination) -> DefaultDestinationDTO {
        switch d {
        case .mostRecentSpace(let profile): return .mostRecentSpace(profile: profile.map { $0.description })
        case .littleOpen(let profile): return .littleOpen(profile: profile.map { $0.description })
        case .space(let id): return .space(id.rawValue.uuidString)
        }
    }

    static func defaultDestination(from dto: DefaultDestinationDTO) -> DefaultDestination {
        switch dto {
        case .mostRecentSpace(let profile): return .mostRecentSpace(profile: profile.map { ProfileID(uuidString: $0) })
        case .littleOpen(let profile): return .littleOpen(profile: profile.map { ProfileID(uuidString: $0) })
        case .space(let s): return .space(SpaceID(uuidString: s))
        }
    }

    /// Structural equality for roundtrip checks (ignores runtime state).
    @MainActor
    public static func structurallyEqual(_ a: BrowserModel, _ b: BrowserModel) -> Bool {
        let ea = JSONEncoder(); ea.outputFormatting = [.sortedKeys]
        let eb = JSONEncoder(); eb.outputFormatting = [.sortedKeys]
        guard let da = try? ea.encode(dto(from: a)), let db = try? eb.encode(dto(from: b)) else { return false }
        return da == db
    }
}
