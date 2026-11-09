import Foundation
import OpenModel

/// The sole path convention for a Profile's persistent data. Constructing paths does no I/O.
public struct ProfileDirectories: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Open", isDirectory: true)
    }

    public func profileDirectory(dataDirectoryName: String) -> URL {
        Self.validate(dataDirectoryName)
        return root.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    /// Chromium's `root_cache_path`. CEF loads a disk profile only for a
    /// direct child of it, so every profile's engine data is `Engine/<dir>`;
    /// the default profile (CEF's global context) is always `Engine/Default`.
    /// Installation-wide Chromium files (Local State, component downloads)
    /// live here too. Open's own per-profile files stay in `Profiles/<dir>/`.
    public var engineRoot: URL { root.appendingPathComponent("Engine", isDirectory: true) }
    public func engineDirectory(dataDirectoryName: String) -> URL {
        Self.validate(dataDirectoryName)
        return engineRoot.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    /// Where Chromium keeps the profile's HTTP and code caches. A profile under
    /// ~/Library/Application Support uses the same path under ~/Library/Caches;
    /// any other profile keeps them inside its own folder
    /// (chrome/common/chrome_paths_mac.mm, GetUserCacheDirectory).
    public func engineCacheDirectory(dataDirectoryName: String) -> URL {
        Self.chromiumCacheDirectory(forProfile: engineDirectory(dataDirectoryName: dataDirectoryName))
    }
    public static func chromiumCacheDirectory(forProfile profile: URL) -> URL {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return profile }
        let base = support.standardizedFileURL.path + "/"
        let path = profile.standardizedFileURL.path
        guard path.hasPrefix(base) else { return profile }
        return caches.appendingPathComponent(String(path.dropFirst(base.count)), isDirectory: true)
    }
    private static func validate(_ name: String) {
        precondition(!name.isEmpty && name != "." && name != ".." && !name.contains("/"), "Invalid Profile directory name")
    }
    private func stateFile(_ file: String, _ name: String) -> URL { profileDirectory(dataDirectoryName: name).appendingPathComponent("State", isDirectory: true).appendingPathComponent(file) }
    public func historyFileURL(dataDirectoryName: String) -> URL { stateFile("history.sqlite3", dataDirectoryName) }
    public func archiveFileURL(dataDirectoryName: String) -> URL { stateFile("archive.sqlite3", dataDirectoryName) }
    public func downloadsFileURL(dataDirectoryName: String) -> URL { stateFile("downloads.sqlite3", dataDirectoryName) }
    public func sleepFileURL(dataDirectoryName: String) -> URL { stateFile("sleep.sqlite3", dataDirectoryName) }
    public func boostsFileURL(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("Boosts/boosts.json") }
    public func adBlockDirectory(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("AdBlock", isDirectory: true) }
    public func adBlockListsDirectory(dataDirectoryName: String) -> URL { adBlockDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("lists", isDirectory: true) }

    /// Open's own directories. The engine creates `Engine/<dir>` when the
    /// profile's context first loads. A profile folder is private (0700), as
    /// Chromium's are.
    public func ensureProfileDirectories(dataDirectoryName: String) throws {
        let fm = FileManager.default
        let profile = profileDirectory(dataDirectoryName: dataDirectoryName)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        let paths = [historyFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), boostsFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), adBlockListsDirectory(dataDirectoryName: dataDirectoryName)]
        for path in paths { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
    }

    public var retiredDirectoriesFileURL: URL { root.appendingPathComponent("State/retired-profile-dirs.json") }

    public func unavailableDirectoryNames() throws -> Set<String> {
        var names: Set<String> = []
        for parent in [root.appendingPathComponent("Profiles"), engineRoot] where FileManager.default.fileExists(atPath: parent.path) {
            names.formUnion(try FileManager.default.contentsOfDirectory(atPath: parent.path))
        }
        if FileManager.default.fileExists(atPath: retiredDirectoriesFileURL.path) {
            names.formUnion(try JSONDecoder().decode([String].self, from: Data(contentsOf: retiredDirectoriesFileURL)))
        }
        return Set(names.map { $0.lowercased() })
    }

    public func retireDirectoryName(_ name: String) throws {
        var names: Set<String> = []
        if FileManager.default.fileExists(atPath: retiredDirectoriesFileURL.path) {
            names.formUnion(try JSONDecoder().decode([String].self, from: Data(contentsOf: retiredDirectoriesFileURL)))
        }
        names.insert(name.lowercased())
        try DurableFiles.write(JSONEncoder().encode(names.sorted()), to: retiredDirectoriesFileURL)
    }

    /// Caller must tear down the engine first. Model deletion alone never calls this.
    /// Removes Open's files, the profile's engine data, and its Chromium cache.
    public func deleteProfileData(dataDirectoryName: String) throws {
        let engine = engineDirectory(dataDirectoryName: dataDirectoryName)
        let cache = engineCacheDirectory(dataDirectoryName: dataDirectoryName)
        if cache != engine, DurableFiles.exists(cache) { try FileManager.default.removeItem(at: cache) }
        if DurableFiles.exists(engine) { try FileManager.default.removeItem(at: engine) }
        try FileManager.default.removeItem(at: profileDirectory(dataDirectoryName: dataDirectoryName))
    }
}

@MainActor
extension ProfileDirectories {
    public func profileDirectory(for profile: Profile) -> URL { profileDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func engineDirectory(for profile: Profile) -> URL { engineDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func engineCacheDirectory(for profile: Profile) -> URL { engineCacheDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func historyFileURL(for profile: Profile) -> URL { historyFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func archiveFileURL(for profile: Profile) -> URL { archiveFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func sleepFileURL(for profile: Profile) -> URL { sleepFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func boostsFileURL(for profile: Profile) -> URL { boostsFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func adBlockDirectory(for profile: Profile) -> URL { adBlockDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func adBlockListsDirectory(for profile: Profile) -> URL { adBlockListsDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func ensureProfileDirectories(for profile: Profile) throws { try ensureProfileDirectories(dataDirectoryName: profile.dataDirectoryName) }
    public func deleteProfileData(for profile: Profile) throws { try deleteProfileData(dataDirectoryName: profile.dataDirectoryName) }
}
