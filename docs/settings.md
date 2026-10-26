# Settings and Library

`OpenSettings` supplies the Settings and Library windows. It has no engine imports. Settings edits the shared model, `UserDefaults`, `KeyBindingStore`, and `AdBlockStore`. Browser and system work crosses `SettingsActions` or `LibraryActions`. This implements steps 1–7 of [the plan](plans/settings-library.md). App presentation belongs to [app-shell integration](plans/app-shell.md).

## App entry points

Construct these objects once on the main actor. Pass the app's existing `BrowserModel` and **the same `SnapshotStore` that owns the data-root lock**. A second snapshot writer for the same root is not supported.

```swift
let settings = SettingsViewModel(
    model: model, actions: settingsActions, defaults: .standard,
    root: root, snapshot: snapshot, focusedProfileID: focusedProfileID)
settings.attach(adBlockStore: adBlockStore)
let settingsPresenter = SettingsPresenter(viewModel: settings)
```

Attach the shared `AdBlockStore`. Settings opens the selected profile on refresh/selection, including newly created profiles, and tracks which opens have finished, and closes its state before profile deletion. The shared store owns update schedules and bundled defaults. Call `settings.adBlock?.refresh()` from its store-event adapter after external Site Control Center or list updates. List and allowed-site controls stay disabled until the selected Profile is open. Store faults use plain text; technical details remain in Copy Debug Info. List status reads cached typed receipts, with no file parsing during view drawing. The preview opens fixture profiles without a schedule. Refresh reconciles externally deleted profiles too. `settings.adBlock?.hasOtherBlocker` accepts the app's extension state.

`SettingsPresenter.show(pane:)` reuses one standard titled window, 684×650 pt. Closing the window retains it. Showing or reactivating it refreshes external browser/store state. The root registers defaults when it is constructed; construct it once at launch. The selected pane writes `open.settings.lastPane`. The native tab bar changes the window title. Account, AI, internal, referral, and sync panes are absent.

For Library, inject the app's existing archive/history stores and its single Downloads feed. Supply app-owned Captures through `FileCapturesProvider(root:)`, or a conforming provider that reads the same index. Pass the shared favicon cache when available.

```swift
let library = LibraryViewModel(
    model: model, defaults: .standard, actions: libraryActions,
    downloads: downloadsProvider, captures: capturesProvider,
    archives: archiveStores, histories: historyStores,
    snapshot: snapshot, faviconStore: faviconStore)
let libraryPresenter = LibraryPresenter(viewModel: library)
```

`LibraryPresenter.show(section:)` reuses one 960×640 pt window (minimum 720×480), with the section as its title and search/filters in its content toolbar. The native AppKit source list supports keyboard selection and extends under the transparent title bar. Its shared cell paints the system accent selection; this avoids AppKit’s GPU-only selection material in the never-ordered renderer. No separate preview view replaces the table. Showing or reactivating Library refreshes Archive/History and the capture index. Section, search, and selection survive closing; section also persists in `open.library.lastSection`. Search and selection remain separate for each section while the window is open. Refresh the capture provider when the capture feature writes its index. An observable Downloads provider can publish snapshots directly; Library keeps no second download list.

Inject retained archive stores, including retired-profile stores from the app's profile catalog when applicable. Library keeps those stores across profile refreshes. Current profile changes add the corresponding stores through `ProfileDirectories` and refresh History choices. History has no delete action.

The Library view model owns Archive restore/delete/clear and capture index/file deletion. Its matching `LibraryActions` callbacks notify the app after those mutations; do not repeat the store mutation in the adapter. Other Library actions perform browser/system work. `openHistoryItem(url:)` must use `library.historyProfileID` to select the destination profile. `viewSpace(id:)` implements the restore toast's View button.

| Command | App adapter |
|---|---|
| `settings`, Cmd+, | `settingsPresenter.show()` |
| `search-settings` | `.show(pane: .general)` |
| `keyboard-shortcuts` | `.show(pane: .shortcuts)` |
| `air-traffic-control` | `.show(pane: .links)`; optional `settings.scrollTarget = "links-rules"` |
| `import-from-browser` | `.show(pane: .general)`, then `settings.showsImport = true` |
| `set-default-browser` | `settings.general.setDefault()` |
| `view-library`, Home, Cmd+Shift+L | `libraryPresenter.show()` |
| `view-downloads`, Cmd+Shift+J | `.show(section: .downloads)` |
| `view-archive` | `.show(section: .archive)` |
| `view-history`, Cmd+Y | `.show(section: .history)` |

The app's command router must preserve command-bar text capture rules. Settings does not install a second global key monitor. Its shortcut recorder is the first responder only while recording.

### Action ownership

- `openPreviewsSettings` is a notification/focus callback: General already presents the shared Previews sheet. The adapter must not present a second copy.
- `keyBindingsDidChange` rebuilds menus and re-registers/unregisters the global hotkey. Load overrides from `State/keybindings.json`. The Links hotkey switch notifies the same owner.
- The app reads General, Peek, numbering, and Advanced defaults at use, and observes changes where an immediate effect is required (Previews and Boosts). Defaults are registered once at startup.
- `setTabSleepMode` maps `automatic`→`SleepMode.balanced`, `never`→`.off`, and the other two labels to the matching model cases. The app reconciles this choice with the existing profile policies used by `SleepController`. No engine or second sleep implementation lives in Settings.
- `AdBlockStore` remains the configuration and download owner. Its engine events and Settings action callbacks must have one app adapter; do not send the same engine reload twice. The master switch is global. Lists and exclusions remain per profile.
- `clearBrowsingData(profileID:kinds:range:)` includes the time range. The app clears the selected profile only, including its History store. The overload without a range means All time.
- `deleteProfileData` wipes the engine data only after the UI has checked deletion guards. A failed wipe keeps the model profile. The model command removes it only after the action succeeds.
- `runImport(plan:)` owns the durable import transaction and honors the selected kinds. On failure it must keep the previous snapshot. `canImportPasswordsAndCookies` defaults to false. In that build the Passwords step says the feature is unavailable and Continue Without Passwords grants no consent. Only an adapter with an actual engine writer may opt in; its consent button then sets `secretsConsented`. Never decrypt passwords or cookies into Settings files. Unchecked, Continue Without Passwords, and Cancel paths grant none.
- `openURL(_:profileID:)` opens list information in an Open tab for the selected profile. Views do not send these links to the system default browser.
- `openMoreSettings`, profile subpages, export dialogs, help, icon selection, clipboard, and file actions are app/system adapters. The preview logs them and uses synthetic files; it does not drive Finder, the user's browser, or the desktop.

## Persistence

New profile fields decode with defaults and always encode at snapshot schema 1. A stored search-engine ID is preserved. Only a missing ID or a fresh profile defaults to Google. `SearchEngine` and `SuggestFormat` now live in `OpenModel`; `OpenSuggest` exports aliases to preserve source compatibility without a dependency cycle.

`ProfilesSettingsModel` remains the profile mutation/validation owner. Auto-archive changes stay pending until This Profile Only or All Profiles is chosen. Cancel leaves the snapshot unchanged. Custom-engine removal resets a selected custom default to Google in the same save. The Profiles pane presents the notice on its first appearance with suggestions ON and the acknowledgement unset. Before a first remote query, call `settingsPresenter.prepareForRemoteSuggestions(profileID:)`. This is a pure gate. It changes neither the selected Settings profile nor any window. False means the request must wait (or suggestions are OFF). When the user opens the notice, call `settingsPresenter.presentSearchSuggestionNotice(profileID:)`; only this explicit presentation selects the Profile. Acknowledgement persists to shared defaults. `profiles.allowsRemoteSuggestions` supplies the gate for `SuggestContext`. `SearchEngines.resolve(id:profile:)` includes custom engines and is used by Profiles, the real suggestions consumer, and Little Open. Editing an engine preserves its endpoint, format, and additional keywords.

Routing binds `LinksSettingsModel` directly. The pane lists rules; a sheet edits a local draft and commits only on Save Rule. Invalid edits stay in the sheet and block save. `commitLinks` and `saveLinkRule` return success, show a pane/sheet error on failure, and close the sheet only after a successful durable save. Links Test shows a plain one-line decision; the original trace stays under collapsed Details. An app picker stores a bundle ID without exposing an editable ID field. Space/profile assignment changes rebuild the routing model with current identities and retain drafts. Test uses the same evaluator and formatter as `openkit route`.

Shortcut edits run `ConflictChecker` before every write. Unexpected conflicts retain the draft and leave the saved file and action log unchanged. Revert returns to the saved store; Reset All requires confirmation. Only customizable, non-reserved commands accept new keys. Recording rejects typing keys, Space, Tab and Return unless ⌘, ⌃ or ⌥ is held. It keeps recording and shows a single instruction, including when a previous draft has a conflict. Bare function and arrow keys remain valid. The parsed key-binding store is cached by modification stamp, size and file identity; unchanged redraws do not parse JSON.

Library reads bounded 100-row pages from the profile archive stores and merges them newest first. It never loads the whole archive on open. Paging becomes available before favicon loading; a row-count task restarts the end sentinel after each page. The 225-row check covers the request during the first page’s favicon work and reaches the last row across two profiles. Delete and Clear use serial-queue transactions. Restore uses the model's Undo path. Restore reads without deleting, stages the model insertion, saves the snapshot, then removes the owning Archive row. A failed save removes the staged tab and publishes no Undo/action or Archive deletion. Delete groups IDs by their owning store; delete/clear report success or failure per profile, including partial completion. Captures use `State/captures.json` with Unix dates; deletion stages the file and atomically replaces the index, with rollback on a failed index write. Thumbnails load off the main actor. Decoded images are cached by capture UUID, Archive ItemID, and History URL row identity; redraws reuse the same NSImage. Missing Archive delete owners show “This archived tab is no longer available.”

## Verification

Build only in `Packages/OpenKit`:

```sh
nice -n 10 swift build -c release -j 6
.build/release/settings-preview --help
.build/release/settings-preview check
.build/release/settings-preview render --out /tmp/open-settings-render --scale both
.build/release/settings-preview dump-keys --root /tmp/open-settings-render/fixture
```

`check` uses a fresh synthetic root and an isolated defaults suite per flow. It reads the CFPreferences plist, snapshot JSON, keybindings JSON, SQLite stores, ad-block generation receipts, allowlist, and capture files/index back from disk. CFPreferences publication can lag `synchronize()`, so the receipt waits up to 30 seconds for the full domain to reach its plist. One concurrent render/check attempt exceeded the former 10-second budget; the disk assertion remains mandatory. `--only NAME` selects one flow. A failure stops the run and exits nonzero.

The import fixture contains two Spaces, three tabs, one skipped easel, and two count-only login rows in `User Data/Default/Login Data`. No real data or Keychain API is used. The ad-block flow starts a real loopback HTTP server and exercises `URLSession` and verified generation publication through the store's explicit debug-source option. It does not replace the store or downloader.

| Check | Result |
|---|---|
| Step 1 shell build and 1x/2x renders | PASS |
| Legacy schema-1 snapshot roundtrip; stored ID preserved, missing ID Google | PASS |
| `commands-demo` | PASS — 115 checks (the plan's 66 count predates the merged Profiles work) |
| General toggles and relaunch, default-browser failure | PASS |
| Profile search/custom engines, archive scope/cancel, downloads, clear-data, delete guards | PASS |
| Links rules/order/invalid drafts/deleted targets; real `openkit route` agreement; hotkey toggle | PASS |
| Shortcuts save/effective keys, conflict no-write, Revert, Reset All | PASS |
| Advanced toggle/sleep action, ad-block master/lists/allowlist/reset, icon action | PASS |
| Import counts, repeat import, consent gate/cancel/counts only, failed source preserves snapshot | PASS |
| Archive search/Space filter, restore/Undo/Redo, delete/clear confirmation and SQLite receipts | PASS |
| Downloads progress, Retry/Reveal IDs, missing-file guard | PASS |
| Captures thumbnail/Save As/delete file+index; profile History search/open | PASS |
| Four Library empty states: native hosted AX labels and valid PNGs | PASS |
| `settings-preview check` | PASS — 30 checks, 0 failed ([current receipt](first-run/checks.txt)); the original 28 Settings/Library flows are retained |
| Renders | 86 PNGs: all panes/sections at both scales, General/Profiles in both appearances, distinct long-pane details, every requested sheet, import Choose/Review/Passwords/Report and engine-ready Passwords copy, Library empty states, shortcut states, suggestion notice, engine editor, and invalid rule |
| `dump-keys` | PASS — synthetic-root guard; sorted persisted values |

`tools/verify-all.sh` now includes `settings-preview` checks, all renders, dimension validation, and `dump-keys`. The PR contains the final full-gate summary after merging `origin/main`.

No unit tests, desktop automation, engine build/sync, real import, or Keychain access ran. Real-app Cmd+,, menu delivery, browser effects, and engine download/capture operations remain the app-shell acceptance gate. These package/preview results do not claim that gate.

## Visual evidence

The layout follows [interaction-states §18](re/interaction-states.md#18-settings-window), captured Settings frames F0147–F0151 and A0495–A0507 in the session index. Those reference images were viewed only. No reference image, artwork, icon, font, sound, or binary asset was copied. All committed screenshots below use the code-built synthetic fixture. Colors and typography use `OpenDesign`, with system grouped-control defaults where there is no Settings token.

Every 1x and 2x pane and sheet was inspected locally. The final inventory has 86 PNGs. Switch bounds measure about 36×17 pt with `.mini`. Native controls render in their inactive appearance in the never-ordered offscreen window; a right-hand switch thumb means ON. Additional viewports expose the rest of the long panes. The Opus design review remains a lead-owned gate before merge.

| Pane | 1x | 2x |
|---|---|---|
| General | [PNG](settings/general@1x.png) | [PNG](settings/general@2x.png) |
| Profiles | [PNG](settings/profiles@1x.png) | [PNG](settings/profiles@2x.png) |
| Links | [PNG](settings/links@1x.png) | [PNG](settings/links@2x.png) |
| Shortcuts | [PNG](settings/shortcuts@1x.png) | [PNG](settings/shortcuts@2x.png) |
| Icon | [PNG](settings/app-icon@1x.png) | [PNG](settings/app-icon@2x.png) |
| Advanced | [PNG](settings/advanced@1x.png) | [PNG](settings/advanced@2x.png) |
| Archive | [PNG](settings/library-archive@1x.png) | [PNG](settings/library-archive@2x.png) |
| Downloads | [PNG](settings/library-downloads@1x.png) | [PNG](settings/library-downloads@2x.png) |
| Captures | [PNG](settings/library-captures@1x.png) | [PNG](settings/library-captures@2x.png) |
| Media | [PNG](settings/library-media@1x.png) | [PNG](settings/library-media@2x.png) |
| History | [PNG](settings/library-history@1x.png) | [PNG](settings/library-history@2x.png) |

General and Profiles also have `-light@1x`, `-light@2x`, `-dark@1x`, and `-dark@2x` files. Details: [routing rules](settings/links-rules@1x.png), [link test](settings/links-test@1x.png), [custom shortcuts](settings/shortcuts-custom@1x.png), [ad blocking](settings/advanced-adblock@1x.png), [sleep and data](settings/advanced-sleep-data@1x.png), each with a matching `@2x` file. The import [Choose](settings/import-choose@1x.png) and [Passwords](settings/import-consent@1x.png) sheets also have 1x/2x renders. The count-only Passwords render grants no consent. The Report render uses the real importer on the synthetic fixture. No Keychain API is called. The harness counts consent-bearing import plans at its action adapter; this proves the wizard gate only, not interception of arbitrary Keychain calls. [SHA-256 receipts](settings/sha256.txt) bind the committed PNGs.

## Plan adjustments

- The user requested one branch and one PR. The ordered steps are separate commits in that PR.
- First-party dependencies add `OpenDesign`, `OpenAdBlock`, and `OpenImport` to the plan's older dependency list, so the views use the merged tokens, store, catalog, and count readers. No third-party dependency was added.
- The merged ad-block contract has a global master in `adblock-settings.json`, and per-profile list/allowlist files in lowercase `Profiles/<UUID>/adblock`. There is no per-profile master and no second catalog. Both fixture profiles therefore show the shared master ON. The catalog's proprietary addition has no public source and stays unavailable, with its reason in help. Reset List Choices adds a small atomic reset API to the existing store/repository; failed list changes persist their error without replacing the active generation.
- `LinksSettingsModel` accepts an injected defaults suite (defaulting to `.standard` for existing callers). Its true fallbacks are unchanged. This prevents preview construction from reading real app preferences before hydration.
- The plan requires clearing Zoom In, but the registry had not marked it customizable. That single flag is enabled; its default keys and command ID do not change.
- `SearchEngine`'s Codable value moved down to `OpenModel`, with aliases in `OpenSuggest`. This is required to persist custom engines without a model→suggest→model cycle.
- Clear-data actions include a range overload. The action protocols also include the plan's missing reset-translate/help/URL/clipboard/Library and download/capture methods. These additions make those controls callable by the app.
- Current archive folder deletions are individual tab records. Library labels their child count from the payload when present, otherwise one tab, rather than inventing a new archive payload schema.
- Empty-state headlines use a small native text bridge. Never-ordered `NSHostingView` does not vend its SwiftUI AX nodes; the CLI instead reads the real native headline labels in the same hosted view tree.
- Step 8 and native engine acceptance stay with app-shell integration, as requested. This PR changes no `App/` file and does not request a design subagent.

### Additional review renders

All links have a matching 1x and 2x render. These use only the synthetic fixture.

| State | 1x | 2x |
|---|---|---|
| Previews | [PNG](settings/sheet-previews@1x.png) | [PNG](settings/sheet-previews@2x.png) |
| Search Engines | [PNG](settings/sheet-search-engines@1x.png) | [PNG](settings/sheet-search-engines@2x.png) |
| Clear Browsing Data | [PNG](settings/sheet-clear-data@1x.png) | [PNG](settings/sheet-clear-data@2x.png) |
| Ad Block Settings | [PNG](settings/sheet-adblock@1x.png) | [PNG](settings/sheet-adblock@2x.png) |
| Link Routing | [PNG](settings/sheet-link-rule@1x.png) | [PNG](settings/sheet-link-rule@2x.png) |
| Create Profile | [PNG](settings/sheet-profile-create@1x.png) | [PNG](settings/sheet-profile-create@2x.png) |
| Rename Profile | [PNG](settings/sheet-profile-rename@1x.png) | [PNG](settings/sheet-profile-rename@2x.png) |
| Auto-archive scope | [PNG](settings/sheet-archive-scope@1x.png) | [PNG](settings/sheet-archive-scope@2x.png) |
| Import Review | [PNG](settings/import-review@1x.png) | [PNG](settings/import-review@2x.png) |
| Import Report | [PNG](settings/import-report@1x.png) | [PNG](settings/import-report@2x.png) |
| Shortcut recording | [PNG](settings/shortcuts-recording@1x.png) | [PNG](settings/shortcuts-recording@2x.png) |
| Shortcut conflict | [PNG](settings/shortcuts-conflict@1x.png) | [PNG](settings/shortcuts-conflict@2x.png) |
| Go-to-Tab controls | [PNG](settings/shortcuts-tab-controls@1x.png) | [PNG](settings/shortcuts-tab-controls@2x.png) |
| Archive empty | [PNG](settings/library-archive-empty@1x.png) | [PNG](settings/library-archive-empty@2x.png) |
| Downloads empty | [PNG](settings/library-downloads-empty@1x.png) | [PNG](settings/library-downloads-empty@2x.png) |
| Captures empty | [PNG](settings/library-captures-empty@1x.png) | [PNG](settings/library-captures-empty@2x.png) |
| History empty | [PNG](settings/library-history-empty@1x.png) | [PNG](settings/library-history-empty@2x.png) |

## Review round 1

Source: lead-approved review decisions in this thread. Measurements use the existing private composite `a-settings.png`, frames A0499–A0507, at about 0.70 px per point (±1.5 pt). The image was viewed only. Color facts are from `assetutil` output in `.re/design/assetutil_Contents__Resources__ARC_PreferencesFeature.bundle__Contents__Resources__Assets.car.json`: `PreferencesButtonBackgroundColor` (light black 15%; dark RGB 0.878/0.875/0.878 at 7%) and `PreferencesLinkColor` (#458AFF). `SettingsTokens` owns Settings metrics, colors, and fonts. Light box colors use the native grouped-form convention (an Open choice).

Guesses retained explicitly: placing Ad Blocking in General was a guess, so Open keeps it in Advanced. Favorites/ninth-tab controls appear when a Go-to-Tab command is selected (guess); round 2 makes the conflict picker available for every customizable command. Download location merges the folder and prompt choice based on strings `arc.folder`, `arc.promptForDownload`, and `arc.other` (guess). The lead approved the three Advanced boxes, removal of the inline General Previews switch, one-column App Icon list, and routing sheet.

| Review item | Change | Proof |
|---|---|---|
| Design 1 | Compact centered custom tabs; neutral selection; 20 pt icons/11 pt labels; 28 pt title within an 89 pt band; transparent full-size title bar | All Settings PNGs; `SettingsTokens`, `SettingsWindow` |
| Design 2 | Dedicated tokens; 64 pt side inset, 19 pt top gap, 10 pt group gap, 8 pt boxes; exact row heights and inset dividers; mini switches | General/Profiles light and dark; Advanced; token source |
| Design 3 | Count-only and capability-gated engine copy; Passwords step only when requested; default/cancel actions and pluralization | Four import states; `import-counts` gate checks |
| Design 4 | Fixed 340 pt list and 200 pt custom panel; 380×35 segments; keycap recording, context actions, conditional tab controls | Shortcuts plus recording/conflict/tab-control renders; shortcut checks |
| Design 5 | Three header-less tile boxes; effective quote shortcut; compact search, ad-block and sleep rows; separate ad-block sheet and data menu | Advanced viewports and Ad Block Settings sheet |
| Design 6 | Two compact General boxes; banner only when not default; Previews and Profile Settings buttons on their rows; one Import row | General light/dark and Previews sheet |
| Design 7 | 205/340 columns, 11 pt gap; 27/31/31 pt list bands; download pop-up; 34 pt data rows, Credit Cards and blue arrows; unused button conditional | Profiles light/dark; create/rename/archive-scope/clear sheets |
| Design 8 | Intro/box/divider/Peek layout; rule list and sheet; unified destinations; app picker; warning quotes the draft pattern | Links, result, and Link Routing sheet |
| Design 9 | Native source-list table with keyboard selection; toolbar filters/search and section title; compact download rows; day-grouped History; simple capture cards; Archive hover actions | Five Library sections and four empty-state pairs |
| Design 10 | One box, six 80 pt icon rows; original art with named palettes, radio selection and current label | App Icon pair |
| Design 11 | Added every requested sheet/state and real Links result | Screenshot inventory and SHA-256 receipts |
| Design 12 | Profiles help copy, underlined help link, From path label | Profiles and import Choose |
| Code 1 | Stage restore, durable save, owner deletion; rollback insertion on save error | `archive-save-failure`, `library-archive` |
| Code 2 | One profile-aware resolver at lookup sites | `profile-search` exercises real `SuggestEngine` with a custom default |
| Code 3 | Open selected/new ad-block profiles, close deleted state; distinguish validation and store errors | `adblock-profile-lifecycle`, disk allowlist, and a [real store callback during external deletion](settings/callback-check.txt) |
| Code 4 | First-ON appearance notice and app presentation API | `suggestion-notice`, persisted acknowledgement and reopened model |
| Code 5 | Required injected shared SnapshotStore; no implicit writer | Initializer and caller compile |
| Code 6 | Removed force-unwrapped draft binding; sheet owns a captured draft | Link Routing sheet source |
| Code 7 | Delete only through owning stores; partial result per profile | `archive-owner-partial` uses a real SQLite failure trigger |
| Code 8 | Gate-only claim and counted consent-bearing action plans; 1-hour scope check; unseeded command priority check | `import-counts`, `profile-archive-scope`, `shortcuts-save` |
| Code 9 | Sidebar file read and JSON parse off main actor; model build remains on main actor | `ArcImporter.readSidebar`, wizard detached task, import check |
| Code 10 | Preserve suggest URL, format and other keywords on edit | `profile-search` disk roundtrip and real consumer |

## Review round 2

The lead chose **Icon** as the tab/window title (the stored pane ID and commands remain unchanged), allows the source-browser name inside the import wizard, and chose a plain Links Test result with the trace under collapsed Details. Default pane/Library renders now all use Dark; General and Profiles also have explicit Light/Dark pairs. The renderer applies the same appearance to NSApp, the host and window so native controls agree with SwiftUI. It yields during layout so SwiftUI tasks and the scroll destination settle before capture. Library toolbar pop-ups also use regular controls.

| Item | Change | Proof |
|---|---|---|
| Design 1 | 13 pt regular, 24 pt buttons with 12 pt side padding/radius 6; regular native pop-ups with actual fixed widths and standard arrows | General/Profiles and sheet PNGs; SettingsPopUp |
| Design 2 | General box 2 rows 43/47; Profiles box 1 rows 44/44/36 | General/Profiles pairs |
| Design 3 | Secondary headers with >=4.5:1 token contrast; Your Profiles semibold; 10 pt header inset | SettingsTokens and Profiles Light/Dark |
| Design 4 | Blue #007AFF selected segment and white text; 148/211 pt segments | Shortcuts pairs |
| Design 5 | Priority picker for every selected customizable command; numbering only for Go to Tab | Recording/custom/tab-control states |
| Design 6 | Rules intro/divider and match subtitles; Test a Link label; controls align at the trailing edge | Links rules/test and Link Routing sheet |
| Design 7 | Plain import summary; ordered Choose categories; skipped item line; Done default at bottom right | Import Report pair |
| Design 8 | Advanced/Shortcuts labels 13 pt; quote subtitle 11 pt and row 50 pt | Advanced and Shortcuts |
| Design 9 | One status per recording/conflict state | Shortcut state pairs |
| Design 10 | Both profile columns 420 pt; inset rounded selected row | Profiles pairs |
| Design 11 | Icon row offsets 27/63/130 pt | Icon pair |
| Design 12 | Aligned rule controls; contained built-in/custom engine list and one action row; hover-dependent Delay; named Profile and no destructive Return default; archive-scope question | Sheet pairs |
| Design 13 | Distinct bottom-aligned detail targets, consistent default appearance, four added state pairs | PNG inventory and hashes |
| Design 14 | Archive actions in header; fixed History separators; fixed empty icon/headline/message geometry; folder title first | Library populated/empty pairs |
| Design 15 | Banner 13 pt; grey 11 pt info.circle | General pairs |
| Design 16 | Shortcut label inset 25.5 pt; Use Automatic Appearance copy and matching search/sort | Shortcuts |
| Code 1 | Central recording admission keeps invalid keys active and never writes | shortcuts-recording-admission, real keybindings file and action log |
| Code 2 | Page state completes before favicon awaits; row-count sentinel task | archive-paging reaches all 225 real SQLite rows |
| Code 3 | Pure profile-aware query gate; separate explicit notice presentation | suggestion-notice checks VM and presenter without opening a window |
| Code 4 | Bool save result, visible error, durable save/rollback, sheet stays open on failure | links-save-failure (invalid sibling and simulated disk failure) |
| Code 5 | Opened-profile readiness, disabled controls, plain fault text | adblock-readiness and lifecycle checks |
| Code 6 | Passwords-not-imported copy only when secretsConsented is false | Import Report source and count-only flow |
| Code 7 | File-change parsed-store cache and retained decoded images | settings-caches checks load count, real file replacement and image identity |
| Code 8 | Unknown owners report the unavailable row | archive-paging final delete case |
| Code 9 | File/JSON parsing and count readers stay off main; graph assembly cost is explicit below | ImportWizard, ArcImporter and model actor boundaries |

Import graph assembly remains on the main actor. `ArcImporter.importAll(sidebar:)` walks the parsed item/Space/Profile graph and constructs actor-isolated OpenModel objects. Moving that work requires a separate Sendable intermediate model or a change to model isolation; this is not a cheap Settings-only move. The remaining walk is proportional to imported nodes and can pause the window for a very large sidebar. This PR claims off-main file/JSON parsing and count reads, not fully off-main model assembly or a large-import latency result.

Additional states: [suggestion notice](settings/sheet-suggestion-notice@1x.png), [engine-ready Passwords copy](settings/import-passwords-ready@1x.png), [search-engine edit form](settings/sheet-search-engine-edit@1x.png), [invalid rule](settings/sheet-link-rule-invalid@1x.png), each with a matching @2x PNG. The engine-ready copy render stops before consent or import. It never requests a consent token or accesses Keychain.


## Round-3 polish

| Item | Change | Proof |
|---|---|---|
| Pop-up trailing edges | Sleep and Little Open archive intervals use SettingsPopUp, with the native control itself sized to 150/155 pt and ending at x 610 | advanced-sleep-data and links-rules at 1x/2x |
| Empty rule hint | Empty or whitespace-only Host contains patterns show “Enter a site to match.” | sheet-link-rule-invalid at 1x/2x |
| Engine edit labels | Name, Keyword, and URL stay visible beside their fields | sheet-search-engine-edit at 1x/2x |

All affected PNGs were re-rendered and inspected at both scales. The release build and all 28 settings-preview checks pass. The PR contains the full verify-all summary for its head.

## Shared first-run probe

First-run Steps A/B replace the wizard's independent count reads with OpenImport.ArcProbe. Counts, file-presence states and cancellation now match first run. No BrowserModel is built for counts. Space mapping labels load only when Review opens, on a utility worker, and are excluded from probe results. Unknown/present-but-unreadable counts no longer show a made-up zero. The count and import busy states are separate so a first-run estimate cannot gate navigation. See [first-run.md](first-run.md) for the 30-flow receipt, WAL checks, timing and six screen pairs. Actual import graph construction is still the import action's responsibility; app-shell Steps C–F are pending.
