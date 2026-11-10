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

## Final validation, 2026-11-09

Main `d279ae85e0b1edad3cd060e5eb0ed083eb10b0f7` merged cleanly in `53803fd3`.
Validation code/docs head: `3a3e1730600e8592592e1c66d9d00aaba4f32456`. The final engine view is main
`627745e0`, framework SHA-256 `891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`. The built App's embedded code hash and
UUID match that distribution. Active fingerprint checks use the new SHA;
no product gate hard-codes the old fingerprints. No engine file changed here.

| Check | Result | Receipt / 1-, 5-, 15-minute load |
|---|---|---|
| Debug | PASS | 574.801 s; 70.24/36.56/21.31 → 45.93/44.34/32.04 |
| Shared keys | PASS | 20 distinct settings-state keys, zero duplicates; one full enabled-key literal in OpenModel |
| Release | PASS | 442.192 s; 45.93/44.34/32.04 → 20.21/31.41/30.69 |
| Gallery | PASS 14/14 | 118.064 s; 19.90/30.21/30.28 → 11.83/24.02/27.82; zero focus interruptions; owned cleanup PASS |
| Final full verify-all | PASS 25/25, zero FAIL/SKIP/INTERRUPTED | 1204.366 s; 9.77/22.36/27.09 → 21.35/34.94/30.75 |
| commandbar-render, strict | PASS 151/151 | CPU p95 5.18 ms; completion +0.149 ms; load 57.1/34.5/27.1; no quiet/paired rerun needed under §4c/§4d |

Debug → key audit → Release ran sequentially under `/tmp/s12-build.lock`, then
`s12-heavy.sh high`. The full gate ran through `s12-heavy.sh high` without the
build lock, per item 34. Every build/check used
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Only this checkout's
superseded build outputs were removed after preserving logs. The detached
build worker survived the system cancel; its Debug, key-audit and Release
receipts all exited 0. Its final engine manifest and completion footer were
observed after exit; no duplicate build ran.

Each App suite used the screen lock and respected the shared priority flag.
Native verifier checks used the repository screen worker. Native rest, hover
and resized Gallery captures were inspected again. Every Gallery row, including
BG1–BG3, both caller Profile cases, the key-Library case, layout, global-off,
private refusal and real keys passed on the new engine. No unit tests, computer
use, Arc launch, new worktree or engine-root edits.

The final gate table follows. `import-arc` requires `--with-arc-data` and is not
selected by the normal full gate; no personal Arc data was needed.

| Check | Result | Seconds |
|---|---|---|
| build | PASS | 112 |
| commands-demo | PASS | 6 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 87 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 27 |
| commands-dump | PASS | 0 |
| route | PASS | 16 |
| favicons | PASS | 11 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 5 |
| profiles | PASS | 4 |
| settings-preview | PASS | 343 |
| sidebar-render | PASS | 113 |
| sidebar-compare | PASS | 125 |
| commandbar-render | PASS | 35 |
| features-render | PASS | 91 |
| extensions-render | PASS | 7 |
| sitecontrol-render | PASS | 171 |
| onboarding-render | PASS | 29 |
| boosts | PASS | 4 |
| verify-secrets-fixture | PASS | 9 |


Full receipts, logs, engine manifests and synthetic Gallery captures are in
`.re/s12-bg/final-20261109-1905/` in the project root. Both App builds have zero
errors and zero warnings in the new Gallery files. Existing engine, package and
shared-automation warnings remain in the saved App build logs; the full gate's
OpenKit Release build is warning/error free. Elapsed receipts include lock wait.

## Earlier targeted validation

Earlier receipts remain in `.re/s12-bg/resume-20261109-0830/` and
`.re/s12-bg/gate-20261109/`. The functional proofs and eight deliberate source
regressions on engine `8e8a461c` stand under the lead's item 31 ruling. The
restored earlier builds and Gallery rerun used engine `34619927`. These are
historical receipts; the new-engine builds, Gallery and full gate are above.

| Check | Result | Evidence / load |
|---|---|---|
| Restored Debug | PASS at `61ace5ec`, engine 34619927 | 90.947 s; 9.26/9.96/12.31 → 11.94/11.19/12.59 |
| Restored Release | PASS at `61ace5ec`, engine 34619927 | 236.585 s; 11.94/11.19/12.59 → 12.19/12.05/12.63 |
| Shared keys | PASS | 20 settings-state literal keys, no duplicates; one full enabled-key literal in OpenModel |
| Gallery | PASS 14/14, engine 34619927 | 15.96/13.16/12.89 → 22.38/16.07/14.04; zero focus interruptions; cleanup PASS |
| Deliberate source regressions | CONFIRMED 8/8, engine 8e8a461c | Each raw FAIL at the intended assertion, cleanup PASS; restored source then passes the complete Gallery run |
| commandbar-render strict | PASS 151/151 | CPU p95 5.04 ms; added completion p95 0.133 ms; load 4.2/6.4/7.3. No quiet/paired rerun required under §4c/§4d. |
| boosts browser harness | PASS 6/6 | 3.97/6.62/7.45 → 4.05/6.59/7.44 |
| settings-preview | PASS 47/47, 240 PNGs, dump-keys | Populated/empty Boosts 1x/2x; Previews controls, stored Profile receipt and removed delay default absent |
| sitecontrol-render | PASS 1551/1551; 2 diagnostic INFO | Code keystroke CPU p95 1.380 ms at 8.42/9.28/10.32. Cold-open diagnostic 8.817 ms vs 8 ms at load1 11.55 retained; instruction/functional gates pass. |
| boosteditor | PASS 27/27 | Run end 11.25/9.48/9.20; cleanup PASS, no focus interruption |
| commandbar + live Settings | PASS 77/77, including 16 settings_ rows | Run end 13.28/10.20/9.47; cleanup PASS |
| incognito, Chrome style | PASS 31; native 2x capture DEFERRED on 1x display | Suite load 23.72/13.74/10.79; cleanup PASS, no focus interruption |
| Full verify-all | NOT RUN in this earlier phase | Former merge-order hold; final gate above is complete |

The earlier limited verifier at product code `749da3a0` passed 5/5 selected rows:
build, commands-demo (326/326), suggest-check (56/56), commands-dump (0/0/0;
same 11 allowed-missing), and commandbar-render (151/151). It was not a full gate.
These earlier builds have no errors and no warning in the new Gallery files. Existing
engine nullability/incomplete-implementation and package/shared-automation
warnings remain; source-warning audits and full build logs are retained.

## Real-App proof

`tools/e2e/engine_e2e.py --only boost-gallery --config Debug
--engine-sha256 891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67
--stop-on-app-death` drives native menus, real hosted Library/Settings controls,
editor controls and pages. Keys use `route='app'` through
`OEApplication.sendEvent`. The bounded `AutomationBoostGallery.swift` traversal
constructs no Boost records and invokes no Library action in place of a control.
The queued Profile proof retains a rendered control, changes the picker binding
and presses the same control in one turn.

Two synthetic HTTPS hosts use an ephemeral loopback TLS server, resolver mapping
and run-specific certificate pin. No system trust setting changes. Boosts are
created through the real editor. Each run has unique data/cache/Profile roots
and a TLS port. Shared App defaults are saved, reset and restored in nested
finally cleanup, including strict early aborts.

| Row | Proof | Result |
|---|---|---|
| BG1 menu / command bar | One Library window reused; grid/card controls; real command-bar Return | PASS |
| BG2 cards / live toggle | Two names/sites; search and empty Profile; off/on affects only the matching page | PASS, including native Window ▸ Zoom resize and restore |
| BG3 Edit | Stored Boost and Profile open against the real HTTPS fixture | PASS, ordinary and queued |
| BG3 Delete / empty | Escape Cancel inert; confirmed deletion removes card and live effect; empty List control remains | PASS; Library has no Boost-specific Undo |
| F1 key Library | Picker B stays B when Gallery runs with Library key | PASS; old reset fails |
| F1 browser/editor caller | Visible non-key Library B changes to caller A; closed Library from B selects B | PASS; old visible-preservation branch fails for browser and editor |
| F2 layout | Sidebar round trip, List/Gallery, plain Library preserves Profile/layout/History; View Boosts selects List | PASS; old default/reset fails |
| F4 captured Profile | Retained Toggle/Edit controls act on rendered A after picker moves to B | PASS; both old live callbacks fail |
| F6 preference | Settings off refuses menu/bar and removes live effect; Turn On restores; editor agrees | PASS |
| Private browser | Menu disabled, dispatch refused, command-bar action absent | PASS |
| Focus | Both layouts: Cmd+L inert, Cmd+T opens bar, Escape dismisses, Cmd+W closes; browser Cmd+L and BG1 Return | PASS |
| Cleanup | All completed App runs remove owned processes/windows | PASS, including forced early failure with Delete sheet open |

Native rest, hover and resized captures were inspected for the two cards and
layout controls. This local-only surface has no claimed Arc Gallery pixel
baseline. Settings populated/empty renders also cover 1x/2x. Native incognito
2x capture remains a display follow-up; no M1 screen run was attempted.

## Deliberate regressions

Each temporary mutation was built in this checkout and tested through the same
App flow. Every row below produced a raw FAIL and passed owned cleanup. All
mutations were restored; no mutant is committed. `negative-summary.json` keeps
each failure's exact load and engine fingerprint.

| Mutation | Rows that fail | Result |
|---|---|---|
| Restore Gallery refusal in factory and App gates | BG1_menu, BG1_commandbar | CONFIRMED 2/2 |
| Restore key-Library Profile reset | F1_key_library | CONFIRMED |
| Restore implicit/default list reset | F2_layout | CONFIRMED |
| Restore live Profile callback reads | F4_toggle_profile, F4_edit_profile | CONFIRMED 2/2 |
| Restore visible-on-Boosts preservation | F1_browser_profile, F1_editor_profile | CONFIRMED 2/2 |
| Force failure with actual Delete sheet open | BG3_delete_empty | Intended assertion fails; cleanup PASS, zero owned windows/processes |

Ordinary and queued Edit first failed because the engine commit arrived before
`host.content.url`. The bounded diagnostic recorded `canEdit=false` at commit.
`f5279ddb` fixes this by passing the committed URL through existing eligibility
and presentation. Pre-fix FAILs and post-fix PASSes are retained.

The first combined final run passed 13 rows including resize, then the focus
helper incorrectly required a non-empty grid after Delete removed both cards.
The helper now requires the actual layout control for that focus setup; other
card/grid assertions are unchanged. The raw failure and cleanup PASS remain.
The corrected complete suite passed all 14 rows; the new-engine final run also passes 14/14.

The initial focus check wrongly expected Library Cmd+L to open a browser bar.
Source tracing and real List/Gallery parity prove the existing inert path;
browser Cmd+L still works. No product key policy changed. The first incognito
run used Alloy: 29 rows passed, then extension management lacked
`chrome.developerPrivate`. The documented Chrome-style run passed 31. Its worker
survived the system cancel; the parent exit code was lost, so the completed
native result, cleanup and exited worker were recorded without a duplicate.
The first menu negative was recovered the same way. Raw initial errors and
observation receipts remain available.

F3's app-level regular-Profile parity is accepted. F5's shared factory readiness
policy remains in `docs/followups.md`. The lead approved F1/F2/F4/F6 source at
`749da3a0`, then the automation and shared Library Edit fix at `6986ccda`
(12:35). The pending Edit after a non-editable navigation is a non-blocking
follow-up in `docs/followups.md`. The final merged-head gate is complete.

Sharing, online browsing/install and preview generation remain out of scope.
Arc Gallery's shared-browsing role remains a guess in the feature-gap audit;
this page makes no new reverse-engineering claim.
