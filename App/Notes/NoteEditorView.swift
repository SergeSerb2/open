import AppKit
import ImageIO
import OpenDocuments
import UniformTypeIdentifiers

/// Look values for the Note editor. Colours are facts from Arc's text editor
/// catalogs (docs/re/easels-notes.md §4.5); sizes and spacing are not
/// captured (Arc 1.172 cannot create Notes) and are marked GUESS.
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
  /// Header and list marker #6E678D / #CDCDFF (`ARC_ArcRichTextEditor` CAR, §4.5).
  static let heading = Pair(light: hex(0x6E678D), dark: hex(0xCDCDFF))
  /// Link #220C7F / #E6E6FF (§4.5).
  static let link = Pair(light: hex(0x220C7F), dark: hex(0xE6E6FF))
  /// Cursor #2702C2 / #9380E0.
  static let cursor = Pair(light: hex(0x2702C2), dark: hex(0x9380E0))
  /// Selection #CDCDFF / #5235CE.
  static let selection = Pair(light: hex(0xCDCDFF), dark: hex(0x5235CE))
  /// Format menu (§4.5): background, border, text, hover, selected item and its background.
  static let menuBackground = Pair(light: .white, dark: hex(0x120F2E))
  static let menuBorder = Pair(light: hex(0xCDCCDF), dark: hex(0x34334D))
  static let menuText = Pair(light: hex(0x6E678D), dark: hex(0x8795C1))
  static let menuHover = Pair(light: hex(0xEBEBEC), dark: NSColor(white: 1, alpha: 0.15))
  static let menuSelected = Pair(light: hex(0x2702C2), dark: hex(0xB6C9FA))
  static let menuSelectedBackground = Pair(light: hex(0x2702C2, 0.10), dark: hex(0x062E79))
  static let placeholderAlpha: CGFloat = 0.4
  /// Body placeholder (STR "Your best ideas here").
  static let bodyPlaceholder = "Your best ideas here"
  /// GUESS: the title placeholder.
  static let titlePlaceholder = "Untitled"

  // GUESS: fonts, sizes and spacing (approved at LEAD STOP A 01:55).
  static let titleFont = NSFont.systemFont(ofSize: 30, weight: .bold)
  static let bodyFont = NSFont.systemFont(ofSize: 16, weight: .regular)
  static let bodyLineHeightMultiple: CGFloat = 1.3
  static let maxColumnWidth: CGFloat = 680
  static let minSideInset: CGFloat = 40
  static let topInset: CGFloat = 64
  static let titleBodyGap: CGFloat = 14
  static let bottomInset: CGFloat = 96
  /// `GutterButton` 44 × 44 (CAR, §4.5).
  static let gutterSize: CGFloat = 44
}

/// The title (plain, one paragraph) or the body (rich) of a Note.
/// TextKit 1 (`usingTextLayoutManager: false`) for exact, cheap height fitting.
@MainActor
final class NoteTextView: NSTextView {
  var placeholder = ""
  var placeholderColor: NSColor = .placeholderTextColor
  /// Return / Tab in the title move to the body; Up at the body start moves to the title.
  var onCommand: ((Selector) -> Bool)?
  var onFocusChange: (() -> Void)?
  /// Body only: rich formats, list markers, markdown shortcuts and images.
  weak var rich: NoteEditorView?
  weak var editor: NoteEditorView?

  /// Find menu actions on either field show the body's find bar (never the replace interface).
  override func performFindPanelAction(_ sender: Any?) { editor?.showFind() }
  override func performTextFinderAction(_ sender: Any?) {
    // Hiding the bar stays native; every other action shows the find interface, as in Arc.
    if (sender as? NSValidatedUserInterfaceItem)?.tag == NSTextFinder.Action.hideFindInterface.rawValue {
      super.performTextFinderAction(sender); return
    }
    editor?.showFind()
  }
  func showNativeFind() {
    let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
    super.performTextFinderAction(item)
  }

  override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
    editor?.openUndoGroup()
    return super.shouldChangeText(in: range, replacementString: replacementString)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    rich?.drawMarkers(in: self, dirtyRect: dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty, rich?.trailingBlock == nil else { return }
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
    let ok = super.becomeFirstResponder(); needsDisplay = true; onFocusChange?(); return ok
  }
  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder(); onFocusChange?(); return ok
  }
  override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    if let rich, let text = (string as? String) ?? (string as? NSAttributedString)?.string { rich.didType(text) }
  }
  // Edit ▸ Format ▸ Font ▸ Bold / Italic (Cmd-B / Cmd-I) go through NSFontManager, which
  // sends changeFont(_:). The trait it adds or removes becomes the Note's logical flag.
  override func changeFont(_ sender: Any?) {
    guard let rich, let manager = sender as? NSFontManager else { return super.changeFont(sender) }
    let at = selectedRange().location
    let current = (textStorage.flatMap { at < $0.length ? $0.attribute(.font, at: at, effectiveRange: nil) as? NSFont : nil })
      ?? (typingAttributes[.font] as? NSFont) ?? NoteLook.bodyFont
    let converted = manager.convert(current)
    let before = manager.traits(of: current), after = manager.traits(of: converted)
    if before.contains(.boldFontMask) != after.contains(.boldFontMask) { rich.toggle(.noteBold) }
    if before.contains(.italicFontMask) != after.contains(.italicFontMask) { rich.toggle(.noteItalic) }
  }
  /// Open's Bold / Italic menu items send addFontTrait: with no target (MenuBuilder: tag 2 bold,
  /// tag 1 italic, the NSFontTraitMask values); the body is the responder that answers.
  @objc func addFontTrait(_ sender: Any?) {
    let tag = (sender as? NSMenuItem)?.tag ?? 0
    guard let rich else { return }
    if tag == Int(NSFontTraitMask.boldFontMask.rawValue) { rich.toggle(.noteBold) }
    else if tag == Int(NSFontTraitMask.italicFontMask.rawValue) { rich.toggle(.noteItalic) }
  }
  override func responds(to selector: Selector!) -> Bool {
    // The title stays plain: only the rich body takes the font-trait action.
    if selector == #selector(addFontTrait(_:)) { return rich != nil }
    return super.responds(to: selector)
  }
  override func underline(_ sender: Any?) {
    guard let rich else { return super.underline(sender) }
    rich.toggle(.noteUnderline)
  }
  // Paste and drop: plain text keeps the Note's formats; images become image paragraphs.
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    rich == nil ? super.readablePasteboardTypes : [.fileURL, .png, .tiff, .string]
  }
  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard let rich else { return super.readSelection(from: pboard, type: type) }
    return rich.paste(from: pboard, type: type)
  }
}

private final class NoteDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// The native Note page: a title above a rich body in one vertical scroll view,
/// with Arc's selection format menu and "+" gutter (§4.5).
@MainActor
final class NoteEditorView: NSView, NSTextViewDelegate {
  let scrollView = NSScrollView()
  private let document = NoteDocumentView()
  let titleView = NoteTextView(usingTextLayoutManager: false)
  let bodyView = NoteTextView(usingTextLayoutManager: false)
  let formatBar = NoteFormatBar()
  let gutterButton = NoteGutterButton()
  var onChange: ((_ title: String, _ body: NSAttributedString) -> Void)?
  /// Saves image bytes for this Note; returns the asset name, nil when refused.
  var onImage: ((_ data: Data, _ ext: String) -> String?)?
  var onOpenLink: ((URL, NSEvent.ModifierFlags) -> Void)?
  /// Automation: the modifier keys of the next link click (a socket call has no mouse event).
  var linkFlagsForNextClick: NSEvent.ModifierFlags?
  private(set) var isDark = false
  /// The Note's own undo history, grouped per event (the App's model undo manager
  /// groups by command, not by event, and must not mix with typing).
  let undo: UndoManager = { let manager = UndoManager(); manager.groupsByEvent = false; return manager }()
  private var undoGroupOpen = false
  private var transforming = false
  /// Characters changed since the last text-change notification (for restyling).
  private var pendingEdit: NSRange?
  private(set) var lastImageError: String?
  /// Whether the body's find bar is on screen.
  var showingFind: Bool { scrollView.isFindBarVisible }
  /// Shows the body's find bar (Arc: `performTextFinderAction:` with tag 1, show find interface).
  func showFind() { bodyView.showNativeFind() }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = document
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    addSubview(scrollView)
    for view in [titleView, bodyView] {
      view.isRichText = view === bodyView
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
      view.onFocusChange = { [weak self] in self?.updateChrome() }
      document.addSubview(view)
    }
    // Arc's Note editor answers the Find menu with the text view's own find interface.
    bodyView.usesFindBar = true
    bodyView.isIncrementalSearchingEnabled = true
    bodyView.rich = self
    bodyView.editor = self; titleView.editor = self
    // No automatic link detection: its deferred checking rewrites attributes over the
    // pre-transform range. Links come from the format bar link input.
    bodyView.isAutomaticLinkDetectionEnabled = false
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
    bodyView.onCommand = { [weak self] selector in self?.bodyCommand(selector) ?? false }
    gutterButton.isHidden = true
    gutterButton.target = self; gutterButton.action = #selector(showGutterMenu(_:))
    document.addSubview(gutterButton)
    formatBar.isHidden = true
    formatBar.onFormat = { [weak self] name in self?.performFormat(name) }
    formatBar.onLink = { [weak self] url in self?.applyLink(url) ?? false }
    formatBar.state = { [weak self] name in self?.isFormatActive(name) ?? false }
    addSubview(formatBar)
    applyStyle()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { NotificationCenter.default.removeObserver(self) }

  func setContent(title: String, body: NSAttributedString) {
    titleView.string = title
    bodyView.textStorage?.setAttributedString(body)
    undo.removeAllActions()
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

  var columnWidth: CGFloat { max(120, bodyView.frame.width) }

  private func applyStyle() {
    layer?.backgroundColor = NoteLook.background.resolve(isDark).cgColor
    let titleColor = NoteLook.title.resolve(isDark)
    titleView.typingAttributes = [.font: NoteLook.titleFont, .foregroundColor: titleColor]
    titleView.font = NoteLook.titleFont; titleView.textColor = titleColor
    titleView.placeholderColor = titleColor.withAlphaComponent(NoteLook.placeholderAlpha)
    if let storage = bodyView.textStorage {
      NoteRichText.restyle(storage, range: NSRange(location: 0, length: storage.length), dark: isDark, imageWidth: columnWidth)
    }
    resetTypingAttributes()
    bodyView.placeholderColor = NoteLook.body.resolve(isDark).withAlphaComponent(NoteLook.placeholderAlpha)
    bodyView.linkTextAttributes = [.foregroundColor: NoteLook.link.resolve(isDark),
                                   .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    for view in [titleView, bodyView] {
      view.insertionPointColor = NoteLook.cursor.resolve(isDark)
      view.selectedTextAttributes = [.backgroundColor: NoteLook.selection.resolve(isDark)]
      view.needsDisplay = true
    }
    formatBar.apply(dark: isDark); gutterButton.apply(dark: isDark)
  }

  /// Typing attributes follow the caret paragraph's kind and the inline flags before it.
  private func resetTypingAttributes() {
    let caret = bodyView.selectedRange().location
    let storage = bodyView.textStorage!
    let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(caret, storage.length), length: 0))
    var block: NoteBlock?, level = 0
    var inline: [NSAttributedString.Key: Any] = [:]
    if paragraph.length > 0 {
      block = NoteRichText.block(at: paragraph.location, in: storage)
      level = storage.attribute(.noteLevel, at: paragraph.location, effectiveRange: nil) as? Int ?? 0
    } else {
      block = trailingBlock; level = bodyView.typingAttributes[.noteLevel] as? Int ?? 0
    }
    if caret > 0, caret <= storage.length, caret > paragraph.location { inline = storage.attributes(at: caret - 1, effectiveRange: nil) }
    else if paragraph.length == 0 { inline = bodyView.typingAttributes }
    bodyView.typingAttributes = NoteRichText.typingAttributes(block: block, level: level, inline: inline, dark: isDark)
  }

  /// The kind of an empty last paragraph (no character holds it): from the typing attributes.
  var trailingBlock: NoteBlock? {
    let string = bodyView.string as NSString
    guard string.length == 0 || string.hasSuffix("\n"),
      bodyView.selectedRange().location == string.length else { return nil }
    return (bodyView.typingAttributes[.noteBlock] as? String).flatMap(NoteBlock.init(rawValue:))
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    let visible = scrollView.contentSize
    let width = max(120, min(NoteLook.maxColumnWidth, visible.width - 2 * NoteLook.minSideInset))
    let x = ((visible.width - width) / 2).rounded()
    let widthChanged = bodyView.frame.width != width
    let titleHeight = fittedHeight(titleView, width: width)
    titleView.frame = NSRect(x: x, y: NoteLook.topInset, width: width, height: titleHeight)
    let bodyY = titleView.frame.maxY + NoteLook.titleBodyGap
    if widthChanged, let storage = bodyView.textStorage, storage.length > 0, storage.containsAttachments {
      bodyView.frame.size.width = width
      NoteRichText.restyle(storage, range: NSRange(location: 0, length: storage.length), dark: isDark, imageWidth: width)
    }
    let bodyHeight = max(fittedHeight(bodyView, width: width), visible.height - bodyY - NoteLook.bottomInset)
    bodyView.frame = NSRect(x: x, y: bodyY, width: width, height: bodyHeight)
    document.frame = NSRect(x: 0, y: 0, width: visible.width, height: max(visible.height, bodyView.frame.maxY + NoteLook.bottomInset))
    updateChrome()
  }

  private func fittedHeight(_ view: NoteTextView, width: CGFloat) -> CGFloat {
    guard let container = view.textContainer, let manager = view.layoutManager else { return 0 }
    if container.containerSize.width != width { container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container).height
    let line = manager.defaultLineHeight(for: view === bodyView ? NoteLook.bodyFont : NoteLook.titleFont)
      * (view === bodyView ? NoteLook.bodyLineHeightMultiple : 1)
    return ceil(max(used, line))
  }

  // MARK: Delegate

  /// The title is one paragraph: pasted line breaks become spaces.
  func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
    if textView === bodyView {
      let changed = NSRange(location: range.location, length: text.map { ($0 as NSString).length } ?? range.length)
      pendingEdit = pendingEdit.map { NSUnionRange($0, changed) } ?? changed
      return true
    }
    guard let text, text.contains(where: \.isNewline) else { return true }
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    if textView.shouldChangeText(in: range, replacementString: flat) {
      textView.replaceCharacters(in: range, with: flat); textView.didChangeText()
    }
    return false
  }

  func textDidChange(_ notification: Notification) {
    if (notification.object as? NSTextView) === bodyView, let storage = bodyView.textStorage, !transforming {
      // Keep derived fonts and paragraph styles right around every edit (paste, delete, undo).
      let edited = pendingEdit ?? bodyView.selectedRange()
      pendingEdit = nil
      let clamped = NSIntersectionRange(edited, NSRange(location: 0, length: storage.length))
      NoteRichText.restyle(storage, range: clamped.length > 0 ? clamped : NSRange(location: min(edited.location, storage.length), length: 0),
                           dark: isDark, imageWidth: columnWidth)
    }
    needsLayout = true
    bodyView.needsDisplay = true
    guard !transforming else { return }
    onChange?(titleView.string, bodyView.attributedString())
  }

  func undoManager(for view: NSTextView) -> UndoManager? { undo }

  /// One undo step per turn of the main queue: the first change opens a group and
  /// the next turn closes it (CEF's pump never closes event-based undo groups).
  func openUndoGroup() {
    guard !undoGroupOpen, !undo.isUndoing, !undo.isRedoing else { return }
    undoGroupOpen = true
    undo.beginUndoGrouping()
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.undoGroupOpen else { return }
        self.undoGroupOpen = false
        if self.undo.groupingLevel > 0 { self.undo.endUndoGrouping() }
      }
    }
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    if (notification.object as? NSTextView) === bodyView, !transforming { resetTypingAttributes() }
    updateChrome()
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
    guard let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return true }
    let flags = (linkFlagsForNextClick ?? NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
    linkFlagsForNextClick = nil
    onOpenLink?(url, flags); return true
  }

  /// Clicks below the body text land in the body.
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(bodyView)
    bodyView.setSelectedRange(NSRange(location: (bodyView.string as NSString).length, length: 0))
  }

  // MARK: Edits (each one undoable)

  /// One attribute edit: undo registration, restyle and save.
  private func editAttributes(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
    guard let storage = bodyView.textStorage, bodyView.isEditable,
      bodyView.shouldChangeText(in: range, replacementString: nil) else { return }
    storage.beginEditing(); body(storage); storage.endEditing()
    NoteRichText.restyle(storage, range: range, dark: isDark, imageWidth: columnWidth)
    bodyView.didChangeText()
  }

  private func replace(_ range: NSRange, with text: NSAttributedString) {
    guard let storage = bodyView.textStorage, bodyView.shouldChangeText(in: range, replacementString: text.string) else { return }
    storage.replaceCharacters(in: range, with: text)
    bodyView.didChangeText()
  }

  func isActive(_ key: NSAttributedString.Key) -> Bool {
    let range = bodyView.selectedRange()
    guard range.length > 0, let storage = bodyView.textStorage else { return bodyView.typingAttributes[key] != nil }
    var all = true
    storage.enumerateAttribute(key, in: range) { value, _, stop in if value == nil { all = false; stop.pointee = true } }
    return all
  }

  func toggle(_ key: NSAttributedString.Key) {
    let range = bodyView.selectedRange()
    let on = !isActive(key)
    if range.length == 0 {
      var attributes = bodyView.typingAttributes
      attributes[key] = on ? true : nil
      let block = (attributes[.noteBlock] as? String).flatMap(NoteBlock.init(rawValue:))
      bodyView.typingAttributes = NoteRichText.typingAttributes(block: block, level: attributes[.noteLevel] as? Int ?? 0, inline: attributes, dark: isDark)
      return
    }
    editAttributes(range) { storage in
      if on { storage.addAttribute(key, value: true, range: range) } else { storage.removeAttribute(key, range: range) }
    }
    formatBar.refresh()
  }

  /// Sets the kind of every paragraph in the selection (nil = Text).
  func setBlock(_ block: NoteBlock?, level: Int = 0) {
    guard let storage = bodyView.textStorage else { return }
    let selection = bodyView.selectedRange()
    let paragraphs = (storage.string as NSString).paragraphRange(for: NSRange(location: min(selection.location, storage.length), length: selection.length))
    if paragraphs.length > 0 {
      editAttributes(paragraphs) { storage in
        if let block { storage.addAttribute(.noteBlock, value: block.rawValue, range: paragraphs) }
        else { storage.removeAttribute(.noteBlock, range: paragraphs) }
        storage.addAttribute(.noteLevel, value: level, range: paragraphs)
      }
    }
    if selection.location >= paragraphs.location, NSMaxRange(selection) <= NSMaxRange(paragraphs) || paragraphs.length == 0 {
      bodyView.typingAttributes = NoteRichText.typingAttributes(block: block, level: level, inline: bodyView.typingAttributes, dark: isDark)
    }
    if paragraphs.length == 0 { bodyView.didChangeText() }
    bodyView.needsDisplay = true; formatBar.refresh(); updateChrome()
  }

  func currentBlock() -> (NoteBlock?, Int) {
    guard let storage = bodyView.textStorage else { return (nil, 0) }
    let caret = bodyView.selectedRange().location
    let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(caret, storage.length), length: 0))
    if paragraph.length == 0 { return (trailingBlock, bodyView.typingAttributes[.noteLevel] as? Int ?? 0) }
    return (NoteRichText.block(at: paragraph.location, in: storage),
            storage.attribute(.noteLevel, at: paragraph.location, effectiveRange: nil) as? Int ?? 0)
  }

  /// Format bar and gutter commands; also the automation entry.
  @discardableResult
  func performFormat(_ name: String) -> Bool {
    switch name {
    case "bold": toggle(.noteBold)
    case "italic": toggle(.noteItalic)
    case "underline": toggle(.noteUnderline)
    case "strikethrough": toggle(.noteStrike)
    case "h1": setBlock(currentBlock().0 == .h1 ? nil : .h1)
    case "h2": setBlock(currentBlock().0 == .h2 ? nil : .h2)
    case "h3": setBlock(currentBlock().0 == .h3 ? nil : .h3)
    case "text": setBlock(nil)
    case "bullet": setBlock(currentBlock().0 == .bullet ? nil : .bullet)
    case "number": setBlock(currentBlock().0 == .number ? nil : .number)
    case "image": chooseImage()
    case "link": formatBar.beginLink(current: currentLink()?.absoluteString ?? "")
    default: return false
    }
    return true
  }

  func isFormatActive(_ name: String) -> Bool {
    switch name {
    case "bold": isActive(.noteBold)
    case "italic": isActive(.noteItalic)
    case "underline": isActive(.noteUnderline)
    case "strikethrough": isActive(.noteStrike)
    case "h1": currentBlock().0 == .h1
    case "h2": currentBlock().0 == .h2
    case "h3": currentBlock().0 == .h3
    case "link": currentLink() != nil
    default: false
    }
  }

  func currentLink() -> URL? {
    let range = bodyView.selectedRange()
    guard let storage = bodyView.textStorage, range.location < storage.length else { return nil }
    return storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL
  }

  /// Sets (or with an empty string removes) the link on the selection. Only http(s) and mailto.
  @discardableResult
  func applyLink(_ raw: String) -> Bool {
    let range = bodyView.selectedRange()
    guard range.length > 0 else { return false }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { editAttributes(range) { $0.removeAttribute(.link, range: range) }; return true }
    var candidate = trimmed
    if !candidate.contains(":") { candidate = "https://" + candidate }
    guard let url = URL(string: candidate), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return false }
    editAttributes(range) { $0.addAttribute(.link, value: url, range: range) }
    formatBar.refresh(); return true
  }

  // MARK: Keys

  private func bodyCommand(_ selector: Selector) -> Bool {
    let (block, level) = currentBlock()
    let caret = bodyView.selectedRange()
    let string = bodyView.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: min(caret.location, string.length), length: 0))
    let content = paragraph.length == 0 ? "" : string.substring(with: paragraph).trimmingCharacters(in: .newlines)
    switch selector {
    case #selector(insertNewline(_:)):
      // Return on an empty list item ends the list (Arc: "newline continues lists").
      if block?.isList == true, content.isEmpty, caret.length == 0 { setBlock(nil); return true }
      if block == .h1 || block == .h2 || block == .h3, caret.location == NSMaxRange(paragraph) - (string.substring(with: paragraph).hasSuffix("\n") ? 1 : 0) {
        bodyView.insertNewline(nil)
        bodyView.typingAttributes = NoteRichText.typingAttributes(block: nil, level: 0, inline: [:], dark: isDark)
        // `string` is the text before the newline; measure the new paragraph in the current text.
        let current = bodyView.string as NSString
        let next = current.paragraphRange(for: NSRange(location: min(bodyView.selectedRange().location, current.length), length: 0))
        if next.length > 0 { editAttributes(next) { $0.removeAttribute(.noteBlock, range: next) } }
        bodyView.needsDisplay = true
        return true
      }
      return false
    case #selector(insertTab(_:)):
      guard let block, block.isList else { return false }
      setBlock(block, level: min(level + 1, NoteRichText.maxListLevel)); return true
    case #selector(insertBacktab(_:)):
      if let block, block.isList { setBlock(level > 0 ? block : nil, level: max(level - 1, 0)); return true }
      window?.makeFirstResponder(titleView)
      titleView.setSelectedRange(NSRange(location: (titleView.string as NSString).length, length: 0))
      return true
    case #selector(deleteBackward(_:)):
      // Backspace at the start of a list item or heading turns it back into Text first.
      if caret.length == 0, caret.location == paragraph.location, block != nil { setBlock(nil); return true }
      return false
    case #selector(moveUp(_:)):
      guard caret == NSRange(location: 0, length: 0) else { return false }
      window?.makeFirstResponder(titleView)
      titleView.setSelectedRange(NSRange(location: (titleView.string as NSString).length, length: 0))
      return true
    default: return false
    }
  }

  // MARK: Markdown shortcuts (Arc `MarkdownTransformType`, §4.5)

  /// Paragraph prefixes: `#`, `##`, `###` headings; `*`, `-` bullets; `1.` numbers. GUESS for exact triggers.
  static let blockPrefixes: [(String, NoteBlock)] = [("# ", .h1), ("## ", .h2), ("### ", .h3), ("* ", .bullet), ("- ", .bullet), ("1. ", .number)]
  /// Inline pairs: `*bold*`, `_italic_`, `-strikethrough-` (Arc's three).
  static let inlineMarks: [(Character, NSAttributedString.Key)] = [("*", .noteBold), ("_", .noteItalic), ("-", .noteStrike)]

  func didType(_ text: String) {
    guard !transforming, text.count == 1, let typed = text.first, let storage = bodyView.textStorage else { return }
    let caret = bodyView.selectedRange().location
    guard caret > 0, caret <= storage.length else { return }
    let string = storage.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
    let before = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
    transforming = true
    var clearAfter: NSAttributedString.Key?
    defer {
      transforming = false; onChange?(titleView.string, bodyView.attributedString()); resetTypingAttributes()
      if let clearAfter { var typing = bodyView.typingAttributes; typing[clearAfter] = nil; bodyView.typingAttributes = typing }
      updateChrome()
    }
    // At a paragraph start, also inside a list (`1. ` in a bullet item makes it numbered).
    if typed == " ", let (prefix, block) = Self.blockPrefixes.first(where: { $0.0 == before }) {
      replace(NSRange(location: paragraph.location, length: (prefix as NSString).length), with: NSAttributedString(string: ""))
      bodyView.setSelectedRange(NSRange(location: paragraph.location, length: 0))
      setBlock(block)
      return
    }
    guard let mark = Self.inlineMarks.first(where: { $0.0 == typed }) else { return }
    let m = NSRegularExpression.escapedPattern(for: String(mark.0))
    let pattern = "(?:^|\\s)\(m)([^\\s\(m)](?:[^\(m)]*[^\\s\(m)])?)\(m)$"
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return }
    let inner = match.range(at: 1)
    let open = NSRange(location: paragraph.location + inner.location - 1, length: 1)
    let close = NSRange(location: paragraph.location + NSMaxRange(inner), length: 1)
    replace(close, with: NSAttributedString(string: ""))
    replace(open, with: NSAttributedString(string: ""))
    let styled = NSRange(location: open.location, length: inner.length)
    editAttributes(styled) { $0.addAttribute(mark.1, value: true, range: styled) }
    bodyView.setSelectedRange(NSRange(location: NSMaxRange(styled), length: 0))
    clearAfter = mark.1
  }

  // MARK: Images

  func paste(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    if type == .fileURL, let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      let url = urls.first, let kind = UTType(filenameExtension: url.pathExtension), kind.conforms(to: .image) {
      return insertImage(fileURL: url)
    }
    if type == .png, let data = board.data(forType: .png) { return insertImage(data: data, ext: "png") }
    if type == .tiff, let data = board.data(forType: .tiff), let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
      return insertImage(data: png, ext: "png")
    }
    guard let text = board.string(forType: .string) else { return false }
    bodyView.insertText(text, replacementRange: bodyView.selectedRange())
    return true
  }

  @discardableResult
  func insertImage(fileURL url: URL) -> Bool {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard size > 0 else { lastImageError = "unreadable image file"; return false }
    guard size <= NoteStore.maxImageBytes else { lastImageError = "image over the size limit"; return false }
    guard let data = try? Data(contentsOf: url) else { lastImageError = "unreadable image file"; return false }
    let ext = url.pathExtension.lowercased()
    return insertImage(data: data, ext: ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(ext) ? ext : "png")
  }

  @discardableResult
  func insertImage(data: Data, ext: String) -> Bool {
    guard data.count <= NoteStore.maxImageBytes else { lastImageError = "image over the size limit"; return false }
    guard let image = NoteImages.image(data) else { lastImageError = "not an image"; return false }
    guard let name = onImage?(data, ext) else { lastImageError = "image not saved"; return false }
    lastImageError = nil
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NoteRichText.imageBounds(image.size, width: columnWidth)
    let piece = NSMutableAttributedString(attachment: attachment)
    var attributes = bodyView.typingAttributes
    attributes[.noteImage] = name
    piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
    replace(bodyView.selectedRange(), with: piece)
    return true
  }

  private func chooseImage() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { _ = self?.insertImage(fileURL: url) }
    }
  }

  // MARK: List markers

  func drawMarkers(in view: NoteTextView, dirtyRect: NSRect) {
    guard view === bodyView, let manager = view.layoutManager, let container = view.textContainer,
      let storage = view.textStorage else { return }
    let color = NoteLook.heading.resolve(isDark)
    let font = NoteLook.bodyFont
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    func draw(_ marker: String, level: Int, fragment: NSRect, baseline: CGFloat) {
      let width = (marker as NSString).size(withAttributes: attributes).width
      let right = NoteRichText.listIndent * CGFloat(level + 1) - NoteRichText.listMarkerGap
      (marker as NSString).draw(at: NSPoint(x: right - width, y: fragment.minY + baseline - font.ascender), withAttributes: attributes)
    }
    let glyphs = manager.glyphRange(forBoundingRect: dirtyRect, in: container)
    let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    for item in NoteRichText.markers(in: storage, range: chars) {
      let glyph = manager.glyphIndexForCharacter(at: item.paragraph.location)
      guard glyph < manager.numberOfGlyphs else { continue }
      let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      draw(item.marker, level: item.level, fragment: fragment, baseline: manager.location(forGlyphAt: glyph).y)
    }
    // An empty last list item has no character: its marker comes from the typing attributes.
    if let block = trailingBlock, block.isList {
      let level = view.typingAttributes[.noteLevel] as? Int ?? 0
      let probe = NSMutableAttributedString(attributedString: storage)
      probe.append(NSAttributedString(string: "\u{200B}", attributes: [.noteBlock: block.rawValue, .noteLevel: level]))
      let marker = NoteRichText.markers(in: probe, range: NSRange(location: storage.length, length: 1)).last?.marker ?? "•"
      var fragment = manager.extraLineFragmentRect
      if fragment == .zero, storage.length == 0 { fragment = NSRect(x: 0, y: 0, width: view.bounds.width, height: font.ascender - font.descender) }
      let lineHeight = manager.defaultLineHeight(for: font) * NoteLook.bodyLineHeightMultiple
      draw(marker, level: level, fragment: fragment, baseline: (fragment.height > 0 ? fragment.height : lineHeight) - (lineHeight - font.ascender) - 0)
    }
  }

  // MARK: Format bar and gutter

  @objc private func scrolled() { updateChrome() }

  /// Shows the selection format menu above a body selection, and the "+" gutter
  /// beside an empty body line (Arc `TextEditorViewController` §4.5).
  func updateChrome() {
    let focused = window?.firstResponder === bodyView && bodyView.isEditable
    let selection = bodyView.selectedRange()
    if focused, selection.length > 0, let manager = bodyView.layoutManager, let container = bodyView.textContainer {
      let glyphs = manager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
      var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
      rect = convert(rect, from: bodyView)
      formatBar.layoutSubtreeIfNeeded()
      let size = formatBar.fittingSize
      var x = rect.midX - size.width / 2
      x = min(max(8, x), bounds.width - size.width - 8)
      // Flipped body → unflipped editor: above the selection's top edge.
      var y = rect.maxY + 8
      if y + size.height > bounds.height - 8 { y = rect.minY - size.height - 8 }
      formatBar.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
      if formatBar.isHidden { formatBar.isHidden = false }
      formatBar.refresh()
    } else if !formatBar.isEditingLink {
      formatBar.isHidden = true
    }
    let (_, _) = currentBlock()
    let string = bodyView.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: 0))
    let empty = paragraph.length == 0 || string.substring(with: paragraph) == "\n"
    if focused, selection.length == 0, empty, currentBlock().0 == nil, let manager = bodyView.layoutManager {
      var line: NSRect
      if paragraph.length == 0 { line = manager.extraLineFragmentRect }
      else { line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: paragraph.location), effectiveRange: nil) }
      if line == .zero { line = NSRect(x: 0, y: 0, width: 10, height: manager.defaultLineHeight(for: NoteLook.bodyFont) * NoteLook.bodyLineHeightMultiple) }
      let inBody = NSPoint(x: 0, y: line.midY)
      let point = document.convert(inBody, from: bodyView)
      gutterButton.frame = NSRect(x: bodyView.frame.minX - NoteLook.gutterSize - 2, y: (point.y - NoteLook.gutterSize / 2).rounded(),
                                  width: NoteLook.gutterSize, height: NoteLook.gutterSize)
      gutterButton.isHidden = false
    } else {
      gutterButton.isHidden = true
    }
  }

  /// The paragraph menu of the "+" gutter: Arc's paragraph items (FM `FormatMenuTextIconType`).
  func gutterMenu() -> NSMenu {
    let menu = NSMenu(title: "Insert")
    for (title, name, symbol) in [("Heading 1", "h1", "textformat.size.larger"), ("Heading 2", "h2", "textformat.size"),
                                  ("Heading 3", "h3", "textformat.size.smaller"), ("Text", "text", "text.alignleft"),
                                  ("Bulleted list", "bullet", "list.bullet"), ("Numbered list", "number", "list.number"),
                                  ("Insert image", "image", "photo")] {
      let item = ClosureMenuItem(title: title) { [weak self] in self?.performFormat(name) }
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      item.identifier = NSUserInterfaceItemIdentifier("note-gutter-" + name)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func showGutterMenu(_ sender: Any?) {
    gutterMenu().popUp(positioning: nil, at: NSPoint(x: gutterButton.frame.maxX, y: gutterButton.frame.minY), in: document)
  }
}

/// Image bounds checked from the header before any decode: 20 MiB per file (the store's
/// limit) and 40 megapixels (at most 160 MB as RGBA when drawn).
enum NoteImages {
  static let maxPixels = 40_000_000
  static func image(_ data: Data) -> NSImage? {
    guard data.count <= NoteStore.maxImageBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= maxPixels,
      !width.multipliedReportingOverflow(by: height).overflow,
      let image = NSImage(data: data), image.isValid else { return nil }
    return image
  }
  static func image(contentsOf url: URL) -> NSImage? {
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= NoteStore.maxImageBytes,
      let data = try? Data(contentsOf: url) else { return nil }
    return image(data)
  }
}
