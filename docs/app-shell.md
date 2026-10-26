# App shell acceptance

## Step A — window before engine

The real `OpenSidebar.SidebarView` draws from the snapshot before Chromium
starts. The theme field is prepared before display. After the window transaction
is flushed, a display-link callback must report a screen refresh later than
submission. Only then is `sidebarDrawn` marked. The temporary AppKit runloop
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
| Fresh profile (5 launches) | 220 | 426 | 1837 | PASS |
| Warm relaunch (5 launches) | 232 | 423 | 474 | PASS |

Fresh means a new data root/profile, with OS caches left intact. Warm means a
new process restoring the same profile and two-row snapshot. All 10 runs have a
kernel process-start timestamp. The paint-clock uncertainty is at most 0.11 ms
in this run. The first fresh launch took 1,837 ms to first paint; it remains in
the five-sample median. The plan's intermediate `main` and `modelLoaded` targets
are still missed (122/132 ms and 123/134 ms respectively).

This was a loaded host (load averages 7.05/8.02/8.63), not a controlled idle
benchmark. An earlier review build measured 269/270 ms to the presented sidebar
and 482/476 ms to paint; its sidebar budget misses are retained in
[results-window-release-review-load.json](engine-spike/results-window-release-review-load.json).
The original pre-presentation, wall-clock numbers are superseded by this table;
[results-window-release-build-load.json](engine-spike/results-window-release-build-load.json)
is historical evidence only.

Current raw samples, host counters, and lifecycle results:
[results-window-release.json](engine-spike/results-window-release.json).
Open's own window: [window-startup.png](engine-spike/window-startup.png).

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
| Debug shell regression suite | 6/6 PASS |
| Debug and Release app builds | PASS; no Swift warnings |
| `tools/verify-all.sh` after merging origin/main | 14 PASS, no SKIP |

The Release window suite passes all 17 assertions. A test copy of Open.app has
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
