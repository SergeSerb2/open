import Foundation

/// One Note: a title and a rich-text body stored as plain text plus format
/// ranges (the same range model Arc uses: one `fullBlob` block per note,
/// docs/re/easels-notes.md §4.4). N1 writes no formats; N2 fills them.
public struct NoteDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var title: String
    public var text: String
    public var formats: [NoteFormat]
    public var createdAt: Date
    public var modifiedAt: Date
    /// Set on a Note that Import from Arc created without its text (Arc kept it on its servers).
    /// An imported Arc Notes export may replace such a Note; an edit clears the flag.
    public var importPlaceholder: Bool?

    public init(id: UUID = UUID(), title: String = "", text: String = "", formats: [NoteFormat] = [],
                createdAt: Date = Date(), modifiedAt: Date? = nil) {
        formatVersion = 1
        self.id = id; self.title = title; self.text = text; self.formats = formats
        self.createdAt = createdAt; self.modifiedAt = modifiedAt ?? createdAt
    }
}

/// A format over a UTF-16 range of `NoteDocument.text`.
public struct NoteFormat: Codable, Equatable, Sendable {
    /// bold, italic, underline, strikethrough, h1, h2, h3, link, bulletList, numberedList, image.
    public var type: String
    public var location: Int
    public var length: Int
    public var url: String?
    public var level: Int?

    public init(type: String, location: Int, length: Int, url: String? = nil, level: Int? = nil) {
        self.type = type; self.location = location; self.length = length; self.url = url; self.level = level
    }
}

/// The internal tab URL of a Note: `open://note/<lower-case uuid>`.
/// A Note is an ordinary sidebar tab with this URL; the engine never sees it.
public enum NoteLink {
    public static func url(for id: UUID) -> URL { URL(string: "open://note/" + id.uuidString.lowercased())! }
    public static func id(from url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == "open", url.host?.lowercased() == "note" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
    public static func matches(_ url: URL?) -> Bool { id(from: url) != nil }
}
