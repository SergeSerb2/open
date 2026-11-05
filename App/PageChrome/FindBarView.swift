import AppKit
import CoreText

/// Recreated from page-chrome §1; no reference assets. The dedicated field
/// editor consumes navigation keys before the embedded page can see them.
@MainActor
final class FindBarView: NSView, NSTextFieldDelegate {
  let field = NSTextField()
  private let editor = FindFieldEditor(usingTextLayoutManager: false)
  private let search = NSImageView()
  private let count = NSTextField(labelWithString: "")
  private let previous = FindButton(symbol: "chevron.up", title: "Previous Match")
  private let next = FindButton(symbol: "chevron.down", title: "Next Match")
  private let close = FindButton(symbol: "xmark", title: "Close Find")
  private let separator = CALayer()
  var onEdit: ((String) -> Void)?
  var onAction: ((Int) -> Void)?
  var onClose: (() -> Void)?
  private(set) var active = 0
  private(set) var total = 0
  private(set) var notFound = false
  private(set) var hasResult = false
  private(set) var layoutCount = 0
  var countText: String { count.stringValue }
  var navigationVisible: Bool { !next.isHidden }
  var separatorVisible: Bool { !separator.isHidden }
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 5
    layer?.shadowRadius = 5
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    layer?.addSublayer(separator)
    let cell = FindTextCell(textCell: ""); cell.editor = editor; field.cell = cell
    field.isEditable = true; field.isSelectable = true
    field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
    field.focusRingType = .none; field.font = .systemFont(ofSize: 13)
    field.placeholderString = "Find in page..."
    field.cell?.isScrollable = true; field.cell?.wraps = false
    field.usesSingleLineMode = true; field.delegate = self
    field.setAccessibilityLabel("Find in page")
    editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = true
    editor.drawsBackground = false
    editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.onAction = { [weak self] in self?.onAction?($0) }
    editor.onClose = { [weak self] in self?.onClose?() }
    let features: [[NSFontDescriptor.FeatureKey: Int]] = [
      [.typeIdentifier: 37, .selectorIdentifier: 1], [.typeIdentifier: 38, .selectorIdentifier: 1]]
    count.font = NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.addingAttributes([.featureSettings: features]), size: 12)
    count.setAccessibilityLabel("Find matches")
    search.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    search.imageScaling = .scaleNone
    for view in [search, field, count, previous, next, close] { addSubview(view) }
    previous.onPress = { [weak self] in self?.onAction?(3) }
    next.onPress = { [weak self] in self?.onAction?(2) }
    close.onPress = { [weak self] in self?.onClose?() }
    update(active: 0, total: 0, final: false)
    applyColors()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
  private func applyColors() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let background = NSColor(displayP3Red: dark ? 0.082 : 0.980, green: dark ? 0.110 : 0.984, blue: dark ? 0.188 : 1, alpha: 1)
    layer?.backgroundColor = background.cgColor
    layer?.shadowColor = NSColor(displayP3Red: 0.082, green: 0.110, blue: 0.196, alpha: 1).cgColor
    layer?.shadowOpacity = dark ? 0.80 : 0.30
    field.textColor = dark ? NSColor.white.withAlphaComponent(0.80)
      : NSColor(displayP3Red: 0.0549, green: 0.0588, blue: 0.0627, alpha: 0.90)
    let tint = NSColor(displayP3Red: dark ? 0.980 : 0.055, green: dark ? 0.984 : 0.059, blue: dark ? 1 : 0.063, alpha: dark ? 0.90 : 0.80)
    search.contentTintColor = tint
    for button in [previous, next, close] { button.contentTintColor = tint }
    count.textColor = notFound ? NSColor(displayP3Red: 0.788, green: 0.2, blue: 0.2, alpha: 1) : tint
    separator.backgroundColor = NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 0.10).cgColor
  }
  override func layout() {
    super.layout(); layoutCount += 1
    search.frame = CGRect(x: 3, y: 3, width: 26, height: 26)
    close.frame = CGRect(x: bounds.width - 29, y: 3, width: 26, height: 26)
    separator.frame = CGRect(x: close.frame.minX - 1.5, y: 7, width: 1, height: 18)
    var trailing = close.frame.minX - 5
    if navigationVisible {
      next.frame = CGRect(x: trailing - 26, y: 3, width: 26, height: 26); trailing -= 26
      previous.frame = CGRect(x: trailing - 26, y: 3, width: 26, height: 26); trailing -= 26
    }
    if !count.isHidden {
      let width = min(100, ceil(count.intrinsicContentSize.width))
      count.frame = CGRect(x: trailing - width, y: 8, width: width, height: 17); trailing -= width
    }
    field.frame = CGRect(x: 32, y: 7, width: max(0, trailing - 4 - 32), height: 18)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
  }
  func update(active: Int, total: Int, final: Bool) {
    self.active = max(0, active); self.total = max(0, total)
    hasResult = final && !field.stringValue.isEmpty
    notFound = hasResult && total == 0
    count.stringValue = hasResult ? (notFound ? "Not Found" : "\(self.active)/\(self.total)") : ""
    count.isHidden = !hasResult
    previous.isHidden = !hasResult || notFound; next.isHidden = previous.isHidden
    separator.isHidden = !hasResult
    count.setAccessibilityValue(count.stringValue)
    applyColors(); needsLayout = true
  }
  func setQuery(_ value: String) {
    guard field.stringValue != value else { return }
    field.stringValue = value; field.currentEditor()?.string = value
    editor.undoManager?.removeAllActions()
  }
  func focusQuery() { window?.makeFirstResponder(field); field.selectText(nil) }
  func owns(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    return responder === field || responder === field.currentEditor()
  }
  func controlTextDidChange(_ obj: Notification) { onEdit?(field.stringValue) }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)): onClose?()
    case #selector(NSResponder.insertNewline(_:)): onAction?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 3 : 2)
    case #selector(NSResponder.moveUp(_:)): onAction?(3)
    case #selector(NSResponder.moveDown(_:)): onAction?(2)
    default: return false
    }
    return true
  }
}

@MainActor
private final class FindButton: NSButton {
  var onPress: (() -> Void)?
  init(symbol: String, title: String) {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
      .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    imagePosition = .imageOnly; imageScaling = .scaleNone; isBordered = false
    toolTip = title; setAccessibilityLabel(title); target = self; action = #selector(pressed)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func pressed() { onPress?() }
}

@MainActor
private final class FindTextCell: NSTextFieldCell {
  weak var editor: NSTextView?
  override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

@MainActor
private final class FindFieldEditor: NSTextView {
  var onAction: ((Int) -> Void)?
  var onClose: (() -> Void)?
  private let editingUndoManager = UndoManager()
  override var undoManager: UndoManager? { editingUndoManager }
  override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      switch event.keyCode {
      case 36, 76: onAction?(event.modifierFlags.contains(.shift) ? 3 : 2); return
      case 125: onAction?(2); return
      case 126: onAction?(3); return
      case 53: onClose?(); return
      default: break
      }
    }
    super.keyDown(with: event)
  }
  override func performFindPanelAction(_ sender: Any?) { onAction?((sender as? NSMenuItem)?.tag ?? 1) }
  override func performTextFinderAction(_ sender: Any?) { onAction?(1) }
}

/// A transparent, autoresizing overlay in the pane's coordinates. Empty space
/// passes through to the page. No window event monitor or idle scheduler.
@MainActor
final class FindPaneOverlay: NSView {
  let bar = FindBarView(frame: .zero)
  var topInset: CGFloat = 10 { didSet { if topInset != oldValue { needsLayout = true } } }
  override init(frame: NSRect) {
    super.init(frame: frame); autoresizingMask = [.width, .height]; addSubview(bar)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let width = min(300, max(0, bounds.width - 20))
    bar.frame = CGRect(x: bounds.width - 10 - width, y: bounds.height - topInset - 32, width: width, height: 32)
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point); return hit === self ? nil : hit
  }
}
