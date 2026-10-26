import AppKit
import SwiftUI
import OpenDesign

/// Account, AI and internal panes are deliberately absent from v1.
public struct SettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    public init(viewModel: SettingsViewModel) { self.viewModel = viewModel }
    public var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(viewModel: viewModel).frame(height: 82)
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    switch viewModel.selectedPane {
                    case .general: GeneralPane(model: viewModel.general)
                    case .profiles: ProfilesPane(model: viewModel.profiles)
                    case .appIcon: AppIconPane(model: viewModel.appIcon)
                    case .advanced: AdvancedPane(model: viewModel.advanced)
                    default: GroupBox(viewModel.selectedPane.title) { Text("Settings").frame(maxWidth: .infinity, minHeight: 80) }
                    }
                }.padding(.horizontal, 54).padding(.vertical, 24)
            }

        }.font(Font(Typography.urlHost.font)).background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $viewModel.showsPreviews) { PreviewsSheet(model: viewModel.general) }
        .sheet(isPresented: $viewModel.showsSearchEngines) { SearchEnginesSheet(model: viewModel.profiles) }
        .sheet(isPresented: $viewModel.showsImport) { ImportWizard(root: viewModel) }

    }
}
private struct SettingsTabBar: NSViewRepresentable {
    let viewModel: SettingsViewModel
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 8; stack.distribution = .fillEqually
        for pane in PaneID.allCases {
            let button = NSButton(title: pane.title, image: NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)!, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.imagePosition = .imageAbove; button.bezelStyle = .recessed; button.setButtonType(.toggle); button.identifier = .init(pane.rawValue)
            button.font = Typography.tooltipSubtitle.font
            stack.addArrangedSubview(button)
        }
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 66, bottom: 8, right: 66)
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        for case let button as NSButton in stack.arrangedSubviews { button.state = button.identifier?.rawValue == viewModel.selectedPane.rawValue ? .on : .off; button.contentTintColor = button.state == .on ? Core.focusRing.nsColor : .secondaryLabelColor }
        stack.window?.title = viewModel.selectedPane.title
    }
    func makeCoordinator() -> Coordinator { Coordinator(viewModel) }
    @MainActor final class Coordinator: NSObject {
        let model: SettingsViewModel
        init(_ model: SettingsViewModel) { self.model = model }
        @objc func select(_ sender: NSButton) { if let pane = PaneID(rawValue: sender.identifier!.rawValue) { model.selectedPane = pane } }
    }
}
@MainActor public enum SettingsWindow {
    public static func makeWindow(viewModel: SettingsViewModel) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 684, height: 628), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: SettingsContent(viewModel: viewModel))
        window.setFrame(.init(x: 200, y: 200, width: 684, height: 650), display: false)
        window.title = viewModel.selectedPane.title; window.isReleasedWhenClosed = false
        return window
    }
}
@MainActor public final class SettingsPresenter {
    public let viewModel: SettingsViewModel
    public private(set) var window: NSWindow?
    public init(viewModel: SettingsViewModel) { self.viewModel = viewModel }
    public func show(pane: PaneID? = nil) {
        if let pane { viewModel.selectedPane = pane }
        if window == nil { window = SettingsWindow.makeWindow(viewModel: viewModel) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { VStack(alignment: .leading, spacing: 8) {
        if !title.isEmpty { Text(title).font(Font(Typography.spaceTitle.font)).foregroundStyle(.secondary) }
        VStack(alignment: .leading, spacing: 12) { content }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Core.baseQuaternary.nsColor).opacity(0.3), in: RoundedRectangle(cornerRadius: URLFieldMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: URLFieldMetrics.cornerRadius).stroke(Color(nsColor: Core.baseQuaternary.nsColor)))
    } }
}
struct PreferenceToggle: View {
    let title: String
    let key: String
    let root: SettingsViewModel
    var body: some View { SettingsSwitch(title, isOn: Binding(get: { root.bool(key) }, set: { root.set($0, for: key) })) }
}
struct SettingsError: View {
    let text: String
    var body: some View { if !text.isEmpty { Text(text).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityLabel(text) } }
}

struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View { HStack { Text(title).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 12); Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }.accessibilityElement(children: .contain) }
}
