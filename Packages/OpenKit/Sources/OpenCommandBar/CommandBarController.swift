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

    public private(set) var isPresented = false
    public private(set) var request: CommandBarRequest?
    /// Current input text.
    public var text: String { panel.input.field.stringValue }
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

    /// Called after each snapshot is applied to the views (diagnostics and checks).
    public var onSnapshotApplied: ((SuggestionSnapshot) -> Void)?
    /// Called when a query is submitted (diagnostics and end-to-end flows).
    public var onQueryStarted: ((String) -> Void)?

    private var panel: PanelView { view.panel }
    private var streamTask: Task<Void, Never>?
    private var generation = 0
    private var siteHint: SiteSearch?
    /// The text `siteHint` was computed for.
    private var hintText = ""
    private var hintAllowsSpace = false
    private var pendingReturn: (generation: Int, text: String, modifiers: CommandBarModifiers)?
    private var queriedText: String?
    private var selectAllOnFocus = false

    public init(engine: SuggestEngine) {
        self.engine = engine
        view = CommandBarView(frame: .zero)
        super.init()
        view.isHidden = true
        view.onClickOutside = { [weak self] in self?.dismiss(reason: .clickOutside) }
        let field = panel.input.field
        field.delegate = self
        panel.input.editor.onCompositionEnded = { [weak self] in
            self?.queriedText = nil
            self?.textChanged()
        }
        panel.input.editor.onHelp = { [weak self] in
            guard let self, self.isPresented else { return false }
            self.delegate?.commandBar(self, perform: .showHelp)
            return true
        }
        view.onMoveToWindow = { [weak self] in self?.focusInput() }
        panel.input.infoButton.action = { [weak self] in
            guard let self else { return }
            self.delegate?.commandBar(self, perform: .showHelp)
        }
        panel.results.onHover = { [weak self] i in self?.hover(i) }
        panel.results.onClick = { [weak self] i, flags in self?.choose(i, modifiers: CommandBarModifiers(flags)) }
    }

    // MARK: Presentation

    /// Opens the bar (or switches it to another mode while open).
    public func present(_ request: CommandBarRequest, animated: Bool = true) {
        let wasPresented = isPresented
        pendingReturn = nil
        panel.input.editor.resetSession()
        self.request = request
        siteScope = nil
        engine.prewarm()
        let field = panel.input.field
        let initial = request.mode == .editCurrentURL ? (request.currentTabURL?.absoluteString ?? "") : ""
        field.stringValue = CommandBarFieldEditor.normalized(initial)
        panel.input.textDidChange()
        isPresented = true
        view.isActive = true
        view.isHidden = false
        applyBackdrop()
        selectAllOnFocus = request.mode == .editCurrentURL
        runQuery(text)
        view.layoutSubtreeIfNeeded()
        focusInput()
        if !wasPresented { view.container.animateIn(animated: animated) }
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
        view.isHidden = false
        applyBackdrop()
        let field = panel.input.field
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
        selectAllOnFocus = preview.selectAllText
        focusInput()
        view.container.animateIn(animated: false)
    }

    public func dismiss(reason: CommandBarDismissReason, animated: Bool = true) {
        pendingReturn = nil
        panel.input.editor.resetSession()
        guard isPresented else { return }
        let mode = request?.mode ?? .newTab
        isPresented = false
        view.isActive = false
        streamTask?.cancel()
        streamTask = nil
        engine.cancel()
        pendingReturn = nil
        if reason != .selection { delegate?.commandBar(self, perform: .dismissed(reason)) }
        if view.window?.firstResponder === panel.input.field.currentEditor() { view.window?.makeFirstResponder(nil) }
        view.container.animateOut(animated: animated) { [weak self] in
            guard let self, !self.isPresented else { return }
            self.view.isHidden = true
        }
        delegate?.commandBar(self, didChangePresentation: false, mode: mode)
    }

    private func focusInput() {
        guard isPresented, let window = view.window else { return }
        let field = panel.input.field
        window.makeFirstResponder(field)
        // Cmd+L selects the whole URL, including when presented before attachment.
        let length = (text as NSString).length
        field.currentEditor()?.selectedRange = selectAllOnFocus ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
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

    // MARK: Query

    private func context() -> SuggestContext {
        let r = request ?? CommandBarRequest(mode: .newTab)
        return SuggestContext(mode: r.mode.suggestMode, profileID: r.profileID, spaceID: r.spaceID, currentTabID: r.currentTabID,
                              currentTabURL: r.currentTabURL, allowsRemoteSuggestions: r.allowsRemoteSuggestions,
                              searchEngineID: r.searchEngineID, siteSearchID: siteScope?.id)
    }

    /// Text changed: a new query. Its first snapshot is buffered when `query` returns and
    /// is applied on the next main-actor turn, before the frame is drawn.
    func runQuery(_ text: String) {
        pendingReturn = nil
        guard !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return }
        generation += 1
        let gen = generation
        userMovedSelection = false
        appliedSequence = -1
        isSnapshotFinal = false
        queriedText = text
        updateSiteHint(text)
        streamTask?.cancel()
        let stream = engine.query(text, context: context())
        onQueryStarted?(text)
        streamTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self, self.generation == gen, self.isPresented else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: SuggestionSnapshot) {
        guard snapshot.query == text, !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return }
        let appliedGeneration = generation
        let r = request
        let visible = snapshot.suggestions.filter { $0.kind != .siteSearchHint }
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
            input.trailing = .siteSearchHint(name: site.name, space: hintAllowsSpace)
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
    }

    private func hover(_ index: Int) {
        guard index != selectedIndex else { return }
        userMovedSelection = true
        panel.results.select(index)
    }

    /// Return on the selection, or a click on row `index`.
    public func choose(_ index: Int, modifiers: CommandBarModifiers = []) {
        guard suggestions.indices.contains(index), let r = request else { return }
        let s = suggestions[index]
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
            return false
        default:
            return false
        }
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
        guard isPresented, !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return }
        let t = text
        guard queriedText != t else { return } // Commit can notify through both AppKit and unmarkText.
        // Space right after a site name or keyword enters Site Search ("youtube" + Space).
        if siteScope == nil, let site = siteHint, hintAllowsSpace, t == hintText + " " {
            enterSiteSearch(site)
            return
        }
        runQuery(t)
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

    public init(mode: CommandBarMode = .newTab, text: String = "", selectAllText: Bool = false, input: CommandBarInput,
                rows: [CommandBarRow], selectedIndex: Int? = 0) {
        self.mode = mode; self.text = text; self.selectAllText = selectAllText; self.input = input
        self.rows = rows; self.selectedIndex = selectedIndex
    }
}
