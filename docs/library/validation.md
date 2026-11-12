# Library validation

Status: LEAD 15:30 accepts all three valid launch controls and closes the
performance work. Judge busy time on Library overlap: launch 3 slice 45 has
8.010792 ms ≤8.3 ms. The enclosing 8.424292 ms, including 0.413500 ms of other
main-thread work, is INFO. All later-row slices and Library overlaps pass
8.3 ms; first-row turns and overlaps pass 16.7 ms INFO. Product code and
artifact are unchanged. Touched suites, main merge, scoped M1 receipts, the
one full M5 gate and PR follow. Original receipts and STOP tables are retained.

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

## LEAD 13:50 — explicit flush restored; scoped ready-open check

The no-flush experiment is reverted. Every idle turn again handles one row and
calls `CATransaction.flush()` before yielding. The complete OpenLibrary module
is byte-identical to `55b507c3`: Git tree `6747b46483dee5c5d61993dd9c2dce5996b891f5`,
source-content SHA-256 `6545a65406364960b56ff1e64b74ddcb127b822b7f9ef527d859f1ecdc5e1611`. Warm section and search carry under the
lead's explicit ruling; they are not repeated.

The new opt-in automation heartbeat records every complete main-loop busy interval
from automation startup, including the implicit Core Animation commit. It does
not add a display link, timer, or product scheduling change. Each preparation
slice is matched to its own busy interval. The ready-open receipt records the
open's launch age, `prebuiltReady`, the App prebuild task and all panel task counts
before the action. The required three pairs wait for preparation to finish;
any open that instead reports pending preparation remains a separate INFO row.

Acceptance is median ready-open ≤8 ms, every scored sample ≤12 ms, every slice
≤8.0 ms and clear Library busy ≤8.3 ms. Mixed intervals retain their full duration
and measured Library contribution; the runner invents no exclusion. The one
measurement ticket has a thirteen-minute deadline with time reserved for cleanup.
Touched suites each use a separate ticket. Receipt copying occurs after release.

The open action phase calls `AppSettingsActions.showLibrary`: it acknowledges the
download badge, registers stores, selects the retained section, attaches/presents
the panel, installs focus/key handlers, makes its window key and requests a menu
rebuild. Native layout, display and the final commit flush are separate phases.
This call graph is not a measured attribution of the transaction-wide flush.

The prior failed no-flush receipt and its cumulative maxima stay unchanged.
No new qualification result, main merge, full gate or PR is claimed here.


## LEAD 13:50 restored-flush result — STOP with 3/3 valid pairs

The single scoped Release run on `754cb5b5a52f5df41eae87af3ce92689cb37c8f2`
completed all three baseline/candidate pairs. Every pair is valid. Preparation
finished before every open, so no sample qualifies as INFO "open during
preparation". Required ready-open and preparation rows fail. Per LEAD 13:50,
D1 stopped before any further rerun, product edit, touched suite, main merge,
exact-head M1 lane, full M5 gate, push or PR.

| Required row | Measured ms | Limit ms | Result |
|---|---:|---:|---|
| Ready-open median | 8.818 | ≤8.0 | FAIL |
| Ready-open maximum | 14.316 | ≤12.0 | FAIL |
| Individual idle slice maximum | 12.279 | ≤8.0 | FAIL |
| Clear Library-associated busy interval maximum | 13.869 | ≤8.3 | FAIL |

The restored explicit `CATransaction.flush()` runs after each one-row idle
slice. An opt-in automation heartbeat observes the main loop from startup,
including implicit Core Animation commits. It records full busy intervals,
not only the cumulative slice counter. All 210 preparation slices (70 per
pair) have complete coverage; no trace overflow occurred. The observers were
removed before trace retrieval. The trace does not add a polling timer or
display link.

### Validity and ready-open phases

Each baseline and candidate passed two pre-launch load1 readings ≤3.5.
Foreign-process CPU remains INFO and is not a post-hoc validity filter.

| Pair | Baseline load1 | Candidate load1 | Open launch age s | Ready-open ms | Action ms | Layout ms | Display ms | Flush ms |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 1 | 3.451 / 3.074 | 3.074 / 2.841 | 5.193 | 14.316 | 7.101 | 0.992 | 0.551 | 5.670 |
| 2 | 2.693 / 3.121 | 3.121 / 2.641 | 4.950 | 7.266 | 3.813 | 0.413 | 0.301 | 2.738 |
| 3 | 3.430 / 3.056 | 3.056 / 3.476 | 5.115 | 8.818 | 4.782 | 0.417 | 0.261 | 3.356 |

The exact `preparationBefore` state is captured inside the open operation,
before its action starts, rather than inferred from an earlier poll.

| Pair | completed | prebuiltReady | prebuildTaskPending | panelTasks | idleSliceCount |
|---|---|---|---|---:|---:|
| 1 | true | true | false | 0 | 70 |
| 2 | true | true | false | 0 | 70 |
| 3 | true | true | false | 0 | 70 |

Every open created/configured/reloaded zero rows and formatted no data. Each
rasterized one Library search-field backing store (30,528 pixels), with zero
row-text or glyph rasters. These counters do not establish the cause of the
open's action or transaction-wide flush cost.

The action phase calls `AppSettingsActions.showLibrary`
(`App/Settings/AppSettingsActions.swift`): refresh download files and acknowledge
the badge; get archive/history stores and register them; call
`AppLibrarySession.show`; make the browser window key, activate the App and
schedule a menu rebuild. `AppLibrarySession.show`
(`App/Settings/AppLibrarySession.swift`) cancels release, reuses the prepared
panel, selects the retained section, attaches/presents it, lays out the browser
container, installs its key handler and focuses the rail. The automation submit
then measures layout, display and the final transaction flush separately. This
source call graph explains what the action includes; it does not assign its
elapsed time to individual calls or attribute the entire flush to the Library.

### Individual slice and full busy-interval evidence

The maximum slice is slice 1 in every pair. Its full enclosing main-loop busy
interval is also the largest interval associated with preparation in that pair.
Measured Library slice work dominates each interval; the remainder stays visible.

| Pair | Max slice ms | Full busy interval ms | Library overlap ms | Other main-thread time ms | Slice / busy result |
|---|---:|---:|---:|---:|---|
| 1 | 12.279 | 13.869 | 12.280 | 1.589 | FAIL / FAIL |
| 2 | 8.559 | 10.335 | 8.559 | 1.776 | FAIL / FAIL |
| 3 | 9.234 | 10.122 | 9.234 | 0.888 | FAIL / FAIL |

| Pair | Slice launch range ms | Full busy launch range ms |
|---|---|---|
| 1 | 4089.071–4101.351 | 4088.890–4102.759 |
| 2 | 3867.335–3875.894 | 3867.259–3877.594 |
| 3 | 3974.607–3983.841 | 3974.508–3984.630 |

The Library-overlap clock uses slice start/end timestamps, while the slice's
own duration ends just before its final timestamp is recorded. This explains
the sub-microsecond difference in pair 1 before rounding. No interval is excluded.
The trace has no per-entry slice labels. `LibraryListView.warmRowKinds`
(`Packages/OpenKit/Sources/OpenLibrary/LibraryListView.swift`) is a source
candidate: its idle loop creates/configures/renders one row at a time, beginning
with a download row. The receipt does not prove that this is slice 1's entry
point, nor which operation inside the slice caused its maximum.

### Identity, carried checks and cleanup

The entire OpenLibrary module is byte-identical to `55b507c3`:
Git tree `6747b46483dee5c5d61993dd9c2dce5996b891f5`, source-content SHA-256
`6545a65406364960b56ff1e64b74ddcb127b822b7f9ef527d859f1ecdc5e1611`.
`git diff --exit-code 55b507c3 -- Packages/OpenKit/Sources/OpenLibrary` passes.
Warm-section and search checks carry under LEAD 13:50; they were not rerun.
This identity does not override the new measured ready-open or slice failures.

The Release build passed before measurement. Executable SHA-256:
`8f2e906dafb530609bfa7bed1f0c96e7bb71a95e0635d9d677cdbb7d43d4f483`.
All 3,021 transported source hashes, artifact hashes and the deep/strict
signature matched inside the M1 slot. OpenEngine remains
`f4bce022c1473542e1220260bcec2a2d2c9eab83cf5bffe502feca79b4155a6d`;
CEF remains `1a22c4aa1b49d7199915766efc2e7665262ec36993ab0b96e4e4200375f762c0`.

The ticket waited 480 seconds, then ran for about four minutes. It released
before receipt copying and analysis. All six launches quit normally
(`forced=false`); every cleanup report passes with zero owned windows/processes.
Post-run audits found no remaining D1 job, holder or waiter on either Mac.
The user's M5 launchd/default-profile Open session was left untouched.
No full gate was invoked, so there is no partial-M1 receipt refusal to report.
The LEAD 14:00 lean exception remains the plan only after a passing ruling.

Receipt: `.re/l3/l3-explicit-flush-ready-r1/result.json`;
SHA-256 `09c6918e8a0a821e201fa208b4f6980d949af0567f329efaced00b4956b6e267`.
M1 retained receipt: `receipts/l3-explicit-flush-ready-r1/result.json`.
Launcher log: `.re/l3/explicit-flush-ready-r1.log`.

Pending lead decision: What narrow next step should D1 take for the failed
ready-open and preparation bounds after explicit flush was restored and all
three opens occurred after preparation finished? No further work is queued.


## LEAD 14:20 closing rule — first-use rows split, launch control pending

Ready-open uses the plan's required median ≤16 ms and sample ceiling ≤24 ms.
All measured sets pass. The ≤8 ms prebuilt median is a stretch target, INFO;
the latest value is 8.818 ms, "stretch target; follow-up with the performance
agent". The action phase is handed to that agent for per-call measurements.
The earlier LEAD 13:50 verdicts remain historical below their original limits.

Only `LibraryListView.warmRowKinds` changes product work: for the first row
of download, archive, history, capture, boost, boostGallery and heading, creation,
configure/layout, and display/flush run in three separate input-yielding turns.
Creation and configure/layout do not explicitly flush; display does. Later rows
keep one row and one explicit flush per turn. `LibraryIdleWork` adds numeric
kind/phase/first-use labels to its existing trace; its default submission order
is unchanged. Automation includes those labels in the full busy-interval trace.
No open action, foreground submission, section switch, search, provider,
scroll callback, overscan body or row drawing path changes. Ready-open,
warm-section, search and scroll receipts carry by this explicit diff scope
under LEAD 14:20; they are not represented as newly measured samples.

One bounded M1 ticket runs three no-scroll launches with a heartbeat from
startup, all slices and all overlapping busy intervals. Required limits are
≤8.3 ms for slices and clear Library busy intervals. If a first creation turn
exceeds that, it is INFO "first-use cost", with a hard ceiling of 16.7 ms;
all other turns and intervals must still be ≤8.3 ms. Only phase 1 of each
labelled kind can use that exception. Full raw intervals and their Library/other
work split remain in the receipt. No interval is silently excluded.

After acceptance: touched content and key suites in separate ≤15-minute tickets,
merge main, M1 receipts limited by LEAD 14:00, one staged full M5 gate, then PR.
If the gate refuses the partial M1 receipt set, report its exact refusal.


## LEAD 14:20 first-use control — STOP at launch 2 configure/layout

The bounded no-scroll launch control ran on `2861c7648e367e4033156e2461dd253ec44b40ec`,
Release executable SHA-256
`be01de5bb51c48726d15d4729775814656938301385807dd0a01c6c6efa957b7`.
Both completed launches are valid. The second launch breaks a required
non-first-turn limit, so the runner stops before launch 3 under LEAD 14:20.
No sample was discarded or repeated. The planned three-launch set is incomplete;
this is a retained required failure, not acceptance of a two-launch set.

| Launch | Pre-launch load1 | Preparation complete at launch age s | Max creation slice ms | Max other slice ms | Max creation busy ms | Max other busy ms | Result |
|---|---|---:|---:|---:|---:|---:|---|
| 1 | 3.300 / 3.099 | 5.428 | 0.449 | 6.528 | 1.347 | 8.299 | PASS |
| 2 | 3.130 / 3.116 | 5.230 | 0.941 | 8.485 | 1.309 | 9.219 | FAIL |

The failing turn is **slice 2, download configure + layout**, the second turn
of the first download row. Its slice is 8.485 ms (>8.3), and its enclosing
main-loop busy interval is 9.219 ms (>8.3). The receipt reserves the 16.7 ms
INFO "first-use cost" exception for each kind's first creation turn (phase 1).
It does not extend that exception to configure/layout (phase 2) or display/flush
(phase 3). Creation itself is below 1 ms in both launches.

| Launch 2 failing interval | Start launch age ms | End launch age ms | Duration ms |
|---|---:|---:|---:|
| Download configure/layout slice 2 | 3970.425 | 3978.914 | 8.485 |
| Full main-loop busy interval | 3970.340 | 3979.559 | 9.219 |
| Library slice overlap inside busy interval | — | — | 8.489 |
| Other main-thread work inside busy interval | — | — | 0.730 |

The Library overlap uses start/end timestamps; the slice duration is recorded
just before the end timestamp. The raw clocks differ by 0.004 ms in this turn.
The interval is dominated by the measured Library phase. Configure and layout
are one measured phase; there is no per-call attribution within it. There is
no explicit transaction flush in this turn. Display plus explicit flush occurs
in the next, separate turn (3.519 ms in launch 2).

### First-row phase table

All seven first row kinds have creation, configure/layout and display/flush in
three distinct main-loop busy intervals. The trace includes implicit commits.
Each completed launch records 84 slices: 21 labelled first-row turns and 63
later-row turns. All 168 slices have complete coverage; no overflow occurred.
No intervals are excluded.

Launch 1 (milliseconds):

| First row kind | Creation | Configure + layout | Display + flush | Largest enclosing busy interval |
|---|---:|---:|---:|---:|
| download | 0.449 | 5.218 | 3.613 | 5.824 |
| archive | 0.317 | 2.560 | 1.654 | 3.296 |
| history | 0.213 | 2.790 | 1.700 | 3.113 |
| capture | 0.209 | 3.038 | 0.464 | 6.552 |
| boost | 0.205 | 2.883 | 1.576 | 3.299 |
| boostGallery | 0.339 | 5.249 | 2.235 | 5.715 |
| heading | 0.135 | 0.080 | 1.012 | 3.207 |

Launch 2 (milliseconds):

| First row kind | Creation | Configure + layout | Display + flush | Largest enclosing busy interval |
|---|---:|---:|---:|---:|
| download | 0.941 | 8.485 | 3.519 | 9.219 |
| archive | 0.233 | 3.309 | 2.113 | 3.652 |
| history | 0.234 | 4.665 | 0.721 | 5.054 |
| capture | 0.272 | 1.218 | 0.572 | 1.362 |
| boost | 0.120 | 1.366 | 0.500 | 1.511 |
| boostGallery | 0.090 | 4.068 | 2.479 | 4.520 |
| heading | 0.395 | 0.283 | 1.105 | 5.338 |

| Later rows only | Maximum slice ms | Maximum enclosing busy interval ms | Limit ms | Result |
|---|---:|---:|---:|---|
| Launch 1, 63 turns | 6.528 | 8.299 | ≤8.3 | PASS |
| Launch 2, 63 turns | 6.717 | 7.096 | ≤8.3 | PASS |

Only launch 2's download configure/layout turn and its enclosing interval
exceed 8.3 ms. It is the second turn of the first row; the later rows pass.
The first-use INFO fallback cannot qualify this required phase under the
receipt's stated first-creation-only interpretation.

### Identity, carried rows and cleanup

The split changes only `LibraryListView.warmRowKinds` and idle trace labels.
The default one-row idle submission order is unchanged. The open action,
foreground submission, warm-section, search, scroll callback and overscan bodies
are unchanged versus `55b507c3`. Their accepted receipts carry by the explicit
LEAD 14:20 diff-scope ruling; this control did not remeasure them. Required
ready-open remains PASS at median/max 8.818/14.316 ms against 16/24 ms.
Its 8.818 ms median is INFO against the 8 ms stretch target:
"stretch target; follow-up with the performance agent".

OpenLibrary source-content SHA-256:
`a75273e2cb4e0adc149a9ca97905f982ea4f4d22805e62d2dcc2e11dfa78ebc1`;
Git tree `9e8403c595277a81f0f95e8007b7d7180e4642b5`.
The Release build passes. An initial compile failure from two display helpers
sharing a name was fixed before the successful build; its log is retained at
`.re/l3/first-use-build-r1.log`. No timing launch used the failed build.
All 3,022 transported source hashes, artifact hashes and the deep/strict
signature matched. OpenEngine `f4bce022c1473542e1220260bcec2a2d2c9eab83cf5bffe502feca79b4155a6d`
and CEF `1a22c4aa1b49d7199915766efc2e7665262ec36993ab0b96e4e4200375f762c0` remain unchanged.

The M1 ticket queued at 14:14:04 and acquired after 980 seconds. Slot time was
about two minutes, including quiet preflight; receipt copying and analysis
occurred after release. Both measured launches quit normally (`forced=false`),
with zero remaining owned windows/processes. Both queues and executable paths
were audited after completion: no D1 job, holder, waiter or Open process remains.
The user's M5 launchd/default-profile session is preserved. Foreign CPU is INFO;
only the two pre-launch load1 readings judge quiet validity.

No third launch, further product change, touched-suite rerun, main merge,
exact-head M1 lane, full M5 gate, push or PR follows this hard-bound failure.
`origin/main` is fetched at `bac09a36` but remains unmerged. There is no gate
receipt refusal to report. LEAD 14:00 lean scope remains planned for later.

Receipt: `.re/l3/l3-first-use-control-r1/result.json`;
SHA-256 `3f6d794cb65e8a509030533f365d99823ed4325f94960a91208228da48d578f0`.
M1 receipt: `receipts/l3-first-use-control-r1/result.json`.
Log: `.re/l3/first-use-control-r1.log`.

Pending lead decision: What narrow next step should D1 take for the first
download row's second turn (configure/layout 8.485 ms, enclosing busy 9.219 ms),
with all creation turns and all later-row turns inside their bounds?


## LEAD 14:50 — all first-row turns are first-use cost; launch 3 only

The lead clarified the scope: creation, configure/layout and display/flush of
the FIRST row of each kind, and their enclosing busy intervals, are all INFO
"first-use cost", with a hard ceiling of16.7ms. Every later-row slice and busy
interval remains required at≤8.3ms. No product code changes for this ruling.
The earlier receipt and its original FAIL/exit1 stay intact. A separate derived
receipt reclassifies its existing clocks under the new rule; no sample is repeated.

| Retained launch | First-row slice max ms, INFO | First-row busy max ms, INFO | Later-row slice max ms | Later-row busy max ms | Hard bounds |
|---|---:|---:|---:|---:|---|
| 1 | 5.249 | 6.552 | 6.528 | 8.299 | PASS |
| 2 | 8.485 | 9.219 | 6.717 | 7.096 | PASS |

Both launches remain valid with complete coverage and normal cleanup. Launch2's
8.485ms configure/layout and9.219ms busy interval are inside the first-row16.7ms
ceiling. All126later-row turns pass. Derived receipt:
`.re/l3/first-use-r1-rescored-1450.json`, linked to raw receipt SHA-256
`3f6d794cb65e8a509030533f365d99823ed4325f94960a91208228da48d578f0`.

Only launch3 remains. The harness supports `--start-index 3 --launches 1` in one
bounded M1 ticket. First-row eligibility derives from the recorded row kind and
phase1/2/3, while the original native creation marker stays unchanged. This is
scoring/harness work only: App, OpenLibrary and Engine are unchanged from2861c764.
The candidate Release executable remainsbe01de5bb51c48726d15d4729775814656938301385807dd0a01c6c6efa957b7,
and the Library module remainsa75273e2cb4e0adc149a9ca97905f982ea4f4d22805e62d2dcc2e11dfa78ebc1.
No ready-open, warm/search, scroll or five-pair rerun follows this clarification.


## LEAD 14:50 launch 3 result — STOP at later-row enclosing busy interval

Launch 3 ran once as the requested continuation, with no product change. It is
valid: Release, both pre-launch load1 readings 3.260742/2.919434 ten seconds apart.
Foreign CPU was 24.8%, informational. All 3,022 transported source hashes match
`6da28142`, the deep/strict signature passes, and the Release executable remains
`be01de5bb51c48726d15d4729775814656938301385807dd0a01c6c6efa957b7`.
Native source remains `2861c764`; OpenLibrary SHA-256 remains
`a75273e2cb4e0adc149a9ca97905f982ea4f4d22805e62d2dcc2e11dfa78ebc1`.
No launch 1/2, ready-open, warm/search, scroll or five-pair sample was repeated.

All three turns of each first row and their enclosing busy intervals use the
LEAD 14:50 INFO first-use ceiling of 16.7 ms. Later-row turns and their enclosing
busy intervals remain required at 8.3 ms. The corrected three-launch set is:

| Launch | First-row slice max ms, INFO | First-row busy max ms, INFO | Later-row slice max ms | Later-row busy max ms | Required result |
|---|---:|---:|---:|---:|---|
| 1 | 5.249 | 6.552 | 6.528 | 8.299 | PASS |
| 2 | 8.485 | 9.219 | 6.717 | 7.096 | PASS |
| 3 | 8.129 | 8.674 | 8.010 | 8.424 | FAIL: later-row busy |

Launch 3 has 84/84 slices with complete heartbeat coverage: 21 first-row phases
and 63 later-row turns. All seven first rows have three distinct main-loop turns.
Every first-row slice and busy interval passes the 16.7 ms hard ceiling. Every
later-row slice passes 8.3 ms, but one enclosing busy interval does not. The
three-launch set has 252 covered slices; all 189 later-row slices pass, and
188/189 later-row enclosing busy intervals pass. No interval is excluded.

### Launch 3 first-row phases, INFO; hard ceiling 16.7 ms

| Row kind | Creation ms | Configure/layout ms | Display/flush ms | Largest enclosing busy ms |
|---|---:|---:|---:|---:|
| download | 1.182 | 8.129 | 3.447 | 8.674 |
| archive | 0.348 | 3.163 | 1.888 | 3.478 |
| history | 0.186 | 3.958 | 0.723 | 4.436 |
| capture | 0.113 | 1.640 | 1.790 | 4.144 |
| boost | 0.272 | 2.840 | 1.729 | 3.640 |
| boostGallery | 0.158 | 6.018 | 1.745 | 6.381 |
| heading | 0.476 | 0.344 | 1.289 | 7.099 |

### The single required failure

| Clock | Launch-age range ms | Duration ms | Required limit ms | Result |
|---|---|---:|---:|---|
| Later-row slice 45 | 4766.602–4774.613 | 8.010417 | 8.3 | PASS |
| Enclosing main-loop busy interval | 4766.543–4774.968 | 8.424292 | 8.3 | FAIL |
| Library slice overlap inside busy interval | Same busy interval | 8.010792 | Attribution | Measured |
| Other main-thread work inside busy interval | Same busy interval | 0.413500 | Attribution | Measured |

The busy interval exceeds 8.3 ms by 0.124292 ms. Native tags are
`rowKind=0`, `phase=0`, `firstUse=0`; this is a later-row turn, not any of the
21 first-row turns. The receipt does not split this turn into configure, layout,
display and flush subphases or identify its row kind. No cause is inferred from
the source alone. It receives no first-use exception.

Preparation completed at launch age 5.274281 s, with `prebuiltReady=true`,
`prebuildTaskPending=false`, and `panelTasks=0`. This control performs no scroll
or timed open. Required ready-open remains accepted at median/max
8.818/14.316 ms against 16/24 ms; the 8.818 ms median remains INFO against the
8 ms stretch target. Existing warm/search/scroll carries are unchanged.

The ticket queued at 14:51:29, waited 1,664 s, then held the slot for about
three minutes, including bounded quiet preflight. It released before receipt
copying and analysis. Launch 3 quit normally (`reply=true`, `forced=false`),
with zero owned windows/processes. Queue/path audits on both Macs show no D1
holder, waiter or Open process. The user's M5 launchd/default-profile session
was preserved.

STOP under LEAD 14:50: one later-row enclosing busy interval exceeds 8.3 ms.
No product edit, further run, touched suite, main merge, exact-head M1 lane,
full M5 gate, push or PR follows. There is no partial-M1 gate refusal; no gate ran.

Receipt: `.re/l3/l3-first-use-control-r2-launch3/result.json`; SHA-256
`bf2d188ecbf4ef8d6307ef4e404a405ca5766645b544a2a076c9db50f6eab4b7`. M1 retained copy:
`receipts/l3-first-use-control-r2-launch3/result.json`. Launcher log:
`.re/l3/first-use-control-r2-launch3.log`. Combined derived summary:
`.re/l3/first-use-three-launch-1450.json`. The original launches 1–2 receipt
and separate LEAD 14:50 rescoring receipt remain unchanged.

Pending question: What narrow next step should D1 take for launch 3's later-row
enclosing busy interval 8.424292 ms (Library overlap 8.010792 ms; other main work
0.413500 ms), with every slice and all first-row hard ceilings passing?


## LEAD 15:30 — PASS; Library-attributed busy time closes performance

The lead accepts the three-launch set. The busy row judges the Library's
measured overlap with a main-thread busy interval. The full enclosing interval
and other main-thread work stay visible as INFO. This applies the same
Library-attributed principle used for scroll. No product code, raw receipt,
sample or clock changes. No further measurement of these performance rows.

| Launch | First-row slice max ms, INFO ≤16.7 | First-row Library overlap max ms, INFO ≤16.7 | Later-row slice max ms, required ≤8.3 | Later-row Library overlap max ms, required ≤8.3 | Full later-row enclosing interval max ms, INFO | Result |
|---|---:|---:|---:|---:|---:|---|
| 1 | 5.249 | 5.249 | 6.528 | 6.528 | 8.299 | PASS |
| 2 | 8.485 | 8.489 | 6.717 | 6.718 | 7.096 | PASS |
| 3 | 8.129 | 8.129 | 8.010 | 8.011 | 8.424 | PASS |

Launch 3 slice 45 passes: measured Library overlap **8.010792 ms ≤8.3 ms**.
Its own slice is 8.010417 ms. The full enclosing interval **8.424292 ms**,
including **0.413500 ms** of other main-thread work, is INFO. All three launches
are valid; all 252 slices have complete coverage. All 189 later-row slices and
Library overlaps pass 8.3 ms. All first-row phases and overlaps pass 16.7 ms.
The old STOP tables and original receipt verdicts remain above as history.
The separate `.re/l3/lead-1530-acceptance.json` records this accepted ruling
without editing the retained raw receipts.

The performance work is CLOSED. Required ready-open remains PASS at
median/max 8.818/14.316 ms against 16/24 ms. Median 8.818 ms against the
8 ms stretch target stays INFO, follow-up with the performance agent. Accepted
warm/search, A/B scroll, interactions and idle receipts carry by the recorded
hashes and unchanged-path rulings.

Continue: touched content and keys in separate bounded M1 tickets; merge
current origin/main; scoped final-head M1 receipts under LEAD 14:00; one full
M5 gate with those receipts; PR with the tables and rulings; pending question
"PR ready to merge". Stop only for a functional failure or gate refusal.


## LEAD 15:30 touched suites — PASS

Both touched suites ran through separate bounded M1 heavy/screen tickets on
source `437e7409`, with the unchanged Release executable `be01de5bb51c…`
(native source `2861c764`, OpenLibrary `a75273e2…`). Each ticket verified all
3,022 transported source files and the original artifact hashes/signature.
Receipt copying and analysis followed release. No Library performance row
was measured again.

| Touched real-App flow | Result | Cleanup | Receipt |
|---|---|---|---|
| Library content, real stores/transfers/capture/Space operations | PASS 95/95 | Native drag-source case required forced cleanup; zero owned windows/processes | `.re/l3/l3-idle-slices-content-r1/result.json` |
| Application key path in rail/search/filter/list | PASS 17/17 | Normal quit; zero owned windows/processes | `.re/l3/l3-idle-slices-keys-r1/result.json` |

Content covers truthful empty state, corrupt capture index and recovery,
provider paging, filters/search, download pause/resume/cancel/failure, native
confirmation paths, real captures, Boosts, Space cards and lifetime checks.
Keys cover Cmd+L/T/W and command-bar Escape through `route=app` in all four
Library focus contexts. Native file/URL pasteboards and drag-source start
pass; foreign-app drop/end remains manual and unverified.

Content raw receipt SHA-256:
`e260f54e4c001df3f2fdce148d06ebf25b05852307e74c422abbb3245440c2ce`.
Keys raw receipt SHA-256:
`b1d21a9cc84e2af668f6f77c7e2c48157aa1a2fb79b4a25d4d2b0d34d9dacb3a`.

Final merge verification and exception tables are reported with the PR.

## LEAD 16:35 / 17:10 / 17:30 — native automation and preview checks

The approved Space card has no Profile indicator. Profiles automation now
opens the real card's More options → Set Profile menu and reads the Space's
Profile from the model/browser owner. It retains Profile changes, sheet
ownership, confirm/Cancel/Return/Undo, durable storage and isolation assertions.
The complete Release Profiles suite passed **74/74** on M5 source `b6b528e9`.
All 23 owned Apps quit normally, with zero survivors. Receipt SHA-256:
`f2aca09c4c0483ef3496c1db1f431d0e0e2ff5b4a62b00ea9b2dd1e4bc49052c`.

Space card shows no Profile indicator by design; follow-up after capture
session 3 Part F (how Arc shows a Space's Profile).

The first final M5 gate on `5a35b0ad` stopped at the old Settings preview
Archive favicon assertion after 24 passing checks. That check read the
removed Library window's eager favicon dictionary. Native rows use
`loadRowIcon`. The repaired Archive check passed on rented Mac 2, including
search, Space filtering, valid icons for both rows, restore, persisted model,
Undo/Redo, delete confirmation/delete and clear. That complete suite then
stopped at the old Boost preview lifecycle/label assumptions after 27 checks.
Both failures and safe cleanup receipts remain retained.

Before adapting the remaining previews, the same Library module was exercised
in the real App on rented Mac 1 through its automation socket. The content
flow passed 74 checks across Downloads, Archive, History and Media before its
Boost editor fixture setup stopped. This is not a complete content-suite pass.
A separate fresh flow created a Boost through the real editor, saved it,
opened Library Boosts, and found its native row by the created ID. Both flows
cleaned up with zero survivors. Their receipt SHA-256 values are respectively
`35abb8b22e1f8f8fa433f97b7a8e0eb8bdb35a621be7bf85cba51e7a4d734f47`
and `a91e5a5988efdc39c5bc408defa0c2d8f9a0fb9e2a992e01b16bcc6e2fadaf56`.

The preview repair activates/dismantles the native panel, joins provider and
row preparation before capture/AX reads, and supplies real Space cards.
Archive/History icons must be valid and retain object identity on a second
native lazy-cache read. Boost checks require both exact visible row labels,
including domain/name/on-off state; native Turn On/defaults persistence and
replacement by the empty state remain asserted. No functional assertion was
removed. Only automation and preview sources changed; the product Library
module and timing paths are unchanged.

The complete Settings preview suite passed **47/47 checks**, its renders,
defaults and snapshot assertions on rented Mac 2 at clean source `768f8ad5`.
The native screen guard reports safe cleanup, no new crashes, no system
windows and no leaked group. The ticket released before receipt copying.
Raw receipt: `.re/l3/preview-native-1730/ns2/d1-preview-1730-r3-out/gate/gate.json`;
SHA-256 `228abaffec82b040f28c3486627435a27d1f973bc6c8e1c29dae7b8624ed6da8`.
This touched-suite result is separate from the required final full M5 gate.


## LEAD 20:45 / 21:15 — live History and browser owner

The Library is part of its browser window. Menu, hotkey and command-bar
entry points (Boost Gallery, Downloads and History) use that window's owner
Profile and reset the Library filter to it. Navigation within the open
Library, including sidebar sections and filters, keeps the chosen filter.
Boost Gallery F1 covers a B filter, internal navigation retaining B, then
menu entry resetting to owner A. Profile isolation assertions remain.

History now cancels the previous store subscription and stale provider
generation only when the selected Profile changes. The NS1 before case
stored Profile2 visits but never published them into the open Library,
even after native filter selection and reopen. After commit87fe8b76,
`history_library_new_profile_live` passes with separate SQLite/model/native
row evidence; Profile isolation and front-window cases also pass. The full
History suite still needs completion after adapting its closed-panel and
no-window setup. Library open and list-scroll timing require one fresh
quiet-M1 ticket under LEAD20:45. Other unchanged receipts carry by ruling.

LEAD21:40 applies the owner reset to all three entry points, even while the
Library is open. Equality checks leave an existing owner filter unchanged.
Same-section entry into an open panel keeps its prepared provider. Native
automation reports each provider generation, so the History flow checks that
repeated owner entry causes no provider reload. Internal section navigation
has its own assertion that the selected Profile stays unchanged. These entry
changes share the single LEAD20:45 open/list-scroll qualification.
