import AppKit

/// Notes are bounded before Foundation parses Markdown. No HTML importer or web view.
@MainActor
final class UpdateReleaseNotesView: NSView, NSTextViewDelegate {
  static let inputLimit = 64 * 1024
  let heading = NSTextField(labelWithString: "")
  let text = NSTextView()
  private let scroll = NSScrollView()
  private var source = ""
  private var format = "markdown"
  var openLink: ((URL) -> Void)?

  init(title: String, source: String, format: String) {
    super.init(frame: .zero)
    wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
    let boundedTitle = Self.boundedUTF8(title, limit: 1024)
    heading.stringValue = boundedTitle.isEmpty ? "A new version is available" : boundedTitle
    heading.font = .boldSystemFont(ofSize: 14); heading.isSelectable = true
    heading.maximumNumberOfLines = 2; heading.lineBreakMode = .byWordWrapping
    text.isEditable = false; text.isSelectable = true; text.delegate = self
    text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
    text.textContainer?.heightTracksTextView = false
    scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = text
    addSubview(heading); addSubview(scroll)
    setNotes(source, format: format)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  static func boundedUTF8(_ value: String, limit: Int = inputLimit) -> String {
    var bytes = Array(value.utf8.prefix(limit))
    // The source String is valid UTF-8. Only its final scalar can be partial.
    while let last = bytes.last {
      if let string = String(bytes: bytes, encoding: .utf8) { return string }
      bytes.removeLast()
      if last < 0x80 { break }
    }
    return ""
  }
  func setNotes(_ value: String, format: String) {
    // Bound the source before Foundation parses it; no remote attachments.
    source = Self.boundedUTF8(value)
    self.format = format.lowercased(); render()
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
  private func render() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let ink = dark ? NSColor.white : NSColor(srgbRed: 20/255, green: 20/255, blue: 20/255, alpha: 1)
    let background = dark ? NSColor.black : .textBackgroundColor
    effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = background.cgColor }
    text.backgroundColor = background
    heading.textColor = ink
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
    paragraph.paragraphSpacing = 8
    let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink, .paragraphStyle: paragraph]
    let rendered = NSMutableAttributedString(string: "")
    if source.isEmpty {
      rendered.append(NSAttributedString(string: "Thanks for using Open!", attributes: base))
    } else if format == "html" || format == "plain-text" {
      rendered.append(NSAttributedString(string: format == "html" ? Self.plainHTML(source) : source, attributes: base))
    } else {
      let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible)
      if let markdown = try? AttributedString(markdown: source, options: options) {
        var previousBlock: Int?
        var previousListItem: Int?
        for run in markdown.runs {
          let components = run.presentationIntent?.components ?? []
          let block = components.first?.identity
          if rendered.length > 0, let block, block != previousBlock {
            rendered.append(NSAttributedString(string: "\n", attributes: base))
          }
          previousBlock = block
          // Foundation supplies block semantics; this only maps them to native
          // text attributes and list markers. It does not parse Markdown itself.
          if let listItem = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
            listItem.identity != previousListItem, case .listItem(let ordinal) = listItem.kind {
            let ordered = components.contains { $0.kind == .orderedList }
            rendered.append(NSAttributedString(string: ordered ? "\(ordinal). " : "• ", attributes: base))
            previousListItem = listItem.identity
          }
          var attributes = base
          var traits: NSFontTraitMask = []
          if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.boldFontMask) }
          if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.italicFontMask) }
          if components.contains(where: { if case .header = $0.kind { true } else { false } }) { traits.insert(.boldFontMask) }
          attributes[.font] = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: traits)
          if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
          rendered.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
      } else { rendered.append(NSAttributedString(string: source, attributes: base)) }
    }
    if rendered.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      rendered.setAttributedString(NSAttributedString(string: "Thanks for using Open!", attributes: base))
    }
    text.linkTextAttributes = [.foregroundColor: NSColor(srgbRed: 0x45/255, green: 0x8A/255, blue: 1, alpha: 1)]
    text.textStorage?.setAttributedString(rendered)
    needsLayout = true
  }
  /// One bounded, non-recursive pass. Tags never become formatting or executable content.
  private static func plainHTML(_ input: String) -> String {
    let chars = Array(input); var result = ""; var i = 0; var inTag = false
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
    while i < chars.count {
      let c = chars[i]
      if c == "<" { inTag = true; i += 1; continue }
      if inTag { if c == ">" { inTag = false }; i += 1; continue }
      if c == "&", let end = chars[i..<min(chars.count, i + 7)].firstIndex(of: ";"),
        let decoded = entities[String(chars[i...end])] { result += decoded; i = end + 1; continue }
      result.append(c); i += 1
    }
    return result
  }
  override func layout() {
    super.layout()
    let width = max(1, bounds.width - 64)
    let headingHeight = min(40, ceil(heading.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 40)).height ?? 18))
    heading.frame = NSRect(x: 32, y: 20, width: width, height: headingHeight)
    let bodyTop = heading.frame.maxY + 12
    // The heading and body share 32 pt horizontal insets.
    scroll.frame = NSRect(x: 32, y: bodyTop, width: width, height: max(0, bounds.height - bodyTop - 16))
    if let container = text.textContainer, let manager = text.layoutManager {
      container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
      manager.ensureLayout(for: container)
      text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, ceil(manager.usedRect(for: container).height))))
    }
  }
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    if let url = link as? URL { openLink?(url) }
    else if let string = link as? String, let url = URL(string: string) { openLink?(url) }
    return true
  }
}
