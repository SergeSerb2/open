# Section 16 release pipeline receipt

Run date: 2026-11-07. Machine: M5 Pro, arm64, macOS 27.2.
Starting main: `df4767ad`. Branch: `s16/release-pipeline`.
The final artifact uses source head `e8ba3901`, after merging `origin/main`
`ca56dff3` (#223 engine 0704 and #233 gate portability). The final full verifier
runs on that merged source. Later changes in this branch only update this
receipt and the release status text. Internal fetch/build commands select
`OPEN_RELEASE_HEAVY_WRAPPER` with Section 16's mandatory two-token wrapper.
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
| C-7 | Historical stock-CEF 329/279 MB measurements were not repeated. Initial dev CEF binary was 460,839,664 bytes; the #222 main view was 460,886,288 bytes, and the final #223 main view is 460,893,168 bytes, so the old official-size budget cannot apply to this dev-only packaging exercise. Production's 320 MB hard gate stays active. | Recorded framework `stat`; current dry-run size rows below |
| C-8 | Release args confirmed: official, PGO 2, ThinLTO, codecs on, Widevine off. Dev args changed: `symbol_level=0`, `enable_widevine=true`; phase 0 / official false remain. Release args override Widevine off. | `Engine/fork/gn/dev.args.gn`, `release.args.gn`; `VERSIONS` |
| C-9 | Not re-verified: this read-only main engine view has a distrib only. No official out directory or live PGO tree is available under this allowed root. The engine owner must establish the profile's current state. | `open-engine-s8-main/README.txt`; absence of official args/output in the view |
| C-10 | Confirmed in source: release packaging still fails with `release packaging not wired yet: CEF's make_distrib expects out/Release_GN_arm64`. No engine-distrib command was run against the view. | `Engine/fork/scripts/engine-distrib:29` |
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
exception is expected; no other release binary gains one. Preflight also rejects
DLV in the four other helper source files and all app CS exceptions. Four real
CLI runs added DLV to separate temporary helper inputs. Each failed before build
or key access; the actual source files stayed unchanged.
Receipt: `source-entitlement-guard.json`.

The lead's 2026-11-07 16:16 STOP-rule withdrew the earlier permission to launch
the exact ad-hoc artifact. That probe caused a dyld crash dialog. Its successful
wrapper exit did not make it acceptable. No exact artifact or mounted DMG app
will be launched again. Static `codesign -d --entitlements` and `-dvv` evidence
shows runtime and no Team ID; §4.4 predicts OpenEngine Library Validation refusal.

The only permitted launch is the **supplemental local-only launch copy,
disable-library-validation exception, not the shipped signature**, on the M1.
`--dry-run --smoke-only` refuses the M5. Before launch, it verifies the temporary
path, runtime/ad-hoc signature, and exact source dictionaries plus DLV for the
app and all five helpers. It copies from a read-only DMG mount, launches only
that temporary copy under the M1 screen lock, deletes it and its temporary
entitlements, and detaches. `m1-smoke.json` binds the result to the DMG hash.
The M5 summary accepts that receipt only for its exact DMG. Missing or mismatched
M1 evidence fails A-2/A-3/A-11. Receipt import invalidates only the summary stamp.
No failed-to-load build is relaunched.
If anything crashes, on-screen work stops and the lead is told. No mode of
`release.sh` launches an exact artifact. Production runtime rows require a
separately approved, DMG-bound lead receipt; this task creates none.

## Dry-run acceptance

Attempts 1–4 are retained as history, not current acceptance. Attempt 1 was
interrupted by an active script edit. Attempt 2 exposed macOS 27.2's default
text entitlement output; explicit `codesign --xml` fixed extraction. Attempt 3
exposed the pinned generator's unsigned dry enclosure; explicit `sign_update`
and independent public-key verification fixed it. Attempt 4 completed but its
exact-artifact launch caused the crash dialog addressed by the STOP-rule.
Its M5 supplemental launches and original no-op run do not prove the new policy.

The replacement protocol is M5 packaging/static checks, an M1-only temporary
copy smoke, receipt import, then an unchanged M5 run with 12 NO-OP phases.
Attempt 5 was stopped while queued for its build slot to close the remaining
production launch path. No app was launched by attempt 5. The first full M5 gate
was also stopped for the policy revision after 21 PASS rows; its trap printed
`sitecontrol-render FAIL 0`. That is an interrupted run, not a Site Control failure
or acceptance.

Attempt 6 completed packaging on `78617865`, then repeated all 12 phases as
NO-OP. It predated the strict missing-M1-receipt gate and is not full acceptance.
Attempts 7 and 8 also passed static packaging and stopped at the missing M1
receipt. They are superseded by the final merged-source attempt below.

Attempt 9 packages `e8ba3901`, after the #223/#233 main merge and source DLV
guard. It produces the final app, DMG, checksum and signed file feed. All static
artifact checks pass. It exits 1 only because the lead's M1 screen hold prevents
the required supplemental smoke. The unchanged second run has 12 NO-OP phases
and still exits 1. Pending smoke does not become a pass. No release app was
launched by attempts 6–9.

Final DMG: 202,582,754 bytes, SHA-256
`65f6bd643a517267a861a2590e9c15d8989909e7778c332a6d423bf79f9cf287`.
App disk use: 548,474,880 bytes. The dev engine exceeds the official size budget;
the production 320 MB hard gate stays active. Manifest dev framework SHA-256:
`c03a5109fc0d815770743a6c25a92d24bd1632eba6e658e00eb6e46314440c91`.
An earlier DMG and checksum passed transfer verification on the M1. The final
DMG has not been transferred or launched there. The lead must forward
**M1 clear** before any supplemental smoke. The unused detached M1 worktree
was removed during cleanup; no M1 app was launched.

Attempt 9 load averages: 14.80 / 38.03 / 51.19 → 14.94 / 29.83 / 46.09.
No-op loads: 14.94 / 29.83 / 46.09 → 14.94 / 29.83 / 46.09.
These are functional receipts, not timing acceptance.
Logs: `dry-run-9-final-m5.log`, `dry-run-9-noop.log`.

| §9.4 row | Result | Evidence / limit |
|---|---|---|
| A-1 Engine provenance | mode-SKIP | Main #223 dev distribution; manifest records root and framework hash. No official output exists in the permitted view. |
| A-2 Launch | BLOCKED (script FAIL) | M1 screen hold. No accepted launch of the final artifact's supplemental copy. |
| A-3 Helpers / JIT | BLOCKED (script FAIL) | Required M1 renderer, GPU and JavaScript smoke has not run. |
| A-4 Signature | PASS | Inside-out ad-hoc runtime signing; deep/strict verification; all six sealed entitlement dictionaries equal source. |
| A-5 Gatekeeper | mode-SKIP | Ad-hoc, no notarization acceptance claimed. |
| A-6 Staple | mode-SKIP | No ticket or credential used. |
| A-7 Size | mode-SKIP | App 548,474,880 bytes; DMG 202,582,754 bytes. Dev engine is above the production hard limit. |
| A-8 Locales | PASS | Exact `en` set; required resources and arm64-only binaries present. |
| A-9 Symbols | PASS | No dSYMs in the app. Official symbol archive remains open. |
| A-10 Automation | PASS | No automation socket string or compile flag in the Release binary/build log. |
| A-11 DMG | Static PASS; smoke BLOCKED (script FAIL) | `hdiutil verify`, attach read-only, verify mounted signature and exact entitlements, detach. Mounted app never launched. |
| A-12 Feed | PASS, shape/signature only | XML and current item fields pass; CryptoKit verifies Ed25519 with the throwaway public key. |
| A-13 Real update | mode-SKIP | No shipped predecessor or updater-consumption claim. |
| A-14 About / credits | mode-SKIP | Incomplete preview generated; full Chromium credits, U-8 source offer and native About proof remain open. |
| A-15 Secrets | PASS | Outputs ignored; no private-key files/PEM; temporary key removed. |

The `file://` feed proves shape and Ed25519 signatures only. Pinned Sparkle
2.10.1 rejects file feeds in the real App (lead: error 2001). No App update
consumption is claimed.

## Full M5 verifier

The Section 16 wrapper ran `tools/verify-all.sh --with-arc-data` on
`e8ba3901`: **25 PASS, 0 FAIL, 0 SKIP**, exit 0. Full-run loads were
14.94 / 29.83 / 46.09 → 16.97 / 13.78 / 22.09. Command-bar rows pass
151/151: CPU p95 2.85 ms (<8), completion overhead p95 +0.070 ms (≤0.3),
at printed load 10.0 / 17.2 / 29.8. No threshold or baseline changed.
Raw evidence: `.re/s16/release-pipeline/verify-all-3/` in the lead project.

| Check | Result | Seconds, including lock waits |
|---|---|---:|
| build | PASS | 40 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 241 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 32 |
| commands-dump | PASS | 0 |
| route | PASS | 16 |
| favicons | PASS | 3 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 4 |
| settings-preview | PASS | 82 |
| sidebar-render | PASS | 111 |
| sidebar-compare | PASS | 107 |
| commandbar-render | PASS | 33 |
| features-render | PASS | 89 |
| extensions-render | PASS | 7 |
| sitecontrol-render | PASS | 376 |
| boosts | PASS | 3 |
| import-arc | PASS | 3 |
| verify-secrets-fixture | PASS | 8 |

Earlier full run `verify-all-2` on `87647e2f` had 24 PASS and one timing FAIL:
command-bar CPU p95 9.97 ms at printed load 21.8 / 31.0 / 28.1. Full-run loads
were 21.41 / 21.02 / 18.35 → 12.48 / 16.54 / 21.72. That failed attempt stays
recorded; the final merged run above passes the same strict rows.

No quiet timing receipt exists. The lead stopped queued wrapper PID 85251 under
the 17:27 ruling before any timing check started; later load exceeded 200.
TANDEM §3.4l treats that miss under load as nonblocking. The final full gate
passes without a dedicated timing rerun. Every later heavy call uses the Section
16 token wrapper. No targeted timing run may start at load1 > 20.

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
| M5 launch refusal | PASS | Final merged `--dry-run --smoke-only` exits 1 at the M1-only guard; no launch. |
| Source DLV drift | PASS | Four real temporary-input CLI cases refuse DLV in generic/GPU/renderer/alerts source before build or key access. |
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
| Flush pending state | BLOCKED for M1 proof | Code asks only its own PID to quit and checks saved sidebar state after clean exit; that runtime smoke awaits M1 clear |
| Real keyboard paths | N/A | No key route or desktop input added |
| Key ownership after merge | N/A | No key route changed |
| Hidden command refusal | N/A | No command visibility changed |
| Checks detect the old defect | PASS | Real CLI break-and-restore: wrong key refused → verifier removed and mismatch accepted through probe → verifier restored and wrong key refused; no certificate/notary lookup |
| Pixel checks | N/A | No image comparison added |
| Exact dialog identity | N/A | No dialog check added; no generic-window success claim |
| Timing logic | N/A | No new performance acceptance row; functional polling has a fixed timeout |
| Isolated data/ports | PASS (static) | Code uses a new data root and ephemeral CDP port; release lock excludes same-version writers. Concurrent real-App proof has not run |
| No human/cleanup | BLOCKED for M1 proof | The earlier exact-artifact probe caused a crash dialog and was withdrawn. Final M5 failure exits clean up keys, mounts and the release lock. Guarded M1 temporary DLV launch/cleanup proof waits for M1 clear. No desktop input. |
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
