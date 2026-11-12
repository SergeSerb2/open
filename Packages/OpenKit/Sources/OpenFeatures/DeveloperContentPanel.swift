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
/// A themed Space tints the bar (capture s3 `s7/12-devoff/d-devmode-on`: #76859C on a blue-grey Space); the
/// tint rule is a GUESS: the Space palette's background, with the ink chosen by its brightness.
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
    /// Our own glyphs (SF Symbols); no Arc asset.
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

/// The bar's colours for one appearance.
struct DeveloperPanelPalette {
    var stripeA: NSColor, stripeB: NSColor, glyph: NSColor, text: NSColor, line: NSColor
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    static let light = DeveloperPanelPalette(stripeA: hex(0xEFF1F5), stripeB: hex(0xF4F5F8), glyph: hex(0x212AFB), text: hex(0x242526), line: hex(0xD8D9DD))
    static let dark = DeveloperPanelPalette(stripeA: hex(0x3E43CA), stripeB: hex(0x4247CB), glyph: hex(0xECEDFE), text: hex(0xD8D9F4), line: hex(0x5155CF))
    /// GUESS: a themed Space's bar. The second stripe is the fill moved 3 % toward white, as in the capture.
    static func tinted(_ fill: NSColor) -> DeveloperPanelPalette {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let bright = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent >= 0.62
        let ink = bright ? NSColor(white: 0, alpha: 0.72) : NSColor(white: 1, alpha: 0.92)
        return DeveloperPanelPalette(stripeA: rgb, stripeB: rgb.blended(withFraction: 0.03, of: .white) ?? rgb, glyph: ink, text: ink,
                                     line: (bright ? rgb.blended(withFraction: 0.10, of: .black) : rgb.blended(withFraction: 0.10, of: .white)) ?? rgb)
    }
}

@MainActor
public final class DeveloperContentPanelView: NSView {
    public var onAction: ((DeveloperPanelAction, NSView) -> Void)?
    public var urlString = "" { didSet { if urlString != oldValue { urlLabel.stringValue = urlString; needsLayout = true } } }
    /// A themed Space's fills (light, dark); nil = the default theme, drawn with Arc's measured colours.
    public var themeFills: (light: NSColor, dark: NSColor)? { didSet { applyColors() } }
    /// The DevTools toggle whose panel is open; its button is drawn pressed (capture `d-network-w`).
    public var activePanel: DeveloperPanelAction? { didSet { if activePanel != oldValue { applyColors() } } }
    private let urlLabel = NSTextField(labelWithString: "")
    private var buttons: [DeveloperPanelAction: NSButton] = [:]

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.lineBreakMode = .byTruncatingMiddle; urlLabel.cell?.usesSingleLineMode = true
        urlLabel.setAccessibilityLabel("Page URL")
        addSubview(urlLabel)
        for action in DeveloperPanelAction.allCases {
            let button = NSButton(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title) ?? NSImage(), target: self, action: #selector(press(_:)))
            button.isBordered = false; button.bezelStyle = .regularSquare; button.imagePosition = .imageOnly; button.wantsLayer = true
            button.setButtonType(.momentaryChange); button.layer?.cornerRadius = 6
            button.symbolConfiguration = .init(pointSize: action == .siteSettings ? 13 : 15, weight: .regular)
            button.toolTip = action.title; button.setAccessibilityLabel(action.title); button.identifier = .init("developer-" + action.rawValue)
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
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let p = palette
        urlLabel.textColor = p.text
        for (action, button) in buttons {
            button.contentTintColor = p.glyph
            button.layer?.backgroundColor = action == activePanel ? p.glyph.withAlphaComponent(0.14).cgColor : nil
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
