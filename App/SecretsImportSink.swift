import Foundation
import OpenEngine
import OpenImport
import OpenModel

/// One destination Profile. Only this adapter translates import records into
/// OpenEngine objects; neither OpenImport nor Settings imports engine types.
@MainActor
final class AppSecretsImportSink: OpenImport.SecretsImportSink {
  let openProfileID: UUID?
  private var context: OEBrowserContext?
  private var cookiesFinished: (@MainActor () -> Void)?
  private var retired = false
  private var pendingWrites = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var reloaded = false
  #if OPEN_AUTOMATION
  var checkpoint: (@MainActor (String) async throws -> Void)?
  #endif

  init(profileID: ProfileID, context: OEBrowserContext, cookiesFinished: @escaping @MainActor () -> Void) {
    openProfileID = profileID.rawValue
    self.context = context; self.cookiesFinished = cookiesFinished
  }

  private func checkBatch(_ count: Int) throws {
    // The reader also bounds each row to 64 KiB and each field to 16 KiB.
    // At most 16 MiB of payload is copied for a 256-row engine batch; each
    // secret-buffer allocation is at most 16 KiB (well below PA's ceiling).
    guard count <= 256 else { throw ArcSecretsImportError.inputLimit }
    guard !retired, context != nil else { throw CancellationError() }
    try Task.checkCancellation()
  }

  func retire() async {
    retired = true
    context = nil; cookiesFinished = nil
    #if OPEN_AUTOMATION
    checkpoint = nil
    #endif
    if pendingWrites > 0 {
      await withCheckedContinuation { drainWaiters.append($0) }
    }
  }

  private func bytes(_ value: borrowing [UInt8]) -> NSMutableData {
    value.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
  }

  private func write(_ operation: (OEBrowserContext, @escaping @Sendable (OEImportResult?, (any Error)?) -> Void) -> Void) async throws -> SecretsWriteResult {
    try checkBatch(0)
    guard let context else { throw CancellationError() }
    pendingWrites += 1
    defer {
      pendingWrites -= 1
      if pendingWrites == 0 {
        let waiters = drainWaiters; drainWaiters = []
        for waiter in waiters { waiter.resume() }
      }
    }
    let result: OEImportResult = try await withCheckedThrowingContinuation { continuation in
      operation(context) { result, error in
        if let error { continuation.resume(throwing: error) }
        else if let result { continuation.resume(returning: result) }
        else { continuation.resume(throwing: ArcSecretsImportError.invalidSinkResult) }
      }
    }
    try checkBatch(0)
    return SecretsWriteResult(added: result.added, existing: result.existing, failed: result.failed)
  }

  func importLogins(_ batch: borrowing [ImportedLoginRecord]) async throws -> SecretsWriteResult {
    try checkBatch(batch.count)
    var buffers: [NSMutableData] = []
    defer { for buffer in buffers { buffer.resetBytes(in: NSRange(location: 0, length: buffer.length)) } }
    let records = batch.map { row in
      let password = bytes(row.passwordBytes), note = bytes(row.noteBytes)
      buffers += [password, note]
      return OEImportedLogin(signonRealm: row.signonRealm, originURL: row.originURLString,
        actionURL: row.actionURLString, usernameElement: row.usernameElement, username: row.username,
        passwordElement: row.passwordElement, password: password, scheme: row.scheme,
        blockedByUser: row.isBlacklisted, dateCreated: row.dateCreated, dateLastUsed: row.dateLastUsed,
        datePasswordModified: row.datePasswordModified, timesUsed: row.timesUsed, note: note)
    }
    return try await write { $0.import(records, completion: $1) }
  }

  func importAddresses(_ batch: borrowing [ImportedAddressRecord]) async throws -> SecretsWriteResult {
    try checkBatch(batch.count)
    #if OPEN_AUTOMATION
    try await checkpoint?("after-logins") // Importer has committed the logins ledger step.
    #endif
    try checkBatch(batch.count)
    let records = batch.map { row in
      OEImportedAddress(guid: row.guid,
        fields: Dictionary(uniqueKeysWithValues: row.fields.map { (NSNumber(value: $0.key), $0.value) }),
        verificationStatuses: Dictionary(uniqueKeysWithValues: row.verificationStatuses.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) }),
        useCount: row.useCount, use: row.useDate, dateModified: row.dateModified, languageCode: row.languageCode)
    }
    return try await write { $0.importAddresses(records, completion: $1) }
  }

  func importCards(_ batch: borrowing [ImportedCardRecord]) async throws -> SecretsWriteResult {
    try checkBatch(batch.count)
    var buffers: [NSMutableData] = []
    defer { for buffer in buffers { buffer.resetBytes(in: NSRange(location: 0, length: buffer.length)) } }
    let records = batch.map { row in
      let number = bytes(row.numberBytes); buffers.append(number)
      return OEImportedCard(guid: row.guid, nameOnCard: row.nameOnCard,
        expirationMonth: row.expirationMonth, expirationYear: row.expirationYear,
        number: number, nickname: row.nickname, useCount: row.useCount, use: row.useDate)
    }
    return try await write { $0.import(records, completion: $1) }
  }

  func importCookies(_ batch: borrowing [ImportedCookieRecord]) async throws -> SecretsWriteResult {
    try checkBatch(batch.count)
    var buffers: [NSMutableData] = []
    defer { for buffer in buffers { buffer.resetBytes(in: NSRange(location: 0, length: buffer.length)) } }
    let records = batch.map { row in
      let value = bytes(row.valueBytes); buffers.append(value)
      return OEImportedCookie(name: row.name, value: value, domain: row.hostKey, path: row.path,
        creation: row.creation, expiration: row.expiresUTC, lastAccess: row.lastAccess,
        lastUpdate: row.lastUpdate, secure: row.isSecure, httpOnly: row.isHTTPOnly,
        sameSite: row.sameSite, priority: row.priority, sourceScheme: row.sourceScheme,
        sourcePort: row.sourcePort, topFrameSiteKey: row.topFrameSiteKey,
        hasCrossSiteAncestor: row.hasCrossSiteAncestor)
    }
    #if OPEN_AUTOMATION
    if checkpoint != nil, records.count > 1 {
      // Two actual durable engine writes let I-6 kill with a partial cookie
      // step. The ledger still says pending until this whole call returns.
      let split = records.count / 2
      let first = try await write { $0.import(Array(records[..<split]), completion: $1) }
      try await checkpoint?("during-cookies")
      let second = try await write { $0.import(Array(records[split...]), completion: $1) }
      return .init(added: first.added + second.added, existing: first.existing + second.existing, failed: first.failed + second.failed)
    }
    #endif
    return try await write { $0.import(records, completion: $1) }
  }

  func didFinishCookies() async {
    guard !retired, !Task.isCancelled, !reloaded else { return }
    reloaded = true; cookiesFinished?()
  }
}
