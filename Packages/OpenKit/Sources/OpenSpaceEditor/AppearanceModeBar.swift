import AppKit
import OpenDesign
import OpenModel
import Symbols

/// A code-drawn plate and system glyph. No image asset or SwiftUI hosting view.
@MainActor
public class ThemeEditorButton: NSView {
    public var onPress: (@MainActor () -> Void)?
    public var enabled = true { didSet { if enabled != oldValue { refresh() } } }
    public var selected = false { didSet { if selected != oldValue { refresh() } } }
    public var forcedHover = false { didSet { if forcedHover != oldValue { refresh() } } }
    public let glyphView: NSImageView = EditorGlyphView()
    private let plate = CALayer()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private let symbol: String
    private let pointSize: CGFloat
    private let glyphOffset: CGSize
    private let glyphColor: DesignColor?

    public init(symbol: String, label: String, pointSize: CGFloat = 13, glyphOffset: CGSize = .zero, glyphColor: DesignColor? = nil) {
        self.symbol = symbol; self.pointSize = pointSize; self.glyphOffset = glyphOffset; self.glyphColor = glyphColor
        super.init(frame: .zero)
        wantsLayer = true; layer?.addSublayer(plate)
        plate.cornerRadius = 8
        glyphView.imageScaling = .scaleNone
        glyphView.setAccessibilityElement(false)
        addSubview(glyphView)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label)
        toolTip = label
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { enabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() }
    }
    public override func layout() {
        super.layout(); plate.frame = bounds; glyphView.frame = bounds.offsetBy(dx: glyphOffset.width, dy: glyphOffset.height)
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) {
        hovered = true; refresh()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { glyphView.addSymbolEffect(.bounce) }
    }
    public override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    public override func mouseDown(with event: NSEvent) {
        guard enabled else { return }; window?.makeFirstResponder(self); pressed = true; refresh()
    }
    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }; pressed = false; refresh()
        if enabled && bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { if enabled && !event.isARepeat { onPress?() }; return }
        super.keyDown(with: event)
    }
    public override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; onPress?(); return true }
    public override func isAccessibilityEnabled() -> Bool { enabled }

    public func refresh() {
        guard layer != nil else { return }
        let appearance = contentAppearance
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plate.backgroundColor = (selected ? ThemeEditorColors.selectedPlate : ThemeEditorColors.hoverPlate).cgColor(appearance)
        plate.opacity = selected || ((hovered || forcedHover || pressed) && enabled) ? 1 : 0
        plate.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast && plate.opacity > 0 ? 1 : 0
        plate.borderColor = ThemeEditorColors.glyph.cgColor(appearance)
        CATransaction.commit()
        glyphView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        glyphView.contentTintColor = (glyphColor ?? (selected ? ThemeEditorColors.glyphSelected : ThemeEditorColors.glyph)).resolved(appearance).nsColor
        glyphView.needsDisplay = true
        glyphView.alphaValue = enabled ? 1 : 0.35
    }
}

@MainActor
public final class AppearanceModeBar: NSView {
    public let buttons: [ThemeEditorButton]
    public var onSelect: (@MainActor (SpaceStyleAppearance) -> Void)?
    public var mode: SpaceStyleAppearance = .automatic { didSet { if mode != oldValue { updateSelection() } } }
    private static let modes: [SpaceStyleAppearance] = [.automatic, .light, .dark]

    public override init(frame: NSRect) {
        buttons = zip(["sparkles", "sun.max.fill", "moon.stars.fill"], ["Automatic", "Light", "Dark"]).map {
            let button = ThemeEditorButton(symbol: $0.0, label: $0.1, pointSize: $0.0 == "moon.stars.fill" ? 16 : 15,
                                           glyphOffset: $0.0 == "sparkles" ? CGSize(width: 0, height: -1) : .zero)
            button.toolTip = "\($0.1) Appearance"; button.setAccessibilityRole(.radioButton)
            return button
        }
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Appearance")
        for (index, button) in buttons.enumerated() {
            addSubview(button); button.onPress = { [weak self] in self?.onSelect?(Self.modes[index]) }
        }
        updateSelection()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() { button.frame = CGRect(x: index * 40, y: 0, width: 32, height: 32) }
    }
    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            button.selected = Self.modes[index] == mode; button.setAccessibilityValue(button.selected ? 1 : 0)
        }
    }
}

@MainActor private final class EditorGlyphView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        context.saveGState(); context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor((contentTintColor ?? .labelColor).cgColor)
        context.fill(rect); context.endTransparencyLayer(); context.restoreGState()
    }
}
