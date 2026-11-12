import Foundation
import SQLite3

public struct FirefoxLoginsReport: Sendable, Equatable {
    public var sourceRows = 0
    public var kept = 0
    public var skippedUnsupportedOrigin = 0
    public var skippedDecryptFailed = 0
    public var skippedOversize = 0
    public init() {}
    public var accounted: Int { kept + skippedUnsupportedOrigin + skippedDecryptFailed + skippedOversize }
}

/// Firefox saved logins (`logins.json` + `key4.db`). Lead ruling 2 (11 Nov 10:55): passwords yes, cookies no.
/// No consent dialog exists without a Primary Password (NSS protects the key with an empty password);
/// with one, the user types it and the caller passes it here. Never stored.
public struct FirefoxLoginsReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    /// Counts `logins.json` rows without touching `key4.db`.
    public func countOnly() throws -> Int {
        try loadJSON().count
    }

    /// True when `key4.db` cannot be opened with an empty password.
    public func needsPrimaryPassword() throws -> Bool {
        do { var key = try sdrKey(primaryPassword: []); zeroSecretBytes(&key); return false }
        catch FirefoxImportError.primaryPasswordRequired { return true }
    }

    public func read(primaryPassword: String = "") throws -> (logins: [ImportedLoginRecord], report: FirefoxLoginsReport) {
        let entries = try loadJSON()
        var report = FirefoxLoginsReport()
        report.sourceRows = entries.count
        guard !entries.isEmpty else { return ([], report) }
        var password = Array(primaryPassword.utf8)
        defer { zeroSecretBytes(&password) }
        var key = try sdrKey(primaryPassword: password)
        defer { zeroSecretBytes(&key) }
        var logins: [ImportedLoginRecord] = []
        for entry in entries {
            guard let hostname = entry["hostname"] as? String, let origin = URL(string: hostname),
                  let scheme = origin.scheme?.lowercased(), ["http", "https"].contains(scheme), origin.host?.isEmpty == false else {
                report.skippedUnsupportedOrigin += 1; continue
            }
            guard let encUser = entry["encryptedUsername"] as? String, let encPass = entry["encryptedPassword"] as? String,
                  var user = try? FirefoxCrypto.decryptSDR(base64: encUser, key: key) else {
                report.skippedDecryptFailed += 1; continue
            }
            defer { zeroSecretBytes(&user) }
            guard var pass = try? FirefoxCrypto.decryptSDR(base64: encPass, key: key) else { report.skippedDecryptFailed += 1; continue }
            // The secrets sink bounds each field to 16 KiB.
            guard user.count <= 16 * 1024, pass.count <= 16 * 1024, hostname.utf8.count <= 16 * 1024 else {
                zeroSecretBytes(&pass); report.skippedOversize += 1; continue
            }
            func date(_ key: String) -> Date? {
                guard let ms = (entry[key] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
                return validatedImportDate(unixSeconds: ms / 1000)
            }
            // Chromium form logins use the origin plus "/" as realm; HTTP auth adds the realm name (scheme 1 = basic).
            let originString = "\(scheme)://\(origin.host!)\(origin.port.map { ":\($0)" } ?? "")"
            let httpRealm = entry["httpRealm"] as? String
            let action = (entry["formSubmitURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var record = ImportedLoginRecord(originURLString: originString + "/", actionURLString: action,
                username: String(decoding: user, as: UTF8.self), passwordBytes: pass,
                signonRealm: httpRealm.map { originString + "/" + $0 } ?? originString + "/",
                dateCreated: date("timeCreated") ?? Date(), isBlacklisted: false,
                timesUsed: (entry["timesUsed"] as? NSNumber)?.intValue ?? 0)
            record.usernameElement = entry["usernameField"] as? String ?? ""
            record.passwordElement = entry["passwordField"] as? String ?? ""
            record.scheme = httpRealm == nil ? 0 : 1
            record.dateLastUsed = date("timeLastUsed")
            record.datePasswordModified = date("timePasswordChanged")
            logins.append(record)
            report.kept += 1
        }
        return (logins, report)
    }

    private func loadJSON() throws -> [[String: Any]] {
        let file = profileDirectory.appendingPathComponent("logins.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file), data.count <= 64 << 20 else { throw FirefoxImportError.unreadable("logins.json") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logins = root["logins"] as? [[String: Any]] else { throw FirefoxImportError.schemaMismatch("logins.json") }
        return logins
    }

    /// Opens the NSS key store. The password check proves the Primary Password before the key is used.
    private func sdrKey(primaryPassword: [UInt8]) throws -> [UInt8] {
        let copy = try FirefoxPlacesReader.open(profileDirectory.appendingPathComponent("key4.db"), name: "key4.db")
        var globalSalt: [UInt8] = [], check: [UInt8] = []
        var keys: [(a11: [UInt8], a102: [UInt8])] = []
        do {
            try copy.rows("SELECT item1, item2 FROM metaData WHERE id = 'password'") { s in
                globalSalt = copy.bytes(s, 0); check = copy.bytes(s, 1)
            }
            try copy.rows("SELECT a11, a102 FROM nssPrivate") { s in keys.append((copy.bytes(s, 0), copy.bytes(s, 1))) }
        } catch { throw FirefoxImportError.schemaMismatch("key4.db") }
        guard !globalSalt.isEmpty, let checkDER = DER.parse(check) else { throw FirefoxImportError.schemaMismatch("key4.db") }
        var clear = (try? FirefoxCrypto.decryptPBE(checkDER, globalSalt: globalSalt, primaryPassword: primaryPassword)) ?? []
        defer { zeroSecretBytes(&clear) }
        guard clear.starts(with: FirefoxCrypto.passwordCheck) else { throw FirefoxImportError.primaryPasswordRequired }
        guard let entry = keys.first(where: { $0.a102 == FirefoxCrypto.sdrKeyID }), let keyDER = DER.parse(entry.a11),
              let key = try? FirefoxCrypto.decryptPBE(keyDER, globalSalt: globalSalt, primaryPassword: primaryPassword),
              key.count >= 24 else { throw FirefoxImportError.schemaMismatch("key4.db") }
        return key
    }
}
