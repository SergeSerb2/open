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
    public var plan: ImportPlan
    public var step: Step = .choose
    public private(set) var counts: [String: Int] = [:]
    public private(set) var probe: ArcProbeResult?
    private var countRequest=UUID()
    public private(set) var spaceMapping: [String] = []
    public private(set) var readable = false
    private var counting=false
    public private(set) var isImporting=false
    public var busy:Bool {counting || isImporting}
    public private(set) var errorText = ""
    public private(set) var outcome: ImportOutcome?
    public private(set) var consentWasDecided = false
    public init(root: SettingsViewModel, directory: URL? = nil, actions: (any ImportActions)? = nil) {
        self.root = root; self.importActions = actions ?? root.actions
        let path = root.defaults.string(forKey: "open.import.lastArcDir")
        plan = ImportPlan(directory: directory ?? path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc"))
    }
    public var directoryDisplayPath: String {
        let path = plan.directory.path
        if path.hasPrefix(root.root.path + "/") { return "Open Data/" + String(path.dropFirst(root.root.path.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    public var canContinue: Bool { readable && !busy && (plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || plan.secretsRequested) }
    public func choose(directory: URL) async { plan.directory = directory; await refreshCounts() }
    public func refreshCounts() async {
        let request=UUID();countRequest=request
        readable=false;counting=true;errorText="";probe=nil
        let directory=plan.directory
        let result=await ArcProbe(arcDirectory:directory).run()
        guard !Task.isCancelled,request == countRequest,directory == plan.directory else {if request == countRequest {counting=false};return}
        probe=result;counts=result.settingsCounts
        readable=result.sidebarFound && result.spaces != nil
        spaceMapping=[];counting=false
        if !readable {errorText="No readable import data found at \(directoryDisplayPath)."}
    }
    private func prepareSpaceMapping() {
        let directory=plan.directory
        Task { [weak self] in
            let labels=await Task.detached(priority:.utility) {(try? ArcImporter(arcDirectory:directory).spaceMappingLabels()) ?? []}.value
            guard let self,self.plan.directory == directory else {return};self.spaceMapping=labels
        }
    }
    public func countLabel(_ category:String)->String {
        if let count=counts[category] {return "Found: \(count)"}
        guard let probe else {return "Counting…"}
        let found=category == "History" ? probe.historyFound:category == "Passwords and cookies" ? probe.secretsFound:category == "Archive" ? probe.archiveFound:probe.sidebarFound
        return found ? "Could not be read":"Not found"
    }
    public static let reportCategories=["Spaces","Pinned and Today tabs","Favorites","Folders","Archive","History","Search settings","Passwords and cookies"]
    public var reportSummary:String {
        let result=outcome?.counts ?? [:],spaces=result["Spaces"] ?? result["Imported Spaces",default:0]
        let tabs=result["Imported tabs"] ?? result["Pinned and Today tabs",default:0]+result["Favorites",default:0]
        return "Imported \(spaces) \(spaces == 1 ? "Space":"Spaces") and \(tabs) \(tabs == 1 ? "tab":"tabs")."
    }
    public func reportCount(_ category:String)->Int {outcome?.counts[category] ?? 0}
    public var reportSkipped:String {
        let result=outcome?.counts ?? [:]
        var parts:[String]=[]
        for (key,singular,plural) in [("Skipped easels","easel","easels"),("Skipped notes","note","notes"),("Skipped unknown","unsupported item","unsupported items")] {
            let count=result[key,default:0];if count > 0 {parts.append("\(count) \(count == 1 ? singular:plural)")}
        }
        return parts.isEmpty ? "":"Skipped: " + parts.joined(separator:", ")
    }
    public var passwordsWereNotImported:Bool {!plan.secretsConsented}
    public var canImportPasswordsAndCookies: Bool { importActions.canImportPasswordsAndCookies }
    public func review() { guard canContinue else { return }; prepareSpaceMapping();step = .review }
    public func beginImport() async {
        guard step == .review, canContinue else { return }
        await requestImport()
    }
    /// First run can start while its estimate is still pending; the shared action reports read errors.
    public func beginImport(plan: ImportPlan) async {
        guard !isImporting, plan.spaces || plan.tabs || plan.favorites || plan.folders || plan.archive || plan.history || plan.searchSettings || plan.secretsRequested else { return }
        self.plan=plan; consentWasDecided=false; outcome=nil; errorText=""; step = .review
        await requestImport()
    }
    private func requestImport() async {
        if plan.secretsRequested && !consentWasDecided { step = .consent; return }
        await execute()
    }
    public func allowAndImportSecrets() async { guard importActions.canImportPasswordsAndCookies, step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.consentToSecrets(); await execute() }
    public func skipSecrets() async { guard step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.skipSecrets(); await execute() }
    private func execute() async {
        isImporting = true; step = .progress
        let result = await importActions.runImport(plan: plan)
        outcome = result; errorText = result.errorText ?? ""; isImporting = false; step = .report
        root.profiles.refresh(); root.refreshLinks()
    }
    public func retry() { guard !busy else { return }; outcome = nil; step = .choose }
    public func finish(openLibrary: Bool = false) { guard !busy else { return }; if outcome?.errorText == nil && outcome != nil { root.set(plan.directory.path, for: "open.import.lastArcDir") }; root.showsImport = false; if openLibrary { root.actions.openLibrary() } }
}
public struct ImportWizard: View {
    @State private var model: ImportWizardViewModel
    public init(root: SettingsViewModel) { _model = State(initialValue: ImportWizardViewModel(root: root)) }
    public init(model: ImportWizardViewModel) { _model = State(initialValue: model) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import from Arc").font(.title2)
            HStack { ForEach(ImportWizardViewModel.Step.allCases.filter { $0 != .progress && ($0 != .consent || model.plan.secretsRequested || model.step == .consent) }, id: \.self) { step in Text(step.rawValue).foregroundStyle(model.step == step ? .primary : .secondary); if step != .report { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } } }
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                case .choose:
                    HStack { Text("From: " + model.directoryDisplayPath).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button("Choose Folder…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let directory = panel.url { Task { await model.choose(directory: directory) } } } }
                    option("Spaces", \.spaces); option("Pinned and Today tabs", \.tabs); option("Favorites", \.favorites); option("Folders", \.folders); option("Archive", \.archive); option("History", \.history); option("Search settings", \.searchSettings); option("Passwords and cookies", \.secretsRequested)
                    Text("Search settings imports your engine choice only.").font(.caption).foregroundStyle(.secondary)
                case .review:
                    ForEach(model.spaceMapping, id: \.self) { Text($0) }
                    Text("Profiles found: \(model.counts["Profiles", default: 0]) · Routing rules found: \(model.counts["Routing rules", default: 0])")
                    Text("Skipped: \(model.counts["Skipped easels", default: 0]) \(model.counts["Skipped easels"] == 1 ? "easel" : "easels"), \(model.counts["Skipped notes", default: 0]) \(model.counts["Skipped notes"] == 1 ? "note" : "notes"), \(model.counts["Skipped unknown", default: 0]) unknown items.")
                    Text("Easels and Notes do not import. Open has no Easels or Notes.").foregroundStyle(.secondary)
                case .consent:
                    let copy=PasswordsImportCopy(canImport:model.canImportPasswordsAndCookies,savedItems:model.probe == nil ? nil:(model.probe?.secretsFound == false ? 0:model.counts["Passwords and cookies"]))
                    Text(copy.title).font(.headline)
                    Text(copy.body)
                case .progress: ProgressView(); Text("Importing selected data…")
                case .report:
                    if model.outcome?.errorText == nil {
                        Text(model.reportSummary).font(.headline)
                        ForEach(ImportWizardViewModel.reportCategories,id:\.self) {name in HStack {Text(name);Spacer();Text("\(model.reportCount(name))").monospacedDigit()}}
                        if !model.reportSkipped.isEmpty {Text(model.reportSkipped).foregroundStyle(.secondary)}
                    }
                    if model.passwordsWereNotImported {Text("Passwords and cookies were not imported.").foregroundStyle(.secondary)}
                }
                SettingsError(text: model.errorText)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            if model.busy { ProgressView() }
            HStack {
                if model.step != .report { Button("Cancel") { model.finish() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
                Spacer()
                switch model.step {
                case .choose: Button("Next") { model.review() }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
                case .review: Button("Back") { model.step = .choose }; Button("Import") { Task { await model.beginImport() } }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
                case .consent:
                    if model.canImportPasswordsAndCookies {
                        Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }
                        Button(PasswordsImportCopy.allowButton) { Task { await model.allowAndImportSecrets() } }.keyboardShortcut(.defaultAction)
                    } else { Button(PasswordsImportCopy.skipButton) { Task { await model.skipSecrets() } }.keyboardShortcut(.defaultAction) }
                case .progress: EmptyView()
                case .report: if model.outcome?.errorText != nil { Button("Try Again") { model.retry() } } else { Button("Open Library") { model.finish(openLibrary: true) } };Button("Done") { model.finish() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 640, height: 520).interactiveDismissDisabled(model.busy)
        .task { if !model.readable { await model.refreshCounts() } }
    }
    private func option(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(name, isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text(model.countLabel(name)).foregroundStyle(.secondary).monospacedDigit() }
    }
}
