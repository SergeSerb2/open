import AppKit
import OpenModel
import OpenStore
import OpenBoosts

/// The model command keeps its normal inverse in a private UndoManager. One
/// native App action owns that inverse and the committed store receipts.
/// Never hold an UndoManager group open across an await or group user edits.
@MainActor
final class AppImportUndo {
  private weak var app: AppDelegate?
  private let modelUndo: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
  private weak var targetModel: BrowserModel?
  private var registered = false
  /// Undo permanently stops this import, even if Redo is pressed before a
  /// pending store batch returns. Store inverses wait for its final receipt.
  private(set) var cancelled = false
  /// Menu title of the Undo item, per import source.
  var actionName = "Import from Arc"
  private var importing = true
  private var importWaiters: [CheckedContinuation<Void, Never>] = []
  private var archives: [(ArchiveStore, [ArchivedTabRecord])] = []
  private var histories: [(HistoryStore, HistoryImportUndo)] = []
  private var boosts: [(ProfileID, BoostStore, [Boost])] = []
  /// Extra Arc data types (ArcImportProviders): their own undo and redo actions.
  private var providers: [(undo: @MainActor @Sendable () async throws -> Void, redo: (@MainActor @Sendable () async throws -> Void)?)] = []
  private(set) var task: Task<Void, Never>?
  private(set) var pendingOperations = 0
  private(set) var errorText = ""

  init(app: AppDelegate) { self.app = app }

  func captureModel<T>(_ model: BrowserModel, _ body: () throws -> T) rethrows -> T {
    targetModel = model
    let previous = model.undoManager
    model.undoManager = modelUndo
    defer { model.undoManager = previous }
    let result = try body()
    if modelUndo.canUndo { registerIfNeeded() }
    return result
  }

  func append(archive: ArchiveStore, records: [ArchivedTabRecord]) {
    guard !records.isEmpty else { return }
    archives.append((archive, records)); registerIfNeeded()
  }

  func append(history: HistoryStore, receipt: HistoryImportUndo) {
    histories.append((history, receipt)); registerIfNeeded()
  }

  func append(boosts values: [Boost], store: BoostStore, profileID: ProfileID) {
    guard !values.isEmpty else { return }
    boosts.append((profileID, store, values)); registerIfNeeded()
  }

  func append(provider undo: (@MainActor @Sendable () async throws -> Void)?, redo: (@MainActor @Sendable () async throws -> Void)?) {
    guard let undo else { return }
    providers.append((undo, redo)); registerIfNeeded()
  }

  func finishImport() {
    importing = false
    let waiters = importWaiters; importWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func registerIfNeeded() {
    guard !registered, let app else { return }
    registered = true
    register(on: app.undoManager, undoing: true)
  }

  private func register(on manager: UndoManager, undoing: Bool) {
    let group = manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
    if group { manager.beginUndoGrouping() }
    // UndoManager does not retain its target. A later no-op import replaces
    // the runner's receipt, so the action itself must keep this one alive.
    manager.registerUndo(withTarget: self) { [self] _ in
      MainActor.assumeIsolated { apply(undoing: undoing) }
    }
    manager.setActionName(actionName)
    if group { manager.endUndoGrouping() }
  }

  private func apply(undoing: Bool) {
    guard let app else { return }
    if undoing { cancelled = true }
    register(on: app.undoManager, undoing: !undoing)
    enqueue { [self] in
      if importing { await withCheckedContinuation { importWaiters.append($0) } }
      if undoing {
        for (_, store, values) in boosts {
          await Task.detached(priority: .utility) {
            for boost in values { store.delete(id: boost.id) }
            // First run restores the bootstrap Default ID at the same file
            // path. Finish the removal before that Profile can load its store.
            store.saveNow()
          }.value
        }
        applyModel(undoing: true)
        for (profileID, _, _) in boosts { app.stores.boosts.refresh(profile: profileID) }
        for (store, receipt) in histories.reversed() {
          guard await store.removeImportedHistory(receipt) else { throw UndoFailure.store }
        }
        for (store, records) in archives.reversed() { try await store.delete(ids: records.map(\.id)) }
        for provider in providers.reversed() { try await provider.undo() }
      } else {
        applyModel(undoing: false)
        var replacedBoosts: [(ProfileID, BoostStore, [Boost])] = []
        for (profileID, store, values) in boosts {
          guard app.model.profile(id: profileID) != nil, !app.stores.boosts.isRetired(profileID) else { continue }
          let added = await Task.detached(priority: .utility) {
            values.filter { store.boost(id: $0.id) == nil }.map { store.upsert($0) }
          }.value
          if !added.isEmpty {
            replacedBoosts.append((profileID, store, added))
            app.stores.boosts.refresh(profile: profileID)
          }
        }
        boosts = replacedBoosts
        var replaced: [(HistoryStore, HistoryImportUndo)] = []
        for (store, receipt) in histories {
          let result = await store.importHistoryBatch(receipt.redoVisits, sourceProfileKey: receipt.sourceProfileKey)
          guard result.succeeded else { throw UndoFailure.store }
          if let next = result.undo { replaced.append((store, next)) }
        }
        histories = replaced
        var replacedArchives: [(ArchiveStore, [ArchivedTabRecord])] = []
        for (store, records) in archives {
          let result = try await store.importRecordsWithUndo(records)
          if !result.undo.isEmpty { replacedArchives.append((store, result.undo)) }
        }
        archives = replacedArchives
        for provider in providers { try await provider.redo?() }
      }
    }
  }

  private func applyModel(undoing: Bool) {
    if let model = targetModel {
      captureModel(model) {
        // One import is one Undo step, even when it merged the sidebar more than once
        // (Firefox: bookmarks, then open tabs). This manager belongs to this import only.
        if undoing { while modelUndo.canUndo { modelUndo.undo() } }
        else { while modelUndo.canRedo { modelUndo.redo() } }
      }
    }
    app?.scheduleSave()
  }

  private enum UndoFailure: Error { case store }
  private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
    let previous = app?.importRunner.undoTask ?? task
    pendingOperations += 1
    app?.importRunner.undoOperations += 1
    task = Task { @MainActor [self] in
      defer { pendingOperations -= 1; app?.importRunner.undoOperations -= 1 }
      await previous?.value
      #if OPEN_AUTOMATION
      if let raw = ProcessInfo.processInfo.environment["OPEN_AUTOMATION_IMPORT_UNDO_DELAY_MS"], let ms = Int(raw), ms > 0 {
        try? await Task.sleep(for: .milliseconds(min(ms, 2_000)))
      }
      #endif
      do { try await operation() }
      catch {
        errorText = "Could not be saved"
        app?.importRunner.undoError = errorText
        // Surface failure in the existing import report, never silently accept
        // a partial store Undo. Keep receipts available to retry with Redo/Undo.
        app?.settingsPresenter.settings.importWizard.reportUndoFailure()
      }
    }
    app?.importRunner.undoTask = task
  }
}
