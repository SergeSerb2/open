import AppKit
import OpenFeatures
import OpenSettings

/// Writes captures into the Library (page-platform §4.6.6, settings-library §2.6):
/// `<root>/Captures/<uuid>.png` and one row appended to `<root>/State/captures.json`.
/// The PNG is written off the main actor; the index read-modify-write runs on the main actor,
/// the same actor as the Library's own reader and remover (`FileCapturesProvider`), so the two
/// never interleave. The index is replaced atomically (a temporary file, then rename(2)).
@MainActor
final class CaptureLibraryWriter: CaptureLibrary {
  /// The index is refused over this size (about 80,000 rows), and appending stops at `maxRows`.
  static let maxIndexBytes = 16 * 1024 * 1024
  static let maxRows = 50_000
  unowned let app: AppDelegate
  let root: URL
  var directory: URL { root.appendingPathComponent("Captures", isDirectory: true) }
  var indexURL: URL { root.appendingPathComponent("State/captures.json") }
  private(set) var saveCount = 0

  init(app: AppDelegate, root: URL) { self.app = app; self.root = root }

  enum Failure: Error, CustomStringConvertible {
    case indexTooLarge, indexFull, indexUnreadable
    var description: String {
      switch self {
      case .indexTooLarge: "The capture index is too large."
      case .indexFull: "The Library holds too many captures."
      case .indexUnreadable: "The capture index could not be read."
      }
    }
  }

  func save(png: Data, kind: CaptureComposer.Kind, sourceHost: String) async throws -> UUID {
    let id = UUID(), folder = directory, file = directory.appendingPathComponent("\(id.uuidString).png")
    try await Task.detached(priority: .utility) {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try png.write(to: file, options: .atomic)
    }.value
    do {
      var rows = try readIndex()
      guard rows.count < Self.maxRows else { throw Failure.indexFull }
      rows.append(CaptureItemSnapshot(id: id, fileName: file.lastPathComponent, createdAt: Date(),
        kind: CaptureKind(rawValue: kind.rawValue) ?? .area, sourceHost: sourceHost))
      try writeIndex(rows)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    saveCount += 1
    // The Library window (if open) shows the new row at once.
    try? app.settingsPresenter.captures?.reload()
    return id
  }

  func readIndex() throws -> [CaptureItemSnapshot] {
    let url = indexURL
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= Self.maxIndexBytes else { throw Failure.indexTooLarge }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
    // A damaged index is never overwritten: the capture is refused instead.
    guard let rows = try? decoder.decode([CaptureItemSnapshot].self, from: Data(contentsOf: url)) else { throw Failure.indexUnreadable }
    return rows
  }

  private func writeIndex(_ rows: [CaptureItemSnapshot]) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(rows)
    let folder = indexURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let temporary = folder.appendingPathComponent(".captures.json.\(UUID().uuidString).tmp")
    try data.write(to: temporary)
    guard rename(temporary.path, indexURL.path) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temporary)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

  func delete(id: UUID) throws {
    let provider = try app.settingsPresenter.captures ?? FileCapturesProvider(root: root)
    try provider.remove(id: id)
  }

  func showInLibrary(id: UUID) {
    app.settingsPresenter.showLibrary(section: .captures)
    app.settingsPresenter.library?.selectedIDs = [id.uuidString]
  }

  func fileURL(id: UUID) -> URL? {
    let url = directory.appendingPathComponent("\(id.uuidString).png")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}
