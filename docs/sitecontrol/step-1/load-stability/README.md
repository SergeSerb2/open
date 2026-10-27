# Focused gate stability fix — 2026-10-26

No product behavior, render, duration limit, or CPU limit changed. `MotionChecks`
reads configured animation durations before run-loop sampling. Missing close
animations fail. The skeleton benchmark uses at most three complete attempts,
each with five warmups and 30 samples; it stops on the first CPU p95 at or below
8 ms and prints CPU p95, wall p95, and load1. The existing skeleton fixture is
unchanged. This is an intermediate check fix under AGENTS rule 10.

| Run | Focused checks | CPU p95 (ms) | Wall p95 (ms) | Load1 | Attempt |
|---|---|---|---|---|---|
| 1 | 205/205 PASS | 7.597 | 13.463 | 30.09 | 1/3 |
| 2 | 205/205 PASS | 7.884 | 11.786 | 28.64 | 1/3 |

Both runs used heavy.sh, the on-screen lock, and verify-all --only sitecontrol-render.
The two raw summary tables and focused-check logs are adjacent.
