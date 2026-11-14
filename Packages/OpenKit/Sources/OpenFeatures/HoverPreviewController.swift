import AppKit
import OpenDesign
import OpenLiveData
import OpenModel
import OpenSidebar

/// Shows the sidebar's Hover Previews (completion §3.6, A2): a page card with the tab's own
/// web content host, or the native folder card. The tracker in OpenSidebar decides when;
/// this controller only places, fills, and clears the card. At most one preview host exists:
/// a hidden cached host moves into the card (no reload), otherwise the factory makes one for
/// the tab's ID. On dismiss the host goes back to the container's hidden cache, so selecting
/// the tab later shows the same page.
@MainActor
public final class HoverPreviewController {
    private unowned let root: NSView
    private let container: WebContentContainer
    private let factory: any WebContentHostFactory
    private let context: SidebarContext
    private let select: @MainActor (ItemID) -> Void
    /// Opens a live-data card link as a Peek of the hovered tab (LD §3.3 "Links").
    public var openPeek: (@MainActor (URL, ItemID) -> Void)?
    public private(set) var request: SidebarHoverPreviewRequest?
    public private(set) var card: PreviewCardView?
    public private(set) var host: (any WebContentHost)?
    public private(set) var hostTabID: ItemID?
    /// Factory calls made for previews, and whether the last page card reused a cached host.
    public private(set) var makeHostCount = 0
    public private(set) var reusedCachedHost = false
    public private(set) var shows = 0
    private var retiringCard: PreviewCardView?

    init(root: NSView, container: WebContentContainer, factory: any WebContentHostFactory, context: SidebarContext,
         select: @escaping @MainActor (ItemID) -> Void) {
        self.root = root; self.container = container; self.factory = factory; self.context = context; self.select = select
    }

    /// The tracker's request: show, swap, or hide (nil).
    public func update(_ next: SidebarHoverPreviewRequest?) {
        guard let next else { hide(animated: !context.hoverPreviews.dismissesImmediately); return }
        if request?.kind == next.kind, card != nil { request = next; layout(); return }
        let swapping = card != nil
        hide(animated: false)
        switch next.kind {
        case .page(let id): guard showPage(id) else { return }
        case .folder(let id): guard showFolder(id) else { return }
        case .glance(let id): guard showGlance(id) else { return }
        }
        request = next; shows += 1
        layout()
        if let layer = card?.layer, !swapping, !Motion.reducesMotion, root.window?.isVisible == true || SidebarDiagnostics.forceAnimations {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.duration = Motion.previewIn; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Folder contents are static during the fade. Composite one bitmap
            // rather than the text, icons, clip and shadow on every frame.
            if case .folder = next.kind {
                layer.rasterizationScale = root.window?.backingScaleFactor ?? 1
                layer.shouldRasterize = true
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak card] in
                MainActor.assumeIsolated {
                    if card?.layer?.animation(forKey: "previewOut") == nil {
                        card?.layer?.shouldRasterize = false
                    }
                }
            }
            layer.add(fade, forKey: "previewIn")
            CATransaction.commit()
        }
    }

    private func showPage(_ id: ItemID) -> Bool {
        guard let tab = context.model.tab(id: id), let profile = context.focusedSpace?.profileID ?? context.model.profiles.first?.id else { return false }
        var page = container.takeHost(for: id)
        reusedCachedHost = page != nil
        let needsLoad = page == nil
        if needsLoad {
            page = factory.makeHost(tabID: id, profileID: profile, url: nil)
            makeHostCount += 1
        }
        guard let page else { return false }
        container.connectPreviewHost(page, for: id)
        if needsLoad { page.load(tab.url) }
        let card = PreviewCardView(content: page.view, appearance: appearance)
        card.onClick = { [weak self] in self?.choose(id) }
        card.onPointer = { [weak self] inside in self?.context.hoverPreviews.setPointerInsidePreview(inside) }
        page.view.isHidden = false
        root.addSubview(card)
        self.card = card; host = page; hostTabID = id
        return true
    }

    private func showFolder(_ id: ItemID) -> Bool {
        guard let folder = context.model.node(id: id)?.folder else { return false }
        let view = FolderPreviewView(context: context, folder: folder)
        view.onSelect = { [weak self] _ in self?.hide(animated: false) }
        let card = PreviewCardView(content: view, appearance: appearance, clicksSelect: false)
        card.onPointer = { [weak self] inside in self?.context.hoverPreviews.setPointerInsidePreview(inside) }
        root.addSubview(card)
        self.card = card
        return true
    }

    /// The native live-data card (Recents, LD §3.4). Owns no web host.
    private func showGlance(_ id: ItemID) -> Bool {
        guard let tab = context.model.tab(id: id), let kind = context.glanceKind(for: tab) else { return false }
        let content: NSView
        switch kind {
        case .gmail(let account):
            let view = MailPreviewView(context: context, tab: tab, account: account)
            view.onOpen = { [weak self] url in
                self?.hide(animated: false)
                self?.openPeek?(url, id)
            }
            view.onResize = { [weak self] in self?.layout() }
            content = view
        case .recents(let site):
            let view = RecentsPreviewView(context: context, tab: tab, site: site)
            view.onOpen = { [weak self] url in
                self?.hide(animated: false)
                self?.openPeek?(url, id)
            }
            view.onResize = { [weak self] in self?.layout() }
            content = view
        case .calendar(let provider):
            guard let source = context.calendarGlance else { return false }
            let view = CalendarPreviewView(context: context, tab: tab, provider: provider, source: source)
            view.onOpen = { [weak self] url in
                self?.hide(animated: false)
                self?.openPeek?(url, id)
            }
            view.onSelectTab = { [weak self] in
                self?.hide(animated: false)
                self?.select(id)
            }
            view.onResize = { [weak self] in self?.layout() }
            content = view
        case .pullRequest:
            // C-LF-1: the PR card; a click opens the row like a click on the row.
            guard let info = tab.liveItem else { return false }
            let card = PreviewCardView(content: LiveItemPreviewView(context: context, tab: tab, info: info), appearance: appearance)
            card.onClick = { [weak self] in self?.choose(id) }
            card.onPointer = { [weak self] inside in self?.context.hoverPreviews.setPointerInsidePreview(inside) }
            root.addSubview(card)
            self.card = card
            return true
        }
        let card = PreviewCardView(content: content, appearance: appearance, clicksSelect: false)
        card.onPointer = { [weak self] inside in self?.context.hoverPreviews.setPointerInsidePreview(inside) }
        root.addSubview(card)
        self.card = card
        return true
    }

    private var appearance: ContentAppearance { context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance }

    /// Places the card next to the sidebar (window coordinates of the root, top-left origin).
    public func layout() {
        guard let card, let request else { return }
        let bounds = root.bounds, anchor = root.convert(request.anchorInWindow, from: nil)
        let m = HoverPreviewMetrics.self
        let preferredWidth: CGFloat, preferredHeight: CGFloat, gap: CGFloat, preferredY: CGFloat
        let availableHeight = max(0, bounds.height - 2 * m.windowInset)
        switch request.kind {
        case .page:
            preferredWidth = m.pageWidth; preferredHeight = m.pageMaxHeight; gap = m.sidebarGap
            preferredY = anchor.minY - m.windowInset
        case .folder:
            preferredWidth = m.folderWidth; preferredHeight = (card.content as? FolderPreviewView)?.fittingSize.height ?? 200
            gap = m.folderSidebarGap
            preferredY = anchor.midY - min(preferredHeight, availableHeight) / 2
        case .glance:
            // Placed like the folder card (GUESS — capture pending, F2 item 10).
            preferredWidth = m.folderWidth; preferredHeight = card.content.fittingSize.height
            gap = m.folderSidebarGap
            preferredY = anchor.midY - min(preferredHeight, availableHeight) / 2
        }
        // When the sidebar leaves less than a useful card width, shrink to fit
        // to its right. Never cross the window's right edge minus 8 pt.
        let right = max(bounds.minX, bounds.maxX - 8)
        let x = min(max(bounds.minX, bounds.minX + context.sidebarWidth + gap), right)
        let width = min(preferredWidth, max(0, right - x))
        let height = min(preferredHeight, availableHeight)
        let top = min(bounds.maxY, bounds.minY + m.windowInset)
        let y = min(max(top, preferredY), max(top, bounds.maxY - m.windowInset - height))
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if card.frame != frame { card.frame = frame }
        context.hoverPreviews.setPreviewFrameInWindow(root.convert(card.frame, to: nil))
    }

    /// A click in the page card selects its tab; the container then shows the same host.
    private func choose(_ id: ItemID) {
        hide(animated: false)
        context.hoverPreviews.dismiss()
        select(id)
    }

    /// Removes the card. A page host returns to the container's hidden cache (LRU and sleep).
    public func hide(animated: Bool) {
        context.hoverPreviews.setPreviewFrameInWindow(nil)
        retiringCard?.removeFromSuperview(); retiringCard = nil
        guard let card else { request = nil; return }
        let page = host, id = hostTabID
        self.card = nil; host = nil; hostTabID = nil; request = nil
        card.isDismissing = true; card.onClick = nil; card.onPointer = nil
        if let page, let id {
            page.view.removeFromSuperview()
            container.adopt(page, for: id)
        }
        let animates = animated && !Motion.reducesMotion && (root.window?.isVisible == true || SidebarDiagnostics.forceAnimations)
        guard animates, let layer = card.layer else { card.removeFromSuperview(); return }
        let start = layer.presentation()?.opacity ?? layer.opacity
        retiringCard = card
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak card] in
            MainActor.assumeIsolated {
                card?.removeFromSuperview()
                if self?.retiringCard === card { self?.retiringCard = nil }
            }
        }
        layer.removeAnimation(forKey: "previewIn"); layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = start; fade.toValue = 0
        fade.duration = Motion.previewOut
        layer.add(fade, forKey: "previewOut")
        CATransaction.commit()
    }
}

/// The preview card: radius 10 continuous, black 0.25 shadow (radius 12, y + 4), the preview
/// background under its content (`HoverPreviewMetrics`, `PreviewColors`; guesses until C4).
@MainActor
public final class PreviewCardView: NSView {
    public let content: NSView
    private let clip = NSView()
    private let catcher: ClickCatcher?
    fileprivate var isDismissing = false
    var onClick: (@MainActor () -> Void)?
    var onPointer: (@MainActor (Bool) -> Void)?
    private var tracking: NSTrackingArea?

    init(content: NSView, appearance: ContentAppearance, clicksSelect: Bool = true) {
        self.content = content
        catcher = clicksSelect ? ClickCatcher() : nil
        super.init(frame: .zero)
        wantsLayer = true
        let m = HoverPreviewMetrics.self
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = m.shadowOpacity
        layer?.shadowRadius = m.shadowRadius; layer?.shadowOffset = CGSize(width: 0, height: -m.shadowOffsetY)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = m.radius; clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = PreviewColors.background.cgColor(appearance)
        addSubview(clip)
        clip.addSubview(content)
        if let catcher { catcher.onClick = { [weak self] in self?.onClick?() }; clip.addSubview(catcher) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Preview")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout()
        if clip.frame != bounds { clip.frame = bounds }
        if content.frame != clip.bounds { content.frame = clip.bounds }
        if catcher?.frame != clip.bounds { catcher?.frame = clip.bounds }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: HoverPreviewMetrics.radius, cornerHeight: HoverPreviewMetrics.radius, transform: nil)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }
    public override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    public override func mouseExited(with event: NSEvent) { onPointer?(false) }
    /// Sends the click to the card (checks and automation use the real event path).
    public func click() { onClick?() }
}

/// Takes the click over a page preview (the page itself gets no input while it is a preview).
@MainActor
private final class ClickCatcher: NSView {
    var onClick: (@MainActor () -> Void)?
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
