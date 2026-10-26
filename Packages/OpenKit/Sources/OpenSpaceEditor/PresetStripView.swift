import AppKit
import OpenDesign
import OpenModel

@MainActor
public final class PresetStripView: NSView {
    public let previous = ThemeEditorButton(symbol: "chevron.left", label: "Previous color presets", pointSize: 16)
    public let next = ThemeEditorButton(symbol: "chevron.right", label: "Next color presets", pointSize: 16)
    public let viewport = NSView(frame: CGRect(x: 48, y: 0, width: 260, height: 32))
    public let swatches: [PresetSwatchView] = SpaceStylePresets.all.enumerated().map { PresetSwatchView(index: $0.offset, preset: $0.element) }
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var page = 0
    private let strip = PresetFlippedView()
    private var scrollAmount: CGFloat = 0
    private var hasApplied = false

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        viewport.wantsLayer = true; viewport.layer?.masksToBounds = true
        strip.wantsLayer = true; viewport.addSubview(strip)
        addSubview(viewport); addSubview(previous); addSubview(next)
        previous.frame = CGRect(x: 9, y: 0, width: 32, height: 32)
        next.frame = CGRect(x: 315, y: 0, width: 32, height: 32)
        strip.frame = CGRect(x: 0, y: 0, width: 1322, height: 32)
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = CGRect(x: Double(i / 9) * 265.5 + Double(i % 9) * 29.5, y: 4, width: 24, height: 24)
            strip.addSubview(swatch)
            swatch.onPress = { [weak self] in self?.onAction?(.selectPreset(index: i)) }
        }
        previous.onPress = { [weak self] in guard let self else { return }; onAction?(.setPresetPage(page - 1)) }
        next.onPress = { [weak self] in guard let self else { return }; onAction?(.setPresetPage(page + 1)) }
        apply(page: 0)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public var visibleSwatches: [PresetSwatchView] { Array(swatches[(page * 9)..<(page * 9 + 9)]) }
    public func apply(page newPage: Int) {
        let newPage = min(4, max(0, newPage)), changed = page != newPage
        guard changed || !hasApplied else { return }; hasApplied = true
        let old = strip.layer?.presentation()?.position.x ?? strip.layer?.position.x
        page = newPage
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.setFrameOrigin(CGPoint(x: -Double(page) * 265.5, y: 0))
        CATransaction.commit()
        if changed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = strip.layer, let old {
            let animation = Motion.spaceSwitch.animation(keyPath: "position.x")
            animation.fromValue = old; animation.toValue = layer.position.x; layer.add(animation, forKey: "preset-page")
        }
        previous.enabled = page > 0; next.enabled = page < 4
        for (i, swatch) in swatches.enumerated() { swatch.setAccessibilityElement(i / 9 == page) }
    }
    public override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
        scrollAmount += event.scrollingDeltaX
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        if abs(scrollAmount) >= threshold {
            onAction?(.setPresetPage(page + (scrollAmount > 0 ? 1 : -1))); scrollAmount = 0
        }
        if event.phase == .ended || event.phase == .cancelled { scrollAmount = 0 }
    }
}

@MainActor
public final class PresetSwatchView: NSView {
    public let index: Int
    public var onPress: (@MainActor () -> Void)?
    public var forcedHover = false { didSet { updateScale() } }
    private let art = CALayer(), rim = CAShapeLayer()
    private var hovered = false, pressed = false
    private var tracking: NSTrackingArea?
    private var authoredRim: CGColor?

    init(index: Int, preset: SpaceStylePreset) {
        self.index = index
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24)); wantsLayer = true
        layer?.addSublayer(art); art.frame = bounds; art.cornerRadius = 12; art.masksToBounds = true
        let colors = ThemeColorMath.harmony(key: ThemeColorMath.toP3(preset.style.keyColor), count: preset.style.colorCount, wheel: preset.style.wheel)
        func color(_ c: P3) -> CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [c.r, c.g, c.b, 1])! }
        if colors.count == 3 {
            // Session 2 item 17 frame 0016: measured sRGB stops are facts;
            // this is our own axial gradient, with no copied pixels or disc.
            let stops: [[UInt32]] = [
                [0xD2D2CA, 0xD3D4CA, 0xC1BAB8],
                [0xD3939D, 0xD39D90, 0xBE85A7],
                [0x936883, 0x946874, 0x7A5E79],
                [0xD37B5E, 0xCE9A5B, 0xBF6B86],
                [0xDCA14E, 0xD4C949, 0xCC7A6D],
                [0xBCCA53, 0x99D352, 0xBD8A54],
                [0x34CCA9, 0x3FCAC8, 0x54B87F],
                [0x6D8EC3, 0x7376C3, 0x5D94A1],
                [0x685E7D, 0x735E7C, 0x59616F]
            ]
            let gradient = CAGradientLayer(); gradient.frame = bounds
            gradient.colors = stops[index % 9].map { RGBA(hex: $0).cgColor }
            gradient.locations = [0, 0.5, 1]
            gradient.startPoint = .zero; gradient.endPoint = CGPoint(x: 1, y: 1)
            art.addSublayer(gradient)
        } else { art.backgroundColor = color(colors[0]) }
        rim.frame = bounds; rim.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        rim.fillColor = nil; rim.lineWidth = 1
        let c = colors[0]; authoredRim = color(P3(c.r * 0.9, c.g * 0.9, c.b * 0.9)); art.addSublayer(rim)
        refreshContrast()
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Set Space color to \(preset.name)")
        toolTip = preset.name
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshContrast() }
    private func refreshContrast() {
        rim.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? ThemeEditorColors.glyph.cgColor(contentAppearance) : authoredRim
    }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() }
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; updateScale() }
    public override func mouseExited(with event: NSEvent) { hovered = false; updateScale() }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pressed = true; updateScale() }
    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }; pressed = false; updateScale()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { if !event.isARepeat { onPress?() } } else { super.keyDown(with: event) }
    }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    private func updateScale() {
        let scale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : pressed ? 0.9 : (hovered || forcedHover) ? 1.1 : 1
        let animation = CABasicAnimation(keyPath: "transform.scale"); animation.fromValue = art.presentation()?.transform.m11 ?? art.transform.m11
        animation.toValue = scale; animation.duration = 0.12; animation.timingFunction = Motion.easeOut
        CATransaction.begin(); CATransaction.setDisableActions(true); art.transform = CATransform3DMakeScale(scale, scale, 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { art.add(animation, forKey: "swatch-scale") }
        CATransaction.commit()
    }
}

@MainActor private final class PresetFlippedView: NSView { override var isFlipped: Bool { true } }
