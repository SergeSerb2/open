import AppKit
import CoreText
import QuartzCore
import OpenDesign
import OpenBoosts

/// Bounded native text cache; draw once per value, appearance, size, and scale.
@MainActor
enum SiteControlDrawing {
    private static var lines: [String: CTLine] = [:]
    // Fixed row geometry: a 236 x 32 @2x bitmap is 120,832 bytes.
    // 48 entries retain at most about 5.6 MiB of row pixels.
    private static var rowImages: [String: CGImage] = [:]
    static func cachedRow(_ key: String,size: CGSize,scale: CGFloat,draw: (CGContext) -> Void) -> CGImage? {
        let identity = key+"|\(size)|\(scale)"
        if let image = rowImages[identity] { return image }
        guard let image = bitmap(size: size,scale: scale,draw: draw) else { return nil }
        if rowImages.count >= 48 { rowImages.removeAll(keepingCapacity: true) }
        rowImages[identity] = image; return image
    }
    static func text(_ text: String,x: CGFloat,baseline: CGFloat,width: CGFloat,font: NSFont,color: NSColor,alignment: NSTextAlignment = .left) {
        guard width > 0,!text.isEmpty,let c = NSGraphicsContext.current?.cgContext else { return }
        let key = "\(text)|\(width)|\(font)|\(color)"
        let line: CTLine
        if let cached = lines[key] { line = cached }
        else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font,.foregroundColor: color]
            var value = CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: attributes))
            if CTLineGetTypographicBounds(value,nil,nil,nil) > width {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…",attributes: attributes))
                guard let truncated = CTLineCreateTruncatedLine(value,width,.end,ellipsis) else { return }; value = truncated
            }
            if lines.count >= 256 { lines.removeAll(keepingCapacity: true) }; lines[key] = value; line = value
        }
        let actual = CTLineGetTypographicBounds(line,nil,nil,nil)
        let offset = alignment == .right ? width-actual : alignment == .center ? (width-actual)/2 : 0
        c.saveGState(); c.textMatrix = CGAffineTransform(scaleX: 1,y: -1); c.textPosition = CGPoint(x: x+offset,y: baseline); CTLineDraw(line,c); c.restoreGState()
    }
    static func bitmap(size: CGSize,scale: CGFloat,draw: (CGContext) -> Void) -> CGImage? {
        guard size.width>0,size.height>0,let c = CGContext(data: nil,width: Int(ceil(size.width*scale)),height: Int(ceil(size.height*scale)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: scale,y: scale); c.translateBy(x: 0,y: size.height); c.scaleBy(x: 1,y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: true); draw(c); NSGraphicsContext.restoreGraphicsState(); return c.makeImage()
    }
}

/// One shared geometry for settings and Boosts. The glyph is an actual hole in
/// the disc bitmap, exposing the material instead of painting a substitute tint.
@MainActor
class SiteControlRow: SiteControlButton {
    private(set) var tile: SiteSettingTile
    private lazy var disc = CALayer()
    private lazy var labels = CALayer()
    private lazy var rowFocus = CAShapeLayer()
    private var drawingLayersAttached = false
    private var tileApplied = false
    private var previousDisc: Any?
    var drawsDisc: Bool { true }
    var focusRect: CGRect { CGRect(x: 8,y: -2,width: 36,height: 36) }
    var isBoostRow: Bool { false }
    init(_ tile: SiteSettingTile) {
        self.tile = tile
        super.init(id: tile.id,label: tile.title,symbol: tile.symbol,pointSize: SiteControlMetrics.rowGlyph)
        apply(tile,animated: false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func apply(_ tile: SiteSettingTile,animated: Bool) {
        guard !tileApplied || self.tile != tile else { return }
        let changed = self.tile.state != tile.state
        let previous = drawingLayersAttached && drawsDisc ? disc.contents : nil
        tileApplied = true; self.tile = tile; symbol = tile.symbol; circleOn = tile.state == .on
        setAccessibilityLabel(tile.title); setAccessibilityRole(tile.state == .unavailable ? .button : .checkBox)
        setAccessibilityValue(tile.state == .on ? 1 : 0); setAccessibilityValueDescription(tile.subtitle)
        setAccessibilityHelp(tile.help); tooltipTitle = tile.help
        needsDisplay = true
        previousDisc = animated && changed && bounds.intersects(visibleRect) ? previous : nil

    }
    override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        let m = SiteControlMetrics.self, scale = window?.backingScaleFactor ?? 1, appearance = contentAppearance
        if !drawingLayersAttached {
            if drawsDisc { layer?.addSublayer(disc) }
            layer?.addSublayer(labels); layer?.addSublayer(rowFocus)
            rowFocus.fillColor = nil; rowFocus.lineWidth = m.focusWidth; drawingLayersAttached = true
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        if drawsDisc {
            disc.frame = CGRect(x: m.padding,y: 0,width: m.rowIcon,height: m.rowIcon)
            var color = (circleOn ? SiteControlColors.circleOn : SiteControlColors.circleOff).resolved(appearance).nsColor
            if isHighlighted { color = SiteControlGlyphRenderer.adjust(color,levels: m.circlePressedLevels) }
            disc.contents = SiteControlGlyphRenderer.circle(symbol: symbol,size: disc.bounds.size,pointSize: m.rowGlyph,disc: color,sparkles: .none,scale: scale,phase: symbolPhase); disc.contentsScale = scale
            if let previousDisc {
                let fade = CABasicAnimation(keyPath: "contents"); fade.fromValue = previousDisc; fade.toValue = disc.contents; fade.duration = Motion.selectionFade; disc.add(fade,forKey: "toggle"); self.previousDisc = nil
            }
        }
        labels.frame = bounds; labels.contentsScale = scale
        labels.contents = SiteControlDrawing.cachedRow("\(tile.title)|\(tile.subtitle)|\(tile.inUse)|\(isBoostRow)|\(appearance)",size: bounds.size,scale: scale) { c in
            let width = bounds.width-m.rowTextX-m.rowTitleTrailing-(tile.inUse ? m.inUseDot+4 : 0)-(isBoostRow ? 11 : 0)
            SiteControlDrawing.text(tile.title,x: m.rowTextX,baseline: m.rowTitleBaseline,width: width,font: Typography.siteControlRowTitle.font,color: SiteControlColors.rowTitle.resolved(appearance).nsColor)
            SiteControlDrawing.text(tile.subtitle,x: m.rowTextX,baseline: m.rowSubtitleBaseline,width: bounds.width-m.rowTextX-m.padding,font: Typography.siteControlRowSubtitle.font,color: SiteControlColors.rowSubtitle.resolved(appearance).nsColor)
            if tile.inUse {
                let advance = min(width,(tile.title as NSString).size(withAttributes: [.font: Typography.siteControlRowTitle.font]).width)
                c.setFillColor(Core.brandBlue.cgColor(appearance)); c.fillEllipse(in: CGRect(x: m.rowTextX+advance+4,y: 5,width: m.inUseDot,height: m.inUseDot))
            }
        }
        rowFocus.frame = bounds
        rowFocus.path = isBoostRow ? SiteControlShape.path(in: focusRect,radius: 8) : CGPath(ellipseIn: focusRect,transform: nil)
        rowFocus.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(appearance) : nil
    }
}

@MainActor
final class SiteControlBoostRow: SiteControlRow {
    private(set) var boost: Boost
    let toggle: SiteControlButton
    private lazy var chevron = CALayer()
    private var chevronAttached = false
    private var hovered = false
    override var drawsDisc: Bool { false }
    override var isBoostRow: Bool { true }
    override var focusRect: CGRect { CGRect(x: 46,y: -4,width: 180,height: 40) }
    init(_ boost: Boost,enabled: Bool = true,globallyEnabled: Bool = true,incognito: Bool = false) {
        self.boost = boost
        toggle = SiteControlButton(id: "boost.\(boost.id).circle",label: "Enable "+(boost.name.isEmpty ? boost.siteMatch.domain : boost.name),symbol: BoostGlyph.fill,pointSize: SiteControlMetrics.rowGlyph)
        let name = boost.name.isEmpty ? boost.siteMatch.domain : boost.name
        super.init(SiteSettingTile(id: "boost.\(boost.id).row",kind: .content("boost"),title: name,subtitle: boost.isEnabled ? "Enabled" : "Disabled",state: boost.isEnabled ? .on : .off,symbol: BoostGlyph.fill))
        toggle.style = .circle; toggle.sparkles = .boost; toggle.setAccessibilityRole(.checkBox)
        addSubview(toggle)
        apply(boost,enabled: enabled,globallyEnabled: globallyEnabled,incognito: incognito)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func apply(_ boost: Boost,enabled: Bool,globallyEnabled: Bool,incognito: Bool) {
        self.boost = boost
        let name = boost.name.isEmpty ? boost.siteMatch.domain : boost.name
        super.apply(SiteSettingTile(id: controlID,kind: .content("boost"),title: name,subtitle: boost.isEnabled ? "Enabled" : "Disabled",state: boost.isEnabled ? .on : .off,symbol: BoostGlyph.fill),animated: true)
        setAccessibilityRole(.button); setAccessibilityLabel("Edit "+name); setAccessibilityValue(nil); setAccessibilityValueDescription(nil)
        toggle.setAccessibilityLabel("Enable "+name); toggle.setAccessibilityValue(boost.isEnabled ? 1 : 0); toggle.circleOn = boost.isEnabled
        // Global-off disables the circle; the editor remains available to explain it.
        toggle.isEnabled = enabled; isEnabled = !incognito
        alphaValue = !globallyEnabled || incognito ? 0.5 : 1
        toggle.disabledOpacity = 1
        let help = incognito ? "Boosts can't be edited in a private window." : nil
        tooltipTitle = help; toggle.tooltipTitle = help; setAccessibilityHelp(help); toggle.setAccessibilityHelp(help)
        setAccessibilityChildren([toggle]); needsDisplay = true
    }
    override func layout() { super.layout(); toggle.frame = CGRect(x: 10,y: 0,width: 32,height: 32) }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false; needsDisplay = true }
    override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        super.updateLayer()
        let scale = window?.backingScaleFactor ?? 1
        let showChevron = hovered || (showsKeyboardFocus && window?.firstResponder === self)
        guard showChevron || chevronAttached else { return }
        if !chevronAttached { layer?.addSublayer(chevron); chevronAttached = true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chevron.isHidden = !showChevron
        if let icon = SiteControlGlyphRenderer.symbol("chevron.right",size: 11,weight: .semibold,color: SiteControlColors.rowSubtitle.resolved(contentAppearance).nsColor,sparkles: .none,scale: scale,fit: nil,phase: .zero) {
            chevron.contents = icon.image; chevron.contentsScale = scale; chevron.frame = CGRect(x: bounds.width-10-11,y: (32-icon.size.height)/2,width: icon.size.width,height: icon.size.height)
        }
        CATransaction.commit()
    }
}

@MainActor
final class SiteControlSectionButton: SiteControlButton {
    private let heading: NSView
    private let headingText: String
    private let accessory: String
    private var hovered = false
    private let caption = CALayer(), hoverText = CALayer(), rowFocus = CAShapeLayer()
    init(id: String,caption: String,accessory: String) {
        self.accessory = accessory; headingText = caption; heading = NSView(frame: .zero)
        super.init(id: id,label: caption+", "+accessory,symbol: "",pointSize: 0)
        heading.setAccessibilityElement(true); heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading")); heading.setAccessibilityLabel(caption)
        addSubview(heading); setAccessibilityChildren([heading])
        for layer in [self.caption,hoverText,rowFocus] { self.layer?.addSublayer(layer) }
        rowFocus.fillColor = nil; rowFocus.lineWidth = SiteControlMetrics.focusWidth
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); heading.frame = CGRect(x: 10,y: 0,width: max(0,bounds.width-20),height: bounds.height) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point,from: superview)) ? self : nil }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false; needsDisplay = true }
    override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        let scale = window?.backingScaleFactor ?? 1, appearance = contentAppearance
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [caption,hoverText] { layer.frame = bounds; layer.contentsScale = scale }
        caption.contents = SiteControlDrawing.bitmap(size: bounds.size,scale: scale) { _ in
            SiteControlDrawing.text(headingText,x: 10,baseline: 21,width: bounds.width-20,font: Typography.siteControlLabel.font,color: SiteControlColors.label.resolved(appearance).nsColor)
        }
        hoverText.contents = SiteControlDrawing.bitmap(size: bounds.size,scale: scale) { _ in
            SiteControlDrawing.text(accessory,x: 10,baseline: 21,width: bounds.width-20,font: Typography.siteControlRowSubtitle.font,color: SiteControlColors.rowSubtitle.resolved(appearance).nsColor,alignment: .right)
        }
        let opacity: Float = hovered || (showsKeyboardFocus && window?.firstResponder === self) ? 1 : 0
        if hoverText.opacity != opacity {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = hoverText.presentation()?.opacity ?? hoverText.opacity; fade.toValue = opacity; fade.duration = Motion.hoverFade; hoverText.add(fade,forKey: "hover")
        }
        hoverText.opacity = opacity
        rowFocus.frame = bounds; rowFocus.path = SiteControlShape.path(in: bounds.insetBy(dx: 2,dy: 1),radius: 6)
        rowFocus.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(appearance) : nil
        CATransaction.commit()
    }
}

@MainActor
final class SiteControlBodyView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class SiteControlBaselineLabel: NSView {
    let text: String
    let multiline: Bool
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    init(_ text: String,multiline: Bool = false) {
        self.text = text; self.multiline = multiline; super.init(frame: .zero); wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        let scale = window?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        layer?.contents = SiteControlDrawing.bitmap(size: bounds.size,scale: scale) { _ in
            let lines = multiline ? ["Boosts are off.","Turn them on in Settings."] : [text]
            for (i,line) in lines.enumerated() { SiteControlDrawing.text(line,x: 0,baseline: multiline ? 11+CGFloat(i)*15 : 20,width: bounds.width,font: Typography.siteControlRowSubtitle.font,color: SiteControlColors.rowSubtitle.resolved(contentAppearance).nsColor) }
        }
    }
}

@MainActor
final class SiteControlReloadButton: SiteControlButton {
    private let caption = CALayer(), ring = CAShapeLayer()
    init() {
        super.init(id: "reload",label: "Reload",symbol: "",pointSize: 0)
        layer?.addSublayer(caption); layer?.addSublayer(ring); ring.fillColor = nil; ring.lineWidth = 2
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        guard bounds.intersects(visibleRect) else { return }
        let scale = window?.backingScaleFactor ?? 1
        caption.frame = bounds; caption.contentsScale = scale
        caption.contents = SiteControlDrawing.bitmap(size: bounds.size,scale: scale) { _ in
            SiteControlDrawing.text("Reload",x: 0,baseline: 20,width: bounds.width,font: .systemFont(ofSize: 13,weight: .semibold),color: SiteControlColors.rowTitle.resolved(contentAppearance).nsColor,alignment: .right)
        }
        ring.frame = bounds; ring.path = SiteControlShape.path(in: bounds.insetBy(dx: -2,dy: -2),radius: 6)
        ring.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(contentAppearance) : nil
    }
}
