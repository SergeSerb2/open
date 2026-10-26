import AppKit
import CoreText
import OpenDesign
import OpenBoosts

@MainActor
public enum BoostEditorFonts {
    public struct Item: Sendable { public let name: String; public let css: String?; public let family: String? }
    public static let available: [Item] = {
        let families: [(String, String)] = [("Helvetica Neue","sans-serif"),("Avenir","sans-serif"),("Futura","sans-serif"),("DIN Alternate","sans-serif"),("PT Mono","monospace"),("Courier","monospace"),("Times New Roman","serif"),("Charter","serif"),("Baskerville","serif"),("Hoefler Text","serif"),("Palatino","serif"),("Chalkboard","cursive"),("SignPainter","cursive"),("Snell Roundhand","cursive"),("Papyrus","fantasy"),("Apple Chancery","cursive"),("Luminari","fantasy"),("Wingdings","fantasy")]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return [Item(name: "Original", css: nil, family: nil), Item(name: "System", css: "system-ui, -apple-system, sans-serif", family: nil)] + families.compactMap { family, generic in
            installed.contains(family) ? Item(name: family, css: family + ", " + generic, family: family) : nil
        }
    }()
}

/// Explicit backing contents keep AppKit's managed layers stable across child-panel resizes.
@MainActor
private enum EditorRaster {
    static func lines(_ text: String,width: CGFloat,font: NSFont) -> [String] {
        let source = text as NSString, typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text,attributes: [.font: font]))
        var result: [String] = [], start = 0
        while start < source.length {
            let count = max(1,CTTypesetterSuggestLineBreak(typesetter,start,Double(width)))
            result.append(source.substring(with: NSRange(location: start,length: count)).trimmingCharacters(in: .whitespaces)); start += count
        }
        return result
    }
    static func display(_ view: NSView, draw: () -> Void) {
        let scale = view.window?.backingScaleFactor ?? 2, size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil,width: Int(ceil(size.width*scale)),height: Int(ceil(size.height*scale)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale,y: scale); context.translateBy(x: 0,y: size.height); context.scaleBy(x: 1,y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin(); CATransaction.setDisableActions(true); view.layer?.contents = context.makeImage(); view.layer?.contentsScale = scale; CATransaction.commit()
    }
}

@MainActor
final class EditorButton: SiteControlButton {
    var fill: DesignColor?; var selected = false; var fontFamily: String?; var tile = false
    var focusAppearanceChanged: (() -> Void)?
    var secondaryClick: (() -> Void)?
    private let focusLayer = CAShapeLayer()
    private var pressed = false
    private var editorHovered = false
    override func mouseEntered(with event: NSEvent) { editorHovered = true; super.mouseEntered(with: event); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { editorHovered = false; super.mouseExited(with: event); needsDisplay = true }
    var activationModifiers: NSEvent.ModifierFlags = []
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; super.mouseDown(with: event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { pressed = false; activationModifiers = event.modifierFlags; super.mouseUp(with: event); needsDisplay = true }
    override func keyDown(with event: NSEvent) { activationModifiers = event.modifierFlags; super.keyDown(with: event) }
    override var needsPanelToBecomeKey: Bool { isEnabled }
    override var drawsStandardButton: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        EditorRaster.display(self) { draw(bounds) }
        if focusLayer.superlayer == nil { layer?.addSublayer(focusLayer) }
        let rect = bounds.insetBy(dx: -2,dy: -2), radius: CGFloat = tile ? 14 : fontFamily != nil ? 10 : rect.height/2
        focusLayer.frame = bounds; focusLayer.path = CGPath(roundedRect: rect,cornerWidth: radius,cornerHeight: radius,transform: nil)
        focusLayer.fillColor = nil; focusLayer.strokeColor = Core.focusRing.cgColor(contentAppearance); focusLayer.lineWidth = 2
        focusLayer.isHidden = focusAppearanceChanged != nil || !showsKeyboardFocus || window?.firstResponder !== self
        focusAppearanceChanged?()
    }
    override func rightMouseDown(with event: NSEvent) { secondaryClick?() }
    override func draw(_ dirtyRect: NSRect) {
        let appearance = contentAppearance
        let color = (controlID == "editor.make" ? BoostEditorColors.interstitialForeground : ["editor.more","editor.close"].contains(controlID) ? BoostEditorColors.headerButton : selected ? BoostEditorColors.label : Core.foregroundPrimary).resolved(appearance).nsColor
        let alpha: CGFloat = isEnabled ? 1 : 0.3
        if let fill {
            let resolved = fill.resolved(appearance).nsColor
            resolved.withAlphaComponent(resolved.alphaComponent*(selected ? 1 : tile ? 0.14 : 1)*alpha).setFill()
            NSGraphicsContext.saveGraphicsState()
            if fontFamily != nil { let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.1); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero; shadow.set() }
            let radius: CGFloat = tile ? 12 : fontFamily != nil ? 8 : bounds.height/2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if editorHovered || pressed {
            Core.foregroundPrimary.resolved(appearance).nsColor.withAlphaComponent(pressed ? 0.12 : 0.06).setFill()
            let r: CGFloat = tile ? 12 : fontFamily != nil ? 8 : bounds.height/2
            NSBezierPath(roundedRect: bounds,xRadius: r,yRadius: r).fill()
        }
        if let fontFamily {
            let font = NSFont(name: fontFamily, size: 17) ?? NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: 17) ?? .systemFont(ofSize: 17)
            SiteControlDrawing.text("Aa", x: 0, baseline: 24, width: bounds.width, font: font, color: color.withAlphaComponent(color.alphaComponent*alpha), alignment: .center)
        } else if tile {
            SiteControlDrawing.glyph(symbol, in: CGRect(x: 0, y: 7, width: bounds.width, height: 22), size: 18, color: color.withAlphaComponent(color.alphaComponent*alpha))
            SiteControlDrawing.text(title, x: 1, baseline: 44, width: bounds.width-2, font: .systemFont(ofSize: 10, weight: .semibold), color: color.withAlphaComponent(color.alphaComponent*alpha), alignment: .center)
        } else if !symbol.isEmpty {
            if let raster = SiteControlDrawing.raster(symbol,size: controlID == "editor.close" ? 11 : 13,color: color.withAlphaComponent(color.alphaComponent*alpha),weight: controlID == "editor.more" ? .bold : .semibold) { SiteControlDrawing.bitmap(raster.image,in: CGRect(x: bounds.midX-raster.size.width/2,y: bounds.midY-raster.size.height/2,width: raster.size.width,height: raster.size.height)) }
        } else {
            SiteControlDrawing.text(title, x: controlID == "editor.scope" ? 0 : 3, baseline: controlID == "editor.scope" ? 12 : (bounds.height+13)/2, width: bounds.width-6, font: .systemFont(ofSize: controlID == "editor.scope" ? 11 : 13, weight: controlID == "editor.scope" ? .regular : .semibold), color: (controlID == "editor.scope" ? Core.foregroundSecondary.resolved(appearance).nsColor : color).withAlphaComponent((controlID == "editor.scope" ? Core.foregroundSecondary.resolved(appearance).nsColor.alphaComponent : color.alphaComponent)*alpha), alignment: controlID == "editor.scope" ? .left : .center)
        }
    }
}

@MainActor
public final class BoostColorWheelView: NSView {
    public let session: BoostEditorSession
    public var onKey: ((NSEvent) -> Bool)?
    private var dragging = false
    private let interactionOwner = BoostEditorInteractionOwner()
    private var keyboardFocus = false
    private let focusLayer = CAShapeLayer()
    private var keyEnd: DispatchWorkItem?
    private static var ring: CGImage?
    private let puckLayer = CAShapeLayer()
    private var puckState: (hue: Double,intensity: Double,bounds: CGRect)?
    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        EditorRaster.display(self) { draw(bounds) }
        if focusLayer.superlayer == nil { layer?.addSublayer(focusLayer) }
        focusLayer.frame = bounds; focusLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: -3,dy: -3),transform: nil)
        focusLayer.fillColor = nil; focusLayer.strokeColor = Core.focusRing.cgColor(contentAppearance); focusLayer.lineWidth = 2
        focusLayer.isHidden = !keyboardFocus || window?.firstResponder !== self
    }
    public override var needsPanelToBecomeKey: Bool { session.isEditable && session.colorsReady }
    public override var acceptsFirstResponder: Bool { session.isEditable && session.colorsReady }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public init(session: BoostEditorSession) {
        self.session = session; super.init(frame: .zero); wantsLayer = true
        puckLayer.bounds = CGRect(x: 0,y: 0,width: 24,height: 24); puckLayer.path = CGPath(ellipseIn: CGRect(x: 1.5,y: 1.5,width: 21,height: 21),transform: nil)
        puckLayer.strokeColor = NSColor.white.cgColor; puckLayer.lineWidth = 3; puckLayer.shadowColor = NSColor.black.cgColor; puckLayer.shadowOpacity = 0.25; puckLayer.shadowRadius = 3; puckLayer.shadowOffset = CGSize(width: 0,height: 1)
        puckLayer.shadowPath = CGPath(ellipseIn: CGRect(x: 0,y: 0,width: 24,height: 24),transform: nil)
        puckLayer.actions = ["position": NSNull(),"fillColor": NSNull(),"bounds": NSNull(),"path": NSNull()]; layer?.addSublayer(puckLayer)
        identifier = .init("editor.wheel"); setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Colors")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { keyEnd?.cancel() }
    public override func becomeFirstResponder() -> Bool { keyboardFocus = true; needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { endKeyGroup(); needsDisplay = true; return true }
    public override func setAccessibilityFocused(_ focused: Bool) { if !focused { endKeyGroup() }; super.setAccessibilityFocused(focused) }
    public override func accessibilityValue() -> Any? { let w = session.displayWheel; return "Hue \(Int(w.hue)) degrees, intensity \(Int(w.intensity*100)) percent" }
    public override func accessibilityPerformIncrement() -> Bool { repeatEdit { $0.intensity += 0.05 }; return session.colorsReady }
    public override func accessibilityPerformDecrement() -> Bool { repeatEdit { $0.intensity -= 0.05 }; return session.colorsReady }
    private func point(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), dx = p.x-bounds.midX, dy = p.y-bounds.midY
        var theta = atan2(dx, -dy)*180 / .pi; if theta < 0 { theta += 360 }
        session.editWheel(owner: interactionOwner) { $0.hue = theta; $0.intensity = min(hypot(dx,dy)/BoostEditorMetrics.padRadius, 1) }
    }
    public override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }; endKeyGroup(); window?.makeFirstResponder(self)
        keyboardFocus = false; needsDisplay = true; dragging = true; session.beginInteractive(owner: interactionOwner); point(event)
    }
    public override func mouseDragged(with event: NSEvent) { if dragging { point(event) } }
    public override func mouseUp(with event: NSEvent) { if dragging { point(event); dragging = false; session.endInteractive(owner: interactionOwner) } }
    private func endKeyGroup() { keyEnd?.cancel(); keyEnd = nil; session.endInteractive(owner: interactionOwner) }
    public override func keyDown(with event: NSEvent) {
        guard [123,124,125,126].contains(event.keyCode) else { endKeyGroup(); if onKey?(event) != true { super.keyDown(with: event) }; return }
        repeatEdit { wheel in
            switch event.keyCode {
            case 123: wheel.hue -= event.modifierFlags.contains(.shift) ? 15 : 5
            case 124: wheel.hue += event.modifierFlags.contains(.shift) ? 15 : 5
            case 125: wheel.intensity -= 0.05
            default: wheel.intensity += 0.05
            }
        }
    }
    private func repeatEdit(_ edit: (inout BoostColorWheel) -> Void) {
        guard acceptsFirstResponder else { return }
        keyboardFocus = true; session.beginInteractive(owner: interactionOwner); session.editWheel(owner: interactionOwner, edit)
        keyEnd?.cancel(); let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endKeyGroup() } }; keyEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: work)
    }
    private func puckPoint(_ w: BoostColorWheel) -> CGPoint {
        CGPoint(x: bounds.midX+w.intensity*46*sin(w.hue * .pi/180),y: bounds.midY-w.intensity*46*cos(w.hue * .pi/180))
    }
    func updatePuck() {
        let w = session.displayWheel
        if let p = puckState, p.hue == w.hue, p.intensity == w.intensity, p.bounds == bounds { return }
        puckState = (w.hue,w.intensity,bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        puckLayer.position = puckPoint(w)
        if w.intensity < 0.02 {
            let annulus = CGMutablePath(); annulus.addEllipse(in: CGRect(x: 0,y: 0,width: 24,height: 24))
            // Reverse the inner contour so the marker casts a ring shadow, not a disc.
            let innerPath = CGMutablePath()
            innerPath.addArc(center: CGPoint(x: 12,y: 12),radius: 9,startAngle: 0,endAngle: .pi*2,clockwise: true); innerPath.closeSubpath()
            annulus.addPath(innerPath); puckLayer.shadowPath = annulus
        } else { puckLayer.shadowPath = CGPath(ellipseIn: CGRect(x: 0,y: 0,width: 24,height: 24),transform: nil) }
        puckLayer.fillColor = w.intensity < 0.02 ? NSColor.clear.cgColor : NSColor(hue: w.hue/360,saturation: 0.85*w.intensity,brightness: 1,alpha: 1).usingColorSpace(.sRGB)?.cgColor
        CATransaction.commit()
    }
    func resetPuck(from value: BoostColorWheel) {
        updatePuck()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "position"); animation.fromValue = NSValue(point: puckPoint(value)); animation.toValue = NSValue(point: puckPoint(session.displayWheel)); animation.duration = BoostEditorMetrics.colorDuration; animation.timingFunction = CAMediaTimingFunction(name: .easeOut); puckLayer.add(animation,forKey: "reset")
        }
    }
    private static func ringImage() -> CGImage {
        if let ring { return ring }
        let n = 256, center = Double(n)/2
        var bytes = [UInt8](repeating: 0, count: n*n*4)
        for y in 0..<n { for x in 0..<n {
            let dx = Double(x)+0.5-center, dy = Double(y)+0.5-center, radius = hypot(dx,dy)
            let alpha = min(1, max(0, min(center-radius, radius-(center-36))))
            guard alpha > 0 else { continue }
            var hue = atan2(dx,-dy)/(2*Double.pi); if hue < 0 { hue += 1 }
            let c = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let color = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1).usingColorSpace(.sRGB) ?? c
            let i = (y*n+x)*4
            bytes[i] = UInt8((color.redComponent*255*alpha).rounded()); bytes[i+1] = UInt8((color.greenComponent*255*alpha).rounded()); bytes[i+2] = UInt8((color.blueComponent*255*alpha).rounded()); bytes[i+3] = UInt8((255*alpha).rounded())
        } }
        let result = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        ring = result; return result
    }
    public override func draw(_ dirtyRect: NSRect) {
        let m = BoostEditorMetrics.self, center = CGPoint(x: bounds.midX,y: bounds.midY)
        let ringRect = CGRect(x: center.x-64, y: center.y-64, width: 128, height: 128)
        NSImage(cgImage: Self.ringImage(), size: ringRect.size).draw(in: ringRect, from: .zero, operation: .sourceOver, fraction: session.colorsReady ? 1 : 0.3, respectFlipped: true, hints: nil)
        BoostEditorColors.puckPad.nsColor.setFill(); NSBezierPath(ovalIn: CGRect(x: center.x-m.padRadius,y: center.y-m.padRadius,width: m.padRadius*2,height: m.padRadius*2)).fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        for radius in [CGFloat(64), CGFloat(46)] { let edge = NSBezierPath(ovalIn: CGRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2)); edge.lineWidth = 1/(window?.backingScaleFactor ?? 2); edge.stroke() }
        updatePuck()

    }
}

@MainActor
final class EditorSlider: NSControl {
    let session: BoostEditorSession
    let component: Int
    let minimum: Double, maximum: Double
    private var dragging = false
    private var keyboardFocus = false
    private let interactionOwner = BoostEditorInteractionOwner()
    private var keyEnd: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(session: BoostEditorSession, component: Int) {
        self.session = session; self.component = component
        minimum = component == 2 ? 0 : 0.5; maximum = component == 2 ? 2 : 1.5
        super.init(frame: .zero); wantsLayer = true
        identifier = .init("editor.slider.\(component)"); setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel(["Brightness", "Contrast", "Original Saturation"][component])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { keyEnd?.cancel() }
    private var value: Double = 1
    override var doubleValue: Double { get { value } set { let next = min(maximum,max(minimum,newValue)); if next != value { value = next; needsDisplay = true; setAccessibilityValue(value) } } }
    private func changed(_ value: Double) {
        doubleValue = value
        session.editWheel(owner: interactionOwner) { w in switch component { case 0: w.brightness = doubleValue; case 1: w.contrast = doubleValue; default: w.originalSaturation = doubleValue } }
    }
    private func update(_ event: NSEvent) { let p = convert(event.locationInWindow,from: nil); changed(minimum+Double(min(1,max(0,(p.x-7)/(bounds.width-14))))*(maximum-minimum)) }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; endGroup(); window?.makeFirstResponder(self); keyboardFocus = false; dragging = true; session.beginInteractive(owner: interactionOwner); update(event) }
    override func mouseDragged(with event: NSEvent) { if dragging { update(event) } }
    override func mouseUp(with event: NSEvent) { if dragging { update(event); dragging = false; session.endInteractive(owner: interactionOwner) } }
    override func keyDown(with event: NSEvent) {
        if [123,124,125,126].contains(event.keyCode) { repeated(doubleValue+([124,126].contains(event.keyCode) ? 0.05 : -0.05)) }
        else { endGroup(); super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { keyboardFocus = true; needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { endGroup(); keyboardFocus = false; needsDisplay = true; return true }
    override func setAccessibilityFocused(_ focused: Bool) { if !focused { endGroup() }; super.setAccessibilityFocused(focused) }
    override func accessibilityValue() -> Any? { doubleValue }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; repeated(doubleValue+0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; repeated(doubleValue-0.05); return true }
    private func endGroup() { keyEnd?.cancel(); keyEnd = nil; session.endInteractive(owner: interactionOwner) }
    private func repeated(_ value: Double) {
        guard isEnabled else { return }
        keyboardFocus = true; session.beginInteractive(owner: interactionOwner); changed(value)
        keyEnd?.cancel(); let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endGroup() } }; keyEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+1,execute: work)
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 7,y: 12,width: bounds.width-14,height: 4)
        BoostEditorColors.sliderTrack.resolved(contentAppearance).nsColor.setFill(); NSBezierPath(roundedRect: track,xRadius: 2,yRadius: 2).fill()
        let x = track.minX+CGFloat((doubleValue-minimum)/(maximum-minimum))*track.width
        BoostEditorColors.sliderTint.nsColor.setFill(); NSBezierPath(roundedRect: CGRect(x: track.minX,y: track.minY,width: x-track.minX,height: 4),xRadius: 2,yRadius: 2).fill()
        NSGraphicsContext.saveGraphicsState(); let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 2; shadow.shadowOffset = CGSize(width: 0,height: -1); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: x-7,y: 7,width: 14,height: 14)).fill(); NSGraphicsContext.restoreGraphicsState()
        if keyboardFocus && window?.firstResponder === self { Core.focusRing.nsColor.setStroke(); NSBezierPath(ovalIn: CGRect(x: x-8,y: 6,width: 16,height: 16)).stroke() }
    }
}

@MainActor
public final class BoostEditorView: NSView {
    public let session: BoostEditorSession
    public let wheel: BoostColorWheelView
    public private(set) var controls: [SiteControlButton] = []
    public private(set) var advanced = false
    public var onResize: ((CGFloat, Bool) -> Void)?
    public var onClose: (() -> Void)?
    public var onMenu: ((NSMenu) -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var onRename: (() -> Void)?
    public var onHeaderDragEnd: (() -> Void)?
    public private(set) var nameField: NSTextField = EditorNameField(labelWithString: "")
    private let scope: EditorButton
    private let note = NSTextField(wrappingLabelWithString: "")
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let banner2 = NSTextField(wrappingLabelWithString: "")
    private let fontScroll = NSScrollView()
    private let fontTrack = NSView()
    private let fontDocument = NSView()
    private let fontMask = CAGradientLayer()
    private let fontFocus = CAShapeLayer()
    private var fontObserver: NSObjectProtocol?
    private let sliderLabels = ["Brightness","Contrast","Original Saturation"].map { NSTextField(labelWithString: $0) }
    private var sliders: [EditorSlider] = []
    private let firstRun = EditorInterstitial()
    private var fontButtons: [EditorButton] = []
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { EditorRaster.display(self) { draw(bounds) } }
    public var focusOrder: [NSView] {
        let visible = controls.filter { !$0.isHidden && $0.isEnabled && !($0.superview?.isHidden ?? false) }
        if session.showsInterstitial { return visible.filter { ["editor.close","editor.make"].contains($0.controlID) } }
        let header = visible.filter { ["editor.more","editor.close"].contains($0.controlID) }
        let sides = visible.filter { $0.controlID.hasPrefix("editor.color.") }
        return [scope] + header + (wheel.acceptsFirstResponder ? [wheel] : []) + sides + (advanced ? sliders : []) + fontButtons + visible.filter { $0.controlID.hasPrefix("editor.tool.") }
    }
    public init(session: BoostEditorSession) {
        self.session = session; wheel = BoostColorWheelView(session: session)
        scope = EditorButton(id: "editor.scope",label: "Boost scope",symbol: "",pointSize: 11)
        super.init(frame: .zero); wantsLayer = true
        layer?.cornerRadius = BoostEditorMetrics.cornerRadius; layer?.cornerCurve = .continuous
        setAccessibilityElement(false); setAccessibilityRole(.group); setAccessibilityLabel("Boost editor")
        nameField.font = Typography.editorTitle.font; nameField.lineBreakMode = .byTruncatingTail; nameField.maximumNumberOfLines = 1
        nameField.setAccessibilityLabel("Boost name")
        (nameField as? EditorNameField)?.onDoubleClick = { [weak self] in self?.onRename?() }
        for label in [note,banner,banner2] { label.preferredMaxLayoutWidth = 240; label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize: 11); label.textColor = .clear }
        for label in sliderLabels { label.font = .systemFont(ofSize: 11, weight: .medium) }
        [nameField,scope,wheel,note,banner,banner2,fontTrack,fontScroll,firstRun].forEach(addSubview)
        controls.append(scope); scope.setAccessibilityRole(.menuButton); scope.invoke = { [weak self] in self?.openScopeMenu() }
        button("editor.more","More","ellipsis",13) { [weak self] in guard let self else { return }; let menu = self.makeMenu?() ?? NSMenu(); self.onMenu?(menu); menu.popUp(positioning: nil, at: CGPoint(x: 0,y: 24), in: self.control(id: "editor.more")) }
        control(id: "editor.more")?.setAccessibilityRole(.menuButton)
        button("editor.close","Close","xmark",11) { [weak self] in self?.onClose?() }
        button("editor.color.invert","Invert lightness","lightbulb",13) { [weak session] in session?.editWheel { $0.invertLightness.toggle() } }
        button("editor.color.advanced","Advanced color controls","slider.horizontal.3",13) { [weak self] in guard let self else { return }; self.advanced.toggle(); self.refresh(animated: true) }
        button("editor.color.reset","Reset to original colors","arrow.counterclockwise",13) { [weak self] in guard let self else { return }; let old = self.session.displayWheel; self.session.resetColors(); self.wheel.resetPuck(from: old) }
        for i in 0..<3 { let slider = EditorSlider(session: session,component: i); sliders.append(slider); addSubview(slider); addSubview(sliderLabels[i]) }
        fontTrack.wantsLayer = true; fontTrack.layer?.cornerRadius = 10; fontTrack.layer?.cornerCurve = .continuous; fontTrack.layer?.addSublayer(fontFocus)
        fontScroll.drawsBackground = false; fontScroll.hasHorizontalScroller = false; fontScroll.documentView = fontDocument
        fontScroll.wantsLayer = true; fontScroll.layer?.mask = fontMask
        fontMask.startPoint = CGPoint(x: 0,y: 0.5); fontMask.endPoint = CGPoint(x: 1,y: 0.5)
        fontScroll.contentView.postsBoundsChangedNotifications = true
        fontObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,object: fontScroll.contentView,queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateFontFade() } }
        for (i,font) in BoostEditorFonts.available.enumerated() {
            let b = EditorButton(id: "editor.font.\(i)",label: font.name,symbol: "",pointSize: 17)
            b.fontFamily = font.family ?? ".AppleSystemUIFont"; b.toolTip = font.name
            b.focusAppearanceChanged = { [weak self] in self?.updateFontFocus() }
            b.invoke = { [weak session] in session?.setFont(font.css) }; b.frame = CGRect(x: CGFloat(i)*BoostEditorMetrics.fontStep,y: 0,width: 56,height: 36)
            b.onKey = { [weak self, weak b] e in self?.navigateFonts(e, current: b) ?? false }; fontDocument.addSubview(b); fontButtons.append(b)
        }
        fontDocument.frame = CGRect(x: 0,y: 0,width: CGFloat(fontButtons.count)*BoostEditorMetrics.fontStep-BoostEditorMetrics.fontGap,height: 36)
        let tools = [("zap","Zap","bolt.fill",7),("code","Code","chevron.left.forwardslash.chevron.right",0),("size","Normal","textformat.size",4),("case","Original","textformat",1)]
        for (i,tool) in tools.enumerated() {
            button("editor.tool."+tool.0,tool.1,tool.2,18) { [weak self] in
                guard let self else { return }
                if i == 2 { self.session.cycleTextSize(backwards: (self.control(id: "editor.tool.size") as? EditorButton)?.activationModifiers.contains(.shift) == true) }
                if i == 3 { self.session.cycleTextCase() }
            }
            let b = controls.last as! EditorButton; b.title = tool.1; b.fill = BoostEditorColors.accents[tool.3]; b.tile = true
            b.secondaryClick = { [weak self, weak b] in self?.openTextMenu(size: i == 2, anchor: b) }
            if i < 2 {
                // Blocked on P7: isolated world; the shell owns the engine hook.
                b.isEnabled = false; b.toolTip = i == 0 ? "Zap isn’t available yet." : "Code editing isn’t available yet."
            }
        }
        let make = EditorButton(id: "editor.make",label: "Make your own!",symbol: "",pointSize: 13); make.title = "Make your own!"
        make.invoke = { [weak session] in session?.dismissInterstitial() }; firstRun.addSubview(make); controls.append(make)
        session.onChange = { [weak self] in self?.refresh() }
        wheel.onKey = { [weak self] in self?.onKey?($0) ?? false }
        firstRun.accent = SiteControlDrawing.accent(session.boost.id)
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) } }
    public var makeMenu: (() -> NSMenu)?
    public func control(id: String) -> SiteControlButton? { (controls + fontButtons).first { $0.controlID == id } }
    private func button(_ id: String,_ label: String,_ symbol: String,_ size: CGFloat,_ action: @escaping () -> Void) {
        let b = EditorButton(id: id,label: label,symbol: symbol,pointSize: size); b.invoke = action
        b.onKey = { [weak self] in self?.onKey?($0) ?? false }; controls.append(b); addSubview(b)
    }
    private func refreshColors() {
        let w = session.displayWheel
        wheel.updatePuck()
        for (i,s) in sliders.enumerated() { s.doubleValue = [w.brightness,w.contrast,w.originalSaturation][i]; if s.isEnabled != session.colorsReady { s.isEnabled = session.colorsReady } }
        let invert = control(id: "editor.color.invert") as! EditorButton
        if invert.selected != w.invertLightness { invert.selected = w.invertLightness; invert.symbol = w.invertLightness ? "lightbulb.fill" : "lightbulb"; invert.fill = w.invertLightness ? Core.brandBlue : BoostEditorColors.segmentBackground; invert.needsDisplay = true }
        let text = session.showsLegacyColors ? "Custom colors — editing replaces them." : session.colorsReady && w.baseHue == nil ? "Few colors here. Try Invert lightness." : ""
        if note.stringValue != text { note.stringValue = text; needsDisplay = true }
    }
    private func bannerHeight(_ label: NSTextField) -> CGFloat { label.stringValue.isEmpty ? 0 : (EditorRaster.lines(label.stringValue,width: 240,font: .systemFont(ofSize: 11,weight: .medium)).count > 1 ? 42 : 28) }
    public func refresh(animated: Bool = false) {
        if session.isInteracting { refreshColors(); return }
        let oldPositions = animated ? subviews.compactMap { v in v.layer.map { (v,$0.position) } } : []
        if !nameField.isEditable { nameField.stringValue = session.boost.name.isEmpty ? session.boost.siteMatch.domain : session.boost.name; nameField.textColor = .clear }
        scope.title = session.boost.siteMatch.domain + (session.boost.siteMatch.pathPrefix ?? "") + " ▾"
        scope.setAccessibilityValue(scope.title)
        let wheelValue = session.displayWheel
        (control(id: "editor.color.invert") as? EditorButton)?.selected = wheelValue.invertLightness
        control(id: "editor.color.invert")?.symbol = wheelValue.invertLightness ? "lightbulb.fill" : "lightbulb"
        (control(id: "editor.color.advanced") as? EditorButton)?.selected = advanced
        for id in ["invert","advanced","reset"] { (control(id: "editor.color."+id) as? EditorButton)?.fill = (id == "invert" && wheelValue.invertLightness || id == "advanced" && advanced) ? Core.brandBlue : BoostEditorColors.segmentBackground }
        for (i,s) in sliders.enumerated() { s.doubleValue = [wheelValue.brightness,wheelValue.contrast,wheelValue.originalSaturation][i]; if s.isEnabled != session.colorsReady { s.isEnabled = session.colorsReady } }
        refreshColors()
        control(id: "editor.color.invert")?.isEnabled = session.colorsReady
        control(id: "editor.color.reset")?.isEnabled = session.colorsReady
        banner.stringValue = session.isActiveOnPage ? "" : "This Boost doesn't apply to \(session.pageURL.host ?? "this page")."
        banner2.stringValue = session.globallyEnabled ? "" : "Boosts are off. Changes show when you turn Boosts on in Settings."
        for (i,b) in fontButtons.enumerated() { b.fill = BoostEditorFonts.available[i].css == session.boost.fontFamily ? BoostEditorColors.segmentSelection : nil; b.needsDisplay = true }
        for (name,index,values) in [("size",session.textSizeIndex,BoostEditorSession.textSizeNames),("case",session.textCaseIndex,BoostEditorSession.textCaseNames)] {
            let b = control(id: "editor.tool."+name) as! EditorButton; b.title = values[index]; b.selected = name == "size" ? index != 1 : index != 0; b.setAccessibilityValue(values[index]); b.setAccessibilityLabel(name == "size" ? "Change text size" : "Change text case")
        }
        let offset = bannerHeight(banner)+bannerHeight(banner2)
        let m = BoostEditorMetrics.self
        let simpleHeight = m.sideButtonsY+m.sideButton+m.blockGap+m.fontStripHeight+m.blockGap+m.toolTile+m.inset
        let height: CGFloat = session.showsInterstitial ? m.interstitialHeight : simpleHeight + (advanced ? m.sliderRow*3 : 0) + offset
        onResize?(height, animated)
        needsLayout = true; needsDisplay = true; wheel.needsDisplay = true
        controls.forEach { $0.needsDisplay = true }
        if animated {
            superview?.superview?.superview?.layoutSubtreeIfNeeded(); layoutSubtreeIfNeeded()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (view,position) in oldPositions where view.layer?.position != position {
                    let a = CABasicAnimation(keyPath: "position"); a.fromValue = NSValue(point: position); a.toValue = view.layer.map { NSValue(point: $0.position) }; a.duration = BoostEditorMetrics.colorDuration; a.timingFunction = CAMediaTimingFunction(name: .easeOut); view.layer?.add(a,forKey: "advanced.slide")
                }
            }
        }
    }
    public override func layout() {
        super.layout(); let first = session.showsInterstitial
        for view in subviews { view.isHidden = first && view !== firstRun && view !== control(id: "editor.close") }
        firstRun.isHidden = !first
        firstRun.frame = bounds
        control(id: "editor.make")?.frame = CGRect(x: 14,y: bounds.height-50,width: 240,height: 36)
        nameField.frame = CGRect(x: 38,y: 8,width: 140,height: 20)
        scope.frame = CGRect(x: 40,y: 27,width: 144,height: 20)
        control(id: "editor.more")?.frame = CGRect(x: 200,y: 12,width: 24,height: 24)
        control(id: "editor.close")?.frame = CGRect(x: 230,y: 12,width: 24,height: 24)
        var shift: CGFloat = 0
        for b in [banner,banner2] { b.isHidden = first || b.stringValue.isEmpty; if !b.isHidden { b.frame = CGRect(x: 14,y: 52+shift,width: 240,height: bannerHeight(b)); shift += b.frame.height } }
        wheel.frame = CGRect(x: (BoostEditorMetrics.width-BoostEditorMetrics.ringDiameter)/2,y: BoostEditorMetrics.wheelY+(BoostEditorMetrics.wheelArea-BoostEditorMetrics.ringDiameter)/2+shift,width: BoostEditorMetrics.ringDiameter,height: BoostEditorMetrics.ringDiameter)
        note.frame = CGRect(x: 14,y: BoostEditorMetrics.noteY+shift,width: 240,height: 18)
        for (i,id) in ["invert","advanced","reset"].enumerated() { control(id: "editor.color."+id)?.frame = CGRect(x: 80+CGFloat(i)*40,y: BoostEditorMetrics.sideButtonsY+shift,width: BoostEditorMetrics.sideButton,height: BoostEditorMetrics.sideButton) }
        for i in 0..<3 { sliders[i].isHidden = first || !advanced; sliderLabels[i].isHidden = first || !advanced; sliderLabels[i].frame = CGRect(x: 14,y: BoostEditorMetrics.sliderLabelY+CGFloat(i)*BoostEditorMetrics.sliderRow+shift,width: BoostEditorMetrics.sliderLabelWidth,height: 18); sliders[i].frame = CGRect(x: BoostEditorMetrics.sliderX,y: BoostEditorMetrics.slidersY+CGFloat(i)*BoostEditorMetrics.sliderRow+shift,width: BoostEditorMetrics.sliderWidth,height: 28) }
        let fontY = BoostEditorMetrics.fontsY+shift+(advanced ? BoostEditorMetrics.sliderRow*3 : 0)
        fontTrack.frame = CGRect(x: 14,y: fontY,width: 240,height: 44); fontTrack.layer?.backgroundColor = BoostEditorColors.segmentBackground.cgColor(contentAppearance)
        fontScroll.frame = CGRect(x: 14+BoostEditorMetrics.fontEdgeInset,y: fontY+4,width: BoostEditorMetrics.fontViewport,height: 36); updateFontFade()
        for (i,id) in ["zap","code","size","case"].enumerated() { control(id: "editor.tool."+id)?.frame = CGRect(x: 14+CGFloat(i)*BoostEditorMetrics.fontStep,y: fontY+56,width: 54,height: 54) }
    }
    public override func draw(_ dirtyRect: NSRect) {
        Core.popoverBackground.nsColor.setFill(); bounds.fill()
        if !session.showsInterstitial { SiteControlDrawing.glyph("paintbrush.pointed.fill", in: CGRect(x: 14,y: 10,width: 18,height: 24), size: 18, color: SiteControlDrawing.accent(session.boost.id).resolved(contentAppearance).nsColor) }
        BoostEditorColors.warning.resolved(contentAppearance).nsColor.withAlphaComponent(0.15).setFill()
        for b in [banner,banner2] where !b.isHidden {
            CGRect(x: 0,y: b.frame.minY,width: bounds.width,height: b.frame.height).fill()
            let lines = EditorRaster.lines(b.stringValue,width: 240,font: .systemFont(ofSize: 11,weight: .medium))
            for (i,line) in lines.enumerated() { SiteControlDrawing.text(line,x: 14,baseline: b.frame.minY+18+CGFloat(i)*14,width: 240,font: .systemFont(ofSize: 11,weight: .medium),color: Core.foregroundPrimary.resolved(contentAppearance).nsColor) }
        }
        if !session.showsInterstitial {
            if !nameField.isEditable { SiteControlDrawing.text(nameField.stringValue,x: 40,baseline: 22,width: 140,font: Typography.editorTitle.font,color: Core.foregroundPrimary.resolved(contentAppearance).nsColor) }
            SiteControlDrawing.text(note.stringValue,x: 14,baseline: note.frame.minY+14,width: 240,font: .systemFont(ofSize: 11),color: Core.foregroundSecondary.resolved(contentAppearance).nsColor,alignment: .center)
        }
        CommandBarColors.hairlineDivider.nsColor.setStroke(); let px = 1/(window?.backingScaleFactor ?? 2)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: px/2,dy: px/2),xRadius: 12,yRadius: 12); edge.lineWidth = px; edge.stroke()
    }
    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow,from: nil)
        if p.y < 52 { if event.clickCount == 2 { onRename?() } else { window?.performDrag(with: event); onHeaderDragEnd?() } }
    }
    public override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    public func scopeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for choice in session.scopeChoices() {
            let item = NSMenuItem(title: choice.title, action: #selector(pickScope(_:)), keyEquivalent: ""); item.target = self; item.representedObject = choice.match
            item.state = choice.match == session.boost.siteMatch ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    @objc private func pickScope(_ item: NSMenuItem) { if let match = item.representedObject as? SiteMatch { session.setScope(match) } }
    private func openScopeMenu() { let menu = scopeMenu(); onMenu?(menu); menu.popUp(positioning: menu.items.first { $0.state == .on },at: .zero,in: scope) }
    private func updateFontFocus() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let focused = window?.firstResponder as? EditorButton, fontButtons.contains(focused), focused.showsKeyboardFocus {
            let rect = fontTrack.convert(focused.bounds,from: focused).insetBy(dx: -2,dy: -2)
            fontFocus.frame = fontTrack.bounds; fontFocus.path = CGPath(roundedRect: rect,cornerWidth: 10,cornerHeight: 10,transform: nil)
            fontFocus.fillColor = nil; fontFocus.strokeColor = Core.focusRing.cgColor(contentAppearance); fontFocus.lineWidth = 2; fontFocus.isHidden = false
        } else { fontFocus.isHidden = true }
        CATransaction.commit()
    }
    private func updateFontFade() {
        let width = fontScroll.bounds.width
        guard width > 0 else { return }
        let trailing = fontScroll.contentView.bounds.maxX < fontDocument.bounds.maxX-0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fontMask.frame = fontScroll.bounds
        fontMask.colors = [NSColor.black.cgColor,NSColor.black.cgColor,(trailing ? NSColor.clear : NSColor.black).cgColor]
        fontMask.locations = [0,NSNumber(value: Double(1-BoostEditorMetrics.fontFade/width)),1]
        CATransaction.commit(); updateFontFocus()
    }
    func focus(_ target: NSView) {
        if let button = target as? SiteControlButton { button.showsKeyboardFocus = true }
        if let button = target as? EditorButton, fontButtons.contains(button) { button.scrollToVisible(button.bounds.insetBy(dx: -BoostEditorMetrics.fontFade,dy: 0)); updateFontFade() }
        else { target.scrollToVisible(target.bounds) }
        window?.makeFirstResponder(target); target.needsDisplay = true
    }
    private func navigateFonts(_ event: NSEvent,current: EditorButton?) -> Bool {
        if event.keyCode == 123 || event.keyCode == 124, let current, let i = fontButtons.firstIndex(of: current) { let next = fontButtons[(i+(event.keyCode == 123 ? fontButtons.count-1 : 1))%fontButtons.count]; focus(next); return true }
        return onKey?(event) ?? false
    }
    private func openTextMenu(size: Bool, anchor: NSView?) {
        let menu = NSMenu(); let values = size ? BoostEditorSession.textSizeNames : BoostEditorSession.textCaseNames
        for (i,name) in values.enumerated() { let item = NSMenuItem(title: name,action: #selector(pickText(_:)),keyEquivalent: ""); item.target = self; item.tag = i+(size ? 10 : 0); item.state = i == (size ? session.textSizeIndex : session.textCaseIndex) ? .on : .off; menu.addItem(item) }
        onMenu?(menu); menu.popUp(positioning: nil,at: .zero,in: anchor)
    }
    @objc private func pickText(_ item: NSMenuItem) { if item.tag >= 10 { session.setTextSize(index: item.tag-10) } else { session.setTextCase(index: item.tag) } }
}

@MainActor
private final class EditorNameField: NSTextField {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && !isEditable { onDoubleClick?() }
        else if isEditable { super.mouseDown(with: event) }
        else { nextResponder?.mouseDown(with: event) }
    }
}

@MainActor
private final class EditorInterstitial: NSView {
    var accent = BoostEditorColors.accents[5]
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Edit the Internet with Boosts. Change colors, fonts, and text on any site, hide parts of a page, or add your own CSS.") }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Core.popoverBackground.nsColor.setFill(); bounds.fill()
        accent.nsColor.setFill(); NSBezierPath(ovalIn: CGRect(x: 99,y: 32,width: 70,height: 70)).fill()
        SiteControlDrawing.glyph("paintbrush.pointed.fill",in: CGRect(x: 99,y: 32,width: 70,height: 70),size: 32,color: .white)
        let wave = NSBezierPath(); wave.move(to: CGPoint(x: 104,y: 112)); wave.curve(to: CGPoint(x: 164,y: 112),controlPoint1: CGPoint(x: 124,y: 96),controlPoint2: CGPoint(x: 144,y: 128)); wave.lineWidth = 3; accent.nsColor.setStroke(); wave.stroke()
        let fg = (contentAppearance == .dark ? Core.foregroundPrimary : BoostEditorColors.interstitialForeground).resolved(contentAppearance).nsColor
        SiteControlDrawing.text("Edit the Internet with Boosts",x: 22,baseline: 155,width: 224,font: .systemFont(ofSize: 16,weight: .bold),color: fg,alignment: .center)
        let body = "Change colors, fonts, and text on any site, hide parts of a page, or add your own CSS."
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (body as NSString).draw(in: CGRect(x: 26,y: 178,width: 216,height: 64),withAttributes: [.font: NSFont.systemFont(ofSize: 12),.foregroundColor: (contentAppearance == .dark ? Core.foregroundSecondary : BoostEditorColors.interstitialForeground).resolved(contentAppearance).nsColor,.paragraphStyle: style])
        BoostEditorColors.interstitialFooter.nsColor.setFill(); CGRect(x: 0,y: bounds.height-64,width: bounds.width,height: 64).fill()
    }
}
