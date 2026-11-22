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
    let trimmed = EaselDocument.clipped(title.trimmingCharacters(in: .whitespacesAndNewlines), utf16: EaselDocument.maxTitleLength)
    if let host = easelHosts[tabID], !host.closed {
      host.canvas.setTitle(trimmed)
    } else {
      var doc = app.easels.load(documentID) ?? EaselDocument(id: documentID)
      doc.title = trimmed.isEmpty ? nil : trimmed
      doc.modifiedAt = Date()
      app.easels.save(doc)
      // An open canvas of another row of this Easel shows the new title too.
      app.easelDidChange(doc, from: nil, titleChanged: true)
    }
    tab.customTitle = nil
    tab.title = trimmed.isEmpty ? EaselDocument.untitled : trimmed
    controller?.refresh(); scheduleSave()
    return true
  }

  /// Copy Link on an Easel row: its own address; "Copied Easel URL" (Arc toast string).
  func copyEaselLink(tabID: ItemID) -> Bool {
    guard let tab = model.tab(id: tabID), EaselTab.matches(tab.url) else { return false }
    NSPasteboard.general.clearContents()
    let copied = NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
    if copied, controller?.window?.isKeyWindow == true { controller?.toasts.show(ToastContent(title: "Copied Easel URL")) }
    return copied
  }

  /// Shows an Easel: its row (any Space of this window's model), or a new row at the top of
  /// Today in the focused Space for an Easel that has none. False for an unknown document.
  @discardableResult
  func showEasel(documentID: UUID) -> Bool {
    if let tab = easelRow(documentID: documentID), selectDocumentRow(tab) { return true }
    guard !isIncognito, let space = focusedSpace, app.easels.exists(documentID) else { return false }
    let title = app.easels.load(documentID)?.displayTitle ?? EaselDocument.untitled
    let tab = model.newTab(in: space.id, url: EaselTab.url(for: documentID), title: title, at: 0)
    tab.live.faviconPNG = EaselIcon.faviconPNG
    select(nodeID: tab.id)
    scheduleSave()
    return true
  }

  /// Shows an Easel or Note row. A Favorite of another Profile shows in a Space of that Profile
  /// (a Favorite is visible only with its own Profile). False when that Profile has no Space:
  /// the caller then adds a row in the focused Space.
  func selectDocumentRow(_ tab: Tab) -> Bool {
    guard case .favorites(let profileID)? = model.parent(of: tab.id), focusedSpace?.profileID != profileID else {
      selectTabForCommand(tab.id); return true
    }
    guard let space = model.mostRecentlyFocusedSpace(profileID: profileID) ?? model.spaces.first(where: { $0.profileID == profileID })
    else { return false }
    selectTabForCommand(tab.id, spaceID: space.id)
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

  /// The Easel goes, with every row of it (a duplicate row or a Favorite shows the same Easel),
  /// like Delete Note.
  func deleteEasel(tabID: ItemID) {
    guard let tab = model.tab(id: tabID), let documentID = EaselTab.documentID(tab.url) else { return }
    app.deleteEaselEverywhere(documentID)
  }
}

extension AppDelegate {
  /// Closes every open canvas of an Easel in every window. Several rows can show one Easel (a
  /// duplicate row, a Favorite), each with its own canvas; one left open would later write its
  /// older copy over the file. Closing commits pending edits and queues their write.
  func closeEaselHosts(documentID: UUID) {
    for factory in hostFactories.values {
      for (rowID, host) in factory.easelHosts where host.documentID == documentID {
        factory.controller?.container.closeHost(for: rowID); host.close()
      }
    }
  }

  /// A canvas saved `doc`: every other open canvas of the Easel shows it. With `titleChanged`,
  /// every row of the Easel takes its title (also rows whose canvas is not open).
  func easelDidChange(_ doc: EaselDocument, from source: EaselContentHost?, titleChanged: Bool) {
    for factory in hostFactories.values {
      for host in factory.easelHosts.values where host !== source && host.documentID == doc.id { host.showSaved(doc) }
    }
    guard titleChanged else { return }
    var models = Set<ObjectIdentifier>(), changed = false
    for factory in hostFactories.values where models.insert(ObjectIdentifier(factory.model)).inserted {
      for tab in factory.model.allTabsForNotes() where EaselTab.documentID(tab.url) == doc.id && tab.title != doc.displayTitle {
        tab.title = doc.displayTitle; changed = true
      }
    }
    guard changed else { return }
    for factory in hostFactories.values { factory.controller?.refresh(); factory.scheduleSave() }
  }

  /// Runs a removal that can take the selected tab of any window (standard windows share one
  /// model): each window then selects the tab that took its place, as the sidebar's Close does.
  func keepingSelectionInEveryWindow(_ removal: () -> Void) {
    let controllers = hostFactories.values.compactMap(\.controller)
    func run(_ index: Int) {
      guard index < controllers.count else { removal(); return }
      controllers[index].keepingSelection { run(index + 1) }
    }
    run(0)
  }

  /// Removes every row of an Easel in every window (no Archive entry) and moves its folder to the
  /// Trash once, after every canvas of it has closed and written.
  func deleteEaselEverywhere(_ documentID: UUID) {
    closeEaselHosts(documentID: documentID)
    keepingSelectionInEveryWindow {
      for factory in hostFactories.values {
        for tab in factory.model.allTabsForNotes() where EaselTab.documentID(tab.url) == documentID {
          // Removal is not an Archive entry: the content is gone.
          let undo = factory.model.undoManager; undo?.disableUndoRegistration()
          factory.model.closeTab(id: tab.id)
          undo?.enableUndoRegistration()
          factory.model.archiveSink?.discardArchived(ids: [tab.id])
        }
        factory.controller?.refresh(); factory.scheduleSave()  // the tree change syncs the tab mirror
      }
    }
    easels.flush()
    // A copy whose write failed is queued again; it must not bring the trashed folder back.
    easels.discard(documentID)
    let folder = easels.fileURL(for: documentID).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    discardArchivedRows(url: EaselTab.url(for: documentID))
  }
}

extension AppDelegate {
  /// Every Easel (sidebar rows first, then documents without a row), for Export All Easels.
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
    // Easels whose row or Space is gone are still the user's (Library › Easels lists them).
    for entry in EaselStore.readIndex(directory: easels.directory) where seen.insert(entry.id).inserted {
      guard let doc = easels.load(entry.id) else { continue }
      items.append(EaselExporter.Item(document: doc, imagesDirectory: easels.imagesDirectory(for: entry.id)))
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
