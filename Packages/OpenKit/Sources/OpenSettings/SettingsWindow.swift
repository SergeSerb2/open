import AppKit
import SwiftUI
import OpenDesign

/// Account, AI and internal panes are deliberately absent from v1.
public struct SettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    let includesWindowTitle: Bool
    public init(viewModel: SettingsViewModel, includesWindowTitle: Bool = true) { self.viewModel = viewModel; self.includesWindowTitle = includesWindowTitle }
    public var body: some View {
        VStack(spacing: 0) {
            if includesWindowTitle { PreviewWindowTitle(title: viewModel.selectedPane.title).frame(height: 22) }
            SettingsTabBar(viewModel: viewModel).frame(height: 66)
            Divider()
            ScrollViewReader { proxy in ScrollView {
                VStack(spacing: viewModel.selectedPane == .shortcuts ? 8 : 20) {
                    switch viewModel.selectedPane {
                    case .general: GeneralPane(model: viewModel.general)
                    case .shortcuts: ShortcutsPane(model: viewModel.shortcuts)
                    case .links: LinksPane(root: viewModel)
                    case .profiles: ProfilesPane(model: viewModel.profiles)
                    case .appIcon: AppIconPane(model: viewModel.appIcon)
                    case .advanced: AdvancedPane(model: viewModel.advanced)
                    }
                }.padding(.horizontal, 54).padding(.vertical, viewModel.selectedPane == .shortcuts ? 10 : 24)
            }.onAppear { if let target = viewModel.scrollTarget { proxy.scrollTo(target, anchor: .top) } }
             .onChange(of: viewModel.scrollTarget) { _, target in if let target { proxy.scrollTo(target, anchor: .top) } }
            }

        }.font(Font(Typography.urlHost.font)).background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: viewModel.model.spaces.map { "\($0.id)|\($0.profileID)|\($0.title ?? "")" }) { _, _ in viewModel.refreshLinks(preserveDrafts: true); viewModel.profiles.refresh() }
        .onChange(of: viewModel.model.profiles.map { "\($0.id)|\($0.name)" }) { _, _ in viewModel.profiles.refresh() }
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
            let button = SettingsTabButton(title: pane.title, image: NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)!, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.imagePosition = .imageAbove; button.isBordered = false; button.setButtonType(.toggle); button.identifier = .init(pane.rawValue)
            button.font = Typography.tooltipSubtitle.font
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: Typography.commandBarInput.size, weight: .regular))
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
            button.setAccessibilityLabel(pane.title)
            stack.addArrangedSubview(button)
        }
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 66, bottom: 4, right: 66)
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        for case let button as NSButton in stack.arrangedSubviews { button.state = button.identifier?.rawValue == viewModel.selectedPane.rawValue ? .on : .off; button.contentTintColor = button.state == .on ? Core.focusRing.nsColor : .secondaryLabelColor; button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: Typography.tooltipSubtitle.font, .foregroundColor: button.contentTintColor!]); button.needsDisplay = true }
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
        window.contentViewController = NSHostingController(rootView: SettingsContent(viewModel: viewModel, includesWindowTitle: false))
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

private struct PreviewWindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSTextField { let field = NSTextField(labelWithString: title); field.font = Typography.spaceTitle.font; field.alignment = .center; field.textColor = .secondaryLabelColor; return field }
    func updateNSView(_ field: NSTextField, context: Context) { field.stringValue = title }
}
private final class SettingsTabButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on { Core.focusRing.nsColor.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: URLFieldMetrics.cornerRadius, yRadius: URLFieldMetrics.cornerRadius).fill() }
        super.draw(dirtyRect)
    }
}
