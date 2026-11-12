import AppKit

/// The floating tool bar at the canvas's bottom-left (capture s4 `e1-new-easel`,
/// C-measurements-s4): seven 36 × 36 pt buttons at a 38 pt pitch inside a white bar with a
/// 4 pt inset, a divider, then the add (split) button. Bar 44 pt tall.
@MainActor
final class EaselToolbarView: NSView {
    static let button: CGFloat = 36
    static let pitch: CGFloat = 38
    static let inset: CGFloat = 4
    /// Bar corner: GUESS from the 2× frame (≈ 10 pt) — capture pending.
    static let corner: CGFloat = 10
    static let dividerGap: CGFloat = 2
    static var size: CGSize {
        CGSize(width: inset + pitch * 7 - 2 + dividerGap * 2 + 1 + button + inset, height: button + inset * 2)
    }

    var selectedTool: EaselTool = .pointer { didSet { if oldValue != selectedTool { buttons.forEach { $0.needsDisplay = true } } } }
    var onSelect: ((EaselTool) -> Void)?
    var onAdd: (() -> Void)?
    private(set) var buttons: [EaselToolButton] = []
    private(set) var addButton: EaselToolButton!
    private let divider = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        layer?.cornerCurve = .continuous
        shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 6; s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor(white: 0, alpha: 0.08); return s
        }()
        for (i, tool) in EaselTool.allCases.enumerated() {
            let b = EaselToolButton(kind: .tool(tool), toolbar: self)
            b.frame = CGRect(x: Self.inset + CGFloat(i) * Self.pitch, y: Self.inset, width: Self.button, height: Self.button)
            buttons.append(b); addSubview(b)
        }
        let dividerX = Self.inset + Self.pitch * 7 - 2 + Self.dividerGap
        divider.frame = CGRect(x: dividerX, y: Self.inset + 4, width: 1, height: Self.button - 8)
        divider.wantsLayer = true
        addSubview(divider)
        addButton = EaselToolButton(kind: .add, toolbar: self)
        addButton.frame = CGRect(x: dividerX + 1 + Self.dividerGap, y: Self.inset, width: Self.button, height: Self.button)
        addSubview(addButton)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Easel Tools")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = EaselStyle.dark(effectiveAppearance)
        layer?.backgroundColor = EaselStyle.floating(dark: dark).cgColor
        divider.layer?.backgroundColor = EaselStyle.divider(dark: dark).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true; buttons.forEach { $0.needsDisplay = true }; addButton.needsDisplay = true
    }
    func button(_ tool: EaselTool) -> EaselToolButton? { buttons.first { if case .tool(tool) = $0.kind { true } else { false } } }
}

@MainActor
final class EaselToolButton: NSView {
    enum Kind { case tool(EaselTool), add }
    let kind: Kind
    private weak var toolbar: EaselToolbarView?
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }

    init(kind: Kind, toolbar: EaselToolbarView) {
        self.kind = kind; self.toolbar = toolbar
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        switch kind {
        case .tool(let t): setAccessibilityLabel(t.title)
        case .add: setAccessibilityLabel("Add Split View")
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var isSelectedTool: Bool { if case .tool(let t) = kind { toolbar?.selectedTool == t } else { false } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func press() {
        switch kind {
        case .tool(let t): toolbar?.onSelect?(t)
        case .add: toolbar?.onAdd?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = EaselStyle.dark(effectiveAppearance)
        let plate = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        let selected = isSelectedTool
        if selected { EaselStyle.toolPlate(dark: dark).setFill(); plate.fill() }
        else if hovered { EaselStyle.toolHover(dark: dark).setFill(); plate.fill() }
        let glyph = CGRect(x: 8, y: 8, width: 20, height: 20)
        let color = selected ? NSColor.white : EaselStyle.toolIcon(dark: dark)
        switch kind {
        case .tool(let t):
            EaselGlyphs.draw(t, in: glyph, color: color, onPlate: selected)
            if hovered, !selected, let letter = t.shortcut {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                            .foregroundColor: EaselStyle.toolIcon(dark: dark).withAlphaComponent(0.7)]
                let size = (letter as NSString).size(withAttributes: attrs)
                (letter as NSString).draw(at: CGPoint(x: bounds.maxX - size.width - 3, y: bounds.maxY - size.height - 1), withAttributes: attrs)
            }
        case .add: EaselGlyphs.drawAdd(in: glyph, color: color)
        }
    }
}
