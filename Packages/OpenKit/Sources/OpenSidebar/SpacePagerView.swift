import AppKit
import OpenDesign
import OpenModel

/// Horizontal pager of Space pages. Pages sit side by side at `index × width`
/// in a layer strip; native page frames stay in the viewport. A switch slides
/// the strip with a spring while the window
/// background cross-fades (docs/re/interaction-states.md §10). A two-finger
/// horizontal swipe drags the strip and the cross-fade interactively.
/// Pages are built on first use and kept; pages off screen are hidden.
@MainActor
final class SpacePagerView: NSView {
    unowned let context: SidebarContext
    let strip = PagerStrip()
    private(set) var pages: [SpaceID: SpacePageView] = [:]
    var menus: SidebarMenus
    weak var themeBackground: ThemeBackgroundView?
    /// Strip offset in points (page index × width) as the model state, not the presentation.
    private var creationPage: NSView?
    private var offset: CGFloat = 0
    private var shownSpaceID: SpaceID?
    private var animating = false
    private var slideGeneration = 0
    private(set) var lastSlideAnimation: CAAnimation?
    private var swipe: SwipeState?
    private var loop: ObservationLoop?


    private struct SwipeState {
        var baseIndex: Int
        var startOffset: CGFloat
        var neighbor: Int?
        var lastDeltas: [CGFloat] = []
        var pastThreshold = false
    }

    init(context: SidebarContext, menus: SidebarMenus) {
        self.context = context
        self.menus = menus
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(strip)
        loop = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.window?.focusedSpaceID
            _ = self.context.model.spaces.map(\.id)
        }) { [weak self] in self?.showFocused(animated: true) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loop?.cancel() }
    override var isFlipped: Bool { true }

    private var spaces: [Space] { context.model.spaces }
    private var focusedIndex: Int { context.focusedSpace.flatMap { s in spaces.firstIndex { $0 === s } } ?? 0 }

    func page(for space: Space) -> SpacePageView {
        if let p = pages[space.id] { return p }
        let p = SpacePageView(context: context, space: space, menus: menus)
        p.scroll.pager = self
        pages[space.id] = p
        strip.addSubview(p)
        return p
    }

    var currentPage: SpacePageView? { context.focusedSpace.map(page(for:)) }

    override func layout() {
        super.layout()
        if shownSpaceID == nil { showFocused(animated: false); return }
        layoutPages()
        if !animating && swipe == nil {
            // Focus observation runs on the next main-actor turn. A layout in
            // between must keep the displayed Space in place so showFocused
            // can start its spring from the existing presentation position.
            let shownIndex = shownSpaceID.flatMap { id in spaces.firstIndex { $0.id == id } } ?? focusedIndex
            offset = CGFloat(creationPage == nil ? shownIndex : spaces.count) * bounds.width
        }
        placeStrip()
    }

    private func layoutPages() {
        let frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Native pages share the viewport. AppKit can paint every participating
        // page; their backing layers form the horizontal strip. Native origins
        // outside the viewport would cull incoming rows until the slide ended.
        if let creationPage {
            creationPage.wantsLayer = true
            if creationPage.frame != frame { creationPage.frame = frame }
            creationPage.layer?.setValue(CGFloat(spaces.count) * bounds.width, forKeyPath: "transform.translation.x")
        }
        let live = Set(spaces.map(\.id))
        for (id, page) in pages where !live.contains(id) { page.removeFromSuperview(); pages[id] = nil }
        for (index, space) in spaces.enumerated() {
            guard let page = pages[space.id] else { continue }
            if page.frame != frame { page.frame = frame }
            page.layer?.setValue(CGFloat(index) * bounds.width, forKeyPath: "transform.translation.x")
        }
        strip.inputPage = creationPage ?? context.focusedSpace.flatMap { pages[$0.id] }
        CATransaction.commit()
    }

    private func placeStrip() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if strip.frame != bounds { strip.frame = bounds }
        strip.layer?.setValue(-offset, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    /// Slides to the focused Space. Every page between the old and the new one is
    /// shown during the slide (Arc passes through them, A0227).
    func showFocused(animated: Bool) {
        guard creationPage == nil else { layoutPages(); offset = CGFloat(spaces.count) * bounds.width; placeStrip(); return }
        let requestedAt = CACurrentMediaTime()
        guard let focused = context.focusedSpace, bounds.width > 0, swipe == nil else { return }
        let previous = shownSpaceID
        guard previous != focused.id else {
            // Space order can change while focus stays on the same Space.
            // Keep the cached page objects and re-offset the strip immediately.
            layoutPages()
            if animating, offset == CGFloat(focusedIndex) * bounds.width { return }
            slideGeneration += 1
            strip.layer?.removeAnimation(forKey: "slide")
            animating = false
            offset = CGFloat(focusedIndex) * bounds.width
            placeStrip(); finishSlide()
            return
        }
        if previous != nil { context.selection.clear(); context.existingHoverPreviews?.dismiss() }
        let target = focusedIndex
        let w = bounds.width
        let from = previous.flatMap { id in spaces.firstIndex { $0.id == id } } ?? target
        for i in min(from, target)...max(from, target) { setPage(page(for: spaces[i]), visible: true) }
        layoutPages()
        shownSpaceID = focused.id
        let presentationX = presentationOffset
        offset = CGFloat(target) * w
        let animate = animated && context.animatesChanges && previous != nil
            && animatesSidebarChanges && !Motion.reducesMotion
        placeStrip()
        let style = context.style(for: focused)
        guard animate else {
            slideGeneration += 1
            strip.layer?.removeAnimation(forKey: "slide")
            lastSlideAnimation = nil
            animating = false
            themeBackground?.crossfade(to: style, animated: false)
            finishSlide()
            return
        }
        slide(from: presentationX, spring: Motion.spaceSwitch, requestedAt: requestedAt)
        themeBackground?.crossfade(to: style, animated: true)
    }

    private var presentationOffset: CGFloat {
        strip.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
            ?? strip.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? -offset
    }

    private func slide(from x: CGFloat, spring token: SpringToken, requestedAt: CFTimeInterval? = nil) {
        animating = true
        slideGeneration += 1
        let generation = slideGeneration
        let motionLayer = strip.layer
        let spring = token.animation(keyPath: "transform.translation.x")
        spring.fromValue = x
        // The finite spring still has a subpixel remainder at settlingDuration.
        // Normalize its travel so its last presentation matches the model when
        // Core Animation removes it. Keep the response, damping and lifetime.
        let progress = Motion.springProgress(token, at: spring.duration)
        spring.toValue = progress.isFinite && abs(progress) > 0.001
            ? x + (-offset - x) / CGFloat(progress) : -offset
        let hz = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
            guard let self, self.slideGeneration == generation else { return }
            self.animating = false; self.placeStrip(); self.finishSlide()
        } }
        let request = requestedAt ?? CACurrentMediaTime()
        spring.beginTime = motionLayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        spring.setValue(motionLayer?.convertTime(request, from: nil) ?? request, forKey: "openRequestedAt")
        motionLayer?.add(spring, forKey: "slide")
        lastSlideAnimation = motionLayer?.animation(forKey: "slide")
        CATransaction.commit()
    }

    private func finishSlide() {
        guard !animating, swipe == nil else { return }
        let focused = context.focusedSpace?.id
        for (id, p) in pages { setPage(p, visible: creationPage == nil && id == focused) }
    }

    private func setPage(_ page: SpacePageView, visible: Bool) {
        // The native pages overlap in the viewport. Hiding an outgoing NSView
        // invalidates its still-visible sibling at the spring endpoint. Keep
        // visibility in the layer tree so the resting page needs no repaint.
        // Accessibility follows the same visibility, and PagerStrip owns input.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        page.layer?.isHidden = !visible
        page.setAccessibilityHidden(!visible)
        CATransaction.commit()
    }

    func beginCreation(page: NSView) {
        guard creationPage == nil else { return }
        swipe = nil; creationPage = page; strip.addSubview(page)
        let from = presentationOffset
        layoutPages(); offset = CGFloat(spaces.count) * bounds.width; placeStrip()
        if animatesSidebarChanges && !Motion.reducesMotion { slide(from: from, spring: Motion.spaceSwitch) }
        else {
            slideGeneration += 1
            strip.layer?.removeAnimation(forKey: "slide")
            lastSlideAnimation = nil
            animating = false; finishSlide()
        }
    }

    func endCreation() {
        let from = presentationOffset
        creationPage?.removeFromSuperview(); creationPage = nil
        strip.layer?.removeAnimation(forKey: "slide"); animating = false
        shownSpaceID = nil
        showFocused(animated: false)
        if animatesSidebarChanges && !Motion.reducesMotion { slide(from: from, spring: Motion.spaceSwitch) }
        if let space = context.focusedSpace { themeBackground?.crossfade(to: context.style(for: space), animated: animatesSidebarChanges) }
    }

    // MARK: Swipe

    /// Two-finger horizontal swipe. Returns true when the event belonged to a swipe.
    func handleScroll(_ event: NSEvent) -> Bool {
        guard creationPage == nil else { return false }
        if event.momentumPhase != [] { return swipe != nil || animating }
        let w = bounds.width
        guard w > 0 else { return false }
        switch event.phase {
        case .began:
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            context.suppressPreviews(.swipe, true)
            let start = -presentationOffset
            slideGeneration += 1
            strip.layer?.removeAnimation(forKey: "slide")
            animating = false
            let base = focusedIndex
            swipe = SwipeState(baseIndex: base, startOffset: start)
            offset = swipe!.startOffset
            for p in pages.values { setPage(p, visible: true) }
            for i in max(0, base - 1)...min(spaces.count - 1, base + 1) { _ = page(for: spaces[i]) }
            layoutPages()
            return true
        case .changed:
            guard var s = swipe else { return false }
            let dx = event.scrollingDeltaX
            s.lastDeltas = Array((s.lastDeltas + [dx]).suffix(4))
            let base = CGFloat(s.baseIndex) * w
            var next = offset - dx
            // Rubber band past the ends and beyond one neighbor.
            let lo = max(0, CGFloat(s.baseIndex - 1) * w), hi = min(CGFloat(spaces.count - 1) * w, base + w)
            if next < lo { next = lo - rubber(lo - next, w) } else if next > hi { next = hi + rubber(next - hi, w) }
            offset = next
            let past = abs(offset - base) / w > 0.5
            let direction = offset > base ? 1 : -1
            if past, !s.pastThreshold, spaces.indices.contains(s.baseIndex + direction) { context.haptics.perform(.levelChange) }
            s.pastThreshold = past
            if !Motion.reducesMotion { placeStrip() }
            let dir = offset >= base ? 1 : -1
            let n = s.baseIndex + dir
            if spaces.indices.contains(n) {
                if s.neighbor != n { themeBackground?.beginTransition(to: context.style(for: spaces[n])); s.neighbor = n }
                themeBackground?.setTransitionProgress(Double(min(abs(offset - base) / w, 1)))
            }
            swipe = s
            return true
        case .ended, .cancelled:
            guard let s = swipe else { return false }
            let velocity = s.lastDeltas.reduce(0, +) / CGFloat(max(s.lastDeltas.count, 1))
            let moved = (offset - CGFloat(s.baseIndex) * w) / w
            var target = s.baseIndex
            if event.phase == .ended && (abs(moved) > 0.5 || (abs(velocity) > 6 && abs(moved) > 0.08)) {
                target = min(max(s.baseIndex + (moved > 0 ? 1 : -1), 0), spaces.count - 1)
            }
            swipe = nil
            context.suppressPreviews(.swipe, false)
            if target != s.baseIndex { context.selection.clear() }
            // The delegate changes focus synchronously; snap to whatever is focused now.
            if target != s.baseIndex { context.send(.switchSpace(spaces[target].id)) }
            let landed = focusedIndex
            themeBackground?.endTransition(commit: landed != s.baseIndex && landed == s.neighbor, duration: Motion.reducesMotion ? 0 : Motion.themeCrossfade)
            if landed != s.baseIndex && landed != s.neighbor, let f = context.focusedSpace {
                themeBackground?.crossfade(to: context.style(for: f), animated: true)
            }
            shownSpaceID = context.focusedSpace?.id
            let from = -offset
            offset = CGFloat(landed) * w
            let animate = animatesSidebarChanges && !Motion.reducesMotion
            placeStrip()
            if animate { slide(from: from, spring: Motion.spaceSwipeSnap) }
            else { lastSlideAnimation = nil; animating = false; finishSlide() }
            return true
        default:
            return swipe != nil
        }
    }

    private func rubber(_ x: CGFloat, _ w: CGFloat) -> CGFloat { (1 - 1 / (x * 0.55 / w + 1)) * w }

    override func scrollWheel(with event: NSEvent) {
        if !handleScroll(event) { super.scrollWheel(with: event) }
    }

    /// Applies a model change to every built page.
    func apply(_ change: TreeChange) {
        for p in pages.values { p.apply(change) }
    }

    func applyBulk(_ changes: [TreeChange]) {
        for page in pages.values { page.applyBulk(changes) }
    }
}

/// The strip holding the pages. Flipped, layer-backed.
@MainActor
final class PagerStrip: NSView {
    weak var inputPage: NSView?

    // The layers move independently of native page origins. Route input to the
    // model's focused page, including while a reversed slide is still visible.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, let inputPage, !inputPage.isHidden, inputPage.layer?.isHidden != true else { return nil }
        return inputPage.hitTest(convert(point, from: superview))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// Scroll view for a page's tab list that hands horizontal swipes to the pager.
@MainActor
final class PageScrollView: NSScrollView {
    weak var pager: SpacePagerView?
    private var routing = false

    override func scrollWheel(with event: NSEvent) {
        (documentView as? SidebarOutlineView)?.page?.context.existingHoverPreviews?.dismiss()
        if event.phase == .began { routing = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
        if routing, let pager, pager.handleScroll(event) {
            if event.phase == .ended || event.phase == .cancelled { routing = false }
            return
        }
        if event.momentumPhase != [], routing { return }
        super.scrollWheel(with: event)
    }
}
