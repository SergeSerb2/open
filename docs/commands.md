# OpenCommands: menus, commands, and hotkeys (M3)

Status: implemented. Package target `OpenCommands` in `Packages/OpenKit`.
Dev executable: `commands-dump`. No third-party dependencies.
No unit tests, per AGENTS.md. Verification is end to end through `commands-dump`.

`OpenCommands` is the single source of truth for every browser command.
Menus, key bindings, keyboard routing, the global Little Open hotkey, and the
command bar all read the same registry. Source facts come from
[docs/re/menus-and-hotkeys.md](re/menus-and-hotkeys.md) (Arc 1.170.0, build 89123).

## Modules

| File | Role |
|---|---|
| `Command.swift` | `CommandDefinition`, `CommandScope`, `ShortcutPriority`, enabled-state keys. |
| `Shortcut.swift` | `KeyboardShortcut`: key plus modifiers, display forms, AppKit and Carbon values. |
| `CommandRegistry.swift` | Every command: id, title, menu path, all default shortcuts, scope, customizable flag, enabled key, aliases. |
| `MenuBuilder.swift` | Builds the full `NSMenu` tree in Arc order. Routes clicks through `CommandDispatcher`. |
| `KeyBindings.swift` | Override file (`KeyBindingStore`), conflict checker. |
| `KeyboardRouter.swift` | Decides browser key versus web page key for one event. |
| `GlobalHotkey.swift` | Carbon `RegisterEventHotKey` wrapper for the global Little Open key. |
| `SuggestAdapter.swift` | Feeds `OpenSuggest`'s `ActionRegistry` from this registry. |
| `ExpectedMenu.swift` | Loads the menu table extracted from the RE report and compares it with the built menu. |

## Command registry

Each command holds: a stable `id` (never rename a shipped id), `title`,
`menuPath`, every `defaultShortcuts` entry (the first one shows in the menu;
the rest are alternate carriers, for example Go Back is Cmd+[ and Cmd+Left,
Zoom In is Cmd++ and Cmd+=, Developer Tools is F12 and Cmd+Opt+I), `scope`,
`isCustomizable`, `enabledKey`, and `aliases` (command-bar search phrases).
Out-of-scope Arc commands (Easels, Notes, Arc Max/ChatGPT, Send to Dia,
account items) stay in the registry with `isReserved = true`. They get no menu
item, and the conflict checker rejects any active command that takes their keys.

Scopes: `global` (system-wide, Little Open), `window`, `sidebar-focused`,
`command-bar`, and `web-content` (text and page keys). A wider scope contains
the narrower ones when the checker looks for collisions.

The app feeds the command bar with `CommandRegistry.makeSuggestRegistry()`.
It returns an `OpenSuggest.ActionRegistry`, so menu titles, shortcuts, and
command-bar rows cannot drift. Pin/Unpin is one menu command and two
command-bar actions (`pin-tab` needs a Today tab, `unpin-tab` needs a pinned tab).
Little Open commands keep "Little Arc" as a search alias. Display titles use
"Little Open".

## Menu bar

`MenuBuilder.buildMainMenu(dispatcher:spaces:tabs:overrides:)` builds, in order:
Open, File, Edit, View, Spaces, Tabs, Archive, Extensions, Window, Help.
Submenus: Edit holds Find, Spelling and Grammar, Substitutions, Transformations,
Speech, and Format > Font. View holds Appearance and Developer. Help holds
Troubleshooting.

Standard system items use `SystemCommandActions` metadata in `OpenCommands`.
The builder installs their native AppKit selectors with `target = nil` and
retains their registry titles and key equivalents. Services is the registered
`NSApp.servicesMenu`; Font uses the registered `NSFontManager` menu. The App does
not own a second selector map. Standard system items are present: Services, Hide, Hide Others, Show All, Quit,
Undo/Redo, Cut/Copy/Paste, Select All, Emoji & Symbols, and Enter Full Screen.
Dynamic sections: the Spaces menu lists each Space with Ctrl+1…9, and the Tabs
menu lists open tabs with Cmd+1…9. Extra key equivalents ride on hidden carrier
items in the same menu, as Arc stores duplicate items in its nib.

Clicks call `CommandDispatcher.performCommand(_:payload:)`. Item validation
reads the command's enabled-state key through
`CommandDispatcher.isCommandEnabled(_:enabledKey:)`. Keys are `always`,
`hasCurrentTab`, `currentTabPinned`, `currentTabInToday`,
`currentTabHasPinnedURL`, `currentTabIsFavorite`, `currentTabNotFavorite`,
`currentTabInSplit`, `hasMultipleSpaces`, `canGoBack`, `canGoForward`,
`textFieldFocused`, and `hasHistory`.

## Key binding overrides

Settings writes one JSON file. The shape follows Arc `StorableKeyBindings`:
command id maps to its shortcut list. Open adds a per-binding `priority`.

```json
{ "version": 1,
  "bindings": {
    "new-tab": { "shortcuts": [{ "key": "t", "modifiers": ["command"] }],
                 "priority": "browser" },
    "zoom-in": { "shortcuts": [] } } }
```

- `shortcuts` replaces the defaults. An empty list clears the command's keys.
- `priority` is `browser`, `site`, or `site-then-browser`. It sets who wins
  when a web page uses the same keys. No value keeps the command default.
- `key` is one character or a token: `space`, `tab`, `return`, `escape`,
  `left`, `right`, `up`, `down`, `delete`, `f1`…`f12`.
- `modifiers` holds `command`, `control`, `option`, `shift`.
- Only commands with `isCustomizable = true` accept new keys. The menu builder
  applies overrides, so the menu shows the user's keys at once.

`ConflictChecker.check(commands:overrides:)` groups every effective shortcut
and reports two kinds: `duplicate` (two active commands share keys in
overlapping scopes) and `reserved-key-reuse` (an active command takes a
reserved key). Three pairs ship in Arc itself and count as known, because
focus resolves them: New Folder / New Incognito Window (Cmd+Shift+N, sidebar
focus wins), Show Fonts / New Tab (Cmd+T, text focus wins), and the Little Open
global / window twins (Cmd+Opt+N). Every other conflict fails `commands-dump`
and must block a settings save.

## Keyboard routing

The app calls `KeyboardRouter.route(shortcut:context:overrides:)` from its
`NSApplication` or key window event path, before the web view sees the event.
`RoutingContext` carries: app active, command bar open, sidebar focused, text
focused, web content focused. The answer is `browserCommand(id)`, `webContent`,
`system` (normal responder chain), or `swallowed`.

Rules, in order:

1. Another app is frontmost: only `global` commands fire.
2. Command bar open: command-bar scope wins. Escape closes the bar. Window
   commands stay off so typing keeps working.
3. Sidebar focus: the sidebar command beats its window twin on shared keys.
4. Text focus: `web-content` edit commands go to the responder chain.
5. Web focus: `browser` runs the command at once. `site` sends the keys to
   the page. `site-then-browser` sends the first press to the page and runs
   the command when the same keys repeat within 0.4 seconds. This is Arc's
   rule: "Press this shortcut once to use the website's shortcut. Press it
   twice to use Arc's shortcut."
6. No matching command: web focus gets the keys; other focus goes to the system.

## Global hotkey (Little Open)

`GlobalHotkeyService` wraps Carbon `RegisterEventHotKey` (signature `OPEN`,
id 1). The app registers the `little-open-global` shortcut (Cmd+Opt+N) only
while the opt-in setting is on. `register` replaces any old registration.
`unregister()` removes the Carbon hotkey and its event handler. The service
cleans up on deinit. System shortcuts may still take priority, as Arc warns.

## commands-dump

```text
swift run commands-dump            # full check; exit 1 on any failure
swift run commands-dump --markdown # print the command table below
```

The tool starts a headless `NSApplication` (no window), builds the real menu
with two sample Spaces and two sample tabs, and prints the tree with shortcuts.
It then runs the conflict checker, loads a sample overrides file (New Tab to
Ctrl+T, Zoom In keys cleared), prints each changed item, checks the suggest
adapter, registers and unregisters the global hotkey, tests double-press
routing, and compares the built menu with
`Sources/OpenCommands/Resources/expected-menu.json`, the menu table extracted
from the RE report. It prints every missing, extra, and different item. The
table keeps its reference titles. The comparison maps "New Little Arc Window"
to "New Little Open Window" and "Open Little Arc or Peek in…" to
"Move Little Open or Peek to Space…", then lists both under
`renamed (by design): 2`. The adapter must cover all 79 seed action ids.
The only allowed gaps are the 11 out-of-scope Arc rows. Exit code is non-zero on
any unexpected conflict or difference.

## Command table

Generated by `commands-dump --markdown`. Shortcut lists every default carrier.
Menu path `—` means the command has no menu item (keys or command bar only).

| id | Title | Shortcut | Scope | Menu path |
|---|---|---|---|---|
| `about-open` | About Open | — | window | Open |
| `set-default-browser` | Set as Default Browser | — | window | Open |
| `settings` | Settings… | Cmd+, | window | Open |
| `check-for-updates` | Check for Updates… | — | window | Open |
| `import-from-browser` | Import from Another Browser… | — | window | Open |
| `hide-open` | Hide Open | Cmd+H | window | Open |
| `hide-others` | Hide Others | Cmd+Opt+H | window | Open |
| `show-all` | Show All | — | window | Open |
| `quit-open` | Quit Open | Cmd+Q | window | Open |
| `new-tab` | New Tab… | Cmd+T | window | File |
| `open-command-bar` | Open Command Bar | Cmd+L | command-bar | File |
| `new-window` | New Window | Cmd+N | window | File |
| `new-incognito-window` | New Incognito Window | Cmd+Shift+N | window | File |
| `new-little-open-window` | New Little Open Window | Cmd+Opt+N | window | File |
| `blank-window` | Blank Window | Cmd+Ctrl+N | window | File |
| `close-window` | Close Window | Cmd+Shift+W | window | File |
| `archive-tab` | Archive Tab | Cmd+W | window | File |
| `restore-last-closed-tab` | Restore Last Closed Tab | Cmd+Shift+T | window | File |
| `print` | Print… | Cmd+P | window | File |
| `save-page-as` | Save Page As… | Cmd+Shift+S | window | File |
| `capture-page` | Capture… | Cmd+Shift+2 | window | File |
| `capture-full-page` | Capture Full Page | — | window | File |
| `capture-portrait` | Capture in Portrait Mode | — | window | File |
| `share-page` | Share… | — | window | File |
| `new-profile` | New Profile | — | window | File |
| `new-boost` | New Boost | — | window | File |
| `edit-boost` | Edit Boost | — | window | File |
| `new-legacy-boost` | New Legacy Boost (Advanced) | — | window | File |
| `boost-gallery` | Boost Gallery | — | window | File |
| `undo` | Undo | Cmd+Z | web-content | Edit |
| `redo` | Redo | Cmd+Shift+Z | web-content | Edit |
| `cut` | Cut | Cmd+X | web-content | Edit |
| `copy` | Copy | Cmd+C | web-content | Edit |
| `paste` | Paste | Cmd+V | web-content | Edit |
| `paste-and-match-style` | Paste and Match Style | Cmd+Shift+V | web-content | Edit |
| `select-all` | Select All | Cmd+A | web-content | Edit |
| `delete` | Delete | — | web-content | Edit |
| `copy-url` | Copy URL | Cmd+Shift+C | window | Edit |
| `copy-url-markdown` | Copy URL as Markdown | Cmd+Opt+Shift+C | window | Edit |
| `copy-url-quote` | Copy URL as Quote | Cmd+Ctrl+Shift+C | window | Edit |
| `find` | Find… | Cmd+F | window | Edit > Find |
| `find-next` | Find Next | Cmd+G | window | Edit > Find |
| `find-previous` | Find Previous | Cmd+Shift+G | window | Edit > Find |
| `find-and-replace` | Find and Replace… | Cmd+Opt+F | window | Edit > Find |
| `use-selection-to-find` | Use Selection to Find | Cmd+E | web-content | Edit > Find |
| `jump-to-selection` | Jump to Selection | Cmd+J | web-content | Edit > Find |
| `emoji-and-symbols` | Emoji & Symbols | Cmd+Ctrl+Space | web-content | Edit |
| `toggle-sidebar` | Show/Hide Sidebar | Cmd+S | window | View |
| `toggle-toolbar` | Show/Hide Toolbar | Cmd+Shift+D | window | View |
| `toggle-full-screen` | Enter Full Screen | Cmd+Ctrl+F | window | View |
| `reload` | Refresh the Page | Cmd+R | window | View |
| `force-reload` | Force Refresh the Page | Cmd+Shift+R | window | View |
| `stop-loading` | Stop Loading | Cmd+. | window | View |
| `zoom-in` | Zoom In | Cmd++, Cmd+= | window | View |
| `zoom-out` | Zoom Out | Cmd+-, Cmd+Shift+- | window | View |
| `zoom-actual-size` | Zoom to Actual Size | Cmd+0 | window | View |
| `add-split-view` | Add Split View | Ctrl+Shift+= | window | View |
| `close-split-pane` | Close this Split Pane | Ctrl+Shift+- | window | View |
| `expand-current-split` | Expand Current Split | — | window | View |
| `separate-from-split-view` | Separate Page from Split View | — | window | View |
| `reveal-current-tab` | Reveal Current Tab | Ctrl+Space | window | View |
| `reveal-tab-in-sidebar` | Reveal Tab in Sidebar | — | window | Tabs |
| `expand-pinned-section` | Expand Pinned Section | — | window | View |
| `collapse-pinned-section` | Collapse Pinned Section | — | window | View |
| `clear-cache-and-refresh` | Clear Cache and Refresh | — | window | View |
| `clear-cookies-and-refresh` | Clear Cookies and Refresh | — | window | View |
| `cast` | Cast… | — | window | View |
| `exit-modal` | Exit | Esc | command-bar | View |
| `appearance-automatic` | Automatic | — | window | View > Appearance |
| `appearance-light` | Light | — | window | View > Appearance |
| `appearance-dark` | Dark | — | window | View > Appearance |
| `new-space` | New Space… | — | window | Spaces |
| `next-space` | Next Space | Cmd+Opt+Right | window | Spaces |
| `previous-space` | Previous Space | Cmd+Opt+Left | window | Spaces |
| `manage-spaces` | Manage Spaces… | — | window | Spaces |
| `rename-space` | Rename Space | — | window | Spaces |
| `edit-theme` | Edit Theme… | — | window | Spaces |
| `change-profile` | Change Profile | — | window | Spaces |
| `pin-unpin-tab` | Pin/Unpin Tab | Cmd+D | window | Tabs |
| `next-tab` | Next Tab | Cmd+Opt+Down | window | Tabs |
| `previous-tab` | Previous Tab | Cmd+Opt+Up | window | Tabs |
| `cycle-tab-forward` | Cycle Tab Forward | Cmd+Ctrl+Right | window | Tabs |
| `cycle-tab-backward` | Cycle Tab Backward | Cmd+Ctrl+Left | window | Tabs |
| `tab-switcher-forward` | Tab Switcher (forward) | Ctrl+Tab | window | Tabs |
| `tab-switcher-backward` | Tab Switcher (backward) | Ctrl+Shift+Tab | window | Tabs |
| `clear-unpinned-tabs` | Clear Unpinned Tabs | Cmd+Shift+K | window | Tabs |
| `new-folder` | New Folder… | Cmd+Shift+N | sidebar-focused | Tabs |
| `duplicate-tab` | Duplicate | — | window | Tabs |
| `rename-tab` | Rename Current Item | — | window | Tabs |
| `expand-all-folders` | Expand All Folders | — | window | Tabs |
| `collapse-all-folders` | Collapse All Folders | — | window | Tabs |
| `reset-tab` | Reset Tab to Original URL | — | window | Tabs |
| `reset-all-tabs-in-space` | Reset all tabs in this Space | — | window | Tabs |
| `peek-email` | Peek Email… | Cmd+Shift+E | window | Tabs |
| `join-meeting` | Join Meeting | Cmd+Ctrl+J | window | Tabs |
| `open-in-current-space` | Move Little Open or Peek to Space… | Cmd+O | window | Tabs |
| `go-back` | Go Back | Cmd+[, Cmd+Left | window | Archive |
| `go-forward` | Go Forward | Cmd+], Cmd+Right | window | Archive |
| `view-archive` | View Archive | — | window | Archive |
| `view-history` | View History | Cmd+Y | window | Archive |
| `clear-archive` | Clear Archive | — | window | Archive |
| `manage-extensions` | Manage Extensions… | — | window | Extensions |
| `add-extension` | Add Extension… | — | window | Extensions |
| `view-downloads` | View Downloads | Cmd+Shift+J | window | Window |
| `view-library` | View Library | Cmd+Shift+L | window | Window |
| `view-media` | View Media | — | window | Window |
| `view-boosts` | View Boosts | — | window | Window |
| `minimize-window` | Minimize | Cmd+M | window | Window |
| `zoom-window` | Zoom | — | window | Window |
| `bring-all-to-front` | Bring All to Front | — | window | Window |
| `help-center` | Open Help Center | — | window | Help |
| `keyboard-shortcuts-edu` | Essential Keyboard Shortcuts | — | window | Help |
| `getting-started` | Getting Started | — | window | Help |
| `contact-team` | Contact the Team | — | window | Help |
| `release-notes` | Release Notes | — | window | Help |
| `task-manager` | Open Task Manager | — | window | Help > Troubleshooting |
| `record-trace` | Record Trace | — | window | Help > Troubleshooting |
| `cancel-trace` | Cancel Trace | — | window | Help > Troubleshooting |
| `copy-open-info` | Copy Open Info | — | window | Help > Troubleshooting |
| `reveal-open-data` | Reveal Open Data | — | window | Help > Troubleshooting |
| `developer-tools` | Developer Tools | F12, Cmd+Opt+I | window | View > Developer |
| `javascript-console` | JavaScript Console | Cmd+Opt+J | window | View > Developer |
| `view-source` | View Source | Cmd+Opt+U | window | View > Developer |
| `inspect-elements` | Inspect Elements | Cmd+Opt+C | window | View > Developer |
| `toggle-developer-mode` | Toggle Developer Mode | Ctrl+D | window | View > Developer |
| `network-inspector` | Network Inspector | — | window | View > Developer |
| `allow-js-apple-events` | Allow JavaScript from Apple Events | — | window | View > Developer |
| `show-spelling` | Show Spelling and Grammar | Cmd+: | web-content | Edit > Spelling and Grammar |
| `check-spelling` | Check Document Now | Cmd+; | web-content | Edit > Spelling and Grammar |
| `check-spelling-while-typing` | Check Spelling While Typing | — | web-content | Edit > Spelling and Grammar |
| `check-grammar` | Check Grammar With Spelling | — | web-content | Edit > Spelling and Grammar |
| `correct-spelling-automatically` | Correct Spelling Automatically | — | web-content | Edit > Spelling and Grammar |
| `show-substitutions` | Show Substitutions | — | web-content | Edit > Substitutions |
| `smart-copy-paste` | Smart Copy/Paste | — | web-content | Edit > Substitutions |
| `smart-quotes` | Smart Quotes | — | web-content | Edit > Substitutions |
| `smart-dashes` | Smart Dashes | — | web-content | Edit > Substitutions |
| `smart-links` | Smart Links | — | web-content | Edit > Substitutions |
| `text-replacement` | Text Replacement | — | web-content | Edit > Substitutions |
| `data-detectors` | Data Detectors | — | web-content | Edit > Substitutions |
| `make-upper-case` | Make Upper Case | — | web-content | Edit > Transformations |
| `make-lower-case` | Make Lower Case | — | web-content | Edit > Transformations |
| `capitalize` | Capitalize | — | web-content | Edit > Transformations |
| `start-speaking` | Start Speaking | — | web-content | Edit > Speech |
| `stop-speaking` | Stop Speaking | — | web-content | Edit > Speech |
| `font-bold` | Bold | Cmd+B | web-content | Edit > Format > Font |
| `font-italic` | Italic | Cmd+I | web-content | Edit > Format > Font |
| `font-underline` | Underline | Cmd+U | web-content | Edit > Format > Font |
| `show-fonts` | Show Fonts | Cmd+T | web-content | Edit > Format > Font |
| `add-to-favorites` | Add to Favorites | — | window | — |
| `remove-from-favorites` | Remove from Favorites | — | window | — |
| `replace-pinned-url` | Replace Pinned URL with Current Site | — | window | — |
| `mute-all-tabs` | Mute All Tabs | — | window | — |
| `unmute-all-tabs` | Unmute All Tabs | — | window | — |
| `air-traffic-control` | Air Traffic Control | — | window | — |
| `manage-passwords` | Manage Passwords | — | window | — |
| `search-settings` | Search Settings | — | window | — |
| `little-open-global` | Show Little Open (Global) | Cmd+Opt+N | global | — |
| `show-shortcuts-overlay` | Show Shortcuts While Holding Command | — | window | — |
| `go-to-tab-1` | Go to Tab 1 | Cmd+1 | window | — |
| `go-to-tab-2` | Go to Tab 2 | Cmd+2 | window | — |
| `go-to-tab-3` | Go to Tab 3 | Cmd+3 | window | — |
| `go-to-tab-4` | Go to Tab 4 | Cmd+4 | window | — |
| `go-to-tab-5` | Go to Tab 5 | Cmd+5 | window | — |
| `go-to-tab-6` | Go to Tab 6 | Cmd+6 | window | — |
| `go-to-tab-7` | Go to Tab 7 | Cmd+7 | window | — |
| `go-to-tab-8` | Go to Tab 8 | Cmd+8 | window | — |
| `go-to-tab-9` | Go to Tab 9 | Cmd+9 | window | — |
| `go-to-last-tab` | Go to Last Tab | — | window | — |
| `go-to-space-1` | Go to Space 1 | Ctrl+1 | window | — |
| `go-to-space-2` | Go to Space 2 | Ctrl+2 | window | — |
| `go-to-space-3` | Go to Space 3 | Ctrl+3 | window | — |
| `go-to-space-4` | Go to Space 4 | Ctrl+4 | window | — |
| `go-to-space-5` | Go to Space 5 | Ctrl+5 | window | — |
| `go-to-space-6` | Go to Space 6 | Ctrl+6 | window | — |
| `go-to-space-7` | Go to Space 7 | Ctrl+7 | window | — |
| `go-to-space-8` | Go to Space 8 | Ctrl+8 | window | — |
| `go-to-space-9` | Go to Space 9 | Ctrl+9 | window | — |
| `focus-split-pane-1` | Focus Split Pane 1 | Ctrl+Shift+1 | window | — |
| `focus-split-pane-2` | Focus Split Pane 2 | Ctrl+Shift+2 | window | — |
| `focus-split-pane-3` | Focus Split Pane 3 | Ctrl+Shift+3 | window | — |
| `focus-split-pane-4` | Focus Split Pane 4 | Ctrl+Shift+4 | window | — |
| `next-split-pane` | Next Split Pane | Ctrl+Shift+} | window | — |
| `previous-split-pane` | Previous Split Pane | Ctrl+Shift+{ | window | — |

Reserved (out-of-scope keys):
- `reserved-new-note` New Note (reserved): Ctrl+Shift+N
- `reserved-new-note-in-split` New Note in Split (reserved): Ctrl+Opt+N
- `reserved-new-easel` New Easel (reserved): Ctrl+Shift+E
- `reserved-new-chatgpt-message` New ChatGPT Message (reserved): Cmd+Opt+G
- `reserved-send-to-dia` Send to Dia (reserved): —
- `reserved-view-easels-notes` View Easels & Notes (reserved): —
- `reserved-export-arc-notes` Export Notes (reserved): —
- `reserved-share-arc` Share App (reserved): —
- `reserved-sign-out` Sign Out (reserved): —

## Open questions

1. Which duplicate key carrier Arc shows (Go Back, Zoom, Developer Tools) is a
   run-time choice in Arc. Open shows the first shortcut and hides the rest.
   The router matches every carrier, so all keys work.
2. Go to Tab (Cmd+1…9), Go to Space (Ctrl+1…9), and Split pane focus
   (Ctrl+Shift+1…4) defaults come from public docs, not the nib. Read the real
   values in Arc Settings > Shortcuts before shipping.
3. The global Little Open default (Cmd+Opt+N) and its on/off default are
   guesses from strings. Confirm in Arc Settings.
4. The forbidden-combination list for custom shortcuts lives in Arc code and
   is not in strings. Open rejects only reserved-key reuse for now.
5. Menu order inside each menu follows the RE report's item order, which the
   nib does not prove. Check against Arc on screen later.


### Native edit and undo ownership (Step C)

Native menus validate and dispatch to the first responder. Text fields and the
Chromium page responder receive Cut, Copy, Paste, Paste and Match Style, Select
All, Undo and Redo. The window key hook uses the same registry-native path when
CEF receives a key directly. It does not invoke model undo before the page.

The sidebar uses the model UndoManager only with sidebar focus or after no text
responder takes the action. Reveal Tab in Sidebar focuses the actual outline.
Native AppKit text fields use a separate window text UndoManager; the command
bar keeps its own editing manager. Thus typing cannot enter model undo groups.
Find uses AppKit's find actions in native text. Only the window responder's
fallback opens the browser find bar.

`Tabs > Reveal Tab in Sidebar` has no default shortcut, matching the empty
shortcut cell in docs/re/menus-and-hotkeys.md §Tabs. The separate View command
keeps Ctrl+Space. The menu comparison JSON includes both titles.


### Space theme editing (Step 5)

`edit-theme` opens the theme panel for the focused Space. The Space context
menu's “Edit Theme Color…” uses the same path, focusing its target first.
No shortcut is added. Panel keys use the native responder chain; browser
Cmd+T/L/W close and flush the editor before the existing browser command
path runs. Undo/redo stay on the model's shared undo manager.
