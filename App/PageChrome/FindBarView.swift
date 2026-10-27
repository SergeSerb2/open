import AppKit

/// Size/placement: app-shell §3.2. Colors and button spacing are Arc-like
/// guesses: the supplied Arc captures do not include the Find bar.
@MainActor
final class FindBarView: NSView {
  let field: NSSearchField
  private let editor = FindFieldEditor(usingTextLayoutManager: false)
  private let count = NSTextField(labelWithString: "")
  private let previous = PageChromeButton(symbol: "chevron.up", title: "Previous Match")
  private let next = PageChromeButton(symbol: "chevron.down", title: "Next Match")
  private let close = PageChromeButton(symbol: "xmark", title: "Close Find")
  var onPrevious: (() -> Void)?
  var onNext: (() -> Void)?
  var onClose: (() -> Void)?
  private(set) var matchCount = 0
  private(set) var matchIndex = 0
  override var isFlipped: Bool { true }

  init(field: NSSearchField) {
    self.field = field
    super.init(frame: .zero)
    let target = field.target, action = field.action, placeholder = field.placeholderString
    let immediate = field.sendsSearchStringImmediately, whole = field.sendsWholeSearchString
    let cell = FindSearchCell(textCell: ""); cell.editor = editor; field.cell = cell
    field.target = target; field.action = action; field.placeholderString = placeholder
    field.isEditable = true; field.isSelectable = true
    field.sendsSearchStringImmediately = immediate; field.sendsWholeSearchString = whole
    editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = true
    editor.onReturn = { [weak self] previous in if previous { self?.onPrevious?() } else { self?.onNext?() } }
    editor.onClose = { [weak self] in self?.onClose?() }
    wantsLayer = true; layer?.cornerRadius = 6
    layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
    layer?.borderWidth = 0.5; layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    appearance = NSAppearance(named: .darkAqua)
    field.font = .systemFont(ofSize: 12); field.focusRingType = .none
    field.isBordered = false; field.drawsBackground = false
    count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    count.textColor = .secondaryLabelColor; count.alignment = .right
    count.setAccessibilityLabel("Find matches")
    for view in [field, count, previous, next, close] { addSubview(view) }
    previous.onPress = { [weak self] in self?.onPrevious?() }
    next.onPress = { [weak self] in self?.onNext?() }
    close.onPress = { [weak self] in self?.onClose?() }
    isHidden = true
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    field.frame = CGRect(x: 6, y: 2, width: max(50, bounds.width - 108), height: 20)
    count.frame = CGRect(x: bounds.width - 102, y: 5, width: 38, height: 14)
    previous.frame = CGRect(x: bounds.width - 62, y: 2, width: 20, height: 20)
    next.frame = CGRect(x: bounds.width - 42, y: 2, width: 20, height: 20)
    close.frame = CGRect(x: bounds.width - 22, y: 2, width: 20, height: 20)
  }
  func resetEditing() { field.currentEditor()?.string = ""; editor.undoManager?.removeAllActions() }
  func update(count total: Int, active: Int) {
    matchCount = total; matchIndex = active
    count.stringValue = field.stringValue.isEmpty ? "" : "\(active)/\(total)"
    previous.isEnabled = total > 0; next.isEnabled = total > 0
    count.setAccessibilityValue(total == 0 ? "No matches" : "\(active) of \(total)")
  }
}

@MainActor
final class PageChromeButton: NSButton {
  var onPress: (() -> Void)?
  init(symbol: String, title: String) {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    imagePosition = .imageOnly; isBordered = false; toolTip = title
    setAccessibilityLabel(title); target = self; action = #selector(pressed)
  }
  init(title: String) {
    super.init(frame: .zero)
    self.title = title; bezelStyle = .rounded; target = self; action = #selector(pressed)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func pressed() { onPress?() }
}

@MainActor
private final class FindSearchCell: NSSearchFieldCell {
  weak var editor: NSTextView?
  override func fieldEditor(for controlView: NSView) -> NSTextView? { editor ?? super.fieldEditor(for: controlView) }
}
@MainActor
private final class FindFieldEditor: NSTextView {
  var onReturn: ((Bool) -> Void)?
  var onClose: (() -> Void)?
  private let editingUndoManager = UndoManager()
  override var undoManager: UndoManager? { editingUndoManager }
  override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      if event.keyCode == 36 || event.keyCode == 76 { onReturn?(event.modifierFlags.contains(.shift)); return }
      if event.keyCode == 53 { onClose?(); return }
    }
    super.keyDown(with: event)
  }
}
