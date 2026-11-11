# Library validation

Status: STOP before the full M5 gate and PR. All five Release pairs are valid.
The interaction budgets and idle median pass. The 10,000-row scroll still
fails its p95 and missed-interval limits. No further performance change or
qualifying rerun follows this result without the lead's answer.

The fourth-pass native source is `c9a2e305`. Harness fix `62bc6e89` restores the
fixture selection after the uncached Archive probe. Main merge `48c378c9`
includes `ccca06d0` and the `icc-header-v1` display-key fix. That merge changes
no App, engine or Library runtime code. Existing reference images are retained.

The Release executable SHA-256 is
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

The fixture uses ten supported profiles with 1,000 downloads each. Loads were
1.997/2.410. It recorded 120 App callbacks and 115 physical content changes.
Normal quit left zero owned processes. Scroll constructed zero cells while
configuring 1,666 rows from the bounded pool.

| Metric | Measured | Limit | Result |
|---|---:|---:|---|
| Main callback p95 | 5.486 ms | ≤4 ms | FAIL |
| Main callback maximum | 7.158 ms | ≤8.3 ms | PASS |
| Cells created during scroll | 0 | 0 | PASS |
| Physical missed 120 Hz intervals | 11 | ≤1 in 120 | FAIL |
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
scroll counter set; no zero-raster claim follows from their absence. The flush
and between-callback busy work need the lead's next plan.

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
tickets. The full M5 gate and PR remain unopened because the scroll still
fails. The display-key hold itself is lifted. No additional performance
optimisation or rerun has started.
