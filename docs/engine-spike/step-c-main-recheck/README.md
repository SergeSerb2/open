# Step C main-merge verification

The final locked matrix uses source `342800c`, main merged through `a962f39`,
the default fork, and Chrome hosting. See [final-summary.md](final-summary.md)
for every repetition, timing miss, interrupted attempt, comparison and verifier
row. Each on-screen invocation holds the shared lock for its own launch/cleanup.
Builds and offscreen checks do not hold it. Source receipts precede the later
commit that records these results.

`native-focus-negative-control-summary.json` verifies the interruption policy
against two owned real Open processes. Its three deliberately interrupted native
keyboard attempts are expected control results, not three accepted suite passes.
The ordinary matrix is separate.

`focus-readiness-unresolved.json` records one genuine final Release actions
readiness failure and 80 additional real-app diagnostic cycles. Its cause is
unconfirmed; it remains FAIL and is not cleared by later passes.

History stays separate and keeps its original failures and source revisions:

- `focus-capture-causes.json`: raw executable versus bundle launch, constrained
  capture-size control, and the pre-fix native/renderer focus mismatch.
- `before-motion-ack/`, `interrupted-display-hold/`, `resumed-before-hover-fix/`:
  original focus/hover/capture failures and the lead-requested display hold.
- `foreground-trace-before-isolation/`: native resignation traces during hover.
- `pointer-isolation-before-background-check/`: first tagged-pointer isolation run.
- `pre-b5f3034/`: partial matrix before the next required main merge.
- `post-b5f3034/`: complete earlier 30-run matrix. It retains one engine code-4
  fullscreen failure, two Widevine download misses, command-bar latency misses,
  launch-budget misses and foreground interruptions. Those are not erased by
  later passing runs.
- `pre-shared-lock-b4b8817/`: three Debug repetitions before the machine-wide
  lock rule. An exhausted actions workflow and an interrupted shell retry remain
  INTERRUPTED. No Release acceptance is claimed for this partial phase.
- `native-focus-control-deactivate-*`: failed diagnostic method; NSApp.deactivate
  did not produce the required handoff. The final cooperative owned-peer control
  replaces that method without treating its failure as a product pass.
- `fullscreen-diagnostic-summary.json`: additional real fullscreen cycles after
  the earlier code-4 failure. They passed, but its underlying engine lifetime
  cause remains unconfirmed.
- `diagnostic-*.png` and `diagnostic-actions-debug.json`: early synthetic Open
  fixtures; diagnostic evidence, not the final acceptance matrix.

Only Open's own synthetic-fixture screenshots are published. Arc pixels,
snapshot content and comparison images remain private under `.re/`; only numeric
comparison tables leave that directory. No unit tests or system desktop input.
