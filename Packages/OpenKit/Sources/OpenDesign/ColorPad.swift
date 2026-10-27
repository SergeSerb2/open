import AppKit

public struct ColorPadKnob {
    public let position: CGPoint
    public let fill: CGColor
    public init(position: CGPoint,fill: CGColor) { self.position = position; self.fill = fill }
}
@MainActor public protocol ColorPadLaw {
    associatedtype State
    associatedtype Value
    func knobs(for state: State) -> [ColorPadKnob]
    func value(at unitPoint: CGPoint,relative: Bool) -> Value
}
public enum ColorPadInput {
    case beginDrag(CGPoint,Bool),endDrag
    case beginKeyboardGesture,endKeyboardGesture,keyboardHue(Double),keyboardRadius(Double)
}
@MainActor public struct ColorPadStyle {
    public var radius: CGFloat = 170
    public var cornerRadius: CGFloat = 4
    public var clipsKnobs = true
    public var primarySize: CGFloat = 44,secondarySize: CGFloat = 27
    public var primaryRing: CGFloat = 5,secondaryRing: CGFloat = 3
    public var dotPitch: CGFloat = 4.25
    public var dragScale: CGFloat = 1.136,hoverScale: CGFloat = 1.09,secondaryActiveScale: CGFloat = 30.0/27
    public var returnSpring = Motion.editorKnobReturn
    public var keyboardFocusOnly = false
    public var focusOnMouseDown = true
    public var fill: (ContentAppearance) -> CGColor = { ThemeEditorColors.padFill.cgColor($0) }
    public var dotColor: (ContentAppearance) -> CGColor = { ThemeEditorColors.dot.cgColor($0) }
    public var contrastColor: (ContentAppearance) -> CGColor = { ThemeEditorColors.glyph.cgColor($0) }
    public static var theme: ColorPadStyle { ColorPadStyle() }
}


@MainActor
open class ColorPadView: NSView {
    public var onInput: (@MainActor (ColorPadInput) -> Void)?
    public var onPoint: (@MainActor (CGPoint,Bool) -> Void)?
    public private(set) var layoutPassCount = 0
    public var renderScale: CGFloat = 1 { didSet { refreshAppearance() } }
    public var showsKeyboardFocus = false { didSet { needsDisplay = true } }
    public var interactionEnabled = true
    public let style: ColorPadStyle
    public private(set) var isGestureInProgress = false
    private var values: [ColorPadKnob] = []
    private var arrowKeys: Set<UInt16> = []
    private let dots = CALayer()
    private let knobs = (0..<3).map { _ in KnobLayers() }
    private var tracking: NSTrackingArea?
    private var draggingRelative = false
    private var pointerOnKnob = false

    public override init(frame: NSRect) { style = .theme; super.init(frame: frame); setup() }
    public init(frame: NSRect,style: ColorPadStyle) { self.style = style; super.init(frame: frame); setup() }
    private func setup() {
        wantsLayer = true; layer?.cornerRadius = style.cornerRadius; layer?.masksToBounds = style.clipsKnobs
        layer?.addSublayer(dots)
        for knob in knobs.reversed() { layer?.addSublayer(knob.outer) }
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Color")
        refreshAppearance()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    open override var isFlipped: Bool { true }
    open override var acceptsFirstResponder: Bool { interactionEnabled }
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    open override var focusRingMaskBounds: NSRect { bounds }
    open override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: style.cornerRadius, yRadius: style.cornerRadius).fill() }
    open override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self && (!style.keyboardFocusOnly || showsKeyboardFocus) { NSFocusRingPlacement.only.set(); drawFocusRingMask() }
    }
    open override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    open override func resignFirstResponder() -> Bool {
        finishKeyboardGesture()
        needsDisplay = true; return true
    }
    public func finishKeyboardGesture() {
        if !arrowKeys.isEmpty { arrowKeys.removeAll(); onInput?(.endKeyboardGesture) }
    }
    open override func layout() {
        super.layout(); layoutPassCount += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dots.frame = bounds
        CATransaction.commit()
        paintKnobs()
    }
    open override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }

    public func apply<Law: ColorPadLaw>(_ state: Law.State,law: Law,gestureInProgress: Bool,onValue: @escaping @MainActor (Law.Value) -> Void) {
        values = Array(law.knobs(for: state).prefix(3)); isGestureInProgress = gestureInProgress
        onPoint = { point,relative in onValue(law.value(at: point,relative: relative)) }
        paintKnobs()
    }
    public var primaryKnobCenter: CGPoint? {
        values.first.map { CGPoint(x: bounds.midX + $0.position.x * style.radius,y: bounds.midY + $0.position.y * style.radius) }
    }
    public var primaryKnobFrame: CGRect? { primaryKnobCenter.map { CGRect(x: $0.x-style.primarySize/2,y: $0.y-style.primarySize/2,width: style.primarySize,height: style.primarySize) } }
    public var secondaryKnobFrames: [CGRect] {
        knobs.dropFirst().filter { !$0.outer.isHidden }.map { CGRect(x: $0.outer.position.x-style.secondarySize/2,y: $0.outer.position.y-style.secondarySize/2,width: style.secondarySize,height: style.secondarySize) }
    }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - bounds.midX) / style.radius,
                y: (point.y - bounds.midY) / style.radius)
    }
    open override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }; showsKeyboardFocus = false
        if style.focusOnMouseDown { window?.makeFirstResponder(self) }
        let point = convert(event.locationInWindow, from: nil)
        draggingRelative = primaryKnobCenter.map { hypot(point.x - $0.x, point.y - $0.y) <= style.primarySize/2+4 } ?? false
        onInput?(.beginDrag(unit(point),draggingRelative)); onPoint?(unit(point),draggingRelative)
    }
    open override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled else { return }; onPoint?(unit(convert(event.locationInWindow, from: nil)),draggingRelative)
    }
    open override func mouseUp(with event: NSEvent) { onInput?(.endDrag) }
    open override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) {
            if arrowKeys.isEmpty { onInput?(.beginKeyboardGesture) }
            arrowKeys.insert(event.keyCode)
        }
        let shifted = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: onInput?(.keyboardHue(shifted ? -20 : -5))
        case 124: onInput?(.keyboardHue(shifted ? 20 : 5))
        case 126: onInput?(.keyboardRadius(shifted ? 0.1 : 0.03))
        case 125: onInput?(.keyboardRadius(shifted ? -0.1 : -0.03))
        default: super.keyDown(with: event)
        }
    }
    open override func accessibilityValue() -> Any? {
        values.isEmpty ? "No color" : "Color"
    }
    open override func keyUp(with event: NSEvent) {
        if arrowKeys.remove(event.keyCode) != nil {
            if arrowKeys.isEmpty { onInput?(.endKeyboardGesture) }
        } else { super.keyUp(with: event) }
    }
    open override func accessibilityPerformIncrement() -> Bool { onInput?(.keyboardHue(5)); return !values.isEmpty }
    open override func accessibilityPerformDecrement() -> Bool { onInput?(.keyboardHue(-5)); return !values.isEmpty }
    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    open override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = primaryKnobCenter.map { hypot(point.x - $0.x, point.y - $0.y) <= style.primarySize/2+4 } ?? false
        if hovered != pointerOnKnob { pointerOnKnob = hovered; updateKnobScale() }
    }
    open override func mouseExited(with event: NSEvent) { pointerOnKnob = false; updateKnobScale() }

    open func refreshAppearance() {
        guard layer != nil else { return }
        let appearance = contentAppearance
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = style.fill(appearance)
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        layer?.borderColor = style.contrastColor(appearance)
        dots.contents = DotGrid.image(side: style.radius*2,pitch: style.dotPitch,color: style.dotColor(appearance),scale: renderScale)
        dots.contentsScale = renderScale
        CATransaction.commit()
        paintKnobs()
    }

    private func paintKnobs() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for knob in knobs { knob.outer.isHidden = true }
        for (index,value) in values.enumerated() {
            let position = value.position
            let size = index == 0 ? style.primarySize : style.secondarySize
            let ring = index == 0 ? style.primaryRing : style.secondaryRing
            let knob = knobs[index]
            knob.outer.isHidden = false
            knob.outer.bounds = CGRect(x: 0,y: 0,width: size,height: size)
            knob.outer.path = CGPath(ellipseIn: knob.outer.bounds,transform: nil)
            knob.outer.position = CGPoint(x: bounds.midX+position.x*style.radius,y: bounds.midY+position.y*style.radius)
            knob.outer.fillColor = CGColor(gray: 1,alpha: 1)
            knob.inner.frame = knob.outer.bounds; knob.rim.frame = knob.outer.bounds
            knob.inner.path = CGPath(ellipseIn: knob.outer.bounds.insetBy(dx: ring,dy: ring),transform: nil)
            knob.inner.fillColor = value.fill
            knob.rim.path = CGPath(ellipseIn: knob.outer.bounds.insetBy(dx: 0.5,dy: 0.5),transform: nil)
            knob.rim.fillColor = nil; knob.rim.lineWidth = 1
            knob.rim.strokeColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? style.contrastColor(contentAppearance) : nil
            knob.outer.shadowColor = CGColor(gray: contentAppearance == .light ? 0 : 1,alpha: 1)
            knob.outer.shadowOpacity = 0.06; knob.outer.shadowRadius = 2
            knob.outer.shadowOffset = CGSize(width: 0,height: 2); knob.outer.shadowPath = knob.outer.path
            knob.outer.contentsScale = renderScale; knob.inner.contentsScale = renderScale; knob.rim.contentsScale = renderScale
        }
        CATransaction.commit()
        updateKnobScale()
    }

    private func updateKnobScale() {
        for (index, knob) in knobs.enumerated() {
            let active = isGestureInProgress || pointerOnKnob
            let desired: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : index == 0
                ? (isGestureInProgress ? style.dragScale : pointerOnKnob ? style.hoverScale : 1) : (active ? style.secondaryActiveScale : 1)
            let layer = knob.outer
            let old = layer.transform.m11
            guard abs(old - desired) > 0.001 else { continue }
            let animation: CABasicAnimation = isGestureInProgress ? CABasicAnimation(keyPath: "transform.scale") : style.returnSpring.animation(keyPath: "transform.scale")
            animation.fromValue = layer.presentation()?.transform.m11 ?? old; animation.toValue = desired
            if isGestureInProgress { animation.duration = 0.12; animation.timingFunction = Motion.easeOut }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeScale(desired, desired, 1)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer.add(animation, forKey: "knob-scale") }
            CATransaction.commit()
        }
    }
}

@MainActor private final class KnobLayers {
    let outer = CAShapeLayer(), inner = CAShapeLayer(), rim = CAShapeLayer()
    init() { outer.addSublayer(inner); outer.addSublayer(rim) }
}

@MainActor private enum DotGrid {
    private static var cache: [String: CGImage] = [:]
    static func image(side padSide: CGFloat,pitch: CGFloat,color: CGColor,scale: CGFloat) -> CGImage {
        let key = "\(padSide)|\(pitch)|\(color)|\(scale)"
        if let image = cache[key] { return image }
        let side = Int((padSide * scale).rounded())
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        for y in stride(from: pitch/2, to: padSide, by: pitch) {
            for x in stride(from: pitch/2, to: padSide, by: pitch) { context.fillEllipse(in: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)) }
        }
        let image = context.makeImage()!; if cache.count>=16 { cache.removeAll(keepingCapacity: true) }; cache[key] = image; return image
    }
}
