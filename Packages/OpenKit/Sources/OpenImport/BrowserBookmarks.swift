import Foundation
import OpenModel

/// Source-neutral bookmark tree read from another browser. Value type, Sendable.
/// Folders keep their order; separators are dropped by each reader.
public indirect enum ImportedBookmark: Sendable, Equatable {
    case folder(sourceID: String, title: String, children: [ImportedBookmark])
    case url(sourceID: String, title: String, url: URL, dateAdded: Date?)

    public var urlCount: Int {
        switch self {
        case .url: return 1
        case .folder(_, _, let children): return children.reduce(0) { $0 + $1.urlCount }
        }
    }

    public var folderCount: Int {
        switch self {
        case .url: return 0
        case .folder(_, _, let children): return 1 + children.reduce(0) { $0 + $1.folderCount }
        }
    }
}

public struct ImportedBookmarksReport: Sendable, Equatable {
    public var sourceRows = 0
    public var urls = 0
    public var folders = 0
    public var skippedSeparators = 0
    public var skippedUnsupportedURL = 0
    public var skippedEmptyFolders = 0
    public var skippedOther = 0
    public init() {}
    /// Every source row lands in exactly one bucket. Roots count as folders.
    public var accounted: Int { urls + folders + skippedSeparators + skippedUnsupportedURL + skippedEmptyFolders + skippedOther }
}

/// Arc parity (F3 report §5, lead ruling 1): bookmarks become pinned tabs in one pinned
/// folder "Imported from <Browser>", with the source folder tree nested inside.
/// IDs are deterministic from (browser key, source ID), so a re-import maps to the same items.
public enum ImportedBookmarksFolder {
    public static func title(browserName: String) -> String { "Imported from \(browserName)" }

    public static func itemID(sourceKey: String, sourceID: String) -> ItemID {
        ItemID(rawValue: ArcImporter.deterministicUUID(for: "\(sourceKey):\(sourceID)", namespace: "browser-bookmark"))
    }

    /// Builds the live folder. Empty roots are left out; a single non-empty root is kept as a subfolder
    /// so that its name ("Bookmarks Toolbar") stays visible, as Arc keeps "Bookmarks bar" (guess — capture pending).
    @MainActor
    public static func make(browserName: String, sourceKey: String, roots: [ImportedBookmark], now: Date = Date()) -> Folder {
        func node(_ bookmark: ImportedBookmark) -> SidebarNode? {
            switch bookmark {
            case .url(let id, let title, let url, let added):
                return .tab(Tab(id: itemID(sourceKey: sourceKey, sourceID: id), url: url, title: title, pinnedURL: url,
                                createdAt: added ?? now, lastActiveAt: added ?? now))
            case .folder(let id, let title, let children):
                let nodes = children.compactMap(node)
                guard !nodes.isEmpty else { return nil }
                return .folder(Folder(id: itemID(sourceKey: sourceKey, sourceID: id), title: title, isExpanded: false, children: nodes))
            }
        }
        return Folder(id: itemID(sourceKey: sourceKey, sourceID: "<root>"), title: title(browserName: browserName),
                      isExpanded: false, children: roots.compactMap(node))
    }
}
