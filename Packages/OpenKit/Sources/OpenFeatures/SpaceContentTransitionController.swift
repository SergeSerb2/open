import AppKit
import OpenDesign
import OpenModel

struct SpaceContentSelection: Equatable {
    let tabs: [ItemID]
    let focused: ItemID?
    let orientation: SplitOrientation
    let fractions: [Double]
    let space: SpaceID
    let profile: ProfileID
}

/// Selection changes once, behind the incoming plate. The plate retires on the
/// engine's presented-frame receipt for every visible engine pane. It never
/// fabricates a receipt and no timer removes it: native panes are ready at
/// once, and a request the engine refuses or ends shows the live page.
@MainActor
final class SpaceContentTransitionController {
    unowned let container: WebContentContainer
    let plate = SpacePageSnapshotTransition(frame: .zero)
    private(set) var nativeSelection: SpaceContentSelection?
    private(set) var requestedSelection: SpaceContentSelection?
    private(set) var presentationUnavailable = false
    private(set) var captureCount = 0
    private var generation: UInt64 = 0
    private var frameGeneration: UInt64 = 0
    private var snapshotTask: Task<Void, Never>?
    private var requests: [UUID: any WebContentFrameRequest] = [:]
    private var waiting: Set<UUID> = []
    private var receipt: SpacePageSnapshotTransition.Receipt?
    private var nativeStyle = SpaceThemeStyle.defaultTheme(system: .dark)
    private var applying = false
    private var applyingCoveredSelection: (() -> Void)?
    private var lastViewport: WebContentFrameViewport?
    private var lastPresentationViewports: [ItemID: WebContentFrameViewport] = [:]

    var keepsEmptySourceVisible: Bool { nativeSelection?.tabs.isEmpty == true && (plate.phase != .idle || plate.isFading) }

    init(container: WebContentContainer) { self.container = container }
    isolated deinit { snapshotTask?.cancel(); for request in requests.values { request.cancel() } }

    func select(_ selection: SpaceContentSelection) {
        if requestedSelection == selection, plate.phase != .idle { return }
        if plate.isFading, requestedSelection == selection, nativeSelection == selection {
            // A routine refresh (title, favicon, loading) during the retire fade: keep the fade and
            // refresh native slots only (review r1 #2). An empty Space has nothing to refresh.
            if selection.focused != nil { container.applySpaceSelection(selection, animateSlots: true, notify: false) }
            return
        }
        let source = nativeSelection
        let needsCover = source != nil && (source?.space != selection.space || plate.phase != .idle)
        let scale = container.window?.backingScaleFactor ?? 1
        // An interrupted slide folds into one image first. When it cannot (a
        // viewport over the 16 Mpx plate limit), no new cover can replace the
        // running one, whose callbacks this switch supersedes: cut over directly.
        let canCover = needsCover && container.window?.isVisible == true
            && container.superview != nil && !container.bounds.isEmpty
        let previousCover = canCover && plate.phase != .idle
            ? plate.capturePresentation(size: container.bounds.size, scale: scale) : nil
        guard canCover, let parent = container.superview,
              plate.phase == .idle || previousCover != nil else {
            applyUncovered(selection, from: source); return
        }

        generation &+= 1; let token = generation
        cancelRequests()
        let previousRequest = requestedSelection
        requestedSelection = selection
        if source?.profile != selection.profile { plate.invalidateAll() }
        plate.frame = container.bounds
        // Share the web panel's ancestor. Sidebar/Cmd+S layer motion therefore
        // moves the cover too, without a per-frame sibling-frame update.
        container.addSubview(plate, positioned: .above, relativeTo: nil)
        // An empty Space keeps its native chrome below this transparent source
        // while the incoming plate enters. Hidden ancestors would cull it.
        container.isHidden = false
        let style = container.style
        let key = container.spaceSnapshotKey(selection)
        let visualSource = previousRequest ?? source
        let oldIndex = visualSource.flatMap { container.spaceOrder.firstIndex(of: $0.space) } ?? 0
        let newIndex = container.spaceOrder.firstIndex(of: selection.space) ?? oldIndex
        let direction: CGFloat = newIndex == oldIndex ? 0 : newIndex < oldIndex ? -1 : 1
        let themeFrame = container.convert(parent.bounds, from: parent)
        // Capture the source for a later return once the incoming plate covers
        // it, just before the selection changes behind the plate. On the input
        // turn this work (theme field plus every pane, 14–25 ms at 1280 × 800)
        // delayed the slide's first frame; here nothing visible waits for it.
        let captureFrom = source.flatMap { $0.space != selection.space ? $0 : nil }
        // True until plate.begin returns: a cover that is already in place (Reduce Motion, no
        // direction) applies on this input turn, which is not a deferred selection.
        var beginning = true
        let apply = { [weak self] in
            guard let self, self.generation == token else { return }
            if let captureFrom, self.nativeSelection == captureFrom { self.captureSource(captureFrom) }
            self.applying = true
            self.nativeSelection = selection; self.nativeStyle = style
            self.container.applySpaceSelection(selection, animateSlots: false, deferred: !beginning)
            self.applying = false
            self.awaitPresentation(rearm: false)
        }
        applyingCoveredSelection = apply
        plate.layer?.cornerRadius = container.fullBleed ? 0 : PanelMetrics.cornerRadius
        let started = plate.begin(outgoing: previousCover, destination: key, theme: style,
                                 themeFrame: themeFrame, direction: direction,
                                 animated: direction != 0) { [weak self] receipt in
            guard let self, self.generation == token else { return }
            self.receipt = receipt
            let apply = self.applyingCoveredSelection; self.applyingCoveredSelection = nil
            apply?()
        }
        beginning = false
        if !started {
            applyingCoveredSelection = nil; requestedSelection = nil
            if plate.phase == .idle {
                // Keep the old native source and allow the same request to
                // retry when geometry becomes representable. Never expose a hole.
                // A fading cover finishes its retire (and its deferred hide) instead (review r1 #5).
                if plate.isFading { plate.cancel() } else { plate.removeFromSuperview() }
                if source?.tabs.isEmpty == true { container.isHidden = true }
            } else {
                // The running cover's callbacks were superseded above: it would
                // stay up and take every click. Retire it and show the selection.
                applyUncovered(selection, from: source); return
            }
        }
        lastViewport = viewport
    }

    /// The uncovered path: no plate, the selection applies at once.
    private func applyUncovered(_ selection: SpaceContentSelection, from source: SpaceContentSelection?) {
        cancel(clearCache: source?.profile != selection.profile,
               preservingCapture: plate.phase == .idle && source?.profile == selection.profile)
        requestedSelection = selection; nativeSelection = selection; nativeStyle = container.style
        container.applySpaceSelection(selection, animateSlots: source?.space == selection.space, notify: false)
    }

    private var viewport: WebContentFrameViewport {
        let scale = container.window?.backingScaleFactor ?? 1
        return WebContentFrameViewport(width: Int(ceil(container.bounds.width * scale)),
            height: Int(ceil(container.bounds.height * scale)), scale: scale)
    }

    private func captureSource(_ source: SpaceContentSelection) {
        guard snapshotTask == nil else { return }
        let key = container.spaceSnapshotKey(source)
        guard let input = container.spaceSnapshotInput(style: nativeStyle) else { return }
        snapshotTask = Task { @MainActor [weak self] in
            defer { self?.snapshotTask = nil }
            guard let image = await input.capture(), !Task.isCancelled,
                  let self, self.container.spaceSnapshotKey(source) == key else { return }
            if self.plate.remember(image, for: key) { self.captureCount += 1 }
        }
    }

    /// Explicit layout/resize input, never a frame driver. Resize the retained
    /// plates once, then request the final native viewport behind them.
    func layout() {
        if plate.phase == .idle {
            // A resize or sidebar change during the retire fade would leave the fading cover at the old
            // geometry: end the fade at once instead (review r1 #5).
            if plate.isFading, plate.frame != container.bounds { plate.cancel() }
            return
        }
        guard let parent = container.superview else { return }
        let frame = container.bounds
        guard frame != plate.frame || lastViewport != viewport else {
            if !applying, plate.phase == .awaitingPresentation, let selection = nativeSelection,
               presentationViewports(selection) != lastPresentationViewports { awaitPresentation() }
            return
        }
        if frame.size == plate.frame.size, lastViewport == viewport {
            CATransaction.begin(); CATransaction.setDisableActions(true); plate.frame = frame; CATransaction.commit()
            return
        }
        guard let selection = requestedSelection else { return }
        let scale = container.window?.backingScaleFactor ?? 1
        guard let image = plate.capturePresentation(size: frame.size, scale: scale) else { return }
        plate.invalidateAll()
        CATransaction.begin(); CATransaction.setDisableActions(true); plate.frame = frame; CATransaction.commit()
        let token = generation
        _ = plate.begin(outgoing: image, destination: container.spaceSnapshotKey(selection),
            theme: container.style, themeFrame: container.convert(parent.bounds, from: parent),
            direction: 0, animated: false, incomingOverride: image) { [weak self] receipt in
                guard let self, self.generation == token else { return }
                self.receipt = receipt
                if let apply = self.applyingCoveredSelection {
                    self.applyingCoveredSelection = nil; apply()
                } else { self.awaitPresentation(rearm: false) }
            }
        lastViewport = viewport
    }

    func invalidate(tab: ItemID) {
        plate.invalidate(tab: tab)
        if !applying, plate.phase == .awaitingPresentation, nativeSelection?.tabs.contains(tab) == true {
            awaitPresentation()
        }
    }

    private func cancelRequests() {
        frameGeneration &+= 1
        // Cancel may run completion synchronously. Invalidate before calling it.
        let old = Array(requests.values); requests.removeAll(); waiting.removeAll()
        lastPresentationViewports.removeAll()
        for request in old { request.cancel() }
    }

    private func visibleTabs(_ selection: SpaceContentSelection) -> [ItemID] {
        if let maximized = container.maximizedTabID, selection.tabs.contains(maximized) { return [maximized] }
        return selection.tabs
    }

    private func presentationViewports(_ selection: SpaceContentSelection) -> [ItemID: WebContentFrameViewport] {
        Dictionary(uniqueKeysWithValues: visibleTabs(selection).compactMap { id in
            container.host(for: id).map { (id, container.spaceHostViewport($0)) }
        })
    }

    /// Called with the final pane sizes before any native page frame changes.
    /// It is not a frame driver; the render-server slide changes no geometry.
    func prepareForLayout(_ viewports: [ItemID: WebContentFrameViewport]) {
        guard plate.phase == .awaitingPresentation, let selection = nativeSelection else { return }
        let visible = Set(visibleTabs(selection))
        let targets = viewports.filter { visible.contains($0.key) }
        guard targets != lastPresentationViewports else { return }
        awaitPresentation(viewports: targets, retainingSurfaceForResize: true)
    }

    private func awaitPresentation(viewports: [ItemID: WebContentFrameViewport]? = nil,
                                   retainingSurfaceForResize: Bool = false, rearm: Bool = true) {
        // Native layout may have armed the future sizes before its one write.
        // Keep those requests when the covering plate itself changes size.
        if !rearm, !presentationUnavailable, !waiting.isEmpty,
           requests.count == waiting.count, let selection = nativeSelection,
           presentationViewports(selection) == lastPresentationViewports { return }
        cancelRequests(); presentationUnavailable = false
        guard let selection = nativeSelection, let receipt,
              plate.phase == .awaitingPresentation else { return }
        if selection.tabs.isEmpty {
            // The explicit native empty-Space surface is ready. No live engine
            // view is exposed and no engine receipt is fabricated for it.
            plate.presented(receipt); container.finishEmptySpaceSelection(); return
        }
        let token = frameGeneration
        // A pane showing native content (sad tab, placeholder) has no engine
        // frame to wait for; only panes showing their engine view do.
        let visibleTabs = visibleTabs(selection).filter { !container.paneShowsNativeContent($0) }
        let hosts = visibleTabs.compactMap { container.host(for: $0) }.filter { !$0.view.isHiddenOrHasHiddenAncestor }
        lastPresentationViewports = viewports ?? presentationViewports(selection)
        guard hosts.count == visibleTabs.count else { presentationUnavailable = true; return }
        if hosts.isEmpty { plate.presented(receipt); return }
        // Loading may finish before pixels are presented, so this is only a
        // prerequisite. Its callback re-arms the actual presentation request.
        guard hosts.allSatisfy({ !$0.isLoading }) else { return }
        let specifications = hosts.compactMap { host in
            lastPresentationViewports[host.tabID].map { (host, UUID(), $0, container.spaceHostRevision(host.tabID)) }
        }
        guard specifications.count == hosts.count else { presentationUnavailable = true; return }
        waiting = Set(specifications.map { $0.1 })
        for (host, id, viewport, revision) in specifications {
            // A native host (Welcome, Notes, Easels) has no engine frame to wait
            // for: its content is drawn natively and is ready now.
            guard let presenter = host.framePresentation else { waiting.remove(id); continue }
            let request = presenter.firstFramePresented(at: viewport, requestID: id,
                retainingSurfaceForResize: retainingSurfaceForResize) { [weak self, weak host] frame in
                guard let self, let host, self.frameGeneration == token,
                      self.nativeSelection == selection, self.container.host(for: host.tabID) === host,
                      !host.view.isHiddenOrHasHiddenAncestor,
                      self.container.spaceHostRevision(host.tabID) == revision,
                      self.container.spaceHostViewport(host) == viewport else { return }
                self.requests[id] = nil
                guard let frame, frame.requestID == id, frame.viewport == viewport,
                      frame.presentedAt.isFinite, frame.presentedAt > 0 else {
                    // The engine ended this request for good (navigation
                    // replacement, renderer loss). Show the live page now,
                    // never a stuck cover; no timer is involved.
                    self.presentationUnavailable = true; self.revealLivePage(); return
                }
                self.waiting.remove(id)
                if self.waiting.isEmpty, let currentReceipt = self.receipt { self.plate.presented(currentReceipt) }
            }
            if let request, waiting.contains(id) { requests[id] = request }
            else if request == nil, waiting.contains(id) {
                // The engine refused the request: no receipt will come.
                presentationUnavailable = true; revealLivePage(); return
            }
        }
        if waiting.isEmpty { plate.presented(receipt) }
    }

    /// The presentation fallback: retire the cover over the live page. Our own
    /// superseded requests never come here (their generation no longer matches).
    private func revealLivePage() {
        cancelRequests()
        if let receipt, plate.phase == .awaitingPresentation { plate.presented(receipt) }
    }

    func cancel(clearCache: Bool = false, preservingCapture: Bool = false) {
        generation &+= 1; cancelRequests()
        // Ordinary same-profile refreshes can run while an outgoing capture is
        // still settling. Its immutable key/revision validates it on completion.
        if !preservingCapture { snapshotTask?.cancel() }
        applyingCoveredSelection = nil; receipt = nil; requestedSelection = nil
        plate.cancel(); if clearCache { plate.invalidateAll() }
    }
    func reset() { cancel(clearCache: true); nativeSelection = nil }
}
