# OpenSleep S0

S0 implements the Swift data and policy layer from
[`plans/memory-fork.md`](plans/memory-fork.md), including its lead appendix.
`OpenSleep` depends only on `OpenModel`. The app will supply the engine and
store adapters in S6. S1–S6, CEF APIs, Chromium patches, switches, and app
wiring remain outside this change. The CEF patch series has no active
patches; main now supplies its comment header.

`TabLiveState` holds runtime sleep phase, capture/PiP, DevTools, and form
protection. Per-profile `sleepMode` and `keepAliveSites` live in the JSON snapshot.
Schema version remains 1; `TabDTO` is unchanged. Old profile settings without
a sleep mode load as balanced. Quiet pinned tabs and favorites sleep like
other tabs. Pin state alone does not protect them.

`SleepStore` writes opaque history containers and sidecars to
`Profiles/<dataDirectoryName>/State/sleep.sqlite3` through `ProfileDirectories`,
with one utility queue per Profile. `SleepStore(fileURL:)` takes that explicit
path. Call `OpenDataRoot.prepare()` before any store opens and retain its
preparation token until the operation finishes. It uses the existing SQLite
helper with WAL, `synchronous=FULL`, and a five-second SQLite busy timeout.
`save` and `flush` are async and throwing. Each returns after a real
transaction commit. Over-cap writes and database errors reach `onError`
on the main actor and throw to the caller. A failed write keeps any prior
row. Archive close retains the history row for later restore. Permanent
delete and archive purge must call `controller.tabPurged(tabID:)` in S6;
that path destroys content and deletes its stored history.

The Swift `SleepHistoryContainer` implements the OPNH v1 packing contract:
little-endian header and lengths, 1–512 entries, valid current index, known
flags, zero reserved bytes, exact lengths, and a 2 MiB total cap. It does
not parse Chromium pickles. Its capture helper retries by rebuilding the
entries without page state when the first container exceeds the cap. A
second over-cap result fails capture; the controller keeps the tab frozen.
The future OpenEngine bridge must enforce the same contract at the CEF
boundary.

The app must supply `SleepVisibilityProviding`. Each pass reads one snapshot
with per-window visible/minimized/occluded/closed state plus actual tabs
shown in Peek, Little Open, split panes, and PiP. Missing/closed windows
contribute no selection. Every pane in a selected split of a visible
window counts as visible. Extra surface sets contain only actually shown
tabs; PiP protects a tab even when its parent window is minimized.

The app calls visibility hooks immediately after selection/window/surface
changes. The pass also reconciles snapshot changes. `tabBecameHidden`
records `hiddenAt`; showing clears it. Freeze/discard ages use hide time.
Only tabs never shown this session fall back to persisted `lastActiveAt`.
Model split selection and focus stamp every pane's activity time.

One global five-second task and one OS memory-pressure source start and
stop together. Each pass builds profile policies once. Tab ownership uses
the model index/parent map, memoized by the model's structural revision;
normal ticks do not walk each tab's ancestors. Unload queries run in stable
round-robin order, capped at 32 per pass. Unknown unload state blocks
discard until queried or supplied by an event. Action plans are made before
execution; critical pressure snapshots sleeping tabs at pass entry, before
any async restore. It destroys only those tabs, after current visibility
is checked. A tab gets at most one phase transition in that pass.
Warning pressure skips the mode delay for eligible frozen tabs. Critical
pressure also calls the engine pressure hook. Both honor protection and
retry backoff. Failed capture/save/discard or false discard completion
backs off for 30, 60, 120 seconds, doubling to a 30-minute cap. Success or
`tabUserInteracted` resets it.

Discard awaits a committed save before renderer release. After an async
save or engine operation, current visibility is rechecked for races;
these necessary checks are in addition to the single pass snapshot.
`captureAllForQuit() async throws` awaits all live/frozen captures, their
saves, and `flush`. S6 must await it before completing quit and handle
storage errors. Quit capture includes all live split panes. There is no
trusted cheap entry-count callback yet, so it captures each eligible tab.

**Hard S6 adapter contract:** call `tabDidCommit` and `tabAudioChanged`
for every tab event, including background events that begin and end
between ticks. Deliver capture, PiP, download, loading, DevTools, form,
and unload-handler changes on every event. Report user interaction and
visibility transitions immediately. Sampling alone is forbidden. The
contract is also on the `SleepEngine` protocol in source. S0 CLI checks
exercise these callbacks; live engine delivery remains an S6 gate.

## App wiring (S6, app-shell Step G)

PR G1 runs the controller in the App on the stock engine API. Files:
`App/Sleep/AppSleepCoordinator.swift` (one controller, events, quit capture,
Battery Saver), `App/Sleep/RoutingSleepStore.swift` (one `SleepStore` per
Profile), `App/WebContent/EngineSleepAdapter.swift` (`SleepEngine` over the
window factories' existing hosts; never a second page per tab), and
`App/Automation/AutomationSleep.swift` (automation builds only).

- Start: the controller is built and started after the first web paint
  (startup T5; `LaunchTiming` mark `sleepStarted`), or 2 s after the first
  load when no paint is reported. Hooks before that are no-ops; the
  controller's init reads the phases the windows already set.
- No idle polling: a live hidden tab uses the five-second pass while it can
  change phase. Frozen tabs wait for their discard deadline, extended by any
  audio, load, form or retry grace deadline. It parks when every hidden tab
  with content waits for an event (keep-alive, notifications, audio, loading, capture, DevTools,
  downloads, a known unload handler on a frozen page, a frozen page in off
  mode). Sleeping shells schedule one pass at their 24 h destroy time. Every
  event hook and `setNeedsPass()` (mode, permission, Low Power Mode changes)
  brings a pass forward within five seconds. The real-App
  `sleep_frozen_deadline` check proves the scheduled policy delay is greater
  than five seconds with 270 seconds left before balanced discard; it fails
  on the previous implementation. See [idle CPU](idle-cpu.md).
- Events: every page change of every sidebar tab, background tabs included
  (`EngineWebContentHost` → `AppSleepCoordinator.pageChanged`): URL commit
  (`Tab.url` first, then `tabDidCommit`), load end (`tabDidCommit`, the 10 s
  loading grace), audio (`tabAudioChanged`), camera/microphone capture
  (`isCapturing`), DevTools (`devToolsOpen`). Downloads per page; keys typed
  into a page set the form proxy; page creation and close from the window
  factories; window, selection, split, Peek, PiP and mini-player changes
  through `AppVisibilityProvider` (Section 3's media feed fills
  `pictureInPicture` and `mediaControls`).
- Notification gate (page-platform §4.5.6): `.notifications` comes right
  after `.keepAlive`. `TabLiveState.notificationsAllowed` refreshes on every
  commit and every permission change made through Open (prompt answer, Site
  Control adapter, automation). It blocks freeze, timed discard, warning
  pressure and debug sleep; critical pressure may freeze and discard such a
  page (Chrome parity).
- Battery Saver: macOS Low Power Mode (`NSProcessInfoPowerStateDidChange`, no
  polling) makes Automatic (balanced) act as Aggressive; other modes keep
  their delays. A change while Open runs shows "Battery Saver Mode
  Activated" / "Battery Saver Mode Deactivated".
- `chrome.tabs.discard` of a hosted tab runs debug sleep and honors every
  gate; the visible tab and protected tabs are refused.
- The window's hidden-host cache (8 per window) skips pages a gate protects,
  so keep-alive and audible pages are not closed by the cap.
- Quit: `applicationShouldTerminate` answers cancel once, awaits
  `captureAllForQuit()` (bounded at 3 s; a save error is logged and quit goes
  on), then terminates again: snapshot save, archive flush, engine shutdown.

Stock fallbacks, each marked `// Until P-MEM-0x` for PR G2: discard closes
the page (the renderer exits; the wake creates a page and loads the URL);
freeze records the phase only (a hidden view is already throttled);
`setVisible` does nothing (the container owns the view); capture returns a
minimal one-entry container with the current URL and no page state, because
a nil capture keeps every tab frozen forever; `hasUnloadHandlers` is false.

## Keep-alive sites

The `keepAlive` never-sleep gate blocks **freeze and discard**, including
debug sleep and memory-pressure discard. The built-in table is
`OpenSleep/Resources/keep-alive-sites.json`. It uses Open's own host
suffix and optional path-prefix format, with no copied regex strings.
`x.com` is an Open addition next to Twitter.

Evidence read-only: `/Applications/Arc.app/Contents/Resources/ARC_WebContentBehaviorConfigurationClient.bundle/Contents/Resources/web_content_behavior.json`,
key `keepaliveAllowList` (21 patterns). The translated scopes are:

| Host suffix | Path prefix, if required |
|---|---|
| `twitter.*`, `x.com` | — |
| `app.slack.*` | `/client` |
| `mail.google.*` | `/mail` |
| `calendar.google.*` | `/calendar` |
| `notion.so`, `app.notion.com` | — |
| `dropbox.*`, `aws.amazon.*`, `open.spotify.*` | — |
| `linear.app`, `instagram.*`, `messenger.*`, `facebook.*`, `web.whatsapp.*`, `sentry.io` | — |
| `figma.*` | `/file/` |
| `docs.google.*` | `/document`, `/presentation`, `/spreadsheets` (three rules) |
| `outlook.live.*` | `/mail`, `/calendar` (two rules) |

Only the hosts with variable TLDs in that evidence use `*`. It consumes
one or more trailing labels, so `mail.google.co.uk/mail` matches.
Fixed suffixes such as `notion.so`, `app.notion.com`, `linear.app`, and
`sentry.io` do not gain a TLD wildcard. Suffix matching includes subdomains
on DNS label boundaries. This covers Arc's optional `www` prefixes and
Notion's `www`, `dev`, and `stg` prefixes; Open's suffix format also accepts
other subdomains. Paths are case-sensitive literal prefixes, including
Figma's trailing slash. Only HTTP and HTTPS URLs match. Gmail outside
`/mail` remains sleepable. Ports, query strings, and fragments do not
change the host/path match.

**Guess:** the evidence does not prove whether Arc's keep-alive list
blocks only discard or also freeze. Open exempts both because frozen
pages miss notifications and socket keepalives ([memory-design §4.2](memory-design.md#42-freezing-background-tabs)).
The same evidence file's `tabSuspensionBlocklist` contains only
`www`/`dev`/`stg.notion.so` and `app.notion.com`, all covered by this gate.

User additions use `ProfileSettings.keepAliveSites`, an array of
`host[/path]` strings, default `[]`, in the browser snapshot. Missing keys
decode as `[]`; values encode unchanged, including empty arrays, like the
other array fields. `BrowserModel.updateProfileSettings(id:settings:)`
edits the list through the existing model and snapshot save path.
The registry is in [settings-library §2](plans/settings-library.md#2-persistence-registry-every-key-no-others-without-a-plan-change)
under per-profile scope, per D-5. User rules extend the built-in list;
invalid entries are ignored for matching. There is no Settings UI in this change.
The Site Control Center plan will add "Keep this site awake" per site.

The shipped table compiles once. Each profile's user rules compile only
when its model array changes. As for `sleepMode`, every controller pass
reads current profile settings independently of the tree revision; a
settings edit refreshes policy on the next tick without a restart.
Each tab caches its match by current URL
and compiled rule identity. URL changes invalidate that match on the next
gate evaluation, including checks after history saves. Adapters must set
`Tab.url` before `tabDidCommit`; normal hide and commit grace times then
apply after navigation away. A navigation to a keep-alive URL during an
awaited engine discard recovers live content and keeps a hidden tab hidden.
No regex runs in a policy evaluation.

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
| `sleep-demo` | 148 checks passed, 0 failed; exit 0 (105 existing checks plus 43 keep-alive checks). Step G (2026-11-02): 172, adding 24 rows for the notification gate, Battery Saver, the audio stop event and the parked pass loop |
| Timing | Freeze at 30 s; discard at 900/300/120 s; off freezes without timed discard; destroy at 24 h after discard |
| Never-sleep gates | Visible, keepAlive, audible, loading, capturing, PiP, DevTools, and downloading block freeze and debug discard |
| Keep-alive scope | All 21 translated service rules plus x.com stay live for 48 simulated hours; Gmail outside `/mail`, excluded paths, fixed-TLD mismatches, and unrelated hosts sleep normally. Subdomains and multiple-label TLDs pass. |
| Keep-alive user rules and navigation | Snapshot-stored user rule stays live; path and profile isolation hold. Model edits invalidate the cache without a restart or tree change; a live tab remains awake for another 48 h. Leaving Gmail freezes at hide+30 s and discards at +300 s. Navigation to Gmail during async discard recovers hidden live content. |
| `openkit roundtrip` keep-alive compatibility | The full-suite runner round-trips a snapshot with `keepAliveSites`, preserving strings unchanged. A snapshot without the key loads with `[]` and saves at schema 1. The CLI prints a keep-alive counts row. |
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
SleepStore: flush failed
```

## PR #29 review findings

| Finding | Fix | CLI result |
|---|---|---|
| 1. Selection-time ages; missing split activity | Record/clear per-tab `hiddenAt`; fallback only for never-shown tabs. Stamp all panes on split selection/focus. | Ten-minute read stays live to hide+29 s, freezes at +30 s, discards at +300 s. Both split panes pass. |
| 2. Critical discard and destroy in one pass | Snapshot sleeping IDs before any async restore; plan each tab's one phase action before execution. | First critical pass retains the newly discarded shell; next pass destroys it. Async restore/selection race also passes. |
| 3. Model selection was the only visibility | Require app-owned window/surface snapshots; reconcile hides/shows. Recheck after async boundaries. | Minimized, occluded, closed and removed windows sleep on hide timers. Peek, Little Open, PiP and shown split panes stay live through time, pressure and debug sleep. |
| 4. Excessive tick cost and engine queries | Cache parent-map ownership by tree revision, group by owner, build policies/visibility once, hold one runtime record per tab, check deadlines before gates, round-robin at most 32 unload queries. | All 67 tabs sampled within 3 passes; unknown state blocks discard; profile move invalidates ownership. Full 5,000-tab/200-pass p95 **1.916 ms**. |
| 5. Quit/discard did not await durable history | Async throwing `save`/`flush`; real SQLite commits with `synchronous=FULL`; save before renderer release. | A real writer lock holds quit/save/flush/discard; release permits completion. A second connection immediately sees the quit row. Save/flush failures reach the caller; failed save prevents discard. |
| 6. Purge leaked history rows | `tabPurged(tabID:)` tears down content and deletes history, including a second delete after an in-flight save. Document mandatory S6 permanent-delete/archive-purge calls. | Undoable close retains history; purge deletes it; purge racing an awaited save cannot resurrect it. |
| 7. Failed discards retried every tick | Per-tab exponential backoff, 30 s through 30 min; reset after success or interaction. | Attempts at 0/30/90/210 s; next 450 s; pressure cannot bypass it. Cap and both resets pass. |
| 8. Event delivery was optional | Hard `SleepEngine` adapter docs require every commit/audio/capture/PiP/download event, plus other protection/visibility changes. | Audio start/stop wholly between ticks retains 60 s grace; a background commit protects for 10 s without sampled loading. Native event wiring remains S6. |

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

The review benchmark measures `await SleepController.tick()` over 5,000
real model tabs for **200 measured passes**, after one warm-up pass. It
includes the app visibility provider, reconciliation, profile policies,
indexed ownership, phase/gate decisions, 32 round-robin engine queries per
pass, transition execution, and any awaited SQLite saves. The engine and
clock are the same CLI simulation used by the functional scenarios.
This is a full controller measurement; native CEF call cost remains an S6
gate. The warm-up includes initial ownership-cache construction and bulk
freeze and is excluded from the percentile sample.

The current gate uses calling-thread CPU time from
`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`, with the same **p95 < 2 ms** budget.
The controller runs on the main actor, so the samples measure its thread's
compute cost across each pass. Wall-time p50/p95/max still print as information;
they include scheduling delays and async commit waits. SQLite queue CPU and
native engine costs are outside this CPU gate. The wall-time results below
are the earlier PR #29 observations, before this clock change.

The keep-alive snapshot-storage update passed the same 5,000-tab/200-pass benchmark:
thread CPU p50 **0.273 ms**, p95 **0.548 ms**, max **0.796 ms**;
wall time p50 **0.283 ms**, p95 **0.698 ms**, max **3.238 ms**.
The release build had zero warnings/errors. Raw full-suite logs are at
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261025-235039.Ck8CR4`.
Native engine sleep and web notification delivery were not exercised by
this library change; the real CLI uses the simulated engine boundary.

The workload has 4 profiles, 12 Spaces, 8 windows (5 visible, 2 minimized,
1 occluded), nested folders, favorites, selected splits, Peek, Little Open,
PiP, and explicit split surfaces. It mixes audible/capturing/loading/DevTools
tabs with quiet tabs. Hidden ages span 40–109 seconds, with twenty older
tabs; protected older tabs stay live. The simulated clock stays fixed so
the 200 passes measure the same scale and phase deadlines. Peek membership
changes each pass. Discard candidates keep the real store path in the
measurement, including durable commit latency.

Final release full-pass result: **p50 0.551 ms, p95 1.916 ms, max
49.722 ms**. The **p95 < 2 ms** budget passed. All 200 samples, including
the maximum, are retained; the budget does not impose a maximum latency.
Across warm-up plus measured passes the engine received 6,432 unload
queries and 15 discards; SQLite held all 15 committed rows. These numbers
include async commit waits; they do not claim native renderer or UI latency.

The first full-pass implementation failed the budget: p50 4.578 ms,
p95 6.207 ms, max 13.235 ms. Consolidating per-tab runtime records and
checking phase deadlines before gates reduced repeated UUID hashing and
runtime reads. Grouping tabs by indexed owner removed per-tab policy-map
lookups. The workload and its durable writes stayed the same.

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
| CEF patch series | No active patches; comment header from main |

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

The PR #29 review update started with `git fetch origin && git merge
origin/main`. Main at `f4f87da` added fork infrastructure, Boosts, and
import targets. The prescribed union script resolved `Package.swift` while
keeping both targets. CLI usage kept both branches' commands. The merged
package built before the review fixes, and the final package built with
the same release command and no warnings/errors. No Chromium build or
shared engine-tree operation ran.

The review requirements supersede the original plan's selection-time clock,
fire-and-forget store seam, model-only visibility, and all-tabs unload
sampling. The lead's phase ladder, mode delays, split-pane quit capture,
Chrome-style requirement, and S0-only scope remain in force.

Final raw CLI receipts (including the failed performance iterations) are
outside the repository at
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-sleep-pr29-review-f32uvocn`.
`sleep-demo-final.stdout` records 105/105 and the 200-pass benchmark;
`sleep-sim-final.stdout` records the passing 48-hour run. The routing
receipts include A1–A17. The reused temporary A14 driver again needed its
case-only `PR` assertion corrected to `pr` before comparing lowercased
document text; routing source was unchanged.

Verified final release `openkit` SHA-256:
`098826ae5d70f4f78c8bf331af244f7c150744a82aeda21f485453e967e36f0b`.
