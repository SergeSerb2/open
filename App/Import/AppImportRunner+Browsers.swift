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
  }

  func importBrowser(source: BrowserSource, profile sourceProfile: BrowserSourceProfile, plan: ImportPlan, undo: AppImportUndo,
                     wizard: ImportWizardViewModel, progress: (String, Double?, Bool) -> Void) async -> BrowserImportResult {
    var result = BrowserImportResult()
    guard source.family == .chromium else {
      result.errorText = "Open cannot import from \(source.name) yet."; return result
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
    return finish(result)
  }

  private func finish(_ input: BrowserImportResult) -> BrowserImportResult {
    var result = input
    if result.errorText == nil, !result.failures.isEmpty {
      result.errorText = "Some selected data could not be imported. You can try again later from Settings."
    }
    return result
  }
}
