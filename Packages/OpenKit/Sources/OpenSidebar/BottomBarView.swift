import AppKit
import OpenDesign
import OpenModel

/// Bottom bar: Home (Library), the Space switcher, and the plus menu
/// (runtime-observations §1.1, interaction-states §5).
@MainActor
final class BottomBarView: NSView {
    unowned let context: SidebarContext
    let home = HomeDownloadButton()
    let plus = PlateButton(glyph: .bottomPlus)
    let plusPopover = PlusPopover()
    /// The "+" popover's rows are `SidebarMenus.plus()`; colours follow the focused Space.
    func togglePlusPopover() {
        if plusPopover.isShown { plusPopover.close(); return }
        guard let sidebar = context.sidebar else { return }
        let style = context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        plusPopover.show(menu: menus.plus(), colors: PlusPopoverColors(style: style, system: context.systemAppearance), from: plus, sidebar: sidebar)
    }
    let strip = SwitcherStripView()
    private(set) var items: [SpaceID: SwitcherItemView] = [:]
    private var loop: ObservationLoop?
    /// What the strip last scrolled the current Space into view for; it scrolls again only when
    /// the current Space, its position (a reorder or undo), the strip width, or the Space count
    /// changes (never against a user scroll).
    private var revealed: (current: SpaceID?, index: Int?, width: CGFloat, count: Int)?
    var menus: SidebarMenus

    init(context: SidebarContext, menus: SidebarMenus) {
        self.context = context
        self.menus = menus
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false; layer?.masksToBounds = false
        addSubview(strip)
        let style: @MainActor () -> SpaceThemeStyle = { [unowned context] in
            context.focusedSpace.map(context.style(for:)) ?? .defaultTheme(system: context.systemAppearance)
        }
        for (b, key) in [(home, SidebarHoverTarget.home), (plus, .plus)] {
            b.context = context
            b.dimsWhenInactive = true
            b.inactiveTint = SidebarRole.bottomGlyphInactive
            b.hoverKey = key
            b.glyphTint = { [unowned context] _ in context.increasedContrastRoles?.bottomGlyph.nsColor ?? SidebarRole.bottomGlyph.nsColor }
            addSubview(b)
        }
        home.glyphTint = { [unowned context] _ in context.increasedContrastRoles?.bottomGlyph.nsColor ?? SidebarRole.homeGlyph.nsColor }
        home.inactiveTint = SidebarRole.homeGlyphInactive
        home.action = { [unowned context] in context.send(.showLibrary) }
        home.contextMenuProvider = { [weak self] in self?.menus.libraryMediaSources() }
        home.tooltip = { [weak home] in Tooltip(title: home?.latestName ?? "Library", placement: .above, style: style()) }
        if context.isIncognito {
            home.isHidden = true; strip.isHidden = true
            plus.action = { [unowned context] in context.send(.newTab) }
            plus.setAccessibilityLabel("New Tab")
        } else {
            // Arc's "+" opens a custom popover and turns into "×" while it shows (capture session 8 item 7).
            plus.action = { [weak self] in self?.togglePlusPopover() }
            plusPopover.onVisibilityChange = { [weak self] shown in self?.plus.glyphView.glyph = shown ? .rowClose : .bottomPlus }
            plusPopover.closesOnly = { [weak self] event in
                guard let self, event.window === self.window else { return false }
                return self.plus.bounds.contains(self.plus.convert(event.locationInWindow, from: nil))
            }
        }
        plus.tooltip = { Tooltip(title: "New…", placement: .above, style: style()) }
        loop = ObservationLoop(read: { [weak self] in
            _ = self?.context.model.spaces.map(\.id); _ = self?.context.downloadBadge; _ = self?.context.focusedSpace?.id
        }) { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loop?.cancel() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let m = BottomBarMetrics.self
        let w = bounds.width
        home.frame = CGRect(x:m.homeX,y:m.buttonY,width:32,height:32)
        plus.frame = CGRect(origin: CGPoint(x: w - m.plusTrailingInset - m.buttonSize.width, y: m.buttonY), size: m.buttonSize)
        let stripRect = CGRect(x: m.switcherLeading, y: 0, width: max(0, w - m.switcherLeading - m.switcherTrailing), height: m.height)
        strip.frame = stripRect
        let spaces = context.hidesSpaceChrome ? [] : context.model.spaces
        let live = Set(spaces.map(\.id))
        for (id, v) in items where !live.contains(id) { v.removeFromSuperview(); items[id] = nil }
        // Centered when the items fit (4 Spaces: 136 pt in a 144 pt strip → 4 pt each side). Otherwise
        // the strip scrolls: the document holds every item, the clip view shows the strip's width.
        // Item frames are 1 pt wider than their plate on each side; that slop may be clipped.
        let total = CGFloat(spaces.count) * m.switcherPitch
        let fits = total <= stripRect.width
        let x0 = fits ? (stripRect.width - total) / 2 - 1 : -1
        strip.document.frame = CGRect(x: 0, y: 0, width: fits ? stripRect.width : total, height: m.height)
        for (i, space) in spaces.enumerated() {
            let v = items[space.id] ?? {
                let v = SwitcherItemView(context: context, space: space, menus: menus)
                items[space.id] = v
                strip.document.addSubview(v)
                return v
            }()
            v.index = i
            v.frame = CGRect(x: x0 + CGFloat(i) * m.switcherPitch, y: m.switcherItemY, width: m.switcherItemSize.width, height: m.switcherItemSize.height)
        }
        strip.tile()  // the clip view takes the new strip width before reveal reads it
        let current = context.focusedSpace.flatMap { live.contains($0.id) ? $0.id : nil }
        let index = current.flatMap { id in spaces.firstIndex { $0.id == id } }
        let key = (current: current, index: index, width: stripRect.width, count: spaces.count)
        if let old = revealed, old.current == key.current, old.index == key.index, old.width == key.width, old.count == key.count {
            // Nothing the reveal depends on changed.
        } else {
            // Animate only a Space switch, and only where the sidebar animates (pager rule: a
            // visible window, `animatesChanges`); a resize, reorder or new Space lands at once.
            let animated = revealed != nil && revealed!.current != current && revealed!.width == key.width && revealed!.count == key.count
                && context.animatesChanges && (context.sidebar?.animatesSidebarChanges ?? false)
            revealed = key
            strip.reveal(current.flatMap { items[$0]?.frame }, animated: animated)
        }
        strip.updateFade()
    }
}

/// The Space switcher's clipped, horizontally scrolling strip between Home and + (runtime-observations
/// §1.1: Arc's switcher is a scroll area). No scroller is shown. Trackpad swipes scroll it natively;
/// a vertical mouse wheel scrolls it sideways. When the Spaces fit, scroll events pass on unchanged.
/// An end that hides more icons fades out (a mask, so it matches any bar background).
@MainActor
final class SwitcherStripView: NSScrollView {
    let document = SwitcherDocumentView()
    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        let clip = SwitcherClipView()
        clip.drawsBackground = false
        clip.onScroll = { [weak self] in self?.updateFade() }
        contentView = clip
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
        automaticallyAdjustsContentInsets = false
        wantsLayer = true
        documentView = document
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var overflows: Bool { document.frame.width > contentView.bounds.width + 0.5 }

    override func scrollWheel(with event: NSEvent) {
        guard overflows else { nextResponder?.scrollWheel(with: event); return }
        TooltipController.shared.cancel(for: nil)  // a shown or pending tooltip would stay at the old place
        // A mouse wheel (no gesture phase) that turns vertically moves the strip sideways.
        if event.phase == [], event.momentumPhase == [], abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * BottomBarMetrics.switcherPitch / 3
            scroll(toX: contentView.bounds.minX - step, animated: false)
            return
        }
        super.scrollWheel(with: event)
    }

    /// Whether an animated reveal is in flight, and which one (a newer scroll supersedes it).
    private var revealing = false
    private var revealGeneration = 0

    /// Scrolls to `x` (not rounded, so slow precise wheel steps add up). A direct scroll replaces an
    /// in-flight reveal: AppKit retargets an animator property when it is set again in a
    /// zero-duration group, so the reveal cannot overwrite the new position.
    func scroll(toX x: CGFloat, animated: Bool) {
        let limit = max(0, document.frame.width - contentView.bounds.width)
        let target = NSPoint(x: min(max(0, x), limit), y: 0)
        guard target != contentView.bounds.origin || revealing else { return }
        TooltipController.shared.cancel(for: nil)
        revealGeneration += 1
        let generation = revealGeneration
        if animated && !Motion.reducesMotion {
            revealing = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = BottomBarMetrics.switcherRevealDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.revealGeneration == generation { self.revealing = false }
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        } else {
            if revealing {
                revealing = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    contentView.animator().setBoundsOrigin(target)
                }
            }
            contentView.setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        }
    }

    /// Scrolls the least distance that shows `itemFrame` (document coordinates) outside the fades.
    func reveal(_ itemFrame: CGRect?, animated: Bool) {
        guard overflows else { scroll(toX: 0, animated: false); return }
        guard let itemFrame else { return }
        let visible = contentView.bounds, margin = BottomBarMetrics.switcherFadeWidth
        if visible.width < itemFrame.width + 2 * margin {
            // Too narrow to keep the item clear of both fades (strip under 92 pt: sidebar 164–175
            // pt): center it. The offset then moves one way as the width changes (no jitter).
            scroll(toX: (itemFrame.midX - visible.width / 2).rounded(), animated: animated)
        } else if itemFrame.minX - margin < visible.minX {
            scroll(toX: (itemFrame.minX - margin).rounded(), animated: animated)
        } else if itemFrame.maxX + margin > visible.maxX {
            scroll(toX: (itemFrame.maxX + margin - visible.width).rounded(), animated: animated)
        } else {
            // Keep a stale offset inside the new range (the document can shrink).
            scroll(toX: visible.minX, animated: false)
        }
    }

    /// Which ends hide some icon ink (the emoji or glyph, not only the plate's transparent margin).
    var fadeEdges: (left: Bool, right: Bool) {
        let m = BottomBarMetrics.self
        let ink = (m.switcherItemSize.width - m.switcherEmojiSize) / 2 - m.switcherPlateInset.width
        let visible = contentView.bounds
        return (visible.minX > ink + 0.5, visible.maxX < document.frame.width - ink - 0.5)
    }

    /// The fade last applied (ends and size); a scroll that keeps it skips the mask update.
    private var appliedFade: FadeState?
    private struct FadeState: Equatable { let left: Bool, right: Bool, size: CGSize }

    func updateFade() {
        let (left, right) = fadeEdges
        let state = FadeState(left: left, right: right, size: bounds.size)
        guard state != appliedFade else { return }
        appliedFade = state
        guard let layer, bounds.width > 0, left || right else { layer?.mask = nil; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let f = min(0.5, BottomBarMetrics.switcherFadeWidth / bounds.width)
        let opaque = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        fade.frame = bounds
        fade.colors = [left ? clear : opaque, opaque, opaque, right ? clear : opaque]
        fade.locations = [0, NSNumber(value: Double(left ? f : 0)), NSNumber(value: Double(right ? 1 - f : 1)), 1]
        if layer.mask !== fade { layer.mask = fade }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateFade()
    }
}

/// Flipped document for the switcher strip, so items keep the bar's top-down y.
@MainActor
final class SwitcherDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Clip view that reports every scroll (gesture, wheel, reveal, elastic bounce) for the fades.
@MainActor
final class SwitcherClipView: NSClipView {
    var onScroll: (@MainActor () -> Void)?
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onScroll?()
    }
}

/// One Space in the switcher: emoji in color when current, faded and gray otherwise.
@MainActor
final class SwitcherItemView: PlateButton {
    let space: Space
    let icon = SpaceIconView()
    var index = 0
    let menus: SidebarMenus
    private var springLoad: DispatchWorkItem?
    private var springPayload: [ItemID]?
    private var springScheduled = false
    private var springDelay: TimeInterval?
    /// Delay the pending spring-load switch was scheduled with, nil when none is pending.
    var pendingSpringLoadDelay: TimeInterval? { springLoad == nil ? nil : springDelay }

    isolated deinit { springLoad?.cancel() }

    init(context: SidebarContext, space: Space, menus: SidebarMenus) {
        self.space = space
        self.menus = menus
        super.init(glyph: nil)
        self.context = context
        hoverKey = .switcher(space.id)
        plateRect = { $0.insetBy(dx: BottomBarMetrics.switcherPlateInset.width, dy: BottomBarMetrics.switcherPlateInset.height) }
        plateRadius = BottomBarMetrics.plateRadius
        icon.space = space
        icon.context = context
        icon.emojiSize = BottomBarMetrics.switcherEmojiSize
        addSubview(icon)
        action = { [unowned context, space] in context.send(.switchSpace(space.id)) }
        menuProvider = nil
        tooltip = { [weak self, unowned context] in
            guard let self else { return nil }
            // The binding in effect after a rebind (bug sweep r7 AB-07).
            let keys = self.index < 9 ? context.keys("go-to-space-\(self.index + 1)", default: ["⌃", "\(self.index + 1)"]) : []
            return Tooltip(title: context.title(of: space), keys: keys, placement: .above, style: context.style(for: space))
        }
        registerForDraggedTypes([.sidebarNode, .URL, .fileURL])
        accessibleTitle = { [unowned context, space] in context.title(of: space) }
    }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    override func updateLayer() {
        super.updateLayer()
        guard let context else { return }
        let current = tracked({ context.focusedSpace === space }) { [weak self] in self?.needsDisplay = true }
        icon.desaturated = !current
        icon.alphaValue = current ? 1 : SidebarRole.switcherInactiveOpacity
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menus.space(space), with: event, for: self)
    }

    private func operation(for pb: NSPasteboard) -> NSDragOperation {
        guard let context, context.model.space(id: space.id) != nil else { return [] }
        if let ids = SidebarPasteboard.nodeIDs(from: pb) {
            return !ids.isEmpty && ids.contains {
                context.model.canMoveNode(id: $0, to: SidebarPasteboard.destination(for: $0, in: space.id, model: context.model))
            } ? .move : []
        }
        return SidebarPasteboard.urls(from: pb).isEmpty ? [] : .copy
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        context?.suppressPreviews(.drag, true)
        let operation = operation(for: sender.draggingPasteboard)
        guard !operation.isEmpty else { cancelSpringLoad(); return [] }
        let ids = SidebarPasteboard.nodeIDs(from: sender.draggingPasteboard)
        if !springScheduled || springPayload != ids {
            cancelSpringLoad()
            springScheduled = true
            springPayload = ids
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.springScheduled, let context = self.context else { return }
                    self.springLoad = nil; self.springDelay = nil
                    if let ids, !ids.contains(where: { context.model.canMoveNode(id: $0, to: SidebarPasteboard.destination(for: $0, in: self.space.id, model: context.model)) }) { return }
                    context.send(.switchSpace(self.space.id))
                }
            }
            let delay: TimeInterval = 0.5
            springLoad = work
            springDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        return operation
    }

    private func cancelSpringLoad() {
        springLoad?.cancel()
        springLoad = nil
        springDelay = nil
        springScheduled = false
        springPayload = nil
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { cancelSpringLoad(); context?.suppressPreviews(.drag, false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { cancelSpringLoad(); context?.suppressPreviews(.drag, false) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { cancelSpringLoad() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !operation(for: sender.draggingPasteboard).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { context?.suppressPreviews(.drag, false) }
        cancelSpringLoad()
        guard !operation(for: sender.draggingPasteboard).isEmpty, let context else { return false }
        if let ids = SidebarPasteboard.nodeIDs(from: sender.draggingPasteboard) {
            let accepted = context.send(.moveNodesToSpace(ids: ids, space: space.id))
            context.haptics.dropped(accepted)
            return accepted
        }
        let urls = SidebarPasteboard.urls(from: sender.draggingPasteboard)
        for url in urls.reversed() {
            guard context.send(.openURL(url, in: .spaceToday(space.id), index: 0)) else { return false }
        }
        return !urls.isEmpty
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelSpringLoad() }
        super.viewWillMove(toWindow: newWindow)
    }
}
