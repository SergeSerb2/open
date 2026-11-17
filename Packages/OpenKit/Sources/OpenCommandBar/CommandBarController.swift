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
    /// Product artwork embeds the real panel without taking keyboard focus.
    public var acceptsInputFocus = true
    public var favicons: CommandBarFaviconSource? {
        didSet { panel.results.favicons = favicons; panel.input.favicons = favicons }
    }
    /// Synchronous engine icon lookup, like the favicon source; no image conversion during draw.
    public var extensionIcon: (@MainActor (String) -> NSImage?)? {
        didSet { panel.results.extensionIcon = extensionIcon; panel.input.extensionIcon = extensionIcon }
    }
    /// The Space accent; `isDark` follows the overlay's effective appearance (plan D3 §2.1).
    public var theme = CommandBarTheme.default {
        didSet { if theme != oldValue { applyTheme() } }
    }
    /// Kept for callers; the D3 card body is opaque and no longer samples the backdrop.
    public var backdrop = CommandBarBackdrop.darkPage
    /// Open's privacy page, the target of "here" in the (i) footer. Nil hides that line (no dead link).
    public var privacyURL: URL? { didSet { panel.footer.showsLearnMore = privacyURL != nil } }
    /// True while the (i) privacy footer shows (CC-42).
    public var allowsSearchHelp = true
    public var showsPrivacyFooter: Bool { view.showsFooter }

    public private(set) var isPresented = false
    /// A second Cmd+T / Cmd+L closes the bar only when the user opened it with that key (Arc 06-keys, 12c). A bar the
    /// App shows by itself (a new window) re-presents instead. The App sets this before `present`.
    public var closesOnModeKey = true
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
    /// The scope while its chip shows: a Site Search, Actions, or Tabs (§4.3).
    public private(set) var scope: CommandBarScope?
    /// The Site Search of the current scope, if it is one.
    public var siteScope: SiteSearch? { if case .site(let s)? = scope { return s } else { return nil } }
    /// The field text before the scope started; Backspace on an empty field restores it (CC-19, CC-41).
    private var queryBeforeEnteringScope: String?
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
    private var extensionHint: ExtensionKeyword?
    private weak var sessionSource: (any ExtensionCommandBarSource)?
    private var sessionExtensionID: String?
    private weak var sessionWindow: NSWindow?
    private var sessionObservers: [NSObjectProtocol] = []
    public var extensionScope: ExtensionKeyword? { if case .extension(let e)? = scope { e } else { nil } }

    private func endExtensionSession(cancel: Bool = true) {
        let source = sessionSource, id = sessionExtensionID
        sessionExtensionID = nil; sessionSource = nil; sessionWindow = nil
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
        if cancel, let id { source?.cancelSession(extensionID: id) }
    }
    private func observeSessionWindow() {
        guard sessionExtensionID != nil, let window = view.window else { return }
        if let previous = sessionWindow {
            if previous !== window { dismiss(reason: .programmatic) }
            return
        }
        sessionWindow = window
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            sessionObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(reason: .programmatic) }
            })
        }
    }
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
        view.onAppearanceChange = { [weak self] in self?.syncAppearance() }
        applyTheme()
        let field = panel.input.field
        field.delegate = self
        panel.input.editor.onShiftDelete = { [weak self] flags in self?.handle(#selector(NSResponder.deleteForward(_:)), flags: flags) ?? false }
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
        // A second Cmd+T closes the New Tab bar; a second Cmd+L closes the address editor (Arc 06-keys, 12c).
        panel.input.editor.onModeKey = { [weak self] key in
            guard let self, self.isPresented, self.closesOnModeKey, let mode = self.request?.mode else { return false }
            guard (key == "t" && mode == .newTab) || (key == "l" && mode == .editCurrentURL) else { return false }
            self.dismiss(reason: .programmatic)
            return true
        }
        view.onMoveToWindow = { [weak self] in
            guard let self else { return }
            if self.sessionExtensionID != nil, self.view.window == nil { self.dismiss(reason: .programmatic) }
            self.observeSessionWindow(); self.focusInput()
        }
        panel.input.closeButton.action = { [weak self] in self?.dismiss(reason: .escape) }
        panel.input.infoButton.action = { [weak self] in self?.togglePrivacyFooter() }
        panel.input.onChipClose = { [weak self] in self?.exitSiteSearch() }
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
    public func present(_ request: CommandBarRequest, presentation: CommandBarPresentation = .overlay) {
        endExtensionSession()
        view.presentation = presentation
        pendingReturn = nil
        panel.input.editor.resetSession()
        self.request = request
        // Scope modes open with their scope; leaving it gives an empty Cmd+T bar.
        switch request.mode {
        case .searchTabs: scope = .tabs
        case .searchActions: scope = .actions
        default: scope = nil
        }
        queryBeforeEnteringScope = nil
        applyScopeTheme()
        engine.prewarm()
        let field = panel.input.field
        let address = request.currentTabURL?.absoluteString == "open://welcome" ? "Welcome to Open" : request.currentTabURL?.absoluteString ?? ""
        let initial = request.mode == .editCurrentURL ? address : ""
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
    public func presentPreview(_ preview: CommandBarPreview, presentation: CommandBarPresentation = .overlay) {
        endExtensionSession()
        view.presentation = presentation
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
        // A previewed scope chip gives the selected row the chip color, as a live scope does.
        var previewTheme = theme
        if preview.input.chip != nil { previewTheme.focus = CommandBarRole.scopeChip }
        panel.results.theme = previewTheme
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
        endExtensionSession()
        scope = nil
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

    public func focusInput() {
        guard acceptsInputFocus else { return }
        guard isPresented, let window = view.window else { return }
        let field = panel.input.field
        window.makeFirstResponder(field)
        // Cmd+L selects the whole URL, including when presented before attachment.
        let length = (fieldText as NSString).length
        field.currentEditor()?.selectedRange = focusSelection ?? NSRange(location: length, length: 0)
        panel.input.editor.undoManager?.removeAllActions()
    }

    private func applyBackdrop() {
        syncAppearance()
        if view.presentation.isEmbedded {
            panel.material.applySolid(LittleOpenMetrics.titleBarFill)
        } else {
            panel.material.apply(theme)
        }
    }

    /// Light or Dark card from the overlay's effective appearance (the window's, not the Space's).
    private func syncAppearance() {
        let dark = ContentAppearance(view.effectiveAppearance) == .dark
        if theme.isDark != dark { theme.isDark = dark }
    }

    private func applyTheme() {
        applyScopeTheme()
        panel.input.theme = theme
        panel.theme = theme
        if !view.presentation.isEmbedded { panel.material.apply(theme) }
    }

    // MARK: Privacy footer (CC-42, D14)

    /// (i) or Cmd+I: shows or hides the footer. The panel changes in one frame (D12).
    public func togglePrivacyFooter() {
        guard isPresented, allowsSearchHelp, request?.mode != .littleOpen, !view.presentation.isEmbedded else { return }
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

    /// Re-read a live default suggestion without changing the field or scope.
    /// The App source reuses the current input's reply instead of sending another input event.
    public func refreshExtensionSuggestions(extensionID: String) {
        guard isPresented, extensionScope?.id == extensionID else { return }
        runQuery(text)
    }

    private func context() -> SuggestContext {
        let r = request ?? CommandBarRequest(mode: .newTab)
        var mode = r.mode.suggestMode
        switch scope {
        case .actions?: mode = .searchActions
        case .tabs?: mode = .searchTabs
        case .site?, .extension?, nil: if mode.isScoped { mode = .newTab }
        }
        var context = SuggestContext(mode: mode, profileID: r.profileID, spaceID: r.spaceID, currentTabID: r.currentTabID,
                              currentTabURL: r.currentTabURL, allowsRemoteSuggestions: r.allowsRemoteSuggestions,
                              searchEngineID: r.searchEngineID, siteSearchID: siteScope?.id, extensionScopeID: extensionScope?.id, allowsInlineCompletion: queryAllowsCompletion)
        context.undoActionName = r.undoActionName; context.redoActionName = r.redoActionName
        return context
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
            guard $0.kind != .siteSearchHint, $0.kind != .extensionKeywordHint else { return false }
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
        extensionHint = nil
        hintText = text
        hintAllowsSpace = false
        guard scope == nil, !trimmed.isEmpty, !trimmed.contains(" ") else { return }
        // An exact extension keyword beats a site's partial name. Exact conflicts were
        // already removed by extensionKeywordTrigger (Q9).
        if let keyword = engine.extensionKeywordTrigger(for: trimmed) {
            extensionHint = keyword
            hintAllowsSpace = true
        } else if let site = engine.siteSearchTrigger(for: trimmed) {
            siteHint = site
            // Scope keywords offer Tab only: Space types a space ("tabs vs spaces", §4.3.2).
            if site.isScope { return }
            // Space enters the scope only when the text is the site's name or keyword exactly, so
            // typing words that merely start a site name keeps working. guess (F0040 shows "or Space").
            let folded = TextMatching.fold(trimmed)
            hintAllowsSpace = TextMatching.fold(site.name) == folded || site.keywords.contains { TextMatching.fold($0) == folded }
        }
    }

    private func updateInputPresentation() {
        let r = request
        var input = CommandBarInput(placeholder: CommandBarText.placeholder, leadingIcon: .symbol("magnifyingglass", plate: false))
        if let scope {
            input.placeholder = CommandBarText.scopePlaceholder
            input.chip = .init(name: scope.title, extensionID: extensionScope?.id)
            if let extensionScope { input.placeholder = CommandBarText.siteSearchPlaceholder(extensionScope.name) }
        }
        let typed = text
        if typed.isEmpty || scope != nil {
            input.leadingIcon = .symbol("magnifyingglass", plate: false)
        } else if r?.mode == .editCurrentURL, let current = r?.currentTabURL,
                  typed == current.absoluteString || (current.absoluteString == "open://welcome" && typed == "Welcome to Open") {
            input.leadingIcon = .favicon(current, fallback: "globe") // Cmd+L shows the page favicon (F0048)
        } else if let top = suggestions.first, [.navigate, .history, .switchToTab].contains(top.kind) {
            // The favicon of the top result when it is a page, else the search glyph (plan D3 §2.1).
            input.leadingIcon = rows.first.map(\.icon).map { icon in
                // A Split View row 1: the matched pane's icon. guess (no capture).
                if case .split(let panes, _) = icon {
                    let i = top.split?.paneTabIDs.firstIndex { $0 == top.tabID } ?? 0
                    return i < panes.count ? panes[i] : .symbol("magnifyingglass", plate: false)
                }
                return icon
            } ?? .symbol("magnifyingglass", plate: false)
            if case .symbol = input.leadingIcon { input.leadingIcon = .symbol("magnifyingglass", plate: false) }
        }
        if let site = siteHint {
            // Never "or Space" while a completion shows (CC-5, CC-40).
            input.trailing = .siteSearchHint(name: site.name, space: hintAllowsSpace && completion.shown == nil)
        } else if let keyword = extensionHint {
            input.trailing = .siteSearchHint(name: keyword.name, space: completion.shown == nil)
        } else if scope != nil {
            input.trailing = .none // no (i) inside a scope (S2 18/0016, 0018)
        } else if r?.mode == .littleOpen || !allowsSearchHelp {
            input.trailing = .none
        } else {
            input.trailing = .info
        }
        panel.input.input = input
    }

    /// Enters Site Search for `site` (or the Actions or Tabs scope for their trigger entries). The trigger
    /// word becomes the chip; text after it stays the query.
    public func enterSiteSearch(_ site: SiteSearch, remainder: String = "") {
        let s: CommandBarScope = site.id == SiteSearch.actionsScopeID ? .actions : site.id == SiteSearch.tabsScopeID ? .tabs : .site(site)
        enterScope(s, remainder: remainder)
    }

    /// Enters `scope`; the field before it is kept for Backspace on empty (CC-19). `restoring` is that text.
    public func enterScope(_ scope: CommandBarScope, remainder: String = "", restoring: String? = nil) {
        // The scope takes the typed text, never the completion (§4.1.5 Tab).
        let before = restoring ?? text
        if let editor = activeEditor { completion.hide(in: editor) }
        completion.reset()
        endExtensionSession()
        self.scope = scope
        if case .extension(let keyword) = scope, let source = engine.extensionSource {
            sessionSource = source; sessionExtensionID = keyword.id
            source.startSession(extensionID: keyword.id)
            observeSessionWindow()
        }
        queryBeforeEnteringScope = before
        panel.input.setText(remainder)
        panel.input.needsLayout = true
        applyScopeTheme()
        runQuery(text)
    }

    /// Leaves the scope (Backspace on an empty field, or a click on the chip's close glyph): the field
    /// gets back the text from before the scope, caret at the end (CC-19, CC-41 S2 18/0021). A scope
    /// opened by command leaves an empty Cmd+T bar.
    public func exitSiteSearch() {
        guard scope != nil else { return }
        endExtensionSession()
        scope = nil
        let restored = queryBeforeEnteringScope ?? ""
        queryBeforeEnteringScope = nil
        if let r = request, r.mode == .searchTabs || r.mode == .searchActions { request?.mode = .newTab }
        panel.input.setText(restored)
        if let editor = activeEditor { editor.setSelectedRange(NSRange(location: (restored as NSString).length, length: 0)) }
        panel.input.needsLayout = true
        applyScopeTheme()
        runQuery(text)
    }

    /// Inside a scope the selected row takes the chip color (S2 18/0018); otherwise the Space's focus.
    private func applyScopeTheme() {
        var t = theme
        if scope != nil { t.focus = CommandBarRole.scopeChip }
        panel.results.theme = t
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
        let destination: CommandBarDestination = r.mode == .editCurrentURL || r.mode == .littleOpen ? .currentTab : .newTab
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
        case .extensionAction:
            intent = s.extensionID.map { .runExtensionAction(extensionID: $0) }
        case .extensionSuggestion:
            intent = s.extensionID.map { .extensionOmnibox(extensionID: $0, content: s.extensionContent ?? text, destination: destination, modifiers: modifiers) }
        case .extensionKeywordHint:
            if let keyword = engine.extensionKeywordTrigger(for: text) { enterScope(.extension(keyword)) }
            return
        case .calculator:
            intent = .copy(s.title)
        case .siteSearchHint:
            if let id = s.siteSearchID, let site = engine.siteSearch(id: id) { enterSiteSearch(site) }
            return
        }
        guard let intent else { return }
        // Cmd+Return on a page or a search opens a background tab and keeps the bar open, the text selected so
        // the next entry replaces it (Arc 11-returns; plan D3 §2.3, lead decision on the text).
        if modifiers.contains(.command), !modifiers.contains(.option), [.navigate, .history, .search, .searchSuggestion, .siteSearch].contains(s.kind) {
            let acceptedCompletion = completion.shown != nil && activeEditor != nil
            if acceptedCompletion { completion.accept() }
            delegate?.commandBar(self, perform: intent)
            guard isPresented else { return }
            // The accepted completion is now typed text: query it, or the next Return waits for a
            // snapshot of this text that never comes (`returnPressed`).
            if acceptedCompletion { runQuery(text) }
            // The new page must not take the keyboard: the field keeps it, all of its text selected.
            focusSelection = NSRange(location: 0, length: (fieldText as NSString).length)
            focusInput()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, self.activeEditor == nil else { return }
                self.focusInput()
            }
            return
        }
        // Accepted omnibox input is completed by the intent; it must not send onInputCancelled first.
        if s.kind == .extensionSuggestion { endExtensionSession(cancel: false) }
        dismiss(reason: .selection)
        delegate?.commandBar(self, perform: intent)
    }

    // MARK: Keys

    /// Handles a text-system command from the field editor. Returns true when consumed.
    func handle(_ selector: Selector, flags: NSEvent.ModifierFlags) -> Bool {
        guard isPresented, !panel.input.editor.hasMarkedText(), !panel.input.editor.isUpdatingComposition else { return false }
        if flags.intersection([.shift, .command, .option, .control]) == .shift,
           selector == #selector(NSResponder.deleteBackward(_:)) || selector == #selector(NSResponder.deleteForward(_:)),
           let s = selectedSuggestion, s.kind == .extensionSuggestion, s.isDeletable,
           let id = s.extensionID, let content = s.extensionContent {
            sessionSource?.deleteSuggestion(content, extensionID: id)
            // Keep the current rows and selection; do not issue another onInputChanged for a deletion.
            engine.cancel(); streamTask?.cancel(); generation += 1
            suggestions.removeAll { $0.id == s.id }
            rows.removeAll { $0.id == s.id }
            panel.results.setRows(rows, selected: min(selectedIndex ?? 0, max(0, rows.count - 1)))
            view.visibleRowCount = min(rows.count, CommandBarMetrics.maxVisibleRows)
            return true
        }
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
            if let keyword = extensionHint { enterScope(.extension(keyword)); return true }
            return false // Without a Site Search hint, use normal AppKit focus traversal.
        case #selector(NSResponder.insertBacktab(_:)):
            return false
        case #selector(NSResponder.deleteBackward(_:)):
            if scope != nil, text.isEmpty { exitSiteSearch(); return true }
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
        if scope == nil, let site = siteHint, hintAllowsSpace, hidden == nil, t == hintText + " " {
            enterScope(.site(site), restoring: hintText)
            return
        }
        if scope == nil, let keyword = extensionHint, hidden == nil, t == hintText + " " {
            enterScope(.extension(keyword), restoring: hintText)
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
