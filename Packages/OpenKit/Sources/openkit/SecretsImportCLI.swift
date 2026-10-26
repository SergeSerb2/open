import Foundation
import OpenImport
import Darwin

private let secretsImportUsage = "usage: openkit import-arc-secrets --arc-user-data DIR [--profile NAME] --dry-run [--allow-keychain-access] [--out-manifest PATH]"

func runImportArcSecrets(args: [String]) {
    let options: ImportCLIArguments
    do {
        options = try ImportCLIArguments(args, values: ["--arc-user-data", "--profile", "--out-manifest"], flags: ["--dry-run", "--allow-keychain-access"])
    } catch { importCLIError(secretsImportUsage, code: 2) }
    guard options.flags.contains("--dry-run") else {
        importCLIError("error: secret storage waits for the engine. Use --dry-run.", code: 3)
    }
    let profile = importCLIProfile(options)
    let reader = ArcSecretsReader(profileDirectory: profile)
    do {
        let counts = try reader.countOnly()
        let extensions = try ArcExtensionsReader(profileDirectory: profile).read()
        print("secrets import (dry-run):")
        print("  profile=\(options.profile)")
        print("  logins rows=\(counts.loginRows) blacklisted=\(counts.loginsBlacklisted)")
        print("  cookies rows=\(counts.cookieRows)")
        print("  addresses rows=\(counts.addressRows) cards rows=\(counts.cardRows) keywords rows=\(counts.keywordRows)")
        var matches = true
        if options.flags.contains("--allow-keychain-access") {
            let consent = SecretsImportConsent.grantedByUser(reason: "CLI --allow-keychain-access")
            print("macOS may ask for Keychain access. Choose Allow to continue.")
            fflush(stdout)
            let pair = try probeChromiumKeychainPair(consent: consent)
            print("  keychain: service=\(pair.service) found")
            let report: ArcSecretsReadReport
            do {
                var password = try fetchKeychainPassword(service: pair.service, account: pair.account, consent: consent)
                defer { zeroSecretBytes(&password) }
                var key = deriveChromiumKey(passwordBytes: password)
                zeroSecretBytes(&password)
                defer { zeroSecretBytes(&key) }
                report = try reader.validateWithKey(key, consent: consent)
            }
            print("  logins decrypt ok=\(report.loginsDecryptOK) failed=\(report.loginsDecryptFailed) invalidTime=\(report.loginsInvalidTime)")
            print("  cookies decrypt ok=\(report.cookiesDecryptOK) failed=\(report.cookiesDecryptFailed) expired=\(report.cookiesExpired) invalidTime=\(report.cookiesInvalidTime) legacyNoHashPrefix=\(report.legacyNoHashPrefix)")
            print("  cards decrypt ok=\(report.cardsDecryptOK) failed=\(report.cardsDecryptFailed)")
            print("  badPrefix=\(report.badPrefix) addressesInvalidTime=\(report.addressesInvalidTime) autofillInvalidTime=\(report.autofillInvalidTime)")
            let logins = report.loginsDecryptOK + report.loginsDecryptFailed + report.loginsBlacklisted + report.loginsInvalidTime
            let cookies = report.cookiesDecryptOK + report.cookiesDecryptFailed + report.cookiesExpired + report.cookiesInvalidTime
            let loginOK = logins == report.loginRows, cookieOK = cookies == report.cookieRows
            let cardOK = report.cardsDecryptOK + report.cardsDecryptFailed == report.cardRows
            print("  check logins: ok+failed+blacklisted+invalidTime=\(logins) rows=\(report.loginRows) \(loginOK ? "OK" : "MISMATCH")")
            print("  check cookies: ok+failed+expired+invalidTime=\(cookies) rows=\(report.cookieRows) \(cookieOK ? "OK" : "MISMATCH")")
            print("  check cards: ok+failed=\(report.cardsDecryptOK + report.cardsDecryptFailed) rows=\(report.cardRows) \(cardOK ? "OK" : "MISMATCH")")
            matches = loginOK && cookieOK && cardOK
        } else {
            print("  keychain: not requested")
        }
        print("  stored=0 (engine writer pending)")
        print("extensions:")
        let summary = extensions.report
        print("  total=\(summary.totalRecords) internal=\(summary.internalRecords) reinstall candidates=\(summary.reinstallCandidates) missingManifest=\(summary.missingManifest)")
        if let path = options.values["--out-manifest"] {
            let destination = URL(fileURLWithPath: path)
            let arcRoot = URL(fileURLWithPath: options.values["--arc-user-data"]!)
            guard !importPath(destination, isWithin: arcRoot),
                  !importPath(destination, isWithin: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc")),
                  manifestOutsideRepository(destination) else {
                importCLIError("error: manifest must be outside Arc data and the repository (except .re).", code: 2)
            }
            let ids = extensions.records.filter { !$0.isInternal }.map(\.extensionID)
            try writeExtensionManifest(ids, to: destination)
            // The path can contain personal text. Do not echo it.
            print("manifest: wrote \(ids.count) ids")
        }
        if !matches { exit(1) }
    } catch ChromiumCryptoError.keychainItemNotFound {
        importCLIError("error: Arc Safe Storage Keychain item not found.", code: 3)
    } catch ChromiumCryptoError.keychainAccessDenied {
        importCLIError("error: Keychain access denied. No secret data read.", code: 3)
    } catch ChromiumCryptoError.keychainFailed {
        importCLIError("error: Keychain access failed. No secret data read.", code: 3)
    } catch ArcSecretsImportError.missingFiles {
        importCLIError("error: no secrets SQLite files found in profile \(options.profile).", code: 4)
    } catch {
        importCLIError("error: source or manifest could not be read or written. No secrets stored.", code: 4)
    }
}

private func manifestOutsideRepository(_ destination: URL) -> Bool {
    let fm = FileManager.default
    var directory = destination.deletingLastPathComponent().resolvingSymlinksInPath()
    while directory.path != "/" {
        if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            return importPath(destination, isWithin: directory.appendingPathComponent(".re"))
        }
        directory.deleteLastPathComponent()
    }
    return true
}

private func writeExtensionManifest(_ ids: [String], to destination: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["candidates": ids], options: [.sortedKeys])
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".open-manifest-" + UUID().uuidString)
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
    try data.withUnsafeBytes { buffer in
        var written = 0
        while written < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
            written += count
        }
    }
    guard fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
}
