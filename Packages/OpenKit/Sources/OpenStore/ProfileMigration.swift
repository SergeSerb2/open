import Foundation
import Darwin
import OpenModel

public struct ProfileMigrationReport: Sendable {
    public var moved: [String] = []
    public var skipped: [String] = []
    public var missing: [String] = []
    public init() {}
}

/// No store may open until this operation has returned successfully.
/// Sources remain intact until a complete destination State directory is published.
public enum ProfileMigration {
    private struct Source: Codable {
        var legacy: String
        var target: String
        var file: String
        var inode: UInt64
        var size: UInt64
        var modified: Date
    }
    private struct Journal: Codable {
        var id: String
        var directory: String
        var store: String
        var sources: [Source]
        var ready: Bool = false
    }
    private static let journalName = "profile-migration.json"
    private static let markerName = ".profile-migration-commit"

    @MainActor
    public static func migrateSingleProfileLayout(root: URL, profiles: [Profile]) throws -> ProfileMigrationReport {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let journalURL = root.appendingPathComponent("State/\(journalName)")
        var report = ProfileMigrationReport()
        if DurableFiles.exists(journalURL) {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            try finish(journal, root: root, journalURL: journalURL)
            report.moved.append("resumed \(journal.store)")
        }
        let directory = (profiles.first { $0.dataDirectoryName == "Default" } ?? profiles.first)?.dataDirectoryName ?? "Default"
        let state = ProfileDirectories(root: root).profileDirectory(dataDirectoryName: directory).appendingPathComponent("State")
        for name in ["history.sqlite3", "archive.sqlite3", "sleep.sqlite3"] {
            let legacy = root.appendingPathComponent("State/\(name)")
            let destination = state.appendingPathComponent(name)
            let suffixes = ["", "-wal", "-shm"]
            let remaining = suffixes.filter { DurableFiles.exists(URL(fileURLWithPath: legacy.path + $0)) }
            guard !remaining.isEmpty else { report.missing.append(name); continue }
            let hasMain = DurableFiles.exists(destination)
            if hasMain && remaining.contains("") {
                throw migrationError("refused \(name): conflicting main databases; legacy set preserved")
            }
            var sources: [Source] = []
            for suffix in remaining {
                let item = URL(fileURLWithPath: legacy.path + suffix)
                // Resolve *every* legacy item before changing anything, including skipped files.
                let target = item.resolvingSymlinksInPath().standardizedFileURL
                let attributes = try fm.attributesOfItem(atPath: target.path)
                guard target.path.hasPrefix(root.path + "/"),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      !target.path.hasPrefix(root.appendingPathComponent("Profiles").path + "/") else {
                    throw migrationError("refused \(name): legacy item must resolve to a regular file inside the data root")
                }
                if hasMain && DurableFiles.exists(URL(fileURLWithPath: destination.path + suffix)) { continue }
                sources.append(Source(legacy: item.path, target: target.path, file: name + suffix,
                    inode: (attributes[.systemFileNumber] as! NSNumber).uint64Value,
                    size: (attributes[.size] as! NSNumber).uint64Value,
                    modified: attributes[.modificationDate] as! Date))
            }
            guard !sources.isEmpty else {
                // Keep the conflict visible and block store opens: SQLite must not consume
                // either half of an unresolved legacy/destination pair.
                throw migrationError("refused \(name): legacy files conflict with destination; sources preserved")
            }
            guard Set(sources.map(\.target)).count == sources.count else {
                throw migrationError("refused \(name): legacy files alias the same target")
            }
            if !hasMain && !sources.contains(where: { $0.file == name }) {
                throw migrationError("refused \(name): legacy sidecars have no main database; sources preserved")
            }
            let journal = Journal(id: UUID().uuidString, directory: directory, store: name, sources: sources)
            try save(journal, to: journalURL)
            DurableFiles.crashPoint("journal")
            try finish(journal, root: root, journalURL: journalURL)
            report.moved.append("\(name) -> Profiles/\(directory)/State/\(name)")
            // A pre-existing destination main wins, but never silently skip a legacy main.
            if suffixes.contains(where: { DurableFiles.exists(URL(fileURLWithPath: legacy.path + $0)) }) {
                throw migrationError("refused \(name): conflicting legacy files remain; sources preserved")
            }
        }
        return report
    }

    private static func migrationError(_ message: String) -> NSError {
        NSError(domain: "OpenStore.ProfileMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func save(_ journal: Journal, to url: URL) throws {
        try DurableFiles.write(JSONEncoder().encode(journal), to: url)
    }
    private static func finish(_ original: Journal, root: URL, journalURL: URL) throws {
        let fm = FileManager.default
        var journal = original
        guard UUID(uuidString: journal.id) != nil,
              !journal.directory.isEmpty, journal.directory != ".", journal.directory != "..", !journal.directory.contains("/"),
              ["history.sqlite3", "archive.sqlite3", "sleep.sqlite3"].contains(journal.store),
              journal.sources.allSatisfy({ source in
                  [journal.store, journal.store + "-wal", journal.store + "-shm"].contains(source.file)
                      && source.legacy == root.appendingPathComponent("State/" + source.file).path
                      && source.target.hasPrefix(root.path + "/")
                      && !source.target.hasPrefix(root.appendingPathComponent("Profiles").path + "/")
              }) else { throw migrationError("invalid migration journal; sources preserved") }
        let profile = ProfileDirectories(root: root).profileDirectory(dataDirectoryName: journal.directory)
        guard profile.resolvingSymlinksInPath().path == profile.path else {
            throw migrationError("Profile destination contains a symlink; migration refused")
        }
        let destination = profile.appendingPathComponent("State")
        let stage = profile.appendingPathComponent(".migration-\(journal.id)")
        let marker = destination.appendingPathComponent(markerName)
        let committed = (try? String(contentsOf: marker, encoding: .utf8)) == journal.id
        if !committed {
            if !journal.ready {
                if DurableFiles.exists(stage) { try fm.removeItem(at: stage) }
                try fm.createDirectory(at: profile, withIntermediateDirectories: true)
                if DurableFiles.exists(destination) { try fm.copyItem(at: destination, to: stage) }
                else { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
                // Orphan destination sidecars belong to no main database. Preserve them
                // inside the directory that will be atomically installed.
                if !DurableFiles.exists(destination.appendingPathComponent(journal.store)) {
                    for suffix in ["-wal", "-shm"] {
                        let orphan = stage.appendingPathComponent(journal.store + suffix)
                        if DurableFiles.exists(orphan) {
                            let quarantine = stage.appendingPathComponent(".quarantine/\(journal.id)")
                            try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
                            try fm.moveItem(at: orphan, to: quarantine.appendingPathComponent(orphan.lastPathComponent))
                        }
                    }
                }
                for source in journal.sources {
                    // The journal is only written by this implementation, but revalidate
                    // resolved paths on resume so a changed symlink cannot escape the root.
                    let url = URL(fileURLWithPath: source.target)
                    guard url.resolvingSymlinksInPath().path == source.target,
                          source.target.hasPrefix(root.path + "/"),
                          try unchanged(source) else {
                        throw migrationError("migration source changed; sources preserved")
                    }
                    let copy = stage.appendingPathComponent(source.file)
                    try fm.copyItem(at: url, to: copy)
                    try DurableFiles.sync(copy)
                    DurableFiles.crashPoint("copy-\(source.file)")
                }
                try DurableFiles.write(Data(journal.id.utf8), to: stage.appendingPathComponent(markerName))
                try syncTree(stage)
                journal.ready = true
                try save(journal, to: journalURL)
                DurableFiles.crashPoint("staged")
            }
            // macOS atomically swaps two nonempty directories in a single syscall.
            let result = DurableFiles.exists(destination)
                ? renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP))
                : rename(stage.path, destination.path)
            guard result == 0 else { throw DurableFiles.failure("publish migration set") }
            try DurableFiles.sync(profile)
            DurableFiles.crashPoint("published")
        }
        // The marker resolves the crash window between directory publication and journal update.
        for source in journal.sources {
            if DurableFiles.exists(URL(fileURLWithPath: source.target)) {
                guard try unchanged(source) else { throw migrationError("migration source changed; source preserved") }
                try fm.removeItem(atPath: source.target)
            }
            if source.legacy != source.target, DurableFiles.exists(URL(fileURLWithPath: source.legacy)) {
                try fm.removeItem(atPath: source.legacy) // unlink the original alias; never move it
            }
            try DurableFiles.sync(URL(fileURLWithPath: source.target).deletingLastPathComponent())
            DurableFiles.crashPoint("cleanup-\(source.file)")
        }
        try DurableFiles.sync(root.appendingPathComponent("State"))
        if DurableFiles.exists(stage) { try fm.removeItem(at: stage) }
        try fm.removeItem(at: journalURL)
        try DurableFiles.sync(journalURL.deletingLastPathComponent())
    }
    private static func unchanged(_ source: Source) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.target)
        return attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == source.inode
            && (attributes[.size] as? NSNumber)?.uint64Value == source.size
            && attributes[.modificationDate] as? Date == source.modified
    }
    private static func syncTree(_ directory: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw migrationError("destination State contains a symlink; migration refused") }
            if values.isDirectory == true { try syncTree(item) } else { try DurableFiles.sync(item) }
        }
        try DurableFiles.sync(directory)
    }
}
