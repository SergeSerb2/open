import Foundation
import OpenModel
import OpenCommands

public struct ClearDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let history = Self(rawValue: 1), cookies = Self(rawValue: 2), cache = Self(rawValue: 4), downloads = Self(rawValue: 8)
}
public enum ClearDataRange: String, CaseIterable, Sendable {
    case lastHour = "Last hour", lastDay = "Last 24 hours", lastWeek = "Last 7 days", all = "All time"
}
public enum ProfilePage: String, Sendable { case privacy, passwords, paymentMethods, notifications }
public struct ImportPlan: Sendable {
    public var directory: URL
    public var spaces = true, tabs = true, favorites = true, folders = true, archive = true, history = false, searchSettings = true
    public var secretsRequested = false
    public private(set) var secretsConsented = false
    public init(directory: URL) { self.directory = directory }
    /// Only the explicit consent button should call this method.
    public mutating func skipSecrets() { secretsRequested = false; secretsConsented = false }
    public mutating func consentToSecrets() { secretsRequested = true; secretsConsented = true }
}
public struct ImportOutcome: Sendable {
    public var counts: [String: Int]
    public var errorText: String?
    public var failures: [String: String]
    public init(counts: [String: Int] = [:], errorText: String? = nil, failures: [String: String] = [:]) { self.counts = counts; self.errorText = errorText; self.failures = failures }
}

/// One import action and capability shared by Settings and first run.
@MainActor public protocol ImportActions: AnyObject {
    var canImportPasswordsAndCookies: Bool { get }
    func runImport(plan: ImportPlan) async -> ImportOutcome
}
public extension ImportActions { var canImportPasswordsAndCookies: Bool { false } }

@MainActor public protocol SettingsActions: ImportActions {
    func setAsDefaultBrowser() -> String?
    func isDefaultBrowser() -> Bool
    func checkForUpdates()
    func openMoreSettings()
    func revealOpenDataFolder()
    func copyOpenInfoToPasteboard()
    func deleteProfileData(profileID: ProfileID) -> String?
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds) async -> String?
    func clearBrowsingData(profileID: ProfileID, kinds: ClearDataKinds, range: ClearDataRange) async -> String?
    func openProfileSubpage(profileID: ProfileID, page: ProfilePage)
    func openPreviewsSettings()
    func keyBindingsDidChange(store: KeyBindingStore)
    func setAdBlockEnabled(_ on: Bool, profileID: ProfileID)
    func setEnabledBlockLists(_ ids: [String], profileID: ProfileID)
    func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID)
    func adBlockDebugInfo(profileID: ProfileID) -> String
    func setTabSleepMode(_ mode: TabSleepMode)
    func setApplicationIcon(id: String)
    // Required by plan buttons that have no method in its original protocol sketch.
    func resetTranslatePrompts(profileID: ProfileID) -> String?
    func openURL(_ url: URL, profileID: ProfileID)
    func openHelp(topic: String)
    func copyText(_ text: String)
    func openLibrary()
}
