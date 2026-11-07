import AppKit
import SwiftUI
import Observation
import OpenDesign
import OpenImport

/// The Settings wizard and first run render the same capability-dependent consent copy.
public struct PasswordsImportCopy: Sendable {
    public let canImport: Bool
    public let savedItems: Int?
    public init(canImport:Bool,savedItems:Int?) {self.canImport=canImport;self.savedItems=savedItems}
    public var title:String {canImport ? "Import passwords and cookies from Arc?":"Passwords and cookies can't be imported yet."}
    public var body:String {
        if canImport {return "Open will read the passwords, cookies, addresses, and cards Arc saved on this Mac. To unlock them, Open needs Arc's key from your Keychain. macOS will ask for your approval. If you choose Deny, Open reads nothing and imports everything else."}
        if let savedItems {return "Open found \(ImportCountCopy.phrase(savedItems,singular:"saved item",plural:"saved items")) in Arc. Open didn't read or copy \(savedItems == 1 ? "it":"them")."}
        return "Open didn't read or copy passwords or cookies. You can continue without them."
    }
    public static let later="You can skip this step and do it later from Settings."
    public var help:String {canImport ? "Saved passwords, cookies, addresses, and cards. macOS will ask for approval on the next step. You can also do this later from Settings.":"Passwords and cookies can't be imported yet. You can continue without them and import later from Settings."}
    public static let skipButton="Continue Without Passwords"
    public static let allowButton="Import Passwords and Cookies"
}

@MainActor public protocol FirstRunActions: ImportActions {
    func setAsDefaultBrowser() -> String?
    func isDefaultBrowser() -> Bool
    func finishFirstRun(imported:Bool)
}

public enum FirstRunWindow {public static let size=SettingsTokens.firstRunSize}

@MainActor @Observable public final class FirstRunViewModel {
    public enum Step:String,Sendable {case welcome,importChoices,secretsConsent,importing,report,defaultBrowser,failed}
    public var step:Step = .welcome
    public var probe:ArcProbeResult?
    public var arcIsRunning=false
    public var includeSpacesAndTabs=true
    public var includeArchive=true
    public var includeHistory=false
    public var includeSecrets=false
    public var phaseText="Importing your Spaces and tabs…"
    public var progress:Double?
    public var browserHasLanded=false
    public var errorText:String?
    public private(set) var isDefaultBrowser=false
    public private(set) var defaultWasAttempted=false
    public let actions:any FirstRunActions
    public let wizard:ImportWizardViewModel
    // Retain the Settings owner: the shared wizard borrows it.
    private let settings:SettingsViewModel
    private var imported=false
    public init(settings:SettingsViewModel,actions:any FirstRunActions,directory:URL?=nil) {
        self.settings=settings;self.actions=actions
        wizard=ImportWizardViewModel(root:settings,directory:directory,actions:actions)
    }
    public var hasSelection:Bool {includeSpacesAndTabs || includeArchive || includeHistory || (includeSecrets && wizard.canImportPasswordsAndCookies)}
    public var outcome:ImportOutcome? {wizard.outcome}
    public var busy:Bool {wizard.isImporting || wizard.extensions.isInstalling || step == .importing}
    public var passwordsCopy:PasswordsImportCopy {.init(canImport:wizard.canImportPasswordsAndCookies,savedItems:probe?.secretsFound == false ? 0:probe?.savedItems)}
    public var welcomeStatus:String {
        guard let probe else {return "Checking for data to import…"}
        guard probe.sidebarFound else {return "No data found to import on this Mac."}
        guard let spaces=probe.spaces,let items=probe.sidebarItems else {return "Import data found. Choose what to bring into Open."}
        return "Found data to import: \(ImportCountCopy.phrase(spaces,singular:"Space",plural:"Spaces")), about \(ImportCountCopy.phrase(items,singular:"tab",plural:"tabs"))."
    }
    public var prefersFreshStart:Bool {probe?.sidebarFound == false || errorText == Self.freshSaveError}
    public func showImport() {errorText=nil;step = .importChoices}
    public func startFresh() {guard !busy else {return};actions.finishFirstRun(imported:false)}
    public func skipImport() {guard !busy else {return};imported=false;enterDefaultBrowser()}
    public func enterDefaultBrowser() {step = .defaultBrowser;errorText=nil;defaultWasAttempted=false;isDefaultBrowser=actions.isDefaultBrowser()}
    /// The App's default-browser service completes asynchronously after its click.
    public func refreshDefaultBrowserStatus() {isDefaultBrowser=actions.isDefaultBrowser()}
    public func makeDefault() {
        guard step == .defaultBrowser,!isDefaultBrowser else {return}
        defaultWasAttempted=true
        if actions.setAsDefaultBrowser() != nil {errorText="Open could not be set as your default browser. You can try again in Settings."}
        else {errorText=nil}
        isDefaultBrowser=actions.isDefaultBrowser()
    }
    public func finish() {guard !busy else {return};actions.finishFirstRun(imported:imported)}
    public func continueImport() async {
        guard [.importChoices,.failed].contains(step),hasSelection,!wizard.isImporting else {return}
        var plan=ImportPlan(directory:wizard.plan.directory)
        plan.spaces=includeSpacesAndTabs;plan.tabs=includeSpacesAndTabs;plan.favorites=includeSpacesAndTabs;plan.folders=includeSpacesAndTabs;plan.searchSettings=includeSpacesAndTabs
        plan.boosts=includeSpacesAndTabs
        plan.archive=includeArchive;plan.history=includeHistory;plan.secretsRequested=includeSecrets && wizard.canImportPasswordsAndCookies
        errorText=nil;phaseText=includeSpacesAndTabs ? "Importing your Spaces and tabs…":includeArchive ? "Importing your archive…":includeHistory ? "Importing your history…":"Checking passwords and cookies…"
        step=plan.secretsRequested ? .secretsConsent:.importing
        await Task.yield()
        await wizard.beginImport(plan:plan)
        synchronizeImportState()
    }
    public func cancelPasswords() {guard !wizard.isImporting else {return};step = .importChoices}
    public func skipPasswords() async {
        guard step == .secretsConsent else {return};step = .importing
        await Task.yield();await wizard.skipSecrets();synchronizeImportState()
    }
    public func allowPasswords() async {
        guard step == .secretsConsent,wizard.canImportPasswordsAndCookies else {return};step = .importing
        await Task.yield();await wizard.allowAndImportSecrets();synchronizeImportState()
    }
    private func synchronizeImportState() {
        if wizard.step == .consent {step = .secretsConsent;return}
        guard let outcome else {return}
        imported=wizard.hasImportedData
        errorText=outcome.errorText
        // Sidebar failure is E-1. Per-kind failures after parsing belong on
        // Report, including an all-failed selection that can Continue fresh.
        let sidebarFailed=outcome.failures["Spaces"] != nil || outcome.failures.isEmpty
        step=outcome.errorText != nil && !imported && sidebarFailed ? .failed:.report
    }
    public func choose(directory:URL) async {wizard.plan.directory=directory;probe=nil;await refreshProbe()}
    public func refreshProbe() async {
        await wizard.refreshCounts()
        guard !Task.isCancelled else {return}
        probe=wizard.probe
    }
    public static let importedSaveError="Open could not save your data. Your imported items are still open in the browser window behind this panel. Try again."
    public static let freshSaveError="Open could not save your data. Try Start Fresh again."
    public func reportSaveFailure(imported:Bool) {errorText=imported ? Self.importedSaveError:Self.freshSaveError}
    public func reportValue(_ category:String)->String {
        if category == "Boosts", let failure=outcome?.failures[category] {return failure}
        if outcome?.failures[category] != nil {return "Could not be read"}
        if category == "History" && !wizard.plan.history {return "Not selected"}
        if category == "Passwords and cookies" && !wizard.plan.secretsConsented {return includeSecrets && wizard.consentWasDecided ? "Not imported":"Not selected"}
        return wizard.reportCount(category).formatted()
    }
    public var reportNote:String? {
        if let error=errorText,!error.isEmpty {return error}
        var parts:[String]=[]
        for (key,singular,plural) in [("Skipped easels","Easel","Easels"),("Skipped notes","Note","Notes"),("Skipped unknown","unsupported item","unsupported items")] {
            if let count=outcome?.counts[key],count>0 {parts.append(ImportCountCopy.phrase(count,singular:singular,plural:plural))}
        }
        return parts.isEmpty ? nil:"Skipped: "+parts.joined(separator:", ")
    }
    public var reportSummary:String {
        var parts:[String]=[]
        if outcome?.failures["Spaces"] == nil {parts.append(ImportCountCopy.phrase(wizard.reportCount("Spaces"),singular:"Space",plural:"Spaces"))}
        if ["Imported tabs","Pinned and Today tabs","Favorites"].allSatisfy({outcome?.failures[$0] == nil}) {parts.append(ImportCountCopy.phrase(wizard.reportCount("Imported tabs"),singular:"tab",plural:"tabs"))}
        if outcome?.failures["Archive"] == nil {parts.append(ImportCountCopy.phrase(wizard.reportCount("Archive"),singular:"archived tab",plural:"archived tabs"))}
        return parts.isEmpty ? "Import finished.":parts.joined(separator:", ")+" imported."
    }
    public var duplicateSummary:String? {
        guard let count=outcome?.counts["Duplicates"],count>0 else {return nil}
        let verb=count == 1 ? "was":"were"
        return "\(ImportCountCopy.phrase(count,singular:"item",plural:"items")) \(verb) already in Open and \(verb) not copied again."
    }
    public var reportNoteIsError:Bool {
        guard errorText != nil else {return false}
        return !(wizard.hasImportedData && outcome?.failures.isEmpty == false && errorText == outcome?.errorText)
    }
    public func found(_ value:Int?,singular:String,plural:String,present:Bool=true,partial:Bool=false)->String {
        if probe == nil {return "Counting…"}
        guard let value else {return present ? "Could not be read":"Not found"}
        return "Found: \(ImportCountCopy.phrase(value,singular:singular,plural:plural))"+(partial ? " (partial)":"")
    }
}

public struct FirstRunView:View {
    @Bindable var model:FirstRunViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let startsProbe:Bool
    public init(model:FirstRunViewModel,startsProbe:Bool=true) {self.model=model;self.startsProbe=startsProbe}
    private var secondary:Color {Color(nsColor:SettingsTokens.secondary.nsColor)}
    private var section:Font {Font(SettingsTokens.section.font)}
    public var body:some View {
        Group {if model.step == .welcome {welcome} else {stepContent}}
            .padding(.horizontal,SettingsTokens.firstRunHorizontalInset)
            .padding(.top,model.step == .welcome ? SettingsTokens.firstRunVerticalInset:SettingsTokens.firstRunStepTopInset)
            .padding(.bottom,SettingsTokens.firstRunVerticalInset)
            .frame(width:FirstRunWindow.size.width,height:FirstRunWindow.size.height)
            .font(Font(SettingsTokens.label.font)).controlSize(.regular).buttonStyle(SettingsButtonStyle())
            .background(Color(nsColor:SettingsTokens.content.nsColor)).ignoresSafeArea()
            .animation(reduceMotion ? nil:.easeInOut(duration:Motion.selectionFade),value:model.step)
            .task {if startsProbe && model.probe == nil {await model.refreshProbe()}}
    }
    private func primary(_ title:String,action:@escaping ()->Void)->some View {Button(title,action:action).keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true))}
    private var brand:some View {OriginalOpenIcon(index:0).frame(width:64,height:64)}
    private var welcome:some View {VStack(spacing:0) {
        Spacer(minLength:0)
        brand.frame(width:SettingsTokens.firstRunIconSize,height:SettingsTokens.firstRunIconSize)
        Text("Open").font(Font(SettingsTokens.firstRunWordmark.font)).padding(.top,16)
        Text("Open is a fast, private browser that keeps your Spaces, tabs, and history on this Mac.").multilineTextAlignment(.center).frame(maxWidth:SettingsTokens.firstRunIdentityWidth).fixedSize(horizontal:false,vertical:true).padding(.top,8)
        VStack(spacing:8) {
            Button {model.showImport()} label:{Text("Import from Arc").frame(width:SettingsTokens.firstRunButtonWidth-24)}.keyboardShortcut(model.prefersFreshStart ? nil:.defaultAction).buttonStyle(SettingsButtonStyle(prominent:!model.prefersFreshStart,height:28))
            Button {model.startFresh()} label:{Text("Start Fresh").frame(width:SettingsTokens.firstRunButtonWidth-24)}.keyboardShortcut(model.prefersFreshStart ? .defaultAction:nil).buttonStyle(SettingsButtonStyle(prominent:model.prefersFreshStart,height:28))
        }.frame(width:SettingsTokens.firstRunButtonWidth).padding(.top,24)
        Text(model.welcomeStatus).font(section).foregroundStyle(secondary).multilineTextAlignment(.center).padding(.top,16)
        if let error=model.errorText {Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth:380).fixedSize(horizontal:false,vertical:true).padding(.top,8)}
        Spacer(minLength:0)
    }}
    @ViewBuilder private var stepContent:some View {
        switch model.step {
        case .importChoices:importChoices
        case .secretsConsent:passwords
        case .importing:progress
        case .report:report
        case .defaultBrowser:defaultBrowser
        case .failed:failure
        case .welcome:EmptyView()
        }
    }
    private var importChoices:some View {VStack(alignment:.leading,spacing:10) {
        Text("Import from Arc").font(.title2)
        Text("Choose what to bring into Open. You can import again later from Settings. Nothing here changes your Arc data.").fixedSize(horizontal:false,vertical:true)
        ScrollView {VStack(alignment:.leading,spacing:10) {
            if model.probe?.sidebarFound == false {
                Text("No Arc data found at \(model.wizard.directoryDisplayPath).").font(.headline).fixedSize(horizontal:false,vertical:true)
                Text("Open looked for the files Arc keeps on this Mac and did not find them. You can pick a different folder, or start fresh.").foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                if model.arcIsRunning {Text("Arc is open right now. Open can still import. If anything is missing, quit Arc and import again from Settings.").font(section).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)}
                SettingsGroup {
                    choice("Spaces & tabs",help:"Spaces, pinned and today tabs, favorites, and folders. These come together.",found:model.found(model.probe?.spaces,singular:"Space",plural:"Spaces"),value:$model.includeSpacesAndTabs,height:62)
                    choice("Archive",help:"Tabs you closed or archived.",found:model.found(model.probe?.archiveItems,singular:"archived tab",plural:"archived tabs",present:model.probe?.archiveFound ?? false),value:$model.includeArchive,height:56)
                    choice("History",help:"Pages you visited. This can take a little longer. You can also do this later from Settings.",found:model.found(model.probe?.historyVisits,singular:"visit",plural:"visits",present:model.probe?.historyFound ?? false,partial:model.probe?.historyPartial ?? false),value:$model.includeHistory,height:62,last:true)
                }
                SettingsGroup {choice("Passwords and cookies",help:model.passwordsCopy.help,found:model.found(model.probe?.savedItems,singular:"saved item",plural:"saved items",present:model.probe?.secretsFound ?? false,partial:model.probe?.savedItemsPartial ?? false),value:$model.includeSecrets,height:74,last:true,enabled:model.wizard.canImportPasswordsAndCookies)}
                if model.probe?.sidebarFound == true && model.probe?.spaces == nil {Text("Open found the sidebar file, but could not count it. You can try the import or choose a different folder.").font(section).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)}
            }
        }.frame(maxWidth:.infinity,alignment:.leading)}.scrollIndicators(.automatic)
        HStack {
            Button("Back"){model.step = .welcome}
            if model.probe?.sidebarFound == true && model.probe?.spaces == nil {chooseFolder}
            Spacer(minLength:0)
            if model.probe?.sidebarFound == false {chooseFolder;primary("Start Fresh"){model.startFresh()}}
            else {Button("Not Now"){model.skipImport()};primary("Continue"){Task {await model.continueImport()}}.disabled(!model.hasSelection)}
        }.fixedSize(horizontal:false,vertical:true)
    }}
    private func choice(_ title:String,help:String,found:String,value:Binding<Bool>,height:CGFloat,last:Bool=false,enabled:Bool=true)->some View {
        SettingsRow(divider:!last,minimumHeight:height) {HStack(alignment:.top,spacing:8) {
            VStack(alignment:.leading,spacing:4) {Toggle(title,isOn:value).toggleStyle(.checkbox).disabled(!enabled);Text(help).font(section).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true).padding(.leading,21)}
            Spacer(minLength:0);Text(found).font(section).foregroundStyle(secondary).monospacedDigit().fixedSize().padding(.top,2)
        }}
    }
    private var chooseFolder:some View {Button("Choose Folder…") {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK,let directory=panel.url {Task {await model.choose(directory:directory)}}}}
    private func symbol(_ name:String)->some View {Image(systemName:name).font(.system(size:40)).foregroundStyle(secondary).frame(width:64,height:40)}
    private func sparse<V:View>(@ViewBuilder content:()->V)->some View {VStack(spacing:0) {Spacer(minLength:0);content().frame(width:SettingsTokens.firstRunSparseTextWidth);Spacer(minLength:0)}.frame(maxWidth:.infinity).multilineTextAlignment(.center)}
    private var passwords:some View {VStack(spacing:16) {
        sparse {
            VStack(spacing:8) {
                symbol("key.fill").padding(.bottom,8)
                Text(model.passwordsCopy.title).font(.title2)
                Text(model.passwordsCopy.body).fixedSize(horizontal:false,vertical:true)
                Text(PasswordsImportCopy.later).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
        HStack {Button("Cancel"){model.cancelPasswords()};Spacer(minLength:0)
            if model.wizard.canImportPasswordsAndCookies {Button(PasswordsImportCopy.skipButton){Task {await model.skipPasswords()}};primary(PasswordsImportCopy.allowButton){Task {await model.allowPasswords()}}}
            else {primary(PasswordsImportCopy.skipButton){Task {await model.skipPasswords()}}}
        }
    }}
    private var progress:some View {sparse {VStack(spacing:0) {
        brand.padding(.bottom,16)
        Text(model.phaseText).font(.headline).padding(.bottom,12)
        Group {if let value=model.progress {ProgressView(value:value)} else {ProgressView().progressViewStyle(.linear)}}.frame(width:320).accessibilityValue(model.phaseText)
        if model.browserHasLanded {Text("Your browser is ready. History is still importing in the background.").frame(width:SettingsTokens.firstRunSparseTextWidth).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true).padding(.top,12)}
    }}}
    private var report:some View {VStack(alignment:.leading,spacing:10) {
        Text("Import complete").font(.title2)
        ScrollView {VStack(alignment:.leading,spacing:10) {
            Text(model.reportSummary).fixedSize(horizontal:false,vertical:true)
            SettingsGroup {ForEach(Array(ImportWizardViewModel.reportCategories.enumerated()),id:\.element) {index,name in
                SettingsRow(height:30,divider:index != ImportWizardViewModel.reportCategories.count-1) {HStack {
                    Text(ImportCountCopy.displayCategory(name));Spacer();
                    Text(model.reportValue(name)).monospacedDigit().foregroundStyle(model.outcome?.failures[name] != nil ? Color.red:model.reportValue(name).contains("Not ") ? secondary:Color.primary)
                }}
            }}
            if let duplicates=model.duplicateSummary {Text(duplicates).font(section).foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)}
            ImportExtensionsSection(model:model.wizard.extensions) {Task {await model.wizard.installExtensions()}}
            if let note=model.reportNote {Text(note).font(section).foregroundStyle(model.reportNoteIsError ? Color.red:secondary).fixedSize(horizontal:false,vertical:true)}
        }.frame(maxWidth:.infinity,alignment:.leading)}.scrollIndicators(.automatic)
        HStack {Spacer();if model.errorText == FirstRunViewModel.importedSaveError {primary("Try Again"){model.actions.finishFirstRun(imported:true)}} else if model.errorText != nil && !model.wizard.hasImportedData {Button("Continue"){model.enterDefaultBrowser()};primary("Try Again"){model.showImport()}} else {primary("Continue"){model.enterDefaultBrowser()}}}.fixedSize(horizontal:false,vertical:true).disabled(model.wizard.extensions.isInstalling)
    }}
    private var defaultBrowser:some View {VStack(spacing:16) {
        sparse {VStack(spacing:8) {
            brand.padding(.bottom,8)
            Text("Make Open your default browser").font(.title2)
            Text("Links from other apps will open in Open. You can change this any time in Settings.").fixedSize(horizontal:false,vertical:true)
            Text("Little Open follows your link routing settings.").font(section).foregroundStyle(secondary)
            Group {
                if model.isDefaultBrowser {Text("Open is your default browser.").font(.headline)}
                else if let error=model.errorText {Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
                else if model.defaultWasAttempted {Text("Open is not your default browser yet. You can set it later in Settings.").foregroundStyle(secondary).fixedSize(horizontal:false,vertical:true)}
                else {Color.clear.accessibilityHidden(true)}
            }.frame(height:SettingsTokens.firstRunStatusHeight,alignment:.top)
        }}
        HStack {Spacer();if model.isDefaultBrowser {primary("Start Browsing"){model.finish()}} else {Button("Not Now"){model.finish()};primary("Make Open your default"){model.makeDefault()}}}
    }}
    private var failure:some View {VStack(spacing:16) {
        sparse {VStack(spacing:8) {
            symbol("exclamationmark.triangle.fill").padding(.bottom,8)
            Text("Open could not read your Arc data.").font(.title2)
            Text("The import stopped before it changed anything in Open. You can try again, or start fresh.").fixedSize(horizontal:false,vertical:true)
        }}
        HStack {Button("Back"){model.showImport()};Button("Start Fresh Instead"){model.startFresh()};Spacer();primary("Try Again"){Task {await model.continueImport()}}}
    }}
}
