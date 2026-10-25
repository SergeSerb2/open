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
        let dto = SnapshotMapper.dto(from: model)
        lock.lock()
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(dto: dto) }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Synchronous save (also used by flush and the CLI).
    @MainActor
    public func saveNow(model: BrowserModel) {
        let dto = SnapshotMapper.dto(from: model)
        lock.lock(); pendingWork?.cancel(); pendingWork = nil; lock.unlock()
        write(dto: dto)
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

    private func write(dto: SnapshotFileDTO) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(dto)
            let tmp = dir.appendingPathComponent("browser.json.tmp-\(UUID().uuidString)")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            // Persistence failure must not crash the app. Surface via stderr for the CLI.
            FileHandle.standardError.write(Data("SnapshotStore write failed: \(error)\n".utf8))
        }
    }

    public func loadData() throws -> SnapshotFileDTO? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SnapshotFileDTO.self, from: data)
    }

    @MainActor
    public func load() throws -> BrowserModel? {
        guard let dto = try loadData() else { return nil }
        return SnapshotMapper.model(from: dto)
    }
}
