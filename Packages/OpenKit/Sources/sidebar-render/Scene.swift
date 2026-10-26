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
        let context = sidebar.context
        lights.tone = context.focusedSpace.map { context.appearance(for: $0) } ?? context.systemAppearance
        lights.showsRing = context.isWindowActive
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

/// Stand-in for the window buttons in renders: the window's own dimmed look at rest
/// (`DimmedTrafficLightsView`, Arc's grey circles), at the measured centers.
@MainActor
final class TrafficLightsView: NSView {
    private let dimmed = DimmedTrafficLightsView()
    /// The Space's content appearance (set by the scene), as in the window.
    var tone: ContentAppearance = .light { didSet { needsLayout = true } }
    /// Rings only in an active window (renders with `--inactive` draw none).
    var showsRing = true { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(dimmed)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dimmed.frame = bounds
        // The dimmed view is not flipped: measure its centers from the bottom.
        dimmed.centers = ChromeMetrics.trafficLightCenters.map { CGPoint(x: $0.x, y: bounds.height - $0.y) }
        dimmed.tone = tone
        dimmed.showsRing = showsRing
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
