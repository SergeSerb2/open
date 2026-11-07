# Lazy Profiles and per-Profile extension UI

Section 10 receipt, 2026-11-06, America/Vancouver. This change keeps an
unvisited Profile unloaded through empty-Space focus, Settings shortcut
conflict reads, automation reads, and extension-window/prompt scans. A page
load or an explicit extension/site action can load it. An existing loaded
context can supply another window's Browser without creating a new context.
Loaded contexts remain resident across Space/window close under the existing
v1 policy; explicit Profile deletion keeps its separate teardown path.

The real-App harness is `tools/e2e/profiles_extensions.py`, included by
`extensions-ui`. It installs distinct signed CRX3 fixtures through Chromium's
installer and native consent sheets. Keys use `OEApplication.sendEvent`.
The harness resets and restores its defaults, uses disposable data roots,
and checks cleanup without a debugger or desktop input.

Measurements below use the App built after merging main `c5a7c4be` (ATC
#214, sidebar resize #210 and window material #211). Later integration
merged main `94c7561c` (New Space, menu-key fixes and Code mode), rebuilt
Debug and automation Release, and repeated the full gate and App suites.
The subsequent `7b3ab45f` merge changes docs only. Raw receipts are private in the primary checkout's
`.re/s10/profiles-lazy-ext/`; no user data or raw process inventories are
committed here.

## Runtime acceptance

| Flow | Real-App proof |
|---|---|
| Empty Work focus and reads | `P10_empty_focus_reads`: only Default; no Work mirror; Settings Shortcuts and extension/action/popup/command/permission/download reads remain non-creating. |
| Saved two-Profile launch | `P10_launch_unvisited_profile`: only Default after ten seconds idle. |
| Two windows | `P10_two_window_strips`, `P10_menu_follows_key_window`: only each Profile's signed fixture in its registry/strip; main Extensions menu follows the key window. |
| Work popup and management | `P10_popup_work_context`, `P10_manage_work_tab`: popup runs in Work; Work's `chrome://extensions` tab lists only Work's fixture. |
| Key routing | `P10_shortcuts_key_profile`: the same Command-Shift-U binding updates only the key Profile's storage ledger. |
| Window without a selected page | `P10_loaded_empty_space_binding`: Work action/pin IDs are attached; the existing no-page UI keeps the strip hidden. |
| Space swap | `P10_space_swap_reuses_context`: visible Work actions after selecting Work's page; context identifiers unchanged. |
| Little Open | `P10_little_work_actions`, `P10_manage_without_space`: Work actions, and Manage Extensions from the key no-Space Profile opens that Profile's Little Open page. |
| Explicit loading | `P10_explicit_interaction_load`: `extensions(create: true)` loads only the requested previously unloaded Profile. |
| Unloaded deletion | `P10_delete_unloaded_no_context`: typed native deletion never adds that Profile to the context census. |
| Quit | `P10_quit_no_orphans`: close Work windows and quit; after five seconds no owned process survives and no new `Open*.ips` exists. |

## Negative proofs

Both temporary source faults were rebuilt into Debug, exercised through the
real App, and removed before the positive builds. Owned-process cleanup
passed without forced termination in both runs.

| Fault | Observed refusal |
|---|---|
| Let empty focus create a request context (`loadContext: true`) | `P10_empty_focus_reads FAIL`; Work appears beside Default. Private `negative-lazy.json` and fault/build logs. |
| Feed Work's strip from Default's Browser actions | `P10_two_window_strips FAIL`, `P10_menu_follows_key_window FAIL`; Work's visible popup slot is absent. Private `negative-strip.json` and fault/build logs. |

Negative-run load averages (1/5/15 min): lazy fault 16.45/16.14/13.60;
wrong-Profile strip 6.50/10.66/11.77. These are functional fault receipts,
not performance comparisons.

A third harness fault raises immediately after the real Chromium install
consent becomes pending. It reports the deliberate `suite FAIL`, then
`owned_process_cleanup PASS`: no forced termination, no remaining owned
processes, and zero owned windows. The `finally` path clears the prompt and
restores defaults. The fault was removed. Load: 5.60/7.32/9.09. Private
receipt: `negative-prompt.json`.

An initial extra no-page row wrongly required visible slots. Its receipt
had the correct Work context/pin IDs, `hasPage: false`, and `visible: false`.
The corrected row checks that binding and hidden state. The separate
page-selection row still requires the visible Work strip. No product
behavior, timing tolerance, comparator or baseline changed for this correction.

## Measurement setup

M5 Pro, 18 logical CPUs, 48 GiB; macOS 27.2 (26B123). Main display is the
1x AW2726DM. Release App built with `OPEN_AUTOMATION=1` and
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Chromium
156.0.8078.48 / CEF 156.0.14. Vendor engine SHA-256:
`af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`;
engine code SHA-256:
`49529fd0e9fcab132dcd741c7276e9d1b7190a10cd62bf547673d40069771e66`.

The memory scope makes five fresh launches from the same saved two-Profile
snapshot, with Default focused and Work never visited. It omits global
unpacked-extension flags. Each launch waits ten seconds, samples `ps` RSS
for Open and its owned helpers, loads Work's first `about:blank`, waits ten
more seconds, and samples again. RSS sums can double-count shared pages;
these values describe this workload, not an isolated context allocation
or a memory budget. Medians of deltas are computed per launch.

| Median of five launches | Before Work | After first Work page | Paired delta |
|---|---:|---:|---:|
| Browser RSS (MiB) | 242.9 | 274.5 | 31.6 |
| Helper count | 3 | 5 | 2 |
| Summed helper RSS (MiB) | 320.3 | 613.2 | 293.8 |

| Launch | Browser RSS before → after (MiB) | Helpers before → after | Helper RSS before → after (MiB) | Load before (1/5/15) | Load after (1/5/15) |
|---|---:|---:|---:|---|---|
| 1 | 244.1 → 278.8 | 3 → 5 | 309.8 → 604.1 | 4.72/6.30/8.21 | 4.46/6.19/8.15 |
| 2 | 242.9 → 274.5 | 3 → 5 | 322.5 → 613.8 | 4.49/6.12/8.09 | 4.74/6.11/8.07 |
| 3 | 242.1 → 273.8 | 3 → 5 | 320.6 → 614.4 | 4.31/5.98/8.00 | 3.65/5.78/7.90 |
| 4 | 240.5 → 272.0 | 3 → 5 | 319.1 → 613.2 | 4.03/5.79/7.88 | 3.95/5.71/7.83 |
| 5 | 244.1 → 275.8 | 3 → 5 | 320.3 → 611.8 | 4.19/5.71/7.80 | 4.22/5.66/7.76 |

All five samples reported only Default before the page and exactly
Default plus Work afterward (`P10_context_memory PASS`). Private receipt:
`profiles-memory.json`. The paired median delta can differ from the
difference between the two marginal medians.

Reproduce after the automation Release build, honoring the priority flag
before taking the locks:

```sh
export OPEN_ENGINE_ROOT="$HOME/Developer/open-engine-s8-main"
OPEN_E2E_EXTENSIONS_UI_SCOPE=profiles-memory \
  /usr/bin/lockf -k /tmp/open-m5-quiet.lock \
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --config Release --style chrome \
  --only extensions-ui --extensions /Users/serge/.t3/projects/open/.re/ext/unpacked
```

## Space switching and idle work

The two Space switches use the existing native Space switcher and its
installed critically damped spring: response 0.20 s, start within one
frame, and at most 0.5 pt remaining travel at 0.30 s. Limits are unchanged.
RPC observation time is diagnostic; it does not measure physical display
latency, and the two switches have different travel distances.

| Switch | Scheduled start delay | Remaining at 300 ms | RPC observation | Load (1/5/15) | Result |
|---|---:|---:|---:|---|---|
| Same Profile, two-page travel | 0.166 ms | 0.384 pt | 17.148 ms | 9.24/9.13/10.39 | PASS |
| Default to Work, one-page travel | 0.172 ms | 0.192 pt | 22.808 ms | 9.24/9.13/10.39 | PASS |

After the fifth Release memory launch, Work stays loaded and a second
standard window opens. After 30 seconds settling, the existing
`process_cpu_window` sampler observes 60 seconds of OS CPU-time deltas,
using `proc_pid_rusage`, the Mach timebase and `ps` cross-checks. It does
not enable Chromium's task-manager observer. As in [idle-cpu.md](idle-cpu.md),
this is a receipt with no new absolute CPU threshold.

The same-session control uses unchanged merged main `c5a7c4be`, built
separately with the same Release automation flags and pinned engine. It
restores a fresh two-Profile snapshot, waits 10 s on Default, loads Work's
first blank page, waits 10 s, opens a second window, settles 30 s, and
uses the same 60 s sampler. Both workloads have two windows and two
renderers for one Work model tab, without unpacked extension fixtures.

| 60 s CPU (% of one core) | Browser | GPU | Renderers | Utility | Network | Total | Load start → end (1/5/15) |
|---|---:|---:|---:|---:|---:|---:|---|
| Branch | 1.0538 | 0.0080 | 0.0077 | 0.0048 | 0.2004 | 1.2748 | { 4.73 5.62 7.67 } → { 3.99 5.17 7.36 } |
| Unchanged main | 1.1878 | 0.0577 | 0.0325 | 0.0124 | 0.2854 | 1.5758 | { 55.12 35.63 21.51 } → { 55.75 39.12 23.76 } |

Both process sets were complete and stable (six processes), with no focus
interruption. In **both** samples, captures stayed 4→4, scheduled saves
16→16, tree changes 0→0, mirror syncs 1→1, dirty stayed false, and completed
sleep passes stayed 1→1. No periodic UI/storage/mirror/sleep work was
observed in these counters; the change adds no timer or recurring task.
The approximately-zero whole-App CPU goal remains open. The different
loads and single CPU windows do not establish a causal CPU reduction or
a new budget PASS. Both controls and the memory scope cleaned up without
forced termination or surviving owned windows/processes.

Private receipts: `profiles-memory.json`, `cpu-main.json` and control build
log. An initial control probe could not bind its overly long temporary
Unix-socket path (POSIX 63); the path was shortened and that attempt is
excluded from these measurements. No App change was needed.

## Validation and remaining evidence

Debug App, automation Release App and OpenKit Release builds passed through
`s10-heavy.sh`. The first full `verify-all.sh --with-arc-data` passed **24/24**,
with no FAIL or SKIP, after the `c5a7c4be` merge. Full-gate start load was
12.28/12.21/11.98; the command-bar CPU p95 was 5.10 ms against 8 ms and
completion added 0.124 ms against 0.3 ms. No timing retry was needed in that run.

After the `94c7561c` integration, both App configurations and the full
OpenKit Release build passed again (zero build warnings/errors). The full
gate recorded **22 PASS, 2 timing FAIL, no SKIP**. Its start load was
52.23/54.60/39.37. All functional rows passed. The Section 10 lead's 20:18
rule 4l makes timing misses under the sustained engine build non-blocking;
these remain measured misses, with the existing limits unchanged.

| Timing row | Measured | Existing limit | Load (1/5/15) |
|---|---:|---:|---|
| commandbar-render 151, cycle-based completion overhead | +0.410 ms (paired median +0.136 ms) | <=0.3 ms | 107.5/84.7/61.1 |
| sitecontrol-render, 2,000-line CSS code highlight | 2.157 ms (+0.157 ms late) | <2 ms | 74.22/77.60/63.09 |

Command-bar CPU p95 still passed at 7.69 ms against 8 ms; its CPU completion
delta was +0.266 ms and maximum layout passes stayed one. Code highlighting
processed at most 191 of 80,999 characters. The existing simple-editor
diagnostic INFO row measured CPU p95 17.230 ms against 12 ms. A queued quiet
command-bar rerun was canceled before any check started when rule 4l
arrived; the functional suite load hold was also removed before it launched
an App. No failed result was relabeled PASS.

The following initial App regressions use the `c5a7c4be` build:

| Required real-App suite | Config | PASS | Other rows | Cleanup |
|---|---|---:|---|---|
| extensions-ui | Debug | 71 | 1 BLOCKED | PASS |
| extensions | Debug | 8 | — | PASS |
| actions | Debug | 26 | — | PASS |
| extensions-e2 | Debug | 26 | — | PASS |
| profiles | Debug | 41 | — | PASS |
| littleopen | Debug | 39 | — | PASS |
| sidebar | Debug | 19 | 1 SKIP | PASS |
| window | Release | 82 | 2 FAIL | PASS |

`extensions-ui` includes all 16 P10 functional/motion rows. Release memory
scope adds four passing receipt rows. All final positive App/harness
receipts record a clean source tree for `App`, OpenKit sources and e2e.
The Profiles suite was repeated after the temporary dialog fault was
removed so its final receipt also has clean provenance.

`sidebar.durable_profile_storage` is the existing duplicate SKIP; the
passing `profiles.durable_second_profile` checks the cookie across relaunch.
The only two `window` FAIL rows in that initial receipt are the known main sidebar-startup
budget misses, accepted by TANDEM §4a:

| Launch median (five samples each) | Sidebar drawn | First contentful paint | Suite start load (1/5/15) |
|---|---:|---:|---|
| Fresh Profile | 360 ms | 579 ms | 7.73/5.88/7.39 |
| Existing Profile | 367 ms | 595 ms | 7.73/5.88/7.39 |

Both stay within the lead's unchanged-main bounds (sidebar <=400 ms, paint
<=700 ms). The original <=250 ms sidebar budget remains unmet. Metadata
dictionaries (`launch_runs`, capture sample and snapshot-file inventory)
are receipts, not additional failing checks.

The integration reruns use the rebuilt `94c7561c` App; the later main merge
is docs only:

| Suite | New result | Cleanup | Start load (1/5/15) |
|---|---|---|---|
| extensions-ui | 71 PASS / existing X13 BLOCKED, including all 16 P10 rows | PASS | 99.47/68.01/52.08 |
| extensions | 8 PASS | PASS | 76.52/77.55/66.61 |
| actions | 26 PASS | PASS | 78.62/76.88/69.11 |
| extensions-e2 | 26 PASS | PASS | 35.06/60.12/63.64 |
| profiles | INTERRUPTED after three key-focus attempts | PASS | 24.70/43.78/55.89 |
| littleopen / sidebar / window | DEFERRED after the foreground interruption | Not launched again | — |

The first integrated `X17_manage_singleton` attempt counted zero tabs
because its URL comparison omitted Chromium's committed trailing slash.
The App already handles both forms. The corrected harness requires the
same single selected tab after each of two commands and records both
states. Its passing receipt shows that same ID across
`chrome://extensions` to `chrome://extensions/`; the Work management lookup
accepts precisely those two root forms too. The first failed attempt and
its successful cleanup remain in `extensions-ui-integration-first.json`.

Profiles' new attempt reported `active=false`, `keyWindow=0`, with
`UserNotificationCenter` frontmost in all three attempts. Each owned App
exited without forced termination, surviving processes or surviving
windows. This is an external foreground interruption, not a product FAIL
or a passing receipt. Further screen launches are deferred under the
lead's general ruling for unavailable external evidence. The earlier
complete native receipts above remain separate.

Cmd+E's Site Control picker remains Section 12's `X13_picker BLOCKED`.
Global OS shortcut delivery, packed permission-increase updates and the
user-owned reference capture session remain separate follow-ups. The
original cold-launch budget is not closed by lazy loading.

Native 2x is deferred: the M1 is held by the lead and the M5 main display is
1x. Do not upscale 1x captures. On a native 2x display, from this branch,
after building Debug and OpenKit Release through `s10-heavy.sh`, run:

```sh
export OPEN_ENGINE_ROOT="$HOME/Developer/open-engine-s8-main"
# Honor /tmp/open-onscreen-priority before taking the screen lock.
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --config Debug --style chrome \
  --only extensions-ui --extensions /Users/serge/.t3/projects/open/.re/ext/unpacked
```

This reruns the native light/dark, strip, popup, menu, Little Open and
Profile flows and their existing captures. It does not replace the
user-owned reference captures listed in the Extensions UI plan.
