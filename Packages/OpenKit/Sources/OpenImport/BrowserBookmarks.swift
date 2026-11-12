import Foundation

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

extension ImportedBookmark {
    /// One builder for the "Imported from <Browser>" folder: `BrowserBookmarksImport.sourceModel`
    /// (IMC). Firefox and Safari trees convert to its node type; source IDs become its GUIDs.
    public var chromium: ChromiumBookmark {
        switch self {
        case .folder(let id, let title, let children): .folder(guid: id, title: title, children: children.map(\.chromium))
        case .url(let id, let title, let url, let added): .url(guid: id, title: title, url: url, added: added)
        }
    }
}
