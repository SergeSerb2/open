import Foundation
import Observation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel
import OpenImport

@MainActor @Observable public final class ImportWizardViewModel {
    public enum Step: String, CaseIterable { case source = "Source", access = "Access", choose = "Choose", review = "Review", consent = "Passwords", progress = "Importing", report = "Report" }
    unowned let root: SettingsViewModel
    private let importActions: any ImportActions
    public let extensions = ImportExtensionsViewModel()
    public var plan: ImportPlan
    public var step: Step = .choose
    public private(set) var counts: [String: Int] = [:]
    public private(set) var probe: ArcProbeResult?
    private var countRequest=UUID()
    public private(set) var spaceMapping: [String] = []
    public private(set) var readable = false
    private var counting=false
    public private(set) var isImporting=false
    public var phaseText = "Importing selected data…"
    public var progress: Double?
    public var browserHasLanded = false
    public var busy:Bool {counting || isImporting || extensions.isInstalling}
    public private(set) var errorText = ""
    public private(set) var outcome: ImportOutcome?
    public private(set) var consentWasDecided = false
    public private(set) var unfinishedSecretsImport: Bool
    /// Settings starts on the source picker; first run and the automation folder path start on Choose.
    public let startedWithSource: Bool
    /// Browsers found on this Mac. Loaded when the picker appears, never at launch.
    public private(set) var sources: [BrowserSource] = []
    public private(set) var sourcesLoaded = false
    public private(set) var appURLs: [String: URL] = [:]
    /// A `BrowserSourceDescriptor.id` ("arc", "chrome", …). Empty until the user picks a pill (capture s5: no preselection).
    public var selectedSourceID: String = ""
    public private(set) var browserCounts: ChromiumProfileCounts?
    /// Firefox and Safari counts (IMF).
    public private(set) var familyCounts: BrowserImportReader.Counts?
    /// What blocks a Firefox or Safari import before the Choose step.
    public enum AccessBlocker: String, Sendable { case fullDiskAccess, quitBrowser }
    public private(set) var accessBlocker: AccessBlocker?
    /// How often the wizard opened System Settings ▸ Full Disk Access (automation reads it; never opened for a synthetic library).
    public private(set) var fullDiskAccessRequests = 0
    private var accessPoll: Task<Void, Never>?
    /// Automation and fixtures point detection at a synthetic `~/Library`.
    nonisolated(unsafe) public static var browserLibraryOverride: URL?
    public init(root: SettingsViewModel, directory: URL? = nil, actions: (any ImportActions)? = nil, startsWithSource: Bool = false) {
        self.root = root; self.importActions = actions ?? root.actions
        startedWithSource = startsWithSource
        if startsWithSource { step = .source }
        unfinishedSecretsImport = self.importActions.hasUnfinishedSecretsImport
        let path = root.defaults.string(forKey: "open.import.lastArcDir")
        plan = ImportPlan(directory: directory ?? path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc"))
    }
    public var directoryDisplayPath: String {
        let path = plan.directory.path
        if path.hasPrefix(root.root.path + "/") { return "Open Data/" + String(path.dropFirst(root.root.path.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    public var canContinue: Bool {
        if !plan.isArc { return readable && !busy && (plan.bookmarks || plan.openTabs || plan.history || plan.searchSettings || plan.passwords || (plan.secretsRequested && canImportBrowserSecrets)) && passwordsReady }
        return readable && !busy && (!plan.providers.isEmpty || plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || (plan.secretsRequested && canImportPasswordsAndCookies)) }
    public var title: String { step == .source ? "Import from another browser" : "Import from " + plan.source.displayName }
    public func choose(directory: URL) async { guard !isImporting else { return }; clearConsent(); plan.source = .arc; selectedSourceID = "arc"; if step == .source { step = .choose }; plan.directory = directory; await refreshCounts() }
    // MARK: Source picker (IMC I-1; IMF adds Firefox and Safari readers)
    public func loadSources() async {
        guard !sourcesLoaded else { return }
        let library = Self.browserLibraryOverride
        let found = await Task.detached(priority: .userInitiated) {
            (library.map { BrowserSourceCatalog(library: $0) } ?? BrowserSourceCatalog()).detect()
        }.value
        // Installed app bundles, for each pill's icon. LaunchServices lookups only; no icon is stored.
        appURLs = Dictionary(uniqueKeysWithValues: found.compactMap { source in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.descriptor.bundleID).map { (source.id, $0) }
        })
        sources = found; sourcesLoaded = true
    }
    /// Capture s5: only detected browsers appear; there is no "not installed" state. A browser folder without an
    /// importable profile is hidden too (Arc hid an installed Chrome). Arc itself has no profile list.
    /// Families without readers yet stay visible as "Coming soon" (lead ruling 01:55).
    public var visibleSources: [BrowserSource] { sources.filter { $0.family == .arc || !$0.isSupported || $0.accessDenied || !$0.profiles.isEmpty } }
    public var selectedSource: BrowserSource? { sources.first { $0.id == selectedSourceID } }
    public var selectedProfileID: String? { if case .browser(_, let profile) = plan.source { return profile.id }; return nil }
    /// Safari stays selectable without Full Disk Access: Arc lists it and asks for access after Next (C-report-s5 §1).
    public func canSelect(_ source: BrowserSource) -> Bool { source.isSupported && (!source.accessDenied || source.family == .safari) && (source.family == .arc || !source.profiles.isEmpty) }
    public func sourceStatus(_ source: BrowserSource) -> String? {
        if source.family == .arc { return nil }
        if !source.isSupported { return "Coming soon" }
        if source.family == .safari { return nil }
        if source.accessDenied { return "No access" }
        if source.profiles.isEmpty { return "No data" }
        return nil
    }
    public var canContinueFromSource: Bool { !busy && selectedSource.map(canSelect) == true }
    public func continueFromSource() async {
        guard step == .source, canContinueFromSource else { return }
        clearConsent(); outcome = nil; errorText = ""
        if let source = selectedSource, source.family == .arc {
            plan.source = .arc; plan.directory = source.dataRoot; step = .choose; await refreshCounts(); return
        }
        guard let source = selectedSource, let profile = source.profiles.first else { return }
        plan.source = .browser(source, profile: profile)
        plan.bookmarks = true; plan.openTabs = source.family == .chromium; plan.history = true; plan.searchSettings = source.family == .chromium; plan.skipSecrets()
        plan.passwords = false; plan.safariFiles = SafariImportFiles(); plan.primaryPassword = ""
        familyCounts = nil
        await enterChooseOrAccess()
    }

    // MARK: Access (IMF): Safari Full Disk Access, a running Firefox

    private func currentBlocker() -> AccessBlocker? {
        guard case .browser(let source, let profile) = plan.source else { return nil }
        switch source.family {
        case .safari:
            if plan.safariFiles.exportArchive == nil, SafariAccess.check(safariDirectory: profile.directory) == .denied { return .fullDiskAccess }
        case .firefox:
            // Arc: "Quit Firefox to continue importing" (browser-import.md §2 item 6).
            let ids = BrowserSourceCatalog.runningBundleIDs(for: source.descriptor)
            if FirefoxProfileCatalog.isLocked(profile.directory) || NSWorkspace.shared.runningApplications.contains(where: { ids.contains($0.bundleIdentifier ?? "") }) {
                return .quitBrowser
            }
        case .arc, .chromium: break
        }
        return nil
    }

    private func enterChooseOrAccess() async {
        accessPoll?.cancel(); accessPoll = nil
        guard let blocker = currentBlocker() else { accessBlocker = nil; step = .choose; await refreshCounts(); return }
        accessBlocker = blocker; step = .access
        // Arc opens the Full Disk Access pane at once on Next (C-report-s5 §1, u3 00:55:08).
        if blocker == .fullDiskAccess { openFullDiskAccessSettings() }
        // Arc polls for the grant (`FullDiskAccessTimerID`); the same poll notices a quit browser.
        accessPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.step == .access else { return }
                if self.currentBlocker() == nil { await self.checkAccessAgain(); return }
            }
        }
    }

    public func checkAccessAgain() async {
        guard step == .access else { return }
        await enterChooseOrAccess()
    }

    public func openFullDiskAccessSettings() {
        fullDiskAccessRequests += 1
        // A synthetic library (e2e) never opens System Settings.
        if Self.browserLibraryOverride == nil { NSWorkspace.shared.open(SafariAccess.settingsURL) }
    }

    public var accessTitle: String {
        switch accessBlocker {
        case .fullDiskAccess: "Open needs Full Disk Access to import from Safari."
        case .quitBrowser: "Quit \(plan.source.displayName) to continue importing."
        case nil: ""
        }
    }

    public var accessBody: String {
        switch accessBlocker {
        case .fullDiskAccess: "In System Settings, turn on Open under Privacy & Security ▸ Full Disk Access. You can turn it off again when the import is finished. Open continues by itself when access is on. You can also import a file that you exported in Safari (File ▸ Export Browsing Data)."
        case .quitBrowser: "\(plan.source.displayName) keeps its files locked while it runs. Open continues by itself when \(plan.source.displayName) has quit."
        case nil: ""
        }
    }

    /// Safari ▸ File ▸ Export Browsing Data: a ZIP with bookmarks, history and passwords. No Full Disk Access needed.
    public func useSafariExport(_ url: URL) async {
        guard !busy, case .browser(let source, _) = plan.source, source.family == .safari else { return }
        guard (try? SafariExportReader(url: url)) != nil else { errorText = "The file you chose is not a Safari export. In Safari, choose File ▸ Export Browsing Data."; return }
        errorText = ""
        plan.safariFiles.exportArchive = url
        await enterChooseOrAccess()
    }

    /// A Passwords.csv exported from Safari or the Passwords app.
    public func usePasswordsFile(_ url: URL) async {
        guard !busy, case .browser(let source, _) = plan.source, source.family == .safari else { return }
        guard let data = try? Data(contentsOf: url), var read = try? PasswordsCSVReader.read(data) else {
            errorText = "The file you chose doesn't look like a passwords file. Export it from Safari or the Passwords app (File ▸ Export All Passwords)."
            return
        }
        for i in read.logins.indices { read.logins[i].zeroSecrets() }
        errorText = ""
        plan.safariFiles.passwordsCSV = url
        plan.passwords = canImportBrowserPasswords
        await refreshCounts()
    }

    public var canImportBrowserPasswords: Bool { importActions.canImportBrowserPasswords }
    public var browserFamily: BrowserFamily? { if case .browser(let source, _) = plan.source { return source.family }; return nil }
    public var needsPrimaryPassword: Bool { browserFamily == .firefox && familyCounts?.needsPrimaryPassword == true }
    /// Passwords need a source: Firefox logins (and the Primary Password when set) or a Safari file with passwords.
    public var passwordsReady: Bool {
        guard plan.passwords else { return true }
        guard canImportBrowserPasswords, (familyCounts?.passwords ?? 0) > 0 else { return false }
        return !needsPrimaryPassword || !plan.primaryPassword.isEmpty
    }
    public func selectProfile(_ id: String) async {
        guard !busy, case .browser(let source, let current) = plan.source, current.id != id,
              let profile = source.profiles.first(where: { $0.id == id }) else { return }
        plan.source = .browser(source, profile: profile)
        plan.primaryPassword = ""
        await enterChooseOrAccess()
    }
    /// Review rows: a count for data, the engine name for search.
    public func reviewValue(_ category: String) -> String {
        if category == "Search settings" { return countLabel(category) }
        return counts[category].map { $0.formatted() } ?? countLabel(category)
    }
    public func backToSource() { guard startedWithSource, !busy else { return }; accessPoll?.cancel(); accessPoll = nil; accessBlocker = nil; errorText = ""; step = .source }
    /// GUESS — capture pending (F3 §3 item 3): the destination copy.
    public var destinationText: String { "Bookmarks go to a pinned folder, “\(BrowserBookmarksImport.folderTitle(browserName: plan.source.displayName))”, in your current Space." }
    private func refreshFamilyCounts(_ family: BrowserFamily, _ profile: BrowserSourceProfile) async {
        let request = UUID(); countRequest = request
        readable = false; counting = true; errorText = ""; probe = nil; browserCounts = nil; familyCounts = nil; counts = [:]; spaceMapping = []
        let source = plan.source, reader = BrowserImportReader(family: family, profile: profile, safari: plan.safariFiles)
        let result = await Task.detached(priority: .utility) { reader.counts() }.value
        guard request == countRequest, source == plan.source, reader.safari == plan.safariFiles else { return }
        familyCounts = result
        var values: [String: Int] = [:]
        if let count = result.bookmarks { values["Bookmarks"] = count }
        if let count = result.historyVisits { values["History"] = count }
        if let count = result.passwords { values["Passwords"] = count }
        if let count = result.openTabs { values["Open tabs"] = count }
        plan.openTabs = (result.openTabs ?? 0) > 0
        counts = values
        if (result.passwords ?? 0) == 0 || !canImportBrowserPasswords { plan.passwords = false }
        else if family == .firefox && !plan.passwords && plan.primaryPassword.isEmpty && !result.needsPrimaryPassword { plan.passwords = true }
        readable = !values.isEmpty
        counting = false
        untickNotFound()
        if !readable { errorText = "No readable import data found in this \(plan.source.displayName) profile." }
    }
    private func refreshBrowserCounts() async {
        guard case .browser(let browser, let profile) = plan.source else { return }
        if browser.family != .chromium { await refreshFamilyCounts(browser.family, profile); return }
        let request = UUID(); countRequest = request
        readable = false; counting = true; errorText = ""; probe = nil; browserCounts = nil; counts = [:]; spaceMapping = []
        let source = plan.source
        let result = await Task.detached(priority: .utility) { ChromiumProfileReader(directory: profile.directory).counts() }.value
        guard request == countRequest, source == plan.source else { return }
        browserCounts = result
        var values: [String: Int] = [:]
        if let count = result.bookmarks { values["Bookmarks"] = count }
        if let count = result.historyVisits { values["History"] = count }
        if let count = result.openTabs { values["Open tabs"] = count }
        if let secrets = result.secrets {
            values["Passwords"] = secrets.loginRows; values["Cookies"] = secrets.cookieRows
            values["Cards"] = secrets.cardRows; values["Addresses"] = secrets.addressRows
            values["Passwords and cookies"] = secrets.loginRows + secrets.cookieRows + secrets.cardRows + secrets.addressRows
        }
        counts = values
        readable = result.bookmarks != nil || result.openTabs != nil || result.historyVisits != nil || result.searchEngine != nil || result.secrets != nil
        counting = false
        untickNotFound()
        if !readable { errorText = "No readable import data found in this \(plan.source.displayName) profile." }
    }
    public func refreshCounts() async {
        if !plan.isArc { await refreshBrowserCounts(); return }
        let request=UUID();countRequest=request
        readable=false;counting=true;errorText="";probe=nil
        let directory=plan.directory
        let result=await ArcProbe(arcDirectory:directory).run()
        guard !Task.isCancelled,request == countRequest,directory == plan.directory else {if request == countRequest {counting=false};return}
        let labels=await Task.detached(priority:.utility) {(try? ArcImporter(arcDirectory:directory).spaceMappingLabels()) ?? []}.value
        guard !Task.isCancelled,request == countRequest,directory == plan.directory else {if request == countRequest {counting=false};return}
        probe=result;counts=result.settingsCounts;spaceMapping=labels
        await refreshProviderCounts()
        readable=result.sidebarFound && result.spaces != nil
        counting=false
        if !readable {errorText="No readable import data found at \(directoryDisplayPath)."}
    }
    public func countLabel(_ category:String)->String {
        if let family = browserFamily, family != .chromium {
            guard let familyCounts else { return counting ? "Counting…" : "Not found" }
            if category == "Passwords", family == .safari, familyCounts.passwords == nil, !familyCounts.unreadable.contains("Passwords") { return "Choose a passwords file" }
            if category == "Passwords", !canImportBrowserPasswords { return "Not available" }
            return counts[category].map { "Found: \($0.formatted())" } ?? (familyCounts.unreadable.contains(category) ? "Could not be read" : "Not found")
        }
        if !plan.isArc {
            guard let browserCounts else { return counting ? "Counting…" : "Not found" }
            if category == "Search settings" { return browserCounts.searchEngine ?? "Browser default" }
            return counts[category].map { "Found: \($0.formatted())" } ?? (browserCounts.unreadable.contains(category) ? "Could not be read" : "Not found")
        }
        if let count=counts[category] {let partial=category == "History" ? probe?.historyPartial == true:category == "Passwords and cookies" && probe?.savedItemsPartial == true;return "Found: \(count.formatted())"+(partial ? " (partial)":"")}
        guard let probe else {return "Counting…"}
        let found=category == "History" ? probe.historyFound:category == "Passwords and cookies" ? probe.secretsFound:category == "Archive" ? probe.archiveFound:probe.sidebarFound
        return found ? "Could not be read":"Not found"
    }
    /// A data type with "Not found" is unticked and its toggle disabled, like Passwords without a source, so the
    /// Report never flags data that was never there (hand check, IMF 20:15). It is ticked again when a later
    /// profile or file has it.
    public func isNotFound(_ category: String) -> Bool { !counting && countLabel(category) == "Not found" }
    private var untickedNotFound: Set<String> = []
    private func untickNotFound() {
        let keys: [(String, WritableKeyPath<ImportPlan, Bool>)] = [("Bookmarks", \.bookmarks), ("History", \.history), ("Open tabs", \.openTabs)]
        for (category, key) in keys {
            if isNotFound(category) {
                if plan[keyPath: key] { plan[keyPath: key] = false; untickedNotFound.insert(category) }
            } else if untickedNotFound.remove(category) != nil { plan[keyPath: key] = true }
        }
    }
    public static let reportCategories=["Spaces","Pinned and Today tabs","Favorites","Folders","Archive","History","Search settings","Boosts","Passwords and cookies"]
    public static let browserReportCategories=["Bookmarks","Open tabs","History","Search settings"]
    public static let otherBrowserReportCategories=["Bookmarks","History","Passwords"]
    public var browserCategories: [String] {
        switch browserFamily {
        case .firefox: Self.otherBrowserReportCategories + ["Open tabs"]
        case .safari: Self.otherBrowserReportCategories
        default: Self.browserReportCategories
        }
    }
    // MARK: Extra Arc data types (ArcImportProviders; EZ adds Easels)
    public private(set) var providerCounts: [String: Int] = [:]
    public var providers: [any ArcImportDataProvider] { ArcImportProviders.all }
    public func refreshProviderCounts() async {
        var values: [String: Int] = [:]
        for provider in providers {
            if let count = await provider.count(arcDirectory: plan.directory, file: plan.providerFiles[provider.id]) { values[provider.id] = count }
        }
        providerCounts = values
    }
    public func setProvider(_ id: String, selected: Bool) { if selected { plan.providers.insert(id) } else { plan.providers.remove(id) } }
    public func chooseProviderFile(_ id: String, url: URL?) async {
        guard !isImporting, ArcImportProviders.provider(id: id) != nil else { return }
        plan.providerFiles[id] = url
        if url != nil { plan.providers.insert(id) }
        await refreshProviderCounts()
    }
    public func providerLabel(_ provider: any ArcImportDataProvider) -> String {
        let file = plan.providerFiles[provider.id].map { " · " + $0.lastPathComponent } ?? ""
        return (providerCounts[provider.id].map { "Found: \($0.formatted())" } ?? "Not found") + file
    }
    public var displayedReportCategories: [String] { if !plan.isArc { return browserCategories }; return Self.reportCategories.filter { $0 != "Passwords and cookies" || outcome?.secretsReportLines.isEmpty != false } + providers.filter { plan.providers.contains($0.id) }.map(\.title) }
    public var secretsReportLines: [String] { outcome?.secretsReportLines ?? [] }
    public var unfinishedSecretsImportMessage: String? {
        unfinishedSecretsImport && !secretsReportLines.contains(ArcSecretsImportReport.unfinishedMessage) ? ArcSecretsImportReport.unfinishedMessage : nil
    }
    public var reportSummary:String {
        if !plan.isArc {
            guard outcome?.failures["Bookmarks"] == nil, plan.bookmarks else { return "Import finished." }
            return "Imported "+ImportCountCopy.phrase(reportCount("Bookmarks"),singular:"bookmark",plural:"bookmarks")+"."
        }
        var parts:[String]=[]
        if outcome?.failures["Spaces"] == nil {parts.append(ImportCountCopy.phrase(reportCount("Spaces"),singular:"Space",plural:"Spaces"))}
        if ["Imported tabs","Pinned and Today tabs","Favorites"].allSatisfy({outcome?.failures[$0] == nil}) {parts.append(ImportCountCopy.phrase(reportCount("Imported tabs"),singular:"tab",plural:"tabs"))}
        return parts.isEmpty ? "Import finished.":"Imported "+parts.joined(separator:" and ")+"."
    }
    public func reportCount(_ category:String)->Int {outcome?.importedCount(category) ?? 0}
    public func reportValue(_ category:String)->String {outcome?.failures[category] ?? reportCount(category).formatted()}
    public func reportUndoFailure() {errorText="Open could not save your data. Try again."}
    public var reportSkipped:String {
        let result=outcome?.counts ?? [:]
        var parts:[String]=[]
        for (key,singular,plural) in [("Skipped easels","Easel","Easels"),("Skipped notes","Note","Notes"),("Skipped unknown","unsupported item","unsupported items")] {
            let count=result[key,default:0];if count > 0 {parts.append(ImportCountCopy.phrase(count,singular:singular,plural:plural))}
        }
        return parts.isEmpty ? "":"Skipped: " + parts.joined(separator:", ")
    }
    public var hasImportedData:Bool {outcome?.didImportAnything ?? false}
    public var passwordsWereNotImported:Bool {outcome?.secretsReportLines.isEmpty != false}
    public var canImportPasswordsAndCookies: Bool { importActions.canImportPasswordsAndCookies }
    public var passwordsCopy: PasswordsImportCopy {
        if !plan.isArc { return .init(canImport: canImportBrowserSecrets, savedItems: counts["Passwords and cookies"], source: plan.source.displayName) }
        return .init(canImport: canImportPasswordsAndCookies, savedItems: probe == nil ? nil : (probe?.secretsFound == false ? 0 : counts["Passwords and cookies"]))
    }
    /// I-2: Chromium profiles with their own "Safe Storage" Keychain item. Opera keeps its profile at the
    /// data root, which the secrets reader does not walk yet.
    public var canImportBrowserSecrets: Bool {
        guard canImportPasswordsAndCookies, case .browser(let source, _) = plan.source else { return false }
        return source.family == .chromium && !source.descriptor.profileAtRoot && source.descriptor.keychainItem != nil
    }
    public func review() { guard step == .choose, canContinue else { return }; step = .review }
    public func beginImport() async {
        guard step == .review, canContinue else { return }
        clearConsent()
        await requestImport()
    }
    /// First run can start while its estimate is still pending; the shared action reports read errors.
    public func beginImport(plan: ImportPlan) async {
        if !plan.isArc {
            // First run from another browser (I-5): no secrets here; Settings offers them later.
            guard !isImporting, plan.bookmarks || plan.openTabs || plan.history || plan.searchSettings else { return }
            self.plan = plan; self.plan.skipSecrets(); consentWasDecided = false; outcome = nil; errorText = ""; step = .review
            await requestImport(); return
        }
        guard !isImporting, plan.isArc, plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || (plan.secretsRequested && canImportPasswordsAndCookies) else { return }
        self.plan=plan; if !canImportPasswordsAndCookies {self.plan.skipSecrets()}; consentWasDecided=false; outcome=nil; errorText=""; step = .review
        await requestImport()
    }
    private func requestImport() async {
        if plan.secretsRequested && canImportPasswordsAndCookies && !consentWasDecided { step = .consent; return }
        await execute()
    }
    public func allowAndImportSecrets() async { guard importActions.canImportPasswordsAndCookies, step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.consentToSecrets(); await execute() }
    public func skipSecrets() async { guard step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.skipSecrets(); await execute() }
    private func execute() async {
        isImporting = true; step = .progress
        let result = await importActions.runImport(plan: plan)
        plan.primaryPassword = ""
        outcome = result; errorText = result.errorText ?? ""; isImporting = false; step = .report
        extensions.reset(candidates: result.extensions, profileCount: result.extensionProfileCount)
        unfinishedSecretsImport = importActions.hasUnfinishedSecretsImport
        root.profiles.refresh(); root.refreshLinks()
    }
    private func clearConsent() {
        let requested = plan.secretsRequested
        plan.skipSecrets(); plan.secretsRequested = requested
        consentWasDecided = false
    }
    public func retry() { guard !busy else { return }; clearConsent(); outcome = nil; step = .choose }
    public func finish(openLibrary: Bool = false) { guard !busy else { return }; accessPoll?.cancel(); accessPoll = nil; plan.primaryPassword = ""; if plan.isArc && outcome?.errorText == nil && outcome != nil { root.set(plan.directory.path, for: "open.import.lastArcDir") }; clearConsent(); root.showsImport = false; if openLibrary { root.actions.openLibrary() } }
    public func installExtensions() async { guard step == .report else { return }; await extensions.install(using: importActions) }
}
public struct ImportWizard: View {
    @State private var model: ImportWizardViewModel
    public init(root: SettingsViewModel) { _model = State(initialValue: root.importWizard) }
    public init(model: ImportWizardViewModel) { _model = State(initialValue: model) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.step != .source {
            Text(model.title).font(.title2)
            HStack { ForEach(ImportWizardViewModel.Step.allCases.filter { $0 != .progress && ($0 != .source || model.startedWithSource) && ($0 != .access || model.step == .access) && ($0 != .consent || model.plan.secretsRequested || model.step == .consent) }, id: \.self) { step in Text(step.rawValue).foregroundStyle(model.step == step ? .primary : .secondary); if step != .report { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } } }
            Divider()
            }
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                case .source:
                    ImportSourcePicker(model: model)
                case .access:
                    HStack(alignment: .top, spacing: 14) {
                        // The installed app's own icon (NSWorkspace), never a drawing (lead 03:30).
                        BrowserIcon(appURL: model.appURLs[model.selectedSourceID]).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.accessTitle).font(.headline)
                            Text(model.accessBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting…").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                case .choose where !model.plan.isArc:
                    if let source = model.selectedSource, source.profiles.count > 1 {
                        Picker("Profile", selection: Binding(get: { model.selectedProfileID ?? "" }, set: { id in Task { await model.selectProfile(id) } })) {
                            ForEach(source.profiles) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 320).disabled(model.busy)
                    }
                    browserOption("Bookmarks", \.bookmarks)
                    if model.browserFamily == .chromium { browserOption("Open tabs", \.openTabs) }
                    browserOption("History", \.history)
                    if model.browserFamily == .chromium {
                        browserOption("Search settings", \.searchSettings)
                        browserOption("Passwords and cookies", \.secretsRequested).disabled(!model.canImportBrowserSecrets)
                    } else { browserOption("Passwords", \.passwords).disabled(!model.canImportBrowserPasswords || (model.familyCounts?.passwords ?? 0) == 0) }
                    if model.browserFamily == .firefox { browserOption("Open tabs", \.openTabs).disabled((model.familyCounts?.openTabs ?? 0) == 0) }
                    if model.needsPrimaryPassword && model.plan.passwords {
                        SecureField("Firefox Primary Password", text: Binding(get: { model.plan.primaryPassword }, set: { model.plan.primaryPassword = $0 }))
                            .frame(maxWidth: 320).accessibilityIdentifier("import-primary-password")
                        Text("Your Firefox passwords are protected by a Primary Password. Open uses it once to read them and does not keep it.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.browserFamily == .safari { SafariFilesRow(model: model) }
                    Text(model.destinationText).font(.caption).foregroundStyle(.secondary)
                case .review where !model.plan.isArc:
                    VStack(spacing: 0) {
                        if model.plan.bookmarks { reviewRow("bookmark", "Bookmarks", model.reviewValue("Bookmarks")) }
                        if model.plan.openTabs { reviewRow("square.on.square", "Open tabs", model.reviewValue("Open tabs")) }
                        if model.plan.history { reviewRow("clock.arrow.circlepath", "History", model.reviewValue("History")) }
                        if model.plan.searchSettings { reviewRow("magnifyingglass", "Search engine", model.reviewValue("Search settings")) }
                        if model.plan.passwords { reviewRow("key", "Passwords", model.reviewValue("Passwords")) }
                        if model.plan.secretsRequested && model.canImportBrowserSecrets {
                            reviewRow("key", "Passwords", model.reviewValue("Passwords"))
                            reviewRow("checkmark.shield", "Cookies", model.reviewValue("Cookies"))
                            reviewRow("creditcard", "Cards", model.reviewValue("Cards"))
                            reviewRow("person.text.rectangle", "Addresses", model.reviewValue("Addresses"))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    if model.plan.bookmarks { Text(model.destinationText).font(.caption).foregroundStyle(.secondary) }
                case .choose:
                    if let message = model.unfinishedSecretsImportMessage { Text(message).foregroundStyle(.secondary) }
                    HStack { Text("From: " + model.directoryDisplayPath).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button("Choose Folder…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let directory = panel.url { Task { await model.choose(directory: directory) } } } }
                    option("Spaces", \.spaces); option("Pinned and Today tabs", \.tabs); option("Favorites", \.favorites); option("Folders", \.folders); option("Archive", \.archive); option("History", \.history); option("Search settings", \.searchSettings); option("Passwords and cookies", \.secretsRequested).disabled(!model.canImportPasswordsAndCookies)
                    Text("Imports your search engine choice only.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.providers, id: \.id) { provider in providerRow(provider) }
                case .review:
                    ForEach(model.spaceMapping, id: \.self) { Text($0) }
                    Text("Found: \(ImportCountCopy.phrase(model.counts["Profiles",default:0],singular:"Profile",plural:"Profiles")) · \(ImportCountCopy.phrase(model.counts["Routing rules",default:0],singular:"routing rule",plural:"routing rules"))")
                    Text("Skipped: \(ImportCountCopy.phrase(model.counts["Skipped easels",default:0],singular:"Easel",plural:"Easels")), \(ImportCountCopy.phrase(model.counts["Skipped notes",default:0],singular:"Note",plural:"Notes")), \(ImportCountCopy.phrase(model.counts["Skipped unknown",default:0],singular:"unknown item",plural:"unknown items")).")
                    ForEach(model.providers.filter { model.plan.providers.contains($0.id) }, id: \.id) { provider in
                        Label("\(provider.title): \(model.providerLabel(provider))", systemImage: provider.symbol)
                    }
                    if model.providers.isEmpty { Text("Easels and Notes do not import. Open has no Easels or Notes.").foregroundStyle(.secondary) }
                case .consent:
                    let copy=model.passwordsCopy
                    Text(copy.title).font(.headline)
                    Text(copy.body)
                case .progress:
                    if let progress = model.progress { ProgressView(value: progress) } else { ProgressView() }
                    Text(model.phaseText)
                    if model.browserHasLanded && model.phaseText == "Importing your history…" { Text("Your browser is ready. History is still importing in the background.").foregroundStyle(.secondary) }
                case .report:
                    if model.outcome?.errorText == nil || model.hasImportedData {
                        Text(model.reportSummary).font(.headline)
                        ForEach(model.displayedReportCategories,id:\.self) {name in HStack {Text(ImportCountCopy.displayCategory(name));Spacer();Text(model.reportValue(name)).monospacedDigit().foregroundStyle(model.outcome?.failures[name] == nil ? Color.primary : Color.red)}}
                        ForEach(model.secretsReportLines, id: \.self) { Text($0).monospacedDigit() }
                        if !model.reportSkipped.isEmpty {Text(model.reportSkipped).foregroundStyle(.secondary)}
                    }
                    if (model.plan.isArc || model.plan.secretsRequested) && model.passwordsWereNotImported {Text("Passwords and cookies were not imported.").foregroundStyle(.secondary)}
                    if let failure = model.outcome?.failures["Passwords and cookies"] { Text(failure).foregroundStyle(.secondary) }
                    if let message = model.unfinishedSecretsImportMessage { Text(message).foregroundStyle(.secondary) }
                    ImportExtensionsSection(model: model.extensions) { Task { await model.installExtensions() } }
                }
                SettingsError(text: model.errorText)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            if model.busy { ProgressView() }
            HStack {
                if model.step != .report && model.step != .source { Button("Cancel") { model.finish() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
                Spacer()
                switch model.step {
                case .access:
                    Button("Back") { model.backToSource() }
                    if model.accessBlocker == .fullDiskAccess {
                        Button("Use Exported File…") { if let url = SafariFilesRow.pick(types: ["zip"]) { Task { await model.useSafariExport(url) } } }
                        Button("Open System Settings") { model.openFullDiskAccessSettings() }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true))
                    }
                case .source:
                    Button("Maybe Later") { model.finish() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                    Button("Next") { Task { await model.continueFromSource() } }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true)).disabled(!model.canContinueFromSource)
                case .choose:
                    if model.startedWithSource { Button("Back") { model.backToSource() }.disabled(model.busy) }
                    Button("Next") { model.review() }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true)).disabled(!model.canContinue)
                case .review: Button("Back") { model.step = .choose }; Button("Import") { Task { await model.beginImport() } }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true)).disabled(!model.canContinue)
                case .consent:
                    if model.canImportPasswordsAndCookies {
                        Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }
                        Button(PasswordsImportCopy.allowButton) { Task { await model.allowAndImportSecrets() } }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true))
                    } else { Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true)) }
                case .progress: EmptyView()
                case .report: if model.outcome?.errorText != nil { Button("Try again") { model.retry() } } else { Button("Open Library") { model.finish(openLibrary: true) } };Button("Done") { model.finish() }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true))
                }
            }.disabled(model.extensions.isInstalling)
        }.padding(24).frame(width: 640, height: 520).interactiveDismissDisabled(model.busy).settingsSheet()
        .task { if model.step == .source { await model.loadSources() } else if model.step != .access && !model.readable { await model.refreshCounts() } }
    }
    private func reviewRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 36)
    }
    private func browserOption(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(ImportCountCopy.displayCategory(name), isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })).disabled(model.isNotFound(name)); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
    private func providerRow(_ provider: any ArcImportDataProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(provider.title, isOn: Binding(get: { model.plan.providers.contains(provider.id) }, set: { model.setProvider(provider.id, selected: $0) }))
                if !provider.fileTypes.isEmpty {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = provider.fileTypes.contains(.folder)
                        let files = provider.fileTypes.filter { $0 != .folder }
                        panel.canChooseFiles = !files.isEmpty
                        if !files.isEmpty { panel.allowedContentTypes = files }
                        if panel.runModal() == .OK, let url = panel.url { Task { await model.chooseProviderFile(provider.id, url: url) } }
                    }.disabled(model.busy)
                }
                Spacer(); Text(model.providerLabel(provider)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Text(provider.help).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
        }
    }
    private func option(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(ImportCountCopy.displayCategory(name), isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
}


/// Safari's file choices on the Choose step: the export archive (instead of live files) and a passwords CSV.
/// Arc: "Upload your Passwords.csv file" (browser-import.md §2, Safari passwords). Open uses a plain file picker
/// here; the drop zone is a GUESS until capture (F3 §3 item 5).
struct SafariFilesRow: View {
    let model: ImportWizardViewModel
    static func pick(types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From: " + (model.plan.safariFiles.exportArchive?.lastPathComponent ?? "Safari on this Mac")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Exported File…") { if let url = Self.pick(types: ["zip"]) { Task { await model.useSafariExport(url) } } }.disabled(model.busy)
                Button("Choose Passwords File…") { if let url = Self.pick(types: ["csv"]) { Task { await model.usePasswordsFile(url) } } }
                    .disabled(model.busy || !model.canImportBrowserPasswords)
            }
            Text("Safari passwords come from a file. In Safari or the Passwords app, choose File ▸ Export All Passwords. Delete the file when the import is finished.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
