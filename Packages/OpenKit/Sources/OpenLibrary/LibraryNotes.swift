import AppKit

/// One Note in Library › Easels (Arc's "Easels & Notes" page: `EaselsAndNotesContentView`,
/// sources `EaselLibraryClient` + `DocumentsLibraryClient`, delete allowed, hide not;
/// docs/re/easels-notes.md §5). Every Note file of the data root, also those whose row is gone.
public struct LibraryNoteItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var preview: String
    public var modifiedAt: Date
    public init(id: String, title: String, preview: String, modifiedAt: Date) {
        self.id = id; self.title = title; self.preview = preview; self.modifiedAt = modifiedAt
    }
}

/// The App's Notes side of the Library (NT). The Library draws; the App reads files, opens and deletes.
@MainActor
public protocol LibraryNotesProvider: AnyObject {
    func libraryNotes() async -> [LibraryNoteItem]
    /// Opens the Note in the window (its row, or a new row at the top of Today in the focused Space).
    func openNote(id: String)
    /// Deletes the Note permanently (rows without an Archive entry, the file to the Trash).
    func deleteNote(id: String)
}

@MainActor
extension LibraryPanelView {
    /// Note rows of the Easels page. Arc's card menu has one item, "Delete" (docs/re/easels.md).
    func noteSources() -> [LibraryRowSource] {
        noteItems.map { item in
            let title = item.title.isEmpty ? "Untitled" : item.title
            let subtitle = "Note · \(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))" + (item.preview.isEmpty ? "" : " · " + item.preview)
            return LibraryRowSource(id: "note-" + item.id, date: item.modifiedAt, text: title + " " + item.preview, prepareText: {
                LibraryRowText(title: title, subtitle: subtitle)
            }) { [unowned self] prepared in
                let id = item.id
                return LibraryRowItem(id: "note-" + id, title: title, subtitle: prepared?.subtitle ?? subtitle, kind: "note",
                    image: symbol("note.text"),
                    activate: { [weak self] in self?.notesProvider?.openNote(id: id) },
                    actions: [.init(title: "Delete", run: { [weak self] in
                        // GUESS: worded like the Easel delete (no Note alert is captured).
                        self?.confirm("Are you sure you want to delete this Note?", message: "Doing so will delete the Note permanently.") { [weak self] in
                            self?.notesProvider?.deleteNote(id: id); self?.reloadEasels()
                        }
                    })])
            }
        }
    }

    /// Easel and Note rows together, newest first.
    func easelAndNoteSources() -> [LibraryRowSource] {
        (easelSources() + noteSources()).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
