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

Library Edit opens the stored HTTPS host/path. Its pending editor uses the
engine's committed URL because the commit callback can precede the URL-property
notification. This keeps the existing private-context, Profile, liveness and
HTTP(S) checks. A non-editable commit does not consume the pending request.
Cmd+L remains inert in the Library in both List and Gallery, as before. Cmd+T
opens the browser command bar, Escape dismisses it, and Cmd+W closes Library.
Browser Cmd+L still opens the location editor.

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

## Targeted validation, 2026-11-09

PR #279 remains a draft. M5 screen/disk holds ended under LEAD-UPDATE item 29.
No new main merge or final full gate is allowed until the lead sends “your
turn”, after #276, #278 and #277 merge. The last merged main is `3fb0645c`.
Main's engine is SHA-256
`8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`.
No engine files changed.

Every build uses outer `/usr/bin/lockf -k /tmp/s12-build.lock`, then
`/Users/serge/.t3/projects/open/.re/handoff/sections/s12/s12-heavy.sh high`,
with `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Debug and Release
run in sequence. Only this checkout's superseded build outputs are removed,
after logs are saved. App suites use the screen lock, one suite per invocation,
and wait outside every lock while the shared priority flag exists. Native
Settings and Site Control checks use the repository's screen worker without
a second nested screen lock.

Receipts, source diffs, logs and synthetic captures are retained in
`.re/s12-bg/resume-20261109-0830/` in the project root. Elapsed receipts include
lock queue time; loads are 1/5/15-minute averages. The earlier limited verifier
on product code `749da3a0` passed 5/5 selected rows: build, commands-demo
(326/326), suggest-check (56/56), commands-dump (0/0/0; same 11 allowed-missing),
and commandbar-render (151/151). That was not a full gate.

| Check | Current result | Evidence / load |
|---|---|---|
| Debug | PASS through native code `f5279ddb`; final restored build pending | 102.643 s; 25.52/17.04/13.17 → 13.73/15.77/13.13 |
| Release | PASS at `8fb592da`; rebuild after Edit fix pending | 150.421 s; 9.95/10.11/8.52 → 7.50/9.07/8.35 |
| Shared keys | PASS | 20 settings-state literal keys, no duplicates; one full enabled-key literal in OpenModel |
| commandbar-render strict | PASS 151/151 | CPU p95 5.04 ms; added completion 0.133 ms; load 4.2/6.4/7.3. No quiet or paired rerun required under §4c/§4d. |
| boosts browser harness | PASS 6/6 | 3.97/6.62/7.45 → 4.05/6.59/7.44 |
| settings-preview | PASS 47/47, 240 PNGs, dump-keys | Populated/empty Boosts at 1x/2x; expected Previews controls; stored Profile search-engine receipt; removed delay default absent |
| sitecontrol-render | PASS 1551/1551; 2 diagnostic INFO | Native windows/menus included. Code keystroke CPU p95 1.380 ms at 8.42/9.28/10.32; cold-open/editor timing diagnostics retained in raw log. |
| boosteditor | PASS 27/27 | Current Debug App; all owned cleanup passed; no focus interruptions |
| incognito | 29 PASS, later suite error in Alloy | chrome.developerPrivate unavailable at extension-management step; no-snapshot-change passed; Chrome-style run pending |
| commandbar + live Settings | PASS 77/77 | Existing commandbar suite invokes settings_live.run; owned cleanup passed |
| Full verify-all | NOT RUN | Lead's merge-order gate; wait for “your turn” |

## Real-App proof

`tools/e2e/engine_e2e.py --only boost-gallery --config Debug
--stop-on-app-death` drives Open's native File menu, real hosted Library controls,
editor controls, Settings, and pages. Keys use `route='app'` through
`OEApplication.sendEvent`. `AutomationBoostGallery.swift` only exposes bounded
UI traversal and actions; it constructs no Boost records and invokes no Library
action in place of a control. The queued Profile proof retains a rendered
control, changes the Profile binding and presses that control in the same turn.

Two synthetic HTTPS hosts use an ephemeral loopback TLS server, resolver mapping
and run-specific certificate pin. No system trust setting changes. Boosts are
created through the real editor. Per-run data/cache/Profile roots and TLS ports
are unique. Shared App defaults are saved, reset, and restored in nested finally
cleanup, including strict early aborts.

| Row | Proof | Current result |
|---|---|---|
| BG1 menu / command bar | Existing Library window reused; real grid/card AX controls; command-bar Return dispatch | PASS |
| BG2 cards / live toggle | Two names/sites; search and empty second Profile; off/on changes only the matching live page | PASS; native Zoom resize capture pending |
| BG3 Edit | Stored Boost and Profile open in editor against the real HTTPS fixture | PASS, ordinary and queued |
| BG3 Delete / empty | Escape Cancel is inert; confirmed deletion removes card and live effect; empty state and List control remain | PASS; Boost-specific Library Undo does not exist |
| F1 key Library | Library picker B stays on B when Gallery runs with Library key | PASS; old-reset negative pending |
| F1 browser/editor caller | Visible non-key Library B changes to caller A; closed Library from B selects B | PASS; old-visible-branch negatives pending |
| F2 layout | Sidebar round trip, in-window List/Gallery, plain Library preserves Profile/layout and History; View Boosts selects List | PASS; old-default/reset negative pending |
| F4 captured Profile | Queued real Toggle/Edit target their rendered Profile A after picker moves to B | PASS; old live-binding negatives pending |
| F6 preference | Real Settings off refuses menu/bar and removes live effect; Library Turn On restores effect; editor agrees | PASS |
| Private browser | Menu disabled; dispatch refused; command-bar action absent | PASS |
| Focus | Both List/Gallery: Cmd+W closes, Cmd+T opens bar, Escape dismisses, Cmd+L inert. Browser Cmd+L opens location editor; BG1 proves Return. | PASS at `a9aadeae` |
| Cleanup | Owned App processes/windows removed after completed runs | PASS, including forced early failure with the real Delete sheet open |

The initial focus assertion wrongly expected Cmd+L in Library to open a browser
bar. The diagnostic identified L. Source tracing and the real List/Gallery
parity row confirm the existing inert Library path; no product key policy
changed. The raw initial FAIL is retained. Thirteen Gallery rows passed at
`f5279ddb`, and the corrected focus row passed at `a9aadeae`.

Ordinary and queued Edit initially failed because the engine commit arrived
before `host.content.url`. The bounded diagnostic recorded `canEdit=false` at
commit. `f5279ddb` fixes this by passing the committed URL through existing
eligibility/presentation. Pre-fix FAILs and post-fix PASSes are retained.

## Deliberate regressions still to run

Each temporary mutation is built in this checkout, tested through the same real
App flow, recorded as raw FAIL, and restored. No mutant is committed.

| Mutation | Rows that must fail | State |
|---|---|---|
| Restore Gallery refusal in factory and App gates | BG1_menu, BG1_commandbar | PENDING |
| Restore key-Library Profile reset | F1_key_library | PENDING |
| Restore implicit/default list reset | F2_layout | PENDING |
| Restore live Profile reads in callbacks | F4_toggle_profile, F4_edit_profile | PENDING |
| Restore visible-on-Boosts preservation | F1_browser_profile, F1_editor_profile | PENDING |
| Force failure with actual Delete sheet open | BG3_delete_empty fails at the forced assertion; owned cleanup passes with zero windows/processes left | CONFIRMED |

After restoration: rebuild Debug and Release, audit shared keys, run the final
Gallery positive (including native Window ▸ Zoom resize), preserve rest/hover/
resized captures, and update these results. The final main merge, rebuild and
full verify-all wait for the lead's “your turn”. No baseline, comparator,
threshold or allowlist changes are permitted.

F3 app-level regular-Profile parity remains accepted by the lead. F5's shared
factory first-run/engine-ready policy remains a follow-up in `docs/followups.md`.
The lead approved F1/F2/F4/F6 source at `749da3a0`; the later automation and shared
Library Edit fix still need lead review.

The online/shared Gallery remains out of scope. Arc Gallery's shared-browsing
role remains a guess in the feature-gap audit; this page specifies only Open's
local behavior and makes no new reverse-engineering claim.
