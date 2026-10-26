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
        precondition(!dataDirectoryName.isEmpty && dataDirectoryName != "." && dataDirectoryName != ".." && !dataDirectoryName.contains("/"), "Invalid Profile directory name")
        return root.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    public func engineDirectory(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("Engine", isDirectory: true) }
    private func stateFile(_ file: String, _ name: String) -> URL { profileDirectory(dataDirectoryName: name).appendingPathComponent("State", isDirectory: true).appendingPathComponent(file) }
    public func historyFileURL(dataDirectoryName: String) -> URL { stateFile("history.sqlite3", dataDirectoryName) }
    public func archiveFileURL(dataDirectoryName: String) -> URL { stateFile("archive.sqlite3", dataDirectoryName) }
    public func sleepFileURL(dataDirectoryName: String) -> URL { stateFile("sleep.sqlite3", dataDirectoryName) }
    public func boostsFileURL(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("Boosts/boosts.json") }
    public func adBlockDirectory(dataDirectoryName: String) -> URL { profileDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("AdBlock", isDirectory: true) }
    public func adBlockListsDirectory(dataDirectoryName: String) -> URL { adBlockDirectory(dataDirectoryName: dataDirectoryName).appendingPathComponent("lists", isDirectory: true) }

    public func ensureProfileDirectories(dataDirectoryName: String) throws {
        let paths = [engineDirectory(dataDirectoryName: dataDirectoryName), historyFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), boostsFileURL(dataDirectoryName: dataDirectoryName).deletingLastPathComponent(), adBlockListsDirectory(dataDirectoryName: dataDirectoryName)]
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }

    /// Caller must tear down the engine first. Model deletion alone never calls this.
    public func deleteProfileData(dataDirectoryName: String) throws {
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
