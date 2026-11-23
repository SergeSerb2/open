import Foundation
import OpenEngine
import OpenImport
import OpenModel
import OpenSettings

extension AppImportRunner {
  func retireProfile(_ profileID: ProfileID, directory: String) async {
    retiredSecretsProfiles.insert(profileID)
    retiredSecretsDirectories.insert(directory.lowercased())
    // Cancel the whole run, including Profiles not yet reached by the reader.
    // Await it so no pending step can update the ledger after we return.
    let task = secretsTaskProfiles.contains(profileID) ? secretsTask : nil
    task?.cancel()
    let sink = secretsSinks.removeValue(forKey: profileID)
    await sink?.retire()
    _ = await task?.result
  }

  func runSecretsBatch(sinks: [String: any OpenImport.SecretsImportSink],
                       operation: @escaping @MainActor () async throws -> ArcSecretsImportReport) async throws -> ArcSecretsImportReport {
    try Task.checkCancellation()
    guard secretsTask == nil else { throw ArcSecretsImportError.invalidSinkResult }
    let profiles = Set(sinks.values.compactMap { $0.openProfileID.map(ProfileID.init(rawValue:)) })
    guard retiredSecretsProfiles.isDisjoint(with: profiles) else { throw CancellationError() }
    let task = Task { @MainActor in try await operation() }
    secretsTask = task; secretsTaskProfiles = profiles
    defer { secretsTask = nil; secretsTaskProfiles = [] }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
  }

  var canImportPasswordsAndCookies: Bool {
    #if OPEN_AUTOMATION
    if Self.syntheticSecretsScenario != nil && OEEngine.shared.usesMockKeychain { return OEEngine.shared.supportsSecretsImport }
    #endif
    return OEEngine.shared.supportsSecretsImport && !OEEngine.shared.usesMockKeychain
  }

  #if OPEN_AUTOMATION
  /// e2e only (`OPEN_AUTOMATION_SYNTHETIC_SECRETS=<scenario>` with the mock key): the consented import reads the
  /// generated fixture instead of the Keychain, so the real runner, report and views run with no system prompt.
  static var syntheticSecretsScenario: SyntheticSecretsScenario? {
    ProcessInfo.processInfo.environment["OPEN_AUTOMATION_SYNTHETIC_SECRETS"].flatMap(SyntheticSecretsScenario.init(rawValue:))
  }

  /// Arc and Chromium-browser imports both stop here before any Keychain call while the seam is on.
  func syntheticSecretsOutcome(sinks: [String: any OpenImport.SecretsImportSink]) async throws -> ImportOutcome? {
    guard let scenario = Self.syntheticSecretsScenario, OEEngine.shared.usesMockKeychain else { return nil }
    let ledger = SecretsImportLedger(dataRoot: app.directories.root)
    let report = try await runSecretsBatch(sinks: sinks) {
      try await ArcSecretsImporter.runSyntheticFixture(sinks: sinks, ledger: ledger, stopAfter: nil, scenario: scenario)
    }
    let total = report.total
    return ImportOutcome(counts: ["Passwords": total.logins.added, "Cookies": total.cookies.added,
      "Addresses": total.addresses.added, "Cards": total.cards.added], secretsReportLines: report.lines)
  }
  #endif

  var hasUnfinishedSecretsImport: Bool {
    (try? SecretsImportLedger(dataRoot: app.directories.root).unfinished) != nil
  }

  /// The regular engine context of a main-model Profile, through the same creation path a page
  /// uses. It needs no window of that Profile: a Blank Window's model holds only its own stand-in
  /// Profile, and a Profile that an Undo removed no longer resolves. Never Incognito.
  func importContext(for profileID: ProfileID) -> OEBrowserContext? {
    guard let profile = app.model.profile(id: profileID) else { return nil }
    return EngineWebContentHostFactory.createRegularContext(profileID: profile.id, directory: profile.dataDirectoryName, app: app)
  }

  /// Resolve through the normal context path even when a Profile has no live tab.
  /// No fallback to Default, and never use an incognito factory for a writer.
  func secretsSink(for profile: Profile) throws -> AppSecretsImportSink {
    guard !retiredSecretsProfiles.contains(profile.id),
      !retiredSecretsDirectories.contains(profile.dataDirectoryName.lowercased()),
      app.model.profile(id: profile.id) === profile else { throw CancellationError() }
    guard let context = importContext(for: profile.id), !context.isEphemeral
    else { throw ArcSecretsImportError.invalidSinkResult }
    let sink = AppSecretsImportSink(profileID: profile.id, context: context) { [weak app] in
      guard let app else { return }
      for factory in app.hostFactories.values where !factory.isIncognito {
        for host in factory.hosts.values where host.profileID == profile.id && !host.closed { host.reload() }
      }
    }
    secretsSinks[profile.id] = sink
    return sink
  }

  /// Only a plan produced by the explicit consent button can enter here.
  /// The capability check is repeated next to token creation, before *any*
  /// Keychain operation. Tokens, keys and source records stay in this task.
  func importSecrets(plan: ImportPlan, imported: ArcImportResult,
                     profileMapping: [ProfileID: ProfileID]) async -> ImportOutcome {
    guard plan.secretsConsented, canImportPasswordsAndCookies,
          !app.terminationRequested, !Task.isCancelled else { return ImportOutcome() }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !app.engineReady && !app.terminationRequested && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard app.engineReady, !app.terminationRequested else { throw ArcSecretsImportError.invalidSinkResult }
      try Task.checkCancellation()
      var sinks: [String: any OpenImport.SecretsImportSink] = [:]
      for (sourceID, directory) in imported.sourceProfileDirectories {
        guard !retiredSecretsProfiles.contains(profileMapping[sourceID] ?? sourceID) else { throw CancellationError() }
        guard let target = app.model.profile(id: profileMapping[sourceID] ?? sourceID) else { continue }
        sinks[directory] = try secretsSink(for: target)
      }
      // A missing destination must never cause a Keychain prompt.
      guard !sinks.isEmpty else { throw ArcSecretsImportError.invalidSinkResult }
      try Task.checkCancellation()
      #if OPEN_AUTOMATION
      if let synthetic = try await syntheticSecretsOutcome(sinks: sinks) { return synthetic }
      #endif
      secretsConsentAdapterCalls += 1
      let consent = SecretsImportConsent.grantedByUser(reason: "import-wizard")
      secretsKeychainProbeCalls += 1
      let pair = try probeChromiumKeychainPair(consent: consent)
      secretsKeychainReadCalls += 1
      var password = try fetchKeychainPassword(service: pair.service, account: pair.account, consent: consent)
      defer { zeroSecretBytes(&password) }
      var key = deriveChromiumKey(passwordBytes: password)
      zeroSecretBytes(&password)
      defer { zeroSecretBytes(&key) }
      let importer = ArcSecretsImporter(arcUserData: plan.directory.appendingPathComponent("User Data"),
        ledger: SecretsImportLedger(dataRoot: app.directories.root))
      let report = try await runSecretsBatch(sinks: sinks) {
        try await importer.run(key: key, consent: consent, sinks: sinks)
      }
      let total = report.total
      return ImportOutcome(counts: ["Passwords": total.logins.added, "Cookies": total.cookies.added,
        "Addresses": total.addresses.added, "Cards": total.cards.added], secretsReportLines: report.lines)
    } catch is ChromiumCryptoError {
      // E-3: the non-secret import remains successful; no retry in this run.
      return ImportOutcome(failures: ["Passwords and cookies": "Keychain access was not granted. Passwords and cookies were not imported."])
    } catch {
      return ImportOutcome(failures: ["Passwords and cookies": "Passwords and cookies could not be imported. You can try again from Settings."])
    }
  }
}
