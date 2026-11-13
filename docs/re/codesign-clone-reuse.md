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

Current results are in [the resumed merged-head record](#resumed-after-lead-attribution-2026-11-09)
and [the completed M1 DLV record](#m1-hardened-dlv-row-e-completed-after-clearance).
The current full gate is 24 PASS / 1 command-bar timing FAIL. Row g remains pending.

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

### Pre-#271 acceptance rows

These historical rows use the S16 distribution with `0801–0810`, then `0106`.
The earlier build, object compilation and patch round trip do not count as
runtime acceptance. This table records the pre-#271 cohort. It does not close
the full live-update gate or establish a gain on the rebuilt engine.

| Row | Required proof | Pre-#271 result |
|---|---|---|
| a | Executable ctime and link count stay unchanged for three full runs after the first clone | PASS, normal App; `stability/receipt.json` |
| b | Seven simple relaunches have no attributable ChangetimeScan | FAIL against the 7/7 target; residual first-after-gap scans, cause open. Functional set: 6/7 scan-free, unchanged executable metadata in all seven. No gain claim |
| c | An in-place executable copy keeps the inode but recreates the clone | PASS, normal App; `stability/receipt.json` |
| d | Two install paths use distinct clones with no cross-reuse | PASS, normal App; `stability/receipt.json` |
| e | Live replacement passes with a reused clone in both ad-hoc and temporary hardened DLV builds | Requested ad-hoc path PASS on main and reused-clone branch (fresh renderers/audio utility; GPU retained). Extra forced GPU/network restart control FAIL retained. DLV PENDING M1 clear |
| f | An unwritable cache falls back to a per-run clone and still works | PASS, normal App; full render and helper types; `adhoc-branch-plain-unwritable/receipt.json`. Fallback live swap not run |
| g | Seven interleaved main/branch pairs at load1 ≤ 12, plus window warm-profile rows | Pre-#271 runner completed seven pairs; both cold/warm budget sets FAIL. See the quiet-window record below. Rebuilt-engine timing remains PENDING the next quiet window |
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
explicit. It is not ready to merge. The approved quiet-window script and its
frozen inputs remain unchanged; hardened DLV launches still wait for `M1 clear`.

### Pre-#271 quiet-window record

The lead's runner executed the approved script on 2026-11-08 at
23:57:39–23:58:38 in the host's fixed GMT−07 clock. The labels are
**pre-#271 main** and **pre-#271 +0106**. Neither App includes #271.
This remains a valid comparison of that frozen cohort. It does not validate
the engine rebuilt after #271. No timing script was rerun for this update.

`window/receipt.json`, `window/pairs/results.json` and
`post271-20261109/pre271-timing-summary.json` retain all samples. Seven pairs
completed at load1 5.48–5.60, with no discarded sample. The scan result is
6/7 without a launch-window candidate, so the 7/7 target still FAILS.

| Pre-#271 variant | Samples | Median main ms | Median sidebarDrawn ms | Median first paint ms |
|---|---:|---:|---:|---:|
| main | 7 | 291 | 427 | 874 |
| +0106 | 7 | 139 | 287 | 725 |

The separate window-suite rows also retain their original thresholds.
Both variants fail the cold and warm budgets. These measurements do not
establish a gain on the rebuilt engine or close the launch budget.

| Pre-#271 variant | Row, five samples | Sidebar median ms | First-paint median ms | Result | Load1 range |
|---|---|---:|---:|---|---|
| main | cold_fresh_profile | 431 | 873 | FAIL | 5.53–6.48 |
| main | warm_existing_profile | 437 | 899 | FAIL | 5.53–6.48 |
| +0106 | cold_fresh_profile | 252 | 654 | FAIL | 6.18–6.28 |
| +0106 | warm_existing_profile | 273 | 672 | FAIL | 6.18–6.28 |

The runner exited 2 in 59.14 seconds and found no new real Open crash.
Both window-row commands exited 2. No priority flag or build was used.
The frozen executable and framework hashes still match `window-inputs.json`;
the read-only check is `post271-20261109/frozen-audit-before.json`.

### Rebuild after #271, 2026-11-09

The host clock read 01:22:52 GMT−07 before resumed work, after the 01:20
gate. Merge `046a077850c645c3918e0094a0507f42cae168d3` includes main
`3fb0645c1c41ff3d66d064fe3a9cb223afa3718d`, including #271 at `518471aa`.
Main's #271 distribution is
`8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`
(`docs/engine-patches.md`, ad-block Step 8). Native ad blocking remains on by
default. These are functional checks; no rebuilt-engine launch gain is claimed.

The only engine root used was `~/Developer/open-engine-s16`.
`post271-20261109/preflight.json` records no stale `open-engine-s8` path in
its state, `.gclient`, `args.gn` or `build.ninja`. The pre-apply status correctly
found the older ad-block inputs and symbols. Its first JSON output path was
refused because it was outside the worktree/state; later status output uses
the S16 state directory and is copied into the receipt directory.

The old checked-in CEF `0310` and Rust `0001` patches were reversed before
applying their current main versions. The Rust apply then found an existing,
byte-identical `gnrt_config.toml.open` overlay at a newly patch-owned path.
That file was preserved outside the tree, then apply created it from main's
patch. The failed apply receipts and saved input remain in
`post271-20261109/`. No patch artifact or 0106 source changed. Its three
wiring hashes still match `roundtrip.json`, as recorded in `artifacts.json`.
No new authoring round trip was needed.

The exact active Chromium order is:

```text
0301 0302 0303 0304 0305 0306
0401 0402 0403
0501 0504 0506
0601
0801 0802 0803 0804 0805 0806 0807 0808 0809 0810
0106
```

CEF order is `0101, 0104, 0105, 0302, 0303, 0304, 0305, 0310, 0311,
0314, 0505, 0601, 0602, 0701`; Rust is `0001`. Full filenames and apply
outcomes are in `artifacts.json`, `engine-apply-recovery.log` and the series
files. Engine-status reports all 39 active patches applied, all 125 overlay
files matching, and all 49 expected symbols present: **7 PASS, 0 FAIL,
1 WARN**. The sole WARN is the intentional Chromium numeric-order difference,
with 0106 after 08xx. It is not a failure or a reordered series.

Every engine job used the shared engine lock and S16 heavy wrapper. The build
used the script's nice setting and `--jobs 10`; no sync ran. Build PASS:
859 executed steps in 154.32 seconds, wrapper load1 6.66→35.99. Distribution
PASS in 67.23 seconds, load1 27.07→17.60. The new branch distribution is:

```text
346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd
```

Fetch and both App builds used `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s16`.
Release with automation passed in 137.24 seconds; Debug passed in 40.22 seconds.
The wrapper load1 was 15.35→9.74. Both deep strict signature checks and both
engine-fingerprint checks passed. The embedded code hash matches the
distribution after excluding the embedding signature:
`983ddb7a61e82970c8315db8f980881bd2495fe996148436d016b17c5610a1ba`.
The Release executable is
`8d5550414aa91994a8882024bc5eb4b9fecbc5fd4a75f72997960ba7c8f61bc0`;
Debug is `8bcebde38fbec1c27629528d923505b02647c57788e7ad9161d9fc1158f560b1`.
See `artifacts.json` and `functional-preflight.log` for complete identities.

`post271-20261109/functional/receipt.json` records nine full normal-App runs
from disposable copies of the new Release App. They ran at 01:48:20–01:48:50
GMT−07, at load1 8.58–10.53, under one functional-suite screen-lock invocation.
The source App and frozen cohort were not modified. Each run rendered the
fixture and observed renderer, GPU and utility helpers. All process/window
cleanup checks passed; all test installs, profiles and caches were removed.
The two startup preference keys were restored. Read-only report checks found
no new real Open crash.

| Row | Post-#271 result | Evidence and limits |
|---|---|---|
| a | PASS | Prime creates the link once. Three subsequent full runs retain identical executable stat, link count two, saved identity and clone bundle inode. No repeated pre-engine ctime change appears in this cohort |
| b | Existing FAIL; not rerun | Residual first-after-gap scans, cause open. The pre-#271 functional and quiet-window sets each remain 6/7 scan-free; this update starts no new row-b launches |
| c | PASS | Ordinary `cp` keeps device/inode `16777229/1158080489`, changes nanosecond mtime, and recreates the clone with a new saved identity and clone bundle inode |
| d | PASS | Two install paths create distinct hash directories and executable inodes. Returning to the first reuses its own clone |
| e | Historical ad-hoc PASS; DLV PENDING | The requested pre-#271 ad-hoc result and separate failed stress control remain above. Neither live swap nor DLV was rerun. M1 remains held |
| f | PASS | Two normal runs with the test install directory at 0500 render and launch all helper types. No persistent clone is created; each run has link count 1→2→1 and ctime changes, proving per-run fallback. The harness restores/removes its own test directory afterward |
| g | PENDING next quiet window | No timing on the rebuilt engine. The pre-#271 runner results above remain a separate cohort |
| h | PASS for the requested M5 functional scope | Shell 7 PASS; features 26 PASS with intentional crash recovery DEFERRED M1; updater 103 result rows PASS; engine-status 7 PASS, 0 FAIL, 1 order WARN |

Each suite used its own screen-lock invocation, with no quiet lock, load gate,
priority flag or simultaneous build. Both shell/features engine fingerprints
match the new distribution. The updater's original and copied bundles use
the rebuilt Debug App. `suites/<name>/suite-receipt.json`, the result JSONs,
and `<name>-screen.json` record cleanup and read-only crash checks. All suites
exited zero and left no owned process/window or new real Open crash.

| Functional suite | Result | Seconds after screen acquisition | Load1 start→end |
|---|---|---:|---|
| shell | 7 PASS | 21.94 | 9.40→12.59 |
| features | 26 PASS; intentional crash row DEFERRED M1 | 97.07 | 4.97→5.79 |
| updater | 103 PASS | 130.09 | 5.49→6.33 |

The later `engine-status-final.json` again records 7 PASS, 0 FAIL and the
same order WARN. No new row-b, live-swap, hardened DLV or timing run was
started. Those limits apply even though the requested functional rows pass.

### Post-#271 full verification and STOP

The full `s16-heavy.sh tools/verify-all.sh` ran on native/merge head
`046a077850c645c3918e0094a0507f42cae168d3`, containing main `3fb0645c`.
It started at 02:06:27 GMT−07 and stopped at 02:35:42 on 2026-11-09.
The wrapper load1 was 5.15→7.77. After the 310-second heavy-slot wait, the
guard's execution start load1 was 4.04. Optional user-data import was not selected.

**INTERRUPTED by the crash STOP rule: 15 PASS, one cancelled active check,
nine later checks not run.** The guard exited 86; the verifier exited 130
on SIGINT. The raw table records `settings-preview FAIL 0` because the
verifier's signal trap writes that row. It is not an assertion failure.
The settings check had passed 47 internal rows and finished its image render;
the final `dump-keys` phase was cancelled. No complete full-gate PASS is claimed.

| Check | Result | Seconds, including queue wait |
|---|---|---:|
| build | PASS | 87 |
| commands-demo | PASS | 4 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 361 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 22 |
| commands-dump | PASS | 0 |
| route | PASS | 9 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 3 |
| profiles | PASS | 2 |
| settings-preview | INTERRUPTED (raw `FAIL` from SIGINT) | 0 |
| sidebar-render | NOT RUN after STOP | — |
| sidebar-compare | NOT RUN after STOP | — |
| commandbar-render | NOT RUN after STOP | — |
| features-render | NOT RUN after STOP | — |
| extensions-render | NOT RUN after STOP | — |
| sitecontrol-render | NOT RUN after STOP | — |
| onboarding-render | NOT RUN after STOP | — |
| boosts | NOT RUN after STOP | — |
| verify-secrets-fixture | NOT RUN after STOP | — |

The read-only guard detected `Open-2026-11-09-023542.ips`, a real
`EXC_CRASH` / `SIGABRT` report (PID 80131, parent Python PID 79175).
Its top Open frames are `SpaceThemeWindow.preserveAppearance(of:)` and
`SpaceThemeWindow.addChildWindow(_:ordered:)`. The report redacts its App path.
Its main-image UUID differs from both rebuilt Apps. Ownership and cause remain
unassigned; this does not attribute the crash to 0106. Our verifier was running
the Settings CLI, not an Open App. The guard cancelled the verifier, all owned
processes exited, and no launch or retry followed. The lead was notified.
Full verification remains PENDING renewed screen clearance.

`full-verify.json`, `verify-crash-guard.json`, `verify-all/results.tsv`,
`verify-all/summary.txt`, `verify-all/settings-preview.log` and `crash-stop.json`
retain the exact outcome. The historical 24 PASS / 1 timing FAIL above remains
separate and unchanged.

A final fetch/merge still found main `3fb0645c` already included. Native source
and engine inputs remain identical to tested merge head `046a0778`; the final
commit changes evidence docs only. `final-audit.json` records no remaining
owned process and both functional cache paths removed. All 11 audited frozen
executable, framework, script and input hashes match the pre-resume audit,
including the saved executable/framework inodes. Frozen Apps, profiles and
approved timing inputs remain in place. No priority flag was set or shared
lock file removed. The one new real report is retained as the STOP event.

### Windowless checkpoint after the disk freeze

After the lead lifted the disk/DMG freeze on 2026-11-09, a fresh fetch/merge
again found main `3fb0645c` already included. `df` showed 18 GiB available
before and after the checks. No data or artifact was deleted.

`resume-0621-preflight.json` found no stale s8 path in the S16 state or live
configuration. `engine-status-0621.json` records exit zero, load1 3.64→3.75;
the status remains 7 PASS, 0 FAIL and the expected 0106-after-08xx WARN.
`engine-build-0621.json` records the locked S16-heavy incremental build with
`--jobs 10` and the script's `nice -n 10`: PASS in 9.79 seconds, load1
4.97→6.25. Ninja reports **no work to do, zero steps**. The earlier #271
rebuild and distribution were already complete; no new distribution was
needed. `resume-0621-final.json` confirms the recorded framework still has
SHA-256 `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`.

The lead's `/tmp/open-screen-hold-m5` now attributes the 02:35 crash to the
S11/window-border build and its `SpaceThemeWindow.preserveAppearance` KVO
cast. This is the lead's later attribution; the original STOP receipt remains
unchanged. The M5 and M1 screen holds still stand. No App, probe, timing run
or verifier was launched for this checkpoint. The interrupted full gate and
other pending acceptance rows remain open; all checkpoint jobs finished.

### M5 clearance at 08:31: new proof and a second STOP

The lead cleared the M5 on 2026-11-09. The new receipts are in
`postclear-0831-20261109/`; earlier receipts remain unchanged. The two normal
Apps survived the overnight cleanup. Deep strict signature checks and the
engine fingerprint preflight passed, so no App rebuild was needed.
`artifacts.json` records their exact hashes and the original build receipt.
The distribution remains
`346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`;
normalized embedded code remains
`983ddb7a61e82970c8315db8f980881bd2495fe996148436d016b17c5610a1ba`.
Both contain #271 and 0106. Native ad blocking remains ON by default.

The runtime proof head was `1a2f96e74c7a93ccec0908431462b7942b60a423`.
Its App and engine source matches the recorded native head `046a0778`.
After the STOP below, main `d624b952861730f169b788243a59964be6de2eff`
(#275) was merged as `3717f4ef2222866625b5dd502a95b78fa658cb1d`.
That merge changes only `sidebar-render/PreviewChecks.swift`; App and engine
inputs are unchanged. The runtime rows below therefore retain their exact
proof head. Full verification of the new merged head has not run.
No engine source, patch, manifest or series changed in this update.

The Chromium apply order remains:

```text
0301 0302 0303 0304 0305 0306 0401 0402 0403
0501 0504 0506 0601
0801 0802 0803 0804 0805 0806 0807 0808 0809 0810
0106
```

The CEF and Rust orders remain those recorded in the #271 rebuild above.
The required 0106-after-08xx numeric-order difference is WARN only.
`engine-status-merged-result.json` records 7 PASS, 0 FAIL, 1 WARN after
merging #275; exit zero, 8.41 seconds, load1 17.49→16.44. An earlier status
invocation passed all seven checks but rejected the JSON output location.
The retry used an allowed worktree path. Both invocations are retained.

| Row | Morning rebuilt-engine result | Receipt or limit |
|---|---|---|
| a | PASS | Three full runs after priming retain identical executable stat, link count two, saved identity and clone bundle inode; `functional/receipt.json` |
| b | 7/7 scan-free in this new cohort; historical FAIL retained | Seven LaunchServices relaunches have matching RunningBoard start records and zero ChangetimeScan pairs in the captured intervals. All stat samples stay at the primed value. Earlier first-after-gap scans remain unexplained; this set does not close that cause |
| c | PASS | In-place `cp` retains device/inode `16777229/1159232070`, changes nanosecond mtime, and recreates the clone and saved identity |
| d | PASS | Two install paths get distinct cache directories and executable inodes; returning to the first reuses only its own clone |
| e | Requested ad-hoc path PASS in both directions; DLV PENDING M1 | Disposable Release→Debug and Debug→Release installs both prime and reuse a clone before the atomic directory swap. Both builds contain #271 + 0106. This is not a new main control. Fresh renderers and a silent audio utility pass; existing GPU retained. Earlier forced GPU/network restart FAIL remains separate |
| f | PASS | Two normal runs with the owned cache directory at 0500 render and launch renderer/GPU/utility helpers. No persistent clone appears; link count goes 1→2→1, with ctime changes, proving the safe per-run fallback |
| g | PENDING next quiet window | No rebuilt-engine timing was run. The completed frozen pre-#271 A/B above remains labelled pre-#271 |
| h | PARTIAL | Shell 7 PASS; engine-status 7 PASS/0 FAIL/1 WARN. Features stopped before launch on the crash guard. Updater did not run. Earlier post-#271 Features 26 PASS and updater 103 PASS remain a separate cohort |

The b poller requested 1 ms and observed a worst gap of 3.88 ms. Each of
seven runs has one unchanged stat event, equal to the post-prime value.
No pre-engine ctime recurrence appears in these runs. The original copy,
signature verification and two priming receipts are retained. No launch-gain
claim follows from this functional set. The prior b FAIL, the windowless
ctime anomaly and the inconclusive assessment-cache guess remain above.

The first b attempt exited before any App launch: an inner priority assertion
saw another section's flag after the outer wrapper had queued. Its measurement
folder was empty. `b-queue-abort.json` records that harness failure. The retry
kept the priority wait in the outer wrapper and omitted the duplicate check
inside the held screen lock. No priority flag was set or removed by this work.
The seven completed samples are the only simple-relaunch samples in this cohort.

`requested-adhoc-Release-swap/receipt.json` and
`requested-adhoc-Debug-swap/receipt.json` record the live replacements. The
existing owned-directory `renamex_np(..., RENAME_SWAP)` helper matches the
Sparkle 2.10.1 operation described above. The old staging App is removed
before new helpers launch. Each direction renders three new local test sites,
creates fresh renderer and audio utility processes, and quits cleanly.
`swap-log-review.json` finds no captured signing-failure candidate tied to the
observed App/helper PIDs or clone paths. This log check covers only its recorded
intervals. It does not claim that all system messages concern these Apps.
The separate historical forced-service restart failure remains unchanged.

Each row batch and suite took its own screen-lock invocation. These are
functional checks: no quiet lock, load gate, timing comparison or priority
flag. No owned build ran during an App launch.

| Batch | Result | Seconds after screen acquisition | Load1 start→end |
|---|---|---:|---|
| a/c/d/f, nine full runs | PASS | 26.79 | 9.81→8.78 |
| b, two primes and seven relaunches | 7/7 scan-free; metadata stable | 18.82 | 5.60→7.21 |
| e, Release→Debug | PASS | 19.12 | 7.59→8.27 |
| e, Debug→Release | PASS | 18.90 | 8.59→8.45 |
| shell | 7 PASS | 21.01 | 7.39→6.78 |
| features | STOP before launch; no feature assertion ran | — | 21.05 at STOP |
| updater | NOT RUN after STOP | — | — |

### Renderer crash STOP at 09:15 and remaining verification

At 09:15:45 GMT−07, the guard found the new real report
`Open Helper (Renderer)-2026-11-09-091543.ips` while acquiring the Features
screen lock. Features had not started an App. The report's capture time is
09:15:28.2698; its header time is 09:15:43. It records PID 33603, parent Open
PID 32710, `EXC_CRASH / SIGABRT`, and `blink::DevToolsSession::IOSession::DispatchProtocolCommand`
among the faulting frames. It is not marked simulated. The App path is redacted.
The parent had exited when checked. Ownership and cause are unassigned.
No relationship to 0106 is established by this report.

The last owned shell App and helper PIDs had all exited by 09:13:22 and do
not include either report PID. The completed morning rows predate the crash
capture. The guard refused to start Features, its wrapper exited 1, and the
serial runner stopped. That exit is a crash-guard refusal, not a Features
assertion failure. Updater and full verification were not started. No retry,
App launch, probe or on-screen check followed. The lead was notified.
`crash-stop.json`, `suite-features.log` and the wrapper receipt retain the STOP.

The full `s16-heavy.sh tools/verify-all.sh` on merged head `3717f4ef` remains
PENDING renewed screen clearance. The table below is a NOT RUN inventory,
not an execution result. Optional user-data import was not selected.
`full-verify-not-started.json` records the reason. The prior full gate's
15 PASS / INTERRUPTED and the older 24 PASS / 1 timing FAIL remain above.

| Current merged-head check | Result | Seconds |
|---|---|---:|
| build | NOT RUN after STOP | — |
| commands-demo | NOT RUN after STOP | — |
| roundtrip | NOT RUN after STOP | — |
| space-legacy | NOT RUN after STOP | — |
| space-editor | NOT RUN after STOP | — |
| space-pad-compare | NOT RUN after STOP | — |
| suggest-check | NOT RUN after STOP | — |
| commands-dump | NOT RUN after STOP | — |
| route | NOT RUN after STOP | — |
| favicons | NOT RUN after STOP | — |
| media-demo | NOT RUN after STOP | — |
| sleep-demo | NOT RUN after STOP | — |
| adblock-perf | NOT RUN after STOP | — |
| adblock-catalog | NOT RUN after STOP | — |
| profiles | NOT RUN after STOP | — |
| settings-preview | NOT RUN after STOP | — |
| sidebar-render | NOT RUN after STOP | — |
| sidebar-compare | NOT RUN after STOP | — |
| commandbar-render | NOT RUN after STOP | — |
| features-render | NOT RUN after STOP | — |
| extensions-render | NOT RUN after STOP | — |
| sitecontrol-render | NOT RUN after STOP | — |
| onboarding-render | NOT RUN after STOP | — |
| boosts | NOT RUN after STOP | — |
| verify-secrets-fixture | NOT RUN after STOP | — |

Remaining: Features, updater and full verification need renewed M5 clearance.
Hardened DLV and intentional crash recovery still need M1 clearance. Timing
g on the rebuilt engine needs the next quiet window. The historical b FAIL
and its unexplained first-after-gap cause remain recorded despite this new
7/7 scan-free set. The PR is not ready to merge.

`final-audit.json` records no remaining owned PID and all audited test clone
caches removed. The new b profile and install copy are removed; its raw logs
and stat receipts remain. Completed harnesses record Open preference restoration
and zero owned windows. All 11 audited frozen executable, framework, script and
input hashes and recorded inodes match the pre-run audit. The known new renderer
report is retained. No system setting changed, no prohibited experiment ran,
and no priority flag or shared lock file was changed. All owned jobs finished.

### Main advanced to #280 after the STOP

The final main fetch also brought `701bcab0c97805030f62970717b046f4b67e271b`
(PR #280, window-border). It was merged as
`2f956a0f6c81f703fb5bdbec7f8df6ec35daecac`. This changes App code, so the
morning runtime table above is strictly evidence for its recorded earlier
App/source head. It is not runtime acceptance of the new #280 Apps.
There are no engine-file changes in either new main merge. The distribution,
code hash and series order remain unchanged; no new engine rebuild is needed.

Both Apps were rebuilt, one at a time through S16-heavy with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s16`, without a launch.

| Windowless check on 2f956a0f | Result | Seconds | Load1 start→end |
|---|---|---:|---|
| Debug App build | PASS | 75.80 | 9.60→10.07 |
| Release automation App build | PASS | 155.62 | 10.07→13.89 |
| Both engine fingerprints | PASS | 5.49 | 10.89→12.82 |
| engine-status | 7 PASS / 0 FAIL / 1 order WARN | 8.24 | 10.89→12.82 |

Deep strict signature verification also passed for both Apps. New executable
SHA-256 values are Debug
`f645b2af08a9116990b9d6023eb4fb0fa1b0d0ea074709bb1a239606655a6fa4` and
Release `c76ca0520fc47435fb26ef12c15b68e1dba22d9f2a954c0cfba84ae47661add7`.
Both embedded signed frameworks retain SHA-256
`63c7e9aef11ec54c31360530c397a16fd9c8f5aef27cea2a7a2b1cb6e2336f7d`.
`post280-artifacts.json`, `build-merged-debug.json`, `build-merged-release.json`,
`post280-static.json` and `engine-status-post280-result.json` record these
windowless checks. Neither new App has been launched.

`full-verify-post280-not-started.json` records the same 25 NOT RUN rows for
the new merged source. The older pre-#280 inventory remains unchanged.
The new Apps need runtime qualification after renewed M5 clearance, including
completion of Features, updater and the full verifier. DLV still needs M1
clearance; rebuilt-engine timing still needs the next quiet window. The morning
clone/scan/swap results and all historical failures retain their exact heads.
No performance or merge-readiness claim follows from build/static success.

### Resumed after lead attribution, 2026-11-09

The lead's 09:45 ruling identifies the 09:15 renderer report as Section 13's
passing intentional `popup_renderer_crash` case, parent PID 32710, in
DevToolsSession. It was not from this work. This is the lead's attribution;
the original STOP and report receipts above remain unchanged. The lead
allowed resumed screen work and required a read-only dlg.js check before
and after each suite. New crash reports are accepted only when their actual
PID exactly matches a Section marker; any unmatched real Open report stops work.
`lead-clearance.json` records the ruling. No system setting changed.

The resumed proof source is `8cac5c6fc131f5ffdac8fa482b86897bfa2aec8d`. It merges main
`bc5678d1030c90a6343e24af7e700ca1c6598377` (#281), which includes #280
and main ≥701bcab0. Engine inputs are unchanged by these App merges. Both
Apps were rebuilt serially through S16-heavy with OPEN_ENGINE_ROOT pointing
only at open-engine-s16. Debug PASS in 21.36 s, load1 4.76→5.53; Release
with automation PASS in 116.01 s, load1 5.53→17.10. Deep strict signatures
and engine fingerprints pass. Current exact identities (`artifacts.json`):

| Artifact | SHA-256 |
|---|---|
| S16 #271 +0106 distribution | `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd` |
| Debug executable | `eaf364c11a73d49c58f93bc9ea2d56953491689ddf0f77350652e66d38cd6bad` |
| Release executable | `873d5fb431b1964ed815d785779ceb89c8811e2d2064b87185c6041e0489e8c3` |
| Embedded signed framework, both Apps | `63c7e9aef11ec54c31360530c397a16fd9c8f5aef27cea2a7a2b1cb6e2336f7d` |
| Normalized framework code | `983ddb7a61e82970c8315db8f980881bd2495fe996148436d016b17c5610a1ba` |

Main #271 remains framework 8e8a461c; native ad blocking stays ON by default.
The exact series remains:

```text
chromium: 0301 0302 0303 0304 0305 0306 0401 0402 0403 0501 0504 0506 0601 0801 0802 0803 0804 0805 0806 0807 0808 0809 0810 0106
cef: 0101 0104 0105 0302 0303 0304 0305 0310 0311 0314 0505 0601 0602 0701
rust: 0001
```

**WARN only:** 0106 follows 0801–0810 as required by the series. Fresh
`engine-status.json` reports 7 PASS, 0 FAIL and this single numeric-order
WARN; exit zero, 8.63 s, load1
6.75→6.69. No patch, overlay, manifest or
engine source changed during this resumption, so no new authoring round trip
was needed. The completed #271 rebuild/distribution and original round trip
remain above.

Receipts below are relative to `resume-0945-20261109/` in the project evidence
directory. Prior cohorts remain historical and unchanged.

| Row | Current rebuilt-engine result | Evidence or remaining limit |
|---|---|---|
| a | PASS | Three normal full reuse runs after priming keep identical executable stat, link count two, saved identity and clone bundle inode |
| b | 7/7 scan-free in this cohort; historical FAIL retained | Matching RunningBoard starts, zero ChangetimeScan pairs, unchanged primed metadata. No pre-engine ctime recurrence. Historical residual first-after-gap scans remain unexplained; no gain claim |
| c | PASS | In-place cp retains device/inode 16777229/1160243975, changes nanosecond mtime and recreates the clone/identity |
| d | PASS | Two install paths create distinct private cache slots and executable inodes; returning to the first reuses its own slot |
| e | PASS: ad-hoc both directions; M1 DLV all three requested directions | Release→Debug and Debug→Release each reuse a clone before atomic whole-App replacement and removal of the old staging App. Three local sites, fresh renderers and silent audio utility pass; GPU retained. Both Apps contain #271 +0106; this is not a new main control. M1 adds main(#271) → +0106 and both +0106 → +0106 directions after three single plain launches. Historical forced GPU/network restart FAIL retained |
| f | PASS | Two normal runs at cache mode 0500 render with renderer/GPU/utility helpers. No persistent clone appears; link count 1→2→1 and changed ctime prove Chromium's safe per-run fallback |
| g | PENDING next quiet window | No rebuilt-engine timing. Frozen pre-#271 A/B remains a separate historical cohort |
| h | PASS for requested M5 functional scope: shell 7 PASS, features 27 PASS including non-fatal chrome://kill recovery, updater 103 PASS | Fresh engine-status 7 PASS / 0 FAIL / 1 numeric-order WARN |


The row-b poller requested 1 ms and observed a worst gap of 11.80325 ms at
functional daytime load. All recorded stat values equal the primed value;
this is not continuous ≤5 ms sampling proof. The scan proof is
`measurements/scan-proof.json`; nine full functional runs are recorded in
`functional/receipt.json`. No launch gain follows from these functional rows.
The old b FAIL, pre-engine ctime anomaly and assessment-cache guess remain open.

Both `requested-adhoc-*-swap/receipt.json` files retain the real whole-directory
RENAME_SWAP and cleanup receipts. `swap-log-review.json` finds no captured
signing-failure candidate tied to the observed App/helper PIDs or clone paths.
That statement is limited to the saved log intervals. The M5 batches ran no
forced service restart or hardened/DLV launch. M1 proof follows below.

| Batch | Result | Seconds after screen acquisition | Load1 start→end |
|---|---|---:|---|
| a/c/d/f, nine full runs | PASS | 31.98 | 12.54→13.71 |
| b, two primes and seven relaunches | PASS | 21.59 | 12.81→18.27 |
| e, Release→Debug | PASS | 18.32 | 14.71→13.86 |
| e, Debug→Release | PASS | 20.36 | 14.64→20.65 |
| shell | PASS | 21.93 | 7.26→9.09 |
| features | PASS | 100.12 | 11.27→8.62 |
| updater | PASS | 137.52 | 7.56→11.03 |

Features recovery uses chrome://kill, retains the same App PID and a live sibling,
then reloads successfully; it does not generate a crash report. This proof
head uses pre-#283 updater termination behavior; the lead's known #283
retry-row issue applies to later merged heads. Shell has seven
PASS rows, Features 27 PASS and updater 103 PASS.

One batch/suite ran per screen-lock invocation. No functional quiet lock,
load gate or priority flag was used. No owned build overlapped an App run.
`suites/*/suite-receipt.json` records preference restoration and process/window
cleanup. All current screen receipts record dlg.js =0 before and after.
Exact-PID marker snapshots and any accepted expected reports are saved under
`intentional-markers/` and `intentional/`; the final audit records their count.

### Full verifier on the resumed merged head

The original full tools/verify-all.sh ran through S16-heavy on `8cac5c6fc131f5ffdac8fa482b86897bfa2aec8d`.
Result: **1 FAIL, 24 PASS**. Wrapper elapsed 2085.02 s, load1 9.71→10.07;
after the slot wait the guard began at load1 9.71
and ended at 10.07. Optional private Arc-data import was
not selected. The gate used no quiet lock or priority flag.

Private instrumentation executed the current production check.py with its
original source/resource paths, assertions, thresholds, CLI commands and screen
locks. It added dlg.js receipts only after each native screen lock acquisition
and after cleanup before release. `verify-instrumentation.json` records both
source hashes. No production verifier file changed.

| Check | Result | Seconds, including queue wait |
|---|---|---:|
| build | PASS | 97 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 443 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 26 |
| commands-dump | PASS | 0 |
| route | PASS | 12 |
| favicons | PASS | 9 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 4 |
| profiles | PASS | 4 |
| settings-preview | PASS | 679 |
| sidebar-render | PASS | 113 |
| sidebar-compare | PASS | 122 |
| commandbar-render | FAIL | 34 |
| features-render | PASS | 89 |
| extensions-render | PASS | 7 |
| sitecontrol-render | PASS | 399 |
| onboarding-render | PASS | 24 |
| boosts | PASS | 4 |
| verify-secrets-fixture | PASS | 5 |

`full-verify.json`, `verify-crash-guard.json`, `verify-all/results.tsv`,
`verify-all/summary.txt` and the per-check logs retain the actual gate.
The earlier 24 PASS / 1 timing FAIL at load1 29.1 and interrupted 15-PASS
gate remain separate. No assertion, baseline, comparator or threshold changed.

The frozen comparison remains **pre-#271 main versus pre-#271 +0106**. Its
seven pairs and failed cold/warm budgets do not validate this rebuilt engine.
No timing script or frozen input was run or modified during this update.
The M1 DLV results below close that requested functional row; new-engine
g remains pending the next quiet window. The historical b cause remains open.
This PR is not ready to merge and has not been merged.

### Isolated command-bar timing attempts

The current full gate's sole FAIL is row 151: inline-completion overhead
+0.309 ms against +0.300 ms at load1 8.7. Row 150 passes at 4.35 ms CPU p95
against 8 ms. Two isolated attempts used quiet lock → S16-heavy on the
already-built CLI, with no App launch or screen lock. They changed no source,
baseline or threshold. The exact command is tools/verify-all.sh --only
commandbar-render. Both attempts remain FAIL; they are not aggregated into PASS.
No unchanged-main CLI comparison ran.

| Attempt | Row 150 CPU p95 / 8 ms | Row 151 overhead / 0.300 ms | Measured load1 | Check result |
|---|---|---|---:|---|
| Full gate | PASS, 4.35 ms | FAIL, +0.309 ms | 8.7 | FAIL |
| Quiet 1 | FAIL, 9.40 ms | PASS, +0.246 ms | 9.0 | FAIL |
| Quiet 2 | FAIL, 9.86 ms | PASS, +0.035 ms | 22.8 | FAIL; not qualified as quiet acceptance |

Quiet 1's wrapper load1 is 8.47→9.04 over 48.50 seconds. Quiet 2 started
at 8.32 and ended at 22.76 over 52.49 seconds in its inner guard. Its wrapper
checked load at start only and did not stop when it rose above 12. That
attempt therefore cannot qualify as quiet proof. Its timing FAIL stays in
the record; no further timing run followed. The original incomplete outer
receipt after a turn interruption remains unchanged. The completed inner
guard, summary and `quiet2-wrapper-recovery.json` record the outcome without
inventing a missing outer exit or end time.

`quiet-verify/`, `quiet2-verify/`, their separate crash guards and the raw
full gate retain every result. These tests did not run row g. No current-engine
launch gain or full-green gate is claimed. The command-bar timing failure
remains an acceptance gap for the lead; #266 changes no code in that CLI path.

### M1 hardened DLV row e: completed after clearance

The lead cleared M1 and requested two kinds of update: the exact M5
Release↔Debug pair, labelled **+0106 → +0106**, and one first-update
**main(#271) → +0106** direction. All requested directions PASS. No engine
build ran on M1. DLV re-signing and every DLV launch ran only on M1.

The exact M5 pair was copied before the control build; both original normal
App hashes match `artifacts.json`. For the main control, this existing M5
worktree was temporarily detached at merge-base main
`bc5678d1030c90a6343e24af7e700ca1c6598377`. The App built against the read-only s8-main
recorded #271 distribution `8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`.
The normal Release automation build PASS took
53.24 s through S16-heavy, load1
6.41→8.37.
Its deep strict signature and engine fingerprint passed before copying.
No engine was built or changed. The branch checkout, S16 Vendor distribution
and exact original Release App were restored. The s8-main distribution hash
remained unchanged. `m1-dlv/control-build.json` and `control-main.log` record
this authorised read-only control use and restoration.

The M1 worktree was detached at `8cac5c6fc131f5ffdac8fa482b86897bfa2aec8d`.
Only supporting harness helpers were compiled there. Three copied Apps were
ad-hoc signed with hardened runtime in release.sh's nested-code order. The
main/helper entitlement dictionaries exactly equal the committed dictionaries
plus disable-library-validation. No certificate or Keychain identity was used.
Deep strict verification passes for each App. Normalized framework code hashes
match before and after re-signing. `m1-dlv/results/signing-receipt.json` retains
all input, signed-executable and framework hashes.

| M1 DLV input | App source head | Engine distribution SHA-256 | DLV executable SHA-256 |
|---|---|---|---|
| Main271 | `bc5678d1030c90a6343e24af7e700ca1c6598377` | `8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1` | `ee585574670ab67e47955bbb5a2dabd035a113e15498668500503c8616da72fb` |
| Release | `8cac5c6fc131f5ffdac8fa482b86897bfa2aec8d` | `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd` | `5ab12ef8ca95be91fc19021ad1f6969f7f1e078a8da6fa24708de22587e7fae5` |
| Debug | `8cac5c6fc131f5ffdac8fa482b86897bfa2aec8d` | `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd` | `c6cc0c622fddb8418170bbc85a0e7e94a02b36c0f55d81d009628de90f70f9c4` |

The matrix ran on 2026-11-09 at 11:02:19–11:03:53, host GMT−07. Each input got
exactly one initial plain launch, with no priming launch in that phase. All
three passed before any live-swap run. Main's plain run observes its original
per-run link lifecycle, 1→2→1; the +0106 inputs retain their first persistent
clone at link count two after quit. No build failed to load, no abort occurred,
and no failed build was relaunched.

| M1 case | Result | Seconds after screen acquisition | Load1 start→end |
|---|---|---:|---|
| Main271 single plain launch | PASS | 11.38 | 3.46→4.96 |
| Release single plain launch | PASS | 10.83 | 4.96→5.16 |
| Debug single plain launch | PASS | 11.63 | 5.16→5.76 |
| main(#271) → +0106 Release | PASS | 17.93 | 5.76→5.24 |
| +0106 Release → +0106 Debug | PASS | 21.06 | 5.24→8.83 |
| +0106 Debug → +0106 Release | PASS | 20.06 | 8.83→8.78 |

For **main(#271) → +0106**, the running old main App uses Chromium's existing
per-run clone. For each **+0106 → +0106** direction, the harness first primes
and quits, then proves unchanged executable stat and saved clone identity on
the actual reuse launch. Each real atomic whole-App RENAME_SWAP removes the
old staging bundle before creating three new local-site renderers and a fresh
silent audio utility. The existing GPU remains. DOM render assertions, helper
PID changes, snapshot and clean shutdown all pass. No forced GPU/network
restart control was repeated.

All six cases took separate M1 screen-lock invocations. The 12 dlg.js checks
record zero before and after. Read-only report checks found zero new real Open
reports; zero expected marker-matched reports and zero marker snapshots were
observed. `swap-log-review.json` finds no captured signing-failure candidate
tied to the observed App/helper PIDs or clone paths; that finding is limited
to the captured intervals. No system setting changed.

Every case restored its startup preferences and left zero owned processes or
windows. All six test cache directories, runtime install copies and profiles
were removed. Receipts and raw logs were copied to M5 under
`m1-dlv/results/`, then the owned detached M1 worktree and its signed input
copies were removed. M5 original normal-App inputs are retained for the next
quiet-window handoff. The prior frozen pre-#271 cohort and timing files remain
unchanged. These temporary DLV checks do not constitute production signing or
notarization acceptance.

Row e is now PASS for the requested ad-hoc and hardened DLV functional scope.
The historical extra forced-service stress FAIL is retained. Remaining:
new-engine row g needs the next quiet window; the current command-bar timing
check remains FAIL; historical row b's first-after-gap scan cause stays open.
The PR remains not ready to merge, with no current-engine launch-gain claim.

### Final evidence and cleanup audit

The final fetch found main `28001634` (#284). Since the tested merge-base
`bc5678d1`, main changed no engine input or file changed by #266. The proof
source remains `8cac5c6f`; this final update changes only the two evidence
docs. It does not claim validation of later main changes, including #283's
new updater termination behavior.

The read-only M5 audit at 11:10:19 GMT−07 confirms all 11 frozen hashes and
inodes unchanged, both current Apps matching `artifacts.json`, all audited
test caches removed and no owned jobs or Apps left. All 24 recorded M5
dialog checks are clear. It finds no new real or expected marker-matched
report and no marker snapshot. `final-audit.json` records the checks.
The M1 audit and `m1-dlv/cleanup.json` confirm zero owned processes/windows,
restored test preferences, copied receipts and removal of the detached
worktree. Original normal-App inputs remain on M5. No row-g timing run or
priority flag was used. No system setting changed and no PR merge ran.

### Lead GO and final main merge, 2026-11-09

The S16 lead's 11:18 ruling, forwarded at 11:20, allows #266 to proceed
without waiting for row g. It accepts the retained full verify-all result
**24 PASS / 1 commandbar-render timing FAIL**, specifically **+0.309 ms
against +0.300 ms**, under TANDEM 4l. This is the OpenKit CLI check, and
#266 adds no OpenKit changes relative to merged main. The check remains a
recorded FAIL; no threshold or result was changed. Its original source is
`8cac5c6f`, with check load1 8.7 and wrapper load1 9.71→10.07. The complete
25-row table and both isolated failed attempts remain unchanged.
No new full verifier or timing attempt ran under this scoped final ruling.

Main `280016348f096643f07f21cdd22d46f121b99bcc` (#284, including #283) merged cleanly as
`8afd3cc1a4736c36dacdc460781285e6daa36c1f`. Both sides were retained. A diff from the earlier merged main
`bc5678d1` to this main contains no Engine file change. The branch's engine
patches, overlays, pins and exact series order remain unchanged. Read-only
engine-status before and after the App builds reports **7 PASS / 0 FAIL /
1 WARN**, the required 0106-after-08xx numeric-order warning. All 39 active
patches, 125 overlays and 49 symbols match. No engine rebuild, apply,
distribution or refresh ran. Only open-engine-s16 was read; neither
open-engine-s8-main nor the M1 engine copy was touched.

Receipts for this final scope are in `go-1120-20261109/`. The normal Debug
and Release Apps were rebuilt one at a time through S16-heavy, with
OPEN_ENGINE_ROOT pointing to open-engine-s16. Release keeps automation
compiled in. The local CEF wrapper was rebuilt by the App dependency script;
Chromium was not rebuilt. Deep strict signatures and both engine fingerprints
pass. The harness helpers were already current. An unstarted own heavy-slot
wait for their check was cancelled; the read-only artifact check then passed
without compilation. Both the cancelled wait and completed check receipts
are retained.

| Final check | Actual result | Seconds | Load1 start→end |
|---|---|---:|---|
| engine-status before build | 7 PASS / 0 FAIL / 1 order WARN | 8.27 | 30.71→28.65 |
| Debug App build | PASS | 96.76 | 24.31→16.68 |
| Release automation App build | PASS | 154.45 | 16.68→13.95 |
| engine-status after build | 7 PASS / 0 FAIL / 1 order WARN | 8.68 | 13.95→13.87 |
| Read-only signatures and fingerprints | PASS | 10.73 | 17.80→16.53 |
| updater, after screen acquisition | 97 PASS rows; suite exit 1, known #283 | 118.44 | 8.75→10.32 |
| shell, after screen acquisition | 7 PASS rows; suite exit 0 | 23.13 | 9.28→11.10 |

Each suite took its own screen-lock invocation, updater first and shell
second. There was no priority flag, quiet lock, functional load gate or
owned build during either suite. All four before/after dlg.js checks are
zero. Read-only report checks found no new real or marker-matched expected
Open report. One intentional-crash marker snapshot was observed and saved;
no new report matched it.

Updater's unchanged suite passes R1, then loses the automation socket in
its `termination-retry` variant before R2 can finish, reporting
`[Errno 2] No such file or directory`. The final App (PID 76018) logs normal
sleep capture and OpenEngine shutdown; cleanup is unforced with no remaining
process or window. This is recorded as **known, #283**, following the lead's
10:05 ruling: install-and-relaunch now skips quit prompts, while the old R2
case expects a cancelled quit. R2 and later rows are **NOT COMPLETED** in
this run, not PASS. `updater-known-283.json`, the result JSON, App log and
cleanup receipts preserve this classification and its limits. All 97 emitted
`ok` rows pass, including preference restoration and all 27 App cleanups.
The prior 103-PASS updater cohort at `8cac5c6f` remains separate.

| Final App artifact | SHA-256 |
|---|---|
| Debug executable | `f819dc043ac924801b301345b254d37f83a8232ee7c31e712d04719d241003be` |
| Release executable | `1f2d7b908d72f004a79cbc6d90223342db61bb289a026a7d5ba2da0ce2ceb127` |
| Embedded signed framework, both Apps | `63c7e9aef11ec54c31360530c397a16fd9c8f5aef27cea2a7a2b1cb6e2336f7d` |
| S16 #271 +0106 distribution | `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd` |

| Row | Final status and proof source |
|---|---|
| a | PASS at `8cac5c6f`; unchanged engine. Three full reuse runs after priming retain ctime/link count |
| b | OPEN cause; historical FAIL retained. First-after-gap scans occurred in 3/7 daytime and 1/7 functional launches. Later rebuilt-engine sets are 7/7 scan-free; they do not explain those scans |
| c | PASS at `8cac5c6f`; same-inode copy invalidates and recreates the clone |
| d | PASS at `8cac5c6f`; separate install slots |
| e | PASS at the recorded prior heads: ad-hoc both directions, M1 hardened DLV main(#271) → +0106 and both +0106 → +0106 directions. Exact identities remain in the M1 table; not rerun in this scoped final update |
| f | PASS at `8cac5c6f`; safe functional per-run fallback with unwritable clone directory |
| g | PENDING next quiet window on the rebuilt engine; explicitly not a merge blocker under the lead GO. No launch-gain claim until it passes |
| h | Shell 7 PASS on `8afd3cc1`; updater 97 emitted rows PASS then known #283 exception, later rows incomplete. Features 27 PASS at `8cac5c6f` remains separate |

`final-audit.json` confirms no owned job, App process or window remains;
all audited test caches are removed and updater test preferences are restored.
Both current Apps still match their artifact hashes. All 11 frozen pre-#271
file hashes and inodes remain unchanged. The earlier M1 DLV receipts remain
on M5 and its owned worktree remains removed. No system setting changed,
prohibited experiment ran or timing input changed. No row-g launch ran.

**Ready under the lead's explicit GO**, with the accepted timing FAIL,
known #283 updater case and open scan item preserved. Row g stays pending;
no current-engine launch gain is claimed. The lead owns the merge and engine
refresh. This agent has not merged the PR or changed another engine copy.

### 1.0.1 stale-cleanup lease guard (2026-11-13)

H2's after-first-paint cleanup can retire an inactive install directory under
an exclusive lease. A producer can have opened that lease before cleanup,
then acquire its lock after retirement. Lock conversion also has a scheduling
window. The old descriptor must not protect a newly recreated install path.

`open_code_sign_clone.cc::LeaseIsCurrent` compares `fstat(fd)` with
`lstat(install/lease)`: both must be regular files with one link and equal
`st_dev`/`st_ino`. The held lease must still belong to the user and have mode
0600. Checks run after initial shared acquisition, after exclusive conversion,
before a reuse return, and after the final shared conversion. A mismatch returns
`nullopt`; the unchanged manager then creates Chromium's per-run clone. Cloning
is never disabled.

The source guard was built at `3a9dd6c6`. The private Release framework is
`61709cc0c07de5a6c489ef692c0491bc6a303cc08fcdecf94ea9d8c06abf8121`,
UUID `4C4C44D5-5555-3144-A137-FBAB1476EFFE`. The OFFLINE incremental build
passed in 2m06.52s (51 executed steps, four local jobs). Shared source and
outputs were restored to `267b0ad8` before runtime qualification; strict
engine status was 8 PASS, 0 FAIL, 0 WARN.

The real-App comparison ran on fresh rental `0vak6f9flht7g`, macOS 27.2.
A diagnostic interposer in ignored evidence pauses the actual lease `flock`.
For lock conversions it exposes the permitted unlock/relock window. An
external cleanup process obtains EX, renames and deletes the owned install
directory, and a second real Open App recreates its clone. The original
producer then resumes its real `flock`. No shipping hook or substitute clone
implementation is involved. Each launch loads and reads a real renderer page.

| Case | Old engine `267b0ad8` | Guarded engine `61709cc0` |
|---|---|---|
| Fresh clone and ordinary reuse | PASS, shared lease held | PASS, shared lease held |
| Retirement before initial SH | Unsafe reuse: deleted lease retained, source link count 2 | Safe per-run fallback: stale fd closed, source link count 3 |
| Retirement during EX conversion | Same unsafe reuse | Same safe fallback |
| Retirement during final SH conversion | Same unsafe reuse | Same safe fallback |
| Real page text and renderer | PASS in all launches | PASS in all launches |
| Owned process/window cleanup | PASS | PASS |

The new safety predicate fails on the old engine in all three race cases.
Both final screen workers exit 0 with `safe=true`, no leaked group, no system
window and no crash. Earlier harness setup and ledger-path failures remain
separate, unqualified receipts; neither required an engine change.

Receipts are in `engine-items/.re/e3-clone-lease-101/`: `runtime.tar.gz`,
`runtime-summary.json`, `{old,candidate}/result.json`, `pause-lease.c`,
`lease-runtime.py`, `window-status.json` and the build/restore logs. These
records prove lease safety and runtime behavior; they make no timing claim.

At 08:40, the guarded overlay, official distribution and matching Release
framework/sample outputs were adopted in one normal heavy-slot transaction.
`adoption.json` records atomic directory exchanges and retained 267 rollback
directories; `adopt-status.json` records 8 PASS, 0 FAIL, 0 WARN. The distribution
pointer still names the official path. No M1 distribution or DMG was changed.
