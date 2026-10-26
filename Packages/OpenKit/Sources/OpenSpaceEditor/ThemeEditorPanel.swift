import AppKit
import OpenDesign
import OpenModel

public enum ThemeEditorAnchor {
    case sidebarTrailingEdge(sidebarFrameInWindow: CGRect)
    case card(CGRect)
}

@MainActor
public final class ThemeEditorPanel: NSPanel {
    public var editorUndoManager: UndoManager?
    public var onEscape: (@MainActor () -> Void)?
    public var beforeUndo: (@MainActor () -> Void)?
    public var renderScale: CGFloat? { didSet { editorView.renderScale = renderScale ?? backingScaleFactor } }
    public var backdrop: RGBA? { didSet { updateBackdrop() } }
    public let editorView = ThemeEditorContentView(frame: CGRect(origin: .zero, size: ThemeEditorMetrics.panelSize))
    private let material = NSVisualEffectView()

    public init() {
        super.init(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: ThemeEditorMetrics.panelSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = false; hasShadow = true; isOpaque = false; backgroundColor = .clear
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        contentView = editorView
        editorView.wantsLayer = true; editorView.layer?.cornerRadius = 16; editorView.layer?.masksToBounds = true
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.frame = editorView.bounds; material.autoresizingMask = [.width, .height]
        editorView.addSubview(material, positioned: .below, relativeTo: editorView.content)
        setAccessibilityRole(.popover); setAccessibilityLabel("Edit Theme")
    }
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var backingScaleFactor: CGFloat { renderScale ?? super.backingScaleFactor }
    public override var undoManager: UndoManager? { editorUndoManager ?? parent?.undoManager }
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
        editorView.layer?.backgroundColor = backdrop?.cgColor
    }
}

@MainActor
public final class ThemeEditorContentView: NSView {
    public let content: NSView = EditorFlippedView()
    public let pad = ColorPadView(frame: ThemeEditorMetrics.pad)
    public let modes = AppearanceModeBar(frame: ThemeEditorMetrics.modeBar)
    public let remove = ThemeEditorButton(symbol: "minus", label: "Remove color")
    public let add = ThemeEditorButton(symbol: "plus", label: "Add color", pointSize: 17, glyphColor: ThemeEditorColors.addGlyph)
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var layoutPassCount = 0
    public var renderScale: CGFloat = 1 { didSet { pad.renderScale = renderScale } }

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        content.wantsLayer = true; addSubview(content)
        let controls: [NSView] = [pad, modes, remove, add]
        for view in controls { content.addSubview(view) }
        remove.frame = ThemeEditorMetrics.remove; add.frame = ThemeEditorMetrics.add
        pad.onAction = { [weak self] in self?.onAction?($0) }
        modes.onSelect = { [weak self] in self?.onAction?(.setAppearance($0)) }
        remove.onPress = { [weak self] in self?.onAction?(.removeColor) }
        add.onPress = { [weak self] in self?.onAction?(.addColor) }
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
        remove.isHidden = state.style == nil; add.isHidden = state.style == nil
        remove.enabled = state.style != nil; add.enabled = state.style.map { $0.colorCount < 3 } ?? false
    }
    public var controlFrames: [String: CGRect] {
        var result = ["pad": pad.frame, "remove": remove.frame, "add": add.frame]
        for (index, button) in modes.buttons.enumerated() {
            result[["automatic", "light", "dark"][index]] = content.convert(button.bounds, from: button)
        }
        if let frame = pad.primaryKnobFrame { result["knob"] = content.convert(frame, from: pad) }
        return result
    }
    public func configureKeyViews(extra: [NSView] = []) {
        let views: [NSView] = modes.buttons + [pad, remove, add] + extra
        for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
    }
}

@MainActor private final class EditorFlippedView: NSView {
    override var isFlipped: Bool { true }
}
