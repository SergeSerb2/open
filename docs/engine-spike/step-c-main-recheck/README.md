# Step C main-merge diagnostics — display hold

These are diagnostic attempts, not the requested completed three-run acceptance matrix.
The lead held on-screen Open runs at 09:58 on 2026-10-26 (America/Vancouver).
No automatic resume is authorized. See `run-state.json`.

- `focus-capture-causes.json`: real-app raw-launch vs bundle-launch native states,
  capture size negative control, and the pre-fix native/renderer focus mismatch.
- `diagnostic-actions-debug.json`: 45/45 checks after the command-bar navigation
  focus fix, before the final pointer/PID/cleanup changes. Fork / Chrome.
- `before-motion-ack/`: first diagnostic matrix; retains the first hide/reveal
  failure and subsequent passing run. Debug only. Not three complete repetitions.
- `interrupted-display-hold/`: partial second attempt. Key-focus/hover failures
  remain failures. The features session was interrupted and has no complete receipt.
- `diagnostic-*.png`: Open's own synthetic-fixture windows captured before the
  display hold. They are diagnostic screenshots, not final acceptance screenshots.

Later foreground failures are not cleared by the earlier 45/45 run. Native motion
acknowledgement did not establish a complete fix: its first subsequent window
attempt still failed hide/reveal and reported appActive=false/keyWindow=0. Exact-PID
activation, app-PID cleanup and worktree-private data roots need the resumed run.

The interrupted supervisors left two own Open processes. Both were identified by
socket-reported PID and closed through those sockets. The next supervisor records
stop requests and waits for the current child instead of interrupting subprocess.run.

The final required matrix remains: window, sidebar, shell, features and actions,
three repetitions each, Debug and Release, default fork and production Chrome hosting.
Every attempt must remain recorded. Durable profile-storage BLOCKED rows and Debug
Release-only timing SKIPs must remain explicit.
