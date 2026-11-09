# Sad Tab

`SadTabView` is created only when a renderer reports a nonzero crash state. Each
visible Split View pane uses its own view. Peek uses the same view inside its
page clip and closes through `PeekController.dismissTop`. A normal or split tab
closes through the window's normal sidebar close intent.

Reload calls the existing host's `reload`. It does not close or replace the host,
model tab, browser tab, or history recorder. Both Reload and a new navigation
remove the replacement when the engine clears its crash state. Crash transitions
refresh the view directly; no timer, polling, disk work, or launch-order change is
added to the app. Return operates the focused Sad Tab's Reload button. Both
buttons have explicit accessibility labels and identifiers.

The symbol `doc.badge.ellipsis` and the text "This page crashed" / "Something went
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
the existing `OPEN_E2E_NO_CRASH_PROBES=1` gate, which remains set on the M5 pending
the lead's ruling. The fixture uses only the existing SIGTERM URL, never a fault.
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

## Results

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
extension. The window close hook uses the existing sidebar close intent. No
engine, factory, or standalone Little Open implementation changed.
