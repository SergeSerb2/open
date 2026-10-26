import AppKit
import OpenModel
import OpenSleep

public typealias OpenSleepWindowState = SleepVisibilitySnapshot.WindowState

@MainActor
public final class AppVisibilityProvider: SleepVisibilityProviding {
    public var browserWindowControllers: [BrowserWindowController] = []
    public var littleOpenCoordinator: LittleOpenCoordinator?
    public var pipTabIDs: Set<ItemID> = []
    public weak var sleepController: SleepController?
    private let model: BrowserModel
    private var lastVisible: Set<ItemID> = []
    private var pending: Task<Void, Never>?
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
            if state == .visible, c.peekController.isShown, let id = c.peekController.stack.last?.hostTabID { peek.insert(id) }
        }
        for s in littleOpenCoordinator?.sessions ?? [] where s.windowIsVisible { little.insert(s.tab.id) }
        return SleepVisibilitySnapshot(windows: windows, peek: peek, littleOpen: little, splitPanes: [], pictureInPicture: pipTabIDs)
    }
    public func visibilityChanged() {
        let visible = sleepVisibility().visibleTabIDs(in: model), hidden = lastVisible.subtracting(visible)
        lastVisible = visible; pending?.cancel()
        for id in hidden { sleepController?.tabBecameHidden(id) }
        pending = Task { [weak self] in
            guard let self else { return }
            for id in visible { guard !Task.isCancelled else { return }; await self.sleepController?.tabBecameVisible(id) }
        }
    }
    /// Future App quit ordering: capture all live histories before closing any cached hosts.
    public func tearDownAfterQuitCapture(_ capture: () async -> Void) async {
        await capture()
        for c in browserWindowControllers { c.peekController.dismissAll(); c.container.closeAll() }
        littleOpenCoordinator?.closeAll()
    }
}
