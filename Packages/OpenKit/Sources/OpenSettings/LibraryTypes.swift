import Foundation
import OpenModel

public enum LibrarySection: String, CaseIterable, Sendable {
    case archive, downloads, captures, media, history
    public var title: String { rawValue.capitalized }
    public var symbol: String { switch self {
    case .archive: "archivebox"; case .downloads: "arrow.down.circle"; case .captures: "camera"
    case .media: "photo.on.rectangle"; case .history: "clock"
    } }
}
public enum OriginFilter: String, CaseIterable, Sendable { case all, spaces, littleOpen }
@MainActor public protocol DownloadsProvider: AnyObject { var downloads: [DownloadItemSnapshot] { get } }
@MainActor public protocol CapturesProvider: AnyObject { var captures: [CaptureItemSnapshot] { get }; var directory: URL { get } }
@MainActor public protocol LibraryActions: AnyObject {
    func restoreArchived(id: ItemID)
    func deleteArchived(id: ItemID)
    func clearArchive()
    func revealDownload(id: String)
    func retryDownload(id: String)
    func cancelDownload(id: String)
    func pauseDownload(id: String)
    func resumeDownload(id: String)
    func openDownload(id: String)
    func removeDownload(id: String)
    func deleteCapture(id: UUID)
    func revealCapture(id: UUID)
    func openCapture(id: UUID)
    func copyCapture(id: UUID)
    func saveCapture(id: UUID, to: URL) -> String?
    func openHistoryItem(url: URL)
    func viewSpace(id: SpaceID)
}
