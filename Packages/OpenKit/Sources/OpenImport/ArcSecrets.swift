import Foundation
import SQLite3
import CommonCrypto

public struct ImportedLoginRecord {
    public var originURLString: String
    public var actionURLString: String?
    public var username: String
    public var passwordBytes: [UInt8]
    public var signonRealm: String
    public var dateCreated: Date
    public var isBlacklisted: Bool
    public var timesUsed: Int
    public var usernameElement: String = ""
    public var passwordElement: String = ""
    public var scheme: Int = 0
    public var dateLastUsed: Date? = nil
    public var datePasswordModified: Date? = nil
    public var noteBytes: [UInt8] = []
    public mutating func zeroSecrets() { zeroSecretBytes(&passwordBytes); zeroSecretBytes(&noteBytes) }
}

public struct ImportedCookieRecord {
    public var hostKey: String
    public var name: String
    public var valueBytes: [UInt8]
    public var path: String
    public var expiresUTC: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var creation: Date = Date(timeIntervalSince1970: 0)
    public var lastAccess: Date? = nil
    public var lastUpdate: Date? = nil
    public var sameSite: Int = -1
    public var priority: Int = 1
    public var sourceScheme: Int = 0
    public var sourcePort: Int = -1
    public var topFrameSiteKey: String? = nil
    public var hasCrossSiteAncestor: Bool = false
    public mutating func zeroSecrets() { zeroSecretBytes(&valueBytes) }
}

public struct ImportedAddressRecord {
    public var guid: String
    public var fields: [Int: String]
    public var useCount: Int
    public var useDate: Date
    public var verificationStatuses: [Int: Int] = [:]
    public var dateModified: Date? = nil
    public var languageCode: String? = nil
    // Address fields are text metadata, not decryptable byte buffers.
    public mutating func zeroSecrets() { fields.removeAll(); verificationStatuses.removeAll() }
}

public struct ImportedCardRecord {
    public var guid: String
    public var nameOnCard: String
    public var expirationMonth: Int
    public var expirationYear: Int
    public var numberBytes: [UInt8]
    public var nickname: String? = nil
    public var useCount: Int = 0
    public var useDate: Date? = nil
    public mutating func zeroSecrets() { zeroSecretBytes(&numberBytes) }
}

// Protect ordinary logs, debug logs, dump(), and reflection, including PII fields.
// Explicit property access is reserved for the eventual engine writer.
extension ImportedLoginRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ImportedLoginRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension ImportedCookieRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ImportedCookieRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension ImportedAddressRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ImportedAddressRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
extension ImportedCardRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ImportedCardRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ArcSecretsReadReport: Sendable {
    public var loginRows = 0
    public var loginsDecryptOK = 0
    public var loginsDecryptFailed = 0
    public var loginsBlacklisted = 0
    public var loginsFederated = 0
    public var loginsInvalidTime = 0
    public var cookieRows = 0
    public var cookiesDecryptOK = 0
    public var cookiesDecryptFailed = 0
    public var cookiesExpired = 0
    public var cookiesInvalidTime = 0
    public var legacyNoHashPrefix = 0
    public var addressRows = 0
    public var addressesInvalidTime = 0
    public var cardRows = 0
    public var cardsDecryptOK = 0
    public var cardsDecryptFailed = 0
    public var keywordRows = 0
    public var autofillRows = 0
    public var autofillInvalidTime = 0
    public var badPrefix = 0
}

public enum ArcSecretsImportError: Error {
    case missingFiles, invalidAccess, invalidFile, inputLimit, invalidSinkResult, invalidLocalState
}

public struct ArcSecretsReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    public func countOnly() throws -> ArcSecretsReadReport {
        var report = ArcSecretsReadReport()
        var found = false
        for file in ArcSecretsBatchReader.File.allCases {
            guard let db = try secretsCopy(profileDirectory, file.rawValue) else { continue }
            found = true
            switch file {
            case .logins:
                report.loginRows = try db.countIfPresent("logins")
                if try db.columns("logins").contains("blacklisted_by_user") {
                    report.loginsBlacklisted = Int(try db.integer("SELECT COUNT(*) FROM logins WHERE blacklisted_by_user <> 0"))
                }
            case .cookies: report.cookieRows = try db.countIfPresent("cookies")
            case .webData:
                let addressColumns = try db.columns("addresses")
                report.addressRows = addressColumns.contains("record_type") ?
                    Int(try db.integer("SELECT COUNT(*) FROM addresses WHERE record_type = 0")) : try db.countIfPresent("addresses")
                report.cardRows = try db.countIfPresent("credit_cards")
                report.keywordRows = try db.countIfPresent("keywords")
                report.autofillRows = try db.countIfPresent("autofill")
            }
        }
        guard found else { throw ArcSecretsImportError.missingFiles }
        return report
    }

    /// Callbacks borrow one record. Do not retain records or their byte buffers.
    /// Each record is cleared immediately after its callback returns.
    public func readWithKey(_ key: [UInt8], consent: SecretsImportConsent,
                            consumeLogin: (borrowing ImportedLoginRecord) -> Void = { _ in },
                            consumeCookie: (borrowing ImportedCookieRecord) -> Void = { _ in },
                            consumeAddress: (borrowing ImportedAddressRecord) -> Void = { _ in },
                            consumeCard: (borrowing ImportedCardRecord) -> Void = { _ in }) throws -> ArcSecretsReadReport {
        try readWithAccess(key, access: .user(consent), consumeLogin: consumeLogin, consumeCookie: consumeCookie,
                           consumeAddress: consumeAddress, consumeCard: consumeCard)
    }

    public func validateWithKey(_ key: [UInt8], consent: SecretsImportConsent) throws -> ArcSecretsReadReport {
        try readWithKey(key, consent: consent)
    }

    func readWithAccess(_ key: [UInt8], access: SecretsReadAccess,
                        consumeLogin: (borrowing ImportedLoginRecord) -> Void = { _ in },
                        consumeCookie: (borrowing ImportedCookieRecord) -> Void = { _ in },
                        consumeAddress: (borrowing ImportedAddressRecord) -> Void = { _ in },
                        consumeCard: (borrowing ImportedCardRecord) -> Void = { _ in }) throws -> ArcSecretsReadReport {
        guard access.permits(profileDirectory) else { throw ArcSecretsImportError.invalidAccess }
        var report = ArcSecretsReadReport()
        var found = false
        for file in ArcSecretsBatchReader.File.allCases {
            guard let reader = try ArcSecretsBatchReader(profileDirectory: profileDirectory, file: file, key: key, access: access) else { continue }
            found = true
            switch file {
            case .logins:
                while var batch = try reader.nextLogins() {
                    defer { for i in batch.indices { batch[i].zeroSecrets() } }
                    for record in batch { consumeLogin(record) }
                }
            case .cookies:
                while var batch = try reader.nextCookies() {
                    defer { for i in batch.indices { batch[i].zeroSecrets() } }
                    for record in batch { consumeCookie(record) }
                }
            case .webData:
                while var batch = try reader.nextAddresses() {
                    defer { for i in batch.indices { batch[i].zeroSecrets() } }
                    for record in batch { consumeAddress(record) }
                }
                while var batch = try reader.nextCards() {
                    defer { for i in batch.indices { batch[i].zeroSecrets() } }
                    for record in batch { consumeCard(record) }
                }
            }
            try reader.validateAuxiliaryRows()
            report.add(reader.report)
        }
        guard found else { throw ArcSecretsImportError.missingFiles }
        return report
    }
}

/// One private SQLite copy of one file, retained until this cursor is released.
/// Not Sendable. The caller owns each returned batch and must clear it after use.
/// At most 256 source rows are visited per call, even when every row is skipped.
public final class ArcSecretsBatchReader {
    public enum File: String, CaseIterable, Sendable { case logins = "Login Data", webData = "Web Data", cookies = "Cookies" }
    private let db: ArcSQLiteCopy
    private let file: File
    private var key: [UInt8]
    private let access: SecretsReadAccess
    private var statements: [String: OpaquePointer] = [:]
    private var exhausted: Set<String> = []
    private var schema: [String: Set<String>] = [:]
    public private(set) var report = ArcSecretsReadReport()

    public convenience init?(profileDirectory: URL, file: File, key: [UInt8], consent: SecretsImportConsent) throws {
        try self.init(profileDirectory: profileDirectory, file: file, key: key, access: .user(consent))
    }

    init?(profileDirectory: URL, file: File, key: [UInt8], access: SecretsReadAccess) throws {
        guard access.permits(profileDirectory) else { throw ArcSecretsImportError.invalidAccess }
        guard let db = try secretsCopy(profileDirectory, file.rawValue) else { return nil }
        self.db = db; self.file = file; self.key = key; self.access = access
    }

    // The borrowing CLI also validates legacy form-history metadata. The write
    // importer never scans that unrelated table on the main actor.
    func validateAuxiliaryRows() throws {
        guard file == .webData else { return }
        report.keywordRows = try db.countIfPresent("keywords")
        try db.rowsIfPresent("autofill", sql: "SELECT date_created, date_last_used FROM autofill") { row in
            report.autofillRows += 1
            if validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 0))) == nil ||
                validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 1))) == nil { report.autofillInvalidTime += 1 }
        }
    }

    deinit { for statement in statements.values { sqlite3_finalize(statement) }; zeroSecretBytes(&key) }

    private func columns(_ table: String) throws -> Set<String> {
        if let cached = schema[table] { return cached }
        let result = try db.columns(table); schema[table] = result; return result
    }

    private func next<T>(_ table: String, expected: File, columns: [(String, String)],
                         clear: (inout T) -> Void, decode: (OpaquePointer) throws -> T?) throws -> [T]? {
        guard file == expected else { throw ArcSecretsImportError.invalidFile }
        if exhausted.contains(table) { return nil }
        if statements[table] == nil {
            let present = try self.columns(table)
            guard !present.isEmpty else { exhausted.insert(table); return nil }
            let selection = columns.map { present.contains($0.0) ? "\"" + $0.0 + "\"" : $0.1 }.joined(separator: ",")
            statements[table] = try db.prepare("SELECT " + selection + " FROM " + table + " ORDER BY rowid")
        }
        guard let row = statements[table] else { return nil }
        var batch: [T] = []
        batch.reserveCapacity(256)
        do {
            for _ in 0..<256 {
                try Task.checkCancellation()
                let status = sqlite3_step(row)
                if status == SQLITE_DONE {
                    sqlite3_finalize(row); statements.removeValue(forKey: table); exhausted.insert(table)
                    return batch.isEmpty ? nil : batch
                }
                guard status == SQLITE_ROW else { throw ArcHistoryImportError.schemaMismatch }
                try checkSecretRowSize(row)
                if let record = try decode(row) { batch.append(record) }
            }
            return batch
        } catch {
            for i in batch.indices { clear(&batch[i]) }
            throw error
        }
    }

    public func nextLogins() throws -> [ImportedLoginRecord]? {
        try next("logins", expected: .logins, columns: [
            ("origin_url", "''"), ("action_url", "''"), ("username_value", "''"), ("password_value", "X''"),
            ("signon_realm", "''"), ("date_created", "0"), ("blacklisted_by_user", "0"), ("times_used", "0"),
            ("username_element", "''"), ("password_element", "''"), ("scheme", "0"), ("date_last_used", "0"),
            ("date_password_modified", "0"), ("federation_url", "''"), ("id", "rowid")
        ], clear: { $0.zeroSecrets() }) { row in
            report.loginRows += 1
            if !db.text(row, 13).isEmpty { report.loginsFederated += 1; return nil }
            let blocked = sqlite3_column_int(row, 6) != 0
            guard let date = chromiumDate(sqlite3_column_int64(row, 5)) else { report.loginsInvalidTime += 1; return nil }
            let action = db.text(row, 1)
            var record = ImportedLoginRecord(originURLString: db.text(row, 0), actionURLString: action.isEmpty ? nil : action,
                username: db.text(row, 2), passwordBytes: [], signonRealm: db.text(row, 4), dateCreated: date,
                isBlacklisted: blocked, timesUsed: Int(sqlite3_column_int64(row, 7)))
            var handedOff = false
            defer { if !handedOff { record.zeroSecrets() } }
            do {
                if !blocked {
                    var blob = db.bytes(row, 3)
                    defer { zeroSecretBytes(&blob) }
                    record.passwordBytes = try decryptChromiumBlob(blob, key: key, access: access)
                    guard validUTF8(record.passwordBytes) else { throw ChromiumCryptoError.decryptFailed }
                }
                let notes = try columns("password_notes")
                if notes.isSuperset(of: ["parent_id", "key", "value"]) {
                    let note = try db.prepare("SELECT value FROM password_notes WHERE parent_id = ? AND key = '' LIMIT 1")
                    defer { sqlite3_finalize(note) }
                    sqlite3_bind_int64(note, 1, sqlite3_column_int64(row, 14))
                    let status = sqlite3_step(note)
                    if status == SQLITE_ROW {
                        try checkSecretRowSize(note)
                        var blob = db.bytes(note, 0)
                        defer { zeroSecretBytes(&blob) }
                        if !blob.isEmpty { record.noteBytes = try decryptChromiumBlob(blob, key: key, access: access) }
                        guard validUTF8(record.noteBytes) else { throw ChromiumCryptoError.decryptFailed }
                    } else if status != SQLITE_DONE { throw ArcHistoryImportError.schemaMismatch }
                }
                record.usernameElement = db.text(row, 8); record.passwordElement = db.text(row, 9)
                record.scheme = Int(sqlite3_column_int(row, 10))
                record.dateLastUsed = chromiumDate(sqlite3_column_int64(row, 11))
                record.datePasswordModified = chromiumDate(sqlite3_column_int64(row, 12))
                if blocked { report.loginsBlacklisted += 1 } else { report.loginsDecryptOK += 1 }
                handedOff = true
                return record
            } catch let error as ChromiumCryptoError {
                if case .badPrefix = error { report.badPrefix += 1 }
                report.loginsDecryptFailed += 1
                return nil
            }
        }
    }

    public func nextCookies() throws -> [ImportedCookieRecord]? {
        let version = (try? db.integer("SELECT value FROM meta WHERE key = 'version'")) ?? 0
        return try next("cookies", expected: .cookies, columns: [
            ("host_key", "''"), ("name", "''"), ("value", "X''"), ("encrypted_value", "X''"), ("path", "'/'"),
            ("expires_utc", "0"), ("is_secure", "0"), ("is_httponly", "0"), ("creation_utc", "0"),
            ("last_access_utc", "0"), ("last_update_utc", "0"), ("samesite", "-1"), ("priority", "1"),
            ("source_scheme", "0"), ("source_port", "-1"), ("top_frame_site_key", "''"), ("has_cross_site_ancestor", "0")
        ], clear: { $0.zeroSecrets() }) { row in
            report.cookieRows += 1
            let expiry = sqlite3_column_int64(row, 5)
            var expires: Date?
            if expiry != 0 {
                // Expiry is allowed to be years in the future; activity times are not.
                guard expiry > 0 else { report.cookiesInvalidTime += 1; return nil }
                expires = Date(timeIntervalSince1970: Double(expiry) / 1_000_000 - 11_644_473_600)
                if let expires, expires < Date() { report.cookiesExpired += 1; return nil }
            }
            var record = ImportedCookieRecord(hostKey: db.text(row, 0), name: db.text(row, 1), valueBytes: [], path: db.text(row, 4),
                expiresUTC: expires, isSecure: sqlite3_column_int(row, 6) != 0, isHTTPOnly: sqlite3_column_int(row, 7) != 0)
            var handedOff = false
            defer { if !handedOff { record.zeroSecrets() } }
            var blob = db.bytes(row, 3)
            defer { zeroSecretBytes(&blob) }
            do {
                record.valueBytes = blob.isEmpty ? db.bytes(row, 2) : try decryptChromiumBlob(blob, key: key, access: access)
                var legacy = false
                if version >= 24 {
                    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                    record.hostKey.utf8CString.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count - 1), &digest) }
                    if record.valueBytes.starts(with: digest) {
                        var value = Array(record.valueBytes.dropFirst(digest.count))
                        zeroSecretBytes(&record.valueBytes); swap(&record.valueBytes, &value)
                    } else { legacy = true }
                }
                guard validUTF8(record.valueBytes) else { throw ChromiumCryptoError.decryptFailed }
                record.creation = chromiumDate(sqlite3_column_int64(row, 8)) ?? Date(timeIntervalSince1970: 0)
                record.lastAccess = chromiumDate(sqlite3_column_int64(row, 9)); record.lastUpdate = chromiumDate(sqlite3_column_int64(row, 10))
                record.sameSite = Int(sqlite3_column_int(row, 11)); record.priority = Int(sqlite3_column_int(row, 12))
                record.sourceScheme = Int(sqlite3_column_int(row, 13)); record.sourcePort = Int(sqlite3_column_int(row, 14))
                let site = db.text(row, 15); record.topFrameSiteKey = site.isEmpty ? nil : site
                record.hasCrossSiteAncestor = sqlite3_column_int(row, 16) != 0
                if legacy { report.legacyNoHashPrefix += 1 }
                report.cookiesDecryptOK += 1
                handedOff = true
                return record
            } catch let error as ChromiumCryptoError {
                if case .badPrefix = error { report.badPrefix += 1 }
                report.cookiesDecryptFailed += 1; return nil
            }
        }
    }

    public func nextAddresses() throws -> [ImportedAddressRecord]? {
        try next("addresses", expected: .webData, columns: [
            ("guid", "''"), ("use_count", "0"), ("use_date", "0"), ("date_modified", "0"), ("language_code", "''"), ("record_type", "0")
        ], clear: { $0.zeroSecrets() }) { row in
            guard sqlite3_column_int(row, 5) == 0 else { return nil }
            report.addressRows += 1
            guard let date = validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 2))) else {
                report.addressesInvalidTime += 1; return nil
            }
            var record = ImportedAddressRecord(guid: db.text(row, 0), fields: [:], useCount: Int(sqlite3_column_int64(row, 1)), useDate: date)
            record.dateModified = validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 3)))
            let language = db.text(row, 4); record.languageCode = language.isEmpty ? nil : language
            let columns = try self.columns("address_type_tokens")
            if !columns.isEmpty {
                let statusColumn = columns.contains("verification_status") ? "verification_status" : "0"
                let tokens = try db.prepare("SELECT type, value, " + statusColumn + " FROM address_type_tokens WHERE guid = ? LIMIT 513")
                defer { sqlite3_finalize(tokens) }
                _ = record.guid.withCString { sqlite3_bind_text(tokens, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                var count = 0
                var fieldBytes = 0
                while true {
                    let status = sqlite3_step(tokens)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw ArcHistoryImportError.schemaMismatch }
                    count += 1
                    guard count <= 512 else { throw ArcSecretsImportError.inputLimit }
                    try checkSecretRowSize(tokens)
                    fieldBytes += Int(sqlite3_column_bytes(tokens, 1))
                    guard fieldBytes <= 64 * 1024 else { throw ArcSecretsImportError.inputLimit }
                    let type = Int(sqlite3_column_int(tokens, 0))
                    record.fields[type] = db.text(tokens, 1)
                    record.verificationStatuses[type] = Int(sqlite3_column_int(tokens, 2))
                }
            }
            return record
        }
    }

    public func nextCards() throws -> [ImportedCardRecord]? {
        try next("credit_cards", expected: .webData, columns: [
            ("guid", "''"), ("name_on_card", "''"), ("expiration_month", "0"), ("expiration_year", "0"),
            ("card_number_encrypted", "X''"), ("nickname", "''"), ("use_count", "0"), ("use_date", "0")
        ], clear: { $0.zeroSecrets() }) { row in
            report.cardRows += 1
            var blob = db.bytes(row, 4)
            defer { zeroSecretBytes(&blob) }
            var plain: [UInt8] = []
            defer { zeroSecretBytes(&plain) }
            do {
                plain = try decryptChromiumBlob(blob, key: key, access: access)
                var digits = plain.filter { $0 != 0x20 }
                defer { zeroSecretBytes(&digits) }
                guard validUTF8(plain), (12...19).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
                    throw ChromiumCryptoError.decryptFailed
                }
                var record = ImportedCardRecord(guid: db.text(row, 0), nameOnCard: db.text(row, 1),
                    expirationMonth: Int(sqlite3_column_int(row, 2)), expirationYear: Int(sqlite3_column_int(row, 3)), numberBytes: [])
                swap(&record.numberBytes, &digits)
                let nickname = db.text(row, 5); record.nickname = nickname.isEmpty ? nil : nickname
                record.useCount = Int(sqlite3_column_int64(row, 6)); record.useDate = validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 7)))
                report.cardsDecryptOK += 1
                return record
            } catch let error as ChromiumCryptoError {
                if case .badPrefix = error { report.badPrefix += 1 }
                report.cardsDecryptFailed += 1; return nil
            }
        }
    }
}

extension ArcSecretsBatchReader: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ArcSecretsBatchReader(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

private func secretsCopy(_ profile: URL, _ name: String) throws -> ArcSQLiteCopy? {
    let file = profile.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    for suffix in ["", "-wal", "-journal"] {
        let candidate = URL(fileURLWithPath: file.path + suffix)
        guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
        let size = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 * 1024 else { throw ArcSecretsImportError.inputLimit }
    }
    return try ArcSQLiteCopy(fileURL: file)
}

private extension ArcSQLiteCopy {
    func columns(_ table: String) throws -> Set<String> {
        var result: Set<String> = []
        try rows("PRAGMA table_info(" + table + ")") { result.insert(text($0, 1)) }
        return result
    }
    func countIfPresent(_ table: String) throws -> Int { try columns(table).isEmpty ? 0 : Int(integer("SELECT COUNT(*) FROM " + table)) }
    func rowsIfPresent(_ table: String, sql: String, consume: (OpaquePointer) throws -> Void) throws {
        if try !columns(table).isEmpty { try rows(sql, consume) }
    }
}

private func checkSecretRowSize(_ row: OpaquePointer) throws {
    // Before Swift allocation: <=16 KiB per field, <=64 KiB per selected row.
    // Address tokens have a separate 64 KiB total bound and <=512 fields.
    // A batch has <=256 records and <=32 MiB of raw selected field bytes.
    // UTF-8 replacement decoding can expand text by <=3x, plus object overhead.
    // Record byte allocations are <=16 KiB (+16 bytes for AES padding); the
    // shared private-file copier uses one 256 KiB buffer, below allocator limits.
    var total = 0
    for index in 0..<sqlite3_column_count(row) {
        let size = Int(sqlite3_column_bytes(row, index))
        guard size <= 16 * 1024 else { throw ArcSecretsImportError.inputLimit }
        total += size
    }
    guard total <= 64 * 1024 else { throw ArcSecretsImportError.inputLimit }
}

extension ArcSecretsReadReport {
    mutating func add(_ other: Self) {
        loginRows += other.loginRows
        loginsDecryptOK += other.loginsDecryptOK
        loginsDecryptFailed += other.loginsDecryptFailed
        loginsBlacklisted += other.loginsBlacklisted
        loginsFederated += other.loginsFederated
        loginsInvalidTime += other.loginsInvalidTime
        cookieRows += other.cookieRows
        cookiesDecryptOK += other.cookiesDecryptOK
        cookiesDecryptFailed += other.cookiesDecryptFailed
        cookiesExpired += other.cookiesExpired
        cookiesInvalidTime += other.cookiesInvalidTime
        legacyNoHashPrefix += other.legacyNoHashPrefix
        addressRows += other.addressRows
        addressesInvalidTime += other.addressesInvalidTime
        cardRows += other.cardRows
        cardsDecryptOK += other.cardsDecryptOK
        cardsDecryptFailed += other.cardsDecryptFailed
        keywordRows += other.keywordRows
        autofillRows += other.autofillRows
        autofillInvalidTime += other.autofillInvalidTime
        badPrefix += other.badPrefix
    }
}

private func chromiumDate(_ micros: Int64) -> Date? {
    let offset: Int64 = 11_644_473_600_000_000
    guard micros > offset else { return nil }
    return validatedImportDate(unixSeconds: Double(micros - offset) / 1_000_000)
}

/// UTF-8 validation without making an immutable String copy of a secret.
private func validUTF8(_ bytes: [UInt8]) -> Bool {
    var iterator = bytes.makeIterator()
    var decoder = Unicode.UTF8()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue: continue
        case .emptyInput: return true
        case .error: return false
        }
    }
}
