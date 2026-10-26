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
        if let savedItems {return "Open found \(savedItems) saved items in Arc. Open didn't read or copy them."}
        return "Open didn't read or copy passwords or cookies. You can continue without them."
    }
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
    public var phaseText="Importing your spaces and tabs…"
    public var progress:Double?
    public var browserHasLanded=false
    public var errorText:String?
    public private(set) var isDefaultBrowser=false
    public private(set) var defaultWasAttempted=false
    public weak var actions:(any FirstRunActions)?
    public let wizard:ImportWizardViewModel
    // Retain the Settings owner: the shared wizard borrows it.
    private let settings:SettingsViewModel
    private var imported=false
    public init(settings:SettingsViewModel,actions:any FirstRunActions,directory:URL?=nil) {
        self.settings=settings;self.actions=actions
        wizard=ImportWizardViewModel(root:settings,directory:directory,actions:actions)
    }
    public var hasSelection:Bool {includeSpacesAndTabs || includeArchive || includeHistory || includeSecrets}
    public var outcome:ImportOutcome? {wizard.outcome}
    public var busy:Bool {wizard.isImporting || step == .importing}
    public var passwordsCopy:PasswordsImportCopy {.init(canImport:wizard.canImportPasswordsAndCookies,savedItems:probe?.secretsFound == false ? 0:probe?.savedItems)}
    public var welcomeStatus:String {
        guard let probe else {return "Checking for data to import…"}
        guard probe.sidebarFound else {return "No data found to import on this Mac."}
        guard let spaces=probe.spaces,let items=probe.sidebarItems else {return "Import data found. Choose what to bring into Open."}
        return "Found data to import: \(spaces) spaces, about \(items) tabs."
    }
    public func showImport() {errorText=nil;step = .importChoices}
    public func startFresh() {guard !busy else {return};actions?.finishFirstRun(imported:false)}
    public func skipImport() {guard !busy else {return};imported=false;enterDefaultBrowser()}
    public func enterDefaultBrowser() {step = .defaultBrowser;errorText=nil;defaultWasAttempted=false;isDefaultBrowser=actions?.isDefaultBrowser() ?? false}
    public func makeDefault() {
        guard step == .defaultBrowser,!isDefaultBrowser else {return}
        defaultWasAttempted=true
        if actions?.setAsDefaultBrowser() != nil {errorText="Open could not be set as your default browser. You can try again in Settings."}
        else {errorText=nil}
        isDefaultBrowser=actions?.isDefaultBrowser() ?? false
    }
    public func finish() {guard !busy else {return};actions?.finishFirstRun(imported:imported)}
    public func continueImport() async {
        guard [.importChoices,.failed].contains(step),hasSelection,!wizard.isImporting else {return}
        var plan=ImportPlan(directory:wizard.plan.directory)
        plan.spaces=includeSpacesAndTabs;plan.tabs=includeSpacesAndTabs;plan.favorites=includeSpacesAndTabs;plan.folders=includeSpacesAndTabs;plan.searchSettings=includeSpacesAndTabs
        plan.archive=includeArchive;plan.history=includeHistory;plan.secretsRequested=includeSecrets
        errorText=nil;phaseText=includeSpacesAndTabs ? "Importing your spaces and tabs…":includeArchive ? "Importing your archive…":includeHistory ? "Importing your history…":"Checking passwords and cookies…"
        step=includeSecrets ? .secretsConsent:.importing
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
        imported=outcome.counts["Spaces",default:0] > 0 || outcome.counts["Imported tabs",default:0] > 0 || outcome.counts["Archive",default:0] > 0 || outcome.counts["History",default:0] > 0
        errorText=outcome.errorText
        step=outcome.errorText != nil && !imported ? .failed:.report
    }
    public func choose(directory:URL) async {wizard.plan.directory=directory;probe=nil;await refreshProbe()}
    public func refreshProbe() async {
        await wizard.refreshCounts()
        guard !Task.isCancelled else {return}
        probe=wizard.probe
    }
    public func found(_ value:Int?,kind:String,present:Bool=true)->String {
        if probe == nil {return "Counting…"}
        guard let value else {return present ? "Could not be read":"Not found"}
        return "Found: \(value) \(kind)"
    }
}

public struct FirstRunView:View {
    @Bindable var model:FirstRunViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(model:FirstRunViewModel) {self.model=model}
    public var body:some View {
        Group {if model.step == .welcome {welcome} else {stepContent}}
            .padding(.horizontal,SettingsTokens.firstRunHorizontalInset).padding(.vertical,SettingsTokens.firstRunVerticalInset)
            .frame(width:FirstRunWindow.size.width,height:FirstRunWindow.size.height)
            .font(Font(SettingsTokens.label.font)).controlSize(.regular).buttonStyle(SettingsButtonStyle())
            .background(Color(nsColor:SettingsTokens.content.nsColor)).ignoresSafeArea()
            .animation(reduceMotion ? nil:.easeInOut(duration:Motion.selectionFade),value:model.step)
            .task {if model.probe == nil {await model.refreshProbe()}}
    }
    private var welcome:some View {VStack(spacing:0) {
        Spacer(minLength:0)
        OriginalOpenIcon(index:0).frame(width:SettingsTokens.firstRunIconSize,height:SettingsTokens.firstRunIconSize)
        // TODO(design): first-run wordmark token; system title until the design pass.
        Text("Open").font(.largeTitle).padding(.top,16)
        Text("Open is a fast, private browser that keeps your spaces, tabs, and history on this Mac.").multilineTextAlignment(.center).frame(maxWidth:SettingsTokens.firstRunIdentityWidth).fixedSize(horizontal:false,vertical:true).padding(.top,8)
        VStack(spacing:8) {Button {model.showImport()} label:{Text("Import from Arc").frame(width:SettingsTokens.firstRunButtonWidth-24)}.keyboardShortcut(.defaultAction);Button {model.startFresh()} label:{Text("Start fresh").frame(width:SettingsTokens.firstRunButtonWidth-24)}}.frame(width:SettingsTokens.firstRunButtonWidth).padding(.top,24)
        Text(model.welcomeStatus).font(.system(size:11)).foregroundStyle(Color(nsColor:SettingsTokens.secondary.nsColor)).multilineTextAlignment(.center).padding(.top,16)
        if let error=model.errorText {SettingsError(text:error).padding(.top,8)}
        Spacer(minLength:0)
    }}
    private var stepContent:some View {VStack(alignment:.leading,spacing:10) {
        Group {switch model.step {
        case .importChoices:importChoices
        case .secretsConsent:passwords
        case .importing:progress
        case .report:report
        case .defaultBrowser:defaultBrowser
        case .failed:failure
        case .welcome:EmptyView()
        }}.transition(.opacity)
    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}
    private var importChoices:some View {Group {
        Text("Import from Arc").font(.title2)
        Text("Choose what to bring into Open. You can import again later from Settings. Nothing here changes your Arc data.").fixedSize(horizontal:false,vertical:true)
        if model.probe?.sidebarFound == false {
            Spacer(minLength:0)
            Text("No Arc data found at \(model.wizard.directoryDisplayPath).").font(.headline).fixedSize(horizontal:false,vertical:true)
            Text("Open looked for the files Arc keeps on this Mac and did not find them. You can pick a different folder, or start fresh.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
            HStack {Button("Back"){model.step = .welcome};Spacer();chooseFolder;Button("Start fresh"){model.startFresh()}.keyboardShortcut(.defaultAction)}
        } else {
            if model.arcIsRunning {Text("Arc is open right now. Open can still import. If anything is missing, quit Arc and import again from Settings.").font(.system(size:11)).foregroundStyle(.secondary)}
            ScrollView {VStack(spacing:10) {
                SettingsGroup {
                    choice("Spaces & tabs",help:"Spaces, pinned and today tabs, favorites, and folders. These come together.",found:model.found(model.probe?.spaces,kind:"spaces"),value:$model.includeSpacesAndTabs,height:62)
                    choice("Archive",help:"Tabs you closed or archived.",found:model.found(model.probe?.archiveItems,kind:"archived tabs",present:model.probe?.archiveFound ?? false),value:$model.includeArchive,height:56)
                    choice("History",help:"Pages you visited. This can take a little longer. You can also do this later from Settings.",found:model.found(model.probe?.historyVisits,kind:"visits",present:model.probe?.historyFound ?? false),value:$model.includeHistory,height:62,last:true)
                }
                SettingsGroup("Passwords and cookies") {choice("Passwords and cookies",help:model.wizard.canImportPasswordsAndCookies ? "Saved passwords, cookies, addresses, and cards. macOS will ask for permission on the next step. You can also do this later from Settings.":"Passwords and cookies can't be imported yet. You can continue without them and import later from Settings.",found:model.found(model.probe?.savedItems,kind:"saved items",present:model.probe?.secretsFound ?? false),value:$model.includeSecrets,height:74,last:true)}
                if model.probe?.sidebarFound == true && model.probe?.spaces == nil {Text("Open found the sidebar file, but could not count it. You can try the import or choose a different folder.").font(.system(size:11)).foregroundStyle(.secondary)}
            }}.scrollIndicators(.hidden)
            HStack {Button("Back"){model.step = .welcome};Spacer();Button("Not now"){model.skipImport()};Button("Continue"){Task {await model.continueImport()}}.keyboardShortcut(.defaultAction).disabled(!model.hasSelection)}
        }
    }}
    private func choice(_ title:String,help:String,found:String,value:Binding<Bool>,height:CGFloat,last:Bool=false)->some View {
        SettingsRow(height:height,divider:!last) {HStack(alignment:.top,spacing:8) {
            VStack(alignment:.leading,spacing:4) {Toggle(title,isOn:value).toggleStyle(.checkbox);Text(help).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.leading,21)}
            Spacer(minLength:0);Text(found).font(.system(size:11)).foregroundStyle(.secondary).monospacedDigit().fixedSize().padding(.top,2)
        }}
    }
    private var chooseFolder:some View {Button("Choose Folder…") {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;if panel.runModal() == .OK,let directory=panel.url {Task {await model.choose(directory:directory)}}}}
    private var passwords:some View {Group {
        Text(model.passwordsCopy.title).font(.title2)
        Text(model.passwordsCopy.body).fixedSize(horizontal:false,vertical:true)
        Text("You can skip this step and do it later from Settings.").foregroundStyle(.secondary)
        Spacer(minLength:0)
        HStack {Button("Cancel"){model.cancelPasswords()};Spacer()
            if model.wizard.canImportPasswordsAndCookies {
                Button(PasswordsImportCopy.skipButton){Task {await model.skipPasswords()}}
                Button(PasswordsImportCopy.allowButton){Task {await model.allowPasswords()}}.keyboardShortcut(.defaultAction)
            } else {Button(PasswordsImportCopy.skipButton){Task {await model.skipPasswords()}}.keyboardShortcut(.defaultAction)}
        }
    }}
    private var progress:some View {Group {
        Spacer(minLength:0)
        Text(model.phaseText).font(.headline)
        if let progress=model.progress {ProgressView(value:progress)} else {ProgressView().progressViewStyle(.linear)}
        if model.browserHasLanded {Text("Your browser is ready. History is still importing in the background.").foregroundStyle(.secondary)}
        Spacer(minLength:0)
    }.accessibilityValue(model.phaseText)}
    private var report:some View {Group {
        Text("Import complete").font(.title2)
        Text("\(model.wizard.reportCount("Spaces")) spaces, \(model.wizard.reportCount("Imported tabs")) tabs, \(model.wizard.reportCount("Archive")) archived tabs imported.")
        SettingsGroup {ForEach(Array(ImportWizardViewModel.reportCategories.enumerated()),id:\.element) {index,name in SettingsRow(height:30,divider:index != ImportWizardViewModel.reportCategories.count-1) {HStack {Text(name);Spacer();Text("\(model.wizard.reportCount(name))").monospacedDigit()}}}}
        if !model.wizard.reportSkipped.isEmpty {Text(model.wizard.reportSkipped).font(.system(size:11)).foregroundStyle(.secondary)}
        if let count=model.outcome?.counts["Duplicates"],count>0 {Text("\(count) items were already in Open and were not copied again.").font(.system(size:11)).foregroundStyle(.secondary)}
        if model.wizard.passwordsWereNotImported {Text("Passwords and cookies were not imported.").font(.system(size:11)).foregroundStyle(.secondary)}
        ForEach((model.outcome?.failures ?? [:]).keys.sorted(),id:\.self) {kind in SettingsError(text:kind+": "+(model.outcome?.failures[kind] ?? ""))}
        if let error=model.errorText {SettingsError(text:error)}
        Spacer(minLength:0);HStack {Spacer();Button("Continue"){model.enterDefaultBrowser()}.keyboardShortcut(.defaultAction)}
    }}
    private var defaultBrowser:some View {Group {
        Text("Make Open your default browser").font(.title2)
        Text("Links from other apps will open in Open. You can change this any time in Settings.").fixedSize(horizontal:false,vertical:true)
        Text("Little Open follows your link routing settings.").font(.system(size:11)).foregroundStyle(.secondary)
        if model.isDefaultBrowser {Text("Open is your default browser.").font(.headline)}
        else if model.defaultWasAttempted {Text("Open is not your default browser yet. You can set it later in Settings.").foregroundStyle(.secondary)}
        if let error=model.errorText {SettingsError(text:error)}
        Spacer(minLength:0)
        HStack {Spacer();Button("Not now"){model.finish()}
            if model.isDefaultBrowser {Button("Open Open"){model.finish()}.keyboardShortcut(.defaultAction)}
            else {Button("Make Open My Default Browser"){model.makeDefault()}.keyboardShortcut(.defaultAction)}
        }
    }}
    private var failure:some View {Group {
        Text("Open could not read your Arc data.").font(.title2)
        Text("The import stopped before it changed anything in Open. You can try again, or start fresh.").fixedSize(horizontal:false,vertical:true)
        Spacer(minLength:0)
        HStack {Button("Start Fresh Instead"){model.startFresh()};Spacer();Button("Try Again"){Task {await model.continueImport()}}.keyboardShortcut(.defaultAction)}
    }}
}
