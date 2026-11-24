import Foundation
import OpenModel
import OpenStore

/// Maps the live `BrowserModel` to the `workspace.*` records and back.
/// The App's `SyncDataAdapter` calls these, so every device builds identical payloads.
@MainActor
public enum SyncWorkspaceCodec {
    /// Collections this codec reads and writes.
    public static let collections: Set<SyncCollection> = [.workspaceMeta, .workspaceProfile, .workspaceSpace, .workspaceToday, .workspaceWindowLayout]

    // MARK: Model to payloads

    public static func metaPayload(from model: BrowserModel) -> SyncedWorkspaceMetaDTO {
        SyncedWorkspaceMetaDTO(orderedProfileIDs: model.profiles.map { $0.id.rawValue },
                               orderedSpaceIDs: model.spaces.map { $0.id.rawValue },
                               routingRules: model.routingRules.map { SnapshotMapper.ruleDTO($0) },
                               defaultDestination: SnapshotMapper.defaultDestinationDTO(model.defaultDestination))
    }

    public static func profilePayload(_ profile: Profile) -> SyncedProfileDTO {
        SyncedProfileDTO(profile: SnapshotMapper.profileDTO(profile))
    }

    public static func spacePayload(_ space: Space) -> SyncedSpaceDTO {
        SyncedSpaceDTO(id: space.id.rawValue, title: space.title, icon: SnapshotMapper.iconDTO(space.icon), theme: space.theme,
                       profileID: space.profileID.rawValue, pinned: space.pinned.map { SnapshotMapper.nodeDTO($0) },
                       isPinnedCollapsed: space.isPinnedCollapsed)
    }

    public static func todayPayload(_ space: Space) -> SyncedTodayTabsDTO {
        SyncedTodayTabsDTO(spaceID: space.id.rawValue, today: space.today.map { SnapshotMapper.nodeDTO($0) })
    }

    public static func windowLayoutPayload(_ window: BrowserWindowState) -> SyncedWindowLayoutDTO {
        SyncedWindowLayoutDTO(sidebarWidth: window.sidebarWidth.rounded(), sidebarMode: window.sidebarMode.rawValue,
                              showsToolbar: window.showsToolbar)
    }

    /// Applies the portable layout to a standard window. Little Open windows are left alone.
    public static func applyWindowLayout(_ layout: SyncedWindowLayoutDTO, to window: BrowserWindowState) {
        guard window.style == .standard else { return }
        if layout.sidebarWidth.isFinite {
            window.sidebarWidth = max(BrowserWindowState.minimumSidebarWidth, min(layout.sidebarWidth, 600))
        }
        if let mode = SidebarMode(rawValue: layout.sidebarMode) { window.sidebarMode = mode }
        window.showsToolbar = layout.showsToolbar
    }

    /// The `workspace.*` records for the enabled categories, and the collections they fully cover.
    /// `layoutWindow` is the window whose layout syncs (normally the frontmost standard window).
    public static func localRecords(from model: BrowserModel, categories: SyncCategorySettings,
                                    layoutWindow: BrowserWindowState?) throws -> (records: [SyncLocalRecord], complete: Set<SyncCollection>) {
        var records: [SyncLocalRecord] = []
        var complete = Set<SyncCollection>()
        if categories.isEnabled(.workspace) {
            records.append(try SyncLocalRecord(collection: .workspaceMeta, recordId: "global", value: metaPayload(from: model)))
            for profile in model.profiles {
                records.append(try SyncLocalRecord(collection: .workspaceProfile, recordId: profile.id.rawValue.uuidString, value: profilePayload(profile)))
            }
            for space in model.spaces {
                records.append(try SyncLocalRecord(collection: .workspaceSpace, recordId: space.id.rawValue.uuidString, value: spacePayload(space)))
            }
            complete.formUnion([.workspaceMeta, .workspaceProfile, .workspaceSpace])
            if let window = layoutWindow ?? model.windows.first(where: { $0.style == .standard }) {
                records.append(try SyncLocalRecord(collection: .workspaceWindowLayout, recordId: "default", value: windowLayoutPayload(window)))
            }
        }
        if categories.isEnabled(.todayTabs) {
            for space in model.spaces {
                records.append(try SyncLocalRecord(collection: .workspaceToday, recordId: space.id.rawValue.uuidString, value: todayPayload(space)))
            }
            complete.insert(.workspaceToday)
        }
        return (records, complete)
    }

    // MARK: Payloads to model

    public struct ResolvedWorkspace {
        public var profiles: [Profile]
        public var spaces: [Space]
        public var routingRules: [RoutingRule]
        public var defaultDestination: DefaultDestination
        /// Profiles that did not exist on this Mac (their data directories may need creating).
        public var newProfileIDs: Set<ProfileID>
    }

    /// The workspace to install for `bundle`, or nil when it holds no workspace change or would
    /// leave this Mac with no Profile or no Space. Existing tabs are reused by ID, so open pages
    /// keep their web content.
    /// - Parameter reservedDirectoryNames: Directory names a new Profile must not take, such as
    ///   the folders that already exist under `Profiles/`. Compared without case (APFS).
    public static func resolveWorkspace(current model: BrowserModel, bundle: SyncRemoteBundle, mode: SyncApplyMode,
                                        categories: SyncCategorySettings,
                                        reservedDirectoryNames: Set<String> = []) throws -> ResolvedWorkspace? {
        let includeWorkspace = categories.isEnabled(.workspace)
        let includeToday = categories.isEnabled(.todayTabs)
        let replace = mode == .replaceLocal
        // A full cloud replacement with no Today records means the cloud has no Today tabs.
        let clearsToday = replace && includeToday && bundle.isFullSnapshot
        var relevant: Set<SyncCollection> = []
        if includeWorkspace { relevant.formUnion([.workspaceMeta, .workspaceProfile, .workspaceSpace]) }
        if includeToday { relevant.insert(.workspaceToday) }
        guard clearsToday || bundle.records.contains(where: { relevant.contains($0.collection) }) else { return nil }

        // Current local state as payloads, keyed by ID.
        var profiles: [UUID: ProfileDTO] = [:]
        for profile in model.profiles where profiles[profile.id.rawValue] == nil { profiles[profile.id.rawValue] = SnapshotMapper.profileDTO(profile) }
        var spaces: [UUID: SyncedSpaceDTO] = [:]
        for space in model.spaces where spaces[space.id.rawValue] == nil { spaces[space.id.rawValue] = spacePayload(space) }
        var today: [UUID: [NodeDTO]] = [:]
        var meta = metaPayload(from: model)
        let localMeta = meta

        let remoteHasStructure = bundle.records.contains { !$0.deleted && ($0.collection == .workspaceProfile || $0.collection == .workspaceSpace) }
        if replace, includeWorkspace, remoteHasStructure { profiles = [:]; spaces = [:] }

        if includeWorkspace {
            for record in bundle.records(in: .workspaceProfile) {
                guard let id = UUID(uuidString: record.recordId) else { continue }
                if record.deleted { profiles[id] = nil; continue }
                guard var dto = try record.decode(SyncedProfileDTO.self)?.profile else { continue }
                dto.id = id.uuidString
                profiles[id] = dto
            }
            for record in bundle.records(in: .workspaceSpace) {
                guard let id = UUID(uuidString: record.recordId) else { continue }
                if record.deleted { spaces[id] = nil; continue }
                guard var dto = try record.decode(SyncedSpaceDTO.self) else { continue }
                dto.id = id
                spaces[id] = dto
            }
            if let record = bundle.records(in: .workspaceMeta).last(where: { !$0.deleted }), let remote = try record.decode(SyncedWorkspaceMetaDTO.self) {
                if bundle.isFullSnapshot && mode == .mergeOrDelta {
                    // First-sign-in merge: cloud order first, then this Mac's own items and rules.
                    let remoteRuleIDs = Set(remote.routingRules.map(\.id))
                    meta = SyncedWorkspaceMetaDTO(
                        orderedProfileIDs: remote.orderedProfileIDs + localMeta.orderedProfileIDs.filter { !remote.orderedProfileIDs.contains($0) },
                        orderedSpaceIDs: remote.orderedSpaceIDs + localMeta.orderedSpaceIDs.filter { !remote.orderedSpaceIDs.contains($0) },
                        routingRules: remote.routingRules + localMeta.routingRules.filter { !remoteRuleIDs.contains($0.id) },
                        defaultDestination: remote.defaultDestination)
                } else {
                    meta = remote
                }
            }
        }
        if includeToday {
            for record in bundle.records(in: .workspaceToday) {
                guard let id = UUID(uuidString: record.recordId) else { continue }
                if record.deleted { today[id] = []; continue }
                guard let dto = try record.decode(SyncedTodayTabsDTO.self) else { continue }
                today[id] = dto.today
            }
        }

        // Order: the meta order first, then anything it does not list, in local order.
        let profileOrder = ordered(meta.orderedProfileIDs + localMeta.orderedProfileIDs + profiles.keys.sorted { $0.uuidString < $1.uuidString },
                                   keeping: Set(profiles.keys))
        let spaceOrder = ordered(meta.orderedSpaceIDs + localMeta.orderedSpaceIDs + spaces.keys.sorted { $0.uuidString < $1.uuidString },
                                 keeping: Set(spaces.keys))
        guard !profileOrder.isEmpty, !spaceOrder.isEmpty else { return nil }

        var builder = NodeBuilder(model: model)
        // Profiles: a Profile this Mac has keeps its data directory; a new one gets a free name.
        // Every local Profile's directory and every reserved name is taken, also a Profile the
        // cloud deletes: its folder stays on disk until cleanup.
        var usedDirectories = Set(reservedDirectoryNames.map { $0.lowercased() })
        for profile in model.profiles { usedDirectories.insert(profile.dataDirectoryName.lowercased()) }
        // `Default` is the engine's global context, not a removable folder: a cloud Profile may
        // take it when no local Profile that stays keeps it.
        let keepsDefault = profileOrder.contains { model.profile(id: ProfileID(rawValue: $0))?.dataDirectoryName.lowercased() == "default" }
        if !keepsDefault { usedDirectories.remove("default") }
        var newProfileIDs = Set<ProfileID>()
        var builtProfiles: [Profile] = []
        for id in profileOrder {
            guard let dto = profiles[id] else { continue }
            let profileID = ProfileID(rawValue: id)
            let directory: String
            if let local = model.profile(id: profileID) {
                directory = local.dataDirectoryName
            } else {
                directory = freeDirectoryName(preferred: dto.dataDirectoryName, used: &usedDirectories)
                newProfileIDs.insert(profileID)
            }
            var metadata = dto
            metadata.favorites = []
            let shell = SnapshotMapper.profile(from: metadata)
            let profile = Profile(id: profileID, name: shell.name, icon: shell.icon,
                                  favorites: dto.favorites.compactMap { node -> Tab? in
                                      if case .tab(let tab) = node { return builder.tab(tab) }
                                      return nil
                                  },
                                  settings: shell.settings, dataDirectoryName: directory)
            profile.favoritesEmptyStateDismissed = dto.favoritesEmptyStateDismissed ?? false
            builtProfiles.append(profile)
        }
        let fallbackProfile = builtProfiles.first(where: { $0.dataDirectoryName == "Default" })?.id ?? builtProfiles[0].id
        let validProfiles = Set(builtProfiles.map { $0.id })

        // Spaces: pinned first, so a tab moved from Today to Pinned elsewhere lands in Pinned.
        var builtSpaces: [Space] = []
        var pinnedBySpace: [UUID: [SidebarNode]] = [:]
        for id in spaceOrder {
            guard let dto = spaces[id] else { continue }
            pinnedBySpace[id] = dto.pinned.compactMap { builder.node($0) }
        }
        for id in spaceOrder {
            guard let dto = spaces[id] else { continue }
            let spaceID = SpaceID(rawValue: id)
            let todayNodes: [SidebarNode]
            if includeToday, let remoteToday = today[id] {
                todayNodes = remoteToday.compactMap { builder.node($0) }
            } else if clearsToday {
                todayNodes = []
            } else {
                // Keep this Mac's Today tabs when Today does not sync or did not change.
                todayNodes = (model.space(id: spaceID)?.today ?? []).compactMap { builder.adopt($0) }
            }
            var profileID = ProfileID(rawValue: dto.profileID)
            if !validProfiles.contains(profileID) { profileID = fallbackProfile }
            builtSpaces.append(Space(id: spaceID, title: dto.title, icon: SnapshotMapper.icon(from: dto.icon), theme: dto.theme,
                                     profileID: profileID, pinned: pinnedBySpace[id] ?? [], today: todayNodes,
                                     isPinnedCollapsed: dto.isPinnedCollapsed))
        }

        return ResolvedWorkspace(profiles: builtProfiles, spaces: builtSpaces,
                                 routingRules: meta.routingRules.map { SnapshotMapper.rule(from: $0) },
                                 defaultDestination: SnapshotMapper.defaultDestination(from: meta.defaultDestination),
                                 newProfileIDs: newProfileIDs)
    }

    /// Resolves and installs the workspace through `BrowserModel.applySyncedWorkspace`.
    /// Returns the resolved workspace, or nil when nothing changed. Also applies the window layout.
    @discardableResult
    public static func apply(_ bundle: SyncRemoteBundle, mode: SyncApplyMode, categories: SyncCategorySettings,
                             to model: BrowserModel, reservedDirectoryNames: Set<String> = []) throws -> ResolvedWorkspace? {
        if categories.isEnabled(.workspace), let record = bundle.records(in: .workspaceWindowLayout).last(where: { !$0.deleted }),
           let layout = try record.decode(SyncedWindowLayoutDTO.self) {
            for window in model.windows where window.style == .standard { applyWindowLayout(layout, to: window) }
        }
        guard let resolved = try resolveWorkspace(current: model, bundle: bundle, mode: mode, categories: categories,
                                                  reservedDirectoryNames: reservedDirectoryNames) else { return nil }
        model.applySyncedWorkspace(profiles: resolved.profiles, spaces: resolved.spaces,
                                   routingRules: resolved.routingRules, defaultDestination: resolved.defaultDestination)
        return resolved
    }

    // MARK: Helpers

    private static func ordered(_ ids: [UUID], keeping valid: Set<UUID>) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { valid.contains($0) && seen.insert($0).inserted }
    }

    /// A directory name for a new Profile: only ASCII letters, digits, space, `-` and `_`,
    /// 1...64 characters, not taken by `used` (lowercased, because APFS ignores case).
    private static func freeDirectoryName(preferred: String, used: inout Set<String>) -> String {
        let allowed = preferred.unicodeScalars.filter { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_")
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: allowed.prefix(64))
        var base = String(view).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Profile" }
        if base.lowercased() == "default" { base = "Default" }
        if used.insert(base.lowercased()).inserted { return base }
        var index = 1
        while !used.insert("profile \(index)").inserted { index += 1 }
        return "Profile \(index)"
    }

    /// Builds sidebar nodes from payloads with each item ID used once, reusing this Mac's `Tab`
    /// objects so open pages keep their web content.
    /// Remote input is bounded: folders nest at most `maxDepth` levels and one resolve builds at
    /// most `maxNodes` remote items. Items past a bound are skipped.
    @MainActor
    private struct NodeBuilder {
        static let maxDepth = 32
        static let maxNodes = 10_000

        let model: BrowserModel
        var used = Set<UUID>()
        private var builtCount = 0

        init(model: BrowserModel) { self.model = model }

        /// Counts one remote item; false when the bound is reached.
        private mutating func reserveNode() -> Bool {
            guard builtCount < Self.maxNodes else { return false }
            builtCount += 1
            return true
        }

        mutating func tab(_ dto: TabDTO) -> Tab? {
            guard let uuid = UUID(uuidString: dto.id), !used.contains(uuid), reserveNode() else { return nil }
            used.insert(uuid)
            let fresh = SnapshotMapper.tab(from: dto)
            guard let existing = model.tab(id: ItemID(rawValue: uuid)) else { return fresh }
            existing.customTitle = fresh.customTitle
            existing.pinnedURL = fresh.pinnedURL
            existing.customIcon = fresh.customIcon
            existing.iconOverride = fresh.iconOverride
            existing.isMuted = fresh.isMuted
            existing.liveItemURL = fresh.liveItemURL
            existing.liveItem = fresh.liveItem
            if !existing.live.hasWebContent {
                existing.url = fresh.url
                existing.title = fresh.title
            }
            return existing
        }

        mutating func node(_ dto: NodeDTO, depth: Int = 0) -> SidebarNode? {
            switch dto {
            case .tab(let tab):
                return self.tab(tab).map { .tab($0) }
            case .folder(let folder):
                guard depth < Self.maxDepth, let uuid = UUID(uuidString: folder.id), !used.contains(uuid), reserveNode() else { return nil }
                used.insert(uuid)
                let children = folder.children.compactMap { node($0, depth: depth + 1) }
                let peeked = folder.peekedChildID.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) }
                let built = Folder(id: ItemID(rawValue: uuid), title: folder.title, isExpanded: folder.isExpanded,
                                   customIcon: folder.customIcon, iconOverride: SnapshotMapper.icon(from: folder.iconOverride),
                                   children: children, peekedChildID: peeked.flatMap { id in children.contains { $0.id == id } ? id : nil })
                built.live = folder.live
                if let existing = model.node(id: ItemID(rawValue: uuid))?.folder { built.liveSSOURL = existing.liveSSOURL }
                return .folder(built)
            case .split(let split):
                guard let uuid = UUID(uuidString: split.id), !used.contains(uuid), reserveNode() else { return nil }
                let panes = split.panes.compactMap { tab($0) }
                guard !panes.isEmpty else { return nil }
                used.insert(uuid)
                // Remote fractions must be finite and positive, one per pane; else equal panes.
                let fractionsValid = split.fractions.count == panes.count && split.fractions.allSatisfy { $0.isFinite && $0 > 0 }
                let total = fractionsValid ? split.fractions.reduce(0, +) : 0
                let fractions = fractionsValid && total.isFinite && total > 0 ? split.fractions.map { $0 / total } : []
                let focused = split.focusedPaneID.flatMap(UUID.init(uuidString:)).map { ItemID(rawValue: $0) }
                return .split(Split(id: ItemID(rawValue: uuid), orientation: SplitOrientation(rawValue: split.orientation) ?? .horizontal,
                                    fractions: fractions, panes: panes,
                                    focusedPaneID: focused.flatMap { id in panes.contains { $0.id == id } ? id : nil },
                                    customTitle: split.customTitle, iconOverride: SnapshotMapper.icon(from: split.iconOverride)))
            }
        }

        /// A local node kept as is, unless one of its IDs is already in use.
        mutating func adopt(_ node: SidebarNode) -> SidebarNode? {
            let ids = Self.ids(in: node)
            guard ids.allSatisfy({ !used.contains($0) }) else { return nil }
            used.formUnion(ids)
            return node
        }

        static func ids(in node: SidebarNode) -> [UUID] {
            switch node {
            case .tab(let tab): return [tab.id.rawValue]
            case .folder(let folder): return [folder.id.rawValue] + folder.children.flatMap { ids(in: $0) }
            case .split(let split): return [split.id.rawValue] + split.panes.map { $0.id.rawValue }
            }
        }
    }
}
