import Foundation
import CoreFoundation
import OpenModel
import OpenStore
import OpenCommands
import OpenBoosts
import OpenEasel
import OpenDocuments

// Plaintext payloads, one per collection (docs/sync-protocol.md §2). Each is sealed as one record.
// Encode them with `SyncPayloadCodec` so equal content always hashes the same.

// MARK: - Codec

public enum SyncPayloadCodec {
    /// Deterministic JSON: sorted keys, unescaped slashes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw SyncError.decoding("Could not encode \(T.self): \(error.localizedDescription)") }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SyncError.decoding("Could not decode \(T.self): \(error.localizedDescription)") }
    }

    /// `schemaVersion` of a payload without decoding all of it; nil when absent.
    public static func schemaVersion(of data: Data) -> Int? {
        struct Probe: Decodable { var schemaVersion: Int? }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion
    }
}

// MARK: - Workspace

/// `workspace.meta` / `global`.
public struct SyncedWorkspaceMetaDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var orderedProfileIDs: [UUID]
    public var orderedSpaceIDs: [UUID]
    public var routingRules: [RoutingRuleDTO]
    public var defaultDestination: DefaultDestinationDTO

    public init(schemaVersion: Int = 1, orderedProfileIDs: [UUID], orderedSpaceIDs: [UUID], routingRules: [RoutingRuleDTO], defaultDestination: DefaultDestinationDTO) {
        self.schemaVersion = schemaVersion; self.orderedProfileIDs = orderedProfileIDs
        self.orderedSpaceIDs = orderedSpaceIDs; self.routingRules = routingRules
        self.defaultDestination = defaultDestination
    }
}

/// `workspace.profile` / `<ProfileUUID>`.
public struct SyncedProfileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profile: ProfileDTO

    public init(schemaVersion: Int = 1, profile: ProfileDTO) {
        self.schemaVersion = schemaVersion; self.profile = profile
    }
}

/// `workspace.space` / `<SpaceUUID>`. Today tabs travel separately in `workspace.today`.
public struct SyncedSpaceDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String?
    public var icon: SpaceIconDTO?
    public var theme: SpaceTheme
    public var profileID: UUID
    public var pinned: [NodeDTO]
    public var isPinnedCollapsed: Bool

    public init(schemaVersion: Int = 1, id: UUID, title: String?, icon: SpaceIconDTO?, theme: SpaceTheme, profileID: UUID, pinned: [NodeDTO], isPinnedCollapsed: Bool) {
        self.schemaVersion = schemaVersion; self.id = id; self.title = title; self.icon = icon
        self.theme = theme; self.profileID = profileID; self.pinned = pinned
        self.isPinnedCollapsed = isPinnedCollapsed
    }
}

/// `workspace.today` / `<SpaceUUID>`.
public struct SyncedTodayTabsDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var spaceID: UUID
    public var today: [NodeDTO]

    public init(schemaVersion: Int = 1, spaceID: UUID, today: [NodeDTO]) {
        self.schemaVersion = schemaVersion; self.spaceID = spaceID; self.today = today
    }
}

/// `workspace.windowLayout` / `default`.
public struct SyncedWindowLayoutDTO: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sidebarWidth: Double
    public var sidebarMode: String
    public var showsToolbar: Bool

    public init(schemaVersion: Int = 1, sidebarWidth: Double, sidebarMode: String, showsToolbar: Bool) {
        self.schemaVersion = schemaVersion; self.sidebarWidth = sidebarWidth
        self.sidebarMode = sidebarMode; self.showsToolbar = showsToolbar
    }
}

// MARK: - Archive

/// Portable copy of `ArchivedTabRecord`.
public struct SyncedArchivedTabRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var spaceID: UUID?
    public var profileID: UUID?
    /// Seconds since 1970.
    public var archivedAt: Double
    public var reason: String
    public var originalLocation: String
    public var kind: String
    public var payloadJSON: String

    public init(id: UUID, url: String, title: String, spaceID: UUID?, profileID: UUID?, archivedAt: Double, reason: String, originalLocation: String, kind: String, payloadJSON: String) {
        self.id = id; self.url = url; self.title = title; self.spaceID = spaceID; self.profileID = profileID
        self.archivedAt = archivedAt; self.reason = reason; self.originalLocation = originalLocation
        self.kind = kind; self.payloadJSON = payloadJSON
    }

    public init(_ record: ArchivedTabRecord) {
        self.init(id: record.id.rawValue, url: record.url.absoluteString, title: record.title,
                  spaceID: record.spaceID?.rawValue, profileID: record.profileID?.rawValue,
                  archivedAt: record.archivedAt.timeIntervalSince1970, reason: record.reason.rawValue,
                  originalLocation: record.originalLocation, kind: record.kind.rawValue, payloadJSON: record.payloadJSON)
    }

    /// The store record, or nil when the URL does not parse.
    public var archivedTabRecord: ArchivedTabRecord? {
        guard let parsed = URL(string: url) else { return nil }
        return ArchivedTabRecord(id: ItemID(rawValue: id), url: parsed, title: title,
                                 spaceID: spaceID.map { SpaceID(rawValue: $0) }, profileID: profileID.map { ProfileID(rawValue: $0) },
                                 archivedAt: Date(timeIntervalSince1970: archivedAt), reason: ArchiveReason(rawValue: reason) ?? .closed,
                                 originalLocation: originalLocation, payloadJSON: payloadJSON,
                                 kind: ArchiveRecordKind(rawValue: kind) ?? .tab)
    }
}

/// `archive.profile` / `<ProfileUUID>`: at most 2,000 most recent records.
public struct SyncedArchiveProfileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var records: [SyncedArchivedTabRecord]

    public init(schemaVersion: Int = 1, profileID: UUID, records: [SyncedArchivedTabRecord]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID
        self.records = Array(records.sorted { $0.archivedAt > $1.archivedAt }.prefix(SyncLimits.maxArchiveRecordsPerProfile))
    }
}

// MARK: - Settings

/// One portable preference value. Tagged so Bool, Int and Double never blur together.
public enum SyncPreferenceValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "int": self = .int(try container.decode(Int.self, forKey: .value))
        case "double": self = .double(try container.decode(Double.self, forKey: .value))
        case "string": self = .string(try container.decode(String.self, forKey: .value))
        case "stringArray": self = .stringArray(try container.decode([String].self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown preference type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value): try container.encode("bool", forKey: .type); try container.encode(value, forKey: .value)
        case .int(let value): try container.encode("int", forKey: .type); try container.encode(value, forKey: .value)
        case .double(let value): try container.encode("double", forKey: .type); try container.encode(value, forKey: .value)
        case .string(let value): try container.encode("string", forKey: .type); try container.encode(value, forKey: .value)
        case .stringArray(let value): try container.encode("stringArray", forKey: .type); try container.encode(value, forKey: .value)
        }
    }

    /// A `UserDefaults` value of a supported type, or nil.
    public init?(userDefaultsValue value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue); return }
            if CFNumberIsFloatType(number as CFNumber) {
                let double = number.doubleValue
                guard double.isFinite else { return nil }
                self = .double(double); return
            }
            self = .int(number.intValue); return
        }
        if let string = value as? String { self = .string(string); return }
        if let array = value as? [String] { self = .stringArray(array); return }
        return nil
    }

    /// The value to store in `UserDefaults`.
    public var userDefaultsValue: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .stringArray(let value): return value
        }
    }
}

/// `settings.preferences` / `global`.
public struct SyncedPreferencesDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var values: [String: SyncPreferenceValue]

    public init(schemaVersion: Int = 1, values: [String: SyncPreferenceValue]) {
        self.schemaVersion = schemaVersion
        self.values = values.filter { Self.isPortable($0.key) }
    }

    /// Exact `open.*` keys that describe the user's choices rather than this Mac's state.
    public static let portablePreferenceKeys: Set<String> = [
        "open.general.previewsEnabled", "open.general.previewsFolders", "open.general.previewsPages",
        "open.general.previewsCalendar", "open.general.previewsRecents", "open.general.previewsGmail",
        "open.general.previewsOnHover", "open.general.previewsDelaySeconds", "open.general.warnBeforeQuitting",
        "open.links.littleOpenHotkeyEnabled", "open.links.openPeekShiftClick", "open.links.openPeekOtherSites",
        "open.links.externalInLittleOpen", "open.links.optionCommandClickLittleOpen",
        "open.shortcuts.defaultPriority", "open.shortcuts.switchToNinthEnabled", "open.shortcuts.includeFavoritesInTabNumbering",
        "open.advanced.tabSleepMode", "open.advanced.playSoundEffects", "open.advanced.hapticOnTabReorder",
        "open.advanced.restoreWindowsOnLaunch", "open.advanced.showFullURLWithToolbar", "open.advanced.enableBoosts",
        "open.advanced.allowWindowDraggingFromWebTop", "open.advanced.enableSharedQuotes",
        "open.advanced.enablePictureInPictureOnLeave", "open.advanced.allowSitesThemeData",
        "open.web.colorScheme",
        "open.sidebar.showSpaceHeaderOnSingleUnnamedSpace",
        "open.translate.enabled", "open.translate.neverTranslateHosts",
        "open.pip.keepOnTop", "open.pip.autoDisabledHosts",
        "open.capture.dragToCaptureEnabled", "open.capture.portraitHidesWatermark",
        "open.capture.portraitColorPercentage", "open.capture.portraitBackground",
        "open.easel.useAlignmentGuides",
        "open.profiles.confirmInterProfileMove",
        "open.liveFolders.githubAutoCreate",
    ]

    /// Key prefixes whose every key is portable (per-site Favorites choices).
    public static let portablePreferencePrefixes: [String] = ["open.favorites."]

    /// Device-local keys that never sync even when a prefix matches.
    public static let excludedPreferencePrefixes: [String] = [
        "open.firstRun.", "open.updates.", "open.debug.", "open.developer.", "open.automation.", "open.import.",
        "open.settings.", "open.library.", "open.onboarding.", "open.appIcon.", "open.sync.",
    ]

    public static func isPortable(_ key: String) -> Bool {
        if excludedPreferencePrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        return portablePreferenceKeys.contains(key) || portablePreferencePrefixes.contains { key.hasPrefix($0) }
    }
}

/// `settings.keybindings` / `global`.
public struct SyncedKeyBindingsDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var store: KeyBindingStore

    public init(schemaVersion: Int = 1, store: KeyBindingStore) {
        self.schemaVersion = schemaVersion; self.store = store
    }
}

// MARK: - Ad blocking

public struct SyncedAdBlockProfile: Codable, Equatable, Sendable {
    public var enabledListIDs: [String]
    public var excludedDomains: [String]

    public init(enabledListIDs: [String], excludedDomains: [String]) {
        self.enabledListIDs = enabledListIDs.sorted(); self.excludedDomains = excludedDomains.sorted()
    }
}

/// `adblock.config` / `global`. `profiles` is keyed by Profile UUID string.
public struct SyncedAdBlockConfigDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var globalEnabled: Bool
    public var profiles: [String: SyncedAdBlockProfile]

    public init(schemaVersion: Int = 1, globalEnabled: Bool, profiles: [String: SyncedAdBlockProfile]) {
        self.schemaVersion = schemaVersion; self.globalEnabled = globalEnabled; self.profiles = profiles
    }
}

// MARK: - Boosts, Easels, Notes

/// `boost.item` / `<ProfileUUID>:<BoostUUID>`.
public struct SyncedBoostDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var boost: Boost

    public init(schemaVersion: Int = 1, profileID: UUID, boost: Boost) {
        self.schemaVersion = schemaVersion; self.profileID = profileID; self.boost = boost
    }

    public var recordID: String { SyncCollection.boostRecordID(profileID: profileID, boostID: boost.id.rawValue) }
}

/// One encrypted asset of an Easel or Note. `sha256` is of the plaintext; `blobId` is the HMAC ID.
public struct SyncedAssetRef: Codable, Equatable, Hashable, Sendable {
    public var filename: String
    public var blobId: String
    public var sha256: String
    public var byteLength: Int

    public init(filename: String, blobId: String, sha256: String, byteLength: Int) {
        self.filename = filename; self.blobId = blobId; self.sha256 = sha256; self.byteLength = byteLength
    }
}

/// `easel.document` / `<EaselUUID>`.
public struct SyncedEaselDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var document: EaselDocument
    public var assets: [SyncedAssetRef]

    public init(schemaVersion: Int = 1, document: EaselDocument, assets: [SyncedAssetRef]) {
        self.schemaVersion = schemaVersion; self.document = document
        self.assets = assets.sorted { $0.filename < $1.filename }
    }
}

/// `note.document` / `<NoteUUID>`.
public struct SyncedNoteDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var document: NoteDocument
    public var assets: [SyncedAssetRef]

    public init(schemaVersion: Int = 1, document: NoteDocument, assets: [SyncedAssetRef]) {
        self.schemaVersion = schemaVersion; self.document = document
        self.assets = assets.sorted { $0.filename < $1.filename }
    }
}

/// The `assets` list of an Easel or Note payload, read without the document.
struct SyncedAssetsProbe: Decodable { var assets: [SyncedAssetRef]? }

// MARK: - History

public struct SyncedHistoryEntry: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// Seconds since 1970.
    public var lastVisitedAt: Double
    public var visitCount: Int
    public var typedCount: Int

    public init(url: String, title: String, lastVisitedAt: Double, visitCount: Int, typedCount: Int) {
        self.url = url; self.title = title; self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount; self.typedCount = typedCount
    }
}

/// `history.profile` / `<ProfileUUID>`: at most 5,000 most recent entries.
public struct SyncedHistoryProfileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var entries: [SyncedHistoryEntry]

    public init(schemaVersion: Int = 1, profileID: UUID, entries: [SyncedHistoryEntry]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID
        self.entries = Array(entries.sorted { ($0.lastVisitedAt, $0.url) > ($1.lastVisitedAt, $1.url) }.prefix(SyncLimits.maxHistoryEntriesPerProfile))
    }
}

// MARK: - Extensions

public struct SyncedExtensionRecord: Codable, Equatable, Sendable {
    public var extensionID: String
    public var name: String
    public var fromWebStore: Bool
    public var isEnabled: Bool
    public var isPinned: Bool
    public var pinnedIndex: Int

    public init(extensionID: String, name: String, fromWebStore: Bool, isEnabled: Bool, isPinned: Bool, pinnedIndex: Int) {
        self.extensionID = extensionID; self.name = name; self.fromWebStore = fromWebStore
        self.isEnabled = isEnabled; self.isPinned = isPinned; self.pinnedIndex = pinnedIndex
    }
}

/// `extensions.profile` / `<ProfileUUID>`.
public struct SyncedExtensionsProfileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var extensions: [SyncedExtensionRecord]

    public init(schemaVersion: Int = 1, profileID: UUID, extensions: [SyncedExtensionRecord]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID
        self.extensions = extensions.sorted { $0.extensionID < $1.extensionID }
    }
}

// MARK: - Credentials (end-to-end encrypted only)

public struct SyncedLoginRecord: Codable, Equatable, Sendable {
    public var originURL: String
    public var actionURL: String?
    public var signonRealm: String
    public var username: String
    public var password: String
    public var usernameElement: String
    public var passwordElement: String
    public var scheme: Int
    public var isBlacklisted: Bool
    public var timesUsed: Int
    /// Seconds since 1970.
    public var dateCreated: Double
    public var dateLastUsed: Double?
    public var datePasswordModified: Double?
    public var note: String?

    public init(originURL: String, actionURL: String? = nil, signonRealm: String, username: String, password: String,
                usernameElement: String = "", passwordElement: String = "", scheme: Int = 0, isBlacklisted: Bool = false,
                timesUsed: Int = 0, dateCreated: Double, dateLastUsed: Double? = nil, datePasswordModified: Double? = nil, note: String? = nil) {
        self.originURL = originURL; self.actionURL = actionURL; self.signonRealm = signonRealm
        self.username = username; self.password = password; self.usernameElement = usernameElement
        self.passwordElement = passwordElement; self.scheme = scheme; self.isBlacklisted = isBlacklisted
        self.timesUsed = timesUsed; self.dateCreated = dateCreated; self.dateLastUsed = dateLastUsed
        self.datePasswordModified = datePasswordModified; self.note = note
    }

    /// Identity of a login across devices.
    public var key: String { "\(signonRealm)\u{1F}\(originURL)\u{1F}\(username)\u{1F}\(usernameElement)\u{1F}\(passwordElement)" }
}

public struct SyncedAddressRecord: Codable, Equatable, Sendable {
    public var guid: String
    /// Autofill field type (decimal string) to value.
    public var fields: [String: String]
    public var useCount: Int
    public var useDate: Double?
    public var dateModified: Double?
    public var languageCode: String?

    public init(guid: String, fields: [String: String], useCount: Int = 0, useDate: Double? = nil, dateModified: Double? = nil, languageCode: String? = nil) {
        self.guid = guid; self.fields = fields; self.useCount = useCount; self.useDate = useDate
        self.dateModified = dateModified; self.languageCode = languageCode
    }
}

public struct SyncedCardRecord: Codable, Equatable, Sendable {
    public var guid: String
    public var nameOnCard: String
    public var expirationMonth: Int
    public var expirationYear: Int
    public var number: String
    public var nickname: String?
    public var useCount: Int
    public var useDate: Double?
    public var dateModified: Double?

    public init(guid: String, nameOnCard: String, expirationMonth: Int, expirationYear: Int, number: String,
                nickname: String? = nil, useCount: Int = 0, useDate: Double? = nil, dateModified: Double? = nil) {
        self.guid = guid; self.nameOnCard = nameOnCard; self.expirationMonth = expirationMonth
        self.expirationYear = expirationYear; self.number = number; self.nickname = nickname
        self.useCount = useCount; self.useDate = useDate; self.dateModified = dateModified
    }
}

/// `credentials.profile` / `<ProfileUUID>`.
public struct SyncedCredentialsProfileDTO: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var passwordSavingEnabled: Bool
    public var creditCardsSavingEnabled: Bool
    public var creditCardReauthenticationEnabled: Bool
    public var addressesSavingEnabled: Bool
    public var logins: [SyncedLoginRecord]
    public var addresses: [SyncedAddressRecord]
    public var cards: [SyncedCardRecord]

    public init(schemaVersion: Int = 1, profileID: UUID, passwordSavingEnabled: Bool, creditCardsSavingEnabled: Bool,
                creditCardReauthenticationEnabled: Bool, addressesSavingEnabled: Bool,
                logins: [SyncedLoginRecord], addresses: [SyncedAddressRecord], cards: [SyncedCardRecord]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID
        self.passwordSavingEnabled = passwordSavingEnabled; self.creditCardsSavingEnabled = creditCardsSavingEnabled
        self.creditCardReauthenticationEnabled = creditCardReauthenticationEnabled
        self.addressesSavingEnabled = addressesSavingEnabled
        self.logins = logins.sorted { $0.key < $1.key }
        self.addresses = addresses.sorted { $0.guid < $1.guid }
        self.cards = cards.sorted { $0.guid < $1.guid }
    }
}

// Protect ordinary logs, debug logs, dump(), and reflection.
extension SyncedLoginRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncedLoginRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension SyncedAddressRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncedAddressRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension SyncedCardRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncedCardRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension SyncedCredentialsProfileDTO: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncedCredentialsProfileDTO(profileID: \(profileID.uuidString), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Site permissions

public struct SyncedPermissionDecision: Codable, Equatable, Sendable {
    /// Origin such as `https://example.com`.
    public var origin: String
    /// Engine permission name such as `notifications`, `geolocation`, `camera`.
    public var permission: String
    /// `allow`, `block`, or `ask`.
    public var decision: String
    public var updatedAt: Double?

    public init(origin: String, permission: String, decision: String, updatedAt: Double? = nil) {
        self.origin = origin; self.permission = permission; self.decision = decision; self.updatedAt = updatedAt
    }
}

public struct SyncedSiteSetting: Codable, Equatable, Sendable {
    public var origin: String
    /// Content setting name such as `javascript`, `popups`, `sound`.
    public var setting: String
    /// Engine value such as `allow`, `block`, or a number as text.
    public var value: String

    public init(origin: String, setting: String, value: String) {
        self.origin = origin; self.setting = setting; self.value = value
    }
}

/// `sitePermissions.profile` / `<ProfileUUID>`.
public struct SyncedSitePermissionsProfileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: UUID
    public var permissions: [SyncedPermissionDecision]
    public var siteSettings: [SyncedSiteSetting]

    public init(schemaVersion: Int = 1, profileID: UUID, permissions: [SyncedPermissionDecision], siteSettings: [SyncedSiteSetting]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID
        self.permissions = permissions.sorted { ($0.origin, $0.permission) < ($1.origin, $1.permission) }
        self.siteSettings = siteSettings.sorted { ($0.origin, $0.setting) < ($1.origin, $1.setting) }
    }
}
