import AppKit
import OpenDesign
import OpenLiveData
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
        var previewFolderID: ItemID?
        /// LF look frames: the intro card beside this Live Folder row.
        var liveIntroFolderID: ItemID?
        /// LF L6 look frames: a Pinned tab shown with the Gmail card.
        var previewMail: ItemID?
        /// A Pinned tab shown with the Recents card (LF L1 look frames).
        var previewRecents: (tabID: ItemID, site: RecentsSite)?
        /// A Pinned tab shown with the calendar card (CAL L4 look frames).
        var previewCalendar: (tabID: ItemID, provider: CalendarProvider)?
    }

    let background: ThemeBackgroundView
    let sidebar: SidebarView
    let panelHost = NSView()
    let panel = WebPanelChromeLayer()
    let lights = TrafficLightsView()
    let cardShadow = RevealCardShadowView()
    let options: Options
    let folderPreview: FolderPreviewView?
    let recentsPreview: RecentsPreviewView?
    let recentsShadow = NSView()
    var liveIntro: LiveFolderIntroView?
    var mailPreview: MailPreviewView?
    let mailShadow = NSView()
    let calendarPreview: CalendarPreviewView?

    init(context: SidebarContext, options: Options, delegate: any SidebarDelegate) {
        self.options = options
        background = ThemeBackgroundView(frame: CGRect(origin: .zero, size: options.size))
        sidebar = SidebarView(context: context)
        folderPreview = options.previewFolderID.flatMap { context.model.node(id: $0)?.folder }.map { FolderPreviewView(context: context, folder: $0) }
        recentsPreview = options.previewRecents.flatMap { item in context.model.tab(id: item.tabID).map { RecentsPreviewView(context: context, tab: $0, site: item.site) } }
        calendarPreview = options.previewCalendar.flatMap { item in
            context.model.tab(id: item.tabID).flatMap { tab in context.calendarGlance.map { CalendarPreviewView(context: context, tab: tab, provider: item.provider, source: $0) } }
        }
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
        if let folderPreview {
            addSubview(folderPreview)
        }
        if let id = options.previewMail, let tab = context.model.tab(id: id) {
            let view = MailPreviewView(context: context, tab: tab, account: 0)
            let deadline = Date().addingTimeInterval(2)
            while !view.isLoaded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let m = HoverPreviewMetrics.self, shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(m.shadowOpacity))
            shadow.shadowBlurRadius = m.shadowRadius; shadow.shadowOffset = CGSize(width: 0, height: -m.shadowOffsetY)
            mailShadow.wantsLayer = true; mailShadow.shadow = shadow
            addSubview(mailShadow); mailShadow.addSubview(view); mailPreview = view
        }
        if options.liveIntroFolderID != nil {
            let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
            let intro = LiveFolderIntroView(appearance: appearance)
            addSubview(intro); liveIntro = intro
        }
        if let recentsPreview {
            // The card's history read is async; renders wait for it (synthetic rows, < 1 s).
            let deadline = Date().addingTimeInterval(2)
            while !recentsPreview.isLoaded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            // The App wraps the card in PreviewCardView; renders draw the same shadow (HoverPreviewMetrics).
            // NSView.shadow, not layer props: AppKit resets a layer-backed view's layer shadow in this scene.
            let m = HoverPreviewMetrics.self
            recentsShadow.wantsLayer = true
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(m.shadowOpacity))
            shadow.shadowBlurRadius = m.shadowRadius; shadow.shadowOffset = CGSize(width: 0, height: -m.shadowOffsetY)
            recentsShadow.shadow = shadow
            addSubview(recentsShadow)
            recentsShadow.addSubview(recentsPreview)
        }
        if let calendarPreview {
            let deadline = Date().addingTimeInterval(2)
            while !calendarPreview.isLoaded, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            addSubview(calendarPreview)
        }
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
            sidebar.cardFieldFrame = CGRect(x: -sidebar.frame.minX, y: -sidebar.frame.minY, width: bounds.width, height: bounds.height)
            cardShadow.frame = sidebar.frame
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        } else {
            sidebar.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            lights.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        }
        if let folderPreview {
            sidebar.layoutSubtreeIfNeeded()
            let height = min(folderPreview.fittingSize.height, bounds.height - 20)
            // As the App's HoverPreviewController: 4 pt right of the sidebar, centered on the row.
            let row = sidebar.rowFrame(nodeID: folderPreview.folder.id) ?? CGRect(x: 0, y: 100, width: w, height: 41)
            folderPreview.frame = CGRect(x: w + HoverPreviewMetrics.folderSidebarGap, y: min(max(10, row.midY - height / 2), bounds.height - 10 - height),
                                         width: HoverPreviewMetrics.folderWidth, height: height)
        }
        if let mailPreview {
            sidebar.layoutSubtreeIfNeeded()
            let height = min(mailPreview.fittingSize.height, bounds.height - 20)
            let row = sidebar.rowFrame(nodeID: mailPreview.tab.id) ?? CGRect(x: 0, y: 100, width: w, height: 41)
            mailShadow.frame = CGRect(x: w + HoverPreviewMetrics.folderSidebarGap, y: min(max(10, row.midY - height / 2), bounds.height - 10 - height),
                                      width: HoverPreviewMetrics.folderWidth, height: height)
            mailPreview.frame = mailShadow.bounds
        }
        if let liveIntro, let id = options.liveIntroFolderID {
            sidebar.layoutSubtreeIfNeeded()
            // As BrowserWindowController.showLiveFolderIntro: right of the sidebar, centred on the row.
            let row = sidebar.rowFrame(nodeID: id) ?? CGRect(x: 0, y: 100, width: w, height: 41)
            let size = liveIntro.fittingSize
            liveIntro.frame = CGRect(x: w + HoverPreviewMetrics.folderSidebarGap, y: row.midY - size.height / 2, width: size.width, height: size.height)
        }
        if let recentsPreview {
            sidebar.layoutSubtreeIfNeeded()
            let height = min(recentsPreview.fittingSize.height, bounds.height - 20)
            // As HoverPreviewController's glance placement: 4 pt right of the sidebar, centered on the row.
            let row = sidebar.rowFrame(nodeID: recentsPreview.tab.id) ?? CGRect(x: 0, y: 100, width: w, height: 41)
            recentsShadow.frame = CGRect(x: w + HoverPreviewMetrics.folderSidebarGap, y: min(max(10, row.midY - height / 2), bounds.height - 10 - height),
                                         width: HoverPreviewMetrics.folderWidth, height: height)
            recentsPreview.frame = recentsShadow.bounds
            recentsShadow.layer?.shadowPath = CGPath(roundedRect: recentsShadow.bounds, cornerWidth: HoverPreviewMetrics.radius, cornerHeight: HoverPreviewMetrics.radius, transform: nil)
        }
        if let calendarPreview {
            sidebar.layoutSubtreeIfNeeded()
            let height = min(calendarPreview.fittingSize.height, bounds.height - 20)
            let row = sidebar.rowFrame(nodeID: calendarPreview.tab.id) ?? CGRect(x: 0, y: 100, width: w, height: 41)
            calendarPreview.frame = CGRect(x: w + HoverPreviewMetrics.folderSidebarGap, y: min(max(10, row.midY - height / 2), bounds.height - 10 - height),
                                           width: HoverPreviewMetrics.folderWidth, height: height)
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
