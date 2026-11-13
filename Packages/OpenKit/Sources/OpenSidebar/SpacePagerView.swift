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
    private var slideGeneration = 0
    private var movingStrip: CALayer?
    private var movingPageIDs: Set<SpaceID> = []
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
        placeStrip(commitOffset: swipe == nil && !animating)
    }

    private func layoutPages() {
        let w = bounds.width, h = bounds.height
        let creationFrame = CGRect(x: CGFloat(spaces.count) * w, y: 0, width: w, height: h)
        if creationPage?.frame != creationFrame { creationPage?.frame = creationFrame }
        // Drop pages of deleted Spaces.
        let live = Set(spaces.map(\.id))
        for (id, p) in pages where !live.contains(id) { p.removeFromSuperview(); pages[id] = nil }
        for (i, s) in spaces.enumerated() {
            let frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
            if pages[s.id]?.frame != frame { pages[s.id]?.frame = frame }
        }
    }

    private func placeStrip(commitOffset: Bool = true) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Commit the native origin once at rest, so AppKit hit testing follows
        // the focused page. Interactive events and springs move only the layer.
        let frame = CGRect(x: commitOffset ? -offset : strip.frame.minX, y: 0, width: max(CGFloat(spaces.count + (creationPage == nil ? 0 : 1)), 1) * bounds.width, height: bounds.height)
        if strip.frame != frame { strip.frame = frame }
        strip.layer?.setValue(-offset - frame.minX, forKeyPath: "transform.translation.x")
        movingStrip?.setValue(-offset, forKeyPath: "transform.translation.x")
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
            movingStrip?.removeAnimation(forKey: "slide")
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
        let presentationX = presentationOffset
        offset = CGFloat(target) * w
        var animate = animated && context.animatesChanges && previous != nil
            && animatesSidebarChanges && !Motion.reducesMotion
        if animate { animate = prepareMovingStrip(indices: min(from, target)...max(from, target)) }
        placeStrip(commitOffset: !animate)
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

    /// AppKit culls pages outside the native viewport. Prepare their pixels once,
    /// so translating a layer never reveals an unpainted native page mid-slide.
    @discardableResult
    private func prepareMovingStrip(indices: ClosedRange<Int>) -> Bool {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return false }
        let scale = min(window?.backingScaleFactor ?? 2, 2)
        // Bound all temporary pixels to 64 MiB, with no single image above it.
        // Large ranges switch immediately rather than allocating more or sliding blanks.
        let pixels = ceil(bounds.width * scale) * ceil(bounds.height * scale)
        let missing = indices.filter { !movingPageIDs.contains(spaces[$0].id) }
        let count = movingPageIDs.count + missing.count
        guard count > 0, pixels.isFinite, pixels > 0, pixels <= 16_777_216 / CGFloat(count) else { return false }
        let images = movingStrip ?? CALayer()
        images.anchorPoint = .zero
        images.frame = CGRect(origin: .zero, size: strip.frame.size)
        images.isGeometryFlipped = layer.isGeometryFlipped
        var prepared: [(SpaceID, CALayer)] = []
        for index in missing {
            let view = page(for: spaces[index])
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { return false }
            let tile = CALayer()
            tile.frame = view.frame
            tile.contents = image
            tile.contentsScale = scale
            prepared.append((spaces[index].id, tile))
        }
        for (id, tile) in prepared {
            images.addSublayer(tile)
            movingPageIDs.insert(id)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        images.setValue(-offset, forKeyPath: "transform.translation.x")
        if movingStrip == nil { layer.addSublayer(images) }
        movingStrip = images
        strip.layer?.opacity = 0
        CATransaction.commit()
        return true
    }

    private func removeMovingStrip() {
        guard let movingStrip else { movingPageIDs.removeAll(keepingCapacity: true); return }
        // Make the live target paint before removing the prepared strip.
        strip.layoutSubtreeIfNeeded()
        strip.displayIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.layer?.opacity = 1
        movingStrip.removeFromSuperlayer()
        self.movingStrip = nil
        movingPageIDs.removeAll(keepingCapacity: true)
        CATransaction.commit()
    }

    private var presentationOffset: CGFloat {
        if let movingStrip {
            return movingStrip.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
                ?? movingStrip.value(forKeyPath: "transform.translation.x") as? CGFloat ?? -offset
        }
        return strip.frame.minX + (strip.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
            ?? strip.layer?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
    }

    private func slide(from x: CGFloat, spring token: SpringToken, requestedAt: CFTimeInterval? = nil) {
        animating = true
        slideGeneration += 1
        let generation = slideGeneration
        let motionLayer = movingStrip ?? strip.layer
        let origin = movingStrip == nil ? strip.frame.minX : 0
        let spring = token.animation(keyPath: "transform.translation.x")
        spring.fromValue = x - origin
        spring.toValue = -offset - origin
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
        removeMovingStrip()
        let focused = context.focusedSpace?.id
        for (id, p) in pages { p.isHidden = creationPage != nil || id != focused }
    }

    func beginCreation(page: NSView) {
        guard creationPage == nil else { return }
        removeMovingStrip()
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
            movingStrip?.removeAnimation(forKey: "slide")
            slideGeneration += 1
            strip.layer?.removeAnimation(forKey: "slide")
            animating = false
            let base = focusedIndex
            swipe = SwipeState(baseIndex: base, startOffset: start)
            offset = swipe!.startOffset
            for p in pages.values { p.isHidden = false }
            for i in max(0, base - 1)...min(spaces.count - 1, base + 1) { _ = page(for: spaces[i]) }
            layoutPages()
            if !Motion.reducesMotion { prepareMovingStrip(indices: max(0, base - 1)...min(spaces.count - 1, base + 1)) }
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
            if !Motion.reducesMotion, movingStrip != nil { placeStrip(commitOffset: false) }
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
            let animate = animatesSidebarChanges && !Motion.reducesMotion && movingStrip != nil
            placeStrip(commitOffset: !animate)
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
