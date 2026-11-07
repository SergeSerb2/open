import Foundation
import SQLite3
import CommonCrypto
import Darwin

/// The only synthetic access issuer. It creates all rows itself. There is no
/// public constructor and no API that accepts an existing profile or ciphertext.
final class SyntheticSecretsFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("open-secrets-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func apply(_ scenario: SyntheticSecretsScenario) throws {
        for profile in ["Default", "Profile 1"] {
            func modify(_ file: String, _ sql: String) throws {
                var db: OpaquePointer?
                guard sqlite3_open(directory.appendingPathComponent(profile).appendingPathComponent(file).path, &db) == SQLITE_OK else {
                    sqlite3_close(db); throw ArcHistoryImportError.openFailed
                }
                defer { sqlite3_close(db) }
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ArcHistoryImportError.schemaMismatch }
            }
            switch scenario {
            case .standard: break
            case .batchBoundary:
                for index in 1...253 {
                    try modify("Login Data", "INSERT INTO logins SELECT id + \(index + 5), origin_url, action_url, username_value || '-extra\(index)', password_value, signon_realm, date_created, blacklisted_by_user, times_used, username_element, password_element, scheme, date_last_used, date_password_modified, federation_url FROM logins WHERE id = 1")
                }
            case .fieldAtLimit, .fieldOverLimit:
                let size = scenario == .fieldAtLimit ? 16_384 : 16_385
                try modify("Login Data", "UPDATE logins SET username_value = '" + String(repeating: "x", count: size) + "' WHERE id = 1")
            case .empty:
                try modify("Login Data", "DELETE FROM logins; DELETE FROM password_notes")
                try modify("Web Data", "DELETE FROM addresses; DELETE FROM address_type_tokens; DELETE FROM credit_cards")
                try modify("Cookies", "DELETE FROM cookies")
            case .nonlocalAddress:
                try modify("Web Data", "INSERT INTO addresses SELECT guid || '-remote', use_count, use_date, date_modified, language_code, 1 FROM addresses")
            case .invalidLogin:
                try modify("Login Data", "UPDATE logins SET password_value = X'763131' WHERE id = 1")
            }
        }
    }

    func createDatabase(_ name: String, profile: String? = nil, sql: String) throws {
        let file = (profile.map { directory.appendingPathComponent($0) } ?? directory).appendingPathComponent(name)
        let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArcHistoryImportError.copyFailed }
        Darwin.close(fd)
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            sqlite3_close(db); throw ArcHistoryImportError.openFailed
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ArcHistoryImportError.schemaMismatch }
    }

    /// Full Section 15 source fixture. SQL contains fixture strings only.
    func createImportProfiles(key: [UInt8]) throws {
        func encrypted(_ value: String) throws -> String {
            var bytes = Array(value.utf8)
            defer { zeroSecretBytes(&bytes) }
            return "X'" + (try encryptFixture(bytes, key: key)).map { String(format: "%02x", $0) }.joined() + "'"
        }
        let now = Int64(Date().timeIntervalSince1970) - 60
        let time = 11_644_473_600_000_000 + now * 1_000_000
        let future = time + 365 * 86_400_000_000
        let state = ["profile": ["info_cache": ["Default": [:], "Profile 1": [:]], "profiles_order": ["Default", "Profile 1"]]] as [String: Any]
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("Local State"))
        for (index, profile) in ["Default", "Profile 1"].enumerated() {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(profile), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var logins = """
                CREATE TABLE logins(id INTEGER PRIMARY KEY, origin_url, action_url, username_value, password_value, signon_realm,
                  date_created, blacklisted_by_user, times_used, username_element, password_element, scheme, date_last_used,
                  date_password_modified, federation_url);
                CREATE TABLE password_notes(parent_id, key, value);
                """
            for row in 1...5 {
                let host = row == 3 ? "other.example.com" : "login.example.com"
                let password = row == 4 ? "X''" : try encrypted("fixture-password")
                logins += "INSERT INTO logins VALUES(\(row), 'https://\(host)/', 'https://\(host)/submit', 'fixture-\(index)-\(row)', \(password), 'https://\(host)/', \(time), \(row == 4 ? 1 : 0), 2, 'email', 'password', 0, \(time), \(time), '\(row == 5 ? "https://federation.example.com/" : "")');"
            }
            logins += "INSERT INTO password_notes VALUES(1, '', \(try encrypted("fixture-note")));"
            // A named system note is not the user's visible note.
            logins += "INSERT INTO password_notes VALUES(1, 'system', X'763131');"
            try createDatabase("Login Data", profile: profile, sql: logins)
            var cookies = """
                CREATE TABLE meta(key PRIMARY KEY, value); INSERT INTO meta VALUES('version', 24);
                CREATE TABLE cookies(host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires,
                  creation_utc, last_access_utc, last_update_utc, samesite, priority, source_scheme, source_port, top_frame_site_key,
                  has_cross_site_ancestor);
                """
            for row in 1...5 {
                let blob = "X'" + (try encryptFixture(SHA256Fixture("login.example.com") + Array("fixture-cookie".utf8), key: key)).map { String(format: "%02x", $0) }.joined() + "'"
                let expiry = row == 2 ? 0 : row == 5 ? time : future
                cookies += "INSERT INTO cookies VALUES('login.example.com', 'fixture-\(index)-\(row)', '', \(blob), '/', \(expiry), 1, \(row == 3 ? 1 : 0), \(row == 2 ? 0 : 1), \(time), \(time), \(time), 1, 2, 2, 443, '\(row == 4 ? "https://other.example.com" : "")', \(row == 4 ? 1 : 0));"
            }
            try createDatabase("Cookies", profile: profile, sql: cookies)
            let web = """
                CREATE TABLE addresses(guid, use_count, use_date, date_modified, language_code, record_type);
                CREATE TABLE address_type_tokens(guid, type, value, verification_status);
                CREATE TABLE credit_cards(guid, name_on_card, expiration_month, expiration_year, card_number_encrypted, nickname, use_count, use_date);
                CREATE TABLE keywords(id); CREATE TABLE autofill(date_created, date_last_used);
                INSERT INTO addresses VALUES('00000000-0000-4000-8000-a0000000000\(index)', 3, \(now), \(now), 'en', 0);
                INSERT INTO address_type_tokens VALUES('00000000-0000-4000-8000-a0000000000\(index)', 7, 'Fixture Person', 3);
                INSERT INTO address_type_tokens VALUES('00000000-0000-4000-8000-a0000000000\(index)', 30, '1 Example Street', 4);
                INSERT INTO credit_cards VALUES('00000000-0000-4000-8000-c0000000000\(index)', 'Fixture Person', 12, 2030, \(try encrypted("4111 1111 1111 1111")), 'Fixture card', 4, \(now));
                """
            try createDatabase("Web Data", profile: profile, sql: web)
        }
    }

}

public struct SyntheticSecretsResult {
    public let report: ArcSecretsReadReport
    public let redactedRecordKinds: Int
    public let knownKeyMatches: Bool
    public let hashValuesMatch: Bool
}

/// End-to-end CLI fixture source. Generates known-password databases, then uses
/// the production SQLite copy, parser, callback, and crypto paths. No Keychain
/// call is made and no caller-supplied file or key can enter this path.
public func verifySyntheticSecretsImport() throws -> SyntheticSecretsResult {
    let fixture = try SyntheticSecretsFixture()
    let access = SecretsReadAccess.synthetic(fixture)
    var password = Array("mock_password".utf8)
    defer { zeroSecretBytes(&password) }
    var key = deriveChromiumKey(passwordBytes: password)
    defer { zeroSecretBytes(&key) }
    let knownKeyMatches = key == [0xaf, 0x0f, 0x76, 0x2a, 0xaf, 0x6d, 0x7d, 0x11, 0x58, 0x1b, 0x7a, 0xa8, 0xce, 0x72, 0x18, 0xde]
    var fallback: [UInt8] = [0xd0, 0xd0, 0xec, 0x9c, 0x7d, 0x77, 0xd4, 0x3a, 0xc5, 0x41, 0x87, 0xfa, 0x48, 0x18, 0xd1, 0x7f]
    defer { zeroSecretBytes(&fallback) }
    func literal(_ bytes: [UInt8]) -> String { "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" }
    func encrypted(_ bytes: [UInt8], fallbackKey: Bool = false) throws -> String {
        try literal(encryptFixture(bytes, key: fallbackKey ? fallback : key))
    }
    let now = Int64(Date().timeIntervalSince1970)
    let date = 11_644_473_600_000_000 + (now - 60) * 1_000_000
    let future = 11_644_473_600_000_000 + (now + 172_800) * 1_000_000
    let loginBlobs = try [encrypted(Array("fixture-password".utf8)), literal(Array("legacy".utf8)),
        literal(Array("v1x-plain".utf8)), encrypted(Array("fallback".utf8), fallbackKey: true),
        encrypted([0xff, 0xfe]), literal(Array("v10broken".utf8)), literal(Array("v11unsupported".utf8)),
        literal(Array("v20unsupported".utf8)), literal(Array("v99unsupported".utf8))]
    var loginSQL = "CREATE TABLE logins(origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, times_used);"
    for blob in loginBlobs {
        loginSQL += "INSERT INTO logins VALUES('https://example.com/login', '', 'fixture-user', \(blob), 'https://example.com', \(date), 0, 1);"
    }
    loginSQL += "INSERT INTO logins VALUES('https://example.com', '', '', X'', '', \(date), 1, 0);"
    for invalid in [Int64(0), .min, future] {
        loginSQL += "INSERT INTO logins VALUES('https://example.com', '', '', X'61', '', \(invalid), 0, 0);"
    }
    try fixture.createDatabase("Login Data", sql: loginSQL)

    let host = "example.com"
    let digest = Array(SHA256Fixture(host))
    let value = Array("fixture-cookie".utf8)
    let cookies: [(String, String, Int64, Int)] = try [
        (encrypted(digest + value), "''", 0, 0),
        (encrypted(value), "''", 0, 0),
        ("X''", literal(value), 0, 0),
        (encrypted(digest + value, fallbackKey: true), "''", 0, 0),
        (encrypted([0xff]), "''", 0, 0),
        (encrypted([UInt8](repeating: 0xff, count: 32) + value), "''", 0, 0),
        (literal(Array("v10broken".utf8)), "''", 0, 0),
        (literal(Array("v11unsupported".utf8)), "''", 0, 0),
        (encrypted(value), "''", date, 1),
        (encrypted(digest + value), "''", date + 3_600_000_000, 1),
        (encrypted(value), "''", -1, 1),
        (encrypted(value), "''", future, 1),
    ]
    var cookieSQL = "CREATE TABLE meta(key PRIMARY KEY, value); INSERT INTO meta VALUES('version', 24); CREATE TABLE cookies(host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires);"
    for (blob, plain, expiry, expires) in cookies {
        cookieSQL += "INSERT INTO cookies VALUES('example.com', 'fixture', \(plain), \(blob), '/', \(expiry), 1, 1, \(expires));"
    }
    try fixture.createDatabase("Cookies", sql: cookieSQL)
    let cardBlobs = try [encrypted(Array("4111 1111 1111 1111".utf8)), encrypted(Array("bad".utf8)),
                         literal(Array("v11unsupported".utf8)), literal(Array("v10broken".utf8))]
    var webSQL = "CREATE TABLE addresses(guid, use_count, use_date); CREATE TABLE address_type_tokens(guid, type, value); CREATE TABLE autofill(name, value, count, date_created, date_last_used); CREATE TABLE credit_cards(guid, name_on_card, expiration_month, expiration_year, card_number_encrypted); CREATE TABLE keywords(id); INSERT INTO keywords VALUES(1);"
    for time in [now - 60, 0, .min, now + 172_800] {
        webSQL += "INSERT INTO addresses VALUES('fixture', 1, \(time)); INSERT INTO autofill VALUES('fixture', 'fixture', 1, \(time), \(time));"
    }
    webSQL += "INSERT INTO address_type_tokens VALUES('fixture', 1, 'fixture');"
    for blob in cardBlobs {
        webSQL += "INSERT INTO credit_cards VALUES('fixture', 'fixture', 1, 2030, \(blob));"
    }
    try fixture.createDatabase("Web Data", sql: webSQL)

    var redactedKinds: Set<String> = []
    func recordIsRedacted<T: CustomStringConvertible & CustomDebugStringConvertible & CustomReflectable>(_ record: borrowing T, kind: String) {
        let expected = kind + "(redacted)"
        let description = String(describing: copy record)
        let debug = String(reflecting: copy record)
        let emptyMirror = Mirror(reflecting: copy record).children.isEmpty
        if description == expected && debug == expected && emptyMirror {
            redactedKinds.insert(kind)
        }
    }
    var hashValuesMatch = true
    let report = try ArcSecretsReader(profileDirectory: fixture.directory).readWithAccess(key, access: access,
        consumeLogin: { recordIsRedacted($0, kind: "ImportedLoginRecord") },
        consumeCookie: {
            recordIsRedacted($0, kind: "ImportedCookieRecord")
            hashValuesMatch = hashValuesMatch && $0.valueBytes == value
        },
        consumeAddress: { recordIsRedacted($0, kind: "ImportedAddressRecord") },
        consumeCard: { recordIsRedacted($0, kind: "ImportedCardRecord") })
    return SyntheticSecretsResult(report: report, redactedRecordKinds: redactedKinds.count,
                                  knownKeyMatches: knownKeyMatches, hashValuesMatch: hashValuesMatch)
}

private func SHA256Fixture(_ text: String) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    text.utf8CString.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count - 1), &digest) }
    return digest
}

private func encryptFixture(_ bytes: [UInt8], key: [UInt8]) throws -> [UInt8] {
    let iv = [UInt8](repeating: 0x20, count: 16)
    var output = [UInt8](repeating: 0, count: bytes.count + kCCBlockSizeAES128)
    var written = 0
    let capacity = output.count
    let status = key.withUnsafeBytes { keyBytes in
        iv.withUnsafeBytes { ivBytes in
            bytes.withUnsafeBytes { input in
                output.withUnsafeMutableBytes {
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, input.count,
                            $0.baseAddress, capacity, &written)
                }
            }
        }
    }
    guard status == kCCSuccess else { zeroSecretBytes(&output); throw ChromiumCryptoError.decryptFailed }
    output.removeSubrange(written..<output.count)
    return Array("v10".utf8) + output
}
