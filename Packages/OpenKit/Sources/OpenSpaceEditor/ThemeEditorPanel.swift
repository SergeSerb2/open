import AppKit
import OpenDesign
import OpenModel

public enum ThemeEditorAnchor {
    case sidebarTrailingEdge(sidebarFrameInWindow: CGRect)
    case card(CGRect)
}

@MainActor
public final class ThemeEditorPanel: NSPanel {
    var editorUndoManager: UndoManager?
    var undoProvider: (@MainActor () -> UndoManager?)?
    public var onEscape: (@MainActor () -> Void)?
    public var beforeUndo: (@MainActor () -> Void)?
    public var renderScale: CGFloat? { didSet { editorView.renderScale = renderScale ?? backingScaleFactor } }
    public var backdrop: RGBA? { didSet { updateBackdrop() } }
    public let editorView = ThemeEditorContentView(frame: CGRect(origin: .zero, size: ThemeEditorMetrics.panelSize))
    private let material = NSVisualEffectView()
    private var appliedMode: SpaceStyleAppearance?

    public init() {
        super.init(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: ThemeEditorMetrics.panelSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        acceptsMouseMovedEvents = true
        isFloatingPanel = false; hasShadow = true; isOpaque = false; backgroundColor = .clear
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        contentView = editorView
        editorView.wantsLayer = true
        editorView.content.layer?.cornerRadius = 20; editorView.content.layer?.cornerCurve = .continuous
        editorView.content.layer?.masksToBounds = true
        material.material = PopoverMaterial.material; material.blendingMode = .behindWindow; material.state = .active
        material.frame = CGRect(origin: .zero, size: ThemeEditorMetrics.contentSize); material.autoresizingMask = [.width, .height]
        editorView.content.addSubview(material, positioned: .below, relativeTo: editorView.pad)
        setAccessibilityRole(.popover); setAccessibilityLabel("Edit Theme")
    }
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public func applyAppearance(_ mode: SpaceStyleAppearance) {
        guard appliedMode != mode else { return }; appliedMode = mode
        switch mode {
        case .automatic: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
    }
    public override var backingScaleFactor: CGFloat { renderScale ?? super.backingScaleFactor }
    public override var undoManager: UndoManager? {
        if let undoProvider { return undoProvider() }
        return editorUndoManager ?? parent?.undoManager
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
    public override func cancelOperation(_ sender: Any?) { onEscape?() }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            beforeUndo?()
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc public func undo(_ sender: Any?) { beforeUndo?(); undoManager?.undo() }
    @objc public func redo(_ sender: Any?) { beforeUndo?(); undoManager?.redo() }

    private func updateBackdrop() {
        material.isHidden = backdrop != nil
        editorView.content.layer?.backgroundColor = backdrop?.cgColor
    }
}

@MainActor
public final class ThemeEditorContentView: NSView {
    public let content: NSView = EditorFlippedView()
    public let pad = ColorPadView(frame: ThemeEditorMetrics.pad)
    public let modes = AppearanceModeBar(frame: ThemeEditorMetrics.modeBar)
    public let remove = ThemeEditorButton(symbol: "minus", label: "Remove color", pointSize: 16, weight: .semibold, glyphOffset: CGSize(width: 0, height: 1))
    public let add = ThemeEditorButton(symbol: "plus", label: "Add color", pointSize: 16, weight: .semibold)
    public let presets = PresetStripView(frame: CGRect(x: 0, y: 364, width: 356, height: 32))
    public let intensity = SineSliderView(frame: ThemeEditorMetrics.intensity)
    public let noise = NoiseDialView(frame: ThemeEditorMetrics.noise)
    private var keyViews: [NSView] = []
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var layoutPassCount = 0
    public var renderScale: CGFloat = 1 { didSet { pad.renderScale = renderScale; noise.renderScale = renderScale; presets.renderScale = renderScale } }

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        content.wantsLayer = true
        (content as? EditorFlippedView)?.overflowSlider = intensity
        content.frame = CGRect(origin: CGPoint(x: 13, y: 13), size: ThemeEditorMetrics.contentSize)
        addSubview(content)
        let controls: [NSView] = [pad, modes, remove, add, presets, intensity, noise]
        for view in controls { content.addSubview(view) }
        remove.frame = ThemeEditorMetrics.remove; add.frame = ThemeEditorMetrics.add
        pad.onAction = { [weak self] in self?.onAction?($0) }
        modes.onSelect = { [weak self] in self?.onAction?(.setAppearance($0)) }
        remove.onPress = { [weak self] in self?.onAction?(.removeColor) }
        add.onPress = { [weak self] in self?.onAction?(.addColor) }
        presets.onAction = { [weak self] in self?.onAction?($0) }
        intensity.onChange = { [weak self] value, final in self?.onAction?(.setIntensity(value, final: final)) }
        noise.onAction = { [weak self] in self?.onAction?($0) }
        configureKeyViews()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout(); layoutPassCount += 1
        content.frame = CGRect(origin: CGPoint(x: 13, y: 13), size: ThemeEditorMetrics.contentSize)
    }
    public func apply(_ state: ThemeEditorState) {
        pad.apply(state); modes.mode = state.appearance
        remove.isHidden = false; add.isHidden = false
        remove.enabled = state.style != nil; add.enabled = state.style.map { $0.colorCount < 3 } ?? false
        presets.apply(page: state.presetPage)
        intensity.apply(value: state.style?.intensityFactor ?? 0.8, enabled: state.style != nil)
        noise.apply(value: state.style?.noiseFactor ?? 0, texture: state.style?.texture ?? .grain, enabled: state.style != nil)
        configureKeyViews()
    }
    public var controlFrames: [String: CGRect] {
        var result = ["pad": pad.frame, "remove": remove.frame, "add": add.frame]
        for (index, button) in modes.buttons.enumerated() {
            result[["automatic", "light", "dark"][index]] = content.convert(button.bounds, from: button)
        }
        if let frame = pad.primaryKnobFrame { result["knob"] = content.convert(frame, from: pad) }
        result["previous"] = content.convert(presets.previous.bounds, from: presets.previous)
        result["next"] = content.convert(presets.next.bounds, from: presets.next)
        result["swatches"] = content.convert(presets.viewport.bounds, from: presets.viewport)
        for (i, swatch) in presets.visibleSwatches.enumerated() { result["swatch-\(i)"] = content.convert(swatch.bounds, from: swatch) }
        result["intensity"] = intensity.frame; result["thumb"] = content.convert(intensity.thumbFrame, from: intensity)
        result["noise"] = noise.frame; result["noise-center"] = content.convert(noise.centerButton.bounds, from: noise.centerButton)
        return result
    }
    public func configureKeyViews(extra: [NSView] = []) {
        let all: [NSView] = modes.buttons + [pad, remove, add, presets.previous] + presets.visibleSwatches
            + [presets.next, intensity, noise.centerButton, noise] + extra
        let views = all.filter { !$0.isHidden && $0.acceptsFirstResponder && (($0 as? ThemeEditorButton)?.enabled ?? true) }
        guard views.count != keyViews.count || zip(views, keyViews).contains(where: { $0 !== $1 }) else { return }
        for old in keyViews { old.nextKeyView = nil }; keyViews = views
        for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
        if let focused = window?.firstResponder as? NSView, all.contains(where: { $0 === focused }),
           !views.contains(where: { $0 === focused }) { window?.makeFirstResponder(views.first) }
    }
    public func finishGestures() {
        pad.finishKeyboardGesture(); intensity.finishScrollGesture(); noise.finishScrollGesture()
    }
}

@MainActor private final class EditorFlippedView: NSView {
    weak var overflowSlider: SineSliderView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHidden, bounds.contains(local), let slider = overflowSlider, slider.enabled, !slider.isHidden,
           slider.displayedThumbFrame.contains(slider.convert(local, from: self)) { return slider }
        return super.hitTest(point)
    }
}
