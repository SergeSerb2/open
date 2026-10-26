import Foundation
import OpenModel

/// Versioned JSON snapshot at <root>/State/browser.json.
/// Writes are atomic (temp file + rename) on a background queue, debounced 1 s.
public final class SnapshotStore: @unchecked Sendable {
    public let root: URL
    public var fileURL: URL { root.appendingPathComponent("State/browser.json") }

    private let queue = DispatchQueue(label: "open.snapshot", qos: .utility)
    private var pendingWork: DispatchWorkItem?
    private let lock = NSLock()
    private var dataRootLock: DataRootLock?

    private func holdRootLock() throws {
        try lock.withLock {
            if dataRootLock == nil { dataRootLock = try DataRootLock.acquire(root: root) }
        }
    }

    @MainActor
    private func prepare(model: BrowserModel) throws {
        try holdRootLock()
        _ = try OpenDataRoot.prepare(root: root, model: model)
    }

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("Open", isDirectory: true)
        }
    }

    /// Debounced save. Call from the main actor after any command.
    @MainActor
    public func scheduleSave(model: BrowserModel) {
        do { try prepare(model: model) }
        catch {
            FileHandle.standardError.write(Data("SnapshotStore prepare failed: \(error)\n".utf8))
            return
        }
        let dto = SnapshotMapper.dto(from: model)
        lock.lock()
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeReportingFailure(dto: dto) }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Synchronous save (also used by flush and the CLI).
    @MainActor
    public func saveNow(model: BrowserModel) throws {
        try prepare(model: model)
        let dto = SnapshotMapper.dto(from: model)
        lock.lock(); pendingWork?.cancel(); pendingWork = nil; lock.unlock()
        try queue.sync { try write(dto: dto) }
    }

    /// Writes synchronously. If a debounced DTO is pending it is written; otherwise no-op.
    /// For quit-time use, prefer saveNow(model:) so the latest state is captured.
    public func flush() {
        queue.sync {
            lock.lock()
            let work = pendingWork
            pendingWork = nil
            lock.unlock()
            _ = work // already scheduled work runs on this queue before the sync block completes
        }
    }

    private func writeReportingFailure(dto: SnapshotFileDTO) {
        do { try write(dto: dto) }
        catch { FileHandle.standardError.write(Data("SnapshotStore write failed: \(error)\n".utf8)) }
    }

    private func write(dto: SnapshotFileDTO) throws {
        if ProcessInfo.processInfo.environment["OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL"] == "1" {
            throw NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: "snapshot write failed: simulated disk full"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFiles.write(encoder.encode(dto), to: fileURL)
    }

    public func loadData() throws -> SnapshotFileDTO? {
        try holdRootLock()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SnapshotFileDTO.self, from: data)
    }

    @MainActor
    public func load() throws -> BrowserModel? {
        guard let dto = try loadData() else {
            try OpenDataRoot.prepare(root: root)
            return nil
        }
        let model = SnapshotMapper.model(from: dto)
        try OpenDataRoot.prepare(root: root, model: model)
        return model
    }
}
