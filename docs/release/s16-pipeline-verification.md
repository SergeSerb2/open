# Section 16 release pipeline receipt

Run date: 2026-11-07. Machine: M5 Pro, arm64, macOS 27.2.
Starting main: `df4767ad`. Branch: `s16/release-pipeline`.
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
| C-7 | Historical stock-CEF 329/279 MB measurements were not repeated. Current dev CEF binary is 460,839,664 bytes, so the old official-size budget cannot apply to this dev-only packaging exercise. Production's 320 MB hard gate stays active. | Recorded framework `stat`; current dry-run size rows below |
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

The `file://` feed is a shape and Ed25519 signature proof only. It is not an
App-consumable update feed. The lead reports Sparkle 2.10.1 rejects a file feed
with error 2001 in the updater-core work. No live-update claim is made here.

Results will be filled from the completed real run. Stamps are accepted only
when the phase inputs and output bytes agree. The second unchanged run must
report NO-OP for all 12 phases.

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

The last case proves the key-match gate itself, not production acceptance.
All cases stopped before Keychain/certificate lookup and notary calls. The
throwaway key files and checkout were deleted at the end.

## Review checklist

| Item from `docs/review-checklist.md` | Result | Evidence / scope |
|---|---|---|
| Input size/count/depth limits | PASS | URLs bounded to 4096 characters; remote feed curl capped at 4 MiB; pinned tools parse trusted local bundle inputs; no new untrusted page/list parser |
| Allocator ceiling | N/A | Shell orchestration; hashing streams 1 MiB blocks; no PartitionAlloc allocation added |
| Limit boundaries | PASS | Real CLI accepts a 4096-character URL and refuses 4097/control characters; key cases reject missing/mismatched inputs |
| Trailing/unknown data | PASS | Unknown CLI options fail; public key is strict base64 of 32 bytes; signature is strict base64 of 64 bytes |
| Callback can close caller | N/A | No application callback code changed |
| Double close/free | N/A | No application allocation/lifetime code changed |
| Unique UI IDs | N/A | No UI IDs added |
| Flush pending state | PASS | Smoke asks only its own PID to quit; reads saved sidebar state after clean process exit |
| Real keyboard paths | N/A | No key route or desktop input added |
| Key ownership after merge | N/A | No key route changed |
| Hidden command refusal | N/A | No command visibility changed |
| Checks detect the old defect | PASS | Old source only checked public-key/signature shape; wrong-key CLI now fails at the random-probe proof before release work |
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
