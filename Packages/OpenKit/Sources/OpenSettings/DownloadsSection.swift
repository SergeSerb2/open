import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel

public struct DownloadsSection: View {
    @Bindable var model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 8) {
        if !model.downloads.downloadHistoryError.isEmpty {
            Text(model.downloads.downloadHistoryError).font(.caption).foregroundStyle(.secondary)
        }
        if model.downloadItems.isEmpty {
            LibraryEmptyState(title: "No downloads", message: "Files you download appear here.", symbol: "arrow.down.circle")
        } else {
            List(selection: $model.selectedIDs) {
                ForEach(model.downloadItems) { item in
                    DownloadRow(model: model, item: item).frame(height: 52).tag(item.id)
                        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                }
            }.listStyle(.plain)
        }
        }
    }
    /// Arc formatter facts: page-chrome §4, 0x101cdbc14 / 0x101cdd0e4.
    public static func subtitle(_ item: DownloadItemSnapshot, model: LibraryViewModel) -> String {
        switch item.state {
        case .failed: return "Failed to Download"
        case .completed:
            if item.isHistorical && item.fileExists == nil { return "Completed · \(model.downloadLocation(item))" }
            return model.fileAvailable(item) ? "Completed · \(model.downloadLocation(item))" : "File moved or deleted."
        case .cancelled: return "Cancelled"
        case .paused: return "Paused"
        case .inProgress:
            let bytes = ByteCountFormatter(); bytes.countStyle = .file
            var size = bytes.string(fromByteCount: item.receivedBytes)
            if let total = item.totalBytes {
                let totalText = bytes.string(fromByteCount: total)
                // Both use the same formatter. Remove only an identical unit suffix.
                if let unit = totalText.split(separator: " ").last, size.hasSuffix(" " + unit) { size.removeLast(unit.count + 1) }
                size += "/" + totalText
            }
            var parts = [size]
            if item.bytesPerSecond >= 0 { parts.append(bytes.string(fromByteCount: item.bytesPerSecond) + "/s") }
            if !item.sourceHost.isEmpty { parts.append("from " + item.sourceHost) }
            return parts.joined(separator: " · ")
        }
    }
}

private struct DownloadRow: NSViewRepresentable {
    let model: LibraryViewModel
    let item: DownloadItemSnapshot
    func makeNSView(context: Context) -> DownloadRowView { DownloadRowView(model: model, item: item) }
    func updateNSView(_ view: DownloadRowView, context: Context) { view.update(item) }
}

/// Native row controls and the actual context menu are also the automation
/// surface. The App harness presses these controls; it does not call an adapter
/// in their place. Row metrics preserve the existing Library row.
@MainActor
public final class DownloadRowView: NSView {
    private let model: LibraryViewModel
    public private(set) var item: DownloadItemSnapshot
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    public let subtitle = NSTextField(labelWithString: "")
    private let track = CALayer(), progress = CALayer()
    public private(set) var buttons: [NSButton] = []
    private var previousState: DownloadState?
    init(model: LibraryViewModel, item: DownloadItemSnapshot) {
        self.model = model; self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        for field in [title, subtitle] { field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; addSubview(field) }
        title.font = .systemFont(ofSize: 13); subtitle.font = .systemFont(ofSize: 11)
        addSubview(icon)
        for shape in [track, progress] { shape.cornerRadius = 1.5; layer?.addSublayer(shape) }
        update(item)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    func update(_ item: DownloadItemSnapshot) {
        self.item = item
        title.stringValue = item.fileName
        subtitle.stringValue = DownloadsSection.subtitle(item, model: model)
        subtitle.textColor = item.state == .failed ? .systemRed : .secondaryLabelColor
        icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(fileURLWithPath: item.fileName).pathExtension) ?? .data)
        if previousState != item.state {
            previousState = item.state
            buttons.forEach { $0.removeFromSuperview() }; buttons.removeAll()
            switch item.state {
            case .inProgress: addButton("pause.fill", "Pause"); addButton("xmark", "Cancel")
            case .paused: addButton("play.fill", "Resume"); addButton("xmark", "Cancel")
            case .failed: addButton("arrow.clockwise", "Retry")
            case .completed: addButton("magnifyingglass", "Show in Finder")
            case .cancelled: break
            }
        }
        buttons.forEach { $0.isEnabled = item.state != .completed || model.fileAvailable(item) }
        needsLayout = true
    }
    private func addButton(_ symbol: String, _ name: String) {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name)!, target: self, action: #selector(press(_:)))
        button.isBordered = false; button.toolTip = name; button.identifier = .init(name); button.setAccessibilityLabel(name)
        button.imageScaling = .scaleProportionallyDown
        buttons.append(button); addSubview(button)
    }
    @objc private func press(_ button: NSButton) {
        switch button.identifier?.rawValue {
        case "Pause": model.actions.pauseDownload(id: item.id)
        case "Resume": model.actions.resumeDownload(id: item.id)
        case "Cancel": model.actions.cancelDownload(id: item.id)
        case "Retry": model.retryDownload(item)
        case "Show in Finder": model.revealDownload(item)
        default: break
        }
    }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.frame = CGRect(x: 0, y: 10, width: 32, height: 32)
        let width = max(0, bounds.width - 44 - CGFloat(buttons.count) * 26 - 4)
        title.frame = CGRect(x: 44, y: 7, width: width, height: 17)
        subtitle.frame = CGRect(x: 44, y: 26, width: width, height: 14)
        for (index, button) in buttons.enumerated() { button.frame = CGRect(x: bounds.width - CGFloat(buttons.count - index) * 26, y: 16, width: 16, height: 20) }
        track.isHidden = item.state != .inProgress && item.state != .paused
        progress.isHidden = track.isHidden
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor; progress.backgroundColor = NSColor.controlAccentColor.cgColor
        track.frame = CGRect(x: 44, y: 44, width: width, height: 3)
        progress.frame = CGRect(x: 44, y: 44, width: width * (item.progress ?? 0.05), height: 3)
        CATransaction.commit()
    }
    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && item.state == .completed { model.revealDownload(item) }
        else { super.mouseDown(with: event) }
    }
    public override func menu(for event: NSEvent) -> NSMenu? { downloadMenu() }
    /// FACT order: page-chrome §4, menu builder 0x102eac4e8.
    public func downloadMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let type = UTType(filenameExtension: URL(fileURLWithPath: item.fileName).pathExtension)?.localizedDescription ?? "File"
        let available = item.state == .completed && model.fileAvailable(item)
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let entry = DownloadMenuItem(title: title, action: action); entry.isEnabled = enabled; menu.addItem(entry)
        }
        let id = item.id, actions = model.actions
        add("Open " + type, enabled: available) { actions.openDownload(id: id) }
        add("Copy " + type, enabled: available) { actions.copyDownload(id: id) }
        add("Show in Finder", enabled: available) { actions.revealDownload(id: id) }
        if item.state == .inProgress || item.state == .paused {
            menu.addItem(.separator()); add("Cancel Download") { actions.cancelDownload(id: id) }
        }
        menu.addItem(.separator()); add("Hide from Open") { actions.removeDownload(id: id) }
        if available { add("Move to Trash") { actions.trashDownload(id: id) } }
        if item.isHistorical { add("Retry") { actions.retryDownload(id: id) } }
        return menu
    }
}

@MainActor private final class DownloadMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
