import AppKit
import OpenDesign

/// Text field cell that hands out the bar's own field editor and sets its caret and
/// selection colors each time editing starts (`NSTextField` resets them on its editor).
final class CommandBarTextFieldCell: NSTextFieldCell {
    weak var editor: NSTextView?
    var selectionColor: NSColor = .selectedTextBackgroundColor
    var selectedTextColor: NSColor = .textColor

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor ?? super.fieldEditor(for: controlView) }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        if let view = text as? NSTextView { apply(to: view) }
        return text
    }

    func apply(to view: NSTextView) {
        view.insertionPointColor = .controlAccentColor
        view.selectedTextAttributes = [.backgroundColor: selectionColor, .foregroundColor: selectedTextColor]
    }
}

/// The input: 18 Medium, no bezel, no focus ring (interaction-states §9.2).
final class CommandBarTextField: NSTextField {
    private var drawnPlaceholder: String?
    override var placeholderString: String? {
        get { drawnPlaceholder }
        // InputRowView paints this placeholder. Keep the field's public value for AX
        // without enabling a second placeholder in NSTextFieldCell/the field editor.
        set { drawnPlaceholder = newValue }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textField }
    override func accessibilityLabel() -> String? { placeholderString }
    override func accessibilityPlaceholderValue() -> String? { placeholderString }
    override class var cellClass: AnyClass? {
        get { CommandBarTextFieldCell.self }
        set {}
    }
}

/// The bar's field editor. Its own instance, so the window's shared editor keeps its settings.
/// TextKit 1: its selection takes `selectedTextAttributes` whenever its window is key.
final class CommandBarFieldEditor: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }
    private var compositionDepth = 0
    var isUpdatingComposition: Bool { compositionDepth > 0 }
    var onCompositionEnded: (() -> Void)?
    var onHelp: (() -> Bool)?

    // Inline completion hooks (CompletionSession, commandbar-completion §4.1.5–§4.1.6).

    /// What the last text-system edit was. Only an insertion at the end of the text allows a completion.
    enum EditKind { case insertionAtEnd, insertion, deletion, paste, undo }
    private(set) var lastEdit = EditKind.insertion
    /// Runs before typing, an IME change, or a paste, with the typed text (nil for IME and paste) and the
    /// range it replaces. Removes the completion (all of it, or only the part the typed text replaces)
    /// so the edit lands on what the user typed and the completion never enters undo.
    var onBeforeEdit: ((_ insertion: String?, _ replacing: NSRange) -> CompletionEdit)?
    enum CompletionEdit {
        /// No completion showed.
        case none
        /// The completion at this range was removed; the field holds what the user typed.
        case removed(NSRange)
        /// The typed text continues the completion: only its first characters were removed. The insertion
        /// goes at `location`, and `tail` UTF-16 units of completion stay after it (no hide-then-show write).
        case kept(location: Int, tail: Int)
    }
    /// During a `.kept` insertion: completion text after the caret, which is not part of the typed text.
    private(set) var keptTail = 0
    /// Runs before undo or redo, for the same reason.
    var onBeforeUndo: (() -> Void)?
    /// The selection or caret moved (keys, a click, select all, or our own writes).
    var onSelectionChange: (() -> Void)?
    private var pasteDepth = 0
    private var observesUndo = false

    /// Starts reporting undo and redo. Called once the editor exists.
    func observeUndo() {
        guard !observesUndo else { return }
        observesUndo = true
        for name in [NSNotification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(willUndoOrRedo(_:)), name: name, object: editingUndoManager)
        }
    }

    @objc private func willUndoOrRedo(_ note: Notification) { onBeforeUndo?() }

    /// An edit replacing `range` with the completion just removed keeps its meaning: replace the selection.
    private func editRange(_ range: NSRange, hidden: NSRange?) -> NSRange {
        guard range.location != NSNotFound, let hidden else { return range }
        if NSEqualRanges(range, hidden) || NSMaxRange(range) > (string as NSString).length { return NSRange(location: NSNotFound, length: 0) }
        return range
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onSelectionChange?()
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        _ = onBeforeEdit?(nil, NSRange(location: NSNotFound, length: 0))
        pasteDepth += 1
        defer { pasteDepth -= 1 }
        return super.readSelection(from: pboard, type: type)
    }

    static func normalized(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").prefix(2_048))
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let length = (string as NSString).length
        if pasteDepth > 0 { lastEdit = .paste }
        else if editingUndoManager.isUndoing || editingUndoManager.isRedoing { lastEdit = .undo }
        else if (replacementString ?? "").isEmpty { lastEdit = .deletion }
        else { lastEdit = NSMaxRange(affectedCharRange) == length - keptTail ? .insertionAtEnd : .insertion }
        guard let replacementString, NSMaxRange(affectedCharRange) <= (string as NSString).length else {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        let proposed = (string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        let clean = Self.normalized(proposed)
        guard clean != proposed else { return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) }
        // Re-enter the normal editing path with the bounded single line. The field and
        // the query then receive the same text, including paste and multi-character input.
        insertText(clean, replacementRange: NSRange(location: 0, length: (string as NSString).length))
        return false
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Marked text never shows a completion (§4.1.6): remove it first, with no query.
        var range = replacementRange
        if !hasMarkedText(), case .removed(let hidden) = onBeforeEdit?(nil, replacementRange) ?? .none { range = editRange(range, hidden: hidden) }
        compositionDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: range)
        compositionDepth -= 1
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        compositionDepth += 1
        super.unmarkText()
        compositionDepth -= 1
        if wasMarked, compositionDepth == 0 { onCompositionEnded?() }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        var range = replacementRange
        if !wasMarked {
            let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
            switch onBeforeEdit?(typed, replacementRange) ?? .none {
            case .none: break
            case .removed(let hidden): range = editRange(range, hidden: hidden)
            case .kept(let location, let tail): range = NSRange(location: location, length: 0); keptTail = tail
            }
        }
        if wasMarked { compositionDepth += 1 }
        super.insertText(insertString, replacementRange: range)
        keptTail = 0
        if wasMarked {
            compositionDepth -= 1
            if compositionDepth == 0 { onCompositionEnded?() }
        }
    }

    func resetSession() {
        compositionDepth += 1
        unmarkText()
        undoManager?.removeAllActions()
        compositionDepth -= 1
    }

    var onShiftDelete: ((NSEvent.ModifierFlags) -> Bool)?
    var onModifiedReturn: ((NSEvent.ModifierFlags) -> Bool)?
    private func handleHelpKey(_ event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command), !hasMarkedText(), !isUpdatingComposition, onModifiedReturn?(event.modifierFlags) == true { return true }
        if !hasMarkedText(), !isUpdatingComposition,
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "i", onHelp?() == true { return true }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleHelpKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
           !hasMarkedText(), !isUpdatingComposition, onShiftDelete?(event.modifierFlags) == true { return }
        if !handleHelpKey(event) { super.keyDown(with: event) }
    }
}

/// The input row: leading icon, optional Site Search chip, text field, and the
/// trailing (i) button or Site Search hint.
@MainActor
final class InputRowView: NSView {
    let field = CommandBarTextField(frame: .zero)
    let editor = CommandBarFieldEditor(usingTextLayoutManager: false)
    let infoButton = InfoButton(frame: .zero)
    let closeButton = EmbeddedCloseButton(frame: .zero)
    var embedded = false { didSet { needsLayout = true } }
    var input = CommandBarInput(placeholder: CommandBarText.placeholder, leadingIcon: .symbol("magnifyingglass", plate: false)) {
        didSet {
            guard input != oldValue else { return }
            if input.leadingIcon != oldValue.leadingIcon { iconView.needsDisplay = true }
            if input.chip != oldValue.chip {
                chipView.needsDisplay = true
                if (input.chip == nil) != (oldValue.chip == nil) { applyFieldFont() }
            }
            if input.trailing != oldValue.trailing { hintView.needsDisplay = true }
            if input.placeholder != oldValue.placeholder { placeholderView.needsDisplay = true }
            updatePlaceholder()
            needsLayout = true
        }
    }
    var theme = CommandBarTheme.default {
        didSet {
            guard theme != oldValue else { return }
            applyEditorColors()
            infoButton.theme = theme
            chipView.needsDisplay = true
            iconView.needsDisplay = true
            placeholderView.needsDisplay = true
            hintView.needsDisplay = true
        }
    }
    /// New Tab card (input 64, 19 pt) or inline editor (input 50, 15 pt), plan D3 §2.1–§2.2.
    var layoutSpec = CommandCardLayout.newTab {
        didSet {
            guard layoutSpec != oldValue else { return }
            applyFieldFont(); iconView.needsDisplay = true; needsLayout = true
        }
    }
    var extensionIcon: (@MainActor (String) -> NSImage?)? { didSet { iconView.needsDisplay = true; chipView.needsDisplay = true } }
    weak var favicons: CommandBarFaviconSource?
    /// While the privacy footer shows, the (i) button hides and the field takes its place (CC-42).
    var showsFooter = false { didSet { if showsFooter != oldValue { needsLayout = true } } }
    private var showsInfoButton: Bool { !embedded && input.trailing == .info && !showsFooter }

    /// Each drawn part is its own small view, so a keystroke redraws only what changed.
    private let iconView = PaintView(frame: .zero)
    private let chipView = PaintView(frame: .zero)
    let chipHit = ChipHitView(frame: .zero)
    private let hintView = PaintView(frame: .zero)
    /// The placeholder is ours, not the field's: the field editor keeps the placeholder it had
    /// when editing began, so a Site Search placeholder would not show.
    private let placeholderView = PaintView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [iconView, chipView, hintView, placeholderView] { addSubview(v) }
        addSubview(chipHit)
        chipHit.onHover = { [weak self] on in self?.chipHovered = on }
        chipHit.onClose = { [weak self] in self?.onChipClose?() }
        placeholderView.paint = { [weak self] ctx in
            guard let self else { return }
            let font = self.fieldFont
            let color = self.theme.secondaryText.cgColor
            let line = TextLine(self.input.placeholder, font: font, color: color)
            let f = self.placeholderView.frame
            line.truncated(to: f.width, font: font, color: color)
                .draw(at: f.minX, baseline: self.textBaseline, in: ctx)
        }
        iconView.paint = { [weak self] ctx in self?.drawLeadingIcon(in: ctx) }
        chipView.paint = { [weak self] ctx in
            guard let self, let chip = self.input.chip else { return }
            self.drawChip(chip, in: ctx)
        }
        hintView.paint = { [weak self] ctx in
            guard let self, case .siteSearchHint(let name, let space) = self.input.trailing else { return }
            self.drawHint(name: name, space: space, right: self.bounds.width - self.layoutSpec.inputPaddingRight, in: ctx)
        }
        (field.cell as? CommandBarTextFieldCell)?.editor = editor
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BarFont.input(layoutSpec.inputFontSize)
        field.textColor = theme.text.nsColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        updatePlaceholder()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        // URLs and queries: no spelling, grammar, completion, replacement, or data detection
        // (each also costs work on every keystroke).
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.enabledTextCheckingTypes = 0
        // No system inline predictions or math results next to our own completion and calculator row,
        // and no Writing Tools: each also runs text checking on every selection change.
        editor.inlinePredictionType = .no
        editor.mathExpressionCompletionType = .no
        editor.writingToolsBehavior = .none
        applyEditorColors()
        addSubview(field)
        infoButton.theme = theme
        addSubview(infoButton)
        closeButton.isHidden = true; addSubview(closeButton)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Command Bar Input" }
    override func accessibilityChildren() -> [Any]? {
        embedded ? [field, closeButton] : showsInfoButton ? [field, infoButton] : [field]
    }

    private func updatePlaceholder() {
        field.placeholderString = input.placeholder
    }

    /// Caret: the system accent (#007AFF, F0063). Selection: the theme's `dark.subtitle` (F0048).
    private func applyEditorColors() {
        guard let cell = field.cell as? CommandBarTextFieldCell else { return }
        cell.selectionColor = theme.textSelection.nsColor
        cell.selectedTextColor = theme.text.nsColor
        cell.apply(to: editor)
        field.textColor = theme.text.nsColor
        editor.textColor = theme.text.nsColor
    }

    /// Replaces the text (Site Search clears the trigger word); the caret goes to the end.
    func setText(_ text: String) {
        let clean = CommandBarFieldEditor.normalized(text)
        field.stringValue = clean
        field.currentEditor()?.selectedRange = NSRange(location: (clean as NSString).length, length: 0)
        textDidChange()
    }

    /// Shows the placeholder while the text is empty.
    func textDidChange() {
        let empty = field.stringValue.isEmpty
        if placeholderView.isHidden == empty { placeholderView.isHidden = !empty }
    }

    // MARK: Layout

    /// Text field origin inside the AX frame. fitted: AppKit insets the text 2 pt in a borderless field.
    static let fieldOffset = CGPoint(x: -2, y: 1)

    /// 19 Regular (New Tab) or 15 Regular (inline), scope or not (plan D3 §2.1).
    var fieldFont: NSFont { BarFont.input(layoutSpec.inputFontSize) }
    /// The field's text frame: one line of `fieldFont`, centred in the row.
    var fieldHeight: CGFloat { ceil(fieldFont.ascender - fieldFont.descender + fieldFont.leading) + 1 }
    /// Text baseline in row points (the placeholder uses the field's own baseline).
    var textBaseline: CGFloat { field.frame.minY + Self.fieldOffset.y + fieldFont.ascender.rounded() }

    private func applyFieldFont() {
        field.font = fieldFont
        editor.font = fieldFont
        editor.typingAttributes[.font] = fieldFont
        placeholderView.needsDisplay = true
    }

    var chipWidth: CGFloat {
        guard let chip = input.chip else { return 0 }
        let m = CommandBarMetrics.self
        return (TextLine(chip.name, font: BarFont.chip, color: CGColor(gray: 1, alpha: 1)).width).rounded() + 2 * m.chipPaddingX
            + (chipHovered ? m.chipCloseGrowth : 0) + (chip.extensionID == nil ? 0 : 20)
    }

    var trailingWidth: CGFloat {
        let m = CommandBarMetrics.self, l = layoutSpec
        if embedded { return m.infoButtonSize + m.infoButtonTrailing }
        switch input.trailing {
        case .info: return CommandCard.infoDiameter + l.inputPaddingRight - (showsFooter ? m.footerFieldGrowth : 0)
        case .siteSearchHint(let name, let space): return Self.hintWidth(name: name, space: space) + l.inputPaddingRight
        case .none: return l.inputPaddingRight
        }
    }

    override func layout() {
        super.layout()
        let m = CommandBarMetrics.self, l = layoutSpec
        var x = l.textX
        if input.chip != nil { x = chipRect.maxX + m.chipToText }
        let right = bounds.width - trailingWidth - l.inputGap
        let h = fieldHeight
        // AX frame [54, 20.5, 656, 23] in Arc08 at 19 pt: the field's text starts 2 pt inside it.
        field.frame = CGRect(x: x + Self.fieldOffset.x, y: ((bounds.height - h) / 2).rounded(.down), width: max(20, right - x), height: h)
        closeButton.isHidden = !embedded
        closeButton.frame = m.littleOpenCloseFrame(width: bounds.width)
        infoButton.isHidden = !showsInfoButton
        let d = CommandCard.infoDiameter
        infoButton.frame = CGRect(x: bounds.width - l.inputPaddingRight - d, y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
        iconView.frame = leadingIconFrame
        // Same origin as the field's text: the field's frame plus the text container's 2 pt padding.
        placeholderView.frame = CGRect(x: field.frame.minX + 2, y: 0, width: max(0, field.frame.width - 4), height: bounds.height)
        textDidChange()
        chipView.isHidden = input.chip == nil
        // The view also holds the glow around the capsule.
        chipView.frame = chipRect.insetBy(dx: -2 * m.chipGlowBlur, dy: -2 * m.chipGlowBlur)
        chipHit.isHidden = input.chip == nil
        chipHit.frame = chipRect
        chipHit.title = input.chip?.name ?? ""
        if input.chip == nil, chipHovered { chipHovered = false }
        if case .siteSearchHint(let name, let space) = input.trailing, !embedded {
            let w = ceil(Self.hintWidth(name: name, space: space))
            hintView.isHidden = false
            hintView.frame = CGRect(x: bounds.width - l.inputPaddingRight - w, y: ((bounds.height - m.keycapHeight) / 2).rounded(), width: w, height: m.keycapHeight)
        } else {
            hintView.isHidden = true
        }
    }

    var chipRect: CGRect {
        let m = CommandBarMetrics.self
        return CGRect(x: layoutSpec.textX - 2, y: ((bounds.height - m.chipHeight) / 2).rounded(), width: chipWidth, height: m.chipHeight)
    }

    /// Leading icon: 18 pt (New Tab) or 16 pt (inline) after the left padding, centred.
    var leadingIconFrame: CGRect {
        let l = layoutSpec
        return CGRect(x: l.inputPaddingLeft, y: ((bounds.height - l.inputIconSize) / 2).rounded(), width: l.inputIconSize, height: l.inputIconSize)
    }

    // MARK: Drawing (row coordinates; each part view translates to its frame)

    private func drawLeadingIcon(in ctx: CGContext) {
        let f = leadingIconFrame
        switch input.leadingIcon {
        case .extension(let id):
            if let image = extensionIcon?(id) { image.drawFlipped(in: f.insetBy(dx: 1, dy: 1)) }
            else { drawSymbol("puzzlepiece.extension", in: f) }
        case .favicon(let url, let fallback):
            if let image = favicons?.favicon(for: url, loaded: { [weak self] _ in self?.iconView.needsDisplay = true }) {
                ctx.saveGState()
                let r = CommandCard.faviconRadius * f.width / 18
                ctx.addPath(CGPath(roundedRect: f, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
                image.drawFlipped(in: f)
                ctx.restoreGState()
            } else {
                drawSymbol(fallback, in: f)
            }
        case .symbol(let name, _):
            drawSymbol(name, in: f)
        case .emoji(let e):
            let s = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: 15)])
            let b = s.size()
            s.draw(at: NSPoint(x: f.midX - b.width / 2, y: f.midY - b.height / 2))
        case .split:
            drawSymbol("rectangle.split.2x1", in: f) // the controller passes a pane's icon; this is a fallback
        }
    }

    private func drawSymbol(_ name: String, in f: CGRect) {
        guard let image = SymbolCache.image(name, size: BarGlyph.inputSymbolSize, weight: BarGlyph.inputSymbolWeight, color: theme.secondaryText) else { return }
        let s = image.size
        image.drawFlipped(in: CGRect(x: (f.midX - s.width / 2).rounded(), y: (f.midY - s.height / 2 + BarGlyph.inputSymbolOffsetY).rounded(),
                                     width: s.width, height: s.height))
    }

    /// The scope chip (CC-41): an orange capsule with a soft glow and the white title, no icon. Hovered,
    /// an `xmark.circle.fill` takes the left padding and the title moves right (guess).
    private func drawChip(_ chip: CommandBarInput.SiteChip, in ctx: CGContext) {
        let m = CommandBarMetrics.self
        let rect = chipRect
        let path = CGPath(roundedRect: rect, cornerWidth: m.chipRadius, cornerHeight: m.chipRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: m.chipGlowBlur, color: CommandBarRole.scopeChip.withAlpha(m.chipGlowAlpha).cgColor)
        ctx.setFillColor(CommandBarRole.scopeChip.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        var textX = rect.minX + m.chipPaddingX
        if chipHovered, let x = SymbolCache.image("xmark.circle.fill", size: m.chipCloseSize, weight: .semibold, color: .white(1)) {
            let s = x.size
            x.drawFlipped(in: CGRect(x: (textX + (m.chipCloseSize - s.width) / 2).rounded(), y: (rect.midY - s.height / 2).rounded(), width: s.width, height: s.height))
            textX += m.chipCloseGrowth
        }
        if let id = chip.extensionID {
            if let image = extensionIcon?(id) { image.drawFlipped(in: CGRect(x: textX, y: rect.midY - 8, width: 16, height: 16)) }
            else if let image = SymbolCache.image("puzzlepiece.extension", size: 14, color: .white(1)) { image.drawFlipped(in: CGRect(x: textX, y: rect.midY - 8, width: 16, height: 16)) }
            textX += 20 // guess (child): 4 pt after the specified 16 pt extension icon
        }
        let line = TextLine(chip.name, font: BarFont.chip, color: CGColor(gray: 1, alpha: 1))
        line.draw(at: textX, baseline: (rect.midY + BarFont.chip.capHeight / 2).rounded(), in: ctx)
    }

    /// The pointer is over the chip: it shows the close glyph; a click leaves the scope.
    var chipHovered = false { didSet { if chipHovered != oldValue { chipView.needsDisplay = true; needsLayout = true } } }
    var onChipClose: (() -> Void)?

    // MARK: Site Search hint

    static func hintWidth(name: String, space: Bool) -> CGFloat {
        let m = CommandBarMetrics.self
        let label = TextLine(CommandBarText.searchSite(name), font: BarFont.hint, color: CGColor(gray: 1, alpha: 1)).width
        var w = ceil(label) + m.hintLabelGap + Keycap.width(CommandBarText.tabKey, height: m.keycapHeight)
        if space {
            let or = TextLine(CommandBarText.or, font: BarFont.hint, color: CGColor(gray: 1, alpha: 1)).width
            w += 2 * m.hintKeyGap + ceil(or) + Keycap.width(CommandBarText.spaceKey, height: m.keycapHeight)
        }
        return w
    }

    /// "Search <Site> [Tab]" or "Search <Site> [Tab] or [Space]", right-aligned at `right` (F0061, F0040).
    private func drawHint(name: String, space: Bool, right: CGFloat, in ctx: CGContext) {
        let m = CommandBarMetrics.self
        var x = right - Self.hintWidth(name: name, space: space)
        let y = hintView.frame.minY
        let baseline = y + Self.hintBaseline
        let color = theme.secondaryText.cgColor
        let label = TextLine(CommandBarText.searchSite(name), font: BarFont.hint, color: color)
        label.draw(at: x, baseline: baseline, in: ctx)
        x += ceil(label.width) + m.hintLabelGap
        x += Keycap.draw(CommandBarText.tabKey, at: CGPoint(x: x, y: y), height: m.keycapHeight, plate: theme.plate, text: theme.secondaryText, in: ctx)
        if space {
            x += m.hintKeyGap
            let or = TextLine(CommandBarText.or, font: BarFont.hint, color: color)
            or.draw(at: x, baseline: baseline, in: ctx)
            x += ceil(or.width) + m.hintKeyGap
            Keycap.draw(CommandBarText.spaceKey, at: CGPoint(x: x, y: y), height: m.keycapHeight, plate: theme.plate, text: theme.secondaryText, in: ctx)
        }
    }

    /// Hint text baseline inside the 24 pt hint group: cap ink 555…564 in a group at 548 (F0061).
    static let hintBaseline: CGFloat = 17
    /// Placeholder baseline inside its frame (frame top = text field y − 2). fitted: cap ink at
    /// panel y 24 (F0063 "Search or Enter URL…" at 552 in a panel at 528).
    static let placeholderBaseline: CGFloat = 20
}

/// The (i) button: a round 24 pt button (Light white, Dark #1C1C1B) with a soft shadow (plan D3 §2.1).
@MainActor
final class InfoButton: NSView {
    var theme = CommandBarTheme.default { didSet { if theme != oldValue { applyFill(); needsDisplay = true } } }
    var action: (() -> Void)?
    private let circle = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false
        circle.shadowColor = CGColor(gray: 0, alpha: 1)
        circle.shadowOpacity = CommandCard.infoShadowOpacity
        circle.shadowRadius = CommandCard.infoShadowRadius
        circle.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "shadowPath": NSNull()]
        layer?.addSublayer(circle)
        applyFill()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Command Bar Help" }
    override func accessibilityHelp() -> String? { "Show how search suggestions use your search engine (Command-I)" }
    override func accessibilityPerformPress() -> Bool {
        guard !isHidden, let action else { return false }
        action()
        return true
    }

    private func applyFill() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.backgroundColor = theme.infoFill.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let d = CommandCard.infoDiameter
        circle.frame = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        circle.cornerRadius = d / 2
        circle.shadowPath = CGPath(ellipseIn: circle.bounds, transform: nil)
        // Flipped view: positive y is down.
        circle.shadowOffset = CGSize(width: 0, height: (layer?.isGeometryFlipped ?? false) ? -CommandCard.infoShadowOffsetY : CommandCard.infoShadowOffsetY)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = SymbolCache.image(BarGlyph.infoSymbol, size: BarGlyph.infoSize, weight: BarGlyph.infoWeight, color: theme.secondaryText) else { return }
        let s = image.size
        image.drawFlipped(in: CGRect(x: (bounds.midX - s.width / 2).rounded(), y: (bounds.midY - s.height / 2).rounded(), width: s.width, height: s.height))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func mouseDown(with event: NSEvent) {}
}

/// The scope chip's pointer target: hover shows the close glyph, a click leaves the scope (§4.3.4).
@MainActor
final class ChipHitView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var title = ""

    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseMoved(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityHelp() -> String? { "Leaves the scope" }
    override func accessibilityPerformPress() -> Bool { onClose?(); return true }
}

/// A view that paints with a closure in its superview's coordinates (flipped).
@MainActor
final class PaintView: NSView {
    var paint: ((CGContext) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        paint?(ctx)
        ctx.restoreGState()
    }
}


/// S2 19/0003: close in the embedded bar, with a small plate rather than the main bar's (i).
@MainActor
final class EmbeddedCloseButton: NSView {
    var action: (() -> Void)?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Close Little Open" }
    override func accessibilityPerformPress() -> Bool {
        guard !isHidden, let action else { return false }; action(); return true
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { _ = accessibilityPerformPress() }
    }
    override func draw(_ dirtyRect: NSRect) {
        CommandBarRole.plate.nsColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: LittleOpenMetrics.closePlateInset, dy: LittleOpenMetrics.closePlateInset), xRadius: LittleOpenMetrics.closePlateRadius, yRadius: LittleOpenMetrics.closePlateRadius).fill()
        if let image = SymbolCache.image("xmark", size: LittleOpenMetrics.closeGlyphSize, weight: .medium, color: CommandBarRole.infoGlyph) {
            image.drawFlipped(in: CGRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
        }
    }
}
