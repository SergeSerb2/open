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
    let (notes, _) = app.notes.allNotes()
    return notes.sorted { $0.modifiedAt > $1.modifiedAt }.map { note in
      let preview = note.text.replacingOccurrences(of: "\u{FFFC}", with: "").split(whereSeparator: \.isNewline)
        .first.map { String($0.prefix(80)) } ?? ""
      return LibraryNoteItem(id: note.id.uuidString.lowercased(), title: note.title, preview: preview, modifiedAt: note.modifiedAt)
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
    if let tab = model.allTabsForNotes().first(where: { NoteLink.id(from: $0.url) == noteID }) { selectTabForCommand(tab.id); return true }
    guard !isIncognito, let space = focusedSpace, let note = app.notes.load(noteID) else { return false }
    let tab = model.newTab(in: space.id, url: NoteLink.url(for: noteID), title: note.title.isEmpty ? NoteTab.untitled : note.title, at: 0)
    tab.live.faviconPNG = NoteTab.faviconPNG
    select(nodeID: tab.id); scheduleSave()
    return true
  }
}
