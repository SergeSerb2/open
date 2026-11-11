import AppKit
import OpenExtensionsUI
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
    /// Compact toolbar only (width < 219): a menu with Reload / Stop Loading and Hide Sidebar.
    let more = PlateButton(glyph: .spaceMore)

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
            Tooltip(title: context.pageIsLoading ? "Stop loading" : "Reload this page", keys: ["⌘", "R"], style: style())
        }
        toggle.action = { [unowned context] in context.send(.toggleSidebar) }
        back.action = { [unowned context] in context.send(.goBack) }
        forward.action = { [unowned context] in context.send(.goForward) }
        reload.action = { [unowned context] in
            context.send(context.pageIsLoading ? .stopLoading : .reload)
        }
        // Arc reports all four as disabled with no page (AX); the toggle's glyph is
        // drawn like the others. guess: the toggle is always enabled in Open.
        back.isEnabled = { [unowned context] in context.pageCanGoBack }
        forward.isEnabled = { [unowned context] in context.pageCanGoForward }
        reload.isEnabled = { [unowned context] in context.hasPage }
        // Under a Peek's dim, Arc draws back, forward, and reload in the enabled tone even
        // when they are disabled (F0090: all four `#444452`–`#464654`; F0108 without the dim: disabled tone).
        for b in [back, forward, reload] {
            b.glyphTint = { [unowned context] enabled in
                (enabled || context.peekSourceNodeID != nil ? SidebarRole.toolbarGlyph : SidebarRole.toolbarGlyphDisabled).nsColor
            }
        }
        toggle.glyphTint = { _ in SidebarRole.toolbarGlyph.nsColor }
        setup(more, .more) { Tooltip(title: "More options", style: style()) }
        more.glyphTint = { _ in SidebarRole.toolbarGlyph.nsColor }
        more.menuProvider = { [weak self] in self?.makeMoreMenu() }
        more.isHidden = true
    }

    /// "More options" (guess: the menu was not opened in the capture; plan §3.16).
    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let loading = context.pageIsLoading
        let reload = ClosureMenuItem(loading ? "Stop Loading" : "Reload This Page", enabled: context.hasPage) { [unowned context] in
            context.send(context.pageIsLoading ? .stopLoading : .reload)
        }
        reload.keyEquivalent = loading ? "." : "r"; reload.keyEquivalentModifierMask = .command
        let hide = ClosureMenuItem("Hide Sidebar") { [unowned context] in context.send(.toggleSidebar) }
        hide.keyEquivalent = "s"; hide.keyEquivalentModifierMask = .command
        menu.addItem(reload); menu.addItem(hide)
        return menu
    }

    /// True while the toolbar shows Back, Forward, and "More options" only.
    var isCompact: Bool { ChromeMetrics.isCompact(sidebarWidth: bounds.width) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, y = ChromeMetrics.toolbarButtonY, s = ChromeMetrics.toolbarButtonSize
        let loading = tracked({ context.pageIsLoading }) { [weak self] in self?.needsLayout = true }
        reload.glyphView.glyph = loading ? .stopLoading : .reload
        // A selected split moves back, forward, and reload into each pane's bar: the
        // sidebar toolbar keeps only the toggle (F0081, F0082: AX and pixels).
        // The content toolbar holds them too (§4.6.3, derived from CC-36 "Show as Toolbar").
        let split = tracked({ context.isSplitSelected || context.isToolbarShown }) { [weak self] in self?.needsLayout = true }
        let compact = isCompact
        if compact != lastCompact { lastCompact = compact; SidebarDiagnostics.compactToolbarSwaps += 1 }
        if compact {
            // Measured: no toggle and no Reload; "More options" holds both (S2 06/0025–0029).
            let c = CompactToolbarMetrics.self, size = CGSize(width: c.buttonSize, height: c.buttonSize)
            back.frame = CGRect(origin: CGPoint(x: c.backX(sidebarWidth: w), y: c.y), size: size)
            forward.frame = CGRect(origin: CGPoint(x: c.forwardX(sidebarWidth: w), y: c.y), size: size)
            more.frame = CGRect(origin: CGPoint(x: c.moreX(sidebarWidth: w), y: c.y), size: size)
            // Arc's compact arrows are smaller than the full toolbar's (ink 13 × 10 vs 15 × 12).
            back.glyphView.glyph = .compactBack; forward.glyphView.glyph = .compactForward
            toggle.isHidden = true; reload.isHidden = true; more.isHidden = false
            for b in [back, forward] { b.isHidden = split }
        } else {
            toggle.frame = CGRect(origin: CGPoint(x: ChromeMetrics.sidebarToggleX, y: y), size: s)
            back.frame = CGRect(origin: CGPoint(x: ChromeMetrics.backX(sidebarWidth: w), y: y), size: s)
            forward.frame = CGRect(origin: CGPoint(x: ChromeMetrics.forwardX(sidebarWidth: w), y: y), size: s)
            reload.frame = CGRect(origin: CGPoint(x: ChromeMetrics.reloadX(sidebarWidth: w), y: y), size: s)
            back.glyphView.glyph = .back; forward.glyphView.glyph = .forward
            toggle.isHidden = false; more.isHidden = true
            for b in [back, forward, reload] { b.isHidden = split }
        }
    }
    private var lastCompact: Bool?
}

public enum SiteControlButtonState: String, Sendable {
    case rest, open, boosted, openBoosted
    public var isOpen: Bool { self == .open || self == .openBoosted }
    public var isBoosted: Bool { self == .boosted || self == .openBoosted }
}

/// The sidebar URL field: placeholder with a magnifier, or the current host.
/// A click asks the delegate to open the command bar (Cmd+L style).
@MainActor
final class URLFieldView: NSView {
    unowned let context: SidebarContext
    private let fill = CALayer()
    private let magnifier = GlyphView()
    private let label = TextLabel()
    /// Leading fade for a long host: the end (the registrable domain) stays visible (plan D3 §2.4).
    private let fadeMask = CAGradientLayer()
    private var fadeKey: (String, CGFloat)?
    let copyLink = PlateButton(glyph: .copyLink)
    let siteControls = PlateButton(glyph: .siteControls)
    private(set) var extensionStrip: ExtensionStripView?
    var siteControlsAvailable = true { didSet { if siteControlsAvailable != oldValue { needsLayout = true } } }
    var siteControlState = SiteControlButtonState.rest {
        didSet {
            guard siteControlState != oldValue else { return }
            // Open: the normal glyph on the pressed fill (the field fill again; Arc 14c, plan D3 §2.4).
            // Only a Boosted site keeps its own art.
            siteControlGlyph.isOpen = false; siteControlGlyph.isBoosted = siteControlState.isBoosted
            siteControls.glyphView.isHidden = siteControlState.isBoosted
            siteControlGlyph.isHidden = !siteControlState.isBoosted
            siteControls.isLatched = siteControlState.isOpen
            needsLayout = true
        }
    }
    private let siteControlGlyph = SiteControlGlyphView(frame: .zero)
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
        label.text = { [unowned context] in context.pageHost ?? "Search or Enter URL…" }
        label.color = { [unowned context] in
            (context.hasPage ? SidebarRole.urlText : SidebarRole.placeholder).nsColor
        }
        for b in [copyLink, siteControls] {
            b.context = context
            b.glyphTint = { _ in SidebarRole.toolbarGlyph.nsColor }
            addSubview(b)
        }
        copyLink.action = { [unowned context] in context.send(.copyCurrentURL) }
        siteControls.action = { [unowned context] in
            guard NSApp.currentEvent?.modifierFlags.contains(.option) != true else { return }
            context.send(.showSiteControls)
        }
        siteControlGlyph.isHidden = true
        siteControls.latchedColor = { [unowned self] in self.fieldFill(hovered: false) }
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5); fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)]
        fadeMask.actions = ["position": NSNull(), "bounds": NSNull(), "locations": NSNull()]
        siteControlGlyph.tint = { SidebarRole.toolbarGlyph.nsColor }
        siteControls.addSubview(siteControlGlyph)
        let style: @MainActor () -> SpaceThemeStyle = { [unowned context] in
            context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        }
        // The standard AppKit tooltip with Open's names (LEAD 12:12).
        _ = style
        copyLink.toolTip = "Copy Link"
        siteControls.toolTip = "Site Controls"
        copyLink.accessibleTitle = { "Copy Link" }
        siteControls.accessibleTitle = { "Site Controls" }
        addSubview(magnifier)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Search or Enter URL")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The copy and Site Control buttons show while a page is loaded and the pointer is over the
    /// field, or while the Site Control panel is open (Arc 14c rest/hover frames; plan D3 §2.4).
    /// Copy Link and Site Controls: not drawn and not in the accessibility tree at rest; shown while the pointer is anywhere
    /// inside the sidebar, and while the Site Control panel is open (Arc 1.172 session 3 URL rest/hover; LEAD 12:12).
    /// Renders count any forced hover as a pointer inside the sidebar.
    private var showsButtons: Bool {
        context.forcedHover != nil || context.pointerInSidebar || pointerInside || siteControlState.isOpen
    }

    func fieldFill(hovered: Bool) -> DesignColor { Self.fill(context: context, hovered: hovered) }

    /// Field fill: the existing measured token (LEAD 11:45; the theme pass sets this role later). The URL
    /// status button under the field shares it.
    static func fill(context: SidebarContext, hovered: Bool) -> DesignColor {
        if context.isIncognito { return DesignColor(.white(0.15)) }
        return hovered ? SidebarRole.fieldHover : SidebarRole.fieldFill
    }

    /// The pointer is over the field (or a render forces it). Arc darkens the field to
    /// `SidebarItemHoveredBackground` on hover (F0033 vs F0032: `#CF8B6F` vs `#D99273` at the
    /// same frame); the field does not move or grow.
    var isHovered: Bool { context.forcedHover == .urlField || pointerInside }

    override func updateLayer() {
        let appearance = contentAppearance
        let hovered = tracked({ isHovered }) { [weak self] in self?.needsDisplay = true }
        CATransaction.begin()
        CATransaction.setDisableActions(!context.animatesChanges)
        CATransaction.setAnimationDuration(Motion.hoverFade)
        fill.backgroundColor = fieldFill(hovered: hovered).cgColor(appearance)
        siteControls.needsDisplay = true
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Field frame is `[8, 46, W − 16, 36]` in sidebar space; this view is that frame.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = URLFieldMetrics.cornerRadius
        CATransaction.commit()
        let hasPage = tracked({ context.hasPage }) { [weak self] in self?.needsLayout = true }
        label.font = (hasPage ? Typography.urlHost : Typography.urlField).font
        let hovered = tracked({ showsButtons }) { [weak self] in self?.needsLayout = true }
        let extensionsUI = tracked({ context.extensionsUI }) { [weak self] in self?.needsLayout = true }
        if extensionStrip?.context !== extensionsUI {
            extensionStrip?.removeFromSuperview(); extensionStrip = nil
            if let extensionsUI {
                let strip = ExtensionStripView(style: .urlField, context: extensionsUI)
                strip.onVisibilityChange = { [weak self] in self?.needsLayout = true }
                addSubview(strip); extensionStrip = strip
            }
        }
        if let strip = extensionStrip {
            strip.frame = CGRect(x: -8, y: -46, width: bounds.width + 16, height: 82)
            strip.hasPage = hasPage; strip.hovered = hovered
            strip.tooltipStyle = context.focusedSpace.map(context.style(for:))
            strip.layoutSubtreeIfNeeded()
        }
        let showAccessories = hasPage && (hovered || extensionStrip?.showsActions == true || !(extensionsUI?.forcedVisibility.isEmpty ?? true))
        let ox = URLFieldMetrics.insetX, oy = URLFieldMetrics.y
        magnifier.isHidden = hasPage
        magnifier.frame = URLFieldMetrics.magnifierFrame.offsetBy(dx: -ox, dy: -oy)
        let textX = (hasPage ? URLFieldMetrics.hostX : URLFieldMetrics.placeholderX) - ox
        var right = bounds.width - (URLFieldMetrics.textTrailingInset - ox)
        let a = URLFieldMetrics.accessorySize
        siteControls.frame = CGRect(x: bounds.width + ox - URLFieldMetrics.siteControlsTrailing - a, y: URLFieldMetrics.accessoryY - oy, width: a, height: a)
        copyLink.frame = siteControls.frame.offsetBy(dx: -URLFieldMetrics.accessoryPitch, dy: 0)
        copyLink.isHidden = !hasPage || !showAccessories
        siteControls.isHidden = !hasPage || !siteControlsAvailable || !(showAccessories || siteControlState.isOpen)
        siteControlGlyph.frame = siteControls.bounds
        if showAccessories || siteControlState.isOpen {
            right = (copyLink.isHidden ? siteControls.frame.minX : copyLink.frame.minX) - URLFieldMetrics.controlsTextGap
            if let strip = extensionStrip, strip.showsActions, let first = strip.geometry.frames.map(\.minX).min() {
                right = first - ox - URLFieldMetrics.controlsTextGap
            }
        }
        label.frame = CGRect(x: textX, y: URLFieldMetrics.textY - oy, width: max(0, right - textX), height: 18)
        updateFade(hasPage: hasPage)
    }

    /// A host wider than the label: right-aligned, never a trailing ellipsis, the leading 34 pt faded
    /// to clear. Built once per text or width change; a short host has no mask (plan D3 §2.4).
    private func updateFade(hasPage: Bool) {
        let text = label.text(), width = label.bounds.width
        let key = (text, width)
        if let fadeKey, fadeKey == key { return }
        fadeKey = key
        let long = hasPage && label.textWidth > width
        label.alignment = long ? .right : .left
        label.trailingInset = 0
        label.allowsOverflow = long
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if long {
            let stop = NSNumber(value: Double(min(1, URLFieldMetrics.longHostFade / max(1, width))))
            fadeMask.locations = [0, stop, 1]
            fadeMask.frame = label.bounds
            label.layer?.mask = fadeMask
        } else {
            label.layer?.mask = nil
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // The field's own bounds, not `.inVisibleRect`: views that do not clip to their
        // bounds (the default since macOS 14) report a visible rect larger than the field,
        // and the hover fill must not show for a pointer elsewhere in the sidebar.
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
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
    override func menu(for event: NSEvent) -> NSMenu? { SidebarMenus(context: context).urlField() }
    var displayedText: String { label.text() }
    /// Diagnostics: the host label's frame, whether a long host is faded and right-aligned, and the first shown control's x.
    var hostState: (frame: CGRect, faded: Bool, rightAligned: Bool, firstControlX: CGFloat?) {
        let first = [copyLink, siteControls].filter { !$0.isHidden }.map(\.frame.minX).min()
        return (label.frame, label.layer?.mask != nil, label.alignment == .right, first)
    }
}
