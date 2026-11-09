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
| b | Seven simple relaunches have no attributable ChangetimeScan | Not run; retain the initial clone and assessment warm-up logs separately |
| c | An in-place executable copy keeps the inode but recreates the clone | PASS, normal App; `stability/receipt.json` |
| d | Two install paths use distinct clones with no cross-reuse | PASS, normal App; `stability/receipt.json` |
| e | Live replacement passes with a reused clone in both ad-hoc and temporary hardened DLV builds | Main ad-hoc control FAIL: first new page stayed blank; branch swap not run. Both plain controls PASS, branch clone reused. DLV PENDING M1 clear |
| f | An unwritable cache falls back to a per-run clone and still works | PASS, normal App; full render and helper types; `adhoc-branch-plain-unwritable/receipt.json`. Fallback live swap not run |
| g | Seven interleaved main/branch pairs at load1 ≤ 12, plus window warm-profile rows | Pending on cleared M5; wait for load outside all locks |
| h | Shell, features, updater and engine-status pass | Shell PASS (7 rows); features PASS with intentional crash row DEFERRED to M1; engine-status: 7 PASS, 0 FAIL, 1 order WARN; updater pending |

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

The matrix stopped at this main control. The branch live-swap proof has not
run. This failure does not establish either a PASS or a failure of persistent
clone reuse after replacement. The saved extracts are
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
