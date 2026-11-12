import Foundation
import OpenImport
import OpenModel
import OpenSettings
import OpenStore

/// Import from other browsers (IMC I-1: Chromium family). Settings only; first run stays Arc-only until I-5.
/// Bookmarks land as one pinned folder in the current Space; history goes to that Space's Profile.
extension AppImportRunner {
  struct BrowserImportResult {
    var counts: [String: Int] = [:]
    var failures: [String: String] = [:]
    var errorText: String?
    var extensions: [ImportExtensionCandidate] = []
    var secretsReportLines: [String] = []
  }

  func importBrowser(source: BrowserSource, profile sourceProfile: BrowserSourceProfile, plan: ImportPlan, undo: AppImportUndo,
                     wizard: ImportWizardViewModel, progress: (String, Double?, Bool) -> Void) async -> BrowserImportResult {
    var result = BrowserImportResult()
    guard source.family == .chromium else {
      return await importOtherBrowser(source: source, profile: sourceProfile, plan: plan, undo: undo, wizard: wizard, progress: progress)
    }
    let key = plan.source.importKey
    // Destination: the focused Space of the front window, else the first Space.
    let model: BrowserModel = self.app.model
    let front = self.app.frontWindowController
    guard let space = front?.context.focusedSpace ?? model.spaces.first,
          let target = model.profile(id: space.profileID) else {
      result.errorText = "Open has no Space to import into."; return result
    }
    undo.actionName = "Import from " + source.name
    let reader = ChromiumProfileReader(directory: sourceProfile.directory)
    if plan.bookmarks || plan.searchSettings {
      progress("Importing your bookmarks…", nil, false)
      let read = await Task.detached(priority: .utility) { () -> (roots: [ImportedBookmark], skipped: Int, failure: String?, search: ChromiumSearchEngine?) in
        var roots: [ImportedBookmark] = [], skipped = 0, failure: String?
        if plan.bookmarks {
          do { (roots, skipped) = try reader.bookmarks() }
          catch ChromiumProfileReader.ReadError.missing { failure = "Not found" }
          catch { failure = "Could not be read" }
        }
        return (roots, skipped, failure, plan.searchSettings ? reader.defaultSearchEngine() : nil)
      }.value
      if let failure = read.failure { result.failures["Bookmarks"] = failure }
      result.counts["Skipped bookmarks"] = read.skipped
      var settings = target.settings
      if let engine = read.search {
        let mapped = ChromiumSearchMapping.map(engine)
        settings.searchEngineID = mapped.id
        if let custom = mapped.custom, !settings.customSearchEngines.contains(where: { $0.id == custom.id }) {
          settings.customSearchEngines.append(custom)
        }
      }
      let model = BrowserBookmarksImport.sourceModel(roots: plan.bookmarks ? read.roots : [], browserName: source.name, sourceKey: key,
                                                     profileID: target.id, settings: settings, spaceID: space.id)
      do {
        let merged = try undo.captureModel(app.model) {
          try app.model.mergeImportedSidebar(model, profileMapping: [:], spaces: false, tabs: plan.bookmarks, favorites: false,
            folders: plan.bookmarks, searchSettings: plan.searchSettings && read.search != nil, importedAt: Date(), saving: {
              try app.snapshotStore.saveNow(model: app.model)
            })
        }
        result.counts["Bookmarks"] = merged.tabs
        result.counts["Bookmark folders"] = merged.folders
        result.counts["Search settings"] = merged.searchSettings
        result.counts["Duplicates", default: 0] += merged.duplicates
        result.counts[ImportOutcomeKeys.tabs] = merged.tabs
      } catch {
        result.failures["Bookmarks"] = "Could not be saved"
        result.errorText = "Open could not save your data. The previous browser state was kept. Try again."
        return result
      }
    }
    app.importInProgress = false
    // Extensions: a reinstall list from the source profile (Chrome Web Store IDs only), as Import from Arc does.
    let extensionsRead = await Task.detached(priority: .utility) { try? ArcExtensionsReader(profileDirectory: sourceProfile.directory).read() }.value
    var seen = Set<String>()
    for record in extensionsRead?.records ?? [] where !record.isInternal {
      let candidate = ImportExtensionCandidate(extensionID: record.extensionID, name: record.manifestName ?? record.extensionID,
                                               profileID: target.id, profileName: target.name)
      if seen.insert(candidate.id).inserted { result.extensions.append(candidate) }
    }
    if plan.history, !undo.cancelled {
      progress("Importing your history…", 0, true)
      guard let store = app.stores.history(for: target.id) else {
        result.failures["History"] = "Could not be saved"; return finish(result)
      }
      let file = sourceProfile.directory.appendingPathComponent("History")
      let estimate = wizard.counts["History"] ?? 0
      let write = await Task.detached(priority: .utility) { [self] in
        var inserted = 0, duplicates = 0, succeeded = true
        var failure: String?
        do {
          _ = try await ArcHistoryReader(historyFileURL: file).readBatches { batch in
            guard succeeded, !Task.isCancelled, !(await undo.cancelled) else { return }
            let visits = batch.map { ImportedHistoryVisit(chromiumVisitID: $0.chromiumVisitID, urlString: $0.urlString,
              title: $0.title, time: $0.time, transition: $0.transition, isTyped: $0.isTyped) }
            let written = await store.importHistoryBatch(visits, sourceProfileKey: key)
            if let receipt = written.undo { await undo.append(history: store, receipt: receipt) }
            succeeded = written.succeeded
            inserted += written.insertedVisits; duplicates += written.duplicateVisits
            await MainActor.run {
              self.historyProgress(batch.count, estimate: estimate, wizard: wizard)
            }
          }
          let ready = await store.importHistoryBatch([], sourceProfileKey: key)
          succeeded = succeeded && ready.succeeded
        } catch {
          succeeded = false
          if let error = error as? ArcHistoryImportError, case .missingHistoryFile = error { failure = "Not found" } else { failure = "Could not be read" }
        }
        return (inserted, duplicates, succeeded, failure)
      }.value
      result.counts["History"] = write.0
      result.counts[ImportOutcomeKeys.history] = write.0
      result.counts["History duplicates"] = write.1
      result.counts["Duplicates", default: 0] += write.1
      if !write.2 { result.failures["History"] = write.3 ?? "Could not be read" }
      wizard.progress = 1
    }
    if plan.secretsConsented && canImportPasswordsAndCookies && !undo.cancelled {
      progress("Importing your passwords and cookies…", nil, true)
      let secrets = await importBrowserSecrets(plan: plan, source: source, profile: sourceProfile, target: target)
      result.counts.merge(secrets.counts) { _, new in new }
      result.failures.merge(secrets.failures) { _, new in new }
      result.secretsReportLines = secrets.secretsReportLines
    }
    return finish(result)
  }

  /// I-2: passwords, cookies, addresses and cards from one Chromium profile. Same consent gate, sink,
  /// ledger and reader as Import from Arc; the Keychain item is the source browser's own "Safe Storage" item,
  /// so macOS asks once per browser. No probe of other browsers' items.
  func importBrowserSecrets(plan: ImportPlan, source: BrowserSource, profile: BrowserSourceProfile, target: Profile) async -> ImportOutcome {
    guard plan.secretsConsented, canImportPasswordsAndCookies, !app.terminationRequested, !Task.isCancelled,
          !source.descriptor.profileAtRoot, let item = source.descriptor.keychainItem else { return ImportOutcome() }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !app.engineReady && !app.terminationRequested && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard app.engineReady, !app.terminationRequested else { throw ArcSecretsImportError.invalidSinkResult }
      let sinks: [String: any OpenImport.SecretsImportSink] = [profile.id: try secretsSink(for: target)]
      try Task.checkCancellation()
      secretsConsentAdapterCalls += 1
      let consent = SecretsImportConsent.grantedByUser(reason: "import-wizard")
      secretsKeychainReadCalls += 1
      var password = try fetchKeychainPassword(service: item.service, account: item.account, consent: consent)
      defer { zeroSecretBytes(&password) }
      var key = deriveChromiumKey(passwordBytes: password)
      zeroSecretBytes(&password)
      defer { zeroSecretBytes(&key) }
      let importer = ArcSecretsImporter(arcUserData: source.dataRoot, ledger: SecretsImportLedger(dataRoot: app.directories.root),
                                        onlyProfiles: [profile.id])
      let report = try await runSecretsBatch(sinks: sinks) {
        try await importer.run(key: key, consent: consent, sinks: sinks)
      }
      let total = report.total
      return ImportOutcome(counts: ["Passwords": total.logins.added, "Cookies": total.cookies.added,
        "Addresses": total.addresses.added, "Cards": total.cards.added], secretsReportLines: report.lines)
    } catch is ChromiumCryptoError {
      return ImportOutcome(failures: ["Passwords and cookies": "Keychain access was not granted. Passwords and cookies were not imported."])
    } catch {
      return ImportOutcome(failures: ["Passwords and cookies": "Passwords and cookies could not be imported. You can try again from Settings."])
    }
  }

  private func finish(_ input: BrowserImportResult) -> BrowserImportResult {
    var result = input
    if result.errorText == nil, !result.failures.isEmpty {
      result.errorText = "Some selected data could not be imported. You can try again later from Settings."
    }
    return result
  }
}
