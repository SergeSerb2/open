import AppKit
import OpenDesign
import OpenModel

/// Open's own artwork and copy; Arc's exact Sad Tab copy/actions remain unverified (ST-1).
/// Created only while a renderer is gone. The host stays alive so Reload preserves its tab/history.
@MainActor
public final class SadTabView: NSView {
    public let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    public let closeButton = NSButton(title: "Close Tab", target: nil, action: nil)
    private let illustration = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "This page crashed")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "Something went wrong while showing this page.")
    public var style: SpaceThemeStyle { didSet { if style != oldValue { updateColors() } } }
    public var onReload: (() -> Void)?
    public var onClose: (() -> Void)?

    public init(style: SpaceThemeStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("sad-tab")
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(titleLabel.stringValue). \(bodyLabel.stringValue)")
        illustration.setAccessibilityElement(false)
        illustration.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 13)
        titleLabel.alignment = .center; bodyLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2; titleLabel.cell?.wraps = true
        titleLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 3; bodyLabel.lineBreakMode = .byWordWrapping
        for button in [reloadButton, closeButton] {
            button.bezelStyle = .rounded; button.controlSize = .regular; button.target = self
            button.setAccessibilityLabel(button.title)
            addSubview(button)
        }
        reloadButton.action = #selector(reloadPage)
        reloadButton.keyEquivalent = "\r"
        reloadButton.setAccessibilityIdentifier("sad-tab-reload")
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityIdentifier("sad-tab-close")
        for view in [illustration, titleLabel, bodyLabel] { addSubview(view) }
        setAccessibilityChildren([titleLabel, bodyLabel, reloadButton, closeButton])
        reloadButton.nextKeyView = closeButton; closeButton.nextKeyView = reloadButton
        updateColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    /// A split can contain several Sad Tabs. Return belongs to the focused one,
    /// including a Peek above a crashed pane; never let a background button reload it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isReturnOrEnter(event) {
            guard !isHiddenOrHasHiddenAncestor, let responder = window?.firstResponder as? NSView,
                  responder === self || responder.isDescendant(of: self) else { return false }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                reloadButton.performClick(nil); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    public override func keyDown(with event: NSEvent) {
        if isReturnOrEnter(event), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            reloadButton.performClick(nil)
        } else { super.keyDown(with: event) }
    }
    private func isReturnOrEnter(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}"
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        let system: ContentAppearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let appearance = style.resolvedAppearance(system: system)
        let palette = style.palette(for: appearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (palette?.background.nsColor ?? .textBackgroundColor).cgColor
        }
        titleLabel.textColor = palette?.foregroundPrimary.nsColor ?? .labelColor
        bodyLabel.textColor = palette?.foregroundSecondary.nsColor ?? .secondaryLabelColor
        reloadButton.bezelColor = style.accentColor(appearance).nsColor
        let symbol = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(paletteColors: [bodyLabel.textColor ?? .secondaryLabelColor]))
        illustration.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbol)
    }
    public override func layout() {
        super.layout()
        let width = max(0, min(440, bounds.width - 32)), x = bounds.midX - width / 2
        titleLabel.font = .systemFont(ofSize: bounds.width < 240 ? 17 : 20, weight: .semibold)
        func height(_ label: NSTextField) -> CGFloat {
            ceil(label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 1000)).height ?? label.fittingSize.height)
        }
        let titleHeight = height(titleLabel), bodyHeight = height(bodyLabel)
        let buttonHeight = max(28, max(reloadButton.fittingSize.height, closeButton.fittingSize.height))
        let total = 44 + 16 + titleHeight + 8 + bodyHeight + 24 + buttonHeight
        var y = max(16, bounds.midY - total / 2) + total
        y -= 44; illustration.frame = CGRect(x: bounds.midX - 22, y: y, width: 44, height: 44)
        y -= 16 + titleHeight; titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y -= 8 + bodyHeight; bodyLabel.frame = CGRect(x: x, y: y, width: width, height: bodyHeight)
        y -= 24 + buttonHeight
        let buttonWidth = min(100, max(0, (width - 12) / 2))
        reloadButton.frame = CGRect(x: bounds.midX - buttonWidth - 6, y: y, width: buttonWidth, height: buttonHeight)
        closeButton.frame = CGRect(x: bounds.midX + 6, y: y, width: buttonWidth, height: buttonHeight)
    }
    @objc private func reloadPage() { onReload?() }
    @objc private func closeTab() { onClose?() }
}
