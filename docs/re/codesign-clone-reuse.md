# Persistent code-sign clone

Patch `chromium/0106-open-code-sign-clone-reuse.patch` keeps Chromium's
`MacAppCodeSignClone` enabled. It reuses a valid clone instead of linking and
unlinking the executable on every browser run. This is an engine change; the
App wrapper and its feature switches do not change.

The [unconditional disable](codesign-clone-off.md) was rejected. Its ad-hoc
live-swap test failed signature validation and navigation. Sparkle's normal
host-termination order did not satisfy the stronger live-replacement gate.
That evidence remains applicable to manual or external replacement.

## Why the clone must remain

Chromium's `chrome/browser/mac/code_sign_clone_manager.h` explains the
requirement: a hard link keeps the running executable reachable after a staged
update removes its original path. The surrounding cloned bundle retains the
matching resources for static and dynamic signature validation. In the matching
`.mm`, `CloneApp` uses APFS `clonefile`, removes the clone's quarantine attribute,
then calls `HardLinkMainExecutable`. Its `link()` changes the source executable's
ctime. The original cleanup helper later removes the link, changing ctime again.

Source for this implementation was inspected and changed only in the assigned
`open-engine-s16` root. No other engine root was used. No root tool, interposer
or debugger was used.

## Cache and failure behavior

The overlay is `chrome/browser/mac/open_code_sign_clone.{h,cc}`. The small
manager/BUILD patch calls it before the original per-run path. The cache lives
under the user's Application Support directory at
`Open/CodeSignClones/<SHA-256 of install path>/Application.bundle`. It is
independent of CEF profiles, so temporary profiles do not multiply clones.
Both cache directories have mode 0700 and must belong to the current user.
The lease is a regular, owned, mode-0600 file opened without following symlinks.

The saved identity is the original executable's device, inode, size and mtime
(seconds and nanoseconds), with a version prefix. The metadata read is bounded
at 256 bytes. It accepts only an owned regular file opened without following
symlinks or blocking on a special file. Reuse requires an exact identity match,
the same identity on the
clone's executable, a link count of at least two, and the clone's Info.plist.
ctime is deliberately absent from the key: link creation itself changes it.
The size and mtime fields detect a copy that rewrites the same inode.
Creating the first clone still changes ctime once. The first relaunch can
therefore assess that change. Scan/timing proof must retain that observation,
then measure relaunches after the cached clone and assessment are warm.

A shared file lease stays with the manager through shutdown. Recreation takes
an exclusive lease, deletes the old clone and identity, calls Chromium's
unchanged `CloneApp`, then rechecks the identity before publishing it. There
is one fixed clone slot per install path, rather than a version directory list.
An active old browser's lease prevents deletion of the clone it still needs.
In that case the new browser uses the original per-run path; the next exclusive
owner retires the old slot. This preserves live-update protection during
concurrent launches. No inactive version list is retained.

Failed directory, metadata, identity, lease or recreation checks use Chromium's
original per-run clone and cleanup. They never disable cloning. The cache does
not repair restrictive permissions. This makes an unavailable cache a tested
fallback, rather than a reason to change its owner's permissions.

## Verification record

Evidence is in the project checkout's `.re/s16/codesign-clone-reuse/`.
`root-path-audit.json` records the S16-only state/configuration audit.
`baseline-apply.json` records the baseline apply. `roundtrip.json` compares
SHA-256s of the edited tree files before revert and after `engine-apply`:
all three files match. The new files are authored in the overlay and copied
by apply. The generated patch was read in full.

The main Release control was built before the engine edit from main `cb1add52`
(branch merge `e686f1d4`, with historical docs only). Build: PASS in 133.63 s,
load1 9.17→13.68. Its CEF SHA-256 is
`24d7d6f5e9ee25da0a4a890fe12b73b5fa0c30046c34acd0ce1c7e4c7cb8d6e0`.
This historical build is retained with the earlier evidence. It is not used
by the final timing or live-replacement proofs.

After the restart, the overlay metadata hardening was applied with
`engine-apply --all` (`hardening-apply.json`, exit 0). A focused build of
`open_code_sign_clone.o` and `code_sign_clone_manager.o` passed in 22 seconds
(`changed-objects.json`). The earlier full build was deliberately interrupted
with 30,928 steps done and zero failed; the resumed job keeps those outputs.
The S16 root audit was repeated (`root-path-resume-audit.json`): no s8 path
remains in state, `.gclient`, `args.gn` or `build.ninja`. `engine-status`
reported 7 PASS, 0 FAIL and the existing CEF series-order warning. That status
still refers to the previous distribution; it does not prove the new binary.

At the initial build checkpoint, normal-App runtime verification was pending.
Required rows are stable
ctime/link count across three full runs after priming; seven simple relaunches
without ChangetimeScan; same-inode copy invalidation; two install paths;
live replacement with a reused clone for ad-hoc and temporary hardened DLV
copies; unwritable-cache fallback; seven interleaved launch pairs; window
warm-profile rows; shell/features/updater suites; engine-status and full gate.
No runtime result or performance gain is claimed yet.

### Main engine ordering

Main `d26300e6` (PR #264) is merged into this branch. Its Chromium patches
`0801` through `0810` precede `0106` in the recorded series. The earlier
engine build is allowed to finish, but its engine predates #264 and cannot
qualify the final proof. The matched main control must include #264 without
`0106`; the branch engine must include #264 followed by `0106`. Both are
built in S16. Final runtime rows and engine-status use that rebuilt engine,
followed by the full gate on the merged head.

The earlier full build passed in 1h39m (`engine-build-resume.json`). Next,
`engine-main-264.log` records `0801` through `0810` applying in order with
`0106` excluded. CEF API regeneration and the incremental engine build passed
(856 actions, 2m57s). The S16-built main distribution has SHA-256
`619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`,
which exactly matches main's recorded framework. See
`matched-main-engine.json` for the full series and distribution path.

`app-main-264.json` records the frozen automation Release App control from
merged head `d1f555da`: build PASS in 206.68 s, load1 17.34→39.35, deep strict
signature verification PASS. The App executable has SHA-256
`549c4c442ded786b49181cc7431453ac1c7c999174eee8f7bc3ac575b46b2214`.
Its embedded, re-signed CEF binary has SHA-256
`d18b7b785ae84900d1bf0ec3445e835e0044259780f12a8b0d9193a57d78eaa5`;
this differs from the distribution hash because embedding re-signs the code.

The 14:08 M5 screen hold began before any runtime proof in this series.
No 0106 on-screen row overlapped 14:02. Live replacement, launch timing and
e2e were pending screen clearance at that checkpoint. The branch rebuild follows the main
control build; no gain or runtime safety PASS is claimed from build results.
The final live-swap matrix replaces main with the matched branch build and
branch with matched main. Both include #264 and share its public engine API;
the native difference is `0106`. The harness requires different executable
SHA-256 values and removes the old staging bundle after the directory swap.

### Required acceptance rows on the rebuilt engine

These rows must use the S16 distribution with `0801–0810`, then `0106`.
The previous build, object compilation and patch round trip do not count as
runtime acceptance. The following table records the current state; it claims
no launch gain or live-update safety result.

| Row | Required proof | Current state |
|---|---|---|
| a | Executable ctime and link count stay unchanged for three full runs after the first clone | PASS, normal App; `stability/receipt.json` |
| b | Seven simple relaunches have no attributable ChangetimeScan | FAIL against the 7/7 target; residual first-after-gap scans, cause open. Functional set: 6/7 scan-free, unchanged executable metadata in all seven. No gain claim |
| c | An in-place executable copy keeps the inode but recreates the clone | PASS, normal App; `stability/receipt.json` |
| d | Two install paths use distinct clones with no cross-reuse | PASS, normal App; `stability/receipt.json` |
| e | Live replacement passes with a reused clone in both ad-hoc and temporary hardened DLV builds | Requested ad-hoc path PASS on main and reused-clone branch (fresh renderers/audio utility; GPU retained). Extra forced GPU/network restart control FAIL retained. DLV PENDING M1 clear |
| f | An unwritable cache falls back to a per-run clone and still works | PASS, normal App; full render and helper types; `adhoc-branch-plain-unwritable/receipt.json`. Fallback live swap not run |
| g | Seven interleaved main/branch pairs at load1 ≤ 12, plus window warm-profile rows | PENDING tonight: executable `window-timing.sh`, dry check only. Daytime set retained, no gain claim |
| h | Shell, features, updater and engine-status pass | Shell PASS (7 rows); features PASS (26 rows) with intentional crash row DEFERRED to M1; updater PASS (21 rows); engine-status: 7 PASS, 0 FAIL, 1 order WARN |

The rebuilt branch engine passed. The incremental build took 48 seconds;
its distribution SHA-256 is
`09c1f661ef7c4caba7f51c6314d1fae7eff9c2b110db97fae790b788fb43a38b`.
`branch-engine.json` and `branch-engine-status.json` record the series,
distribution, 7 PASS, 0 FAIL and one numeric-order WARN. The warning records
the required placement of `0106` after `0801–0810`; it is not hidden or
reordered. A packaging retry and a corrected status-report output path are
recorded separately; they did not require a source change or engine rebuild.

`app-branch-264.json` records the Release App build: PASS in 44.46 seconds,
load1 21.64→23.35. The frozen executable SHA-256 is
`af2af579cb7964e3d4f124819115b2b1316cbdb21a23a357ee269e78d2842d01`.
The Debug App build, existing e2e helper compilation, and preparation and
static signature checks of temporary hardened DLV copies also passed
(`build-after-engine.json`). This preparation launched no App or suite.
The lead cleared the M5 in the 16:31 instruction. Normal-App rows and full
`verify-all` may proceed there. The M1 remains held. Hardened DLV launch and
live-swap proof must wait for `M1 clear` and run on the M1 only; the ad-hoc
live-swap matrix is allowed on the M5.

### Supplemental off-screen control

`offscreen-main/receipt.json` records a windowless caller of the real public
OpenEngine startup, message-loop and shutdown API. It uses the matched main
engine `619324d3` in a disposable bundle, with a 55,920-byte caller executable.
The caller creates no browser or native window and uses a temporary profile
and the mock keychain. It keeps `MacAppCodeSignClone` enabled. This is engine
lifecycle evidence; it does not satisfy the normal-App or helper-rendering
rows above.

The main control passed: its original executable retained the same device,
inode, size and mtime, while link count went from 1 to 2 during initialization
and back to 1 after cleanup. Its ctime changed. The caller initialized and
shut down successfully; the AppKit and owned on-screen-window checks found
no windows. No real crash report appeared. All owned processes, temporary
paths and test cache paths were removed. Load1 was 17.17 before the
functional run and 18.28 afterward;
this was not a timing measurement.

### Rebuilt windowless comparison and a retained failure

These runs use the same public-engine caller, not the normal Open executable.
`offscreen-polled/receipt.json` records the completed comparison against
matched main `619324d3` and branch `09c1f661`. A separate process polls stat
at a requested 1 ms interval. The largest observed gap was 3.79 ms. The runs
take the screen lock and create no browser or window.
Load1 was 9.35→12.24; these are functional checks, not launch measurements.

| Check | Windowless result | Evidence |
|---|---|---|
| Matched main negative | ctime changes; link count 1→2→1 | `main-negative.stat-events.json` |
| Branch first clone | ctime changes once; link count 1→2 | `branch-prime.stat-events.json` |
| Three branch reuse runs | All six executable stat fields stay unchanged; link count stays 2; same cached bundle inode | `branch-stable-1` through `branch-stable-3` receipts and stat events |
| Same-inode copy | Device and inode stay fixed, mtime changes, saved identity and clone bundle inode change | `same-inode-copy` receipt and stat events |
| Separate install | Separate cache path and executable inode, no cross-reuse | `second-install` receipt |
| Unwritable cache | Mode stays 0500; per-run diagnostic; link count 1→2→1; startup and shutdown succeed | `unwritable-cache` receipt and stat events |
| Cleanup | No real crash, no visible window, no remaining owned process; owned temporary paths and caches removed | `offscreen-polled/receipt.json` |

The first comparison did **not** pass its stable-ctime assertion. Keep
`offscreen-rebuilt/receipt.json` and its unified log as contrary evidence.
On its second reuse run, ctime changed while the link count remained 2 and
the same cached clone was reused. The recorded order was:

| Local time, 2026-11-08 | Observation |
|---|---|
| 16:17:59.258146691 | Executable's new ctime |
| 16:17:59.269782 | Caller saves `startWall`, before calling `OEEngine.startWithConfiguration` |
| 16:17:59.328922 | Engine logs `Open code-sign clone reused` |

The caller source is `headless-engine.m`; the launch receipt is
`branch-stable-2.engine.json`. This places that change before the engine
startup call and its clone reuse. The collected syspolicyd/AMFI/kernel log
does not identify its writer. Do not attribute it to a specific OS component
or dismiss it as a harness artifact. A separate xattr diagnostic
(`offscreen-xattrs2/receipt.json`) had five unchanged reuse runs and unchanged
executable xattr hashes; the later polled comparison also passed. Neither
result erases the first failure. Normal-App ctime and seven simple-launch
scan rows must still pass, and any recurring pre-engine ctime writer needs
separate attribution before a launch-gain claim.

The initial diagnostic wrapper lacked Python xattr support and stopped before
starting the caller (`offscreen-xattrs/receipt.json`). Its corrected version
uses read-only `/usr/bin/xattr`. No product or engine source changed during
these supplemental checks. No live-swap, helper-rendering, simple-launch scan,
timing, e2e or full-gate acceptance is claimed by this section.

### Harness rule breach and affected receipts

The harness changed a user system setting. That breached the standing rule.
The original receipts below contain `crash_dialogs_restored: true`; the swap
receipts also contain a `crash_dialogs` description. These are wrapper fields,
not independent evidence of system state or dialog behavior. They do not
establish compliant crash protection. The original receipts remain unchanged,
including their failures. No normal-App acceptance is gained from these runs.

All times below are on 2026-11-08 in America/Vancouver (UTC−07:00). They are
the receipt's outer run bounds, not separately measured setting-write times.
Receipt paths are relative to `.re/s16/` in the project checkout.

| Receipt | Start | End | Recorded result |
|---|---|---|---|
| `codesign-clone-off/adhoc-main-plain/receipt.json` | 11:01:23.412 | 11:01:30.787 | PASS |
| `codesign-clone-off/adhoc-branch-plain/receipt.json` | 11:05:42.965 | 11:05:51.014 | PASS |
| `codesign-clone-off/adhoc-main-swap/receipt.json` | 11:05:54.975 | 11:06:08.430 | PASS |
| `codesign-clone-off/adhoc-branch-swap/receipt.json` | 11:06:12.280 | 11:06:40.142 | FAIL |
| `codesign-clone-reuse/offscreen-main/receipt.json` | 15:13:09.048 | 15:13:18.324 | PASS |
| `codesign-clone-reuse/offscreen-rebuilt/receipt.json` | 16:17:46.127 | 16:17:59.968 | FAIL; retained ctime change |
| `codesign-clone-reuse/offscreen-xattrs/receipt.json` | 16:19:27.171 | 16:19:28.526 | FAIL in setup before caller launch |
| `codesign-clone-reuse/offscreen-xattrs2/receipt.json` | 16:20:02.058 | 16:20:16.905 | DIAGNOSTIC |
| `codesign-clone-reuse/offscreen-polled/receipt.json` | 16:21:04.944 | 16:21:26.210 | PASS |

The setting calls and their obsolete receipt fields were removed from
`guard.py`, `offscreen.py`, `stability.py`, both swap harnesses, and all other
matching harness source. At the cleanup checkpoint, the reuse guard, stability and swap harnesses had
no execution receipt in this series. The cleanup did not execute a harness
or read or change a system setting. The lead independently confirmed the
setting key was absent, as before, in the 16:30 instruction.

No CrashReporter, ReportCrash, launchctl or other system-setting changes are
allowed. Launch only unmodified, already-passing builds. Never relaunch a
build that failed to load. Stop at the first new real Open crash report;
the read-only `.ips` baseline/diff check remains in the harness sources.
The windowless modified caller is not a permitted substitute for the pending
normal-App rows. No harness was rerun before the subsequent M5 clearance.

The 16:31 instruction cleared the M5 for normal-App rows a, b, c, d, f, g, h
and the ad-hoc part of e. The hardened DLV part of e waits for `M1 clear`. In row b,
retain stat snapshots around install/copy/xattr/codesign setup separately
from launch. If the pre-engine ctime change recurs, attribute it before any
gain claim. Check the harness's own setup and read-only Spotlight/mds logs;
do not change system settings to investigate it.

### Normal-App results after M5 clearance

`normal-stability.json` and `stability/receipt.json` record a full-App PASS
for rows a, c and d. Three full reuse runs retained executable ctime and
link count two. A copy over the same inode changed mtime and recreated the
clone. Two install paths had separate caches; returning to the first path
reused its own clone. Malformed and special-file identity controls recreated
the clone and rendered the fixture. Copy and signature-verification stat
snapshots are separate; `codesign --verify --deep --strict` did not change
ctime. The earlier pre-engine ctime anomaly did not recur in this set.

Load1 was 32.67–30.71. This is functional evidence, not timing evidence.
The separate stat process requested a 1 ms interval, but its largest observed
gap under load was 14.15 ms. This set does not prove a maximum 5 ms poll gap.
No new real Open crash report, owned process or owned window remained.

`adhoc-main-plain/receipt.json` and `adhoc-branch-plain/receipt.json` passed.
The branch plain control primed and reused the persistent clone, retained
ctime, rendered the fixture, and had renderer, GPU and utility processes.

`adhoc-main-swap/receipt.json` failed. The unchanged-main control used the
original per-run clone. The whole-App swap ran at 16:34:39.853–39.942 local
time on 2026-11-08. It used Sparkle's directory exchange and removed the old
staging App. The harness then sent SIGTERM to the original GPU and network
processes to require fresh helpers. The first new page stayed blank and
`wait` timed out. Fresh renderer 52951, GPU 52950 and network utility 52952
were alive in the failure capture. `app.log` records the requested exits and
GPU reinitialization; `unified.ndjson` records sandbox application to the
fresh helpers. There was no new real Open `.ips` and no identified
CODESIGNING or Killed: 9 event. The ad-hoc/unknown-chain AMFI message alone
does not establish a signing kill. The cause remains unassigned; service
restart and initial navigation overlapped.

At that checkpoint, the matrix stopped at this main control before the branch
live-swap proof. This failure does not establish either a PASS or a failure
of persistent clone reuse after replacement. The saved extracts are
`adhoc-main-swap/failure-app-events.json` and
`adhoc-main-swap/failure-signing-events.json`. No failed control was retried.
The independent normal-App rows may continue. Hardened DLV rows remain
PENDING until M1 clearance. No system settings were read or changed by these
corrected runs.

`normal-fallback.json` and `adhoc-branch-plain-unwritable/receipt.json`
record row f PASS. The inactive persistent clone was retired under its
exclusive lease, then the owned cache was set to mode 0500. The full App
used the logged per-run fallback, rendered the fixture and launched all
three helper types. The source executable link count was 1 before launch,
2 while running and 1 after cleanup; ctime changed. The persistent clone
stayed absent, and the App did not repair the cache permissions. This was
a plain functional run, not another live-swap attempt. It left no owned
process, window or new real Open crash report.

### Requested ad-hoc live replacement

`requested-adhoc-matrix.json` records PASS for the requested whole-directory
swap path on matched main and the reused-clone branch. The earlier control
added simultaneous SIGTERM of GPU and network services. It failed on main
and remains a separate, unassigned robustness failure. It was not retried
or erased. The requested path does not terminate either service. It opens
three distinct sites after replacement, then starts a silent Web Audio
stream to require a new audio utility process. The stream reports state
`running` and gain zero. Both cases require fresh renderer and audio utility
PIDs, live DOM content on all three sites, successful log collection and no
new real Open crash report. The existing GPU remains alive; no fresh-GPU
success is claimed for this path.

`requested-adhoc-main-swap/receipt.json` and
`requested-adhoc-branch-swap/receipt.json` both passed. The branch primed its
clone in a prior full run, then reused it before replacement: ctime, mtime,
inode and link count two stayed equal to the post-prime snapshot. After the
whole-App exchange and removal of the old staging App, three new sites
rendered with fresh helpers. Both cases ended with no owned process, window
or new real `.ips`. The main case ran at load1 9.54–9.29. These are functional
results, not launch measurements. Hardened DLV acceptance remains PENDING
on the held M1; it has not launched on the M5.

The existing shell suite passed 7 rows. Features passed 26 rows; the explicit
renderer-kill row is DEFERRED to the M1 by the crash-probe rule. Updater
passed all 21 result rows with seven disposable App instances and restored
its App preferences. All suite cleanup passed. Receipts are under
`suites/shell`, `suites/features` and `suites/updater`. The final read-only
`engine-status-normal.json` still reports 7 PASS, 0 FAIL and the required
0106-after-08xx order WARN.

### Daytime scan set and quiet-window handoff

The first seven-pair set did not pass its scan assertion. All seven branch
runs retained the executable's post-prime ctime, inode, size, mtime and link
count two. Its first three exact launch windows nevertheless contained
ChangetimeScan candidates. The last four contained none. All seven main
windows contained a scan. The scan signposts have private paths; the collector
conservatively retains every scan between request and the process's main
mark. Do not treat the first three candidates as attributed source-executable
ctime changes. No such change was observed. Their remaining assessment/cache
cause is unassigned. No launch-gain claim is based on this set.

| Pair | Main scan candidate ms | Branch scan candidate ms | Branch executable ctime changed |
|---|---:|---:|---|
| 1 | 145.68 | 148.98 | no |
| 2 | 144.30 | 148.13 | no |
| 3 | 143.64 | 144.50 | no |
| 4 | 156.45 | none | no |
| 5 | 153.65 | none | no |
| 6 | 160.50 | none | no |
| 7 | 153.98 | none | no |

Receipts: `measurements/results.json`, `measurements/scan-proof.json`, exact
per-sample `.ndjson` files, and `launch-seven-pairs-path-retry.json` (exit 1
at the scan assertion). The earlier pair-three path-query assertion was a
harness interruption. Its initial query value was not captured. Cleanup
found the requested executable path and no remaining owned process or
window. Both halves of that incomplete pair remain in
`measurements/interrupted-path-query/`. The harness now records path queries
and retries the exact same comparison for at most two seconds. It does not
accept an inode-only match. No retry was needed in the completed samples.

The lead's 17:35 ruling moves row g and the existing window launch rows to
tonight's quiet window. No daytime timing runner remains active. The old
priority-setting coordinators are retired. `window-timing.sh` sets no priority
flag and uses only the frozen Apps named in `window-inputs.json`. It takes
quiet then screen for each measuring set; log reading happens outside those
locks. It checks load1 ≤12, stops on a new real Open crash report, and limits
the whole invocation to twenty minutes. It records all failures and exits
nonzero on a harness or budget failure. It writes receipts under `window/`.
Every timing sample is retained, including scan-bearing launches. The scan
acceptance result stays separate from row g; a scan does not cause sample
replacement or suppress the later warm-profile rows. Only `bash -n` and
frozen-App path existence were dry-checked; the script has
not run. Both cold and warm rows use the existing window assertions verbatim;
the remaining window suite is outside this timing handoff.

The priority flag caused an unfair shared-screen wait. This task no longer
sets it.
The new functional seven-relaunch set uses the ordinary screen queue, without
the quiet lock or priority. Earlier failed observations remain in this report.

### Functional seven-relaunch result after the 17:35 ruling

`functional-seven-relaunches.json` records seven completed normal-App
launches and clean exits under one ordinary screen-lock invocation, without
priority or the quiet lock. `functional-seven-scan-logs.json` records exit 1
at the scan assertion. The executable's saved stat identity, ctime and link
count two stayed unchanged in all seven runs. There was no repeated
pre-engine executable-ctime change. Six launch windows had no ChangetimeScan;
the first had one 143.06 ms candidate. This is **6/7, FAIL**, not the requested
7/7 proof. These functional launches make no launch-gain claim. The separate stat
process requested 1 ms polling; its largest observed gap was 9.74 ms. This
set does not prove a maximum 5 ms polling interval. All seven owned-process
and window cleanup checks passed. Load1 was 11.12–11.59.

| Functional relaunch | Launch-window ChangetimeScan candidate ms | Executable stat unchanged |
|---|---:|---|
| 1 | 143.06 | yes |
| 2 | none | yes |
| 3 | none | yes |
| 4 | none | yes |
| 5 | none | yes |
| 6 | none | yes |
| 7 | none | yes |

This set reused the same frozen bundle and profile as the earlier four
scan-free daytime launches. No copy, xattr write or signing step occurred
between those sets. The first functional scan therefore cannot be discarded
as first-clone setup without further evidence.

The precise scan trigger remains unassigned. The signpost paths are private,
so the report uses the conservative launch-window candidate count. The result
does not establish a new executable writer or justify discarding the first
launch. All exact-window logs, the matching RunningBoard process-start lines,
stat polls and cleanup receipts are in `functional-scans/`. No extra retry set
was started. The lead's quiet-window runner will produce row g separately;
its source Apps and profiles are retained for that handoff.

Read-only sequence detail: in `functional-scans/01-branch.ndjson`, lines
101–103 report that code was already evaluated and that its scan returns
quickly. The next assessment begins ChangetimeScan at lines 165–167 and
records a cache miss at line 195; the scan ends at line 224. The assessments
have different evaluation IDs. Their target paths are private. This does
not identify which code object missed the cache, and it does not establish
another executable-ctime writer.

`functional-bundle-ctime-audit.json` is a later read-only `lstat` walk of the
frozen branch bundle. None of its 1,115 stat observations found a remaining
entry whose current ctime fell inside the seven functional runs. This is not
a recursive before/after snapshot. Deleted transient entries and later
changes are outside its coverage. It does not identify the scan target or
prove a Gatekeeper cache-expiry cause.

The gap audit in `between-sets-bundle-ctime-audit.json` also examines the
original bundle and its persistent clone (761 distinct paths each). No
remaining entry had a current ctime between the previous fast set and the
end of the functional set. Its post-run-snapshot limits remain the same.

### M1 staging, no runtime acceptance

`stage-m1.json` and `m1-staged-apps.json` record copying both already prepared
runtime/DLV temp Apps to a private M1 temp directory. Both executable hashes
match their source receipts, and both deep strict signature checks pass.
This is headless file staging and static inspection only. No App was launched
and no engine was built on the M1. The plain-launch and live-swap DLV gates
remain PENDING until the lead forwards `M1 clear`.

### Full gate on the merged head

`full-verify.json` and `verify-all/summary.txt` record the full
`s16-heavy.sh tools/verify-all.sh` run on `bb1d6824`, which contains main
`d26300e6`. It ran on 2026-11-08 from 17:42:17 to 18:23:32 local time.
The wrapper's load1 was 9.47 at start and 12.21 at finish. Each on-screen
check used its own screen-lock invocation. No priority flag was set by this
run. The command exited 1: **24 PASS, 1 FAIL**, with no SKIP or interruption.
The optional user-data import was not selected.

| Check | Result | Seconds, including queue wait |
|---|---|---:|
| build | PASS | 80 |
| commands-demo | PASS | 6 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 3 |
| space-editor | PASS | 234 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 24 |
| commands-dump | PASS | 1 |
| route | PASS | 17 |
| favicons | PASS | 3 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 4 |
| profiles | PASS | 3 |
| settings-preview | PASS | 1473 |
| sidebar-render | PASS | 111 |
| sidebar-compare | PASS | 149 |
| commandbar-render | FAIL | 46 |
| features-render | PASS | 90 |
| extensions-render | PASS | 9 |
| sitecontrol-render | PASS | 182 |
| onboarding-render | PASS | 22 |
| boosts | PASS | 4 |
| verify-secrets-fixture | PASS | 7 |

`verify-all/commandbar-render.log:164–177` records 149/151 passing rows.
Row 150 measured main-thread CPU p95 10.34 ms against the 8 ms limit.
Row 151 measured inline-completion cycle overhead p95 0.612 ms against
0.3 ms; maximum layout passes remained one. The check's load averages were
29.1, 23.5 and 18.7. These are retained failures. This branch changes none
of `OpenCommandBar`, `OpenSuggest`, `OpenCommands` or `OpenDesign` relative
to merged main. That fact does not prove main fails the same way. No quiet
recovery run or main comparison has run, and no threshold changed.

`functional-final-audit.json` records no remaining owned fixture process
and no new real Open crash report found by its read-only check since the
full gate began. The frozen Apps and primed timing profiles remain for
tonight's handoff. No quiet-window measurement or M1 launch has run.
The scan failure, timing handoff, full-gate failure and pending M1 rows
remain separate acceptance gaps. At this full-gate checkpoint there was
no PR or launch-gain claim.

### Read-only check of launches between sets

The lead's 18:35 ruling separates the engine contract from the remaining
assessment question. Rows a, c, d and f, plus unchanged executable stat in
all row-b runs, prove that reuse avoids per-run ctime/link writes. Row b
remains **FAIL against the 7/7 target; residual first-after-gap scans, cause
open**. Row g is still pending tonight. No launch gain is claimed.

The cache-pressure hypothesis is that other Open bundles evict this install's
syspolicyd assessment entry during each gap. This check used only saved
launch receipts and a new read-only `log show`, with no App launch. The exact
command and exit 0 are in `gap-attribution/collection.json`; the raw log is
`gap-attribution/open-family.ndjson`. The interval is 2026-11-08
17:13:00–17:41:10 local time. The predicate selects RunningBoard and Launch
Services messages naming Open, plus process-start and path-resolution lines.

`gap-attribution/analyze.py`, `starts.json` and `gap-counts.json` preserve
the extraction and every counted event. A confirmed App start requires
RunningBoard's successful `submitAndStart`, a matching activity's public
`PreventLaunch` executable path, and its tracked App identity. Count each
PID once. Anonymous capital-`Open` processes without a public bundle path
are separate first-tracking observations. Lower-case `/usr/bin/open`
launchers, repeated launch-request lines, and system XPC attachments are
excluded. This is an App-start comparison, not a complete Chromium helper
exec census. Launch Services messages did not supply additional public
bundle paths in this query.

Bundle aliases in the table:

- M: `.re/s16/codesign-clone-reuse/measurements/main/Open.app`, the matched control.
- D: `~/.t3/worktrees/open/t3-c5d84ead/build/Debug/Open.app`.
- R: `~/.t3/worktrees/open/t3-fcc4acd6/build/Release/Open.app`.
- S: `~/.t3/worktrees/open/t3-section-11-app-shell/build/Debug/Open.app`.
- T: the disposable `Open-E2E-downloads-…/downloads-attempt-…/Open.app`.

Each gap runs from the previous branch launch's recorded exit to the next
branch request. Daytime 3 starts after the retained interrupted branch
launch at 17:27:46.708, rather than after daytime 2. No interrupted launch
is hidden. Times below are local; counts exclude the branch being measured.

| Branch relaunch | Gap before request | Gap s | Scan ms | Confirmed starts by other bundle path | Path-unavailable Open observations |
|---|---|---:|---:|---|---:|
| Daytime 1 | 17:13:22.714–17:24:53.329 | 690.615 | 148.98 | 33: M ×1, D ×1, S ×31 | 26 |
| Daytime 2 | 17:24:55.206–17:27:41.136 | 165.930 | 148.13 | 0 | 0 |
| Daytime 3 | 17:27:46.708–17:33:22.501 | 335.793 | 144.50 | 9: M ×1, R ×2, S ×6 | 21 |
| Daytime 4 | 17:33:24.130–17:33:24.309 | 0.179 | none | 0 | 0 |
| Daytime 5 | 17:33:25.546–17:33:28.955 | 3.409 | none | 2: M ×2 | 0 |
| Daytime 6 | 17:33:30.242–17:33:30.480 | 0.238 | none | 0 | 0 |
| Daytime 7 | 17:33:31.713–17:33:35.173 | 3.460 | none | 2: M ×2 | 0 |
| Functional 1 | 17:33:36.493–17:40:56.995 | 440.502 | 143.06 | 36: R ×31, S ×3, T ×2 | 15 |
| Functional 2 | 17:40:58.569–17:40:58.653 | 0.084 | none | 0 | 0 |
| Functional 3 | 17:40:59.671–17:40:59.757 | 0.086 | none | 0 | 0 |
| Functional 4 | 17:41:00.765–17:41:00.851 | 0.086 | none | 0 | 0 |
| Functional 5 | 17:41:01.861–17:41:01.944 | 0.083 | none | 0 | 0 |
| Functional 6 | 17:41:02.972–17:41:03.059 | 0.087 | none | 0 | 0 |
| Functional 7 | 17:41:04.024–17:41:04.112 | 0.088 | none | 0 | 0 |

For example, raw lines 674/678/681 pair the S bundle path with a successful
start and tracking record in the first gap. Lines 15149/15153/15156 do the
same for the disposable downloads App before functional 1. Each event's
source line numbers are also saved in `starts.json` and each gap's details.

**Conclusion: cache eviction by other bundles remains a guess.** Three of
the four scan-bearing gaps include 8–36 confirmed external App starts,
excluding M. None of the ten scan-free gaps has an external bundle start.
However, daytime 2 scanned after a 165.930 s gap with no observed other
Open-family start at all. Other-bundle launches are therefore not a complete
explanation in this log record. Daytime 5 and 7 also remain scan-free despite
two matched-main starts each. The long gaps and other launch counts covary;
this comparison does not isolate elapsed time from cache pressure. It exposes
neither an eviction event nor the assessment cache's key or contents. A
time-dependent assessment rule is another untested possibility. The scan
target paths remain private, so the cause stays open.

The lead approved opening the PR with these failures and pending rows
explicit. It is not ready to merge. The approved quiet-window script remains
unchanged and unrun; hardened DLV launches still wait for `M1 clear`.
