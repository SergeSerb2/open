import Foundation
import OpenModel
import Observation

public enum LibrarySection: String, CaseIterable, Sendable {
    case spaces, archive, downloads, captures, boosts, media, history
    public var title: String { rawValue.capitalized }
    public var symbol: String { switch self {
    case .spaces: "rectangle.split.3x1"; case .archive: "archivebox"; case .downloads: "arrow.down.circle"; case .captures: "camera"
    case .boosts: "paintbrush.pointed"
    case .media: "photo.on.rectangle"; case .history: "clock"
    } }
}
public enum OriginFilter: String, CaseIterable, Sendable { case all, spaces, littleOpen }
@MainActor public protocol DownloadsProvider: AnyObject {
    var downloads: [DownloadItemSnapshot] { get }
    var downloadHistoryError: String { get }
    func refreshDownloads() async
}
public extension DownloadsProvider {
    var downloadHistoryError: String { "" }
    func refreshDownloads() async {}
}
@MainActor public protocol CapturesProvider: AnyObject { var captures: [CaptureItemSnapshot] { get }; var directory: URL { get }; var loadFailed: Bool { get }; func remove(id: UUID) throws }
public extension CapturesProvider { var loadFailed: Bool { false } }
@MainActor public protocol LibraryActions: AnyObject {
    func setBoostEnabled(id: String, enabled: Bool, profileID: ProfileID)
    func renameBoost(id: String, to name: String, profileID: ProfileID)
    func deleteBoost(id: String, profileID: ProfileID)
    func editBoost(id: String, profileID: ProfileID)
    func restoreArchived(id: ItemID)
    func deleteArchived(id: ItemID)
    func clearArchive()
    func revealDownload(id: String)
    func retryDownload(id: String)
    func cancelDownload(id: String)
    func pauseDownload(id: String)
    func resumeDownload(id: String)
    func openDownload(id: String)
    func copyDownload(id: String)
    func trashDownload(id: String)
    func removeDownload(id: String)
    func deleteCapture(id: UUID)
    func revealCapture(id: UUID)
    func openCapture(id: UUID)
    func copyCapture(id: UUID)
    func saveCapture(id: UUID, to: URL) -> String?
    func openHistoryItem(url: URL)
    func flushHistoryWrites() async
    func viewSpace(id: SpaceID)
}
extension LibraryActions { public func flushHistoryWrites() async {} }

/// The capture feature writes the same epoch-based index. No filesystem folder sources.
@MainActor @Observable public final class FileCapturesProvider: CapturesProvider {
    public let directory: URL
    public let indexURL: URL
    public private(set) var captures: [CaptureItemSnapshot] = []
    public private(set) var loadFailed = false
    /// Keep the provider alive after a read failure so the next Library opening can retry.
    public init(root: URL, loadImmediately: Bool = true) { directory = root.appendingPathComponent("Captures"); indexURL = root.appendingPathComponent("State/captures.json"); if loadImmediately { try? reload() } }
    private var readRevision = 0
    public func refresh() async {
        readRevision += 1
        let revision = readRevision, url = indexURL
        let result = await Task.detached(priority:.utility) { Result { try Self.read(url) } }.value
        guard !Task.isCancelled, revision == readRevision else { return }
        switch result {
        case .success(let next): captures = next; loadFailed = false
        case .failure: captures = []; loadFailed = true
        }
    }
    public func reload() throws {
        readRevision += 1
        do {
            captures = try Self.read(indexURL); loadFailed = false
        } catch { captures = []; loadFailed = true; throw error }
    }
    nonisolated private static func read(_ indexURL:URL) throws -> [CaptureItemSnapshot] {
            // Match the capture writer's 16 MiB input ceiling. A bounded read also
            // refuses a file that grows between opening and reading it.
            let file: FileHandle
            do { file = try FileHandle(forReadingFrom: indexURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
            defer { try? file.close() }
            let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            let next = try decoder.decode([CaptureItemSnapshot].self, from: data)
            guard next.count <= 50_000, next.allSatisfy({ Self.safeName($0.fileName) && ($0.sourceURL?.absoluteString.utf8.count ?? 0) <= CaptureItemSnapshot.maxSourceURLBytes }), Set(next.map(\.id)).count == next.count else { throw CocoaError(.fileReadCorruptFile) }
            return next
    }
    nonisolated public static func safeName(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && URL(fileURLWithPath: name).lastPathComponent == name }
    public func remove(id: UUID) throws {
        try reload()
        guard let item = captures.first(where: { $0.id == id }) else { return }
        let file = directory.appendingPathComponent(item.fileName)
        let tombstone = directory.appendingPathComponent(".delete-\(id.uuidString)")
        let exists = FileManager.default.fileExists(atPath: file.path)
        if exists { try FileManager.default.moveItem(at: file, to: tombstone) }
        let next = captures.filter { $0.id != id }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: indexURL, options: .atomic)
        } catch { if exists { try? FileManager.default.moveItem(at: tombstone, to: file) }; throw error }
        captures = next
        if exists { try? FileManager.default.removeItem(at: tombstone) }
    }
}

// Existing render fixtures do not own downloadable files.
public extension LibraryActions {
    func copyDownload(id: String) {}
    func trashDownload(id: String) {}
}
