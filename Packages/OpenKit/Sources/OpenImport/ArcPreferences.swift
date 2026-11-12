import Foundation

/// Read-only reader for Arc's app preferences (`~/Library/Preferences/company.thebrowser.Browser.plist`), shared by
/// every Import from Arc mapping of an Arc setting (plan NS §2 CAL; LEAD 04:05). Arc writes a key only after the user
/// changes it, so a missing key keeps Open's default. Never writes to Arc's file and never goes through `cfprefsd`
/// for Arc's domain (no `UserDefaults(suiteName:)`), so Arc's preferences cannot change.
public struct ArcPreferences: Sendable {
    public static let domain = "company.thebrowser.Browser"
    /// Arc's preferences file is a few KB; refuse anything over this size.
    public static let maxBytes = 8 << 20
    /// Values Open maps, copied out of the property list (Sendable).
    public private(set) var bools: [String: Bool] = [:]
    public private(set) var strings: [String: String] = [:]
    /// Arc's per-Profile Live Calendar reminder times (`liveCalendarNotificationPreferences`): Arc Profile key →
    /// Arc raw value (`never`, `onStart`, `twoMinutesBefore`, `fiveMinutesBefore`, `tenMinutesBefore`; strings next to
    /// `BaseModels/LiveCalendar.swift` in the Arc 1.172.2 binary). The container format is not known (no Arc data on
    /// this Mac has the key); the reader accepts a dictionary or JSON data of one. GUESS — capture pending.
    public private(set) var reminderIntervals: [String: String] = [:]
    /// The file was found and read.
    public private(set) var found = false

    /// Where Arc keeps its preferences for an Arc data folder at `<home>/Library/Application Support/Arc`:
    /// `<home>/Library/Preferences/company.thebrowser.Browser.plist`. Synthetic e2e roots use the same layout.
    public static func fileURL(arcDirectory: URL) -> URL {
        arcDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Preferences", isDirectory: true).appendingPathComponent(domain + ".plist")
    }

    public init() {}

    /// Reads the file next to `arcDirectory`. A missing file gives an empty value (`found` false); an unreadable or
    /// oversized file throws.
    public static func read(arcDirectory: URL) throws -> ArcPreferences {
        let url = fileURL(arcDirectory: arcDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return ArcPreferences() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var prefs = ArcPreferences()
        prefs.found = true
        for key in ArcPreferenceMapping.boolKeys {
            if let value = root[key] as? Bool { prefs.bools[key] = value }
            else if let value = root[key] as? NSNumber { prefs.bools[key] = value.boolValue }
        }
        if let value = root[ArcPreferenceMapping.reminderKey] { prefs.reminderIntervals = Self.intervals(from: value) }
        return prefs
    }

    static let intervalValues: Set<String> = ["never", "onStart", "twoMinutesBefore", "fiveMinutesBefore", "tenMinutesBefore"]

    /// `[profileKey: rawValue]` from a dictionary (or JSON data of one) whose values are a raw value, or an object
    /// holding one (for example `{"interval": "twoMinutesBefore"}` or Swift's enum encoding `{"twoMinutesBefore": {}}`).
    static func intervals(from value: Any) -> [String: String] {
        var object = value
        if let data = value as? Data, data.count <= maxBytes, let json = try? JSONSerialization.jsonObject(with: data) { object = json }
        guard let dictionary = object as? [String: Any] else { return [:] }
        func raw(_ any: Any, depth: Int = 0) -> String? {
            if let text = any as? String { return intervalValues.contains(text) ? text : nil }
            guard depth < 3, let inner = any as? [String: Any] else { return nil }
            if let key = inner.keys.first(where: intervalValues.contains), inner.count == 1 { return key }
            for nested in inner.values { if let found = raw(nested, depth: depth + 1) { return found } }
            return nil
        }
        var out: [String: String] = [:]
        for (key, nested) in dictionary.prefix(256) { if let value = raw(nested) { out[key] = value } }
        return out
    }
}

/// Arc setting → Open setting. Arc's Previews sheet has seven switches (docs/re/live-data.md §3.1, capture session 2).
public enum ArcPreferenceMapping {
    /// One Open key per Arc key. Several Arc calendar switches feed one Open switch: it stays on when any is on.
    public static let previews: [(arc: String, open: String)] = [
        ("folderPreviewEnabled", "open.general.previewsFolders"),
        ("recentPagesPreviewEnabled", "open.general.previewsRecents"),
        ("calendarPreviewEnabled", "open.general.previewsCalendar"),
        ("outlookCalendarPreviewEnabled", "open.general.previewsCalendar"),
        ("cronPreviewEnabled", "open.general.previewsCalendar"),
        ("notionCalendarPreviewEnabled", "open.general.previewsCalendar"),
        // Reserved for LF's Gmail card (L6); Settings shows no row until it lands.
        ("gmailPreviewEnabled", "open.general.previewsGmail"),
    ]
    /// Arc keys read but not mapped, with the reason (shown in the import report counts).
    public static let unmapped: [String: String] = [
        // F-questions LEAD 11:05 Q2: Outlook Mail keeps the live-page preview; no native card, no switch.
        "outlookEmailPreviewEnabled": "Outlook Mail has no native card in Open",
    ]
    public static let meetRouteKey = "didSetDefaultGoogleMeetRoute"
    public static let openMeetRouteKey = "open.links.didSetDefaultMeetRoute"
    public static let reminderKey = "liveCalendarNotificationPreferences"
    static var boolKeys: [String] { previews.map(\.arc) + Array(unmapped.keys) + [meetRouteKey] }

    /// Open's raw value for an Arc reminder raw value (`LiveCalendar.ReminderInterval`).
    public static func openInterval(_ arc: String) -> String? {
        ["never": "never", "onStart": "onStart", "twoMinutesBefore": "twoMinutes",
         "fiveMinutesBefore": "fiveMinutes", "tenMinutesBefore": "tenMinutes"][arc]
    }

    /// Open settings to write: key → Bool. Calendar is on when any present Arc calendar switch is on.
    public static func openSettings(_ prefs: ArcPreferences) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (arc, open) in previews {
            guard let value = prefs.bools[arc] else { continue }
            out[open] = (out[open] ?? false) || value
        }
        // Arc already made its Meet rule (it comes in with Arc's routing rules): Open must not add a second one.
        if prefs.bools[meetRouteKey] == true { out[openMeetRouteKey] = true }
        return out
    }
}

public extension ArcImporter {
    /// The Open Profile ID the importer gives an Arc Profile key (`default` or a custom Profile key).
    static func profileID(forArcProfileKey key: String) -> UUID {
        deterministicUUID(for: key == "Default" ? "default" : key, namespace: "profile")
    }
}
