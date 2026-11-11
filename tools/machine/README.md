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

Each machine has one FIFO build slot. Wrap every build and gate command:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh
```

Nested heavy.sh calls use the outer slot. On the M5, the script also holds
P's quiet lock during the command. Do not acquire that lock separately for
new builds. The default lock paths are machine-local. Do not override them
to bypass the shared queue.

Every on-screen suite separately holds the screen slot, through cleanup:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only shell --style chrome
```

Keep at most one waiting screen command per agent per machine. A normal build
and screen suite may overlap. A strict timing measurement takes both slots,
always in this order:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock <measurement-command>
```

The full gate keeps its one build slot and takes the screen lock once per
native check or real-App suite. Release the screen lock between suites.
Do not hold either slot while thinking or waiting for user input. Keep the
M1's compile cap at 6 of its 8 cores. Report queue waits over 10 minutes and
dead-looking holders to the lead. Never stop or adopt another agent's job.
