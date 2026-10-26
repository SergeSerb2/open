import AppKit
import OpenDesign
import OpenModel

@MainActor
public final class NoiseDialView: NSView {
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public let centerButton = NoiseTextureButton(frame: CGRect(x: ThemeEditorMetrics.noiseCenter.x - 20, y: ThemeEditorMetrics.noiseCenter.y - 20, width: 40, height: 40))
    public private(set) var value = 0.0
    public private(set) var texture: SpaceStyleTexture = .grain
    public var enabled = true
    public var renderScale: CGFloat = 1 { didSet { updatePreview() } }
    public private(set) var layoutPassCount = 0
    public private(set) var previewCompositionCount = 0
    public var isTickVisible: Bool { !tick.isHidden }
    public var tickAngle: Double { value * 360 }
    public var tickCenter: CGPoint {
        let point = ringPoint(angle: tickAngle), scale = max(1, renderScale)
        return CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
    public var litDotCount: Int { guard enabled else { return 0 }; return (0..<20).filter { !hidden($0) && Double($0) * 18 <= tickAngle + 1e-9 }.count }
    public var hiddenDotIndices: [Int] { (0..<20).filter { hidden($0) } }
    private let dots = (0..<20).map { _ in CAShapeLayer() }
    private let tick = CAShapeLayer()
    private var previewKey: String?
    private let center = ThemeEditorMetrics.noiseCenter
    private var pressed = false
    private let scrollGesture = EditorScrollGesture()

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for dot in dots { layer?.addSublayer(dot) }; layer?.addSublayer(tick)
        addSubview(centerButton)
        centerButton.onPress = { [weak self] in if self?.enabled == true { self?.onAction?(.cycleTexture) } }
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Noise"); toolTip = "Noise"
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { enabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }
    public override func layout() { super.layout(); layoutPassCount += 1; refresh() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    public func apply(value: Double, texture: SpaceStyleTexture, enabled: Bool) {
        self.value = min(1, max(0, value)); self.texture = texture; self.enabled = enabled
        centerButton.enabled = enabled; centerButton.setAccessibilityValue(value == 0 ? "none" : texture.rawValue)
        refresh(); updatePreview()
    }
    public func ringPoint(angle: Double) -> CGPoint {
        CGPoint(x: center.x + ThemeEditorMetrics.noiseRadius * sin(angle * .pi / 180), y: center.y - ThemeEditorMetrics.noiseRadius * cos(angle * .pi / 180))
    }
    private func hidden(_ index: Int) -> Bool {
        // Lead decision: non-wrapping distance to 0…342°, half a slot tolerance.
        // At the exact endpoint the tick coincides with slot zero again.
        guard enabled else { return false }
        let angle = value == 1 ? 0 : tickAngle
        let nearest = min(19, max(0, Int((angle / 18).rounded())))
        return index == nearest && abs(Double(nearest) * 18 - angle) <= 9
    }
    private func refresh() {
        guard layer != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            if dot.path == nil {
                dot.bounds = CGRect(x: 0, y: 0, width: 4.5, height: 4.5)
                dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            }
            dot.position = ringPoint(angle: Double(index) * 18); dot.isHidden = hidden(index)
            dot.fillColor = (enabled && Double(index) * 18 <= tickAngle + 1e-9 ? ThemeEditorColors.dotLit : ThemeEditorColors.dotUnlit).cgColor(contentAppearance)
            dot.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
            dot.strokeColor = ThemeEditorColors.glyph.cgColor(contentAppearance)
        }
        if tick.path == nil {
            tick.bounds = CGRect(origin: .zero, size: ThemeEditorMetrics.noiseTickSize)
            tick.path = CGPath(roundedRect: tick.bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        }
        tick.isHidden = !enabled
        tick.position = tickCenter; tick.transform = CATransform3DMakeRotation(value * 2 * .pi, 0, 0, 1)
        tick.fillColor = ThemeEditorColors.thumb.cgColor(contentAppearance)
        tick.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance)
            : nil
        tick.lineWidth = 1
        centerButton.layer?.borderColor = (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph : ThemeEditorColors.dotUnlit).cgColor(contentAppearance)
        centerButton.preview.opacity = enabled && value > 0 ? 1 : 0
        CATransaction.commit()
    }
    private func updatePreview() {
        guard enabled, value > 0 else { return }
        let key = "\(texture.rawValue)-\(renderScale)"
        guard key != previewKey else { return }; previewKey = key
        previewCompositionCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        centerButton.preview.contents = ThemeTexture.knobPreview(texture, diameter: 40, scale: renderScale)
        centerButton.preview.contentsScale = renderScale
        CATransaction.commit()
    }
    private func angle(_ point: CGPoint) -> Double {
        let a = atan2(point.x - center.x, center.y - point.y) / (2 * .pi)
        return a < 0 ? a + 1 : a
    }
    public override func mouseDown(with event: NSEvent) {
        guard enabled else { return }; finishScrollGesture(); window?.makeFirstResponder(self); pressed = true
        let point = convert(event.locationInWindow, from: nil)
        if let dot = (0..<20).min(by: { a, b in
            let p = ringPoint(angle: Double(a) * 18), q = ringPoint(angle: Double(b) * 18)
            return hypot(point.x - p.x, point.y - p.y) < hypot(point.x - q.x, point.y - q.y)
        }), { let p = ringPoint(angle: Double(dot) * 18); return hypot(point.x - p.x, point.y - p.y) <= 3 }() {
            onAction?(.setNoise(Double(dot) * 0.05, final: false))
        } else { onAction?(.setNoise(angle(point), final: false)) }
    }
    public override func mouseDragged(with event: NSEvent) {
        guard enabled, pressed else { return }
        let raw = angle(convert(event.locationInWindow, from: nil))
        let target = abs(raw - value) > 0.5 ? (value < 0.5 ? 0.0 : 1.0) : raw
        onAction?(.setNoise(target, final: false))
    }
    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }; pressed = false; onAction?(.setNoise(value, final: true))
    }
    public override func scrollWheel(with event: NSEvent) { scroll(event, delta: Double(event.deltaY) * 0.01) }
    public override func rotate(with event: NSEvent) { scroll(event, delta: Double(event.rotation) / 360) }
    private func scroll(_ event: NSEvent, delta: Double) {
        guard enabled else { return }
        scrollGesture.update(event, change: { onAction?(.setNoise(value + delta, final: false)) },
                             finish: { [weak self] in guard let self else { return }; onAction?(.setNoise(value, final: true)) })
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
    public override func accessibilityPerformIncrement() -> Bool { guard enabled else { return false }; finishScrollGesture(); onAction?(.setNoise(value + 0.05, final: true)); return true }
    public override func accessibilityPerformDecrement() -> Bool { guard enabled else { return false }; finishScrollGesture(); onAction?(.setNoise(value - 0.05, final: true)); return true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 0)).fill() }
    public override func draw(_ dirtyRect: NSRect) { if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() } }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

@MainActor
public final class NoiseTextureButton: NSView {
    public var onPress: (@MainActor () -> Void)?
    public var enabled = true
    fileprivate let preview = CALayer()
    private var pressed = false
    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = 20; layer?.borderWidth = 1; layer?.masksToBounds = true
        preview.frame = bounds; preview.cornerRadius = 20; preview.masksToBounds = true; layer?.addSublayer(preview)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Cycle noise texture"); toolTip = "Cycle noise texture"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { enabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= 20 ? self : nil
    }
    public override func mouseDown(with event: NSEvent) { guard enabled else { return }; window?.makeFirstResponder(self); pressed = true }
    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }; pressed = false
        let point = convert(event.locationInWindow, from: nil)
        if enabled && hypot(point.x - bounds.midX, point.y - bounds.midY) <= 20 { onPress?() }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { if !event.isARepeat { _ = accessibilityPerformPress() } } else { super.keyDown(with: event) }
    }
    public override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; onPress?(); return true }
    public override func isAccessibilityEnabled() -> Bool { enabled }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }
    public override func draw(_ dirtyRect: NSRect) { if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() } }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}
