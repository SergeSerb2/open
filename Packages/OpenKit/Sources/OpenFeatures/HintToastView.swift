import AppKit
import CoreText
import OpenDesign

/// The first-hide hint (completion §3.12): "You can use [⌘S] to easily show and hide your
/// Sidebar!" at the window's top-right, above the web panel. It ignores the mouse (guess).
/// Geometry and colors: `HintToastMetrics` (measured on A0440).
@MainActor
public final class HintToastView: NSView {
    public let leadingText = "You can use"
    public let trailingText = "to easily show and hide your Sidebar!"
    public let keys: String
    private var lines: (leading: CTLine, keys: CTLine, trailing: CTLine)
    /// Text and plate origins in view coordinates (flipped; laid out once).
    public private(set) var plateFrame: CGRect = .zero
    public private(set) var leadingOrigin: CGPoint = .zero
    public private(set) var trailingOrigin: CGPoint = .zero

    public init(keys: String, style: SpaceThemeStyle) {
        self.keys = keys
        // Text color: the shared toast rule (page-platform §4.1.2), white on the dark fills.
        let color = style.toastText
        func line(_ text: String) -> CTLine {
            // CoreText reads a CGColor foreground (an NSColor value is ignored).
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: Typography.toast.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
        }
        lines = (line(leadingText), line(keys), line(trailingText))
        let m = HintToastMetrics.self
        // A0440 measures ink (HintToastMetrics): the runs are placed by their ink boxes.
        let leadingInk = CTLineGetImageBounds(lines.leading, nil), trailingInk = CTLineGetImageBounds(lines.trailing, nil)
        let leadingWidth = leadingInk.width, trailingWidth = trailingInk.width
        let keyInk = CTLineGetImageBounds(lines.keys, nil)
        let keyWidth = keyInk.width > 0 ? keyInk.width : CGFloat(CTLineGetTypographicBounds(lines.keys, nil, nil, nil))
        // Keycap ink is 19 px on A0440 (1919 ..< 1938), plate 37: ink + 18 in whole points.
        let plateWidth = (keyWidth + m.plateInkPadding).rounded(.down)
        let width = (m.leadingPadding + leadingWidth + m.textToPlate + plateWidth + m.plateToText + trailingWidth + m.trailingPadding).rounded(.up)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: m.height))
        wantsLayer = true
        leadingOrigin = CGPoint(x: m.leadingPadding - leadingInk.minX, y: m.baselineY)
        plateFrame = CGRect(x: (m.leadingPadding + leadingWidth + m.textToPlate).rounded(), y: m.plateY, width: plateWidth, height: m.plateHeight)
        trailingOrigin = CGPoint(x: plateFrame.maxX + m.plateToText - trailingInk.minX, y: m.baselineY)
        // The container only casts the shadow; the background and the text are ordered
        // subviews, so AppKit keeps the text layer above the fill.
        let layer = self.layer!
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = ToastMetrics.shadowOpacity
        layer.shadowRadius = ToastMetrics.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: -ToastMetrics.shadowOffsetY)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: m.radius, cornerHeight: m.radius, transform: nil)
        let background = HintBackgroundView(frame: bounds, fill: style.toastFill, plateFill: style.toastKeycapFill, plate: plateFrame)
        addSubview(background)
        addSubview(HintTextLayerView(frame: bounds, owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(leadingText) \(keys) \(trailingText)")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    /// Clicks pass through to the page under the hint.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func drawText(in context: CGContext) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = leadingOrigin; CTLineDraw(lines.leading, context)
        let keyInk = CTLineGetImageBounds(lines.keys, nil)
        let keyX = plateFrame.midX - keyInk.midX
        context.textPosition = CGPoint(x: keyX, y: HintToastMetrics.baselineY); CTLineDraw(lines.keys, context)
        context.textPosition = trailingOrigin; CTLineDraw(lines.trailing, context)
    }
}

/// The hint's three text runs, rendered once into the layer's contents at the backing scale.
@MainActor
private final class HintTextLayerView: NSView {
    unowned let owner: HintToastView
    init(frame: CGRect, owner: HintToastView) { self.owner = owner; super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Flip to the view's top-left coordinates, then let CoreText draw upright glyphs.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        owner.drawText(in: context)
        layer?.contents = context.makeImage()
        layer?.contentsScale = scale
    }
}

/// Gradient fill, 1 px rim, and keycap plate of the hint (its own backing layer).
@MainActor
private final class HintBackgroundView: NSView {
    init(frame: CGRect, fill: (top: RGBA, bottom: RGBA), plateFill: RGBA, plate frameOfPlate: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        let m = HintToastMetrics.self
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [fill.top.cgColor, fill.bottom.cgColor]
        // The view is flipped: start at the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = m.radius; gradient.cornerCurve = .continuous; gradient.masksToBounds = true
        gradient.borderWidth = 1; gradient.borderColor = RGBA.black(ToastMetrics.rimAlpha).cgColor
        let plate = CALayer()
        plate.frame = frameOfPlate
        plate.cornerRadius = m.plateRadius; plate.cornerCurve = .continuous
        plate.backgroundColor = plateFill.cgColor
        gradient.addSublayer(plate)
        layer?.addSublayer(gradient)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
