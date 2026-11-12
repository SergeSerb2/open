# Performance scorecard history

The first accepted P1 cohort uses Arc 1.172.2 (90755) on the M5 AW2726DM,
2560×1440, 1×, 240 Hz. Arc is fixed at 7.0. The overall covers only the
measured Phase 1 categories (weight 57/100); its Phase 2 categories were unmeasured.
Core rows have seven matched pairs, Speedometer and JetStream three each,
and MotionMark five after Open’s first-three spread exceeded 5%. Disk retains
seven measurements against a required minimum of one.

The pinned Open build predates PR 308. Its idle rows may include Chromium’s
sampling profiler thread; this cohort does not establish that cause. The
lead ordered a current-main idle/launch re-measure before Phase 2; its eight
rows are included in the P2 build mix below.
Negative-control coverage is incomplete and is disclosed in the P1 report.
Earlier self-update/display interruptions and preparation runs are excluded.

| Date | Open commit | Interaction | Smoothness | Launch | Memory | Idle CPU/energy | Page load | Web benchmarks | Resume | Disk | Overall |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026-11-11 (P1, corrected) | `1593ece6f92a50feac5b44cc5a5b5c1161f900fd` | — | — | 8.3 | 7.7 | 6.9 | 7.0 | 5.6 | — | 8.4 | 7.4 |
| 2026-11-11 (P2, recorded build mix) | `efeb350c4c89a698726e4271c657247a8f76a445` | 9.6 | 9.0 | 8.3 | 7.6 | 7.0 | 7.0 | 5.6 | 7.6 | 8.4 | 8.2 |

LEAD 01:35 correction: category contributions are bounded to [0.5, 2.0].
The original raw overall was 7.8; the corrected clamped headline is 7.4.

P2 has 63 scored rows, a clamped overall of 8.2 and raw overall of 8.8.
The 33 new rows have seven matched pairs each. They and the eight main-delta
rows use `efeb350c`; the remaining 22 Phase 1 rows retain `1593ece6`.
The main delta retains its approved original app hash; all scored Phase 2
rows use the corrected automation adapter, with both hashes in the report.
Smoothness uses the shared 8.3 ms detector limit. These scores do not prove
architecture-budget acceptance or continuous 240 Hz frame delivery.
