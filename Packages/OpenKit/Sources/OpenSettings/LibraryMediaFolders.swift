import Foundation
import Observation
import UniformTypeIdentifiers

/// Library folder sources (Arc LB-1; `StorableHome.json` `dataSourcePreferences` =
/// documents, screenshot, desktop, download, capture, all on by default). Arc's sidebar
/// Library-button menu lists them as "Show media from:" Documents · Desktop · Screenshots ·
/// Captures · Downloads (capture C-report-s3 Part D). Files from folders can only be hidden,
/// never deleted (LB-2). The populated Media look is not captured (it needs folder consent):
/// rows reuse the existing Library media row (GUESS — capture pending).
public enum LibraryMediaSource: String, CaseIterable, Codable, Sendable {
    case documents, desktop, screenshot, capture, download
    /// Arc's menu order.
    public static let menuOrder: [LibraryMediaSource] = [.documents, .desktop, .screenshot, .capture, .download]
    public var title: String {
        switch self {
        case .documents: "Documents"; case .desktop: "Desktop"; case .screenshot: "Screenshots"
        case .capture: "Captures"; case .download: "Downloads"
        }
    }
}

public struct LibraryMediaFile: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let date: Date
    public let source: LibraryMediaSource
}

/// Folder locations. The App passes the user's folders; automation passes fixture folders,
/// so tests never touch the user's files or trigger a folder-consent prompt.
public struct LibraryMediaFolders: Sendable {
    public var documents: URL, desktop: URL, downloads: URL, screenshots: URL
    public init(documents: URL, desktop: URL, downloads: URL, screenshots: URL) {
        self.documents = documents; self.desktop = desktop; self.downloads = downloads; self.screenshots = screenshots
    }
    public static func user() -> LibraryMediaFolders {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop")
        // macOS keeps the screenshot folder in com.apple.screencapture `location`; Desktop by default.
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return LibraryMediaFolders(
            documents: fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Documents"),
            desktop: desktop,
            downloads: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads"),
            screenshots: location ?? desktop)
    }
    /// A fixture root with Documents, Desktop, Downloads and Screenshots subfolders.
    public static func fixture(root: URL) -> LibraryMediaFolders {
        LibraryMediaFolders(documents: root.appendingPathComponent("Documents"), desktop: root.appendingPathComponent("Desktop"),
                            downloads: root.appendingPathComponent("Downloads"), screenshots: root.appendingPathComponent("Screenshots"))
    }
}

@MainActor @Observable public final class LibraryMediaFoldersProvider {
    /// Bounds: at most this many newest files per folder, top level only, and this many hidden paths.
    nonisolated public static let perFolderLimit = 500
    nonisolated public static let hiddenLimit = 10_000
    nonisolated static let stateLimit = 2 * 1024 * 1024

    struct State: Codable, Equatable {
        var version = 1
        var onboarded = false
        var sources: [String: Bool] = [:]
        var hidden: [String] = []
    }

    public let folders: LibraryMediaFolders
    public let stateURL: URL
    public private(set) var files: [LibraryMediaFile] = []
    public private(set) var onboarded = false
    public private(set) var enabled: Set<LibraryMediaSource> = Set(LibraryMediaSource.allCases)
    public private(set) var hidden: Set<String> = []
    public private(set) var scanCount = 0
    /// Called after a source or onboarding change (the App refreshes sidebar menus and the Library).
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private var revision = 0

    public init(stateURL: URL, folders: LibraryMediaFolders) {
        self.stateURL = stateURL; self.folders = folders
        if let state = Self.load(stateURL) {
            onboarded = state.onboarded
            enabled = Set(LibraryMediaSource.allCases.filter { state.sources[$0.rawValue] ?? true })
            hidden = Set(state.hidden.prefix(Self.hiddenLimit))
        }
    }

    public func isEnabled(_ source: LibraryMediaSource) -> Bool { enabled.contains(source) }

    public func setEnabled(_ source: LibraryMediaSource, _ on: Bool) {
        if on { enabled.insert(source) } else { enabled.remove(source) }
        save(); onChange?()
    }
    /// "Choose Folders…" on the Media first-use card. Reading the folders afterwards is what makes
    /// macOS ask for Desktop/Documents/Downloads access (Info.plist usage strings).
    public func markOnboarded() {
        guard !onboarded else { return }
        onboarded = true; save(); onChange?()
    }
    public func hide(_ file: LibraryMediaFile) {
        guard hidden.count < Self.hiddenLimit else { return }
        hidden.insert(file.url.path); files.removeAll { $0.url == file.url }; save()
    }

    /// Scans the enabled folders off the main thread. Nothing is read before onboarding.
    public func refresh() async {
        revision += 1
        let token = revision
        guard onboarded else { files = []; return }
        let folders = folders, enabled = enabled, hidden = hidden
        let next = await Task.detached(priority: .utility) { Self.scan(folders: folders, enabled: enabled, hidden: hidden) }.value
        guard token == revision, !Task.isCancelled else { return }
        files = next; scanCount += 1
    }

    nonisolated static func scan(folders: LibraryMediaFolders, enabled: Set<LibraryMediaSource>, hidden: Set<String>) -> [LibraryMediaFile] {
        var byPath: [String: LibraryMediaFile] = [:]
        // Screenshots first, so a screenshot on the Desktop belongs to the Screenshots source.
        let order: [(LibraryMediaSource, URL)] = [(.screenshot, folders.screenshots), (.desktop, folders.desktop),
                                                 (.documents, folders.documents), (.download, folders.downloads)]
        var claimed = Set<String>()
        for (folderSource, folder) in order {
            for file in listMedia(in: folder, source: folderSource) where !claimed.contains(file.url.path) {
                // A screen capture belongs to Screenshots wherever it is; other files in the
                // screenshot folder belong to the folder they are in (a later pass).
                let screenshot = isScreenCapture(file.url)
                if folderSource == .screenshot && !screenshot { continue }
                claimed.insert(file.url.path)
                let source: LibraryMediaSource = screenshot ? .screenshot : folderSource
                guard enabled.contains(source), !hidden.contains(file.url.path) else { continue }
                byPath[file.url.path] = LibraryMediaFile(url: file.url, name: file.name, date: file.date, source: source)
            }
        }
        return byPath.values.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
    }

    nonisolated static func listMedia(in folder: URL, source: LibraryMediaSource) -> [LibraryMediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .contentModificationDateKey, .creationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [LibraryMediaFile] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true, let type = values.contentType,
                  type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
            result.append(LibraryMediaFile(url: url, name: url.lastPathComponent, date: date, source: source))
        }
        result.sort { $0.date > $1.date }
        return Array(result.prefix(perFolderLimit))
    }

    /// Finder marks screenshots with `kMDItemIsScreenCapture` (an extended attribute on the file).
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) > 0
        }
    }

    private static func load(_ url: URL) -> State? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: stateLimit + 1), data.count <= stateLimit,
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 else { return nil }
        return state
    }
    private func save() {
        let state = State(onboarded: onboarded,
                          sources: Dictionary(uniqueKeysWithValues: LibraryMediaSource.allCases.map { ($0.rawValue, enabled.contains($0)) }),
                          hidden: hidden.sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}
