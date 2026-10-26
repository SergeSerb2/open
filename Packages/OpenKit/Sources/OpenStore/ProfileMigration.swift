import Foundation
import OpenModel

public struct ProfileMigrationReport: Sendable {
    public var moved: [String] = []
    public var skipped: [String] = []
    public var missing: [String] = []
    public init() {}
}

public enum ProfileMigration {
    /// Run before opening any store. Existing per-Profile databases always win.
    @MainActor
    public static func migrateSingleProfileLayout(root: URL, profiles: [Profile]) -> ProfileMigrationReport {
        var report = ProfileMigrationReport()
        let names = ["history.sqlite3", "archive.sqlite3", "sleep.sqlite3"]
        guard let profile = profiles.first(where: { $0.dataDirectoryName == "Default" }) ?? profiles.first else {
            report.missing = names
            return report
        }
        let directories = ProfileDirectories(root: root)
        let fm = FileManager.default
        for name in names {
            let source = root.appendingPathComponent("State/\(name)")
            let destination = directories.profileDirectory(for: profile).appendingPathComponent("State/\(name)")
            let summary = "\(name) -> Profiles/\(profile.dataDirectoryName)/State/\(name)"
            let suffixes = ["", "-wal", "-shm"]
            // A leftover destination sidecar must not get paired with a different database.
            if suffixes.contains(where: { fm.fileExists(atPath: destination.path + $0) }) {
                report.skipped.append(summary)
                continue
            }
            guard fm.fileExists(atPath: source.path) else { report.missing.append(name); continue }
            var moved: [String] = []
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                for suffix in suffixes where fm.fileExists(atPath: source.path + suffix) {
                    try fm.moveItem(atPath: source.path + suffix, toPath: destination.path + suffix)
                    moved.append(suffix)
                }
                report.moved.append(summary)
            } catch {
                // Keep the legacy set together on a partial filesystem failure.
                for suffix in moved.reversed() {
                    try? fm.moveItem(atPath: destination.path + suffix, toPath: source.path + suffix)
                }
                report.skipped.append(summary + " (move failed)")
            }
        }
        return report
    }
}
