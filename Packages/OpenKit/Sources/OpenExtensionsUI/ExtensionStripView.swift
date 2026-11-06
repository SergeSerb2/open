import AppKit
import OpenDesign
import OpenWeb

@MainActor public final class ExtensionStripView: NSView {
    public let style: ExtensionStripStyle
    public let context: ExtensionsUIContext
    public var tooltipStyle: SpaceThemeStyle? {
        didSet { buttons.forEach { $0.tooltipStyle = tooltipStyle }; moreButton.tooltipStyle = tooltipStyle }
    }
    public var hostTextWidth: CGFloat = 120 { didSet { if hostTextWidth != oldValue { needsLayout = true } } }
    public var isFocused = true { didSet { needsLayout = true; updateVisibility() } }
    public var hasPage = true { didSet { updateVisibility() } }
    public var hovered = false { didSet { updateVisibility() } }
    public var forcedVisibility: ExtensionsUIContext.ForcedVisibility = [] { didSet { updateVisibility() } }
    public private(set) var layoutCount = 0
    public private(set) var geometry: ExtensionStripLayout
    public private(set) var buttons: [ExtensionActionButton] = []
    public let moreButton = ExtensionsPlateButton(frame: .zero)
    private var pinned: [ExtensionActionInfo] = []
    private var dragID: String?
    private var dragIndex = 0
    private weak var priorResponder: NSResponder?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { dragID != nil }
    public init(style: ExtensionStripStyle, context: ExtensionsUIContext = ExtensionsUIContext()) {
        self.style = style; self.context = context
        geometry = ExtensionStripLayout(style: style, width: 0, pinnedCount: 0)
        super.init(frame: .zero)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        moreButton.glyph = .extensionsMore; moreButton.tooltipTitle = "More Extensions"
        moreButton.contentTintColor = SidebarRole.toolbarGlyph.nsColor
        moreButton.setAccessibilityLabel("More Extensions"); moreButton.setAccessibilityIdentifier("extensions.more")
        moreButton.target = self; moreButton.action = #selector(openOverflow)
        addSubview(moreButton)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    /// Structural changes alone relayout. Per-action badge/title/image events touch one button.
    @discardableResult public func setActions(_ actions: [ExtensionActionInfo]) -> Bool {
        guard context.setActions(actions) else { return false }
        let next = ExtensionsUIContext.ordered(actions).filter(\.isPinned)
        let structure = next.map(\.id) != pinned.map(\.id)
        pinned = next
        if structure {
            cancelOperation(nil)
            buttons.forEach { $0.removeFromSuperview() }
            buttons = next.map { action in
                let b = ExtensionActionButton(action: action); b.tooltipStyle = tooltipStyle
                b.onIntent = { [weak self, weak b] intent in
                    guard let self, let b else { return }
                    switch intent {
                    case let .run(id, source): self.context.run?(id, source, b)
                    case .closePopup: self.context.closePopup?()
                    case let .contextMenu(id, event): self.context.contextMenu?(id, b, event)
                    }
                }
                b.onDrag = { [weak self, weak b] event, begins in if let b { self?.drag(b, event: event, begins: begins) } }
                b.onDragEnd = { [weak self] event in self?.drop(event) }
                addSubview(b); return b
            }
            needsLayout = true
        } else { for (button, action) in zip(buttons, next) { if button.action != action { button.update(action) } } }
        updateVisibility(); return true
    }
    public func updateAction(_ value: ExtensionActionInfo) {
        guard ExtensionsUIContext.accepts([value]), context.actions.contains(where: { $0.id == value.id }) else { return }
        // Another strip may already have updated the shared context. Compare with
        // this strip's rendered structure so every host applies pin/order changes.
        let old = pinned.first(where: { $0.id == value.id })
        if (old != nil) != value.isPinned || (value.isPinned && old?.pinnedIndex != value.pinnedIndex) {
            var actions = context.actions
            guard let i = actions.firstIndex(where: { $0.id == value.id }) else { return }
            actions[i] = value; _ = setActions(actions)
        } else {
            _ = context.updateAction(value)
            if let i = pinned.firstIndex(where: { $0.id == value.id }) { pinned[i] = value; buttons[i].update(value) }
        }
    }
    public override func layout() {
        super.layout(); layoutCount += 1
        geometry = ExtensionStripLayout(style: style, width: bounds.width, pinnedCount: pinned.count, hostTextWidth: hostTextWidth, focused: isFocused)
        for (i, b) in buttons.enumerated() {
            b.isHidden = i >= geometry.actionFrames.count
            if i < geometry.actionFrames.count { b.frame = geometry.actionFrames[i] }
        }
        moreButton.isHidden = geometry.moreFrame == nil
        if let f = geometry.moreFrame { moreButton.frame = f }
        updateVisibility()
    }
    public func updateVisibility() {
        // App sets .popup on the anchor strip. A popup elsewhere must not reveal this strip.
        let forced = !forcedVisibility.union(context.forcedVisibility).isEmpty || dragID != nil
        let visible = hasPage && (style != .paneBar || isFocused) && (style != .urlField || hovered || forced)
        for (i, b) in buttons.enumerated() {
            b.isHidden = !visible || i >= geometry.actionFrames.count; b.setAccessibilityElement(!b.isHidden)
            if b.isHidden { b.setHovered(false, animated: false); TooltipController.shared.cancel(for: b) }
        }
        moreButton.isHidden = !visible || geometry.moreFrame == nil
        if moreButton.isHidden { TooltipController.shared.cancel(for: moreButton) }
        moreButton.setAccessibilityElement(!moreButton.isHidden)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point); return hit === self ? nil : hit
    }
    @objc private func openOverflow() { context.overflow?(Array(pinned.dropFirst(geometry.actionFrames.count)), moreButton) }
    private func drag(_ b: ExtensionActionButton, event: NSEvent, begins: Bool) {
        if begins {
            dragID = b.action.id; priorResponder = window?.firstResponder; window?.makeFirstResponder(self)
            forcedVisibility.insert(.drag)
        }
        guard dragID == b.action.id, !geometry.actionFrames.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil), frames = geometry.actionFrames
        dragIndex = min(frames.count - 1, max(0, Int(((p.x - frames[0].minX) / ExtensionsMetrics.pitch).rounded(.down))))
        let others = buttons.prefix(frames.count).filter { $0 !== b }
        var destinations = frames; destinations.remove(at: dragIndex)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (other, f) in zip(others, destinations) {
            let from = other.layer?.presentation()?.position ?? other.layer?.position
            other.frame = f
            if !Motion.reducesMotion, let from, let layer = other.layer {
                let a = CABasicAnimation(keyPath: "position"); a.fromValue = from; a.toValue = layer.position
                a.duration = Motion.rowStructure; a.timingFunction = Motion.easeOut; layer.add(a, forKey: "reorder")
            }
        }
        b.frame.origin.x = p.x - b.frame.width / 2
        CATransaction.commit()
    }
    private func drop(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = geometry.frames.reduce(CGRect.null) { $0.union($1) }.contains(point)
        let id = dragID, index = dragIndex
        cancelOperation(nil)
        if inside, let id { context.movePinned?(id, index) }
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    public override func cancelOperation(_ sender: Any?) {
        guard dragID != nil else { return }
        dragID = nil; forcedVisibility.remove(.drag)
        buttons.forEach { $0.cancelDrag(); $0.layer?.removeAnimation(forKey: "reorder") }
        needsLayout = true; layoutSubtreeIfNeeded()
        if let priorResponder { window?.makeFirstResponder(priorResponder) }
    }
}
