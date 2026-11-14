import AppKit
import OpenDesign

public enum BoostCodeLanguage: String, Sendable { case css, js }

/// Plain native text editing. Syntax attributes never enter the text undo stack.
@MainActor public final class CodeEditorView: NSTextView {
    public var language: BoostCodeLanguage = .css { didSet { if oldValue != language { highlightAll() } } }
    public var onEdit: ((String) -> Void)?
    public var onEndEditing: (() -> Void)?
    public private(set) var lastHighlightedCharacters = 0
    private let textUndo = UndoManager()
    private var editRange = NSRange(location: 0,length: 0)
    private var settingText = false
    private static let stateKey = NSAttributedString.Key("open.code.lexicalState")
    private static let cssPattern = try! NSRegularExpression(pattern: #"(/\*[\s\S]*?(?:\*/|$))|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(@[\w-]+)|([\w-]+(?=\s*:(?![^;{}\r\n]*\{)))|(?<![\w#-])(-?(?:\d*\.)?\d+(?:%|[a-z]+)?)"#)
    private static let jsPattern = try! NSRegularExpression(pattern: #"(/\*[\s\S]*?(?:\*/|$)|//[^\r\n]*)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`?)|\b(break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|function|if|import|in|instanceof|let|new|null|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|with|yield|async|await)\b|(\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?))"#)
    public override var needsPanelToBecomeKey: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var undoManager: UndoManager? { textUndo }
    public override var isOpaque: Bool { true }
    public init() {
        let storage = NSTextStorage(),layout = NSLayoutManager(),container = NSTextContainer(size: CGSize(width: 0,height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout);layout.addTextContainer(container)
        super.init(frame: .zero,textContainer: container)
        font = .monospacedSystemFont(ofSize: BoostEditorMetrics.codeFont,weight: .regular)
        textColor = BoostEditorColors.title.nsColor;backgroundColor = .white
        isRichText = false;importsGraphics = false;allowsUndo = true;usesFindBar = true
        isAutomaticQuoteSubstitutionEnabled = false;isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false;isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false;isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false;isGrammarCheckingEnabled = false
        isHorizontallyResizable = false;isVerticallyResizable = true;autoresizingMask = [.width]
        minSize = .zero;maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = true
        textContainerInset = BoostEditorMetrics.codeInset
        let paragraph = NSMutableParagraphStyle();paragraph.minimumLineHeight = BoostEditorMetrics.codeLineHeight;paragraph.maximumLineHeight = BoostEditorMetrics.codeLineHeight
        defaultParagraphStyle = paragraph
        typingAttributes = [.font: font!, .foregroundColor: textColor!, .paragraphStyle: paragraph]
        identifier = .init("editor.code.text");setAccessibilityLabel("CSS code")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func load(_ text: String,language: BoostCodeLanguage) {
        guard string != text || self.language != language else { return }
        settingText = true;self.language = language;string = text
        textUndo.removeAllActions();setSelectedRange(NSRange(location: (text as NSString).length,length: 0))
        highlightAll();scrollRangeToVisible(selectedRange());settingText = false
        setAccessibilityLabel(language == .css ? "CSS code" : "JavaScript code")
    }
    public override func shouldChangeText(in affectedCharRange: NSRange,replacementString: String?) -> Bool {
        editRange = NSRange(location: affectedCharRange.location,length: (replacementString as NSString?)?.length ?? 0)
        return super.shouldChangeText(in: affectedCharRange,replacementString: replacementString)
    }
    public override func didChangeText() {
        super.didChangeText();highlightEdit();enclosingScrollView?.verticalRulerView?.needsDisplay = true
        if !settingText { onEdit?(string) }
    }
    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder();if result { breakUndoCoalescing();onEndEditing?() };return result
    }
    public override func mouseDown(with event: NSEvent) { window?.makeKey();super.mouseDown(with: event) }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let value = language == .css ? "your css here" : "your javascript here"
            (value as NSString).draw(at: CGPoint(x: textContainerInset.width+textContainer!.lineFragmentPadding,y: textContainerInset.height),withAttributes: [.font: font!, .foregroundColor: BoostEditorColors.codePlaceholder.nsColor])
        }
    }
    public override func insertTab(_ sender: Any?) { insertText("  ",replacementRange: selectedRange()) }
    public override func insertBacktab(_ sender: Any?) { indent(outdent: true) }
    public override func insertNewline(_ sender: Any?) {
        let source = string as NSString,selection = selectedRange(),start = source.lineRange(for: NSRange(location: selection.location,length: 0)).location
        let prefix = source.substring(with: NSRange(location: start,length: selection.location-start))
        let spaces = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText("\n"+spaces+(prefix.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? "  " : ""),replacementRange: selection)
    }
    public override func insertText(_ insertString: Any,replacementRange: NSRange) {
        let value = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        if value == "}" {
            let source = string as NSString,selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let start = source.lineRange(for: NSRange(location: selection.location,length: 0)).location
            let prefix = source.substring(with: NSRange(location: start,length: selection.location-start))
            if !prefix.isEmpty && prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let count = prefix.hasSuffix("  ") ? 2 : 1
                super.insertText("}",replacementRange: NSRange(location: selection.location-count,length: selection.length+count));return
            }
        }
        super.insertText(insertString,replacementRange: replacementRange)
    }
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,event.modifierFlags.intersection([.command,.control,.option,.shift]) == .shift { insertBacktab(nil);return }
        super.keyDown(with: event)
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        if flags == .command || flags == [.command,.shift],event.charactersIgnoringModifiers?.lowercased() == "z" {
            breakUndoCoalescing();if flags.contains(.shift) { textUndo.redo() } else { textUndo.undo() };return true
        }
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "f": let item = NSMenuItem();item.tag = NSTextFinder.Action.showFindInterface.rawValue;performTextFinderAction(item);return true
            case "/": toggleComment();return true
            case "]": indent(outdent: false);return true
            case "[": indent(outdent: true);return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    private func selectedLines() -> NSRange {
        let source = string as NSString,varSelection = selectedRange()
        var selection = varSelection
        if selection.length>0 && NSMaxRange(selection)<=source.length && source.substring(with: NSRange(location: NSMaxRange(selection)-1,length: 1)) == "\n" { selection.length -= 1 }
        return source.lineRange(for: selection)
    }
    private func replaceLines(_ transform: (String) -> String) {
        let range = selectedLines(),value = transform((string as NSString).substring(with: range))
        breakUndoCoalescing();insertText(value,replacementRange: range);setSelectedRange(NSRange(location: range.location,length: (value as NSString).length));breakUndoCoalescing()
    }
    private func indent(outdent: Bool) {
        replaceLines { text in
            let trailing = text.hasSuffix("\n"),body = trailing ? String(text.dropLast()) : text
            return body.components(separatedBy: "\n").map { line in
                outdent ? (line.hasPrefix("  ") ? String(line.dropFirst(2)) : line.hasPrefix(" ") || line.hasPrefix("\t") ? String(line.dropFirst()) : line) : "  "+line
            }.joined(separator: "\n")+(trailing ? "\n" : "")
        }
    }
    private func toggleComment() {
        replaceLines { text in
            let trailing = text.hasSuffix("\n"),body = trailing ? String(text.dropLast()) : text
            let lines = body.components(separatedBy: "\n"),js = language == .js
            // Blank lines neither decide nor receive the toggle; a CRLF line keeps its "\r" outside the comment.
            func split(_ line: String) -> (String,String) { line.hasSuffix("\r") ? (String(line.dropLast()),"\r") : (line,"") }
            func blank(_ line: String) -> Bool { split(line).0.allSatisfy { $0 == " " || $0 == "\t" } }
            let uncomment = lines.contains { !blank($0) } && lines.allSatisfy { line in
                let s = split(line).0.trimmingCharacters(in: .whitespaces)
                return s.isEmpty || (js ? s.hasPrefix("//") : s.hasPrefix("/*") && s.hasSuffix("*/"))
            }
            return lines.map { whole in
                if blank(whole) { return whole }
                let (line,cr) = split(whole)
                let indent = String(line.prefix { $0 == " " || $0 == "\t" }),tail = String(line.dropFirst(indent.count))
                // CSS needs "*/" last; trailing blanks would make uncomment cut the wrong two characters.
                let content = js ? tail : tail.replacingOccurrences(of: #"[ \t]+$"#,with: "",options: .regularExpression)
                if uncomment {
                    var result = String(content.dropFirst(2));if !js { result = String(result.dropLast(2));if result.hasSuffix(" ") { result.removeLast() } };if result.hasPrefix(" ") { result.removeFirst() };return indent+result+cr
                }
                return indent+(js ? "// "+content : "/* "+content+" */")+cr
            }.joined(separator: "\n")+(trailing ? "\n" : "")
        }
    }
    private func highlightAll() { highlight(NSRange(location: 0,length: (string as NSString).length),propagate: false) }
    private func highlightEdit() {
        let source = string as NSString,n = source.length
        guard n>0 else { needsDisplay = true;return }
        var range = source.paragraphRange(for: NSRange(location: min(editRange.location,n),length: min(editRange.length,max(0,n-editRange.location))))
        if range.location>0 { range = NSUnionRange(range,source.paragraphRange(for: NSRange(location: range.location-1,length: 0))) }
        if NSMaxRange(range)<n { range = NSUnionRange(range,source.paragraphRange(for: NSRange(location: NSMaxRange(range),length: 0))) }
        lastHighlightedCharacters = 0;highlight(range,propagate: true)
        highlightVisible()
    }
    public func highlightVisible() {
        guard let layoutManager,let textContainer,(string as NSString).length>0 else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerInset.width,dy: -textContainerInset.height),in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs,actualGlyphRange: nil)
        guard let storage = textStorage else { return }
        // Already colored visible paragraphs need no new attribute edits. Scrolling
        // only fills gaps; edits invalidate and recolor their own paragraph span.
        var missing: [NSRange] = []
        storage.enumerateAttribute(Self.stateKey,in: chars) { value,range,_ in if value == nil { missing.append(range) } }
        for range in missing { highlight(range,propagate: false) }
    }
    private func highlight(_ requested: NSRange,propagate: Bool) {
        guard let storage = textStorage,storage.length>0 else { return }
        let source = storage.string as NSString,n = source.length
        var paragraph = source.paragraphRange(for: NSIntersectionRange(requested,NSRange(location: 0,length: n)))
        let end = NSMaxRange(paragraph)
        var state = paragraph.location>0 ? storage.attribute(Self.stateKey,at: paragraph.location-1,effectiveRange: nil) as? Int ?? 0 : 0
        storage.beginEditing()
        repeat {
            paragraph = source.paragraphRange(for: NSRange(location: paragraph.location,length: 0))
            let old = storage.attribute(Self.stateKey,at: NSMaxRange(paragraph)-1,effectiveRange: nil) as? Int ?? 0
            let line = source.substring(with: paragraph) as NSString
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: BoostEditorMetrics.codeFont,weight: .regular),.foregroundColor: BoostEditorColors.title.nsColor],range: paragraph)
            var offset = 0
            if state != 0 {
                let terminator = state == 1 ? "*/" : "`",found = line.range(of: terminator)
                offset = found.location == NSNotFound ? line.length : NSMaxRange(found)
                storage.addAttribute(.foregroundColor,value: (state == 1 ? BoostEditorColors.codeComment : BoostEditorColors.codeString).nsColor,range: NSRange(location: paragraph.location,length: offset))
                if found.location != NSNotFound { state = 0 }
            }
            if state == 0 {
                let regex = language == .css ? Self.cssPattern : Self.jsPattern
                regex.enumerateMatches(in: line as String,range: NSRange(location: offset,length: line.length-offset)) { match,_,_ in
                    guard let match else { return }
                    let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound } ?? 0
                    let color = group == 1 ? BoostEditorColors.codeComment : group == 2 ? BoostEditorColors.codeString : group == 3 ? BoostEditorColors.codeKeyword : language == .css && group == 4 ? BoostEditorColors.codeProperty : BoostEditorColors.codeNumber
                    let local = match.range,global = NSRange(location: paragraph.location+local.location,length: local.length)
                    storage.addAttribute(.foregroundColor,value: color.nsColor,range: global)
                    if group == 3 { storage.addAttribute(.font,value: NSFont.monospacedSystemFont(ofSize: BoostEditorMetrics.codeFont,weight: .semibold),range: global) }
                    let token = line.substring(with: local)
                    if group == 1 && token.hasPrefix("/*") && !token.hasSuffix("*/") { state = 1 }
                    if group == 2 && token.hasPrefix("`") && (token.count == 1 || !token.hasSuffix("`")) { state = 2 }
                }
            }
            storage.addAttribute(Self.stateKey,value: state,range: paragraph)
            lastHighlightedCharacters += paragraph.length
            let next = NSMaxRange(paragraph)
            if next>=n || next>=end && (!propagate || state == old) { break }
            paragraph = NSRange(location: next,length: 0)
        } while true
        storage.endEditing();needsDisplay = true
    }
}

@MainActor final class CodeLineRuler: NSRulerView {
    weak var editor: CodeEditorView?
    init(scrollView: NSScrollView,editor: CodeEditorView) { self.editor = editor;super.init(scrollView: scrollView,orientation: .verticalRuler);clientView = editor;ruleThickness = BoostEditorMetrics.gutterWidth }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.white.setFill();bounds.fill()
        guard let editor,let layout = editor.layoutManager,let container = editor.textContainer else { return }
        let source = editor.string as NSString,visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible,in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs,actualGlyphRange: nil)
        var index = source.lineRange(for: NSRange(location: min(chars.location,source.length),length: 0)).location
        // Count lines the way lineRange(for:) splits them: "\r\n" is one Character
        // (never == "\n"), and lone "\r" and U+2028 also end a line.
        var number = source.substring(to: index).reduce(1) { ["\n","\r","\r\n","\u{85}","\u{2028}","\u{2029}"].contains($1) ? $0+1 : $0 }
        var end = 0,contentsEnd = 0
        if source.length>0 { source.getLineStart(nil,end: &end,contentsEnd: &contentsEnd,for: NSRange(location: source.length-1,length: 0)) }
        let endsWithBreak = source.length == 0 || contentsEnd<end
        repeat {
            let lineRect: CGRect
            if index<source.length { lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index),effectiveRange: nil) }
            else if endsWithBreak { lineRect = layout.extraLineFragmentRect }
            // No empty last line after unterminated text: its zero rect would draw over line 1.
            else { break }
            let point = convert(CGPoint(x: 0,y: lineRect.minY+editor.textContainerInset.height),from: editor)
            let text = String(number) as NSString,attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: BoostEditorMetrics.gutterFont,weight: .regular),.foregroundColor: BoostEditorColors.codeGutter.nsColor]
            text.draw(at: CGPoint(x: ruleThickness-text.size(withAttributes: attrs).width-BoostEditorMetrics.codeInset.width,y: point.y),withAttributes: attrs)
            if index>=source.length { break }
            index = NSMaxRange(source.lineRange(for: NSRange(location: index,length: 0)));number += 1
        } while index<=min(source.length,NSMaxRange(chars))
    }
}
