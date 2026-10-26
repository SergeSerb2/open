import AppKit
import OpenDesign
import OpenModel

@MainActor
public final class ColorPadView: NSView {
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var state = ThemeEditorState()
    public private(set) var layoutPassCount = 0
    public var renderScale: CGFloat = 1 { didSet { refreshAppearance() } }
    public let emptyLabel = NSTextField(wrappingLabelWithString: "Tap to pick a color\nfor this space")
    private let dots = CALayer()
    private let knobs = (0..<3).map { _ in KnobLayers() }
    private var tracking: NSTrackingArea?
    private var draggingRelative = false
    private var pointerOnKnob = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 4; layer?.masksToBounds = true
        layer?.addSublayer(dots)
        for knob in knobs { layer?.addSublayer(knob.outer) }
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.alignment = .center; emptyLabel.maximumNumberOfLines = 2
        emptyLabel.setAccessibilityElement(false)
        addSubview(emptyLabel)
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Color")
        refreshAppearance()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    public override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); drawFocusRingMask() }
    }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func layout() {
        super.layout(); layoutPassCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dots.frame = bounds
        CATransaction.commit()
        emptyLabel.frame = CGRect(x: bounds.midX - 110, y: bounds.midY - 20, width: 220, height: 40)
        paintKnobs()
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }

    public func apply(_ state: ThemeEditorState) {
        self.state = state
        emptyLabel.isHidden = state.style != nil
        paintKnobs()
    }

    public var primaryKnobCenter: CGPoint? {
        state.knob.map { CGPoint(x: bounds.midX + $0.x * ThemeEditorMetrics.padRadius,
                                y: bounds.midY + $0.y * ThemeEditorMetrics.padRadius) }
    }
    public var primaryKnobFrame: CGRect? { primaryKnobCenter.map { CGRect(x: $0.x - 22, y: $0.y - 22, width: 44, height: 44) } }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - bounds.midX) / ThemeEditorMetrics.padRadius,
                y: (point.y - bounds.midY) / ThemeEditorMetrics.padRadius)
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        draggingRelative = primaryKnobCenter.map { hypot(point.x - $0.x, point.y - $0.y) <= 26 } ?? false
        onAction?(.dragKnob(to: unit(point), relative: draggingRelative))
    }
    public override func mouseDragged(with event: NSEvent) {
        onAction?(.dragKnob(to: unit(convert(event.locationInWindow, from: nil)), relative: draggingRelative))
    }
    public override func mouseUp(with event: NSEvent) { onAction?(.endDrag) }
    public override func keyDown(with event: NSEvent) {
        let shifted = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: onAction?(.keyboardHue(shifted ? -20 : -5))
        case 124: onAction?(.keyboardHue(shifted ? 20 : 5))
        case 126: onAction?(.keyboardRadius(shifted ? 0.1 : 0.03))
        case 125: onAction?(.keyboardRadius(shifted ? -0.1 : -0.03))
        default: super.keyDown(with: event)
        }
    }
    public override func accessibilityValue() -> Any? {
        guard let style = state.style else { return "No color" }
        let color = ThemeColorMath.hsl(ThemeColorMath.toP3(style.keyColor))
        return "Hue \(Int((color.h * 360).rounded()))°, lightness \(Int((color.l * 100).rounded())) %"
    }
    public override func accessibilityPerformIncrement() -> Bool { onAction?(.keyboardHue(5)); return state.style != nil }
    public override func accessibilityPerformDecrement() -> Bool { onAction?(.keyboardHue(-5)); return state.style != nil }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = primaryKnobCenter.map { hypot(point.x - $0.x, point.y - $0.y) <= 26 } ?? false
        if hovered != pointerOnKnob { pointerOnKnob = hovered; updateKnobScale() }
    }
    public override func mouseExited(with event: NSEvent) { pointerOnKnob = false; updateKnobScale() }

    public func refreshAppearance() {
        guard layer != nil else { return }
        let appearance = contentAppearance
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = ThemeEditorColors.padFill.cgColor(appearance)
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        layer?.borderColor = ThemeEditorColors.glyph.cgColor(appearance)
        dots.contents = DotGrid.image(appearance: appearance, scale: renderScale)
        dots.contentsScale = renderScale
        CATransaction.commit()
        emptyLabel.textColor = ThemeEditorColors.secondaryText.resolved(appearance).nsColor
        paintKnobs()
    }

    private func paintKnobs() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for knob in knobs { knob.outer.isHidden = true }
        if let style = state.style {
            let colors = ThemeColorMath.harmony(key: ThemeColorMath.toP3(style.keyColor), count: style.colorCount, wheel: style.wheel)
            for (index, color) in colors.enumerated() {
                let position = ThemeColorMath.knob(for: color, range: state.range)
                let size: CGFloat = index == 0 ? 44 : 30, ring: CGFloat = index == 0 ? 5 : 3
                let knob = knobs[index]
                knob.outer.isHidden = false
                knob.outer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                knob.outer.path = CGPath(ellipseIn: knob.outer.bounds, transform: nil)
                knob.outer.position = CGPoint(x: bounds.midX + position.x * 170, y: bounds.midY + position.y * 170)
                knob.outer.fillColor = CGColor(gray: 1, alpha: index == 0 ? 1 : 0.8)
                knob.inner.frame = knob.outer.bounds; knob.rim.frame = knob.outer.bounds
                knob.inner.path = CGPath(ellipseIn: knob.outer.bounds.insetBy(dx: ring, dy: ring), transform: nil)
                knob.inner.fillColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [color.r, color.g, color.b, 1])
                knob.rim.path = CGPath(ellipseIn: knob.outer.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
                knob.rim.fillColor = nil; knob.rim.lineWidth = 1
                knob.rim.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                    ? ThemeEditorColors.glyph.cgColor(contentAppearance)
                    : contentAppearance == .light ? CGColor(gray: 0, alpha: 0.12) : nil
                knob.outer.contentsScale = renderScale; knob.inner.contentsScale = renderScale; knob.rim.contentsScale = renderScale
            }
        }
        CATransaction.commit()
        updateKnobScale()
    }

    private func updateKnobScale() {
        let desired: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : state.isGestureInProgress ? 1.12 : pointerOnKnob ? 1.08 : 1
        let layer = knobs[0].outer
        let old = layer.transform.m11
        guard abs(old - desired) > 0.001 else { return }
        let animation: CABasicAnimation = state.isGestureInProgress ? CABasicAnimation(keyPath: "transform.scale") : Motion.editorKnobReturn.animation(keyPath: "transform.scale")
        animation.fromValue = layer.presentation()?.transform.m11 ?? old; animation.toValue = desired
        if state.isGestureInProgress { animation.duration = 0.12; animation.timingFunction = Motion.easeOut }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(desired, desired, 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer.add(animation, forKey: "knob-scale") }
        CATransaction.commit()
    }
}

@MainActor private final class KnobLayers {
    let outer = CAShapeLayer(), inner = CAShapeLayer(), rim = CAShapeLayer()
    init() { outer.addSublayer(inner); outer.addSublayer(rim) }
}

@MainActor private enum DotGrid {
    private static var cache: [String: CGImage] = [:]
    static func image(appearance: ContentAppearance, scale: CGFloat) -> CGImage {
        let key = "\(appearance.rawValue)-\(scale)"
        if let image = cache[key] { return image }
        let side = Int((340 * scale).rounded())
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(ThemeEditorColors.dot.cgColor(appearance))
        for y in stride(from: 2.125, to: 340.0, by: 4.25) {
            for x in stride(from: 2.125, to: 340.0, by: 4.25) { context.fillEllipse(in: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)) }
        }
        let image = context.makeImage()!; cache[key] = image; return image
    }
}
