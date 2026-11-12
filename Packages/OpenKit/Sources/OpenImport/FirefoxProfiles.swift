import Foundation
import Darwin

/// One Gecko profile from `profiles.ini`. Evidence: docs/re/browser-import.md §4.3.
public struct FirefoxProfile: Sendable, Equatable {
    public var name: String
    public var directory: URL
    public var isDefault: Bool
    /// Stable key for history import keys and bookmark IDs: "<browser>:<directory name>".
    public var sourceKey: String
}

/// Gecko-family source browsers. Catalog rows only (lead ruling 3, 11 Nov 10:55).
public struct FirefoxFamilyBrowser: Sendable, Equatable {
    public var key: String
    public var displayName: String
    public var bundleIDs: [String]
    /// Relative to `~/Library/Application Support`.
    public var dataRoot: String

    public static let firefox = FirefoxFamilyBrowser(key: "firefox", displayName: "Firefox",
        bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"], dataRoot: "Firefox")
    public static let zen = FirefoxFamilyBrowser(key: "zen", displayName: "Zen", bundleIDs: ["app.zen-browser.zen"], dataRoot: "zen")
    public static let librewolf = FirefoxFamilyBrowser(key: "librewolf", displayName: "LibreWolf", bundleIDs: ["io.gitlab.librewolf-community"], dataRoot: "librewolf")
    public static let floorp = FirefoxFamilyBrowser(key: "floorp", displayName: "Floorp", bundleIDs: ["one.ablaze.floorp"], dataRoot: "Floorp")
    public static let all: [FirefoxFamilyBrowser] = [.firefox, .zen, .librewolf, .floorp]
}

public enum FirefoxProfileError: Error, Equatable { case missingProfilesIni, unreadable, noProfiles }

public enum FirefoxProfileCatalog {
    /// Reads `profiles.ini` (and `installs.ini` for the default of this install) under `root`.
    /// Only directory names and the INI are read; no profile file is opened.
    public static func profiles(root: URL, browser: FirefoxFamilyBrowser = .firefox) throws -> [FirefoxProfile] {
        let ini = root.appendingPathComponent("profiles.ini")
        guard FileManager.default.fileExists(atPath: ini.path) else { throw FirefoxProfileError.missingProfilesIni }
        guard let data = try? Data(contentsOf: ini), data.count <= 1 << 20 else { throw FirefoxProfileError.unreadable }
        let sections = parseINI(String(decoding: data, as: UTF8.self))
        var installDefaults = Set<String>()
        if let installs = try? Data(contentsOf: root.appendingPathComponent("installs.ini")), installs.count <= 1 << 20 {
            for (name, values) in parseINI(String(decoding: installs, as: UTF8.self)) where name.hasPrefix("Install") || name.hasPrefix("install") {
                if let path = values["Default"] { installDefaults.insert(path) }
            }
        }
        for (name, values) in sections where name.hasPrefix("Install") {
            if let path = values["Default"] { installDefaults.insert(path) }
        }
        var result: [FirefoxProfile] = []
        for (name, values) in sections where name.hasPrefix("Profile") {
            guard let path = values["Path"], !path.isEmpty, !path.contains("\0") else { continue }
            let relative = values["IsRelative"].map { $0 != "0" } ?? true
            let directory = relative ? root.appendingPathComponent(path, isDirectory: true) : URL(fileURLWithPath: path, isDirectory: true)
            if relative {
                let resolved = directory.standardizedFileURL.path, base = root.standardizedFileURL.path
                guard resolved.hasPrefix(base + "/") else { continue }
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let isDefault = installDefaults.isEmpty ? values["Default"] == "1" : installDefaults.contains(path)
            result.append(FirefoxProfile(name: values["Name"] ?? directory.lastPathComponent, directory: directory,
                                         isDefault: isDefault, sourceKey: "\(browser.key):\(directory.lastPathComponent)"))
        }
        guard !result.isEmpty else { throw FirefoxProfileError.noProfiles }
        // Default first, then the INI order.
        return result.enumerated().sorted { ($0.element.isDefault ? 0 : 1, $0.offset) < ($1.element.isDefault ? 0 : 1, $1.offset) }.map(\.element)
    }

    static func parseINI(_ text: String) -> [(String, [String: String])] {
        var sections: [(String, [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:])); continue
            }
            guard let equals = line.firstIndex(of: "="), !sections.isEmpty else { continue }
            sections[sections.count - 1].1[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return sections
    }

    /// True while a running Gecko process holds the POSIX lock on `.parentlock`.
    /// This only tests the lock (F_GETLK); it never takes it. A leftover file after a quit is not a lock.
    public static func isLocked(_ profile: URL) -> Bool {
        let path = profile.appendingPathComponent(".parentlock").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET); lock.l_start = 0; lock.l_len = 0
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }
}
