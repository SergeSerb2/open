import AppKit
import CoreText
import OpenDesign

/// One toast pill (page-platform §4.1.2): `[symbol?][keycaps?][title / subtitle][button?]` over a
/// vertical gradient with a 1 px rim and a soft shadow. Geometry: `ToastMetrics` (PG-1.1–1.4);
/// colors: the shared `SpaceThemeStyle` toast rule. Only the button takes clicks.
@MainActor
public final class ToastView: NSView {
    public private(set) var content: ToastContent
    public private(set) var style: SpaceThemeStyle
    /// The 32 × 27 button (`.button` accessory), or nil.
    public private(set) var accessoryButton: ToastAccessoryButton?
    /// Title and subtitle origin frames in view coordinates (flipped), for checks.
    public private(set) var titleFrame: CGRect = .zero
    public private(set) var keycapFrames: [CGRect] = []
    var onHover: ((Bool) -> Void)?
    var onAccessory: (() -> Void)?
    private let fill = ToastFillView()
    private let text = ToastTextView()
    private var symbolView: NSImageView?
    private var trackingArea: NSTrackingArea?

    public init(content: ToastContent, style: SpaceThemeStyle) {
        self.content = content; self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        let layer = self.layer!
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = ToastMetrics.shadowOpacity
        layer.shadowRadius = ToastMetrics.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: -ToastMetrics.shadowOffsetY)
        addSubview(fill); addSubview(text)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        apply(content, style: style)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    /// The body passes clicks through; only the button answers.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let button = accessoryButton, !button.isHidden, button.isEnabled else { return nil }
        let local = convert(point, from: superview)
        return button.frame.contains(local) ? button : nil
    }

    /// Lays the toast out for `content` and returns nothing; `frame.size` is the toast size.
    public func apply(_ content: ToastContent, style: SpaceThemeStyle) {
        self.content = content; self.style = style
        let m = ToastMetrics.self
        let hasButton: Bool, keycaps: [String]
        switch content.accessory {
        case .button: hasButton = true; keycaps = []
        case .keycaps(let keys): hasButton = false; keycaps = keys
        case .none: hasButton = false; keycaps = []
        }
        let height = m.height(hasSubtitle: content.subtitle != nil, hasButton: hasButton)
        text.configure(title: content.title, subtitle: content.subtitle, style: style)
        let keyLines = keycaps.map { ToastTextView.line($0, font: Typography.toast.font, color: style.toastText) }
        let keyWidths = keyLines.map { line -> CGFloat in
            let ink = CTLineGetImageBounds(line, nil).width
            let width = ink > 0 ? ink : CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return (width + m.keycapInkPadding).rounded(.down)
        }
        var lead = m.leadingPadding
        if content.symbol != nil { lead += m.symbolSize + m.symbolToTitle }
        if !keyWidths.isEmpty { lead += keyWidths.reduce(0, +) + m.keycapGap * CGFloat(keyWidths.count - 1) + m.keycapToTitle }
        let trailing = hasButton ? m.labelToAccessory + m.accessorySize.width + m.accessoryTrailing : m.trailingPadding
        let natural = (lead + text.naturalWidth + trailing).rounded(.up)
        let width = min(m.maxWidth, max(m.minWidth, natural))
        let textWidth = width - lead - trailing
        // A short text-only toast ("90%") is padded to the minimum width with the text centered.
        let slack = max(0, width - natural)
        frame.size = CGSize(width: width, height: height)
        fill.frame = bounds
        var x = m.leadingPadding + slack / 2
        if let symbol = content.symbol {
            let view = symbolView ?? NSImageView()
            if symbolView == nil { symbolView = view; addSubview(view) }
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: m.symbolSize, weight: .medium)).map { ToastView.tinted($0, style.toastText) }
            view.frame = CGRect(x: x, y: ((height - m.symbolSize) / 2).rounded(), width: m.symbolSize, height: m.symbolSize)
            x += m.symbolSize + m.symbolToTitle
        } else { symbolView?.removeFromSuperview(); symbolView = nil }
        keycapFrames = []
        for (i, keyWidth) in keyWidths.enumerated() {
            keycapFrames.append(CGRect(x: x.rounded(), y: ((height - m.keycapHeight) / 2).rounded(), width: keyWidth, height: m.keycapHeight))
            x += keyWidth + (i == keyWidths.count - 1 ? m.keycapToTitle : m.keycapGap)
        }
        fill.configure(style: style, keycaps: keycapFrames)
        text.keycaps = zip(keyLines, keycapFrames).map { ($0, $1) }
        text.frame = bounds
        titleFrame = text.layoutLines(x: x, width: textWidth, height: height)
        if hasButton, case .button(let symbol, let label) = content.accessory {
            let button = accessoryButton ?? ToastAccessoryButton()
            if accessoryButton == nil {
                accessoryButton = button; addSubview(button)
                button.perform = { [weak self] in self?.onAccessory?() }
            }
            button.configure(symbol: symbol, label: label, style: style)
            let top = content.subtitle == nil ? m.accessoryTop : ((height - m.accessorySize.height) / 2).rounded()
            button.frame = CGRect(x: width - m.accessoryTrailing - m.accessorySize.width, y: top,
                                  width: m.accessorySize.width, height: m.accessorySize.height)
        } else { accessoryButton?.removeFromSuperview(); accessoryButton = nil }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: m.cornerRadius, cornerHeight: m.cornerRadius, transform: nil)
        setAccessibilityLabel([content.title, content.subtitle].compactMap { $0 }.joined(separator: ", "))
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); trackingArea = area
    }
    public override func mouseEntered(with event: NSEvent) { onHover?(true) }
    public override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Gradient fill (top → bottom), corner, rim, for checks.
    public var fillColors: (top: RGBA, bottom: RGBA) { style.toastFill }
    public var cornerRadius: CGFloat { fill.gradient.cornerRadius }
    public var cornerCurve: CALayerCornerCurve { fill.gradient.cornerCurve }
    public var titleFont: NSFont { Typography.toast.font }
    public var titleColor: RGBA { style.toastText }
    public var titleLineIsTruncated: Bool { text.titleTruncated }
    /// A symbol drawn in the text color, cut-outs kept (`quote.bubble.fill`'s quotes). A borderless
    /// button does not tint its template image, so the image carries the color.
    static func tinted(_ symbol: NSImage, _ color: RGBA) -> NSImage {
        let color = color.nsColor
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set(); rect.fill(using: .sourceAtop)
            return true
        }
        image.accessibilityDescription = symbol.accessibilityDescription
        return image
    }
}

/// The gradient, rim, and keycap plates (one layer tree, no drawing).
@MainActor
private final class ToastFillView: NSView {
    let gradient = CAGradientLayer()
    private var plates: [CALayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.cornerRadius = ToastMetrics.cornerRadius; gradient.cornerCurve = .continuous; gradient.masksToBounds = true
        gradient.borderWidth = 1; gradient.borderColor = RGBA.black(ToastMetrics.rimAlpha).cgColor
        // The view is flipped: start at the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(style: SpaceThemeStyle, keycaps: [CGRect]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let fill = style.toastFill
        gradient.colors = [fill.top.cgColor, fill.bottom.cgColor]
        plates.forEach { $0.removeFromSuperlayer() }
        plates = keycaps.map { frame in
            let plate = CALayer()
            plate.frame = frame; plate.cornerRadius = ToastMetrics.keycapRadius; plate.cornerCurve = .continuous
            plate.backgroundColor = style.toastKeycapFill.cgColor
            gradient.addSublayer(plate)
            return plate
        }
        CATransaction.commit()
    }
}

/// Title, subtitle and keycap text drawn with CoreText (ink placed like the hint toast; the title
/// truncates in the middle).
@MainActor
private final class ToastTextView: NSView {
    private var title: CTLine?
    private var subtitle: CTLine?
    private var titleFull: CTLine?
    private var subtitleFull: CTLine?
    private var titleOrigin = CGPoint.zero
    private var subtitleOrigin = CGPoint.zero
    private var color = RGBA.white(1), subtitleColor = RGBA.white(0.8)
    private var titleString = "", subtitleString: String?
    var keycaps: [(CTLine, CGRect)] = [] { didSet { needsDisplay = true } }
    private(set) var titleTruncated = false
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setAccessibilityElement(true); setAccessibilityRole(.staticText) }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func line(_ string: String, font: NSFont, color: RGBA) -> CTLine {
        // CoreText reads a CGColor foreground (an NSColor value is ignored).
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
    }
    func configure(title: String, subtitle: String?, style: SpaceThemeStyle) {
        titleString = title; subtitleString = subtitle
        color = style.toastText; subtitleColor = style.toastSubtitleText
        titleFull = Self.line(title, font: Typography.toast.font, color: color)
        subtitleFull = subtitle.map { Self.line($0, font: Typography.toastSubtitle.font, color: subtitleColor) }
        setAccessibilityValue([title, subtitle].compactMap { $0 }.joined(separator: "\n"))
    }
    var naturalWidth: CGFloat {
        let widths = [titleFull, subtitleFull].compactMap { $0 }.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        return (widths.max() ?? 0).rounded(.up)
    }
    /// Places the lines in `width` from `x`, centered as a block in `height`; returns the title box.
    func layoutLines(x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        func fit(_ line: CTLine?) -> (CTLine?, Bool) {
            guard let line else { return (nil, false) }
            guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > width + 0.5 else { return (line, false) }
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                .font: Typography.toast.font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
            return (CTLineCreateTruncatedLine(line, Double(width), .middle, ellipsis) ?? line, true)
        }
        (title, titleTruncated) = fit(titleFull)
        subtitle = fit(subtitleFull).0
        func metrics(_ line: CTLine?) -> (ascent: CGFloat, descent: CGFloat) {
            guard let line else { return (0, 0) }
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return (ascent, descent)
        }
        let t = metrics(title), s = metrics(subtitle)
        let titleHeight = t.ascent + t.descent
        let block = subtitle == nil ? titleHeight : titleHeight + ToastMetrics.lineGap + s.ascent + s.descent
        let top = (height - block) / 2
        titleOrigin = CGPoint(x: x, y: top + t.ascent)
        subtitleOrigin = CGPoint(x: x, y: top + titleHeight + ToastMetrics.lineGap + s.ascent)
        needsDisplay = true
        let titleWidth = title.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        return CGRect(x: x, y: top, width: titleWidth, height: titleHeight)
    }
    /// Rendered once per change into the layer's contents at the backing scale (as the hint toast).
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Flip to the view's top-left coordinates, then let CoreText draw upright glyphs.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        drawText(in: context)
        layer?.contents = context.makeImage()
        layer?.contentsScale = scale
    }
    private func drawText(in context: CGContext) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if let title { context.textPosition = titleOrigin; CTLineDraw(title, context) }
        if let subtitle { context.textPosition = subtitleOrigin; CTLineDraw(subtitle, context) }
        for (line, plate) in keycaps {
            let ink = CTLineGetImageBounds(line, nil)
            context.textPosition = CGPoint(x: plate.midX - ink.midX, y: titleOrigin.y)
            CTLineDraw(line, context)
        }
    }
}

/// The toast's one button (Share, Undo, Stop, Show in Finder, Copy Quote Link): 32 × 27, a
/// white 0.22 plate (PG-1.3). It never takes focus.
@MainActor
public final class ToastAccessoryButton: NSButton {
    var perform: (() -> Void)?
    public private(set) var symbolName = ""
    private var fill = RGBA.white(0.22), pressedFill = RGBA.white(0.32)
    public private(set) var isPressedDown = false
    init() {
        super.init(frame: .zero)
        isBordered = false; title = ""; imagePosition = .imageOnly; focusRingType = .none
        refusesFirstResponder = true; wantsLayer = true
        layer?.cornerRadius = ToastMetrics.accessoryRadius; layer?.cornerCurve = .continuous
        target = self; action = #selector(fire)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(symbol: String, label: String, style: SpaceThemeStyle) {
        symbolName = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: ToastMetrics.accessorySymbolSize, weight: .medium)).map { ToastView.tinted($0, style.toastText) }
        fill = style.toastAccessoryFill; pressedFill = style.toastAccessoryPressedFill
        layer?.backgroundColor = fill.cgColor
        setAccessibilityLabel(label); toolTip = nil
    }
    public override func mouseDown(with event: NSEvent) {
        setPressed(true)
        super.mouseDown(with: event) // tracks until the mouse goes up
        setPressed(false)
    }
    private func setPressed(_ pressed: Bool) {
        isPressedDown = pressed
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = (pressed ? pressedFill : fill).cgColor
        CATransaction.commit()
    }
    @objc private func fire() { perform?() }
}
