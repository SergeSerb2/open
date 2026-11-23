import AppKit
import OpenDocuments
import OpenLibrary
import OpenModel

/// Library › Easels, Notes half (NT): every Note file of the data root, newest first.
/// Open selects the Note's row, or adds one at the top of Today in the focused Space.
@MainActor
final class NoteLibraryProvider: LibraryNotesProvider {
  unowned let app: AppDelegate
  weak var controller: BrowserWindowController?
  init(app: AppDelegate) { self.app = app }

  var factory: EngineWebContentHostFactory? {
    controller.flatMap { app.hostFactories[$0.windowID] } ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
  }

  func libraryNotes() async -> [LibraryNoteItem] {
    // Unsaved edits first, then the files off the main thread, as Library ▸ Easels does (bug sweep r6 CF-12).
    app.notes.flush()
    let directory = app.notes.directory
    let rows = await Task.detached(priority: .userInitiated) { NoteStore.librarySummaries(directory: directory) }.value
    return rows.sorted { $0.modifiedAt > $1.modifiedAt }.map { note in
      LibraryNoteItem(id: note.id.uuidString.lowercased(), title: note.title, preview: note.preview, modifiedAt: note.modifiedAt)
    }
  }

  func openNote(id: String) {
    guard let noteID = UUID(uuidString: id), let factory else { return }
    app.settingsPresenter.closeLibrary()
    factory.showNote(noteID: noteID)
  }

  func deleteNote(id: String) {
    guard let noteID = UUID(uuidString: id) else { return }
    app.deleteNoteEverywhere(noteID)
  }
}

extension EngineWebContentHostFactory {
  /// Shows a Note: its row (any Space of this window's model), or a new row at the top of Today.
  @discardableResult
  func showNote(noteID: UUID) -> Bool {
    // Prefer a row this Profile shows; a Favorite of another Profile switches to that Profile's Space.
    let rows = model.allTabsForNotes().filter { NoteLink.id(from: $0.url) == noteID }
    let visible = rows.first { tab in
      guard case .favorites(let profileID)? = model.parent(of: tab.id) else { return true }
      return profileID == focusedSpace?.profileID
    }
    if let tab = visible ?? rows.first, selectDocumentRow(tab) { return true }
    guard !isIncognito, let space = focusedSpace, let note = app.notes.load(noteID) else { return false }
    let tab = model.newTab(in: space.id, url: NoteLink.url(for: noteID), title: note.title.isEmpty ? NoteTab.untitled : note.title, at: 0)
    tab.live.faviconPNG = NoteTab.faviconPNG
    select(nodeID: tab.id); scheduleSave()
    return true
  }
}
