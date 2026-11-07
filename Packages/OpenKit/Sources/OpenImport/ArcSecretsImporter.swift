import Foundation

/// Generated inputs only; no caller-supplied source data enters these checks.
public enum SyntheticSecretsScenario: Sendable { case standard, batchBoundary, fieldAtLimit, fieldOverLimit, empty, nonlocalAddress, invalidLogin }

/// Copy what is needed before returning. Complete only after the writes are
/// durable (LoginDatabase completion, web-data read barrier, cookie flush).
/// Existing Open records win: login realm/username (realm/blocked for blocked
/// sites), cookie name/domain/path/partition key, address/card GUID then content.
@MainActor public protocol SecretsImportSink: AnyObject {
    /// Optional opaque Open ProfileID for the counts-only ledger.
    var openProfileID: UUID? { get }
    func importLogins(_ batch: borrowing [ImportedLoginRecord]) async throws -> SecretsWriteResult
    func importAddresses(_ batch: borrowing [ImportedAddressRecord]) async throws -> SecretsWriteResult
    func importCards(_ batch: borrowing [ImportedCardRecord]) async throws -> SecretsWriteResult
    func importCookies(_ batch: borrowing [ImportedCookieRecord]) async throws -> SecretsWriteResult
}

public extension SecretsImportSink { var openProfileID: UUID? { nil } }

public struct SecretsWriteResult: Codable, Equatable, Sendable {
    public var added: Int
    public var existing: Int
    public var failed: Int
    public init(added: Int = 0, existing: Int = 0, failed: Int = 0) { self.added = added; self.existing = existing; self.failed = failed }
}

public struct SecretsImportCounts: Equatable, Sendable {
    public var added = 0
    public var existing = 0
    public var failed = 0
    public var skippedFederated = 0
    public var skippedExpired = 0
    public var unmapped = 0
    public init() {}
    var writeResult: SecretsWriteResult { .init(added: added, existing: existing, failed: failed) }
    mutating func add(_ value: SecretsWriteResult, expected: Int) throws {
        guard value.added >= 0, value.existing >= 0, value.failed >= 0,
              value.added <= expected, value.existing <= expected, value.failed <= expected,
              value.added + value.existing + value.failed == expected else { throw ArcSecretsImportError.invalidSinkResult }
        added += value.added; existing += value.existing; failed += value.failed
    }
    mutating func add(_ value: Self) {
        added += value.added; existing += value.existing; failed += value.failed
        skippedFederated += value.skippedFederated; skippedExpired += value.skippedExpired; unmapped += value.unmapped
    }
}

public struct ArcSecretsProfileCounts: Equatable, Sendable {
    public var logins = SecretsImportCounts()
    public var cookies = SecretsImportCounts()
    public var addresses = SecretsImportCounts()
    public var cards = SecretsImportCounts()
    public init() {}
    mutating func add(_ other: Self) {
        logins.add(other.logins); cookies.add(other.cookies); addresses.add(other.addresses); cards.add(other.cards)
    }
}

/// Counts only; the UI can render these lines without retaining source records.
public struct ArcSecretsImportReport: Sendable {
    public var profiles: [String: ArcSecretsProfileCounts] = [:]
    public var profileOrder: [String] = []
    public var unmappedProfiles = 0
    public var wasInterrupted = false
    public var previousRunUnfinished = false
    public var total: ArcSecretsProfileCounts { profiles.values.reduce(into: .init()) { $0.add($1) } }
    public static let unfinishedMessage = "The last import stopped before it finished. Import again to add the rest."
    public static let passkeyMessage = "Passkeys saved only in Arc stay in Arc. Sign in to those sites again to create new ones."
    public var lines: [String] {
        let counts = total
        var result = [("Passwords", counts.logins), ("Cookies", counts.cookies), ("Addresses", counts.addresses), ("Cards", counts.cards)].map {
            "\($0.0): \($0.1.added) imported, \($0.1.existing) already in Open"
        }
        let failed = counts.logins.failed + counts.cookies.failed + counts.addresses.failed + counts.cards.failed
        if failed > 0 { result.append("\(failed) couldn't be imported") }
        if previousRunUnfinished || wasInterrupted { result.append(Self.unfinishedMessage) }
        return result
    }
}

@MainActor public final class ArcSecretsImporter {
    private let arcUserData: URL
    private let ledger: SecretsImportLedger
    public init(arcUserData: URL, ledger: SecretsImportLedger) { self.arcUserData = arcUserData; self.ledger = ledger }

    public func run(key: [UInt8], consent: SecretsImportConsent, sinks: [String: SecretsImportSink]) async throws -> ArcSecretsImportReport {
        try await run(key: key, access: .user(consent), sinks: sinks)
    }

    public static func runSyntheticFixture(sinks: [String: SecretsImportSink]) async throws -> ArcSecretsImportReport {
        let fixture = try SyntheticSecretsFixture()
        return try await runSyntheticFixture(fixture, sinks: sinks, ledger: SecretsImportLedger(dataRoot: fixture.directory.appendingPathComponent("Open")))
    }

    /// Recovery verification only. Still accepts no source path, key or ciphertext.
    /// A ledger is a destination for counts, never a source of secret records.
    public static func runSyntheticFixture(sinks: [String: SecretsImportSink], ledger: SecretsImportLedger,
                                           stopAfter: SecretsImportStep?, scenario: SyntheticSecretsScenario = .standard) async throws -> ArcSecretsImportReport {
        try await runSyntheticFixture(SyntheticSecretsFixture(), sinks: sinks, ledger: ledger, stopAfter: stopAfter, scenario: scenario)
    }

    private static func runSyntheticFixture(_ fixture: SyntheticSecretsFixture, sinks: [String: SecretsImportSink],
                                            ledger: SecretsImportLedger, stopAfter: SecretsImportStep? = nil,
                                            scenario: SyntheticSecretsScenario = .standard) async throws -> ArcSecretsImportReport {
        var password = Array("mock_password".utf8)
        defer { zeroSecretBytes(&password) }
        var key = deriveChromiumKey(passwordBytes: password)
        zeroSecretBytes(&password)
        defer { zeroSecretBytes(&key) }
        try fixture.createImportProfiles(key: key)
        try fixture.apply(scenario)
        return try await ArcSecretsImporter(arcUserData: fixture.directory, ledger: ledger).run(
            key: key, access: .synthetic(fixture), sinks: sinks, stopAfter: stopAfter)
    }

    private func run(key: [UInt8], access: SecretsReadAccess, sinks: [String: SecretsImportSink],
                     stopAfter: SecretsImportStep? = nil) async throws -> ArcSecretsImportReport {
        let directories = try profileDirectories()
        var report = ArcSecretsImportReport()
        report.previousRunUnfinished = try ledger.unfinished != nil
        let mapped = directories.filter { sinks[$0] != nil }
        var ids: [String: UUID] = [:]
        for name in mapped { ids[name] = sinks[name]?.openProfileID }
        try ledger.begin(profiles: mapped, openProfiles: ids)
        for name in directories {
            try Task.checkCancellation()
            report.profileOrder.append(name)
            var counts = ArcSecretsProfileCounts()
            let directory = arcUserData.appendingPathComponent(name)
            guard let sink = sinks[name] else {
                report.unmappedProfiles += 1
                let read: ArcSecretsReadReport
                do { read = try ArcSecretsReader(profileDirectory: directory).countOnly() }
                catch ArcSecretsImportError.missingFiles { read = ArcSecretsReadReport() }
                counts.logins.unmapped = read.loginRows; counts.cookies.unmapped = read.cookieRows
                counts.addresses.unmapped = read.addressRows; counts.cards.unmapped = read.cardRows
                report.profiles[name] = counts
                continue
            }
            for step in SecretsImportStep.allCases {
                // The scope drops the private file copy before opening the next file.
                if let reader = try ArcSecretsBatchReader(profileDirectory: directory, file: step.file, key: key, access: access) {
                    switch step {
                    case .logins:
                        while var batch = try reader.nextLogins() {
                            defer { for i in batch.indices { batch[i].zeroSecrets() } }
                            if !batch.isEmpty { try counts.logins.add(await sink.importLogins(batch), expected: batch.count) }
                            for i in batch.indices { batch[i].zeroSecrets() }; batch.removeAll()
                            await Task.yield()
                        }
                        counts.logins.failed += reader.report.loginsDecryptFailed + reader.report.loginsInvalidTime
                        counts.logins.skippedFederated += reader.report.loginsFederated
                    case .webData:
                        while var batch = try reader.nextAddresses() {
                            defer { for i in batch.indices { batch[i].zeroSecrets() } }
                            if !batch.isEmpty { try counts.addresses.add(await sink.importAddresses(batch), expected: batch.count) }
                            for i in batch.indices { batch[i].zeroSecrets() }; batch.removeAll()
                            await Task.yield()
                        }
                        while var batch = try reader.nextCards() {
                            defer { for i in batch.indices { batch[i].zeroSecrets() } }
                            if !batch.isEmpty { try counts.cards.add(await sink.importCards(batch), expected: batch.count) }
                            for i in batch.indices { batch[i].zeroSecrets() }; batch.removeAll()
                            await Task.yield()
                        }
                        counts.addresses.failed += reader.report.addressesInvalidTime
                        counts.cards.failed += reader.report.cardsDecryptFailed
                    case .cookies:
                        while var batch = try reader.nextCookies() {
                            defer { for i in batch.indices { batch[i].zeroSecrets() } }
                            if !batch.isEmpty { try counts.cookies.add(await sink.importCookies(batch), expected: batch.count) }
                            for i in batch.indices { batch[i].zeroSecrets() }; batch.removeAll()
                            await Task.yield()
                        }
                        counts.cookies.failed += reader.report.cookiesDecryptFailed + reader.report.cookiesInvalidTime
                        counts.cookies.skippedExpired += reader.report.cookiesExpired
                    }
                }
                try ledger.complete(step, profile: name, counts: counts)
                report.profiles[name] = counts
                if step == stopAfter { report.wasInterrupted = true; return report }
            }
        }
        try ledger.finish()
        return report
    }

    private func profileDirectories() throws -> [String] {
        let file = arcUserData.appendingPathComponent("Local State")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw ArcSecretsImportError.inputLimit }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let profile = root["profile"] as? [String: Any], let info = profile["info_cache"] as? [String: Any],
              info.count <= 256 else { throw ArcSecretsImportError.invalidLocalState }
        let order = profile["profiles_order"] as? [String] ?? []
        guard order.count <= 256 else { throw ArcSecretsImportError.inputLimit }
        var names: [String] = []
        for name in ["Default"] + order + info.keys.sorted() where info[name] != nil && !names.contains(name) {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), name.utf8.count <= 255 else {
                throw ArcSecretsImportError.invalidLocalState
            }
            let directory = arcUserData.appendingPathComponent(name)
            guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == arcUserData.resolvingSymlinksInPath() else {
                throw ArcSecretsImportError.invalidLocalState
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue { names.append(name) }
        }
        return names
    }
}

private extension SecretsImportStep {
    var file: ArcSecretsBatchReader.File { switch self { case .logins: .logins; case .webData: .webData; case .cookies: .cookies } }
}
