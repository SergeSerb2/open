# Local Boost Gallery

File ▸ Boost Gallery and the command-bar action open Library ▸ Boosts as a card
grid. Window ▸ View Boosts keeps the list. Both commands reuse
`AppSettingsActions.showLibrary(section:boostsPresentation:boostsProfileID:)`, one
`LibraryPresenter`, and one `LibraryViewModel`. Presentation is transient; it
does not add a preference or a second window.

Browser commands pass the invoking factory's Profile; Little Open passes its
session Profile. Only when the Library itself is key does its Profile picker
stay unchanged. Otherwise an explicit Boosts open uses the caller's
Profile, or the default regular Profile for an app-level command. A plain
`view-library` call changes neither Profile nor presentation. The optional
presentation parameter defaults to nil, which preserves the current layout.
Only `view-boosts` explicitly requests list; only Gallery requests gallery.
The Boosts section also has a small List/Gallery segmented control, including
in its empty state. The editor's All Boosts path keeps the selected layout and
uses the same Profile-preservation rule. The existing Profile picker and search
apply to both layouts. `BoostsProvider` is the sole `app.stores.boosts` owner.
Observation of its revision updates cards
after changes in the editor, import or Library.

Each card shows the name, host pattern with optional path prefix, the shared
`BoostGlyph.fill` in `Core.brandBlue`, an enable switch, Edit and Delete. The
context menu also keeps Rename. Card fill, border, fonts and radius use
`SettingsTokens`; the adaptive grid uses the Library Captures grid's spacing
and minimum width. The empty state uses the existing Library Boosts text.
No preview image is requested, cached or generated. Opening the Gallery loads
no site for a preview.

The list and grid share bindings, Edit, Rename, and Delete confirmation state.
Actions still enter `App/Boosts/BoostLibraryActions.swift`. Toggling a card uses
`AppBoosts.setBoostEnabled` → `refresh(profile:)` → `BoostEngineAdapter.refresh`.
There is no new delivery path. Toggle bindings and Edit callbacks capture the
Profile when the row/card action is formed. Rename/Delete confirmations retain
the original Profile and close if the Profile selection changes. Library Delete
has no Boost-specific Undo registration today; this change keeps that behavior.

Menu validation and the command-bar action gate refuse Gallery in private
windows and while `open.advanced.enableBoosts` is false. Validation reads the
preference through `BoostPreferences.globallyEnabledKey` without creating a
Boost owner or opening a Profile. Settings, the editor, runtime and existing
harnesses share that constant. With Settings/Library key, or with no browser
window key, this remains an app-level Library command, as `view-boosts` is. It
uses a regular Profile even if the only browser window is private; it never
uses the private context (F3, accepted parity by the Section 12 lead).
The existing command registry and action title are unchanged. The change is
outside the command bar's text, drawing and keystroke code, but the lead's required TANDEM
§4c/§4d timing qualification still applies.

## Build and off-screen validation, 2026-11-09

Fetched and merged `origin/main` at `3fb0645c`; Git reported already up to date.
The code head is `749da3a0`. The recorded main engine framework was verified as
SHA-256 `8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`.
Debug and Release used `s12-heavy.sh low` with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` in this existing checkout.
Elapsed times include wrapper queue time. Loads are 1/5/15-minute averages.

| Check | Result | Evidence / load start → end |
|---|---|---|
| App Debug | PASS, 479.4 s | `BUILD SUCCEEDED`; 8.36/9.04/7.25 → 8.55/10.23/8.65 |
| Shared keys, after Debug | PASS | 20 distinct literal keys in the `settings-state` response, no duplicates; each new key once. One full Boosts-enabled preference literal, in `BoostPreferences`. |
| App Release | PASS, 93.0 s | `BUILD SUCCEEDED`; 7.42/9.89/8.56 → 10.83/10.29/8.84 |
| Targeted verifier: release CLI build | PASS, 86 s | Zero warnings/errors; all package products, including settings and Site Control harnesses, compiled |
| `commands-demo` | PASS, 3 s | 326/326 checks; URL cleaning 30/30; archive migration and six folder-peek import variants passed |
| `suggest-check` | PASS, 22 s | 56/56; first-snapshot benchmark load 7.6/9.4/8.6; completion benchmark load 7.6/9.3/8.6 |
| `commands-dump` | PASS, 0 s | Missing/extra/different 0/0/0; 11 allowed-missing entries; no unexpected default/override conflicts |
| `commandbar-render` | PASS, 33 s | 151/151; CPU p95 2.92 ms < 8 ms; completion added p95 0.093 ms ≤ 0.3 ms; load 5.1/8.5/8.4 |

The targeted command was `tools/verify-all.sh --only
commands-demo,suggest-check,commands-dump,commandbar-render`, under the same
Section 12 wrapper and engine environment. All five selected rows passed in
145.5 s total, at load 9.95/10.12/8.80 → 5.13/8.45/8.35. The first command-bar
run passed every strict row; no timing rerun or paired qualification was needed.
These CLI checks do not exercise the App's new Gallery dispatch or hosted UI.

The native App builds are not warning-free: Debug has 69 primary source warning
lines (41 unique), Release 43 (22 unique). Source comparison found none on lines
changed by this branch. Both builds have zero error lines. Raw logs, load
receipts and diagnostic summaries are retained in `.re/s12-bg/gate-20261109/`
and `build/xcodebuild-{Debug,Release}.log`.

`settings-preview` and `sitecontrol-render` remain NOT RUN. Their verifier rows
call `tools/verification/check.py onscreen-suite`; settings previews require the
screen lock, and Site Control opens native EditorHarness windows/menus. They
cannot run under item 25. No full verifier or e2e suite ran in this phase.

## Acceptance after the screen hold

All real-App rows below are **NOT RUN**. Section 12 lead update item 27 lifted
the disk hold for builds and off-screen checks in existing checkouts. Item 25's
screen hold remains in force from 02:35 on 2026-11-09. No Open launch, e2e suite
or real-window capture is allowed until the lead sends "M5 clear". Build and
off-screen results do not prove Gallery runtime acceptance.

| Row | Real-App check on the M5 | State |
|---|---|---|
| BG1 menu | File ▸ Boost Gallery opens Boosts in gallery mode. Open View Boosts, then Gallery again; the Library window number stays the same and each route restores its own layout. | NOT RUN |
| BG1 command bar | Use Cmd+T, type Boost Gallery, select that action and press Return through the App event path. The same Library window shows the grid. | NOT RUN |
| F1 Profile ownership | Select Profile B in the Library with browser A behind it. With the Library key, File ▸ Boost Gallery keeps B. With browser A key and Library still open on B, Gallery selects A. Manage Boosts from a Profile A editor also selects A in that already-open Library. A closed Library opened from B uses B. Restore the old reset to record the Library-key case failing; restore the old visible-on-Boosts preservation branch to record the browser/editor caller case failing. | NOT RUN |
| F2 preserve layout | Open Gallery, select another Library section, return through the Boosts sidebar, then choose List in the layout control. `view-library` keeps both the selected Profile and layout; `view-boosts` explicitly chooses List. Also check `view-library` with History selected. With the old default `.list` parameter/implicit Profile reset restored, record the preservation case failing. | NOT RUN |
| F4 captured Profile | Exercise a row/card Toggle and Edit around a queued Profile change in the real App. The callback retains its rendered Profile and does not act on the newly selected Profile. | NOT RUN |
| F6 preference | Toggle Boosts in real Settings; verify the runtime, editor, Turn On action, menu and command-bar gates agree on the shared preference. | NOT RUN |
| BG2 cards | Create two nonempty Boosts through the editor on two fixture hosts in one Profile. Both cards show the correct names/sites. Test another Profile and search, then return. | NOT RUN |
| BG2 live toggle | Turn one card off: its open matching page loses the Boost and the other page keeps its Boost. Turn it on: the first page regains it. Check the stored enabled flags too. | NOT RUN |
| BG3 Edit | Press a card's Edit; the existing Library action opens the editor for that stored Boost and Profile. | NOT RUN |
| BG3 Delete | Press Delete and Cancel, then Delete and confirm. The card and live effect disappear; any editor for that Boost closes. No Boost-specific Library Undo exists. | NOT RUN |
| Empty | With no Boosts in the selected Profile, Gallery shows Nothing Boosted Yet! with the same message as the list. | NOT RUN |
| Disabled | Global Boosts off disables the menu and command-bar action. A private browser window disables them with the global switch on. Dispatch from that private window cannot open Gallery. The app-level regular Library remains allowed per F3. | NOT RUN |
| Negative proof | Temporarily restore only the old `boost-gallery` enablement refusal, rebuild, and record BG1 failing through the menu and command bar; restore the fix and rerun. | NOT RUN |
| Focus | Check Cmd+W, Cmd+T, Cmd+L, Esc and Return in the Library, command bar and confirmation sheet through `OEApplication.sendEvent`. | NOT RUN |

Use synthetic fixtures and the existing App automation runner. Do not use
computer use or launch Arc. `settings-state` reports `boostsPresentation` and
`boostsProfile` for the selected Library context. The grid, list, cards and
card controls have stable accessibility identifiers (`boosts.gallery`,
`boosts.list`, `boosts.layout`, `boosts.<id>.card`, `.enabled`, `.edit`, `.delete`).
Read the real hosted UI and page state as well as the presentation flag. For BG3 fixture
planning, the existing Library Edit action opens the stored host/path as HTTPS;
it does not retain a development fixture's HTTP port.

After "M5 clear", Section 16's DMG launch goes first; the S12 merge order is
#276, #278, #277, then Gallery. Follow the current Section 12 rules: run BG
acceptance and `boosteditor`, `incognito` and settings suites, then the full
`tools/verify-all.sh` on the final head. Required regressions include
`sitecontrol-render`, `boosts`, `settings-preview` and `commandbar-render`.
Merge overlapping main changes under rule 5a, rebuild Debug and Release against
main's recorded engine through `s12-heavy.sh`, and audit shared literal keys
before any App launch. Every App launch and screen-based harness needs the M5
screen lock, one suite per invocation. Use the quiet lock only for timing
receipts and record loads for strict and any required paired runs. Do not
regenerate baselines or relax thresholds. Keep raw misses separate from lead
qualifications.

The online/shared Gallery remains out of scope. Arc Gallery's shared-browsing
role remains a guess in the feature-gap audit; this page specifies only Open's
local behavior and makes no new reverse-engineering claim.
