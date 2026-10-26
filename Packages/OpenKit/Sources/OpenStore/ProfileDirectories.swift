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
    private static func validate(_ name: String) {
        precondition(!name.isEmpty && name != "." && name != ".." && !name.contains("/"), "Invalid Profile directory name")
    }
    private func stateFile(_ file: String, _ name: String) -> URL { profileDirectory(dataDirectoryName: name).appendingPathComponent("State", isDirectory: true).appendingPathComponent(file) }
    public func historyFileURL(dataDirectoryName: String) -> URL { stateFile("history.sqlite3", dataDirectoryName) }
    public func archiveFileURL(dataDirectoryName: String) -> URL { stateFile("archive.sqlite3", dataDirectoryName) }
    public func sleepFileURL(dataDirectoryName: String) -> URL { stateFile("sleep.sqlite3", dataDirectoryName) }
    public func boostsFileURL(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("Boosts/boosts.json") }
    public func adBlockDirectory(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("AdBlock", isDirectory: true) }
    public func adBlockListsDirectory(dataDirectoryName: String) -> URL { adBlockDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("lists", isDirectory: true) }

    /// Open's own directories. The engine creates `Engine/<dir>` when the
    /// profile's context first loads.
    public func ensureProfileDirectories(dataDirectoryName: String) throws {
        let paths = [historyFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), boostsFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), adBlockListsDirectory(dataDirectoryName: dataDirectoryName)]
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
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
    /// Removes Open's files and the profile's engine data.
    public func deleteProfileData(dataDirectoryName: String) throws {
        let engine = engineDirectory(dataDirectoryName: dataDirectoryName)
        if DurableFiles.exists(engine) { try FileManager.default.removeItem(at: engine) }
        try FileManager.default.removeItem(at: profileDirectory(dataDirectoryName: dataDirectoryName))
    }
}

@MainActor
extension ProfileDirectories {
    public func profileDirectory(for profile: Profile) -> URL { profileDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func engineDirectory(for profile: Profile) -> URL { engineDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func historyFileURL(for profile: Profile) -> URL { historyFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func archiveFileURL(for profile: Profile) -> URL { archiveFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func sleepFileURL(for profile: Profile) -> URL { sleepFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func boostsFileURL(for profile: Profile) -> URL { boostsFileURL(dataDirectoryName: profile.dataDirectoryName) }
    public func adBlockDirectory(for profile: Profile) -> URL { adBlockDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func adBlockListsDirectory(for profile: Profile) -> URL { adBlockListsDirectory(dataDirectoryName: profile.dataDirectoryName) }
    public func ensureProfileDirectories(for profile: Profile) throws { try ensureProfileDirectories(dataDirectoryName: profile.dataDirectoryName) }
    public func deleteProfileData(for profile: Profile) throws { try deleteProfileData(dataDirectoryName: profile.dataDirectoryName) }
}
