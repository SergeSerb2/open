import Foundation

public struct ArcExtensionRecord: Sendable {
    public var extensionID: String
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
}

public struct ArcExtensionsReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    public func read() throws -> (report: ArcExtensionReport, records: [ArcExtensionRecord]) {
        let fm = FileManager.default
        let preferences = profileDirectory.appendingPathComponent("Secure Preferences")
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: preferences.path) {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any] else {
                throw ArcHistoryImportError.schemaMismatch
            }
            settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
        }
        let payloadRoot = profileDirectory.appendingPathComponent("Extensions", isDirectory: true)
        let rootPath = payloadRoot.resolvingSymlinksInPath().path + "/"
        func safeDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return url.resolvingSymlinksInPath().path.hasPrefix(rootPath)
                && fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        var folders: [String: URL] = [:]
        if fm.fileExists(atPath: payloadRoot.path) {
            for folder in try fm.contentsOfDirectory(at: payloadRoot, includingPropertiesForKeys: nil) where safeDirectory(folder) {
                folders[folder.lastPathComponent] = folder
            }
        }
        var report = ArcExtensionReport()
        var records: [ArcExtensionRecord] = []
        for id in Set(settings.keys).union(folders.keys).sorted() {
            let entry = settings[id] as? [String: Any]
            var manifest = entry?["manifest"] as? [String: Any]
            if manifest == nil, let folder = folders[id] {
                let versions = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { safeDirectory($0) }
                    .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                for version in versions {
                    let file = version.appendingPathComponent("manifest.json")
                    guard file.resolvingSymlinksInPath().path.hasPrefix(rootPath), fm.fileExists(atPath: file.path) else { continue }
                    if let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        manifest = object
                        break
                    }
                }
            }
            let path = entry?["path"] as? String ?? ""
            let isInternal = path.hasPrefix("/Applications/") || (path.isEmpty && folders[id] == nil)
                || (entry == nil && manifest == nil)
            records.append(ArcExtensionRecord(extensionID: id, version: manifest?["version"] as? String,
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
