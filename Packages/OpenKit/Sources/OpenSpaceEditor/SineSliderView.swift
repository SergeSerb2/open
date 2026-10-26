import AppKit
import OpenDesign

@MainActor
public final class SineSliderView: NSView {
    public var onChange: (@MainActor (Double, Bool) -> Void)?
    public var enabled = true
    public private(set) var value: Double = 0.8
    public private(set) var layoutPassCount = 0
    public var thumbFrame: CGRect { CGRect(x: 200 * value, y: 0, width: 24, height: 56) }
    private let track = CAShapeLayer(), inactive = CAShapeLayer(), active = CAShapeLayer(), thumb = CAShapeLayer()
    private let activeMask = CALayer()

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for layer in [track, inactive, active, thumb] { self.layer?.addSublayer(layer) }
        active.mask = activeMask; activeMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        for wave in [inactive, active] { wave.fillColor = nil; wave.lineWidth = 4.5; wave.lineCap = .round; wave.lineJoin = .round }
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Intensity"); toolTip = "Intensity"
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { enabled }
    public override func layout() { super.layout(); layoutPassCount += 1; drawLayers() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    public func apply(value: Double, enabled: Bool) {
        self.enabled = enabled; self.value = min(1, max(0, value))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.position = CGPoint(x: thumbFrame.midX, y: 28)
        activeMask.frame = CGRect(x: 0, y: 0, width: thumbFrame.midX, height: 56)
        CATransaction.commit()
    }
    private func drawLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [track, inactive, active] { layer.frame = bounds }
        track.path = CGPath(roundedRect: CGRect(x: 0, y: 20, width: 224, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)
        let path = CGMutablePath()
        for x in stride(from: 12.0, through: 212.0, by: 0.25) {
            let p = CGPoint(x: x, y: 28 + 13.75 * sin((x - 12) * 2 * .pi / 37.5))
            if x == 12 { path.move(to: p) } else { path.addLine(to: p) }
        }
        inactive.path = path; active.path = path
        thumb.bounds = CGRect(x: 0, y: 0, width: 24, height: 56)
        thumb.path = CGPath(roundedRect: thumb.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        thumb.shadowColor = CGColor(gray: 0, alpha: 1); thumb.shadowOpacity = 0.2; thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 1); thumb.shadowPath = thumb.path
        CATransaction.commit(); apply(value: value, enabled: enabled)
    }
    private func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.fillColor = ThemeEditorColors.trackFill.cgColor(contentAppearance)
        track.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance) : nil
        track.lineWidth = 1
        inactive.strokeColor = ThemeEditorColors.waveInactive.cgColor(contentAppearance)
        active.strokeColor = ThemeEditorColors.waveActive.cgColor(contentAppearance)
        thumb.fillColor = ThemeEditorColors.thumb.cgColor(contentAppearance)
        thumb.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance)
            : contentAppearance == .light ? CGColor(gray: 0, alpha: 0.12) : nil
        thumb.lineWidth = 1
        CATransaction.commit()
    }
    private func drag(_ event: NSEvent, final: Bool) {
        guard enabled else { return }; let point = convert(event.locationInWindow, from: nil)
        onChange?(min(1, max(0, (point.x - 12) / 200)), final)
    }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); drag(event, final: false) }
    public override func mouseDragged(with event: NSEvent) { drag(event, final: false) }
    public override func mouseUp(with event: NSEvent) { drag(event, final: true) }
    public override func scrollWheel(with event: NSEvent) { if enabled { onChange?(value + Double(event.deltaY) * 0.02, true) } }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { _ = accessibilityPerformDecrement() }
        else if event.keyCode == 124 { _ = accessibilityPerformIncrement() }
        else { super.keyDown(with: event) }
    }
    public override func accessibilityValue() -> Any? { value * 100 }
    public override func accessibilityMinValue() -> Any? { 0 }
    public override func accessibilityMaxValue() -> Any? { 100 }
    public override func isAccessibilityEnabled() -> Bool { enabled }
    public override func accessibilityPerformIncrement() -> Bool { guard enabled else { return false }; onChange?(value + 0.05, true); return true }
    public override func accessibilityPerformDecrement() -> Bool { guard enabled else { return false }; onChange?(value - 0.05, true); return true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    public override func draw(_ dirtyRect: NSRect) { if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() } }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}
