import Foundation
import AppKit
import OpenModel
import OpenCommands
import OpenImport

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
    public var boosts = true
    /// Arc keeps its folder-based path. Other browsers import bookmarks, history and the search engine (IMC I-1).
    public var source: ImportSource = .arc
    public var bookmarks = true
    /// I-6: the source browser's open tabs from its last session.
    public var openTabs = true
    /// Firefox and Safari (IMF): saved passwords. The toggle on the Choose step is the user's choice;
    /// Firefox has no Keychain prompt and Safari passwords come from a file the user picked.
    public var passwords = false
    public var safariFiles = SafariImportFiles()
    /// Typed by the user for a Firefox Primary Password. Used once by the reader, cleared after the run, never stored.
    public var primaryPassword = ""
    public private(set) var secretsConsented = false
    public init(directory: URL) { self.directory = directory }
    public var isArc: Bool { source == .arc }
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
    public var secretsReportLines: [String]
    public var extensions: [ImportExtensionCandidate]
    public var extensionProfileCount: Int
    public init(counts: [String: Int] = [:], errorText: String? = nil, failures: [String: String] = [:], extensions: [ImportExtensionCandidate] = [], extensionProfileCount: Int = 0, secretsReportLines: [String] = []) {
        self.counts = counts; self.errorText = errorText; self.failures = failures
        self.extensions = extensions; self.extensionProfileCount = extensionProfileCount
        self.secretsReportLines = secretsReportLines
    }
}

/// One import action and capability shared by Settings and first run.
/// Canonical adapter keys. Legacy display keys remain accepted at the one outcome boundary.
public enum ImportOutcomeKeys {
    public static let spaces="Imported Spaces",tabs="Imported items",archive="Imported Archive",history="Imported History"
    public static let imported=[spaces,tabs,archive,history,"Spaces","Imported tabs","Archive","History","Favorites","Folders","Search settings","Boosts","Passwords and cookies","Passwords","Cookies","Addresses","Cards"]
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
    /// Firefox and Safari passwords: the engine can write logins to this Profile.
    var canImportBrowserPasswords: Bool { get }
    var hasUnfinishedSecretsImport: Bool { get }
    func runImport(plan: ImportPlan) async -> ImportOutcome
    func installImportedExtension(_ candidate: ImportExtensionCandidate) async -> ImportExtensionInstallResult
}
public extension ImportActions {
    var canImportPasswordsAndCookies: Bool { false }
    var canImportBrowserPasswords: Bool { false }
    var hasUnfinishedSecretsImport: Bool { false }
    func installImportedExtension(_ candidate: ImportExtensionCandidate) async -> ImportExtensionInstallResult { .failed("Extension installation is unavailable.") }
}

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
    func hasEnabledBlockerExtension(profileID: ProfileID) -> Bool
    func setTabSleepMode(_ mode: TabSleepMode)
    func setApplicationIcon(id: String)
    func setWebsiteAppearance(_ value: String)
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
    func setWebsiteAppearance(_ value: String) {}
    func hasEnabledBlockerExtension(profileID: ProfileID) -> Bool { false }
    func chooseProfileIcon(profileID: ProfileID, anchor: NSView) {}
    func extensionShortcutConflicts(profileID: ProfileID) -> [ExtensionShortcutConflict] { [] }
    func makeSpaceManagerView() -> NSView? { nil }
}
