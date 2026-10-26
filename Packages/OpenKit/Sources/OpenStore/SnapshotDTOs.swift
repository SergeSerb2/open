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
}

public struct ProfileSettingsDTO: Codable, Sendable {
    public var autoArchiveAfter: String
    public var littleArcAutoArchiveAfter: String
    public var searchEngineID: String
}

public enum SpaceIconDTO: Codable, Sendable {
    case emoji(String)
    case symbol(String)
}

public struct SpaceDTO: Codable, Sendable {
    public var id: String
    public var title: String
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
    public var createdAt: Double
    public var lastActiveAt: Double
    public var isMuted: Bool
    public var openerID: String?
    public var isUnread: Bool
}

public struct FolderDTO: Codable, Sendable {
    public var id: String
    public var title: String
    public var isExpanded: Bool
    public var customIcon: String?
    public var children: [NodeDTO]
}

public struct SplitDTO: Codable, Sendable {
    public var id: String
    public var orientation: String
    public var fractions: [Double]
    public var panes: [TabDTO]
    public var focusedPaneID: String?
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
}

public enum RoutingMatchDTO: Codable, Sendable {
    case hostContains(String)
    case hostEquals(String)
    case urlPrefix(String)
}

/// Schema version stays 1. The `mostRecentSpace` case was added after v1 shipped;
/// files written before it contain only `space` / `littleArc` and still decode,
/// because Swift's enum decoding only needs the cases present in the payload.
public enum RoutingDestinationDTO: Codable, Sendable {
    case space(String)
    case littleArc
    case mostRecentSpace
}

public enum DefaultDestinationDTO: Codable, Sendable {
    case mostRecentSpace
    case littleArc
    case space(String)
}

public struct RoutingRuleDTO: Codable, Sendable {
    public var id: String
    public var match: RoutingMatchDTO
    public var destination: RoutingDestinationDTO
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
        let profiles = dto.profiles.map { profile(from: $0) }
        let spaces = dto.spaces.map { space(from: $0) }
        let windows = dto.windows.map { window(from: $0) }
        let rules = dto.routingRules.map { rule(from: $0) }
        let model = BrowserModel(profiles: profiles, spaces: spaces, windows: windows, routingRules: rules, defaultDestination: defaultDestination(from: dto.defaultDestination))
        return model
    }

    static func iconDTO(_ icon: SpaceIcon?) -> SpaceIconDTO? {
        switch icon {
        case .emoji(let s): return .emoji(s)
        case .symbol(let s): return .symbol(s)
        case nil: return nil
        }
    }

    static func icon(from dto: SpaceIconDTO?) -> SpaceIcon? {
        switch dto {
        case .emoji(let s): return .emoji(s)
        case .symbol(let s): return .symbol(s)
        case nil: return nil
        }
    }

    static func profileDTO(_ p: Profile) -> ProfileDTO {
        ProfileDTO(id: p.id.rawValue.uuidString, name: p.name, icon: iconDTO(p.icon),
                   favorites: p.favorites.map { .tab(tabDTO($0)) },
                   settings: ProfileSettingsDTO(autoArchiveAfter: p.settings.autoArchiveAfter.rawValue, littleArcAutoArchiveAfter: p.settings.littleArcAutoArchiveAfter.rawValue, searchEngineID: p.settings.searchEngineID),
                   dataDirectoryName: p.dataDirectoryName)
    }

    static func profile(from dto: ProfileDTO) -> Profile {
        Profile(id: ProfileID(uuidString: dto.id), name: dto.name, icon: icon(from: dto.icon),
                favorites: dto.favorites.compactMap { if case .tab(let t) = $0 { return tab(from: t) }; return nil },
                settings: ProfileSettings(autoArchiveAfter: AutoArchiveInterval(rawValue: dto.settings.autoArchiveAfter) ?? .twelveHours, littleArcAutoArchiveAfter: AutoArchiveInterval(rawValue: dto.settings.littleArcAutoArchiveAfter) ?? .twelveHours, searchEngineID: dto.settings.searchEngineID),
                dataDirectoryName: dto.dataDirectoryName)
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
        case .folder(let f): return .folder(FolderDTO(id: f.id.rawValue.uuidString, title: f.title, isExpanded: f.isExpanded, customIcon: f.customIcon, children: f.children.map { nodeDTO($0) }))
        case .split(let s): return .split(SplitDTO(id: s.id.rawValue.uuidString, orientation: s.orientation.rawValue, fractions: s.fractions, panes: s.panes.map { tabDTO($0) }, focusedPaneID: s.focusedPaneID?.rawValue.uuidString))
        }
    }

    static func node(from dto: NodeDTO) -> SidebarNode {
        switch dto {
        case .tab(let t): return .tab(tab(from: t))
        case .folder(let f): return .folder(Folder(id: ItemID(uuidString: f.id), title: f.title, isExpanded: f.isExpanded, customIcon: f.customIcon, children: f.children.map { node(from: $0) }))
        case .split(let s): return .split(Split(id: ItemID(uuidString: s.id), orientation: SplitOrientation(rawValue: s.orientation) ?? .horizontal, fractions: s.fractions, panes: s.panes.map { tab(from: $0) }, focusedPaneID: s.focusedPaneID.map { ItemID(uuidString: $0) }))
        }
    }

    static func tabDTO(_ t: Tab) -> TabDTO {
        TabDTO(id: t.id.rawValue.uuidString, url: t.url.absoluteString, title: t.title, customTitle: t.customTitle,
               pinnedURL: t.pinnedURL?.absoluteString, customIcon: t.customIcon,
               createdAt: t.createdAt.timeIntervalSince1970, lastActiveAt: t.lastActiveAt.timeIntervalSince1970,
               isMuted: t.isMuted, openerID: t.openerID?.rawValue.uuidString, isUnread: t.isUnread)
    }

    static func tab(from dto: TabDTO) -> Tab {
        Tab(id: ItemID(uuidString: dto.id), url: URL(string: dto.url) ?? URL(string: "about:blank")!, title: dto.title,
            customTitle: dto.customTitle, pinnedURL: dto.pinnedURL.flatMap { URL(string: $0) }, customIcon: dto.customIcon,
            createdAt: Date(timeIntervalSince1970: dto.createdAt), lastActiveAt: Date(timeIntervalSince1970: dto.lastActiveAt),
            isMuted: dto.isMuted, openerID: dto.openerID.map { ItemID(uuidString: $0) }, isUnread: dto.isUnread)
    }

    static func windowDTO(_ w: BrowserWindowState) -> WindowDTO {
        var sel: [String: String] = [:]
        for (k, v) in w.selectedNodeBySpace { sel[k.rawValue.uuidString] = v.rawValue.uuidString }
        return WindowDTO(id: w.id.rawValue.uuidString, focusedSpaceID: w.focusedSpaceID.rawValue.uuidString,
                         selectedNodeBySpace: sel, sidebarWidth: w.sidebarWidth, sidebarMode: w.sidebarMode.rawValue,
                         frameX: w.frameX, frameY: w.frameY, frameWidth: w.frameWidth, frameHeight: w.frameHeight,
                         style: w.style.rawValue, stayOnTop: w.stayOnTop)
    }

    static func window(from dto: WindowDTO) -> BrowserWindowState {
        var sel: [SpaceID: ItemID] = [:]
        for (k, v) in dto.selectedNodeBySpace { sel[SpaceID(uuidString: k)] = ItemID(uuidString: v) }
        return BrowserWindowState(id: WindowID(uuidString: dto.id), focusedSpaceID: SpaceID(uuidString: dto.focusedSpaceID),
                                  selectedNodeBySpace: sel, sidebarWidth: dto.sidebarWidth,
                                  sidebarMode: SidebarMode(rawValue: dto.sidebarMode) ?? .anchored,
                                  frameX: dto.frameX, frameY: dto.frameY, frameWidth: dto.frameWidth, frameHeight: dto.frameHeight,
                                  style: WindowStyle(rawValue: dto.style) ?? .standard, stayOnTop: dto.stayOnTop)
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
        case .littleArc: d = .littleArc
        case .mostRecentSpace: d = .mostRecentSpace
        }
        return RoutingRuleDTO(id: r.id.rawValue.uuidString, match: m, destination: d)
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
        case .littleArc: d = .littleArc
        case .mostRecentSpace: d = .mostRecentSpace
        }
        return RoutingRule(id: RuleID(uuidString: dto.id), match: m, destination: d)
    }

    static func defaultDestinationDTO(_ d: DefaultDestination) -> DefaultDestinationDTO {
        switch d {
        case .mostRecentSpace: return .mostRecentSpace
        case .littleArc: return .littleArc
        case .space(let id): return .space(id.rawValue.uuidString)
        }
    }

    static func defaultDestination(from dto: DefaultDestinationDTO) -> DefaultDestination {
        switch dto {
        case .mostRecentSpace: return .mostRecentSpace
        case .littleArc: return .littleArc
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
