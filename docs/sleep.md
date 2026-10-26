# OpenSleep S0

S0 implements the Swift data and policy layer from
[`plans/memory-fork.md`](plans/memory-fork.md), including its lead appendix.
`OpenSleep` depends only on `OpenModel`. The app will supply the engine and
store adapters in S6. S1–S6, CEF APIs, Chromium patches, switches, and app
wiring remain outside this change. The CEF patch series is empty.

`TabLiveState` holds runtime sleep phase, capture/PiP, DevTools, and form
protection. Only the per-profile `sleepMode` is added to the JSON snapshot.
Schema version remains 1; `TabDTO` is unchanged. Old profile settings without
a sleep mode load as balanced. Quiet pinned tabs and favorites sleep like
other tabs. Pin state alone does not protect them.

`SleepStore` writes opaque history containers and sidecars to
`State/sleep.sqlite3` on one utility queue. It uses the existing SQLite
helper and WAL settings. Over-cap writes and database errors reach
`onError` on the main actor. A failed write keeps any prior row. Archive
close retains the history row for later restore.

The Swift `SleepHistoryContainer` implements the OPNH v1 packing contract:
little-endian header and lengths, 1–512 entries, valid current index, known
flags, zero reserved bytes, exact lengths, and a 2 MiB total cap. It does
not parse Chromium pickles. Its capture helper retries by rebuilding the
entries without page state when the first container exceeds the cap. A
second over-cap result fails capture; the controller keeps the tab frozen.
The future OpenEngine bridge must enforce the same contract at the CEF
boundary.

The controller uses explicit app visibility hooks after model selection
changes. The tick computes protection from current window selections and
all panes of each selected split. It refreshes unload flags and processes
tabs oldest first, with one timed transition per tab per tick. One global
5-second task and one OS memory-pressure source start and stop together.
Warning pressure uses the normal capture/save/discard path on eligible
frozen tabs, without waiting for the mode delay. Critical pressure also
destroys eligible sleeping content and calls the engine pressure hook.
Async discard completion rechecks current visibility and engine discard
state. Quit capture includes all live/frozen split panes. With no trusted
cheap entry-count callback yet, it takes the plan's “when in doubt,
capture” path rather than skipping a potentially changed history.

## CLI verification

All checks below ran on 2026-10-25 (America/Vancouver), on the release CLI.
No unit tests, desktop automation, Arc launch, or engine-tree access ran.
All builds used exactly this command in `Packages/OpenKit`, in separate
process sessions:

```sh
nice -n 10 swift build -c release -j 6
```

The final build had zero warnings and zero errors. Development builds
first exposed actor-isolation and async-expression compiler errors; both
were fixed before the successful runs below.

```sh
Packages/OpenKit/.build/release/openkit sleep-demo /tmp/open-sleep-demo-NEW
Packages/OpenKit/.build/release/openkit sleep-sim DIR_WITH_IMPORTED_SNAPSHOT
```

`sleep-demo` requires an empty output directory and writes synthetic data
there. It exercises the real BrowserModel, policy, controller, SQLite
store, and snapshot mapper. Only the engine boundary and clock are
simulated. It records engine/store call order, restore arguments, and
pressure effects. Its OPNH payloads are synthetic opaque bytes, not CEF
pickles. `sleep-sim` loads a real snapshot, changes runtime state only in
memory, writes a temporary SleepStore, prints counts only, and removes
that temporary store on exit. It does not save over its input snapshot.

| Check | Observed result |
|---|---|
| `sleep-demo` | 62 checks passed, 0 failed; exit 0 |
| Timing | Freeze at 30 s; discard at 900/300/120 s; off freezes without timed discard; destroy at 24 h after discard |
| Never-sleep gates | Visible, audible, loading, capturing, PiP, DevTools, and downloading block freeze and debug discard |
| Grace periods | Audio protected for 60 s after stop; loading for 10 s after completion; form proxy for 300 s |
| Discard-only gates | Unload/form allow freeze and block discard; refreshed unload state permits later discard |
| Ownership | Per-profile modes apply to nested pinned tabs and favorites; selected split panes and other windows stay protected |
| Engine ordering and failures | Capture → save → discard; capture/discard/freeze failures preserve phase; false completion cannot claim discard |
| Pressure injection | Warning discards two eligible frozen tabs oldest first, including off mode; visible/audio/capture gates hold. Critical destroys those two sleeping shells and calls the engine hook |
| Wake | Retained shell reload waits for commit; destroyed wake restores both navigation directions; unfreeze and destroyed wake logs emitted |
| Storage | Equal-field round-trip, reload through a second SQLite connection, single/batch delete, missing read, all IDs and byte total pass |
| Container cap | Exactly 2,097,152 bytes stored intact; 2,097,153-byte write rejected and logged, prior row retained |
| Capture retry | Over-cap default capture rebuilds without page state and sleeps; a still-over-cap retry leaves the tab frozen |
| Corrupt blob | Flipped OPNH magic stored in SQLite; destroyed wake rejects it, retries once with the sidecar URL despite a stale snapshot URL, disables Back/Forward, logs `sleep-restore-fallback` |
| OPNH validation | Bad magic/version/count/index/flags/reserved bytes/lengths, truncation, zero entry length, and trailing bytes rejected as a whole |
| Snapshot compatibility | Committed synthetic pre-change schema-1 fixture loads as balanced; save/reload prints `roundtrip OK`; all four modes persist |
| Split quit/close | Both panes captured at quit; archive close keeps the stored row |
| Async selection race | Selection during delayed discard completion recovers visible content and leaves phase live |
| Failure handling | Real invalid filesystem root calls `onError` without crashing |

Expected stderr from the intentional failure cases:

```text
SleepStore: container exceeds 2 MiB; write dropped
SleepStore: save failed
SleepStore: read failed
```

## Imported snapshot: 48 simulated hours

The input was imported from a private temporary copy of the 15 top-level
`*.json` files in `~/Library/Application Support/Arc`. The original files
were read only. Import output and snapshot contents remain outside the
repository. This report contains counts only.

Import accounted for all 46 items: 35 imported sidebar items, 2 skipped
welcome items, and 9 structural containers. The
model held 1 profile, 4 Spaces, 33 tabs, and a split with 2 panes. The
archive import stored 9 tabs from 10 entries; 1 easel was skipped.

Balanced mode ran over that imported model with a fake clock. One tab was
visible. Five distinct hidden tabs received runtime protection: audible,
capturing, PiP, DevTools, and downloading. These states were assigned for
the simulation; the import does not prove live engine media callbacks.
All other 27 tabs were quiet, including pinned tabs and favorites.

```text
sleep-sim imported snapshot: profiles=1 spaces=4 tabs=33 splitPanes=2
runtime assignments: visible=1 audible=1 capturing=1 PiP=1 DevTools=1 downloading=1
t=0s live=33 frozen=0 sleeping=0 destroyed=0
t=30s live=6 frozen=27 sleeping=0 destroyed=0
t=300s live=6 frozen=0 sleeping=27 destroyed=0
t=86700s live=6 frozen=0 sleeping=27 destroyed=27
t=172800s live=6 frozen=0 sleeping=27 destroyed=27
48h checks: never-sleep gates=OK quiet freeze-discard-destroy=OK storedRows=27 bytes=1512
```

Destroyed is a subset of sleeping: model phase stays sleeping while the
controller removes engine content. The 1,512 bytes are synthetic simulation
blobs, not a measurement of real Chromium histories or renderer memory.

## Performance and existing CLIs

Release policy scan over 5,000 tabs: p50 **0.658 ms**, p95 **0.871 ms**,
maximum **1.113 ms**; all 100 measured scans were below 2 ms.

The performance command runs 101 scans and drops the first warm-up scan.
Each measured scan sends all 5,000 real Tab objects through the pure policy
with a fixed clock and a visible set. The budget check uses the maximum
of the remaining 100 samples. It measures policy decisions; it excludes
engine work, SQLite I/O, and native wake/paint time.

| Existing command | Result |
|---|---|
| `import-arc` on temporary JSON copy | PASS; sidebar and archive accounted checks OK |
| `roundtrip` on that import | `roundtrip OK` |
| `commands-demo` on fresh directory | 66/66, 0 failed |
| `commands-demo` on imported snapshot copy | 66/66, 0 failed |
| `suggest-check` | 31/31 passed |
| `commands-dump` | OK; missing=0, extra=0, different=0 |
| Route A1–A11 | PASS, plus usage, empty-state, source, prefix, and failure paths |
| Route A12–A17 | PASS: IPv6 35, IDN 48, migration 3, ports 11, bare authorities 4, stale-rule defaults 6 CLI decisions |
| Dependency boundary | All three OpenSleep files import Foundation and OpenModel only |
| CEF patch series | Zero bytes |

The route replay used the existing temporary CLI drivers with a fresh
imported fixture. One driver had a case mismatch in its documentation
assertion (`PR` compared with lowercased text); only the temporary driver
was corrected before the full replay passed. No routing source changed.

The five HTML fixtures served over loopback with HTTP 200 for every file.
Port 8765 was already occupied, so this check used 18765 and stopped its
server afterward. Their default future invocation remains:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Engine/fork/verification/fixtures
```

This is S0 acceptance. Native freeze, real capture/PiP callbacks, actual
EXCLUDE_PAGE_STATE serialization, Chromium history/scroll/form restoration,
`document.wasDiscarded`, renderer/RSS scaling, idle CPU, and wake p50/p95
remain unverified until the engine and app steps. The fixtures are ready
for those checks. The existing routing and scripting targets were kept;
the plan's earlier target inventory predates them.
