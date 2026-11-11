# Library validation

Status: STOP after the LEAD 12:50 lean checks. All three pairs are valid,
but ready-open median 10.882 ms exceeds its 8 ms budget. Warm section and search
pass. The earlier scroll and idle rulings remain recorded below. No further
rerun, main merge, full gate or PR was started after this required failure.

The fourth-pass native source is `c9a2e305`. Harness fix `62bc6e89` restores the
fixture selection after the uncached Archive probe. Main merge `48c378c9`
includes `ccca06d0` and the `icc-header-v1` display-key fix. That merge changes
no App, engine or Library runtime code. Existing reference images are retained.

The five-pair Release executable SHA-256 is
`7217a9f5eafdb9979f9277f291ce934090d5024573444173e7b73cb4b8c535f4`.
The freshly linked OpenEngine bridge is
`f4bce022c1473542e1220260bcec2a2d2c9eab83cf5bffe502feca79b4155a6d`;
CEF remains
`1a22c4aa1b49d7199915766efc2e7665262ec36993ab0b96e4e4200375f762c0`.
M5/M1 hashes, the candidate signature and all 3,014 transported source files
were verified before timing. There was no native change during qualification.

Every pair held all configured M1 heavy slots and the screen lock. Two load1
readings ten seconds apart were at or below 3.5. Other process CPU and later
load remain information, without a rejection threshold. The fixture has
1,000 downloads, 5,000 history entries and 2,000 archived tabs. All five
baseline and candidate launches quit normally, with no owned process left.

| Pair | Pre-pair load1 readings | Candidate load before / end (INFO) |
|---|---|---|
| 1 | 2.940 / 2.635 | 3.064 / 1.859 |
| 2 | 1.859 / 1.954 | 1.954 / 1.449 |
| 3 | 1.449 / 1.306 | 2.002 / 1.779 |
| 4 | 1.779 / 1.899 | 1.899 / 1.256 |
| 5 | 1.256 / 1.296 | 1.433 / 1.997 |

Budget clocks end at the App commit containing the complete first screen or
filtered result. They do not wait for the open animation to finish.

| Metric | Median ms | Maximum ms | Median limit / sample ceiling ms | Result |
|---|---:|---:|---:|---|
| Prebuilt first commit | 5.560 | 8.936 | 8 / 12 | PASS |
| Complete first screen | 5.560 | 8.936 | 100 / 150 | PASS |
| Cold-section header/container | 9.900 | 11.469 | every sample ≤16 | PASS |
| Cold section, provider data warm | 30.285 | 33.987 | 50 / 75 | PASS |
| Warm section | 4.574 | 5.335 | 8.3 / 12.45 | PASS |
| One-key search | 7.495 | 9.456 | 16 / 24 | PASS |
| Early cold open, one launch | 26.038 | 26.038 | 50 / 75 | PASS |
| Uncached Archive header, one launch | 6.568 | 6.568 | every sample ≤16 | PASS |
| Uncached Archive rows, one launch | 30.718 | 30.718 | every sample ≤150 | PASS |

The uncached Archive check is the first provider read in a fresh process,
before idle warming. The OS file cache is uncontrolled; no cache purge was
used. First-visit hosts in the five pairs use provider pages explicitly warmed
by the input-cancelled idle scheduler. Each sample records `providerWarm=1`.

Configure p95 median 0.403 ms, maximum configure 1.158 ms and cold-screen apply
median 9.148 ms remain diagnostic INFO. They are not budgets. All fifteen warm
switches configured and reloaded zero rows. Settled tasks, timers, display
links and animations were zero in every idle window.

The ready-open flush rasterized one Library-owned native search-field backing
store, 30,528 pixels, in every pair. It configured zero rows and rasterized no
row text or glyphs. Physical first-change clocks were 28.671–34.420 ms; final
signatures were 587.005–599.621 ms. These physical clocks remain INFO. Their
socket-dispatch origin differs from the App operation clock; subtracting the
two elapsed values does not establish commit-to-compositor delay.

## Idle attribution

Closed → open → closed uses three 30-second windows, with 5.3-second transition
settles. The first window starts at least 30 seconds after launch settles.
Read-only libproc process/thread counters and socket counters supply the
measurements. No prohibited diagnostic tool ran in this pass.

The five open-minus-mean(closed) deltas are +2.183718, −0.022531, +0.016578,
−0.024914 and +0.044140 percentage points. Median +0.016578 passes 0.05.
Pair 1's raw main-excess verdict remains FAIL in the receipt. Library activity
is zero. Its named App threads show the same launch-burst pattern accepted
by LEAD 09:20 after the separate order-swapped proof:

| App thread | Closed before CPU % | Open CPU % | Closed after CPU % |
|---|---:|---:|---:|
| CrBrowserMain | 0.073562 | 0.458487 | 0.098078 |
| Foreground worker group | 0.041704 | 1.029299 | 0.014911 |
| Background worker group | 0.073284 | 0.636636 | 0.060086 |
| Chrome_IOThread | 0.002890 | 0.128617 | 0.004956 |

The prior order-swapped open → closed → open run put the burst in the closed
65–96-second window: App CPU 3.756%, foreground worker 2.683%, main 0.340%
and NetworkService 0.276%. The lead accepted launch-time overlap, with idle
judged on its median. That proof is retained; it was not repeated in this pass.
The exact Chromium job is still unidentified. Full top-ten named-thread and
per-process tables for the new high sample remain in the private phase report.
Zero counters alone do not prove the cause, and the raw verdict is not rewritten.

## 10,000-row scroll

LEAD 11:20 separates two profiles on the same 10,000-row list. Both start at
least 150 seconds after launch, on a quiet M1 in Release. Wheel input uses
precise native scroll events with contact and momentum phases. Each profile
requires two load1 readings at or below 3.5, ten seconds apart, while holding
both machine slots. Other process CPU and later load remain information.

| Profile | Input | Required limits |
|---|---|---|
| A, wheel | 600 callbacks over about 5 seconds; velocity peaks at 3 rows (168 pt) per callback, then decays | Main callback p95 ≤4 ms; maximum ≤8.3 ms; cells created 0; App-attributed physical misses ≤1 |
| B, scroller drag | Cross the list in 120 callbacks, about 83 rows per callback | Main callback maximum ≤8.3 ms; cells created 0; p95 and physical misses INFO |

The runner is `tools/e2e/library_scroll_profiles.py`. It records launch age,
heartbeat context, nested phases and counters between callbacks. It also
records one no-scroll control with the Library open at the old gaps' launch
offset. An exclusion needs the same gap in that control; raw counts remain.
The full physical capture and the active-scroll interval counts remain
separate, so the scrollbar fade after scrolling ends is outside the budget.
Native events have current timestamps. Contact lasts 4.5 seconds and the
momentum tail lasts 0.5 seconds. The runner verifies actual movement during
both phases. Precise AppKit scrolling can apply clip changes after event
dispatch. Wheel work therefore uses the greater of direct callback wall time
and all main-run-loop busy time in that display interval. It compares p95
over both all callbacks and moving callbacks, using the larger value. Raw
dispatch costs remain visible; an idle tail cannot lower the budget result.

### Two-profile result

The corrected benchmark source is `a81a39db`. Its Release App SHA-256 is
`54833812ff464571b50f114f809a396b5a25cc58e06e0be3d3d7034ebf9386b3`.
OpenEngine and CEF hashes match the accepted five-pair artifact above. All
3,016 source hashes and the deep/strict signature were checked on the M1,
inside D1's slots. Both samples are valid and start after 150 seconds.

| Profile | Start age | Two load1 readings | Direct callback p95 / max | Cells created over whole series | Physical misses | Result |
|---|---:|---|---|---:|---|---|
| A, wheel, 600 callbacks | 160.843 s | 2.396 / 2.335 | 1.673 / 2.429 ms | 0 | 43 raw, none excluded | UNQUALIFIED |
| B, scroller drag, 120 callbacks | 178.434 s | 2.388 / 2.415 | 4.003 ms INFO / 4.477 ms PASS | 0 | 2 active / 3 full capture, INFO | PASS |

Wheel motion changed the native offset in 553 callbacks and produced 529
physical content changes. Its 706 row configurations ran between callbacks;
none ran inside direct dispatch. Creation is zero across both paths. The
runner's broader main-run-loop busy clock has p95 4.065 ms over all callbacks
and 4.151 ms over moving callbacks. This is broader than direct callback
work; it is retained separately rather than presented as the same clock.
The runner conservatively leaves all 43 physical intervals unexcluded. That
does not prove that each interval is a missed App render. Qualification
cannot claim the App-attributed limit of one has passed.

| A phase | Maximum ms | Scope |
|---|---:|---|
| Direct native event callback | 2.429 | Includes explicit layout/display/flush |
| Explicit layout / display / flush | 0.805 / 0.378 / 1.502 | Subsets of direct callback |
| Deferred clip-bounds work | 0.656 | Between callbacks |
| Deferred overscan reconcile | 18.284 | Includes configure/layout/display below |
| Configure / cell layout / overscan display | 1.916 / 1.711 / 13.936 | Nested in reconcile |
| Full main-run-loop busy interval | 21.808 | Settling work before callback 582 |

The 20.734 ms continuous busy gap runs at launch age 165.683–165.704 s.
Counters identify `LibraryTableView.scheduleSettle` →
`LibraryListView.prepareOverscan` → overscan reconcile/display. It configures
26 rows and creates none. The last native offset change is at 165.610 s;
the last physical content change is at 165.626 s. This settling batch is
ours, but occurs after motion ends and cannot explain the earlier 43 gaps.

For example, physical gaps of 25.000 ms occur across callbacks 19–21 and
297–299 while native offsets advance 446→498→553 and
35012→35051→35090 pt. Their sampled main-thread busy ages stay below
3.005 ms. Near the end, repeated native offsets also contribute raw physical
gaps; they remain visible. A capture gap alone does not locate the delayed
stage. No main-thread gap of at least 8 ms overlaps these physical gaps.
The permitted single-layer row fix is not triggered by these flush numbers.

The no-scroll control covers launch age 2.018–3.951 s. Its 49.987 ms early
busy gap includes Library pool/overscan preparation. A second 61.854 ms gap
at 3.186–3.248 s has no Library counter delta and reproduces an early gap
without scrolling. It is outside the known 65–96-second burst. Neither
control gap explains a sample at 160–166 s; no exclusion was applied.

Normal quit left zero owned windows/processes. No extra product optimisation,
main merge, full gate or PR follows this non-flush result without the lead's
next plan. Main `3b4d4228` must be merged before the eventual staged gate.

### Retained earlier scroller-drag receipt

The earlier stress fixture uses ten supported profiles with 1,000 downloads each. Loads were
1.997/2.410. It recorded 120 App callbacks and 115 physical content changes.
Normal quit left zero owned processes. Scroll constructed zero cells while
configuring 1,666 rows from the bounded pool.

| Metric | Measured | Limit | Result |
|---|---:|---:|---|
| Main callback p95 | 5.486 ms | Stress profile, no p95 budget | INFO |
| Main callback maximum | 7.158 ms | ≤8.3 ms | PASS |
| Cells created during scroll | 0 | 0 | PASS |
| Physical missed 120 Hz intervals | 11 | Stress profile, no miss budget | INFO |
| Missed intervals in first ten callbacks | 0 | 0 | PASS |

The old first-callback remainder is now measured. Phases below are nested:
clip handling includes reconcile/configure/layout; dequeue and tracking are
subsets. Add only scroll-to, final layout, display, flush and remainder.
Callback numbering is one-based.

| Callback | Total ms | Scroll-to ms | Clip nested ms | Configure nested ms | Cell-layout nested ms | Final layout ms | Display ms | Flush ms | Remainder ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2, maximum work | 7.158 | 3.107 | 2.751 | 1.387 | 0.742 | 0.232 | 0.318 | 3.481 | 0.019 |
| 3 | 6.645 | 2.455 | 2.339 | 1.145 | 0.734 | 0.134 | 0.289 | 3.750 | 0.017 |
| 77, maximum flush | 6.445 | 0.852 | 0.797 | 0.257 | 0.338 | 0.064 | 0.163 | 5.355 | 0.011 |
| 89, after busy gap | 3.112 | 1.130 | 1.044 | 0.372 | 0.405 | 0.078 | 0.185 | 1.707 | 0.012 |
| 114, after busy gap | 3.966 | 1.412 | 1.331 | 0.429 | 0.433 | 0.159 | 0.189 | 2.194 | 0.012 |

Only flush exceeds 4 ms as an individually measured phase. Maximum dequeue
is 0.013 ms and tracking update is 0.010 ms. The benchmark's main-thread
heartbeat and 2 ms background watchdog show two gaps:

| Callback | Interval ms | Maximum busy age ms | Maximum idle age ms | Watchdog observations |
|---|---:|---:|---:|---:|
| 89 | 46.371 | 37.902 | 2.364 | 23 |
| 114 | 16.887 | 13.881 | 2.546 | 9 |

Neither gap qualifies for the idle-main/no-system-callback exemption. All
11 physical misses remain unexcluded. This does not identify which App or
engine work caused every miss. Raster counts are not part of the constant-cost
scroll counter set; no zero-raster claim follows from their absence.

Retained wall-clock/tick anchors put the old gaps roughly 2.94–3.39 seconds
after launch. Those estimates have external-anchor uncertainty. They do not
put these gaps in the known 65–96-second launch burst. New benchmark receipts
use the App's exact launch clock; no launch-burst exclusion is assumed.

## Other evidence and next gate

Debug content checks pass 95/95. Application-route keys pass 17/17 unique
assertions. The final Debug provider/10k probe passes with zero cell creation,
zero settled activity and normal cleanup. The content drag case needed forced
cleanup, with zero owned windows/processes left. Native drag-source start and
file/URL pasteboards pass; dropping into Finder or a web upload field remains
a manual check. The real 60-second release fired at 60.011958 seconds.

The eight existing [L3 frames](l3/README.md) use synthetic Open data with the
browser window key. [Shared contrast findings](contrast.md) remain owned by
the lead. No reference was re-recorded after the ICC fix.

The first fourth-pass qualification attempt stopped before pair 1 because the
uncached Archive check changed the fixture's persisted selection. Its passing
early-cold results and forced error cleanup with zero survivors are retained.
Harness-only fix `62bc6e89` restored Downloads before quitting. The new run
contains all five fresh pairs; no measured performance sample was discarded.

Post-merge M5 `--only build` passes in 129 seconds. The 17 unique application-route key assertions also pass, with normal quit and zero owned processes.
The M5 run records the exact `icc-header-v1` key, 2560×1440 points/pixels,
scale 1 and 240 Hz. Pre-check load1 readings were 5.83/5.47 ten seconds apart.
Both machines have zero D1 App processes, frame helpers, timing jobs or heavy
tickets at that checkpoint. The full M5 gate and PR remain unopened after
the two-profile result above. The display-key hold is lifted. Only automation
code and the runner changed for this check; product rendering is unchanged.
LEAD 11:20 requires a new plan for a non-flush failure. The staged gate on main
will use its bounded tickets and exact-head M1 receipts; the old private
exclusive gate wrapper must not be reused. No reference is re-recorded.


## LEAD 12:25 clock ruling and bounded preparation

The retained wheel receipt has 33 raw capture gaps, representing 43 nominal
120 Hz intervals. Under the lead's revised attribution rule, all 43 are INFO,
"outside the App (compositor or capture cadence)". None overlaps a main-thread
busy interval of at least 8 ms, a display-link interval over 12.5 ms, or a tick
with a new offset and no App commit. The two late link callbacks occur after
the final physical change. The M1 built-in panel uses adaptive refresh;
repeated native offsets at the tail are not App misses. Raw counts are retained.
Direct callback p95/max stays 1.673/2.429 ms. The broader moving main-busy p95
4.151 ms is a separate diagnostic clock. The 61.854 ms early launch gap without
Library counter changes is assigned to performance agent H.

The narrow product change splits pool preparation, overscan rendering and
first-use row warming into cancellable idle turns. Each row is configured and
rendered before yielding to the run loop. Input cancels pending work; preparation
resumes when idle. Launch preparation waits for launch age 2 s and 500 ms without
input; the hidden panel shell still waits at least 3 s after the sidebar draw.
Prepared overscan rows survive implicit layout. Visible rows still finish
synchronously when the user opens before preparation completes.

New scoped acceptance is pending: A/B/control once, ready-open/warm/search three
pairs, and touched real-App suites. The probe records per-slice durations, exact
continuous main-busy intervals, and a no-input settling tail. Required limits
are 4 ms per slice and 6 ms for Library-attributed busy intervals at launch and
after motion. The accepted five-pair receipt and idle median remain separate.
No full gate or PR is claimed by this entry.

## LEAD 12:25 scoped result — STOP with valid A/B/control

Native source55b507c3; Release App SHA256b376f19dece6a6fcd72eac4ca981567325e499e09bcb091292f12ed022d19444. Bridgef4bce022… andCEF1a22c4aa… unchanged. All3018tracked source hashes and deep/strict signature matched inside the ownedM1slot. No product source changed during this run. The existing receipt classification is retained separately:43raw wheel intervals become0App-attributed underLEAD12:25. The new receipt below is not a replacement for those raw facts.

| Profile | Start launch age s | Two load1 readings | Callback p95 / max ms | Explicit flush max ms | Created over series and tail | Active raw / App-attributed intervals |
| --- | --- | --- | --- | --- | --- | --- |
| A wheel,600callbacks | 160.870 | 1.663 / 1.647 | 0.458 / 2.479 | 0.528 | 0 | 26 / 4 |
| B drag,120callbacks | 181.003 | 1.928 / 2.092 | 3.818 / 4.045 | 2.254 | 0 | 0 / 0 |

A callback budgets PASS (p95<=4,max<=8.3),creation0PASS;App-attributed missed intervals4>1FAIL. This is ONE raw gap containing4nominal120Hz intervals,not4separate gaps. The other22raw intervals are outside App,INFO. B callback max4.045<=8.3 andcreation0PASS;B p95/misses remain INFO underLEAD11:20. Its independent after-motion preparation acceptance fails below. Full capture raw counts:A26,B0. M1 built-in adaptive refresh and repeated native offsets do not create App misses by themselves.

| Preparation window | Slices | Maximum slice ms /4 | Library busy ms /6 | Result |
| --- | --- | --- | --- | --- |
| Launch control | 91 | 6.519 | 7.045 clear Library;59.976 mixed overlap | FAIL |
| A after motion | 41 | 4.855 | 5.321 | BusyPASS,sliceFAIL |
| B after motion | 28 | 6.693 | 7.838 | FAIL |

Each idle turn contains only one row and includes an explicit transaction flush. The measurements show that a single native row still exceeds4ms in some turns; a row-count choice alone does not prove the target. Launch preparation begins at2.761700s,after launch age2s and the input-idle guard. Control coverage2.019812–3.919829s; prelaunch loads3.475586/3.101074 pass. The control performs no synthetic scroll or forced callback commit.

| Observed event | Launch age s | Busy ms | Direct callback ms | Measured Library work | Interpretation |
| --- | --- | --- | --- | --- | --- |
| A physical gap,callback280 | 163.194937–163.236604 | 38.201 | 0.216 | clip0.452;reconcile0.375;configure0.133;cell layout0.086;idle slices0 | App-attributed by busy/link clocks;entry0,outside callback;cause unresolved |
| A late display-link callback280 | 163.224903 | 38.201 | 0.216 | display-link interval38.759;explicit flush0.034 | Same gap;do not count twice |
| Launch pool slice,callback85 | 2.761700–2.768219 | 7.045 | 0.007 | one cell created;slice6.519 | Clear Library preparation exceeds6ms |
| A overscan slice,callback688 | 166.624768–166.629624 | 5.321 | 0.012 | configure0.457;cell layout0.316;display1.571;reconcile2.654;slice4.855 | Nested phases;2.202ms outside reconcile includes flush |
| B overscan slice,callback195 | 182.618501–182.625194 | 7.838 | 0.011 | configure0.943;cell layout0.578;display2.027;reconcile4.173;slice6.693 | Nested phases;2.520ms outside reconcile includes flush |
| Mixed launch interval,callback139 | 3.217232–3.277207 | 59.976 | 0.005 | slices3.371 and0.230;one cell created | Conservative overlap match;does not prove all59.976ms is Library work |

The older61.854ms no-Library-counter gap remains assigned toH. The new59.976ms launch interval is close in launch age but has Library slices at its edges. It stays raw and mixed; no automatic exemption or whole-interval Library cause is claimed. Even without that mixed interval,the clear7.045ms Library turn fails. The new38.201ms A busy interval lies far outside the earlier65–96s launch burst and is not excluded. No idle slice overlaps it. Existing counters do not name the remaining main-thread entry point.

All41A settling slices and28B settling slices are recorded after motion in216no-input display-link ticks per profile. A last native movement165.694994s; settling coverage through167.695057s. B tail covers through183.795009s. No desktop input or prohibited attach/profiling tool ran. The native heartbeat now records the exact end of each busiest continuous interval as well as watchdog observations. App-side budget clocks and physical capture clocks remain separate.

Normal quit:reply true,forced false,zero owned windows andprocesses. Frame helper closed normally before quit. All dependent D1jobs completed; queue audits show noD1holder/waiter on eitherMac. The M5 user launchd/default-profile Open session is preserved. First launcher ticket waited144s and failed BEFORE an App launch on a private Path+str error; corrected ticket waited150s,then ran this single valid measurement. No sample was discarded or repeated.

STOP underLEAD12:25:more than1App-attributed missed interval,and6ms cannot be reached by this row-level slicing at launch/afterB. No further product edit or performance rerun. Three ready-open/warm/search pairs and touched suites NOT RUN;ready-open<=8ms remains unverified on this product head. No main merge,fullM5gate,push orPR. Accepted five-pair interaction/idle results remain separate historical receipts; do not relabel them as post-slicing ready-open acceptance.

Receipt local:`.re/l3/l3-idle-slices-profiles-r1/result.json`; M1:`receipts/l3-idle-slices-profiles-r1/result.json`. Raw receipt SHA256854086dc1eb41fa2af7da2242b0f275003bea599baeead77c1e828e2c5bffff4. Local launcher log:`.re/l3/idle-slices-profiles-r1b.log`. The machine held all configured heavy slots(one) and the screen lock through measurement and cleanup; transfer/retrieval happened only inside the owned heavy slot.

Pending question:What narrow plan should D1 follow for one A gap containing4App-attributed intervals(38.201ms main busy),and native row slices above4ms with clear Library busy turns7.045ms at launch and7.838ms afterB?


## LEAD 12:50 accepted bounds and no-flush comparison

The lead accepts the scoped scroll/preparation result at one-frame bounds:
idle slice ≤8.0 ms and clear Library busy interval ≤8.3 ms, with one row per
turn and input cancellation. The measured 55b507c3 maxima pass. Scroll is
judged on Library-attributed intervals: Library phases must account for at
least 4 ms of the overlapping busy interval. A has 0 such intervals. The
4 App-attributed intervals and 38.201 ms stall remain INFO:
"App main thread, not Library; handed to the performance agent". The mixed
59.976 ms launch interval has the same handoff. Raw counts remain unchanged.
The lead closes the performance work and retains the accepted five-pair set.

One no-flush comparison ran on c7bbc5e8, Release executable
668ece3d459faec9cdb7fce0fe448ef191327fead6222cc877f270d4d7aa112e.
All 3,019 tracked source hashes and the signature matched. Valid prelaunch
load1 readings were 3.445/3.437; before the motion setup they were 2.475/2.568.
The comparison uses the launch control and A's after-motion window only.
The heartbeat's sleep observer runs after the implicit Core Animation commit;
this includes work moved out of the explicit slice.

| Window | Slice before / without flush | Clear busy before / without flush | Limit | Result |
|---|---:|---:|---|---|
| Launch preparation | 6.519 / 4.825 ms | 7.045 / 6.027 ms | Slice ≤8.0; busy ≤8.3 ms | PASS, lower |
| A after motion | 4.855 / 3.223 ms | 5.321 / 5.218 ms | Slice ≤8.0; busy ≤8.3 ms | PASS, lower |

The explicit idle-slice flush is removed. Rows still render in idle turns;
the run loop commits them. Visible first-screen preparation and foreground
result submission keep their existing commits. No row drawing redesign or
second full five-pair/idle rerun follows this comparison.

Experiment teardown deviation: its temporary profile left scope before quit,
which removed the live socket. The App was alive at cleanup and required
forced termination; zero owned windows/processes remained. This is a harness
ordering error after completed measurements, not an App crash. The harness
now quits before removing the profile. The comparison is not rerun; normal
exit remains part of the next three pairs and touched flows.

Next checks: ready-open/warm/search three pairs and touched flows, then merge
main and the staged full M5 gate. No gate or PR is claimed by this entry.

## LEAD 12:50 lean result — STOP at ready-open with 3/3 valid pairs

The three-pair Release run completed on source `af9dfbe5`, native `c7bbc5e8`,
executable SHA-256 `668ece3d459faec9cdb7fce0fe448ef191327fead6222cc877f270d4d7aa112e`.
All 3,019 transported source hashes, artifact hashes and the deep/strict signature matched.
The ticket waited 2,440 seconds in the queue, then measured for about three minutes;
it did not hold the slot throughout that queue wait. All three baseline/candidate
pairs held both slots and passed both pre-launch load1 readings ≤3.5. Foreign CPU
remains INFO. No valid sample was interrupted after the 13:38 scheduling instruction.

| Required row | Median ms | Maximum ms | Median limit / sample ceiling ms | Result |
|---|---:|---:|---:|---|
| Ready-open first commit | 10.882 | 11.144 | 8 / 12 | FAIL |
| Warm section | 4.644 | 4.845 | 8.3 / 12.45 | PASS |
| Search | 7.151 | 8.557 | 16 / 24 | PASS |

All nine warm switches configured/reloaded zero rows. Every baseline/candidate
quit normally (`forced=false`), with zero remaining owned processes and windows.
This verifies the fixed temporary-root teardown order.

| Pair | Baseline load1 | Candidate load1 | Ready first ms | Action ms | Layout ms | Display ms | Commit flush ms | Cumulative idle-slice max at open ms |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 1 | 3.485 / 3.103 | 3.103 / 2.926 | 10.882 | 4.402 | 0.637 | 0.351 | 5.492 | 11.665 |
| 2 | 2.692 / 2.572 | 3.087 / 2.766 | 11.144 | 5.145 | 0.663 | 0.361 | 4.975 | 9.803 |
| 3 | 2.864 / 2.577 | 2.577 / 2.254 | 5.183 | 1.759 | 0.360 | 0.237 | 2.827 | 8.582 |

The open operation created/configured/reloaded zero rows and formatted no data.
It rasterized one native Library search backing store (30,528 pixels), with no
row-text/glyph raster. The explicit commit phase is 5.492/4.975/2.827 ms; that
transaction-wide flush does not by itself prove all time belongs to the Library.

The cumulative idle-slice counter also records 11.665/9.803/8.582 ms before each
open, above the 8.0 ms bound. These are newly observed raw Library slice maxima;
this lean runner did not capture their individual busy intervals. They are retained
and must be ruled on; the earlier scoped no-flush/control result is not rewritten.
There was no idle or full A/B rerun.

Per LEAD 12:50, the required ready-open failure stops further work. Touched content
and keys suites, main merge, exact-head M1 receipts, full M5 gate, push and PR remain
NOT RUN. Both D1 machine queues are clear and no D1 App process remains. Future M1
work uses one bounded ticket per pair or touched suite (about 15 minutes maximum
while others wait), with receipt copying and analysis after release.
