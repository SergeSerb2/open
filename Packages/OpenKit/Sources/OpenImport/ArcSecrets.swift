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

public struct ArcSecretsReadReport: Sendable {
    public var loginRows: Int = 0
    public var loginsDecryptOK: Int = 0
    public var loginsDecryptFailed: Int = 0
    public var loginsBlacklisted: Int = 0
    public var cookieRows: Int = 0
    public var cookiesDecryptOK: Int = 0
    public var cookiesDecryptFailed: Int = 0
    public var cookiesExpired: Int = 0
    public var addressRows: Int = 0
    public var cardRows: Int = 0
    public var cardsDecryptOK: Int = 0
    public var cardsDecryptFailed: Int = 0
    public var keywordRows: Int = 0
    public var autofillRows: Int = 0
}

public enum ArcSecretsImportError: Error { case missingFiles }

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

    /// Retaining API for the future engine writer. The caller must clear every secret record.
    /// The CLI uses validateWithKey instead, so file sets never overlap in memory.
    public func readWithKey(_ key: [UInt8]) throws -> (report: ArcSecretsReadReport, logins: [ImportedLoginRecord], cookies: [ImportedCookieRecord], addresses: [ImportedAddressRecord], cards: [ImportedCardRecord]) {
        try checkFiles()
        var report = ArcSecretsReadReport()
        var logins: [ImportedLoginRecord] = [], cookies: [ImportedCookieRecord] = [], cards: [ImportedCardRecord] = []
        var complete = false
        defer {
            if !complete {
                for i in logins.indices { logins[i].zeroSecrets() }
                for i in cookies.indices { cookies[i].zeroSecrets() }
                for i in cards.indices { cards[i].zeroSecrets() }
            }
        }
        logins = try readLogins(key, report: &report)
        cookies = try readCookies(key, report: &report)
        let addresses = try readAddresses(report: &report)
        cards = try readCards(key, report: &report)
        complete = true
        return (report, logins, cookies, addresses, cards)
    }

    /// A dry run consumes, clears, and drops one file set before reading the next.
    public func validateWithKey(_ key: [UInt8]) throws -> ArcSecretsReadReport {
        try checkFiles()
        var report = ArcSecretsReadReport()
        do {
            var records = try readLogins(key, report: &report)
            defer { for i in records.indices { records[i].zeroSecrets() } }
            guard records.count == report.loginsDecryptOK else { throw ArcHistoryImportError.schemaMismatch }
        }
        do {
            var records = try readCookies(key, report: &report)
            defer { for i in records.indices { records[i].zeroSecrets() } }
            guard records.count == report.cookiesDecryptOK else { throw ArcHistoryImportError.schemaMismatch }
        }
        _ = try readAddresses(report: &report)
        do {
            var records = try readCards(key, report: &report)
            defer { for i in records.indices { records[i].zeroSecrets() } }
            guard records.count == report.cardsDecryptOK else { throw ArcHistoryImportError.schemaMismatch }
        }
        return report
    }

    private func readLogins(_ key: [UInt8], report: inout ArcSecretsReadReport) throws -> [ImportedLoginRecord] {
        guard let db = try copy("Login Data") else { return [] }
        var records: [ImportedLoginRecord] = []
        var complete = false
        defer { if !complete { for i in records.indices { records[i].zeroSecrets() } } }
        try db.rows("SELECT origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, times_used FROM logins") { row in
            report.loginRows += 1
            if sqlite3_column_int(row, 6) != 0 { report.loginsBlacklisted += 1; return }
            var blob = db.bytes(row, 3)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = try decryptChromiumBlob(blob, key: key)
                var transferred = false
                defer { if !transferred { zeroSecretBytes(&plain) } }
                guard validUTF8(plain) else { report.loginsDecryptFailed += 1; return }
                let action = db.text(row, 1)
                records.append(ImportedLoginRecord(originURLString: db.text(row, 0), actionURLString: action.isEmpty ? nil : action,
                                                   username: db.text(row, 2), passwordBytes: plain, signonRealm: db.text(row, 4),
                                                   dateCreated: chromiumDate(sqlite3_column_int64(row, 5)), isBlacklisted: false,
                                                   timesUsed: Int(sqlite3_column_int64(row, 7))))
                transferred = true
                report.loginsDecryptOK += 1
            } catch { report.loginsDecryptFailed += 1 }
        }
        complete = true
        return records
    }

    private func readCookies(_ key: [UInt8], report: inout ArcSecretsReadReport) throws -> [ImportedCookieRecord] {
        guard let db = try copy("Cookies") else { return [] }
        let version = try db.integer("SELECT value FROM meta WHERE key = 'version'")
        var records: [ImportedCookieRecord] = []
        var complete = false
        defer { if !complete { for i in records.indices { records[i].zeroSecrets() } } }
        let now = Date()
        try db.rows("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires FROM cookies") { row in
            report.cookieRows += 1
            let expiry = sqlite3_column_int64(row, 5)
            let expires = expiry == 0 || sqlite3_column_int(row, 8) == 0 ? nil : chromiumDate(expiry)
            if let expires, expires < now { report.cookiesExpired += 1; return }
            var blob = db.bytes(row, 3)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = blob.isEmpty ? db.bytes(row, 2) : try decryptChromiumBlob(blob, key: key)
                var transferred = false
                defer { if !transferred { zeroSecretBytes(&plain) } }
                let host = db.text(row, 0)
                // Chromium schema 24+: encrypted values begin with SHA256(host_key).
                // Evidence: net/extras/sqlite/sqlite_persistent_cookie_store.cc,
                // MakeCookiesFromSQLStatement and the version 24 schema comment.
                if !blob.isEmpty && version >= 24 {
                    let digest = host.utf8CString.withUnsafeBytes { input -> [UInt8] in
                        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                        _ = CC_SHA256(input.baseAddress, CC_LONG(input.count - 1), &hash)
                        return hash
                    }
                    guard plain.starts(with: digest) else { report.cookiesDecryptFailed += 1; return }
                    var value = Array(plain.dropFirst(digest.count))
                    zeroSecretBytes(&plain)
                    swap(&plain, &value)
                }
                guard validUTF8(plain) else { report.cookiesDecryptFailed += 1; return }
                records.append(ImportedCookieRecord(hostKey: host, name: db.text(row, 1), valueBytes: plain, path: db.text(row, 4),
                                                    expiresUTC: expires, isSecure: sqlite3_column_int(row, 6) != 0,
                                                    isHTTPOnly: sqlite3_column_int(row, 7) != 0))
                transferred = true
                report.cookiesDecryptOK += 1
            } catch { report.cookiesDecryptFailed += 1 }
        }
        complete = true
        return records
    }

    private func readAddresses(report: inout ArcSecretsReadReport) throws -> [ImportedAddressRecord] {
        guard let db = try copy("Web Data") else { return [] }
        report.keywordRows = Int(try db.integer("SELECT COUNT(*) FROM keywords"))
        var fields: [String: [Int: String]] = [:]
        try db.rows("SELECT guid, type, value FROM address_type_tokens") { row in
            fields[db.text(row, 0), default: [:]][Int(sqlite3_column_int(row, 1))] = db.text(row, 2)
        }
        var records: [ImportedAddressRecord] = []
        try db.rows("SELECT guid, use_count, use_date FROM addresses") { row in
            let guid = db.text(row, 0)
            // Chromium AddressAutofillTable uses Time::FromTimeT for use_date (Unix seconds).
            records.append(ImportedAddressRecord(guid: guid, fields: fields[guid] ?? [:], useCount: Int(sqlite3_column_int64(row, 1)),
                                                 useDate: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)))))
            report.addressRows += 1
        }
        // Parse form history without keeping or converting its value to String.
        try db.rows("SELECT name, value, count, date_created, date_last_used FROM autofill") { row in
            var value = db.bytes(row, 1)
            defer { zeroSecretBytes(&value) }
            _ = db.text(row, 0)
            _ = sqlite3_column_int64(row, 2)
            _ = sqlite3_column_int64(row, 3)
            _ = sqlite3_column_int64(row, 4)
            report.autofillRows += 1
        }
        return records
    }

    private func readCards(_ key: [UInt8], report: inout ArcSecretsReadReport) throws -> [ImportedCardRecord] {
        guard let db = try copy("Web Data") else { return [] }
        var records: [ImportedCardRecord] = []
        var complete = false
        defer { if !complete { for i in records.indices { records[i].zeroSecrets() } } }
        try db.rows("SELECT guid, name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards") { row in
            report.cardRows += 1
            var blob = db.bytes(row, 4)
            defer { zeroSecretBytes(&blob) }
            do {
                var plain = try decryptChromiumBlob(blob, key: key)
                defer { zeroSecretBytes(&plain) }
                var digits = plain.filter { $0 != 0x20 }
                var transferred = false
                defer { if !transferred { zeroSecretBytes(&digits) } }
                guard validUTF8(plain), (12...19).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
                    report.cardsDecryptFailed += 1
                    return
                }
                records.append(ImportedCardRecord(guid: db.text(row, 0), nameOnCard: db.text(row, 1), expirationMonth: Int(sqlite3_column_int(row, 2)),
                                                  expirationYear: Int(sqlite3_column_int(row, 3)), numberBytes: digits))
                transferred = true
                report.cardsDecryptOK += 1
            } catch { report.cardsDecryptFailed += 1 }
        }
        complete = true
        return records
    }
}

private func chromiumDate(_ micros: Int64) -> Date {
    let (unixMicros, overflow) = micros.subtractingReportingOverflow(11_644_473_600_000_000)
    return overflow ? .distantPast : Date(timeIntervalSince1970: Double(unixMicros) / 1_000_000)
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
