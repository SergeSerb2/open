import AppKit
import OpenDocuments
import OpenFeatures
import OpenModel

/// Note row actions (sidebar row menu): rename (row and Note title stay one value),
/// export one Note, delete it permanently. Mirrors the Easel row (EaselRowActions).
extension EngineWebContentHostFactory {
  /// Inline row rename sets the Note's title; a shown editor shows it at once.
  func renameNote(tabID: ItemID, title: String) -> Bool {
    guard let tab = model.tab(id: tabID), let noteID = NoteLink.id(from: tab.url) else { return false }
    let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).joined(separator: " ").prefix(1_000))
    if let host = noteHosts[tabID], !host.closed { host.setTitle(trimmed) }
    else if !app.notes.isUnreadable(noteID) {
      var note = app.notes.document(noteID)
      note.title = trimmed; note.importPlaceholder = nil
      app.notes.update(note); app.notes.flush()
    }
    app.notes.flush()   // a rename is one discrete action: write it now
    tab.customTitle = nil
    tab.title = trimmed.isEmpty ? NoteTab.untitled : trimmed
    controller?.refresh(); scheduleSave()
    return true
  }

  /// Export Note…: one self-contained HTML page (images inline), like one file of Export Notes.
  @discardableResult
  func exportNote(tabID: ItemID, to destination: URL? = nil) -> Bool {
    guard let tab = model.tab(id: tabID), let noteID = NoteLink.id(from: tab.url) else { return false }
    app.notes.flush()
    let note = app.notes.load(noteID) ?? NoteDocument(id: noteID, title: tab.title == NoteTab.untitled ? "" : tab.title)
    let store = app.notes
    func write(_ url: URL) {
      let html = NoteExport.html(note) { name in
        guard let file = store.assetURL(note: noteID, name: name), let data = try? Data(contentsOf: file) else { return nil }
        return (data, file.pathExtension == "jpg" || file.pathExtension == "jpeg" ? "image/jpeg" : "image/" + file.pathExtension)
      }
      do {
        try Data(html.utf8).write(to: url, options: .atomic)
        lastNoteExport = url.path
        controller?.toasts.show(ToastContent(title: "Note Saved"))   // GUESS: our wording, like "Easel Saved"
      } catch {
        lastNoteExport = nil
        controller?.toasts.show(ToastContent(title: "Notes export failed."))
      }
    }
    if let destination { write(destination); return true }
    guard let window else { return false }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.message = "Save this Note as a web page you can open anywhere."
    var used = Set<String>()
    panel.nameFieldStringValue = NoteExport.fileName(for: note, used: &used) + ".html"
    panel.prompt = "Save"
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { MainActor.assumeIsolated { write(url) } }
    }
    return true
  }

  /// Delete Note, worded like Delete Easel (C-measurements-s4; the Note texts are GUESS).
  func confirmDeleteNote(tabID: ItemID) -> Bool {
    guard model.tab(id: tabID) != nil, let window else { return false }
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to delete this Note?"
    alert.informativeText = "Doing so will delete the Note permanently."
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { MainActor.assumeIsolated { self?.deleteNote(tabID: tabID) } }
    }
    return true
  }

  /// The row goes (not to the Archive); the Note file and its images move to the Trash.
  /// Other rows of the same Note (a duplicate) go too: the content is gone.
  func deleteNote(tabID: ItemID) {
    guard let tab = model.tab(id: tabID), let noteID = NoteLink.id(from: tab.url) else { return }
    app.deleteNoteEverywhere(noteID)
  }
}

extension AppDelegate {
  /// Removes every row of a Note in every window (no Archive entry) and trashes its files.
  func deleteNoteEverywhere(_ noteID: UUID) {
    for factory in hostFactories.values {
      for tab in factory.model.allTabsForNotes() where NoteLink.id(from: tab.url) == noteID {
        if let host = factory.noteHosts[tab.id] { factory.controller?.container.closeHost(for: tab.id); host.close() }
        let undo = factory.model.undoManager; undo?.disableUndoRegistration()
        factory.model.closeTab(id: tab.id)
        undo?.enableUndoRegistration()
        factory.model.archiveSink?.discardArchived(ids: [tab.id])
      }
      factory.controller?.refresh(); factory.scheduleSave()
    }
    notes.delete(noteID)
  }
}
