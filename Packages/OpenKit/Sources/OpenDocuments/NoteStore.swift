import CryptoKit
import Foundation

/// Notes on disk: `<data root>/Notes/<uuid>.json`, one small file per Note.
/// Nothing is read until a Note is shown; a sidebar row needs only its tab
/// title from the snapshot. Edits are saved 500 ms after the last change
/// (atomic temp file + rename) and flushed when the App quits.
@MainActor
public final class NoteStore {
    public let directory: URL
    private var cache: [UUID: NoteDocument] = [:]
    private var dirty: Set<UUID> = []
    private var saveTimer: Timer?
    public static let saveDelay: TimeInterval = 0.5
    /// 32 MiB: far above any typed Note (Arc refused to sync Notes over 1 MB), well under allocator limits.
    public nonisolated static let maxFileBytes = 32 << 20
    public private(set) var writeCount = 0
    public private(set) var lastError: String?

    public init(root: URL) {
        directory = root.appendingPathComponent("Notes", isDirectory: true)
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// The stored Note, or nil when no file exists yet (a Note that was never edited).
    public func load(_ id: UUID) -> NoteDocument? {
        if let cached = cache[id] { return cached }
        let url = fileURL(for: id)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        // Our own files, but still bounded: a Note over the limit is refused, not decoded.
        guard size <= Self.maxFileBytes else { lastError = "\(id): \(size) bytes is over the \(Self.maxFileBytes)-byte limit"; return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let note = try Self.decoder.decode(NoteDocument.self, from: data)
            cache[id] = note
            return note
        } catch {
            lastError = "\(id): \(error)"
            return nil
        }
    }

    /// A file exists for this Note but cannot be read (too large or not a Note).
    /// The editor must not overwrite it.
    public func isUnreadable(_ id: UUID) -> Bool {
        load(id) == nil && FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    /// The stored Note, or a new empty one with this id (not written until edited).
    public func document(_ id: UUID) -> NoteDocument { load(id) ?? NoteDocument(id: id) }

    public func update(_ note: NoteDocument) {
        var note = note
        if cache[note.id] == note { return }
        note.modifiedAt = Date()
        cache[note.id] = note
        dirty.insert(note.id)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    public var hasPendingWrites: Bool { !dirty.isEmpty }

    // MARK: Images

    /// 20 MiB per image: refused above, before decoding.
    public nonisolated static let maxImageBytes = 20 << 20

    /// `<data root>/Notes/<uuid>.assets/`: images of one Note, named by content hash.
    public func assetDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".assets", isDirectory: true)
    }

    /// The file of an image name from a Note's formats. Names are hash.ext only; anything else is refused.
    public func assetURL(note id: UUID, name: String) -> URL? {
        guard name.range(of: #"^[0-9a-f]{64}\.(png|jpg|jpeg|gif|heic|tiff|webp)$"#, options: .regularExpression) != nil else { return nil }
        return assetDirectory(for: id).appendingPathComponent(name)
    }

    /// Writes image bytes once (content-addressed) and returns the name to store in a format.
    public func writeAsset(_ data: Data, ext: String, note id: UUID) throws -> String {
        guard data.count <= Self.maxImageBytes else { throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "image over \(Self.maxImageBytes) bytes"]) }
        let name = SHA256Hex.digest(data) + "." + ext.lowercased()
        guard let url = assetURL(note: id, name: name) else { throw CocoaError(.fileWriteInvalidFileName) }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    /// Writes every changed Note now. Safe to call often.
    public func flush() {
        saveTimer?.invalidate(); saveTimer = nil
        guard !dirty.isEmpty else { return }
        let ids = dirty; dirty.removeAll()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { lastError = "\(error)"; dirty.formUnion(ids); return }
        for id in ids {
            guard let note = cache[id] else { continue }
            do {
                try Self.encoder.encode(note).write(to: fileURL(for: id), options: .atomic)
                writeCount += 1
            } catch {
                lastError = "\(id): \(error)"; dirty.insert(id)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum SHA256Hex {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
