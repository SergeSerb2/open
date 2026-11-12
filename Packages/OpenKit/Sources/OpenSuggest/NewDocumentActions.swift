import Foundation

/// Command-bar actions from Arc's "Action to create a new document; e.g. 'New Google Doc'" and
/// "Action to undo/redo an action by name" (Arc 1.170.0 strings 555715, 555750–555751).
/// URLs are Arc's own new-document table (strings 543213–543224, 537278–537290). Titles: "New " +
/// the service name from Arc's split small-string immediates ("Google S|lide", "Figma Do|cument",
/// "FigJam", "Notion P|age", "Word Doc", "Confluen|ce Page", "Linear I|ssue"). GUESS — capture
/// C3-PB1-h pending: "Google Sheet", "Google Meet", "Replit" (fragments "Google D/M", "Repl").
public enum NewDocumentActions {
    public static let undoByNameID = "undo-by-name"
    public static let redoByNameID = "redo-by-name"

    public struct Entry: Sendable {
        public let id: String, title: String, url: URL, aliases: [String]
    }

    public static let entries: [Entry] = [
        entry("google-doc", "Google Doc", "https://doc.new", ["Google Docs", "Docs", "Document"]),
        entry("google-sheet", "Google Sheet", "https://sheet.new", ["Google Sheets", "Spreadsheet", "Sheets"]),
        entry("google-slide", "Google Slide", "https://slide.new", ["Google Slides", "Slides", "Presentation"]),
        entry("google-meet", "Google Meet", "https://meet.new", ["Meeting", "Meet"]),
        entry("figma-document", "Figma Document", "https://figma.new", ["Figma", "Figma File", "Design"]),
        entry("figjam", "FigJam", "https://figjam.new", ["Whiteboard", "FigJam Board"]),
        entry("notion-page", "Notion Page", "https://app.notion.com/new", ["Notion"]),
        entry("word-doc", "Word Doc", "https://word.new", ["Word", "Microsoft Word"]),
        entry("confluence-page", "Confluence Page", "https://confluence.new", ["Confluence"]),
        entry("linear-issue", "Linear Issue", "https://linear.app/new", ["Linear", "Issue"]),
        entry("replit", "Replit", "https://replit.com/new", ["Repl"]),
    ]

    private static func entry(_ key: String, _ name: String, _ url: String, _ aliases: [String]) -> Entry {
        Entry(id: "new-document-" + key, title: "New " + name, url: URL(string: url)!,
              aliases: ["Create " + name] + aliases.map { "New " + $0 })
    }

    public static func url(for actionID: String) -> URL? { entries.first { $0.id == actionID }?.url }

    public static var actions: [BrowserAction] {
        entries.map { BrowserAction(id: $0.id, title: $0.title, aliases: $0.aliases, symbol: "doc.badge.plus") }
    }
}
