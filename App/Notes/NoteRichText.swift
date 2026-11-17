import AppKit
import OpenDocuments

/// Logical Note formats live in the text storage as these keys; fonts, colours
/// and paragraph styles are derived from them (`NoteRichText.restyle`). The
/// stored file keeps only the logical formats (`NoteFormat`), the same range
/// model as Arc's `RichTextFormatType` (docs/re/easels-notes.md §4.4).
extension NSAttributedString.Key {
  static let noteBold = NSAttributedString.Key("open.note.bold")
  static let noteItalic = NSAttributedString.Key("open.note.italic")
  static let noteUnderline = NSAttributedString.Key("open.note.underline")
  static let noteStrike = NSAttributedString.Key("open.note.strikethrough")
  /// Paragraph kind: `NoteBlock` raw value. Absent means Text.
  static let noteBlock = NSAttributedString.Key("open.note.block")
  /// List indent level, 0-based.
  static let noteLevel = NSAttributedString.Key("open.note.level")
  /// Image asset name on an attachment character.
  static let noteImage = NSAttributedString.Key("open.note.image")
}

/// Arc's paragraph formats (FM `FormatMenuTextIconType`): Heading 1/2/3, Text, Bulleted list, Numbered list.
enum NoteBlock: String, CaseIterable {
  case h1, h2, h3, bullet, number
  var formatType: String {
    switch self {
    case .h1: "h1"
    case .h2: "h2"
    case .h3: "h3"
    case .bullet: "bulletList"
    case .number: "numberedList"
    }
  }
  init?(formatType: String) {
    guard let match = Self.allCases.first(where: { $0.formatType == formatType }) else { return nil }
    self = match
  }
  var isList: Bool { self == .bullet || self == .number }
}

@MainActor
enum NoteRichText {
  static let inlineKeys: [(NSAttributedString.Key, String)] = [
    (.noteBold, "bold"), (.noteItalic, "italic"), (.noteUnderline, "underline"), (.noteStrike, "strikethrough"),
  ]
  static let maxListLevel = 5

  // GUESS — capture pending (Arc 1.172 cannot create Notes): heading sizes, list indents, spacing.
  static func baseFont(_ block: NoteBlock?) -> NSFont {
    switch block {
    case .h1: NSFont.systemFont(ofSize: 24, weight: .bold)
    case .h2: NSFont.systemFont(ofSize: 20, weight: .bold)
    case .h3: NSFont.systemFont(ofSize: 17, weight: .semibold)
    default: NoteLook.bodyFont
    }
  }
  static let listIndent: CGFloat = 24
  static let listMarkerGap: CGFloat = 6

  static func block(at index: Int, in text: NSAttributedString) -> NoteBlock? {
    guard text.length > 0 else { return nil }
    let i = min(index, text.length - 1)
    return (text.attribute(.noteBlock, at: i, effectiveRange: nil) as? String).flatMap(NoteBlock.init(rawValue:))
  }

  /// Derives fonts, colours and paragraph styles from the logical keys for every
  /// paragraph that touches `range`. Attribute-only: callers wrap it in an edit.
  static func restyle(_ storage: NSTextStorage, range: NSRange, dark: Bool, imageWidth: CGFloat) {
    let string = storage.string as NSString
    guard storage.length > 0 else { return }
    let start = min(range.location, storage.length)
    let span = string.paragraphRange(for: NSRange(location: start == storage.length ? max(0, start - 1) : start,
                                                  length: min(range.length, storage.length - start)))
    storage.beginEditing()
    string.enumerateSubstrings(in: span, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
      let block = (storage.attribute(.noteBlock, at: enclosing.location, effectiveRange: nil) as? String).flatMap(NoteBlock.init(rawValue:))
      let level = storage.attribute(.noteLevel, at: enclosing.location, effectiveRange: nil) as? Int ?? 0
      // One block per paragraph: normalise stragglers from edits inside the paragraph.
      if let block { storage.addAttribute(.noteBlock, value: block.rawValue, range: enclosing) }
      else { storage.removeAttribute(.noteBlock, range: enclosing) }
      if block?.isList == true { storage.addAttribute(.noteLevel, value: level, range: enclosing) }
      else { storage.removeAttribute(.noteLevel, range: enclosing) }
      storage.addAttribute(.paragraphStyle, value: paragraphStyle(block, level: level), range: enclosing)
      let base = baseFont(block)
      let isHeading = block == .h1 || block == .h2 || block == .h3
      let color = (isHeading ? NoteLook.heading : NoteLook.body).resolve(dark)
      storage.enumerateAttributes(in: enclosing) { attributes, run, _ in
        var font = base
        let manager = NSFontManager.shared
        if attributes[.noteBold] != nil { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if attributes[.noteItalic] != nil { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        storage.addAttribute(.font, value: font, range: run)
        storage.addAttribute(.foregroundColor, value: color, range: run)
        if attributes[.noteUnderline] != nil { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run) }
        else if attributes[.link] == nil { storage.removeAttribute(.underlineStyle, range: run) }
        if attributes[.noteStrike] != nil { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run) }
        else { storage.removeAttribute(.strikethroughStyle, range: run) }
        if let attachment = attributes[.attachment] as? NSTextAttachment, let image = attachment.image {
          attachment.bounds = imageBounds(image.size, width: imageWidth)
        }
      }
    }
    storage.endEditing()
  }

  static func paragraphStyle(_ block: NoteBlock?, level: Int) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    switch block {
    case .h1, .h2, .h3:
      style.lineHeightMultiple = 1.1
      style.paragraphSpacingBefore = block == .h1 ? 14 : 10
      style.paragraphSpacing = 4
    case .bullet, .number:
      style.lineHeightMultiple = NoteLook.bodyLineHeightMultiple
      let indent = listIndent * CGFloat(level + 1)
      style.headIndent = indent; style.firstLineHeadIndent = indent
    default:
      style.lineHeightMultiple = NoteLook.bodyLineHeightMultiple
    }
    return style
  }

  static func imageBounds(_ size: NSSize, width: CGFloat) -> NSRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let scale = min(1, max(40, width) / size.width)
    return NSRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }

  /// Body typing attributes for a paragraph of `block`, keeping inline flags from `current`.
  static func typingAttributes(block: NoteBlock?, level: Int, inline current: [NSAttributedString.Key: Any], dark: Bool) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [:]
    for (key, _) in inlineKeys where current[key] != nil { attributes[key] = true }
    if let block { attributes[.noteBlock] = block.rawValue }
    if block?.isList == true { attributes[.noteLevel] = level }
    var font = baseFont(block)
    if attributes[.noteBold] != nil { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    if attributes[.noteItalic] != nil { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    attributes[.font] = font
    let isHeading = block == .h1 || block == .h2 || block == .h3
    attributes[.foregroundColor] = (isHeading ? NoteLook.heading : NoteLook.body).resolve(dark)
    attributes[.paragraphStyle] = paragraphStyle(block, level: level)
    if attributes[.noteUnderline] != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if attributes[.noteStrike] != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    return attributes
  }

  // MARK: Stored formats <-> attributed text

  /// Builds the body from stored text and formats. Unknown or out-of-range formats are dropped.
  static func attributed(text: String, formats: [NoteFormat], image: (String) -> NSImage?) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: text)
    let length = result.length
    for format in formats {
      // No `location + length`: a damaged file's huge values would overflow and trap.
      guard format.location >= 0, format.length >= 0, format.location <= length, format.length <= length - format.location else { continue }
      let range = NSRange(location: format.location, length: format.length)
      if let key = inlineKeys.first(where: { $0.1 == format.type })?.0 {
        result.addAttribute(key, value: true, range: range)
      } else if format.type == "link", let raw = format.url, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
        result.addAttribute(.link, value: url, range: range)
      } else if let block = NoteBlock(formatType: format.type) {
        let paragraphs = (text as NSString).paragraphRange(for: range)
        result.addAttribute(.noteBlock, value: block.rawValue, range: paragraphs)
        if block.isList { result.addAttribute(.noteLevel, value: min(max(format.level ?? 0, 0), maxListLevel), range: paragraphs) }
      } else if format.type == "image", format.length == 1, let name = format.url,
        (text as NSString).character(at: format.location) == 0xFFFC {
        let attachment = NSTextAttachment()
        attachment.image = image(name)
        result.addAttribute(.attachment, value: attachment, range: range)
        result.addAttribute(.noteImage, value: name, range: range)
      }
    }
    return result
  }

  /// The stored formats of the body, in text order. Runs of one format are merged.
  static func formats(of text: NSAttributedString) -> [NoteFormat] {
    var formats: [NoteFormat] = []
    let all = NSRange(location: 0, length: text.length)
    for (key, type) in inlineKeys {
      text.enumerateAttribute(key, in: all) { value, range, _ in
        if value != nil { formats.append(NoteFormat(type: type, location: range.location, length: range.length)) }
      }
    }
    text.enumerateAttribute(.link, in: all) { value, range, _ in
      let url = (value as? URL)?.absoluteString ?? (value as? String)
      if let url { formats.append(NoteFormat(type: "link", location: range.location, length: range.length, url: url)) }
    }
    let string = text.string as NSString
    string.enumerateSubstrings(in: all, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
      guard paragraph.location < text.length,
        let block = (text.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? String).flatMap(NoteBlock.init(rawValue:))
      else { return }
      let level = block.isList ? (text.attribute(.noteLevel, at: paragraph.location, effectiveRange: nil) as? Int ?? 0) : nil
      formats.append(NoteFormat(type: block.formatType, location: paragraph.location, length: paragraph.length, level: level))
    }
    // An empty last paragraph has no character; its kind lives in the typing attributes only.
    text.enumerateAttribute(.noteImage, in: all) { value, range, _ in
      guard let name = value as? String else { return }
      for offset in 0..<range.length where string.character(at: range.location + offset) == 0xFFFC {
        formats.append(NoteFormat(type: "image", location: range.location + offset, length: 1, url: name))
      }
    }
    return formats.sorted { ($0.location, $0.type) < ($1.location, $1.type) }
  }

  // MARK: List markers

  /// "•" or "n." for each list paragraph intersecting `range`. Numbers count the
  /// run of numbered paragraphs at the same level, as typed.
  static func markers(in text: NSAttributedString, range: NSRange) -> [(paragraph: NSRange, marker: String, level: Int)] {
    var result: [(NSRange, String, Int)] = []
    var counters: [Int: Int] = [:]
    let string = text.string as NSString
    string.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, paragraph, enclosing, stop in
      guard enclosing.location < text.length else { return }
      let block = (text.attribute(.noteBlock, at: enclosing.location, effectiveRange: nil) as? String).flatMap(NoteBlock.init(rawValue:))
      let level = text.attribute(.noteLevel, at: enclosing.location, effectiveRange: nil) as? Int ?? 0
      guard let block, block.isList else { counters.removeAll(); return }
      counters = counters.filter { $0.key <= level }
      let marker: String
      if block == .number { let n = (counters[level] ?? 0) + 1; counters[level] = n; marker = "\(n)." }
      else { counters[level] = nil; marker = level % 2 == 0 ? "•" : "◦" }
      if NSIntersectionRange(enclosing, range).length > 0 || NSLocationInRange(enclosing.location, range) {
        result.append((paragraph, marker, level))
      }
      if enclosing.location > NSMaxRange(range) { stop.pointee = true }
    }
    return result
  }
}
