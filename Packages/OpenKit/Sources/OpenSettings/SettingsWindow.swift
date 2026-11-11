import AppKit
import SwiftUI
import OpenDesign
import OpenModel

/// An active native recorder owns keys before the app's saved shortcuts.
/// Looking up the current responder does not construct Settings at launch.
@MainActor public protocol SettingsKeyCapturing: AnyObject {
    func captureSettingsKey(_ event: NSEvent) -> Bool
}

public struct SettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    public init(viewModel: SettingsViewModel, includesWindowTitle: Bool = true) { self.viewModel = viewModel }
    public var body: some View {
        HStack(spacing: 0) {
            SettingsNavigation(viewModel: viewModel, section: viewModel.selectedSection,
                query: viewModel.searchQuery, results: viewModel.searchResults, updateState: viewModel.updateState,
                focusRequest: viewModel.searchFocusRequest)
                .frame(width: SettingsTokens.Redesign.navigationWidth)
            Rectangle().fill(Color(nsColor: SettingsTokens.Redesign.hairline.nsColor)).frame(width: 1)
            SettingsDetail(root: viewModel)
        }
        .font(.system(size: 13)).foregroundStyle(Color(nsColor: SettingsTokens.Redesign.text.nsColor))
        .background(Color(nsColor: SettingsTokens.Redesign.background.nsColor)).ignoresSafeArea()
        .onChange(of: viewModel.model.spaces.map { "\($0.id)|\($0.profileID)|\($0.title ?? "")" }) { _, _ in viewModel.refreshLinks(preserveDrafts: true); viewModel.profiles.refresh() }
        .onChange(of: viewModel.model.profiles.map { "\($0.id)|\($0.name)" }) { _, _ in viewModel.profiles.refresh(); viewModel.adBlock?.refresh(); viewModel.refreshLinks(preserveDrafts: true) }
        .sheet(isPresented: $viewModel.showsPreviews) { PreviewsSheet(model: viewModel.general) }
        .sheet(isPresented: $viewModel.showsSearchEngines) { SearchEnginesSheet(model: viewModel.profiles) }
        .sheet(isPresented: $viewModel.showsImport) { ImportWizard(root: viewModel) }
        .sheet(isPresented: Binding(get: { viewModel.profiles.showsCreate }, set: { viewModel.profiles.showsCreate = $0 })) { ProfileNameSheet(model: viewModel.profiles, create: true) }
        .sheet(isPresented: Binding(get: { viewModel.profiles.showsRename }, set: { viewModel.profiles.showsRename = $0 })) { ProfileNameSheet(model: viewModel.profiles, create: false) }
        .sheet(isPresented: Binding(get: { viewModel.profiles.showsClear }, set: { viewModel.profiles.showsClear = $0 })) { ClearBrowsingDataSheet(model: viewModel.profiles) }
        .sheet(isPresented: Binding(get: { viewModel.profiles.confirmsDelete || viewModel.profiles.confirmsUnused }, set: { if !$0 { viewModel.profiles.confirmsDelete = false; viewModel.profiles.confirmsUnused = false } })) { ProfileDeleteSheet(model: viewModel.profiles) }
        .sheet(isPresented: $viewModel.showsControlsKit) { SettingsControlsKit(root: viewModel) }
        .sheet(isPresented: Binding(get: { viewModel.profiles.showsSuggestNotice }, set: { if !$0 { viewModel.profiles.showsSuggestNotice = false } })) { SuggestNoticeSheet(model: viewModel.profiles) }
    }
}

@MainActor private final class OpenSettingsWindow: NSWindow {
    let settings: SettingsViewModel
    init(settings: SettingsViewModel) {
        self.settings = settings
        super.init(contentRect: CGRect(origin: .zero, size: SettingsTokens.Redesign.window),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet != nil || settings.shortcuts.recordingCommandID != nil { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            if key == "f" { settings.searchFocusRequest &+= 1; return true }
            if key == "[" { settings.goBack(); return true }
            if key == "]" { settings.goForward(); return true }
            if let number = Int(key), (1...9).contains(number) { settings.navigate(to: SettingsSection.allCases[number - 1]); return true }
        }
        if flags == [.command, .option], key == "k", settings.selectedSection == .shortcuts {
            settings.shortcuts.findByKeys.toggle(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if settings.shortcuts.recordingCommandID != nil { settings.shortcuts.cancelRecording() }
        else if !settings.searchQuery.isEmpty { settings.searchQuery = "" }
        else { super.cancelOperation(sender) }
    }
}

@MainActor public enum SettingsWindow {
    public static func makeWindow(viewModel: SettingsViewModel) -> NSWindow {
        let window = OpenSettingsWindow(settings: viewModel)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.backgroundColor = SettingsTokens.Redesign.background.nsColor
        window.minSize = SettingsTokens.Redesign.minimum
        let hosting = NSHostingController(rootView: SettingsContent(viewModel: viewModel))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrame(NSRect(origin: window.frame.origin, size: SettingsTokens.Redesign.window), display: false)
        window.title = viewModel.selectedSection.title; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenSettingsRedesign")
        if !window.setFrameUsingName("OpenSettingsRedesign") { window.center() }
        return window
    }
}

@MainActor public final class SettingsPresenter: NSObject, NSWindowDelegate {
    public let viewModel: SettingsViewModel
    public private(set) var window: NSWindow?
    public private(set) var lastOpenMilliseconds = 0.0
    public init(viewModel: SettingsViewModel) { self.viewModel = viewModel; super.init() }
    public func show(pane: PaneID? = nil) {
        let start = ProcessInfo.processInfo.systemUptime
        if let pane { viewModel.selectedPane = pane; viewModel.selectedSection = .legacy(pane); viewModel.searchQuery = "" }
        if window == nil { window = SettingsWindow.makeWindow(viewModel: viewModel); window?.delegate = self }
        viewModel.refreshExternalState(); window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
        lastOpenMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
    @discardableResult public func prepareForRemoteSuggestions(profileID: OpenModel.ProfileID) -> Bool { viewModel.profiles.prepareForRemoteSuggestions(profileID: profileID) }
    public func presentSearchSuggestionNotice(profileID: OpenModel.ProfileID) {
        viewModel.profiles.presentSuggestNotice(profileID: profileID)
        if viewModel.profiles.showsSuggestNotice { viewModel.navigate(to: .search, row: "suggestions"); show() }
    }
    public func windowDidBecomeKey(_ notification: Notification) { viewModel.refreshExternalState() }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String = "", @ViewBuilder content: () -> Content) { self.title=title;self.content=content() }
    var body: some View { VStack(alignment:.leading,spacing:5) {
        if !title.isEmpty { Text(title).font(Font(SettingsTokens.section.font)).foregroundStyle(Color(nsColor:SettingsTokens.secondary.nsColor)).padding(.leading,10) }
        VStack(spacing:0) { content }.frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:SettingsTokens.fill.nsColor),in:RoundedRectangle(cornerRadius:SettingsTokens.radius))
            .overlay(RoundedRectangle(cornerRadius:SettingsTokens.radius).stroke(Color(nsColor:SettingsTokens.border.nsColor),lineWidth:1))
    } }
}
struct SettingsRow<Content: View>: View {
    var height: CGFloat = SettingsTokens.controlRowHeight
    var divider = true
    var minimumHeight:CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        Group {
            if let minimumHeight {content.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,10).frame(minHeight:minimumHeight)}
            else {content.frame(maxWidth:.infinity,alignment:.leading).frame(height:height)}
        }.padding(.horizontal,10)
            .overlay(alignment:.bottom) { if divider { Rectangle().fill(Color(nsColor:SettingsTokens.divider.nsColor)).frame(height:1).padding(.horizontal,10) } }
    }
}
struct PreferenceToggle: View {
    let title:String;let key:String;let root:SettingsViewModel
    var body:some View { SettingsSwitch(title,isOn:Binding(get:{root.bool(key)},set:{root.set($0,for:key)})) }
}
struct SettingsError:View { let text:String;var body:some View { if !text.isEmpty { Text(text).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true).accessibilityLabel(text) } } }
struct SettingsSwitch:View {
    let title:String;@Binding var isOn:Bool
    init(_ title:String,isOn:Binding<Bool>) { self.title=title;_isOn=isOn }
    var body:some View { HStack { Text(title).fixedSize(horizontal:false,vertical:true);Spacer(minLength:8);Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini) }.accessibilityElement(children:.contain) }
}

public struct SettingsButtonStyle:ButtonStyle {
    public init(prominent:Bool=false,height:CGFloat=24) {self.prominent=prominent;self.height=height}
    var prominent=false
    var height:CGFloat=24
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlActiveState) private var activeState
    private var highlighted:Bool {prominent && activeState == .key && enabled}
    public func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:13,weight:.regular)).padding(.horizontal,12).frame(height:height)
            .foregroundStyle(highlighted ? Color.white:Color.primary)
            .background((highlighted ? Color(nsColor:.controlAccentColor):Color(nsColor:SettingsTokens.button.nsColor)).opacity(configuration.isPressed ? 0.8:1),in:RoundedRectangle(cornerRadius:6))
            .opacity(enabled ? 1:0.45)
    }
}
