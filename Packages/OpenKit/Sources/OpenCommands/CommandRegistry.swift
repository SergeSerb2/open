import Foundation

/// Every Arc command Open v1 needs, plus reserved out-of-scope commands.
/// Source: `docs/re/menus-and-hotkeys.md` (Arc 1.170.0, build 89123).
/// Dropped from menus but reserved: Easels, Export Notes, Arc Max/ChatGPT, Send to Dia,
/// and account items. Their shortcuts stay in `reservedShortcuts`.
public enum CommandRegistry {
    public static let all: [CommandDefinition] = appMenu + fileMenu + editMenu + viewMenu
        + spacesMenu + tabsMenu + archiveMenu + extensionsMenu + windowMenu + helpMenu
        + developerMenu + textMenu + codeOnly + reserved

    public static let byID: [String: CommandDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Commands that appear in menus or respond to keys (excludes reserved).
    public static var active: [CommandDefinition] { all.filter { !$0.isReserved } }

    /// Keys no active command may take, because an out-of-scope Arc command owns them.
    public static var reservedShortcuts: Set<KeyboardShortcut> {
        Set(all.filter(\.isReserved).flatMap(\.defaultShortcuts))
    }

    public static func command(id: String) -> CommandDefinition? { byID[id] }

    /// The command that owns a shortcut under default bindings, if any.
    /// Alternate carriers count: Cmd+Left finds `go-back`.
    public static func command(for shortcut: KeyboardShortcut, in scope: CommandScope? = nil) -> CommandDefinition? {
        active.first { candidate in
            candidate.defaultShortcuts.contains(shortcut) && (scope == nil || candidate.scope.overlaps(scope!))
        }
    }

    // MARK: - Open (app) menu

    static let appMenu: [CommandDefinition] = [
        CommandDefinition(id: "about-open", title: "About Open", menuPath: ["Open"]),
        CommandDefinition(id: "set-default-browser", title: "Set as Default Browser", menuPath: ["Open"], aliases: ["Default Browser"]),
        CommandDefinition(id: "settings", title: "Settings…", menuPath: ["Open"],
                          defaultShortcuts: [.cmd(",")], aliases: ["Preferences"]),
        CommandDefinition(id: "check-for-updates", title: "Check for Updates…", menuPath: ["Open"]),
        CommandDefinition(id: "import-from-browser", title: "Import from Another Browser…", menuPath: ["Open"],
                          aliases: ["Import Bookmarks", "Import Passwords", "Import Settings", "Bookmarks"]),
        CommandDefinition(id: "hide-open", title: "Hide Open", menuPath: ["Open"], defaultShortcuts: [.cmd("h")]),
        CommandDefinition(id: "hide-others", title: "Hide Others", menuPath: ["Open"],
                          defaultShortcuts: [KeyboardShortcut(key: "h", modifiers: [.command, .option])]),
        CommandDefinition(id: "show-all", title: "Show All", menuPath: ["Open"]),
        CommandDefinition(id: "quit-open", title: "Quit Open", menuPath: ["Open"], defaultShortcuts: [.cmd("q")]),
    ]

    // MARK: - File menu

    static let fileMenu: [CommandDefinition] = [
        CommandDefinition(id: "new-tab", title: "New Tab…", menuPath: ["File"],
                          defaultShortcuts: [.cmd("t")], isCustomizable: true,
                          aliases: ["Open New Tab", "Create Tab"]),
        CommandDefinition(id: "open-command-bar", title: "Open Command Bar", menuPath: ["File"],
                          defaultShortcuts: [.cmd("l")], scope: .commandBar, isCustomizable: true,
                          aliases: ["Edit URL", "Command Bar", "Omnibox"]),
        CommandDefinition(id: "new-window", title: "New Window", menuPath: ["File"],
                          defaultShortcuts: [.cmd("n")], isCustomizable: true,
                          aliases: ["Create Window", "Duplicate Window"]),
        CommandDefinition(id: "new-incognito-window", title: "New Incognito Window", menuPath: ["File"],
                          defaultShortcuts: [.cmdShift("n")], isCustomizable: true, aliases: ["Incognito", "Private Window"]),
        CommandDefinition(id: "new-little-open-window", title: "New Little Open Window", menuPath: ["File"],
                          defaultShortcuts: [KeyboardShortcut(key: "n", modifiers: [.command, .option])],
                          isCustomizable: true, aliases: ["Little Open", "Little Arc", "Quick Lookup", "Mini Window"]),
        CommandDefinition(id: "blank-window", title: "Blank Window", menuPath: ["File"],
                          defaultShortcuts: [KeyboardShortcut(key: "n", modifiers: [.command, .control])]),
        // Arc 1.170 File menu (NIB `newNote:`, `newNoteInSplitView:`); aliases from the NIB search titles.
        CommandDefinition(id: "new-note", title: "New Note", menuPath: ["File"],
                          defaultShortcuts: [.ctrlShift("n")], isCustomizable: true,
                          aliases: ["Create Note", "Note", "Scratchpad"]),
        CommandDefinition(id: "new-note-in-split", title: "New Note (in Split)", menuPath: ["File"],
                          defaultShortcuts: [KeyboardShortcut(key: "n", modifiers: [.control, .option])], isCustomizable: true,
                          aliases: ["Create Note in Split View", "Note Split", "Scratchpad Split", "New Note in Split"]),
        // docs/re/easels.md: File › New Easel ⌃⇧E (`newEasel:`); also the "+" menu.
        CommandDefinition(id: "new-easel", title: "New Easel", menuPath: ["File"],
                          defaultShortcuts: [.ctrlShift("e")],
                          aliases: ["Easel", "Create Easel", "Canvas", "Scrapbook"]),
        CommandDefinition(id: "close-window", title: "Close Window", menuPath: ["File"],
                          defaultShortcuts: [.cmdShift("w")]),
        CommandDefinition(id: "archive-tab", title: "Archive Tab", menuPath: ["File"],
                          defaultShortcuts: [.cmd("w")], isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Close Tab", "Close Current Tab"]),
        CommandDefinition(id: "restore-last-closed-tab", title: "Restore Last Closed Tab", menuPath: ["File"],
                          defaultShortcuts: [.cmdShift("t")], isCustomizable: true, enabledKey: EnabledKey.hasHistory,
                          aliases: ["Reopen Closed Tab"]),
        CommandDefinition(id: "print", title: "Print…", menuPath: ["File"],
                          defaultShortcuts: [.cmd("p")], enabledKey: EnabledKey.currentTab, aliases: ["Print Page"]),
        CommandDefinition(id: "save-page-as", title: "Save Page As…", menuPath: ["File"],
                          defaultShortcuts: [.cmdShift("s")], enabledKey: EnabledKey.currentTab,
                          aliases: ["Save Page", "Save File"]),
        CommandDefinition(id: "capture-page", title: "Capture…", menuPath: ["File"],
                          defaultShortcuts: [.cmdShift("2")], enabledKey: EnabledKey.currentTab, aliases: ["Capture"]),
        CommandDefinition(id: "capture-full-page", title: "Capture Full Page", menuPath: ["File"],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "capture-portrait", title: "Capture in Portrait Mode", menuPath: ["File"],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "share-page", title: "Share…", menuPath: ["File"], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "new-profile", title: "New Profile", menuPath: ["File"],
                          aliases: ["Create Profile"]),
        CommandDefinition(id: "new-boost", title: "New Boost", menuPath: ["File"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Boost", "Create Boost", "Boost the Current Page"]),
        CommandDefinition(id: "edit-boost", title: "Edit Boost", menuPath: ["File"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Boost"]),
        CommandDefinition(id: "new-legacy-boost", title: "New Legacy Boost (Advanced)", menuPath: ["File"],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "boost-gallery", title: "Boost Gallery", menuPath: ["File"],
                          aliases: ["Boosts Gallery", "Boosts Store"]),
    ]

    // MARK: - Edit menu

    static let editMenu: [CommandDefinition] = [
        CommandDefinition(id: "undo", title: "Undo", menuPath: ["Edit"],
                          defaultShortcuts: [.cmd("z")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "redo", title: "Redo", menuPath: ["Edit"],
                          defaultShortcuts: [.cmdShift("z")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "cut", title: "Cut", menuPath: ["Edit"],
                          defaultShortcuts: [.cmd("x")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "copy", title: "Copy", menuPath: ["Edit"],
                          defaultShortcuts: [.cmd("c")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "paste", title: "Paste", menuPath: ["Edit"],
                          defaultShortcuts: [.cmd("v")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "paste-and-match-style", title: "Paste and Match Style", menuPath: ["Edit"],
                          defaultShortcuts: [.cmdShift("v")], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "select-all", title: "Select All", menuPath: ["Edit"],
                          defaultShortcuts: [.cmd("a")], scope: .webContent),
        CommandDefinition(id: "delete", title: "Delete", menuPath: ["Edit"], scope: .webContent, enabledKey: EnabledKey.textField),
        CommandDefinition(id: "copy-url", title: "Copy URL", menuPath: ["Edit"],
                          defaultShortcuts: [.cmdShift("c")], isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Copy Link"]),
        CommandDefinition(id: "copy-url-markdown", title: "Copy URL as Markdown", menuPath: ["Edit"],
                          defaultShortcuts: [KeyboardShortcut(key: "c", modifiers: [.command, .option, .shift])],
                          isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Copy Link as Markdown", "Copy Markdown"]),
        CommandDefinition(id: "copy-url-quote", title: "Copy URL as Quote", menuPath: ["Edit"],
                          defaultShortcuts: [KeyboardShortcut(key: "c", modifiers: [.command, .control, .shift])],
                          isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Copy Quote", "Copy Link to Highlight"]),
        CommandDefinition(id: "find", title: "Find…", menuPath: ["Edit", "Find"],
                          defaultShortcuts: [.cmd("f")], enabledKey: EnabledKey.currentTab,
                          aliases: ["Find on Page", "Search Page"]),
        CommandDefinition(id: "find-next", title: "Find Next", menuPath: ["Edit", "Find"],
                          defaultShortcuts: [.cmd("g")], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "find-previous", title: "Find Previous", menuPath: ["Edit", "Find"],
                          defaultShortcuts: [.cmdShift("g")], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "find-and-replace", title: "Find and Replace…", menuPath: ["Edit", "Find"],
                          defaultShortcuts: [KeyboardShortcut(key: "f", modifiers: [.command, .option])],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "use-selection-to-find", title: "Use Selection to Find", menuPath: ["Edit", "Find"],
                          scope: .webContent),
        CommandDefinition(id: "jump-to-selection", title: "Jump to Selection", menuPath: ["Edit", "Find"],
                          defaultShortcuts: [.cmd("j")], scope: .webContent),
        CommandDefinition(id: "emoji-and-symbols", title: "Emoji & Symbols", menuPath: ["Edit"],
                          defaultShortcuts: [KeyboardShortcut(key: "space", modifiers: [.command, .control])],
                          scope: .webContent),
    ]

    // MARK: - View menu

    static let viewMenu: [CommandDefinition] = [
        CommandDefinition(id: "toggle-sidebar", title: "Show/Hide Sidebar", menuPath: ["View"],
                          defaultShortcuts: [.cmd("s")], isCustomizable: true,
                          aliases: ["Toggle Sidebar", "Hide Sidebar", "Show Sidebar"]),
        CommandDefinition(id: "toggle-toolbar", title: "Show/Hide Toolbar", menuPath: ["View"],
                          defaultShortcuts: [.cmdShift("d")], aliases: ["Toggle Toolbar"]),
        CommandDefinition(id: "toggle-full-screen", title: "Enter Full Screen", menuPath: ["View"],
                          defaultShortcuts: [KeyboardShortcut(key: "f", modifiers: [.command, .control])],
                          aliases: ["Exit Full Screen", "Full Screen", "Toggle Full Screen"]),
        CommandDefinition(id: "reload", title: "Refresh the Page", menuPath: ["View"],
                          defaultShortcuts: [.cmd("r")], enabledKey: EnabledKey.currentTab,
                          aliases: ["Reload Page", "Reload", "Refresh"]),
        CommandDefinition(id: "force-reload", title: "Force Refresh the Page", menuPath: ["View"],
                          defaultShortcuts: [.cmdShift("r")], enabledKey: EnabledKey.currentTab,
                          aliases: ["Force Reload", "Force Refresh"]),
        CommandDefinition(id: "stop-loading", title: "Stop Loading", menuPath: ["View"],
                          defaultShortcuts: [.cmd(".")], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "zoom-in", title: "Zoom In", menuPath: ["View"],
                          defaultShortcuts: [.cmdShift("="), .cmd("=")], isCustomizable: true, enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "zoom-out", title: "Zoom Out", menuPath: ["View"],
                          defaultShortcuts: [.cmd("-"), .cmdShift("-")], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "zoom-actual-size", title: "Zoom to Actual Size", menuPath: ["View"],
                          defaultShortcuts: [.cmd("0")], enabledKey: EnabledKey.currentTab, aliases: ["Reset Zoom"]),
        CommandDefinition(id: "add-split-view", title: "Add Split View", menuPath: ["View"],
                          defaultShortcuts: [.ctrlShift("=")], isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Split View", "Split", "Create Split View Pane"]),
        CommandDefinition(id: "close-split-pane", title: "Close this Split Pane", menuPath: ["View"],
                          defaultShortcuts: [.ctrlShift("-")], isCustomizable: true, enabledKey: EnabledKey.currentTabInSplit,
                          aliases: ["Close Split View", "Close Split Pane"]),
        CommandDefinition(id: "expand-current-split", title: "Expand Current Split", menuPath: ["View"],
                          enabledKey: EnabledKey.currentTabInSplit, aliases: ["Maximize Split Pane"]),
        CommandDefinition(id: "separate-from-split-view", title: "Separate Page from Split View", menuPath: ["View"],
                          enabledKey: EnabledKey.currentTabInSplit, aliases: ["Separate from Split View"]),
        // Tabs carries a separate title and no key (menus-and-hotkeys.md §Tabs).
        CommandDefinition(id: "reveal-tab-in-sidebar", title: "Reveal Tab in Sidebar", menuPath: ["Tabs"], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "reveal-current-tab", title: "Reveal Current Tab", menuPath: ["View"],
                          defaultShortcuts: [.ctrl("space")], enabledKey: EnabledKey.currentTab,
                          aliases: ["Reveal Tab in Sidebar", "Focus Sidebar", "Show Tab in Sidebar"]),
        CommandDefinition(id: "expand-pinned-section", title: "Expand Pinned Section", menuPath: ["View"],
                          aliases: ["Expand Pinned Tabs", "Show Pinned Tabs"]),
        CommandDefinition(id: "collapse-pinned-section", title: "Collapse Pinned Section", menuPath: ["View"],
                          aliases: ["Collapse Pinned Tabs", "Hide Pinned Tabs"]),
        CommandDefinition(id: "clear-cache-and-refresh", title: "Clear Cache and Refresh", menuPath: ["View"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Clear Cache"]),
        CommandDefinition(id: "clear-cookies-and-refresh", title: "Clear Cookies and Refresh", menuPath: ["View"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Clear Cookies"]),
        CommandDefinition(id: "cast", title: "Cast…", menuPath: ["View"], enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "exit-modal", title: "Exit", menuPath: ["View"],
                          defaultShortcuts: [KeyboardShortcut(key: "escape")], scope: .commandBar),
        CommandDefinition(id: "appearance-automatic", title: "Automatic", menuPath: ["View", "Appearance"],
                          aliases: ["Automatic Appearance"]),
        CommandDefinition(id: "appearance-light", title: "Light", menuPath: ["View", "Appearance"], aliases: ["Light Mode"]),
        CommandDefinition(id: "appearance-dark", title: "Dark", menuPath: ["View", "Appearance"], aliases: ["Dark Mode"]),
    ]

    // MARK: - Spaces menu

    static let spacesMenu: [CommandDefinition] = [
        CommandDefinition(id: "new-space", title: "New Space…", menuPath: ["Spaces"],
                          aliases: ["Create New Space", "Create Space", "Add Space"]),
        CommandDefinition(id: "next-space", title: "Next Space", menuPath: ["Spaces"],
                          defaultShortcuts: [KeyboardShortcut(key: "right", modifiers: [.command, .option])],
                          isCustomizable: true, enabledKey: EnabledKey.multipleSpaces, aliases: ["Focus Next Space"]),
        CommandDefinition(id: "previous-space", title: "Previous Space", menuPath: ["Spaces"],
                          defaultShortcuts: [KeyboardShortcut(key: "left", modifiers: [.command, .option])],
                          isCustomizable: true, enabledKey: EnabledKey.multipleSpaces, aliases: ["Focus Previous Space"]),
        CommandDefinition(id: "manage-spaces", title: "Manage Spaces…", menuPath: ["Spaces"],
                          aliases: ["Space Management", "Organize", "Toggle Space Manager", "View Spaces"]),
        CommandDefinition(id: "rename-space", title: "Rename Space", menuPath: ["Spaces"], aliases: ["Rename Current Space"]),
        CommandDefinition(id: "edit-theme", title: "Edit Theme…", menuPath: ["Spaces"],
                          aliases: ["Theme", "Edit Space Theme"]),
        CommandDefinition(id: "change-profile", title: "Change Profile", menuPath: ["Spaces"],
                          aliases: ["Move Space to Profile"]),
    ]

    // MARK: - Tabs menu

    static let tabsMenu: [CommandDefinition] = [
        CommandDefinition(id: "pin-unpin-tab", title: "Pin/Unpin Tab", menuPath: ["Tabs"],
                          defaultShortcuts: [.cmd("d")], isCustomizable: true, enabledKey: EnabledKey.currentTab,
                          aliases: ["Pin Tab", "Unpin Tab", "Pin", "Unpin"]),
        CommandDefinition(id: "next-tab", title: "Next Tab", menuPath: ["Tabs"],
                          defaultShortcuts: [KeyboardShortcut(key: "down", modifiers: [.command, .option])],
                          isCustomizable: true),
        CommandDefinition(id: "previous-tab", title: "Previous Tab", menuPath: ["Tabs"],
                          defaultShortcuts: [KeyboardShortcut(key: "up", modifiers: [.command, .option])],
                          isCustomizable: true),
        CommandDefinition(id: "cycle-tab-forward", title: "Cycle Tab Forward", menuPath: ["Tabs"],
                          defaultShortcuts: [KeyboardShortcut(key: "right", modifiers: [.command, .control])]),
        CommandDefinition(id: "cycle-tab-backward", title: "Cycle Tab Backward", menuPath: ["Tabs"],
                          defaultShortcuts: [KeyboardShortcut(key: "left", modifiers: [.command, .control])]),
        CommandDefinition(id: "tab-switcher-forward", title: "Tab Switcher (forward)", menuPath: ["Tabs"],
                          defaultShortcuts: [.ctrl("tab")], isCustomizable: true),
        CommandDefinition(id: "tab-switcher-backward", title: "Tab Switcher (backward)", menuPath: ["Tabs"],
                          defaultShortcuts: [.ctrlShift("tab")], isCustomizable: true),
        CommandDefinition(id: "clear-unpinned-tabs", title: "Clear Unpinned Tabs", menuPath: ["Tabs"],
                          defaultShortcuts: [.cmdShift("k")], isCustomizable: true,
                          aliases: ["Close Unpinned Tabs", "Clear Tabs", "Clear Today"]),
        CommandDefinition(id: "new-folder", title: "New Folder…", menuPath: ["Tabs"],
                          defaultShortcuts: [.cmdShift("n")], scope: .sidebarFocused,
                          aliases: ["Create Folder", "Create New Folder", "New Folder from Selection"]),
        CommandDefinition(id: "duplicate-tab", title: "Duplicate", menuPath: ["Tabs"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Duplicate Tab", "Duplicate Current Tab"]),
        CommandDefinition(id: "rename-tab", title: "Rename Current Item", menuPath: ["Tabs"],
                          enabledKey: EnabledKey.currentTab, aliases: ["Rename Tab", "Rename Current Tab"]),
        CommandDefinition(id: "expand-all-folders", title: "Expand All Folders", menuPath: ["Tabs"]),
        CommandDefinition(id: "collapse-all-folders", title: "Collapse All Folders", menuPath: ["Tabs"]),
        CommandDefinition(id: "reset-tab", title: "Reset Tab to Original URL", menuPath: ["Tabs"],
                          enabledKey: EnabledKey.currentTabHasPinnedURL, aliases: ["Reset Tab"]),
        CommandDefinition(id: "reset-all-tabs-in-space", title: "Reset all tabs in this Space", menuPath: ["Tabs"],
                          aliases: ["Reset Pinned Tabs"]),
        CommandDefinition(id: "peek-email", title: "Peek Email…", menuPath: ["Tabs"],
                          defaultShortcuts: [.cmdShift("e")]),
        CommandDefinition(id: "join-meeting", title: "Join Meeting", menuPath: ["Tabs"],
                          defaultShortcuts: [KeyboardShortcut(key: "j", modifiers: [.command, .control])]),
        CommandDefinition(id: "open-in-current-space", title: "Open Little Open or Peek in…", menuPath: ["Tabs"],
                          defaultShortcuts: [.cmd("o")], enabledKey: EnabledKey.currentTab),
    ]

    // MARK: - Archive menu

    static let archiveMenu: [CommandDefinition] = [
        CommandDefinition(id: "go-back", title: "Go Back", menuPath: ["Archive"],
                          defaultShortcuts: [.cmd("["), KeyboardShortcut(key: "left", modifiers: [.command])],
                          isCustomizable: true, enabledKey: EnabledKey.canGoBack,
                          aliases: ["Back", "Navigate Back"]),
        CommandDefinition(id: "go-forward", title: "Go Forward", menuPath: ["Archive"],
                          defaultShortcuts: [.cmd("]"), KeyboardShortcut(key: "right", modifiers: [.command])],
                          isCustomizable: true, enabledKey: EnabledKey.canGoForward,
                          aliases: ["Forward", "Navigate Forward"]),
        CommandDefinition(id: "view-archive", title: "View Archive", menuPath: ["Archive"],
                          aliases: ["Archive", "Open Archive"]),
        CommandDefinition(id: "view-history", title: "View History", menuPath: ["Archive"],
                          defaultShortcuts: [.cmd("y")], aliases: ["Show History", "History"]),
        CommandDefinition(id: "clear-archive", title: "Clear Archive", menuPath: ["Archive"], aliases: ["Delete Archive"]),
    ]

    // MARK: - Extensions, Window, Help

    static let extensionsMenu: [CommandDefinition] = [
        CommandDefinition(id: "open-extensions-picker", title: "Open Extensions", menuPath: ["Extensions"],
                          defaultShortcuts: [.cmd("e")], isCustomizable: true,
                          aliases: ["Extensions picker", "Pinned extensions", "Run extension"]),
        CommandDefinition(id: "manage-extensions", title: "Manage Extensions…", menuPath: ["Extensions"], aliases: ["Extensions"]),
        CommandDefinition(id: "add-extension", title: "Add Extension…", menuPath: ["Extensions"], aliases: ["Chrome Web Store"]),
    ]

    static let windowMenu: [CommandDefinition] = [
        CommandDefinition(id: "view-downloads", title: "View Downloads", menuPath: ["Window"],
                          defaultShortcuts: [.cmdShift("j")], aliases: ["Downloads"]),
        CommandDefinition(id: "view-library", title: "View Library", menuPath: ["Window"],
                          defaultShortcuts: [.cmdShift("l")], aliases: ["Library"]),
        CommandDefinition(id: "view-media", title: "View Media", menuPath: ["Window"]),
        CommandDefinition(id: "view-boosts", title: "View Boosts", menuPath: ["Window"]),
        // Arc 1.172.2 Window menu (runtime AX, `didClickStayOnTopWithMenuItem:`): keeps this window above others.
        CommandDefinition(id: "stay-on-top", title: "Stay On Top", menuPath: ["Window"], aliases: ["Float Window", "Always on Top"]),
        // Arc: Window ▸ View Easels & Notes, `viewEaselsAndNotes:` (docs/re/menus-and-hotkeys.md); opens
        // the Library at its Easels page, which lists Easels and Notes.
        CommandDefinition(id: "view-easels-notes", title: "View Easels & Notes", menuPath: ["Window"], aliases: ["Easels", "Notes"]),
        CommandDefinition(id: "minimize-window", title: "Minimize", menuPath: ["Window"],
                          defaultShortcuts: [.cmd("m")]),
        CommandDefinition(id: "zoom-window", title: "Zoom", menuPath: ["Window"]),
        CommandDefinition(id: "bring-all-to-front", title: "Bring All to Front", menuPath: ["Window"]),
    ]

    static let helpMenu: [CommandDefinition] = [
        // Arc Help ▸ Export Arc Notes (NIB `exportArcNotes:`; aliases from the NIB search titles).
        CommandDefinition(id: "export-notes", title: "Export Notes…", menuPath: ["Help"],
                          aliases: ["Export Notes", "Backup Notes", "Download Notes"]),
        CommandDefinition(id: "help-center", title: "Open Help Center", menuPath: ["Help"], aliases: ["Visit Help Center"]),
        CommandDefinition(id: "keyboard-shortcuts-edu", title: "Essential Keyboard Shortcuts", menuPath: ["Help"],
                          aliases: ["Keyboard Shortcuts", "Keyboard", "Shortcuts"]),
        CommandDefinition(id: "getting-started", title: "Getting Started", menuPath: ["Help"]),
        CommandDefinition(id: "contact-team", title: "Contact the Team", menuPath: ["Help"]),
        CommandDefinition(id: "release-notes", title: "Release Notes", menuPath: ["Help"]),
        CommandDefinition(id: "task-manager", title: "Open Task Manager", menuPath: ["Help", "Troubleshooting"],
                          aliases: ["Task Manager", "CPU", "Memory", "RAM"]),
        CommandDefinition(id: "record-trace", title: "Record Trace", menuPath: ["Help", "Troubleshooting"]),
        CommandDefinition(id: "cancel-trace", title: "Cancel Trace", menuPath: ["Help", "Troubleshooting"]),
        CommandDefinition(id: "copy-open-info", title: "Copy Open Info", menuPath: ["Help", "Troubleshooting"]),
        CommandDefinition(id: "reveal-open-data", title: "Reveal Open Data", menuPath: ["Help", "Troubleshooting"]),
    ]

    // MARK: - Developer submenu (View > Developer)

    static let developerMenu: [CommandDefinition] = [
        CommandDefinition(id: "developer-tools", title: "Developer Tools", menuPath: ["View", "Developer"],
                          defaultShortcuts: [KeyboardShortcut(key: "f12"), KeyboardShortcut(key: "i", modifiers: [.command, .option])],
                          enabledKey: EnabledKey.currentTab, aliases: ["DevTools", "Debug Tools"]),
        CommandDefinition(id: "javascript-console", title: "JavaScript Console", menuPath: ["View", "Developer"],
                          defaultShortcuts: [KeyboardShortcut(key: "j", modifiers: [.command, .option])],
                          enabledKey: EnabledKey.currentTab, aliases: ["Console", "JS Console", "Toggle Console"]),
        CommandDefinition(id: "view-source", title: "View Source", menuPath: ["View", "Developer"],
                          defaultShortcuts: [KeyboardShortcut(key: "u", modifiers: [.command, .option])],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "inspect-elements", title: "Inspect Elements", menuPath: ["View", "Developer"],
                          defaultShortcuts: [KeyboardShortcut(key: "c", modifiers: [.command, .option])],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "toggle-developer-mode", title: "Toggle Developer Mode", menuPath: ["View", "Developer"],
                          defaultShortcuts: [.ctrl("d")]),
        CommandDefinition(id: "network-inspector", title: "Network Inspector", menuPath: ["View", "Developer"],
                          enabledKey: EnabledKey.currentTab),
        CommandDefinition(id: "allow-js-apple-events", title: "Allow JavaScript from Apple Events", menuPath: ["View", "Developer"]),
    ]

    // MARK: - Text submenus (Edit > Find is above; Spelling, Substitutions, Transformations, Speech, Format > Font)

    static let textMenu: [CommandDefinition] = [
        CommandDefinition(id: "show-spelling", title: "Show Spelling and Grammar", menuPath: ["Edit", "Spelling and Grammar"],
                          defaultShortcuts: [.cmdShift(";")], scope: .webContent),
        CommandDefinition(id: "check-spelling", title: "Check Document Now", menuPath: ["Edit", "Spelling and Grammar"],
                          defaultShortcuts: [.cmd(";")], scope: .webContent),
        CommandDefinition(id: "check-spelling-while-typing", title: "Check Spelling While Typing", menuPath: ["Edit", "Spelling and Grammar"], scope: .webContent),
        CommandDefinition(id: "check-grammar", title: "Check Grammar With Spelling", menuPath: ["Edit", "Spelling and Grammar"], scope: .webContent),
        CommandDefinition(id: "correct-spelling-automatically", title: "Correct Spelling Automatically", menuPath: ["Edit", "Spelling and Grammar"], scope: .webContent),
        CommandDefinition(id: "show-substitutions", title: "Show Substitutions", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "smart-copy-paste", title: "Smart Copy/Paste", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "smart-quotes", title: "Smart Quotes", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "smart-dashes", title: "Smart Dashes", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "smart-links", title: "Smart Links", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "text-replacement", title: "Text Replacement", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "data-detectors", title: "Data Detectors", menuPath: ["Edit", "Substitutions"], scope: .webContent),
        CommandDefinition(id: "make-upper-case", title: "Make Upper Case", menuPath: ["Edit", "Transformations"], scope: .webContent),
        CommandDefinition(id: "make-lower-case", title: "Make Lower Case", menuPath: ["Edit", "Transformations"], scope: .webContent),
        CommandDefinition(id: "capitalize", title: "Capitalize", menuPath: ["Edit", "Transformations"], scope: .webContent),
        CommandDefinition(id: "start-speaking", title: "Start Speaking", menuPath: ["Edit", "Speech"], scope: .webContent),
        CommandDefinition(id: "stop-speaking", title: "Stop Speaking", menuPath: ["Edit", "Speech"], scope: .webContent),
        CommandDefinition(id: "font-bold", title: "Bold", menuPath: ["Edit", "Format", "Font"],
                          defaultShortcuts: [.cmd("b")], scope: .webContent),
        CommandDefinition(id: "font-italic", title: "Italic", menuPath: ["Edit", "Format", "Font"],
                          defaultShortcuts: [.cmd("i")], scope: .webContent),
        CommandDefinition(id: "font-underline", title: "Underline", menuPath: ["Edit", "Format", "Font"],
                          defaultShortcuts: [.cmd("u")], scope: .webContent),
        CommandDefinition(id: "show-fonts", title: "Show Fonts", menuPath: ["Edit", "Format", "Font"],
                          defaultShortcuts: [.cmd("t")], scope: .webContent),
    ]

    // MARK: - Code-only commands (no menu item; keys live in code, not in the nib)

    static let codeOnly: [CommandDefinition] = [
        // Import from Arc, Notes half: the zip that Arc's Help ▸ Export Arc Notes writes. Command bar only.
        CommandDefinition(id: "import-arc-notes", title: "Import Arc Notes Export…",
                          aliases: ["Import Notes", "Arc Notes", "Restore Notes"]),
        CommandDefinition(id: "change-space-icon", title: "Change Space Icon…", aliases: ["Space Icon", "Change Icon", "Emoji"]),
        // Runtime App menus only, like dynamic window rows; the RE menu dump stays static.
        CommandDefinition(id: "show-little-open-windows", title: "Show Little Open Windows"),
        CommandDefinition(id: "close-little-open-windows", title: "Close Little Open Windows"),
        CommandDefinition(id: "extension-shortcuts", title: "Extension Shortcuts"),
        CommandDefinition(id: "add-to-favorites", title: "Add to Favorites",
                          enabledKey: EnabledKey.currentTabNotFavorite, aliases: ["Favorite", "Move to Favorites"]),
        CommandDefinition(id: "remove-from-favorites", title: "Remove from Favorites",
                          enabledKey: EnabledKey.currentTabIsFavorite, aliases: ["Unfavorite", "Remove Favorite"]),
        CommandDefinition(id: "replace-pinned-url", title: "Replace Pinned URL with Current Site",
                          enabledKey: EnabledKey.currentTabHasPinnedURL,
                          aliases: ["Replace Pinned Tab", "Update Pinned URL"]),
        // Open the command bar in a scope (commandbar-completion §4.3.2). No default keys; customizable.
        CommandDefinition(id: "search-actions", title: "Search Actions", isCustomizable: true, aliases: ["Actions", "Commands"]),
        CommandDefinition(id: "search-tabs", title: "Search Tabs", isCustomizable: true, aliases: ["Tabs"]),
        CommandDefinition(id: "mute-all-tabs", title: "Mute All Tabs", aliases: ["Mute"]),
        CommandDefinition(id: "unmute-all-tabs", title: "Unmute All Tabs", aliases: ["Unmute"]),
        CommandDefinition(id: "air-traffic-control", title: "Air Traffic Control", aliases: ["Link Routing", "Link Preferences", "Air Traffic Controller"]),
        CommandDefinition(id: "manage-passwords", title: "Manage Passwords", aliases: ["Passwords"]),
        CommandDefinition(id: "search-settings", title: "Search Settings",
                          aliases: ["Manage Search Settings", "Search Engine", "Default Search Engine"]),
        CommandDefinition(id: "little-open-global", title: "Show Little Open (Global)",
                          defaultShortcuts: [KeyboardShortcut(key: "n", modifiers: [.command, .option])], scope: .global,
                          aliases: ["Little Open", "Little Arc"]),
        CommandDefinition(id: "show-shortcuts-overlay", title: "Show Shortcuts While Holding Command", scope: .window),
    ] + (1...9).map { number in
        CommandDefinition(id: "go-to-tab-\(number)", title: "Go to Tab \(number)",
                          defaultShortcuts: [.cmd(String(number))], isCustomizable: true, aliases: ["Go to Sidebar Item \(number)"])
    } + [
        CommandDefinition(id: "go-to-last-tab", title: "Go to Last Tab",
                          aliases: ["Go to Last Sidebar Item"]),
    ] + (1...9).map { number in
        CommandDefinition(id: "go-to-space-\(number)", title: "Go to Space \(number)",
                          defaultShortcuts: [.ctrl(String(number))], isCustomizable: true)
    } + (1...4).map { number in
        CommandDefinition(id: "focus-split-pane-\(number)", title: "Focus Split Pane \(number)",
                          defaultShortcuts: [.ctrlShift(String(number))], enabledKey: EnabledKey.currentTabInSplit)
    } + [
        CommandDefinition(id: "next-split-pane", title: "Next Split Pane",
                          defaultShortcuts: [.ctrlShift("]")], enabledKey: EnabledKey.currentTabInSplit),
        CommandDefinition(id: "previous-split-pane", title: "Previous Split Pane",
                          defaultShortcuts: [.ctrlShift("[")], enabledKey: EnabledKey.currentTabInSplit),
    ]

    // MARK: - Reserved out-of-scope commands (keys stay taken; no menu item)

    /// Easels, Notes, Arc Max/ChatGPT, Send to Dia, and account items.
    /// They never appear in menus. The conflict checker rejects any active
    /// command that tries to take these keys.
    static let reserved: [CommandDefinition] = [
        CommandDefinition(id: "reserved-new-chatgpt-message", title: "New ChatGPT Message (reserved)",
                          defaultShortcuts: [KeyboardShortcut(key: "g", modifiers: [.command, .option])], isReserved: true),
        CommandDefinition(id: "reserved-send-to-dia", title: "Send to Dia (reserved)", isReserved: true),
        CommandDefinition(id: "reserved-share-arc", title: "Share App (reserved)", isReserved: true),
        CommandDefinition(id: "reserved-sign-out", title: "Sign Out (reserved)", isReserved: true),
    ]
}
