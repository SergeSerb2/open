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

    func createDatabase(_ name: String, sql: String) throws {
        let file = directory.appendingPathComponent(name)
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
