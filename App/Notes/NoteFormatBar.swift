import AppKit

/// Arc's selection format menu ("Format Selection", §4.5): headings, inline
/// styles and a link input, in a small floating bar above the selection.
/// Colours are Arc's format-menu values; sizes are GUESS (no capture exists).
@MainActor
final class NoteFormatBar: NSView, NSTextFieldDelegate {
  var onFormat: ((String) -> Void)?
  var onLink: ((String) -> Bool)?
  var state: ((String) -> Bool)?
  private(set) var buttons: [NoteFormatButton] = []
  private let stack = NSStackView()
  let linkField = NSTextField()
  private(set) var isEditingLink = false
  private var dark = false
  /// (name, accessibility title, SF Symbol or text label)
  static let items: [(String, String, String?)] = [
    ("h1", "Heading 1", nil), ("h2", "Heading 2", nil), ("h3", "Heading 3", nil),
    ("bold", "Bold", "bold"), ("italic", "Italic", "italic"), ("underline", "Underline", "underline"),
    ("strikethrough", "Strikethrough", "strikethrough"), ("link", "Link", "link"),
  ]

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    shadow = { let s = NSShadow(); s.shadowBlurRadius = 8; s.shadowOffset = NSSize(width: 0, height: -2)
      s.shadowColor = NSColor.black.withAlphaComponent(0.12); return s }()
    stack.orientation = .horizontal; stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                 stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    for (index, item) in Self.items.enumerated() {
      if index == 3 || index == 7 { stack.addArrangedSubview(Self.separator()) }
      let button = NoteFormatButton(name: item.0, title: item.1, symbol: item.2)
      button.target = self; button.action = #selector(pressed(_:))
      buttons.append(button); stack.addArrangedSubview(button)
    }
    linkField.placeholderString = "Paste or type a link"   // GUESS: Arc's link input text is not captured.
    linkField.isBordered = false; linkField.drawsBackground = false; linkField.focusRingType = .none
    linkField.font = .systemFont(ofSize: 13)
    linkField.delegate = self
    linkField.widthAnchor.constraint(equalToConstant: 240).isActive = true
    linkField.isHidden = true
    linkField.setAccessibilityIdentifier("note-link-field")
    stack.addArrangedSubview(linkField)
    setAccessibilityRole(.toolbar); setAccessibilityLabel("Format Selection")
    setAccessibilityIdentifier("note-format-bar")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  private static func separator() -> NSView {
    let line = NSBox(); line.boxType = .separator
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  @objc private func pressed(_ sender: NoteFormatButton) { onFormat?(sender.name); refresh() }

  func apply(dark: Bool) {
    self.dark = dark
    layer?.backgroundColor = NoteLook.menuBackground.resolve(dark).cgColor
    layer?.borderColor = NoteLook.menuBorder.resolve(dark).cgColor
    linkField.textColor = NoteLook.menuText.resolve(dark)
    for button in buttons { button.apply(dark: dark) }
  }

  func refresh() { for button in buttons { button.isOn = state?(button.name) ?? false } }

  /// Swaps the buttons for the link input; Return applies, Esc cancels.
  func beginLink(current: String) {
    isEditingLink = true
    for view in stack.arrangedSubviews where view !== linkField { view.isHidden = true }
    linkField.isHidden = false; linkField.stringValue = current
    window?.makeFirstResponder(linkField)
  }
  func endLink() {
    isEditingLink = false
    for view in stack.arrangedSubviews { view.isHidden = view === linkField }
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(insertNewline(_:)) {
      let value = linkField.stringValue
      endLink()
      (superview as? NoteEditorView).map { $0.window?.makeFirstResponder($0.bodyView) }
      _ = onLink?(value)
      return true
    }
    if selector == #selector(cancelOperation(_:)) {
      endLink(); (superview as? NoteEditorView).map { $0.window?.makeFirstResponder($0.bodyView) }
      return true
    }
    return false
  }
}

@MainActor
final class NoteFormatButton: NSButton {
  let name: String
  var isOn = false { didSet { if isOn != oldValue { updateColors() } } }
  private var dark = false
  private var hovering = false
  init(name: String, title: String, symbol: String?) {
    self.name = name
    super.init(frame: .zero)
    isBordered = false; wantsLayer = true; layer?.cornerRadius = 5
    setButtonType(.momentaryChange)
    if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
      self.image = image.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)); imagePosition = .imageOnly
    } else {
      self.title = name.uppercased(); font = .systemFont(ofSize: 12, weight: .bold)
    }
    toolTip = title
    setAccessibilityLabel(title); setAccessibilityIdentifier("note-format-" + name)
    widthAnchor.constraint(equalToConstant: 28).isActive = true
    heightAnchor.constraint(equalToConstant: 28).isActive = true
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func apply(dark: Bool) { self.dark = dark; updateColors() }
  override func mouseEntered(with event: NSEvent) { hovering = true; updateColors() }
  override func mouseExited(with event: NSEvent) { hovering = false; updateColors() }
  private func updateColors() {
    let ink = isOn ? NoteLook.menuSelected.resolve(dark) : NoteLook.menuText.resolve(dark)
    contentTintColor = ink
    if image == nil { attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: ink, .font: font ?? .systemFont(ofSize: 12)]) }
    layer?.backgroundColor = (isOn ? NoteLook.menuSelectedBackground.resolve(dark) : hovering ? NoteLook.menuHover.resolve(dark) : .clear).cgColor
  }
}

/// The "+" beside an empty body line (`GutterButton` 44 × 44, §4.5). Our own drawing.
@MainActor
final class NoteGutterButton: NSButton {
  private var dark = false
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Insert")?
      .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
    imagePosition = .imageOnly
    setAccessibilityLabel("Insert"); setAccessibilityIdentifier("note-gutter")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func apply(dark: Bool) { self.dark = dark; contentTintColor = NoteLook.heading.resolve(dark).withAlphaComponent(0.7) }
}
