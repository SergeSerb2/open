import AppKit

public struct DialogSheetButton: Sendable {
    public enum Role: Sendable { case primary, cancel, leading }
    public let label: String
    public let role: Role
    public init(_ label: String, role: Role) { self.label = label; self.role = role }
}

// Visual guesses pending Arc capture S-1 (passwords-autofill §6.1): all sheet
// metrics, colors, typography, button order and the absence of an icon. These
// reuse ExtensionPromptView's design; that view adopts this component later.
public enum DialogSheetMetrics {
    public static let width: CGFloat = 420
    public static let padding: CGFloat = 24
    public static let cornerRadius = ExtensionsMetrics.promptCornerRadius
    public static let titleBodyGap: CGFloat = 8
    public static let bodyButtonGap: CGFloat = 20
    public static let buttonHeight: CGFloat = 28
    public static let buttonRadius: CGFloat = 8
    public static let buttonMinWidth: CGFloat = 88
    public static let buttonGap: CGFloat = 8
    public static var textWidth: CGFloat { width - 2 * padding }
}

@MainActor public final class DialogSheetView: NSView {
    public let titleLabel: NSTextField
    public let bodyLabel: NSTextField
    public let buttonModels: [DialogSheetButton]
    /// In visual/key-view order, left to right.
    public let buttons: [NSButton]
    public var onPress: ((DialogSheetButton.Role) -> Void)?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public var primaryButton: NSButton? { button(for: .primary) }
    public var cancelButton: NSButton? { button(for: .cancel) }

    public init(title: String, body: String, buttons: [DialogSheetButton]) {
        titleLabel = Self.label(title, font: Typography.promptTitle.font, lines: 2)
        bodyLabel = Self.label(body, font: Typography.promptBody.font, lines: 3)
        buttonModels = buttons
        self.buttons = buttons.map { _ in NSButton() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DialogSheetMetrics.cornerRadius; layer?.cornerCurve = .continuous
        titleLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        addSubview(titleLabel); addSubview(bodyLabel)
        let p = DialogSheetMetrics.padding, w = DialogSheetMetrics.textWidth
        titleLabel.frame = CGRect(x: p, y: p, width: w, height: Self.height(title, font: Typography.promptTitle.font, lines: 2))
        bodyLabel.frame = CGRect(x: p, y: titleLabel.frame.maxY + DialogSheetMetrics.titleBodyGap, width: w,
            height: Self.height(body, font: Typography.promptBody.font, lines: 3))
        let buttonY = bodyLabel.frame.maxY + DialogSheetMetrics.bodyButtonGap
        for (index, button) in self.buttons.enumerated() {
            let model = buttons[index]
            button.isBordered = false; button.wantsLayer = true
            button.layer?.cornerRadius = DialogSheetMetrics.buttonRadius
            button.title = model.label; button.setAccessibilityLabel(model.label)
            button.target = self; button.action = #selector(press(_:)); button.tag = index
            button.keyEquivalent = model.role == .primary ? "\r" : model.role == .cancel ? "\u{1b}" : ""
            button.keyEquivalentModifierMask = []
            addSubview(button)
        }
        refreshColors()
        var trailing = DialogSheetMetrics.width - p
        for (model, button) in zip(buttonModels, self.buttons).reversed() where model.role != .leading {
            button.frame.origin = CGPoint(x: trailing - button.frame.width, y: buttonY)
            trailing = button.frame.minX - DialogSheetMetrics.buttonGap
        }
        for (model, button) in zip(buttonModels, self.buttons) where model.role == .leading {
            button.frame.origin = CGPoint(x: p, y: buttonY)
        }
        for index in self.buttons.indices {
            self.buttons[index].nextKeyView = self.buttons[(index + 1) % self.buttons.count]
        }
        frame.size = CGSize(width: DialogSheetMetrics.width, height: buttonY + DialogSheetMetrics.buttonHeight + p)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func button(for role: DialogSheetButton.Role) -> NSButton? {
        buttonModels.firstIndex(where: { $0.role == role }).map { buttons[$0] }
    }
    private static func label(_ text: String, font: NSFont, lines: Int) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = font
        label.maximumNumberOfLines = lines
        label.cell?.wraps = true; label.cell?.isScrollable = false; label.cell?.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        return label
    }
    /// Native line boxes include the cell's inset, as in ExtensionPromptView.
    public static func textHeight(_ text: String, font: NSFont) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text); cell.font = font
        cell.wraps = true; cell.isScrollable = false; cell.usesSingleLineMode = false
        cell.isBordered = false; cell.isBezeled = false; cell.lineBreakMode = .byWordWrapping
        return ceil(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: DialogSheetMetrics.textWidth, height: 100000)).height)
    }
    private static func height(_ text: String, font: NSFont, lines: Int) -> CGFloat {
        min(textHeight(text, font: font), textHeight(Array(repeating: "A", count: lines).joined(separator: "\n"), font: font))
    }
    private func refreshColors() {
        layer?.backgroundColor = Core.popoverBackground.cgColor(contentAppearance)
        titleLabel.textColor = Core.foregroundPrimary.nsColor
        bodyLabel.textColor = Core.foregroundSecondary.nsColor
        for (model, button) in zip(buttonModels, buttons) {
            let foreground = model.role == .primary ? NSColor.white : Core.foregroundPrimary.nsColor
            let hint = model.role == .primary ? "↩" : model.role == .cancel ? "esc" : ""
            let title = NSMutableAttributedString(string: model.label + (hint.isEmpty ? "" : "  "),
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: foreground])
            title.append(NSAttributedString(string: hint, attributes: [.font: Typography.keycap.font,
                .foregroundColor: foreground.withAlphaComponent(0.6)]))
            button.attributedTitle = title
            button.layer?.backgroundColor = (model.role == .primary ? Core.brandBlue : SidebarColors.itemBackground).cgColor(contentAppearance)
            button.frame.size = CGSize(width: max(DialogSheetMetrics.buttonMinWidth, ceil(title.size().width) + 24), height: DialogSheetMetrics.buttonHeight)
        }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    @objc private func press(_ sender: NSButton) { onPress?(buttonModels[sender.tag].role) }
    public override func cancelOperation(_ sender: Any?) { cancelButton?.performClick(sender) }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { primaryButton?.performClick(nil) }
        else if event.keyCode == 53 { cancelButton?.performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

@MainActor open class DialogSheetPanel: NSPanel {
    public let dialogView: DialogSheetView
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public init(title: String, body: String, buttons: [DialogSheetButton]) {
        dialogView = DialogSheetView(title: title, body: body, buttons: buttons)
        super.init(contentRect: CGRect(origin: .zero, size: dialogView.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        contentView = dialogView
        initialFirstResponder = NSApp.isFullKeyboardAccessEnabled ? dialogView.buttons.first : dialogView
        autorecalculatesKeyViewLoop = false
        defaultButtonCell = dialogView.primaryButton?.cell as? NSButtonCell
        setAccessibilityRole(.sheet); setAccessibilityLabel(title)
        setAccessibilityDefaultButton(dialogView.primaryButton); setAccessibilityCancelButton(dialogView.cancelButton)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animationBehavior = .none }
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError() }
    public func announce() {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(title). \(dialogView.bodyLabel.stringValue)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            dialogView.primaryButton?.performClick(nil); return true
        }
        if modifiers.isEmpty, event.keyCode == 53 {
            dialogView.cancelButton?.performClick(nil); return true
        }
        if modifiers == .command,
           event.charactersIgnoringModifiers == "." {
            dialogView.cancelButton?.performClick(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    open override func cancelOperation(_ sender: Any?) { dialogView.cancelButton?.performClick(sender) }
}
