# Settings

Settings uses Open’s original design. The standard resizable window opens at 960 × 660 pt with an 800 × 540 pt minimum. A 232 pt navigation column stays in place while the content scrolls. The window remembers its frame. Settings and its section views are created only when needed.

## Navigation and search

The sections are General, Appearance, Tabs & Archive, Search, Links, Downloads, Previews, Ad Blocking, Site Permissions, Passwords & Cards, Browsing Data, Profiles, Shortcuts, Extensions, and Advanced. Library is separate and is unchanged.

Command-F focuses the global search. Labels, help, aliases, and every active shortcut command are indexed. `is:changed` limits results to changed settings. Up/Down selects a result; Return opens its section and pulses the target once. Escape clears search. Command-1 through Command-9 opens the first nine sections. Command-[ and Command-] move through section history. Typing while a navigation item has focus starts search.

Each row has a stable `section/row` ID. `open://settings/<section>[/<row>]` opens it through the App’s URL delivery path. Unknown sections, rows, query strings, and fragments are refused. Existing Settings, Shortcuts, Air Traffic Control, Search Settings, New Profile and import commands keep their actions. The command bar registers the same metadata index as a suggestion provider; it does not construct Settings during launch.

## Profile scope and changes

Search, Tabs & Archive, Downloads, Ad Blocking, Site Permissions, Passwords & Cards, and Browsing Data show a Profile pill. A pill in search results belongs to its per-Profile group. Profiles manages names, icons, Space counts, creation and deletion. It does not contain another settings pane.

A 4 pt dot marks a value that differs from its shipping default. Hover or keyboard focus reveals Reset. Archive changes apply to the selected Profile, then offer Apply to all Profiles. The shipping external-link destination is Little Open. Reset preserves that default.

## Ownership and persistence

The App supplies one SettingsViewModel with the existing BrowserModel, SnapshotStore, actions, and UserDefaults. Existing view models and stores own mutations. The view layer does not create a second persistence path. Profile updates use the shared SnapshotStore and its one-second save debounce. Operations that need durable state flush it before continuing.

Links validates every draft, preserves order, and rolls the model back when its durable save fails. Test a Link expands inline; its deep link expands the URL, source-app and recent-Space controls automatically. A failed rule save leaves the captured draft open. Profile deletion captures IDs and names before confirmation, requires the exact token, then rechecks default/in-use guards and uses the App’s ProfileDataOwner barrier before removing data. A delayed confirmation never deletes the later selection.

Ad-block lists keep ready, busy, and retired-Profile guards. Host-only validation uses the store’s registrable-domain rules. Failed updates keep prior lists. Global enabled state and per-Profile list/site choices retain their original action callbacks.

KeyBindingStore keeps saved bindings separate from conflicting drafts. Invalid bare keys stay in recording mode and never write. Escape cancels, Delete clears, and Reset all requires confirmation. Import/export, priorities, extension conflicts and keyBindingsDidChange keep their existing semantics. Every unassigned row is blank at rest and offers Add shortcut on hover or focus.

Default-browser changes, folder pickers, file panels, and Keychain consent remain user actions. Automated verification never accepts a macOS system dialog. The import wizard retains its count-only probe, explicit consent, cancellation, partial-result and error paths. Import graph construction remains on the main actor; this change does not claim large-import performance.

## Phase 1 boundaries

Site Permissions, Passwords & Cards, Browsing Data and Extensions are native section shells with clearly labelled actions to existing browser destinations. Native management details are phase 2. Appearance uses real website appearance, focused-window toolbar/full-URL and app-icon settings. Its approved static miniature remains behind one preview seam until the shared miniature kit lands. There are no invented sidebar-position or tab-number preferences.

The App icon action changes the running app icon without changing the signed bundle. Alternate artwork caches and asynchronous restore keep the existing behavior described in [first-run verification](first-run/steps-ef-verification.md#alternate-icon-restore-split).

## Control migration

Every former pane action is retained. The table identifies its current row and guard.

| Old location / control | G2 section and stable ID | Behaviour / guard |
|---|---|---|
| General default browser | `general/default-browser` | Existing default-browser service; OS confirmation remains user-owned |
| General automatic updates and help | `general/automatic-updates` | Existing preference and updater; Learn more in the row help |
| General Check | Navigation footer | Existing updater check; status is shown only after a known updater result |
| General quit warning | `general/warn-before-quitting` | Existing download-in-progress quit guard |
| General import wizard | `general/import` | Same model, consent, progress, partial and error guards; retained multi-step sheet |
| Advanced export | `general/export` | Same snapshot and Archive export action |
| Advanced restore windows | `general/restore-windows` | Same persisted preference |
| App Icon six choices | `appearance/app-icon` | Same icon model and app action |
| Added website appearance and focused-window toolbar | `appearance/website-appearance`, `appearance/toolbar` | Real existing model state; static preview seam approved |
| Advanced full URL | `appearance/full-url` | Disabled label/control and explanatory help while toolbar is off |
| Profiles archive / apply scope | `tabs-archive/archive-after` | Same propose/apply methods; applies to this Profile, then inline Apply to all Profiles |
| Links Little Open archive | `tabs-archive/little-open-archive` | Same selected Profile setting and Links commit action |
| Advanced sleeping tabs | `tabs-archive/sleep` | Same global sleep policy action |
| Shortcuts Favorites and ninth-tab options | `tabs-archive/include-favorites`, `tabs-archive/ninth-tab` | Original preference keys; shortcut search aliases retained |
| Profiles engine, management, suggestions | `search/engine`, `search/engines`, `search/suggestions` | Same Profile settings; built-in engine protections and suggestion notice retained |
| Profiles download location / ask each time | `downloads/location`, `downloads/ask` | Same Profile settings and folder picker action |
| General Previews sheet master / folders / pages | `previews/enabled`, `previews/folders`, `previews/pages` | Inline; dependent rows disabled when master is off |
| Links Little Open hotkey / Option-Command-click / external links | `links/little-open-hotkey`, `links/option-command-click`, `links/external-links` | Same Links model, defaults, commit and global-hotkey callback |
| Links Shift-click Peek / other-site Peek | `links/peek-shift-click`, `links/peek-other-sites` | Same preferences |
| Links default destination / route list | `links/destination`, `links/rules` | Same route validation, order, drag/drop, edit/delete, durability rollback and failed-save sheet retention |
| Links Test URL / source app / recent Space / details | `links/test` | Same evaluator and validation; app picker remains available |
| Profiles Privacy / Notifications | `site-permissions/privacy`, `site-permissions/notifications` | Native phase-1 shell, clearly labelled Open in Tab; original Profile target action |
| Profiles Passwords / Credit Cards | `passwords-cards/passwords`, `passwords-cards/cards` | Native phase-1 shell, clearly labelled Open in Tab; original Profile target action |
| Profiles Clear Browsing Data | `browsing-data/clear` | Retained destructive sheet; captured Profile identity, time range, kinds and in-flight guards |
| Profiles create, icon, rename, Spaces, delete unused / selected | `profiles/manage`, `profiles/name`, `profiles/delete` | Create with Space assignment retained as multi-step sheet; inline rename; same icon action; same exact-name/delete-token and default/in-use guards |
| Advanced ad-block master | `ad-blocking/enabled` | Same global store and app action |
| Ad Block sheet list search / categories / checkboxes / status / info / Reset | `ad-blocking/lists` | Inline; same list IDs, ready/busy/retired-Profile guards and async actions |
| Ad Block allowed-site add / remove | `ad-blocking/allowed-sites` | Same host validation and per-Profile store |
| Ad Block debug | `ad-blocking/debug` | Same clipboard action |
| Shortcuts every command, recording, conflict, clear/reset, priority, import/export/revert, learning window | `shortcuts/<command-id>`, `shortcuts/priority`, `shortcuts/essential` | Same KeyBindingStore, conflict guard and keyBindingsDidChange; Reset All confirmation is an app-owned sheet |
| Extensions destination | `extensions/manage` | Native phase-1 shell opens current extension manager |
| Advanced sounds / haptics / window drag / quotes / PiP / theme / Boosts | `advanced/sound`, `advanced/haptics`, `advanced/window-dragging`, `advanced/shared-quotes`, `advanced/picture-in-picture`, `advanced/theme-data`, `advanced/boosts` | Same preferences |
| Advanced more / translate / reveal / copy info | `advanced/more`, `advanced/translate`, `advanced/data-folder`, `advanced/copy-info` | Same app-owned actions |

## Visual system and accessibility

SettingsTokens.Redesign owns spacing, fonts, colors and finite motion durations. Labels are 13 pt regular, help 11.5 pt, navigation 13 pt medium and section labels 11 pt semibold. Section labels start 4 pt inside the card edge. Cards have 12 pt corners, 14 pt row padding, and inset separators. Light and dark are designed separately; dark content is #15151c and cards are #1d1d27. Space color supplies the accessible accent. Sun colors mark actions that need attention.

A focus ring appears only on the keyboard-focused control. Disabled dependent rows use secondary labels and explain their dependency. Each row exposes its label, help and changed state. Reduce Motion removes the section rise and keeps only the finite fade. No repeating animation or timer runs at rest.

## Verification and frames

`tools/e2e/settings_redesign_g2.py` exercises the real App through its automation socket with a short private data root. It verifies navigation/search/deep links, store round trips, profile scope, shortcut recording and conflict guards, list/site actions, retained sheets, Reduce Motion and window bounds. Native inputs stay in Open’s process. Runs hold the machine’s on-screen lock and restore changed preferences in finally.

The settings-preview product retains functional store/action checks and renders the new section layout. Library renders and checks remain separate and unchanged. Native frames in docs/settings and the lead’s G-frames/g3 review set bind the display scale and ICC profile in their receipts. Performance reports distinguish content submission and display-link pacing from WindowServer scanout.
