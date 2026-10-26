import AppKit
import OpenDesign
import OpenModel

/// Top toolbar row: space for the system traffic lights, the sidebar toggle,
/// and back / forward / reload at the measured positions (runtime-observations §1.1).
@MainActor
final class ToolbarView: NSView {
    unowned let context: SidebarContext
    let toggle = PlateButton(glyph: .sidebarToggle)
    let back = PlateButton(glyph: .back)
    let forward = PlateButton(glyph: .forward)
    let reload = PlateButton(glyph: .reload)

    init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        let style: @MainActor () -> SpaceThemeStyle = { [unowned context] in
            context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        }
        func setup(_ b: PlateButton, _ key: ToolbarButtonKind, _ tip: @escaping @MainActor () -> Tooltip?) {
            b.context = context
            b.dimsWhenInactive = true
            b.hoverKey = .toolbar(key)
            b.tooltip = tip
            addSubview(b)
        }
        setup(toggle, .sidebarToggle) { Tooltip(title: "Hide sidebar", keys: ["⌘", "S"], style: style()) }
        setup(back, .back) { Tooltip(title: "Go back", keys: ["⌘", "["], style: style()) }
        setup(forward, .forward) { Tooltip(title: "Go forward", keys: ["⌘", "]"], style: style()) }
        setup(reload, .reload) { [unowned context] in
            Tooltip(title: context.currentTab?.live.isLoading == true ? "Stop loading" : "Reload this page", keys: ["⌘", "R"], style: style())
        }
        toggle.action = { [unowned context] in context.send(.toggleSidebar) }
        back.action = { [unowned context] in context.send(.goBack) }
        forward.action = { [unowned context] in context.send(.goForward) }
        reload.action = { [unowned context] in
            context.send(context.currentTab?.live.isLoading == true ? .stopLoading : .reload)
        }
        // Arc reports all four as disabled with no page (AX); the toggle's glyph is
        // drawn like the others. guess: the toggle is always enabled in Open.
        back.isEnabled = { [unowned context] in context.currentTab?.live.canGoBack ?? false }
        forward.isEnabled = { [unowned context] in context.currentTab?.live.canGoForward ?? false }
        reload.isEnabled = { [unowned context] in context.currentTab != nil }
        toggle.glyphTint = { _ in SidebarRole.toolbarGlyph.nsColor }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, y = ChromeMetrics.toolbarButtonY, s = ChromeMetrics.toolbarButtonSize
        toggle.frame = CGRect(origin: CGPoint(x: ChromeMetrics.sidebarToggleX, y: y), size: s)
        back.frame = CGRect(origin: CGPoint(x: ChromeMetrics.backX(sidebarWidth: w), y: y), size: s)
        forward.frame = CGRect(origin: CGPoint(x: ChromeMetrics.forwardX(sidebarWidth: w), y: y), size: s)
        reload.frame = CGRect(origin: CGPoint(x: ChromeMetrics.reloadX(sidebarWidth: w), y: y), size: s)
        let loading = tracked({ context.currentTab?.live.isLoading == true }) { [weak self] in self?.needsLayout = true }
        reload.glyphView.glyph = loading ? .stopLoading : .reload
    }
}

/// The sidebar URL field: placeholder with a magnifier, or the current host.
/// A click asks the delegate to open the command bar (Cmd+L style).
@MainActor
final class URLFieldView: NSView {
    unowned let context: SidebarContext
    private let fill = CALayer()
    private let magnifier = GlyphView()
    private let label = TextLabel()
    let copyLink = PlateButton(glyph: .copyLink)
    let siteControls = PlateButton(glyph: .siteControls)
    private var pointerInside = false { didSet { if pointerInside != oldValue { needsLayout = true; needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        magnifier.glyph = .magnifier
        magnifier.tint = { SidebarRole.magnifier.nsColor }
        label.font = Typography.urlField.font
        label.baseline = URLFieldMetrics.textBaselineOffset
        label.inset = SpaceListMetrics.textInset
        label.text = { [unowned context] in context.currentTab?.displayHost ?? "Search or Enter URL…" }
        label.color = { [unowned context] in
            (context.currentTab == nil ? SidebarRole.placeholder : SidebarRole.urlText).nsColor
        }
        for b in [copyLink, siteControls] {
            b.context = context
            b.glyphTint = { _ in SidebarRole.toolbarGlyph.nsColor }
            addSubview(b)
        }
        copyLink.action = { [unowned context] in context.send(.copyCurrentURL) }
        siteControls.action = { [unowned context] in context.send(.showSiteControls) }
        let style: @MainActor () -> SpaceThemeStyle = { [unowned context] in
            context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        }
        copyLink.tooltip = { Tooltip(title: "Copy URL", keys: ["⇧", "⌘", "C"], style: style()) }
        siteControls.tooltip = { Tooltip(title: "Site Controls", style: style()) }
        addSubview(magnifier)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Search or Enter URL")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The copy and Site Control buttons show while a page is loaded and the
    /// pointer is anywhere over the sidebar. guess: they came and went between
    /// frames (F0015, F0016, F0019, F0035, F0123).
    private var showsButtons: Bool { context.forcedHover != nil || context.pointerInSidebar || pointerInside }

    override func updateLayer() {
        let appearance = contentAppearance
        fill.backgroundColor = SidebarRole.fieldFill.cgColor(appearance)
    }

    override func layout() {
        super.layout()
        // Field frame is `[8, 46, W − 16, 36]` in sidebar space; this view is that frame.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = URLFieldMetrics.cornerRadius
        CATransaction.commit()
        let hasPage = tracked({ context.currentTab != nil }) { [weak self] in self?.needsLayout = true }
        label.font = (hasPage ? Typography.urlHost : Typography.urlField).font
        let showAccessories = hasPage && tracked({ showsButtons }) { [weak self] in self?.needsLayout = true }
        let ox = URLFieldMetrics.insetX, oy = URLFieldMetrics.y
        magnifier.isHidden = hasPage
        magnifier.frame = URLFieldMetrics.magnifierFrame.offsetBy(dx: -ox, dy: -oy)
        let textX = (hasPage ? URLFieldMetrics.hostX : URLFieldMetrics.placeholderX) - ox
        var right = bounds.width - (URLFieldMetrics.textTrailingInset - ox)
        let a = URLFieldMetrics.accessorySize
        siteControls.frame = CGRect(x: bounds.width + ox - URLFieldMetrics.siteControlsTrailing - a, y: URLFieldMetrics.accessoryY - oy, width: a, height: a)
        copyLink.frame = siteControls.frame.offsetBy(dx: -URLFieldMetrics.accessoryPitch, dy: 0)
        copyLink.isHidden = !showAccessories
        siteControls.isHidden = !showAccessories
        if showAccessories { right = copyLink.frame.minX - 2 }
        label.frame = CGRect(x: textX, y: URLFieldMetrics.textY - oy, width: max(0, right - textX), height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { context.send(.openCommandBar(.urlField)) }
    }
    override func accessibilityPerformPress() -> Bool { context.send(.openCommandBar(.urlField)); return true }
}
