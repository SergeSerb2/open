# Section 16 release pipeline receipt

Run date: 2026-11-07. Machine: M5 Pro, arm64, macOS 27.2.
Starting main: `df4767ad`. Branch: `s16/release-pipeline`.
The dry run includes main through `eaa70c28`. Before full verification, merged
`origin/main` at `7f405f3b` (only the software-update RE document was added).
All App builds use `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`.
No engine tree, Keychain, certificate, notary profile, tag, upload or public
hosting setting was changed. No unit tests or desktop input were used.

## Plan §0 re-check

These checks use the current main source and its recorded dev distribution.
The child rules prohibit reads of the shared Chromium tree. That boundary means
C-6's upstream entitlement files and C-9's live PGO profile cannot be re-checked
here. This is an explicit evidence gap, not a current confirmation of old facts.

| Row | Result / drift from the 2026-10-25 snapshot | Current evidence |
|---|---|---|
| C-1 | Confirmed: `0.1.0`, build `1`; plist uses build setting substitutions. | `project.yml` base settings; `App/Info.plist` |
| C-2 | Confirmed: local builds use ad-hoc signing, Manual style, empty development team and runtime NO. | `project.yml` base settings |
| C-3 | Changed: IDs already use `io.github.sergeserb2.open`, `.engine`, `.helper` and role suffixes. | `project.yml` targets and helper template |
| C-4 | Confirmed: five helpers; embed script copies CEF and helper bundles and signs copied CEF code. | `tools/embed-cef.sh`; `project.yml` |
| C-5 | Changed: app now has all seven §4.2 device/privacy entitlements, including photos-library; no CS exception. The five helper dictionaries still match §4.2. | `plutil -lint App/Open.entitlements Helper/Entitlements/*.entitlements`: all six OK |
| C-6 | Partial: the recorded distribution README confirms required framework/data/snapshot and optional locales/SwiftShader. Shared-tree upstream entitlement files were not read. SwiftShader remains required by Open's release policy. | Recorded `README.txt`, REDISTRIBUTION; `tools/release.sh` bundle check |
| C-7 | Historical stock-CEF 329/279 MB measurements were not repeated. Initial dev CEF binary was 460,839,664 bytes; the refreshed #222 main view is 460,886,288 bytes, so the old official-size budget cannot apply to this dev-only packaging exercise. Production's 320 MB hard gate stays active. | Recorded framework `stat`; current dry-run size rows below |
| C-8 | Release args confirmed: official, PGO 2, ThinLTO, codecs on, Widevine off. Dev args changed: `symbol_level=0`, `enable_widevine=true`; phase 0 / official false remain. Release args override Widevine off. | `Engine/fork/gn/dev.args.gn`, `release.args.gn`; `VERSIONS` |
| C-9 | Not re-verified: this read-only main engine view has a distrib only. No official out directory or live PGO tree is available under this allowed root. The engine owner must establish the profile's current state. | `open-engine-s8-main/README.txt`; absence of official args/output in the view |
| C-10 | Confirmed in source: release packaging still fails with `release packaging not wired yet: CEF's make_distrib expects out/Release_GN_arm64`. No engine-distrib command was run against the view. | `Engine/fork/scripts/engine-distrib:28` |
| C-11 | Confirmed: no Team ID selects the mock Keychain path; Developer ID selects Open Safe Storage. No credential was queried. | `App/main.swift`, `configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier` |
| C-12 | Changed: Sparkle 2.10.1 is linked. The OpenKit menu owns the visible commands. `check-for-updates` routes to the Settings stub. `App/UpdaterController.swift` is absent. | `project.yml`; `App/AppDelegate.swift`; `App/Settings/AppSettingsActions.swift`; `test -f App/UpdaterController.swift` fails |
| C-13 | Changed: the source generator and license inventory exist. Release staging generates Credits.rtf and a text twin. Native About rendering still needs a real artifact-bound receipt. | `tools/generate-acknowledgements.py`; `docs/release/licenses.md` |
| C-14 | Confirmed remote URL. `gh repo view --json visibility` says PRIVATE. `gh release list`, `git tag -l`, and `git ls-remote --heads origin gh-pages` returned no release, tag or Pages branch. No public endpoint is established. | Read-only GitHub/git commands, 2026-11-07 |
| C-15 | Changed: `Engine/fork/licenses/THIRD_PARTY.md` has the vendored dependency inventory, not one planned row. The release inventory still contains older “not yet linked” descriptions. Full Chromium credits are only the 401-byte sample. U-6 review and U-8 public source offer remain open. | `Engine/fork/licenses/THIRD_PARTY.md`; `docs/release/licenses.md`; recorded CREDITS.html |

## Sparkle tool provenance

The pinned tools already existed; no install or key generation was needed.
`~/Developer/open-release-tools/sparkle-2.10.1/UPSTREAM.json` records archive SHA-256
`1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`.
The current GitHub release API asset digest for `Sparkle-2.10.1.tar.xz` agrees.
A fresh download had the same SHA-256. All three installed executables were
byte-identical to that verified archive.
Both installed tools' help supports `--ed-key-file` and `--account`.
The default account is `ed25519`, not the account name in the old plan.
`generate_keys -h` was read; `generate_keys` was never run in a key-access mode.

## Signing and launch boundary

The release app and the app inside the DMG keep the exact committed entitlement
dictionaries for the app and all five helpers. The script compares sealed plist
dictionaries to the source files. The plugin helper's existing Library Validation
exception is expected; no other release binary gains one.

The lead approved only this separate smoke path on 2026-11-07:
**supplemental local-only launch copy, disable-library-validation exception,
not the shipped signature**. The script copies the source app to a temporary
directory, creates temporary entitlement files, re-signs the app and helpers
with runtime enabled, exercises the page/helpers/JavaScript, and deletes the
copy and entitlement files. It repeats this with a copy read from the mounted
DMG. This never proves that the exact ad-hoc release signature can launch.
The exact artifact's Library Validation refusal is recorded as an expected
dry-run limit. Production keeps exact entitlements and requires a Team ID.

## Dry-run acceptance

Retained attempts: attempt 1 built Release successfully, then was interrupted
by editing the active shell script. Attempt 2 built and deeply verified the
signed app, then failed at the entitlement parser. macOS 27.2 prints a text
dictionary by default; `codesign --xml` fixes the extraction without changing
any signing policy. Attempt 3 reached a valid DMG but the pinned appcast generator emitted no
EdDSA enclosure signature for the dry archive. The script now uses `sign_update`
explicitly for dry enclosures and verifies with the throwaway public key. These
attempts are not acceptance runs.

The `file://` feed is a shape and Ed25519 signature proof only. It is not an
App-consumable update feed. The lead reports Sparkle 2.10.1 rejects a file feed
with error 2001 in the updater-core work. No live-update claim is made here.

Attempt 4 completed with exit 0. Its unchanged second run also exited 0 and
reported **NO-OP for all 12 phases**. Stamps compare phase inputs and output
bytes. The second run performed no build, signing, DMG creation or launch.

Command: `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main tools/release.sh --dry-run`.
The script takes a heavy slot for fetch/build and the on-screen lock for each
launch. It honors the on-screen priority flag. No production credential was read.

| §9.4 check | Result | Evidence / limit |
|---|---|---|
| A-1 Official engine | mode-SKIP | Main dev distribution; no official ThinLTO/PGO output. Manifest records root and binary hash. |
| A-2 Launch/page/sidebar/quit | PASS, supplemental only | Real Example Domain title; saved sidebar tab; clean PID-targeted quit. |
| A-3 Helpers/JavaScript | PASS, supplemental only | Own renderer and GPU descendants; dynamic JavaScript function and hot loop returned the expected result. |
| A-4 Signature | PASS | Inside-out ad-hoc runtime signing; `codesign --verify --deep --strict`; exact six source entitlement dictionaries. |
| A-5 Gatekeeper | mode-SKIP | No Developer ID or notarization acceptance claimed. |
| A-6 Stapling | mode-SKIP | No notary ticket or credential used. |
| A-7 Size | mode-SKIP | App 548,438,016 bytes; dev framework exceeds official budget. DMG 202,592,656 bytes. Production hard limit stays 320 MB. |
| A-8 Locales | PASS | Exact set `en`; required engine resources and arm64-only binaries present. |
| A-9 Symbols excluded | PASS | No dSYMs in the app. Official symbol archive remains open. |
| A-10 Automation excluded | PASS | No automation socket string or compilation flag in the Release binary/build log. |
| A-11 DMG | PASS, supplemental launch only | `hdiutil verify`; attach read-only; verify mounted app signature and exact entitlements; smoke a temporary copy; detach. |
| A-12 Feed | PASS, shape/signature only | `xmllint`; exact enclosure URL/length/version/OS; CryptoKit verifies Ed25519 with throwaway public key. |
| A-13 Real update | mode-SKIP | No shipped predecessor or real updater-consumption proof. |
| A-14 About/credits | mode-SKIP | Incomplete preview generated; sample Chromium credits, U-8 offer and native About receipt still open. |
| A-15 No secrets | PASS | Outputs ignored; no private-key files/PEM; throwaway seed removed. |

A-2/A-3/A-11 use the **supplemental local-only launch copy,
disable-library-validation exception, not the shipped signature**. Both the
local-app copy and mounted-DMG copy passed all six smoke fields. The exact
artifact exited with signal 6; its log names OpenEngine and the missing Team ID.
This expected Library Validation refusal is not a successful launch.

| Artifact | SHA-256 |
|---|---|
| `Open-0.1.0.dmg` | `e701e3c548755568b00c896bfadadc796a1b6498a60f3230a737c0544b31a70a` |
| `appcast.xml` | `6dc1e731e1ea119dd7bc777d77c4bd6a263057a1378cc457528980b8b5d99c39` |
| Dev framework | `2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10` |

The DMG is unsigned (`codesign -dv` exits 1: code object is not signed at all).
The app inside it is signed. After completion, no release mount, temporary launch
copy, temporary entitlement file, throwaway-key directory, or owned Open process
remained. The release lock was removed.

Raw logs remain in the private `.re/s16/release-pipeline/` receipt directory:
`dry-run-4.log`, `dry-run-noop.log`, and the preflight/provenance receipts.
The artifact folder holds the manifest, checksum, feed/public key, exact-launch
receipt, two smoke receipts and the machine-readable acceptance table.

| Run | Local time | Load averages before → after | Exit |
|---|---|---|---|
| Accepted dry run | 15:47–15:54 | 16.82 / 19.71 / 21.60 → 17.97 / 15.19 / 18.31 | 0 |
| Unchanged rerun | 15:54 | 28.78 / 17.99 / 19.23 → 28.16 / 18.04 / 19.24 | 0 |

These loads describe functional checks. They are not quiet-machine timing proof.

## Preflight failure cases

The real `tools/release.sh --preflight-only` command ran in a temporary input
checkout. It used the pinned Sparkle tools and two random file-based keys outside
that checkout. No tool was mocked. The temporary plist held only a throwaway
public key. The worktree's source plist and all real credentials stayed untouched.

| Case | Real result |
|---|---|
| No identity environment variable | Exit 1; names `OPEN_SIGN_IDENTITY` and U-2 |
| Source public-key placeholder | Exit 1; names `OPEN_SPARKLE_KEY_ACCOUNT` / `OPEN_SPARKLE_KEY_FILE` and U-4 |
| Private key differs from plist public key | Probe is signed, public-key verification fails, exit 1; names U-4 |
| Matching private/public key | Probe verification passes; then exit 1 at main's missing Step 8 updater controller, before certificate lookup |
| Feed URL at 4096 characters | Exit 0 in dry preflight |
| Feed URL at 4097 characters | Exit 1; names `OPEN_RELEASE_FEED_URL` and U-8 / U-5 |
| URL containing a newline | Exit 1 before bundle or feed work |
| Missing pinned tools directory | Exit 1; names `OPEN_SPARKLE_TOOLS` and U-4 |
| Valid private seed padded to 4096 bytes | Public-key probe passes; no Keychain access |
| Same key file at 4097 bytes | Exit 1 at the file-size gate, before Sparkle reads the key |

The matching-key case proves the key-match gate itself, not production acceptance.
All cases stopped before Keychain/certificate lookup and notary calls. The
throwaway key files and checkout were deleted at the end.

A separate real-CLI break-and-restore run used another temporary checkout and
two throwaway keys. Intact code refused the mismatch. Removing only the
public-key verifier invocation let that same mismatch pass the probe gate and
reach the missing Step 8 prerequisite. Restoring the invocation refused it again.
All three commands exited 1 before any certificate or notary lookup. The broken
script and private keys were deleted. Receipts: `preflight-break-intact.log`,
`preflight-break-broken.log`, `preflight-break-restored.log`, and
`preflight-break-proof.json`.

## Static and guide checks

| Check | Result | Evidence |
|---|---|---|
| Bash 3.2 syntax | PASS | `/bin/bash` 3.2.57; `/bin/bash -n tools/release.sh` exits 0. |
| Whitespace | PASS | `git diff --check` exits 0. |
| Source entitlement plists | PASS | `plutil -lint App/Open.entitlements Helper/Entitlements/*.entitlements`: six OK. |
| U-7 verification command | PASS, local fixture | Exact guide command downloads the dry DMG, compares its approved checksum/length and verifies the enclosure with the throwaway public key. No production endpoint or update consumption claimed. |

## Review checklist

| Item from `docs/review-checklist.md` | Result | Evidence / scope |
|---|---|---|
| Input size/count/depth limits | PASS | URLs bounded to 4096 characters; private-key files bounded to 4096 bytes; remote feed curl capped at 4 MiB; pinned tools parse trusted local bundle inputs; no new untrusted page/list parser |
| Allocator ceiling | N/A | Shell orchestration; hashing streams 1 MiB blocks; no PartitionAlloc allocation added |
| Limit boundaries | PASS | Real CLI accepts a 4096-character URL and a valid 4096-byte key file; refuses 4097, control characters and mismatched keys |
| Trailing/unknown data | PASS | Unknown CLI options fail; public key is strict base64 of 32 bytes; signature is strict base64 of 64 bytes |
| Callback can close caller | N/A | No application callback code changed |
| Double close/free | N/A | No application allocation/lifetime code changed |
| Unique UI IDs | N/A | No UI IDs added |
| Flush pending state | PASS | Smoke asks only its own PID to quit; reads saved sidebar state after clean process exit |
| Real keyboard paths | N/A | No key route or desktop input added |
| Key ownership after merge | N/A | No key route changed |
| Hidden command refusal | N/A | No command visibility changed |
| Checks detect the old defect | PASS | Real CLI break-and-restore: wrong key refused → verifier removed and mismatch accepted through probe → verifier restored and wrong key refused; no certificate/notary lookup |
| Pixel checks | N/A | No image comparison added |
| Exact dialog identity | N/A | No dialog check added; no generic-window success claim |
| Timing logic | N/A | No new performance acceptance row; functional polling has a fixed timeout |
| Isolated data/ports | PASS | Each smoke uses a new data root and ephemeral CDP port; release lock excludes same-version writers |
| No human/cleanup | PASS | PID-targeted quit, finally cleanup of owned process group, EXIT cleanup of temporary copy/keys/mount; no mouse/keyboard automation |
| Reduce Motion | N/A | No motion changed |
| Interrupted animation | N/A | No animation changed |
| Resize/hide animation | N/A | No geometry changed |
| Real-window visual parity | N/A | Release orchestration only; no visual parity claim |
| Current comments/docs | PASS | Plan errata, user guide, receipt, §1.20 and release follow-ups state explicit local/production limits |
| Plan/follow-ups/PR agreement | PASS | Same source, credential, artifact and live-updater gates in all three |

## Remaining public-release gates

- Official ThinLTO/PGO engine, distribution packaging, and local symbol archive.
- Complete Chromium/codec credits and refreshed linked-component inventory.
- Step 8 updater controller, menu/Settings wiring, and channel routing.
- Native About receipt and a real predecessor update, where applicable.
- Final notes and a new build number before anything leaves this Mac.
- U-1…U-8 setup, review and per-release publish approval. U-9 is not defined.

Changes outside the allowed files need the lead's approval. This PR does not
implement the updater controller or engine packaging.
