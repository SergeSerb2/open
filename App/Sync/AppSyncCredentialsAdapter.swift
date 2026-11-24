import Foundation
import OpenEngine
import OpenImport
import OpenModel
import OpenStore
import OpenSync

/// Decrypted rows of one Profile. Built and used only for one sync pass.
struct SyncProfileSecrets: Sendable {
  var logins: [SyncedLoginRecord] = []
  var addresses: [SyncedAddressRecord] = []
  var cards: [SyncedCardRecord] = []
}

struct SyncSecretsReadResult: Sendable {
  var byProfile: [UUID: SyncProfileSecrets] = [:]
  var failed: Set<UUID> = []
  var warnings: [String] = []
}

/// `credentials.profile`: autofill preferences from the engine context, and the saved logins,
/// addresses and cards read from the engine's own `Login Data` / `Web Data` files.
extension AppSyncDataAdapter {
  static let mockSecretsArgument = "--open-allow-mock-keychain-secrets"
  static let unsignedSecretsWarning = "Passwords and cards sync requires a signed Open build (or --open-allow-mock-keychain-secrets)."
  /// The engine's Keychain item (`OEEngine` default: "Open Safe Storage" / "Open").
  nonisolated static let engineKeychainService = "Open Safe Storage"
  nonisolated static let engineKeychainAccount = "Open"

  /// Raw secrets may be read and written: a real Keychain key, or the mock key with the explicit
  /// automation switch (the engine then accepts fixture records only).
  private var secretsAllowed: Bool {
    !OEEngine.shared.usesMockKeychain || ProcessInfo.processInfo.arguments.contains(Self.mockSecretsArgument)
  }

  func collectCredentials() async -> SyncBundlePart {
    var part = SyncBundlePart()
    guard app.engineReady, !app.shutdownPrepared else { return part }
    var contexts: [(profile: Profile, context: OEBrowserContext)] = []
    var complete = true
    for profile in app.model.profiles {
      if let context = existingContext(for: profile) { contexts.append((profile, context)) } else { complete = false }
    }
    if !secretsAllowed {
      // Never upload an empty credential list from an unsigned mock-keychain build;
      // doing so would overwrite passwords synced from a signed Mac.
      part.warnings.append(Self.unsignedSecretsWarning)
      return part
    }
    let inputs = contexts.map { ($0.profile.id.rawValue, app.directories.engineDirectory(for: $0.profile)) }
    let mock = OEEngine.shared.usesMockKeychain
    // Consent: the user signed in to Open Sync with "Passwords, Autofill & Site Permissions" on.
    let consent = SecretsImportConsent.grantedByUser(reason: "Open Account Sync")
    // The key is derived, used and zeroed inside this task; it never crosses an actor boundary.
    let secrets = await Task.detached(priority: .utility) {
      Self.readSecrets(profiles: inputs, mock: mock, consent: consent)
    }.value
    part.warnings += secrets.warnings
    for (profile, context) in contexts {
      let id = profile.id.rawValue
      if secrets.failed.contains(id) {
        // Never replace the cloud copy with an empty list because this Mac could not decrypt.
        complete = false; continue
      }
      let rows = secrets.byProfile[id] ?? SyncProfileSecrets()
      let dto = SyncedCredentialsProfileDTO(
        profileID: id, passwordSavingEnabled: context.passwordSavingEnabled,
        creditCardsSavingEnabled: context.creditCardsSavingEnabled,
        creditCardReauthenticationEnabled: context.creditCardReauthenticationEnabled,
        addressesSavingEnabled: context.addressesSavingEnabled,
        logins: rows.logins, addresses: rows.addresses, cards: rows.cards)
      do {
        part.records.append(try SyncLocalRecord(collection: .credentialsProfile, recordId: id.uuidString, value: dto))
      } catch { complete = false }
    }
    if complete { part.complete.insert(.credentialsProfile) }
    return part
  }

  /// Reads every Profile's secrets with one derived key. Every decrypted byte buffer is zeroed.
  nonisolated static func readSecrets(profiles: [(UUID, URL)], mock: Bool, consent: SecretsImportConsent) -> SyncSecretsReadResult {
    var result = SyncSecretsReadResult()
    var password: [UInt8]
    if mock {
      password = Array("peanuts".utf8)
    } else {
      do { password = try fetchKeychainPassword(service: engineKeychainService, account: engineKeychainAccount, consent: consent) }
      catch {
        result.failed = Set(profiles.map(\.0))
        result.warnings.append("Passwords and cards were not synced: Open's Keychain item could not be read.")
        return result
      }
    }
    var key = deriveChromiumKey(passwordBytes: password)
    zeroSecretBytes(&password)
    defer { zeroSecretBytes(&key) }
    guard key.count == 16 else {
      result.failed = Set(profiles.map(\.0))
      result.warnings.append("Passwords and cards were not synced: the encryption key could not be derived.")
      return result
    }
    for (id, directory) in profiles {
      do { result.byProfile[id] = try readProfileSecrets(directory: directory, key: key, consent: consent) }
      catch {
        result.failed.insert(id)
        result.warnings.append("Saved passwords of one Profile could not be read for sync.")
      }
    }
    return result
  }

  private nonisolated static func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

  private nonisolated static func readProfileSecrets(directory: URL, key: [UInt8], consent: SecretsImportConsent) throws -> SyncProfileSecrets {
    var secrets = SyncProfileSecrets()
    if let reader = try ArcSecretsBatchReader(profileDirectory: directory, file: .logins, key: key, consent: consent) {
      while var batch = try reader.nextLogins() {
        defer { for index in batch.indices { batch[index].zeroSecrets() } }
        for row in batch {
          secrets.logins.append(SyncedLoginRecord(
            originURL: row.originURLString, actionURL: row.actionURLString, signonRealm: row.signonRealm,
            username: row.username, password: string(row.passwordBytes), usernameElement: row.usernameElement,
            passwordElement: row.passwordElement, scheme: row.scheme, isBlacklisted: row.isBlacklisted,
            timesUsed: row.timesUsed, dateCreated: row.dateCreated.timeIntervalSince1970,
            dateLastUsed: row.dateLastUsed?.timeIntervalSince1970,
            datePasswordModified: row.datePasswordModified?.timeIntervalSince1970,
            note: row.noteBytes.isEmpty ? nil : string(row.noteBytes)))
        }
      }
    }
    if let reader = try ArcSecretsBatchReader(profileDirectory: directory, file: .webData, key: key, consent: consent) {
      while var batch = try reader.nextAddresses() {
        defer { for index in batch.indices { batch[index].zeroSecrets() } }
        for row in batch {
          secrets.addresses.append(SyncedAddressRecord(
            guid: row.guid, fields: Dictionary(uniqueKeysWithValues: row.fields.map { (String($0.key), $0.value) }),
            useCount: row.useCount, useDate: row.useDate.timeIntervalSince1970,
            dateModified: row.dateModified?.timeIntervalSince1970, languageCode: row.languageCode))
        }
      }
      while var batch = try reader.nextCards() {
        defer { for index in batch.indices { batch[index].zeroSecrets() } }
        for row in batch {
          secrets.cards.append(SyncedCardRecord(
            guid: row.guid, nameOnCard: row.nameOnCard, expirationMonth: row.expirationMonth,
            expirationYear: row.expirationYear, number: string(row.numberBytes), nickname: row.nickname,
            useCount: row.useCount, useDate: row.useDate?.timeIntervalSince1970))
        }
      }
    }
    return secrets
  }

  // MARK: Apply

  func applyCredentials(_ bundle: SyncRemoteBundle) async -> [String] {
    var warnings: [String] = []
    var records: [(Profile, SyncedCredentialsProfileDTO)] = []
    for record in bundle.records(in: .credentialsProfile) {
      guard let uuid = UUID(uuidString: record.recordId), let profile = app.model.profile(id: ProfileID(rawValue: uuid)) else { continue }
      do { if let dto = try record.decode(SyncedCredentialsProfileDTO.self) { records.append((profile, dto)) } }
      catch { warnings.append(error.localizedDescription) }
    }
    for (profile, dto) in records {
      guard let context = liveContext(for: profile), !context.isEphemeral else {
        warnings.append("Passwords and autofill of the Profile “\(profile.name)” were not updated: the browser engine is not ready."); continue
      }
      if context.passwordSavingEnabled != dto.passwordSavingEnabled { context.passwordSavingEnabled = dto.passwordSavingEnabled }
      if context.creditCardsSavingEnabled != dto.creditCardsSavingEnabled { context.creditCardsSavingEnabled = dto.creditCardsSavingEnabled }
      if context.creditCardReauthenticationEnabled != dto.creditCardReauthenticationEnabled {
        context.creditCardReauthenticationEnabled = dto.creditCardReauthenticationEnabled
      }
      if context.addressesSavingEnabled != dto.addressesSavingEnabled { context.addressesSavingEnabled = dto.addressesSavingEnabled }
      guard !dto.logins.isEmpty || !dto.addresses.isEmpty || !dto.cards.isEmpty else { continue }
      guard secretsAllowed else { warnings.append(Self.unsignedSecretsWarning); continue }
      guard OEEngine.shared.supportsSecretsImport else {
        warnings.append("Passwords and cards could not be saved: this browser engine cannot import them."); continue
      }
      do {
        try await importLogins(dto.logins, into: context)
        try await importAddresses(dto.addresses, into: context)
        try await importCards(dto.cards, into: context)
      } catch {
        warnings.append("Some passwords or cards of the Profile “\(profile.name)” could not be saved.")
      }
      // No reload of open pages: a background sync must never discard form input or end a call.
      // Autofill reads the new data on the next form focus or navigation.
    }
    return warnings
  }

  private static func buffer(_ text: String) -> NSMutableData {
    var bytes = Array(text.utf8)
    defer { zeroSecretBytes(&bytes) }
    return bytes.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
  }

  private static func zero(_ buffers: [NSMutableData]) {
    for buffer in buffers { buffer.resetBytes(in: NSRange(location: 0, length: buffer.length)) }
  }

  /// Runs in the engine's completion block (main thread, outside actor isolation).
  private nonisolated static func finish(_ result: OEImportResult?, _ error: (any Error)?) -> Result<Void, any Error> {
    if let error { return .failure(error) }
    if result == nil { return .failure(SyncError.storage("The browser engine returned no import result.")) }
    return .success(())
  }

  /// Engine batches hold at most 256 records (`OEBrowserContext (SecretsImport)`).
  private static func batches<T>(_ items: [T]) -> [ArraySlice<T>] {
    stride(from: 0, to: items.count, by: 256).map { items[$0..<min($0 + 256, items.count)] }
  }

  private func importLogins(_ logins: [SyncedLoginRecord], into context: OEBrowserContext) async throws {
    for chunk in Self.batches(logins) {
      var buffers: [NSMutableData] = []
      defer { Self.zero(buffers) }
      let records = chunk.map { row -> OEImportedLogin in
        let password = Self.buffer(row.password), note = Self.buffer(row.note ?? "")
        buffers += [password, note]
        return OEImportedLogin(signonRealm: row.signonRealm, originURL: row.originURL, actionURL: row.actionURL,
          usernameElement: row.usernameElement, username: row.username, passwordElement: row.passwordElement,
          password: password, scheme: row.scheme, blockedByUser: row.isBlacklisted,
          dateCreated: Date(timeIntervalSince1970: row.dateCreated),
          dateLastUsed: row.dateLastUsed.map { Date(timeIntervalSince1970: $0) },
          datePasswordModified: row.datePasswordModified.map { Date(timeIntervalSince1970: $0) },
          timesUsed: row.timesUsed, note: note)
      }
      let outcome: Result<Void, any Error> = await withCheckedContinuation { continuation in
        context.import(records) { result, error in continuation.resume(returning: Self.finish(result, error)) }
      }
      try outcome.get()
    }
  }

  private func importAddresses(_ addresses: [SyncedAddressRecord], into context: OEBrowserContext) async throws {
    for chunk in Self.batches(addresses) {
      let records = chunk.map { row -> OEImportedAddress in
        var fields: [NSNumber: String] = [:]
        for (key, value) in row.fields { if let type = Int(key) { fields[NSNumber(value: type)] = value } }
        return OEImportedAddress(guid: row.guid, fields: fields, verificationStatuses: [:], useCount: row.useCount,
          use: Date(timeIntervalSince1970: row.useDate ?? Date().timeIntervalSince1970),
          dateModified: row.dateModified.map { Date(timeIntervalSince1970: $0) }, languageCode: row.languageCode)
      }
      let outcome: Result<Void, any Error> = await withCheckedContinuation { continuation in
        context.importAddresses(records) { result, error in continuation.resume(returning: Self.finish(result, error)) }
      }
      try outcome.get()
    }
  }

  private func importCards(_ cards: [SyncedCardRecord], into context: OEBrowserContext) async throws {
    for chunk in Self.batches(cards) {
      var buffers: [NSMutableData] = []
      defer { Self.zero(buffers) }
      let records = chunk.map { row -> OEImportedCard in
        let number = Self.buffer(row.number); buffers.append(number)
        return OEImportedCard(guid: row.guid, nameOnCard: row.nameOnCard, expirationMonth: row.expirationMonth,
          expirationYear: row.expirationYear, number: number, nickname: row.nickname, useCount: row.useCount,
          use: row.useDate.map { Date(timeIntervalSince1970: $0) })
      }
      let outcome: Result<Void, any Error> = await withCheckedContinuation { continuation in
        context.import(records) { result, error in continuation.resume(returning: Self.finish(result, error)) }
      }
      try outcome.get()
    }
  }
}
