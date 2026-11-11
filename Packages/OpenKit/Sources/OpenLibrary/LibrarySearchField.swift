import AppKit

/// A plain search text field with its own small, retained TextKit 1 editor.
/// Search does not need rich text, prediction, writing tools or substitutions.
@MainActor
final class LibrarySearchField: LibraryField {
    override class var cellClass: AnyClass? { get { LibrarySearchCell.self } set {} }
    private var editorStorage: LibrarySearchEditor?
    var timestamps: [String:Double] = [:]
    override init(frame:NSRect) {
        super.init(frame:frame)
        (cell as? LibrarySearchCell)?.editorProvider = { [weak self] in self?.editor() }
        cell?.isScrollable = true; cell?.wraps = false
    }
    required init?(coder:NSCoder) { fatalError() }
    func note(_ name:String) { timestamps[name] = ProcessInfo.processInfo.systemUptime }
    func beginMeasurement() { timestamps = [:]; note("dispatch") }
    private func editor() -> LibrarySearchEditor {
        if let editorStorage { return editorStorage }
        let editor = LibrarySearchEditor(usingTextLayoutManager:false); editorStorage = editor
        editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticTextCompletionEnabled = false
        editor.inlinePredictionType = .no; editor.writingToolsBehavior = .none
        editor.onKeyDown = { [weak self] in self?.note("editorKeyDown") }
        editor.onTextChange = { [weak self] in self?.note("textChanged") }
        return editor
    }
    func warmEditor() {
        let editor = editor()
        editor.font = font; editor.string = "Library search"
        editor.layoutManager?.ensureLayout(for:editor.textContainer!)
        editor.string = ""
    }
}

@MainActor
private final class LibrarySearchCell: NSTextFieldCell {
    var editorProvider: (() -> NSTextView?)?
    override func fieldEditor(for controlView:NSView) -> NSTextView? { editorProvider?() }
}

@MainActor
private final class LibrarySearchEditor: NSTextView {
    var onKeyDown: (() -> Void)?
    var onTextChange: (() -> Void)?
    override func keyDown(with event:NSEvent) { onKeyDown?(); super.keyDown(with:event) }
    override func didChangeText() { onTextChange?(); super.didChangeText() }
}
