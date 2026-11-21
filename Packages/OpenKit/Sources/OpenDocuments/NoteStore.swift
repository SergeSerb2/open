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
    /// Notes encoded to JSON (automation evidence: an oversized Note is not encoded at every save).
    public private(set) var encodeCount = 0
    public private(set) var lastError: String?
    /// Notes whose last save was refused because its file would be over `maxFileBytes`.
    public private(set) var oversized: Set<UUID> = []
    /// A save was refused for size (every refused save: each one is an edit that is not on disk).
    /// The file keeps the last text that fits; the App tells the user.
    public var onTooLarge: ((UUID) -> Void)?

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

    /// Writes an imported Note now unless a file for it exists. Returns true when written.
    @discardableResult
    public func importIfAbsent(_ note: NoteDocument) -> Bool {
        guard !FileManager.default.fileExists(atPath: fileURL(for: note.id).path), cache[note.id] == nil else { return false }
        cache[note.id] = note; dirty.insert(note.id); flush(notify: false)
        if oversized.contains(note.id) { cache[note.id] = nil; oversized.remove(note.id); return false }
        return !dirty.contains(note.id)
    }

    /// Deletes a Note: its file and image folder move to the Trash (removed when no Trash exists).
    public func delete(_ id: UUID) {
        cache[id] = nil; dirty.remove(id); oversized.remove(id)
        for url in [fileURL(for: id), assetDirectory(for: id)] where FileManager.default.fileExists(atPath: url.path) {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Replaces a Note (an import that fills a placeholder). Written now. False when the Note is
    /// over the size limit: the previous Note (the placeholder) stays, in memory and on disk.
    @discardableResult
    public func replace(_ note: NoteDocument) -> Bool {
        let previous = cache[note.id]
        cache[note.id] = note; dirty.insert(note.id); flush(notify: false)
        guard oversized.remove(note.id) == nil else { cache[note.id] = previous; return false }
        return !dirty.contains(note.id)
    }

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

    /// Writes every changed Note now. Safe to call often. `notify` false: an import reports a
    /// refused Note itself (no editor toast).
    public func flush() { flush(notify: true) }

    private func flush(notify: Bool) {
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
                // `load` refuses a file over the limit, so writing it would lose the whole Note at the
                // next open. Keep the last file that fits; the editor still holds the text. A Note whose
                // text alone already encodes over the limit is refused without encoding it (an oversized
                // Note is refused at every debounced save; each encode copied tens of MB).
                let textBytes = Self.minimumEncodedBytes(note.text)
                let data = textBytes > Self.maxFileBytes ? nil : try Self.encoder.encode(note)
                if data != nil { encodeCount += 1 }
                guard let data, data.count <= Self.maxFileBytes else {
                    let size = data?.count ?? textBytes
                    lastError = "\(id): \(data == nil ? "over " : "")\(size) bytes is over the \(Self.maxFileBytes)-byte limit; the last save is kept"
                    oversized.insert(id)
                    if notify { onTooLarge?(id) }
                    continue
                }
                try data.write(to: fileURL(for: id), options: .atomic)
                writeCount += 1
                if oversized.remove(id) != nil { lastError = nil }
            } catch {
                lastError = "\(id): \(error)"; dirty.insert(id)
            }
        }
    }

    /// A lower bound of the bytes `encoder` writes for `text` as a JSON string value: UTF-8 bytes,
    /// with the escapes JSONEncoder always writes ('/', '"', '\\' and control characters).
    nonisolated static func minimumEncodedBytes(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 {
            switch byte {
            case 0x22, 0x2F, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: count += 2
            case 0..<0x20: count += 6
            default: count += 1
            }
        }
        return count
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
