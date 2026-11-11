import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenImport

@MainActor @Observable public final class ImportWizardViewModel {
    public enum Step: String, CaseIterable { case choose = "Choose", review = "Review", consent = "Passwords", progress = "Importing", report = "Report" }
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
    public init(root: SettingsViewModel, directory: URL? = nil, actions: (any ImportActions)? = nil) {
        self.root = root; self.importActions = actions ?? root.actions
        unfinishedSecretsImport = self.importActions.hasUnfinishedSecretsImport
        let path = root.defaults.string(forKey: "open.import.lastArcDir")
        plan = ImportPlan(directory: directory ?? path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc"))
    }
    public var directoryDisplayPath: String {
        let path = plan.directory.path
        if path.hasPrefix(root.root.path + "/") { return "Open Data/" + String(path.dropFirst(root.root.path.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    public var canContinue: Bool { readable && !busy && (plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || (plan.secretsRequested && canImportPasswordsAndCookies)) }
    public func choose(directory: URL) async { guard !isImporting else { return }; clearConsent(); plan.directory = directory; await refreshCounts() }
    public func refreshCounts() async {
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
        if let count=counts[category] {let partial=category == "History" ? probe?.historyPartial == true:category == "Passwords and cookies" && probe?.savedItemsPartial == true;return "Found: \(count.formatted())"+(partial ? " (partial)":"")}
        guard let probe else {return "Counting…"}
        let found=category == "History" ? probe.historyFound:category == "Passwords and cookies" ? probe.secretsFound:category == "Archive" ? probe.archiveFound:probe.sidebarFound
        return found ? "Could not be read":"Not found"
    }
    public static let reportCategories=["Spaces","Pinned and Today tabs","Favorites","Folders","Archive","History","Search settings","Boosts","Passwords and cookies"]
    public var displayedReportCategories: [String] { Self.reportCategories.filter { $0 != "Passwords and cookies" || outcome?.secretsReportLines.isEmpty != false } }
    public var secretsReportLines: [String] { outcome?.secretsReportLines ?? [] }
    public var unfinishedSecretsImportMessage: String? {
        unfinishedSecretsImport && !secretsReportLines.contains(ArcSecretsImportReport.unfinishedMessage) ? ArcSecretsImportReport.unfinishedMessage : nil
    }
    public var reportSummary:String {
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
        .init(canImport: canImportPasswordsAndCookies, savedItems: probe == nil ? nil : (probe?.secretsFound == false ? 0 : counts["Passwords and cookies"]))
    }
    public func review() { guard canContinue else { return }; step = .review }
    public func beginImport() async {
        guard step == .review, canContinue else { return }
        clearConsent()
        await requestImport()
    }
    /// First run can start while its estimate is still pending; the shared action reports read errors.
    public func beginImport(plan: ImportPlan) async {
        guard !isImporting, plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || (plan.secretsRequested && canImportPasswordsAndCookies) else { return }
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
    public func finish(openLibrary: Bool = false) { guard !busy else { return }; if outcome?.errorText == nil && outcome != nil { root.set(plan.directory.path, for: "open.import.lastArcDir") }; clearConsent(); root.showsImport = false; if openLibrary { root.actions.openLibrary() } }
    public func installExtensions() async { guard step == .report else { return }; await extensions.install(using: importActions) }
}
public struct ImportWizard: View {
    @State private var model: ImportWizardViewModel
    public init(root: SettingsViewModel) { _model = State(initialValue: root.importWizard) }
    public init(model: ImportWizardViewModel) { _model = State(initialValue: model) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import from Arc").font(.title2)
            HStack { ForEach(ImportWizardViewModel.Step.allCases.filter { $0 != .progress && ($0 != .consent || model.plan.secretsRequested || model.step == .consent) }, id: \.self) { step in Text(step.rawValue).foregroundStyle(model.step == step ? .primary : .secondary); if step != .report { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } } }
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                switch model.step {
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
                    if model.passwordsWereNotImported {Text("Passwords and cookies were not imported.").foregroundStyle(.secondary)}
                    if let failure = model.outcome?.failures["Passwords and cookies"] { Text(failure).foregroundStyle(.secondary) }
                    if let message = model.unfinishedSecretsImportMessage { Text(message).foregroundStyle(.secondary) }
                    ImportExtensionsSection(model: model.extensions) { Task { await model.installExtensions() } }
                }
                SettingsError(text: model.errorText)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            if model.busy { ProgressView() }
            HStack {
                if model.step != .report { Button("Cancel") { model.finish() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
                Spacer()
                switch model.step {
                case .choose: Button("Next") { model.review() }.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle()).disabled(!model.canContinue)
                case .review: Button("Back") { model.step = .choose }; Button("Import") { Task { await model.beginImport() } }.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle()).disabled(!model.canContinue)
                case .consent:
                    if model.canImportPasswordsAndCookies {
                        Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }
                        Button(PasswordsImportCopy.allowButton) { Task { await model.allowAndImportSecrets() } }.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle())
                    } else { Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle()) }
                case .progress: EmptyView()
                case .report: if model.outcome?.errorText != nil { Button("Try again") { model.retry() } } else { Button("Open Library") { model.finish(openLibrary: true) } };Button("Done") { model.finish() }.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle())
                }
            }.disabled(model.extensions.isInstalling)
        }.padding(24).frame(width: 640, height: 520).interactiveDismissDisabled(model.busy).settingsSheet()
        .task { if !model.readable { await model.refreshCounts() } }
    }
    private func option(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(ImportCountCopy.displayCategory(name), isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
}
