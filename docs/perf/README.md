# Arc / Open performance evaluation

P1 uses the installed **Arc 1.172.2 (90755)** and an automation Release build
of Open at the recorded `origin/main` commit. The original unmodified Arc
1.170.0 (89123) reference was copied, version checked and deep-signature
verified before the first launch. It stays at
`~/Library/Caches/OpenRE/arc-reference/Arc-1.170.0-89123.app` for static
research. Never restore or launch it on the migrated M5 data.

The accepted performance baseline is `arc-reference-m5.json`. Phase 2 adds
33 rows to the original 30 Phase 1 rows without replacing them. Its
`arc_version`, `arc_build`, machine, macOS, display, executable hashes,
per-metric N, median, quartiles and extrema identify the cohort. It must not
be reused across displays. No Phase 2 or architecture-budget acceptance is
implied by Phase 1 scores.

Report 2 records 63 scored rows, 8.2/10 clamped and 8.8/10 raw. Each new
Phase 2 row has seven matched pairs. Eight main-delta rows and all 33 new
rows use the frozen `efeb350c` build; 22 remaining Phase 1 rows retain the
pinned `1593ece6` build. Each row keeps its actual commit and app hash.
The paired Phase 2 collector and frozen reference are complete. The harness
also exposes Open-only Phase 2 replay against hashed private paired starts.
Replay never launches Arc or reads its live data or defaults. The accepted
historical reports precede this replay CLI; their numerical values are unchanged.

## Prepare

Build only in the dedicated checkout. Do not build while holding screen or
quiet locks. The runner never builds:

```sh
OPEN_ENGINE_ROOT="$HOME/Developer/open-engine-s8-main" OPEN_AUTOMATION=1 \
  ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
mkdir -p .re/perf/bin
~/Library/Caches/OpenRE/scripts/heavy.sh \
  xcrun clang -O2 -fobjc-arc -Wno-deprecated-declarations tools/perf/probe.m \
  -o .re/perf/bin/probe -framework AppKit -framework CoreGraphics
~/Library/Caches/OpenRE/scripts/heavy.sh \
  xcrun clang -dynamiclib -O2 tools/perf/startup-fault.c \
  -o .re/perf/bin/startup-fault.dylib
```

Pristine benchmark checkouts stay outside the repository, under
`~/Library/Caches/OpenRE/perf/`. `tools/perf/benchmarks.py` records and checks
the pinned Speedometer 3.1, JetStream 2.2 and MotionMark 1.3 revisions.
No third-party benchmark source is vendored or edited. The loopback server
inserts `benchmark-reporter.js` at serve time; the original suite calculates
the result before the hook reports it. The same hook starts both browsers.
No mouse, keyboard or scripting Apple events are used.
Each benchmark entry URL includes the pair's private starting-state hash.
Entry documents and reporter scripts use no-store responses. Stage beacons
show reporter load, window load and suite start without changing suite code.
MotionMark keeps its official automatic frame-rate detector. This pinned
version maps to at most 144 fps, even on the approved 240 Hz display. Its
reported target/system rate is retained in the start-stage telemetry.

For Phase 2, also compile the app-scoped frame detector and bounded AX reader:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh \
  xcrun clang -O2 -fobjc-arc tools/perf/frames.m -o .re/perf/bin/frames \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreVideo -framework CoreGraphics
~/Library/Caches/OpenRE/scripts/heavy.sh \
  xcrun clang -O2 -fobjc-arc tools/perf/ax-perf.m -o .re/perf/bin/ax-perf \
  -framework AppKit -framework ApplicationServices
```

The Arc-only input helper is not needed by Open-only replay. Private inputs
from the accepted cohort must already exist; a public checkout contains no
user profiles and cannot reproduce S-real without them.

Before creating a new Arc cohort, record any authorized preference changes
and their original types/presence privately. P1 was explicitly authorized to
set the plain defaults `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`
and `openExternalLinksInLittleBrowserEnabled` to false. All three originals
were absent and must be restored by deleting those keys after P1. Do not
change the Arc bundle. Check the installed version before and after every
session. New sessions also check ArcCore's Info.plist version/build and binary
SHA-256. Installed ArcCore is Chromium 157.0.8103.51; Open uses Chromium
156.0.8078.48, a developer build without PGO/ThinLTO. The scorecard compares
products with different engines. The original P1 ArcCore audit was post hoc;
its existing bundle-version guards and receipts remain identified as such.
A changed build invalidates the unfinished cohort; restart on the
new installed build, keeping one Arc build per cohort.

```sh
python3 tools/perf/campaign.py paired --prepare --max-load 10 \
  --out .re/perf/DATE/setup.json
```

Setup launches Arc with the local startup page, quits it, then uses Open's
real Settings **Import from Arc** flow. Only a private read-only source view
is reordered when Arc serializes its `littleBrowser` container before the
global sidebar. No source file is changed. Live count checks require equal
Spaces, Favorites, pinned and Today counts. The extra fresh Open placeholder
Space is removed through its real socket menu/alert flow. Existing imported
profiles remain intact. Arc has zero externally enabled extensions in this
cohort; Open installs none. Counts and detailed import receipts stay private.

## Run and replay

A complete new cohort alternates Arc then Open for each task and round:

```sh
tools/perf/run.sh paired --state S-real --max-load 10 \
  --out .re/perf/DATE/paired.json
```

The tasks are `paint`, `core`, `bench-speedometer`, `bench-jetstream` and
`bench-motionmark`. `--tasks` can select a batch. Core and paint need seven
accepted matched pairs. Per LEAD 23:45, each web benchmark needs three;
extend to five if `(max-min)/median` of the first three accepted results
exceeds 5% in either browser. This target stays at five once triggered.
Disk needs one sample; the existing seven are retained. Core sessions take about thirteen
minutes per browser because the settles and CPU windows are real elapsed
time. Load-invalid attempts are saved and excluded; the runner allows up to
fourteen rounds. Optional warm/cold rows may have a smaller N and are then
excluded from the frozen reference. After a post-workload optional relaunch
timed out, later P1 workers omit that probe in both browsers so it cannot
delay mandatory rows. The original failed pair remains excluded. Reports
separate primary startup failures from optional relaunch failures.

The runner retains clean, live-app no-window timeouts as failed startup
intents and continues toward the declared matched-sample target. It prints the
failure numerator and all attempted sessions separately. Latency medians
are conditional on success; a failure is never converted into a finite
latency or silently dropped. Crashes, system dialogs, display/build changes
and cleanup failures still stop the run. If a job is interrupted, preserve
its receipt and use `--resume-from OLD.json --out NEW.json` with the same
build, display, tasks and private replay manifest. The new receipt records
the old receipt's hash. A failed Arc attempt's Open counterpart runs before
the next pair, preserving the alternating order.

Arc adds normal tabs for repeated external URLs and has no permitted Phase 1
close interface. Before each pair, Open therefore imports Arc's current
sidebar while Arc is quit, inside the following Arc screen-lock hold.
This prevents capture agent C from changing Arc in an import-to-launch gap.
The harness saves and hashes that exact private
Open starting snapshot. Both browsers then add the same visited workload
pages. Saved tab counts grow across pairs. The metric labels 1/10/30 mean
**newly visited synthetic pages plus the pair-matched saved sidebar**, not
fresh empty browsers or a guaranteed count of resident renderers. Normal
tab sleeping/discard policies remain enabled.

Once the accepted task receipts are assembled and frozen, repeat Open alone
against those exact private snapshots:

```sh
tools/perf/run.sh open --state S-real --out .re/perf/DATE/open.json && \
  tools/perf/score.py docs/perf/arc-reference-m5.json \
    .re/perf/DATE/open.json --out .re/perf/DATE/scorecard.json
```

Use `--max-load 10` if the declared ceiling for a rerun is 10; default is 8.
Private replay snapshots and their manifest live in `.re/perf/profiles/` in
this checkout. They are required for exact S-real replay and never enter
Git. The frozen file contains only count metadata and snapshot hashes.
A missing or changed replay snapshot must stop the run. To move machines or
lose these private inputs, record a new Arc cohort; do not silently replace
the workload.

Phase 2 uses a separate manifest, exported once from the accepted paired
receipt. Export verifies the receipt hash against the frozen reference,
hashes each private starting tree and binds the manifest hash to reference
metadata. This adds replay metadata without changing measured values:

```sh
tools/perf/run.sh open --phase 2 \
  --export-replay .re/perf/phase2-paired-5.json \
  --out .re/perf/phase2-replay/manifest.json
tools/perf/run.sh open --phase 2 --samples 1 --calibrate \
  --out .re/perf/replay-calibration.json
tools/perf/run.sh open --phase 2 --samples 7 \
  --out .re/perf/open-phase2.json
tools/perf/run.sh open --phase 2 --samples 5 \
  --metrics 'fps.sidebar_scroll.*' --app-cadence \
  --out .re/perf/sidebar-main-n5.json
```

Full replay requires N7. Named metric subsets accept a declared N1–N7.
Calibration is unscored. `--fail-after-metric ui.settings_open_ms --calibrate`
proves cleanup after a real Settings action. Unknown metric selectors,
changed manifests, changed snapshots and mismatched host/OS/display stop
before launch. Inputs and outputs stay under `.re/perf`; copied temporary
states use a short private socket path and are verified again after copying.
Each session records and checks its current app, engine and helper hashes.
Replay scorecards cover selected Phase 2 rows only; they do not carry old
Phase 1 values into a new overall. `--max-wait-seconds` bounds gate retries;
waiting inside the shared FIFO can exceed that budget.

`--app-cadence` adds informative, automation-only observations during the
sidebar trial: App display-link timestamps and native clip bounds-change
timestamps, capped at 4,096 samples or ten seconds. The observer restores
the clip's notification setting on stop. Display-link callbacks do not prove
drawing or scanout. Bounds changes show sidebar movement inside the App;
the independent 120 fps detector still scores visible changed-image pacing.
The probe adds work and is off unless explicitly requested.

`tools/perf/assemble.py --input RECEIPT:TASK,TASK ... --negative RECEIPT
--out .re/perf/DATE/accepted.json` combines selected accepted task receipts,
checks source/build/display identity, enforces required N, freezes the Arc
reference and writes the P1 lead handoff. `--interim` writes `P-report-0.md`
without freezing. Earlier failed preparation attempts stay saved, and do
not enter accepted inputs.

While the cohort runs, add `--progress` to publish the qualified rows in
`P-report-1.md` and `P-scorecard-1.json`. This labels incomplete categories
pending, retains each pending row's accepted N, and never freezes the
permanent Arc reference. The final assembly requires every mandatory row
to meet its declared target. The interim overall uses only the rows and
categories that already meet their targets. The sampling policy, first-three
web spreads and per-metric targets are stored in the reference JSON.

Arc S-empty is BLOCKED on the M5 because native-state isolation is not
established. Do not delete its data. Fresh Open runs are information only:

```sh
tools/perf/run.sh open --state S-empty --groups launch,disk --max-load 10 \
  --out .re/perf/DATE/open-empty.json
```

## Measurement rules

- Wait for load1 at or below the declared gate with **no lock held**. Each
  measured browser session takes its own FIFO ticket through `heavy.sh`,
  which takes all build slots exclusively, then takes the on-screen lock with
  `lockf -k` (at most 30 seconds). With `OPEN_HEAVY_HELD=1`, never take the
  quiet lock again. Explicitly set `OPEN_HEAVY_EXCLUSIVE=1` for measurement.
  Queue v3 has three M5 build slots; measurement still excludes all builds.
  Recheck load and existing browser processes after entry;
  a refused gate releases both slots before retrying. Release both after
  every session and re-queue. The pre-18:35 cohort used the authorized quiet
  try-lock; resume 4 uses the FIFO. Honor priority and hold files. Record
  load1/5/15 at entry, exit and long-workload checkpoints.
- Record AC/battery and Low Power Mode configuration, machine, macOS and the
  complete display metadata, including backing scale and ICC SHA-256.
  A display change stops the cohort. User decision 16:19 / LEAD 16:25 makes
  AW2726DM 2560×1440, 1×, 240 Hz the M5 reference for both phases. The older
  1920×1080, 60 Hz samples are appendix-only and never enter this reference.
- Leave the existing macOS permission dialog alone. Detect new system-owned
  windows from owner IDs and stop without interacting. No Screen Recording,
  Accessibility, AppleScript, debugger, root or Instruments is needed for
  Phase 1. Phase 2 uses the already approved Accessibility and Screen
  Recording permissions; the harness never requests them or drives a dialog.
- `probe.m` uses default LaunchServices configuration. Plain launch, without
  a URL, measures process birth to the first owned on-screen listed window.
  The corrected helper polls at a 0.1 ms target, independently of the
  LaunchServices callback, and retains actual gaps/frequency plus zero-size
  and off-screen window states. Accepted plain-launch samples require at
  least 250 Hz actual polling. This
  does not confirm sidebar frame presentation. The first-paint row uses the
  same external URL startup intent in both apps, as expressly approved by
  the lead. It briefly produces two Arc windows and one Open window.
  Plain Arc launch does not reload the selected local tab. Do not relabel
  this URL route as restored-tab paint.
- The page reports timeOrigin, FCP, LCP and loadEventEnd. Launch FCP maps its
  epoch time to the kernel process birth. The one-shot normal reporter
  disconnects its paint observer and stops after load. Cold/warm document
  pairs share one asset key and require observed network/cached resources.
  Documents themselves are served with no-store. Local fixture FCP/LCP are
  snapshots reported after load, not a full user-navigation LCP audit.
- Main workload/benchmark viewports match through Open's socket frame
  adjustment. Arc's restored frame is retained. Record each pair's actual
  viewport. Benchmark scores are specific to this display/viewport/machine.
- Memory sums `ri_phys_footprint` for the whole browser process tree at 60 s.
  Record process/renderer counts, browser share and Open saved/loaded counts.
  The slope is least-squares MiB per newly visited page across 1/10/30.
- CPU/wakeups use 120 s kernel-counter deltas. One core is 100%. Include live
  self and reaped-child counters so exited helpers are not silently lost.
  Stable-process detail stays available. Both browsers use the same
  `NSRunningApplication.hide/unhide/activate` helper for hidden windows.
- POWER is top's own rounded counter, summed over the initial process tree
  and averaged after its first frame. Incomplete tree coverage is excluded.
  It is not joules or a physical energy measurement. Swap is machine-wide
  information; other agents prevent browser-specific attribution.
- App disk size is allocated bytes (`du -sk`); main executable is logical
  bytes. Fresh Open profile size is measured after its workload, not before
  navigation. Disk sizes are not memory footprint.
- Quit through Open's socket or Arc's NSRunningApplication normal quit.
  Check owned process identities until zero survivors. Never stop unrelated
  jobs. No titles, personal URLs, frames or profiles enter committed files.

## Scores and absolute budgets

Arc is fixed at **7.0**. Open is
`clamp(7 + 3*log2(r), 0, 10)`, rounded to one decimal. Lower-is-better uses
`r=Arc/Open`; higher-is-better uses `r=Open/Arc`. CPU adds epsilon 0.1
percentage point, wakeups add 1/s, and top POWER adds 0.1 of its reported
unit, before division. Zero/noise-floor
rows need a declared floor or stay unscored. Overlapping p25–p75 intervals
keep their computed score visible with **≈**, but use ratio 1 (score 7.0)
in category totals. Per LEAD 01:35, bound each metric ratio to [0.5, 2.0]
before the category geometric mean. Rows retain raw ratios/scores and mark
bounded contributions. The clamped overall is the headline; the former raw
overall is retained for comparison. Categories use these bounded effective ratios;
overall uses the plan weights restricted to measured categories and says
**Phase 1 partial**. The scorer refuses different hardware, macOS or display.

Scores do not replace absolute budgets. The first-listed-window, external
URL FCP and local-static CPU fixtures differ from the architecture's
confirmed sidebar, restored-tab paint and Section 8 ten-page fixtures.
The scorecard shows numeric threshold distances as PASS/FAIL proxies, with
this non-equivalence explicit. Memory/disk/benchmarks have no numeric budget.

## Negative controls and remaining scope

`--mode negative` uses real Open pages with a 200 ms HTTP response delay, a
touched 100 MiB renderer allocation, a 5% CPU spinner and a 1 ms foreground
timer. `--mode negative-launch --groups launch` uses a separate 200 ms
startup constructor dylib, never linked into Open. No unit tests or mocks
are used. Fault samples never enter primary measurements. Each proof must
state its actual metric coverage; a counter-family proof alone does not
independently prove every derived row.

Normal Arc tabs refuse script self-close, so `mem.after_close_mib` is Phase 2.
Arc fresh-native state is a later M1 follow-up. Interaction, smoothness and
resume start only after the scored P1 handoff. LEAD 16:25 allows Phase 2 on
the approved AW2726DM. Arc system-input blocks must stay below about three
minutes, use AX targets, stop on system dialogs, and release the shared screen
lock between blocks. Open always uses its own automation socket.
Optional ten-minute-quit comparisons, POWER averaging or swap census must
not delay the first complete scored P1 handoff (LEAD 16:00).

## Current-main delta and Phase 2

LEAD 01:35 requires eight Open-only rows at N5 before Phase 2: static,
hidden and ten-tab idle CPU; top POWER; wakeups; one-tab memory; URL startup
paint; and plain launch to the first listed window. The delta replays the
private Phase 1 starting states. `delta_report.py` updates the main-delta
table in report 1 after each session. The pinned Phase 1 headline stays tied
to its original artifact.

```sh
python3 tools/perf/campaign.py open --main-delta --samples 5 --max-load 10 \
  --out .re/perf/main-delta-1.json
```

LEAD 05:00 permits a narrow two-artifact exception: the completed main delta
keeps its original app hash, while every scored Phase 2 row uses the corrected
automation adapter. CG finger phases 1/2/4 map explicitly to AppKit phases
1/4/8. Both app hashes, the correction hash and the unchanged engine hash are
recorded. No delta value is relabeled as the corrected artifact.
The only source patch adds an
automation-only native scroll route. It creates real CG pixel-wheel events,
adds the own-window destination and phase/momentum data, and calls
`NSApp.sendEvent`. It never invokes a scroll view or gesture handler directly
and never posts input to the system. The patch SHA-256 is part of provenance;
the hook is inert during delta measurements. Arc receives the same event
script through system CG events. Input-to-first-response latency includes
different routing costs, so scroll and swipe latency is informative only.

The common app-scoped ScreenCaptureKit helper requests native refresh with
`minimumFrameInterval=kCMTimeZero`. The measured stream still resolves
8.334 ms, about 120 frames/s, on the 240 Hz display. LEAD 03:00 authorizes
scoring at that observed detector rate for both browsers: **detector resolves
8.3 ms; drops shorter than that are not seen**. This is stated in the report
header and each smoothness row. It does not establish 240 Hz frame delivery.

Before Phase 2, run the bounded swipe proof under LEAD 03:40. It sends one
threshold-crossing horizontal script in each direction over the AX-derived
native pager, with three Spaces. If neither direction changes Space, record
the synthetic route as unmeasurable and use the approved keyboard Space
transition for both browsers. Do not score a synthetic no-op as good pacing
or as a product failure. The raw route receipt remains private.

```sh
OPEN_HEAVY_EXCLUSIVE=1 ~/Library/Caches/OpenRE/scripts/heavy.sh \
  /usr/bin/lockf -k -t 30 /tmp/open-onscreen-e2e.lock \
  python3 tools/perf/swipe_route.py --out .re/perf/phase2-swipe-route-corrected-2
python3 tools/perf/phase2.py --tasks explore --samples 1 --browser arc \
  --out .re/perf/phase2-explore-1.json
python3 tools/perf/phase2.py --samples 7 \
  --delta .re/perf/main-delta-2.json \
  --out .re/perf/phase2-paired-1.json
```

Each Phase 2 session takes its own exclusive FIFO ticket and screen lock.
Arc input blocks stay below three minutes; authorized absent defaults are
recorded, temporarily set, and restored inside each block. Open uses its own
socket. The worker checks display, Arc bundle/Core and Open app/engine hashes
before and after each session, and quits its owned process tree normally.
Foreign browser processes stop preflight without adoption or termination.

Resume an interrupted cohort with a new output path and its saved receipt:

```sh
python3 tools/perf/phase2.py --samples 7 \
  --tasks interaction,smoothness,resume \
  --resume-from .re/perf/PREVIOUS.json \
  --delta .re/perf/main-delta-2.json \
  --out .re/perf/NEXT.json
```

The resumed run preserves completed pairs, excluded attempts and source receipt
hashes. It checks the app, engine, ArcCore, helper binaries, display and Space
transition route before continuing. Interaction boundary version 2 timestamps
Open key/text input at the actual socket call, after preflight and window
discovery. Older Open interaction samples are excluded with their unmatched
Arc counterparts and repeated. Calibration never counts toward N7.

Tab switching uses Ctrl+Tab with modifier release in both browsers, with the
synthetic selected page checked before and after. Command-bar timing uses a
fixed 40-character sequence of one-character queries, clearing outside each
timed interval. Appending a long query eventually truncates result text and
cannot time a repaint for every character; that calibration is unscored.
Synthetic web geometry is read with temporary process-level
`AXManualAccessibility`, restored before scored input. It does not change
Arc defaults or `AXEnhancedUserInterface`. The original read status and
successful restoration are retained privately. Web queries allow only the
synthetic fixtures, internal debugging controls and discards page, capped at
depth 30, 3,000 nodes and 3 seconds.

Smoothness measures native sidebar scroll, long-article page scroll, command
bar open/close, sidebar collapse/expand, then the ruled Space transition.
Each scenario has late share (interval >1.5× detector median), p95, p99 and
longest stall. Page rAF median/p95 during scrolling is informative, unscored.
Discard resume requires a real discarded state, fresh page telemetry and a
known nonblank content signature. Unhide uses the same native helper in both
browsers. A visible target before discard selection cannot qualify as resume.
For unhide, the worker first checks the native hidden state and zero visible
owned windows. ScreenCaptureKit may retain the old image while the app is
hidden; only fresh capture timestamps after unhide count toward resume.

User approval at 06:14 and LEAD 06:20 allow Arc's internal debugging pages
only for discarding synthetic fixture tabs. The worker records the disabled
original at `chrome://chrome-urls`, confirms enable, then uses the fixture's
urgent-discard control at `chrome://discards`. It confirms disabled again
before each Arc quit, including error cleanup, and checks the stored disabled
state at the next Arc launch. A failed restoration stops Arc sessions. No
other internal page or flag may change. Open uses its own sleep/discard route
on the same fixture and must prove a discarded state before selection.

`phase2_report.py` requires every new row at seven matched pairs and all
eight delta rows at N5. It extends the Arc reference with new Phase 2 rows
only. Report 2 combines the eight current-main rows, new Phase 2 rows and
remaining pinned Phase 1 rows; each metric keeps its actual commit and hash.
