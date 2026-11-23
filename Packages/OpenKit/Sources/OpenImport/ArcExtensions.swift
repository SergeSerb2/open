import Foundation

public struct ArcExtensionRecord: Sendable {
    public var extensionID: String
    /// Display only. Never include this value in CLI output or receipts.
    public var manifestName: String?
    public var version: String?
    public var manifestVersion: Int?
    public var fromWebStore: Bool
    public var locationRaw: Int?
    public var isInternal: Bool
}

public struct ArcExtensionReport: Sendable {
    public var totalRecords: Int = 0
    public var internalRecords: Int = 0
    public var reinstallCandidates: Int = 0
    public var missingManifest: Int = 0
    public init() {}
}

public enum ArcExtensionsReadError: Error { case exceedsLimit }

public struct ArcExtensionsReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    /// Replaces every `__MSG_key__` token (case-insensitive key). Nil when a key is unknown, or the result is
    /// empty or over the 1024-byte name limit (ignored, so it cannot fail the whole Profile read).
    static func localizedName(_ raw: String, messages: [String: Any]) -> String? {
        var lookup: [String: String] = [:]
        for (key, value) in messages { if let message = (value as? [String: Any])?["message"] as? String { lookup[key.lowercased()] = message } }
        guard let pattern = try? NSRegularExpression(pattern: "__MSG_([A-Za-z0-9_@]+?)__") else { return nil }
        var result = "", cursor = raw.startIndex
        for match in pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let whole = Range(match.range, in: raw), let key = Range(match.range(at: 1), in: raw),
                  let message = lookup[raw[key].lowercased()] else { return nil }
            result += raw[cursor..<whole.lowerBound] + message
            cursor = whole.upperBound
        }
        result += raw[cursor...]
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("__MSG_") || trimmed.utf8.count > 1024 ? nil : trimmed
    }
    private func boundedData(_ file: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // The largest read buffer is 16 MiB + 1. At 24x JSON expansion the
        // largest decoded input is about 384 MiB, below the 2 GiB ceiling.
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw ArcExtensionsReadError.exceedsLimit }
        return data
    }

    private func children(_ directory: URL, maximum: Int) throws -> [URL] {
        var failure: (any Error)?
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else {
            throw ArcHistoryImportError.schemaMismatch
        }
        var result: [URL] = []
        for case let child as URL in entries {
            guard result.count < maximum else { throw ArcExtensionsReadError.exceedsLimit }
            result.append(child)
        }
        if let failure { throw failure }
        return result
    }

    public func read() throws -> (report: ArcExtensionReport, records: [ArcExtensionRecord]) {
        let fm = FileManager.default
        let preferences = profileDirectory.appendingPathComponent("Secure Preferences")
        let profilePath = profileDirectory.resolvingSymlinksInPath().path + "/"
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: preferences.path) {
            guard preferences.resolvingSymlinksInPath().path.hasPrefix(profilePath) else { throw ArcHistoryImportError.schemaMismatch }
            let data = try boundedData(preferences, maximum: 16 * 1024 * 1024)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArcHistoryImportError.schemaMismatch
            }
            settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
            guard settings.count <= 4096 else { throw ArcExtensionsReadError.exceedsLimit }
        }
        // Resolve the existing Profile first: a missing child can otherwise
        // keep a different /private/var alias from its resolved parent.
        let payloadRoot = profileDirectory.resolvingSymlinksInPath().appendingPathComponent("Extensions", isDirectory: true)
        let rootPath = payloadRoot.resolvingSymlinksInPath().path + "/"
        guard rootPath.hasPrefix(profilePath) else { throw ArcHistoryImportError.schemaMismatch }
        func safeDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return url.resolvingSymlinksInPath().path.hasPrefix(rootPath)
                && fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var folders: [String: URL] = [:]
        if fm.fileExists(atPath: payloadRoot.path) {
            for folder in try children(payloadRoot, maximum: 4096) where safeDirectory(folder) {
                folders[folder.lastPathComponent] = folder
                guard folders.count <= 4096 else { throw ArcExtensionsReadError.exceedsLimit }
            }
        }
        var report = ArcExtensionReport()
        var records: [ArcExtensionRecord] = []
        guard Set(settings.keys).union(folders.keys).count <= 4096 else { throw ArcExtensionsReadError.exceedsLimit }
        for id in Set(settings.keys).union(folders.keys).sorted() {
            let entry = settings[id] as? [String: Any]
            var manifest = entry?["manifest"] as? [String: Any]
            if manifest == nil, let folder = folders[id] {
                let versions = try children(folder, maximum: 256)
                    .filter { safeDirectory($0) }
                    .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                guard versions.count <= 256 else { throw ArcExtensionsReadError.exceedsLimit }
                for version in versions {
                    let file = version.appendingPathComponent("manifest.json")
                    guard file.resolvingSymlinksInPath().path.hasPrefix(rootPath), fm.fileExists(atPath: file.path) else { continue }
                    let data: Data
                    do { data = try boundedData(file, maximum: 1024 * 1024) }
                    catch ArcExtensionsReadError.exceedsLimit { throw ArcExtensionsReadError.exceedsLimit }
                    catch { continue }
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        manifest = object
                        break
                    }
                }
            }
            let path = entry?["path"] as? String ?? ""
            // Built in, never a reinstall candidate: a component (Chromium `ManifestLocation` 5 kComponent,
            // 10 kExternalComponent), an extension the browser installed by default (`was_installed_by_default`, such as
            // Chrome's "Google Docs Offline" and "Chrome Web Store Payments", which live in the profile's own Extensions
            // folder), an extension inside an app bundle, or a settings-only entry with no payload.
            let location = entry?["location"] as? Int
            let isInternal = location == 5 || location == 10 || entry?["was_installed_by_default"] as? Bool == true
                || path.hasPrefix("/Applications/") || (path.isEmpty && folders[id] == nil)
                || (entry == nil && manifest == nil)
            var name = manifest?["name"] as? String
            // A localized name holds `__MSG_key__` tokens, resolved from the default locale's messages.json as
            // Chromium does (every token, anywhere in the name). An unknown key leaves no name, so the list shows
            // the ID (bug sweep r7 Y-06, review r1 #4).
            if let raw = name, raw.contains("__MSG_") {
                name = nil
                let locale = (manifest?["default_locale"] as? String) ?? ""
                let pathParts = path.split(separator: "/")
                if let folder = folders[id], !locale.isEmpty, !locale.contains("/"), !locale.contains("..") {
                    // The version Preferences names first; a stale path falls back to the newest folder on disk.
                    let named = pathParts.count == 2 && pathParts[0] == Substring(id)
                        ? [folder.appendingPathComponent(String(pathParts[1]), isDirectory: true)] : []
                    let scanned = ((try? children(folder, maximum: 256)) ?? [])
                        .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                    for version in named + scanned where safeDirectory(version) {
                        let file = version.appendingPathComponent("_locales/\(locale)/messages.json")
                        guard file.resolvingSymlinksInPath().path.hasPrefix(rootPath), fm.fileExists(atPath: file.path),
                              let data = try? boundedData(file, maximum: 1024 * 1024),
                              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        name = Self.localizedName(raw, messages: messages)
                        break
                    }
                }
            }
            guard id.utf8.count <= 256, (name?.utf8.count ?? 0) <= 1024 else { throw ArcExtensionsReadError.exceedsLimit }
            records.append(ArcExtensionRecord(extensionID: id, manifestName: name, version: manifest?["version"] as? String,
                                               manifestVersion: manifest?["manifest_version"] as? Int,
                                               fromWebStore: entry?["from_webstore"] as? Bool ?? false,
                                               locationRaw: entry?["location"] as? Int, isInternal: isInternal))
            report.totalRecords += 1
            if manifest == nil { report.missingManifest += 1 }
            if isInternal { report.internalRecords += 1 } else { report.reinstallCandidates += 1 }
        }
        return (report, records)
    }
}
