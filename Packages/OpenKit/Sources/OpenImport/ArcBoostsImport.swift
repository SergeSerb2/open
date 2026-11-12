import Foundation
import CoreFoundation
import OpenBoosts

public struct ArcBoostsReport: Sendable {
    public var cacheFound = false
    public var status = "not found"
    public var found = 0, imported = 0, malformed = 0, deleted = 0, unknownDocuments = 0, otherCollections = 0
    public var unknownFields = 0, mappedFields = 0, defaultProfileGuesses = 0, enablementUnknown = 0
    public var fieldsDropped: [String: Int] = [:]
    public init() {}
}
public struct ArcBoostsReadResult: Sendable {
    public var boosts: [Boost] = []
    public var report = ArcBoostsReport()
    public init() {}
}

/// The cache contains account-scoped documents; Profile ownership is not stored.
/// Destination assignment to Default is an explicit guess, counted per Boost.
public struct ArcBoostsReader: Sendable {
    public let arcDirectory: URL
    public let cacheDirectory: URL
    public init(arcDirectory: URL, cacheDirectory: URL? = nil) {
        self.arcDirectory = arcDirectory
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let isRealArc = arcDirectory.standardizedFileURL == support.appendingPathComponent("Arc").standardizedFileURL
        self.cacheDirectory = cacheDirectory ?? (isRealArc
            ? support.appendingPathComponent("firestore/Arc/bcny-arc-server/main")
            : arcDirectory.appendingPathComponent("Firestore/main"))
    }
    public func read() -> ArcBoostsReadResult {
        var result = ArcBoostsReadResult()
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return result }
        result.report.cacheFound = true
        do {
            let documents = try ArcFirestore.privateCopy(cacheDirectory) { try ArcFirestore.read(copy: $0) }
            result.report.found = documents.documents.count
            result.report.deleted = documents.deleted; result.report.unknownDocuments = documents.unknown
            result.report.otherCollections = documents.otherCollections; result.report.malformed = documents.malformed
            let enabled = enabledIDs(report: &result.report)
            for document in documents.documents.sorted(by: { $0.id < $1.id }) {
                // A malformed entry must not discard any other valid Boost.
                var candidateReport = result.report
                do {
                    let boost = try map(document, enabled: enabled, report: &candidateReport)
                    result.report = candidateReport; result.boosts.append(boost)
                    result.report.imported += 1; result.report.defaultProfileGuesses += 1
                } catch { result.report.malformed += 1 }
            }
            result.report.status = "read"
        } catch {
            // Keep the rest of Import from Arc usable. No source values or paths
            // are interpolated in errors, logs, or the count-only report.
            result.report.status = error is CancellationError ? "cancelled" : "unreadable or exceeds limit"
        }
        return result
    }
    private func normalizedID(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }
    private func enabledIDs(report: inout ArcBoostsReport) -> Set<String>? {
        do {
            let bytes = try ArcLevelDB.file(arcDirectory.appendingPathComponent("StorableBoostsData.json"), limit: 2 * 1024 * 1024)
            guard let root = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let ids = root["locallyEnabledBoostIDs"] as? [Any], ids.count <= 4096 else { return nil }
            var result: Set<String> = []
            for raw in ids {
                guard let object = raw as? [String: Any], let id = object["value"] as? String,
                      !id.isEmpty, id.utf8.count <= 256 else { return nil }
                result.insert(normalizedID(id))
            }
            report.unknownFields += root.keys.filter { !["version", "locallyEnabledBoostIDs"].contains($0) }.count
            return result
        } catch { return nil }
    }
    private func map(_ document: ArcFirestoreDocument, enabled: Set<String>?, report: inout ArcBoostsReport) throws -> Boost {
        let fields = document.fields
        func remoteString(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            if case .null = value { return nil }
            guard let text = value.string else { throw ArcCacheError.invalid }
            return text
        }
        let title = try remoteString("title"), forkID = try remoteString("forkedFromBoostID")
        guard let host = fields["hostPattern"]?.string, !host.isEmpty, host.utf8.count <= 253,
              let serialized = fields["data"]?.string, serialized.utf8.count <= ArcFirestore.stringLimit,
              let data = serialized.data(using: .utf8),
              let components = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArcCacheError.invalid }
        // A broader or path-based Arc pattern must not silently become a
        // whole-domain Open Boost. Bare hosts and a leading *. are supported.
        let bare = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        guard !bare.isEmpty, !bare.contains(".."), bare.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "."
        }), bare.first != ".", bare.last != "." else { throw ArcCacheError.invalid }
        var visited = 0
        func bound(_ value: Any, depth: Int) throws {
            visited += 1
            guard depth < 16, visited <= 8192 else { throw ArcCacheError.limit }
            if let dictionary = value as? [String: Any] {
                guard dictionary.count <= 128 else { throw ArcCacheError.limit }
                for (key, value) in dictionary { guard key.utf8.count <= 256 else { throw ArcCacheError.limit }; try bound(value, depth: depth + 1) }
            } else if let array = value as? [Any] {
                guard array.count <= 1024 else { throw ArcCacheError.limit }
                for value in array { try bound(value, depth: depth + 1) }
            }
        }
        try bound(components, depth: 0)
        let knownTop: Set<String> = ["creatorID", "hostPattern", "data", "title", "author", "signature", "type", "lastModified", "isActive", "forkedFromBoostID", "forkedFromSnapshotID"]
        report.unknownFields += fields.keys.filter { !knownTop.contains($0) }.count
        let knownComponents: Set<String> = ["css", "js", "font", "textTransform", "textZoom", "zaps", "colorScheme"]
        report.unknownFields += components.keys.filter { !knownComponents.contains($0) }.count
        for key in ["creatorID", "author", "signature", "type", "forkedFromSnapshotID"] where fields[key] != nil { report.fieldsDropped[key, default: 0] += 1 }
        func optionalString(_ key: String) throws -> String {
            guard let raw = components[key], !(raw is NSNull) else { return "" }
            guard let text = raw as? String, text.utf8.count <= ArcFirestore.stringLimit else { throw ArcCacheError.invalid }
            report.mappedFields += 1; return text
        }
        let css = try optionalString("css"), js = try optionalString("js")
        let modified: Date
        if let raw = try remoteString("lastModified") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let value = formatter.date(from: raw)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = value ?? formatter.date(from: raw) else { throw ArcCacheError.invalid }
            modified = date; report.mappedFields += 1
        } else { modified = document.updatedAt ?? Date(timeIntervalSince1970: 0) }
        var active = true
        if let raw = fields["isActive"] {
            if let text = raw.string, ["true", "false"].contains(text) { active = text == "true" }
            else if let value = raw.bool { active = value }
            else { throw ArcCacheError.invalid }
        }
        // Missing local enablement never activates imported code on a site.
        // The state is unknown, counted, and imported disabled until reviewed.
        if enabled == nil { report.enablementUnknown += 1 }
        let isEnabled = active && (enabled?.contains(normalizedID(document.id)) ?? false)
        var font: String?, transform: String?
        if let raw = components["font"], !(raw is NSNull) {
            guard let object = raw as? [String: Any], let family = object["family"] as? String, family.utf8.count <= 1024 else { throw ArcCacheError.invalid }
            font = family; report.mappedFields += 1
            report.unknownFields += object.keys.filter { $0 != "family" }.count
        }
        if let raw = components["textTransform"], !(raw is NSNull) {
            guard let text = raw as? String, ["capitalize", "uppercase", "lowercase"].contains(text) else { throw ArcCacheError.invalid }
            transform = text; report.mappedFields += 1
        }
        var zaps: [ZappedElement] = []
        if let raw = components["zaps"], !(raw is NSNull) {
            guard let selectors = raw as? [String], selectors.count <= 1024,
                  selectors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw ArcCacheError.invalid }
            zaps = selectors.map { ZappedElement(selector: $0, createdAt: modified) }; report.mappedFields += 1
        }
        var textZoom: Double?
        if let zoom = components["textZoom"], !(zoom is NSNull) {
            guard let object = zoom as? [String: Any], let level = object["level"] as? NSNumber,
                  CFGetTypeID(level) != CFBooleanGetTypeID(), level.doubleValue.isFinite,
                  level.doubleValue == Double(level.intValue) else { throw ArcCacheError.invalid }
            // Capture C11 (Arc 1.172.2): `level` is the percent itself (the Size button stores
            // 110, 125, 150, 90; normal is the absent key). Open's multiplier is level / 100.
            // A level outside Open's 50…200 % range is not a size Arc's editor can write:
            // counted as dropped, never clamped into a different size.
            if (50...200).contains(level.intValue) {
                textZoom = level.intValue == 100 ? nil : level.doubleValue / 100
                report.mappedFields += 1
            } else { report.fieldsDropped["textZoom.level", default: 0] += 1 }
            report.unknownFields += object.keys.filter { $0 != "level" }.count
        }
        var wheel: BoostColorWheel?
        if let color = components["colorScheme"], !(color is NSNull) {
            // PB4 row 4: the knob inputs Open stores are Arc's stored knob fields
            // (docs/plans/boost-color-remap.md §7.2: `primaryHueDegrees` = stored `hue`,
            // `primarySaturation` = stored `intensity`; `invertLightness` the same name).
            // Every other leaf (secondary offset, base appearance, advanced settings,
            // theme-driven schemes) has no proven Open input: counted, not invented.
            let colorKeys: Set<String> = ["colorWheelDriven", "themeDriven", "_0", "primaryHueDegrees", "primarySaturation", "secondaryHueOffset", "invertLightness", "baseAppearance", "advancedSettings", "light", "dark", "preservedSaturation", "preservedLightness", "lightnessShift", "secondarySaturation", "primaryLightness", "secondaryLightness", "primaryColorModel", "secondaryColorModel"]
            func dropped(_ value: Any, path: String) {
                if let object = value as? [String: Any], !object.isEmpty {
                    for (key, child) in object {
                        if colorKeys.contains(key) { dropped(child, path: path + "." + key) }
                        else { report.unknownFields += 1 }
                    }
                } else { report.fieldsDropped[path, default: 0] += 1 }
            }
            var rest = color
            if var object = color as? [String: Any], var driven = object["colorWheelDriven"] as? [String: Any],
               var scheme = driven["_0"] as? [String: Any] {
                func number(_ key: String) -> Double? {
                    guard let value = scheme[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                    return value.doubleValue
                }
                if let hue = number("primaryHueDegrees"), let saturation = number("primarySaturation") {
                    let invert = (scheme["invertLightness"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : false } ?? false
                    wheel = BoostColorWheel(hue: hue, intensity: saturation, invertLightness: invert).clamped()
                    report.mappedFields += 1
                    for key in ["primaryHueDegrees", "primarySaturation", "invertLightness"] { scheme[key] = nil }
                    // Prune emptied containers so mapped leaves are not counted as dropped.
                    driven["_0"] = scheme.isEmpty ? nil : scheme
                    object["colorWheelDriven"] = driven.isEmpty ? nil : driven
                    rest = object
                }
            }
            if let object = rest as? [String: Any], object.isEmpty, wheel != nil {} else { dropped(rest, path: "colorScheme") }
        }
        report.mappedFields += 3 // ID, site match, enabled state
        if title != nil { report.mappedFields += 1 }
        let fork = forkID.map { BoostID(rawValue: ArcImporter.deterministicUUID(for: $0, namespace: "boost")) }
        if fork != nil { report.mappedFields += 1 }
        return Boost(id: BoostID(rawValue: ArcImporter.deterministicUUID(for: document.id, namespace: "boost")),
            name: title ?? "", siteMatch: SiteMatch(domain: bare), isEnabled: isEnabled,
            css: css, js: js, colorWheel: wheel, fontFamily: font, textZoom: textZoom, textTransform: transform, zaps: zaps,
            createdAt: document.createdAt ?? modified, updatedAt: modified, forkedFromID: fork)
    }
}
