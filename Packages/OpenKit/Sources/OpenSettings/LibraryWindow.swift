import AppKit
import SwiftUI
import OpenDesign

public struct LibraryContent: View {
    @Bindable var viewModel: LibraryViewModel
    public init(viewModel: LibraryViewModel) { self.viewModel = viewModel }
    public var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(viewModel: viewModel).frame(width: 180)
            Divider()
            VStack(spacing: 18) {
                TextField("Search \(viewModel.section.title)", text: $viewModel.query).textFieldStyle(.roundedBorder)
                switch viewModel.section {
                case .archive: ArchiveSection(model: viewModel)
                case .downloads: DownloadsSection(model: viewModel)
                case .captures, .media: CapturesSection(model: viewModel)
                case .history: HistorySection(model: viewModel)
                }
                if !viewModel.statusText.isEmpty { HStack { Text(viewModel.statusText).font(.caption).foregroundStyle(.secondary); if let space = viewModel.restoredSpaceID { Button("View") { viewModel.actions.viewSpace(id: space) } }; Spacer() } }
            }.padding(24)

        }.font(Font(Typography.urlHost.font)).background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .task(id: viewModel.filterIdentity) { await viewModel.reload() }
    }
}
private struct LibrarySidebar: NSViewRepresentable {
    let viewModel: LibraryViewModel
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for section in LibrarySection.allCases {
            let button = LibrarySectionButton(title: section.title, image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)!, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.setAccessibilityLabel(section.title); button.isBordered = false; button.heightAnchor.constraint(equalToConstant: 32).isActive = true; button.widthAnchor.constraint(equalToConstant: 144).isActive = true; button.setButtonType(.toggle); button.identifier = .init(section.rawValue); stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(NSView()); stack.edgeInsets = NSEdgeInsets(top: 24, left: 18, bottom: 24, right: 18)
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) { for case let b as NSButton in stack.arrangedSubviews { b.state = b.identifier?.rawValue == viewModel.section.rawValue ? .on : .off; b.needsDisplay = true } }
    func makeCoordinator() -> Coordinator { Coordinator(viewModel) }
    @MainActor final class Coordinator: NSObject {
        let model: LibraryViewModel
        init(_ model: LibraryViewModel) { self.model = model }
        @objc func select(_ sender: NSButton) { model.section = LibrarySection(rawValue: sender.identifier!.rawValue)! }
    }
}
@MainActor public enum LibraryWindow {
    public static func makeWindow(viewModel: LibraryViewModel) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 618), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: LibraryContent(viewModel: viewModel)); window.title = "Library"; window.minSize = .init(width: 720, height: 480); window.isReleasedWhenClosed = false
        window.setFrame(.init(x: 200, y: 200, width: 960, height: 640), display: false)
        return window
    }
}
@MainActor public final class LibraryPresenter {
    public let viewModel: LibraryViewModel
    public private(set) var window: NSWindow?
    public init(viewModel: LibraryViewModel) { self.viewModel = viewModel }
    public func show(section: LibrarySection? = nil) { if let section { viewModel.section = section }; if window == nil { window = LibraryWindow.makeWindow(viewModel: viewModel) }; window?.makeKeyAndOrderFront(nil) }
}

private final class LibrarySectionButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on { Core.focusRing.nsColor.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: bounds, xRadius: URLFieldMetrics.cornerRadius, yRadius: URLFieldMetrics.cornerRadius).fill() }
        super.draw(dirtyRect)
    }
}
