import AppKit
import QuartzCore
import OpenImport
import OpenModel
import OpenSettings
import OpenStore
import OpenBoosts

/// The sole App import implementation. Settings merges; first run installs.
/// History streams through the existing Profile stores after the landing gate.
@MainActor
final class AppImportRunner {
  unowned let app: AppDelegate
  private(set) var lastOutcome: ImportOutcome?
  private var running = false
  private(set) var undoReceipt: AppImportUndo?
  var undoTask: Task<Void, Never>?
  var undoOperations = 0
  var undoError = ""
  private var undoQuitWaiters: [CheckedContinuation<Void, Never>] = []
  var hasPendingUndo: Bool { undoOperations > 0 || (running && undoReceipt?.cancelled == true) }
  func flushUndoForQuit() async {
    if running, undoReceipt?.cancelled == true {
      await withCheckedContinuation { undoQuitWaiters.append($0) }
    }
    await undoTask?.value
  }
  var extensionAttempt: AppImportExtensionAttempt?
  var installingExtension = false
  #if OPEN_AUTOMATION
  var extensionFixtures: [String: URL] = [:]
  var extensionWebStoreCompletion: (installed: Bool, error: String?)?
  #endif
  private(set) var historyInProgress = false
  private(set) var historyProcessed = 0
  private(set) var importAllMilliseconds: Double = 0
  private(set) var historyMilliseconds: Double = 0
  private(set) var totalMilliseconds: Double = 0
  #if OPEN_AUTOMATION
  let watchdog = ImportMainThreadWatchdog()
  #endif
  init(app: AppDelegate) { self.app = app }

  func run(plan: ImportPlan, firstRun: Bool) async -> ImportOutcome {
    guard !running, !installingExtension else { return ImportOutcome(errorText: "An import is already running.") }
    running = true
    await undoTask?.value
    let undo = AppImportUndo(app: app)
    undoReceipt = undo
    let importStarted = CACurrentMediaTime()
    historyMilliseconds = 0
    #if OPEN_AUTOMATION
    watchdog.start()
    #endif
    #if OPEN_AUTOMATION
    if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_IMPORT_STALL_MS"], let ms = Int(raw), ms > 0 {
      usleep(useconds_t(min(ms, 100) * 1_000))
    }
    #endif
    defer {
      totalMilliseconds = (CACurrentMediaTime() - importStarted) * 1_000
      #if OPEN_AUTOMATION
      watchdog.stop()
      #endif
    }
    lastOutcome = nil
    app.importInProgress = true
    historyProcessed = 0
    defer {
      undo.finishImport()
      app.importInProgress = false; historyInProgress = false; running = false
      let waiters = undoQuitWaiters; undoQuitWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    let flow = firstRun ? app.firstRunWindowController?.model : nil
    let wizard = flow?.wizard ?? app.settingsPresenter.settings.importWizard
    func progress(_ text: String, _ fraction: Double? = nil, landed: Bool = false) {
      flow?.phaseText = text; flow?.progress = fraction
      if landed { flow?.browserHasLanded = true }
      wizard.phaseText = text; wizard.progress = fraction; wizard.browserHasLanded = landed
    }
    progress("Importing your Spaces and tabs…")
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
    var extensions: [ImportExtensionCandidate] = []
    var extensionProfileCount = 0
    func result(_ message: String? = nil) -> ImportOutcome {
      let outcome = ImportOutcome(counts: counts, errorText: message, failures: failures,
        extensions: extensions, extensionProfileCount: extensionProfileCount)
      lastOutcome = outcome; return outcome
    }
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    var imported: ArcImportResult
    do {
      // File decoding is already a Sendable seam in OpenImport. Build the live
      // graph on the main actor, once the progress view has been displayed.
      let directory = plan.directory
      #if OPEN_AUTOMATION
      watchdog.beginPhase("readSidebar")
      #endif
      let parsed = try await Task.detached(priority: .utility) { try ArcImporter(arcDirectory: directory).readSidebar() }.value
      #if OPEN_AUTOMATION
      watchdog.beginPhase("buildSidebar")
      #endif
      let started = CACurrentMediaTime()
      imported = try ArcImporter(arcDirectory: directory).importAll(sidebar: parsed,
        directoryNamesToAvoid: app.model.unavailableProfileDirectoryNames,
        existingDirectories: Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id, $0.dataDirectoryName) }), includeArchive: false)
      importAllMilliseconds = (CACurrentMediaTime() - started) * 1_000
      #if OPEN_AUTOMATION
      watchdog.beginPhase("readArchive")
      #endif
      if plan.archive, let firstSpace = imported.model.spaces.first {
        let profiles = Dictionary(uniqueKeysWithValues: imported.model.spaces.map { ($0.id, $0.profileID) })
        let initial = imported.report, defaultSpaceID = firstSpace.id
        let archive = await Task.detached(priority: .utility) {
          ArcImporter(arcDirectory: directory).readArchive(sidebar: parsed, spaceProfiles: profiles,
                                                         defaultSpaceID: defaultSpaceID, report: initial)
        }.value
        imported.archiveRecords = archive.records; imported.report = archive.report
      }
      guard imported.report.accountedTotal == imported.report.totalItems,
            !plan.archive || imported.report.archiveAccounted == imported.report.archiveTotal else { throw ImportError.malformedSidebar }
    } catch {
      let value = (error as? ImportError) == .missingSidebar ? "Not found" : "Could not be read"
      for kind in ["Spaces", "Pinned and Today tabs", "Favorites", "Folders", "Archive"] { failures[kind] = value }
      return result("Open could not read your Arc data.")
    }
    #if OPEN_AUTOMATION
    watchdog.beginPhase("landSidebar")
    #endif
    let report = imported.report
    counts["Extensions total"] = report.extensions.totalRecords
    counts["Extensions internal"] = report.extensions.internalRecords
    counts["Extensions candidates"] = report.extensions.reinstallCandidates
    counts["Extensions missing manifest"] = report.extensions.missingManifest
    counts["Extensions unreadable profiles"] = report.extensionProfilesUnreadable
    let hasSidebarData = report.sourceSpaces > 0 || report.importedTabNodes > 0 || report.folders > 0
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    if plan.archive && report.archiveStatus == "present but unreadable" { failures["Archive"] = "Could not be read" }
    if plan.archive && !report.archiveFilePresent { failures["Archive"] = "Not found" }
    counts["Sidebar accounted"] = report.accountedTotal; counts["Sidebar total"] = report.totalItems
    counts["Archive accounted"] = report.archiveAccounted; counts["Archive total"] = report.archiveTotal
    counts["Skipped easels"] = report.skippedEasels + (plan.archive ? report.archiveSkippedEasels : 0)
    counts["Skipped notes"] = report.skippedNotes + (plan.archive ? report.archiveSkippedNotes : 0)
    counts["Skipped unknown"] = report.skippedUnknown + (plan.archive ? report.archiveSkippedUnknownKind : 0)
    counts["Imported welcome"] = report.importedWelcome
    counts["Session selections"] = report.sessionAppliedSelections
    if plan.boosts {
      counts["Boosts found"] = imported.boostsByProfile.values.reduce(0) { $0 + $1.count }
      counts["Boosts"] = 0
      counts["Boosts malformed"] = report.boosts.malformed
      counts["Boost fields dropped"] = report.boosts.fieldsDropped.values.reduce(0, +)
      counts["Boost fields unknown"] = report.boosts.unknownFields
      if report.boosts.cacheFound && report.boosts.status != "read" { failures["Boosts"] = "Could not be read" }
    }
    var profileMapping: [ProfileID: ProfileID] = [:]
    if !firstRun || !plan.spaces || !hasSidebarData {
      for profile in imported.model.profiles {
        // Arc Default keeps the live Default context, including its logins.
        // Resolve the source role before stable IDs; names and paths are not identity.
        if profile.id == imported.sourceDefaultProfileID, let live = app.model.defaultProfile {
          profileMapping[profile.id] = live.id
        } else if let live = app.model.profile(id: profile.id) { profileMapping[profile.id] = live.id }
      }
    }
    func mapExtensions() {
      extensionProfileCount = imported.model.profiles.count
      var seen = Set<String>()
      extensions = []
      for source in imported.model.profiles {
        let targetID = profileMapping[source.id] ?? source.id
        guard imported.sourceProfileDirectories[source.id] != nil,
          let target = app.model.profile(id: targetID) else { continue }
        for record in imported.extensionsByProfile[source.id] ?? [] where !record.isInternal {
          let candidate = ImportExtensionCandidate(extensionID: record.extensionID,
            name: record.manifestName ?? record.extensionID, profileID: target.id, profileName: target.name)
          if seen.insert(candidate.id).inserted { extensions.append(candidate) }
        }
      }
    }
    // Even an empty sidebar can have extensions for an existing destination.
    mapExtensions()
    if firstRun && !(plan.spaces && hasSidebarData) && (plan.archive || plan.history || plan.boosts) {
      do {
        _ = try undo.captureModel(app.model) { try app.model.mergeImportedSidebar(imported.model, profileMapping: profileMapping,
          spaces: false, tabs: false, favorites: false, folders: false, searchSettings: false,
          profiles: true, saving: {
            for profile in app.model.profiles { try app.directories.ensureProfileDirectories(for: profile) }
          }) }
      } catch { return result("Open could not create the imported Profiles.") }
    }
    // Phase 4 remains capability OFF. No consent token or secret API is called.
    guard !app.terminationRequested, !Task.isCancelled else { return result("Import stopped because Open is quitting.") }
    if firstRun {
      if plan.spaces {
        counts[ImportOutcomeKeys.spaces] = report.sourceSpaces
        counts["Pinned and Today tabs"] = report.pinnedTabs + report.todayTabs
        counts["Favorites"] = report.favorites; counts["Folders"] = report.folders
        counts["Profiles"] = imported.model.profiles.count; counts["Routing rules"] = imported.model.routingRules.count
        counts["Splits"] = report.splits
        counts["Imported tabs"] = report.importedTabNodes
        counts[ImportOutcomeKeys.tabs] = report.importedTabNodes
        // A fallback Profile in an empty source is not imported data.
        if plan.searchSettings && hasSidebarData { counts["Search settings"] = imported.model.profiles.count }
      }
      // An empty/all-failed selection has not landed data. Keep D3 intact;
      // Continue/Start Fresh owns the first save of the default model.
      guard ImportOutcome(counts: counts).didImportAnything || plan.history || (plan.archive && report.archiveImported > 0)
        || (plan.boosts && report.boosts.imported > 0) else {
        return result(failures.isEmpty ? nil : "Some selected data could not be imported. You can try again later from Settings.")
      }
      if plan.spaces && hasSidebarData {
        do { imported.model = try materializeProfiles(in: imported.model) }
        catch { return result("Open could not create the imported Profiles.") }
        if !plan.searchSettings { for profile in imported.model.profiles { profile.settings = ProfileSettings() } }
        let importedAt = Date()
        for space in imported.model.spaces {
          for tab in importTabs(space.today) { tab.lastActiveAt = importedAt }
        }
        ensureSelection(in: imported.model)
        undo.captureModel(imported.model) { imported.model.registerImportedReplacementUndo(restoring: app.model) }
        app.installModel(imported.model)
        app.settingsPresenter.modelWasInstalled()
        mapExtensions()
      }
      app.showFirstRunBrowser()
      do {
        try app.snapshotStore.saveNow(model: app.model)
        // This is a landing checkpoint. Final setup still owns D3 completion.
        // Keep ordinary snapshot writes guarded until Get Started succeeds.
      } catch {
        return result(FirstRunViewModel.importedSaveError)
      }
    } else {
      do {
        var archivedIDs: [ProfileID: Set<ItemID>] = [:]
        if plan.tabs || plan.favorites {
          let candidates = Set(imported.model.profiles.flatMap { $0.favorites.map(\.id) }
            + imported.model.spaces.flatMap { importTabs($0.pinned + $0.today).map(\.id) })
          let targets = Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id, $0) })
          // The sink's queue also owns pending manual archives. Await one batch
          // per Profile before the synchronous, ID-preserving model merge.
          for profile in targets.values {
            let store = app.archiveSink.store(for: profile.id)
            archivedIDs[profile.id] = try await store.existingIDs(in: candidates)
          }
        }
        let beforeProfiles = app.model.profiles.count, beforeRules = app.model.routingRules.count
        let merged = try undo.captureModel(app.model) { try app.model.mergeImportedSidebar(imported.model, profileMapping: profileMapping,
          spaces: plan.spaces, tabs: plan.tabs, favorites: plan.favorites, folders: plan.folders,
          searchSettings: plan.searchSettings, profiles: plan.archive || plan.history || plan.boosts, archivedIDsByProfile: archivedIDs,
          importedAt: Date(), saving: {
            for profile in app.model.profiles { try app.directories.ensureProfileDirectories(for: profile) }
            try app.snapshotStore.saveNow(model: app.model)
          }) }
        counts["Profiles"] = app.model.profiles.count - beforeProfiles
        counts["Routing rules"] = app.model.routingRules.count - beforeRules
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
    // Resolve metadata only after the live model has landed. Destination
    // directory collision suffixes must never be used to read the Arc source.
    mapExtensions()
    if plan.boosts {
      guard !undo.cancelled else { return result() }
      #if OPEN_AUTOMATION
      watchdog.beginPhase("writeBoosts")
      #endif
      // Resolve the destination only after the model has landed. In particular,
      // the source Default ID need not be the live Default ID in Settings.
      var batches: [ProfileID: [Boost]] = [:]
      for (sourceID, values) in imported.boostsByProfile {
        let targetID = sourceID == imported.sourceDefaultProfileID
          ? app.model.defaultProfile?.id : (profileMapping[sourceID] ?? sourceID)
        guard let targetID, app.model.profile(id: targetID) != nil else {
          failures["Boosts"] = "Could not be saved"; continue
        }
        batches[targetID, default: []].append(contentsOf: values)
      }
      for (profileID, values) in batches {
        guard !undo.cancelled else { break }
        // AppBoosts loads once on its actor. The existing Sendable store owns
        // its lock and save queue; never construct a competing store here.
        let store = app.stores.boosts.store(for: profileID)
        let added = await Task.detached(priority: .utility) {
          var added: [Boost] = []
          for boost in values where store.boost(id: boost.id) == nil {
            added.append(store.upsert(boost))
          }
          return added
        }.value
        undo.append(boosts: added, store: store, profileID: profileID)
        counts["Boosts", default: 0] += added.count
        counts["Boost duplicates", default: 0] += values.count - added.count
        counts["Duplicates", default: 0] += values.count - added.count
        if !added.isEmpty { app.stores.boosts.refresh(profile: profileID) }
      }
    }
    #if OPEN_AUTOMATION
    watchdog.beginPhase("writeArchive")
    #endif
    if plan.archive {
      guard !undo.cancelled else { return result() }
      progress("Importing your archive…")
      for (sourceID, records) in Dictionary(grouping: imported.archiveRecords, by: \.profileID) {
        guard let source = sourceID.flatMap({ imported.model.profile(id: $0) }) ?? imported.model.defaultProfile else { continue }
        let targetID = profileMapping[source.id] ?? source.id
        guard let profile = app.model.profile(id: targetID) else {
          failures["Archive"] = "Could not be read"; continue
        }
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
            guard !undo.cancelled else { break }
            let write = try await sink.importRecordsWithUndo(batch)
            undo.append(archive: sink, records: write.undo)
            counts[ImportOutcomeKeys.archive, default: 0] += write.inserted
            counts["Archive duplicates", default: 0] += write.duplicates
            counts["Duplicates", default: 0] += write.duplicates
          }
        } catch { failures["Archive"] = "Could not be read" }
      }
    }
    // The snapshot and window are ready. Ordinary browser saves are now free
    // to run; the separate runner guard still refuses overlapping imports.
    #if OPEN_AUTOMATION
    watchdog.beginPhase("browserReady")
    #endif
    app.importInProgress = false
    if plan.directory != ArcImporter().arcDirectory { UserDefaults.standard.set(plan.directory.path, forKey: "open.import.lastArcDir") }
    #if OPEN_AUTOMATION
    watchdog.beginPhase("writeHistory")
    #endif
    if plan.history {
      guard !undo.cancelled else { return result() }
      let historyStarted = CACurrentMediaTime()
      defer { historyMilliseconds = (CACurrentMediaTime() - historyStarted) * 1_000 }
      historyInProgress = true
      progress("Importing your history…", 0, landed: true)
      let estimate = wizard.probe?.historyVisits ?? 0
      var failedVisits = 0
      for source in imported.model.profiles {
        guard !undo.cancelled else { break }
        let targetID = profileMapping[source.id] ?? source.id
        guard let directory = imported.sourceProfileDirectories[source.id],
              let target = app.model.profile(id: targetID),
              let store = app.stores.history(for: target.id) else {
          counts["History unmapped profiles", default: 0] += 1
          continue
        }
        // The importer owns Profile resolution. Never treat a renamed Open
        // destination directory as an Arc source directory or merge an orphan
        // source Profile into Default.
        guard !directory.isEmpty, directory.utf8.count <= 255, directory != ".", directory != "..",
              !directory.contains("/"), !directory.contains("\\"),
              !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
          failures["History"] = "Could not be read"; continue
        }
        let file = plan.directory.appendingPathComponent("User Data").appendingPathComponent(directory).appendingPathComponent("History")
        let expected = wizard.probe?.profileCounts[source.id.description]?.historyVisits ?? 0
        let write = await Task.detached(priority: .utility) { [self] in
          var inserted = 0, duplicates = 0, processed = 0
          var succeeded = true
          var readFailure: String?
          do {
            _ = try await ArcHistoryReader(historyFileURL: file).readBatches { batch in
              guard succeeded, !Task.isCancelled, !(await undo.cancelled) else { return }
              #if OPEN_AUTOMATION
              // Hold the real pending batch before its transaction so the
              // suite proves browsing while imported visits are still absent.
              if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_HISTORY_DELAY_MS"], let ms = Int(raw), ms > 0 {
                try? await Task.sleep(for: .milliseconds(min(ms, 10_000)))
              }
              #endif
              let visits = batch.map { ImportedHistoryVisit(chromiumVisitID: $0.chromiumVisitID,
                urlString: $0.urlString, title: $0.title, time: $0.time, transition: $0.transition, isTyped: $0.isTyped) }
              let result = await store.importHistoryBatch(visits, sourceProfileKey: directory)
              if let receipt = result.undo { await undo.append(history: store, receipt: receipt) }
              succeeded = result.succeeded
              inserted += result.insertedVisits; duplicates += result.duplicateVisits
              processed += batch.count
              await MainActor.run {
                self.historyProcessed += batch.count
                let fraction = estimate > 0 ? min(1, Double(self.historyProcessed) / Double(estimate)) : 0
                flow?.progress = fraction; wizard.progress = fraction
              }
            }
            // Validate an empty import too; a broken destination must not look
            // like a successful zero-visit source.
            let ready = await store.importHistoryBatch([], sourceProfileKey: directory)
            succeeded = succeeded && ready.succeeded
          } catch {
            succeeded = false
            if let error = error as? ArcHistoryImportError, case .missingHistoryFile = error { readFailure = "Not found" }
            else { readFailure = "Could not be read" }
          }
          return (inserted, duplicates, processed, succeeded, readFailure)
        }.value
        counts["History", default: 0] += write.0
        counts["History duplicates", default: 0] += write.1
        counts["Duplicates", default: 0] += write.1
        if !write.3 {
          failures["History"] = write.4 ?? "Could not be read"
          failedVisits += max(0, expected - write.0 - write.1)
        }
      }
      counts["History failed"] = failedVisits
      counts[ImportOutcomeKeys.history] = counts["History", default: 0]
      flow?.progress = 1; wizard.progress = 1
      if failures["History"] != nil {
        return result("Your Spaces and tabs are in. \(failedVisits.formatted()) history visits could not be read. You can import history later from Settings.")
      }
    }
    return result(failures.isEmpty ? nil : "Some selected data could not be imported. You can try again later from Settings.")
  }

  /// Source Profiles are DTOs. Live Profiles use the same allocator and
  /// initialization hook as Settings creation, retaining the stable import ID.
  private func materializeProfiles(in source: BrowserModel) throws -> BrowserModel {
    let destination = BrowserModel()
    destination.unavailableProfileDirectoryNames = app.model.unavailableProfileDirectoryNames
      .union(try app.directories.unavailableDirectoryNames())
    // First run already owns the bootstrap Default context in this fresh root.
    // Named source directories are never adopted, even when their names match.
    if app.model.defaultProfile?.dataDirectoryName == "Default" {
      destination.unavailableProfileDirectoryNames.remove("default")
    }
    let ordered = source.profiles.sorted { $0.id == source.defaultProfile?.id && $1.id != source.defaultProfile?.id }
    for profile in ordered {
      var name = profile.name, suffix = 2
      while destination.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
        name = profile.name + " (" + String(suffix) + ")"; suffix += 1
      }
      guard let live = destination.createProfile(name: name, icon: profile.icon, settings: profile.settings, id: profile.id) else {
        throw BrowserModel.ProfileImportError.invalidProfile
      }
      live.favorites = profile.favorites
      try app.directories.ensureProfileDirectories(for: live)
    }
    destination.spaces = source.spaces
    destination.windows = source.windows
    destination.routingRules = source.routingRules
    destination.defaultDestination = source.defaultDestination
    destination.rebuildIndex()
    return destination
  }

  private func importTabs(_ nodes: [SidebarNode]) -> [Tab] {
    nodes.flatMap { node in
      switch node {
      case .tab(let tab): return [tab]
      case .folder(let folder): return importTabs(folder.children)
      case .split(let split): return split.panes
      }
    }
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
