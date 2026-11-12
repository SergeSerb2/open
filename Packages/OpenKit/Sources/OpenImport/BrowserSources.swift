import Foundation

/// The data format family of an import source. Each family has its own readers.
/// Evidence: Arc's catalog `import_source_catalog.cc` (docs/re/browser-import.md §1).
public enum BrowserFamily: String, Sendable, Hashable, Codable {
    case arc, chromium, firefox, safari
}

/// One browser Open knows how to find on this Mac. Facts only: bundle IDs and data roots.
public struct BrowserSourceDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let family: BrowserFamily
    /// Relative to `~/Library`.
    public let dataRoot: String
    /// Opera keeps its single profile at the data root, not in `Default`.
    public let profileAtRoot: Bool

    public init(id: String, name: String, bundleID: String, family: BrowserFamily, dataRoot: String, profileAtRoot: Bool = false) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.family = family
        self.dataRoot = dataRoot; self.profileAtRoot = profileAtRoot
    }
}

/// One source profile (Chromium `Default`, `Profile 1`, …; Firefox profile directory; Safari has one).
public struct BrowserSourceProfile: Sendable, Hashable, Identifiable {
    /// The directory basename. It is the import identity, never the display name.
    public let id: String
    public let name: String
    public let directory: URL
    public init(id: String, name: String, directory: URL) { self.id = id; self.name = name; self.directory = directory }
}

/// A browser that is present on this Mac, with its profiles.
public struct BrowserSource: Sendable, Hashable, Identifiable {
    public let descriptor: BrowserSourceDescriptor
    public let dataRoot: URL
    public let profiles: [BrowserSourceProfile]
    /// The data root exists but this process may not list it (macOS data protection or Full Disk Access).
    public let accessDenied: Bool
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
    public var family: BrowserFamily { descriptor.family }
    /// Families whose readers exist in this build. IMF adds `.firefox` and `.safari`.
    public var isSupported: Bool { BrowserSourceCatalog.supportedFamilies.contains(descriptor.family) }
    public init(descriptor: BrowserSourceDescriptor, dataRoot: URL, profiles: [BrowserSourceProfile], accessDenied: Bool) {
        self.descriptor = descriptor; self.dataRoot = dataRoot; self.profiles = profiles; self.accessDenied = accessDenied
    }
}

/// What the import wizard imports from. Arc keeps its own folder-based path.
public enum ImportSource: Sendable, Hashable {
    case arc
    case browser(BrowserSource, profile: BrowserSourceProfile)

    public var displayName: String {
        switch self {
        case .arc: "Arc"
        case .browser(let source, _): source.name
        }
    }
    /// Stable key for history import dedup and deterministic sidebar IDs.
    public var importKey: String {
        switch self {
        case .arc: "arc"
        case .browser(let source, let profile): source.family.rawValue + ":" + source.id + ":" + profile.id
        }
    }
}

/// Finds installed browsers by their data roots. Reads directory listings and
/// `Local State` only; it never opens a browser database. Cheap enough to run
/// when the import sheet opens, and never earlier.
public struct BrowserSourceCatalog: Sendable {
    /// Arc's catalog plus Chromium (F3 §8 Q3). Order is the picker order.
    /// GUESS — capture pending: Arc's tile order (F3 §3 item 1).
    public static let descriptors: [BrowserSourceDescriptor] = [
        .init(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", family: .chromium, dataRoot: "Application Support/Google/Chrome"),
        .init(id: "safari", name: "Safari", bundleID: "com.apple.Safari", family: .safari, dataRoot: "Safari"),
        .init(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", family: .firefox, dataRoot: "Application Support/Firefox"),
        .init(id: "brave", name: "Brave", bundleID: "com.brave.Browser", family: .chromium, dataRoot: "Application Support/BraveSoftware/Brave-Browser"),
        .init(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", family: .chromium, dataRoot: "Application Support/Microsoft Edge"),
        .init(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", family: .chromium, dataRoot: "Application Support/Vivaldi"),
        .init(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera", family: .chromium, dataRoot: "Application Support/com.operasoftware.Opera", profileAtRoot: true),
        .init(id: "opera-gx", name: "Opera GX", bundleID: "com.operasoftware.OperaGX", family: .chromium, dataRoot: "Application Support/com.operasoftware.OperaGX", profileAtRoot: true),
        .init(id: "chrome-canary", name: "Chrome Canary", bundleID: "com.google.Chrome.canary", family: .chromium, dataRoot: "Application Support/Google/Chrome Canary"),
        .init(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", family: .chromium, dataRoot: "Application Support/Chromium"),
    ]
    /// IMF extends this set when its readers land.
    public static let supportedFamilies: Set<BrowserFamily> = [.arc, .chromium]

    public let library: URL
    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")) {
        self.library = library
    }

    public func detect() -> [BrowserSource] {
        Self.descriptors.compactMap { detect($0) }
    }

    public func detect(_ descriptor: BrowserSourceDescriptor) -> BrowserSource? {
        let root = library.appendingPathComponent(descriptor.dataRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
            return BrowserSource(descriptor: descriptor, dataRoot: root, profiles: [], accessDenied: true)
        }
        let profiles: [BrowserSourceProfile]
        switch descriptor.family {
        case .chromium: profiles = Self.chromiumProfiles(root: root, atRoot: descriptor.profileAtRoot)
        case .arc, .firefox, .safari: profiles = []
        }
        return BrowserSource(descriptor: descriptor, dataRoot: root, profiles: profiles, accessDenied: false)
    }

    /// `Local State` → `profile.info_cache.<dir>.name`, ordered by `profile.profiles_order`.
    /// Only directories with a bookmarks or history file are kept.
    static func chromiumProfiles(root: URL, atRoot: Bool) -> [BrowserSourceProfile] {
        let fm = FileManager.default
        func usable(_ directory: URL) -> Bool {
            ["Bookmarks", "History", "Preferences"].contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        if atRoot {
            return usable(root) ? [BrowserSourceProfile(id: "Default", name: "Default", directory: root)] : []
        }
        var names: [String: String] = [:]
        var order: [String] = []
        if let json = try? ChromiumProfileReader.readJSON(root.appendingPathComponent("Local State")),
           let profile = json["profile"] as? [String: Any] {
            if let cache = profile["info_cache"] as? [String: Any] {
                for (key, value) in cache { names[key] = ((value as? [String: Any])?["name"] as? String) ?? key }
            }
            order = (profile["profiles_order"] as? [String]) ?? []
        }
        var directories = order.filter { names[$0] != nil }
        directories += names.keys.filter { !directories.contains($0) }.sorted()
        if let listed = try? fm.contentsOfDirectory(atPath: root.path) {
            directories += listed.filter { ($0 == "Default" || $0.hasPrefix("Profile ")) && !directories.contains($0) }.sorted()
        }
        // A real Chromium install has a handful of profiles; refuse to list more than 100.
        return directories.prefix(100).compactMap { directory in
            guard Self.safeBasename(directory) else { return nil }
            let url = root.appendingPathComponent(directory, isDirectory: true)
            guard usable(url) else { return nil }
            let name = names[directory].flatMap { $0.isEmpty ? nil : $0 } ?? (directory == "Default" ? "Default" : directory)
            return BrowserSourceProfile(id: directory, name: name, directory: url)
        }
    }

    static func safeBasename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." && !name.contains("/")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
