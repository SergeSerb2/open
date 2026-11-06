import AppKit
import OpenDesign
import OpenWeb

public enum ExtensionPromptType: String, CaseIterable, Sendable {
    case install, externalInstall, remoteInstall, repair, permissions, reEnable, uninstall
}
public struct ExtensionPermissionMessage: Sendable {
    public var message: String
    public var details: [String]
    public init(_ message: String, details: [String] = []) { self.message = message; self.details = details }
}
@MainActor public protocol ExtensionPromptModel: AnyObject {
    var type: ExtensionPromptType { get }
    var extensionName: String { get }
    var icon: ExtensionImage? { get }
    var chromiumTitle: String { get }
    var chromiumAcceptLabel: String { get }
    var chromiumCancelLabel: String { get }
    var permissions: [ExtensionPermissionMessage] { get }
    var triggeringExtensionName: String? { get }
    func accept()
    func cancel()
}
public struct ExtensionPromptText: Equatable, Sendable {
    public let title: String
    public let accept: String
    public let cancel: String
    public let bodyHeading: String?
    @MainActor public init(_ model: any ExtensionPromptModel) {
        switch model.type {
        case .install, .externalInstall, .remoteInstall:
            title = "Add \(model.extensionName) extension to Open?"; accept = "Add Extension"; cancel = "Cancel"
        case .permissions, .reEnable:
            title = "The extension \(model.extensionName) has requested additional permissions"; accept = "Allow"; cancel = "Deny"
        case .repair:
            title = ExtensionsMenuBuilder.relabel(model.chromiumTitle)
            accept = ExtensionsMenuBuilder.relabel(model.chromiumAcceptLabel); cancel = ExtensionsMenuBuilder.relabel(model.chromiumCancelLabel)
        case .uninstall:
            title = model.triggeringExtensionName == nil ? "Remove \(model.extensionName) extension from Open?" : ExtensionsMenuBuilder.relabel(model.chromiumTitle)
            accept = "Remove Extension"; cancel = "Cancel"
        }
        bodyHeading = model.type == .repair || model.type == .uninstall ? nil : model.permissions.isEmpty
            ? "This extension requires no special permissions." : "It can:"
    }
}
@MainActor public final class ExtensionPromptView: NSView {
    public let text: ExtensionPromptText
    public let model: any ExtensionPromptModel
    public var onAnswer: ((Bool) -> Void)?
    public let acceptButton = NSButton(), cancelButton = NSButton()
    public let bodyScroll = NSScrollView()
    public private(set) var bodyHeight: CGFloat = 0
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public init(model: any ExtensionPromptModel) {
        self.model = model; text = ExtensionPromptText(model)
        super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = Core.popoverBackground.cgColor(contentAppearance)
        layer?.cornerRadius = ExtensionsMetrics.promptCornerRadius; layer?.cornerCurve = .continuous
        let title = Self.label(text.title, font: Typography.promptTitle.font)
        title.maximumNumberOfLines = 3
        // Use the native cell's line boxes, including its vertical inset.
        // NSString glyph bounds alone can clip the last line at 1x.
        let titleHeight = min(Self.height("A\nA\nA", width: 308, font: Typography.promptTitle.font),
            ceil(title.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: 308, height: 100000)).height))
        title.frame = CGRect(x: 88, y: 24, width: 308, height: titleHeight); addSubview(title)
        let top = max(72, 24 + titleHeight) + 16
        if let heading = text.bodyHeading {
            let document = PromptDocumentView()
            var y: CGFloat = 0
            func line(_ text: String, x: CGFloat, font: NSFont, secondary: Bool = false) {
                let label = Self.label(text, font: font, secondary: secondary)
                let h = Self.height(text, width: 372 - x, font: font)
                label.frame = CGRect(x: x, y: y, width: 372 - x, height: h); document.addSubview(label); y += h
            }
            line(heading, x: 0, font: model.permissions.isEmpty ? Typography.promptBody.font : .systemFont(ofSize: 13, weight: .semibold))
            if !model.permissions.isEmpty { y += 10 }
            for permission in model.permissions {
                let bullet = Self.label("•", font: Typography.promptBody.font)
                bullet.frame = CGRect(x: 4, y: y, width: 8, height: 18); document.addSubview(bullet)
                line(permission.message, x: 16, font: Typography.promptBody.font)
                for detail in permission.details { line(detail, x: 32, font: Typography.promptDetail.font, secondary: true) }
                y += 6
            }
            bodyHeight = y
            document.frame = CGRect(x: 0, y: 0, width: 372, height: y)
            bodyScroll.documentView = document; bodyScroll.drawsBackground = false
            bodyScroll.hasVerticalScroller = y > ExtensionsMetrics.promptBodyMaxHeight
            bodyScroll.autohidesScrollers = true; bodyScroll.borderType = .noBorder
            bodyScroll.frame = CGRect(x: 24, y: top, width: 372, height: min(y, ExtensionsMetrics.promptBodyMaxHeight))
            addSubview(bodyScroll)
        }
        let buttonY = (text.bodyHeading == nil ? max(72, 24 + titleHeight) : top + min(bodyHeight, 240)) + 24
        for (button, label, key) in [(cancelButton, text.cancel, "esc"), (acceptButton, text.accept, "↩")] {
            button.title = ""; button.isBordered = false; button.wantsLayer = true; button.layer?.cornerRadius = 8
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let string = NSMutableAttributedString(string: label + "  ", attributes: [.font: font, .foregroundColor: button === acceptButton ? NSColor.white : Core.foregroundPrimary.nsColor])
            string.append(NSAttributedString(string: key, attributes: [.font: Typography.keycap.font, .foregroundColor: (button === acceptButton ? NSColor.white : Core.foregroundPrimary.nsColor).withAlphaComponent(0.6)]))
            button.attributedTitle = string; button.setAccessibilityLabel(label)
            button.layer?.backgroundColor = (button === acceptButton ? Core.brandBlue : SidebarColors.itemBackground).cgColor(contentAppearance)
            button.frame.size = CGSize(width: max(88, ceil(string.size().width) + 24), height: 28)
            button.target = self; button.action = button === acceptButton ? #selector(accept) : #selector(cancel)
            addSubview(button)
        }
        acceptButton.frame.origin = CGPoint(x: 396 - acceptButton.frame.width, y: buttonY)
        cancelButton.frame.origin = CGPoint(x: acceptButton.frame.minX - 8 - cancelButton.frame.width, y: buttonY)
        frame.size = CGSize(width: 420, height: buttonY + 28 + 24)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private static func label(_ text: String, font: NSFont, secondary: Bool = false) -> NSTextField {
        let v = NSTextField(wrappingLabelWithString: text); v.font = font
        v.textColor = (secondary ? Core.foregroundSecondary : Core.foregroundPrimary).nsColor
        v.cell?.wraps = true; v.cell?.isScrollable = false; v.cell?.usesSingleLineMode = false
        v.lineBreakMode = .byWordWrapping; return v
    }
    fileprivate static func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text); cell.font = font
        cell.wraps = true; cell.isScrollable = false; cell.usesSingleLineMode = false
        cell.isBordered = false; cell.isBezeled = false; cell.lineBreakMode = .byWordWrapping
        return ceil(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 100000)).height)
    }
    public override func draw(_ dirtyRect: NSRect) {
        if let icon = model.icon { ExtensionActionButton.draw(icon, in: CGRect(x: 24, y: 24, width: 48, height: 48), scale: window?.backingScaleFactor ?? 2, interpolation: .high) }
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Core.popoverBackground.cgColor(contentAppearance)
        acceptButton.layer?.backgroundColor = Core.brandBlue.cgColor(contentAppearance)
        cancelButton.layer?.backgroundColor = SidebarColors.itemBackground.cgColor(contentAppearance)
    }
    @objc private func accept() { onAnswer?(true) }
    @objc private func cancel() { onAnswer?(false) }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { accept() }
        else if event.keyCode == 53 { cancel() }
        else { super.keyDown(with: event) }
    }
    public override func cancelOperation(_ sender: Any?) { cancel() }
}
// Flipped document view, declared here to keep the §8.1 file list exact.
@MainActor private final class PromptDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor public final class ExtensionPromptSheet: NSPanel {
    public let promptView: ExtensionPromptView
    public private(set) var answered = false
    public var onAnswered: (() -> Void)?
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public static func accepts(_ model: any ExtensionPromptModel) -> Bool {
        let strings = [model.extensionName, model.chromiumTitle, model.chromiumAcceptLabel, model.chromiumCancelLabel, model.triggeringExtensionName ?? ""]
        guard strings.allSatisfy({ $0.utf8.count <= 4096 }), model.permissions.count <= 256 else { return false }
        // <=1024 labels and <=256 KiB UTF-8 per sheet before text layout.
        // The largest single source string is 4096 bytes, far below allocator ceilings.
        var labels = 0, bytes = strings.reduce(0) { $0 + $1.utf8.count }
        var bodyHeight: CGFloat = 28
        for permission in model.permissions {
            guard permission.message.utf8.count <= 4096, permission.details.count <= 64,
                  permission.details.allSatisfy({ $0.utf8.count <= 4096 }) else { return false }
            labels += 1 + permission.details.count
            bytes += permission.message.utf8.count + permission.details.reduce(0) { $0 + $1.utf8.count }
            bodyHeight += ExtensionPromptView.height(permission.message, width: 356, font: Typography.promptBody.font) + 6
            for detail in permission.details { bodyHeight += ExtensionPromptView.height(detail, width: 340, font: Typography.promptDetail.font) }
            // Bound decoded layout too: <=372×16384 pt. At 2x RGBA the worst
            // single backing allocation is 97,517,568 bytes (<2^31−2MiB).
            guard labels <= 1024, bytes <= 262144, bodyHeight <= 16384 else { return false }
        }
        return true
    }
    public init?(model: any ExtensionPromptModel) {
        guard Self.accepts(model) else { model.cancel(); return nil }
        promptView = ExtensionPromptView(model: model)
        super.init(contentRect: CGRect(origin: .zero, size: promptView.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        contentView = promptView
        promptView.onAnswer = { [weak self] accepted in self?.answer(accepted) }
        initialFirstResponder = promptView
    }
    public func answer(_ accepted: Bool) {
        guard !answered else { return }; answered = true
        if accepted { promptView.model.accept() } else { promptView.model.cancel() }
        onAnswered?()
    }
    public override func close() { answer(false); super.close() }
    public override func cancelOperation(_ sender: Any?) { answer(false) }
    isolated deinit { if !answered { promptView.model.cancel() } }
}
/// One FIFO per browser window; App chooses a window/profile before enqueueing.
@MainActor public final class ExtensionPromptQueue {
    public private(set) var pending: [any ExtensionPromptModel] = []
    public private(set) var active: ExtensionPromptSheet?
    public var queuedCount: Int { pending.count + (active == nil ? 0 : 1) }
    private weak var window: NSWindow?
    private var closing = false
    private var observers: [any NSObjectProtocol] = []
    public init(window: NSWindow) {
        self.window = window
        for (name, object) in [(NSWindow.willCloseNotification, window as AnyObject), (NSApplication.willTerminateNotification, NSApplication.shared as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAll() }
            })
        }
    }
    public func enqueue(_ model: any ExtensionPromptModel) {
        // A repeated delivery of the same request must not answer it twice.
        guard active?.promptView.model !== model, !pending.contains(where: { $0 === model }) else { return }
        guard !closing, window != nil, queuedCount < 32, ExtensionPromptSheet.accepts(model) else { model.cancel(); return }
        pending.append(model); showNext()
    }
    private func showNext() {
        guard active == nil, !closing, !pending.isEmpty, let window else { return }
        let model = pending.removeFirst()
        guard let sheet = ExtensionPromptSheet(model: model) else { showNext(); return }
        active = sheet
        sheet.onAnswered = { [weak self, weak sheet] in
            guard let self, let sheet, self.active === sheet else { return }
            self.window?.endSheet(sheet); sheet.orderOut(nil)
            self.active = nil
            // End-sheet callbacks can reenter; start the next request on the next turn.
            DispatchQueue.main.async { [weak self] in self?.showNext() }
        }
        window.beginSheet(sheet)
        sheet.makeFirstResponder(sheet.promptView)
    }
    public func cancelAll() {
        closing = true
        let waiting = pending, sheet = active
        pending = []; active = nil
        if let sheet { sheet.onAnswered = nil; sheet.answer(false); window?.endSheet(sheet); sheet.orderOut(nil) }
        waiting.forEach { $0.cancel() }
    }
    isolated deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; cancelAll() }
}
