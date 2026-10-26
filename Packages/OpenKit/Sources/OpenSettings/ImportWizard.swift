import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenImport

@MainActor @Observable public final class ImportWizardViewModel {
    public enum Step: String, CaseIterable { case choose = "Choose", review = "Review", consent = "Passwords", progress = "Importing", report = "Report" }
    unowned let root: SettingsViewModel
    public var plan: ImportPlan
    public var step: Step = .choose
    public private(set) var counts: [String: Int] = [:]
    public private(set) var spaceMapping: [String] = []
    public private(set) var readable = false
    public private(set) var busy = false
    public private(set) var errorText = ""
    public private(set) var outcome: ImportOutcome?
    public private(set) var consentWasDecided = false
    public init(root: SettingsViewModel, directory: URL? = nil) {
        self.root = root
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
        readable = false; busy = true; errorText = ""; defer { busy = false }
        do {
            let directory = plan.directory
            let summary = try await Task.detached(priority: .utility) {
                let parsed = try ArcImporter(arcDirectory: directory).readSidebar()
                return parsed
            }.value
            let result = try ArcImporter(arcDirectory: directory).importAll(sidebar: summary)
            let report = result.report
            counts = ["Spaces": report.spaces, "Pinned and Today tabs": report.pinnedTabs + report.todayTabs,
                      "Favorites": report.favorites, "Folders": report.folders, "Archive": report.archiveImported,
                      "Profiles": report.profiles, "Routing rules": report.routingRules, "Skipped easels": report.skippedEasels,
                      "Skipped notes": report.skippedNotes, "Skipped unknown": report.skippedUnknown, "Welcome items": report.importedWelcome,
                      "Archive accounted": report.archiveAccounted, "Archive total": report.archiveTotal]
            spaceMapping = result.model.spaces.map { result.model.displayTitle(for: $0) + " → " + result.model.displayTitle(for: $0) }
            // Counts only: these readers do not probe or read any Keychain item.
            var secrets = 0, history = 0
            let source = plan.directory
            let names = result.model.profiles.map(\.dataDirectoryName)
            let totals = try await Task.detached(priority: .utility) { () -> (Int, Int) in
                var secretCount = 0, historyCount = 0
                for name in names {
                    let directory = source.appendingPathComponent("User Data").appendingPathComponent(name)
                    if ["Login Data", "Cookies", "Web Data"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                        let report = try ArcSecretsReader(profileDirectory: directory).countOnly()
                        secretCount += report.loginRows + report.cookieRows + report.addressRows + report.cardRows
                    }
                    let history = directory.appendingPathComponent("History")
                    if FileManager.default.fileExists(atPath: history.path) { let report = try await ArcHistoryReader(historyFileURL: history).readBatches(consume: { _ in }); historyCount += report.keptVisits }
                }
                return (secretCount, historyCount)
            }.value
            secrets = totals.0; history = totals.1
            counts["Passwords and cookies"] = secrets; counts["History"] = history; counts["Search settings"] = report.profiles
            readable = true
        } catch { counts = [:]; spaceMapping = []; errorText = "No readable import data found at \(plan.directory.path)." }
    }
    public var canImportPasswordsAndCookies: Bool { root.actions.canImportPasswordsAndCookies }
    public func review() { guard canContinue else { return }; step = .review }
    public func beginImport() async {
        guard step == .review, canContinue else { return }
        if plan.secretsRequested && !consentWasDecided { step = .consent; return }
        await execute()
    }
    public func allowAndImportSecrets() async { guard root.actions.canImportPasswordsAndCookies, step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.consentToSecrets(); await execute() }
    public func skipSecrets() async { guard step == .consent, !consentWasDecided else { return }; consentWasDecided = true; plan.skipSecrets(); await execute() }
    private func execute() async {
        busy = true; step = .progress
        let result = await root.actions.runImport(plan: plan)
        outcome = result; errorText = result.errorText ?? ""; busy = false; step = .report
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
                    if model.canImportPasswordsAndCookies {
                        Text("Import passwords and cookies from Arc?").font(.headline)
                        Text("Open will read the passwords, cookies, addresses, and cards Arc saved on this Mac. To unlock them, Open needs Arc's key from your Keychain. macOS will ask for your approval. If you choose Deny, Open reads nothing and imports everything else.")
                    } else {
                        Text("Passwords and cookies can't be imported yet.").font(.headline)
                        Text("Open found \(model.counts["Passwords and cookies", default:0]) saved items in Arc. Open didn't read or copy them.")
                    }
                case .progress: ProgressView(); Text("Importing selected data…")
                case .report:
                    ForEach((model.outcome?.counts ?? [:]).keys.sorted(), id: \.self) { name in HStack { Text(name); Spacer(); Text("\(model.outcome!.counts[name]!)").monospacedDigit() } }
                    if model.plan.secretsRequested || model.consentWasDecided { Text("Passwords and cookies were not imported.").foregroundStyle(.secondary) }
                }
                SettingsError(text: model.errorText)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            if model.busy { ProgressView() }
            HStack {
                if model.step == .report { Button("Done") { model.finish() }.keyboardShortcut(.defaultAction) }
                else { Button("Cancel") { model.finish() }.keyboardShortcut(.cancelAction).disabled(model.busy) }
                Spacer()
                switch model.step {
                case .choose: Button("Next") { model.review() }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
                case .review: Button("Back") { model.step = .choose }; Button("Import") { Task { await model.beginImport() } }.keyboardShortcut(.defaultAction).disabled(!model.canContinue)
                case .consent:
                    if model.canImportPasswordsAndCookies {
                        Button("Continue Without Passwords") { Task { await model.skipSecrets() } }
                        Button("Import Passwords and Cookies") { Task { await model.allowAndImportSecrets() } }.keyboardShortcut(.defaultAction)
                    } else { Button("Continue Without Passwords") { Task { await model.skipSecrets() } }.keyboardShortcut(.defaultAction) }
                case .progress: EmptyView()
                case .report: if model.outcome?.errorText != nil { Button("Try Again") { model.retry() } } else { Button("Open Library") { model.finish(openLibrary: true) } }
                }
            }
        }.padding(24).frame(width: 640, height: 520).interactiveDismissDisabled(model.busy)
        .task { if !model.readable { await model.refreshCounts() } }
    }
    private func option(_ name: String, _ key: WritableKeyPath<ImportPlan, Bool>) -> some View {
        HStack { Toggle(name, isOn: Binding(get: { model.plan[keyPath: key] }, set: { model.plan[keyPath: key] = $0 })); Spacer(); Text("Found: \(model.counts[name, default: 0])").foregroundStyle(.secondary).monospacedDigit() }
    }
}
