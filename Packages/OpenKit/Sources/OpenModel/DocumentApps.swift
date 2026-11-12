import Foundation

/// Settings ▸ Profiles ▸ New documents (Arc's "Default Document App", key
/// `defaultNoteDocumentApp`, docs/re/easels-notes.md §4.2). Options as captured in
/// session 4 (docs/re/easels.md, Notes): Confluence Page, Google Doc, Notion Page,
/// Word Doc; their URLs are Arc's strings (STR `https://confluence.new`,
/// `https://doc.new`, `https://app.notion.com/new`, `https://word.new`). Arc's own
/// Notes option shows "——" in 1.172 (phased out); in Open it is "Note".
public struct DocumentApp: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let url: URL?
    public static let note = DocumentApp(id: "note", title: "Note", url: nil)
    public static let all: [DocumentApp] = [
        note,
        DocumentApp(id: "confluence", title: "Confluence Page", url: URL(string: "https://confluence.new")),
        DocumentApp(id: "google-doc", title: "Google Doc", url: URL(string: "https://doc.new")),
        DocumentApp(id: "notion", title: "Notion Page", url: URL(string: "https://app.notion.com/new")),
        DocumentApp(id: "word", title: "Word Doc", url: URL(string: "https://word.new")),
    ]
    /// Unknown ids (a newer snapshot) fall back to a Note.
    public static func resolve(_ id: String?) -> DocumentApp { all.first { $0.id == id } ?? note }
}
