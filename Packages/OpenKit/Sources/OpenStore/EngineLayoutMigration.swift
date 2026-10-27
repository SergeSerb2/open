import Foundation
import Darwin
import os

/// The Chromium data layout one launch uses (docs/plans/profiles.md §6.2).
public enum EngineLayout: Sendable, Equatable {
    /// root_cache_path = `<root>/Engine`; profile `<dir>` is `Engine/<dir>`.
    case engine
    /// The old layout, for this launch only: root_cache_path = `<root>/Profiles`
    /// with the default profile's Chromium files in `Profiles/Default`. The
    /// migration could not finish; it runs again on the next launch.
    case legacy
}

/// What the engine layout step did. The App logs it and starts the engine
/// with `layout`; nothing here is an error the App has to handle.
public struct EngineLayoutResult: Sendable {
    public var layout: EngineLayout = .engine
    public var report = ProfileMigrationReport()
    /// Why this launch uses the legacy layout.
    public var problem: String?
    public var milliseconds: Double = 0
}

/// One-time move of Chromium's data from `<root>/Profiles` (the old
/// root_cache_path) to `<root>/Engine`.
///
/// The old layout kept the default profile's Chromium files in
/// `Profiles/Default/` next to Open's own `State/`, `Boosts/`, and `AdBlock/`,
/// installation-wide Chromium files (`Local State`, component downloads) in
/// `Profiles/`, and pointed other profiles at `Profiles/<dir>/Engine/`, which
/// CEF refused (not a direct child of root_cache_path).
///
/// The move renames the ~30 top-level entries; everything stays on one
/// volume, so no file is copied and no file is fsynced. A journal written
/// first lists every rename, so at any crash point each entry is in exactly
/// one place and the next launch finishes the list. The default profile's
/// entries gather in `Engine/.migrating-Default` and appear as
/// `Engine/Default` with one rename (the publish). A failure before the
/// publish renames everything back: that launch uses the legacy layout. After
/// the publish, the remaining steps (the Chromium cache folder, stale
/// `Singleton*` links, empty old folders) are best effort.
///
/// Runs once: `Engine/.open-layout` records that the layout is done. It runs
/// only when the old location holds a Chromium file (`Profiles/Default/
/// Preferences` or `Profiles/Local State`); a fresh install just writes the
/// marker. It runs before the snapshot loads, never inside it.
enum EngineLayoutMigration {
    static let layoutMarkerName = ".open-layout"
    static let journalName = ".open-layout-journal.json"
    static let layoutVersion = "2\n"
    /// Open's own entries in a profile folder; everything else the old layout
    /// put in `Profiles/Default/` is Chromium's.
    static let openEntries: Set<String> = ["State", "Boosts", "AdBlock", "adblock", "Engine"]
    private static let logger = Logger(subsystem: "io.github.sergeserb2.open", category: "engine-layout")

    private struct Move: Codable, Equatable {
        /// Paths relative to the data root.
        var from: String
        var to: String
    }
    private struct Journal: Codable {
        var moves: [Move]
        /// Index of the publish rename in `moves`, if any.
        var publish: Int?
        var published = false
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(root: URL) -> EngineLayoutResult {
        let clock = ContinuousClock()
        let start = clock.now
        var result = EngineLayoutResult()
        do {
            try migrate(root: root, result: &result)
        } catch {
            // Only unexpected errors (an unwritable Engine folder) end here:
            // the old layout is untouched or was restored.
            result.layout = .legacy
            result.problem = "\(error)"
        }
        let elapsed = (clock.now - start).components
        result.milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        for line in result.report.moved { log("moved \(line)") }
        for line in result.report.skipped { log("skipped \(line)", error: true) }
        if let problem = result.problem {
            log("legacy layout for this launch, retried next launch: \(problem)", error: true)
        }
        return result
    }

    private static func log(_ line: String, error: Bool = false) {
        FileHandle.standardError.write(Data("engine layout: \(line)\n".utf8))
        if error { logger.error("\(line, privacy: .public)") } else { logger.notice("\(line, privacy: .public)") }
    }

    private static func migrate(root: URL, result: inout EngineLayoutResult) throws {
        let fm = FileManager.default
        let engine = root.appendingPathComponent("Engine", isDirectory: true)
        let legacy = root.appendingPathComponent("Profiles", isDirectory: true)
        let marker = engine.appendingPathComponent(layoutMarkerName)
        let journalURL = engine.appendingPathComponent(journalName)
        try fm.createDirectory(at: engine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)

        if DurableFiles.exists(journalURL) {
            // A crash or a failed rollback during an earlier launch.
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            try execute(journal, root: root, journalURL: journalURL, result: &result, resumed: true)
            return
        }
        if DurableFiles.exists(marker) { return }

        let legacyDefault = legacy.appendingPathComponent("Default", isDirectory: true)
        let hasChromiumData = DurableFiles.exists(legacyDefault.appendingPathComponent("Preferences"))
            || DurableFiles.exists(legacy.appendingPathComponent("Local State"))
        guard hasChromiumData else {
            // A fresh install, or an old root whose engine never ran.
            removeEmptyOldEngineFolders(legacy: legacy)
            try writeMarker(marker)
            return
        }
        if let owner = liveSingletonOwner(legacy) {
            result.layout = .legacy
            result.problem = "the old engine data is in use by process \(owner)"
            return
        }

        // Plan every rename. Nothing moves until the journal is durable.
        var moves: [Move] = []
        var publish: Int?
        let engineDefault = engine.appendingPathComponent("Default", isDirectory: true)
        let stage = engine.appendingPathComponent(".migrating-Default", isDirectory: true)
        let defaultItems = try entries(legacyDefault).filter { !openEntries.contains($0) }
        if !defaultItems.isEmpty {
            if try isInUse(engineDefault) {
                result.report.skipped.append(
                    "Profiles/Default: Engine/Default is in use; \(defaultItems.count) old Chromium item(s) left in Profiles/Default")
            } else {
                if DurableFiles.exists(stage) {
                    // An empty stage is a crash before the journal; anything
                    // else is an earlier build's copy: kept, never deleted.
                    if try entries(stage, includingHidden: true).isEmpty { try fm.removeItem(at: stage) }
                    else { try setAside(stage, root: root, result: &result) }
                }
                for item in defaultItems {
                    moves.append(Move(from: "Profiles/Default/\(item)", to: "Engine/.migrating-Default/\(item)"))
                }
                publish = moves.count
                moves.append(Move(from: "Engine/.migrating-Default", to: "Engine/Default"))
            }
        }
        for name in try entries(legacy) where !name.hasPrefix("Singleton") {
            let item = legacy.appendingPathComponent(name)
            if isProfileFolder(item, name: name) {
                // Other profiles' old engine folders: empty unless CEF ever
                // accepted them.
                let old = item.appendingPathComponent("Engine", isDirectory: true)
                guard name != "Default", isDirectory(old), !(try entries(old)).isEmpty else { continue }
                if DurableFiles.exists(engine.appendingPathComponent(name)) {
                    result.report.skipped.append("Profiles/\(name)/Engine: Engine/\(name) exists; left in place")
                } else {
                    moves.append(Move(from: "Profiles/\(name)/Engine", to: "Engine/\(name)"))
                }
                continue
            }
            if DurableFiles.exists(engine.appendingPathComponent(name)) {
                result.report.skipped.append("Profiles/\(name): Engine/\(name) exists; left in place")
                continue
            }
            moves.append(Move(from: "Profiles/\(name)", to: "Engine/\(name)"))
        }
        // Publish last, so the default profile appears complete or not at all.
        if let index = publish {
            let move = moves.remove(at: index)
            moves.append(move)
            publish = moves.count - 1
        }

        // Pre-flight: a locked entry or an unwritable folder fails before
        // anything moves.
        for move in moves where move.from != "Engine/.migrating-Default" {
            if let problem = renameProblem(root.appendingPathComponent(move.from)) {
                result.layout = .legacy
                result.problem = "\(move.from): \(problem)"
                return
            }
        }

        if !moves.isEmpty {
            if publish != nil {
                try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let journal = Journal(moves: moves, publish: publish)
            try DurableFiles.write(JSONEncoder().encode(journal), to: journalURL)
            DurableFiles.crashPoint("engine-journaled")
            try execute(journal, root: root, journalURL: journalURL, result: &result, resumed: false)
        } else {
            try finishAfterPublish(root: root, result: &result)
            try writeMarker(marker)
        }
    }

    /// Runs (or resumes) the journal's renames. A failure before the publish
    /// renames everything back and leaves the legacy layout for this launch.
    private static func execute(_ journal: Journal, root: URL, journalURL: URL,
                                result: inout EngineLayoutResult, resumed: Bool) throws {
        var journal = journal
        if !journal.published {
            var done: [Move] = []
            for (index, move) in journal.moves.enumerated() {
                let from = root.appendingPathComponent(move.from)
                let to = root.appendingPathComponent(move.to)
                if move.to == "Engine/Default" { removeIfOnlyFinderFiles(to) }
                switch (DurableFiles.exists(from), DurableFiles.exists(to)) {
                case (true, false):
                    let simulated = index == journal.publish && DurableFiles.failPoint("engine-publish")
                    guard !simulated, rename(from.path, to.path) == 0 else {
                        let error = DurableFiles.failure("rename \(move.from)")
                        try rollBack(done, root: root, journalURL: journalURL, result: &result, reason: "\(error.localizedDescription)")
                        return
                    }
                case (false, true):
                    break  // Done before a crash.
                case (true, true):
                    try rollBack(done, root: root, journalURL: journalURL, result: &result,
                                 reason: "\(move.from) and \(move.to) both exist")
                    return
                case (false, false):
                    result.report.missing.append(move.from)
                    continue
                }
                done.append(move)
                if index == 0 { DurableFiles.crashPoint("engine-moved") }
                if move.from.hasPrefix("Profiles/"), !move.from.hasPrefix("Profiles/Default/") {
                    DurableFiles.crashPoint("engine-installation")
                }
                if index + 1 == journal.publish { DurableFiles.crashPoint("engine-staged") }
            }
            for directory in ["Profiles/Default", "Profiles", "Engine/.migrating-Default", "Engine"] {
                let url = root.appendingPathComponent(directory)
                if DurableFiles.exists(url) { try DurableFiles.sync(url) }
            }
            if journal.publish != nil { DurableFiles.crashPoint("engine-published") }
            journal.published = true
            try DurableFiles.write(JSONEncoder().encode(journal), to: journalURL)
            let count = journal.moves.count - (journal.publish == nil ? 0 : 1)
            result.report.moved.append("\(count) Chromium item(s) to Engine/\(resumed ? " (resumed)" : "")")
        }
        try finishAfterPublish(root: root, result: &result)
        DurableFiles.crashPoint("engine-cleanup")
        try writeMarker(root.appendingPathComponent("Engine/\(layoutMarkerName)"))
        try FileManager.default.removeItem(at: journalURL)
        try DurableFiles.sync(journalURL.deletingLastPathComponent())
    }

    /// Renames `done` back in reverse order. The journal stays if that fails
    /// too, so the next launch tries again.
    private static func rollBack(_ done: [Move], root: URL, journalURL: URL,
                                 result: inout EngineLayoutResult, reason: String) throws {
        result.layout = .legacy
        result.problem = reason
        var stuck: [String] = []
        for move in done.reversed() {
            let from = root.appendingPathComponent(move.from)
            let to = root.appendingPathComponent(move.to)
            if DurableFiles.exists(to), !DurableFiles.exists(from), rename(to.path, from.path) != 0 {
                stuck.append(move.to)
            }
        }
        guard stuck.isEmpty else {
            result.problem = reason + "; could not move back: " + stuck.joined(separator: ", ")
            return
        }
        let stage = root.appendingPathComponent("Engine/.migrating-Default")
        if DurableFiles.exists(stage) { try? FileManager.default.removeItem(at: stage) }  // empty now
        try FileManager.default.removeItem(at: journalURL)
        for directory in ["Profiles/Default", "Profiles", "Engine"] {
            let url = root.appendingPathComponent(directory)
            if DurableFiles.exists(url) { try? DurableFiles.sync(url) }
        }
    }

    /// Best effort after the publish: problems are logged, never fatal.
    private static func finishAfterPublish(root: URL, result: inout EngineLayoutResult) throws {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("Profiles", isDirectory: true)
        // Chromium keeps a profile's HTTP and code caches in ~/Library/Caches
        // when the profile is under ~/Library/Application Support.
        let oldCache = ProfileDirectories.chromiumCacheDirectory(forProfile: legacy.appendingPathComponent("Default"))
        let newCache = ProfileDirectories.chromiumCacheDirectory(forProfile: root.appendingPathComponent("Engine/Default"))
        if oldCache.path != legacy.appendingPathComponent("Default").path, DurableFiles.exists(oldCache) {
            if DurableFiles.exists(newCache) {
                result.report.skipped.append("old cache \(oldCache.path) left: \(newCache.path) exists")
            } else {
                do {
                    try fm.createDirectory(at: newCache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard rename(oldCache.path, newCache.path) == 0 else { throw DurableFiles.failure("rename cache") }
                    result.report.moved.append("cache \(oldCache.path) -> \(newCache.path)")
                } catch {
                    result.report.skipped.append("old cache \(oldCache.path) left: \(error.localizedDescription)")
                }
            }
        }
        // Stale Singleton* links of the old engine (its owner was checked).
        for name in (try? entries(legacy, includingHidden: true)) ?? [] where name.hasPrefix("Singleton") {
            let link = legacy.appendingPathComponent(name)
            if unlink(link.path) != 0 {
                result.report.skipped.append("Profiles/\(name): \(String(cString: strerror(errno)))")
            }
        }
        removeEmptyOldEngineFolders(legacy: legacy)
    }

    private static func writeMarker(_ marker: URL) throws {
        try DurableFiles.write(Data(layoutVersion.utf8), to: marker)
    }

    /// `Profiles/<dir>/Engine` folders the old layout created and CEF never used.
    private static func removeEmptyOldEngineFolders(legacy: URL) {
        for name in (try? entries(legacy)) ?? [] {
            let old = legacy.appendingPathComponent(name).appendingPathComponent("Engine", isDirectory: true)
            if isDirectory(old), ((try? entries(old, includingHidden: true)) ?? ["?"]).allSatisfy({ $0 == ".DS_Store" }) {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }

    /// The new folder holds a profile already: anything but Finder's files.
    private static func isInUse(_ engineDefault: URL) throws -> Bool {
        guard DurableFiles.exists(engineDefault) else { return false }
        return try !entries(engineDefault, includingHidden: true).allSatisfy { $0 == ".DS_Store" }
    }

    private static func removeIfOnlyFinderFiles(_ url: URL) {
        guard let names = try? entries(url, includingHidden: true), names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves an unexplained leftover (an earlier interrupted build's stage)
    /// out of the way instead of deleting it.
    private static func setAside(_ url: URL, root: URL, result: inout EngineLayoutResult) throws {
        let aside = root.appendingPathComponent("Profiles/.engine-migration-leftovers", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = aside.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString)")
        guard rename(url.path, target.path) == 0 else { throw DurableFiles.failure("set aside \(url.lastPathComponent)") }
        result.report.skipped.append("\(url.lastPathComponent) set aside in Profiles/.engine-migration-leftovers")
    }

    /// Why `url` cannot be renamed, if a cheap check can tell: a locked
    /// (immutable or append-only) entry, or an unwritable parent folder.
    private static func renameProblem(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "missing" }
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        if info.st_flags & locked != 0 { return "locked (immutable or append-only flag)" }
        if access(url.deletingLastPathComponent().path, W_OK) != 0 { return "parent folder not writable" }
        return nil
    }

    /// The pid in `Profiles/SingletonLock` ("<host>-<pid>"), if that process
    /// on this host is alive.
    private static func liveSingletonOwner(_ legacy: URL) -> Int32? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: legacy.appendingPathComponent("SingletonLock").path),
              let dash = target.lastIndex(of: "-"), let pid = Int32(target[target.index(after: dash)...]) else { return nil }
        var host = [CChar](repeating: 0, count: 256)
        gethostname(&host, host.count)
        let hostName = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard String(target[..<dash]) == hostName, pid > 0, pid != getpid() else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
    }

    /// Visible entries (dot entries are Finder's or migration state).
    private static func entries(_ url: URL, includingHidden: Bool = false) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { includingHidden || !$0.hasPrefix(".") }.sorted()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// One of Open's profile folders: `Default`, or a folder holding Open's
    /// own entries. Chromium's installation-wide folders hold neither.
    private static func isProfileFolder(_ url: URL, name: String) -> Bool {
        guard isDirectory(url) else { return false }
        if name == "Default" { return true }
        return openEntries.contains { DurableFiles.exists(url.appendingPathComponent($0)) }
    }
}
