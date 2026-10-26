# App shell acceptance

## Step A — window before engine

The original evidence below used **CDN CEF**. Current fork evidence is recorded
in the fork refresh table at the end of this document.

The real `OpenSidebar.SidebarView` draws from the snapshot before Chromium
starts. The theme field is prepared before display. After the window transaction
is flushed, a display-link callback must report a screen refresh later than
submission. Only then is `sidebarDrawn` marked. A three-second timeout continues
startup with `firstFrameConfirmed=false` and `firstFrameWaitTimedOut`, without
a `sidebarDrawn` mark. Off-screen, sleeping or locked displays must not prevent
launch. The temporary AppKit runloop
returns before `OEEngine.start`, so Chromium's observers first run in its own
message loop. The same sidebar remains attached after engine readiness.

Only selected restored tabs create web content. Launch URLs enter the model
before window composition. Background rows, including never-loaded pinned rows,
stay lazy. Close and unload act on the requested ID without selecting it; only
closing the selected row changes selection. Pinned entries remain in the model.
Today entries use `model.closeTab` and the archive sink.

### Review fixes

- Quit through `OEApplication.terminate` during the first-frame wait flushes the
  snapshot and exits 0 before engine startup. `OEEngine.terminate` null-guards
  its client. That guard is the lead-approved minimal Engine/ exception.
- Engine startup errors show an `NSAlert` with a plain message and a Quit button
  before exit 1. The real missing-library failure is exercised end to end.
- A forced missing-display-link launch waits for the real three-second timer,
  starts the engine, and shows the requested page. The first-frame wait is a
  timing aid; only a termination request prevents engine startup on that path.
- Address entry before readiness queues the URL in the model; direct page and
  context creation paths enforce readiness. Only the selected queued URL loads.
- All launch marks use `mach_continuous_time`. The kernel process-start ticks
  (`ri_proc_start_abstime`) are translated once to that clock. Renderer paint
  timing uses `performance.now()` / paint start time, mapped to host monotonic
  uptime at the CDP round-trip midpoint; the report includes its uncertainty.
  No wall-clock time participates in launch-duration calculations.

### Release timing after review

Command: `python3 tools/e2e/engine_e2e.py --config Release --only window`.
Build: `OPEN_AUTOMATION=1 nice -n 10 tools/build.sh Release`.
CEF 156.0.14, Chromium 156.0.8078.48, arm64, macOS 27.2, Apple M5 Pro.
Local visible HTML in a data URL removes external-network variance.
All values are ms from kernel process start, with the presented-frame mark.

| Case | Sidebar median (≤250) | First paint median (≤700) | Slowest first paint | Verdict |
|---|---:|---:|---:|---|
| Fresh profile (5 launches) | 224 | 461 | 1798 | PASS |
| Warm relaunch (5 launches) | 242 | 452 | 485 | PASS |

Fresh means a new data root/profile, with OS caches left intact. Warm means a
new process restoring the same profile and two-row snapshot. All 10 runs have a
kernel process-start timestamp. The paint-clock uncertainty is at most 0.11 ms
in the ten benchmark launches. The first fresh launch took 1,798 ms to first paint; it remains in
the five-sample median. The plan's intermediate `main` and `modelLoaded` targets
are still missed (113/135 ms and 115/137 ms respectively).

This was a loaded host (load averages 6.61/7.14/7.54), not a controlled idle
benchmark. An earlier review build measured 269/270 ms to the presented sidebar
and 482/476 ms to paint; its sidebar budget misses are retained in
[results-window-release-review-load.json](engine-spike/results-window-release-review-load.json).
The original pre-presentation, wall-clock numbers are superseded by this table;
[results-window-release-build-load.json](engine-spike/results-window-release-build-load.json)
is historical evidence only.

Current raw samples, host counters, and lifecycle results:
[results-window-release.json](engine-spike/results-window-step-a-cdn-release.json).
Open's own window: [window-startup.png](engine-spike/window-startup.png).

Merged `origin/main` through M4 visual finish `39fb0ed` before final builds,
startup/shell checks and repository verification.

### End-to-end checks

| Check | Result |
|---|---|
| Presented real sidebar before engine; zero pages and contexts | 5/5 PASS |
| Relaunch restores two rows and loads only the selected page | 5/5 PASS |
| Fresh/warm timing medians | 2/2 PASS |
| Never-loaded pinned close and unload: cumulative host count unchanged | PASS (1 → 1 → 1) |
| Pre-engine native quit: snapshot flushed, no engine start, exit 0 | PASS |
| Pre-engine address action: queued page shown, one host | PASS |
| Real missing CEF library: native Quit alert, exit 1 | PASS |
| Display link suppressed: timeout marked unconfirmed, engine and page start | PASS |
| Debug shell regression suite | 6/6 PASS |
| Debug and Release app builds | PASS; no Swift warnings |
| `tools/verify-all.sh` after merging origin/main | 14 PASS, no SKIP |

The Release window suite passes all 18 assertions. The forced timeout records
3,215 ms to the unconfirmed timeout, 3,216 ms to engine start, and 3,380 ms to
first paint; it creates one host and loads the requested page.

A test copy of Open.app has
its CEF library removed to exercise startup failure. The automation-only flags
call Open's real terminate and address actions, and its own alert button; they
are compiled out of ordinary Release builds.

### Comparison and scope

| Scope | Position | ΔE00 | Result |
|---|---|---|---|
| Step A startup screenshot | Not measured | Not measured | Step B owns static comparison |

Step A temporarily keeps the M1 engine wiring behind the real sidebar. Its URL
editor appears only on request; Step C replaces it. This follows the lead task's
real-sidebar requirement over the old “still the M1 window” plan table wording.
No unit tests, Arc launch, desktop input, other-app screenshots, copied Arc
assets, or committed personal browser data were used. Test apps close after each
run. Engine changes are limited to the approved client null guard.

## Step B — real window

In progress on top of Step A. Review fixes will be carried forward.


## Step A fork refresh — 2026-10-25

Merged `origin/main` through `c95be65` (including fork #46, Settings #51, and Settings polish #56).
Both Debug and Release builds passed with the default **fork** distribution.
The Release socket build uses `OPEN_AUTOMATION=1`. The embedded and vendor
Mach-O UUIDs match `4C4C44FE-5555-3144-A175-7398C5A1D4B4`; each new JSON records
that proof and the fork source stamp. No engine build or source sync was run.

| Suite / engine | Result | Evidence |
|---|---|---|
| Release window / fork | 16 functional PASS; 2 sidebar timing FAIL (16/18) | [JSON](engine-spike/results-window-step-a-fork-release.json) |
| Debug shell / fork | 6/6 PASS | [JSON](engine-spike/results-shell-step-a-fork-debug.json) |
| Release shell / fork | 6/6 PASS | [JSON](engine-spike/results-shell-step-a-fork-release.json) |

| Release median, 5 samples each / fork | Sidebar drawn (≤250 ms) | First paint (≤700 ms) |
|---|---:|---:|
| Cold, fresh profile | 252 — FAIL | 502 — PASS |
| Warm, existing profile | 252 — FAIL | 460 — PASS |

The sidebar misses by 2 ms are kept as failures. Host load was [11.0986328125, 9.64599609375, 11.220703125]
on 18 CPUs; these are not controlled idle measurements. The forced
no-display-link launch still waits for the real three-second timeout, reports
`firstFrameConfirmed=false`, starts the engine, and loads the requested page.
Quit during that wait still saves and exits without starting the engine.

Rule 10: full verification after merging `c95be65`; 15 PASS, no SKIP.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 19 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 12 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 48 |
| sidebar-render | PASS | 18 |
| commandbar-render | PASS | 14 |
| boosts | PASS | 2 |
