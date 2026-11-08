# Code-sign clone candidate: stopped at the live-swap gate

The unconditional App-side disable is **not ready to merge**. It prevents the
executable ctime change during a normal run, but the ad-hoc build failed new
navigation after live bundle replacement. The enabled-clone control passed.
The required stop rule ended further experiments. No alternative fix was chosen.

## Source evidence

Chromium's `chrome/browser/mac/code_sign_clone_manager.h:20–37` explains the
protection: a reachable hard link, surrounded by the original valid bundle,
keeps static and dynamic signature validation valid after a staged update.
`HardLinkMainExecutable` in the matching `.mm:282–301` calls `link()` at line
294. Link creation and removal advance the original executable's ctime.
The source was read only in the authorized `open-engine-s8` tree.

Sparkle 2.10.1 waits for its host to terminate before final replacement.
`Autoupdate/AppInstaller.m:401–417`, `739–743` and `764–800` establish that
ordering. `SUPlainInstaller.m:235–245` attempts a whole-directory swap;
`Sparkle/SUFileManager.m:360–362` calls `renamex_np(..., RENAME_SWAP)`.
The fallback renames the old bundle aside and the new bundle into place
(`SUPlainInstaller.m:279–311`). `performCleanup` removes staging directories.
Open uses the standard Sparkle updater for its host bundle. This source argument
applies to that normal install order, not to external live replacement.

## Real-App method and artifacts

Main was frozen from `16732fdb`; the candidate implementation is `6a900c0e`.
Both Release controls used the same authorized engine view and the same embedded
CEF binary SHA-256:
`24d7d6f5e9ee25da0a4a890fe12b73b5fa0c30046c34acd0ce1c7e4c7cb8d6e0`.
Builds used `s16-heavy.sh`; Debug also passed in 57.37 s at load1 15.68→39.20.

Each functional case held the M5 screen lock. It used a temporary bundle copy
and a unique synthetic profile. It loaded a local HTTP fixture and required DOM
readiness, renderer, GPU and utility processes. The caller supplied an existing
`HardwareMediaKeyHandling` disable; the branch helpers retained it along with
`MacAppCodeSignClone`. No DYLD hooks, root tools or desktop input were used.

For the swap, the harness copied the other build to the same volume, called
`renamex_np(..., RENAME_SWAP)`, then removed the old staging bundle. It sent
SIGTERM to the owned GPU and network service to require fresh helpers, and
opened three distinct local test sites. The two intentional exit-15 messages
are expected. They are not code-signing kills.

Local evidence root: the project checkout's
`.re/s16/codesign-clone-off/`. `BUILD-PROVENANCE.json` records App/framework
hashes and build loads. `preflight-sources.json` records source hashes.
`swap.py`, `matrix.py` and `atomic-swap.c` preserve the procedure. These are
stopped research artifacts, not an instruction to rerun the failed candidate.
Each case directory contains `receipt.json`, App stderr and `unified.ndjson`.
The enabled swap also has the rendered window and all three DOM results.

## Results on 2026-11-08

These were functional checks at unrestricted load. Their launch marks are not
timing evidence and no performance gain is claimed.

| Shape / clone | Plain run | Live swap | load1 before→after (plain; swap) |
|---|---|---|---|
| Ad-hoc / enabled (main) | PASS; ctime changes, links 1→2→1 | PASS; three new sites render; fresh renderer/GPU/utility PIDs | 6.29→6.51; 11.71→12.66 |
| Ad-hoc / disabled (branch) | PASS; ctime and link count unchanged | FAIL; first new site times out; process signature validation fails | 9.86→10.03; 12.37→10.97 |
| Hardened runtime + temporary DLV / enabled | NOT RUN after stop | NOT RUN after stop | — |
| Hardened runtime + temporary DLV / disabled | NOT RUN after stop | NOT RUN after stop | — |

The pipeline-shaped copies were prepared and checked statically with hardened
runtime and the committed App/helper entitlements plus DLV. Neither was launched.
No exact `release.sh` artifact was launched, and no source entitlement changed.

The plain branch executable stayed at ctime `1794161142991464126` ns and link
count 1 before, during and after the full run. Its inode and mtime also stayed
fixed (`adhoc-branch-plain/receipt.json`). The main negative control changed
ctime from `1794160883434602261` to `1794160890379723949` ns, with a live link
count of 2 and final count of 1 (`adhoc-main-plain/receipt.json`).

With the clone enabled, fresh renderer PIDs were 27480, 27558 and 27560; the new
GPU PID was 27478 and the new utility PID was 27479. All three new origins
returned `SWAP_RENDER_OK` and DOM readiness (`adhoc-main-swap/receipt.json`).

With the clone disabled, replacement completed at 11:06:19.136. At 11:06:19.208,
browser PID 27681 logged:

> Unable to derive validation category for current process. Signature validation
> of current process failed: Error Domain=NSOSStatusErrorDomain Code=-67065

Evidence: `adhoc-branch-swap/app.log.launch-1794161173659429000.log:7`.
The first new site's `wait` returned `timeout waiting for load`; the receipt is
FAIL. In Chromium `base/mac/process_requirement.cc:151–162`, that message follows
a failed `SecStaticCodeCheckValidity` for the running process. This supports the
clone's documented signature protection. It does not establish an AMFI kill.
The harness retained initial process state and cleanup PIDs; it did not capture
the failed tab's full state before cleanup, so no fresh-helper success is claimed
for that case.

The case log queries included syspolicyd, amfid, kernel and runningboardd, plus
messages containing CODESIGNING, AMFI or `Killed: 9`. No new real Open/Helper
`.ips` or corresponding code-signing SIGKILL was found. Routine ad-hoc-signature
warnings also occur in the passing control and are not evidence of a kill.
`signing-process-evidence.json` preserves the relevant log-line indices.
The disabled case's `Killed: 9` lines 6649–6650 belong to launchd cleanup of
`com.apple.SetStoreUpdateService`, after the browser quit with status 0
(lines 6651–6652). The passing control also has such Apple service cleanup
(`com.apple.MTLCompilerService`, lines 2717–2718). Neither identifies a killed
Open helper.
Both cases ended with no owned processes or windows; crash-dialog settings were
restored. Unused pipeline temporary copies were removed (`STOP.json`). No screen
work continued after the failed case.

## Pending lead decision

Disabling the clone trades its live-replacement signature protection for stable
ctime. The supported Sparkle termination order does not make the failed manual
replacement case pass. The requested merge gate therefore failed even before
the hardened-runtime matrix could run.

The seven simple-launch scan checks, seven paired timings, Release window rows,
shell/features/updater suites, final main merge and full verify-all remain
unrun for this candidate. They were stopped deliberately, not marked PASS or
SKIP. No PR was opened and no replacement fix was implemented.
