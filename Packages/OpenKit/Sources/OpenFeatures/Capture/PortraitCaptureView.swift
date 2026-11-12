import AppKit
import OpenDesign

/// The Capture in Portrait Mode popover content (PB2 row 4; capture `43-pb2-probe`, 286 × 246 pt):
/// a full-width button, the preview on its background with the watermark tile, and a row with
/// "Use Website Color", the colour slider and "Use Desktop Wallpaper". Frames come from the
/// capture's accessibility tree (`CaptureMetrics.portrait*`); fills and strokes are GUESS (LOOK STOP).
@MainActor
public final class PortraitCaptureView: NSView {
    public var style: PortraitStyle { didSet { if style != oldValue { needsLayout = true; needsDisplay = true; for v in [left, right, slider] { v.needsDisplay = true } } } }
    public var onCapture: (() -> Void)?
    public var onStyle: ((PortraitStyle) -> Void)?
    /// The composed preview (the page on its background at preview size).
    public var preview: CGImage? { didSet { previewLayer.contents = preview } }

    public let captureButton = PortraitCaptureButton()
    public let left = PortraitSwatch(kind: .website)
    public let right = PortraitSwatch(kind: .wallpaper)
    public let slider = PortraitColorSlider()
    public let watermarkButton = NSButton()
    private let previewLayer = CALayer()
    private let previewHost = NSView()

    public init(style: PortraitStyle) {
        self.style = style
        super.init(frame: CGRect(origin: .zero, size: CaptureMetrics.portraitPopoverSize))
        captureButton.target = self; captureButton.action = #selector(capture)
        captureButton.setAccessibilityIdentifier("portraitCaptureButton")
        addSubview(captureButton)
        previewHost.wantsLayer = true
        previewHost.layer?.cornerRadius = CaptureMetrics.portraitPreviewRadius; previewHost.layer?.masksToBounds = true
        previewHost.layer?.cornerCurve = .continuous
        previewLayer.contentsGravity = .resizeAspectFill
        previewHost.layer?.addSublayer(previewLayer)
        previewHost.setAccessibilityElement(true); previewHost.setAccessibilityRole(.image)
        previewHost.setAccessibilityLabel("Portrait preview"); previewHost.setAccessibilityIdentifier("portraitPreview")
        addSubview(previewHost)
        // Arc: "Portrait Capture Watermark Toggle", the tile at the preview's bottom-left.
        watermarkButton.isBordered = false; watermarkButton.title = ""; watermarkButton.setButtonType(.momentaryChange)
        watermarkButton.target = self; watermarkButton.action = #selector(toggleWatermark)
        watermarkButton.setAccessibilityLabel("Portrait Capture Watermark Toggle")
        watermarkButton.setAccessibilityIdentifier("portraitWatermarkToggle")
        addSubview(watermarkButton)
        left.onPress = { [weak self] in self?.pick(.website) }
        right.onPress = { [weak self] in self?.pick(.wallpaper) }
        slider.style = { [weak self] in self?.style ?? .standard }
        slider.onChange = { [weak self] value in
            guard let self else { return }
            var next = self.style; next.source = .color; next.colorPercentage = value; self.update(next)
        }
        for v in [left, right, slider] as [NSView] { addSubview(v) }
        left.isSelected = { [weak self] in self?.style.source == .website }
        right.isSelected = { [weak self] in self?.style.source == .wallpaper }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        captureButton.frame = CaptureMetrics.portraitButtonFrame
        previewHost.frame = CaptureMetrics.portraitPreviewFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = previewHost.bounds
        CATransaction.commit()
        let p = CaptureMetrics.portraitPreviewFrame, tile = p.width * CaptureMetrics.portraitWatermarkFraction
        let inset = p.width * CaptureMetrics.portraitWatermarkInsetFraction
        watermarkButton.frame = CGRect(x: p.minX + inset, y: p.maxY - inset - tile, width: tile, height: tile)
        let s = CaptureMetrics.portraitSwatchSize
        left.frame = CGRect(origin: CaptureMetrics.portraitLeftSwatchOrigin, size: CGSize(width: s, height: s))
        right.frame = CGRect(origin: CaptureMetrics.portraitRightSwatchOrigin, size: CGSize(width: s, height: s))
        // The slider spans between the swatches (capture: track 20 pt right of the left swatch's
        // centre to 20 pt left of the right one's; knob 23 pt).
        let midY = left.frame.midY, x0 = left.frame.midX + 20, x1 = right.frame.midX - 20
        slider.frame = CGRect(x: x0 - 11.5, y: midY - 11.5, width: x1 - x0 + 23, height: 23)
    }

    func update(_ next: PortraitStyle) {
        guard next != style else { return }
        style = next; onStyle?(next)
    }
    public func pick(_ source: PortraitStyle.Source) { var next = style; next.source = source; update(next) }
    @objc private func toggleWatermark() { var next = style; next.hidesWatermark.toggle(); update(next) }
    @objc private func capture() { onCapture?() }
}

/// The popover's full-width button. White fill, hairline edge (GUESS colours), 16 pt title.
@MainActor
public final class PortraitCaptureButton: NSButton {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = "Capture in Portrait Mode"; setButtonType(.momentaryPushIn)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.cornerCurve = .continuous; layer?.borderWidth = 1
        font = .systemFont(ofSize: 15, weight: .regular)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override public var wantsUpdateLayer: Bool { true }
    override public func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: isHighlighted ? 0.16 : 0.10) : NSColor(white: isHighlighted ? 0.94 : 1, alpha: 1)).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.16).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 15), .foregroundColor: dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.16, alpha: 1)])
    }
}

/// A round 17 pt swatch: "Use Website Color" (white) or "Use Desktop Wallpaper" (grey).
@MainActor
public final class PortraitSwatch: NSView {
    public enum Kind { case website, wallpaper }
    let kind: Kind
    var onPress: (() -> Void)?
    var isSelected: () -> Bool = { false }
    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        // Arc's labels (ContentPanel strings).
        setAccessibilityLabel(kind == .website ? "Use Website Color" : "Use Desktop Wallpaper")
        setAccessibilityIdentifier(kind == .website ? "portraitWebsiteSwatch" : "portraitWallpaperSwatch")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override public func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override public func accessibilityValue() -> Any? { isSelected() ? 1 : 0 }
    override public func mouseDown(with event: NSEvent) { onPress?() }
    override public func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (kind == .website ? NSColor(white: 0.97, alpha: 1) : NSColor(white: dark ? 0.55 : 0.84, alpha: 1)).setFill(); circle.fill()
        NSColor(white: 0, alpha: dark ? 0.35 : 0.14).setStroke(); circle.lineWidth = 1; circle.stroke()
        if isSelected() {
            // Selected: an accent ring inside the edge (GUESS: not in the capture, which shows the slider chosen).
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke(); ring.stroke()
        }
    }
}

/// The colour slider: a rainbow capsule, 12 pt tall, with a 23 pt white knob.
@MainActor
public final class PortraitColorSlider: NSView {
    var style: () -> PortraitStyle = { .standard }
    var onChange: ((Double) -> Void)?
    static let knob: CGFloat = 23, track: CGFloat = 12
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Color")
        setAccessibilityIdentifier("portraitColorSlider")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override public var isFlipped: Bool { true }
    var trackRect: CGRect { CGRect(x: Self.knob / 2, y: (bounds.height - Self.track) / 2, width: bounds.width - Self.knob, height: Self.track) }
    public var knobCenterX: CGFloat { trackRect.minX + trackRect.width * CGFloat(style().colorPercentage) }
    override public func accessibilityValue() -> Any? { style().colorPercentage }
    override public func setAccessibilityValue(_ value: Any?) { if let v = value as? Double { onChange?(min(1, max(0, v))) } }
    override public func mouseDown(with event: NSEvent) { track(event) }
    override public func mouseDragged(with event: NSEvent) { track(event) }
    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x, t = trackRect
        onChange?(Double(min(1, max(0, (x - t.minX) / max(1, t.width)))))
        needsDisplay = true
    }
    override public func draw(_ dirtyRect: NSRect) {
        let t = trackRect, capsule = NSBezierPath(roundedRect: t, xRadius: t.height / 2, yRadius: t.height / 2)
        let colors = PortraitStyle.sliderStops.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
        NSGradient(colors: colors)?.draw(in: capsule, angle: 0)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: 0, alpha: dark ? 0.3 : 0.08).setStroke(); capsule.lineWidth = 1; capsule.stroke()
        let knob = CGRect(x: knobCenterX - Self.knob / 2, y: (bounds.height - Self.knob) / 2, width: Self.knob, height: Self.knob)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.25); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
