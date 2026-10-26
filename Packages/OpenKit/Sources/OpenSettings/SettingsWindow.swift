import AppKit
import SwiftUI
import OpenDesign
import OpenModel

public struct SettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    let includesWindowTitle: Bool
    public init(viewModel: SettingsViewModel, includesWindowTitle: Bool = true) { self.viewModel = viewModel; self.includesWindowTitle = includesWindowTitle }
    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color(nsColor: SettingsTokens.band.nsColor)
                if includesWindowTitle { Text(viewModel.selectedPane.title).font(Font(SettingsTokens.title.font)).foregroundStyle(.secondary).frame(height: SettingsTokens.titleHeight) }
                SettingsTabBar(viewModel: viewModel).frame(height: SettingsTokens.bandHeight)
            }.frame(height: SettingsTokens.bandHeight)
            if viewModel.selectedPane == .shortcuts {
                ShortcutsPane(model: viewModel.shortcuts).padding(.horizontal, SettingsTokens.contentInset).padding(.top, 19)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: SettingsTokens.groupGap) {
                            switch viewModel.selectedPane {
                            case .general: GeneralPane(model: viewModel.general)
                            case .profiles: ProfilesPane(model: viewModel.profiles)
                            case .links: LinksPane(root: viewModel)
                            case .appIcon: AppIconPane(model: viewModel.appIcon)
                            case .advanced: AdvancedPane(model: viewModel.advanced)
                            case .shortcuts: EmptyView()
                            }
                        }.padding(.horizontal, SettingsTokens.contentInset).padding(.top, SettingsTokens.firstBoxGap).padding(.bottom, 20)
                    }.task(id:viewModel.scrollTarget) {
                        // Wait for the destination views to enter the laid-out scroll tree.
                        guard let target=viewModel.scrollTarget else {return}
                        await Task.yield()
                        proxy.scrollTo(target,anchor:.bottom)
                    }
                }
            }
        }.font(Font(SettingsTokens.label.font)).controlSize(.regular)
        .background(Color(nsColor: SettingsTokens.content.nsColor)).buttonStyle(SettingsButtonStyle()).ignoresSafeArea()
        .onChange(of: viewModel.model.spaces.map { "\($0.id)|\($0.profileID)|\($0.title ?? "")" }) { _, _ in viewModel.refreshLinks(preserveDrafts: true); viewModel.profiles.refresh() }
        .onChange(of: viewModel.model.profiles.map { "\($0.id)|\($0.name)" }) { _, _ in viewModel.profiles.refresh(); viewModel.adBlock?.refresh() }
        .sheet(isPresented: $viewModel.showsPreviews) { PreviewsSheet(model: viewModel.general) }
        .sheet(isPresented: $viewModel.showsSearchEngines) { SearchEnginesSheet(model: viewModel.profiles) }
        .sheet(isPresented: $viewModel.showsImport) { ImportWizard(root: viewModel) }
    }
}
private struct SettingsTabBar: NSViewRepresentable {
    let viewModel: SettingsViewModel
    func makeNSView(context: Context) -> TabBandView {
        let band = TabBandView()
        for pane in PaneID.allCases {
            let button = SettingsTabButton(title: pane.title, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.identifier = .init(pane.rawValue); button.symbol = pane.symbol
            button.setButtonType(.toggle); button.isBordered = false
            button.setAccessibilityLabel(pane.title); band.addSubview(button)
        }
        return band
    }
    func updateNSView(_ band: TabBandView, context: Context) {
        for case let button as SettingsTabButton in band.subviews {
            button.state = button.identifier?.rawValue == viewModel.selectedPane.rawValue ? .on : .off; button.needsDisplay = true
        }
        band.window?.title = viewModel.selectedPane.title
    }
    func makeCoordinator() -> Coordinator { Coordinator(viewModel) }
    @MainActor final class Coordinator: NSObject {
        let model: SettingsViewModel
        init(_ model: SettingsViewModel) { self.model = model }
        @objc func select(_ sender: NSButton) { if let id = sender.identifier, let pane = PaneID(rawValue: id.rawValue) { model.selectedPane = pane } }
    }
}
private final class TabBandView: NSView {
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let widths = subviews.compactMap { ($0 as? NSButton).map { max(54, ($0.title as NSString).size(withAttributes: [.font: SettingsTokens.tabLabel.font]).width + 13) } }
        var x = (bounds.width - widths.reduce(0,+) - CGFloat(max(0,widths.count-1))*3)/2
        for (view,width) in zip(subviews,widths) { view.frame = .init(x:x,y:34,width:width,height:45); x += width+3 }
    }
}
private final class SettingsTabButton: NSButton {
    var symbol = "gearshape"
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on { SettingsTokens.selectedTab.nsColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        let color = state == .on ? SettingsTokens.link.nsColor : NSColor.secondaryLabelColor
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        if let image {
            let tinted = NSImage(size:.init(width:20,height:20),flipped:false) { rect in
                image.draw(in:rect);color.setFill();rect.fill(using:.sourceAtop);return true
            }
            tinted.draw(in:.init(x:(bounds.width-20)/2,y:4,width:20,height:20),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: SettingsTokens.tabLabel.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: .init(x:(bounds.width-size.width)/2,y:34-size.height/2), withAttributes: attrs)
    }
}
@MainActor public enum SettingsWindow {
    public static func makeWindow(viewModel: SettingsViewModel) -> NSWindow {
        let window = NSWindow(contentRect: .init(x:0,y:0,width:684,height:650), styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView], backing:.buffered,defer:false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .visible
        window.backgroundColor = SettingsTokens.band.nsColor
        window.contentViewController = NSHostingController(rootView: SettingsContent(viewModel:viewModel,includesWindowTitle:false))
        window.setFrame(.init(x:200,y:200,width:684,height:650),display:false)
        window.title = viewModel.selectedPane.title; window.isReleasedWhenClosed = false; return window
    }
}
@MainActor public final class SettingsPresenter: NSObject, NSWindowDelegate {
    public let viewModel: SettingsViewModel
    public private(set) var window: NSWindow?
    public init(viewModel: SettingsViewModel) { self.viewModel=viewModel;super.init() }
    public func show(pane: PaneID? = nil) { if let pane { viewModel.selectedPane=pane }; if window == nil { window=SettingsWindow.makeWindow(viewModel:viewModel);window?.delegate=self }; viewModel.refreshExternalState();window?.makeKeyAndOrderFront(nil) }
    /// App calls before its first remote suggestion query. False means present and await the notice.
    @discardableResult public func prepareForRemoteSuggestions(profileID: OpenModel.ProfileID) -> Bool {
        viewModel.profiles.prepareForRemoteSuggestions(profileID:profileID)
    }
    /// Explicit presentation action. A query gate alone never changes Settings or opens a window.
    public func presentSearchSuggestionNotice(profileID:OpenModel.ProfileID) {
        viewModel.profiles.presentSuggestNotice(profileID:profileID)
        if viewModel.profiles.showsSuggestNotice {show(pane:.profiles)}
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
