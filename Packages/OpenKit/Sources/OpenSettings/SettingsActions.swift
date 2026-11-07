import Foundation
import AppKit
import OpenModel
import OpenCommands

public struct ClearDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let history = Self(rawValue: 1), cookies = Self(rawValue: 2), cache = Self(rawValue: 4), downloads = Self(rawValue: 8)
}
public enum ClearDataRange: String, CaseIterable, Sendable {
    case lastHour = "Last hour", lastDay = "Last 24 hours", lastWeek = "Last 7 days", lastFourWeeks = "Last 4 weeks", all = "All time"
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
enum ImportCountCopy {
    static func phrase(_ count:Int,singular:String,plural:String)->String {
        "\(count.formatted()) \(count == 1 ? singular:plural)"
    }
    static func displayCategory(_ category:String)->String {category == "Search settings" ? "Search engine":category}
}

public struct ImportOutcome: Sendable {
    public var counts: [String: Int]
    public var errorText: String?
    public var failures: [String: String]
    public init(counts: [String: Int] = [:], errorText: String? = nil, failures: [String: String] = [:]) { self.counts = counts; self.errorText = errorText; self.failures = failures }
}

/// One import action and capability shared by Settings and first run.
/// Canonical adapter keys. Legacy display keys remain accepted at the one outcome boundary.
public enum ImportOutcomeKeys {
    public static let spaces="Imported Spaces",tabs="Imported items",archive="Imported Archive",history="Imported History"
    public static let imported=[spaces,tabs,archive,history,"Spaces","Imported tabs","Archive","History","Favorites","Folders","Search settings","Passwords and cookies"]
}
public extension ImportOutcome {
    func importedCount(_ category:String)->Int {
        let aliases:[String:[String]]=["Spaces":[ImportOutcomeKeys.spaces,"Spaces"],"Imported tabs":["Imported tabs",ImportOutcomeKeys.tabs,"Pinned and Today tabs"],"Pinned and Today tabs":["Pinned and Today tabs",ImportOutcomeKeys.tabs],"Archive":[ImportOutcomeKeys.archive,"Archive"],"History":[ImportOutcomeKeys.history,"History"]]
        return (aliases[category] ?? [category]).compactMap{counts[$0]}.first ?? 0
    }
    var didImportAnything:Bool {ImportOutcomeKeys.imported.contains {counts[$0,default:0] > 0}}
}

@MainActor public protocol ImportActions: AnyObject {
    var canImportPasswordsAndCookies: Bool { get }
    func runImport(plan: ImportPlan) async -> ImportOutcome
}
public extension ImportActions { var canImportPasswordsAndCookies: Bool { false } }

public struct ExtensionShortcutConflict: Sendable, Hashable {
    public var extensionName: String
    public var commandDescription: String
    public var shortcut: OpenCommands.KeyboardShortcut
    public var openCommandID: String
    public init(extensionName: String, commandDescription: String, shortcut: OpenCommands.KeyboardShortcut, openCommandID: String) {
        self.extensionName = extensionName; self.commandDescription = commandDescription
        self.shortcut = shortcut; self.openCommandID = openCommandID
    }
    public var notice: String {
        "\(extensionName): \(shortcut.symbolDisplay) is used by \(CommandRegistry.byID[openCommandID]?.title ?? openCommandID), so it is off."
    }
}

@MainActor public protocol SettingsActions: ImportActions {
    func setAsDefaultBrowser() -> String?
    func isDefaultBrowser() -> Bool
    func checkForUpdates()
    func openMoreSettings()
    func revealOpenDataFolder()
    func copyOpenInfoToPasteboard()
    /// Called after irreversible model removal, with the directory captured before deletion.
    func deleteProfileData(profileID: ProfileID, dataDirectoryName: String) async -> String?
    func chooseProfileIcon(profileID: ProfileID, anchor: NSView)
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
    /// The Library hosts this native view without importing OpenSidebar.
    /// Vend a distinct view for each LibraryViewModel: one NSView has one host.
    /// Never share an instance between Library windows or view models. The caller
    /// retains a successful result and may detach/rehost it on section switches.
    /// Return nil for temporary unavailability; the caller retries on later access.
    func makeSpaceManagerView() -> NSView?
    /// Settings ▸ Shortcuts "Learn the Essential Shortcuts": open the Essential Keyboard Shortcuts window
    /// (commandbar-completion §4.5.3, CC-29).
    func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict]
    func openEssentialShortcuts()
}

public extension SettingsActions {
    func chooseProfileIcon(profileID: ProfileID, anchor: NSView) {}
    func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict] { [] }
    func makeSpaceManagerView() -> NSView? { nil }
}
