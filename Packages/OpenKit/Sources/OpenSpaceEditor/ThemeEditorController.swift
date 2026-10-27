import AppKit
import Observation
import OpenDesign
import OpenModel

@MainActor
public final class ThemeEditorController {
    public let panel = ThemeEditorPanel()
    public private(set) var state: ThemeEditorState
    /// May close or release the owner. Called only after the complete commit.
    public var onCommit: (@MainActor () -> Void)? { didSet { editorUndo.onModelRestore = onCommit } }
    public private(set) var session: ThemeEditSession?
    public var onClose: (@MainActor () -> Void)?
    public private(set) var previewCount = 0
    public private(set) var frameCount = 0
    public private(set) var commitCount = 0
    public private(set) var isClosed = false
    private weak var ownerWindow: NSWindow?
    private let anchor: ThemeEditorAnchor
    private let model: BrowserModel?
    private let spaceID: SpaceID?
    private let draftChange: (@MainActor (SpaceStyle?) -> Void)?
    private let editorUndo: EditorUndoRelay
    private var baselineState: ThemeEditorState
    private var baseline: SpaceTheme
    private var lastWritten: SpaceTheme
    private var pendingPreview = false
    private var pendingFinish = false
    private var liveGesture = false
    private var isClosing = false
    private var displayLink: CADisplayLink?
    private var frameTarget: EditorFrameTarget?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var outsideMonitor: Any?

    public convenience init(model: BrowserModel, spaceID: SpaceID, window: NSWindow,
                            anchor: ThemeEditorAnchor) {
        let baseline = model.space(id: spaceID)?.theme ?? SpaceTheme()
        let manager = model.undoManager ?? window.undoManager ?? UndoManager()
        model.undoManager = manager
        self.init(model: model, spaceID: spaceID, draft: SpaceStyle.seed(from: baseline), baseline: baseline,
                  window: window, anchor: anchor, undoManager: manager, onChange: nil)
    }

    public convenience init(draft: SpaceStyle?, window: NSWindow, anchor: ThemeEditorAnchor,
                            onChange: @escaping @MainActor (SpaceStyle?) -> Void) {
        let manager = window.undoManager ?? {
            let manager = UndoManager(); manager.groupsByEvent = false; return manager
        }()
        self.init(model: nil, spaceID: nil, draft: draft, baseline: SpaceTheme(style: draft),
                  window: window, anchor: anchor, undoManager: manager, onChange: onChange)
    }

    private init(model: BrowserModel?, spaceID: SpaceID?, draft: SpaceStyle?, baseline: SpaceTheme,
                 window: NSWindow, anchor: ThemeEditorAnchor, undoManager: UndoManager?,
                 onChange: (@MainActor (SpaceStyle?) -> Void)?) {
        self.model = model; self.spaceID = spaceID; self.ownerWindow = window; self.anchor = anchor
        self.baseline = baseline; lastWritten = baseline
        if let model, let spaceID { session = ThemeEditSession(model: model, spaceID: spaceID) }
        let initial = ThemeEditorState(style: draft); state = initial; baselineState = initial
        draftChange = onChange
        editorUndo = EditorUndoRelay(onRestore: onChange)
        panel.editorUndoManager = undoManager
        if let model { panel.undoProvider = { [weak model] in model?.undoManager } }
        editorUndo.controller = self
        panel.editorView.onAction = { [weak self] in self?.apply($0) }
        panel.onEscape = { [weak self] in self?.close() }
        panel.beforeUndo = { [weak self] in self?.finishBeforeExternalAction() }
        renderState()
        observeTheme()
    }

    isolated deinit {
        displayLink?.invalidate(); session?.close()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    public func show() {
        guard let window = ownerWindow, !isClosed else { return }
        var frame = CGRect(origin: .zero, size: ThemeEditorMetrics.panelSize)
        let windowTop = window.frame.maxY
        let position: CGPoint
        switch anchor {
        case .sidebarTrailingEdge(let sidebar):
            position = window.convertPoint(toScreen: CGPoint(x: sidebar.maxX, y: window.contentView?.isFlipped == true ? 35 : window.contentLayoutRect.height - 35))
            frame.origin = CGPoint(x: position.x, y: windowTop - 35 - frame.height)
        case .card(let card):
            position = window.convertPoint(toScreen: CGPoint(x: card.maxX, y: card.maxY))
            frame.origin = CGPoint(x: position.x, y: position.y - frame.height)
        }
        if panel.renderScale == nil { panel.renderScale = window.backingScaleFactor }
        if let screen = window.screen?.visibleFrame {
            let band = ThemeEditorMetrics.contentInset
            frame.origin.x = min(max(frame.minX, screen.minX + 8 - band), screen.maxX - frame.width - 8 + band)
            frame.origin.y = min(max(frame.minY, screen.minY + 8 - band), screen.maxY - frame.height - 8 + band)
        }
        panel.setFrame(frame, display: false)
        // Harness windows are never ordered. The production owner orders its child.
        if window.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            animateOpen()
        }
        panel.makeFirstResponder(panel.editorView.pad)
        observeLifecycle()
    }

    public func close() {
        guard !isClosed, !isClosing else { return }; isClosing = true
        finishBeforeExternalAction()
        isClosed = true; displayLink?.invalidate(); displayLink = nil; session?.close()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver); lifecycleObservers.removeAll()
        let panel = panel
        let hide: @MainActor () -> Void = {
            if let parent = panel.parent { parent.removeChildWindow(panel) }
            panel.orderOut(nil)
        }
        if panel.isVisible, let layer = panel.editorView.layer {
            CATransaction.begin(); CATransaction.setAnimationDuration(Motion.editorFade)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { hide() } }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0; fade.duration = Motion.editorFade
            layer.opacity = 0; layer.add(fade, forKey: "editor-close-fade")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = layer.presentation()?.transform.m11 ?? 1; scale.toValue = Motion.editorCloseScale
                scale.duration = Motion.editorFade; layer.add(scale, forKey: "editor-close-scale")
            }
            CATransaction.commit()
        } else { hide() }
        onClose?()
    }

    public func apply(_ action: ThemeEditorAction) {
        guard !isClosed, !isClosing else { return }
        if pendingFinish && !state.isGestureInProgress { flushPreviewFrame() }
        switch action {
        case .setAppearance, .addColor, .removeColor, .selectPreset, .cycleTexture:
            finishBeforeExternalAction(); captureBaseline()
        default: break
        }
        let wasGesture = state.isGestureInProgress
        let previous = state.style
        switch action {
        case .beginKeyboardGesture, .dragKnob, .setIntensity(_, final: false), .setNoise(_, final: false):
            if !wasGesture { finishBeforeExternalAction(); captureBaseline() }; liveGesture = true
        default: break
        }
        state.apply(action)
        renderState()
        let changed = previous != state.style
        switch action {
        case .beginKeyboardGesture, .dragKnob, .setIntensity(_, final: false), .setNoise(_, final: false):
            pendingPreview = pendingPreview || changed
            if pendingPreview { requestFrame() }
        case .endKeyboardGesture, .endDrag, .setIntensity(_, final: true), .setNoise(_, final: true):
            pendingPreview = pendingPreview || changed; pendingFinish = true; requestFrame()
        case .setPresetPage: break
        case .keyboardHue where state.isGestureInProgress, .keyboardRadius where state.isGestureInProgress:
            pendingPreview = pendingPreview || changed; if pendingPreview { requestFrame() }
        default:
            if changed {
                writePreview(); commit()
                if case .addColor = action { announceCount() }
                if case .removeColor = action { announceCount() }
            }
        }
    }

    /// One display frame for offscreen callers; the visible panel uses CADisplayLink.
    public func flushPreviewFrame() {
        displayLink?.invalidate(); displayLink = nil
        frameCount += 1
        if pendingPreview { pendingPreview = false; writePreview() }
        if pendingFinish { pendingFinish = false; commit() }
    }

    public func prepareForSnapshot() {
        flushPreviewFrame()
        synchronizeFromModel()
        panel.editorView.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
    }

    private func renderState() {
        panel.applyAppearance(state.appearance)
        panel.editorView.apply(state)
    }
    private func captureBaseline() {
        baseline = model.flatMap { model in spaceID.flatMap { model.space(id: $0)?.theme } } ?? SpaceTheme(style: state.style)
        baselineState = state; session?.captureBaseline()
    }
    private func writePreview() {
        let theme = state.style.map { SpaceTheme(style: $0) } ?? SpaceTheme()
        guard theme != lastWritten else { return }
        lastWritten = theme; previewCount += 1
        if let session { session.preview(state.style, live: liveGesture) }
        else { draftChange?(state.style) }
    }
    private func commit() {
        let current = model.flatMap { model in spaceID.flatMap { model.space(id: $0)?.theme } } ?? SpaceTheme(style: state.style)
        guard current != baseline else { _ = session?.commit(); liveGesture = false; return }
        let manager = panel.undoManager
        let group = manager.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
        if group { manager?.beginUndoGrouping() }
        defer { if group { manager?.endUndoGrouping() } }
        var didCommit = false
        let old = EditorUndoSnapshot(state: baselineState, theme: baseline)
        let new = EditorUndoSnapshot(state: state, theme: current)
        if let session {
            if session.commit() {
                // Same undo group as the model write. Undo restores this state
                // first, then the model; redo reverses that order. Observation
                // sees lastWritten and does not reconstruct the pad range.
                if let manager { editorUndo.record(manager: manager, from: old, to: new) }
                commitCount += 1; didCommit = true
            }
        } else if let manager {
            editorUndo.record(manager: manager, from: old, to: new); commitCount += 1; didCommit = true
        }
        if manager?.groupingLevel ?? 0 > 0 { manager?.setActionName("Update Theme") }
        baseline = current; baselineState = state; liveGesture = false
        if didCommit { onCommit?() }
    }
    private func requestFrame() {
        guard displayLink == nil else { return }
        let target = frameTarget ?? EditorFrameTarget(owner: self); frameTarget = target
        let link = panel.editorView.displayLink(target: target, selector: #selector(EditorFrameTarget.tick(_:)))
        displayLink = link; link.add(to: .main, forMode: .common)
    }
    private func finishBeforeExternalAction() {
        panel.editorView.finishGestures()
        if state.isGestureInProgress { state.apply(.endDrag); renderState(); pendingFinish = true }
        if pendingPreview || pendingFinish { flushPreviewFrame() }
    }
    private func observeTheme() {
        guard let model, let spaceID, !isClosed else { return }
        withObservationTracking {
            _ = model.space(id: spaceID)?.theme
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                if let model = self.model, let id = self.spaceID, model.space(id: id) == nil { self.close(); return }
                self.synchronizeFromModel(); self.observeTheme()
            }
        }
    }
    private func synchronizeFromModel() {
        guard let model, let spaceID, let theme = model.space(id: spaceID)?.theme, theme != lastWritten else { return }
        pendingPreview = false; pendingFinish = false; liveGesture = false; lastWritten = theme; baseline = theme
        let page = state.presetPage
        state = ThemeEditorState(style: SpaceStyle.seed(from: theme)); state.presetPage = page
        baselineState = state
        session?.restored(theme)
        renderState()
    }
    fileprivate func restoreEditor(_ snapshot: EditorUndoSnapshot) {
        guard !isClosed else { return }
        pendingPreview = false; pendingFinish = false; liveGesture = false
        state = snapshot.state; baselineState = state
        baseline = snapshot.theme; lastWritten = snapshot.theme
        session?.restored(snapshot.theme, publish: false)
        renderState()
    }
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for (name, object) in [(NSApplication.didResignActiveNotification, nil),
                               (NSApplication.willTerminateNotification, nil),
                               (NSWindow.willCloseNotification, ownerWindow)] as [(Notification.Name, Any?)] {
            lifecycleObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        lifecycleObservers.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: ownerWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let owner = self.ownerWindow else { return }
                self.panel.renderScale = owner.backingScaleFactor
            }
        })
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close() }
            }
            return event
        }
    }
    fileprivate func publishRestoredTheme() {
        guard !isClosed, let model, let id = spaceID, model.space(id: id) != nil else { return }
        session?.registry.publish(id)
    }
    private func announceCount() {
        NSAccessibility.post(element: panel.editorView.pad, notification: .announcementRequested,
                             userInfo: [.announcement: "\(state.style?.colorCount ?? 0) colors", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func animateOpen() {
        guard let layer = panel.editorView.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = Motion.editorFade
        layer.add(fade, forKey: "editor-open-fade")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spring = Motion.editorOpen.animation(keyPath: "transform")
            var start = CATransform3DMakeTranslation(-panel.editorView.bounds.width * 0.17, -panel.editorView.bounds.height * 0.17, 0)
            start = CATransform3DScale(start, 0.66, 0.66, 1)
            spring.fromValue = NSValue(caTransform3D: start); spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            layer.add(spring, forKey: "editor-open-scale")
        }
    }
}

@MainActor private final class EditorFrameTarget: NSObject {
    weak var owner: ThemeEditorController?
    init(owner: ThemeEditorController) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.flushPreviewFrame() }
}

fileprivate struct EditorUndoSnapshot {
    var state: ThemeEditorState
    var theme: SpaceTheme
}

@MainActor private final class EditorUndoRelay: NSObject {
    weak var controller: ThemeEditorController?
    var onModelRestore: (@MainActor () -> Void)?
    let onRestore: (@MainActor (SpaceStyle?) -> Void)?
    init(onRestore: (@MainActor (SpaceStyle?) -> Void)?) { self.onRestore = onRestore }
    func record(manager: UndoManager, from old: EditorUndoSnapshot, to new: EditorUndoSnapshot) {
        let group = !manager.groupsByEvent && manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        if group { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { [weak manager] relay in
            MainActor.assumeIsolated {
                // The draft callback may close or release the editor. Resolve
                // the weak controller only afterwards; closed editors ignore it.
                relay.onRestore?(old.state.style); relay.controller?.restoreEditor(old)
                relay.onModelRestore?()
                // Undo restores editor state before the model. Publish only after
                // the full undo group has restored the model's theme.
                Task { @MainActor [weak controller = relay.controller] in
                    guard let controller, !controller.isClosed else { return }
                    controller.publishRestoredTheme()
                }
                if let manager { relay.record(manager: manager, from: new, to: old) }
            }
        }
        if group { manager.endUndoGrouping() }
    }
}
