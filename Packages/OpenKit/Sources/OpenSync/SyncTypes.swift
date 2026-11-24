import Foundation

// MARK: - Constants

public enum SyncDefaults {
    /// Local self-hosted server default (SyncServer/).
    public static let serverURL = "http://127.0.0.1:8787"
    public static let platform = "macos"
    /// Push debounce after the last local change, and the longest a burst of changes waits.
    public static let pushDebounceSeconds = 2.0
    public static let pushMaxCoalesceSeconds = 10.0
    public static let minimumPasswordLength = 8
}

/// Hard bounds from docs/sync-protocol.md §3, plus client response caps.
public enum SyncLimits {
    public static let maxJSONRequestBytes = 8_388_608
    public static let maxRecordCiphertextBytes = 2_097_152
    public static let maxMutationsPerPush = 256
    /// Client batch size (≤ server maximum of 256).
    public static let pushBatchSize = 128
    /// Base64 bytes per push batch, below the 8 MiB request cap with room for JSON framing.
    public static let pushBatchBase64Bytes = 6_291_456
    public static let maxChangesLimit = 500
    public static let defaultChangesLimit = 200
    public static let maxBlobBytes = 20_971_520
    public static let defaultMaxAccountBlobBytes = 262_144_000
    public static let maxDevices = 64
    public static let maxRecordIDLength = 128
    public static let maxDeviceNameLength = 128
    public static let maxDisplayNameLength = 120
    public static let emailLength = 3...254
    /// Largest JSON response the client reads.
    public static let maxJSONResponseBytes = 16_777_216
    /// Largest blob response the client reads.
    public static let maxBlobResponseBytes = 20_971_520
    /// Collection caps the App applies when it builds records (§2).
    public static let maxArchiveRecordsPerProfile = 2_000
    public static let maxHistoryEntriesPerProfile = 5_000

    /// `^[A-Za-z0-9._:-]{1,128}$`
    public static func isValidRecordID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...maxRecordIDLength).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 46 || byte == 95 || byte == 58 || byte == 45
        }
    }
}

// MARK: - Collections and categories

/// Allowed record collections (§2). Raw values are the exact wire strings.
public enum SyncCollection: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceMeta = "workspace.meta"
    case workspaceProfile = "workspace.profile"
    case workspaceSpace = "workspace.space"
    case workspaceToday = "workspace.today"
    case workspaceWindowLayout = "workspace.windowLayout"
    case archiveProfile = "archive.profile"
    case settingsPreferences = "settings.preferences"
    case settingsKeybindings = "settings.keybindings"
    case adblockConfig = "adblock.config"
    case boostItem = "boost.item"
    case easelDocument = "easel.document"
    case noteDocument = "note.document"
    case historyProfile = "history.profile"
    case extensionsProfile = "extensions.profile"
    case credentialsProfile = "credentials.profile"
    case sitePermissionsProfile = "sitePermissions.profile"

    /// Fixed record ID for single-record collections.
    public var singletonRecordID: String? {
        switch self {
        case .workspaceMeta, .settingsPreferences, .settingsKeybindings, .adblockConfig: return "global"
        case .workspaceWindowLayout: return "default"
        default: return nil
        }
    }

    public var category: SyncCategory {
        SyncCategory.allCases.first { $0.collections.contains(self) } ?? .workspace
    }

    /// Records of these collections reference encrypted blobs through `assets`.
    public var carriesAssets: Bool { self == .easelDocument || self == .noteDocument }

    /// `boost.item` record ID: `<ProfileUUID>:<BoostUUID>`.
    public static func boostRecordID(profileID: UUID, boostID: UUID) -> String {
        "\(profileID.uuidString):\(boostID.uuidString)"
    }
}

/// User-facing groups of collections. Each can be switched off in Settings.
public enum SyncCategory: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case workspace
    case todayTabs
    case archive
    case settingsAndShortcuts
    case adBlocking
    case boostsEaselsNotes
    case history
    case extensions
    case credentialsAndPermissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workspace: return "Spaces, Profiles & Pinned Tabs"
        case .todayTabs: return "Today Tabs"
        case .archive: return "Archived Tabs"
        case .settingsAndShortcuts: return "Settings & Shortcuts"
        case .adBlocking: return "Ad Blocking"
        case .boostsEaselsNotes: return "Boosts, Easels & Notes"
        case .history: return "History"
        case .extensions: return "Extensions"
        case .credentialsAndPermissions: return "Passwords, Autofill & Site Permissions"
        }
    }

    public var subtitle: String {
        switch self {
        case .workspace: return "Profiles, Favorites, Spaces, themes, pinned tabs, folders, and link routing rules."
        case .todayTabs: return "The unpinned tabs in each Space."
        case .archive: return "Recently archived tabs and folders for each Profile."
        case .settingsAndShortcuts: return "Portable preferences and custom keyboard shortcuts."
        case .adBlocking: return "Ad blocking, enabled block lists, and allowed sites."
        case .boostsEaselsNotes: return "Boosts, Easels, Notes, and their images."
        case .history: return "Recent browsing history for each Profile."
        case .extensions: return "Chrome Web Store extensions. Other devices ask before they install them."
        case .credentialsAndPermissions: return "Saved passwords, addresses, cards, and site permissions. End-to-end encrypted."
        }
    }

    public var collections: [SyncCollection] {
        switch self {
        case .workspace: return [.workspaceMeta, .workspaceProfile, .workspaceSpace, .workspaceWindowLayout]
        case .todayTabs: return [.workspaceToday]
        case .archive: return [.archiveProfile]
        case .settingsAndShortcuts: return [.settingsPreferences, .settingsKeybindings]
        case .adBlocking: return [.adblockConfig]
        case .boostsEaselsNotes: return [.boostItem, .easelDocument, .noteDocument]
        case .history: return [.historyProfile]
        case .extensions: return [.extensionsProfile]
        case .credentialsAndPermissions: return [.credentialsProfile, .sitePermissionsProfile]
        }
    }
}

/// Which categories sync. Every category is on by default; unknown keys are kept.
public struct SyncCategorySettings: Codable, Equatable, Sendable {
    public var enabled: [String: Bool]

    public init(enabled: [String: Bool] = [:]) { self.enabled = enabled }

    public static let allEnabled = SyncCategorySettings()

    public func isEnabled(_ category: SyncCategory) -> Bool { enabled[category.rawValue] ?? true }

    public mutating func setEnabled(_ isOn: Bool, for category: SyncCategory) { enabled[category.rawValue] = isOn }

    public var enabledCategories: [SyncCategory] { SyncCategory.allCases.filter { isEnabled($0) } }

    public var enabledCollections: Set<SyncCollection> { Set(enabledCategories.flatMap(\.collections)) }

    public func isEnabled(_ collection: SyncCollection) -> Bool { isEnabled(collection.category) }
}

/// What the first sign-in does when the account already holds data.
public enum FirstSyncStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case replaceLocalWithCloud
    case mergeLocalAndCloud
    case replaceCloudWithLocal

    public static let `default`: FirstSyncStrategy = .replaceLocalWithCloud
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .replaceLocalWithCloud: return "Use the cloud data on this Mac"
        case .mergeLocalAndCloud: return "Merge this Mac with the cloud"
        case .replaceCloudWithLocal: return "Replace the cloud with this Mac"
        }
    }

    public var subtitle: String {
        switch self {
        case .replaceLocalWithCloud: return "This Mac's Spaces, tabs and settings are replaced. A backup is kept."
        case .mergeLocalAndCloud: return "Both sets are combined. Items with the same ID use the newest copy."
        case .replaceCloudWithLocal: return "The cloud is wiped and filled with this Mac's data. Other devices follow."
        }
    }
}

// MARK: - Status and UI snapshot

public struct SyncCloudSummary: Codable, Equatable, Sendable {
    public var serverRevision: Int
    public var resetRevision: Int
    public var hasCloudData: Bool
    public var collectionCounts: [String: Int]

    public init(serverRevision: Int = 0, resetRevision: Int = 0, hasCloudData: Bool = false, collectionCounts: [String: Int] = [:]) {
        self.serverRevision = serverRevision; self.resetRevision = resetRevision
        self.hasCloudData = hasCloudData; self.collectionCounts = collectionCounts
    }

    public var totalRecords: Int { collectionCounts.values.reduce(0, +) }
    public func count(_ collection: SyncCollection) -> Int { collectionCounts[collection.rawValue] ?? 0 }
    public var spaceCount: Int { count(.workspaceSpace) }
    public var profileCount: Int { count(.workspaceProfile) }
}

public enum SyncStatus: Equatable, Sendable {
    case signedOut
    case idle
    case syncing(String)
    case awaitingInitialChoice(SyncCloudSummary)
    case error(String)
    case needsReauth(String)

    public var label: String {
        switch self {
        case .signedOut: return "Signed out"
        case .idle: return "Up to date"
        case .syncing(let step): return step
        case .awaitingInitialChoice: return "Choose how to sync this Mac"
        case .error(let message): return message
        case .needsReauth(let message): return message
        }
    }

    /// Stable machine name (automation, logs).
    public var kind: String {
        switch self {
        case .signedOut: return "signedOut"
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .awaitingInitialChoice: return "awaitingInitialChoice"
        case .error: return "error"
        case .needsReauth: return "needsReauth"
        }
    }
}

public struct SyncDeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var lastSeenAt: Date?
    public var isCurrent: Bool
    public var id: String { deviceId }

    public init(deviceId: String, deviceName: String, platform: String, lastSeenAt: Date?, isCurrent: Bool) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.platform = platform
        self.lastSeenAt = lastSeenAt; self.isCurrent = isCurrent
    }
}

/// A synced extension this device does not have yet. The App asks before it installs it.
public struct SyncPendingExtension: Codable, Equatable, Identifiable, Sendable {
    public var profileID: UUID
    public var extensionID: String
    public var name: String
    public var isEnabled: Bool
    public var isPinned: Bool
    public var pinnedIndex: Int
    public var id: String { "\(profileID.uuidString)|\(extensionID)" }

    public init(profileID: UUID, extensionID: String, name: String, isEnabled: Bool = true, isPinned: Bool = false, pinnedIndex: Int = 0) {
        self.profileID = profileID; self.extensionID = extensionID; self.name = name
        self.isEnabled = isEnabled; self.isPinned = isPinned; self.pinnedIndex = pinnedIndex
    }
}

/// Outcome of signing in or recovering an account.
public enum SyncSignInOutcome: Equatable, Sendable {
    case synced
    case needsInitialChoice(SyncCloudSummary)
}

/// Immutable account state for Settings, Onboarding, the sidebar banner, and automation.
public struct SyncAccountSnapshot: Equatable, Sendable {
    public var isSignedIn: Bool
    public var serverURL: String
    public var accountId: String?
    public var email: String?
    public var displayName: String?
    public var deviceId: String?
    public var deviceName: String?
    public var status: SyncStatus
    public var categories: SyncCategorySettings
    public var lastSyncAt: Date?
    public var lastPulledRevision: Int
    public var devices: [SyncDeviceInfo]
    public var pendingExtensionInstalls: [SyncPendingExtension]
    /// Non-fatal notes from the last pass (skipped oversized records, missing blobs, mock keychain).
    public var warnings: [String]
    public var usesFileCredentialStore: Bool
    public var isBusy: Bool
    /// Set while the first sync after sign-in waits for a `FirstSyncStrategy`, even when the
    /// last attempt failed and `status` shows the error.
    public var pendingInitialChoice: SyncCloudSummary?

    public init(isSignedIn: Bool = false, serverURL: String = SyncDefaults.serverURL, accountId: String? = nil,
                email: String? = nil, displayName: String? = nil, deviceId: String? = nil, deviceName: String? = nil,
                status: SyncStatus = .signedOut, categories: SyncCategorySettings = .allEnabled, lastSyncAt: Date? = nil,
                lastPulledRevision: Int = 0, devices: [SyncDeviceInfo] = [], pendingExtensionInstalls: [SyncPendingExtension] = [],
                warnings: [String] = [], usesFileCredentialStore: Bool = false, isBusy: Bool = false,
                pendingInitialChoice: SyncCloudSummary? = nil) {
        self.isSignedIn = isSignedIn; self.serverURL = serverURL; self.accountId = accountId
        self.email = email; self.displayName = displayName; self.deviceId = deviceId; self.deviceName = deviceName
        self.status = status; self.categories = categories; self.lastSyncAt = lastSyncAt
        self.lastPulledRevision = lastPulledRevision; self.devices = devices
        self.pendingExtensionInstalls = pendingExtensionInstalls; self.warnings = warnings
        self.usesFileCredentialStore = usesFileCredentialStore; self.isBusy = isBusy
        self.pendingInitialChoice = pendingInitialChoice
    }

    public static let signedOut = SyncAccountSnapshot()

    public var isAwaitingInitialChoice: Bool {
        if case .awaitingInitialChoice = status { return true }
        return pendingInitialChoice != nil
    }
}

// MARK: - Errors

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case invalidEmail
    case weakPassword(String)
    case invalidServerURL(String)
    case invalidCredentials
    case invalidRecoveryKey
    case emailTaken
    case notSignedIn
    case awaitingInitialChoice
    case sessionExpired(String)
    case server(status: Int, code: String, message: String)
    case transport(String)
    case decoding(String)
    case crypto(String)
    case responseTooLarge(Int)
    case payloadTooLarge(String)
    case keychain(Int32)
    case storage(String)
    case noDataAdapter
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .weakPassword(let reason): return reason
        case .invalidServerURL(let url): return "“\(url)” is not a valid sync server address. Use an http:// or https:// URL."
        case .invalidCredentials: return "The email or password is incorrect."
        case .invalidRecoveryKey: return "The recovery key is not valid for this account."
        case .emailTaken: return "An account with this email already exists."
        case .notSignedIn: return "You are not signed in to Open Sync."
        case .awaitingInitialChoice: return "Choose how to combine this Mac with your cloud data first."
        case .sessionExpired(let message): return message.isEmpty ? "Your session ended. Sign in again." : message
        case .server(_, _, let message): return message
        case .transport(let message): return "Could not reach the sync server: \(message)"
        case .decoding(let message): return "The sync server sent an unexpected response: \(message)"
        case .crypto(let message): return message
        case .responseTooLarge(let limit): return "The sync server response is larger than \(limit) bytes."
        case .payloadTooLarge(let what): return "\(what) is too large to sync."
        case .keychain(let status): return "The Keychain refused the sync credentials (\(status))."
        case .storage(let message): return "Could not save sync state: \(message)"
        case .noDataAdapter: return "Sync is not ready yet."
        case .cancelled: return "Sync was cancelled."
        }
    }

    /// The server's machine code, or a stable client code.
    public var code: String {
        switch self {
        case .invalidEmail: return "INVALID_EMAIL"
        case .weakPassword: return "WEAK_PASSWORD"
        case .invalidServerURL: return "INVALID_SERVER_URL"
        case .invalidCredentials: return "INVALID_CREDENTIALS"
        case .invalidRecoveryKey: return "INVALID_RECOVERY_KEY"
        case .emailTaken: return "EMAIL_TAKEN"
        case .notSignedIn: return "NOT_SIGNED_IN"
        case .awaitingInitialChoice: return "AWAITING_INITIAL_CHOICE"
        case .sessionExpired: return "SESSION_EXPIRED"
        case .server(_, let code, _): return code
        case .transport: return "TRANSPORT"
        case .decoding: return "DECODING"
        case .crypto: return "CRYPTO"
        case .responseTooLarge: return "RESPONSE_TOO_LARGE"
        case .payloadTooLarge: return "PAYLOAD_TOO_LARGE"
        case .keychain: return "KEYCHAIN"
        case .storage: return "STORAGE"
        case .noDataAdapter: return "NO_DATA_ADAPTER"
        case .cancelled: return "CANCELLED"
        }
    }

    /// The session can no longer refresh: the user must sign in again.
    public var requiresReauthentication: Bool {
        if case .sessionExpired = self { return true }
        return false
    }

    static func wrap(_ error: any Error) -> SyncError {
        if let sync = error as? SyncError { return sync }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            return url.code == .cancelled ? .cancelled : .transport(url.localizedDescription)
        }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .transport(error.localizedDescription)
    }
}
