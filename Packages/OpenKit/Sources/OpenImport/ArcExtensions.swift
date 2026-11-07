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
        let payloadRoot = profileDirectory.appendingPathComponent("Extensions", isDirectory: true)
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
            let isInternal = path.hasPrefix("/Applications/") || (path.isEmpty && folders[id] == nil)
                || (entry == nil && manifest == nil)
            let name = manifest?["name"] as? String
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
