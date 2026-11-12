import Foundation

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

    public init(root: URL) { directory = root.appendingPathComponent("Easels", isDirectory: true) }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).appendingPathComponent("document.json")
    }

    /// The pending (unsaved) copy wins over the file.
    public func load(_ id: UUID) -> EaselDocument? {
        if let doc = pending[id] { return doc }
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(EaselDocument.self, from: data)
    }

    public func exists(_ id: UUID) -> Bool {
        pending[id] != nil || FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    public func save(_ doc: EaselDocument) {
        pending[doc.id] = doc
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush(wait: false) }
        }
    }

    /// Writes every pending document. `wait` blocks until the bytes are on disk (quit).
    public func flush(wait: Bool = true) {
        timer?.invalidate(); timer = nil
        guard !pending.isEmpty else { if wait { queue.sync {} }; return }
        let jobs = pending.map { ($0.value, fileURL(for: $0.key)) }
        pending.removeAll()
        writeCount += jobs.count
        let work: @Sendable () -> Void = {
            for (doc, url) in jobs {
                guard let data = try? Self.encoder.encode(doc) else { continue }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
    nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
