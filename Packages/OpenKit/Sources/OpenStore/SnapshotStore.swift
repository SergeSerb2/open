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
    @MainActor private var dirtyModel: BrowserModel?
    @MainActor private var saveGeneration = 0
    @MainActor public private(set) var captureCount = 0
    @MainActor public private(set) var scheduleCount = 0
    @MainActor public var isDirty: Bool { dirtyModel != nil }

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
        // Scheduling never walks the model or opens files. Frame drags can
        // mark dirty repeatedly; only the final debounced turn captures a DTO.
        dirtyModel = model; saveGeneration += 1; scheduleCount += 1
        let generation = saveGeneration
        lock.lock()
        pendingWork?.cancel()
        let work = DispatchWorkItem { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.capturePending(generation: generation) }
        }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    @MainActor
    private func capturePending(generation: Int) {
        guard generation == saveGeneration, let model = dirtyModel else { return }
        do {
            try prepare(model: model)
            let dto = SnapshotMapper.dto(from: model); captureCount += 1
            dirtyModel = nil
            lock.withLock { pendingWork = nil }
            queue.async { [weak self] in self?.writeReportingFailure(dto: dto) }
        } catch {
            FileHandle.standardError.write(Data("SnapshotStore prepare failed: \(error)\n".utf8))
        }
    }

    /// Synchronous save (also used by flush and the CLI).
    @MainActor
    public func saveNow(model: BrowserModel) throws {
        saveGeneration += 1
        lock.withLock { pendingWork?.cancel(); pendingWork = nil }
        try prepare(model: model)
        let dto = SnapshotMapper.dto(from: model); captureCount += 1; dirtyModel = nil
        try queue.sync { try write(dto: dto) }
    }

    /// Captures dirty state synchronously, then waits for writes already queued.
    /// For quit-time use, prefer saveNow(model:) so the latest state is captured.
    @MainActor public func flush() {
        if let model = dirtyModel {
            do { try saveNow(model: model) }
            catch { FileHandle.standardError.write(Data("SnapshotStore flush failed: \(error)\n".utf8)) }
        } else { queue.sync {} }
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
