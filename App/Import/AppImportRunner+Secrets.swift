import Foundation
import OpenEngine
import OpenImport
import OpenModel
import OpenSettings

extension AppImportRunner {
  var canImportPasswordsAndCookies: Bool {
    OEEngine.shared.supportsSecretsImport && !OEEngine.shared.usesMockKeychain
  }

  var hasUnfinishedSecretsImport: Bool {
    (try? SecretsImportLedger(dataRoot: app.directories.root).unfinished) != nil
  }

  /// Resolve through the normal factory even when a Profile has no live tab.
  /// No fallback to Default, and never use an incognito factory for a writer.
  func secretsSink(for profile: Profile) throws -> AppSecretsImportSink {
    guard let factory = app.frontStandardWindowController.flatMap({ app.hostFactories[$0.windowID] })
      ?? app.hostFactories.values.first(where: { !$0.isIncognito }),
      !factory.isIncognito, let context = factory.context(for: profile.id), !context.isEphemeral
    else { throw ArcSecretsImportError.invalidSinkResult }
    return AppSecretsImportSink(profileID: profile.id, context: context) { [weak app] in
      guard let app else { return }
      for factory in app.hostFactories.values where !factory.isIncognito {
        for host in factory.hosts.values where host.profileID == profile.id && !host.closed { host.reload() }
      }
    }
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
        guard let target = app.model.profile(id: profileMapping[sourceID] ?? sourceID) else { continue }
        sinks[directory] = try secretsSink(for: target)
      }
      // A missing destination must never cause a Keychain prompt.
      guard !sinks.isEmpty else { throw ArcSecretsImportError.invalidSinkResult }
      try Task.checkCancellation()
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
      let report = try await ArcSecretsImporter(arcUserData: plan.directory.appendingPathComponent("User Data"),
        ledger: SecretsImportLedger(dataRoot: app.directories.root)).run(key: key, consent: consent, sinks: sinks)
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
