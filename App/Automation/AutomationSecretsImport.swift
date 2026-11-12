#if OPEN_AUTOMATION
import Foundation
import OpenEngine
import OpenImport
import OpenModel

extension AutomationController {
  /// Generated source only. There is deliberately no source path, key, blob,
  /// record, or consent argument. The real wizard adapter is never invoked.
  func importSecretsFixture(_ args: [String: Any]) async throws -> [String: Any] {
    #if !DEBUG
    guard ProcessInfo.processInfo.arguments.contains("--open-e2e") else {
      throw Failure(message: "synthetic secrets import requires Debug or --open-e2e")
    }
    #endif
    guard app.engineReady, OEEngine.shared.usesMockKeychain else {
      throw Failure(message: "synthetic secrets import requires a ready mock-key engine")
    }
    guard secretsFixtureStage != "running", !secretsFixtureStage.hasPrefix("paused-"),
      !app.importInProgress, !app.importRunner.historyInProgress, !app.importRunner.installingExtension,
      !app.importRunner.secretsFixtureInProgress else { throw Failure(message: "an import is already running") }
    guard Set(args.keys).isSubset(of: ["map", "pause", "pauseProfile", "only"]) else { throw Failure(message: "unsupported synthetic import argument") }
    // IMC I-2: other Chromium browsers import one chosen profile.
    var only: Set<String>?
    if let value = args["only"] {
      guard let names = value as? [String], !names.isEmpty, Set(names).isSubset(of: ["Default", "Profile 1"]) else {
        throw Failure(message: "invalid synthetic profile restriction")
      }
      only = Set(names)
    }
    let mapping: [String: String]
    if let value = args["map"] {
      guard let value = value as? [String: String], !value.isEmpty, value.count <= 2,
        Set(value.keys).isSubset(of: ["Default", "Profile 1"]),
        value.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
      else { throw Failure(message: "invalid synthetic Profile map") }
      mapping = value
    } else { mapping = ["Default": "Default", "Profile 1": "Work"] }
    let pause = args["pause"] as? String
    guard args["pause"] == nil || ["after-logins", "during-cookies"].contains(pause ?? "") else {
      throw Failure(message: "invalid synthetic import checkpoint")
    }
    let pauseProfile = args["pauseProfile"] as? String ?? "Default"
    guard pause == nil || mapping[pauseProfile] != nil,
      args["pauseProfile"] == nil || (args["pauseProfile"] as? String == pauseProfile && pause != nil) else {
      throw Failure(message: "invalid synthetic pause Profile")
    }
    var sinks: [String: any OpenImport.SecretsImportSink] = [:]
    var destinations = Set<ProfileID>()
    for (source, name) in mapping {
      guard let profile = app.model.profiles.first(where: { $0.name == name || $0.id.description == name }),
        destinations.insert(profile.id).inserted else { throw Failure(message: "missing or repeated destination Profile") }
      let sink = try app.importRunner.secretsSink(for: profile)
      if source == pauseProfile, let pause {
        sink.checkpoint = { [weak self] stage in
          guard let self, stage == pause else { return }
          self.secretsFixtureStage = "paused-" + stage
          // Hold a real import batch without blocking Profile deletion.
          // Bound the pause so an abandoned fixture cannot hold work forever.
          try await Task.sleep(for: .seconds(60))
          throw CancellationError()
        }
      }
      sinks[source] = sink
    }
    secretsFixtureStage = "running"; secretsFixtureError = ""; secretsFixtureReport = [:]
    app.importRunner.secretsFixtureInProgress = true
    let ledger = SecretsImportLedger(dataRoot: app.directories.root)
    if pause != nil {
      secretsFixtureTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { secretsFixtureTask = nil; app.importRunner.secretsFixtureInProgress = false }
        do {
          let report = try await app.importRunner.runSecretsBatch(sinks: sinks) {
            try await ArcSecretsImporter.runSyntheticFixture(sinks: sinks, ledger: ledger, stopAfter: nil, onlyProfiles: only)
          }
          secretsFixtureReport = Self.secretsCounts(report); secretsFixtureStage = "finished"
        } catch { secretsFixtureError = Self.secretsError(error); secretsFixtureStage = "failed" }
      }
      return secretsImportState()
    }
    defer { app.importRunner.secretsFixtureInProgress = false }
    do {
      let report = try await app.importRunner.runSecretsBatch(sinks: sinks) {
        try await ArcSecretsImporter.runSyntheticFixture(sinks: sinks, ledger: ledger, stopAfter: nil, onlyProfiles: only)
      }
      secretsFixtureReport = Self.secretsCounts(report); secretsFixtureStage = "finished"
      return secretsImportState()
    } catch {
      secretsFixtureStage = "failed"; secretsFixtureError = Self.secretsError(error)
      throw Failure(message: secretsFixtureError)
    }
  }

  private static func secretsError(_ error: any Error) -> String {
    let error = error as NSError
    // Never expose an engine description, source path, or imported record.
    if error.domain == OEErrorDomain { return "OEErrorDomain:\(error.code)" }
    return "synthetic secrets import failed"
  }

  private static func secretsCounts(_ report: ArcSecretsImportReport) -> [String: Any] {
    func count(_ value: SecretsImportCounts) -> [String: Int] {
      ["added": value.added, "existing": value.existing, "failed": value.failed,
       "skippedFederated": value.skippedFederated, "skippedExpired": value.skippedExpired, "unmapped": value.unmapped]
    }
    func profile(_ value: ArcSecretsProfileCounts) -> [String: Any] {
      ["logins": count(value.logins), "addresses": count(value.addresses), "cards": count(value.cards), "cookies": count(value.cookies)]
    }
    return ["profiles": report.profiles.mapValues(profile), "total": profile(report.total),
            "unmappedProfiles": report.unmappedProfiles, "previousRunUnfinished": report.previousRunUnfinished]
  }

  func secretsImportState() -> [String: Any] {
    let runner = app.importRunner
    return ["stage": secretsFixtureStage, "report": secretsFixtureReport, "error": secretsFixtureError,
      "consentAdapterCalls": runner.secretsConsentAdapterCalls,
      "keychainProbeCalls": runner.secretsKeychainProbeCalls, "keychainReadCalls": runner.secretsKeychainReadCalls,
      "canImportPasswordsAndCookies": runner.canImportPasswordsAndCookies,
      "unfinishedAtLaunch": runner.unfinishedSecretsImportAtLaunch,
      "activeBatch": runner.secretsTask != nil, "cachedSinks": runner.secretsSinks.count,
      "retiredProfiles": runner.retiredSecretsProfiles.count,
      "unfinished": runner.hasUnfinishedSecretsImport]
  }
}
#endif
