import Foundation
import OpenEasel
import OpenSuggest

/// Command bar: every Easel by title (EZ GAPS G6, LEAD 15:25). The catalog is refreshed off the
/// main thread when a normal window's command bar opens, at most every 5 s, and only when the
/// Easels folder exists. It never makes the Easel store at launch.
@MainActor
final class EaselSearch {
  let catalog = EaselCatalog()
  private var lastRefresh = -Double.infinity
  private var task: Task<Void, Never>?
  private(set) var refreshCount = 0
  unowned let app: AppDelegate
  init(app: AppDelegate) { self.app = app }

  func refresh(force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastRefresh > 5, task == nil, let root = app.directories?.root else { return }
    lastRefresh = now
    let directory = root.appendingPathComponent("Easels", isDirectory: true)
    // Unsaved edits win over the files (an open Easel's newest title).
    let pending = app.hasEaselStore ? app.easels.pendingDocuments.map { ($0.id, $0.displayTitle, $0.modifiedAt) } : []
    task = Task { [weak self] in
      let index = await Task.detached(priority: .utility) { () -> [EaselStore.IndexEntry] in
        FileManager.default.fileExists(atPath: directory.path) ? EaselStore.readIndex(directory: directory) : []
      }.value
      guard let self else { return }
      var byID = Dictionary(index.map { ($0.id, ($0.title, $0.modifiedAt)) }, uniquingKeysWith: { a, _ in a })
      for (id, title, modified) in pending { byID[id] = (title, modified) }
      self.catalog.replace(byID.map { EaselCatalog.Entry(url: EaselTab.url(for: $0.key), title: $0.value.0, modifiedAt: $0.value.1) })
      self.refreshCount += 1
      self.task = nil
    }
  }
}
