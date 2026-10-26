import AppKit
import QuartzCore
import OpenDesign
import OpenBoosts

/// AppKit view with template glyphs, keyboard activation and an accessibility press action.
@MainActor
public class SiteControlButton: NSView {
    public let controlID: String
    public var symbol: String { didSet { needsDisplay = true } }
    public var tint = Core.foregroundSecondary
    public var invoke: (() -> Void)?
    public var onKey: ((NSEvent) -> Bool)?
    public var statusOnly = false
    public var title = "" { didSet { needsDisplay = true } }
    private var hoverText: String?
    public override var toolTip: String? { get { hoverText } set { hoverText = newValue } }
    public var isEnabled = true { didSet { setAccessibilityEnabled(isEnabled); needsDisplay = true } }
    private var isHighlighted = false
    private lazy var glyphLayer = CALayer()
    private lazy var captionLayer = CALayer()
    private lazy var buttonFocus = CAShapeLayer()
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    public var tooltipKeys: [String] = []
    private var hovered = false
    private var cachedGlyphName: String?
    private var cachedGlyphColor: NSColor?
    private var cachedGlyph: (image: CGImage, size: CGSize)?
    func glyphRaster(_ name: String, color: NSColor) -> (image: CGImage, size: CGSize)? {
        if cachedGlyphName != name || cachedGlyphColor != color {
            cachedGlyphName = name; cachedGlyphColor = color
            cachedGlyph = SiteControlDrawing.raster(name, size: pointSize, color: color, weight: weight)
        }
        return cachedGlyph
    }
    var drawsStandardButton: Bool { true }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public init(id: String, label: String, symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) {
        self.controlID = id; self.symbol = symbol; self.pointSize = pointSize; self.weight = weight
        super.init(frame: .zero)
        focusRingType = .none; wantsLayer = true
        if drawsStandardButton {
            glyphLayer.contentsGravity = .resizeAspect
            for child in [glyphLayer, captionLayer, buttonFocus] { child.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "path": NSNull(), "strokeColor": NSNull()]; layer?.addSublayer(child) }
            buttonFocus.fillColor = nil; buttonFocus.lineWidth = SiteControlMetrics.focusWidth
        }
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label); identifier = NSUserInterfaceItemIdentifier(id); toolTip = label
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func performClick(_ sender: Any?) { guard isEnabled else { return }; invoke?() }
    public override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; performClick(nil); return true }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }; window?.makeFirstResponder(self)
        hideTooltip(); isHighlighted = true; needsDisplay = true
    }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func mouseUp(with event: NSEvent) {
        let pressed = isHighlighted; isHighlighted = false; needsDisplay = true
        if pressed && bounds.contains(convert(event.locationInWindow, from: nil)) { performClick(nil) }
    }
    public override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if event.keyCode == 36 || event.keyCode == 49 { performClick(nil); return }
        super.keyDown(with: event)
    }
    public override var intrinsicContentSize: NSSize {
        CGSize(width: pointSize + (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: SiteControlMetrics.securityGlyph, weight: .medium)]).width + SiteControlMetrics.securityPadding * 3,
               height: SiteControlMetrics.footerButton)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; fadeHover(); showTooltip() }
    public override func mouseExited(with event: NSEvent) { hovered = false; fadeHover(); hideTooltip() }
    func showTooltip() {
        guard let toolTip else { return }
        TooltipController.shared.schedule(Tooltip(title: toolTip, keys: tooltipKeys, style: .defaultTheme(system: contentAppearance)), for: self)
    }
    func hideTooltip() { TooltipController.shared.cancel(for: self) }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hideTooltip() } }
    func fadeHover() {
        wantsLayer = true
        let transition = CATransition(); transition.type = .fade; transition.duration = Motion.hoverFade
        layer?.add(transition, forKey: "hover.fill"); needsDisplay = true
    }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        let m = SiteControlMetrics.self
        let resolved = tint.resolved(contentAppearance).nsColor
        let color = resolved.withAlphaComponent(resolved.alphaComponent * (isEnabled || statusOnly ? 1 : m.disabledAlpha))
        let fill = hovered && isEnabled ? (isHighlighted ? SidebarColors.itemHoveredBackground : SidebarColors.itemBackground).cgColor(contentAppearance) : NSColor.clear.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = fill; layer?.cornerRadius = m.actionRadius; layer?.cornerCurve = .continuous
        var captionX: CGFloat = 0
        if let raster = glyphRaster(symbol, color: color) {
            glyphLayer.contents = raster.image
            let x = title.isEmpty ? (bounds.width - raster.size.width) / 2 : m.securityPadding
            glyphLayer.frame = CGRect(x: x, y: (bounds.height - raster.size.height) / 2, width: raster.size.width, height: raster.size.height)
            captionX = glyphLayer.frame.maxX + m.securityPadding
        } else { glyphLayer.contents = nil }
        let font = NSFont.systemFont(ofSize: m.bodySize, weight: title.isEmpty ? .regular : .semibold)
        let captionSize = CGSize(width: max(0, bounds.width - captionX), height: bounds.height)
        captionLayer.frame = CGRect(origin: CGPoint(x: captionX, y: 0), size: captionSize)
        captionLayer.contents = SiteControlDrawing.caption(title, size: captionSize, font: font, color: color, centered: symbol.isEmpty)
        buttonFocus.frame = bounds
        buttonFocus.path = CGPath(roundedRect: bounds.insetBy(dx: m.focusWidth / 2, dy: m.focusWidth / 2), cornerWidth: m.actionRadius, cornerHeight: m.actionRadius, transform: nil)
        buttonFocus.strokeColor = window?.firstResponder === self ? Core.focusRing.cgColor(contentAppearance) : nil
        CATransaction.commit()
    }

}

@MainActor
enum SiteControlDrawing {
    private struct SymbolKey: Hashable { let name: String; let size: CGFloat; let color: NSColor; let weight: CGFloat }
    private static var symbols: [SymbolKey: NSImage] = [:]
    private static var pixels: [SymbolKey: CGImage] = [:]
    private struct TextKey: Hashable { let text: String; let width: CGFloat; let font: NSFont; let color: NSColor }
    private static var lines: [TextKey: CTLine] = [:]
    private struct CaptionKey: Hashable { let title: String; let size: CGSize; let font: NSFont; let color: NSColor; let centered: Bool }
    private static var captions: [CaptionKey: CGImage] = [:]
    static func caption(_ title: String, size: CGSize, font: NSFont, color: NSColor, centered: Bool) -> CGImage? {
        guard !title.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let key = CaptionKey(title: title, size: size, font: font, color: color, centered: centered)
        if let cached = captions[key] { return cached }
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2); context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text(title, x: 0, baseline: (size.height + font.ascender + font.descender) / 2, width: size.width, font: font, color: color, alignment: centered ? .center : .left)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if captions.count >= 32 { captions.removeAll(keepingCapacity: true) }; captions[key] = image; return image
    }
    private struct TileLabelKey: Hashable { let title: String; let subtitle: String; let inUse: Bool; let appearance: ContentAppearance }
    private static var tileLabels: [TileLabelKey: CGImage] = [:]
    static func labels(for tile: SiteSettingTile, appearance: ContentAppearance) -> CGImage? {
        let key = TileLabelKey(title: tile.title, subtitle: tile.subtitle, inUse: tile.inUse, appearance: appearance)
        if let cached = tileLabels[key] { return cached }
        let m = SiteControlMetrics.self
        guard let context = CGContext(data: nil, width: Int(m.tile.width * 2), height: Int(m.tile.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2); context.translateBy(x: 0, y: m.tile.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let width = m.tile.width - m.tileTextX - m.tileTextTrailing
        text(tile.title, x: m.tileTextX, baseline: m.tileTitleBaseline, width: width - (tile.inUse ? m.inUseDot + m.inUseGap : 0), font: Typography.tileTitle.font, color: Core.foregroundPrimary.resolved(appearance).nsColor)
        text(tile.subtitle, x: m.tileTextX, baseline: m.tileSubtitleBaseline, width: width, font: Typography.tileSubtitle.font, color: Core.foregroundSecondary.resolved(appearance).nsColor)
        if tile.inUse {
            context.setFillColor(Core.brandBlue.cgColor(appearance))
            let titleWidth = (tile.title as NSString).size(withAttributes: [.font: Typography.tileTitle.font]).width
            context.fillEllipse(in: CGRect(x: min(m.tileTextX + titleWidth + m.inUseGap, m.tile.width - m.tileTextTrailing - m.inUseDot), y: m.tileTitleBaseline - m.inUseDot, width: m.inUseDot, height: m.inUseDot))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if tileLabels.count >= 32 { tileLabels.removeAll(keepingCapacity: true) }
        tileLabels[key] = image; return image
    }
    static func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        guard !name.isEmpty else { return nil }
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = SymbolKey(name: name, size: size, color: resolved, weight: weight.rawValue)
        if let cached = symbols[key] { return cached }
        guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        // NSImage's symbol representation resolves/rasterizes again for every new
        // backing context. Cache our rendered system glyph as a 2x bitmap instead.
        let points = source.size
        guard let context = CGContext(data: nil, width: max(1, Int(ceil(points.width * 2))), height: max(1, Int(ceil(points.height * 2))),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: CGRect(origin: .zero, size: points), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        context.setBlendMode(.sourceIn); context.setFillColor(resolved.cgColor)
        context.fill(CGRect(origin: .zero, size: points))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = context.makeImage() else { return nil }
        let image = NSImage(cgImage: pixels, size: points)
        if symbols.count >= 256 { symbols.removeAll(keepingCapacity: true); self.pixels.removeAll(keepingCapacity: true) }
        self.pixels[key] = pixels
        symbols[key] = image; return image
    }
    static func raster(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> (image: CGImage, size: CGSize)? {
        let key = SymbolKey(name: name, size: size, color: color.usingColorSpace(.sRGB) ?? color, weight: weight.rawValue)
        if let pixels = pixels[key], let image = symbols[key] { return (pixels, image.size) }
        guard let image = symbol(name, size: size, color: color, weight: weight), let pixels = pixels[key] else { return nil }
        return (pixels, image.size)
    }
    static func bitmap(_ image: CGImage, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    static func text(_ text: String, x: CGFloat, baseline: CGFloat, width: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard width > 0, !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let key = TextKey(text: text, width: width, font: font, color: color)
        let line: CTLine
        if let cached = lines[key] { line = cached }
        else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            var created = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if CTLineGetTypographicBounds(created, nil, nil, nil) > width {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                guard let truncated = CTLineCreateTruncatedLine(created, width, .end, token) else { return }; created = truncated
            }
            if lines.count >= 256 { lines.removeAll(keepingCapacity: true) }
            lines[key] = created; line = created
        }
        let actual = CTLineGetTypographicBounds(line, nil, nil, nil)
        let offset = alignment == .right ? width - actual : (alignment == .center ? (width - actual) / 2 : 0)
        context.saveGState(); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x + offset, y: baseline); CTLineDraw(line, context); context.restoreGState()
    }
    static func glyph(_ symbol: String, in rect: CGRect, size: CGFloat, color: NSColor) {
        guard let raster = self.raster(symbol, size: size, color: color) else { return }
        bitmap(raster.image, in: CGRect(x: rect.midX - raster.size.width / 2, y: rect.midY - raster.size.height / 2, width: raster.size.width, height: raster.size.height))
    }
    static func focus(_ view: NSView, radius: CGFloat) {
        guard view.window?.firstResponder === view else { return }
        Core.focusRing.resolved(view.contentAppearance).nsColor.setStroke()
        let shape = NSBezierPath(roundedRect: view.bounds.insetBy(dx: SiteControlMetrics.focusWidth / 2, dy: SiteControlMetrics.focusWidth / 2), xRadius: radius, yRadius: radius)
        shape.lineWidth = SiteControlMetrics.focusWidth; shape.stroke()
    }
    static func accent(_ id: BoostID) -> DesignColor {
        // Stable across launches, unlike Swift's per-process hashValue.
        let value = id.description.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return BoostEditorColors.accents[Int(value % UInt64(BoostEditorColors.accents.count))]
    }
}

@MainActor
final class SiteControlTileButton: SiteControlButton {
    override var drawsStandardButton: Bool { false }
    private(set) var tile: SiteSettingTile
    private let circle = CALayer()
    private let icon = CALayer()
    private let labels = CALayer()
    private let focusRing = CAShapeLayer()
    private var hovered = false
    init(_ tile: SiteSettingTile) {
        self.tile = tile
        super.init(id: tile.id, label: tile.title, symbol: tile.symbol, pointSize: SiteControlMetrics.tileGlyph)
        wantsLayer = true; layer?.addSublayer(circle); circle.addSublayer(icon)
        layer?.addSublayer(labels); layer?.addSublayer(focusRing)
        labels.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        focusRing.fillColor = nil; focusRing.lineWidth = SiteControlMetrics.focusWidth
        focusRing.actions = ["path": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        icon.contentsGravity = .resizeAspect
        circle.cornerRadius = SiteControlMetrics.tileIcon / 2
        circle.actions = ["position": NSNull(), "bounds": NSNull()]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func apply(_ tile: SiteSettingTile, animated: Bool) {
        self.tile = tile
        setAccessibilityLabel(tile.title)
        setAccessibilityRole(tile.state == .unavailable ? .button : .checkBox)
        setAccessibilityValue(tile.state == .on ? 1 : 0)
        setAccessibilityValueDescription(tile.subtitle)
        setAccessibilityHelp(tile.help); toolTip = tile.help
        CATransaction.begin(); CATransaction.setAnimationDuration(animated ? Motion.selectionFade : 0)
        CATransaction.setDisableActions(!animated)
        circle.backgroundColor = (tile.state == .on ? Core.brandBlue : GrayScale.a(4)).cgColor(contentAppearance)
        let raster = glyphRaster(tile.symbol, color: tile.state == .on ? .white : Core.foregroundSecondary.resolved(contentAppearance).nsColor)
        icon.contents = raster?.image
        labels.contents = SiteControlDrawing.labels(for: tile, appearance: contentAppearance)
        CATransaction.commit(); needsDisplay = true
    }
    override func layout() {
        super.layout()
        circle.frame = CGRect(x: SiteControlMetrics.tileIconInset, y: SiteControlMetrics.tileIconInset, width: SiteControlMetrics.tileIcon, height: SiteControlMetrics.tileIcon)
        icon.frame = circle.bounds.insetBy(dx: (SiteControlMetrics.tileIcon - SiteControlMetrics.tileGlyph) / 2, dy: (SiteControlMetrics.tileIcon - SiteControlMetrics.tileGlyph) / 2)
        labels.frame = bounds; focusRing.frame = bounds
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; fadeHover(); showTooltip() }
    override func mouseExited(with event: NSEvent) { hovered = false; fadeHover(); hideTooltip() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let m = SiteControlMetrics.self
        let fill = (hovered ? SidebarColors.itemHoveredBackground : SidebarColors.itemBackground).cgColor(contentAppearance)
        if let old = layer?.backgroundColor, old != fill {
            let animation = CABasicAnimation(keyPath: "backgroundColor"); animation.fromValue = old; animation.toValue = fill
            animation.duration = Motion.hoverFade; layer?.add(animation, forKey: "hover.background")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = fill; layer?.cornerRadius = m.tileRadius; layer?.cornerCurve = .continuous
        focusRing.path = CGPath(roundedRect: bounds.insetBy(dx: m.focusWidth / 2, dy: m.focusWidth / 2), cornerWidth: m.tileRadius + m.focusOutset, cornerHeight: m.tileRadius + m.focusOutset, transform: nil)
        focusRing.strokeColor = window?.firstResponder === self ? Core.focusRing.cgColor(contentAppearance) : nil
        CATransaction.commit()
    }
}

@MainActor
final class SiteControlSectionButton: SiteControlButton {
    override var drawsStandardButton: Bool { false }
    let caption: String
    let accessory: String
    private let heading: NSTextField
    private let hoverLabel: NSTextField
    private let chevron = NSImageView()
    private var hovered = false
    init(id: String, caption: String, accessory: String) {
        self.caption = caption; self.accessory = accessory
        heading = NSTextField(labelWithString: caption); hoverLabel = NSTextField(labelWithString: accessory)
        super.init(id: id, label: caption + ", " + accessory, symbol: "", pointSize: SiteControlMetrics.bodySize)
        heading.font = Typography.sectionTitle.font; heading.textColor = Core.foregroundSecondary.nsColor
        heading.setAccessibilityElement(true); heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading")); heading.setAccessibilityLabel(caption)
        hoverLabel.font = NSFont.systemFont(ofSize: SiteControlMetrics.bodySize, weight: .medium)
        hoverLabel.textColor = Core.brandBlue.nsColor; hoverLabel.alphaValue = 0
        hoverLabel.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false); chevron.alphaValue = 0
        chevron.image = SiteControlDrawing.symbol("chevron.right", size: SiteControlMetrics.sectionChevron, color: Core.brandBlue.light.nsColor)
        addSubview(heading); addSubview(hoverLabel); addSubview(chevron)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        heading.sizeToFit(); hoverLabel.sizeToFit()
        heading.setFrameOrigin(CGPoint(x: SiteControlMetrics.inset, y: (bounds.height - heading.frame.height) / 2))
        chevron.frame = CGRect(x: bounds.width - SiteControlMetrics.inset - SiteControlMetrics.sectionChevron, y: (bounds.height - SiteControlMetrics.sectionChevron) / 2, width: SiteControlMetrics.sectionChevron, height: SiteControlMetrics.sectionChevron)
        hoverLabel.setFrameOrigin(CGPoint(x: chevron.frame.minX - SiteControlMetrics.accessoryGap - hoverLabel.frame.width, y: (bounds.height - hoverLabel.frame.height) / 2))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.hoverFade
            hoverLabel.animator().alphaValue = hovered || window?.firstResponder === self ? 1 : 0
            chevron.animator().alphaValue = hovered || window?.firstResponder === self ? 1 : 0
        }
    }
    override func becomeFirstResponder() -> Bool { hoverLabel.alphaValue = 1; chevron.alphaValue = 1; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { if !hovered { hoverLabel.alphaValue = 0; chevron.alphaValue = 0 }; return super.resignFirstResponder() }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        SiteControlDrawing.focus(self, radius: SiteControlMetrics.securityRadius)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func accessibilityChildren() -> [Any]? { [heading] }
}

@MainActor
final class SiteControlSwitch: SiteControlButton {
    override var drawsStandardButton: Bool { false }
    private let knob = CALayer()
    override var wantsUpdateLayer: Bool { false }
    var isOn = false { didSet { setAccessibilityValue(isOn ? 1 : 0); updateKnob(animated: oldValue != isOn) } }
    init(id: String, label: String) {
        super.init(id: id, label: label, symbol: "", pointSize: 0)
        knob.backgroundColor = NSColor.white.cgColor; knob.cornerRadius = SiteControlMetrics.switchKnob / 2
        layer?.addSublayer(knob)
        setAccessibilityRole(.checkBox)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateKnob(animated: false) }
    private func updateKnob(animated: Bool) {
        if animated && window != nil && bounds.width > 0 && !wantsLayer {
            wantsLayer = true; layer?.addSublayer(knob)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            knob.frame = CGRect(x: !isOn ? bounds.width - SiteControlMetrics.switchInset - SiteControlMetrics.switchKnob : SiteControlMetrics.switchInset,
                                y: SiteControlMetrics.switchInset, width: SiteControlMetrics.switchKnob, height: SiteControlMetrics.switchKnob)
            CATransaction.commit()
        }
        guard wantsLayer else { needsDisplay = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(!(animated && window != nil && bounds.width > 0)); CATransaction.setAnimationDuration(SiteControlMetrics.switchDuration)
        knob.frame = CGRect(x: isOn ? bounds.width - SiteControlMetrics.switchInset - SiteControlMetrics.switchKnob : SiteControlMetrics.switchInset,
                            y: SiteControlMetrics.switchInset, width: SiteControlMetrics.switchKnob, height: SiteControlMetrics.switchKnob)
        CATransaction.commit(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.intersects(visibleRect) else { return }
        (isOn ? Core.brandBlue : GrayScale.a(6)).resolved(contentAppearance).nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if !wantsLayer {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: isOn ? bounds.width - SiteControlMetrics.switchInset - SiteControlMetrics.switchKnob : SiteControlMetrics.switchInset,
                                       y: SiteControlMetrics.switchInset, width: SiteControlMetrics.switchKnob, height: SiteControlMetrics.switchKnob)).fill()
        }
        SiteControlDrawing.focus(self, radius: bounds.height / 2 + SiteControlMetrics.focusOutset)
    }
}

@MainActor
final class SiteControlBoostRow: NSView {
    private(set) var boost: Boost
    let toggle: SiteControlSwitch
    let edit: SiteControlButton
    var onEdit: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ boost: Boost, enabled: Bool) {
        self.boost = boost
        let name = boost.name.isEmpty ? boost.siteMatch.domain : boost.name
        toggle = SiteControlSwitch(id: "boost.\(boost.id).switch", label: "Enable " + name)
        edit = SiteControlButton(id: "boost.\(boost.id).edit", label: "Edit " + name, symbol: "pencil", pointSize: SiteControlMetrics.editGlyph)
        super.init(frame: .zero); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        identifier = NSUserInterfaceItemIdentifier("boost.\(boost.id)")
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(name + ", " + (boost.isEnabled ? "Enabled" : "Disabled"))
        toggle.isOn = boost.isEnabled; toggle.isEnabled = enabled; edit.isEnabled = enabled
        edit.alphaValue = 0; addSubview(toggle); addSubview(edit)
        edit.invoke = { [weak self] in self?.onEdit?() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func apply(_ boost: Boost, enabled: Bool) {
        self.boost = boost
        let name = boost.name.isEmpty ? boost.siteMatch.domain : boost.name
        setAccessibilityLabel(name + ", " + (boost.isEnabled ? "Enabled" : "Disabled"))
        toggle.setAccessibilityLabel("Enable " + name); edit.setAccessibilityLabel("Edit " + name)
        toggle.isOn = boost.isEnabled; toggle.isEnabled = enabled; edit.isEnabled = enabled
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { edit.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { if window?.firstResponder !== edit && window?.firstResponder !== toggle { edit.alphaValue = 0 } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 && edit.isEnabled { onEdit?() }
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if event.keyCode == 36 && edit.isEnabled { onEdit?(); return }
        super.keyDown(with: event)
    }
    override func layout() {
        super.layout(); let m = SiteControlMetrics.self
        toggle.frame = CGRect(x: bounds.width - m.inset - m.switchSize.width, y: (bounds.height - m.switchSize.height) / 2, width: m.switchSize.width, height: m.switchSize.height)
        edit.frame = CGRect(x: toggle.frame.minX - m.editGap - m.editButton, y: (bounds.height - m.editButton) / 2, width: m.editButton, height: m.editButton)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.intersects(visibleRect), alphaValue > 0 else { return }
        let m = SiteControlMetrics.self
        SiteControlDrawing.glyph("paintbrush.pointed.fill", in: CGRect(x: m.inset, y: (bounds.height - m.boostIcon) / 2, width: m.boostIcon, height: m.boostIcon), size: m.boostIcon, color: SiteControlDrawing.accent(boost.id).resolved(contentAppearance).nsColor)
        let name = boost.name.isEmpty ? boost.siteMatch.domain : boost.name
        SiteControlDrawing.text(name, x: m.boostTextX, baseline: m.boostTitleBaseline, width: edit.frame.minX - m.boostTextX - m.editGap, font: Typography.boostRowTitle.font, color: Core.foregroundPrimary.resolved(contentAppearance).nsColor)
        SiteControlDrawing.text(boost.isEnabled ? "Enabled" : "Disabled", x: m.boostTextX, baseline: m.boostSubtitleBaseline, width: edit.frame.minX - m.boostTextX, font: Typography.tileSubtitle.font, color: Core.foregroundSecondary.resolved(contentAppearance).nsColor)
    }
}
