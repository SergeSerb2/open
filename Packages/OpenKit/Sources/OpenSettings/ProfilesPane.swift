import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenSuggest

@MainActor @Observable public final class ProfilesViewModel {
    unowned let root: SettingsViewModel
    public let dataModel: ProfilesSettingsModel
    public var errorText = ""
    public var showsCreate = false
    public var showsRename = false
    public var confirmsDelete = false
    public var confirmsUnused = false
    public var showsClear = false
    public var showsSuggestNotice = false
    public var nameDraft = ""
    public var assignedSpaces: Set<SpaceID> = []
    public var pendingArchive: AutoArchiveInterval?
    private var archiveProfileID: ProfileID?
    private var clearProfileID: ProfileID?
    public var clearKinds: ClearDataKinds = [.history, .cookies, .cache]
    public var clearRange: ClearDataRange = .all
    public var clearing = false
    public var clearStatus = ""
    public init(root: SettingsViewModel) { self.root = root; dataModel = ProfilesSettingsModel(model: root.model) }
    public var profile: Profile? { root.model.profile(id: root.selectedProfileID) }
    public var engines: [SearchEngine] { SearchEngines.all + (profile?.settings.customSearchEngines ?? []) }
    public var searchEngineID: String { get { SearchEngines.engine(id: profile?.settings.searchEngineID, in: engines).id } set { update { $0.searchEngineID = newValue } } }
    public var suggestions: Bool { get { profile?.settings.searchSuggestEnabled ?? true } set {
        update { $0.searchSuggestEnabled = newValue }
        if newValue && !root.bool("open.general.searchSuggestNoticeDismissed") { showsSuggestNotice = true }
    } }
    /// The app uses this when building SuggestContext; no request while the notice is open.
    public var allowsRemoteSuggestions: Bool { suggestions && root.bool("open.general.searchSuggestNoticeDismissed") && !showsSuggestNotice }
    public func dismissSuggestNotice() { root.set(true, for: "open.general.searchSuggestNoticeDismissed"); showsSuggestNotice = false }
    public var downloadDirectory: String { get { profile?.settings.downloadDirectory ?? "~/Downloads" } set { update { $0.downloadDirectory = newValue } } }
    public var askWhereToSave: Bool { get { profile?.settings.askWhereToSaveEachFile ?? false } set { update { $0.askWhereToSaveEachFile = newValue } } }
    public func nextDownloadSettings() -> (directory: String, ask: Bool) { (downloadDirectory.isEmpty ? "~/Downloads" : downloadDirectory, askWhereToSave) }
    public func refresh() { dataModel.refresh(from: root.model) }
    public func select(_ id: ProfileID) { root.selectedProfileID = id; refresh() }
    public func update(_ change: (inout ProfileSettings) -> Void) {
        guard let profile else { return }; var settings = profile.settings; change(&settings)
        dataModel.updateSettings(in: root.model, id: profile.id, settings: settings); root.save()
    }
    private func nameIsValid(_ name: String, excluding: ProfileID? = nil) -> Bool {
        if let issue = dataModel.nameIssue(for: name, excluding: excluding) {
            errorText = issue == .invalidCharacters ? "Invalid Profile name." : issue.message; return false
        }
        errorText = ""; return true
    }
    @discardableResult public func create(name: String, spaces: Set<SpaceID> = []) -> Profile? {
        guard nameIsValid(name), let created = dataModel.createProfile(in: root.model, name: name) else { return nil }
        for id in spaces { _ = root.model.moveSpace(id: id, toProfile: created.id) }
        root.selectedProfileID = created.id; refresh(); root.save(); root.refreshLinks(); showsCreate = false; return created
    }
    public func rename(to name: String) {
        guard let profile, nameIsValid(name, excluding: profile.id) else { return }
        _ = dataModel.renameProfile(in: root.model, id: profile.id, to: name); root.save(); showsRename = false
    }
    public var canDelete: Bool { profile.map { root.model.deleteBlockReason(for: $0.id) == nil } ?? false }
    public var unusedIDs: [ProfileID] { root.model.profiles.filter { root.model.deleteBlockReason(for: $0.id) == nil }.map(\.id) }
    @discardableResult public func delete(id: ProfileID) -> Bool {
        if let block = root.model.deleteBlockReason(for: id) { errorText = block.message; return false }
        if let error = root.actions.deleteProfileData(profileID: id) { errorText = error; return false }
        do {
            guard try dataModel.deleteProfile(in: root.model, id: id) else { return false }
            if root.selectedProfileID == id, let first = root.model.defaultProfile { root.selectedProfileID = first.id }
            root.save(); root.refreshLinks(); errorText = ""; return true
        } catch { errorText = "Could not delete this Profile. \(error.localizedDescription)"; return false }
    }
    public func deleteUnused() { for id in unusedIDs { if !delete(id: id) { break } } }
    public func proposeArchive(_ interval: AutoArchiveInterval) { archiveProfileID = root.selectedProfileID; pendingArchive = interval }
    public func applyArchive(all: Bool) {
        guard let interval = pendingArchive, let id = archiveProfileID else { return }
        for profile in root.model.profiles where all || profile.id == id {
            var settings = profile.settings; settings.autoArchiveAfter = interval
            dataModel.updateSettings(in: root.model, id: profile.id, settings: settings)
        }
        pendingArchive = nil; archiveProfileID = nil; root.save()
    }
    public func cancelArchive() { pendingArchive = nil; archiveProfileID = nil }
    public func showClear() { clearProfileID = root.selectedProfileID; clearStatus = ""; showsClear = true }
    public func clear() async {
        guard !clearing, let id = clearProfileID else { return }
        clearing = true
        clearStatus = await root.actions.clearBrowsingData(profileID: id, kinds: clearKinds, range: clearRange) ?? "Done"
        clearing = false
    }
    public func engineIssue(name: String, keyword: String, template: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keyword.isEmpty, !keyword.contains(where: \.isWhitespace), template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "example")), ["http", "https"].contains(url.scheme), url.host() != nil else {
            return "Enter a name, a keyword without spaces, and a search URL containing %s."
        }
        return nil
    }
    @discardableResult public func saveEngine(id: String? = nil, name: String, keyword: String, template: String) -> Bool {
        if let issue = engineIssue(name: name, keyword: keyword, template: template) { errorText = issue; return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = SearchEngine(id: id ?? "custom-\(UUID().uuidString.lowercased())", name: name, keywords: [keyword], searchURLTemplate: template, suggestURLTemplate: nil)
        guard !SearchEngines.all.contains(where: { $0.id == engine.id }) else { errorText = "Built-in engines cannot be replaced."; return false }
        update { settings in if let index = settings.customSearchEngines.firstIndex(where: { $0.id == engine.id }) { settings.customSearchEngines[index] = engine } else { settings.customSearchEngines.append(engine) } }
        errorText = ""; return true
    }
    public func removeEngine(_ id: String) { update { $0.customSearchEngines.removeAll { $0.id == id }; if $0.searchEngineID == id { $0.searchEngineID = "google" } } }
    public func restoreBuiltins() { update { settings in if settings.customSearchEngines.contains(where: { $0.id == settings.searchEngineID }) { settings.searchEngineID = "google" }; settings.customSearchEngines = [] } }
    public func open(_ page: ProfilePage) { root.actions.openProfileSubpage(profileID: root.selectedProfileID, page: page) }
}

public struct ProfilesPane: View {
    @Bindable var model: ProfilesViewModel
    public init(model: ProfilesViewModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Profiles keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces. [Learn more.](open-help://profiles)")
                .environment(\.openURL, OpenURLAction { _ in model.root.actions.openHelp(topic: "profiles"); return .handled })
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Profiles").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.dataModel.rows) { row in
                        Button { model.select(row.id) } label: { VStack(alignment: .leading, spacing: 4) { Text(row.name); Text("\(row.spaceCount) \(row.spaceCount == 1 ? "Space" : "Spaces")").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(row.id == model.root.selectedProfileID ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 100)
                    HStack { Button { model.nameDraft = ""; model.assignedSpaces = []; model.showsCreate = true } label: { Image(systemName: "plus") }.help("Create Profile")
                        Button { model.confirmsDelete = true } label: { Image(systemName: "minus") }.disabled(!model.canDelete).help("Delete Profile")
                        Button { model.nameDraft = model.profile?.name ?? ""; model.showsRename = true } label: { Image(systemName: "pencil") }.help("Rename Profile")
                    }
                    Button { model.confirmsUnused = true } label: { Text("Delete unused Profiles").font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true) }.buttonStyle(.plain).disabled(model.unusedIDs.isEmpty)
                }.padding(10).frame(width: 145).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                VStack(spacing: 16) {
                    SettingsGroup("") {
                        HStack { Text("Search engine"); Spacer(); Picker("Search engine", selection: $model.searchEngineID) { ForEach(model.engines) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize() }
                        HStack { Text("Manage search"); Spacer(); Button("Search Settings…") { model.root.showsSearchEngines = true } }
                        SettingsSwitch("Include search engine suggestions", isOn: $model.suggestions)
                    }
                    SettingsGroup("") {
                        Picker("Archive tabs after", selection: Binding(get: { model.pendingArchive ?? model.profile?.settings.autoArchiveAfter ?? .twelveHours }, set: { model.proposeArchive($0) })) { ForEach(AutoArchiveInterval.allCases, id: \.self) { Text($0.settingsTitle + ($0 == .twelveHours ? " (default)" : "")).tag($0) } }
                        VStack(alignment: .leading) {
                            HStack { Text("Download location"); Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { model.downloadDirectory = url.path } } }
                            Text(model.downloadDirectory.isEmpty ? "~/Downloads" : model.downloadDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        SettingsSwitch("Ask where to save each file", isOn: $model.askWhereToSave)
                    }
                    SettingsGroup("Your Data and Settings") {
                        page("Privacy and Security", .privacy); page("Passwords", .passwords); page("Payment Methods", .paymentMethods); page("Notifications", .notifications)
                        Button("Clear Browsing Data…", role: .destructive) { model.showClear() }
                    }
                }.frame(maxWidth: .infinity)
            }
            SettingsError(text: model.errorText)
        }.onAppear { model.refresh() }
        .sheet(isPresented: $model.showsCreate) { nameSheet(create: true) }
        .sheet(isPresented: $model.showsRename) { nameSheet(create: false) }
        .sheet(isPresented: Binding(get: { model.pendingArchive != nil }, set: { if !$0 { model.cancelArchive() } })) {
            VStack(spacing: 24) { Text(model.pendingArchive == .never ? "Open will never auto-archive your tabs." : "Open will now archive your tabs after \(model.pendingArchive?.settingsTitle ?? "").")
                HStack { Button("Cancel") { model.cancelArchive() }; Button("All Profiles") { model.applyArchive(all: true) }; Button("This Profile Only") { model.applyArchive(all: false) }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 500)
        }
        .sheet(isPresented: $model.showsSuggestNotice) { VStack(spacing: 24) { Text("We talk to your search engine to help us suggest results."); Button("Got it") { model.dismissSuggestNotice() } }.padding(32).frame(width: 400) }
        .sheet(isPresented: $model.showsClear) { clearSheet }
        .confirmationDialog("Deleting this Profile will permanently remove any cookies, history, preferences, and logins that belong to it.", isPresented: $model.confirmsDelete) { Button("Delete Profile", role: .destructive) { _ = model.delete(id: model.root.selectedProfileID) } }
        .confirmationDialog("Deleting unused Profiles will permanently remove any cookies, history, preferences, and logins that belong to those Profiles.", isPresented: $model.confirmsUnused) { Button("Delete unused Profiles", role: .destructive) { model.deleteUnused() } }
    }
    private func page(_ title: String, _ page: ProfilePage) -> some View { Button { model.open(page) } label: { HStack { Text(title); Spacer(); Image(systemName: "chevron.right") } }.buttonStyle(.plain) }
    private func nameSheet(create: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(create ? "What do you want to call this Profile?" : "Rename Profile").font(.title3)
            TextField("Name", text: $model.nameDraft)
            if create { Text("Which Spaces should use this Profile?"); Text("These Spaces will start fresh in your brand new Profile").foregroundStyle(.secondary)
                ForEach(model.root.model.spaces, id: \.id) { space in Toggle(model.root.model.displayTitle(for: space), isOn: Binding(get: { model.assignedSpaces.contains(space.id) }, set: { if $0 { model.assignedSpaces.insert(space.id) } else { model.assignedSpaces.remove(space.id) } })) }
            }
            SettingsError(text: model.errorText)
            HStack { Button("Cancel") { model.showsCreate = false; model.showsRename = false }; Spacer(); Button(create ? "Create Profile" : "Save") { if create { _ = model.create(name: model.nameDraft, spaces: model.assignedSpaces) } else { model.rename(to: model.nameDraft) } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440)
    }
    private var clearSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Clear Browsing Data").font(.title2)
            ForEach([(ClearDataKinds.history, "Browsing history"), (.cookies, "Cookies and site data"), (.cache, "Cached files"), (.downloads, "Download history")], id: \.0.rawValue) { kind, title in
                Toggle(title, isOn: Binding(get: { model.clearKinds.contains(kind) }, set: { if $0 { model.clearKinds.insert(kind) } else { model.clearKinds.remove(kind) } }))
            }
            Picker("Time range", selection: $model.clearRange) { ForEach(ClearDataRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if model.clearing { ProgressView() }; Text(model.clearStatus)
            Spacer(); HStack { Button(model.clearStatus == "Done" ? "Done" : "Cancel") { model.showsClear = false }.disabled(model.clearing); Spacer(); Button("Clear Data", role: .destructive) { Task { await model.clear() } }.disabled(model.clearing || model.clearKinds.isEmpty) }
        }.padding(24).frame(width: 412, height: 312)
    }
}
