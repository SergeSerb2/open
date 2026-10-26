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
    public mutating func consentToSecrets() { secretsRequested = true; secretsConsented = true }
}
public struct ImportOutcome: Sendable {
    public var counts: [String: Int]
    public var errorText: String?
    public init(counts: [String: Int] = [:], errorText: String? = nil) { self.counts = counts; self.errorText = errorText }
}

@MainActor public protocol SettingsActions: AnyObject {
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
    func runImport(plan: ImportPlan) async -> ImportOutcome
    func setAdBlockEnabled(_ on: Bool, profileID: ProfileID)
    func setEnabledBlockLists(_ ids: [String], profileID: ProfileID)
    func setAdBlockExcludedDomains(_ domains: [String], profileID: ProfileID)
    func adBlockDebugInfo(profileID: ProfileID) -> String
    func setTabSleepMode(_ mode: TabSleepMode)
    func setApplicationIcon(id: String)
    // Required by plan buttons that have no method in its original protocol sketch.
    func resetTranslatePrompts(profileID: ProfileID) -> String?
    func openHelp(topic: String)
    func copyText(_ text: String)
    func openLibrary()
}
