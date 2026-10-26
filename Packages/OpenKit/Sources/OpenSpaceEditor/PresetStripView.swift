import AppKit
import OpenDesign
import OpenModel

@MainActor
public final class PresetStripView: NSView {
    public let previous = ThemeEditorButton(symbol: "chevron.left", label: "Previous color presets", pointSize: 16, weight: .semibold, glyphOffset: CGSize(width: 0, height: 1))
    public let next = ThemeEditorButton(symbol: "chevron.right", label: "Next color presets", pointSize: 16, weight: .semibold, glyphOffset: CGSize(width: 0, height: 1))
    public let viewport = NSView(frame: CGRect(x: 48, y: 0, width: 260, height: 32))
    public let swatches: [PresetSwatchView] = SpaceStylePresets.all.enumerated().map { PresetSwatchView(index: $0.offset, preset: $0.element) }
    public var renderScale: CGFloat = 1 { didSet { positionSwatches() } }
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
            strip.addSubview(swatch)
            swatch.onPress = { [weak self] in self?.onAction?(.selectPreset(index: i)) }
        }
        positionSwatches()
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
    private func positionSwatches() {
        let scale = Double(max(1, renderScale))
        for (i, swatch) in swatches.enumerated() {
            let x = Double(i / 9) * 265.5 + floor(Double(i % 9) * 29.5 * scale) / scale
            swatch.frame = CGRect(x: x, y: 4, width: 24, height: 24)
        }
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
        if index / SpaceStylePresets.swatchesPerPage == 1 {
            // Session 2 item 17 frame 0016: measured sRGB stops are facts;
            // this is our own axial gradient, with no copied pixels or disc.
            let stops: [[UInt32]] = [
                [0xD3D2CA, 0xD2D4CA, 0xD4CFCC],
                [0xD3939C, 0xD39D8E, 0xD293B1],
                [0x936882, 0x956874, 0x876984],
                [0xD37B5E, 0xCF9B57, 0xD37C8C],
                [0xDCA24E, 0xD3CC45, 0xE19274],
                [0xBCCA53, 0x95D652, 0xCAA25B],
                [0x35CCAA, 0x3FCACB, 0x5BCC98],
                [0x6D8EC3, 0x7375C3, 0x699DB6],
                [0x685E7D, 0x735D7C, 0x67687C],
            ]
            let gradient = CAGradientLayer(); gradient.frame = bounds
            gradient.colors = stops[index % 9].map { RGBA(hex: $0).cgColor }
            gradient.locations = [0, 0.5, 1]
            gradient.startPoint = CGPoint(x: 0.235, y: 0.235); gradient.endPoint = CGPoint(x: 0.765, y: 0.765)
            art.addSublayer(gradient)
        } else { art.backgroundColor = color(colors[0]) }
        rim.frame = bounds; rim.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        rim.fillColor = nil; rim.lineWidth = 2
        authoredRim = CGColor(gray: 0, alpha: 0.10); art.addSublayer(rim)
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
