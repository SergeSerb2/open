import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenSuggest
import OpenDesign

@MainActor @Observable public final class ProfilesViewModel {
    unowned let root: SettingsViewModel
    public let dataModel: ProfilesSettingsModel
    public var errorText = ""
    public var showsCreate = false
    public var showsRename = false
    public var confirmsDelete = false
    public var confirmsUnused = false
    public var deleteConfirmation = ""
    public private(set) var deletionProfiles: [(id: ProfileID, name: String)] = []
    public private(set) var deleting = false
    public var showsClear = false
    public var showsSuggestNotice = false
    public var nameDraft = ""
    public var assignedSpaces: Set<SpaceID> = []
    public func beginCreate(sourceSpace: SpaceID? = nil) {
        nameDraft = ""; errorText = ""
        assignedSpaces = Set(sourceSpace.flatMap { root.model.space(id: $0)?.id }.map { [$0] } ?? [])
        showsSuggestNotice = false
        showsCreate = true
    }
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
    public var searchEngineID: String { get { SearchEngines.resolve(profile: profile).id } set { update { $0.searchEngineID = newValue } } }
    public var suggestions: Bool { get { profile?.settings.searchSuggestEnabled ?? true } set {
        update { $0.searchSuggestEnabled = newValue }
        if newValue && !root.bool("open.general.searchSuggestNoticeDismissed") { showsSuggestNotice = true }
    } }
    /// The app uses this when building SuggestContext; no request while the notice is open.
    public var allowsRemoteSuggestions: Bool { suggestions && root.bool("open.general.searchSuggestNoticeDismissed") && !showsSuggestNotice }
    /// App calls this before its first remote query and presents Settings on Profiles when false.
    /// This uses the same notice state as pane appearance; the request must wait for dismissal.
    @discardableResult public func prepareForRemoteSuggestions(profileID: ProfileID? = nil) -> Bool {
        let id=profileID ?? root.selectedProfileID
        guard root.model.profile(id:id)?.settings.searchSuggestEnabled == true else { return false }
        return root.bool("open.general.searchSuggestNoticeDismissed") && !showsSuggestNotice
    }
    public func presentSuggestNotice(profileID: ProfileID? = nil) {
        let id=profileID ?? root.selectedProfileID
        guard root.model.profile(id:id)?.settings.searchSuggestEnabled == true,
              !root.bool("open.general.searchSuggestNoticeDismissed") else {return}
        if root.selectedProfileID != id {root.selectedProfileID=id}; showsSuggestNotice=true
    }
    public func paneDidAppear() { refresh(); if !showsCreate { presentSuggestNotice() } }
    public func dismissSuggestNotice() { root.set(true, for: "open.general.searchSuggestNoticeDismissed"); showsSuggestNotice = false }
    public var downloadDirectory: String { get { profile?.settings.downloadDirectory ?? "~/Downloads" } set { update { $0.downloadDirectory = newValue } } }
    public var askWhereToSave: Bool { get { profile?.settings.askWhereToSaveEachFile ?? false } set { update { $0.askWhereToSaveEachFile = newValue } } }
    public func nextDownloadSettings() -> (directory: String, ask: Bool) { (downloadDirectory.isEmpty ? "~/Downloads" : downloadDirectory, askWhereToSave) }
    public func refresh() { dataModel.refresh(from: root.model) }
    public func select(_ id: ProfileID) { root.selectedProfileID = id; refresh(); showsSuggestNotice=false; presentSuggestNotice() }
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
        root.selectedProfileID = created.id; root.adBlock?.refresh(); refresh(); root.save(); root.refreshLinks(); showsCreate = false; return created
    }
    public func rename(to name: String) {
        guard let profile, nameIsValid(name, excluding: profile.id) else { return }
        _ = dataModel.renameProfile(in: root.model, id: profile.id, to: name); root.save(); showsRename = false
    }
    public var canDelete: Bool { profile.map { root.model.deleteBlockReason(for: $0.id) == nil } ?? false }
    public var unusedIDs: [ProfileID] { root.model.profiles.filter { root.model.deleteBlockReason(for: $0.id) == nil }.map(\.id) }
    public func beginDelete(unused: Bool = false) {
        let ids = unused ? unusedIDs : [root.selectedProfileID]
        deletionProfiles = ids.compactMap { id in root.model.profile(id: id).map { (id, $0.name) } }
        deleteConfirmation = ""; errorText = ""
        confirmsUnused = unused; confirmsDelete = !unused
    }
    public var deleteToken: String { confirmsUnused ? "DELETE" : deletionProfiles.first?.name ?? "" }
    public var canConfirmDelete: Bool { !deleting && !deletionProfiles.isEmpty && deleteConfirmation == deleteToken }
    public func confirmDeletion() async {
        guard canConfirmDelete else { return }
        let captured = deletionProfiles
        // Recheck the captured identities and names, never a later Settings selection.
        guard captured.allSatisfy({ root.model.profile(id: $0.id)?.name == $0.name && root.model.deleteBlockReason(for: $0.id) == nil }) else {
            errorText = "These Profiles changed. Close this dialog and try again."; return
        }
        deleting = true
        defer { deleting = false; confirmsDelete = false; confirmsUnused = false }
        for profile in captured { if !(await delete(id: profile.id)) { break } }
    }
    @discardableResult public func delete(id: ProfileID) async -> Bool {
        guard let profile = root.model.profile(id: id) else { return false }
        let directory = profile.dataDirectoryName
        if let block = root.model.deleteBlockReason(for: id) { errorText = block.message; return false }
        do { try root.adBlock?.closeProfile(id) }
        catch { errorText = "This Profile’s block lists are updating. Try deleting it after the update finishes."; return false }
        do {
            let undo = root.model.undoManager
            undo?.disableUndoRegistration()
            let removed: Bool
            do { removed = try dataModel.deleteProfile(in: root.model, id: id) }
            catch { undo?.enableUndoRegistration(); throw error }
            undo?.enableUndoRegistration()
            guard removed else { return false }
            // An older create/redo must not resurrect a permanently deleted Profile.
            undo?.removeAllActions()
            if root.selectedProfileID == id, let first = root.model.defaultProfile { root.selectedProfileID = first.id }
            root.refreshLinks(); refresh()
            let diskError = await root.actions.deleteProfileData(profileID: id, dataDirectoryName: directory)
            try root.flush()
            errorText = diskError ?? ""; return diskError == nil
        } catch { root.adBlock?.refresh(); errorText = "Could not delete this Profile. \(error.localizedDescription)"; return false }
    }
    public func deleteUnused() async { for id in unusedIDs { if !(await delete(id: id)) { break } } }
    public func setIcon(_ icon: SpaceIcon?, profileID: ProfileID) {
        guard root.model.profile(id: profileID) != nil else { return }
        dataModel.setIcon(in: root.model, id: profileID, icon: icon); root.save()
    }
    public func proposeArchive(_ interval: AutoArchiveInterval) { archiveProfileID = root.selectedProfileID; pendingArchive = interval }
    public func applyArchive(all: Bool) {
        guard let interval = pendingArchive, let id = archiveProfileID else { return }
        for profile in root.model.profiles where all || profile.id == id {
            var settings = profile.settings; settings.autoArchiveAfter = interval
            dataModel.updateSettings(in: root.model, id: profile.id, settings: settings)
        }
        pendingArchive = nil; archiveProfileID = nil; root.save()
    }
    public var archiveScopeProfileName:String {archiveProfileID.flatMap{root.model.profile(id:$0)?.name} ?? profile?.name ?? "this Profile"}
    public var clearProfileName:String {clearProfileID.flatMap{root.model.profile(id:$0)?.name} ?? profile?.name ?? "this Profile"}
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
        let existing = profile?.settings.customSearchEngines.first { $0.id == id }
        var keywords = existing?.keywords ?? []
        if keywords.isEmpty { keywords = [keyword] } else { keywords[0] = keyword }
        let engine = SearchEngine(id: id ?? "custom-\(UUID().uuidString.lowercased())", name: name, keywords: keywords, searchURLTemplate: template, suggestURLTemplate: existing?.suggestURLTemplate, suggestFormat: existing?.suggestFormat ?? .openSearch)
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
    public init(model: ProfilesViewModel) { self.model=model }
    public var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(introduction).fixedSize(horizontal:false,vertical:true)

            HStack(alignment:.top,spacing:11) {
                VStack(spacing:8) {
                    VStack(spacing:0) {
                        Text("Your Profiles").font(Font(SettingsTokens.sectionTitle.font)).foregroundStyle(Color(nsColor:SettingsTokens.secondary.nsColor)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).frame(height:27)
                        Divider()
                        ForEach(model.dataModel.rows) { row in
                            HStack(spacing:4) {
                                ProfileIconButton(profile: row) { anchor in model.root.actions.chooseProfileIcon(profileID: row.id, anchor: anchor) }.frame(width:20,height:20)
                                Button { model.select(row.id) } label: {
                                    HStack(spacing:4) { Text(row.name).lineLimit(1);Spacer(minLength:2);Text("\(row.spaceCount.formatted()) \(row.spaceCount == 1 ? "Space" : "Spaces")").font(.system(size:11)).foregroundStyle(.secondary) }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }.padding(.horizontal,20).frame(height:31).background {if row.id == model.root.selectedProfileID {RoundedRectangle(cornerRadius:6).fill(Color(nsColor:SettingsTokens.selectedProfile.nsColor)).padding(.horizontal,16)}}
                        }
                        Spacer(minLength:0)
                        Divider()
                        HStack(spacing:0) {
                            profileTool("plus",help:"Create Profile") { model.beginCreate() }
                            Divider().frame(height:15)
                            profileTool("minus",help:"Delete Profile") { model.beginDelete() }.disabled(!model.canDelete)
                            Divider().frame(height:15)
                            profileTool("pencil",help:"Rename Profile") { model.nameDraft=model.profile?.name ?? "";model.showsRename=true }
                            Spacer(minLength:0)
                        }.frame(height:31)
                    }.frame(height:420).background(Color(nsColor:SettingsTokens.fill.nsColor),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(nsColor:SettingsTokens.border.nsColor)))
                    Button("Delete Unused Profiles…") { model.beginDelete(unused:true) }.buttonStyle(.plain).font(.system(size:11)).disabled(model.unusedIDs.isEmpty)
                }.frame(width:205)
                VStack(spacing:10) {
                    SettingsGroup {
                        SettingsRow(height:44) {HStack {Text("Search engine");Spacer();SettingsPopUp("Search engine",selection:$model.searchEngineID,width:137,entries:model.engines.map{.option($0.name,$0.id)})}}
                        SettingsRow(height:44) {HStack {Text("Manage search");Spacer();Button("Search Settings…"){model.root.showsSearchEngines=true}}}
                        SettingsRow(height:36,divider:false) { SettingsSwitch("Include search engine suggestions",isOn:$model.suggestions) }
                    }
                    SettingsGroup {
                        SettingsRow(height:44) {
                            HStack(spacing:4) { Text("Archive tabs after");Image(systemName:"info.circle").font(.system(size:11)).foregroundStyle(.secondary);Spacer(minLength:2)
                                SettingsPopUp("Archive tabs after",selection:Binding(get:{model.pendingArchive ?? model.profile?.settings.autoArchiveAfter ?? .twelveHours},set:{model.proposeArchive($0)}),width:152,entries:AutoArchiveInterval.allCases.map{.option($0.settingsTitle + ($0 == .twelveHours ? " (default)":""),$0)})
                            }
                        }
                        SettingsRow(height:44,divider:false) {HStack {Text("Download location");Spacer(minLength:2);SettingsPopUp("Download location",selection:Binding(get:{model.askWhereToSave ? "ask":"folder"},set:{if $0 == "ask" {model.askWhereToSave=true} else if $0 == "other" {chooseDownloads()} else {model.askWhereToSave=false}}),width:137,entries:[.option(downloadName,"folder",symbol:"folder.fill"),.option("Ask for each download","ask"),.separator,.option("Other…","other")])}}
                    }
                    SettingsGroup("Your Data and Settings") {
                        page("Privacy and Security",symbol:"lock.fill",color:.blue,page:.privacy)
                        page("Passwords",symbol:"key.fill",color:.green,page:.passwords)
                        page("Credit Cards",symbol:"creditcard.fill",color:.yellow,page:.paymentMethods)
                        page("Notifications",symbol:"bell.fill",color:.orange,page:.notifications)
                        dataRow("Clear Browsing Data",symbol:"trash.fill",color:.red,divider:false) { model.showClear() }
                    }
                }.frame(width:340)
            }
            SettingsError(text:model.errorText)
        }.environment(\.openURL,OpenURLAction { _ in model.root.actions.openHelp(topic:"profiles");return .handled })
        .onAppear { model.paneDidAppear() }
        .sheet(isPresented:$model.showsCreate) { ProfileNameSheet(model:model,create:true) }
        .sheet(isPresented:$model.showsRename) { ProfileNameSheet(model:model,create:false) }
        .sheet(isPresented:Binding(get:{model.pendingArchive != nil},set:{if !$0 {model.cancelArchive()}})) { ArchiveScopeSheet(model:model) }
        .sheet(isPresented:$model.showsSuggestNotice) { SuggestNoticeSheet(model:model) }
        .sheet(isPresented:$model.showsClear) { ClearBrowsingDataSheet(model:model) }
        .sheet(isPresented:Binding(get:{model.confirmsDelete || model.confirmsUnused},set:{if !$0 {model.confirmsDelete=false;model.confirmsUnused=false}})) { ProfileDeleteSheet(model:model) }
    }
    private var introduction:AttributedString {
        var text=AttributedString("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces. ")
        var link=AttributedString("Learn more.");link.link=URL(string:"open-help://profiles");link.underlineStyle = .single;link.foregroundColor=Color(nsColor:SettingsTokens.link.nsColor);text.append(link);return text
    }
    private var downloadName:String { URL(fileURLWithPath:(model.downloadDirectory as NSString).expandingTildeInPath).lastPathComponent }
    private func chooseDownloads() { let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK,let url=panel.url { model.downloadDirectory=url.path;model.askWhereToSave=false } }
    private func profileTool(_ symbol:String,help:String,action:@escaping ()->Void)->some View { Button(action:action) { Image(systemName:symbol).frame(width:32,height:31) }.buttonStyle(.plain).help(help).accessibilityLabel(help) }
    private func page(_ title:String,symbol:String,color:Color,page:ProfilePage)->some View { dataRow(title,symbol:symbol,color:color) { model.open(page) } }
    private func dataRow(_ title:String,symbol:String,color:Color,divider:Bool=true,action:@escaping ()->Void)->some View {
        SettingsRow(height:34,divider:divider) { Button(action:action) { HStack(spacing:8) { Image(systemName:symbol).font(.system(size:13)).foregroundStyle(.white).frame(width:24,height:24).background(color,in:RoundedRectangle(cornerRadius:4));Text(title);Spacer();Text("→").foregroundStyle(Color(nsColor:SettingsTokens.link.nsColor)) } }.buttonStyle(.plain) }
    }
}
/// Native anchor for the shared App icon picker. Profile icon editing is a Section 10 guess.
private struct ProfileIconButton: NSViewRepresentable {
    let profile: ProfileRowData
    let onPress: (NSView) -> Void
    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { action(sender) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action:onPress) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title:"",target:context.coordinator,action:#selector(Coordinator.press(_:)))
        button.isBordered=false; button.imageScaling = .scaleProportionallyDown
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action=onPress
        button.title=""; button.image=nil; button.imagePosition = .imageOnly
        switch profile.icon {
        case .emoji(let emoji): button.title=emoji;button.imagePosition = .noImage;button.font=NSFont(name:"AppleColorEmoji",size:14)
        case .symbol(let name): button.image=NSImage(systemSymbolName:name,accessibilityDescription:nil)
        case .named(let name): button.image=NSImage(systemSymbolName:NamedSpaceIcons.symbolName(for:name),accessibilityDescription:nil)
        case nil: button.image=NSImage(systemSymbolName:"person.crop.circle",accessibilityDescription:nil)
        }
        button.setAccessibilityLabel("Change icon for \(profile.name)");button.toolTip="Change icon for \(profile.name)"
    }
}

public struct ProfileDeleteSheet: View {
    @Bindable var model: ProfilesViewModel
    public init(model: ProfilesViewModel) { self.model=model }
    public var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(model.confirmsUnused ? "Delete Unused Profiles" : "Delete this Profile").font(.title3)
            if model.confirmsUnused {
                Text("Deleting these Profiles will permanently remove their cookies, history, preferences, and logins. This can't be undone.")
                Text("The unused Profiles to be deleted are: \(model.deletionProfiles.map(\.name).joined(separator:", ")).")
                Text("To continue, type DELETE:")
            } else {
                Text("Deleting “\(model.deletionProfiles.first?.name ?? "")” will permanently remove any cookies, history, preferences, and logins that belong to this Profile. This can't be undone.")
                Text("To continue, type the name of this Profile:")
            }
            TextField("Confirmation",text:$model.deleteConfirmation).accessibilityIdentifier("profile-delete-confirmation")
            SettingsError(text:model.errorText)
            HStack {
                Button("Cancel") { model.confirmsDelete=false;model.confirmsUnused=false }.keyboardShortcut(.cancelAction).disabled(model.deleting)
                Spacer()
                Button("Delete",role:.destructive) { Task { await model.confirmDeletion() } }.keyboardShortcut(.defaultAction).disabled(!model.canConfirmDelete).accessibilityIdentifier("profile-delete-submit")
            }
        }.padding(24).frame(width:460)
    }
}

public struct ProfileNameSheet:View {
    @Bindable var model:ProfilesViewModel;let create:Bool
    public init(model:ProfilesViewModel,create:Bool) { self.model=model;self.create=create }
    public var body:some View { VStack(alignment:.leading,spacing:20) {
        Text(create ? "What do you want to call this Profile?" : "Rename Profile").font(.title3)
        TextField("Name",text:$model.nameDraft)
        if create { Text("Which Spaces should use this Profile?");Text("These Spaces will start fresh in your brand new Profile").foregroundStyle(.secondary)
            ForEach(model.root.model.spaces,id:\.id) { space in Toggle(model.root.model.displayTitle(for:space),isOn:Binding(get:{model.assignedSpaces.contains(space.id)},set:{if $0 {model.assignedSpaces.insert(space.id)} else {model.assignedSpaces.remove(space.id)}})) }
        }
        SettingsError(text:model.errorText);Spacer()
        HStack { Button("Cancel") { model.showsCreate=false;model.showsRename=false }.keyboardShortcut(.cancelAction);Spacer();Button(create ? "Create Profile" : "Save") { if create {_=model.create(name:model.nameDraft,spaces:model.assignedSpaces)} else {model.rename(to:model.nameDraft)} }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true)) }
    }.padding(24).frame(width:440,height:create ? 330:180) }
}
public struct ArchiveScopeSheet:View {
    @Bindable var model:ProfilesViewModel
    public init(model:ProfilesViewModel) { self.model=model }
    public var body:some View { VStack(spacing:14) {Text("Apply to all Profiles or only “\(model.archiveScopeProfileName)”?").font(.headline); Text(model.pendingArchive == .never ? "Open will never auto-archive your tabs." : "Open will now archive your tabs after \(model.pendingArchive?.settingsTitle ?? "").")
        HStack { Button("Cancel") { model.cancelArchive() }.keyboardShortcut(.cancelAction);Button("All Profiles") { model.applyArchive(all:true) };Button("This Profile Only") { model.applyArchive(all:false) }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true)) }
    }.padding(24).frame(width:500,height:160) }
}
public struct SuggestNoticeSheet:View {
    @Bindable var model:ProfilesViewModel
    public init(model:ProfilesViewModel) { self.model=model }
    public var body:some View { VStack(spacing:24) { Text("We talk to your search engine to help us suggest results.");Button("Got it") { model.dismissSuggestNotice() }.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true)) }.padding(32).frame(width:400,height:180) }
}
public struct ClearBrowsingDataSheet:View {
    @Bindable var model:ProfilesViewModel
    public init(model:ProfilesViewModel) { self.model=model }
    public var body:some View { VStack(alignment:.leading,spacing:20) { Text("Clear Browsing Data").font(.title2);Text("Clear data for “\(model.clearProfileName)”.").foregroundStyle(.secondary)
        ForEach([(ClearDataKinds.history,"Browsing history"),(.cookies,"Cookies and site data"),(.cache,"Cached files"),(.downloads,"Download history")],id:\.0.rawValue) { kind,title in Toggle(title,isOn:Binding(get:{model.clearKinds.contains(kind)},set:{if $0 {model.clearKinds.insert(kind)} else {model.clearKinds.remove(kind)}})) }
        Picker("Time range",selection:$model.clearRange) { ForEach(ClearDataRange.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
        if model.clearing { ProgressView() };if !model.clearStatus.isEmpty {Text(model.clearStatus)};Spacer()
        HStack { Button(model.clearStatus == "Done" ? "Done":"Cancel") { model.showsClear=false }.keyboardShortcut(.cancelAction).disabled(model.clearing);Spacer();Button("Clear Data",role:.destructive) { Task {await model.clear()} }.disabled(model.clearing || model.clearKinds.isEmpty) }
    }.padding(24).frame(width:460,height:360) }
}
