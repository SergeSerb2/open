import SwiftUI
import AppKit

public struct CapturesSection: View {
    @Bindable var model: LibraryViewModel
    @State private var keyboard = CaptureGridKeyboardView(frame: .zero)
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 16) {
            if model.captures.loadFailed { LibraryEmptyState(title: "Captures could not be loaded.", message: "Open will try again next time you open the Library.", symbol: "camera") }
            else if model.captureItems.isEmpty { LibraryEmptyState(title: "No captures", message: "Captures you save in Open appear here.", symbol: "camera") }
            else {
                GeometryReader { geometry in
                ScrollViewReader { reader in
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 22) { ForEach(model.captureItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geometry in
                            ZStack {
                                RoundedRectangle(cornerRadius:8).fill(.quaternary)
                                if let image=model.thumbnailImages[item.id] {Image(nsImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:150).clipped()}
                                else {Image(systemName:"photo").foregroundStyle(.secondary)}
                            }.frame(width:geometry.size.width,height:150).clipShape(RoundedRectangle(cornerRadius:8))
                        }.frame(height:150).task {await model.loadThumbnail(item)}
                        Text(item.fileName).lineLimit(1)
                        Text("\(item.createdAt.formatted(.dateTime.month(.abbreviated).day())) · \(item.sourceHost)").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(10).background(model.selectedIDs.contains(item.id.uuidString) ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                    .background(CaptureCardAccessibility(label: metadata(item), selected: model.selectedIDs.contains(item.id.uuidString)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedIDs = [item.id.uuidString]; keyboard.window?.makeFirstResponder(keyboard) }
                    .onTapGesture(count: 2) { model.actions.openCapture(id: item.id) }
                    .id(item.id.uuidString)
                    .contextMenu { captureActions(item) }
                } } }
                .background(CaptureGridKeyboard(view: keyboard, model: model, columns: max(1, Int((geometry.size.width + 18) / 208))))
                .onChange(of: model.selectedIDs) { _, ids in if let id = ids.first { reader.scrollTo(id) } }
                }
                }
            }
        }.confirmationDialog("This will permanently delete your capture.", isPresented: Binding(get: { model.pendingCaptureDelete != nil }, set: { if !$0 { model.pendingCaptureDelete = nil } })) { Button("Delete Capture", role: .destructive) { model.deleteCaptureConfirmed() } }
    }
    private func kind(_ kind: CaptureKind) -> String { switch kind { case .area: "Capture"; case .fullPage: "Full Page"; case .portrait: "Portrait"; case .screenshot: "Screenshot" } }
    private func metadata(_ item: CaptureItemSnapshot) -> String {
        "\(item.fileName) · \(kind(item.kind)) · \(ByteCountFormatter.string(fromByteCount: model.captureBytes(item), countStyle: .file)) · \(item.sourceHost)"
    }
    @ViewBuilder private func captureActions(_ item: CaptureItemSnapshot) -> some View {
        Button("Open") { model.actions.openCapture(id: item.id) }
        Button("Copy Image") { model.actions.copyCapture(id: item.id) }
        Button("Save As…") { let panel = NSSavePanel(); panel.nameFieldStringValue = item.fileName; if panel.runModal() == .OK, let url = panel.url { model.saveCapture(item, to: url) } }
        Button("Show in Finder") { model.actions.revealCapture(id: item.id) }
        Button("Delete…", role: .destructive) { model.pendingCaptureDelete = item.id }
    }
}

/// As with Library's native empty-state headline, the native label is also
/// available to an in-process AX reader without a running screen reader.
private struct CaptureCardAccessibility: NSViewRepresentable {
    let label: String
    let selected: Bool
    func makeNSView(context: Context) -> CaptureCardAccessibilityView { CaptureCardAccessibilityView() }
    func updateNSView(_ view: CaptureCardAccessibilityView, context: Context) {
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(label); view.setAccessibilityValue(selected ? "Selected" : "")
        view.toolTip = label
    }
}
private final class CaptureCardAccessibilityView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct CaptureGridKeyboard: NSViewRepresentable {
    let view: CaptureGridKeyboardView
    let model: LibraryViewModel
    let columns: Int
    func makeNSView(context: Context) -> CaptureGridKeyboardView { view }
    func updateNSView(_ view: CaptureGridKeyboardView, context: Context) { view.model = model; view.columns = columns }
}

/// One native Tab stop for the grid. Events reach this responder through
/// NSApplication and the normal menu path; there is no global key monitor.
public final class CaptureGridKeyboardView: NSView, NSMenuItemValidation {
    weak var model: LibraryViewModel?
    public fileprivate(set) var columns = 1
    override public var acceptsFirstResponder: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func becomeFirstResponder() -> Bool {
        guard let model, !model.captureItems.isEmpty else { return false }
        if !model.captureItems.contains(where: { model.selectedIDs.contains($0.id.uuidString) }) {
            model.selectedIDs = [model.captureItems[0].id.uuidString]
        }
        return true
    }
    private var selected: CaptureItemSnapshot? { model?.captureItems.first { model?.selectedIDs.contains($0.id.uuidString) == true } }
    override public func keyDown(with event: NSEvent) {
        guard let model else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48 && (modifiers.isEmpty || modifiers == .shift) { // Keep Tab and Shift+Tab in the native key-view loop.
            if modifiers == .shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        }
        guard modifiers.isEmpty else { super.keyDown(with: event); return }
        let items = model.captureItems
        switch event.keyCode {
        case 123, 124, 125, 126:
            guard !items.isEmpty else { return }
            let current = items.firstIndex { model.selectedIDs.contains($0.id.uuidString) }
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            let index = current.map { min(items.count - 1, max(0, $0 + delta)) } ?? 0
            model.selectedIDs = [items[index].id.uuidString]
        case 36, 76: if let selected { model.actions.openCapture(id: selected.id) }
        case 51, 117: if let selected { model.pendingCaptureDelete = selected.id }
        case 49: break // Space has no capture action.
        default: super.keyDown(with: event)
        }
    }
    @objc public func copy(_ sender: Any?) { if let selected { model?.actions.copyCapture(id: selected.id) } }
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.action == #selector(copy(_:)) && selected != nil }
}
