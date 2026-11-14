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

/// Selection changes once, behind the incoming plate. A missing engine seam
/// leaves that plate visible; it never creates a synthetic presentation receipt.
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

    init(container: WebContentContainer) { self.container = container }
    isolated deinit { snapshotTask?.cancel(); for request in requests.values { request.cancel() } }

    func select(_ selection: SpaceContentSelection) {
        if requestedSelection == selection, plate.phase != .idle { return }
        let source = nativeSelection
        let needsCover = source != nil && (source?.space != selection.space || plate.phase != .idle)
        guard needsCover, container.window?.isVisible == true,
              let parent = container.superview, !container.bounds.isEmpty else {
            cancel(clearCache: source?.profile != selection.profile)
            requestedSelection = selection; nativeSelection = selection; nativeStyle = container.style
            container.applySpaceSelection(selection, animateSlots: source?.space == selection.space, notify: false)
            return
        }

        generation &+= 1; let token = generation
        cancelRequests()
        let previousRequest = requestedSelection
        requestedSelection = selection
        if source?.profile != selection.profile { plate.invalidateAll() }
        let scale = container.window?.backingScaleFactor ?? 1
        let previousCover = plate.capturePresentation(size: container.bounds.size, scale: scale)
        if plate.phase != .idle, previousCover == nil { return }
        plate.frame = container.bounds
        // Share the web panel's ancestor. Sidebar/Cmd+S layer motion therefore
        // moves the cover too, without a per-frame sibling-frame update.
        container.addSubview(plate, positioned: .above, relativeTo: nil)
        let style = container.style
        let key = container.spaceSnapshotKey(selection)
        let visualSource = previousRequest ?? source
        let oldIndex = visualSource.flatMap { container.spaceOrder.firstIndex(of: $0.space) } ?? 0
        let newIndex = container.spaceOrder.firstIndex(of: selection.space) ?? oldIndex
        let direction: CGFloat = newIndex == oldIndex ? 0 : newIndex < oldIndex ? -1 : 1
        let themeFrame = container.convert(parent.bounds, from: parent)
        // Source remains attached and visible throughout the slide. Capture it
        // once for a later return, without waiting to begin the layer motion.
        if let source, source.space != selection.space { captureSource(source) }
        let apply = { [weak self] in
            guard let self, self.generation == token else { return }
            self.applying = true
            self.nativeSelection = selection; self.nativeStyle = style
            self.container.applySpaceSelection(selection, animateSlots: false)
            self.applying = false
            self.awaitPresentation()
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
        if !started {
            // Keep the old native source/cover and allow the same request to
            // retry when geometry becomes representable. Never expose a hole.
            applyingCoveredSelection = nil; requestedSelection = nil
            if plate.phase == .idle { plate.removeFromSuperview() }
        }
        lastViewport = viewport
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
        guard plate.phase != .idle, let parent = container.superview else { return }
        let frame = container.bounds
        guard frame != plate.frame || lastViewport != viewport else { return }
        if frame.size == plate.frame.size, lastViewport == viewport {
            CATransaction.begin(); CATransaction.setDisableActions(true); plate.frame = frame; CATransaction.commit()
            return
        }
        guard let selection = requestedSelection else { return }
        let scale = container.window?.backingScaleFactor ?? 1
        guard let image = plate.capturePresentation(size: frame.size, scale: scale) else { return }
        cancelRequests(); plate.invalidateAll()
        CATransaction.begin(); CATransaction.setDisableActions(true); plate.frame = frame; CATransaction.commit()
        let token = generation
        _ = plate.begin(outgoing: image, destination: container.spaceSnapshotKey(selection),
            theme: container.style, themeFrame: container.convert(parent.bounds, from: parent),
            direction: 0, animated: false, incomingOverride: image) { [weak self] receipt in
                guard let self, self.generation == token else { return }
                self.receipt = receipt
                if let apply = self.applyingCoveredSelection {
                    self.applyingCoveredSelection = nil; apply()
                } else { self.awaitPresentation() }
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
        for request in old { request.cancel() }
    }

    private func awaitPresentation() {
        cancelRequests(); presentationUnavailable = false
        guard let selection = nativeSelection, let receipt,
              plate.phase == .awaitingPresentation else { return }
        if selection.tabs.isEmpty {
            // The explicit native empty-Space surface is ready. No live engine
            // view is exposed and no engine receipt is fabricated for it.
            plate.presented(receipt); container.finishEmptySpaceSelection(); return
        }
        let token = frameGeneration
        let hosts = selection.tabs.compactMap { container.host(for: $0) }.filter { !$0.view.isHiddenOrHasHiddenAncestor }
        guard hosts.count == selection.tabs.count else { presentationUnavailable = true; return }
        // Loading may finish before pixels are presented, so this is only a
        // prerequisite. Its callback re-arms the actual presentation request.
        guard hosts.allSatisfy({ !$0.isLoading }) else { return }
        let specifications = hosts.map { host in (host, UUID(), container.spaceHostViewport(host), container.spaceHostRevision(host.tabID)) }
        waiting = Set(specifications.map { $0.1 })
        for (host, id, viewport, revision) in specifications {
            guard let presenter = host.framePresentation else { presentationUnavailable = true; continue }
            let request = presenter.firstFramePresented(at: viewport, requestID: id) { [weak self, weak host] frame in
                guard let self, let host, self.frameGeneration == token,
                      self.nativeSelection == selection, self.container.host(for: host.tabID) === host,
                      self.container.spaceHostRevision(host.tabID) == revision,
                      self.container.spaceHostViewport(host) == viewport else { return }
                self.requests[id] = nil
                guard frame?.requestID == id, frame?.viewport == viewport else {
                    self.presentationUnavailable = true; return
                }
                self.waiting.remove(id)
                if self.waiting.isEmpty { self.plate.presented(receipt) }
            }
            if let request, waiting.contains(id) { requests[id] = request }
            else if request == nil, waiting.contains(id) { presentationUnavailable = true }
        }
    }

    func cancel(clearCache: Bool = false) {
        generation &+= 1; cancelRequests(); snapshotTask?.cancel()
        applyingCoveredSelection = nil; receipt = nil; requestedSelection = nil
        plate.cancel(); if clearCache { plate.invalidateAll() }
    }
    func reset() { cancel(clearCache: true); nativeSelection = nil }
}
