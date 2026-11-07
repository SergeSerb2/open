import AppKit
import OpenDesign
import OpenModel

/// Horizontal pager of Space pages. Pages sit side by side at `index × width`
/// in a strip; a Space switch slides the strip with a spring while the window
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
        if !animating && swipe == nil { offset = CGFloat(creationPage == nil ? focusedIndex : spaces.count) * bounds.width }
        placeStrip()
    }

    private func layoutPages() {
        let w = bounds.width, h = bounds.height
        creationPage?.frame = CGRect(x: CGFloat(spaces.count) * w, y: 0, width: w, height: h)
        // Drop pages of deleted Spaces.
        let live = Set(spaces.map(\.id))
        for (id, p) in pages where !live.contains(id) { p.removeFromSuperview(); pages[id] = nil }
        for (i, s) in spaces.enumerated() { pages[s.id]?.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h) }
    }

    private func placeStrip() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: -offset, y: 0, width: max(CGFloat(spaces.count + (creationPage == nil ? 0 : 1)), 1) * bounds.width, height: bounds.height)
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
        for i in min(from, target)...max(from, target) { page(for: spaces[i]).isHidden = false }
        layoutPages()
        shownSpaceID = focused.id
        let presentationX = strip.layer?.presentation()?.position.x ?? strip.frame.minX
        offset = CGFloat(target) * w
        placeStrip()
        let style = context.style(for: focused)
        guard animated, previous != nil, animatesSidebarChanges, !Motion.reducesMotion else {
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

    private func slide(from x: CGFloat, spring token: SpringToken, requestedAt: CFTimeInterval? = nil) {
        animating = true
        let spring = token.animation(keyPath: "position.x")
        spring.fromValue = x
        spring.toValue = -offset
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.animating = false; self?.finishSlide() } }
        let request = requestedAt ?? CACurrentMediaTime()
        spring.beginTime = strip.layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        spring.setValue(strip.layer?.convertTime(request, from: nil) ?? request, forKey: "openRequestedAt")
        strip.layer?.add(spring, forKey: "slide")
        lastSlideAnimation = strip.layer?.animation(forKey: "slide")
        CATransaction.commit()
    }

    private func finishSlide() {
        guard !animating, swipe == nil else { return }
        let focused = context.focusedSpace?.id
        for (id, p) in pages { p.isHidden = creationPage != nil || id != focused }
    }

    func beginCreation(page: NSView) {
        guard creationPage == nil else { return }
        swipe = nil; creationPage = page; strip.addSubview(page)
        let from = strip.layer?.presentation()?.position.x ?? strip.frame.minX
        layoutPages(); offset = CGFloat(spaces.count) * bounds.width; placeStrip()
        if animatesSidebarChanges && !Motion.reducesMotion { slide(from: from, spring: Motion.spaceSwitch) }
        else { animating = false; finishSlide() }
    }

    func endCreation() {
        let from = strip.layer?.presentation()?.position.x ?? strip.frame.minX
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
            strip.layer?.removeAnimation(forKey: "slide")
            animating = false
            let base = focusedIndex
            swipe = SwipeState(baseIndex: base, startOffset: -(strip.layer?.presentation()?.position.x ?? -offset))
            offset = swipe!.startOffset
            for p in pages.values { p.isHidden = false }
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
            placeStrip()
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
            themeBackground?.endTransition(commit: landed != s.baseIndex && landed == s.neighbor)
            if landed != s.baseIndex && landed != s.neighbor, let f = context.focusedSpace {
                themeBackground?.crossfade(to: context.style(for: f), animated: true)
            }
            shownSpaceID = context.focusedSpace?.id
            let from = -offset
            offset = CGFloat(landed) * w
            placeStrip()
            slide(from: from, spring: Motion.spaceSwipeSnap)
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
