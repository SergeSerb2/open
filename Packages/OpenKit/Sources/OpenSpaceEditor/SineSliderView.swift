import AppKit
import OpenDesign

@MainActor
public final class SineSliderView: NSView {
    public var onChange: (@MainActor (Double, Bool) -> Void)?
    public var enabled = true
    public private(set) var value: Double = 0.8
    public private(set) var layoutPassCount = 0
    public var isThumbVisible: Bool { !thumb.isHidden }
    public var waveAmplitude: Double { 14.4 * value }
    public var thumbSize: CGSize {
        if value <= 0.8 { return CGSize(width: 12.2 + 12.2 * value / 0.8, height: 44.4 + 11.6 * value / 0.8) }
        let t = (value - 0.8) / 0.2
        return CGSize(width: 24.4 + 2.65 * t, height: 56 + 3.15 * t)
    }
    public var thumbFrame: CGRect {
        CGRect(x: ThemeEditorMetrics.intensityThumbStart + ThemeEditorMetrics.intensityTravel * value - thumbSize.width / 2,
               y: 28 - thumbSize.height / 2, width: thumbSize.width, height: thumbSize.height)
    }
    private let track = CAShapeLayer(), inactive = CAShapeLayer(), active = CAShapeLayer(), thumb = CAShapeLayer()
    private let activeMask = CALayer(), inactiveMask = CALayer()
    private let scrollGesture = EditorScrollGesture()
    private var hovered = false, pressed = false
    private var tracking: NSTrackingArea?

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for layer in [track, inactive, active, thumb] { self.layer?.addSublayer(layer) }
        active.mask = activeMask; activeMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        inactive.mask = inactiveMask; inactiveMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        for wave in [inactive, active] { wave.fillColor = nil; wave.lineWidth = 4.5; wave.lineCap = .round; wave.lineJoin = .round }
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Intensity"); toolTip = "Intensity"
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { enabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }
    public override func layout() { super.layout(); layoutPassCount += 1; drawLayers() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    public func apply(value: Double, enabled: Bool) {
        self.enabled = enabled; self.value = value.isFinite ? min(1, max(0, value)) : 0
        drawValue()
    }
    private func drawLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [track, inactive, active] { layer.frame = bounds }
        track.path = CGPath(roundedRect: CGRect(x: 0, y: 20, width: 224, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)
        CATransaction.commit(); drawValue()
    }
    private func drawValue() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        for x in stride(from: 7.8, through: 216.2, by: 0.25) {
            let point = CGPoint(x: x, y: 28 - waveAmplitude * sin((x - 7.8) * 2 * .pi / 37.9))
            if x == 7.8 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.addLine(to: CGPoint(x: 216.2, y: 28))
        inactive.path = path; active.path = path; active.isHidden = !enabled; thumb.isHidden = !enabled
        thumb.bounds = CGRect(origin: .zero, size: thumbSize)
        thumb.path = CGPath(roundedRect: thumb.bounds, cornerWidth: thumbSize.width / 2, cornerHeight: thumbSize.width / 2, transform: nil)
        thumb.position = CGPoint(x: thumbFrame.midX, y: 28); thumb.shadowPath = thumb.path
        activeMask.frame = CGRect(x: 0, y: 0, width: thumbFrame.midX, height: 56)
        let split = enabled ? thumbFrame.midX : 0
        inactiveMask.frame = CGRect(x: split, y: 0, width: max(0, bounds.width - split), height: 56)
        CATransaction.commit(); updateScale()
    }
    private func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.fillColor = ThemeEditorColors.trackFill.cgColor(contentAppearance)
        track.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance) : nil
        track.lineWidth = 1
        inactive.strokeColor = ThemeEditorColors.waveInactive.cgColor(contentAppearance)
        active.strokeColor = ThemeEditorColors.waveActive.cgColor(contentAppearance)
        thumb.fillColor = ThemeEditorColors.thumb.cgColor(contentAppearance)
        thumb.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance) : nil
        thumb.lineWidth = 1
        thumb.shadowColor = CGColor(gray: contentAppearance == .light ? 0 : 1, alpha: 1)
        thumb.shadowOpacity = 0.06; thumb.shadowRadius = 2; thumb.shadowOffset = CGSize(width: 0, height: 2)
        CATransaction.commit()
    }
    private func updateScale() {
        let scale: CGFloat = enabled && (hovered || pressed) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.09 : 1
        guard abs(thumb.transform.m11 - scale) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = thumb.presentation()?.transform.m11 ?? thumb.transform.m11
        animation.toValue = scale; animation.duration = 0.12; animation.timingFunction = Motion.easeOut
        CATransaction.begin(); CATransaction.setDisableActions(true); thumb.transform = CATransform3DMakeScale(scale, scale, 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { thumb.add(animation, forKey: "thumb-scale") }
        CATransaction.commit()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -16, dy: -8), options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseMoved(with event: NSEvent) { hovered = thumbFrame.contains(convert(event.locationInWindow, from: nil)); updateScale() }
    public override func mouseExited(with event: NSEvent) { hovered = false; updateScale() }
    private func drag(_ event: NSEvent, final: Bool) {
        guard enabled else { return }; let point = convert(event.locationInWindow, from: nil)
        let target = min(1, max(0, (point.x - ThemeEditorMetrics.intensityThumbStart) / ThemeEditorMetrics.intensityTravel))
        // Preserve an exact stored value when drawing/input roundoff maps its
        // own center back to the same value. A stationary click has no undo.
        onChange?(abs(target - value) < 1e-12 ? value : target, final)
    }
    public override func mouseDown(with event: NSEvent) { guard enabled else { return }; finishScrollGesture(); window?.makeFirstResponder(self); pressed = true; drag(event, final: false) }
    public override func mouseDragged(with event: NSEvent) { drag(event, final: false) }
    public override func mouseUp(with event: NSEvent) { guard pressed else { return }; pressed = false; drag(event, final: true); hovered = thumbFrame.contains(convert(event.locationInWindow, from: nil)); updateScale() }
    public override func scrollWheel(with event: NSEvent) {
        guard enabled else { return }
        scrollGesture.update(event, change: { onChange?(value + Double(event.deltaY) * 0.02, false) },
                             finish: { [weak self] in guard let self else { return }; onChange?(value, true) })
    }
    public func finishScrollGesture() { scrollGesture.finish() }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { _ = accessibilityPerformDecrement() }
        else if event.keyCode == 124 { _ = accessibilityPerformIncrement() }
        else { super.keyDown(with: event) }
    }
    public override func accessibilityValue() -> Any? { value * 100 }
    public override func accessibilityMinValue() -> Any? { 0 }
    public override func accessibilityMaxValue() -> Any? { 100 }
    public override func isAccessibilityEnabled() -> Bool { enabled }
    public override func accessibilityPerformIncrement() -> Bool { guard enabled else { return false }; finishScrollGesture(); onChange?(value + 0.05, true); return true }
    public override func accessibilityPerformDecrement() -> Bool { guard enabled else { return false }; finishScrollGesture(); onChange?(value - 0.05, true); return true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    public override func draw(_ dirtyRect: NSRect) { if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() } }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}
