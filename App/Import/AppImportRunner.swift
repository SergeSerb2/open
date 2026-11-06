import AppKit
import QuartzCore
import OpenImport
import OpenModel
import OpenSettings
import OpenStore

/// The sole App import implementation. Settings merges; first run installs.
/// History (phase 3) and consent-gated secrets (phase 4) attach after this gate.
@MainActor
final class AppImportRunner {
  unowned let app: AppDelegate
  private(set) var lastOutcome: ImportOutcome?
  init(app: AppDelegate) { self.app = app }

  func run(plan: ImportPlan, firstRun: Bool) async -> ImportOutcome {
    guard !app.importInProgress else { return ImportOutcome(errorText: "An import is already running.") }
    app.importInProgress = true
    defer { app.importInProgress = false }
    let flow = firstRun ? app.firstRunWindowController?.model : nil
    flow?.phaseText = "Importing your Spaces and tabs…"
    // Let SwiftUI commit the progress step before any model construction.
    await Task.yield()
    for window in NSApp.windows where window.isVisible {
      window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    CATransaction.flush()
    #if OPEN_AUTOMATION
    if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_IMPORT_DELAY_MS"], let delay = Int(raw), delay > 0 {
      try? await Task.sleep(for: .milliseconds(min(delay, 5_000)))
    }
    #endif
    var counts: [String: Int] = [:]
    var failures: [String: String] = [:]
    func result(_ message: String? = nil) -> ImportOutcome {
      let outcome = ImportOutcome(counts: counts, errorText: message, failures: failures)
      lastOutcome = outcome; return outcome
    }
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    let imported: ArcImportResult
    do {
      // File decoding is already a Sendable seam in OpenImport. Build the live
      // graph on the main actor, once the progress view has been displayed.
      let directory = plan.directory
      let parsed = try await Task.detached(priority: .utility) { try ArcImporter(arcDirectory: directory).readSidebar() }.value
      imported = try ArcImporter(arcDirectory: directory).importAll(sidebar: parsed,
        directoryNamesToAvoid: app.model.unavailableProfileDirectoryNames,
        existingDirectories: Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id, $0.dataDirectoryName) }))
      guard imported.report.accountedTotal == imported.report.totalItems,
            !plan.archive || imported.report.archiveAccounted == imported.report.archiveTotal else { throw ImportError.malformedSidebar }
    } catch {
      for kind in ["Spaces", "Pinned and Today tabs", "Favorites", "Folders", "Archive"] { failures[kind] = "Could not be read" }
      return result("Open could not read your Arc data.")
    }
    let report = imported.report
    let hasSidebarData = report.sourceSpaces > 0 || report.importedTabNodes > 0 || report.folders > 0
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    if plan.archive && report.archiveStatus == "present but unreadable" { failures["Archive"] = "Could not be read" }
    counts["Sidebar accounted"] = report.accountedTotal; counts["Sidebar total"] = report.totalItems
    counts["Archive accounted"] = report.archiveAccounted; counts["Archive total"] = report.archiveTotal
    counts["Skipped easels"] = report.skippedEasels + (plan.archive ? report.archiveSkippedEasels : 0)
    counts["Skipped notes"] = report.skippedNotes + (plan.archive ? report.archiveSkippedNotes : 0)
    counts["Skipped unknown"] = report.skippedUnknown + (plan.archive ? report.archiveSkippedUnknownKind : 0)
    counts["Imported welcome"] = report.importedWelcome
    counts["Session selections"] = report.sessionAppliedSelections
    var profileMapping: [ProfileID: ProfileID] = [:]
    if !firstRun || !plan.spaces || !hasSidebarData {
      for profile in imported.model.profiles {
        if let live = app.model.profile(id: profile.id) { profileMapping[profile.id] = live.id }
        else if profile.dataDirectoryName == "Default", let live = app.model.defaultProfile { profileMapping[profile.id] = live.id }
      }
    }
    if plan.archive {
      flow?.phaseText = "Importing your archive…"
      for (sourceID, records) in Dictionary(grouping: imported.archiveRecords, by: \.profileID) {
        guard let source = sourceID.flatMap({ imported.model.profile(id: $0) }) ?? imported.model.defaultProfile else { continue }
        let targetID = profileMapping[source.id] ?? source.id
        let profile = app.model.profile(id: targetID) ?? source
        do {
          try app.directories.ensureProfileDirectories(for: profile)
          let store = ArchiveStore(fileURL: app.directories.archiveFileURL(for: profile))
          let mapped = records.map { record in
            var row = record
            // Existing Space profile assignments are authoritative on re-import.
            row.profileID = row.spaceID.flatMap { app.model.space(id: $0)?.profileID } ?? targetID
            return row
          }
          // Route each record by its actual target Profile, including reassigned Spaces.
          for (id, batch) in Dictionary(grouping: mapped, by: \.profileID) {
            let destination = id.flatMap { app.model.profile(id: $0) } ?? profile
            let sink = destination.id == profile.id ? store : ArchiveStore(fileURL: app.directories.archiveFileURL(for: destination))
            let write = try await sink.importRecords(batch, checking: true)
            counts[ImportOutcomeKeys.archive, default: 0] += write.inserted
            counts["Archive duplicates", default: 0] += write.duplicates
            counts["Duplicates", default: 0] += write.duplicates
          }
        } catch { failures["Archive"] = "Could not be read" }
      }
    }
    // Phase 3 seam: the next milestone streams history after this landing gate.
    // Never claim requested History as imported while that continuation is absent.
    if plan.history { failures["History"] = "History import is not available yet. You can import it later from Settings." }
    // Phase 4 remains capability OFF. No consent token or secret API is called.
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    if firstRun {
      if plan.spaces {
        counts[ImportOutcomeKeys.spaces] = report.sourceSpaces
        counts["Pinned and Today tabs"] = report.pinnedTabs + report.todayTabs
        counts["Favorites"] = report.favorites; counts["Folders"] = report.folders
        counts["Imported tabs"] = report.importedTabNodes
        counts[ImportOutcomeKeys.tabs] = report.importedTabNodes
        // A fallback Profile in an empty source is not imported data.
        if plan.searchSettings && hasSidebarData { counts["Search settings"] = imported.model.profiles.count }
      }
      // An empty/all-failed selection has not landed data. Keep D3 intact;
      // Continue/Start Fresh owns the first save of the default model.
      guard ImportOutcome(counts: counts).didImportAnything else {
        return result(failures.isEmpty ? nil : "Some selected data could not be imported. You can try again later from Settings.")
      }
      if plan.spaces && hasSidebarData {
        if !plan.searchSettings { for profile in imported.model.profiles { profile.settings = ProfileSettings() } }
        ensureSelection(in: imported.model)
        app.installModel(imported.model)
        app.settingsPresenter.modelWasInstalled()
      }
      app.showFirstRunBrowser()
      do {
        try app.snapshotStore.saveNow(model: app.model)
        app.firstRunSaved = true
        UserDefaults.standard.set(true, forKey: "open.firstRun.completed")
      } catch {
        return result(FirstRunViewModel.importedSaveError)
      }
    } else {
      do {
        let merged = try app.model.mergeImportedSidebar(imported.model, profileMapping: profileMapping,
          spaces: plan.spaces, tabs: plan.tabs, favorites: plan.favorites, folders: plan.folders,
          searchSettings: plan.searchSettings, saving: { try app.snapshotStore.saveNow(model: app.model) })
        counts[ImportOutcomeKeys.spaces] = merged.spaces
        counts["Pinned and Today tabs"] = merged.tabs
        counts["Favorites"] = merged.favorites; counts["Folders"] = merged.folders
        counts["Imported tabs"] = merged.tabs + merged.favorites
        counts[ImportOutcomeKeys.tabs] = merged.tabs + merged.favorites
        counts["Search settings"] = merged.searchSettings
        counts["Duplicates", default: 0] += merged.duplicates
      } catch {
        for kind in ["Spaces", "Pinned and Today tabs", "Favorites", "Folders", "Search settings"] { failures[kind] = "Could not be saved" }
        return result("Open could not save your data. The previous browser state was kept. Try again.")
      }
    }
    if plan.directory != ArcImporter().arcDirectory { UserDefaults.standard.set(plan.directory.path, forKey: "open.import.lastArcDir") }
    return result(failures.isEmpty ? nil : "Some selected data could not be imported. You can try again later from Settings.")
  }

  private func ensureSelection(in model: BrowserModel) {
    if model.windows.filter({ $0.style == .standard }).isEmpty, let space = model.spaces.first {
      model.windows.append(BrowserWindowState(focusedSpaceID: space.id))
    }
    for window in model.windows where window.style == .standard {
      guard let space = model.space(id: window.focusedSpaceID) ?? model.spaces.first else { continue }
      window.focusedSpaceID = space.id
      if window.selectedNodeBySpace[space.id].flatMap({ model.node(id: $0) }) == nil {
        window.selectedNodeBySpace[space.id] = space.today.first?.id ?? space.pinned.first?.id
      }
    }
  }
}
