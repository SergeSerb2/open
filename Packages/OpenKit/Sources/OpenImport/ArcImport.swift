import Foundation
import OpenModel

public struct ImportReport: Sendable {
    public var totalItems: Int = 0
    public var spaces: Int = 0
    public var pinnedTabs: Int = 0
    public var todayTabs: Int = 0
    public var favorites: Int = 0
    public var folders: Int = 0
    public var splits: Int = 0
    public var routingRules: Int = 0
    public var skippedEasels: Int = 0
    public var skippedNotes: Int = 0
    public var skippedWelcome: Int = 0
    public var skippedUnknown: Int = 0
    public var orphans: Int = 0
    public var skippedRoutingRules: Int = 0
    public var archiveStatus: String = "not imported (no real file exists)"
    public var boostsStatus: String = "not imported (no real file exists)"
    /// imported tabs (pinned + today + favorites items that are tabs) + folders + splits + skipped* + orphans should equal total non-container items.
    public var importedTabNodes: Int = 0

    public var accounted: Int {
        // Every item object is exactly one of: container (structural, not counted),
        // imported node, skipped, or orphan (orphans are also imported, counted separately).
        importedTabNodes + folders + splits + skippedEasels + skippedNotes + skippedWelcome + skippedUnknown
    }
}

public enum ImportError: Error {
    case missingSidebar
    case malformedSidebar
}

/// Read-only importer for Arc's Storable files. Never writes to the Arc folder.
public struct ArcImporter {
    public let arcDirectory: URL

    public init(arcDirectory: URL? = nil) {
        if let arcDirectory { self.arcDirectory = arcDirectory }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.arcDirectory = base.appendingPathComponent("Arc", isDirectory: true)
        }
    }

    private static let epoch2001: TimeInterval = 978307200

    static func date(from2001 value: Double?) -> Date {
        guard let value else { return Date(timeIntervalSince1970: epoch2001) }
        return Date(timeIntervalSince1970: value + epoch2001)
    }

    @MainActor
    public func importModel() throws -> (model: BrowserModel, report: ImportReport) {
        let sidebarURL = arcDirectory.appendingPathComponent("StorableSidebar.json")
        guard let data = try? Data(contentsOf: sidebarURL), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.missingSidebar
        }
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any], containers.count >= 2,
              let holder = containers[1] as? [String: Any],
              let itemsArr = holder["items"] as? [Any],
              let spacesArr = holder["spaces"] as? [Any] else {
            throw ImportError.malformedSidebar
        }

        var report = ImportReport()

        // Parse alternating arrays.
        var itemsByID: [String: [String: Any]] = [:]
        var i = 0
        while i + 1 < itemsArr.count {
            if let id = itemsArr[i] as? String, let obj = itemsArr[i + 1] as? [String: Any] {
                itemsByID[id] = obj
            }
            i += 2
        }
        report.totalItems = itemsByID.count

        var spacesRaw: [(id: String, obj: [String: Any])] = []
        i = 0
        while i + 1 < spacesArr.count {
            if let id = spacesArr[i] as? String, let obj = spacesArr[i + 1] as? [String: Any] {
                spacesRaw.append((id, obj))
            }
            i += 2
        }

        // Profiles: one per distinct Space.profile value. All observed installs use {default:true}.
        var profileIDByKey: [String: ProfileID] = [:]
        var profiles: [Profile] = []
        func profileID(for raw: Any?) -> ProfileID {
            let key: String
            if let dict = raw as? [String: Any], dict["default"] as? Bool == true {
                key = "default"
            } else if let dict = raw as? [String: Any], let s = dict.values.first as? String {
                key = s
            } else { key = "default" }
            if let existing = profileIDByKey[key] { return existing }
            let pid = ProfileID()
            profileIDByKey[key] = pid
            let name = key == "default" ? "Default" : "Profile"
            let dirName = key == "default" ? "Default" : key
            profiles.append(Profile(id: pid, name: name, dataDirectoryName: dirName))
            return pid
        }

        // Pre-create profiles in Space order.
        for (_, obj) in spacesRaw { _ = profileID(for: obj["profile"]) }
        if profiles.isEmpty {
            let pid = ProfileID()
            profileIDByKey["default"] = pid
            profiles.append(Profile(id: pid, name: "Default", dataDirectoryName: "Default"))
        }
        let defaultProfileID = profileIDByKey["default"] ?? profiles[0].id

        // Icon / theme helpers.
        func spaceIcon(from customInfo: [String: Any]?) -> SpaceIcon? {
            guard let info = customInfo, let iconType = info["iconType"] as? [String: Any] else { return nil }
            if let emojiV2 = iconType["emoji_v2"] as? String { return .emoji(emojiV2) }
            if let scalar = iconType["emoji"] as? NSNumber, let s = UnicodeScalar(scalar.intValue) {
                return .emoji(String(Character(s)))
            }
            if let named = iconType["icon"] as? String { return .symbol(named) }
            return nil
        }

        func spaceTheme(from customInfo: [String: Any]?) -> SpaceTheme {
            var theme = SpaceTheme()
            guard let info = customInfo, let wt = info["windowTheme"] else {
                return theme
            }
            // Keep the raw theme JSON.
            if let jsonData = try? JSONSerialization.data(withJSONObject: wt) {
                theme.importedArcThemeJSON = jsonData
            }
            // Map what we can: light/dark background + foreground from semanticColorPalette.
            if let wtDict = wt as? [String: Any],
               let semantic = wtDict["semanticColorPalette"] as? [String: Any],
               let appearance = semantic["appearanceBased"] as? [String: Any] {
                func color(_ set: [String: Any]?, _ key: String) -> RGBAColor? {
                    guard let c = set?[key] as? [String: Any] else { return nil }
                    func d(_ k: String) -> Double { (c[k] as? NSNumber)?.doubleValue ?? 0 }
                    return RGBAColor(red: d("red"), green: d("green"), blue: d("blue"), alpha: (c["alpha"] as? NSNumber)?.doubleValue ?? 1)
                }
                let light = appearance["light"] as? [String: Any]
                let dark = appearance["dark"] as? [String: Any]
                theme.lightBackground = color(light, "backgroundExtra") ?? color(light, "cutoutColor")
                theme.darkBackground = color(dark, "backgroundExtra") ?? color(dark, "cutoutColor")
                theme.lightForeground = color(light, "foregroundPrimary")
                theme.darkForeground = color(dark, "foregroundPrimary")
            }
            return theme
        }

        func tabCustomIcon(from tabData: [String: Any]) -> String? {
            guard let customInfo = tabData["customInfo"] as? [String: Any],
                  let iconType = customInfo["iconType"] as? [String: Any] else { return nil }
            if let emojiV2 = iconType["emoji_v2"] as? String { return emojiV2 }
            if let scalar = iconType["emoji"] as? NSNumber, let s = UnicodeScalar(scalar.intValue) {
                return String(Character(s))
            }
            if let named = iconType["icon"] as? String { return named }
            return nil
        }

        // Build nodes recursively from childrenIds. Memoize by Arc id.
        var nodeByArcID: [String: SidebarNode] = [:]
        var building: Set<String> = []

        func buildNode(arcID: String) -> SidebarNode? {
            if let cached = nodeByArcID[arcID] { return cached }
            guard let item = itemsByID[arcID] else { return nil }
            guard !building.contains(arcID) else { return nil }
            building.insert(arcID)
            defer { building.remove(arcID) }
            guard let dataDict = item["data"] as? [String: Any], let kind = dataDict.keys.first else {
                report.skippedUnknown += 1
                return nil
            }
            let payload = dataDict[kind]
            switch kind {
            case "tab":
                guard let td = payload as? [String: Any] else { report.skippedUnknown += 1; return nil }
                let urlString = td["savedURL"] as? String ?? "about:blank"
                let url = URL(string: urlString) ?? URL(string: "about:blank")!
                let savedTitle = td["savedTitle"] as? String ?? ""
                let itemTitle = item["title"] as? String
                // Custom title only when it differs from the saved title.
                let customTitle = (itemTitle != nil && itemTitle != savedTitle) ? itemTitle : nil
                let tab = Tab(
                    url: url, title: savedTitle, customTitle: customTitle,
                    customIcon: tabCustomIcon(from: td),
                    createdAt: Self.date(from2001: (item["createdAt"] as? NSNumber)?.doubleValue),
                    lastActiveAt: Self.date(from2001: (td["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (item["createdAt"] as? NSNumber)?.doubleValue),
                    isMuted: (td["savedMuteStatus"] as? String) == "mute",
                    isUnread: (item["isUnread"] as? Bool) ?? false
                )
                let node = SidebarNode.tab(tab)
                nodeByArcID[arcID] = node
                return node
            case "list":
                let folder = Folder(title: (item["title"] as? String) ?? "Folder")
                var children: [SidebarNode] = []
                for childID in (item["childrenIds"] as? [String]) ?? [] {
                    if let child = buildNode(arcID: childID) { children.append(child) }
                }
                folder.children = children
                let node = SidebarNode.folder(folder)
                nodeByArcID[arcID] = node
                report.folders += 1
                return node
            case "splitView":
                let sd = payload as? [String: Any] ?? [:]
                let orientation: SplitOrientation = (sd["layoutOrientation"] as? String) == "vertical" ? .vertical : .horizontal
                var fractions: [Double] = []
                if let factors = sd["itemWidthFactors"] as? [Any] {
                    fractions = factors.compactMap { ($0 as? NSNumber)?.doubleValue }
                }
                var panes: [Tab] = []
                for childID in (item["childrenIds"] as? [String]) ?? [] {
                    if let child = buildNode(arcID: childID), let tab = child.tab { panes.append(tab) }
                }
                // Normalize fractions or drop them when they do not match the pane count.
                if fractions.count != panes.count { fractions = [] }
                else if !fractions.isEmpty {
                    let sum = fractions.reduce(0, +)
                    if sum > 0 { fractions = fractions.map { $0 / sum } }
                }
                let split = Split(orientation: orientation, fractions: fractions, panes: panes,
                                  focusedPaneID: (sd["focusItemID"] as? String).flatMap { nodeByArcID[$0]?.id })
                // focusItemID refers to an Arc id; resolve after panes exist.
                if let focusArc = sd["focusItemID"] as? String, let idx = ((item["childrenIds"] as? [String]) ?? []).firstIndex(of: focusArc), idx < panes.count {
                    split.focusedPaneID = panes[idx].id
                }
                let node = SidebarNode.split(split)
                nodeByArcID[arcID] = node
                report.splits += 1
                return node
            case "itemContainer":
                return nil // structural, not a sidebar node
            case "easel":
                report.skippedEasels += 1
                return nil
            case "note":
                report.skippedNotes += 1
                return nil
            case "welcomeToArc":
                report.skippedWelcome += 1
                return nil
            default:
                report.skippedUnknown += 1
                return nil
            }
        }

        func containerIDs(for spaceObj: [String: Any]) -> (pinned: String?, today: String?) {
            // Prefer newContainerIDs.
            if let newIDs = spaceObj["newContainerIDs"] as? [Any], !newIDs.isEmpty {
                var pinned: String?; var today: String?
                var pending: String? // "pinned" | "today"
                for element in newIDs {
                    if let dict = element as? [String: Any] {
                        if dict.keys.contains("pinned") { pending = "pinned" }
                        else if dict.keys.contains("unpinned") { pending = "today" }
                    } else if let id = element as? String {
                        if pending == "pinned" { pinned = id }
                        else if pending == "today" { today = id }
                        pending = nil
                    }
                }
                if pinned != nil || today != nil { return (pinned, today) }
            }
            if let legacy = spaceObj["containerIDs"] as? [Any] {
                var pinned: String?; var today: String?
                var pending: String?
                for element in legacy {
                    if let s = element as? String {
                        if s == "pinned" { pending = "pinned" }
                        else if s == "unpinned" { pending = "today" }
                        else if pending == "pinned" { pinned = s; pending = nil }
                        else if pending == "today" { today = s; pending = nil }
                    }
                }
                return (pinned, today)
            }
            return (nil, nil)
        }

        // Spaces.
        var spaces: [Space] = []
        var reachedArcIDs: Set<String> = []
        for (spaceArcID, obj) in spacesRaw {
            let pid = profileID(for: obj["profile"])
            let info = obj["customInfo"] as? [String: Any]
            let title = (obj["title"] as? String) ?? "Space"
            let space = Space(title: title, icon: spaceIcon(from: info), theme: spaceTheme(from: info), profileID: pid)
            let (pinnedCID, todayCID) = containerIDs(for: obj)
            func nodes(forContainer cid: String?) -> [SidebarNode] {
                guard let cid, let container = itemsByID[cid] else { return [] }
                reachedArcIDs.insert(cid)
                var result: [SidebarNode] = []
                for childID in (container["childrenIds"] as? [String]) ?? [] {
                    reachedArcIDs.insert(childID)
                    if let node = buildNode(arcID: childID) { result.append(node) }
                }
                return result
            }
            space.pinned = nodes(forContainer: pinnedCID)
            space.today = nodes(forContainer: todayCID)
            _ = spaceArcID
            spaces.append(space)
        }
        report.spaces = spaces.count

        // Favorites (topApps) per profile. Observed: single container.
        if let topApps = holder["topAppsContainerIDs"] as? [Any], topApps.count >= 2, let favCID = topApps[1] as? String,
           let container = itemsByID[favCID] {
            reachedArcIDs.insert(favCID)
            var favorites: [Tab] = []
            for childID in (container["childrenIds"] as? [String]) ?? [] {
                reachedArcIDs.insert(childID)
                if let node = buildNode(arcID: childID), let tab = node.tab {
                    if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
                    favorites.append(tab)
                }
            }
            // Attach to the profile named by topAppsContainerIDs[0]; default profile in practice.
            let favProfileID: ProfileID
            if let ref = topApps[0] as? [String: Any], ref["default"] as? Bool == true {
                favProfileID = defaultProfileID
            } else { favProfileID = defaultProfileID }
            if let profile = profiles.first(where: { $0.id == favProfileID }) {
                profile.favorites = favorites
            }
        }

        // Opener references: remap Arc opener ids to Open tabs (best effort by URL+order is skipped;
        // we keep opener unset because Arc ids do not survive. This is deliberate: openerID uses Open IDs.)
        // Count tab nodes by location for the report.
        func countTabs(_ nodes: [SidebarNode]) -> Int {
            nodes.reduce(0) { acc, node in
                switch node {
                case .tab: return acc + 1
                case .folder(let f): return acc + countTabs(f.children)
                case .split(let s): return acc + s.panes.count
                }
            }
        }
        report.pinnedTabs = spaces.reduce(0) { $0 + countTabs($1.pinned) }
        report.todayTabs = spaces.reduce(0) { $0 + countTabs($1.today) }
        report.favorites = profiles.reduce(0) { $0 + $1.favorites.count }
        // Imported tab nodes = every tab object imported anywhere (pinned+today+favorites, splits included once).
        report.importedTabNodes = report.pinnedTabs + report.todayTabs + report.favorites

        // Orphans: item objects never reached and not containers.
        var orphanNodes: [SidebarNode] = []
        for (arcID, item) in itemsByID {
            guard let dataDict = item["data"] as? [String: Any], let kind = dataDict.keys.first else { continue }
            if kind == "itemContainer" { continue }
            if reachedArcIDs.contains(arcID) { continue }
            if nodeByArcID[arcID] != nil { continue } // built as a split pane etc.
            // Was it skipped (easel/note/welcome/unknown)? buildNode already counted those; avoid double count.
            if kind == "tab" || kind == "list" || kind == "splitView" {
                if let node = buildNode(arcID: arcID) {
                    orphanNodes.append(node)
                    report.orphans += 1
                }
            }
        }
        if !orphanNodes.isEmpty, let first = spaces.first {
            for node in orphanNodes {
                if case .tab = node { first.today.append(node) }
                else { first.today.append(node) }
            }
            report.todayTabs += orphanNodes.reduce(0) { acc, node in
                switch node {
                case .tab: return acc + 1
                case .folder(let f): return acc + countTabs(f.children)
                case .split(let s): return acc + s.panes.count
                }
            }
            report.importedTabNodes = report.pinnedTabs + report.todayTabs + report.favorites
        }
        if spaces.isEmpty {
            let pid = profiles.first?.id ?? defaultProfileID
            spaces.append(Space(title: "Space", profileID: pid))
            report.spaces = 1
        }

        // Windows.
        var windows: [BrowserWindowState] = []
        let arcSpaceIDToOpen: [String: SpaceID] = Dictionary(uniqueKeysWithValues: zip(spacesRaw.map { $0.id }, spaces.map { $0.id }))
        if let winData = try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableWindows.json")),
           let winRoot = try? JSONSerialization.jsonObject(with: winData) as? [String: Any],
           let winArr = winRoot["windows"] as? [[String: Any]] {
            let collapsed = Set((winArr.first?["spacesWithCollapsedPinnedSections"] as? [String]) ?? [])
            for space in spaces {
                // Collapsed state is per Arc space id; map back.
                if let arcID = spacesRaw.first(where: { arcSpaceIDToOpen[$0.id] == space.id })?.id, collapsed.contains(arcID) {
                    space.isPinnedCollapsed = true
                }
            }
            for w in winArr {
                let focusedArc = w["focusedSpaceID"] as? String
                let focused = focusedArc.flatMap { arcSpaceIDToOpen[$0] } ?? spaces[0].id
                let style: WindowStyle
                if let styleDict = w["style"] as? [String: Any], styleDict.keys.contains("littleArc") { style = .littleArc } else { style = .standard }
                let window = BrowserWindowState(
                    focusedSpaceID: focused,
                    sidebarWidth: (w["sidebarWidth"] as? NSNumber)?.doubleValue ?? 228,
                    sidebarMode: (w["sidebarMode"] as? String) == "hidden" ? .hidden : .anchored,
                    style: style,
                    stayOnTop: (w["stayOnTop"] as? Bool) ?? false
                )
                windows.append(window)
            }
            _ = winRoot["lastFocusedSpaceID"]
        }
        if windows.isEmpty {
            windows.append(BrowserWindowState(focusedSpaceID: spaces[0].id))
        }

        // Routing.
        var rules: [RoutingRule] = []
        var defaultDestination: DefaultDestination = .mostRecentSpace
        if let routeData = try? Data(contentsOf: arcDirectory.appendingPathComponent("StorableLinkRouting.json")),
           let routeRoot = try? JSONSerialization.jsonObject(with: routeData) as? [String: Any] {
            defaultDestination = parseDestination(routeRoot["defaultDestination"], arcSpaceIDToOpen: arcSpaceIDToOpen) ?? .mostRecentSpace
            for rawRule in (routeRoot["rules"] as? [[String: Any]]) ?? [] {
                guard let components = rawRule["sourceComponents"] as? [[String: Any]] else { report.skippedRoutingRules += 1; continue }
                var importedRule = false
                for component in components {
                    guard let ct = component["componentType"] as? [String: Any],
                          let urlMatch = ct["urlMatch"] as? [String: Any],
                          let pattern = urlMatch["_1"] as? String,
                          let kindDict = urlMatch["_0"] as? [String: Any] else { continue }
                    let match: RoutingMatch
                    if kindDict.keys.contains("contains") { match = .hostContains(pattern) }
                    else if kindDict.keys.contains("equals") || kindDict.keys.contains("exact") { match = .hostEquals(pattern) }
                    else if kindDict.keys.contains("prefix") || kindDict.keys.contains("hasPrefix") { match = .urlPrefix(pattern) }
                    else { continue }
                    guard let dest = parseDestination(rawRule["destination"], arcSpaceIDToOpen: arcSpaceIDToOpen) else { continue }
                    let destination: RoutingDestination
                    switch dest {
                    case .littleArc: destination = .littleArc
                    case .mostRecentSpace: destination = .littleArc // rule to most-recent space: keep as littleArc? No: map below.
                    case .space(let sid): destination = .space(sid)
                    }
                    // Rules whose destination is mostRecent have no fixed Space; store as littleArc is wrong.
                    // Instead skip fixed mapping: represent mostRecent rule destination as the first Space.
                    let finalDestination: RoutingDestination
                    if case .mostRecentSpace = dest {
                        if let first = spaces.first { finalDestination = .space(first.id) } else { continue }
                    } else { finalDestination = destination }
                    rules.append(RoutingRule(match: match, destination: finalDestination))
                    importedRule = true
                }
                if !importedRule { report.skippedRoutingRules += 1 }
            }
        }
        report.routingRules = rules.count

        let model = BrowserModel(profiles: profiles, spaces: spaces, windows: windows, routingRules: rules, defaultDestination: defaultDestination)
        return (model, report)
    }

    private func parseDestination(_ raw: Any?, arcSpaceIDToOpen: [String: SpaceID]) -> DefaultDestination? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let spaceDict = dict["space"] as? [String: Any] {
            if let zero = spaceDict["_0"] as? [String: Any] {
                if zero.keys.contains("mostRecent") { return .mostRecentSpace }
                // {_0: "<spaceArcID>"} form
                for value in zero.values {
                    if let s = value as? String, let openID = arcSpaceIDToOpen[s] { return .space(openID) }
                }
            }
            if let s = spaceDict["_0"] as? String, let openID = arcSpaceIDToOpen[s] { return .space(openID) }
            return .mostRecentSpace
        }
        if dict["littleArc"] != nil { return .littleArc }
        return nil
    }
}
