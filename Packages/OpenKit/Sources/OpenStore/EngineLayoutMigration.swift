import Foundation
import Darwin

/// One-time move of Chromium's data to `<root>/Engine`, the engine's
/// `root_cache_path` (docs/plans/profiles.md §6.2).
///
/// The old layout used `<root>/Profiles` as `root_cache_path`:
/// - the default profile's Chromium files sat in `Profiles/Default/`, next to
///   Open's own `State/`, `Boosts/`, and `AdBlock/`;
/// - installation-wide Chromium files (`Local State`, component downloads)
///   sat in `Profiles/`;
/// - other profiles pointed at `Profiles/<dir>/Engine/`, which CEF refused
///   (not a direct child of `root_cache_path`), so those stayed empty.
///
/// Crash safety: a profile's Chromium files are cloned (APFS copy-on-write)
/// into a staging folder, compared with the originals, and published with
/// one rename. Only then are the originals removed. The published folder
/// carries a marker listing them until that removal is done, so any crash
/// resumes on the next run. Installation-wide files move with single renames.
/// Runs before the engine starts (OpenDataRoot.prepare); idempotent.
enum EngineLayoutMigration {
    static let markerName = ".open-engine-migration.json"
    /// Open's own entries in a profile folder. Everything else that the old
    /// layout put in `Profiles/Default/` is Chromium's.
    static let openEntries: Set<String> = ["State", "Boosts", "AdBlock", "Engine"]

    static func migrate(root: URL, profileDirectoryNames: Set<String>) throws -> ProfileMigrationReport {
        var report = ProfileMigrationReport()
        let fm = FileManager.default
        let directories = ProfileDirectories(root: root)
        let legacy = root.appendingPathComponent("Profiles", isDirectory: true)
        guard isDirectory(legacy) else { return report }
        try fm.createDirectory(at: directories.engineRoot, withIntermediateDirectories: true)

        // The default profile (CEF's global context was always <root_cache_path>/Default).
        let legacyDefault = legacy.appendingPathComponent("Default", isDirectory: true)
        if isDirectory(legacyDefault) {
            let items = try entries(legacyDefault).filter { !openEntries.contains($0) }
            try move(items, from: legacyDefault, to: directories.engineRoot.appendingPathComponent("Default", isDirectory: true),
                     label: "Profiles/Default", report: &report)
        }

        // Other profiles' old engine folders: empty unless CEF ever accepted them.
        for name in try entries(legacy) where isDirectory(legacy.appendingPathComponent(name)) {
            let old = legacy.appendingPathComponent(name).appendingPathComponent("Engine", isDirectory: true)
            guard isDirectory(old) else { continue }
            if name != "Default" {
                try move(try entries(old), from: old, to: directories.engineRoot.appendingPathComponent(name, isDirectory: true),
                         label: "Profiles/\(name)/Engine", report: &report)
            }
            if try fm.contentsOfDirectory(atPath: old.path).isEmpty { try fm.removeItem(at: old) }
        }

        // Installation-wide files: whatever in Profiles/ is not a profile folder.
        for name in try entries(legacy) where !name.hasPrefix("Singleton") {
            let item = legacy.appendingPathComponent(name)
            if isProfileFolder(item, name: name, known: profileDirectoryNames) { continue }
            let target = directories.engineRoot.appendingPathComponent(name)
            if DurableFiles.exists(target) {
                report.skipped.append("Profiles/\(name): Engine/\(name) exists; left in place")
                continue
            }
            guard rename(item.path, target.path) == 0 else { throw DurableFiles.failure("move Profiles/\(name)") }
            report.moved.append("Profiles/\(name) -> Engine/\(name)")
        }
        try DurableFiles.sync(legacy)
        try DurableFiles.sync(directories.engineRoot)
        return report
    }

    /// Clones `items` of `source` into `destination`, checks the clone,
    /// publishes it, then removes the originals.
    private static func move(_ items: [String], from source: URL, to destination: URL, label: String,
                             report: inout ProfileMigrationReport) throws {
        let fm = FileManager.default
        let marker = destination.appendingPathComponent(markerName)
        if DurableFiles.exists(marker) {
            // Published before a crash; finish removing the originals.
            let listed = try JSONDecoder().decode([String].self, from: Data(contentsOf: marker))
            try removeOriginals(listed, from: source, marker: marker)
            report.moved.append("\(label) -> Engine/\(destination.lastPathComponent) (resumed)")
            return
        }
        guard !items.isEmpty else { return }
        if DurableFiles.exists(destination), !(try entries(destination, includingHidden: true)).isEmpty {
            // The engine already uses the new folder: never mix two profiles.
            report.skipped.append("\(label): Engine/\(destination.lastPathComponent) is in use; \(items.count) old item(s) left in place")
            return
        }
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".migrating-\(destination.lastPathComponent)", isDirectory: true)
        if DurableFiles.exists(stage) { try fm.removeItem(at: stage) }  // an unfinished earlier copy
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        for item in items {
            try fm.copyItem(at: source.appendingPathComponent(item), to: stage.appendingPathComponent(item))
        }
        DurableFiles.crashPoint("engine-copied")
        for item in items {
            let original = try inventory(source.appendingPathComponent(item))
            guard original == (try inventory(stage.appendingPathComponent(item))) else {
                try? fm.removeItem(at: stage)
                throw migrationError("\(label)/\(item): the copy differs from the original; nothing moved")
            }
        }
        try DurableFiles.write(JSONEncoder().encode(items), to: stage.appendingPathComponent(markerName))
        try syncTree(stage)
        DurableFiles.crashPoint("engine-staged")
        if DurableFiles.exists(destination) { try fm.removeItem(at: destination) }  // empty, checked above
        guard rename(stage.path, destination.path) == 0 else { throw DurableFiles.failure("publish \(label)") }
        try DurableFiles.sync(destination.deletingLastPathComponent())
        DurableFiles.crashPoint("engine-published")
        try removeOriginals(items, from: source, marker: marker)
        report.moved.append("\(label) -> Engine/\(destination.lastPathComponent) (\(items.count) items)")
    }

    private static func removeOriginals(_ items: [String], from source: URL, marker: URL) throws {
        let fm = FileManager.default
        for (index, item) in items.enumerated() {
            let url = source.appendingPathComponent(item)
            if DurableFiles.exists(url) { try fm.removeItem(at: url) }
            if index == 0 { DurableFiles.crashPoint("engine-cleanup") }
        }
        if DurableFiles.exists(source) { try DurableFiles.sync(source) }
        try fm.removeItem(at: marker)
        try DurableFiles.sync(marker.deletingLastPathComponent())
    }

    /// Relative path -> kind and size (or link target) of every entry under `url`, without following links.
    private static func inventory(_ url: URL) throws -> [String: String] {
        let fm = FileManager.default
        func describe(_ path: String) throws -> String {
            let attributes = try fm.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: return "dir"
            case .typeSymbolicLink?: return "link:" + ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "")
            case .typeRegular?: return "file:\((attributes[.size] as? NSNumber)?.uint64Value ?? 0)"
            default: return "other"
            }
        }
        var out = ["": try describe(url.path)]
        guard out[""] == "dir" else { return out }
        for relative in try fm.subpathsOfDirectory(atPath: url.path) {
            out[relative] = try describe(url.appendingPathComponent(relative).path)
        }
        return out
    }

    private static func syncTree(_ directory: URL) throws {
        let fm = FileManager.default
        for relative in try fm.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(relative)
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeRegular || type == .typeDirectory { try DurableFiles.sync(url) }
        }
        try DurableFiles.sync(directory)
    }

    /// Visible entries (dot entries are temporary or migration state).
    private static func entries(_ url: URL, includingHidden: Bool = false) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { includingHidden || !$0.hasPrefix(".") }.sorted()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// A folder of Open's: a known profile directory name, or one that holds
    /// Open's own entries. Chromium's installation-wide folders hold neither.
    private static func isProfileFolder(_ url: URL, name: String, known: Set<String>) -> Bool {
        guard isDirectory(url) else { return false }
        if name == "Default" || known.contains(name) { return true }
        return openEntries.contains { DurableFiles.exists(url.appendingPathComponent($0)) }
    }

    private static func migrationError(_ message: String) -> NSError {
        NSError(domain: "OpenStore.EngineLayoutMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
