# Machine queues

These are copies of the shared macOS queue scripts installed by the lead on
2026-11-10. Install the same version on each build machine:

```sh
mkdir -p ~/Library/Caches/OpenRE/scripts
install -m 755 tools/machine/heavy.sh tools/machine/queue.sh ~/Library/Caches/OpenRE/scripts/
```

Check the queue before a long job:

```sh
~/Library/Caches/OpenRE/scripts/queue.sh
```

The M5 has three FIFO build slots; the M1 has one. A normal command takes
one slot. Configure a new host with the machine's slot count in
`~/Library/Caches/OpenRE/heavy-slots` (default: 1). Wrap every build and gate command:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh
```

Nested heavy.sh calls use the outer slot. The default lock paths are
machine-local; do not override them to bypass the queue. An exclusive job
takes every slot and retains FIFO order. Use it for measurements:

```sh
OPEN_HEAVY_EXCLUSIVE=1 ~/Library/Caches/OpenRE/scripts/heavy.sh <measurement-command>
```

The strict-timing form below and jobs from the performance worktree are
exclusive automatically. No separate quiet lock is needed.
`OPEN_HEAVY_KIND` is `build` or `exclusive` inside the command.
`/tmp/open-heavy-holder` lists every holder on a separate tab-separated
line: PID, clock, working directory, command, and optional kind. Per-holder
records are also in `/tmp/open-heavy-holders/<pid>`. Read all lines.

Every on-screen suite separately holds the screen slot, through cleanup:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only shell --style chrome
```

Keep at most one waiting screen command per agent per machine. A normal build
and screen suite may overlap. A strict timing measurement takes every build slot and the screen slot,
always in this order:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock <measurement-command>
```

The full gate keeps one normal build slot and takes the screen lock once per
native check or real-App suite. Release the screen lock between suites.
Do not hold either slot while thinking or waiting for user input. Keep the
M1's compile cap at 6 of its 8 cores. Report queue waits over 10 minutes and
dead-looking holders to the lead. Never stop or adopt another agent's job.

A timing or budget failure sampled while another M5 build slot was occupied
is void. Rerun only that row with `OPEN_HEAVY_EXCLUSIVE=1 heavy.sh
tools/verify-all.sh --only ROW`; keep its original budget and both receipts.
