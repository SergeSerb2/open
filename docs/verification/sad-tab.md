# Sad Tab

`SadTabView` is created only for crashed, killed, or out-of-memory renderers.
An unresponsive renderer does not show it. Each
visible Split View pane uses its own view. Peek uses the same view inside its
page clip and closes through `PeekController.dismissTop`. A split pane closes
through its pane close path, which archives the pane and collapses the split.
A single tab uses the normal sidebar close intent; pinned and Favorite tabs
unload and stay in the sidebar.

Reload calls the existing host's `reload`. It does not close or replace the host,
model tab, browser tab, or history recorder. Both Reload and a new navigation
remove the replacement when the engine clears its crash state. Crash transitions
refresh the view directly; no timer, polling, disk work, or launch-order change is
added to the app. Return operates the focused Sad Tab's Reload button. Both
buttons have explicit accessibility labels and identifiers.

The SF Symbol `exclamationmark.circle` and the text "This page crashed" / "Something went
wrong while showing this page." are Open's own art and copy. Reload and Close Tab
are the requested Open actions. Their parity with Arc is a **guess** until a
capture is available. Arc evidence is limited to ST-1 in
`docs/re/features-advanced.md`; no Arc asset or code is copied.

Little Open uses `LittleOpenWebContent` / `LittleOpenSurfaceView`, rather than
`WebContentContainer`. It is outside this task's shared-container condition.

## Verification contract

Build with `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` through
`lockf -k /tmp/open-s11-heavy.lock` and `heavy.sh`. All Open launches take the
on-screen lock and set `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`.

The production view can be rendered without creating or killing a renderer:

```sh
Packages/OpenKit/.build/release/features-render render --scene sad-tab --appearance light --out .re/sad-tab/light.png
Packages/OpenKit/.build/release/features-render render --scene sad-tab --appearance dark --out .re/sad-tab/dark.png
```

`tools/e2e/sad_tab.py` runs inside `features`. It first proves that a healthy page
has no Sad Tab and refuses the replacement's actions. Every kill row is behind
the existing `OPEN_E2E_NO_CRASH_PROBES=1` gate. The lead ruled that kill rows run
only on the M1; the gate stays set on the M5. The fixture uses only the existing SIGTERM URL, never a fault.
No preferences are changed by the new rows.

| Row | Acceptance |
|---|---|
| `sad_tab_healthy_absent` | A healthy page has no replacement; its Sad Tab action is refused. |
| `sad_tab_healthy_split` | Both healthy panes remain usable without a replacement. |
| `sad_tab_healthy_peek` | A healthy Peek remains usable without a replacement. |
| `sad_tab_appears` | Killed state 2, model crash flag, visible replacement, AX labels, default Reload. |
| `sad_tab_reload_identity` | Reload restores the same URL, model ID, page identifier and `chromeTabId`; Back still works. |
| `sad_tab_close` | The real Close Tab button removes the normal tab. |
| `sad_tab_sibling_unaffected` | The sibling still runs JavaScript, stays healthy, and the App PID is unchanged. |
| `sad_tab_split` | An unfocused crashed pane alone gets the replacement and recovers. |
| `sad_tab_peek` | Peek alone gets the replacement, reloads in place, then closes through its normal path. |

## Initial results, before review fixes

M5, 2026-11-09. The lead imposed a **SCREEN HOLD on both machines at 02:43**
after another build crashed. This branch launched no Open instance or e2e suite.
No renderer termination, desktop input, debugger, or defaults write was used.
The temporary negative-proof build was compiled but never launched; its two
source mutations were restored before the final production build.

| Check | Result | Local receipt |
|---|---|---|
| Final production Debug build | PASS | `.re/sad-tab/build-debug-final.log` |
| Release `features-render` build | PASS | `.re/sad-tab/build-render-final.log` |
| Focused `verify-all --only features-render` | PASS: build plus 689 feature rows and 19 idle rows | `.re/sad-tab/verify-final.log` |
| Production Sad Tab light/dark renders at 2x | PASS: 1600 × 1080 PNGs; art, copy and buttons inspected | `.re/sad-tab/light.png`, `.re/sad-tab/dark.png` |
| Rendered AX labels / default role | PASS: Reload, Close Tab; Reload has the Return equivalent | `.re/sad-tab/render-light.log`, `.re/sad-tab/render-dark.log` |
| Swift syntax, Python AST and `git diff --check` | PASS | Source-only checks; no app launch |
| `sad_tab_healthy_absent`, `sad_tab_healthy_split`, `sad_tab_healthy_peek` | NOT RUN: SCREEN HOLD | `.re/sad-tab/held-results.json` |
| Real-App `shell`, `peek`, `split`, and `features` regressions | NOT RUN: SCREEN HOLD | `.re/sad-tab/held-results.json` |
| Healthy-page break-and-revert proof | NOT RUN: SCREEN HOLD | Mutation retained only in `.re/sad-tab/negative-source.diff`; production sources restored |

**DEFERRED**, with `OPEN_E2E_NO_CRASH_PROBES=1`: `crash_recovery`,
`sad_tab_appears`, `sad_tab_reload_identity`, `sad_tab_close`,
`sad_tab_sibling_unaffected`, `sad_tab_split`, and `sad_tab_peek`.
Their negative proofs are also deferred. The held-results file records the
hold; it is not an executed e2e receipt. Default Return routing, actual renderer
replacement, recovery/identity/history, and closing a crashed page still need
the permitted real-App run after the hold and the crash-probe gate are cleared.

The first focused verification stopped on an omitted explicit scene source in
`Package.swift`; that registration was fixed. Initial dark rendering exposed a
black symbol on the dark fill; an explicit SF Symbol palette fixed it, and both
final PNGs were rendered and inspected again. No baseline or threshold changed.

## Changed files

- `App/Automation/AutomationController.swift`, `App/Automation/AutomationSadTab.swift`.
- `Packages/OpenKit/Package.swift`.
- `Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift`, `PeekController.swift`, `PeekOverlayView.swift`, `SadTabView.swift`, `WebContentContainer.swift`.
- `Packages/OpenKit/Sources/features-render/RenderCLI.swift`, `SadTabScene.swift`, `main.swift`.
- `tools/e2e/engine_e2e.py`, `tools/e2e/sad_tab.py`.
- `docs/automation.md`, `docs/followups.md`, `docs/re/features-advanced.md`, `docs/status.md`, this report.

The App hook is limited to two automation dispatch cases plus the new automation
extension. The current close paths also share the crash-state guard in
`PageChromeCoordinator`. No standalone Little Open implementation changed.

## Fixture follow-up, 2026-11-09

The lead merged main at `9e1f9bdc` and built the Debug app on the M5. This
follow-up changes the fixture and this report; the production Swift code stays
at that built revision.

Split cleanup now separates panes through the enabled production split menu,
then closes the requested fixture tab. It does not select a child UUID outside
the split or depend on the focus gate under test. Peek
setup waits for a positive content ID from `peek-state`; page checks use that
engine ID instead of looking for a sidebar UUID. Split shortcut numbers come
from the current pane order. The healthy split row also exercises those keys.

M5 offscreen verification:

| Check | Result | Receipt |
|---|---|---|
| `heavy.sh tools/verify-all.sh --only features-render` (with the S11 outer lock) | PASS: release package build, zero warnings/errors; 713 feature checks and 19 idle checks | `.re/sad-tab/features-render-review-fix/summary.txt` |
| Sad Tab at 800/200 pt, light/dark, 2x | PASS: all four PNGs inspected; title, body, icon, and buttons fit | `.re/sad-tab/review-fix-renders/{light,dark}-{800,200}.png` |

The renders show native controls without an active app window; they do not
prove the active-window default-button appearance. The scene checks also
verify the Reload bezel accent property, AX order/labels, and fitted layout.

M5 real-App verification used the focused `features` harness in Alloy, matching
the lead's M1 mode. The launch held `/tmp/open-onscreen-e2e.lock`, set
`OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1` and `OPEN_E2E_NO_CRASH_PROBES=1`, and
ran `osascript -l JavaScript /tmp/dlg.js` before and after. Both dialog checks
returned zero. The harness confirmed owned-process cleanup and unchanged Peek
preferences through a read-only comparison; it made no defaults writes.

| Row | Result |
|---|---|
| `sad_tab_healthy_absent` | PASS |
| `sad_tab_healthy_split` | PASS, including pane shortcut order and split cleanup |
| `sad_tab_healthy_peek` | PASS, including real Peek content readiness and engine-ID lookup |

Receipt: `.re/sad-tab/healthy-m5.log` and
`.re/sad-tab/sad/results-features-alloy.json`. An earlier Chrome attempt passed
the split shortcut checks but failed cleanup after selecting a child UUID; the
final fixture removes that selection. Its receipt remains in
`.re/sad-tab/healthy-m5-attempt1.log`.

**DEFERRED on the M5:** `crash_recovery`, `sad_tab_appears`,
`sad_tab_reload_identity`, `sad_tab_close`, `sad_tab_sibling_unaffected`,
`sad_tab_split`, `sad_tab_peek`, `sad_tab_navigation`,
`sad_tab_background_select`, `sad_tab_split_close`,
`sad_tab_return_unfocused_pane`, `sad_tab_return_peek_over_crashed_pane`,
`sad_tab_split_focus`, `sad_tab_keypad_enter`, `sad_tab_shortcuts`,
`sad_tab_pinned_close`, `sad_tab_favorite_close`, and `sad_tab_private`.
The lead will rerun these on the M1. The prior break-and-revert proof and full
gate remain pending; this fixture follow-up ran the scoped checks above.
