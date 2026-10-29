import AppKit
import OpenDesign
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
    public private(set) var request: SidebarHoverPreviewRequest?
    public private(set) var card: PreviewCardView?
    public private(set) var host: (any WebContentHost)?
    public private(set) var hostTabID: ItemID?
    /// Factory calls made for previews, and whether the last page card reused a cached host.
    public private(set) var makeHostCount = 0
    public private(set) var reusedCachedHost = false
    public private(set) var shows = 0

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
        }
        request = next; shows += 1
        layout()
        if let layer = card?.layer, !swapping, !Motion.reducesMotion, root.window?.isVisible == true || SidebarDiagnostics.forceAnimations {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.duration = Motion.previewIn; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "previewIn")
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
        guard let card else { request = nil; return }
        let page = host, id = hostTabID
        self.card = nil; host = nil; hostTabID = nil; request = nil
        if let page, let id {
            page.view.removeFromSuperview()
            container.adopt(page, for: id)
        }
        let animates = animated && !Motion.reducesMotion && (root.window?.isVisible == true || SidebarDiagnostics.forceAnimations)
        guard animates, let layer = card.layer else { card.removeFromSuperview(); return }
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.duration = Motion.previewOut
        layer.add(fade, forKey: "previewOut")
        let work = DispatchWorkItem { [weak card] in MainActor.assumeIsolated { card?.removeFromSuperview() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.previewOut, execute: work)
    }
}

/// The preview card: radius 10 continuous, black 0.25 shadow (radius 12, y + 4), the preview
/// background under its content (`HoverPreviewMetrics`, `PreviewColors`; guesses until C4).
@MainActor
public final class PreviewCardView: NSView {
    public let content: NSView
    private let clip = NSView()
    private let catcher: ClickCatcher?
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
        clip.frame = bounds; content.frame = clip.bounds; catcher?.frame = clip.bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: HoverPreviewMetrics.radius, cornerHeight: HoverPreviewMetrics.radius, transform: nil)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
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
