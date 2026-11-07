# Window material performance measurements

`tools/verification/window-material-perf.py` drives the real Release app through
its automation socket. Build with `OPEN_AUTOMATION=1`. The opt-in
`window-material-probe` command adds a bounded `CADisplayLink` sampler. It reads
the real sidebar layer's presentation offset once per callback and records both
callback time and display timestamps. It requests the screen's maximum refresh
rate. No sampler starts in a normal app flow, and this code is absent from
non-automation builds. `stop` invalidates the link and removes its notification
observers. The sampler also stops after 60 seconds or 20,000 callbacks.

For comparisons, apply exactly the same automation hook to both source commits,
build each in Release, and preserve each `.app` before changing the checkout.
Build `sidebar-render` in Release at each commit too. Compare the embedded CEF
hashes. Keep source commits, hook hashes, build logs, and run receipts together.

Run one invocation per build in alternating order:

```sh
tools/verification/window-material-perf-lock.sh \
  --bundle /absolute/path/to/preserved/Open.app \
  --bench /absolute/path/to/preserved/sidebar-render \
  --probe /absolute/path/to/idle-probe.dylib \
  --label main-1 --out /absolute/path/to/receipt-directory
```

Compile `tools/verification/feature-idle-probe.m` with `-DOPEN_APP_TIMER_PROBE`,
using its existing AppKit, QuartzCore, CoreVideo, ARC, and blocks flags. The
wrapper takes the quiet lock, a heavy slot, then the on-screen lock. It waits
outside the screen lock for the priority marker and tries for load1 <=12 for
up to two minutes. A run above that load is busy-machine evidence. It cannot
establish quiet-machine acceptance. The caller must not build concurrently.

Each run uses fresh synthetic data and local static dark-band and white pages.
It measures 20 reveal/hide cycles on each page, five seconds of shown idle and
hidden idle, and 20 key changes between two owned windows. It then quits its App
and runs the existing 1,000-row sidebar bench at scale 2. It retains CPU, GPU,
load, presentation samples, activation events, snapshots, and cleanup evidence.
Foreground loss invalidates the whole attempt. Keep interrupted receipts and
rerun from a fresh profile. Stop on a crash or a no-space error.

`--only scroll` runs only the preserved native sidebar bench, with the same
locks and per-run loads, without starting Open. `--only activation` skips the
motion and idle phases but retains the real two-window activation phase,
cleanup, and final sidebar bench. For synchronous key updates, the runner
arms the field-count baseline before each focus request; otherwise a rebuild
before the key observer runs could be missed. Apply this revised hook to both
comparison builds. It still observes the first later display callback, not
Core Animation transaction completion or GPU presentation.

The sampler measures callback pacing and presentation-layer values, not actual
GPU-presented frames. It has overhead, as do socket polling and idle observers;
use the same instrumentation on both builds. A field rebuild is first observed
on a sampler callback, so key-to-rebuild timing is an upper bound with about
one actual callback interval of observation uncertainty. Callback gaps can grow
during key changes, even with a fixed preferred frame rate. The summary reports
the observed gap and the width of each commit observation interval: the previous
callback with unchanged field counts is its lower bound, and the first changed
count is its upper bound. This does not directly time the theme's commit call.
A snapshot is taken only after
that observation, because snapshot preparation can force a pending rebuild.
No timing hook was added to the theme implementation itself.

The idle observer covers view/layer events and schedulers within its existing
attribution rules; it does not prove that the entire engine or OS has no timers.
Field rebuild counts must also stay unchanged. `ps %cpu` is a decayed process
reading; CPU-time differences over the sampled rest interval are a separate
measure. GPU and WindowServer counters cover the whole desktop and cannot be
attributed to Open alone. The sidebar bench measures native offscreen layout and
display submission, not physical display presentation.

The shared idle observer now checks `CFRunLoopCopyAllModes` for null before it
reads or releases the returned array. A failed query increments the overflow
channel, so it cannot appear as a successful zero-work observation.
