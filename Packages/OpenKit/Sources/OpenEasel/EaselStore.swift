import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Local Easel storage: `<root>/Easels/<uuid>/document.json` (a directory per Easel so E2
/// images and E4 thumbnails sit beside it). Nothing loads until an Easel opens. Saves are
/// debounced (500 ms) and written atomically on a utility queue; `flush` writes at once
/// (close, quit, automation).
@MainActor
public final class EaselStore {
    public let directory: URL
    private var pending: [UUID: EaselDocument] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "open.easel.store", qos: .utility)
    public private(set) var writeCount = 0
    public var saveDelay: TimeInterval = 0.5
    /// The last failed write (nil after a write succeeds). A failed document goes back into
    /// `pending`, like `NoteStore` marks a Note dirty again: the next flush (a later edit, close,
    /// quit) writes it again, so a full disk does not drop the last edits silently.
    public private(set) var lastError: String?
    /// Bumped by `save` and `discard`: a failed write is queued again only while no newer copy was
    /// saved (and possibly written) and the document was not discarded since.
    private var generations: [UUID: Int] = [:]
    /// Failed writes of background flushes, confined to `queue`. Every reader of the disk state
    /// (`load`, a waiting flush) and the flush's own main-thread callback drain it first, so a quit
    /// or a reopen that comes before that callback cannot drop or bypass a failed edit.
    private final class FailedWrites: @unchecked Sendable {
        var items: [(EaselDocument, Int, String)] = []
        /// A flush wrote everything since the last drain.
        var clean = false
    }
    private let failedWrites = FailedWrites()

    public init(root: URL) { directory = root.appendingPathComponent("Easels", isDirectory: true) }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).appendingPathComponent("document.json")
    }

    /// The pending (unsaved) copy wins over the file.
    public func load(_ id: UUID) -> EaselDocument? {
        if let doc = pending[id] { return doc }
        // A debounced flush hands its copy to the write queue and clears `pending`;
        // wait for that write, or an Easel reopened at once reads the older file. A copy whose
        // write failed comes back into `pending` here.
        drainFailedWrites()
        if let doc = pending[id] { return doc }
        let url = fileURL(for: id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= EaselDocument.maxFileBytes,
              let data = try? Data(contentsOf: url),
              let doc = try? Self.decoder.decode(EaselDocument.self, from: data),
              doc.id == id, doc.isValid else { return nil }
        return doc
    }

    // MARK: Index (Library)

    public struct IndexEntry: Sendable {
        public var id: UUID; public var title: String; public var modifiedAt: Date; public var objectCount: Int
        public init(id: UUID, title: String, modifiedAt: Date, objectCount: Int) {
            self.id = id; self.title = title; self.modifiedAt = modifiedAt; self.objectCount = objectCount
        }
    }
    /// Every readable Easel document under `directory`, newest first. File work only: call
    /// it off the main thread. Refused files (limits, damage) are left out.
    public nonisolated static func readIndex(directory: URL) -> [IndexEntry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var out: [IndexEntry] = []
        for folder in folders.prefix(10_000) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let file = folder.appendingPathComponent("document.json")
            guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= EaselDocument.maxFileBytes,
                  let data = try? Data(contentsOf: file), let doc = try? decoder.decode(EaselDocument.self, from: data),
                  doc.id == id, doc.isValid else { continue }
            out.append(IndexEntry(id: id, title: doc.displayTitle, modifiedAt: doc.modifiedAt, objectCount: doc.objects.count))
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    /// Documents saved but not yet written count too (an Easel edited seconds ago).
    public var pendingDocuments: [EaselDocument] { Array(pending.values) }

    // MARK: Images

    /// Limits for an added picture: 50 MiB of encoded bytes and 16,384 px per side (a decoded
    /// thumbnail is bounded separately by `EaselImageCache`).
    public nonisolated static let maxImageBytes = 50 << 20
    public nonisolated static let maxImagePixels = 16_384

    public func imagesDirectory(for id: UUID) -> URL { fileURL(for: id).deletingLastPathComponent().appendingPathComponent("images", isDirectory: true) }
    public func imageURL(document id: UUID, file: String) -> URL? {
        EaselDocument.isImageFileName(file) ? imagesDirectory(for: id).appendingPathComponent(file) : nil
    }

    /// Validates and stores image bytes as `images/<sha256>.<ext>` (deduplicated). Returns the
    /// file name and the pixel size, or nil for data that is not a supported picture.
    public func addImage(_ data: Data, document id: UUID) -> EaselImage? {
        guard data.count <= Self.maxImageBytes, let info = Self.imageInfo(data) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = "\(hash).\(info.ext)"
        let url = imagesDirectory(for: id).appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { return nil }
        }
        return EaselImage(file: file, width: info.width, height: info.height)
    }

    nonisolated static func imageInfo(_ data: Data) -> (ext: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1, let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxImagePixels, h <= maxImagePixels else { return nil }
        let ext: String
        switch type {
        case UTType.png.identifier: ext = "png"
        case UTType.jpeg.identifier: ext = "jpg"
        case UTType.gif.identifier: ext = "gif"
        case UTType.webP.identifier: ext = "webp"
        case UTType.heic.identifier: ext = "heic"
        case UTType.tiff.identifier: ext = "tiff"
        default: return nil
        }
        return (ext, w, h)
    }

    /// A file `load` refused is renamed `document.refused-<unix time>.json` beside it, so a new
    /// empty document never overwrites it. Returns the new name.
    @discardableResult
    public func setAsideRefused(_ id: UUID) -> URL? {
        let url = fileURL(for: id)
        guard pending[id] == nil, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let aside = url.deletingLastPathComponent().appendingPathComponent("document.refused-\(Int(Date().timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: url, to: aside)) != nil ? aside : nil
    }

    public func exists(_ id: UUID) -> Bool {
        if pending[id] != nil { return true }
        // As `load`: a new document's first write may still be queued (or failed and comes back).
        drainFailedWrites()
        return pending[id] != nil || FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    public func save(_ doc: EaselDocument) {
        pending[doc.id] = doc
        generations[doc.id, default: 0] += 1
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush(wait: false) }
        }
    }

    /// Drops the queued copy of a document whose folder is about to be trashed or replaced
    /// (delete, import Undo/Redo), also a copy that a failed write queues again later.
    public func discard(_ id: UUID) {
        pending[id] = nil
        generations[id, default: 0] += 1
    }

    /// Writes every pending document. `wait` blocks until the bytes are on disk (quit).
    public func flush(wait: Bool = true) {
        timer?.invalidate(); timer = nil
        // A failed background write is written again by this flush (quit, close, automation).
        if wait { drainFailedWrites() }
        guard !pending.isEmpty else { return }
        let jobs = pending.map { ($0.value, fileURL(for: $0.key), generations[$0.key, default: 0]) }
        pending.removeAll()
        writeCount += jobs.count
        let failedWrites = self.failedWrites
        let work: @Sendable () -> Void = {
            var failed = false
            for (doc, url, generation) in jobs {
                // A document that cannot be encoded never will be: it is not queued again.
                guard let data = try? Self.encoder.encode(doc) else { continue }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    failed = true
                    failedWrites.items.append((doc, generation, "\(doc.id): \(error.localizedDescription)"))
                }
            }
            if !failed { failedWrites.clean = true }
        }
        if wait { queue.sync(execute: work); drainFailedWrites() }
        else {
            queue.async(execute: work)
            queue.async { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.drainFailedWrites() } } }
        }
    }

    /// Waits for queued writes and takes their failures: each failed document goes back into
    /// `pending` unless a newer copy was saved or the document was discarded meanwhile. Flushes
    /// that all succeeded clear `lastError`.
    private func drainFailedWrites() {
        let failedWrites = self.failedWrites
        let (taken, clean) = queue.sync { () -> ([(EaselDocument, Int, String)], Bool) in
            let result = (failedWrites.items, failedWrites.clean)
            failedWrites.items.removeAll(); failedWrites.clean = false
            return result
        }
        // A failure of a copy that a newer save replaced is not a current error.
        var kept = false
        for (doc, generation, message) in taken {
            guard pending[doc.id] == nil, generations[doc.id, default: 0] == generation else { continue }
            pending[doc.id] = doc
            lastError = message; kept = true
        }
        if !kept, clean { lastError = nil }
    }

    public nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
