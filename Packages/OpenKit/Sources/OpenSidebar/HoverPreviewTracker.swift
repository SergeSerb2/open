import AppKit
import OpenModel

public struct SidebarHoverPreviewRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case folder(ItemID), page(tabID: ItemID) }
    public var kind: Kind
    public var anchorInWindow: CGRect
    public init(kind: Kind, anchorInWindow: CGRect) { self.kind = kind; self.anchorInWindow = anchorInWindow }
}

/// One window's delayed hover state. Uses cancellable one-shot tasks only.
/// The App owns the preview panel/host and reports pointer entry/exit through
/// setPointerInsidePreview. No panel or engine host is made by this tracker.
@MainActor
public final class HoverPreviewTracker {
    public enum Suppression: Hashable { case drag, rename, menu, swipe }
    unowned let context: SidebarContext
    private let model: BrowserModel
    private var candidate: SidebarHoverPreviewRequest?
    private weak var owner: NSView?
    private weak var shownWindow: NSWindow?
    private var showTask: DispatchWorkItem?
    private var hideTask: DispatchWorkItem?
    private var lastHidden: TimeInterval?
    private var insideCard = false
    private var suppressed: Set<Suppression> = []
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var focusLoop: ObservationLoop?
    private var modelObserver: UUID?
    public var hasInstalledWork: Bool { !observers.isEmpty || eventMonitor != nil || showTask != nil || hideTask != nil }
    public private(set) var request: SidebarHoverPreviewRequest?
    public private(set) var scheduledShowCount = 0
    /// Delay and `systemUptime` deadline of the pending show work, nil when
    /// no show is scheduled. Read-back for checks; no behavior depends on it.
    public private(set) var scheduledShowDelay: TimeInterval?
    public private(set) var scheduledShowDeadline: TimeInterval?
    /// Delay of the pending hide work, nil when no hide is scheduled.
    public private(set) var scheduledHideDelay: TimeInterval?
    public var isArmed: Bool { showTask != nil }
    public var suppressesTooltips: Bool { isArmed || request != nil }

    init(context: SidebarContext) { self.context = context; model = context.model }
    isolated deinit {
        showTask?.cancel(); hideTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        focusLoop?.cancel()
        if let modelObserver { model.removeObserver(modelObserver) }
    }
    private var preferences: UserDefaults { context.previewPreferences }
    private func enabled(_ key: String) -> Bool { preferences.object(forKey: key) == nil || preferences.bool(forKey: key) }

    /// Returns true while this target owns hover feedback (suppress its tooltip).
    @discardableResult
    func hover(nodeID: ItemID, anchorInWindow: CGRect, owner: NSView) -> Bool {
        guard enabled("open.general.previewsEnabled") else { stopDisabled(); return false }
        installObservers()
        guard suppressed.isEmpty, context.previewSuppressions.isEmpty else { dismiss(); return false }
        guard context.currentTab?.id != nodeID, let node = context.model.node(id: nodeID) else { leaveTarget(); return false }
        let kind: SidebarHoverPreviewRequest.Kind
        switch node {
        case .folder:
            guard enabled("open.general.previewsFolders") else { leaveTarget(); return false }
            kind = .folder(nodeID)
        case .tab:
            guard enabled("open.general.previewsPages"), context.model.isPinned(tabID: nodeID) || {
                if case .favorites = context.model.parent(of: nodeID) { return true }; return false
            }() else { leaveTarget(); return false }
            kind = .page(tabID: nodeID)
        case .split: leaveTarget(); return false
        }
        hideTask?.cancel(); hideTask = nil; scheduledHideDelay = nil
        self.owner = owner
        let next = SidebarHoverPreviewRequest(kind: kind, anchorInWindow: anchorInWindow)
        if candidate?.kind == kind { candidate = next; return suppressesTooltips }
        candidate = next
        showTask?.cancel(); showTask = nil; scheduledShowDelay = nil; scheduledShowDeadline = nil
        TooltipController.shared.cancel(for: nil)
        let now = ProcessInfo.processInfo.systemUptime
        if request != nil || lastHidden.map({ now - $0 <= 1 }) == true { show(next); return true }
        let configured = preferences.object(forKey: "open.general.previewsDelaySeconds") == nil ? 0.5 : preferences.double(forKey: "open.general.previewsDelaySeconds")
        let delay = configured.isFinite ? max(0, configured) : 0.5
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.candidate?.kind == kind, self.suppressed.isEmpty, self.enabled("open.general.previewsEnabled") else { return }
            self.showTask = nil; self.scheduledShowDelay = nil; self.scheduledShowDeadline = nil
            if let candidate = self.candidate { self.show(candidate) }
        } }
        showTask = work; scheduledShowCount += 1
        scheduledShowDelay = delay; scheduledShowDeadline = ProcessInfo.processInfo.systemUptime + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    private func valid(_ next: SidebarHoverPreviewRequest) -> Bool {
        guard context.canStartHoverPreview else { return false }
        switch next.kind {
        case .folder(let id): return enabled("open.general.previewsFolders") && context.model.node(id: id)?.folder != nil
        case .page(let id):
            guard enabled("open.general.previewsPages"), context.model.tab(id: id) != nil, context.currentTab?.id != id else { return false }
            if case .favorites = context.model.parent(of: id) { return true }
            return context.model.isPinned(tabID: id)
        }
    }
    private func show(_ next: SidebarHoverPreviewRequest) {
        guard valid(next), let window = owner?.window else { dismiss(); return }
        showTask?.cancel(); showTask = nil; scheduledShowDelay = nil; scheduledShowDeadline = nil
        shownWindow = window
        request = next
        context.send(.hoverPreview(next))
    }
    func leaveTarget() {
        candidate = nil; showTask?.cancel(); showTask = nil; scheduledShowDelay = nil; scheduledShowDeadline = nil
        guard request != nil, !insideCard, hideTask == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.candidate == nil, !self.insideCard else { return }
            self.dismiss()
        } }
        let delay: TimeInterval = 0.25
        hideTask = work; scheduledHideDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    public func setPointerInsidePreview(_ inside: Bool) {
        insideCard = inside
        if inside { hideTask?.cancel(); hideTask = nil; scheduledHideDelay = nil }
        else if candidate == nil { leaveTarget() }
    }
    public func setSuppressed(_ reason: Suppression, _ value: Bool) {
        if value { suppressed.insert(reason); dismiss() } else { suppressed.remove(reason) }
    }
    public func dismiss() {
        showTask?.cancel(); showTask = nil; hideTask?.cancel(); hideTask = nil
        scheduledShowDelay = nil; scheduledShowDeadline = nil; scheduledHideDelay = nil
        candidate = nil; insideCard = false
        guard request != nil else { return }
        request = nil; shownWindow = nil; lastHidden = ProcessInfo.processInfo.systemUptime
        context.send(.hoverPreview(nil))
    }
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        focusLoop = ObservationLoop(read: { [weak self] in
            _ = self?.context.focusedSpace?.id; _ = self?.context.currentTab?.id
        }) { [weak self] in self?.dismiss() }
        modelObserver = context.model.addObserver { [weak self] _ in
            guard let self, let target = self.candidate ?? self.request else { return }
            if !self.valid(target) { self.dismiss() }
        }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuppressed(.menu, true) }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuppressed(.menu, false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let resignedWindow = note.object as? NSWindow
            MainActor.assumeIsolated { if let self, resignedWindow === (self.shownWindow ?? self.owner?.window) { self.dismiss() } }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.context.previewsEnabled { self.dismiss() } else { self.stopDisabled() }
            }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.owner?.window, event.type == .scrollWheel || event.keyCode == 53 { self.dismiss() }
            }
            return event
        }
    }
    private func stopDisabled() {
        dismiss()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        focusLoop?.cancel(); focusLoop = nil
        if let modelObserver { context.model.removeObserver(modelObserver); self.modelObserver = nil }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }
}
