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
    public var style: SpaceThemeStyle { didSet { updateColors() } }
    public var onReload: (() -> Void)?
    public var onClose: (() -> Void)?

    public init(style: SpaceThemeStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("sad-tab")
        illustration.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 13)
        titleLabel.alignment = .center; bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 2
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
        updateColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    /// A split can contain several Sad Tabs. Return belongs to the focused one,
    /// including a Peek above a crashed pane; never let a background button reload it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\r" {
            guard !isHiddenOrHasHiddenAncestor, let responder = window?.firstResponder as? NSView,
                  responder === self || responder.isDescendant(of: self) else { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            reloadButton.performClick(nil)
        } else { super.keyDown(with: event) }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        let system: ContentAppearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let appearance = style.resolvedAppearance(system: system)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (style.palette(for: appearance)?.background.nsColor ?? .textBackgroundColor).cgColor
        }
        titleLabel.textColor = style.titleColor(appearance).nsColor
        bodyLabel.textColor = titleLabel.textColor?.withAlphaComponent(0.65)
        let symbol = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(paletteColors: [bodyLabel.textColor ?? .secondaryLabelColor]))
        illustration.image = NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: "Page unavailable")?
            .withSymbolConfiguration(symbol)
    }
    public override func layout() {
        super.layout()
        let width = max(0, min(440, bounds.width - 32)), x = bounds.midX - width / 2
        let bottom = max(12, bounds.midY - 98)
        illustration.frame = CGRect(x: bounds.midX - 28, y: bottom + 140, width: 56, height: 56)
        titleLabel.frame = CGRect(x: x, y: bottom + 98, width: width, height: 28)
        bodyLabel.frame = CGRect(x: x, y: bottom + 50, width: width, height: 40)
        let buttonWidth = min(100, max(0, (width - 12) / 2))
        reloadButton.frame = CGRect(x: bounds.midX - buttonWidth - 6, y: bottom, width: buttonWidth, height: 32)
        closeButton.frame = CGRect(x: bounds.midX + 6, y: bottom, width: buttonWidth, height: 32)
    }
    @objc private func reloadPage() { onReload?() }
    @objc private func closeTab() { onClose?() }
}
