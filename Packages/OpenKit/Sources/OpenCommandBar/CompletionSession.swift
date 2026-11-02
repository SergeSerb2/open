import AppKit
import OpenSuggest

/// Inline autocomplete in the field (docs/plans/commandbar-completion.md §4.1; CC-1…CC-7, CC-40).
///
/// The completion is real text in the field editor with a selection over it (D3): the AX value holds
/// the whole text (CC-3) and AppKit draws Arc's selection look (CC-2). It is never in the undo stack
/// and never posts a text change: every write here disables undo registration and edits the text
/// storage directly, so `controlTextDidChange` does not run. While a completion shows, the engine's
/// query text is `userText`, not the field text (D4).
@MainActor
final class CompletionSession {
    /// The completion in the field, or nil.
    private(set) var shown: InlineCompletion?
    /// What the user typed while `shown` is set. Without a completion the field text is the typed text.
    private(set) var userText = ""
    /// The current snapshot's completion for row 1. It shows only while row 1 is selected (D2).
    var available: InlineCompletion?
    /// The last edit was an insertion at the end of the text (§4.1.1 rule 2). Paste, deletion, undo,
    /// and caret moves turn it off until the next insertion at the end.
    var allowsCompletion = false
    /// True while the session itself writes into the field editor (no accept, no query).
    private(set) var isApplying = false

    func reset() {
        shown = nil; available = nil; userText = ""; allowsCompletion = false
    }

    /// Writes `completion` into `editor`: the field shows its text, the completed part selected.
    func show(_ completion: InlineCompletion, typed: String, in editor: NSTextView) {
        let length = (completion.fieldText as NSString).length
        let selection = NSRange(location: completion.typedLength, length: length - completion.typedLength)
        if shown == completion, userText == typed, editor.string == completion.fieldText, editor.selectedRange() == selection { return }
        userText = typed
        shown = completion
        write(completion.fieldText, selection: selection, in: editor)
    }

    /// Removes the completion: the field holds what the user typed, caret at the end.
    func hide(in editor: NSTextView) {
        guard shown != nil else { return }
        let typed = userText
        shown = nil
        write(typed, selection: NSRange(location: (typed as NSString).length, length: 0), in: editor)
    }

    /// The typed text continues the completion (§4.1.5): removes only the completion's first `count`
    /// UTF-16 units, which the insertion then replaces, so the rest stays in the field with no
    /// hide-then-show write. The session holds no completion until the controller shows the next one.
    func removeHead(_ count: Int, in editor: NSTextView) {
        guard let range = selectionRange, count < range.length else { return }
        shown = nil
        isApplying = true
        defer { isApplying = false }
        let undo = editor.undoManager
        undo?.disableUndoRegistration()
        defer { undo?.enableUndoRegistration() }
        editor.textStorage?.replaceCharacters(in: NSRange(location: range.location, length: count), with: "")
    }

    /// Removes text after `typed` (the rest of a kept completion that did not stay): caret at the end.
    func trim(to typed: String, in editor: NSTextView) {
        write(typed, selection: NSRange(location: (typed as NSString).length, length: 0), in: editor)
    }

    /// The completed text becomes typed text (Right, Left, a click…): the field keeps its text.
    func accept() {
        shown = nil
        allowsCompletion = false
    }

    /// The range of the completed part in the field, while one shows.
    var selectionRange: NSRange? {
        shown.map { NSRange(location: $0.typedLength, length: ($0.fieldText as NSString).length - $0.typedLength) }
    }

    private func write(_ text: String, selection: NSRange, in editor: NSTextView) {
        isApplying = true
        defer { isApplying = false }
        let undo = editor.undoManager
        undo?.disableUndoRegistration()
        defer { undo?.enableUndoRegistration() }
        if let storage = editor.textStorage, storage.string != text {
            // Replace only what differs (usually the completed tail), so the text system re-lays out less.
            let old = storage.string as NSString, new = text as NSString
            var start = 0
            let limit = min(old.length, new.length)
            while start < limit, old.character(at: start) == new.character(at: start) { start += 1 }
            if start > 0, start < old.length, (0xDC00...0xDFFF).contains(old.character(at: start)) { start -= 1 }
            storage.replaceCharacters(in: NSRange(location: start, length: old.length - start), with: new.substring(from: start))
        }
        editor.setSelectedRange(selection)
    }
}
