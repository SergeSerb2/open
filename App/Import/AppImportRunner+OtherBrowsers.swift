import Foundation
import OpenEngine
import OpenImport
import OpenModel
import OpenSettings
import OpenStore

/// Import from Firefox-family browsers and Safari (IMF). Same destination rules as the Chromium path
/// (IMC): bookmarks become one pinned folder "Imported from <Browser>" in the focused Space, built by
/// `BrowserBookmarksImport.sourceModel`; history goes to that Space's Profile; passwords go to the same
/// Profile through the engine login sink. Undo covers the sidebar and history, as for Chromium.
extension AppImportRunner {
  /// Firefox has no Keychain prompt and Safari passwords come from a user-picked file, so the only gate is
  /// the engine's own write rule: a mock-key engine (e2e) writes only with `--open-allow-mock-keychain-secrets`,
  /// and here also only for a synthetic library.
  var canImportBrowserPasswords: Bool {
    OEEngine.shared.supportsSecretsImport && (!OEEngine.shared.usesMockKeychain
      || (ImportWizardViewModel.browserLibraryOverride != nil && CommandLine.arguments.contains("--open-allow-mock-keychain-secrets")))
  }

  func importOtherBrowser(source: BrowserSource, profile sourceProfile: BrowserSourceProfile, plan: ImportPlan, undo: AppImportUndo,
                          wizard: ImportWizardViewModel, progress: (String, Double?, Bool) -> Void) async -> BrowserImportResult {
    var result = BrowserImportResult()
    // The Safari export has no bookmark UUIDs, so it gets its own key and lands as a second
    // "Imported from Safari" folder next to a live-files import (lead 01:25, as in Arc).
    let key = plan.source.importKey + (plan.safariFiles.exportArchive != nil ? ":export" : "")
    let model: BrowserModel = app.model
    guard let space = app.frontWindowController?.context.focusedSpace ?? model.spaces.first,
          let target = model.profile(id: space.profileID) else {
      result.errorText = "Open has no Space to import into."; return result
    }
    undo.actionName = "Import from " + source.name
    let reader = BrowserImportReader(family: source.family, profile: sourceProfile, safari: plan.safariFiles)
    if plan.bookmarks {
      progress("Importing your bookmarks…", nil, false)
      let read = await Task.detached(priority: .utility) { () -> (roots: [ImportedBookmark], skipped: Int, failure: String?) in
        do {
          let value = try reader.bookmarks()
          let r = value.report
          return (value.roots, r.skippedSeparators + r.skippedUnsupportedURL + r.skippedEmptyFolders + r.skippedOther, nil)
        } catch FirefoxImportError.missingFile, SafariImportError.missingFile { return ([], 0, "Not found") }
        catch SafariImportError.fullDiskAccessRequired { return ([], 0, "Full Disk Access is off") }
        catch { return ([], 0, "Could not be read") }
      }.value
      if let failure = read.failure { result.failures["Bookmarks"] = failure }
      result.counts["Skipped bookmarks"] = read.skipped
      let sourceModel = BrowserBookmarksImport.sourceModel(roots: read.roots.map(\.chromium), browserName: source.name, sourceKey: key,
                                                           profileID: target.id, settings: target.settings, spaceID: space.id)
      do {
        let merged = try undo.captureModel(app.model) {
          try app.model.mergeImportedSidebar(sourceModel, profileMapping: [:], spaces: false, tabs: true, favorites: false,
            folders: true, searchSettings: false, importedAt: Date(), saving: {
              try app.snapshotStore.saveNow(model: app.model)
            })
        }
        result.counts["Bookmarks"] = merged.tabs
        result.counts["Bookmark folders"] = merged.folders
        result.counts["Duplicates", default: 0] += merged.duplicates
        result.counts[ImportOutcomeKeys.tabs] = merged.tabs
      } catch {
        result.failures["Bookmarks"] = "Could not be saved"
        result.errorText = "Open could not save your data. The previous browser state was kept. Try again."
        return finishOther(result)
      }
    }
    app.importInProgress = false
    if plan.history, !undo.cancelled {
      progress("Importing your history…", 0, true)
      guard let store = app.stores.history(for: target.id) else {
        result.failures["History"] = "Could not be saved"; return finishOther(result)
      }
      let estimate = wizard.counts["History"] ?? 0
      let write = await Task.detached(priority: .utility) { [self] in
        var inserted = 0, duplicates = 0, succeeded = true
        var failure: String?
        do {
          _ = try await reader.history { batch in
            guard succeeded, !Task.isCancelled, !(await undo.cancelled) else { return }
            let visits = batch.map { ImportedHistoryVisit(chromiumVisitID: $0.chromiumVisitID, urlString: $0.urlString,
              title: $0.title, time: $0.time, transition: $0.transition, isTyped: $0.isTyped) }
            let written = await store.importHistoryBatch(visits, sourceProfileKey: key)
            if let receipt = written.undo { await undo.append(history: store, receipt: receipt) }
            succeeded = written.succeeded
            inserted += written.insertedVisits; duplicates += written.duplicateVisits
            await MainActor.run { self.historyProgress(batch.count, estimate: estimate, wizard: wizard) }
          }
          let ready = await store.importHistoryBatch([], sourceProfileKey: key)
          succeeded = succeeded && ready.succeeded
        } catch FirefoxImportError.missingFile, SafariImportError.missingFile { succeeded = false; failure = "Not found" }
        catch SafariImportError.fullDiskAccessRequired { succeeded = false; failure = "Full Disk Access is off" }
        catch { succeeded = false; failure = "Could not be read" }
        return (inserted, duplicates, succeeded, failure)
      }.value
      result.counts["History"] = write.0
      result.counts[ImportOutcomeKeys.history] = write.0
      result.counts["History duplicates"] = write.1
      result.counts["Duplicates", default: 0] += write.1
      if !write.2 { result.failures["History"] = write.3 ?? "Could not be read" }
      wizard.progress = 1
    }
    if plan.passwords, !undo.cancelled {
      progress("Importing your passwords…", nil, true)
      await importBrowserPasswords(reader: reader, primaryPassword: plan.primaryPassword, target: target, result: &result)
    }
    return finishOther(result)
  }

  private func importBrowserPasswords(reader: BrowserImportReader, primaryPassword: String, target: Profile, result: inout BrowserImportResult) async {
    guard canImportBrowserPasswords else { result.failures["Passwords"] = "Not available"; return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !app.engineReady && !app.terminationRequested && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    // One hand-off from the reader task to the main-actor sink; nothing else holds the records.
    struct Handoff: @unchecked Sendable { var logins: [ImportedLoginRecord]; var skipped: Int }
    let read = await Task.detached(priority: .utility) { () -> Result<Handoff, any Error> in
      Result { let value = try reader.passwords(primaryPassword: primaryPassword); return Handoff(logins: value.logins, skipped: value.skipped) }
    }.value
    var logins: [ImportedLoginRecord]
    switch read {
    case .success(let value): logins = value.logins; result.counts["Skipped passwords"] = value.skipped
    case .failure(FirefoxImportError.primaryPasswordRequired): result.failures["Passwords"] = "The Primary Password is not correct"; return
    case .failure(SafariImportError.notPasswordsFile): result.failures["Passwords"] = "Not a passwords file"; return
    case .failure: result.failures["Passwords"] = "Could not be read"; return
    }
    defer { for i in logins.indices { logins[i].zeroSecrets() } }
    guard app.engineReady, !app.terminationRequested else { result.failures["Passwords"] = "Could not be saved"; return }
    do {
      let sink = try secretsSink(for: target)
      var added = 0, existing = 0, failed = 0
      // The engine sink takes at most 256 rows per batch.
      for start in stride(from: 0, to: logins.count, by: 256) {
        guard !retiredSecretsProfiles.contains(target.id), !Task.isCancelled else { throw CancellationError() }
        let batch = Array(logins[start..<min(start + 256, logins.count)])
        let written = try await sink.importLogins(batch)
        added += written.added; existing += written.existing; failed += written.failed
      }
      result.counts["Passwords"] = added
      result.counts["Password duplicates"] = existing
      result.counts["Duplicates", default: 0] += existing
      if failed > 0 { result.failures["Passwords"] = "\(failed.formatted()) could not be saved" }
    } catch {
      // Type and code only; never a record or an engine description.
      let ns = error as NSError
      AppDelegate.commandLog("browser passwords import failed: \(String(describing: type(of: error))) \(ns.domain) \(ns.code)")
      result.failures["Passwords"] = "Could not be saved"
    }
  }

  private func finishOther(_ input: BrowserImportResult) -> BrowserImportResult {
    var result = input
    if result.errorText == nil, !result.failures.isEmpty {
      result.errorText = "Some selected data could not be imported. You can try again later from Settings."
    }
    return result
  }
}
