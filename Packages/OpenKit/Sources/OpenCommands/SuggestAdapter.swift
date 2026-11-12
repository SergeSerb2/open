import Foundation
import OpenSuggest

/// Feeds `OpenSuggest`'s action registry from this registry, so the command
/// bar and the menus never drift. The app builds its registry with
/// `CommandRegistry.makeSuggestRegistry()` and passes it to `SuggestEngine`.
/// OpenSuggest itself stays untouched.
public extension CommandRegistry {
    /// Browser actions for the command bar. Commands with no command-bar value
    /// (text editing, spelling, window chrome) stay out, as in `docs/suggest.md`.
    static func makeSuggestActions() -> [BrowserAction] {
        var actions: [BrowserAction] = []
        for command in active where command.menuPath != nil || suggestOnlyIDs.contains(command.id) {
            guard !suggestExcludedIDs.contains(command.id) else { continue }
            // Pin/Unpin is one menu command and two command-bar actions.
            if command.id == "pin-unpin-tab" {
                actions.append(BrowserAction(
                    id: "pin-tab", title: "Pin Tab", aliases: ["Pin", "Pin/Unpin Tab"],
                    shortcut: command.defaultShortcuts.first?.symbolDisplay,
                    symbol: "pin", requirement: .currentTabInToday
                ))
                actions.append(BrowserAction(
                    id: "unpin-tab", title: "Unpin Tab", aliases: ["Unpin", "Pin", "Pin/Unpin Tab"],
                    shortcut: command.defaultShortcuts.first?.symbolDisplay,
                    symbol: "pin.slash", requirement: .currentTabPinned
                ))
                continue
            }
            // Numbered go-to commands are menu carriers; the command bar uses
            // the dynamic focus-space action instead.
            if command.id.hasPrefix("go-to-") || command.id.hasPrefix("focus-split-pane") { continue }
            actions.append(browserAction(for: command))
        }
        return actions
    }

    static func makeSuggestRegistry() -> ActionRegistry {
        ActionRegistry(makeSuggestActions())
    }

    /// Ids kept equal to the `OpenSuggest` seed, so the adapter is a drop-in feed.
    private static let suggestIDOverrides: [String: String] = [
        "reveal-current-tab": "reveal-tab-in-sidebar",
        "keyboard-shortcuts-edu": "keyboard-shortcuts",
    ]

    /// One command as one command-bar action.
    static func browserAction(for command: CommandDefinition) -> BrowserAction {
        BrowserAction(
            id: suggestIDOverrides[command.id] ?? command.id,
            title: displayTitle(for: command),
            aliases: command.aliases,
            shortcut: command.defaultShortcuts.first?.symbolDisplay,
            symbol: symbolName(for: command),
            requirement: requirement(for: command)
        )
    }

    private static func displayTitle(for command: CommandDefinition) -> String {
        // Command-bar titles drop the trailing ellipsis, as in ActionRegistry.
        command.title.hasSuffix("…") ? String(command.title.dropLast()) : command.title
    }

    private static func requirement(for command: CommandDefinition) -> ActionRequirement {
        switch command.enabledKey {
        case EnabledKey.currentTab: return .currentTab
        case EnabledKey.currentTabInToday: return .currentTabInToday
        case EnabledKey.currentTabPinned: return .currentTabPinned
        case EnabledKey.currentTabHasPinnedURL: return .currentTabHasPinnedURL
        case EnabledKey.currentTabIsFavorite: return .currentTabIsFavorite
        case EnabledKey.currentTabNotFavorite: return .currentTabNotFavorite
        case EnabledKey.currentTabInSplit: return .currentTabInSplit
        case EnabledKey.multipleSpaces: return .multipleSpaces
        default: return .none
        }
    }

    private static func symbolName(for command: CommandDefinition) -> String {
        symbols[command.id] ?? "command"
    }

    private static let suggestOnlyIDs: Set<String> = [
        "add-to-favorites", "remove-from-favorites", "replace-pinned-url",
        "mute-all-tabs", "unmute-all-tabs", "air-traffic-control",
        "manage-passwords", "search-settings", "extension-shortcuts",
    ]

    /// Menu commands with no command-bar row (text, spelling, chrome, help detail).
    private static let suggestExcludedIDs: Set<String> = [
        "reveal-tab-in-sidebar", // View command already emits this action ID.
        "about-open", "check-for-updates", "hide-open", "hide-others", "show-all", "quit-open",
        "close-window", "blank-window", "share-page", "capture-page", "capture-full-page", "capture-portrait",
        "undo", "redo", "cut", "copy", "paste", "paste-and-match-style", "select-all", "delete",
        "use-selection-to-find", "jump-to-selection", "emoji-and-symbols",
        "show-spelling", "check-spelling", "check-spelling-while-typing", "check-grammar", "correct-spelling-automatically",
        "show-substitutions", "smart-copy-paste", "smart-quotes", "smart-dashes", "smart-links", "text-replacement", "data-detectors",
        "make-upper-case", "make-lower-case", "capitalize", "start-speaking", "stop-speaking",
        "font-bold", "font-italic", "font-underline", "show-fonts",
        "exit-modal", "cast", "minimize-window", "zoom-window", "bring-all-to-front",
        "view-media", "record-trace", "cancel-trace", "copy-open-info", "reveal-open-data",
        "network-inspector", "allow-js-apple-events", "toggle-developer-mode",
        "tab-switcher-forward", "tab-switcher-backward", "cycle-tab-forward", "cycle-tab-backward",
        "peek-email", "join-meeting", "next-split-pane", "previous-split-pane", "show-shortcuts-overlay",
        "little-open-global", "getting-started", "release-notes", "help-center",
    ]

    private static let symbols: [String: String] = [
        "open-extensions-picker": "puzzlepiece.extension", "extension-shortcuts": "command",
        "new-tab": "plus", "contact-team": "ellipsis.bubble", "new-window": "macwindow.badge.plus", "new-incognito-window": "eyeglasses",
        "new-little-open-window": "macwindow.on.rectangle", "archive-tab": "archivebox",
        "restore-last-closed-tab": "arrow.uturn.backward", "print": "printer", "save-page-as": "square.and.arrow.down",
        "new-profile": "person.crop.circle.badge.plus", "new-boost": "paintbrush", "edit-boost": "paintbrush",
        "boost-gallery": "sparkles", "copy-url": "link", "copy-url-markdown": "text.badge.plus", "copy-url-quote": "quote.bubble",
        "find": "magnifyingglass", "toggle-sidebar": "sidebar.left", "toggle-toolbar": "menubar.rectangle",
        "toggle-full-screen": "arrow.up.left.and.arrow.down.right", "reload": "arrow.clockwise",
        "force-reload": "arrow.clockwise.circle", "zoom-in": "plus.magnifyingglass", "zoom-out": "minus.magnifyingglass",
        "zoom-actual-size": "1.magnifyingglass", "add-split-view": "rectangle.split.2x1", "close-split-pane": "xmark.rectangle",
        "expand-current-split": "arrow.up.left.and.arrow.down.right", "separate-from-split-view": "rectangle.split.2x1",
        "reveal-current-tab": "sidebar.left", "clear-cache-and-refresh": "trash", "clear-cookies-and-refresh": "trash.circle",
        "appearance-automatic": "circle.lefthalf.filled", "appearance-light": "sun.max", "appearance-dark": "moon",
        "new-space": "plus.rectangle.on.rectangle", "next-space": "arrow.right", "previous-space": "arrow.left",
        "manage-spaces": "square.grid.2x2", "rename-space": "pencil", "edit-theme": "paintpalette", "change-space-icon": "face.smiling", "change-profile": "person.crop.circle",
        "next-tab": "arrow.down", "previous-tab": "arrow.up", "clear-unpinned-tabs": "xmark.circle",
        "new-folder": "folder.badge.plus", "new-easel": "scribble.variable", "duplicate-tab": "plus.square.on.square", "rename-tab": "pencil",
        "expand-all-folders": "folder", "collapse-all-folders": "folder.fill", "reset-tab": "arrow.counterclockwise",
        "reset-all-tabs-in-space": "arrow.counterclockwise.circle", "open-in-current-space": "macwindow.on.rectangle",
        "go-back": "chevron.left", "go-forward": "chevron.right", "view-archive": "archivebox", "view-history": "clock",
        "clear-archive": "trash", "manage-extensions": "puzzlepiece.extension", "add-extension": "puzzlepiece",
        "view-downloads": "arrow.down.circle", "view-library": "books.vertical", "view-boosts": "sparkles",
        "keyboard-shortcuts-edu": "keyboard", "task-manager": "cpu",
        "developer-tools": "hammer", "javascript-console": "terminal", "view-source": "chevron.left.forwardslash.chevron.right",
        "inspect-elements": "magnifyingglass", "settings": "gearshape", "set-default-browser": "checkmark.seal",
        "import-from-browser": "square.and.arrow.down.on.square",
        "add-to-favorites": "star", "remove-from-favorites": "star.slash", "replace-pinned-url": "pin.circle",
        "mute-all-tabs": "speaker.slash", "unmute-all-tabs": "speaker.wave.2",
        "air-traffic-control": "airplane", "manage-passwords": "key", "search-settings": "magnifyingglass.circle",
        "expand-pinned-section": "chevron.down", "collapse-pinned-section": "chevron.up",
    ]
}
