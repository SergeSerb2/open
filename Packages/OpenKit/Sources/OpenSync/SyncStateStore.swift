import Foundation

/// What this device last pushed or applied for one record.
public struct SyncRecordMirror: Codable, Equatable, Sendable {
    /// HMAC-SHA256 hex of the plaintext (`payloadHashKey`).
    public var payloadHash: String
    /// Milliseconds since 1970.
    public var clientUpdatedAt: Int64
    public var deleted: Bool

    public init(payloadHash: String, clientUpdatedAt: Int64, deleted: Bool) {
        self.payloadHash = payloadHash; self.clientUpdatedAt = clientUpdatedAt; self.deleted = deleted
    }
}

/// Non-secret sync state in `State/sync-state.json`. Secrets live in `SyncCredentialStore`.
public struct SyncPersistedState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var serverURL: String
    public var accountId: String?
    public var email: String?
    public var displayName: String?
    public var deviceId: String
    public var deviceName: String
    public var lastPulledRevision: Int
    public var lastResetRevision: Int
    public var lastSyncAt: Date?
    public var categories: SyncCategorySettings
    public var awaitingInitialChoice: SyncCloudSummary?
    public var pendingExtensionInstalls: [SyncPendingExtension]
    /// `"<collection>|<recordId>"` to the last synced state of that record.
    public var mirror: [String: SyncRecordMirror]
    /// Blob IDs this device knows the server has.
    public var uploadedBlobIDs: [String]
    /// Categories switched on since the last pass; their full history is pulled once.
    public var pendingBackfillCategories: [SyncCategory]

    public init(serverURL: String = SyncDefaults.serverURL, accountId: String? = nil, email: String? = nil,
                displayName: String? = nil, deviceId: String = UUID().uuidString.lowercased(), deviceName: String,
                lastPulledRevision: Int = 0, lastResetRevision: Int = 0, lastSyncAt: Date? = nil,
                categories: SyncCategorySettings = .allEnabled, awaitingInitialChoice: SyncCloudSummary? = nil,
                pendingExtensionInstalls: [SyncPendingExtension] = [], mirror: [String: SyncRecordMirror] = [:],
                uploadedBlobIDs: [String] = [], pendingBackfillCategories: [SyncCategory] = []) {
        self.schemaVersion = 1
        self.serverURL = serverURL; self.accountId = accountId; self.email = email; self.displayName = displayName
        self.deviceId = deviceId; self.deviceName = deviceName
        self.lastPulledRevision = lastPulledRevision; self.lastResetRevision = lastResetRevision
        self.lastSyncAt = lastSyncAt; self.categories = categories
        self.awaitingInitialChoice = awaitingInitialChoice; self.pendingExtensionInstalls = pendingExtensionInstalls
        self.mirror = mirror; self.uploadedBlobIDs = uploadedBlobIDs
        self.pendingBackfillCategories = pendingBackfillCategories
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serverURL, accountId, email, displayName, deviceId, deviceName
        case lastPulledRevision, lastResetRevision, lastSyncAt, categories, awaitingInitialChoice
        case pendingExtensionInstalls, mirror, uploadedBlobIDs, pendingBackfillCategories
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? SyncDefaults.serverURL
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? UUID().uuidString.lowercased()
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Mac"
        lastPulledRevision = try c.decodeIfPresent(Int.self, forKey: .lastPulledRevision) ?? 0
        lastResetRevision = try c.decodeIfPresent(Int.self, forKey: .lastResetRevision) ?? 0
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        categories = try c.decodeIfPresent(SyncCategorySettings.self, forKey: .categories) ?? .allEnabled
        awaitingInitialChoice = try c.decodeIfPresent(SyncCloudSummary.self, forKey: .awaitingInitialChoice)
        pendingExtensionInstalls = try c.decodeIfPresent([SyncPendingExtension].self, forKey: .pendingExtensionInstalls) ?? []
        mirror = try c.decodeIfPresent([String: SyncRecordMirror].self, forKey: .mirror) ?? [:]
        uploadedBlobIDs = try c.decodeIfPresent([String].self, forKey: .uploadedBlobIDs) ?? []
        // Unknown category names from a newer build are dropped.
        let backfill = try c.decodeIfPresent([String].self, forKey: .pendingBackfillCategories) ?? []
        pendingBackfillCategories = backfill.compactMap(SyncCategory.init(rawValue:))
    }

    public static func mirrorKey(_ collection: SyncCollection, _ recordId: String) -> String {
        "\(collection.rawValue)|\(recordId)"
    }

    public static func parseMirrorKey(_ key: String) -> (collection: SyncCollection, recordId: String)? {
        guard let bar = key.firstIndex(of: "|"), let collection = SyncCollection(rawValue: String(key[..<bar])) else { return nil }
        return (collection, String(key[key.index(after: bar)...]))
    }
}

/// Reads and writes `State/sync-state.json`, and keeps local backups before destructive applies.
public struct SyncStateStore: Sendable {
    public static let stateRelativePath = "State/sync-state.json"
    public static let backupsRelativePath = "State/SyncBackups"
    public static let maxBackups = 3

    public let root: URL
    public var fileURL: URL { Self.stateFileURL(in: root) }

    public init(root: URL) { self.root = root }

    public static func stateFileURL(in root: URL) -> URL { root.appendingPathComponent(stateRelativePath) }

    /// One `stat`: cheap enough for every cold launch.
    public static func hasSavedAccount(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: stateFileURL(in: root).path)
    }

    public func load() throws -> SyncPersistedState? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SyncError.storage(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(SyncPersistedState.self, from: data) }
        catch { throw SyncError.storage("The sync state file is damaged.") }
    }

    public func save(_ state: SyncPersistedState) throws {
        try SyncFiles.writeAtomically(Self.encode(state), to: fileURL, permissions: 0o600)
    }

    public static func encode(_ state: SyncPersistedState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do { return try encoder.encode(state) } catch { throw SyncError.storage(error.localizedDescription) }
    }

    public func delete() throws {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch { throw SyncError.storage(error.localizedDescription) }
    }

    /// Writes `files` under `State/SyncBackups/<timestamp>/` and keeps only the newest three backups.
    /// `relativePath` may contain subdirectories but never `..`.
    @discardableResult
    public static func createLocalBackup(root: URL, files: [(relativePath: String, data: Data)]) throws -> URL {
        let backups = root.appendingPathComponent(backupsRelativePath, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var name = formatter.string(from: Date())
        var folder = backups.appendingPathComponent(name, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: folder.path) {
            suffix += 1
            name = formatter.string(from: Date()) + "-\(suffix)"
            folder = backups.appendingPathComponent(name, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw SyncError.storage(error.localizedDescription) }
        for file in files {
            let parts = file.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !file.relativePath.hasPrefix("/") else {
                throw SyncError.storage("Invalid backup path \(file.relativePath).")
            }
            try SyncFiles.writeAtomically(file.data, to: folder.appendingPathComponent(parts.joined(separator: "/")), permissions: 0o600)
        }
        pruneBackups(in: backups)
        return folder
    }

    static func pruneBackups(in backups: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backups.path) else { return }
        // Timestamp names sort chronologically.
        let folders = names.filter { !$0.hasPrefix(".") }.sorted()
        guard folders.count > maxBackups else { return }
        for name in folders.prefix(folders.count - maxBackups) {
            try? FileManager.default.removeItem(at: backups.appendingPathComponent(name, isDirectory: true))
        }
    }
}
