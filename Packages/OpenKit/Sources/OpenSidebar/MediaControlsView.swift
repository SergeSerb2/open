import AppKit
import OpenDesign
import OpenMedia
import OpenModel

/// One window's stack (PP-14/18/20). Only hover-off schedules work; paused cards do not tick.
@MainActor public final class MediaControlsView: NSView {
    enum HeightTransition { case structure, drawer, stack }
    private let context: SidebarContext
    private var observation: ObservationLoop?
    private var tracking: NSTrackingArea?
    private var collapseWork: DispatchWorkItem?
    private var collapseDelay: TimeInterval?
    private var windowCloseObservation: NSObjectProtocol?
    private var byID: [ItemID: MiniPlayerCardView] = [:]
    private var retiring: [ObjectIdentifier: MiniPlayerCardView] = [:]
    private var ordered: [ItemID] = []
    private var holdingLastHeight: CGFloat = 0
    private var pendingTransition = false
    private var reducedCrossFadeAdded = false
    private var lastLayoutWidth: CGFloat = 0
    var hasPendingTransition: Bool { pendingTransition }
    private(set) var heightTransition = HeightTransition.structure
    public private(set) var isExpanded = false
    public private(set) var stackHeight: CGFloat = 0
    public var onUpdateHeight: (() -> Void)?
    /// Automation receipt at the actual insertion; nil outside automated App runs.
    public var onCardInserted: ((ItemID) -> Void)?
    public var requiredHeight: CGFloat { stackHeight == 0 ? 0 : MiniPlayerMetrics.gapAbove + stackHeight }
    public var cards: [MiniPlayerCardView] { ordered.compactMap { byID[$0] } }
    public var pendingCollapseCount: Int { collapseWork == nil ? 0 : 1 }
    /// Delay the pending collapse was scheduled with, nil when none is pending.
    public var pendingCollapseDelay: TimeInterval? { collapseWork == nil ? nil : collapseDelay }

    public init(context: SidebarContext) {
        self.context = context
        super.init(frame: .zero); wantsLayer = true
        observation = ObservationLoop(read: { [weak self] in
            guard let self else { return }
            // The stable per-window publication contains no position, volume or video-area reads.
            _ = self.context.media?.visibleSources(windowID: self.context.windowID, displayed: self.context.displayedTabIDs)
            _ = self.context.forcedMediaHover
        }) { [weak self] in self?.sync() }
        sync()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observation?.cancel(); collapseWork?.cancel(); if let windowCloseObservation { NotificationCenter.default.removeObserver(windowCloseObservation) } }
    public override var isFlipped: Bool { true }

    private func sync() {
        let sources = context.media?.visibleSources(windowID: context.windowID, displayed: context.displayedTabIDs) ?? []
        let ids = sources.compactMap(\.tabID), wasEmpty = ordered.isEmpty
        context.mediaDrawers.formIntersection(ids)
        let changed = ids != ordered || sources.contains { s in s.tabID.map { byID[$0]?.source !== s } ?? false }
        if changed {
            pendingTransition = true
            let previous = byID
            if !ids.isEmpty { holdingLastHeight = 0 }
            if ids.isEmpty && !ordered.isEmpty && animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion { holdingLastHeight = stackHeight }
            for (id, card) in previous where !sources.contains(where: { $0.tabID == id && $0 === card.source }) {
                context.mediaDrawers.remove(id)
                byID.removeValue(forKey: id); retire(card)
            }
            for source in sources {
                guard let id = source.tabID, byID[id] == nil else { continue }
                let card = MiniPlayerCardView(source: source, context: context)
                card.onHeightChange = { [weak self] in self?.measure(.drawer) }
                byID[id] = card; addSubview(card)
                onCardInserted?(id)
                if animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion {
                    let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0; a.toValue = 1
                    a.duration = Motion.miniPlayerReveal
                    a.beginTime = CACurrentMediaTime() + (wasEmpty ? Motion.miniPlayerAppearDelay : 0); a.fillMode = .backwards
                    card.layer?.add(a, forKey: "media.appear")
                }
            }
            ordered = ids
            for id in ids.reversed() { if let card = byID[id] { addSubview(card, positioned: .above, relativeTo: nil) } }
        }
        if context.forcedMediaHover != nil { cancelCollapse(); isExpanded = !ids.isEmpty }
        else if ids.isEmpty { isExpanded = false; cancelCollapse() }
        measure(changed && (wasEmpty || ids.isEmpty) ? .structure : .stack)
    }
    private func retire(_ card: MiniPlayerCardView) {
        card.isRetiring = true
        let identity = ObjectIdentifier(card)
        guard animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion else { card.removeFromSuperview(); return }
        retiring[identity] = card
        let start = MediaAnimationStart(layer: card.layer, frame: card.frame)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak card] in
            Task { @MainActor in
                card?.removeFromSuperview()
                guard let self else { return }
                self.retiring.removeValue(forKey: identity)
                if self.ordered.isEmpty && self.retiring.isEmpty { self.holdingLastHeight = 0; self.measure(.structure) }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = start.opacity; fade.toValue = 0
        fade.duration = Motion.miniPlayerDisappear
        card.layer?.opacity = 0; card.layer?.add(fade, forKey: "media.disappear")
        CATransaction.commit()
    }
    private func measure(_ transition: HeightTransition) {
        let current = cards
        for (i, card) in current.enumerated() {
            if card.configure(expanded: isExpanded, level: i) { pendingTransition = true }
        }
        let height: CGFloat
        if current.isEmpty { height = holdingLastHeight }
        else if isExpanded { height = current.reduce(0) { $0 + $1.cardHeight } + CGFloat(current.count - 1) * MiniPlayerMetrics.expandedGap }
        else { height = (current.first?.cardHeight ?? 0) + CGFloat(current.count - 1) * MiniPlayerMetrics.stackOffset }
        if height != stackHeight { pendingTransition = true; heightTransition = transition; stackHeight = height; onUpdateHeight?() }
        needsLayout = true
    }
    /// One cross-fade owns the whole subtree, including source changes at the same height.
    func crossFadeReducedTransition() {
        guard pendingTransition, !reducedCrossFadeAdded else { return }
        let fade = CATransition(); fade.type = .fade; fade.duration = Motion.reducedMedia
        layer?.add(fade, forKey: "media.reducedHeight")
        reducedCrossFadeAdded = true
    }
    public override func layout() {
        super.layout()
        let widthChanged = lastLayoutWidth > 0 && lastLayoutWidth != bounds.width
        lastLayoutWidth = bounds.width
        if widthChanged { removeMediaAnimations(layer) }
        let animate = pendingTransition && animatesMediaChanges && !widthChanged
        if animate && SidebarDiagnostics.mediaReducesMotion { crossFadeReducedTransition() }
        pendingTransition = false; reducedCrossFadeAdded = false
        let current = cards, m = MiniPlayerMetrics.self
        var accumulated: CGFloat = 0
        for (i, card) in current.enumerated() {
            accumulated += card.cardHeight
            let inset = m.inset + (isExpanded ? 0 : CGFloat(i) * m.stackInset)
            let y = isExpanded ? requiredHeight - accumulated - CGFloat(i) * m.expandedGap
                               : requiredHeight - m.rowHeight - CGFloat(i) * m.stackOffset
            let target = CGRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: card.cardHeight)
            let previous = card.frame, oldOpacity = card.alphaValue
            let start = MediaAnimationStart(layer: card.layer, frame: previous)
            let opacity = isExpanded ? CGFloat(1) : 1 - CGFloat(i) * m.stackOpacityStep
            card.animatesNextLayout = animate
            CATransaction.begin(); CATransaction.setDisableActions(true)
            card.frame = target; card.alphaValue = opacity
            CATransaction.commit()
            if previous != .zero && previous != target {
                animateMediaFrame(card.layer, from: start, to: target, enabled: animate, drawer: heightTransition == .drawer)
            }
            if oldOpacity != opacity && animate && !SidebarDiagnostics.mediaReducesMotion {
                let fade = Motion.miniPlayerStack.animation(keyPath: "opacity")
                fade.fromValue = start.opacity; fade.toValue = opacity
                card.layer?.add(fade, forKey: "media.stackOpacity")
            }
        }
        updateTrackingAreas()
    }
    public var hoverRect: CGRect {
        CGRect(x: MiniPlayerMetrics.inset, y: MiniPlayerMetrics.gapAbove,
               width: max(0, bounds.width - 2 * MiniPlayerMetrics.inset), height: stackHeight)
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func cancelCollapse() { collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil }
    public override func mouseEntered(with event: NSEvent) {
        cancelCollapse()
        if !ordered.isEmpty { isExpanded = true; measure(.stack) }
    }
    public override func mouseExited(with event: NSEvent) {
        cancelCollapse()
        guard isExpanded, context.forcedMediaHover == nil else { return }
        let delay = MiniPlayerMetrics.collapseDelay
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            self?.collapseWork = nil; self?.collapseDelay = nil; self?.isExpanded = false; self?.measure(.stack)
        } }
        collapseWork = work; collapseDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    public override func viewDidHide() {
        super.viewDidHide(); cancelCollapse()
        if isExpanded && context.forcedMediaHover == nil { isExpanded = false; measure(.stack) }
        pendingTransition = false; reducedCrossFadeAdded = false
        for card in cards { card.animatesNextLayout = false }
        removeMediaAnimations(layer)
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let windowCloseObservation { NotificationCenter.default.removeObserver(windowCloseObservation); self.windowCloseObservation = nil }
        if newWindow == nil { cancelCollapse() }
        else { windowCloseObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelCollapse() }
        } }
        super.viewWillMove(toWindow: newWindow)
    }

}

extension NSView {
    var animatesMediaChanges: Bool { animatesSidebarChanges && window?.isMiniaturized != true && !isHiddenOrHasHiddenAncestor }
}
