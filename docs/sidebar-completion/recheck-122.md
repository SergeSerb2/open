# Sidebar #122 value re-check

Section 1 item 13, 2026-10-28. Base: `593a847e08955a0b11bbc56a521c6915089ef341`.
No shipping value changed: all five already agree with the measured evidence.
The app automation now exposes the installed spring's physical parameters and
settling duration. The sidebar e2e flow clicks the actual Space switcher through
`OEApplication.sendEvent` and checks that animation.

## Evidence and code trace

Arc evidence is the existing read-only capture analysis, not a new Arc run.
`docs/re/interaction-states.md` (IS) §20.1 records AX widths and held-drag states;
§20.12 records video edge positions and spring fits. `docs/re/sidebar-completion.md`
§7 and `docs/re/capture-session-2-results.md` §2.2 / §2.10 corroborate these values.

| Value | Arc evidence | PR #122 (`8b83c7e8`) | Code before this re-check | Code after | Real-app proof row |
|---|---|---|---|---|---|
| Width 164–500 pt | IS §20.1: S2 06/0025–0029 reaches 164; 0069–0072 reaches 500 | Temporary 218–500 floor until compact toolbar; #126 subsequently set 164 | `BrowserWindowState.minimumSidebarWidth = 164`; `WindowMetrics.maxSidebarWidth = 500`; live clamp in `BrowserWindowController.resizeSidebar` | Unchanged | `window.width_toolbar_floor`, `width_live_limits`, `width_visible_commit_once` |
| Drag-hide while pressed; restore pre-drag width | IS §20.1: 06/0035 hidden while held (pointer crossed between x85 and x65), 0053 remains hidden, 0066 Cmd+S restores 228 | Hide below x82 while held; hidden release keeps start width | `WindowMetrics.sidebarDragHidePoint = 82` (guess within measured band); hidden release keeps the model width | Unchanged | `window.width_hide_while_pressed`, `width_show_before_release`, `width_hidden_commit`, `width_cmd_s_restores_start` (364 pt fixture) |
| Double-click resets to 228 pt | IS §20.1: 06/0009 (from 364) and 0088 (from 500) | Added native edge double-click reset | `WindowMetrics.defaultSidebarWidth = 228`; `resetSidebarWidth` | Unchanged | `window.width_double_click_reset` (both start widths; one commit/save, no animation) |
| Cmd+S ≈ 0.10 s spring | IS §13.1 / §20.12: `21-motion.mov` hide 16.26/20.61/24.93 s, show 18.76/23.08/32.41 s; fitted R 0.09–0.105 s, damping 0.9–1.0 | Set R 0.10 s / damping 0.95 (old code was R 0.30, despite stale status text saying 0.22) | `Motion.sidebarToggle = SpringToken(response: 0.10, dampingFraction: 0.95)`; installed on sidebar and panel layers | Unchanged | `window.motion_sidebar_toggle`, `motion_end_frame_curves`, `motion_show_panel_right_edge`, `motion_reduce_motion` |
| Space spring response 0.20 s, critical damping | IS §20.12: video 35.05/43.63 s, remaining offsets sampled about every 25 ms, critical R 0.20 s fit RMS 0.003, visually settled ≈ 0.27 s | Set R 0.20 s / damping 1.0 (from R 0.30) | `Motion.spaceSwitch`; `SpacePagerView.slide` installs that spring on the page strip | Unchanged | `window.motion_space_switch`, `sidebar.space_switch_wrapper`, `sidebar.space_switch_click_spring` |

`gh pr view 122 --json body,mergeCommit,title,url` and
`git diff 8b83c7e8^1 8b83c7e8 -- Packages/OpenKit/Sources/OpenDesign/Motion.swift Packages/OpenKit/Sources/OpenDesign/Metrics.swift`
prove the historical changes. The width and gesture status rows were already
`done` after #126. This re-check closes the two stale `done (partial)` motion rows.

## Spring timing meaning

For an installed spring with mass m, stiffness k, and damping c, response is
`R = 2π / sqrt(k/m)` and damping fraction is `ζ = c / (2 sqrt(km))`.
The real-layer readback checks those quantities, zero initial velocity, key path,
start within one scheduled frame, and `duration == settlingDuration`.

The measured **0.20 s is response, not settling time or CA animation duration**.
The same Arc evidence says visual settling took about 0.27 s. For the installed
critical Space spring, the remaining displacement at 0.27 s is computed as
`228 × (1 + sqrt(k/m) × 0.27) × exp(-sqrt(k/m) × 0.27)` and must be at most 0.5 pt.
The scheduled duration keeps CA's own longer settling estimate; forcing it to
0.20 s would cut off the measured curve. No new wall-clock motion check was added.
The existing Cmd+S moving-edge snapshot is the one real-time observation for
that behavior and reports capture lateness and load.

Arc's unexplained ≈ 0.29 s show delay remains intentionally absent (app-shell
Q11). The exact drag-hide trigger remains a guess within the measured 65–85 pt
band. Lost mouse-up cancellation and per-crossing undo remain separate follow-ups
in `docs/followups.md`; these normal-flow receipts do not close those tasks.

## Verification

The release harness gate passed: build, `sidebar-render` (564/564), and
`features-render` (303/303). The real Debug app build passed. Commands:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only window
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only sidebar
```

The installed Cmd+S spring has m=1, k=3947.8417604357433,
c=119.38052083641213, R=0.10 s, ζ=0.95, and CA duration/settling estimate
0.13912826706998516 s. The installed Space spring has m=1,
k=986.9604401089358, c=62.83185307179586, R=0.20 s, ζ=1, and CA
duration/settling estimate 0.30000000000000004 s. These longer CA lifetimes do
not change the fitted response. The Space remainder at 0.27 s is 0.447747 pt.

Initial e2e runs caught two assertion errors in this re-check, both corrected:
group children need their relative `beginTime` checked while the parent owns
the absolute start, and the native-click flow must wait for queued mouse-up
before reading that switch's retained animation. Initial window: 73 PASS,
1 FAIL (`motion_sidebar_toggle`); initial sidebar: 18 PASS, 1 FAIL
(`space_switch_click_spring`). No shipping parameter failed those runs.

Final foreground results:

| Command | Result |
|---|---|
| `heavy.sh tools/verify-all.sh --only sidebar-render,features-render` | PASS: build + 564 sidebar + 303 features checks; 0 failed |
| `heavy.sh tools/build.sh` | PASS: real Debug `Open.app` |
| `lockf … engine_e2e.py --style chrome --only window` | PASS: 74 checks, 0 failed; 2 SKIP (Release timing budgets in Debug), 1 DEFERRED (card material, outside Part A) |
| `lockf … engine_e2e.py --style chrome --only sidebar` | PASS: 19 checks, 0 failed; 1 SKIP (durable profile storage belongs to the profiles suite) |

The final window command retried once after a fullscreen focus interruption;
the completed attempt passed. Sidebar had no interruption. Both report owned
process cleanup PASS. The shared brief's known comparison failures did not
reproduce in these completed runs. All value proof rows in the table above pass.
The native Space click slides 224.740 pt from its current presentation position,
selects/shows the expected cached page, and starts its installed spring 0.398 ms
after the request. This is scheduled metadata, not a wall-clock budget.

Local receipts (ignored): `.re/sidebar-recheck-122/{verify,build,window,sidebar}.log`,
`{window,sidebar}-results.json`, and the initial failed-run receipts beside them.
The verify runner's summary and detailed harness logs are under
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-150318.JSpSHM/`.
Generated `docs/engine-spike/*` results and screenshots are excluded from this
change.

Review checklist: real key/mouse events and native switcher action PASS (§3);
installed scheduled parameters, relative group start times, isolated suite
roots, and process cleanup PASS (§4); existing Reduce Motion rows PASS (§5);
status/follow-up notes agree with these receipts (§6). No unit tests, new
dependencies, value changes, or image-tolerance changes. The Debug build emits
warnings in existing engine/observer files outside this diff; it succeeds.
