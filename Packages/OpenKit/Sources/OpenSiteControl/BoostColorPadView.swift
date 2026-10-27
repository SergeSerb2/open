import AppKit
import CoreImage
import OpenDesign
import OpenBoosts

@MainActor
private struct BoostPadLaw: ColorPadLaw {
    struct State { let wheel: BoostColorWheel; let showsValues: Bool }
    struct Value { let point: CGPoint; let relative: Bool }
    func knobs(for state: State) -> [ColorPadKnob] {
        let wheel = state.wheel
        let t = state.showsValues ? wheel.intensity : Double(BoostEditorMetrics.defaultKnobRadius/BoostEditorMetrics.padRadius/0.99)
        let hue = state.showsValues ? wheel.hue : 0
        return (0..<2).map { index in
            let angle = hue+Double(index)*45,rad = angle * .pi/180
            let color: NSColor = state.showsValues
                ? NSColor(hue: angle.truncatingRemainder(dividingBy: 360)/360,saturation: t*(index == 0 ? 1 : 0.68),brightness: index == 0 ? 0.78 : 0.24,alpha: 1).usingColorSpace(.sRGB)!
                : (index == 0 ? BoostEditorColors.noColorKnobs.primary : BoostEditorColors.noColorKnobs.secondary).nsColor
            return ColorPadKnob(position: CGPoint(x: cos(rad)*t*0.99,y: sin(rad)*t*0.99),fill: color.cgColor,
                topFill: SiteControlGlyphRenderer.adjust(color,levels: -14).cgColor,bottomFill: SiteControlGlyphRenderer.adjust(color,levels: 12).cgColor)
        }
    }
    func value(at unitPoint: CGPoint,relative: Bool) -> Value { Value(point: unitPoint,relative: relative) }
}

/// Boost state and color law only. The shared pad owns all dot/knob drawing and input.
@MainActor
public final class BoostColorPadView: OpenDesign.ColorPadView {
    public let session: BoostEditorSession
    public var onKey: ((NSEvent) -> Bool)?
    private let owner = BoostEditorInteractionOwner()
    private let ring = CAGradientLayer(),ringMask = CAShapeLayer(),guide = CAShapeLayer(),tint = CALayer()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var dragSeed: (pointer: CGPoint,knob: CGPoint)?
    public private(set) var isDragging = false
    private var previous: (BoostColorWheel,Bool,Bool,Bool,Bool,Bool)?
    private var hueAX: PadAxis!,intensityAX: PadAxis!
    private static var tintImages: [CGFloat: CGImage] = [:]

    public init(session: BoostEditorSession) {
        self.session = session
        var style = ColorPadStyle.theme
        style.radius = 66.5; style.plateInset = 7; style.cornerRadius = 20; style.plateCornerRadius = 13.5; style.clipsKnobs = false
        style.primarySize = 34; style.secondarySize = 25; style.primaryRing = 2; style.secondaryRing = 3
        style.dotPitch = 4; style.dragScale = 38.0/30; style.hoverScale = 1; style.secondaryActiveScale = 1
        style.returnSpring = Motion.knobRelease; style.springOnPress = true; style.keyboardEndDelay = 1
        style.keyboardFocusOnly = true; style.focusOnMouseDown = false; style.focusOutset = 2
        style.shadowOpacity = 0.10; style.shadowRadius = 1.5; style.shadowOffset = 0.5; style.secondaryOutline = BoostEditorColors.secondaryOutline.cgColor
        style.fill = { _ in BoostEditorColors.plate.cgColor }; style.dotColor = { _ in BoostEditorColors.dot.cgColor }
        super.init(frame: .zero,style: style)
        appearance = .init(named: .aqua); identifier = .init("editor.pad")
        setAccessibilityRole(.group); setAccessibilityLabel("Color")
        hueAX = PadAxis(pad: self,hue: true); intensityAX = PadAxis(pad: self,hue: false); setAccessibilityChildren([hueAX!,intensityAX!])
        ring.type = .conic; ring.startPoint = CGPoint(x: 0.5,y: 0.5); ring.endPoint = CGPoint(x: 1,y: 0.5)
        ring.mask = ringMask; ringMask.fillRule = .evenOdd; ringLayer = ring
        guide.fillColor = nil; guide.strokeColor = BoostEditorColors.guide.cgColor; guide.lineWidth = 2; guideLayer = guide
        plateOverlayLayer = tint; tint.opacity = 0.04
        note.font = .systemFont(ofSize: 10,weight: .medium); note.textColor = NSColor(srgbRed: 142/255,green: 142/255,blue: 147/255,alpha: 1)
        note.alignment = .center; note.maximumNumberOfLines = 2; note.setAccessibilityElement(true); addSubview(note)
        onInput = { [weak self] in self?.input($0) }; refresh()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
    public override var needsPanelToBecomeKey: Bool { false }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        let mask = CGMutablePath(); mask.addRoundedRect(in: bounds,cornerWidth: 20,cornerHeight: 20)
        mask.addRoundedRect(in: bounds.insetBy(dx: 7,dy: 7),cornerWidth: 13.5,cornerHeight: 13.5); ringMask.path = mask
        ringMask.frame = bounds; guide.frame = bounds
        tint.frame = CGRect(x: -7,y: -7,width: bounds.width,height: bounds.height)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.08; layer?.shadowRadius = 4; layer?.shadowOffset = CGSize(width: 0,height: 2)
        layer?.shadowPath = CGPath(roundedRect: bounds,cornerWidth: 20,cornerHeight: 20,transform: nil)
        CATransaction.commit()
        note.frame = CGRect(x: 9,y: 115,width: 129,height: 25)
        updateGuide()
    }
    public func refresh(animatedReset: Bool = false) {
        let wheel = session.displayWheel,hasValues = session.showsLegacyColors || session.boost.colorWheel != nil
        interactionEnabled = session.isEditable && session.colorsReady
        let snapshot = (wheel,hasValues,session.colorsReady,isDragging,session.showsLegacyColors,session.boost.colorWheel != nil)
        if let old = previous,old.0 == wheel,old.1 == hasValues,old.2 == session.colorsReady,old.3 == isDragging,old.4 == session.showsLegacyColors,old.5 == (session.boost.colorWheel != nil) { return }
        let positions = [primaryKnobCenter].compactMap { $0 }+secondaryKnobFrames.map { CGPoint(x: $0.midX,y: $0.midY) }
        previous = snapshot; renderScale = window?.backingScaleFactor ?? renderScale
        super.apply(BoostPadLaw.State(wheel: wheel,showsValues: hasValues),law: BoostPadLaw(),gestureInProgress: isDragging) { [weak self] value in self?.edit(value.point,relative: value.relative) }
        let coloredRing = session.boost.colorWheel != nil
        let colors = BoostEditorColors.ringStops.map { stop -> CGColor in
            let c = RGBA(hex: stop.color)
            return coloredRing ? c.cgColor : RGBA(0.2126*c.red+0.7152*c.green+0.0722*c.blue,0.2126*c.red+0.7152*c.green+0.0722*c.blue,0.2126*c.red+0.7152*c.green+0.0722*c.blue).cgColor
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if animatedReset,let old = ring.colors { let fade = CABasicAnimation(keyPath: "colors"); fade.fromValue = old; fade.toValue = colors; fade.duration = 0.22; ring.add(fade,forKey: "reset") }
        ring.colors = colors; ring.locations = BoostEditorColors.ringStops.map { NSNumber(value: Double($0.degrees/360)) }
        tint.isHidden = !coloredRing
        if coloredRing { tint.contents = Self.tintImage(scale: renderScale); tint.contentsScale = renderScale }
        CATransaction.commit()
        let message = session.showsLegacyColors ? "Custom colors — editing replaces them." : session.colorsReady && wheel.baseHue == nil ? "Few colors here. Try Invert lightness." : ""
        if note.stringValue != message { note.stringValue = message }; note.isHidden = isDragging || message.isEmpty
        updateGuide(); if animatedReset { animateKnobs(from: positions,duration: 0.22) }
    }
    private func input(_ input: ColorPadInput) {
        switch input {
        case .beginDrag(let point,let relative):
            finishKeyboardGesture(); session.beginInteractive(owner: owner); isDragging = true
            if relative, session.boost.colorWheel != nil || session.showsLegacyColors,let center = primaryKnobCenter {
                dragSeed = (point,CGPoint(x: (center.x-bounds.midX)/66.5,y: (center.y-bounds.midY)/66.5))
            } else { dragSeed = nil }
        case .endDrag: isDragging = false; dragSeed = nil; session.endInteractive(owner: owner); refresh()
        case .beginKeyboardGesture: session.beginInteractive(owner: owner)
        case .endKeyboardGesture: session.endInteractive(owner: owner)
        case .keyboardHue(let value): _ = session.editWheel(owner: owner) { $0.hue += value }
        case .keyboardRadius(let value): _ = session.editWheel(owner: owner) { $0.intensity += value }
        }
    }
    private func edit(_ raw: CGPoint,relative: Bool) {
        let point = relative && dragSeed != nil ? ColorPadGeometry.relative(raw,startPointer: dragSeed!.pointer,startKnob: dragSeed!.knob) : raw
        let hue = (atan2(point.y,point.x)*180 / .pi+360).truncatingRemainder(dividingBy: 360)
        _ = session.editWheel(owner: owner) { $0.hue = hue; $0.intensity = min(1,hypot(point.x,point.y)/0.99) }
        refresh()
    }
    private func updateGuide() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guide.isHidden = !isDragging
        if let p = primaryKnobCenter { let r = hypot(p.x-bounds.midX,p.y-bounds.midY); guide.path = CGPath(ellipseIn: CGRect(x: bounds.midX-r,y: bounds.midY-r,width: r*2,height: r*2),transform: nil) }
        CATransaction.commit()
    }
    public override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    public override func accessibilityValue() -> Any? { nil }
    private static func tintImage(scale: CGFloat) -> CGImage? {
        if let image = tintImages[scale] { return image }
        let side = Int(147*scale),s = BoostEditorColors.ringStops
        var pixels = [UInt8](repeating: 0,count: side*side*4)
        for y in 0..<side { for x in 0..<side {
            let a = (atan2(Double(y)-Double(side)/2,Double(x)-Double(side)/2)*180 / .pi+360).truncatingRemainder(dividingBy: 360)
            let i = min(11,Int(a/30)),f = (a-Double(i*30))/30,c0 = RGBA(hex: s[i].color),c1 = RGBA(hex: s[i+1].color),offset = (y*side+x)*4
            for (j,v) in [c0.red+(c1.red-c0.red)*f,c0.green+(c1.green-c0.green)*f,c0.blue+(c1.blue-c0.blue)*f].enumerated() { pixels[offset+j] = UInt8((v*255).rounded()) }; pixels[offset+3] = 255
        } }
        let cg = CGImage(width: side,height: side,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: side*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(pixels) as CFData)!,decode: nil,shouldInterpolate: true,intent: .defaultIntent)!
        let source = CIImage(cgImage: cg),filter = CIFilter(name: "CIGaussianBlur",parameters: [kCIInputImageKey: source,kCIInputRadiusKey: 12*scale])!
        let image = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(filter.outputImage!,from: source.extent)
        if let image { if tintImages.count>=4 { tintImages.removeAll() }; tintImages[scale] = image }; return image
    }
}

@MainActor private final class PadAxis: NSAccessibilityElement {
    weak var pad: BoostColorPadView?
    let hue: Bool
    init(pad: BoostColorPadView,hue: Bool) {
        self.pad = pad; self.hue = hue; super.init()
        setAccessibilityRole(.slider); setAccessibilityLabel(hue ? "Hue" : "Intensity"); setAccessibilityParent(pad)
    }
    override func accessibilityFrame() -> NSRect { pad.map { $0.window?.convertToScreen($0.convert($0.bounds,to: nil)) ?? .zero } ?? .zero }
    override func accessibilityValue() -> Any? { pad.map { hue ? $0.session.displayWheel.hue : $0.session.displayWheel.intensity*100 } }
    override func accessibilityPerformIncrement() -> Bool { pad?.accessibilityStep(hue: hue ? 5 : nil,radius: hue ? nil : 0.03) ?? false }
    override func accessibilityPerformDecrement() -> Bool { pad?.accessibilityStep(hue: hue ? -5 : nil,radius: hue ? nil : -0.03) ?? false }
}
