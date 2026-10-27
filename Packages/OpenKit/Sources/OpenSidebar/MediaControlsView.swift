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
    private var byID: [ItemID: MiniPlayerCardView] = [:]
    private var retiring: [ObjectIdentifier: MiniPlayerCardView] = [:]
    private var ordered: [ItemID] = []
    private var holdingLastHeight: CGFloat = 0
    private(set) var heightTransition = HeightTransition.structure
    public private(set) var isExpanded = false
    public private(set) var stackHeight: CGFloat = 0
    public var onUpdateHeight: (() -> Void)?
    public var requiredHeight: CGFloat { stackHeight == 0 ? 0 : 2 * MiniPlayerMetrics.verticalInset + stackHeight }
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
    isolated deinit { observation?.cancel(); collapseWork?.cancel() }
    public override var isFlipped: Bool { true }

    private func sync() {
        let sources = context.media?.visibleSources(windowID: context.windowID, displayed: context.displayedTabIDs) ?? []
        let ids = sources.compactMap(\.tabID), wasEmpty = ordered.isEmpty
        context.mediaDrawers.formIntersection(ids)
        let changed = ids != ordered || sources.contains { s in s.tabID.map { byID[$0]?.source !== s } ?? false }
        if changed {
            let previous = byID
            if !ids.isEmpty { holdingLastHeight = 0 }
            if ids.isEmpty && !ordered.isEmpty && animatesMediaChanges { holdingLastHeight = stackHeight }
            for (id, card) in previous where !sources.contains(where: { $0.tabID == id && $0 === card.source }) {
                context.mediaDrawers.remove(id)
                byID.removeValue(forKey: id); retire(card)
            }
            for source in sources {
                guard let id = source.tabID, byID[id] == nil else { continue }
                let card = MiniPlayerCardView(source: source, context: context)
                card.onHeightChange = { [weak self] in self?.measure(.drawer) }
                byID[id] = card; addSubview(card)
                if animatesMediaChanges {
                    let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0; a.toValue = 1
                    a.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : Motion.miniPlayerReveal
                    a.beginTime = CACurrentMediaTime() + (wasEmpty ? Motion.miniPlayerAppearDelay : 0); a.fillMode = .backwards
                    card.layer?.add(a, forKey: "media.appear")
                }
            }
            ordered = ids
            for id in ids.reversed() { if let card = byID[id] { addSubview(card, positioned: .above, relativeTo: nil) } }
        }
        if context.forcedMediaHover != nil { collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil; isExpanded = ids.count > 1 }
        else if ids.count < 2 { isExpanded = false; collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil }
        measure(changed && (wasEmpty || ids.isEmpty) ? .structure : .stack)
    }
    private func retire(_ card: MiniPlayerCardView) {
        card.isRetiring = true
        let identity = ObjectIdentifier(card)
        guard animatesMediaChanges else { card.removeFromSuperview(); return }
        retiring[identity] = card
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak card] in
            Task { @MainActor in
                card?.removeFromSuperview()
                guard let self else { return }
                self.retiring.removeValue(forKey: identity)
                if self.ordered.isEmpty && self.retiring.isEmpty { self.holdingLastHeight = 0; self.measure(.structure) }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = card.layer?.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = SidebarDiagnostics.mediaReducesMotion ? Motion.reducedMedia : Motion.miniPlayerDisappear
        card.layer?.opacity = 0; card.layer?.add(fade, forKey: "media.disappear")
        CATransaction.commit()
    }
    private func measure(_ transition: HeightTransition) {
        let current = cards
        let height: CGFloat
        if current.isEmpty { height = holdingLastHeight }
        else if isExpanded { height = current.reduce(0) { $0 + $1.cardHeight } + CGFloat(current.count - 1) * MiniPlayerMetrics.expandedGap }
        else { height = (current.first?.cardHeight ?? 0) + CGFloat(current.count - 1) * MiniPlayerMetrics.stackOffset }
        if height != stackHeight { heightTransition = transition; stackHeight = height; onUpdateHeight?() }
        needsLayout = true
    }
    public override func layout() {
        super.layout()
        let current = cards, m = MiniPlayerMetrics.self
        var expandedY = m.verticalInset
        for (i, card) in current.enumerated().reversed() {
            let inset = m.inset + (isExpanded ? 0 : CGFloat(i) * m.stackWidthOffset)
            let y = isExpanded ? expandedY : m.verticalInset + CGFloat(current.count - 1 - i) * m.stackOffset
            let target = CGRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: card.cardHeight)
            let previous = card.frame, opacity = isExpanded ? Float(1) : 1 - Float(i) * m.stackOpacity
            CATransaction.begin(); CATransaction.setDisableActions(true)
            card.frame = target; card.alphaValue = CGFloat(opacity)
            if !isExpanded && i > 0 {
                let mask = card.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
                mask.frame = card.bounds
                mask.path = CGPath(rect: CGRect(x: 0, y: 0, width: target.width, height: m.stackOffset), transform: nil)
                card.layer?.mask = mask
            } else { card.layer?.mask = nil }
            card.showsStackEdge = !isExpanded && i > 0
            card.marquee.isExposed = isExpanded || i == 0
            CATransaction.commit()
            if previous != .zero && previous != target && animatesMediaChanges && !SidebarDiagnostics.mediaReducesMotion {
                let position = Motion.miniPlayerStack.animation(keyPath: "position")
                position.fromValue = CGPoint(x: previous.midX, y: previous.midY); position.toValue = CGPoint(x: target.midX, y: target.midY)
                let size = Motion.miniPlayerStack.animation(keyPath: "bounds.size")
                size.fromValue = previous.size; size.toValue = target.size
                card.layer?.add(position, forKey: "media.stackPosition"); card.layer?.add(size, forKey: "media.stackSize")
            }
            expandedY += card.cardHeight + m.expandedGap
        }
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) {
        collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil
        if ordered.count > 1 { isExpanded = true; measure(.stack) }
    }
    public override func mouseExited(with event: NSEvent) {
        collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil
        guard isExpanded, context.forcedMediaHover == nil else { return }
        let delay = MiniPlayerMetrics.collapseDelay
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            self?.collapseWork = nil; self?.collapseDelay = nil; self?.isExpanded = false; self?.measure(.stack)
        } }
        collapseWork = work; collapseDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    public override func viewDidHide() {
        super.viewDidHide(); collapseWork?.cancel(); collapseWork = nil; collapseDelay = nil
        for card in cards { card.marquee.refreshAnimation() }
    }
    public override func viewDidUnhide() { super.viewDidUnhide(); for card in cards { card.marquee.refreshAnimation() } }
}

extension NSView {
    var animatesMediaChanges: Bool { animatesSidebarChanges && window?.isMiniaturized != true && !isHiddenOrHasHiddenAncestor }
}
