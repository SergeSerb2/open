import AppKit
import OpenModel
import OpenSleep

public typealias OpenSleepWindowState = SleepVisibilitySnapshot.WindowState

@MainActor
public final class AppVisibilityProvider: SleepVisibilityProviding {
    public var browserWindowControllers: [BrowserWindowController] = []
    public var littleOpenCoordinator: LittleOpenCoordinator?
    public var pipTabIDs: Set<ItemID> = []
    /// Tabs of the mini players shown in visible windows, plus playing or paused sessions without
    /// controls (media-pip §4.10). The App's MediaCoordinator feeds both sets.
    public var mediaControlTabIDs: Set<ItemID> = []
    public weak var sleepController: SleepController?
    private let model: BrowserModel
    private var lastVisible: Set<ItemID> = []
    private var pending: Task<Void, Never>?
    private var pendingVisible: Set<ItemID> = []
    public init(model: BrowserModel) { self.model = model }
    isolated deinit { pending?.cancel() }
    public func attachHooks() {
        for controller in browserWindowControllers { controller.onVisibilityChange = { [weak self] in self?.visibilityChanged() } }
        littleOpenCoordinator?.onChange = { [weak self] in self?.visibilityChanged() }
        visibilityChanged()
    }
    public func sleepVisibility() -> SleepVisibilitySnapshot {
        var windows: [WindowID: OpenSleepWindowState] = [:], peek: Set<ItemID> = [], little: Set<ItemID> = []
        for c in browserWindowControllers {
            let state: OpenSleepWindowState
            if let override = c.visibilityOverride { state = override }
            else if let window = c.window {
                state = window.isMiniaturized ? .minimized : (!window.isVisible ? .closed : (window.occlusionState.contains(.visible) ? .visible : .occluded))
            } else { state = .closed }
            windows[c.windowID] = state
            if state == .visible, c.hasPeekController, c.peekController.isShown, let id = c.peekController.stack.last?.hostTabID { peek.insert(id) }
        }
        for s in littleOpenCoordinator?.sessions ?? [] where s.windowIsVisible { little.insert(s.tab.id) }
        return SleepVisibilitySnapshot(windows: windows, peek: peek, littleOpen: little, splitPanes: [], pictureInPicture: pipTabIDs, mediaControls: mediaControlTabIDs)
    }
    public func visibilityChanged() {
        let visible = sleepVisibility().visibleTabIDs(in: model)
        let newlyVisible = visible.subtracting(lastVisible), hidden = lastVisible.subtracting(visible)
        lastVisible = visible
        for id in hidden { sleepController?.tabBecameHidden(id) }
        pendingVisible.formUnion(newlyVisible); pendingVisible.formIntersection(visible)
        // Repeated chrome/focus notifications must neither stamp existing tabs
        // active again nor cancel a newly visible tab's queued wake.
        guard pending == nil, !pendingVisible.isEmpty else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            defer { self.pending = nil }
            while !Task.isCancelled, let id = self.pendingVisible.first {
                self.pendingVisible.remove(id)
                await self.sleepController?.tabBecameVisible(id)
            }
        }
    }
    /// Future App quit ordering: capture all live histories before closing any cached hosts.
    public func tearDownAfterQuitCapture(_ capture: () async -> Void) async {
        await capture()
        for c in browserWindowControllers { if c.hasPeekController { c.peekController.dismissAll() }; c.container.closeAll() }
        littleOpenCoordinator?.closeAll()
    }
}
