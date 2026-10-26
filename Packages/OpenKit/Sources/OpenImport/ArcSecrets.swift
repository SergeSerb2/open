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
    public mutating func zeroSecrets() { zeroSecretBytes(&passwordBytes) }
}

public struct ImportedCookieRecord {
    public var hostKey: String
    public var name: String
    public var valueBytes: [UInt8]
    public var path: String
    public var expiresUTC: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public mutating func zeroSecrets() { zeroSecretBytes(&valueBytes) }
}

public struct ImportedAddressRecord: Sendable {
    public var guid: String
    public var fields: [Int: String]
    public var useCount: Int
    public var useDate: Date
}

public struct ImportedCardRecord {
    public var guid: String
    public var nameOnCard: String
    public var expirationMonth: Int
    public var expirationYear: Int
    public var numberBytes: [UInt8]
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

public enum ArcSecretsImportError: Error { case missingFiles, invalidAccess }

public struct ArcSecretsReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    private func copy(_ name: String) throws -> ArcSQLiteCopy? {
        let file = profileDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try ArcSQLiteCopy(fileURL: file)
    }

    private func checkFiles() throws {
        guard ["Login Data", "Cookies", "Web Data"].contains(where: {
            FileManager.default.fileExists(atPath: profileDirectory.appendingPathComponent($0).path)
        }) else { throw ArcSecretsImportError.missingFiles }
    }

    public func countOnly() throws -> ArcSecretsReadReport {
        try checkFiles()
        var report = ArcSecretsReadReport()
        if let db = try copy("Login Data") {
            report.loginRows = Int(try db.integer("SELECT COUNT(*) FROM logins"))
            report.loginsBlacklisted = Int(try db.integer("SELECT COUNT(*) FROM logins WHERE blacklisted_by_user <> 0"))
        }
        if let db = try copy("Cookies") { report.cookieRows = Int(try db.integer("SELECT COUNT(*) FROM cookies")) }
        if let db = try copy("Web Data") {
            report.addressRows = Int(try db.integer("SELECT COUNT(*) FROM addresses"))
            report.cardRows = Int(try db.integer("SELECT COUNT(*) FROM credit_cards"))
            report.keywordRows = Int(try db.integer("SELECT COUNT(*) FROM keywords"))
            report.autofillRows = Int(try db.integer("SELECT COUNT(*) FROM autofill"))
        }
        return report
    }

    /// Each callback borrows one record. Its byte buffer is cleared immediately
    /// after the callback returns. Do not copy or retain records or their fields.
    /// No retaining overload is needed before the engine writer exists.
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

    // Synthetic callers cannot supply a directory: only the module's fixture
    // factory can issue synthetic access. All real-data entry points need consent.
    func readWithAccess(_ key: [UInt8], access: SecretsReadAccess,
                        consumeLogin: (borrowing ImportedLoginRecord) -> Void = { _ in },
                        consumeCookie: (borrowing ImportedCookieRecord) -> Void = { _ in },
                        consumeAddress: (borrowing ImportedAddressRecord) -> Void = { _ in },
                        consumeCard: (borrowing ImportedCardRecord) -> Void = { _ in }) throws -> ArcSecretsReadReport {
        guard access.permits(profileDirectory) else { throw ArcSecretsImportError.invalidAccess }
        try checkFiles()
        var report = ArcSecretsReadReport()
        try readLogins(key, access: access, report: &report, consume: consumeLogin)
        try readCookies(key, access: access, report: &report, consume: consumeCookie)
        try readAddresses(access: access, report: &report, consume: consumeAddress)
        try readCards(key, access: access, report: &report, consume: consumeCard)
        return report
    }

    private func readLogins(_ key: [UInt8], access: SecretsReadAccess, report: inout ArcSecretsReadReport,
                            consume: (borrowing ImportedLoginRecord) -> Void) throws {
        guard let db = try copy("Login Data") else { return }
        try db.rows("SELECT origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, times_used FROM logins") { row in
            report.loginRows += 1
            if sqlite3_column_int(row, 6) != 0 { report.loginsBlacklisted += 1; return }
            guard let date = chromiumDate(sqlite3_column_int64(row, 5)) else { report.loginsInvalidTime += 1; return }
            var blob = db.bytes(row, 3)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = try decryptChromiumBlob(blob, key: key, access: access)
                defer { zeroSecretBytes(&plain) }
                guard validUTF8(plain) else { report.loginsDecryptFailed += 1; return }
                let action = db.text(row, 1)
                var record = ImportedLoginRecord(originURLString: db.text(row, 0), actionURLString: action.isEmpty ? nil : action,
                    username: db.text(row, 2), passwordBytes: [], signonRealm: db.text(row, 4), dateCreated: date,
                    isBlacklisted: false, timesUsed: Int(sqlite3_column_int64(row, 7)))
                swap(&record.passwordBytes, &plain)
                defer { record.zeroSecrets() }
                consume(record)
                report.loginsDecryptOK += 1
            } catch {
                if case ChromiumCryptoError.badPrefix = error { report.badPrefix += 1 }
                report.loginsDecryptFailed += 1
            }
        }
    }

    private func readCookies(_ key: [UInt8], access: SecretsReadAccess, report: inout ArcSecretsReadReport,
                             consume: (borrowing ImportedCookieRecord) -> Void) throws {
        guard let db = try copy("Cookies") else { return }
        let version = try db.integer("SELECT value FROM meta WHERE key = 'version'")
        let now = Date()
        try db.rows("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires FROM cookies") { row in
            report.cookieRows += 1
            let expiry = sqlite3_column_int64(row, 5)
            var expires: Date?
            if expiry != 0 && sqlite3_column_int(row, 8) != 0 {
                guard let date = chromiumDate(expiry) else { report.cookiesInvalidTime += 1; return }
                expires = date
                if date < now { report.cookiesExpired += 1; return }
            }
            var blob = db.bytes(row, 3)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = blob.isEmpty ? db.bytes(row, 2) : try decryptChromiumBlob(blob, key: key, access: access)
                defer { zeroSecretBytes(&plain) }
                let host = db.text(row, 0)
                // Schema evidence: net/extras/sqlite/sqlite_persistent_cookie_store.cc,
                // MakeCookiesFromSQLStatement and the version 24 schema comment.
                var legacy = false
                if version >= 24 {
                    let digest = host.utf8CString.withUnsafeBytes { input -> [UInt8] in
                        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                        _ = CC_SHA256(input.baseAddress, CC_LONG(input.count - 1), &hash)
                        return hash
                    }
                    if plain.starts(with: digest) {
                        var value = Array(plain.dropFirst(digest.count))
                        zeroSecretBytes(&plain)
                        swap(&plain, &value)
                    } else { legacy = true }
                }
                guard validUTF8(plain) else { report.cookiesDecryptFailed += 1; return }
                var record = ImportedCookieRecord(hostKey: host, name: db.text(row, 1), valueBytes: [], path: db.text(row, 4),
                    expiresUTC: expires, isSecure: sqlite3_column_int(row, 6) != 0, isHTTPOnly: sqlite3_column_int(row, 7) != 0)
                swap(&record.valueBytes, &plain)
                defer { record.zeroSecrets() }
                consume(record)
                if legacy { report.legacyNoHashPrefix += 1 }
                report.cookiesDecryptOK += 1
            } catch {
                if case ChromiumCryptoError.badPrefix = error { report.badPrefix += 1 }
                report.cookiesDecryptFailed += 1
            }
        }
    }

    private func readAddresses(access: SecretsReadAccess, report: inout ArcSecretsReadReport,
                               consume: (borrowing ImportedAddressRecord) -> Void) throws {
        guard let db = try copy("Web Data") else { return }
        report.keywordRows = Int(try db.integer("SELECT COUNT(*) FROM keywords"))
        try db.rows("SELECT guid, use_count, use_date FROM addresses") { row in
            report.addressRows += 1
            guard let date = validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 2))) else {
                report.addressesInvalidTime += 1; return
            }
            let guid = db.text(row, 0)
            var fields: [Int: String] = [:]
            let tokens = try db.prepare("SELECT type, value FROM address_type_tokens WHERE guid = ?")
            defer { sqlite3_finalize(tokens) }
            _ = guid.withCString { sqlite3_bind_text(tokens, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            while true {
                let status = sqlite3_step(tokens)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw ArcHistoryImportError.schemaMismatch }
                fields[Int(sqlite3_column_int(tokens, 0))] = db.text(tokens, 1)
            }
            let record = ImportedAddressRecord(guid: guid, fields: fields, useCount: Int(sqlite3_column_int64(row, 1)), useDate: date)
            consume(record)
        }
        try db.rows("SELECT date_created, date_last_used FROM autofill") { row in
            report.autofillRows += 1
            // Autofill form dates use Unix seconds, as do address use dates.
            guard validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 0))) != nil,
                  validatedImportDate(unixSeconds: Double(sqlite3_column_int64(row, 1))) != nil else {
                report.autofillInvalidTime += 1; return
            }
        }
    }

    private func readCards(_ key: [UInt8], access: SecretsReadAccess, report: inout ArcSecretsReadReport,
                           consume: (borrowing ImportedCardRecord) -> Void) throws {
        guard let db = try copy("Web Data") else { return }
        try db.rows("SELECT guid, name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards") { row in
            report.cardRows += 1
            var blob = db.bytes(row, 4)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = try decryptChromiumBlob(blob, key: key, access: access)
                defer { zeroSecretBytes(&plain) }
                var digits = plain.filter { $0 != 0x20 }
                defer { zeroSecretBytes(&digits) }
                guard validUTF8(plain), (12...19).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
                    report.cardsDecryptFailed += 1; return
                }
                var record = ImportedCardRecord(guid: db.text(row, 0), nameOnCard: db.text(row, 1), expirationMonth: Int(sqlite3_column_int(row, 2)),
                    expirationYear: Int(sqlite3_column_int(row, 3)), numberBytes: [])
                swap(&record.numberBytes, &digits)
                defer { record.zeroSecrets() }
                consume(record)
                report.cardsDecryptOK += 1
            } catch {
                if case ChromiumCryptoError.badPrefix = error { report.badPrefix += 1 }
                report.cardsDecryptFailed += 1
            }
        }
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
