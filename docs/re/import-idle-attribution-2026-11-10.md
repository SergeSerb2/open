# Import idle CPU attribution, 2026-11-10

The real Release `import-robust` flow failed `idle_after_import` on quiet M1
samples at source `06f5139e286fe86d17f3a9c9533d17930401c2d6`. The limit remains
less than 1% of one core. The engine distribution was
`891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`.

## Quiet samples and thread counters

Every sample held the machine's FIFO build slot and screen lock. Load1 was
read twice, ten seconds apart, before launch. Foreign CPU excludes the owned
Open tree, WindowServer, and harness. The after-row reading precedes App
cleanup; the separate after-cleanup reading is retained in the raw receipt.
No low-load condition was applied after the run. The user's background jobs
were left untouched.

| Run | Before load1 | Foreign CPU before / after row | App CPU | Result |
|---|---|---|---|---|
| R2 | 2.3667 / 2.0757 | 17.9% / 23.4% | 3.585% | FAIL |
| R3 | 2.7275 / 2.6089 | 35.9% / 27.9% | 3.161% | FAIL |
| R4 | 2.7793 / 2.5854 | 30.5% / 83.0% | 3.357% | FAIL |

History import was 989.9 ms in R2 against 1400 ms; maximum main-thread lag was
29.4 ms against 50 ms. Both passed. Store files and save counters stayed
unchanged, and `watchdogActive` was zero. Cleanup passed without a new crash
or system dialog. After-cleanup foreign CPU was 120.2%, 129.9%, and 209.6%
respectively; these are separate from the readings at the idle-row boundary.

R3 used read-only OS counters around the existing five-second measurement.
`proc_pid_rusage` measured Open PID 37920 at 3.019% over 5.062 seconds.
`proc_pidinfo(PROC_PIDLISTTHREADS/PROC_PIDTHREADINFO)` attributed 1.904% to
`CrBrowserMain` and 0.355% to Chromium's `StackSamplingProfiler` thread.
Helpers used 0.721%, 0.267%, and 0%; the existing assertion measures only
the App/browser PID. No debugger or sampling-profiler command was run.

## The measured fixture was still animating Welcome

The native automation state immediately after R4's original failed row
reported Welcome visible, `animating=true`, `playlist=playing`, six layer
animations, and a pending completion timer. First run and import were done.
The sleep controller was not prepared or started.

Source evidence: `App/Welcome/WelcomePageView.swift`, `duration`, `play`, and
`setVisible`. Each card takes 8.5 seconds; the four-card playlist can therefore
still run during a check that starts ten seconds after a quick import.
`tools/e2e/import_robust.py` starts fresh, opens Settings, imports, then waits
ten seconds. That does not establish an idle Welcome fixture.

A diagnostic R5 selected a blank tab before the same import. Welcome then
reported hidden, stopped, no pending completion, and zero animations. App
CPU fell to 1.384%, still FAIL. OS counters attributed only 0.102% to
`CrBrowserMain`; `StackSamplingProfiler` used 0.403%, and an unnamed worker
used 0.347%. This control also starts Chromium pages and the sleep controller,
so it does not establish steady idle or a production fix.

R6 switched pages within one process after the original row failed at 3.356%.
The first new blank page cost 4.546% while starting. Showing Welcome again
cost 2.656%, including 1.379% on `CrBrowserMain`; hiding it again cost 0.681%,
including 0.088% on `CrBrowserMain`. The native state confirmed animations
running only for the Welcome phase. This attributes a substantial part of
the original main-thread cost to the active Welcome surface. It does not
attribute every unnamed worker or prove an engine CPU regression.

All original failures remain in the private receipts under
`.re/gate-health/quiet-import-06f5139e-r{2,3,4,5,6}/` on the M1. Private
wrappers add counters and diagnostic controls; they do not change the row's
predicate.

## Completed-Welcome diagnostic control

R7's first completion probe observed a stopped state before Welcome's first
frame; it did not establish a completed fixture and still failed. R8 required
all four native completions before starting import. It waited 34.261 seconds
before import, then retained the ten-second post-import settle, five-second
CPU interval, and less-than-1% limit. The row passed at 0.395% App CPU; OS
counters independently measured 0.444%. Welcome remained visible with four
completions, zero animations, and no pending timer. Before load1 was
2.1567 / 2.1997, foreign CPU was 26.6% / 37.6% before / after row, and the
separate after-cleanup reading was 139.4%. Cleanup passed without a new
crash or system dialog.

LEAD21:00 rules that the original valid failures are a product regression.
The completed-Welcome control is diagnostic only. The production gate keeps
its original flow, wait, CPU interval, and failing predicate. A proposed
pre-import completion precondition was withdrawn before qualification.
The next step is the requested main-merge bisection, beginning with
`44b19f3d` and `b0ebbacf`, plus attribution of Release profiler startup.
