import Foundation
import OpenEasel
import OpenModel
import OpenRouting
import OpenBoosts
import OpenDocuments

public struct ImportReport: Sendable {
    public var totalItems: Int = 0
    public var profiles: Int = 0
    public var profilesGuessed: Int = 0
    public var chromiumDirsFound: Int = 0
    public var chromiumDirsMissing: Int = 0
    public var spaces: Int = 0
    /// Actual source Spaces, excluding the fallback Space needed by an empty model.
    public var sourceSpaces: Int = 0
    public var pinnedTabs: Int = 0
    public var todayTabs: Int = 0
    public var favorites: Int = 0
    public var collapsedFolders: Int = 0
    public var folders: Int = 0
    /// Arc Live Folders brought over with their settings (LF L7).
    public var liveFolders: Int = 0
    /// Profiles whose Favorites empty-state card Arc had dismissed (A3).
    public var favoritesEmptyDismissed: Int = 0
    public var splits: Int = 0
    public var routingRules: Int = 0
    public var skippedEasels: Int = 0
    /// Arc sidebar Easels with an `easelID`: Open Easel rows (content comes from Arc's export).
    /// They are also counted in `importedTabNodes`.
    public var importedEasels: Int = 0
    public var skippedNotes: Int = 0
    public var importedWelcome: Int = 0
    /// Arc Notes (`arcDocument` rows) imported as Note tabs; with text from `StorableARCDocuments`
    /// or as placeholders (their text is on Arc's servers: Help ▸ Export Arc Notes, then import the zip).
    public var importedNotes: Int = 0
    public var notesWithText: Int = 0
    public var notePlaceholders: Int = 0
    public var noteStoreUnreadable: Int = 0
    public var namedSpaceIcons: [String: Int] = [:]
    public var unknownNamedSpaceIcons: Int = 0
    public var untitledSpaces: Int = 0
    public var skippedUnknown: Int = 0
    public var orphans: Int = 0
    public var skippedRoutingRules: Int = 0
    public var routingDestinationFallbacks: Int = 0
    public var containers: Int = 0
    public var archiveStatus: String = "not imported (no real file exists)"
    public var boosts = ArcBoostsReport()
    public var boostsStatus: String { boosts.status }
    public var boostsStoredNew = 0, boostsStoredDuplicates = 0, boostsProtectedEdits = 0
    /// imported tabs (pinned + today + favorites items that are tabs) + folders + splits + skipped* + orphans should equal total non-container items.
    public var importedTabNodes: Int = 0
    // Archive (StorableArchiveItems.json)
    public var archiveFilePresent: Bool = false
    public var archiveTotal: Int = 0
    public var archiveImported: Int = 0
    public var archiveImportedWelcome: Int = 0
    public var archiveSkippedEasels: Int = 0
    public var archiveSkippedNotes: Int = 0
    public var archiveSkippedWelcome: Int = 0
    public var archiveSkippedUnknownKind: Int = 0
    public var archiveSkippedUnknownReason: Int = 0
    public var archiveSkippedUnknownSource: Int = 0
    public var archiveSkippedMalformed: Int = 0
    public var archiveDuplicatesInFile: Int = 0
    public var archiveAlreadyLive: Int = 0
    /// Filled by the CLI after it writes to ArchiveStore: rows that were new vs already stored.
    public var archiveStoredNew: Int = 0
    public var archiveStoredDuplicates: Int = 0
    // Session restoration (StorableSessionRestorationData.json)
    public var sessionFilePresent: Bool = false
    public var sessionTotalPairs: Int = 0
    public var sessionMapped: Int = 0
    public var sessionUnmappedItems: Int = 0
    public var sessionUnmappedWindows: Int = 0
    public var sessionIgnoredIncognito: Int = 0
    public var sessionWindows: Int = 0
    public var sessionAppliedSelections: Int = 0
    public var sessionDistinctChromiumIDs: Int = 0
    public var sessionMalformedPairs: Int = 0
    public var extensions = ArcExtensionReport()
    public var extensionProfilesUnreadable: Int = 0

    public var accounted: Int {
        // Easel rows are tab nodes too: `importedEasels` is a subset of `importedTabNodes`.
        importedTabNodes + folders + splits + skippedEasels + skippedNotes + skippedUnknown
    }
    /// Every sidebar item object: imported + skipped + structural containers.
    public var accountedTotal: Int { accounted + containers }
    public var archiveAccounted: Int {
        archiveImported + archiveSkippedEasels + archiveSkippedNotes + archiveSkippedWelcome
            + archiveSkippedUnknownKind + archiveSkippedUnknownReason + archiveSkippedUnknownSource
            + archiveSkippedMalformed + archiveDuplicatesInFile + archiveAlreadyLive
    }
}

/// Full import result. The CLI stores `archiveRecords` through ArchiveStore;
/// OpenImport itself stays free of OpenStore so the layering in Package.swift holds.
@MainActor
public struct ArcImportResult {
    public var model: BrowserModel
    public var report: ImportReport
    public var archiveRecords: [ArchivedTabRecord]
    /// The `{default:true}` role, independent of its display name or directory.
    public var sourceDefaultProfileID: ProfileID
    /// Original Chromium directory, before destination collision suffixes.
    public var sourceProfileDirectories: [ProfileID: String] = [:]
    /// In-memory metadata only; no payload or extension storage is imported.
    public var extensionsByProfile: [ProfileID: [ArcExtensionRecord]] = [:]
    public var boostsByProfile: [ProfileID: [Boost]] = [:]
    /// Note documents for the imported Note tabs; the App writes each one that does not exist yet.
    public var notes: [NoteDocument] = []
}

public enum ImportError: Error, Equatable {
    case missingSidebar
    case unreadableSidebar
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

    // Arc stores welcome items without a URL. Import as a regular tab to its public welcome page.
    static let welcomeURL = URL(string: "https://arc.net/welcome-to-arc")!
    /// Body of a Note whose text Arc did not keep on this Mac. Arc names are allowed in import text.
    public static let notePlaceholderText = "Arc kept this Note's text on its servers. In Arc, choose Help ▸ Export Arc Notes, then in Open use the action “Import Arc Notes Export…” in the command bar."

    private static let epoch2001: TimeInterval = 978307200

    static func date(from2001 value: Double?) -> Date {
        guard let value else { return Date(timeIntervalSince1970: epoch2001) }
        return Date(timeIntervalSince1970: value + epoch2001)
    }

    /// Stable Open ID for one Arc ID. UUID Arc IDs keep their UUID. Sentinel
    /// string IDs get a deterministic UUID from two FNV-1a hashes of the ID.
    /// Stable IDs make re-import idempotent: the same Arc item always maps
    /// to the same Open item, so ArchiveStore never creates a second row.
    static func deterministicUUID(for arcID: String, namespace: String) -> UUID {
        if let uuid = UUID(uuidString: arcID) { return uuid }
        let seed = "\(namespace):\(arcID)"
        func fnv(_ text: String, offset: UInt64) -> UInt64 {
            var hash = offset
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            return hash
        }
        let h1 = fnv(seed, offset: 14695981039346656037)
        let h2 = fnv(String(seed.reversed()), offset: 1469598103934665603)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((h1 >> UInt64(8 * i)) & 0xff) }
        for i in 0..<8 { bytes[8 + i] = UInt8((h2 >> UInt64(8 * i)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func itemID(forArcID arcID: String) -> ItemID { ItemID(rawValue: deterministicUUID(for: arcID, namespace: "item")) }
    static func spaceID(forArcID arcID: String) -> SpaceID { SpaceID(rawValue: deterministicUUID(for: arcID, namespace: "space")) }

    @MainActor
    public func importModel() throws -> (model: BrowserModel, report: ImportReport) {
        let result = try importAll()
        return (result.model, result.report)
    }

    /// JSONSerialization produces immutable containers. Their contents are private and read-only;
    /// only the model construction that consumes them runs on the main actor.
    public struct ParsedSidebar: @unchecked Sendable {
        let root: [String: Any]
        let files: [String: Any]
        let present: Set<String>
        let boosts: ArcBoostsReadResult
    }
    public func readSidebar() throws -> ParsedSidebar {
        let root = try readSidebarRoot()
        var files: [String: Any] = [:]
        var present = Set<String>()
        for name in ["StorableProfiles.json", "StorableProfileContainers.json", "User Data/Local State",
                     "StorableWindows.json", "StorableLinkRouting.json", "StorableArchiveItems.json", "StorableSessionRestorationData.json"] {
            let file = arcDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { present.insert(name) }
            if let bytes = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: bytes) { files[name] = object }
        }
        return ParsedSidebar(root: root, files: files, present: present, boosts: ArcBoostsReader(arcDirectory: arcDirectory).read())
    }
    private func readSidebarRoot() throws -> [String: Any] {
        let url = arcDirectory.appendingPathComponent("StorableSidebar.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if (error as NSError).code == NSFileReadNoSuchFileError { throw ImportError.missingSidebar }
            throw ImportError.unreadableSidebar
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.malformedSidebar }
        return root
    }
    /// StorableSidebar encodes a dictionary as alternating identity/value pairs.
    /// The global key is {"global":{}}; Little Browser keys carry their own ID.
    /// Pair order changes as Arc opens windows, so it cannot select the sidebar.
    static func globalSidebar(in root: [String: Any]) throws -> [String: Any] {
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              !containers.isEmpty, containers.count.isMultiple(of: 2) else {
            throw ImportError.malformedSidebar
        }
        var global: [String: Any]?
        for index in stride(from: 0, to: containers.count, by: 2) {
            guard let key = containers[index] as? [String: Any], key.count == 1,
                  let payload = key["global"] as? [String: Any], payload.isEmpty else { continue }
            guard global == nil, let holder = containers[index + 1] as? [String: Any] else {
                throw ImportError.malformedSidebar
            }
            global = holder
        }
        guard let global else { throw ImportError.malformedSidebar }
        return global
    }
    /// Shared by model import and the count-only probe; missing/empty refs mean Default.
    static func profileReferenceKey(_ raw:Any?)->String {
        if let value=raw as? String {return value}
        guard let object=raw as? [String:Any] else {return "default"}
        if object["default"] as? Bool == true {return "default"}
        // Confirmed on disk: Space.profile and topAppsContainerIDs use this
        // same ref. machineID identifies the source Mac, not another Profile.
        if let directory = customProfileDirectory(raw) { return directory }
        // Guess: older/unobserved Storable metadata may use a flat string ref.
        return object.keys.sorted().compactMap {object[$0] as? String}.first ?? "default"
    }
    private static func customProfileDirectory(_ raw: Any?) -> String? {
        guard let object = raw as? [String: Any], let custom = object["custom"] as? [String: Any],
              let payload = custom["_0"] as? [String: Any],
              let directory = payload["directoryBasename"] as? String,
              !directory.isEmpty, directory.utf8.count <= 255, directory != ".", directory != "..",
              !directory.contains(where: { "/:\\".contains($0) }),
              !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return directory
    }
    /// UI labels only, read on a utility worker when the wizard prepares its review.
    /// The count-only probe never returns these strings or builds model objects.
    public func spaceMappingLabels() throws -> [String] {
        // Mapping labels need no cache I/O; the caller can be on the UI actor.
        let root=try readSidebarRoot()
        let holder = try Self.globalSidebar(in: root)
        guard let spaces=holder["spaces"] as? [Any] else {throw ImportError.malformedSidebar}
        return stride(from:1,to:spaces.count,by:2).compactMap {index in
            guard let object=spaces[index] as? [String:Any] else {return nil}
            let name=(object["title"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "Untitled Space"
            return name+" → "+name
        }
    }
    struct ArcSourceProfile {let id:ProfileID;let name:String;let dataDirectoryName:String;let sourceDirectory:String}
    struct ArcSourceProfiles {let profiles:[ArcSourceProfile];let spaceOwners:[String:ProfileID];let refOwners:[String:ProfileID];let defaultID:ProfileID}
    func sourceProfiles(spacesRaw:[(id:String,obj:[String:Any])],holder:[String:Any],itemsByID:[String:[String:Any]],directoryNamesToAvoid:Set<String>=[],existingDirectories:[ProfileID:String]=[:],files:[String:Any]?=nil,report:inout ImportReport)->ArcSourceProfiles {
        // StorableProfiles/ProfileContainers metadata shapes remain inferred.
        // Local State info_cache and custom._0.directoryBasename are confirmed.
        struct ProfileMetadata {
            var name: String?
            var directory: String?
        }
        func readJSON(_ path: String) -> Any? {
            if let files { return files[path] }
            guard let data = try? Data(contentsOf: arcDirectory.appendingPathComponent(path)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        func entries(_ raw: Any?) -> [(String, [String: Any])] {
            if let array = raw as? [Any] {
                var result: [(String, [String: Any])] = []
                var index = 0
                while index + 1 < array.count {
                    if let id = array[index] as? String, let object = array[index + 1] as? [String: Any] { result.append((id, object)) }
                    index += 2
                }
                return result
            }
            guard let object = raw as? [String: Any] else { return [] }
            for wrapper in ["profiles", "storableProfiles", "profileContainers", "storableProfileContainers"] {
                if let nested = object[wrapper] { return entries(nested) }
            }
            return object.keys.sorted().compactMap { key in (object[key] as? [String: Any]).map { (key, $0) } }
        }
        func string(_ object: [String: Any], _ keys: [String]) -> String? {
            keys.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        }
        func refKey(_ raw: Any?) -> String {Self.profileReferenceKey(raw)}
        var metadata: [String: ProfileMetadata] = [:]
        var metadataOrder: [String] = []
        var sourceDirectories: Set<String> = []
        func mergeMetadata(_ key: String, name: String?, directory: String?) {
            if metadata[key] == nil { metadataOrder.append(key) }
            let old = metadata[key]
            metadata[key] = ProfileMetadata(name: old?.name ?? name, directory: old?.directory ?? directory)
        }
        for (key, object) in entries(readJSON("StorableProfiles.json")) {
            let id = string(object, ["id"]) ?? key
            let directory = string(object, ["profileDirectoryBasename", "directoryBasename", "directory"])
            mergeMetadata(id, name: string(object, ["name", "displayName", "title"]), directory: directory)
            if let directory { sourceDirectories.insert(directory) }
        }
        var profileRefBySpace: [String: Any] = [:]
        for (key, object) in entries(readJSON("StorableProfileContainers.json")) {
            let id = string(object, ["id"]) ?? key
            let name = string(object, ["name", "displayName", "title"])
            let directory = string(object, ["profileDirectoryBasename", "directoryBasename", "directory"])
            if name != nil || directory != nil { mergeMetadata(id, name: name, directory: directory) }
            if let ref = object["profile"] ?? object["profileID"] {
                profileRefBySpace[string(object, ["spaceID"]) ?? key] = ref
            }
            if let spaceIDs = object["spaceIDs"] as? [String] {
                for spaceID in spaceIDs { profileRefBySpace[spaceID] = object["profile"] ?? object["profileID"] ?? id }
            }
        }
        if let local = readJSON("User Data/Local State") as? [String: Any],
           let info = (local["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for directory in info.keys.sorted() {
                let key = metadataOrder.first { metadata[$0]?.directory == directory } ?? (directory == "Default" ? "default" : directory)
                mergeMetadata(key, name: (info[directory] as? [String: Any])?["name"] as? String, directory: directory)
                sourceDirectories.insert(directory)
            }
        }
        // The observed ref itself proves the source directory, even when
        // Local State is absent from a selected/copy-only import folder.
        let refs = spacesRaw.compactMap { $0.obj["profile"] }
            + ((holder["topAppsContainerIDs"] as? [Any]).map { values in
                stride(from: 0, to: max(0, values.count - 1), by: 2).map { values[$0] }
            } ?? [])
        for ref in refs {
            guard let directory = Self.customProfileDirectory(ref) else { continue }
            let key = metadataOrder.first { metadata[$0]?.directory == directory } ?? directory
            mergeMetadata(key, name: nil, directory: directory)
            sourceDirectories.insert(directory)
        }
        for directory in sourceDirectories {
            var isDirectory: ObjCBool = false
            let safe = !directory.isEmpty && directory != "." && directory != ".." && !directory.contains("/")
            let found = safe && FileManager.default.fileExists(atPath: arcDirectory.appendingPathComponent("User Data").appendingPathComponent(directory).path, isDirectory: &isDirectory) && isDirectory.boolValue
            if found { report.chromiumDirsFound += 1 } else { report.chromiumDirsMissing += 1 }
        }
        let defaultMetadataKey: String? = metadata["default"] != nil ? "default" : nil
        func canonicalKey(_ ref: String) -> String {
            if ref == "default" || ref == defaultMetadataKey { return "default" }
            if metadata[ref] != nil { return ref }
            if let match = metadataOrder.first(where: { metadata[$0]?.directory == ref }) {
                return match == defaultMetadataKey ? "default" : match
            }
            return ref == "Default" ? "default" : ref
        }
        func metadataFor(_ key: String) -> ProfileMetadata? {
            if key == "default" { return defaultMetadataKey.flatMap { metadata[$0] } }
            return metadata[key]
        }
        var profileIDByKey: [String: ProfileID] = [:]
        var profiles: [ArcSourceProfile] = []
        func profileID(for raw: Any?) -> ProfileID {
            let key = canonicalKey(refKey(raw))
            if let existing = profileIDByKey[key] { return existing }
            let pid = ProfileID(rawValue: Self.deterministicUUID(for: key, namespace: "profile"))
            profileIDByKey[key] = pid
            let found = metadataFor(key)
            let fallback = "Profile-" + pid.description.prefix(8).uppercased()
            var directory = key == "default" ? "Default" : (existingDirectories[pid] ?? found?.directory ?? fallback)
            directory = String(directory.unicodeScalars.map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "-" : Character(String(scalar))
            })
            if directory.isEmpty || directory == "." || directory == ".." { directory = fallback }
            if key != "default", directory.caseInsensitiveCompare("Default") == .orderedSame { directory = "Default-named" }
            let stem = directory
            var suffix = 2
            while profiles.contains(where: { $0.dataDirectoryName.caseInsensitiveCompare(directory) == .orderedSame })
                || (key != "default" && directoryNamesToAvoid.contains(directory.lowercased())
                    && existingDirectories[pid]?.caseInsensitiveCompare(directory) != .orderedSame) {
                directory = "\(stem)-\(suffix)"; suffix += 1
            }
            profiles.append(ArcSourceProfile(id:pid,name:found?.name ?? (key == "default" ? "Default":"Profile"),dataDirectoryName:directory,sourceDirectory:found?.directory ?? directory))
            if key != "default", found?.name == nil && found?.directory == nil { report.profilesGuessed += 1 }
            return pid
        }
        // Space order controls display order and collision suffixes. Sidebar links win.
        for (id, object) in spacesRaw { _ = profileID(for: object["profile"] ?? profileRefBySpace[id]) }
        for key in metadataOrder { _ = profileID(for: key) }
        _ = profileID(for: ["default": true])
        if let topApps=holder["topAppsContainerIDs"] as? [Any] {
            for index in stride(from:0,to:max(0,topApps.count-1),by:2) {
                if let id=topApps[index+1] as? String,itemsByID[id] != nil {_ = profileID(for:topApps[index])}
            }
        }
        var resolvedSpaces:[String:ProfileID]=[:]
        for (id,object) in spacesRaw {resolvedSpaces[id]=profileID(for:object["profile"] ?? profileRefBySpace[id])}
        var resolvedRefs:[String:ProfileID]=[:]
        for key in metadataOrder+["default"] {resolvedRefs[key]=profileID(for:key)}
        if let topApps=holder["topAppsContainerIDs"] as? [Any] {
            for index in stride(from:0,to:max(0,topApps.count-1),by:2) {
                if let id=topApps[index+1] as? String,itemsByID[id] != nil {resolvedRefs[refKey(topApps[index])]=profileID(for:topApps[index])}
            }
        }
        return ArcSourceProfiles(profiles:profiles,spaceOwners:resolvedSpaces,refOwners:resolvedRefs,defaultID:profileID(for:["default":true]))
    }
    static func buildsSidebarNode(_ item:[String:Any])->Bool {
        guard let data=item["data"] as? [String:Any],let kind=data.keys.first else {return false}
        switch kind {case "tab","welcomeToArc":return data[kind] is [String:Any];case "list","splitView":return true;default:return false}
    }
    struct ArcArchiveCandidate {let entry:[String:Any];let item:[String:Any];let data:[String:Any];let kind:String;let arcID:String;let spaceID:String;let url:URL;let reason:ArchiveReason}
    static func archiveCandidates(_ flat:[Any],liveArcIDs:Set<String>,report:inout ImportReport)->[ArcArchiveCandidate] {
                report.archiveTotal = flat.count / 2
                if flat.count % 2 != 0 { report.archiveSkippedMalformed += 1 }
                var seenArcIDs: Set<String> = []
                var candidates:[ArcArchiveCandidate]=[]
                var idx = 0
                while idx + 1 < flat.count {
                    defer { idx += 2 }
                    guard let key = flat[idx] as? String, let entry = flat[idx + 1] as? [String: Any] else {
                        report.archiveSkippedMalformed += 1
                        continue
                    }
                    guard let sidebarItem = entry["sidebarItem"] as? [String: Any] else {
                        report.archiveSkippedMalformed += 1
                        continue
                    }
                    let arcID = (sidebarItem["id"] as? String) ?? key
                    if seenArcIDs.contains(arcID) { report.archiveDuplicatesInFile += 1; continue }
                    seenArcIDs.insert(arcID)
                    guard let dataDict = sidebarItem["data"] as? [String: Any], let kind = dataDict.keys.first else {
                        report.archiveSkippedUnknownKind += 1
                        continue
                    }
                    switch kind {
                    case "tab", "welcomeToArc": break
                    case "easel": report.archiveSkippedEasels += 1; continue
                    case "note", "arcDocument": report.archiveSkippedNotes += 1; continue
                    default: report.archiveSkippedUnknownKind += 1; continue
                    }
                    let reason: ArchiveReason
                    switch entry["reason"] as? String {
                    case "manual": reason = .closed
                    case "auto": reason = .autoArchived
                    case "clearButton", "clearTabGroup": reason = .clearedToday
                    default: report.archiveSkippedUnknownReason += 1; continue
                    }
                    guard let source = entry["source"] as? [String: Any],
                          let spaceSource = source["space"] as? [String: Any],
                          let arcSpaceID = spaceSource["_0"] as? String else {
                        report.archiveSkippedUnknownSource += 1
                        continue
                    }
                    if liveArcIDs.contains(arcID) {
                        report.archiveAlreadyLive += 1
                        continue
                    }
                    guard let td = dataDict[kind] as? [String: Any],
                          let urlString = kind == "welcomeToArc" ? Self.welcomeURL.absoluteString : td["savedURL"] as? String,
                          let url = URL(string: urlString) else {
                        report.archiveSkippedMalformed += 1
                        continue
                    }
                    candidates.append(ArcArchiveCandidate(entry:entry,item:sidebarItem,data:td,kind:kind,arcID:arcID,spaceID:arcSpaceID,url:url,reason:reason))
                }
                return candidates
    }
    @MainActor
    public func importAll(sidebar parsed: ParsedSidebar? = nil, directoryNamesToAvoid: Set<String> = [], existingDirectories: [ProfileID: String] = [:], includeArchive: Bool = true) throws -> ArcImportResult {
        let parsed = try parsed ?? readSidebar()
        let root = parsed.root
        let holder = try Self.globalSidebar(in: root)
        guard let itemsArr = holder["items"] as? [Any],
              let spacesArr = holder["spaces"] as? [Any] else {
            throw ImportError.malformedSidebar
        }

        var report = ImportReport()
        report.boosts = parsed.boosts.report

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
        report.containers = itemsByID.values.filter { (($0["data"] as? [String: Any])?.keys.first) == "itemContainer" }.count

        var spacesRaw: [(id: String, obj: [String: Any])] = []
        // A repeated Space ID would give two Spaces one Open ID and trap the
        // `uniqueKeysWithValues` maps below. The first pair wins.
        var seenSpaceIDs: Set<SpaceID> = []
        i = 0
        while i + 1 < spacesArr.count {
            if let id = spacesArr[i] as? String, let obj = spacesArr[i + 1] as? [String: Any],
               seenSpaceIDs.insert(Self.spaceID(forArcID: id)).inserted {
                spacesRaw.append((id, obj))
            }
            i += 2
        }
        report.sourceSpaces = spacesRaw.count

        let sourceProfiles=sourceProfiles(spacesRaw:spacesRaw,holder:holder,itemsByID:itemsByID,directoryNamesToAvoid:directoryNamesToAvoid,existingDirectories:existingDirectories,files:parsed.files,report:&report)
        let profiles=sourceProfiles.profiles.map {Profile(id:$0.id,name:$0.name,dataDirectoryName:$0.dataDirectoryName)}
        let defaultProfileID=sourceProfiles.defaultID
        // Icon / theme helpers.
        func spaceIcon(from customInfo: [String: Any]?) -> SpaceIcon? {
            guard let info = customInfo, let iconType = info["iconType"] as? [String: Any] else { return nil }
            if let emojiV2 = iconType["emoji_v2"] as? String { return .emoji(emojiV2) }
            if let scalar = iconType["emoji"] as? NSNumber, let s = UnicodeScalar(scalar.intValue) {
                return .emoji(String(Character(s)))
            }
            if let named = iconType["icon"] as? String {
                if NamedSpaceIcons.symbols[named] != nil { report.namedSpaceIcons[named, default: 0] += 1 }
                else { report.unknownNamedSpaceIcons += 1 }
                return .named(named)
            }
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

        func tabCustomIcon(from tabData: [String: Any]) -> SpaceIcon? {
            guard let customInfo = tabData["customInfo"] as? [String: Any],
                  let iconType = customInfo["iconType"] as? [String: Any] else { return nil }
            if let emojiV2 = iconType["emoji_v2"] as? String, !emojiV2.isEmpty { return .emoji(emojiV2) }
            if let scalar = iconType["emoji"] as? NSNumber, let s = UnicodeScalar(scalar.intValue) {
                return .emoji(String(Character(s)))
            }
            if let named = iconType["icon"] as? String {
                if NamedSpaceIcons.symbols[named] != nil { report.namedSpaceIcons[named, default: 0] += 1 }
                else { report.unknownNamedSpaceIcons += 1 }
                return .named(named)
            }
            return nil
        }

        // Build nodes recursively from childrenIds. Memoize by Arc id.
        var nodeByArcID: [String: SidebarNode] = [:]
        var building: Set<String> = []
        var skipCounted: Set<String> = []
        let arcNoteStore = ArcNotes.readStore(arcDirectory.appendingPathComponent("StorableARCDocuments", isDirectory: true))
        report.noteStoreUnreadable = arcNoteStore.unreadable
        var importedNotes: [NoteDocument] = []
        var importedNoteIDs: Set<UUID> = []
        func countSkip(_ arcID: String, _ apply: () -> Void) {
            guard !skipCounted.contains(arcID) else { return }
            skipCounted.insert(arcID)
            apply()
        }

        func buildNode(arcID: String) -> SidebarNode? {
            if let cached = nodeByArcID[arcID] { return cached }
            guard let item = itemsByID[arcID] else { return nil }
            guard !building.contains(arcID) else { return nil }
            building.insert(arcID)
            defer { building.remove(arcID) }
            guard let dataDict = item["data"] as? [String: Any], let kind = dataDict.keys.first else {
                countSkip(arcID) { report.skippedUnknown += 1 }
                return nil
            }
            let payload = dataDict[kind]
            switch kind {
            case "tab":
                guard Self.buildsSidebarNode(item),let td = payload as? [String: Any] else { countSkip(arcID) { report.skippedUnknown += 1 }; return nil }
                let urlString = td["savedURL"] as? String ?? "about:blank"
                let url = URL(string: urlString) ?? URL(string: "about:blank")!
                let savedTitle = td["savedTitle"] as? String ?? ""
                let itemTitle = item["title"] as? String
                // Custom title only when it differs from the saved title.
                let customTitle = (itemTitle != nil && itemTitle != savedTitle) ? itemTitle : nil
                let tab = Tab(
                    id: Self.itemID(forArcID: arcID),
                    url: url, title: savedTitle, customTitle: customTitle,
                    iconOverride: tabCustomIcon(from: td),
                    createdAt: Self.date(from2001: (item["createdAt"] as? NSNumber)?.doubleValue),
                    lastActiveAt: Self.date(from2001: (td["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (item["createdAt"] as? NSNumber)?.doubleValue),
                    isMuted: (td["savedMuteStatus"] as? String) == "mute",
                    isUnread: (item["isUnread"] as? Bool) ?? false
                )
                let node = SidebarNode.tab(tab)
                nodeByArcID[arcID] = node
                return node
            case "list":
                let folder = Folder(id: Self.itemID(forArcID: arcID), title: (item["title"] as? String) ?? "Folder")
                var children: [SidebarNode] = []
                for childID in (item["childrenIds"] as? [String]) ?? [] {
                    if let child = buildNode(arcID: childID) { children.append(child) }
                }
                folder.children = children
                if let list = payload as? [String: Any], let auto = list["automaticLiveFolderData"] as? [String: Any],
                   let config = Self.liveFolderConfig(auto) {
                    // An Arc Live Folder (live-data §2.7): its settings, and its PR rows marked as fetched rows.
                    folder.live = config
                    for case .tab(let tab) in children where LiveFolderConfig.repository(of: tab.url) != nil { tab.liveItemURL = tab.url }
                    report.liveFolders += 1
                }
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
                let split = Split(id: Self.itemID(forArcID: arcID), orientation: orientation, fractions: fractions, panes: panes,
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
                // An Arc Easel row becomes an Open Easel row: `open://easel/<stable id>`, the same id
                // the Easel export import (`EaselImporter`) gives its content. Rows without an
                // `easelID` cannot meet their content and stay skipped.
                guard let ed = payload as? [String: Any],
                      let easelID = ed["easelID"] as? String, !easelID.isEmpty, easelID.utf8.count <= 256 else {
                    countSkip(arcID) { report.skippedEasels += 1 }; return nil
                }
                let documentID = EaselImporter.documentID(forArcEaselID: easelID).uuidString.lowercased()
                let rawTitle = (ed["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // `SidebarEasel.customInfo.iconType` is the same custom icon as a tab's (easels-notes.md §3.2).
                let tab = Tab(id: Self.itemID(forArcID: arcID), url: URL(string: "open://easel/\(documentID)")!,
                              title: rawTitle.isEmpty ? "Untitled Easel" : String(rawTitle.prefix(1_000)),
                              iconOverride: tabCustomIcon(from: ed),
                              createdAt: Self.date(from2001: (item["createdAt"] as? NSNumber)?.doubleValue),
                              lastActiveAt: Self.date(from2001: (ed["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (item["createdAt"] as? NSNumber)?.doubleValue),
                              isUnread: item["isUnread"] as? Bool ?? false)
                let node = SidebarNode.tab(tab)
                nodeByArcID[arcID] = node
                report.importedEasels += 1
                return node
            case "arcDocument", "note":
                // Arc's sidebar kind is `arcDocument` (easels-notes.md §4.3); `note` is the old guess, kept.
                let nd = payload as? [String: Any] ?? [:]
                guard let documentID = (nd["arcDocumentID"] as? String) ?? (nd["id"] as? String) ?? Optional(arcID) else { return nil }
                let noteID = ArcNotes.noteID(forArcDocumentID: documentID)
                var note: NoteDocument
                if let stored = arcNoteStore.documents[documentID] {
                    note = stored.note; note.id = noteID
                    report.notesWithText += 1
                } else {
                    note = NoteDocument(id: noteID, title: (item["title"] as? String) ?? "",
                                        text: Self.notePlaceholderText)
                    note.importPlaceholder = true
                    report.notePlaceholders += 1
                }
                let title = note.title.isEmpty ? ((item["title"] as? String) ?? "") : note.title
                note.title = title
                // `SidebarArcDocument.customInfo.iconType` is the same custom icon as a tab's
                // (easels-notes.md §4.3); Open's Note rows take an icon through Change Icon….
                let tab = Tab(id: Self.itemID(forArcID: arcID), url: NoteLink.url(for: noteID),
                              title: title.isEmpty ? "Untitled" : title,
                              iconOverride: tabCustomIcon(from: nd),
                              createdAt: Self.date(from2001: (item["createdAt"] as? NSNumber)?.doubleValue),
                              lastActiveAt: Self.date(from2001: (nd["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (item["createdAt"] as? NSNumber)?.doubleValue),
                              isUnread: item["isUnread"] as? Bool ?? false)
                if !importedNoteIDs.contains(noteID) { importedNoteIDs.insert(noteID); importedNotes.append(note) }
                report.importedNotes += 1
                let node = SidebarNode.tab(tab)
                nodeByArcID[arcID] = node
                return node
            case "welcomeToArc":
                guard Self.buildsSidebarNode(item),let td = payload as? [String: Any] else { countSkip(arcID) { report.skippedUnknown += 1 }; return nil }
                let tab = Tab(id: Self.itemID(forArcID: arcID), url: Self.welcomeURL,
                              title: item["title"] as? String ?? "Getting Started",
                              createdAt: Self.date(from2001: (item["createdAt"] as? NSNumber)?.doubleValue),
                              lastActiveAt: Self.date(from2001: (td["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (item["createdAt"] as? NSNumber)?.doubleValue),
                              isUnread: item["isUnread"] as? Bool ?? false)
                let node = SidebarNode.tab(tab)
                nodeByArcID[arcID] = node
                report.importedWelcome += 1
                return node
            default:
                countSkip(arcID) { report.skippedUnknown += 1 }
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
            let pid = sourceProfiles.spaceOwners[spaceArcID] ?? defaultProfileID
            let info = obj["customInfo"] as? [String: Any]
            let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if title == nil { report.untitledSpaces += 1 }
            let space = Space(id: Self.spaceID(forArcID: spaceArcID), title: title, icon: spaceIcon(from: info), theme: spaceTheme(from: info), profileID: pid)
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
            spaces.append(space)
        }
        report.spaces = spaces.count

        // Every alternating ProfileRef/container pair owns its own Favorites.
        if let topApps = holder["topAppsContainerIDs"] as? [Any] {
            var offset = 0
            while offset + 1 < topApps.count {
                defer { offset += 2 }
                guard let containerID = topApps[offset + 1] as? String, let container = itemsByID[containerID] else { continue }
                let owner = sourceProfiles.refOwners[Self.profileReferenceKey(topApps[offset])] ?? defaultProfileID
                reachedArcIDs.insert(containerID)
                for childID in (container["childrenIds"] as? [String]) ?? [] {
                    reachedArcIDs.insert(childID)
                    if let tab = buildNode(arcID: childID)?.tab {
                        if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
                        profiles.first(where: { $0.id == owner })?.favorites.append(tab)
                    }
                }
            }
        }
        report.profiles = profiles.count

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
            guard let dataDict = item["data"] as? [String: Any], let kind = dataDict.keys.first else {
                if !skipCounted.contains(arcID) { countSkip(arcID) { report.skippedUnknown += 1 } }
                continue
            }
            if kind == "itemContainer" { continue }
            if nodeByArcID[arcID] != nil { continue } // built as a split pane etc.
            if reachedArcIDs.contains(arcID) {
                // Direct child already attempted. If it was skipped, countSkip kept it once.
                continue
            }
            // Unreached item: build it so tab/list/split become orphans and every
            // other kind is counted once as skipped. This keeps the audit exact.
            if let node = buildNode(arcID: arcID) {
                orphanNodes.append(node)
                report.orphans += 1
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
        var windowByArcID: [String: BrowserWindowState] = [:]
        let arcSpaceIDToOpen: [String: SpaceID] = Dictionary(uniqueKeysWithValues: zip(spacesRaw.map { $0.id }, spaces.map { $0.id }))
        if let winRoot = parsed.files["StorableWindows.json"] as? [String: Any],
           let winArr = winRoot["windows"] as? [[String: Any]] {
            let front = winArr.first { window in
                let style = window["style"] as? [String: Any] ?? [:]
                return style["little"] == nil && style["littleArc"] == nil
            }
            let collapsed = Set((front?["spacesWithCollapsedPinnedSections"] as? [String]) ?? [])
            if let front {
                let pairs = front["expandedItems"] as? [Any] ?? []
                var expansions: [String: [String: Any]] = [:]
                for i in stride(from: 0, to: max(0, pairs.count - 1), by: 2) {
                    if let id = pairs[i] as? String, let value = pairs[i + 1] as? [String: Any] { expansions[id] = value }
                }
                for (arcID, node) in nodeByArcID {
                    guard let folder = node.folder else { continue }
                    let value = expansions[arcID] ?? [:]
                    if value["expanded"] != nil { folder.applyExpansion(.expanded) }
                    else {
                        let direct = Set(folder.children.filter { $0.folder == nil }.map(\.id))
                        let ids = (value["peeked"] as? [String: Any])?["_0"] as? [String] ?? []
                        let child = ids.lazy.compactMap { nodeByArcID[$0]?.id }.first { direct.contains($0) }
                        folder.applyExpansion(child.map { .peeked($0) } ?? .collapsed)
                        report.collapsedFolders += 1
                    }
                }
            }
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
                if let styleDict = w["style"] as? [String: Any], (styleDict.keys.contains("littleArc") || styleDict.keys.contains("little")) { style = .littleOpen } else { style = .standard }
                let arcWindowID = w["id"] as? String
                let windowID = arcWindowID.map { WindowID(rawValue: Self.deterministicUUID(for: $0, namespace: "window")) } ?? WindowID()
                let window = BrowserWindowState(
                    id: windowID,
                    focusedSpaceID: focused,
                    sidebarWidth: (w["sidebarWidth"] as? NSNumber)?.doubleValue ?? 228,
                    sidebarMode: (w["sidebarMode"] as? String) == "hidden" ? .hidden : .anchored,
                    style: style,
                    stayOnTop: (w["stayOnTop"] as? Bool) ?? false
                )
                windows.append(window)
                if let arcWindowID { windowByArcID[arcWindowID] = window }
            }
            _ = winRoot["lastFocusedSpaceID"]
        }
        if windows.isEmpty {
            windows.append(BrowserWindowState(focusedSpaceID: spaces[0].id))
        }

        // Routing.
        var rules: [RoutingRule] = []
        var profileReferences = sourceProfiles.refOwners
        for (arcID, object) in spacesRaw {
            if let reference = object["profile"], let owner = sourceProfiles.spaceOwners[arcID] {
                profileReferences[Self.profileReferenceKey(reference)] = owner
            }
        }
        func destination(_ raw: Any?) -> DefaultDestination? {
            let result = parseDestination(raw, arcSpaceIDToOpen: arcSpaceIDToOpen,
                profileReferences: profileReferences, spaces: spaces)
            if result.usedFallback { report.routingDestinationFallbacks += 1 }
            return result.destination
        }
        var defaultDestination: DefaultDestination = .littleOpen(profile: nil)
        if let routeRoot = parsed.files["StorableLinkRouting.json"] as? [String: Any] {
            defaultDestination = destination(routeRoot["defaultDestination"]) ?? .littleOpen(profile: nil)
            for rawRule in (routeRoot["rules"] as? [[String: Any]]) ?? [] {
                guard let components = rawRule["sourceComponents"] as? [[String: Any]] else { report.skippedRoutingRules += 1; continue }
                let target = destination(rawRule["destination"])
                var importedRule = false
                // Guess: components are OR alternatives. Keep one Open rule per
                // component in source order; Arc's comparison logic is unverified.
                for component in components {
                    guard let ct = component["componentType"] as? [String: Any],
                          let urlMatch = ct["urlMatch"] as? [String: Any],
                          let pattern = urlMatch["_1"] as? String,
                          let kindDict = urlMatch["_0"] as? [String: Any] else { continue }
                    let match: RoutingMatch
                    if kindDict.keys.contains("contains") { match = .hostContains(pattern) }
                    else if kindDict.keys.contains("matches") {
                        // Guess: Arc analytics calls this "equals". Treat a bare
                        // host as hostEquals, other text as urlPrefix. Arc's actual
                        // matching semantics remain unverified (s10 audit §2).
                        match = Self.routingMatchForArcMatches(pattern)
                    }
                    else if kindDict.keys.contains("equals") || kindDict.keys.contains("exact") { match = .hostEquals(pattern) }
                    else if kindDict.keys.contains("prefix") || kindDict.keys.contains("hasPrefix") { match = .urlPrefix(pattern) }
                    else { continue }
                    guard let dest = target else { continue }
                    let destination: RoutingDestination
                    switch dest {
                    case .littleOpen(let profile): destination = .littleOpen(profile: profile)
                    case .mostRecentSpace(let profile): destination = .mostRecentSpace(profile: profile)
                    case .space(let sid): destination = .space(sid)
                    }
                    rules.append(RoutingRule(match: match, destination: destination))
                    importedRule = true
                }
                if !importedRule { report.skippedRoutingRules += 1 }
            }
        }
        report.routingRules = rules.count

        // MARK: Archive (StorableArchiveItems.json)
        // Lenient parse. Unknown keys, reasons, sources, and non-tab kinds are
        // skipped and counted. The record payload holds the full tab fields so
        // BrowserModel.restoreArchivedTab can rebuild the tab. The parent
        // folder is lost in Arc's file, so the restore target is the source
        // Space's Today section (today:<spaceID>).
        var archiveRecords: [ArchivedTabRecord] = []
        if includeArchive {
            let archive = readArchive(sidebar: parsed, spaceProfiles: Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.profileID) }),
                                      defaultSpaceID: spaces[0].id, report: report)
            archiveRecords = archive.records; report = archive.report
        }

        // MARK: Session restoration (StorableSessionRestorationData.json)
        // Used: which sidebar items were open in which window. Per window and
        // Space, the item with the newest lastActiveAt becomes the selection.
        // Ignored: the Chromium SessionID values (only counted as distinct),
        // profile/context detail beyond the incognito check, pair order
        // beyond the tie-break, windows absent from StorableWindows.json,
        // and items absent from the sidebar (archived or deleted items).
        if parsed.present.contains("StorableSessionRestorationData.json") {
            report.sessionFilePresent = true
            if let sessionRoot = parsed.files["StorableSessionRestorationData.json"] as? [String: Any],
               let mapping = sessionRoot["mapping"] as? [String: Any],
               let flat = mapping["keysToValues"] as? [Any] {
                report.sessionTotalPairs = flat.count / 2
                if flat.count % 2 != 0 { report.sessionMalformedPairs += 1 }
                // Open item -> owning Space. Favorites resolve per window below.
                var spaceByItem: [ItemID: SpaceID] = [:]
                var tabByItem: [ItemID: Tab] = [:]
                func collect(_ nodes: [SidebarNode], space: SpaceID) {
                    for node in nodes {
                        switch node {
                        case .tab(let tab): spaceByItem[tab.id] = space; tabByItem[tab.id] = tab
                        case .folder(let folder): collect(folder.children, space: space)
                        case .split(let split): for pane in split.panes { spaceByItem[pane.id] = space; tabByItem[pane.id] = pane }
                        }
                    }
                }
                for space in spaces {
                    collect(space.pinned, space: space.id)
                    collect(space.today, space: space.id)
                }
                var favoriteProfiles: [ItemID: ProfileID] = [:]
                for profile in profiles {
                    for tab in profile.favorites { favoriteProfiles[tab.id] = profile.id; tabByItem[tab.id] = tab }
                }
                let arcItemToOpen: [String: ItemID] = Dictionary(uniqueKeysWithValues: nodeByArcID.map { ($0.key, $0.value.id) })
                var windowIDsSeen: Set<String> = []
                var chromiumIDs: Set<Int> = []
                var perWindow: [String: [(item: ItemID, order: Int)]] = [:]
                var order = 0
                var idx = 0
                while idx + 1 < flat.count {
                    defer { idx += 2; order += 1 }
                    guard let key = flat[idx] as? [String: Any] else { report.sessionMalformedPairs += 1; continue }
                    if let number = flat[idx + 1] as? NSNumber { chromiumIDs.insert(number.intValue) }
                    guard let browser = key["browser"] as? [String: Any],
                          let arcWindowID = browser["windowID"] as? String,
                          let arcItemID = key["itemId"] as? String else {
                        report.sessionMalformedPairs += 1
                        continue
                    }
                    windowIDsSeen.insert(arcWindowID)
                    if let context = browser["contextID"] as? [String: Any],
                       let contextType = context["contextType"] as? [String: Any],
                       contextType.keys.contains("incognito") {
                        report.sessionIgnoredIncognito += 1
                        continue
                    }
                    guard windowByArcID[arcWindowID] != nil else { report.sessionUnmappedWindows += 1; continue }
                    guard let openItem = arcItemToOpen[arcItemID] else { report.sessionUnmappedItems += 1; continue }
                    report.sessionMapped += 1
                    perWindow[arcWindowID, default: []].append((openItem, order))
                }
                report.sessionWindows = windowIDsSeen.count
                report.sessionDistinctChromiumIDs = chromiumIDs.count
                for (arcWindowID, entries) in perWindow {
                    guard let window = windowByArcID[arcWindowID] else { continue }
                    var bestBySpace: [SpaceID: (item: ItemID, order: Int, active: Date)] = [:]
                    for entry in entries {
                        let targetSpace: SpaceID
                        if let owner = favoriteProfiles[entry.item] {
                            // An inactive Profile's session may outlive a switch
                            // to a different Profile. Never select its Favorite
                            // in a Space that uses another engine context.
                            // Guess: if this window no longer focuses that
                            // Profile, use its first Space; the session mapping
                            // has no Space ID for a Favorite.
                            guard let owned = spaces.first(where: { $0.id == window.focusedSpaceID && $0.profileID == owner })
                                ?? spaces.first(where: { $0.profileID == owner }) else { continue }
                            targetSpace = owned.id
                        }
                        else if let owned = spaceByItem[entry.item] { targetSpace = owned }
                        else { continue }
                        let active = tabByItem[entry.item]?.lastActiveAt ?? .distantPast
                        if let current = bestBySpace[targetSpace] {
                            if active > current.active || (active == current.active && entry.order > current.order) {
                                bestBySpace[targetSpace] = (entry.item, entry.order, active)
                            }
                        } else {
                            bestBySpace[targetSpace] = (entry.item, entry.order, active)
                        }
                    }
                    for (spaceID, best) in bestBySpace {
                        window.selectedNodeBySpace[spaceID] = best.item
                        report.sessionAppliedSelections += 1
                    }
                }
            }
        }

        let sourceProfileDirectories = Dictionary(uniqueKeysWithValues: sourceProfiles.profiles.map { ($0.id, $0.sourceDirectory) })
        var extensionsByProfile: [ProfileID: [ArcExtensionRecord]] = [:]
        for (profileID, directory) in sourceProfileDirectories.sorted(by: { $0.key.description < $1.key.description }) {
            do {
                guard !directory.isEmpty, directory.utf8.count <= 255, directory != ".", directory != "..",
                      !directory.contains("/"), !directory.contains("\\"),
                      !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ImportError.malformedSidebar }
                let root = arcDirectory.appendingPathComponent("User Data").resolvingSymlinksInPath()
                guard root.path.hasPrefix(arcDirectory.resolvingSymlinksInPath().path + "/") else { throw ImportError.malformedSidebar }
                let profile = root.appendingPathComponent(directory)
                guard profile.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw ImportError.malformedSidebar }
                let result = try ArcExtensionsReader(profileDirectory: profile).read()
                report.extensions.totalRecords += result.report.totalRecords
                report.extensions.internalRecords += result.report.internalRecords
                report.extensions.reinstallCandidates += result.report.reinstallCandidates
                report.extensions.missingManifest += result.report.missingManifest
                extensionsByProfile[profileID] = result.records
            } catch { report.extensionProfilesUnreadable += 1 }
        }
        let model = BrowserModel(profiles: profiles, spaces: spaces, windows: windows, routingRules: rules, defaultDestination: defaultDestination)
        // Favorites empty-state card (A3): Arc's dismissal per Profile key, or the older global flag.
        if let prefs = try? ArcPreferences.read(arcDirectory: arcDirectory), prefs.found {
            let all = prefs.bools[ArcPreferenceMapping.favoritesEmptyDismissedKey] == true
            let ids = Set(prefs.favoritesEmptyDismissedProfiles.map { ProfileID(rawValue: Self.profileID(forArcProfileKey: $0)) })
            for profile in model.profiles where all || ids.contains(profile.id) {
                profile.favoritesEmptyStateDismissed = true; report.favoritesEmptyDismissed += 1
            }
        }
        return ArcImportResult(model: model, report: report, archiveRecords: archiveRecords,
            sourceDefaultProfileID: defaultProfileID,
            sourceProfileDirectories: sourceProfileDirectories,
            extensionsByProfile: extensionsByProfile,
            boostsByProfile: parsed.boosts.boosts.isEmpty ? [:] : [defaultProfileID: parsed.boosts.boosts],
            notes: importedNotes)
    }

    public struct ArchiveReadResult: Sendable {
        public var records: [ArchivedTabRecord]
        public var report: ImportReport
    }

    /// Immutable parsed input and value records make Archive preparation safe
    /// on a utility worker. No live model, file I/O or JSON encoding is needed
    /// on the App's main actor for these records.
    public func readArchive(sidebar parsed: ParsedSidebar, spaceProfiles: [SpaceID: ProfileID],
                            defaultSpaceID: SpaceID, report initial: ImportReport) -> ArchiveReadResult {
        var report = initial
        var archiveRecords: [ArchivedTabRecord] = []
        let holder = try? Self.globalSidebar(in: parsed.root)
        let items = holder?["items"] as? [Any] ?? []
        var liveArcIDs = Set<String>()
        for index in stride(from: 0, to: max(0, items.count - 1), by: 2) {
            if let id = items[index] as? String, let object = items[index+1] as? [String: Any], Self.buildsSidebarNode(object) { liveArcIDs.insert(id) }
        }
        func tabCustomIcon(from tabData: [String: Any]) -> SpaceIcon? {
            guard let customInfo = tabData["customInfo"] as? [String: Any], let icon = customInfo["iconType"] as? [String: Any] else { return nil }
            if let emoji = icon["emoji_v2"] as? String, !emoji.isEmpty { return .emoji(emoji) }
            if let number = icon["emoji"] as? NSNumber, let scalar = UnicodeScalar(number.intValue) { return .emoji(String(scalar)) }
            if let named = icon["icon"] as? String {
                if NamedSpaceIcons.symbols[named] != nil { report.namedSpaceIcons[named, default: 0] += 1 }
                else { report.unknownNamedSpaceIcons += 1 }
                return .named(named)
            }
            return nil
        }
        if parsed.present.contains("StorableArchiveItems.json") {
            report.archiveFilePresent = true
            if let archiveRoot = parsed.files["StorableArchiveItems.json"] as? [String: Any],
               let flat = archiveRoot["items"] as? [Any] {
                for candidate in Self.archiveCandidates(flat,liveArcIDs:liveArcIDs,report:&report) {
                    let entry=candidate.entry,sidebarItem=candidate.item,td=candidate.data,kind=candidate.kind,arcID=candidate.arcID,arcSpaceID=candidate.spaceID,url=candidate.url,reason=candidate.reason
                    let candidateSpaceID = Self.spaceID(forArcID: arcSpaceID)
                    let openSpaceID = spaceProfiles[candidateSpaceID] != nil ? candidateSpaceID : defaultSpaceID
                    let savedTitle = td["savedTitle"] as? String ?? (kind == "welcomeToArc" ? (sidebarItem["title"] as? String ?? "Getting Started") : "")
                    let itemTitle = sidebarItem["title"] as? String
                    let customTitle = (itemTitle != nil && itemTitle != savedTitle) ? itemTitle : nil
                    let id = Self.itemID(forArcID: arcID)
                    let createdAt = Self.date(from2001: (sidebarItem["createdAt"] as? NSNumber)?.doubleValue)
                    let lastActiveAt = Self.date(from2001: (td["timeLastActiveAt"] as? NSNumber)?.doubleValue ?? (sidebarItem["createdAt"] as? NSNumber)?.doubleValue)
                    let iconOverride = tabCustomIcon(from: td)
                    let archivedAt = Self.date(from2001: (entry["archivedAt"] as? NSNumber)?.doubleValue ?? (sidebarItem["createdAt"] as? NSNumber)?.doubleValue)
                    var payload: [String: Any] = [
                        "id": id.rawValue.uuidString,
                        "url": url.absoluteString,
                        "title": savedTitle,
                        "createdAt": createdAt.timeIntervalSince1970,
                        "lastActiveAt": lastActiveAt.timeIntervalSince1970,
                        "isMuted": (td["savedMuteStatus"] as? String) == "mute",
                        "isUnread": (sidebarItem["isUnread"] as? Bool) ?? false,
                    ]
                    if let customTitle { payload["customTitle"] = customTitle }
                    if let icon = iconOverride, let encoded = try? JSONEncoder().encode(icon),
                       let value = try? JSONSerialization.jsonObject(with: encoded) {
                        payload["iconOverride"] = value
                    }
                    let payloadData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let location = "today:\(openSpaceID.rawValue.uuidString)"
                    if kind == "welcomeToArc" { report.archiveImportedWelcome += 1 }
                    archiveRecords.append(ArchivedTabRecord(
                        id: id, url: url, title: customTitle ?? savedTitle,
                        spaceID: openSpaceID, profileID: spaceProfiles[openSpaceID],
                        archivedAt: archivedAt, reason: reason,
                        originalLocation: location, payloadJSON: payloadJSON
                    ))
                }
                archiveRecords.sort { $0.archivedAt < $1.archivedAt }
                report.archiveImported = archiveRecords.count
                report.archiveStatus = "imported \(archiveRecords.count) of \(report.archiveTotal)"
            } else {
                report.archiveStatus = "present but unreadable"
            }
        }

        return ArchiveReadResult(records: archiveRecords, report: report)
    }

    private static func routingMatchForArcMatches(_ pattern: String) -> RoutingMatch {
        HostNormalizer.isBareHostPattern(pattern) ? .hostEquals(pattern) : .urlPrefix(pattern)
    }

    @MainActor
    private func parseDestination(_ raw: Any?, arcSpaceIDToOpen: [String: SpaceID],
                                  profileReferences: [String: ProfileID], spaces: [Space])
        -> (destination: DefaultDestination?, usedFallback: Bool) {
        guard let dict = raw as? [String: Any] else { return (nil, true) }
        let little = dict["littleArc"] ?? dict["little"]
        guard let payload = (dict["space"] ?? little) as? [String: Any] else { return (nil, true) }
        let isLittle = dict["space"] == nil
        func recent(_ profile: ProfileID? = nil) -> DefaultDestination {
            isLittle ? .littleOpen(profile: profile) : .mostRecentSpace(profile: profile)
        }
        func specificSpace(_ arcID: String) -> DefaultDestination? {
            guard let id = arcSpaceIDToOpen[arcID] else { return nil }
            if isLittle {
                guard let space = spaces.first(where: { $0.id == id }) else { return nil }
                return .littleOpen(profile: space.profileID)
            }
            return .space(id)
        }
        // Keep the older direct-string Space representation readable too.
        if let id = payload["_0"] as? String {
            return specificSpace(id).map { ($0, false) } ?? (recent(), true)
        }
        guard let context = payload["_0"] as? [String: Any], context.count == 1 else {
            return (recent(), true)
        }
        if context["mostRecent"] != nil { return (recent(), false) }
        if let space = context["space"] as? [String: Any],
           let id = space["_0"] as? String, let destination = specificSpace(id) {
            return (destination, false)
        }
        if let profile = context["profile"] as? [String: Any], let reference = profile["_0"],
           let id = profileReferences[Self.profileReferenceKey(reference)] {
            return (recent(id), false)
        }
        // Preserve the previous unknown-context fallback, and count the loss.
        return (recent(), true)
    }
}
