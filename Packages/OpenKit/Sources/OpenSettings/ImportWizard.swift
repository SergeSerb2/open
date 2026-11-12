import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenImport

@MainActor @Observable public final class ImportWizardViewModel {
    public enum Step: String, CaseIterable { case source = "Source", choose = "Choose", review = "Review", consent = "Passwords", progress = "Importing", report = "Report" }
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
        if !plan.isArc { return readable && !busy && (plan.bookmarks || plan.openTabs || plan.history || plan.searchSettings || (plan.secretsRequested && canImportBrowserSecrets)) }
        return readable && !busy && (plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || (plan.secretsRequested && canImportPasswordsAndCookies)) }
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
    public func canSelect(_ source: BrowserSource) -> Bool { source.isSupported && !source.accessDenied && (source.family == .arc || !source.profiles.isEmpty) }
    public func sourceStatus(_ source: BrowserSource) -> String? {
        if source.family == .arc { return nil }
        if !source.isSupported { return "Coming soon" }
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
        plan.bookmarks = true; plan.openTabs = true; plan.history = true; plan.searchSettings = true; plan.skipSecrets()
        step = .choose
        await refreshCounts()
    }
    public func selectProfile(_ id: String) async {
        guard !busy, case .browser(let source, let current) = plan.source, current.id != id,
              let profile = source.profiles.first(where: { $0.id == id }) else { return }
        plan.source = .browser(source, profile: profile)
        await refreshCounts()
    }
    /// Review rows: a count for data, the engine name for search.
    public func reviewValue(_ category: String) -> String {
        if category == "Search settings" { return countLabel(category) }
        return counts[category].map { $0.formatted() } ?? countLabel(category)
    }
    public func backToSource() { guard startedWithSource, !busy else { return }; errorText = ""; step = .source }
    /// GUESS — capture pending (F3 §3 item 3): the destination copy.
    public var destinationText: String { "Bookmarks go to a pinned folder, “\(BrowserBookmarksImport.folderTitle(browserName: plan.source.displayName))”, in your current Space." }
    private func refreshBrowserCounts() async {
        guard case .browser(_, let profile) = plan.source else { return }
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
        readable=result.sidebarFound && result.spaces != nil
        counting=false
        if !readable {errorText="No readable import data found at \(directoryDisplayPath)."}
    }
    public func countLabel(_ category:String)->String {
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
    public static let reportCategories=["Spaces","Pinned and Today tabs","Favorites","Folders","Archive","History","Search settings","Boosts","Passwords and cookies"]
    public static let browserReportCategories=["Bookmarks","Open tabs","History","Search settings"]
    public var displayedReportCategories: [String] { if !plan.isArc { return Self.browserReportCategories }; return Self.reportCategories.filter { $0 != "Passwords and cookies" || outcome?.secretsReportLines.isEmpty != false } }
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
    public func finish(openLibrary: Bool = false) { guard !busy else { return }; if plan.isArc && outcome?.errorText == nil && outcome != nil { root.set(plan.directory.path, for: "open.import.lastArcDir") }; clearConsent(); root.showsImport = false; if openLibrary { root.actions.openLibrary() } }
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
            HStack { ForEach(ImportWizardViewModel.Step.allCases.filter { $0 != .progress && ($0 != .source || model.startedWithSource) && ($0 != .consent || model.plan.secretsRequested || model.step == .consent) }, id: \.self) { step in Text(step.rawValue).foregroundStyle(model.step == step ? .primary : .secondary); if step != .report { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } } }
            Divider()
            }
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                case .source:
                    ImportSourcePicker(model: model)
                case .choose where !model.plan.isArc:
                    if let source = model.selectedSource, source.profiles.count > 1 {
                        Picker("Profile", selection: Binding(get: { model.selectedProfileID ?? "" }, set: { id in Task { await model.selectProfile(id) } })) {
                            ForEach(source.profiles) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 320).disabled(model.busy)
                    }
                    browserOption("Bookmarks", \.bookmarks); browserOption("Open tabs", \.openTabs); browserOption("History", \.history); browserOption("Search settings", \.searchSettings)
                    browserOption("Passwords and cookies", \.secretsRequested).disabled(!model.canImportBrowserSecrets)
                    Text(model.destinationText).font(.caption).foregroundStyle(.secondary)
                case .review where !model.plan.isArc:
                    VStack(spacing: 0) {
                        if model.plan.bookmarks { reviewRow("bookmark", "Bookmarks", model.reviewValue("Bookmarks")) }
                        if model.plan.openTabs { reviewRow("square.on.square", "Open tabs", model.reviewValue("Open tabs")) }
                        if model.plan.history { reviewRow("clock.arrow.circlepath", "History", model.reviewValue("History")) }
                        if model.plan.searchSettings { reviewRow("magnifyingglass", "Search engine", model.reviewValue("Search settings")) }
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
                case .review:
                    ForEach(model.spaceMapping, id: \.self) { Text($0) }
                    Text("Found: \(ImportCountCopy.phrase(model.counts["Profiles",default:0],singular:"Profile",plural:"Profiles")) · \(ImportCountCopy.phrase(model.counts["Routing rules",default:0],singular:"routing rule",plural:"routing rules"))")
                    Text("Skipped: \(ImportCountCopy.phrase(model.counts["Skipped easels",default:0],singular:"Easel",plural:"Easels")), \(ImportCountCopy.phrase(model.counts["Skipped notes",default:0],singular:"Note",plural:"Notes")), \(ImportCountCopy.phrase(model.counts["Skipped unknown",default:0],singular:"unknown item",plural:"unknown items")).")
                    Text("Easels and Notes do not import. Open has no Easels or Notes.").foregroundStyle(.secondary)
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
        .task { if model.step == .source { await model.loadSources() } else if !model.readable { await model.refreshCounts() } }
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
        HStack { Toggle(ImportCountCopy.displayCategory(name), isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
    private func option(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(ImportCountCopy.displayCategory(name), isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
}
