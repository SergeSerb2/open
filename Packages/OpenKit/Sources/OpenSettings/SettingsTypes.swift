import Foundation
import OpenModel

public enum PaneID: String, CaseIterable, Sendable {
    case general, profiles, links, shortcuts, appIcon, advanced
    public var title: String { switch self {
    case .general: "General"; case .profiles: "Profiles"; case .links: "Links"
    case .shortcuts: "Shortcuts"; case .appIcon: "Icon"; case .advanced: "Advanced"
    } }
    public var symbol: String { switch self {
    case .general: "gearshape"; case .profiles: "person"; case .links: "rectangle.on.rectangle"
    case .shortcuts: "keyboard"; case .appIcon: "app.dashed"; case .advanced: "slider.horizontal.3"
    } }
}

public enum AppIconOption: String, CaseIterable, Sendable {
    case openDefault, openDark, openLight, openMono, openColor, openRetro
    public var title: String { switch self {
    case .openDefault: "The Original Open"; case .openDark: "Midnight"; case .openLight: "Daylight"
    case .openMono: "Graphite"; case .openColor: "Spectrum"; case .openRetro: "Notebook"
    } }
}

/// UI labels map to the model policy. No second sleep policy lives here.
public enum TabSleepMode: String, CaseIterable, Sendable {
    case automatic, conservative, aggressive, never
    public var modelMode: SleepMode { switch self {
    case .automatic: .balanced; case .conservative: .conservative; case .aggressive: .aggressive; case .never: .off
    } }
}

public enum DownloadState: String, CaseIterable, Sendable { case inProgress, paused, completed, failed, cancelled }
public struct DownloadItemSnapshot: Identifiable, Sendable {
    public var id: String
    public var fileName: String
    public var sourceHost: String
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var state: DownloadState
    public var filePath: String?
    public var startedAt: Date
    public var profileID: ProfileID
    public var bytesPerSecond: Int64 = 0
    public var errorDescription: String?
    public var progress: Double? { totalBytes.flatMap { $0 > 0 ? min(1, Double(receivedBytes) / Double($0)) : nil } }
    public init(id: String, fileName: String, sourceHost: String, receivedBytes: Int64, totalBytes: Int64?, state: DownloadState, filePath: String?, startedAt: Date, profileID: ProfileID) {
        self.id = id; self.fileName = fileName; self.sourceHost = sourceHost; self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes; self.state = state; self.filePath = filePath; self.startedAt = startedAt; self.profileID = profileID
    }
}
public enum CaptureKind: String, Codable, CaseIterable, Sendable { case area, fullPage, portrait, screenshot }
public struct CaptureItemSnapshot: Identifiable, Codable, Sendable {
    public var id: UUID
    public var fileName: String
    public var createdAt: Date
    public var kind: CaptureKind
    public var sourceHost: String
    public init(id: UUID, fileName: String, createdAt: Date, kind: CaptureKind, sourceHost: String) {
        self.id = id; self.fileName = fileName; self.createdAt = createdAt; self.kind = kind; self.sourceHost = sourceHost
    }
}
public extension AutoArchiveInterval {
    var settingsTitle: String { switch self {
    case .never: "Never"; case .oneHour: "1 hour"; case .sixHours: "6 hours"; case .twelveHours: "12 hours"
    case .twentyFourHours: "24 hours"; case .sevenDays: "7 days"; case .thirtyDays: "30 days"
    } }
}

/// Complete app registry, including additions in §§5.1.1, 5.2 and 5.4.2.
@MainActor public enum SettingsDefaults {
    public static let values: [String: Any] = [
        "open.settings.lastPane": "general", "open.general.automaticallyUpdate": true,
        "open.general.warnBeforeQuitting": true, "open.general.previewsEnabled": true,
        "open.general.previewsOnHover": true, "open.general.previewsDelaySeconds": 0.5,
        "open.general.searchSuggestNoticeDismissed": false,
        "open.links.externalInLittleOpen": true, "open.links.littleOpenHotkeyEnabled": true,
        "open.links.optionCommandClickLittleOpen": true, "open.links.openPeekOtherSites": true,
        "open.links.openPeekShiftClick": true, "open.advanced.restoreWindowsOnLaunch": true,
        "open.advanced.enablePictureInPictureOnLeave": true, "open.advanced.allowWindowDraggingFromWebTop": false,
        "open.advanced.showFullURLWithToolbar": false, "open.advanced.enableBoosts": true,
        "open.advanced.allowSitesThemeData": false, "open.advanced.enableSharedQuotes": true,
        "open.advanced.playSoundEffects": false, "open.advanced.hapticOnTabReorder": true,
        "open.advanced.tabSleepMode": "automatic", "open.appIcon.selectedID": "openDefault",
        "open.library.lastSection": "archive", "open.shortcuts.defaultPriority": "browser",
        "open.shortcuts.includeFavoritesInTabNumbering": true, "open.shortcuts.switchToNinthEnabled": true,
    ]
    public static func register(in defaults: UserDefaults) { defaults.register(defaults: values) }
}
