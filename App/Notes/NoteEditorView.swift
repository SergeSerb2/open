import AppKit

/// Look values for the Note editor. Colours are facts from Arc's text editor
/// catalogs (docs/re/easels-notes.md §4.5); sizes and spacing are not
/// captured yet and are marked GUESS — capture pending (C3 item NT-2).
@MainActor
enum NoteLook {
  struct Pair { let light: NSColor; let dark: NSColor
    func resolve(_ dark: Bool) -> NSColor { dark ? self.dark : light } }
  static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
  }
  /// The document surface, the same as a web page area (LEAD 01:55): white in light; in dark,
  /// Chromium's default dark page canvas #121212, which a blank dark-scheme page shows.
  /// (Arc's translucent `NotesBackground` white 85 % / black 50 % read grey over the window.)
  static let background = Pair(light: .white, dark: hex(0x121212))
  /// Arc title colour, cited per LEAD 01:55: `TitleText` #220C7F / #E6E6FF in
  /// `ARC_TextEditor.bundle` Assets.car (docs/re/easels-notes.md §4.5, evidence CAR).
  /// Placeholder the same at 40 %.
  static let title = Pair(light: hex(0x220C7F), dark: hex(0xE6E6FF))
  /// Body #000 / #FFF; placeholder 40 %.
  static let body = Pair(light: .black, dark: .white)
  /// Cursor #2702C2 / #9380E0.
  static let cursor = Pair(light: hex(0x2702C2), dark: hex(0x9380E0))
  /// Selection #CDCDFF / #5235CE.
  static let selection = Pair(light: hex(0xCDCDFF), dark: hex(0x5235CE))
  static let placeholderAlpha: CGFloat = 0.4
  /// Body placeholder (STR "Your best ideas here").
  static let bodyPlaceholder = "Your best ideas here"
  /// GUESS — capture pending (C3 item NT-2): the title placeholder.
  static let titlePlaceholder = "Untitled"

  // GUESS — capture pending (C3 item NT-2): fonts, sizes and spacing.
  static let titleFont = NSFont.systemFont(ofSize: 30, weight: .bold)
  static let bodyFont = NSFont.systemFont(ofSize: 16, weight: .regular)
  static let bodyLineHeightMultiple: CGFloat = 1.3
  static let maxColumnWidth: CGFloat = 680
  static let minSideInset: CGFloat = 40
  static let topInset: CGFloat = 64
  static let titleBodyGap: CGFloat = 14
  static let bottomInset: CGFloat = 96
}

/// One plain-text line or block of the Note: the title or the body.
/// TextKit 1 (`usingTextLayoutManager: false`) for exact, cheap height fitting.
@MainActor
final class NoteTextView: NSTextView {
  var placeholder = ""
  var placeholderColor: NSColor = .placeholderTextColor
  /// Return / Tab in the title move to the body; Up at the body start moves to the title.
  var onCommand: ((Selector) -> Bool)?

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    var attributes = typingAttributes
    attributes[.foregroundColor] = placeholderColor
    let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
    (placeholder as NSString).draw(at: origin, withAttributes: attributes)
  }
  override func doCommand(by selector: Selector) {
    if onCommand?(selector) == true { return }
    super.doCommand(by: selector)
  }
  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder(); needsDisplay = true; return ok
  }
}

private final class NoteDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// The native Note page: a title above a body in one vertical scroll view.
@MainActor
final class NoteEditorView: NSView, NSTextViewDelegate {
  let scrollView = NSScrollView()
  private let document = NoteDocumentView()
  let titleView = NoteTextView(usingTextLayoutManager: false)
  let bodyView = NoteTextView(usingTextLayoutManager: false)
  var onChange: ((_ title: String, _ body: String) -> Void)?
  private(set) var isDark = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = document
    scrollView.contentView.postsBoundsChangedNotifications = false
    addSubview(scrollView)
    for view in [titleView, bodyView] {
      view.isRichText = false
      view.importsGraphics = false
      view.allowsUndo = true
      view.drawsBackground = false
      view.isVerticallyResizable = true
      view.isHorizontallyResizable = false
      view.textContainerInset = .zero
      view.textContainer?.widthTracksTextView = true
      view.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
      view.isAutomaticQuoteSubstitutionEnabled = false
      view.isAutomaticDashSubstitutionEnabled = false
      view.delegate = self
      document.addSubview(view)
    }
    titleView.placeholder = NoteLook.titlePlaceholder
    bodyView.placeholder = NoteLook.bodyPlaceholder
    titleView.setAccessibilityIdentifier("note-title")
    titleView.setAccessibilityLabel("Note title")
    bodyView.setAccessibilityIdentifier("note-body")
    bodyView.setAccessibilityLabel("Note")
    titleView.onCommand = { [weak self] selector in
      guard let self else { return false }
      if selector == #selector(insertNewline(_:)) || selector == #selector(insertTab(_:)) || selector == #selector(moveDown(_:)) {
        self.window?.makeFirstResponder(self.bodyView)
        self.bodyView.setSelectedRange(NSRange(location: 0, length: 0))
        return true
      }
      return false
    }
    bodyView.onCommand = { [weak self] selector in
      guard let self else { return false }
      let atStart = self.bodyView.selectedRange() == NSRange(location: 0, length: 0)
      if selector == #selector(insertBacktab(_:)) || (atStart && selector == #selector(moveUp(_:))) {
        self.window?.makeFirstResponder(self.titleView)
        self.titleView.setSelectedRange(NSRange(location: (self.titleView.string as NSString).length, length: 0))
        return true
      }
      return false
    }
    applyStyle()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  func setContent(title: String, body: String) {
    titleView.string = title
    bodyView.string = body
    applyStyle()
    needsLayout = true
  }

  /// Arc: "Websites, Easels, and Notes will use:" (View ▸ Appearance). Open
  /// reads the same website setting; Automatic follows the system, not a Space override.
  func setDark(_ dark: Bool) {
    appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    guard dark != isDark else { return }
    isDark = dark; applyStyle()
  }

  private func applyStyle() {
    layer?.backgroundColor = NoteLook.background.resolve(isDark).cgColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = NoteLook.bodyLineHeightMultiple
    let styles: [(NoteTextView, NSFont, NSColor, NSParagraphStyle?)] = [
      (titleView, NoteLook.titleFont, NoteLook.title.resolve(isDark), nil),
      (bodyView, NoteLook.bodyFont, NoteLook.body.resolve(isDark), paragraph),
    ]
    for (view, font, color, paragraphStyle) in styles {
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      if let paragraphStyle { attributes[.paragraphStyle] = paragraphStyle }
      view.typingAttributes = attributes
      view.font = font
      view.textColor = color
      if let paragraphStyle { view.defaultParagraphStyle = paragraphStyle }
      if let storage = view.textStorage, storage.length > 0 {
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
      }
      view.insertionPointColor = NoteLook.cursor.resolve(isDark)
      view.selectedTextAttributes = [.backgroundColor: NoteLook.selection.resolve(isDark)]
      view.placeholderColor = color.withAlphaComponent(NoteLook.placeholderAlpha)
      view.needsDisplay = true
    }
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    let visible = scrollView.contentSize
    let width = max(120, min(NoteLook.maxColumnWidth, visible.width - 2 * NoteLook.minSideInset))
    let x = ((visible.width - width) / 2).rounded()
    let titleHeight = fittedHeight(titleView, width: width)
    titleView.frame = NSRect(x: x, y: NoteLook.topInset, width: width, height: titleHeight)
    let bodyY = titleView.frame.maxY + NoteLook.titleBodyGap
    let bodyHeight = max(fittedHeight(bodyView, width: width), visible.height - bodyY - NoteLook.bottomInset)
    bodyView.frame = NSRect(x: x, y: bodyY, width: width, height: bodyHeight)
    document.frame = NSRect(x: 0, y: 0, width: visible.width, height: max(visible.height, bodyView.frame.maxY + NoteLook.bottomInset))
  }

  private func fittedHeight(_ view: NoteTextView, width: CGFloat) -> CGFloat {
    guard let container = view.textContainer, let manager = view.layoutManager else { return 0 }
    if container.containerSize.width != width { container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container).height
    let line = manager.defaultLineHeight(for: view.font ?? NoteLook.bodyFont)
      * (view === bodyView ? NoteLook.bodyLineHeightMultiple : 1)
    return ceil(max(used, line))
  }

  /// The title is one paragraph: pasted line breaks become spaces.
  func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
    guard textView === titleView, let text, text.contains(where: \.isNewline) else { return true }
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    if textView.shouldChangeText(in: range, replacementString: flat) {
      textView.replaceCharacters(in: range, with: flat); textView.didChangeText()
    }
    return false
  }

  func textDidChange(_ notification: Notification) {
    needsLayout = true
    onChange?(titleView.string, bodyView.string)
  }

  /// Clicks below the body text land in the body.
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(bodyView)
    bodyView.setSelectedRange(NSRange(location: (bodyView.string as NSString).length, length: 0))
  }
}
