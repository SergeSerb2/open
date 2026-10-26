import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Window-sized composition for renders: theme background, the web panel
/// chrome, stand-in traffic lights, and the real `SidebarView`.
@MainActor
final class RenderScene: NSView {
    struct Options {
        var size = CGSize(width: 1280, height: 900)
        var sidebarHidden = false
        var revealCard = false
        var trafficLights = true
        /// Panel without a page: white 10 % (Arc's empty state). Otherwise opaque white.
        var emptyPanel = true
    }

    let background: ThemeBackgroundView
    let sidebar: SidebarView
    let panelHost = NSView()
    let panel = WebPanelChromeLayer()
    let lights = TrafficLightsView()
    let cardShadow = RevealCardShadowView()
    let options: Options

    init(context: SidebarContext, options: Options, delegate: any SidebarDelegate) {
        self.options = options
        background = ThemeBackgroundView(frame: CGRect(origin: .zero, size: options.size))
        sidebar = SidebarView(context: context)
        super.init(frame: CGRect(origin: .zero, size: options.size))
        wantsLayer = true
        sidebar.delegate = delegate
        sidebar.themeBackground = background
        addSubview(background)
        panelHost.wantsLayer = true
        panelHost.layer?.addSublayer(panel)
        panel.showsEmptyState = options.emptyPanel
        addSubview(panelHost)
        if options.revealCard { sidebar.presentation = .floatingCard; addSubview(cardShadow) }
        if !options.sidebarHidden || options.revealCard { addSubview(sidebar) }
        if options.trafficLights && !(options.sidebarHidden && !options.revealCard) {
            if options.revealCard { sidebar.addSubview(lights) } else { addSubview(lights) }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = sidebar.context.sidebarWidth
        background.frame = bounds
        panelHost.frame = bounds
        let hidden = options.sidebarHidden
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel.frame = PanelMetrics.frame(windowSize: bounds.size, sidebarWidth: w, sidebarHidden: hidden)
        CATransaction.commit()
        if options.revealCard {
            sidebar.frame = WindowMetrics.revealCardFrame(windowSize: bounds.size, sidebarWidth: w)
            cardShadow.frame = sidebar.frame
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        } else {
            sidebar.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        }
    }
}

/// Stand-in for the system traffic lights in renders: three 12 pt circles at the
/// measured centers. Inactive style only (black ≈ 0.11 over the theme, F0001).
@MainActor
final class TrafficLightsView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Inactive lights: black 0.11 on light content (F0001), white 0.31 on dark (F0079).
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.31) : NSColor.black.withAlphaComponent(0.11)).setFill()
        for f in ChromeMetrics.trafficLightFrames {
            let d = ChromeMetrics.trafficLightDiameter
            NSBezierPath(ovalIn: NSRect(x: f.midX - d / 2, y: f.midY - d / 2, width: d, height: d)).fill()
        }
    }
}

/// Delegate for renders and checks: applies model intents, records the rest.
@MainActor
final class RecordingDelegate: SidebarDelegate {
    var log: [SidebarIntent] = []
    var refuses = false
    @discardableResult
    func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        log.append(intent)
        return !refuses && ModelSidebarActions(context: sidebar.context).perform(intent)
    }
}
