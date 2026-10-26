import Foundation
import Darwin
import OpenModel
import Synchronization

/// One lease on the process's single open file description for this root.
/// The registry owns the fd; leases never open or close independent descriptors.
final class DataRootLock: Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    deinit { DataRootLocks.release(root: root) }
}

private enum DataRootLocks {
    private struct Entry {
        let fd: Int32
        var references = 1
        var prepared = false
    }
    private static let entries = Mutex<[String: Entry]>([:])

    static func acquire(root: URL) throws -> DataRootLock {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
        // Resolve after creation, including /tmp -> /private/tmp and symlinked parents
        // of a root that did not exist at the first call.
        guard let path = realpath(root.path, nil) else { throw DurableFiles.failure("resolve data root") }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        return try entries.withLock { entries in
            if var entry = entries[root.path] {
                entry.references += 1
                entries[root.path] = entry
                return DataRootLock(root: root)
            }
            let fd = Darwin.open(root.appendingPathComponent("State/.profile-data.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DurableFiles.failure("open data root lock") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                // Capture errno before close() can replace it.
                let error = DurableFiles.failure("lock data root (already in use or unavailable)")
                Darwin.close(fd)
                throw error
            }
            entries[root.path] = Entry(fd: fd)
            return DataRootLock(root: root)
        }
    }

    static func isPrepared(root: URL) -> Bool {
        entries.withLock { $0[root.path]?.prepared == true }
    }

    static func markPrepared(root: URL) {
        entries.withLock { $0[root.path]?.prepared = true }
    }

    static func release(root: URL) {
        entries.withLock { entries in
            guard var entry = entries[root.path] else { preconditionFailure("unbalanced data root lock") }
            entry.references -= 1
            if entry.references == 0 {
                flock(entry.fd, LOCK_UN)
                Darwin.close(entry.fd)
                entries.removeValue(forKey: root.path)
            } else { entries[root.path] = entry }
        }
    }
}

extension DataRootLock {
    static func acquire(root: URL) throws -> DataRootLock { try DataRootLocks.acquire(root: root) }
}

/// Shared bootstrap for CLI, benchmarks and the future App. Call before any store
/// open, including when no snapshot exists. Retain the preparation for the operation.
@MainActor
public enum OpenDataRoot {
    public struct Preparation: Sendable {
        let lock: DataRootLock
        public var root: URL { lock.root }
        public let migrationReport: ProfileMigrationReport
    }

    nonisolated static func root(forStoreFileURL storeFileURL: URL) -> URL {
        let state = storeFileURL.deletingLastPathComponent()
        let profile = state.deletingLastPathComponent()
        if state.lastPathComponent == "State", profile.deletingLastPathComponent().lastPathComponent == "Profiles" {
            return profile.deletingLastPathComponent().deletingLastPathComponent()
        } else if state.lastPathComponent == "State" { return state.deletingLastPathComponent() }
        else { return state }
    }

    /// Explicit file CLIs still bootstrap the surrounding root. Per-Profile paths
    /// and the global State directory share the same root convention.
    public static func prepare(storeFileURL: URL) throws -> Preparation {
        let root = root(forStoreFileURL: storeFileURL)
        let snapshot = SnapshotStore(root: root)
        defer { withExtendedLifetime(snapshot) {} }
        let model = try snapshot.load()
        let preparation = try prepare(root: root, model: model)
        // Refuse an old per-Profile store path after migration rather than reopening it.
        let state = storeFileURL.deletingLastPathComponent()
        if state.lastPathComponent == "State",
           ["history.sqlite3", "archive.sqlite3", "sleep.sqlite3"].contains(storeFileURL.lastPathComponent),
           state.deletingLastPathComponent() == root {
            throw NSError(domain: "OpenStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "use Profiles/<dir>/State/\(storeFileURL.lastPathComponent) after migration"])
        }
        return preparation
    }

    @discardableResult
    public static func prepare(root: URL, model: BrowserModel? = nil) throws -> Preparation {
        let lock = try DataRootLock.acquire(root: root)
        let root = lock.root
        let directories = ProfileDirectories(root: root)
        var report = ProfileMigrationReport()
        if !DataRootLocks.isPrepared(root: root) {
            report = try ProfileMigration.migrateSingleProfileLayout(root: root, profiles: model?.profiles ?? [])
            // Before any engine start: Chromium's data moves to <root>/Engine.
            let engine = try EngineLayoutMigration.migrate(
                root: root, profileDirectoryNames: Set((model?.profiles ?? []).map(\.dataDirectoryName)))
            report.moved += engine.moved
            report.skipped += engine.skipped
            DataRootLocks.markPrepared(root: root)
            for line in report.moved { FileHandle.standardError.write(Data("migration moved \(line)\n".utf8)) }
            for line in report.skipped { FileHandle.standardError.write(Data("migration skipped \(line)\n".utf8)) }
        }
        if let model {
            model.unavailableProfileDirectoryNames.formUnion(try directories.unavailableDirectoryNames())
            for profile in model.profiles { try directories.ensureProfileDirectories(for: profile) }
        }
        return Preparation(lock: lock, migrationReport: report)
    }
}
