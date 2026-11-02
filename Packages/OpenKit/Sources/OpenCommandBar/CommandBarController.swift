import AppKit
import OpenDesign
import OpenModel
import OpenSuggest

/// Runs the command bar: owns the overlay view, sends each keystroke to `SuggestEngine`,
/// applies its snapshots, handles keys and the mouse, and reports choices as
/// `CommandBarIntent`s. It never touches the engine layer or the model.
///
/// Snapshot rules (docs/commandbar.md §4):
/// - A new query selects row 0 (Arc selects the first row even with no top hit, F0063).
/// - Later snapshots of the same query keep the selection on the same suggestion id once
///   the user moved it (keys or pointer). Before that, the selection follows row 0, so it
///   changes only when the top hit changes.
@MainActor
public final class CommandBarController: NSObject {
    public let engine: SuggestEngine
    public weak var delegate: CommandBarDelegate?
    public let view: CommandBarView
    public var favicons: CommandBarFaviconSource? {
        didSet { panel.results.favicons = favicons; panel.input.favicons = favicons }
    }
    public var theme = CommandBarTheme.default {
        didSet { panel.results.theme = theme; panel.input.theme = theme }
    }
    /// What lies behind the panel. Set before `present`.
    public var backdrop = CommandBarBackdrop.darkPage { didSet { applyBackdrop() } }
    /// Open's privacy page, the target of "here" in the (i) footer. Nil hides that line (no dead link).
    public var privacyURL: URL? { didSet { panel.footer.showsLearnMore = privacyURL != nil } }
    /// True while the (i) privacy footer shows (CC-42).
    public var showsPrivacyFooter: Bool { view.showsFooter }

    public private(set) var isPresented = false
    public private(set) var request: CommandBarRequest?
    /// What the user typed: the engine's query text (D4). Equals `fieldText` unless an inline
    /// completion shows; then the field also holds the completed part.
    public var text: String { completion.shown != nil ? completion.userText : panel.input.field.stringValue }
    /// The field's whole text, an inline completion included (the AX value, CC-3).
    public var fieldText: String { panel.input.field.stringValue }
    /// The inline completion in the field, while one shows (§4.1).
    public var inlineCompletion: InlineCompletion? { completion.shown }
    /// Inline completion on (Arc has no setting for it). The keystroke bench turns it off for its A/B run.
    public var allowsInlineCompletion = true
    /// Site Search scope, while the chip shows.
    public private(set) var siteScope: SiteSearch?
    /// Drawn rows and the suggestions behind them (same order).
    public private(set) var rows: [CommandBarRow] = []
    public private(set) var suggestions: [Suggestion] = []
    public var selectedIndex: Int? { panel.results.selectedIndex }
    public var selectedSuggestion: Suggestion? {
        guard let i = selectedIndex, suggestions.indices.contains(i) else { return nil }
        return suggestions[i]
    }
    /// True once the user moved the selection in this query.
    public private(set) var userMovedSelection = false
    /// Sequence of the snapshot last applied, and its query.
    public private(set) var appliedSequence = -1
    public private(set) var appliedQuery: String?
    /// True when the last applied snapshot was the stream's final one.
    public private(set) var isSnapshotFinal = false

    /// Called before and after each snapshot is applied to the views (diagnostics and checks).
    public var onSnapshotWillApply: ((SuggestionSnapshot) -> Void)?
    public var onSnapshotApplied: ((SuggestionSnapshot) -> Void)?
    /// Called when a query is submitted (diagnostics and end-to-end flows).
    public var onQueryStarted: ((String) -> Void)?
    /// The App uses the same enabled-state validation as its menus.
    public var isActionEnabled: ((String, SpaceID?) -> Bool)?

    private var panel: PanelView { view.panel }
    private var streamTask: Task<Void, Never>?
    private var generation = 0
    private var siteHint: SiteSearch?
    /// The text `siteHint` was computed for.
    private var hintText = ""
    private var hintAllowsSpace = false
    private var pendingReturn: (generation: Int, text: String, modifiers: CommandBarModifiers)?
    private var queriedText: String?
    /// Selection to set when the field gets focus: all of Cmd+L's URL, else the caret at the end.
    private var focusSelection: NSRange?
    private let completion = CompletionSession()
    /// The running query may carry an inline completion (§4.1.1 rule 2).
    private var queryAllowsCompletion = false

    public init(engine: SuggestEngine) {
        self.engine = engine
        view = CommandBarView(frame: .zero)
        super.init()
        view.isHidden = true
        view.onClickOutside = { [weak self] in self?.dismiss(reason: .clickOutside) }
        let field = panel.input.field
        field.delegate = self
        panel.input.editor.onModifiedReturn = { [weak self] flags in self?.handle(#selector(NSResponder.insertNewline(_:)), flags: flags) ?? false }
        panel.input.editor.onCompositionEnded = { [weak self] in
            self?.queriedText = nil
            self?.textChanged()
        }
        // Cmd+I and the (i) button toggle the privacy footer; nothing else shows it (D14).
        panel.input.editor.onHelp = { [weak self] in
            guard let self, self.isPresented else { return false }
            self.togglePrivacyFooter()
            return true
        }
        view.onMoveToWindow = { [weak self] in self?.focusInput() }
        panel.input.infoButton.action = { [weak self] in self?.togglePrivacyFooter() }
        panel.footer.settingsButton.action = { [weak self] in self?.openSearchSettings() }
        panel.footer.dismissButton.action = { [weak self] in self?.dismissPrivacyNotice() }
        panel.footer.link.action = { [weak self] in self?.openPrivacyPage() }
        let editor = panel.input.editor
        editor.observeUndo()
        editor.onBeforeEdit = { [weak self] insertion, replacing in self?.beforeEdit(insertion, replacing: replacing) ?? .none }
        editor.onBeforeUndo = { [weak self] in
            guard let self else { return }
            _ = self.removeCompletionForEdit()
        }
        editor.onSelectionChange = { [weak self] in self?.selectionChanged() }
        panel.results.onHover = { [weak self] i in self?.hover(i) }
        panel.results.onClick = { [weak self] i, flags in self?.choose(i, modifiers: CommandBarModifiers(flags)) }
    }

    // MARK: Presentation

    /// Opens the bar (or switches it to another mode while open). The panel shows in the next
    /// frame at full size and opacity: Arc's bar has no open animation (CC-44, D12).
    public func present(_ request: CommandBarRequest) {
        pendingReturn = nil
        panel.input.editor.resetSession()
        self.request = request
        siteScope = nil
        engine.prewarm()
        let field = panel.input.field
        let initial = request.mode == .editCurrentURL ? (request.currentTabURL?.absoluteString ?? "") : ""
        completion.reset()
        field.stringValue = CommandBarFieldEditor.normalized(initial)
        panel.input.textDidChange()
        isPresented = true
        view.isActive = true
        view.showsFooter = false // The footer never opens by itself (D14).
        view.setShown(true)
        applyBackdrop()
        focusSelection = request.mode == .editCurrentURL ? NSRange(location: 0, length: (text as NSString).length) : nil
        runQuery(text, applyInitialImmediately: true)
        view.layoutSubtreeIfNeeded()
        focusInput()
        delegate?.commandBar(self, didChangePresentation: true, mode: request.mode)
    }

    /// Shows fixed content without a query: renders, design review, and docs.
    public func presentPreview(_ preview: CommandBarPreview) {
        pendingReturn = nil
        panel.input.editor.resetSession()
        streamTask?.cancel()
        generation += 1
        request = CommandBarRequest(mode: preview.mode)
        isPresented = true
        view.isActive = true
        view.showsFooter = preview.showsFooter
        view.setShown(true)
        applyBackdrop()
        let field = panel.input.field
        completion.reset()
        field.stringValue = CommandBarFieldEditor.normalized(preview.text)
        panel.input.textDidChange()
        suggestions = []
        rows = preview.rows
        panel.input.input = preview.input
        panel.results.resetScroll()
        panel.results.setRows(preview.rows, selected: preview.selectedIndex)
        view.visibleRowCount = min(preview.rows.count, CommandBarMetrics.maxVisibleRows)
        panel.showsSeparator = !preview.rows.isEmpty
        appliedQuery = text
        queriedText = nil
        appliedSequence = 0
        isSnapshotFinal = true
        view.layoutSubtreeIfNeeded()
        let length = (preview.text as NSString).length
        focusSelection = preview.selectedRange ?? (preview.selectAllText ? NSRange(location: 0, length: length) : nil)
        focusInput()
    }

    public func editingUndoManager(for responder: NSResponder?) -> UndoManager? {
        responder === panel.input.editor ? panel.input.editor.undoManager : nil
    }

    /// Closes the bar. The panel goes in the next frame (CC-44, D12).
    public func dismiss(reason: CommandBarDismissReason) {
        pendingReturn = nil
        panel.input.editor.resetSession()
        guard isPresented else { return }
        completion.reset()
        let mode = request?.mode ?? .newTab
        isPresented = false
        view.isActive = false
        streamTask?.cancel()
        streamTask = nil
        engine.cancel()
        pendingReturn = nil
        if reason != .selection { delegate?.commandBar(self, perform: .dismissed(reason)) }
        if view.window?.firstResponder === panel.input.field.currentEditor() { view.window?.makeFirstResponder(nil) }
        view.showsFooter = false
        view.setShown(false)
        delegate?.commandBar(self, didChangePresentation: false, mode: mode)
    }

    private func focusInput() {
        guard isPresented, let window = view.window else { return }
        let field = panel.input.field
        window.makeFirstResponder(field)
        // Cmd+L selects the whole URL, including when presented before attachment.
        let length = (fieldText as NSString).length
        field.currentEditor()?.selectedRange = focusSelection ?? NSRange(location: length, length: 0)
        panel.input.editor.undoManager?.removeAllActions()
    }

    private func applyBackdrop() {
        panel.backdropIsDark = backdrop.isDark
        if let image = backdrop.image, view.bounds.width > 0 {
            let tallest = CommandBarMetrics.panelFrame(windowSize: view.bounds.size, rows: CommandBarMetrics.maxVisibleRows)
            panel.material.apply(image: image, imageScale: backdrop.imageScale, panelRect: tallest, fallback: backdrop.color)
        } else {
            panel.material.apply(color: backdrop.color)
        }
    }

    // MARK: Privacy footer (CC-42, D14)

    /// (i) or Cmd+I: shows or hides the footer. The panel changes in one frame (D12).
    public func togglePrivacyFooter() {
        guard isPresented else { return }
        view.showsFooter.toggle()
        view.layoutSubtreeIfNeeded()
        if let i = selectedIndex { panel.results.select(i) } // keep the highlighted row out from behind the band
    }

    /// Updates the request's remote-suggestion permission, for example after the App recorded
    /// the notice dismissal. Takes effect with the next query.
    public func setAllowsRemoteSuggestions(_ allowed: Bool) {
        request?.allowsRemoteSuggestions = allowed
    }

    private func dismissPrivacyNotice() {
        guard isPresented, view.showsFooter else { return }
        view.showsFooter = false
        view.layoutSubtreeIfNeeded()
        delegate?.commandBarDidDismissPrivacyNotice(self)
        guard isPresented else { return }
        runQuery(text) // so remote rows can arrive now
    }

    private func openSearchSettings() {
        guard isPresented else { return }
        let profile = request?.profileID
        dismiss(reason: .selection)
        delegate?.commandBar(self, perform: .openSearchSettings(profileID: profile))
    }

    private func openPrivacyPage() {
        guard isPresented, let url = privacyURL else { return }
        dismiss(reason: .selection)
        delegate?.commandBar(self, perform: .open(url, .newTab, []))
    }

    // MARK: Query

    private func context() -> SuggestContext {
        let r = request ?? CommandBarRequest(mode: .newTab)
        return SuggestContext(mode: r.mode.suggestMode, profileID: r.profileID, spaceID: r.spaceID, currentTabID: r.currentTabID,
                              currentTabURL: r.currentTabURL, allowsRemoteSuggestions: r.allowsRemoteSuggestions,
                              searchEngineID: r.searchEngineID, siteSearchID: siteScope?.id, allowsInlineCompletion: queryAllowsCompletion)
    }

    /// Opening applies ready local rows before cold focus work. Text edits
    /// retain the next-turn boundary so a queued Return can still be cancelled by
    /// another edit, presentation or dismissal. Later providers use the stream.
    func runQuery(_ text: String, applyInitialImmediately: Bool = false, allowsCompletion: Bool = false) {
        pendingReturn = nil
        guard !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return }
        queryAllowsCompletion = allowsCompletion
        generation += 1
        let gen = generation
        userMovedSelection = false
        appliedSequence = -1
        isSnapshotFinal = false
        queriedText = text
        updateSiteHint(text)
        streamTask?.cancel()
        onQueryStarted?(text)
        var receiveInitial: ((SuggestionSnapshot) -> Void)?
        if applyInitialImmediately {
            receiveInitial = { [weak self] snapshot in
                guard let self, self.generation == gen, self.isPresented else { return }
                self.apply(snapshot)
            }
        }
        let stream = engine.query(text, context: context(), receiveInitialSnapshot: receiveInitial)
        guard generation == gen, isPresented else { return }
        streamTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self, self.generation == gen, self.isPresented else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: SuggestionSnapshot) {
        guard snapshot.query == text, !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return }
        onSnapshotWillApply?(snapshot)
        let appliedGeneration = generation
        let r = request
        let visible = snapshot.suggestions.filter {
            guard $0.kind != .siteSearchHint else { return false }
            if $0.kind == .action, let id = $0.actionID { return isActionEnabled?(id, $0.spaceID) ?? true }
            return true
        }
        let newRows = visible.map {
            RowPresentation.row($0, mode: r?.mode ?? .newTab, currentSpaceID: r?.spaceID, currentURL: r?.currentTabURL, currentTitle: r?.currentTabTitle)
        }
        let firstOfQuery = appliedSequence < 0
        var selected: Int?
        if newRows.isEmpty {
            selected = nil
        } else if firstOfQuery || !userMovedSelection {
            selected = 0
        } else if let id = selectedSuggestion?.id, let i = visible.firstIndex(where: { $0.id == id }) {
            selected = i
        } else {
            selected = min(selectedIndex ?? 0, newRows.count - 1)
        }
        suggestions = visible
        rows = newRows
        if firstOfQuery { panel.results.resetScroll() }
        panel.results.setRows(newRows, selected: selected)
        if let s = selected, userMovedSelection { panel.results.scrollToVisible(s) }
        view.visibleRowCount = min(newRows.count, CommandBarMetrics.maxVisibleRows)
        panel.showsSeparator = !newRows.isEmpty
        // The completion belongs to row 1 (D2) and needs the edit that allowed it (§4.1.1 rules 2, 5).
        if let c = snapshot.inlineCompletion, queryAllowsCompletion, completion.allowsCompletion, c.rowID == visible.first?.id {
            completion.available = c
        } else {
            completion.available = nil
        }
        updateCompletionDisplay()
        updateInputPresentation()
        appliedSequence = snapshot.sequence
        appliedQuery = snapshot.query
        isSnapshotFinal = snapshot.isFinal
        onSnapshotApplied?(snapshot)
        guard generation == appliedGeneration, isPresented, snapshot.query == text else { return }
        if let pending = pendingReturn, pending.generation == generation, pending.text == text,
           snapshot.query == text, let i = selectedIndex {
            pendingReturn = nil
            choose(i, modifiers: pending.modifiers)
        } else if firstOfQuery {
            // An empty first snapshot is still a snapshot: Return never waits for providers.
            pendingReturn = nil
        }
    }

    // MARK: Input row

    private func updateSiteHint(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        siteHint = nil
        hintText = text
        hintAllowsSpace = false
        guard siteScope == nil, request?.mode != .searchTabs, !trimmed.isEmpty, !trimmed.contains(" ") else { return }
        if let site = engine.siteSearchTrigger(for: trimmed) {
            siteHint = site
            // Space enters the scope only when the text is the site's name or keyword exactly, so
            // typing words that merely start a site name keeps working. guess (F0040 shows "or Space").
            let folded = TextMatching.fold(trimmed)
            hintAllowsSpace = TextMatching.fold(site.name) == folded || site.keywords.contains { TextMatching.fold($0) == folded }
        }
    }

    private func updateInputPresentation() {
        let r = request
        var input = CommandBarInput(placeholder: CommandBarText.placeholder, leadingIcon: .symbol("magnifyingglass", plate: false))
        if r?.mode == .searchTabs { input.placeholder = CommandBarText.searchTabsPlaceholder }
        if let site = siteScope {
            input.placeholder = CommandBarText.siteSearchPlaceholder(site.name)
            input.chip = .init(name: site.name, icon: siteIcon(site))
        }
        let typed = text
        if typed.isEmpty || siteScope != nil {
            input.leadingIcon = .symbol("magnifyingglass", plate: false)
        } else if r?.mode == .editCurrentURL, let current = r?.currentTabURL, typed == current.absoluteString {
            input.leadingIcon = .favicon(current, fallback: "globe") // Cmd+L shows the page favicon (F0048)
        } else if let top = suggestions.first {
            input.leadingIcon = rows.first.map(\.icon).map { icon in
                if case .symbol(let name, _) = icon { return .symbol(name, plate: false) }
                return icon
            } ?? .symbol("magnifyingglass", plate: false)
            if top.kind == .navigate, case .symbol = input.leadingIcon { input.leadingIcon = .symbol("globe", plate: false) }
        }
        if let site = siteHint {
            // Never "or Space" while a completion shows (CC-5, CC-40).
            input.trailing = .siteSearchHint(name: site.name, space: hintAllowsSpace && completion.shown == nil)
        } else {
            input.trailing = .info
        }
        panel.input.input = input
    }

    private func siteIcon(_ site: SiteSearch) -> CommandBarIcon {
        let host = site.host.split(separator: "/").first.map(String.init) ?? site.host
        if let u = URL(string: "https://\(host)/") { return .favicon(u, fallback: "magnifyingglass") }
        return .symbol("magnifyingglass", plate: false)
    }

    /// Enters Site Search for `site`. The trigger word becomes the chip; text after it stays the query.
    public func enterSiteSearch(_ site: SiteSearch, remainder: String = "") {
        // The scope takes the typed text, never the completion (§4.1.5 Tab).
        if let editor = activeEditor { completion.hide(in: editor) }
        completion.reset()
        siteScope = site
        panel.input.setText(remainder)
        panel.input.needsLayout = true
        runQuery(text)
    }

    /// Leaves Site Search (Backspace on an empty query, features-core §4.6 rule 16).
    public func exitSiteSearch() {
        guard siteScope != nil else { return }
        siteScope = nil
        panel.input.needsLayout = true
        runQuery(text)
    }

    // MARK: Selection

    public func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(0, current + delta), rows.count - 1)
        guard next != selectedIndex else { return }
        userMovedSelection = true
        panel.results.select(next)
        updateCompletionDisplay() // only row 1 shows its completion (D2); no query
    }

    private func hover(_ index: Int) {
        guard index != selectedIndex else { return }
        userMovedSelection = true
        panel.results.select(index)
        updateCompletionDisplay()
    }

    /// Return on the selection, or a click on row `index`.
    public func choose(_ index: Int, modifiers: CommandBarModifiers = []) {
        guard suggestions.indices.contains(index), let r = request else { return }
        let s = suggestions[index]
        if s.kind == .action, let id = s.actionID, isActionEnabled?(id, s.spaceID) == false {
            runQuery(text); return
        }
        let destination: CommandBarDestination = r.mode == .editCurrentURL ? .currentTab : .newTab
        let intent: CommandBarIntent?
        switch s.kind {
        case .navigate, .history:
            intent = s.url.map { .open($0, destination, modifiers) }
        case .search, .searchSuggestion, .siteSearch:
            let query = s.kind == .siteSearch ? text.trimmingCharacters(in: .whitespaces) : s.title
            intent = s.url.map { .search(query: query, url: $0, siteSearchID: s.siteSearchID, destination, modifiers) }
        case .switchToTab:
            intent = s.tabID.map { .switchToTab($0, spaceID: s.spaceID) }
        case .action:
            intent = s.actionID.map { .runAction(id: $0, spaceID: s.spaceID) }
        case .calculator:
            intent = .copy(s.title)
        case .siteSearchHint:
            if let id = s.siteSearchID, let site = engine.siteSearch(id: id) { enterSiteSearch(site) }
            return
        }
        guard let intent else { return }
        dismiss(reason: .selection)
        delegate?.commandBar(self, perform: intent)
    }

    // MARK: Keys

    /// Handles a text-system command from the field editor. Returns true when consumed.
    func handle(_ selector: Selector, flags: NSEvent.ModifierFlags) -> Bool {
        guard isPresented, !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            returnPressed(CommandBarModifiers(flags)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(reason: .escape); return true
        case #selector(NSResponder.insertTab(_:)):
            if let site = siteHint {
                enterSiteSearch(site)
                return true
            }
            return false // Without a Site Search hint, use normal AppKit focus traversal.
        case #selector(NSResponder.insertBacktab(_:)):
            return false
        case #selector(NSResponder.deleteBackward(_:)):
            if siteScope != nil, text.isEmpty { exitSiteSearch(); return true }
            return removeCompletionByDeletion()
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)),
             #selector(NSResponder.deleteWordForward(_:)), #selector(NSResponder.deleteToEndOfLine(_:)):
            return removeCompletionByDeletion()
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfParagraph(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)): // End
            // Accept: the whole text becomes typed text, caret at the end (CC-7; key set guess).
            guard completion.shown != nil, let editor = activeEditor else { return false }
            completion.accept()
            editor.setSelectedRange(NSRange(location: (fieldText as NSString).length, length: 0))
            runQuery(text)
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)):
            // The completed text becomes typed text; the native move puts the caret (guess, Q7).
            guard completion.shown != nil else { return false }
            completion.accept()
            runQuery(text)
            return false
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)): // Home: AppKit only scrolls; the caret goes to the start (guess)
            guard completion.shown != nil, let editor = activeEditor else { return false }
            completion.accept()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            runQuery(text)
            return true
        default:
            return false
        }
    }

    // MARK: Inline completion (§4.1.4–§4.1.8)

    private var activeEditor: CommandBarFieldEditor? {
        let editor = panel.input.editor
        return panel.input.field.currentEditor() === editor ? editor : nil
    }

    /// Shows the available completion while row 1 is selected; otherwise the field holds the typed text.
    private func updateCompletionDisplay() {
        guard let editor = activeEditor, !editor.hasMarkedText(), !editor.isUpdatingComposition else { return }
        if let c = completion.available, completion.allowsCompletion, selectedIndex == 0 {
            completion.show(c, typed: text, in: editor)
        } else {
            completion.hide(in: editor)
        }
    }

    /// Before typing, an IME change, or a paste. Typed text that continues the completion replaces only
    /// the completion's first characters, so the rest stays on screen and nothing is written twice (§4.1.5).
    /// Anything else removes the whole completion first (`removeCompletionForEdit`).
    private func beforeEdit(_ insertion: String?, replacing: NSRange) -> CommandBarFieldEditor.CompletionEdit {
        guard let editor = activeEditor, let shown = completion.shown, let range = completion.selectionRange else { return .none }
        if let insertion, replacing.location == NSNotFound || NSEqualRanges(replacing, range) {
            let n = (insertion as NSString).length
            if n > 0, n < range.length,
               TextMatching.fold((shown.fieldText as NSString).substring(with: NSRange(location: range.location, length: n))) == TextMatching.fold(insertion) {
                hiddenForEdit = shown
                completion.removeHead(n, in: editor)
                return .kept(location: range.location, tail: range.length - n)
            }
        }
        return removeCompletionForEdit().map { .removed($0) } ?? .none
    }

    /// Before an edit or an undo: the field goes back to the typed text, so the edit applies to it.
    /// Returns the completion's former range. The completion is remembered so a character that matches
    /// it keeps it on screen (no flicker, §4.1.5).
    private func removeCompletionForEdit() -> NSRange? {
        guard let editor = activeEditor, let range = completion.selectionRange else { return nil }
        hiddenForEdit = completion.shown
        completion.hide(in: editor)
        return range
    }
    private var hiddenForEdit: InlineCompletion?

    /// Backspace and the other deletions with a completion: remove only the completion. The text stays,
    /// completion is off until the next insertion at the end, and the query re-runs (CC-40).
    private func removeCompletionByDeletion() -> Bool {
        guard completion.shown != nil, let editor = activeEditor else { return false }
        completion.hide(in: editor)
        completion.allowsCompletion = false
        completion.available = nil
        runQuery(text)
        return true
    }

    /// A caret or selection change the bar did not make (Shift+arrows, Cmd+A, a click): the completed
    /// text becomes typed text, and the query re-runs with completion off.
    private func selectionChanged() {
        guard isPresented, !completion.isApplying, let range = completion.selectionRange, let editor = activeEditor,
              editor.selectedRange() != range else { return }
        completion.accept()
        runQuery(text)
    }

    private func returnPressed(_ modifiers: CommandBarModifiers) {
        // Return acts on what is highlighted on screen at the key press (WYSIWYG).
        // Only when this text has NO snapshot yet does it wait for that text's first
        // snapshot and open its top row. It never waits for history or remote providers.
        if appliedQuery != text || appliedSequence < 0 {
            pendingReturn = (generation, text, modifiers)
            return
        }
        if let i = selectedIndex { choose(i, modifiers: modifiers) }
    }

    fileprivate func textChanged() {
        panel.input.textDidChange()
        let editor = panel.input.editor
        guard isPresented, !editor.hasMarkedText(), !editor.isUpdatingComposition else { return }
        // A text-system edit (cut, for example) while a completion showed: the field text is the typed text.
        if completion.shown != nil { completion.accept() }
        let hidden = hiddenForEdit
        hiddenForEdit = nil
        // After a kept insertion the rest of the completion follows the caret: it is not typed text.
        let full = fieldText as NSString
        let typedLength = full.length - editor.keptTail
        let t = editor.keptTail > 0 ? full.substring(to: typedLength) : fieldText
        let selection = editor.selectedRange()
        completion.allowsCompletion = allowsInlineCompletion && editor.lastEdit == .insertionAtEnd && selection.length == 0
            && selection.location == typedLength
        // The kept rest shows again below; if it cannot (completion off), the field drops it now.
        if editor.keptTail > 0, !(completion.allowsCompletion && selectedIndex == 0 && hidden.flatMap({ Self.continued($0, typed: t) }) != nil) {
            completion.trim(to: t, in: editor)
        }
        guard queriedText != t else { return } // Commit can notify through both AppKit and unmarkText.
        // Space right after a site name or keyword enters Site Search ("youtube" + Space), but not while a
        // completion showed: then Space only types a space (CC-5).
        if siteScope == nil, let site = siteHint, hintAllowsSpace, hidden == nil, t == hintText + " " {
            enterSiteSearch(site)
            return
        }
        // A character that continues the completion keeps it on screen until the new snapshot (§4.1.5).
        if let hidden, completion.allowsCompletion, selectedIndex == 0, let kept = Self.continued(hidden, typed: t), let active = activeEditor {
            completion.available = kept
            completion.show(kept, typed: t, in: active)
        } else {
            completion.available = nil
        }
        runQuery(t, allowsCompletion: completion.allowsCompletion)
    }

    /// `completion` with `typed` as its typed part, when the field text still extends `typed`.
    static func continued(_ completion: InlineCompletion, typed: String) -> InlineCompletion? {
        let field = completion.fieldText as NSString
        let n = (typed as NSString).length
        guard n < field.length, TextMatching.fold(field.substring(to: n)) == TextMatching.fold(typed) else { return nil }
        return InlineCompletion(rowID: completion.rowID, fieldText: completion.fieldText, typedLength: n)
    }
}

extension CommandBarController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) { textChanged() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handle(commandSelector, flags: NSApp.currentEvent?.modifierFlags ?? [])
    }
}

/// Fixed content for `presentPreview`.
public struct CommandBarPreview: Sendable {
    public var mode: CommandBarMode
    public var text: String
    public var selectAllText: Bool
    public var input: CommandBarInput
    public var rows: [CommandBarRow]
    public var selectedIndex: Int?
    /// Shows the (i) privacy footer.
    public var showsFooter: Bool
    /// Text selection in the field (an inline completion's range); overrides `selectAllText`.
    public var selectedRange: NSRange?

    public init(mode: CommandBarMode = .newTab, text: String = "", selectAllText: Bool = false, input: CommandBarInput,
                rows: [CommandBarRow], selectedIndex: Int? = 0, showsFooter: Bool = false, selectedRange: NSRange? = nil) {
        self.mode = mode; self.text = text; self.selectAllText = selectAllText; self.input = input
        self.rows = rows; self.selectedIndex = selectedIndex; self.showsFooter = showsFooter; self.selectedRange = selectedRange
    }
}
