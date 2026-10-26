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
        isFloatingPanel = false; hasShadow = true; isOpaque = false; backgroundColor = .clear
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        contentView = editorView
        editorView.wantsLayer = true
        editorView.content.layer?.cornerRadius = 20; editorView.content.layer?.cornerCurve = .continuous
        editorView.content.layer?.masksToBounds = true
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
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
    private var keyViews: [NSView] = []
    public var onAction: (@MainActor (ThemeEditorAction) -> Void)?
    public private(set) var layoutPassCount = 0
    public var renderScale: CGFloat = 1 { didSet { pad.renderScale = renderScale } }

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        content.wantsLayer = true
        content.frame = CGRect(origin: CGPoint(x: 13, y: 13), size: ThemeEditorMetrics.contentSize)
        addSubview(content)
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
        remove.isHidden = false; add.isHidden = false
        remove.enabled = state.style != nil; add.enabled = state.style.map { $0.colorCount < 3 } ?? false
        configureKeyViews()
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
        let all: [NSView] = modes.buttons + [pad, remove, add] + extra
        let views = all.filter { !$0.isHidden && $0.acceptsFirstResponder && (($0 as? ThemeEditorButton)?.enabled ?? true) }
        guard views.count != keyViews.count || zip(views, keyViews).contains(where: { $0 !== $1 }) else { return }
        for old in keyViews { old.nextKeyView = nil }; keyViews = views
        for (index, view) in views.enumerated() { view.nextKeyView = views[(index + 1) % views.count] }
        if let focused = window?.firstResponder as? NSView, all.contains(where: { $0 === focused }),
           !views.contains(where: { $0 === focused }) { window?.makeFirstResponder(views.first) }
    }
    public func finishGestures() { pad.finishKeyboardGesture() }
}

@MainActor private final class EditorFlippedView: NSView {
    override var isFlipped: Bool { true }
}
