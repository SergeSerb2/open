# Arc menus and hotkeys (1.170.0, build 89123)

Target: Arc 1.170.0 (89123) at `/Applications/Arc.app`. This file records facts
only. It does not copy Arc code or assets.

## How to read this file

- `NIB` means the value comes from `Base.lproj/MainMenu.nib`. The command was
  `rea decode-interface-builder /Applications/Arc.app --max-documents 64`.
  Raw output is in `.re/hotkeys/decode-ib.json`. The extractor is
  `.re/hotkeys/extract_menus.py`. It writes `.re/hotkeys/mainmenu-items.csv`.
- `STR` means the value comes from `strings .re/bin/Arc-arm64`. Raw output is
  in `.re/hotkeys/strings-raw.txt`. Symbol output is in
  `.re/hotkeys/nm-demangled.txt` (`nm` plus `xcrun swift-demangle`).
- `WEB` means the value comes from public web pages. The build wins when web
  pages and the build differ. Web pages are old. Treat web-only keys as a
  guess until a person checks them in the running app.
- A shortcut such as `Cmd+Shift+N` uses short names. `Cmd` is Command. `Opt`
  is Option. `Ctrl` is Control.
- In the nib, an upper-case key letter means Shift. For example, key `N` with
  the Ctrl mask shows as Ctrl+Shift+N. Tables show the full form.

## Limits. Read these first

- The app has one Arc menu nib: `Base.lproj/MainMenu.nib` (678 objects).
  Sparkle adds five updater nibs. No other nib or storyboard holds Arc menus.
  Most menus live in code (Swift). See the context menu section.
- The rea graph omits `NSMenuItems` arrays. So item grouping, titles, keys,
  and selectors are exact. Item order inside each menu is not proven. Tables
  sort by nib object ID. Do not ship pixel order from these tables. Check
  order on screen later.
- The same limit hides user-defined runtime attribute values. Strings in the
  nib prove the keys `arcKeyBindingID` and `arcKeyBindingPriority` exist.
  They do not show which items carry which ID. So the exact set of
  customizable menu items is not proven. The system itself is proven.
- `rea inspect-native-dispatch-metadata` failed on this binary. Error:
  `Apple static metadata input exceeds its 64 MiB snapshot budget`. Selectors
  here come from the nib action edges instead. That is enough for menu items.
- The shared Ghidra project was not queried. No new Ghidra run was started,
  per task rules. Code-only default keys that live in Swift constants are
  marked as web-based guesses.

## Menu bar at a glance

The nib holds a main menu (`_NSMainMenu`), an Arc menu (`_NSAppleMenu`), a
Services menu, a Window menu (`_NSWindowsMenu`), a Help menu (`_NSHelpMenu`),
and a Font menu (`_NSFontMenu`). It holds 23 `NSMenu` objects and 219
`NSMenuItem` objects. 85 items carry a key equivalent. 151 distinct selectors
appear. 30 empty-title items are separators. One separator has the outlet
name `manageSpacesDivider`, which proves the empty-title reading.

Top-level order below is a guess. It follows normal macOS order and public
Arc help text. The nib proves membership, not order.

| Menu | Items | Holds |
|---|---|---|
| Arc | 19 | About, Settings, Import, account |
| File | 28 | New tab/window, Capture, Print |
| Edit | 19 | Copy URL forms, Find, text menus |
| View | 32 | Sidebar, zoom, Split View, Developer |
| Spaces | 9 | Next/Prev, New, Manage |
| Tabs | 23 | New Tab, pin, Tab Switcher |
| Archive | 8 | Back/Forward, History, Archive |
| Extensions | 2 | Manage, Add |
| Window | 10 | Downloads, Library, Media |
| Help | 9 | Help Center, Shortcuts EDU |

Submenus: Edit holds Find, Spelling, Substitutions, Transformations, Speech,
and Format. Format holds Font. Help holds Troubleshooting. View holds
Developer and a dynamic Appearance submenu (Automatic, Light, Dark). Tabs
holds one untitled dynamic submenu with placeholder items Item 1 to Item 3.
Code fills that submenu at run time. Its real title is not in the nib.

## Full menu tree

Selector is the Objective-C action from the nib target-action edge. An empty
selector on a normal item means code sets the action at run time. Separators
and the Share Arc and Import items work that way.


### Arc (19 items)

| Item | Shortcut | Selector |
|---|---|---|
| About Arc |  | orderFrontStandardAboutPanel: |
| Set as Default Browser |  | setAsDefaultBrowser: |
| Show All |  | unhideAllApplications: |
| Privacy Policy |  | showPrivacyPolicy: |
| Share Arc |  |  |
| Hide Arc | Cmd+H | hide: |
| Hide Other Windows | Cmd+Opt+H | hideOtherApplications: |
| Quit Arc | Cmd+Q | userQuitApp: |
| Preferences… | Cmd+, | showPreferences: |
| Check for Updates… |  | checkForUpdates: |
| Import from Another Browser… |  |  |
| Sign Out |  | signOut: |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| Services > submenu 2181 |  | submenuAction: |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |

### File (28 items)

| Item | Shortcut | Selector |
|---|---|---|
| Boost Gallery |  | openBoostGallery: |
| Open Command Bar | Cmd+L | toggleOpenOmnibox: |
| Capture… | Cmd+Shift+2 | capturePage: |
| New Profile |  | newProfile: |
| Edit Boost |  | editBoost: |
| New Little Arc Window | Cmd+Opt+N | newLittleBrowserWindow: |
| Close Window | Cmd+Shift+W | closeWindow: |
| Share… |  | share: |
| New Window | Cmd+N | newWindow: |
| New Note | Ctrl+Shift+N | newNote: |
| Restore Last Closed Tab | Cmd+Shift+T | reopenLastTab: |
| New Tab… | Cmd+T | newWindowForTab: |
| New Boost |  | newBoost: |
| Print | Cmd+P | printPage: |
| Capture in Portrait Mode |  | capturePrettyScreenshot: |
| Archive Tab | Cmd+W | closeCurrentItem: |
| New Incognito Window | Cmd+Shift+N | newIncognitoWindow: |
| Send to Dia |  | sendCurrentTabToDia: |
| New Legacy Boost (Advanced) |  | newLegacyBoost: |
| Save Page As | Cmd+Shift+S | save: |
| New Note (in Split) | Opt+Ctrl+N | newNoteInSplitView: |
| Capture Full Page |  | captureFullPage: |
| New Easel | Ctrl+Shift+E | newEasel: |
| Blank Window | Cmd+Ctrl+N | blankWindow: |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |

### Edit (19 items)

| Item | Shortcut | Selector |
|---|---|---|
| Redo | Cmd+Shift+Z | redo: |
| Copy URL as Markdown | Cmd+Opt+Shift+C | copyCurrentURLAsMarkdown: |
| Select All | Cmd+A | selectAll: |
| Paste and Match Style | Cmd+Shift+V | pasteAsPlainText: |
| Copy URL | Cmd+Shift+C | copyCurrentURL: |
| Paste | Cmd+V | paste: |
| Cut | Cmd+X | cut: |
| Copy URL as Quote | Cmd+Ctrl+Shift+C | copyCurrentURLAsQuote: |
| Copy | Cmd+C | copyAction: |
| Delete |  | delete: |
| Undo | Cmd+Z | undo: |
| (separator) |  |  |
| (separator) |  |  |
| Find > submenu 2216 |  | submenuAction: |
| Spelling and Grammar > submenu 2224 |  | submenuAction: |
| Substitutions > submenu 2234 |  | submenuAction: |
| Transformations > submenu 2243 |  | submenuAction: |
| Speech > submenu 2251 |  | submenuAction: |
| Format > submenu 2259 |  | submenuAction: |

### View (32 items)

| Item | Shortcut | Selector |
|---|---|---|
| Show/Hide Sidebar | Cmd+S | toggleArcSidebar: |
| Zoom Out | Cmd+- | zoomOut: |
| Add Split View | Ctrl+Shift+= | addSplitPanel: |
| Close this Split Pane | Ctrl+Shift+- | closeFocusedSplitViewPanel: |
| Enter/Exit Full Screen | Cmd+Ctrl+F | toggleFullScreen: |
| Stop Loading | Cmd+. | stopLoadingCurrentTab: |
| Expand Pinned Section |  | expandPinnedSection: |
| Expand Current Split |  | maximizeCurrentSplitViewPane: |
| Refresh the Page | Cmd+R | reloadPage: |
| Zoom to Actual Size | Cmd+0 | resetZoom: |
| Reveal Current Tab | Ctrl+Space | focusSidebar: |
| Collapse Pinned Section |  | collapsePinnedSection: |
| Force Refresh the Page | Cmd+Shift+R | forceReloadPage: |
| Zoom In | Cmd++ | zoomIn: |
| Clear Cache and Refresh |  | clearCacheAndRefresh: |
| Show/Hide Toolbar | Cmd+Shift+D | toggleArcToolbar: |
| Separate Page from Split View |  | separateTabFromSplitView: |
| Exit | Esc | exit: |
| Cast |  | cast: |
| Clear Cookies and Refresh |  | clearCookiesAndRefresh: |
| Zoom Out | Cmd+Shift+- | zoomOut: |
| Zoom In | Cmd+= | zoomIn: |
| Zoom In | Cmd+= | zoomIn: |
| Appearance > submenu 2284 |  | submenuAction: |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| (separator) |  |  |
| Developer > submenu 2300 |  | submenuAction: |
| (separator) |  |  |

### Spaces (9 items)

| Item | Shortcut | Selector |
|---|---|---|
| Change Profile |  | changeProfileForCurrentSpace: |
| Rename Space |  | renameFocusedSpace: |
| Manage Spaces… |  | toggleSpaceManager: |
| Next Space | Cmd+Opt+Right | nextSpace: |
| Previous Space | Cmd+Opt+Left | previousSpace: |
| New Space… |  | newSpace: |
| Edit Theme… |  | editSpaceTheme: |
| (separator) |  |  |
| (separator) |  |  |

### Tabs (23 items)

| Item | Shortcut | Selector |
|---|---|---|
| New ChatGPT Message… | Cmd+Opt+G | gptMessage: |
| Collapse All Folders |  | collapseAllFolders: |
| Rename Current Item |  | rename: |
| Expand All Folders |  | expandAllFolders: |
| Cycle Tab Backward | Cmd+Ctrl+Left | cycleTabBackward: |
| Pin/Unpin Tab | Cmd+D | toggleSelectedItemsPinned: |
| Tab Switcher (backward) | Ctrl+Shift+Tab | cycleToPreviousRecentTab: |
| Peek Email… | Cmd+Shift+E | peekEmail: |
| Reset all tabs in this Space |  | resetVisiblePinnedTabs: |
| Clear Unpinned Tabs | Cmd+Shift+K | clearExplore: |
| Duplicate |  | duplicate: |
| Reveal Tab in Sidebar |  | revealCurrentTabInSidebar: |
| Previous Tab | Cmd+Opt+Up | previousTab: |
| Cycle Tab Forward | Cmd+Ctrl+Right | cycleTabForward: |
| New Folder… | Cmd+Shift+N | newList: |
| Tab Switcher (forward) | Ctrl+Tab | cycleToNextRecentTab: |
| Join Meeting | Cmd+Ctrl+J | joinLiveMeeting: |
| Reset Tab to Original URL |  | resetTab: |
| Next Tab | Cmd+Opt+Down | nextTab: |
| Open Little Arc or Peek in… | Cmd+O | openInCurrentSpace: |
| New Tab… | Cmd+T | newWindowForTab: |
| (separator) |  |  |
| (separator) > submenu 1698 |  | submenuAction: |

### Archive (8 items)

| Item | Shortcut | Selector |
|---|---|---|
| Go Forward | Cmd+] | navigateTabForward: |
| Go Back | Cmd+Left | navigateTabBackArrow: |
| View Archive |  | showArchive: |
| Go Back | Cmd+[ | navigateTabBack: |
| View History | Cmd+Y | showAllHistory: |
| Clear Archive |  | clearArchive: |
| Go Forward | Cmd+Right | navigateTabForwardArrow: |
| (separator) |  |  |

### Extensions (2 items)

| Item | Shortcut | Selector |
|---|---|---|
| Manage Extensions… |  | navigateToChromeExtensionsPage: |
| Add Extension… |  | navigateToChromeWebStore: |

Code adds more at run time (2026-10-25; `features-advanced.md` §11.1 EX-5
and §11.3 EX-10): one item per extension with a 16×16 icon above these two
(`BrowserExtensionsMainMenuProvider`), and a hidden item "Open Extensions"
(`toggleOpenExtensions:`, Cmd+E, binding id `openExtensionsPicker`, catalog
text "Open pinned extensions picker.") built by the hidden-items builder at
`0x10003aa54`. "Use Selection to Find" has no key in the nib, so Cmd+E is
Arc's extension picker, not a Find command.

### Window (10 items)

| Item | Shortcut | Selector |
|---|---|---|
| View Downloads | Cmd+Shift+J | toggleDownloads: |
| View Library | Cmd+Shift+L | toggleLibrary: |
| View Media |  | viewScreenshotsAndCaptures: |
| View Boosts |  | viewBoosts: |
| Minimize Window | Cmd+M | performMiniaturize: |
| View Easels & Notes |  | viewEaselsAndNotes: |
| Zoom |  | performZoom: |
| (separator) |  |  |
| (separator) |  |  |
| Bring All to Front |  | arrangeInFront: |

### Help (9 items)

| Item | Shortcut | Selector |
|---|---|---|
| Visit Help Center |  | visitHelpCenter: |
| Essential Keyboard Shortcuts |  | keyboardShortcutsEDU: |
| Getting Started |  | showWelcomeToArc: |
| Export Arc Notes |  | exportArcNotes: |
| Contact the Team |  | contactTheTeam: |
| Release Notes |  | onSelectResource_releaseNotes: |
| Restore Data |  | presentRestoreDataFlow: |
| (separator) |  |  |
| Troubleshooting > submenu 1605 |  | submenuAction: |

### Find (6 items)

| Item | Shortcut | Selector |
|---|---|---|
| Find Previous | Cmd+Shift+G | arc_performFindPanelAction: |
| Jump to Selection | Cmd+J | arc_performFindPanelAction: |
| Find… | Cmd+F | arc_performFindPanelAction: |
| Find and Replace | Cmd+Opt+F | arc_performFindPanelAction: |
| Use Selection to Find |  | arc_performFindPanelAction: |
| Find Next | Cmd+G | arc_performFindPanelAction: |

### Spelling (6 items)

| Item | Shortcut | Selector |
|---|---|---|
| Show Spelling and Grammar | Cmd+: | showGuessPanel: |
| Correct Spelling Automatically |  | toggleAutomaticSpellingCorrection: |
| Check Document Now | Cmd+; | checkSpelling: |
| Check Grammar With Spelling |  | toggleGrammarChecking: |
| Check Spelling While Typing |  | toggleContinuousSpellChecking: |
| (separator) |  |  |

### Substitutions (8 items)

| Item | Shortcut | Selector |
|---|---|---|
| Smart Copy/Paste |  | toggleSmartInsertDelete: |
| Text Replacement |  | toggleAutomaticTextReplacement: |
| Smart Links |  | toggleAutomaticLinkDetection: |
| Smart Quotes |  | toggleAutomaticQuoteSubstitution: |
| Smart Dashes |  | toggleAutomaticDashSubstitution: |
| Data Detectors |  | toggleAutomaticDataDetection: |
| Show Substitutions |  | orderFrontSubstitutionsPanel: |
| (separator) |  |  |

### Transformations (3 items)

| Item | Shortcut | Selector |
|---|---|---|
| Capitalize |  | capitalizeWord: |
| Make Lower Case |  | lowercaseWord: |
| Make Upper Case |  | uppercaseWord: |

### Speech (2 items)

| Item | Shortcut | Selector |
|---|---|---|
| Stop Speaking |  | stopSpeaking: |
| Start Speaking |  | startSpeaking: |

### Format (1 items)

| Item | Shortcut | Selector |
|---|---|---|
| Font > submenu 2267 |  | submenuAction: |

### Font (3 items)

| Item | Shortcut | Selector |
|---|---|---|
| Underline | Cmd+U | underline: |
| Bold | Cmd+B | addFontTrait: |
| Italic | Cmd+I | addFontTrait: |

### Troubleshooting (6 items)

| Item | Shortcut | Selector |
|---|---|---|
| Cancel Trace |  | cancelTrace: |
| Record Trace |  | recordTrace: |
| Open Task Manager |  | openTaskManager: |
| Copy Arc Info |  | copyArcInfo: |
| Reveal Arc Data |  | revealArcData: |
| (separator) |  |  |

### Developer (8 items)

| Item | Shortcut | Selector |
|---|---|---|
| Developer Tools | F12 | toggleDevTools: |
| Network Inspector |  | networkInspector: |
| View Source | Cmd+Opt+U | viewSource: |
| Toggle Developer Mode | Ctrl+D | toggleDeveloperMode: |
| JavaScript Console | Cmd+Opt+J | javaScriptConsole: |
| Inspect Elements | Cmd+Opt+C | inspectElements: |
| Developer Tools | Cmd+Opt+I | toggleDevTools: |
| Allow JavaScript from Apple Events |  | allowJavascriptFromAppleEvents: |

### Untitled submenu (dynamic) (7 items)

| Item | Shortcut | Selector |
|---|---|---|
| Dark |  | setDarkAppearance: |
| Automatic |  | setAutomaticAppearance: |
| Light |  | setLightAppearance: |
| Item 1 |  |  |
| Item 2 |  |  |
| Item 3 |  |  |
| Websites, Easels, and Notes will use: |  |  |

## Enabled and hidden rules (what static data can prove)

Code holds 58 outlets to menu items (`MainMenuOutlets`, object 1532 in the
nib). An outlet means code can hide, enable, or retitle that item. Examples:
`newTabMenuItem`, `closeCurrentTabMenuItem` (Archive Tab), `pinTabMenuItem`,
`focusSidebarMenuItem`, `keyboardShortcutsEDUMenuItem`. Full pairs are in
`.re/hotkeys/mainmenu-items.csv` (column `outlet`).

Duplicate titles with different keys are key carriers. The menu holds two Go
Back items (Cmd+[ and Cmd+Left), two Go Forward items (Cmd+] and Cmd+Right),
three Zoom In items (Cmd++, Cmd+=, Cmd+=), two Zoom Out items, and two
Developer Tools items (F12 and Cmd+Opt+I). One carrier in each set shows in
the menu. The rest give extra keys. Which one shows is a run-time choice.
`STR` also shows `Hidden Shortcuts` and `hidden` handling in `KeyBindings`.
Treat all duplicate keys as live unless a person proves otherwise.

The Appearance submenu header `Websites, Easels, and Notes will use:` has no
selector. It is a label, not a command. The Tabs dynamic submenu (Item 1 to
Item 3) and the Services menu are filled by the system or code at run time.

## Master shortcut table (menu keys, from the nib)

Scope is `Window` for all rows. They fire when an Arc window is key, except
text keys (Undo, Copy, Find, Font) which need a text field or web view.
`Custom` means the KeyBindings system can remap the action. See the
customization section. `NIB` is the source for every row.

| Action | Shortcut | Menu | Custom |
|---|---|---|---|
| New Tab | Cmd+T | File/Tabs | Yes, NIB |
| Open Command Bar | Cmd+L | File | Yes, NIB |
| New Window | Cmd+N | File | Yes, NIB |
| New Little Arc Window | Cmd+Opt+N | File | Yes, NIB |
| New Incognito Window | Cmd+Shift+N | File | Yes, NIB |
| Blank Window | Cmd+Ctrl+N | File | ?, NIB |
| Archive Tab (close current) | Cmd+W | File | Yes, NIB |
| Close Window | Cmd+Shift+W | File | ?, NIB |
| Restore Last Closed Tab | Cmd+Shift+T | File | Yes, NIB |
| Capture (page) | Cmd+Shift+2 | File | ?, NIB |
| Print | Cmd+P | File | No, NIB |
| Save Page As | Cmd+Shift+S | File | No, NIB |
| Show/Hide Sidebar | Cmd+S | View | Yes, NIB |
| Reveal Current Tab (focus sidebar) | Ctrl+Space | View | ?, NIB |
| Refresh / Force Refresh | Cmd+R / Cmd+Shift+R | View | No, NIB |
| Stop Loading | Cmd+. | View | No, NIB |
| Zoom In / Out / Actual | Cmd++ or Cmd+= / Cmd+- / Cmd+0 | View | No, NIB |
| Full Screen | Cmd+Ctrl+F | View | No, NIB |
| Show/Hide Toolbar | Cmd+Shift+D | View | ?, NIB |
| Exit (full screen / modal) | Esc | View | No, NIB |
| Add Split View | Ctrl+Shift+= | View | Yes, NIB |
| Close Split Pane | Ctrl+Shift+- | View | Yes, NIB |
| Next / Previous Tab | Cmd+Opt+Down / Up | Tabs | Yes, NIB |
| Cycle Tab Forward / Backward | Cmd+Ctrl+Right / Left | Tabs | ?, NIB |
| Tab Switcher fwd / back | Ctrl+Tab / Ctrl+Shift+Tab | Tabs | Yes, NIB |
| Pin/Unpin Tab | Cmd+D | Tabs | Yes, NIB |
| Clear Unpinned Tabs | Cmd+Shift+K | Tabs | Yes, NIB |
| New Folder | Cmd+Shift+N | Tabs | ?, NIB |
| Peek Email | Cmd+Shift+E | Tabs | ?, NIB |
| Join Meeting | Cmd+Ctrl+J | Tabs | ?, NIB |
| Open Little Arc or Peek in… | Cmd+O | Tabs | ?, NIB |
| ChatGPT Message (Arc Max) | Cmd+Opt+G | Tabs | Out of scope |
| Next / Previous Space | Cmd+Opt+Right / Left | Spaces | Yes, NIB |
| Go Back / Forward | Cmd+[ or Left / Cmd+] or Right | Archive | Yes, NIB |
| View History | Cmd+Y | Archive | No, NIB |
| Copy URL / as Markdown / as Quote | Cmd+Shift+C / Cmd+Opt+Shift+C / Cmd+Ctrl+Shift+C | Edit | Yes, NIB |
| Undo / Redo | Cmd+Z / Cmd+Shift+Z | Edit | No, NIB |
| Find / Next / Previous | Cmd+F / Cmd+G / Cmd+Shift+G | Find | No, NIB |
| View Downloads / Library | Cmd+Shift+J / Cmd+Shift+L | Window | ?, NIB |
| Developer Tools | Cmd+Opt+I or F12 | Developer | No, NIB |
| View Source / Console / Inspect | Cmd+Opt+U / J / C | Developer | No, NIB |
| Toggle Developer Mode | Ctrl+D | Developer | No, NIB |
| Preferences | Cmd+, | Arc | No, NIB |
| Hide Arc / Hide Others / Quit | Cmd+H / Cmd+Opt+H / Cmd+Q | Arc | No, NIB |

New Note is Ctrl+Shift+N and New Easel is Ctrl+Shift+E in this build
(File menu, `newNote:` / `newEasel:`). Both are out of scope for Open v1.
New Note in Split is Ctrl+Opt+N (`newNoteInSplitView:`).

## Shortcuts that live in code, not in the nib

These actions have no nib key. Strings prove the actions and the Settings
UI. Default keys come from public docs. Mark each doc key as a guess until
a person checks it in Arc Settings > Shortcuts.

| Action | Shortcut (guess) | Scope | Source |
|---|---|---|---|
| Go to sidebar item 1–9 | Cmd+1…Cmd+9 | Window | STR+WEB |
| Go to last sidebar item | Cmd+9 variant | Window | STR |
| Go to Space 1–9 | Ctrl+1…Ctrl+9 | Window | STR+WEB |
| Focus Split View pane 1–4 | Ctrl+Shift+1…4 | Window | STR+WEB |
| Next/prev Split View pane | Ctrl+Shift+} / { | Window | WEB only |
| Little Arc (system-wide) | Cmd+Opt+N | Global | STR+WEB |
| Show shortcuts while holding Cmd | Hold Cmd | Window | STR |

Evidence for the numbered rows: strings hold `Jumps to the first item` up to
`Jumps to the ninth item`, `Jumps to the last item at the bottom of your
Sidebar`, `Description for Space-switching shortcut`, and `Switch to first
Split View page` up to fourth, plus next/previous. Settings strings hold
`switchToNinthSidebarItemEnabled` and an include/exclude Favorites prefix
for item counting. The exact modifier for each family lives in Swift
constants (`KeyboardShortcutConstants`, `KeyBindings` client). Static
strings do not hold the values. The web split (Cmd for items, Ctrl for
Spaces, Ctrl+Shift for splits) is coherent, but it is still a guess.

Other code paths: `keyboardShortcutFocusSidebar`, `keyboardShortcutL`,
`keyboardShortcutT`, and `keyboardShortcutCommandOptionG` appear as stored
keys. `focusSidebar:` already has Ctrl+Space in the nib. Do not invent keys
for the rest.

## Custom shortcuts (Settings)

The system is real and Open must copy its shape. Evidence (`STR`):
`KeyBindingsClient` with `setShortcutForAction`, `bindingForAction`,
`registerUserOverrides`, `resetToDefaults`; `StorableKeyBindings.json` as
the store name; `KeyboardShortcutInterceptionView` to record keys;
`ShortcutsPane` in Preferences with `Custom Shortcuts`, `Reset All
Shortcuts`, `Reset Shortcut to Default`, `Remove Conflicting Shortcut`,
and `Extension Shortcuts`. Main-menu actions join by the
`arcKeyBindingID` runtime attribute. Numbered, Space, and Split actions
join by code registration.

Priority rule: strings hold `When shortcuts conflict, Arc wins.`, `When
shortcuts conflict, the website wins.`, and `Press this shortcut once to
use the website's shortcut. Press it twice to use Arc's shortcut.` So each
binding has a priority: Arc first, site first, or site-then-Arc on double
press. `GlobalHotkeyListenerClient.registeredSystemShortcuts` reads macOS
symbolic hot keys (`kHISymbolicHotKeyCode` and friends). Settings warn:
`System shortcuts may take priority over this shortcut`.

Forbidden combos exist. Strings hold `Attempting to set user shortcut for
comination that is forbidden.` [sic] and `The forbidden shortcut managed to
get registered in KeyboardShortcutInterceptionView`. The forbidden list is
in code. It is not in strings. Do not guess it.

Help > Essential Keyboard Shortcuts (`keyboardShortcutsEDU:`) opens a
teaching window (`KeyboardShortcutsEDUWindow`). Its list is built in code.
Its default contents should match the tables here. Check on screen later.

## Global hotkey and Little Arc

`GlobalHotkeyManager` uses Carbon `RegisterEventHotKey` (`STR`: symbols
`_RegisterEventHotKey`, `_CopySymbolicHotKeys`, `EventHotKeyID`). The
setting key is `globalLittleBrowserHotkeyEnabled`. The toggle handler is
`onToggleGlobalLittleBrowserHotkey`. The register call is
`registerLittleBrowserShortcut`. So one system-wide key opens Little Arc
from any app when the setting is on. The in-window twin is File > New
Little Arc Window, Cmd+Opt+N (`newLittleBrowserWindow:`). The global
default is a guess: same combo, registered system-wide. Also in strings:
`optionCommandClickLittleArcEntryPointEnabled` (Opt+Cmd+Click opens a link
in Little Arc) and `Show Little Arc` / `Close Little Arc Windows` actions
with no nib key.

## Command Bar

Open keys: Cmd+T (`newWindowForTab:`) and Cmd+L (`toggleOpenOmnibox:`).
Typing searches tabs, Spaces, history, and menu actions. Menu actions carry
search words from the nib. 79 keyword strings exist. Examples: Show/Hide
Sidebar also matches `Toggle Sidebar`; Open Task Manager matches `Task;
Manager; Task Manager; Cpu; Memory: RAM`; Manage Spaces matches `Space
Management; Organize; Toggle Space Manager; View Spaces`. Full pairs are in
`.re/hotkeys/ib-localizable.txt`. Code calls this layer TypeTravel
(`TypeTravelMainMenuIndex`, `arcTypeTravelTitle`, `arcTypeTravelTriggers`).
Inside the bar, Up/Down, Return, and Esc follow normal macOS list rules.
That last sentence is a guess. No string proves it. The bar also shows key
caps (`CommandBar.KeyboardShortcutView`, `showShortcutsWhenHoldingCmd`).
Update 2026-10-25: `showShortcutsWhenHoldingCmd` belongs to the Favorites
("top apps") view state, behind the remote flag
`show-top-app-shortcuts-when-holding-cmd` (built-in default false). The
Essential Keyboard Shortcuts window lists five items. See
`commandbar-completion.md` §4–§5 (CC-23…CC-31).

## Gestures and mouse

- Page swipe: `PageSwipeController`, `PageSwipeTrackingState`, and
  `webContentsWantsOverscrollSwipeEvents:` (`STR`). Two-finger horizontal
  swipe on web content goes Back/Forward. It shares the Cmd+[ / Cmd+]
  actions (`navigateTabBack:` / `navigateTabForward:`).
- Space swipe: the string `Jumps over to your %@ Space without needing to
  swipe.` proves a swipe between Spaces exists. Fingers and direction are
  not in strings. Guess: horizontal swipe on the sidebar or Space bar.
- Sidebar gesture: `hideSidebarWithGesture`, `didHideSidebarWithGesture`,
  `isPreviewingGestureHiddenSidebar`. An edge swipe hides and previews the
  sidebar. Exact edge is not proven.
- Pinch: `NSMagnificationGestureRecognizer`, `zoomAtPinchBegin`, and
  `pinchToSummarize` (Arc Max, out of scope). Pinch zooms web content.
  Pinch to summarize is AI. Skip it for Open.
- Capture drag: `Hold Command and Shift to start a Capture.` (`STR`). Hold
  Cmd+Shift, then drag. It pairs with File > Capture…, Cmd+Shift+2.
- Clicks: Opt+Cmd+Click opens Little Arc (setting above). Shift+Click
  multi-selects sidebar items (normal macOS rule; `STR` holds
  `shiftClickedLinkToOpenModal` and split-close Opt+Click flag
  `optionClickSplitTabCloseButtonToUnsplitEnabled`). Double-click renames
  a tab (`Double-click to rename`, `STR`). Sidebar resize has pan and
  double-click recognizers (`handleSidebarResizePanGestureRecognizer:`).
- No trackpad string names three-finger or four-finger moves. Do not add
  them without screen proof.

## Context menus (right-click, built in code)

No context menu lives in a nib. Code builds them (`STR` file names):
`ContextMenus/SidebarMenu+TabContextMenu.swift`,
`SidebarMenu+ListContextMenu.swift` (folders), `SidebarMenu+MoveMenu.swift`,
`SpaceMenu.swift` and `SidebarSpaceState+SpaceContextMenu.swift`,
`WindowState+ContextMenu.swift`, `WindowData+SidebarItemContextMenus.swift`.
Families and proven item names:

- Tab row: Archive Tab, Archive Tabs Above/Below, Archive Other Tabs,
  Pin/Unpin, Mute/Unmute (`Context menu action to mute the selected tab`),
  Share, Copy URL forms, Move to Space / New Window / Profile
  (`moveToSpaceTabContextMenuOption` and friends), New Folder from
  Selection. Ask Dia / Ask about tab items are AI. Skip them.
- Space header: Rename, New Folder, Share, Edit Theme, Change Icon,
  Delete Space, Manage Spaces, Manage Profile, header show/hide. Strings
  name each one (`Title for the 'Rename' menuItem in the Space Context
  Menu.` and peers).
- Folder/list: New Folder, New Folder from Selection, Copy Links (plain
  and Markdown), Share folder, archive/close/delete forms with singular
  and plural titles. Live Folder adds source toggles.
- Favorites/pinned: Remove Favorite, Close Favorite, Edit Pinned URL,
  Reset Tab to Original URL. Split item adds Add Tab to Split, Separate,
  layout orientation, Share Split View.
- Web content: Chromium base menu plus Arc adds Capture, Capture Full
  Page, Share, Copy URL, Hide/Show Full URL, Hide/Show Shared Quotes,
  Manage Extensions. Site Control Center adds per-site items. Exact web
  menu order comes from ArcCore at run time. It is not in this binary.
- Downloads, media, Captures (Library): Open, Copy URL, Show in Finder,
  Send via iMessage, AirDrop, Delete/Hide. Easel/Note items are out of
  scope except where they share tab code.

Exact item order, separators, and disabled rules for these menus need
screen checks. Static data proves families, not full lists.

### Split row menu (from code, 2026-10-25)

No capture shows this menu. Its items and order come from the function
that builds it in the arm64 slice, `0x102eccc9c` (shared Ghidra project,
read-only; `DecompAt.java` run from `~/Library/Caches/OpenRE/ghidra-scripts-vf`,
plus `xcrun llvm-objdump -d` with an `adrp`/`add` string resolver; raw output
in `.re/`). It appends items in this order:

| Order | Item | Evidence |
|---|---|---|
| — | Menu title "Split View Context Menu" | string `0x103a373d0` |
| 1 | "Share Split View", then a separator. Only when a flag is clear. | strings `0x103957ae0`, comment "Title for the 'Share' menuItem in the Split view Context Menu." |
| 2 | "Separate All Tabs" | string `0x103a37460` with comment "…separate all tabs from a split view sidebar item" |
| 3 | "Add Tab…" | inline small string `Add Tab` + `E2 80 A6`, comment "…add a new tab to a split view sidebar item" |
| 4 | "Convert to Vertical Split View" or "Convert to Horizontal Split View", one selected item only | `0x102ecefbc` calls `0x102ed0208`, which picks the title by length (30 or 32 bytes) |
| 5 | Separator, then the header "Tab Options" | inline small string, comment "…header in split view menu that demarcates child tab level options" |
| 6 | One item per pane, built by `0x102ecf180`: the pane title cut to 30 characters plus "…", holding "Separate from Split View", a separator, Mute (`0x102ecc2f0`), Copy Link (`0x102ec9680`), Copy Link as Markdown (`0x102ecc068`), a separator, and Archive Item | strings `0x103a12680`, "Context menu action to mute the selected tab", "Copy link as Markdown"; the truncation call takes `0x1e` and `…` |
| 7 | Separator, "Reset Name and Icon", then optional "Change Icon…" (`0x102ee1b38`) and "Rename…" (`0x102eca348`) | string `0x103a15de0`; inline `Change Icon`, `Rename` |
| 8 | Separator, "Duplicate", then staff-only "Copy IDs" | inline `Duplicate`, `Copy IDs` |
| 9 | Separator, "Archive Item" / "Archive Items" with "Archive Other Tabs", "Archive Tabs Below", "Archive Tabs Above" | strings `0x103a37520`, `0x103a37580`, `0x103a375f0` |
| 10 | `0x102ecb9b8`: the root-Spaces submenu ("Move to") and "New Folder with N Items" | "Menu Item that shows a user's root spaces in a submenu" |

guess: display order is append order. guess: each pane item is a submenu (a
title item followed by its own list). "Archive Other/Below/Above" are not in
the captured tab menus (F0115, F0116), so they are probably alternates or
multi-selection items. Open builds this menu without Share (account link),
Reset Name and Icon, Change Icon…, and Rename… (Open's splits have no custom
name or icon), and without staff items. It puts "Move to" before the last
separator, as in the captured tab menus.

### Media and Picture in Picture (from code, 2026-10-25)

Source: features-advanced §8 (PP-8, PP-16, PP-21); decompiles in
`.re/media/ghidra-media.txt`; type metadata in `.re/media/swift-fields.tsv`.

- No main-menu item and no default shortcut exists for media or PiP:
  `MainMenuAction` has no such case, and the nib has no such item.
- Command bar: "Mute all tabs" and "Unmute all tabs" (TypeTravel
  candidates `muteAllTabs`, `unmuteAllTabs`).
- Tab context menu: "Mute" / "Unmute" (`toggleMuted`), disabled when the
  tab is silent and not muted (F0116 shows "Mute" disabled). Split pane
  submenus have the same item (rule 6 above).
- PiP window menu (the window's settings button), in this order: "Keep
  Window on Top" (check mark), separator, a disabled header
  "Picture-in-picture on <host>:", "Open automatically" (checked), "Turn
  off", separator, "Copy URL", then "Mute" or "Unmute". The header block
  shows only when the source URL has a host. The Document PiP window menu
  has "Keep Window on Top" and the same header.
- Button tooltips (all with a 0.45 s delay): mini player "Open Picture in
  Picture", "Close Mini Player", "Toggle Microphone", "Toggle Camera",
  "Previous Track", "Play" / "Pause", "Next Track", "Adjust Tab Volume";
  PiP window "Close", "Minimize", "Skip back 15 seconds", "Skip ahead 15
  seconds", scrubber hint "Drag upwards to seek precisely".
- Keyboard media keys (play/pause, next, previous) reach the page through
  Chromium's system media controls, not through Arc's menus (PP-22).

## Out of scope for Open v1 (present in this build)

- Account/sync: Sign Out, Share Arc (referral), Import sync prompts,
  Restore Data iCloud paths. Keep Import from Another Browser. It is v1.
- Arc Max AI: New ChatGPT Message… (Cmd+Opt+G, `gptMessage:`), Ask on Page
  text (`Press Command + F on any page to ask a question and let Max
  answer`), pinch to summarize, Ask Dia tab items, Send to Dia.
- Easels and Notes: New Easel (Ctrl+Shift+E), New Note (Ctrl+Shift+N),
  New Note in Split (Ctrl+Opt+N), View Easels & Notes, Export Arc Notes.
  Notes show a phase-out notice in strings. Still list the keys so Open
  does not reuse them by accident.
- Dia handoff: Send to Dia (`sendCurrentTabToDia:`). Dia is the successor
  app. Open has no Dia. Drop the item.

## Public docs vs this build

| Point | Public web | This build (wins) |
|---|---|---|
| New Note | Ctrl+N (2023 guide) | Ctrl+Shift+N, NIB |
| New Easel | Ctrl+Shift+L (2023 guide) | Ctrl+Shift+E, NIB |
| Go to Space | Ctrl+1…9 | Not in nib, guess |
| Split focus | Ctrl+Shift+1…4 | Not in nib, guess |
| Little Arc | Cmd+Opt+N anywhere | Cmd+Opt+N in-app, NIB; global needs setting, STR |
| Sidebar | Cmd+S | Cmd+S, NIB |
| History | Cmd+Y | Cmd+Y, NIB |

The old in-binary help URL `https://resources.arc.net/hc/en-us/articles/20595231349911-Shortcuts`
now returns 404. The live custom-shortcut article is
`25622899860631-How-to-Set-Custom-Keyboard-Shortcuts-on-Arc-for-Desktop`.
It confirms Settings > Shortcuts remapping on macOS. It does not list
defaults. DefKey (Arc 1.96) matches the nib on all 29 keys it lists,
except it omits most Arc-only keys. No DefKey key contradicts the nib.

## Evidence index

- `rea decode-interface-builder /Applications/Arc.app --max-documents 64`
  to `.re/hotkeys/decode-ib.json` (6 documents, MainMenu 678 objects).
- `python3 .re/hotkeys/extract_menus.py` to `mainmenu-items.csv/json` and
  `mainmenu-keys.txt` (219 items, 85 keys, 151 selectors).
- `strings .re/bin/Arc-arm64` to `strings-raw.txt` (192,033 lines);
  `nm` plus `xcrun swift-demangle` to `nm-demangled.txt`.
- `plutil -p` on `Settings_Settings` and `ARC_AskArc` English strings (2
  and 6 keys). Menu English lives in the nib `NSDev` values, not in a
  top-level `en.lproj`. Only `en-GB.lproj/MainMenu.strings` exists, with
  2 keys.
- Failed: `rea inspect-native-dispatch-metadata` (64 MiB budget, above).
  Web fetches to resources.arc.net returned 404 to this tool. Search
  snippets and DefKey were used instead.

## Needs a person in the running app

1. Menu order inside each menu, and top-level menu order.
2. Which duplicate key carrier shows (Go Back, Zoom, Developer Tools).
3. Default keys for Go to Item, Go to Space, and Split focus families.
   Read them in Settings > Shortcuts. Do not trust the web split yet.
4. Global Little Arc default key and on/off default.
5. Space swipe and sidebar edge-swipe fingers and direction.
6. Full context menu lists with order and disabled rules.
7. Which menu items the `arcKeyBindingID` set holds. Read the Shortcuts
   pane list. It is the ground truth for `Custom = Yes`.
8. Command Bar Up/Down/Return/Esc and hold-Cmd overlay behavior.
9. Keys inside a focused PiP window (space, arrows, Esc, Cmd+W), if any.
