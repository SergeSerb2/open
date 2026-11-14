import Foundation

/// When an action is offered. Actions that do not apply are hidden, not disabled (Arc §4.4 rule 10).
public enum ActionRequirement: String, Sendable, Hashable {
    case none
    /// A tab is selected.
    case currentTab
    /// The selected tab is a Today tab (not pinned, not a favorite).
    case currentTabInToday
    /// The selected tab is pinned in its Space.
    case currentTabPinned
    /// The selected tab is pinned or a favorite (it has a pinned URL to reset to).
    case currentTabHasPinnedURL
    case currentTabIsFavorite
    case currentTabNotFavorite
    case currentTabInSplit
    /// The Profile has more than one Space.
    case multipleSpaces
}

/// A browser command the command bar can run. The app registers the handler for `id`.
public struct BrowserAction: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Extra search phrases ("Clear Today" finds "Clear Unpinned Tabs").
    public var aliases: [String]
    /// Key equivalent for display, in macOS order (⌃⌥⇧⌘).
    public var shortcut: String?
    public var symbol: String
    public var requirement: ActionRequirement

    public init(id: String, title: String, aliases: [String] = [], shortcut: String? = nil,
                symbol: String = "command", requirement: ActionRequirement = .none) {
        self.id = id; self.title = title; self.aliases = aliases; self.shortcut = shortcut
        self.symbol = symbol; self.requirement = requirement
    }
}

/// Injectable list of actions. `arcDefaults` is the Arc 1.170.0 command set that fits a command bar.
public struct ActionRegistry: Sendable {
    public private(set) var actions: [BrowserAction]

    public init(_ actions: [BrowserAction]) { self.actions = actions }

    /// Adds an action, or replaces the one with the same id.
    public mutating func register(_ action: BrowserAction) {
        if let i = actions.firstIndex(where: { $0.id == action.id }) { actions[i] = action } else { actions.append(action) }
    }

    public mutating func remove(id: String) { actions.removeAll { $0.id == id } }

    /// Titles follow the menu items in docs/re/menus-and-hotkeys.md with Open naming, without a trailing "…".
    /// Aliases include the Arc menu trigger phrases (`ibExternalUserDefinedRuntimeAttributesLocalizableStrings`
    /// in `MainMenu.nib`, `.re/hotkeys/ib-localizable.txt`). Shortcuts are the nib key equivalents.
    /// Out of scope and left out: Easels, Notes, Arc Max, Dia, account items, Capture.
    public static let arcDefaults = ActionRegistry([
        // Tabs and windows
        BrowserAction(id: "new-tab", title: "New Tab", aliases: ["Open New Tab", "Create Tab"], shortcut: "⌘T", symbol: "plus"),
        BrowserAction(id: "new-window", title: "New Window", aliases: ["Create Window", "Copy Window", "Duplicate Window"], shortcut: "⌘N", symbol: "macwindow.badge.plus"),
        BrowserAction(id: "new-incognito-window", title: "New Incognito Window", aliases: ["Incognito", "Private Window"], shortcut: "⇧⌘N", symbol: "eyeglasses"),
        BrowserAction(id: "new-little-open-window", title: "New Little Open Window", aliases: ["Little Open", "Little Arc", "Quick Lookup", "Mini Window"], shortcut: "⌥⌘N", symbol: "macwindow.on.rectangle"),
        BrowserAction(id: "archive-tab", title: "Archive Tab", aliases: ["Close Tab", "Close Current Tab"], shortcut: "⌘W", symbol: "archivebox", requirement: .currentTab),
        BrowserAction(id: "restore-last-closed-tab", title: "Restore Last Closed Tab", aliases: ["Reopen Closed Tab"], shortcut: "⇧⌘T", symbol: "arrow.uturn.backward"),
        BrowserAction(id: "duplicate-tab", title: "Duplicate Current Tab", aliases: ["Duplicate Tab", "Duplicate"], symbol: "plus.square.on.square", requirement: .currentTab),
        BrowserAction(id: "rename-tab", title: "Rename Current Tab", aliases: ["Rename Tab", "Rename Current Item"], symbol: "pencil", requirement: .currentTab),
        BrowserAction(id: "pin-tab", title: "Pin Tab", aliases: ["Pin", "Pin/Unpin Tab", "Save"], shortcut: "⌘D", symbol: "pin", requirement: .currentTabInToday),
        BrowserAction(id: "unpin-tab", title: "Unpin Tab", aliases: ["Unpin", "Pin", "Pin/Unpin Tab"], shortcut: "⌘D", symbol: "pin.slash", requirement: .currentTabPinned),
        BrowserAction(id: "add-to-favorites", title: "Add to Favorites", aliases: ["Favorite", "Move to Favorites"], symbol: "star", requirement: .currentTabNotFavorite),
        BrowserAction(id: "remove-from-favorites", title: "Remove from Favorites", aliases: ["Unfavorite", "Remove Favorite"], symbol: "star.slash", requirement: .currentTabIsFavorite),
        BrowserAction(id: "reset-tab", title: "Reset Tab to Original URL", aliases: ["Reset Tab"], symbol: "arrow.counterclockwise", requirement: .currentTabHasPinnedURL),
        BrowserAction(id: "replace-pinned-url", title: "Replace Pinned URL with Current Site", aliases: ["Replace Pinned Tab", "Update Pinned URL"], symbol: "pin.circle", requirement: .currentTabHasPinnedURL),
        BrowserAction(id: "copy-url", title: "Copy URL", aliases: ["Copy Link"], shortcut: "⇧⌘C", symbol: "link", requirement: .currentTab),
        BrowserAction(id: "copy-url-markdown", title: "Copy URL as Markdown", aliases: ["Copy Link as Markdown", "Copy Markdown"], shortcut: "⌥⇧⌘C", symbol: "text.badge.plus", requirement: .currentTab),
        BrowserAction(id: "copy-url-quote", title: "Copy URL as Quote", aliases: ["Copy Quote", "Copy Link to Highlight"], shortcut: "⌃⇧⌘C", symbol: "quote.bubble", requirement: .currentTab),
        BrowserAction(id: "clear-unpinned-tabs", title: "Clear Unpinned Tabs", aliases: ["Close Unpinned Tabs", "Clear Tabs", "Clear Today"], shortcut: "⇧⌘K", symbol: "xmark.circle"),
        BrowserAction(id: "new-folder", title: "New Folder", aliases: ["Create Folder", "Create New Folder", "New Folder from Selection"], shortcut: "⇧⌘N", symbol: "folder.badge.plus"),
        BrowserAction(id: "expand-all-folders", title: "Expand All Folders", symbol: "folder"),
        BrowserAction(id: "collapse-all-folders", title: "Collapse All Folders", symbol: "folder.fill"),
        BrowserAction(id: "mute-all-tabs", title: "Mute All Tabs", aliases: ["Mute"], symbol: "speaker.slash"),
        BrowserAction(id: "unmute-all-tabs", title: "Unmute All Tabs", aliases: ["Unmute"], symbol: "speaker.wave.2"),
        BrowserAction(id: "next-tab", title: "Next Tab", shortcut: "⌥⌘↓", symbol: "arrow.down"),
        BrowserAction(id: "previous-tab", title: "Previous Tab", shortcut: "⌥⌘↑", symbol: "arrow.up"),
        BrowserAction(id: "reveal-tab-in-sidebar", title: "Reveal Tab in Sidebar", aliases: ["Reveal Current Tab", "Show Tab in Sidebar", "Reveal in Sidebar", "Go to Current Tab", "Focus Sidebar"], shortcut: "⌃Space", symbol: "sidebar.left", requirement: .currentTab),
        // Split View
        BrowserAction(id: "add-split-view", title: "Add Split View", aliases: ["Split View", "Create Split View Pane", "New Split View", "Split"], shortcut: "⌃⇧=", symbol: "rectangle.split.2x1", requirement: .currentTab),
        BrowserAction(id: "close-split-pane", title: "Close this Split Pane", aliases: ["Close Split View", "Close Split Pane"], shortcut: "⌃⇧-", symbol: "xmark.rectangle", requirement: .currentTabInSplit),
        BrowserAction(id: "separate-from-split-view", title: "Separate Page from Split View", aliases: ["Separate from Split View", "Separate Tab"], symbol: "rectangle.split.2x1", requirement: .currentTabInSplit),
        BrowserAction(id: "expand-current-split", title: "Expand Current Split", aliases: ["Expand", "Expand Split View", "Maximize"], symbol: "arrow.up.left.and.arrow.down.right", requirement: .currentTabInSplit),
        // View
        BrowserAction(id: "toggle-sidebar", title: "Show/Hide Sidebar", aliases: ["Toggle Sidebar", "Hide Sidebar", "Show Sidebar"], shortcut: "⌘S", symbol: "sidebar.left"),
        BrowserAction(id: "toggle-toolbar", title: "Show/Hide Toolbar", aliases: ["Toggle Toolbar", "Hide Toolbar", "Show Toolbar"], shortcut: "⇧⌘D", symbol: "menubar.rectangle"),
        BrowserAction(id: "toggle-full-screen", title: "Enter/Exit Full Screen", aliases: ["Enter Full Screen", "Exit Full Screen", "Full Screen", "Toggle Full Screen"], shortcut: "⌃⌘F", symbol: "arrow.up.left.and.arrow.down.right"),
        BrowserAction(id: "reload", title: "Refresh the Page", aliases: ["Reload Page", "Reload", "Refresh"], shortcut: "⌘R", symbol: "arrow.clockwise", requirement: .currentTab),
        BrowserAction(id: "force-reload", title: "Force Refresh the Page", aliases: ["Force Reload", "Force Refresh"], shortcut: "⇧⌘R", symbol: "arrow.clockwise.circle", requirement: .currentTab),
        BrowserAction(id: "clear-cache-and-refresh", title: "Clear Cache and Refresh", aliases: ["Clear Cache"], symbol: "trash", requirement: .currentTab),
        BrowserAction(id: "clear-cookies-and-refresh", title: "Clear Cookies and Refresh", aliases: ["Clear Cookies"], symbol: "trash.circle", requirement: .currentTab),
        BrowserAction(id: "zoom-in", title: "Zoom In", shortcut: "⇧⌘=", symbol: "plus.magnifyingglass", requirement: .currentTab),
        BrowserAction(id: "zoom-out", title: "Zoom Out", shortcut: "⌘-", symbol: "minus.magnifyingglass", requirement: .currentTab),
        BrowserAction(id: "zoom-actual-size", title: "Zoom to Actual Size", aliases: ["Reset Zoom"], shortcut: "⌘0", symbol: "1.magnifyingglass", requirement: .currentTab),
        BrowserAction(id: "find", title: "Find", aliases: ["Find on Page", "Search Page"], shortcut: "⌘F", symbol: "magnifyingglass", requirement: .currentTab),
        BrowserAction(id: "print", title: "Print", aliases: ["Print Page"], shortcut: "⌘P", symbol: "printer", requirement: .currentTab),
        BrowserAction(id: "save-page-as", title: "Save Page As", aliases: ["Save Page", "Save File"], shortcut: "⇧⌘S", symbol: "square.and.arrow.down", requirement: .currentTab),
        BrowserAction(id: "go-back", title: "Go Back", aliases: ["Back", "Navigate Back"], shortcut: "⌘[", symbol: "chevron.left", requirement: .currentTab),
        BrowserAction(id: "go-forward", title: "Go Forward", aliases: ["Forward", "Navigate Forward"], shortcut: "⌘]", symbol: "chevron.right", requirement: .currentTab),
        BrowserAction(id: "developer-tools", title: "Developer Tools", aliases: ["Debug Tools", "Devtools"], shortcut: "⌥⌘I", symbol: "hammer", requirement: .currentTab),
        BrowserAction(id: "view-source", title: "View Source", shortcut: "⌥⌘U", symbol: "chevron.left.forwardslash.chevron.right", requirement: .currentTab),
        BrowserAction(id: "javascript-console", title: "JavaScript Console", aliases: ["Toggle Console", "Console", "JS Console"], shortcut: "⌥⌘J", symbol: "terminal", requirement: .currentTab),
        BrowserAction(id: "appearance-dark", title: "Switch to Dark Mode", aliases: ["Dark Mode"], symbol: "moon"),
        BrowserAction(id: "appearance-light", title: "Switch to Light Mode", aliases: ["Light Mode"], symbol: "sun.max"),
        BrowserAction(id: "appearance-automatic", title: "Switch to Automatic Appearance", aliases: ["Automatic Appearance"], symbol: "circle.lefthalf.filled"),
        // Spaces
        BrowserAction(id: "new-space", title: "New Space", aliases: ["Create New Space", "Create Space", "Add Space"], symbol: "plus.rectangle.on.rectangle"),
        BrowserAction(id: "next-space", title: "Next Space", aliases: ["Focus Next Space"], shortcut: "⌥⌘→", symbol: "arrow.right", requirement: .multipleSpaces),
        BrowserAction(id: "previous-space", title: "Previous Space", aliases: ["Focus Previous Space"], shortcut: "⌥⌘←", symbol: "arrow.left", requirement: .multipleSpaces),
        BrowserAction(id: "manage-spaces", title: "Manage Spaces", aliases: ["Space Management", "Organize", "Toggle Space Manager", "View Spaces"], symbol: "square.grid.2x2"),
        BrowserAction(id: "rename-space", title: "Rename Space", symbol: "pencil"),
        BrowserAction(id: "edit-theme", title: "Edit Theme", aliases: ["Theme", "Edit Space Theme"], symbol: "paintpalette"),
        BrowserAction(id: "change-profile", title: "Change Profile", aliases: ["Move Space to Profile"], symbol: "person.crop.circle"),
        BrowserAction(id: "reset-all-tabs-in-space", title: "Reset all tabs in this Space", aliases: ["Reset Pinned Tabs"], symbol: "arrow.counterclockwise.circle"),
        BrowserAction(id: "expand-pinned-section", title: "Expand Pinned Section", aliases: ["Expand Pinned Tabs", "Show Pinned Tabs", "Pinned"], symbol: "chevron.down"),
        BrowserAction(id: "collapse-pinned-section", title: "Collapse Pinned Section", aliases: ["Collapse Pinned Tabs", "Hide Pinned Tabs", "Pinned"], symbol: "chevron.up"),
        // Library and windows
        BrowserAction(id: "view-archive", title: "View Archive", aliases: ["Archive", "Open Archive"], symbol: "archivebox"),
        BrowserAction(id: "clear-archive", title: "Clear Archive", aliases: ["Delete Archive"], symbol: "trash"),
        BrowserAction(id: "view-history", title: "View History", aliases: ["Show History", "History"], shortcut: "⌘Y", symbol: "clock"),
        BrowserAction(id: "view-downloads", title: "View Downloads", aliases: ["Downloads"], shortcut: "⇧⌘J", symbol: "arrow.down.circle"),
        BrowserAction(id: "view-library", title: "View Library", aliases: ["Library"], shortcut: "⇧⌘L", symbol: "books.vertical"),
        // Settings and features
        BrowserAction(id: "settings", title: "Settings", aliases: ["Preferences"], shortcut: "⌘,", symbol: "gearshape"),
        BrowserAction(id: "search-settings", title: "Search Settings", aliases: ["Manage Search Settings", "Search Engine", "Default Search Engine"], symbol: "magnifyingglass.circle"),
        BrowserAction(id: "air-traffic-control", title: "Air Traffic Control", aliases: ["Link Routing", "Link Preferences", "Air Traffic Controller"], symbol: "airplane"),
        BrowserAction(id: "manage-passwords", title: "Manage Passwords", aliases: ["Passwords"], symbol: "key"),
        BrowserAction(id: "manage-extensions", title: "Manage Extensions", aliases: ["Extensions"], symbol: "puzzlepiece.extension"),
        BrowserAction(id: "add-extension", title: "Add Extension", aliases: ["Chrome Web Store"], symbol: "puzzlepiece"),
        BrowserAction(id: "new-profile", title: "New Profile", aliases: ["Create Profile"], symbol: "person.crop.circle.badge.plus"),
        BrowserAction(id: "new-boost", title: "New Boost", aliases: ["Boost", "Create Boost", "Boost the Current Page", "Edit Boost"], symbol: "paintbrush", requirement: .currentTab),
        BrowserAction(id: "boost-gallery", title: "Boost Gallery", aliases: ["Boosts Gallery", "Boost Store", "Boosts Store"], symbol: "sparkles"),
        BrowserAction(id: "task-manager", title: "Open Task Manager", aliases: ["Task Manager", "CPU", "Memory", "RAM"], symbol: "cpu"),
        BrowserAction(id: "set-default-browser", title: "Set as Default Browser", aliases: ["Default Browser"], symbol: "checkmark.seal"),
        BrowserAction(id: "import-from-browser", title: "Import from Another Browser", aliases: ["Import Bookmarks", "Import Passwords", "Import Settings", "Bookmarks"], symbol: "square.and.arrow.down.on.square"),
        BrowserAction(id: "keyboard-shortcuts", title: "Essential Keyboard Shortcuts", aliases: ["Keyboard", "Shortcuts"], symbol: "keyboard"),
        // Arc's empty Cmd+T ends with this row (S2 18/0008, 18/0044 AX: "Contact the Team", image
        // "Ellipsis on a message bubble"); the empty-query row of `ActionsProvider`.
        BrowserAction(id: "contact-team", title: "Contact the Team", aliases: ["Feedback", "Contact", "Support"], symbol: "ellipsis.bubble"),
    ])

    /// Id of the dynamic "Focus on <Space>" action. The row's `spaceID` names the Space.
    public static let focusSpaceActionID = "focus-space"
}

/// Folded search data for one action, built once per registry change.
struct ActionMatcher: Sendable {
    struct Entry: Sendable {
        let action: BrowserAction
        /// Title first, then aliases; folded, each with match factor 1.
        let phrases: [[UInt8]]
        /// Initials of each phrase with 2+ words.
        let initials: [[UInt8]]
    }

    let entries: [Entry]

    init(_ registry: ActionRegistry) {
        entries = registry.actions.map { Self.entry(for: $0) }
    }

    static func entry(for action: BrowserAction) -> Entry {
        let phrases = ([action.title] + action.aliases).map { TextMatching.fold($0) }
        let initials = phrases.map(TextMatching.initials(of:)).filter { $0.count >= 2 }
        return Entry(action: action, phrases: phrases, initials: initials)
    }

    /// Quality over the title and aliases; queries shorter than 2 bytes never match.
    static func quality(_ query: FoldedQuery, _ entry: Entry, minimumBytes: Int = 2) -> Double {
        guard query.bytes.count >= minimumBytes else { return 0 }
        var best = TextMatching.rowQuality(query, titles: entry.phrases)
        if best < MatchQuality.initials, !query.bytes.contains(32), entry.initials.contains(query.bytes) {
            best = MatchQuality.initials
        }
        return best
    }
}
