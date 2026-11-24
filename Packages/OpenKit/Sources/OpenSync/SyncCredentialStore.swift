import Foundation
import Security
import Darwin

/// Session secrets: tokens and the raw vault key. Never logged.
public struct SyncCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since 1970; 0 when unknown.
    public var accessTokenExpiresAt: Int64
    public var vaultKeyBase64: String

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Int64 = 0, vaultKeyBase64: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt; self.vaultKeyBase64 = vaultKeyBase64
    }

    private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, accessTokenExpiresAt, vaultKeyBase64 }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        accessTokenExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .accessTokenExpiresAt) ?? 0
        vaultKeyBase64 = try c.decode(String.self, forKey: .vaultKeyBase64)
    }

    public var tokens: SyncTokens {
        SyncTokens(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiresAt: accessTokenExpiresAt)
    }
}

extension SyncCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public protocol SyncCredentialStoring: Sendable {
    func load() throws -> SyncCredentials?
    func save(_ credentials: SyncCredentials) throws
    func clear() throws
    /// True for the `0600` file backend (ad-hoc or isolated runs without a usable Keychain).
    var usesFileBackend: Bool { get }
}

public extension SyncCredentialStoring {
    var usesFileBackend: Bool { false }
}

/// Keychain (`kSecClassGenericPassword`) or `0600` JSON file storage for `SyncCredentials`.
public struct SyncCredentialStore: SyncCredentialStoring {
    public enum Backend: Sendable, Equatable {
        case keychain(service: String, account: String)
        case file(url: URL)
    }

    public static let defaultKeychainService = "app.open.sync"
    public static let defaultKeychainAccount = "sync-credentials"
    public static let fileRelativePath = "State/sync-credentials.json"

    public let backend: Backend

    public init(backend: Backend) { self.backend = backend }

    /// The Keychain normally; the file under `<dataRoot>/State/` when `useFileStore` is true
    /// (mock Keychain, ad-hoc signing, or an isolated data root).
    public init(dataRoot: URL, useFileStore: Bool, keychainService: String = SyncCredentialStore.defaultKeychainService,
                keychainAccount: String = SyncCredentialStore.defaultKeychainAccount) {
        if useFileStore {
            backend = .file(url: dataRoot.appendingPathComponent(Self.fileRelativePath))
        } else {
            backend = .keychain(service: keychainService, account: keychainAccount)
        }
    }

    public var usesFileBackend: Bool {
        if case .file = backend { return true }
        return false
    }

    public func load() throws -> SyncCredentials? {
        guard var data = try loadData() else { return nil }
        defer { SyncCrypto.zeroData(&data) }
        do { return try JSONDecoder().decode(SyncCredentials.self, from: data) }
        catch { throw SyncError.storage("The saved sync credentials are damaged.") }
    }

    public func save(_ credentials: SyncCredentials) throws {
        var data = try JSONEncoder().encode(credentials)
        defer { SyncCrypto.zeroData(&data) }
        switch backend {
        case .keychain(let service, let account): try Self.keychainSave(data, service: service, account: account)
        case .file(let url): try SyncFiles.writeAtomically(data, to: url, permissions: 0o600)
        }
    }

    public func clear() throws {
        switch backend {
        case .keychain(let service, let account):
            let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncError.keychain(status) }
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { throw SyncError.storage(error.localizedDescription) }
            }
        }
    }

    private func loadData() throws -> Data? {
        switch backend {
        case .keychain(let service, let account):
            var query = Self.baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw SyncError.keychain(status) }
            return result as? Data
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do { return try Data(contentsOf: url) }
            catch { throw SyncError.storage(error.localizedDescription) }
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainSave(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SyncError.keychain(status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Open Sync"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SyncError.keychain(addStatus) }
    }
}

/// Crash-safe file writes: temporary file, fsync, rename, directory fsync.
enum SyncFiles {
    static func writeAtomically(_ data: Data, to url: URL, permissions: mode_t = 0o644) throws {
        let parent = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw SyncError.storage(error.localizedDescription) }
        let temporary = parent.appendingPathComponent(".sync-write-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw failure("open") }
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
            unlink(temporary.path)
        }
        // The umask can narrow the mode given to open(2); set it exactly.
        guard fchmod(fd, permissions) == 0 else { throw failure("fchmod") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("write")
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
        guard fsync(fd) == 0 else { throw failure("fsync") }
        Darwin.close(fd); closed = true
        guard rename(temporary.path, url.path) == 0 else { throw failure("rename") }
        let dirFD = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC)
        if dirFD >= 0 { _ = fsync(dirFD); Darwin.close(dirFD) }
    }

    private static func failure(_ operation: String) -> SyncError {
        .storage("\(operation): \(String(cString: strerror(errno)))")
    }
}
