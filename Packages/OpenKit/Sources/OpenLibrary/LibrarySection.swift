import AppKit
import OpenSettings

/// Presentation order is independent of the legacy source list and its raw IDs.
public enum LibraryPanelSection: String, CaseIterable, Sendable {
    case media, downloads, easels, spaces, boosts, archive, history

    public var title: String {
        switch self {
        case .media: "Media"
        case .downloads: "Downloads"
        case .easels: "Easels"
        case .spaces: "Spaces"
        case .boosts: "Boosts"
        case .archive: "Archived Tabs"
        case .history: "History"
        }
    }
    public var modelSection: LibrarySection? { self == .easels ? nil : LibrarySection(rawValue: rawValue) }
    public init(_ section: LibrarySection) { self = section == .captures ? .media : Self(rawValue: section.rawValue) ?? .downloads }
    var hasFilter: Bool { self == .downloads || self == .archive || self == .history }
    var placeholder: String { "Search \(self == .archive ? "Archive" : title)…" }
    var emptyCopy: (title: String, body: String, button: String?) {
        switch self {
        case .media: ("No media yet", "Page captures you take appear here.", nil)
        case .downloads: ("No downloads yet", "Files you download appear here.", nil)
        case .easels: ("No Easels yet", "Press + in the sidebar to start one.", nil)
        case .spaces: ("No Spaces yet", "Your Spaces appear here.", nil)
        case .boosts: ("No Boosts yet", "Open a site and choose Boost to change how it looks.", nil)
        case .archive: ("Nothing archived yet", "Tabs you close, and tabs that Open tidies away, appear here.", "Learn more")
        case .history: ("No history yet", "Pages you visit appear here.", nil)
        }
    }
    public static func visible(in defaults: UserDefaults) -> [Self] {
        allCases.filter { $0 != .easels || defaults.bool(forKey: "libraryShowsEasels") }
    }
}
