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
This is a provisional control: any new main engine patch must be incorporated
and rebuilt before final matched evidence and distribution.

After the restart, the overlay metadata hardening was applied with
`engine-apply --all` (`hardening-apply.json`, exit 0). A focused build of
`open_code_sign_clone.o` and `code_sign_clone_manager.o` passed in 22 seconds
(`changed-objects.json`). The earlier full build was deliberately interrupted
with 30,928 steps done and zero failed; the resumed job keeps those outputs.
The S16 root audit was repeated (`root-path-resume-audit.json`): no s8 path
remains in state, `.gclient`, `args.gn` or `build.ninja`. `engine-status`
reported 7 PASS, 0 FAIL and the existing CEF series-order warning. That status
still refers to the previous distribution; it does not prove the new binary.

Runtime verification is pending the engine build. Required rows are stable
ctime/link count across three full runs after priming; seven simple relaunches
without ChangetimeScan; same-inode copy invalidation; two install paths;
live replacement with a reused clone for ad-hoc and temporary hardened DLV
copies; unwritable-cache fallback; seven interleaved launch pairs; window
warm-profile rows; shell/features/updater suites; engine-status and full gate.
No runtime result or performance gain is claimed yet.
