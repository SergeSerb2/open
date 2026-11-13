import AppKit
import OpenModel
import OpenDesign

/// Developer Mode's toolbar (Arc `ContentPanel`): a bar over the page of a Developer Mode site.
/// Arc adds only this toolbar, the sidebar row outline and the host subtitle; Console, Network and Inspect open
/// the standard Chromium DevTools (capture PB3-a, C-report-s6.md:247 and :273).
///
/// Measured from `s9-queue/m1/arc/v2/44-pb3a-probe/d-0.png` (light) and `d-2-dark.png` (dark), 2x:
/// - 40 pt high, with a 1 pt line at its bottom edge; 45° stripes of two close tones, 22.5 pt wide each.
/// - Light: stripes #EFF1F5 / #F4F5F8, glyphs #212AFB, URL text #242526, bottom line #D8D9DD.
/// - Dark: stripes #3E43CA / #4247CB, glyphs #ECEDFE, URL text #D8D9F4, bottom line #5155CF.
/// - Controls, left to right (Arc's AX descriptions, 28 × 28 pt): Site Settings ("i") · the full URL in a
///   monospaced face · Copy Link | Capture Window · Capture | Toggle Console · Toggle Network Panel ·
///   Inspect Element | Extensions Menu · Split View Menu, with thin dividers between the groups.
/// A themed Space tints the bar (capture s3 `s7/12-devoff/d-devmode-on`: #76859C on a blue-grey Space). The tint
/// rule is a GUESS (LEAD 12:18): the Space's accent colour, with the ink chosen by its brightness.
/// Hover (capture s10 `v10/d1-devbar-hover-menus`, C-report-s10 PB3-a1): a grey rounded plate fills the hovered
/// 28 pt button (light black 7 %, dark white 8 %, C3 session 11 `c3-bar-hover-plate-*`), and after the usual delay
/// the Space's tooltip pill shows below it, with key caps where a shortcut exists. Site Settings shows the plate
/// only (`h-site`); Capture Window shows no tooltip, because resting on it opens the Portrait Mode popover.
/// Extensions Menu and Split View Menu open menus (PB3-a2); the App builds them.
public enum DeveloperPanelAction: String, CaseIterable, Sendable {
    case siteSettings, copyLink, captureWindow, capture, console, network, inspect, extensionsMenu, splitMenu

    /// Arc's accessibility description of the control.
    public var title: String {
        switch self {
        case .siteSettings: "Site Settings"
        case .copyLink: "Copy Link"
        case .captureWindow: "Capture Window"
        case .capture: "Capture"
        case .console: "Toggle Console"
        case .network: "Toggle Network Panel"
        case .inspect: "Inspect Element"
        case .extensionsMenu: "Extensions Menu"
        case .splitMenu: "Split View Menu"
        }
    }
    /// Arc's tooltip pill: title and key caps (C-report-s10 PB3-a1). Nil for Site Settings (plate only) and for
    /// Capture Window, whose hover opens a popover.
    public var tooltip: (title: String, keys: [String])? {
        switch self {
        case .siteSettings, .captureWindow: nil
        case .copyLink: ("Copy Link", ["⇧", "⌘", "C"])
        case .capture: ("Capture a portion of this page", ["⇧", "⌘", "2"])
        case .console: ("Toggle Console", ["⌥", "⌘", "J"])
        case .network: ("Toggle Network Panel", [])
        case .inspect: ("Inspect Element", ["⌥", "⌘", "C"])
        case .extensionsMenu: ("Extensions", [])
        case .splitMenu: ("Split View Options", [])
        }
    }
    /// Our own glyphs (SF Symbols, and a puzzle outline drawn in code); no Arc asset.
    var symbol: String {
        switch self {
        case .siteSettings: "info"
        case .copyLink: "link"
        case .captureWindow: "photo.on.rectangle"
        case .capture: "camera"
        case .console: "apple.terminal"
        case .network: "globe"
        case .inspect: "scope"
        case .extensionsMenu: "puzzlepiece.extension"
        case .splitMenu: "square.split.2x1"
        }
    }
    @MainActor var image: NSImage {
        if self == .extensionsMenu { return DeveloperPanelGlyphs.puzzle }
        if self == .captureWindow { return DeveloperPanelGlyphs.picture }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
    }
    /// The three controls that toggle DevTools on a panel.
    public var isDevToolsToggle: Bool { self == .console || self == .network || self == .inspect }
}

public enum DeveloperPanelMetrics {
    public static let height: CGFloat = 40
    static let infoCenterX: CGFloat = 22
    static let urlX: CGFloat = 41.5
    static let buttonSize: CGFloat = 28
    /// Button centers measured from the card's right edge, in group order.
    static let rightCenters: [(DeveloperPanelAction, CGFloat)] = [
        (.splitMenu, 19), (.extensionsMenu, 46.7), (.inspect, 91.5), (.network, 119.3), (.console, 147.3),
        (.capture, 191.7), (.captureWindow, 219.7), (.copyLink, 275.5),
    ]
    /// Thin dividers between the groups (midpoints of the measured gaps).
    static let separators: [CGFloat] = [69.1, 169.5, 247.6]
    /// Horizontal width of one stripe band; the stripes run at 45°.
    static let stripeBand: CGFloat = 22.5
}

/// Glyphs drawn in code (our own drawing).
@MainActor
enum DeveloperPanelGlyphs {
    /// The Extensions Menu glyph: a puzzle-piece outline with knobs left and right and notches top and bottom.
    /// Arc's ink box is 19 × 13 pt with a 1.5 pt stroke (`44-pb3a-probe/d-0.png` x 2427–2464, y 47–72 at 2x).
    static let puzzle: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 13), flipped: false) { _ in
            // Path through the stroke's center, inset 0.75 pt so the ink fills the 19 × 13 box.
            let l: CGFloat = 3.5, r: CGFloat = 15.5, b: CGFloat = 0.75, t: CGFloat = 12.25, c: CGFloat = 2
            let knob: CGFloat = 2.75, notch: CGFloat = 2.25, mid: CGFloat = 6.5, cx: CGFloat = 9.5
            let path = NSBezierPath()
            path.move(to: CGPoint(x: l + c, y: t))
            path.line(to: CGPoint(x: cx - notch, y: t))
            path.appendArc(withCenter: CGPoint(x: cx, y: t), radius: notch, startAngle: 180, endAngle: 0, clockwise: false)
            path.line(to: CGPoint(x: r - c, y: t))
            path.appendArc(withCenter: CGPoint(x: r - c, y: t - c), radius: c, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: CGPoint(x: r, y: mid + knob))
            path.appendArc(withCenter: CGPoint(x: r, y: mid), radius: knob, startAngle: 90, endAngle: -90, clockwise: true)
            path.line(to: CGPoint(x: r, y: b + c))
            path.appendArc(withCenter: CGPoint(x: r - c, y: b + c), radius: c, startAngle: 0, endAngle: -90, clockwise: true)
            path.line(to: CGPoint(x: cx + notch, y: b))
            path.appendArc(withCenter: CGPoint(x: cx, y: b), radius: notch, startAngle: 0, endAngle: 180, clockwise: false)
            path.line(to: CGPoint(x: l + c, y: b))
            path.appendArc(withCenter: CGPoint(x: l + c, y: b + c), radius: c, startAngle: 270, endAngle: 180, clockwise: true)
            path.line(to: CGPoint(x: l, y: mid - knob))
            path.appendArc(withCenter: CGPoint(x: l, y: mid), radius: knob, startAngle: 270, endAngle: 90, clockwise: true)
            path.line(to: CGPoint(x: l, y: t - c))
            path.appendArc(withCenter: CGPoint(x: l + c, y: t - c), radius: c, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()
            path.lineWidth = 1.5; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = DeveloperPanelAction.extensionsMenu.title
        return image
    }()

    /// The Capture Window glyph: one framed picture with a small flower inside (our own drawing).
    /// Arc's ink box is 17 × 13 pt: a rounded frame with a 1 pt stroke, a flower head about 4.5 × 3.5 pt over a
    /// stem, and two leaves about 9 pt across (`44-pb3a-probe/d-0.png` x 2083–2116, y 47–72 at 2x).
    static let picture: NSImage = {
        let image = NSImage(size: NSSize(width: 17, height: 13), flipped: false) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: CGRect(x: 0.625, y: 0.625, width: 15.75, height: 11.75), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = 1.25; frame.stroke()
            // Flower head: a rounded cup with two petal tips, about 4.6 × 3.8 pt.
            let head = NSBezierPath()
            head.move(to: CGPoint(x: 6.2, y: 10.9))
            head.line(to: CGPoint(x: 7.35, y: 10.0)); head.line(to: CGPoint(x: 8.5, y: 11.1)); head.line(to: CGPoint(x: 9.65, y: 10.0))
            head.line(to: CGPoint(x: 10.8, y: 10.9))
            head.curve(to: CGPoint(x: 8.5, y: 7.1), controlPoint1: CGPoint(x: 11.0, y: 8.5), controlPoint2: CGPoint(x: 9.9, y: 7.1))
            head.curve(to: CGPoint(x: 6.2, y: 10.9), controlPoint1: CGPoint(x: 7.1, y: 7.1), controlPoint2: CGPoint(x: 6.0, y: 8.5))
            head.close(); head.fill()
            let stem = NSBezierPath(); stem.move(to: CGPoint(x: 8.5, y: 7.3)); stem.line(to: CGPoint(x: 8.5, y: 2.6))
            stem.lineWidth = 1.1; stem.stroke()
            // Two leaves from the stem's foot, up and out, about 9 pt across.
            for side: CGFloat in [-1, 1] {
                let leaf = NSBezierPath(), base = CGPoint(x: 8.5, y: 2.8), tip = CGPoint(x: 8.5 + side * 4.4, y: 6.6)
                leaf.move(to: base)
                leaf.curve(to: tip, controlPoint1: CGPoint(x: 8.5 + side * 1.6, y: 2.3), controlPoint2: CGPoint(x: 8.5 + side * 4.3, y: 3.6))
                leaf.curve(to: base, controlPoint1: CGPoint(x: 8.5 + side * 2.4, y: 6.8), controlPoint2: CGPoint(x: 8.5 + side * 0.6, y: 5.2))
                leaf.close(); leaf.fill()
            }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = DeveloperPanelAction.captureWindow.title
        return image
    }()
}

/// A bar button that reports the pointer entering and leaving it (hover plate, tooltip, Capture Window popover).
final class DeveloperHoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
    override func mouseDown(with event: NSEvent) { onHover?(false); super.mouseDown(with: event) }
}

/// The bar's colours for one appearance.
struct DeveloperPanelPalette {
    var stripeA: NSColor, stripeB: NSColor, glyph: NSColor, text: NSColor, line: NSColor
    /// The hover plate over the full 28 pt button, radius 6: light black 7 %, dark white 8 % (C3 session 11
    /// `c3-bar-hover-plate-{light,dark}.png`: #F7F8FF → #E6E6ED, #3E43CA → #4D51CE). Tinted Spaces: GUESS, same rule by
    /// the fill's brightness.
    var plate: NSColor = NSColor(white: 0, alpha: 0.07)
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    static let light = DeveloperPanelPalette(stripeA: hex(0xEFF1F5), stripeB: hex(0xF4F5F8), glyph: hex(0x212AFB), text: hex(0x242526), line: hex(0xD8D9DD))
    static let dark = DeveloperPanelPalette(stripeA: hex(0x3E43CA), stripeB: hex(0x4247CB), glyph: hex(0xECEDFE), text: hex(0xD8D9F4), line: hex(0x5155CF),
                                            plate: NSColor(white: 1, alpha: 0.08))
    /// GUESS: a themed Space's bar. The second stripe is the fill moved 3 % toward white, as in the capture.
    static func tinted(_ fill: NSColor) -> DeveloperPanelPalette {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let bright = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent >= 0.62
        let ink = bright ? NSColor(white: 0, alpha: 0.72) : NSColor(white: 1, alpha: 0.92)
        return DeveloperPanelPalette(stripeA: rgb, stripeB: rgb.blended(withFraction: 0.03, of: .white) ?? rgb, glyph: ink, text: ink,
                                     line: (bright ? rgb.blended(withFraction: 0.10, of: .black) : rgb.blended(withFraction: 0.10, of: .white)) ?? rgb,
                                     plate: bright ? NSColor(white: 0, alpha: 0.07) : NSColor(white: 1, alpha: 0.08))
    }
}

@MainActor
public final class DeveloperContentPanelView: NSView {
    public var onAction: ((DeveloperPanelAction, NSView) -> Void)?
    /// The pointer entered a control that acts on hover (today: Capture Window). The view is the anchor.
    public var onHover: ((DeveloperPanelAction, NSView) -> Void)?
    public var urlString = "" { didSet { if urlString != oldValue { urlLabel.stringValue = urlString; needsLayout = true } } }
    /// A themed Space's accent colours (light, dark); nil = the default theme, drawn with Arc's measured colours.
    public var themeFills: (light: NSColor, dark: NSColor)? { didSet { applyColors() } }
    /// The DevTools toggle whose panel is open; its button is drawn pressed (capture `d-network-w`).
    public var activePanel: DeveloperPanelAction? { didSet { if activePanel != oldValue { applyColors() } } }
    /// The button under the pointer: it shows the hover plate.
    public private(set) var hovered: DeveloperPanelAction? { didSet { if hovered != oldValue { applyColors() } } }
    /// The Space style for the tooltip pill (the sidebar's tooltip colours).
    public var tooltipStyle: SpaceThemeStyle = .defaultTheme(system: .light)
    private let urlLabel = NSTextField(labelWithString: "")
    private var buttons: [DeveloperPanelAction: NSButton] = [:]

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.lineBreakMode = .byTruncatingMiddle; urlLabel.cell?.usesSingleLineMode = true
        urlLabel.setAccessibilityLabel("Page URL")
        addSubview(urlLabel)
        for action in DeveloperPanelAction.allCases {
            let button = DeveloperHoverButton()
            button.image = action.image; button.target = self; button.action = #selector(press(_:))
            button.onHover = { [weak self] inside in self?.pointer(inside, action) }
            button.isBordered = false; button.bezelStyle = .regularSquare; button.imagePosition = .imageOnly; button.wantsLayer = true
            button.setButtonType(.momentaryChange); button.layer?.cornerRadius = 6
            button.symbolConfiguration = .init(pointSize: action == .siteSettings ? 13 : 15, weight: .regular)
            button.setAccessibilityLabel(action.title); button.identifier = .init("developer-" + action.rawValue)
            addSubview(button); buttons[action] = button
        }
        setAccessibilityElement(true); setAccessibilityRole(.toolbar); setAccessibilityLabel("Developer Mode")
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func press(_ sender: NSButton) {
        guard let action = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(action, sender)
    }
    public func button(_ action: DeveloperPanelAction) -> NSView? { buttons[action] }

    /// The pointer entered or left a button: plate, tooltip pill and the hover hook.
    /// Automation calls this as the button's tracking area does.
    public func pointer(_ inside: Bool, _ action: DeveloperPanelAction) {
        guard let button = buttons[action] else { return }
        if inside {
            hovered = action
            if let tip = action.tooltip {
                TooltipController.shared.schedule(Tooltip(title: tip.title, keys: tip.keys, style: tooltipStyle), for: button)
            }
            onHover?(action, button)
        } else {
            if hovered == action { hovered = nil }
            TooltipController.shared.cancel(for: button)
        }
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { if let hovered, let button = buttons[hovered] { TooltipController.shared.cancel(for: button) }; hovered = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private var palette: DeveloperPanelPalette {
        if let themeFills { return .tinted(isDark ? themeFills.dark : themeFills.light) }
        return isDark ? .dark : .light
    }
    /// The colours in use, as sRGB hex strings (verification).
    public var paletteDescription: [String: String] {
        func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        let p = palette
        return ["stripeA": hex(p.stripeA), "stripeB": hex(p.stripeB), "glyph": hex(p.glyph), "text": hex(p.text), "line": hex(p.line)]
    }
    /// The hovered button's plate as sRGB hex with alpha (verification), or nil.
    public var hoverPlateDescription: String? {
        guard hovered != nil, let c = palette.plate.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X/%.2f", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()), c.alphaComponent)
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let p = palette
        urlLabel.textColor = p.text
        for (action, button) in buttons {
            button.contentTintColor = p.glyph
            button.layer?.backgroundColor = action == hovered ? p.plate.cgColor
                : action == activePanel ? p.glyph.withAlphaComponent(0.14).cgColor : nil
        }
        needsDisplay = true
    }

    public override var isFlipped: Bool { true }
    /// The fill and its 45° stripes (down to the right), one band every 22.5 pt along x.
    public override func draw(_ dirtyRect: NSRect) {
        let p = palette
        p.stripeA.setFill(); bounds.fill()
        p.stripeB.setFill()
        let band = DeveloperPanelMetrics.stripeBand, h = bounds.height
        var x = -h - band
        while x < bounds.width {
            let stripe = NSBezierPath()
            stripe.move(to: CGPoint(x: x, y: 0)); stripe.line(to: CGPoint(x: x + band, y: 0))
            stripe.line(to: CGPoint(x: x + band + h, y: h)); stripe.line(to: CGPoint(x: x + h, y: h)); stripe.close()
            stripe.fill()
            x += 2 * band
        }
        // Group dividers and the 1 pt line at the bottom edge (the view is flipped: maxY is the bottom).
        p.glyph.withAlphaComponent(0.16).setFill()
        for fromRight in DeveloperPanelMetrics.separators {
            CGRect(x: bounds.width - fromRight, y: h / 2 - 10, width: 1, height: 20).fill(using: .sourceOver)
        }
        p.line.setFill(); CGRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, mid = bounds.height / 2, size = DeveloperPanelMetrics.buttonSize
        buttons[.siteSettings]?.frame = CGRect(x: DeveloperPanelMetrics.infoCenterX - size / 2, y: mid - size / 2, width: size, height: size)
        var leftmostRight = w
        for (action, fromRight) in DeveloperPanelMetrics.rightCenters {
            let frame = CGRect(x: w - fromRight - size / 2, y: mid - size / 2, width: size, height: size)
            buttons[action]?.frame = frame; leftmostRight = min(leftmostRight, frame.minX)
        }
        needsDisplay = true
        let urlWidth = max(0, leftmostRight - 12 - DeveloperPanelMetrics.urlX)
        urlLabel.frame = CGRect(x: DeveloperPanelMetrics.urlX, y: mid - 8, width: urlWidth, height: 16)
    }
}
