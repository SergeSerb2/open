import AppKit

/// Inline editor for one text object: a TextKit 2 text view over the object's frame, with the
/// "+ / Aa / −" size control at its left (capture s4 `e2-text-editing`) and the placeholder
/// "Start typing to enter text" (`e2-text-focus`). Exists only while editing.
@MainActor
final class EaselTextEditor: NSView, NSTextViewDelegate {
    static let placeholder = "Start typing to enter text"
    let objectID: UUID
    weak var canvas: EaselCanvasView?
    /// The document before a brand-new box was added (nil when editing an existing one).
    var undoBase: EaselDocument?
    var style: EaselText
    let textView: EaselEditorTextView
    let placeholderLabel = NSTextField(labelWithString: EaselTextEditor.placeholder)
    let sizeControl = EaselSizeControl()

    init(objectID: UUID, canvas: EaselCanvasView) {
        self.objectID = objectID; self.canvas = canvas
        if case .text(let t)? = canvas.document.object(objectID)?.content { style = t } else { style = EaselText() }
        textView = EaselEditorTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.delegate = self
        textView.string = style.string
        textView.setAccessibilityLabel("Easel Text")
        textView.setAccessibilityPlaceholderValue(Self.placeholder)
        textView.onEscape = { [weak canvas] in canvas?.endTextEditing(commit: true) }
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        addSubview(placeholderLabel)
        addSubview(textView)
        addSubview(sizeControl)
        sizeControl.onAction = { [weak self] action in self?.sizeAction(action) }
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var scale: CGFloat { canvas?.scale ?? 1 }

    func applyStyle() {
        let dark = EaselStyle.dark(effectiveAppearance)
        let attrs = EaselTextMetrics.attributes(style, scale: scale, dark: dark)
        textView.typingAttributes = attrs
        textView.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        textView.insertionPointColor = EaselStyle.text(dark: dark)
        var placeholderAttrs = attrs
        placeholderAttrs[.foregroundColor] = EaselStyle.placeholder(dark: dark)
        placeholderLabel.attributedStringValue = NSAttributedString(string: Self.placeholder, attributes: placeholderAttrs)
        placeholderLabel.isHidden = !textView.string.isEmpty
        sizeControl.canGrow = style.paragraphStyle.larger != nil
        sizeControl.canShrink = style.paragraphStyle.smaller != nil
    }

    /// Text height in document points for the current width.
    var neededDocHeight: CGFloat {
        guard let canvas, let object = canvas.document.object(objectID) else { return 0 }
        let width = object.frame.width * scale - 2 * EaselTextMetrics.inset * scale
        let s = NSAttributedString(string: textView.string.isEmpty ? " " : textView.string,
                                   attributes: EaselTextMetrics.attributes(style, scale: scale, dark: false))
        let h = s.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return ceil(h / scale) + 4
    }

    func layoutIn(canvas: EaselCanvasView) {
        guard let object = canvas.document.object(objectID) else { return }
        var r = canvas.viewRect(object.frame)
        r.size.height = max(r.height, neededDocHeight * scale)
        let control = EaselSizeControl.size
        frame = CGRect(x: r.minX - control.width - 8, y: r.minY, width: r.width + control.width + 8, height: max(r.height, control.height))
        sizeControl.frame = CGRect(x: 0, y: 0, width: control.width, height: control.height)
        let inset = EaselTextMetrics.inset * scale
        let textFrame = CGRect(x: control.width + 8 + inset, y: 0, width: max(10, r.width - 2 * inset), height: r.height)
        textView.frame = textFrame
        textView.textContainer?.size = CGSize(width: textFrame.width, height: .greatestFiniteMagnitude)
        placeholderLabel.frame = textFrame
        applyStyle()
    }

    func textDidChange(_ notification: Notification) {
        placeholderLabel.isHidden = !textView.string.isEmpty
        if let canvas { layoutIn(canvas: canvas); canvas.updateSelectionChrome() }
    }

    func sizeAction(_ action: EaselSizeControl.Action) {
        switch action {
        case .larger: if let s = style.paragraphStyle.larger { style.paragraphStyle = s }
        case .smaller: if let s = style.paragraphStyle.smaller { style.paragraphStyle = s }
        case .family(let f): style.fontFamily = f
        }
        if let canvas { layoutIn(canvas: canvas) }
        window?.makeFirstResponder(textView)
    }
}

@MainActor
final class EaselEditorTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// Typing undo stays inside the box while it is open; committing is one canvas undo step.
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }
    @objc func undo(_ sender: Any?) { typingUndo.undo() }
    @objc func redo(_ sender: Any?) { typingUndo.redo() }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Vertical pill: "+", "Aa" (family menu), "−". Sizes GUESS — capture pending.
@MainActor
final class EaselSizeControl: NSView {
    enum Action { case larger, smaller, family(EaselFontFamily) }
    static let size = CGSize(width: 28, height: 84)
    var onAction: ((Action) -> Void)?
    var canGrow = true { didSet { plus.isEnabled = canGrow } }
    var canShrink = true { didSet { minus.isEnabled = canShrink } }
    private let plus = NSButton(title: "+", target: nil, action: nil)
    private let family = NSButton(title: "Aa", target: nil, action: nil)
    private let minus = NSButton(title: "−", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        shadow = { let s = NSShadow(); s.shadowBlurRadius = 6; s.shadowOffset = NSSize(width: 0, height: -1); s.shadowColor = NSColor(white: 0, alpha: 0.12); return s }()
        for (i, b) in [plus, family, minus].enumerated() {
            b.isBordered = false
            b.font = .systemFont(ofSize: i == 1 ? 12 : 16, weight: .semibold)
            b.target = self
            b.action = #selector(pressed(_:))
            b.frame = CGRect(x: 0, y: CGFloat(i) * 28, width: 28, height: 28)
            addSubview(b)
        }
        plus.setAccessibilityLabel("Larger Text"); minus.setAccessibilityLabel("Smaller Text"); family.setAccessibilityLabel("Text Style")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = EaselStyle.dark(effectiveAppearance)
        layer?.backgroundColor = EaselStyle.floating(dark: dark).cgColor
        for b in [plus, family, minus] { b.contentTintColor = EaselStyle.toolIcon(dark: dark) }
    }
    func button(_ which: String) -> NSView? { ["larger": plus, "family": family, "smaller": minus][which] }

    @objc private func pressed(_ sender: NSButton) {
        if sender === plus { onAction?(.larger) }
        else if sender === minus { onAction?(.smaller) }
        else {
            let menu = NSMenu()
            for f in EaselFontFamily.allCases {
                let item = NSMenuItem(title: f.title, action: #selector(pickFamily(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = f.rawValue
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: CGPoint(x: sender.frame.maxX, y: sender.frame.minY), in: self)
        }
    }
    @objc private func pickFamily(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let f = EaselFontFamily(rawValue: raw) { onAction?(.family(f)) }
    }
}

extension EaselFontFamily {
    /// Menu titles: Open's own names. GUESS — Arc's titles need capture.
    var title: String {
        switch self {
        case .clean: "Clean"
        case .mono: "Mono"
        case .fancy: "Fancy"
        case .hip: "Hip"
        }
    }
}
