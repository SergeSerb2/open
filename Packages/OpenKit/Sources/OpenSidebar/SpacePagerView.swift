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
    /// The New Space form's slot in the strip. It stays in the window for the pager's lifetime,
    /// and only this host moves by layer translation. A form inserted and translated in the same
    /// turn lost its translation and sat a whole strip to the left, off the window (UX round 1 C1).
    private let creationHost = PagerCreationHost()
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
        creationHost.isHidden = true
        strip.addSubview(creationHost)
        loop = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.context.window?.focusedSpaceID
            _ = self.context.model.spaces.map(\.id)
        }) { [weak self] in self?.showFocused(animated: true) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        loop?.cancel()
        for placement in placements.values { placement.watch.invalidate() }
    }
    override var isFlipped: Bool { true }

    private var spaces: [Space] { context.model.spaces }
    private var focusedIndex: Int { context.focusedSpace.flatMap { s in spaces.firstIndex { $0 === s } } ?? 0 }

    var isShowingCreation: Bool { creationPage != nil }

    func page(for space: Space) -> SpacePageView {
        if let p = pages[space.id] { return p }
        let p = SpacePageView(context: context, space: space, menus: menus)
        p.scroll.pager = self
        pages[space.id] = p
        strip.addSubview(p)
        if strip.inputPage == nil, creationPage == nil, context.focusedSpace?.id == space.id {
            strip.inputPage = p
        }
        p.setAcceptsDrops(strip.inputPage === p)
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

    /// Each page's strip position, and the strip's offset, live in view layers' x translations. When
    /// AppKit rebuilds the layer tree (`-[NSView _updateLayerGeometryFromView]` inside
    /// `-[NSWindow displayIfNeeded]`), it sets a view layer's transform from the view's own geometry,
    /// which is identity. A page built for a Space switch then sat at x 0, off screen, and the new
    /// Space showed a blank list (UX round 1, B7); an offscreen render resets the strip as well. The
    /// pager keeps the translation it wants per layer (pages and strip) and puts it back in the same
    /// pass, before the frame renders.
    private struct Placement {
        var wanted: CGFloat
        let layer: ObjectIdentifier
        let watch: NSKeyValueObservation
    }
    /// Keyed by the view, so a replaced backing layer is noticed and observed afresh.
    private var placements: [ObjectIdentifier: Placement] = [:]
    /// True while the pager writes a transform itself: its own KVO echo is ignored.
    private var placingTransform = false
    #if DEBUG || OPEN_AUTOMATION
    private(set) var translationRestores = 0
    #endif

    private func setTranslation(_ x: CGFloat, of view: NSView) {
        guard x.isFinite, let layer = view.layer else { return }
        let viewKey = ObjectIdentifier(view), layerKey = ObjectIdentifier(layer)
        if placements[viewKey]?.layer == layerKey {
            placements[viewKey]?.wanted = x
        } else {
            placements.removeValue(forKey: viewKey)?.watch.invalidate()
            let watch = layer.observe(\.transform, options: [.new]) { [weak self] layer, change in
                // AppKit sets view layer transforms on the main thread (the display pass).
                guard Thread.isMainThread, let now = change.newValue?.m41 else { return }
                nonisolated(unsafe) let layer = layer
                MainActor.assumeIsolated {
                    guard let self, !self.placingTransform, let placement = self.placements[viewKey],
                          placement.layer == ObjectIdentifier(layer), now != placement.wanted else { return }
                    #if DEBUG || OPEN_AUTOMATION
                    self.translationRestores += 1
                    #endif
                    self.apply(placement.wanted, to: layer)
                }
            }
            placements[viewKey] = Placement(wanted: x, layer: layerKey, watch: watch)
        }
        if !CATransform3DEqualToTransform(layer.transform, CATransform3DMakeTranslation(x, 0, 0)) { apply(x, to: layer) }
    }

    private func apply(_ x: CGFloat, to layer: CALayer) {
        placingTransform = true
        defer { placingTransform = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }

    private func forgetTranslation(of view: NSView) {
        placements.removeValue(forKey: ObjectIdentifier(view))?.watch.invalidate()
    }

    /// A page's viewport frame and strip position. Hidden pages are not moved on every layout (a
    /// live resize would touch every built page each frame); a page is placed when it is shown.
    private func place(_ page: NSView, at index: Int) {
        let frame = CGRect(origin: .zero, size: bounds.size)
        if page.frame != frame { page.frame = frame }
        setTranslation(CGFloat(index) * bounds.width, of: page)
    }

    private func layoutPages() {
        let frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Native pages share the viewport. AppKit can paint every participating
        // page; their backing layers form the horizontal strip. Native origins
        // outside the viewport would cull incoming rows until the slide ended.
        if let creationPage {
            if creationHost.frame != frame { creationHost.frame = frame }
            if creationPage.frame != creationHost.bounds { creationPage.frame = creationHost.bounds }
            // The host is placed like a page: its translation survives AppKit's layer resets (B7).
            setTranslation(CGFloat(spaces.count) * bounds.width, of: creationHost)
        }
        let live = Set(spaces.map(\.id))
        for (id, page) in pages where !live.contains(id) { forgetTranslation(of: page); page.removeFromSuperview(); pages[id] = nil }
        for (index, space) in spaces.enumerated() {
            guard let page = pages[space.id], page.layer?.isHidden != true else { continue }
            place(page, at: index)
        }
        syncInputAndDropTargets()
        CATransaction.commit()
    }

    private func syncInputAndDropTargets() {
        strip.inputPage = creationPage == nil ? context.focusedSpace.flatMap { pages[$0.id] } : creationHost
        for page in pages.values { page.setAcceptsDrops(strip.inputPage === page) }
    }

    private func placeStrip() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if strip.frame != bounds { strip.frame = bounds }
        setTranslation(-offset, of: strip)
        CATransaction.commit()
    }

    /// Starts the slide in the caller's turn when focus moved. The observation
    /// loop otherwise reaches the pager one turn later, after the window's
    /// synchronous content swap, so the slide began 20-40 ms after the input.
    func showFocusedIfChanged() {
        guard creationPage == nil, swipe == nil, window != nil,
              let focused = context.focusedSpace, focused.id != shownSpaceID else { return }
        showFocused(animated: true)
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
        if let previous {
            context.selection.clear(); context.existingHoverPreviews?.dismiss()
            // A drag can stay over the sidebar through ⌃N: the outgoing page keeps no drop line or folder fill.
            pages[previous]?.clearDropIndicator()
        }
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

    #if DEBUG || OPEN_AUTOMATION
    /// Pager internals for layout checks: each built page's layer state and the strip offsets.
    var diagnostics: [String: Any] {
        // JSON has no NaN: a missing layer or presentation reads as null.
        func tx(_ l: CALayer?) -> Any { (l?.value(forKeyPath: "transform.translation.x") as? CGFloat).map { Double($0) } ?? NSNull() }
        func ptx(_ l: CALayer?) -> Any { (l?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat).map { Double($0) } ?? NSNull() }
        let order = spaces.map(\.id)
        let built: [[String: Any]] = pages.map { id, p in
            ["space": id.description, "index": order.firstIndex(of: id) ?? -1, "layerHidden": p.layer?.isHidden ?? true,
             "viewHidden": p.isHidden, "inStrip": p.superview === strip, "translation": tx(p.layer),
             "presentationTranslation": ptx(p.layer), "frame": [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height].map(Double.init),
             "alpha": Double(p.alphaValue), "layerOpacity": Double(p.layer?.opacity ?? 0), "hasLayer": p.layer != nil,
             "sublayers": p.layer?.sublayers?.count ?? 0, "subviews": p.subviews.count,
             "layerID": p.layer.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? ""]
        }
        return ["offset": Double(offset), "stripTranslation": tx(strip.layer), "stripPresentation": ptx(strip.layer),
                "shownSpace": shownSpaceID?.description ?? "", "focusedIndex": focusedIndex, "animating": animating,
                "creation": creationPage != nil, "creationHostTranslation": tx(creationHost.layer),
                "creationHostHidden": creationHost.isHidden, "width": Double(bounds.width), "pages": built,
                "stripHidden": strip.layer?.isHidden ?? true, "stripAnimations": strip.layer?.animationKeys() ?? [],
                "translationRestores": translationRestores]
    }
    #endif

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
        syncInputAndDropTargets()
    }

    private func setPage(_ page: SpacePageView, visible: Bool) {
        // The native pages overlap in the viewport. Hiding an outgoing NSView
        // invalidates its still-visible sibling at the spring endpoint. Keep
        // visibility in the layer tree so the resting page needs no repaint.
        // Accessibility follows the same visibility, and PagerStrip owns input.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if visible, page.layer?.isHidden == true, let index = spaces.firstIndex(where: { $0.id == page.space.id }) {
            place(page, at: index)  // hidden pages skip layout; place it before it shows
        }
        page.layer?.isHidden = !visible
        page.setAccessibilityHidden(!visible)
        CATransaction.commit()
    }

    func beginCreation(page: NSView) {
        guard creationPage == nil else { return }
        swipe = nil; creationPage = page
        creationHost.isHidden = false; creationHost.addSubview(page)
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
        creationPage?.removeFromSuperview(); creationPage = nil; creationHost.isHidden = true
        strip.layer?.removeAnimation(forKey: "slide"); animating = false
        shownSpaceID = nil
        showFocused(animated: false)
        syncInputAndDropTargets()
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
            let animate = animatesSidebarChanges && !Motion.reducesMotion
            var snapping = false
            if animate, target != s.baseIndex {
                // Commit the snap before the synchronous Space switch swaps the
                // web content; that work otherwise held the last drag frame.
                let from = -offset
                shownSpaceID = spaces[target].id
                offset = CGFloat(target) * w
                placeStrip(); slide(from: from, spring: Motion.spaceSwipeSnap)
                CATransaction.flush()
                snapping = true
            }
            // The delegate changes focus synchronously; snap to whatever is focused now.
            if target != s.baseIndex { context.send(.switchSpace(spaces[target].id)) }
            let landed = focusedIndex
            themeBackground?.endTransition(commit: landed != s.baseIndex && landed == s.neighbor, duration: Motion.reducesMotion ? 0 : Motion.themeCrossfade)
            if landed != s.baseIndex && landed != s.neighbor, let f = context.focusedSpace {
                themeBackground?.crossfade(to: context.style(for: f), animated: true)
            }
            shownSpaceID = context.focusedSpace?.id
            syncInputAndDropTargets()
            if snapping, landed == target { return true }
            let from = snapping ? presentationOffset : -offset
            offset = CGFloat(landed) * w
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

/// Empty, flipped slot that carries the New Space form at the strip's end.
@MainActor
final class PagerCreationHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
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
    /// In a Space Manager column: where this column's trackpad gesture goes, decided by its first event
    /// that moves (`mayBegin` and often `began` carry none). Once it goes to the strip, the strip owns
    /// the gesture and its momentum (`SpaceManagerScrollView.ownsGesture`), wherever they land.
    private enum Route { case undecided, strip, column }
    private var route = Route.undecided
    /// This column's gesture events before the deciding one; replayed to the chosen view, so that view
    /// sees the whole gesture from its start (dropped when the gesture ends without moving).
    private var held: [NSEvent] = []
    private var managerStrip: SpaceManagerScrollView? {
        var view = superview
        while let candidate = view { if let strip = candidate as? SpaceManagerScrollView { return strip }; view = candidate.superview }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        (documentView as? SidebarOutlineView)?.page?.context.existingHoverPreviews?.dismiss()
        // A Space Manager column (no pager) scrolls only vertically: sideways input belongs to the
        // manager's sideways strip.
        if pager == nil, let strip = managerStrip { routeInManager(event, strip: strip); return }
        if event.phase == .began { routing = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
        if routing, let pager, pager.handleScroll(event) {
            if event.phase == .ended || event.phase == .cancelled { routing = false }
            return
        }
        if event.momentumPhase != [], routing { return }
        super.scrollWheel(with: event)
    }

    private func routeInManager(_ event: NSEvent, strip: SpaceManagerScrollView) {
        let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
        if event.phase == [] {
            if event.momentumPhase == [] {
                // A notched wheel turn: sideways when it turns sideways, or a vertical turn with Shift.
                if dx > dy || (!event.hasPreciseScrollingDeltas && event.modifierFlags.contains(.shift)) {
                    strip.scrollSideways(with: event)
                } else { strip.releaseGesture(); super.scrollWheel(with: event) }
            } else if strip.ownsMomentum {
                strip.scrollSideways(with: event)  // including a zero-delta momentum end
            } else { super.scrollWheel(with: event) }
            return
        }
        let ends = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            // A new gesture starts here: nothing earlier is still owned by the strip or this column.
            if event.phase.contains(.mayBegin) { held = [] } else { held.removeAll { !$0.phase.contains(.mayBegin) } }
            route = .undecided; strip.releaseGesture()
        }
        if strip.ownsGesture {
            // The strip's gesture, begun over another column (or this one): it keeps all of it.
            strip.scrollSideways(with: event)
            if ends { route = .undecided }
            return
        }
        if route == .undecided {
            guard dx + dy > 0 else {
                if ends { held = [] } else { held.append(event) }
                return
            }
            route = dx > dy ? .strip : .column
            let pending = held; held = []
            for early in pending { deliver(early, to: strip) }
        }
        deliver(event, to: strip)
        if ends { route = .undecided }
    }

    private func deliver(_ event: NSEvent, to strip: SpaceManagerScrollView) {
        if route == .strip { strip.scrollSideways(with: event) } else { super.scrollWheel(with: event) }
    }
}
