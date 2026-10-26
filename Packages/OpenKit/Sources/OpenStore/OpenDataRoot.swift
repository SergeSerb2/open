import Foundation
import Darwin
import OpenModel

/// Shared bootstrap for CLI, benchmarks and the future App. Call before any store
/// open, including when no snapshot exists. A process holds the root lock until exit.
@MainActor
public enum OpenDataRoot {
    private static var prepared: Set<String> = []
    private static var locks: [String: Int32] = [:]

    /// Explicit file CLIs still bootstrap the surrounding root. Per-Profile paths
    /// and the global State directory share the same root convention.
    public static func prepare(storeFileURL: URL) throws {
        let state = storeFileURL.deletingLastPathComponent()
        let profile = state.deletingLastPathComponent()
        let root: URL
        if state.lastPathComponent == "State", profile.deletingLastPathComponent().lastPathComponent == "Profiles" {
            root = profile.deletingLastPathComponent().deletingLastPathComponent()
        } else if state.lastPathComponent == "State" { root = state.deletingLastPathComponent() }
        else { root = state }
        _ = try SnapshotStore(root: root).load()
        // Refuse an old per-Profile store path after migration rather than reopening it.
        if state.lastPathComponent == "State",
           ["history.sqlite3", "archive.sqlite3", "sleep.sqlite3"].contains(storeFileURL.lastPathComponent),
           state.deletingLastPathComponent() == root {
            throw NSError(domain: "OpenStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "use Profiles/<dir>/State/\(storeFileURL.lastPathComponent) after migration"])
        }
    }

    @discardableResult
    public static func prepare(root: URL, model: BrowserModel? = nil) throws -> ProfileMigrationReport {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let key = root.path
        let directories = ProfileDirectories(root: root)
        var report = ProfileMigrationReport()
        if !prepared.contains(key) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("State"), withIntermediateDirectories: true)
            if locks[key] == nil {
                let fd = Darwin.open(root.appendingPathComponent("State/.profile-data.lock").path, O_CREAT | O_RDWR, 0o600)
                guard fd >= 0 else { throw DurableFiles.failure("open data root lock") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw DurableFiles.failure("lock data root") }
                locks[key] = fd
            }
            report = try ProfileMigration.migrateSingleProfileLayout(root: root, profiles: model?.profiles ?? [])
            prepared.insert(key)
            for line in report.moved { FileHandle.standardError.write(Data("migration moved \(line)\n".utf8)) }
        }
        if let model {
            model.unavailableProfileDirectoryNames.formUnion(try directories.unavailableDirectoryNames())
            for profile in model.profiles { try directories.ensureProfileDirectories(for: profile) }
        }
        return report
    }
}
