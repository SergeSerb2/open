import AppKit
import OpenEasel
import OpenFeatures
import OpenModel

/// Easel row actions: rename (row and canvas title stay one value), save as a web page,
/// delete permanently, and export every Easel (Library › Easels, Arc 1.172).
extension EngineWebContentHostFactory {
  /// Inline row rename sets the Easel's title (the canvas title field shows it too).
  func renameEasel(tabID: ItemID, title: String) -> Bool {
    guard let tab = model.tab(id: tabID), let documentID = EaselTab.documentID(tab.url) else { return false }
    let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EaselDocument.maxTitleLength))
    if let host = easelHosts[tabID], !host.closed {
      host.canvas.setTitle(trimmed)
    } else {
      var doc = app.easels.load(documentID) ?? EaselDocument(id: documentID)
      doc.title = trimmed.isEmpty ? nil : trimmed
      doc.modifiedAt = Date()
      app.easels.save(doc)
    }
    tab.customTitle = nil
    tab.title = trimmed.isEmpty ? EaselDocument.untitled : trimmed
    controller?.refresh(); scheduleSave()
    return true
  }

  func easelExportItem(_ tab: Tab) -> EaselExporter.Item? {
    guard let documentID = EaselTab.documentID(tab.url) else { return nil }
    if let host = easelHosts[tab.id], !host.closed { host.canvas.commitPendingEdits() }
    app.easels.flush()
    let doc = app.easels.load(documentID) ?? EaselDocument(id: documentID, title: tab.title == EaselDocument.untitled ? nil : tab.title)
    return EaselExporter.Item(document: doc, imagesDirectory: app.easels.imagesDirectory(for: documentID))
  }

  /// Save as Web Page…: a save panel for a folder with `index.html`, `easel.json`, `images/`.
  func exportEasel(tabID: ItemID, to destination: URL? = nil) -> Bool {
    guard let tab = model.tab(id: tabID), let item = easelExportItem(tab) else { return false }
    func write(_ url: URL) {
      do {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        try EaselExporter.export(item, to: url)
        lastEaselExport = url.path
        controller?.toasts.show(ToastContent(title: "Easel Saved"))
      } catch {
        lastEaselExport = nil
        controller?.toasts.show(ToastContent(title: "Could not save the Easel. \(error)"))
      }
    }
    if let destination { write(destination); return true }
    guard let window else { return false }
    let panel = NSSavePanel()
    panel.message = "Save this Easel as a web page you can open anywhere."
    panel.nameFieldStringValue = EaselExporter.folderName(item.document.displayTitle)
    panel.prompt = "Save"
    easelSavePanel = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      self?.easelSavePanel = nil
      if response == .OK, let url = panel.url { write(url) }
    }
    return true
  }

  /// Delete Easel (C-measurements-s4): "Are you sure you want to delete this Easel?" /
  /// "Doing so will delete the Easel permanently." The row goes (not to the Archive) and the
  /// Easel's folder moves to the Trash.
  func confirmDeleteEasel(tabID: ItemID) -> Bool {
    guard model.tab(id: tabID) != nil, let window else { return false }
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to delete this Easel?"
    alert.informativeText = "Doing so will delete the Easel permanently."
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    easelDeleteAlert = alert
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.easelDeleteAlert = nil
      if response == .alertFirstButtonReturn { self?.deleteEasel(tabID: tabID) }
    }
    return true
  }

  func deleteEasel(tabID: ItemID) {
    guard let tab = model.tab(id: tabID), let documentID = EaselTab.documentID(tab.url) else { return }
    if let host = easelHosts[tabID] { controller?.container.closeHost(for: tabID); host.close() }
    // Removal is not an Archive entry: the content is gone.
    let undo = model.undoManager; undo?.disableUndoRegistration()
    model.closeTab(id: tabID)
    undo?.enableUndoRegistration()
    model.archiveSink?.discardArchived(ids: [tabID])
    app.easels.flush()
    let folder = app.easels.fileURL(for: documentID).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    controller?.refresh(); scheduleSave()  // the tree change syncs the tab mirror
  }
}

extension AppDelegate {
  /// Every Easel of every Profile (sidebar rows), for Export All Easels.
  func allEaselItems() -> [EaselExporter.Item] {
    var seen = Set<UUID>(), items: [EaselExporter.Item] = []
    for factory in hostFactories.values { for host in factory.easelHosts.values { host.canvas.commitPendingEdits() } }
    easels.flush()
    func visit(_ tabs: [Tab]) {
      for tab in tabs {
        guard let id = EaselTab.documentID(tab.url), seen.insert(id).inserted else { continue }
        let doc = easels.load(id) ?? EaselDocument(id: id, title: tab.title == EaselDocument.untitled ? nil : tab.title)
        items.append(EaselExporter.Item(document: doc, imagesDirectory: easels.imagesDirectory(for: id)))
      }
    }
    for space in model.spaces {
      func flat(_ nodes: [SidebarNode]) -> [Tab] {
        nodes.flatMap { node -> [Tab] in
          switch node { case .tab(let t): [t]; case .folder(let f): flat(f.children); case .split(let s): s.panes }
        }
      }
      visit(flat(space.pinned + space.today))
    }
    return items
  }

  /// Export All Easels into `folder` (created). Returns (written, failures).
  func exportAllEasels(to folder: URL) throws -> (Int, [String]) {
    var failures: [String] = []
    let count = try EaselExporter.exportAll(allEaselItems(), to: folder, failures: &failures)
    return (count, failures)
  }
}
