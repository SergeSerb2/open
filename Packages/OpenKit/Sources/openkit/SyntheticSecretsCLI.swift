import Foundation
import OpenImport
import CryptoKit

/// Keeps only uniqueness keys and digests. It models existing-wins semantics;
/// it makes no engine-durability claim. Only generated fixtures reach this sink.
@MainActor private final class CountingSecretsSink: SecretsImportSink {
    let openProfileID: UUID? = UUID()
    private var logins: Set<[String]> = []
    private var cookies: Set<[String]> = []
    private var addressGUIDs: Set<String> = []
    private var addresses: Set<Data> = []
    private var cardGUIDs: Set<String> = []
    private var cards: Set<Data> = []
    var valid = true
    var failOnCookiesOnce = false
    var calls: [String] = []
    var loginBatchSizes: [Int] = []
    var sizes: [Int] { [logins.count, addresses.count, cards.count, cookies.count] }
    private func digest(_ parts: [String], bytes: [UInt8] = []) -> Data {
        var hash = SHA256()
        for part in parts { hash.update(data: Data(part.utf8)); hash.update(data: Data([0])) }
        hash.update(data: Data(bytes))
        return Data(hash.finalize())
    }
    private func count(_ inserted: [Bool]) -> SecretsWriteResult {
        valid = valid && inserted.count <= 256
        return .init(added: inserted.filter { $0 }.count, existing: inserted.filter { !$0 }.count)
    }
    func importLogins(_ batch: borrowing [ImportedLoginRecord]) async throws -> SecretsWriteResult {
        calls.append("logins")
        loginBatchSizes.append(batch.count)
        var result: [Bool] = []
        for index in batch.indices {
            let record = batch[index]
            valid = valid && record.usernameElement == "email" && record.passwordElement == "password" && record.scheme == 0 &&
                record.dateLastUsed != nil && record.datePasswordModified != nil && record.timesUsed == 2 &&
                (record.isBlacklisted ? record.passwordBytes.isEmpty : !record.passwordBytes.isEmpty)
            if record.username.hasSuffix("-1") { valid = valid && !record.noteBytes.isEmpty }
            result.append(logins.insert([record.signonRealm, record.isBlacklisted ? "blocked" : "login", record.isBlacklisted ? "" : record.username]).inserted)
        }
        return count(result)
    }
    func importCookies(_ batch: borrowing [ImportedCookieRecord]) async throws -> SecretsWriteResult {
        calls.append("cookies")
        var result: [Bool] = []
        for index in batch.indices {
            let record = batch[index]
            valid = valid && record.creation.timeIntervalSince1970 > 0 && record.lastAccess != nil && record.lastUpdate != nil &&
                record.sameSite == 1 && record.priority == 2 && record.sourceScheme == 2 && record.sourcePort == 443 &&
                record.isSecure && !record.valueBytes.isEmpty
            if record.name.hasSuffix("-2") { valid = valid && record.expiresUTC == nil }
            if record.name.hasSuffix("-3") { valid = valid && record.isHTTPOnly }
            if record.name.hasSuffix("-4") { valid = valid && record.topFrameSiteKey != nil && record.hasCrossSiteAncestor }
            result.append(cookies.insert([record.name, record.hostKey, record.path, record.topFrameSiteKey ?? "", String(record.hasCrossSiteAncestor)]).inserted)
        }
        let counts = count(result)
        if failOnCookiesOnce { failOnCookiesOnce = false; throw SyntheticSinkFailure.stopped }
        return counts
    }
    func importAddresses(_ batch: borrowing [ImportedAddressRecord]) async throws -> SecretsWriteResult {
        calls.append("addresses")
        var result: [Bool] = []
        for index in batch.indices {
            let record = batch[index]
            valid = valid && record.verificationStatuses == [7: 3, 30: 4] && record.fields.count == 2 && record.dateModified != nil && record.languageCode == "en" && record.useCount == 3
            let content = digest(record.fields.keys.sorted().flatMap { [String($0), record.fields[$0]!] })
            let existing = addressGUIDs.contains(record.guid) || addresses.contains(content)
            if !existing { addressGUIDs.insert(record.guid); addresses.insert(content) }
            result.append(!existing)
        }
        return count(result)
    }
    func importCards(_ batch: borrowing [ImportedCardRecord]) async throws -> SecretsWriteResult {
        calls.append("cards")
        var result: [Bool] = []
        for index in batch.indices {
            let record = batch[index]
            valid = valid && record.nickname != nil && record.useCount == 4 && record.useDate != nil && record.numberBytes.count == 16
            let content = digest([record.nameOnCard, String(record.expirationMonth), String(record.expirationYear)], bytes: record.numberBytes)
            let existing = cardGUIDs.contains(record.guid) || cards.contains(content)
            if !existing { cardGUIDs.insert(record.guid); cards.insert(content) }
            result.append(!existing)
        }
        return count(result)
    }
}

private enum SyntheticSinkFailure: Error { case stopped }

@MainActor func runSyntheticSecretsFixture(args: [String]) async throws {
    let stop: SecretsImportStep?
    if args.isEmpty { stop = nil }
    else if args.count == 2, args[0] == "--stop-after", let value = SecretsImportStep(rawValue: args[1]) { stop = value }
    else { importCLIError("usage: openkit verify-secrets-fixture [--stop-after logins|webData|cookies]", code: 2) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-secrets-ledger-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = SecretsImportLedger(dataRoot: root)
    let firstSink = CountingSecretsSink(), secondSink = CountingSecretsSink()
    let sinks: [String: SecretsImportSink] = ["Default": firstSink, "Profile 1": secondSink]
    var passed = true
    func row(_ label: String, _ value: Bool) { print("\(value ? "PASS" : "FAIL") \(label)"); passed = passed && value }
    func printCounts(_ report: ArcSecretsImportReport, run: Int) {
        for (profileIndex, name) in ["Default", "Profile 1"].enumerated() {
            let counts = report.profiles[name] ?? ArcSecretsProfileCounts()
            for (kind, value) in [("logins", counts.logins), ("addresses", counts.addresses), ("cards", counts.cards), ("cookies", counts.cookies)] {
                print("run=\(run) profile=\(profileIndex + 1) kind=\(kind) added=\(value.added) existing=\(value.existing) failed=\(value.failed) skippedFederated=\(value.skippedFederated) skippedExpired=\(value.skippedExpired) unmapped=\(value.unmapped)")
            }
        }
    }
    print("synthetic secrets; Keychain not requested")
    let first = try await ArcSecretsImporter.runSyntheticFixture(sinks: sinks, ledger: ledger, stopAfter: stop)
    printCounts(first, run: 1)
    let firstLedger = try ledger.read()
    let unfinished = try ledger.unfinished
    if let stop {
        let entry = firstLedger?.profiles["Default"]
        let states = [entry?.logins.state, entry?.webData.state, entry?.cookies.state]
        let count = SecretsImportStep.allCases.firstIndex(of: stop)! + 1
        row("unfinished ledger after durable step", first.wasInterrupted && unfinished != nil && states.prefix(count).allSatisfy { $0 == "done" } && states.dropFirst(count).allSatisfy { $0 == "pending" })
    } else {
        row("first run counts", first.profiles.count == 2 && first.profiles.values.allSatisfy {
            $0.logins.added == 4 && $0.logins.skippedFederated == 1 && $0.cookies.added == 4 && $0.cookies.skippedExpired == 1 && $0.addresses.added == 1 && $0.cards.added == 1
        })
        row("finished ledger", unfinished == nil && firstLedger?.finished != nil)
    }
    let second = try await ArcSecretsImporter.runSyntheticFixture(sinks: sinks, ledger: ledger, stopAfter: nil)
    printCounts(second, run: 2)
    let secondLedger = try ledger.read()
    row("second run exact counts", ["Default", "Profile 1"].allSatisfy { name in
        let before = first.profiles[name] ?? ArcSecretsProfileCounts()
        guard let after = second.profiles[name] else { return false }
        return zip([before.logins, before.addresses, before.cards, before.cookies],
                   zip([after.logins, after.addresses, after.cards, after.cookies], [4, 1, 1, 4])).allSatisfy {
            $0.1.0.added == $0.1.1 - $0.0.added && $0.1.0.existing == $0.0.added
        }
    })
    row("new run ID", firstLedger?.runID != secondLedger?.runID)
    row("recovery notice", second.previousRunUnfinished == (stop != nil))
    row("final counts without duplicates", firstSink.sizes == [4, 1, 1, 4] && secondSink.sizes == [4, 1, 1, 4])
    row("metadata and batch bounds", firstSink.valid && secondSink.valid)
    row("skip and failure counts", second.profiles.count == 2 && second.profiles.values.allSatisfy {
        $0.logins.skippedFederated == 1 && $0.cookies.skippedExpired == 1 && $0.logins.failed + $0.cookies.failed + $0.addresses.failed + $0.cards.failed == 0
    })
    row("steps rerun in order", firstSink.calls.suffix(4) == ["logins", "addresses", "cards", "cookies"] && secondSink.calls.suffix(4) == ["logins", "addresses", "cards", "cookies"])
    if stop == nil {
        row("second run adds zero", second.profiles.values.allSatisfy { $0.logins.added + $0.addresses.added + $0.cards.added + $0.cookies.added == 0 })
    }
    row("ledger complete", try ledger.unfinished == nil && secondLedger?.profiles.values.allSatisfy { $0.logins.state == "done" && $0.webData.state == "done" && $0.cookies.state == "done" } == true)
    let mode = try FileManager.default.attributesOfItem(atPath: ledger.fileURL.path)[.posixPermissions] as? Int
    row("ledger mode 0600", mode == 0o600)
    // Preserve the older malformed-blob, legacy-schema and redaction coverage.
    let legacy = try verifySyntheticSecretsImport()
    let r = legacy.report
    row("legacy crypto and redaction", legacy.knownKeyMatches && legacy.hashValuesMatch && legacy.redactedRecordKinds == 4 && r.loginsDecryptFailed == 5 && r.badPrefix == 5 && r.cardsDecryptFailed == 3 && r.cookiesExpired == 1)
    row("report copy", second.lines.count == (stop == nil ? 4 : 5) && ArcSecretsImportReport.passkeyMessage.count > 0)
    let unmapped = try await ArcSecretsImporter.runSyntheticFixture(sinks: [:])
    row("unmapped profiles", unmapped.unmappedProfiles == 2 && unmapped.profiles.values.allSatisfy {
        $0.logins.unmapped == 5 && $0.cookies.unmapped == 5 && $0.addresses.unmapped == 1 && $0.cards.unmapped == 1
    })
    let failureSink = CountingSecretsSink()
    failureSink.failOnCookiesOnce = true
    var threw = false
    do {
        _ = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": failureSink], ledger: ledger, stopAfter: nil)
    } catch SyntheticSinkFailure.stopped { threw = true }
    let pending = try ledger.unfinished
    row("sink failure keeps unfinished step", threw && pending?.profiles["Default"]?.cookies.state == "pending" && pending?.profiles["Default"]?.webData.state == "done")
    let recovered = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": failureSink], ledger: ledger, stopAfter: nil)
    row("sink failure recovery", recovered.previousRunUnfinished && failureSink.sizes == [4, 1, 1, 4] && recovered.total.cookies.added == 0 && recovered.total.cookies.existing == 4)
    let boundarySink = CountingSecretsSink()
    let boundary = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": boundarySink], ledger: ledger, stopAfter: nil, scenario: .batchBoundary)
    row("bounded batches across 256 source rows", boundary.total.logins.added == 257 && boundarySink.loginBatchSizes == [255, 2] && boundarySink.valid)
    let atLimit = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": CountingSecretsSink()], ledger: ledger, stopAfter: nil, scenario: .fieldAtLimit)
    row("field at 16384-byte limit", atLimit.total.logins.added == 4)
    var refused = false
    do {
        _ = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": CountingSecretsSink()], ledger: ledger, stopAfter: nil, scenario: .fieldOverLimit)
    } catch ArcSecretsImportError.inputLimit { refused = true }
    row("field over limit refused", refused)
    let emptySink = CountingSecretsSink()
    let empty = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": emptySink], ledger: ledger, stopAfter: nil, scenario: .empty)
    let emptyUnfinished = try ledger.unfinished
    row("empty source", empty.total == ArcSecretsProfileCounts() && emptySink.calls.isEmpty && emptyUnfinished == nil)
    let local = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": CountingSecretsSink()], ledger: ledger, stopAfter: nil, scenario: .nonlocalAddress)
    row("only local addresses", local.total.addresses.added == 1)
    let invalid = try await ArcSecretsImporter.runSyntheticFixture(sinks: ["Default": CountingSecretsSink()], ledger: ledger, stopAfter: nil, scenario: .invalidLogin)
    row("failed record and report text", invalid.total.logins.added == 3 && invalid.total.logins.failed == 1 && invalid.lines.contains("1 couldn't be imported"))
    if !passed { exit(1) }
}
