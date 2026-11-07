# Local CRX completion 0704: final receipt

2026-11-07, M5 Pro. PR #223 targets `main`, after merging `eaa70c28`
(PR #222). Later main commit `7f405f3b` only adds software-update RE docs;
there is no overlapping source update to chase.

0704 uses Section 10's next number in the **03xx extensions area**. It adds
`OEExtensionManager.installLocalCRX(_:completion:)` and the generated export
`cef_install_local_crx`. The result is installed with the live registry ID,
cancelled, or failed with Chromium text, exactly once on a later main-queue turn.
The old page-based selector remains a wrapper. The Web Store path is unchanged.

Chromium 156 calls its API `CrxInstaller::AddInstallerCallback`, rather than
`set_installer_callback`. The manager retains at most 32 installers, removes
requests before delivery, uses non-recycled IDs and weak owners, and settles
pending requests on context closure. The bridge clears its block before main-queue
delivery. Evidence: `open_extension_manager.mm:329`, `:427`, `:170`;
`OEExtensions.mm:271`; `OEExtension.h:220`; real-App gate `extensions_p3.py:60`.

## Engine and App

Only `~/Developer/open-engine-s10` was changed. Engine jobs ran detached under
`/usr/bin/lockf -k /tmp/open-engine-build.lock`, with 10 jobs and the scripts'
nice setting. App and verify jobs used `s10-heavy.sh`. Every build/check exported
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s10`. Every App run used one suite
per `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock` invocation, with priority and
front-app checks. No PR merge, child agent, sync, unit test, debugger attach,
desktop input, or other engine-root change ran.

Framework SHA-256: `c03a5109fc0d815770743a6c25a92d24bd1632eba6e658e00eb6e46314440c91`.
Framework size: 460,893,168 bytes. App and Vendor normalized code fingerprints
matched in every completed App run.

| Command | Result | Load (1/5/15 min), start to end |
|---|---|---|
| `engine-apply --all` | PASS: 23 already applied; 2 overlays copied; CEF API regenerated | (23.60, 15.04, 12.57) to (25.89, 15.80, 12.87) |
| `engine-build --target "cefsimple cefclient" --jobs 10` | PASS, 189 s | (25.89, 15.80, 12.87) to (50.95, 40.25, 24.21) |
| `engine-distrib --run --skip-build` | PASS | (50.95, 40.25, 24.21) to (21.90, 33.47, 23.14) |
| `engine-status --strict` | PASS 8/8; 117 CEF patches, 23 Open patches, 53 overlays, 32 symbols; 0 FAIL/0 WARN | (13.86, 29.56, 22.28) to (13.31, 29.18, 22.19) |
| `s10-heavy.sh tools/build.sh Debug` | PASS, 124.9 s | (12.81, 28.82, 22.10) to (16.73, 24.22, 21.13) |
| Negative Debug build | PASS; 310 s machine-slot wait | (37.20, 28.51, 22.98) to (16.24, 26.61, 24.62) |
| Restored Debug build | PASS, 11.8 s | (21.07, 20.72, 22.02) to (20.28, 20.56, 21.95) |

App-build loads include queue time. The first strict-status JSON export used a
refused output path; the final export under the engine state directory passed 8/8.

## Real-App results

Command: `python3 tools/e2e/engine_e2e.py --style chrome --config Debug
--only SUITE --engine-sha256 c03a5109fc0d815770743a6c25a92d24bd1632eba6e658e00eb6e46314440c91`, plus the private unpacked-extension fixture
directory for regressions. Loads below are App-start to job finish. Each completed
run passed owned-process cleanup.

| Run | Result | Load (1/5/15 min) |
|---|---|---|
| `p3-positive` | 19 PASS / 0 FAIL | (17.81, 23.87, 21.09) to (39.82, 28.70, 22.98) |
| `p3-negative` | EXPECTED FAIL: signature timeout, events=[] | (18.36, 20.07, 22.03) to (21.17, 20.61, 22.03) |
| `p3-restored` | 19 PASS / 0 FAIL | (11.40, 14.88, 19.09) to (11.83, 14.58, 18.80) |
| `extensions` | 7 PASS / 1 FAIL | (13.67, 14.61, 18.55) to (13.18, 14.35, 18.29) |
| `extensions-retry2` | 7 PASS / 1 FAIL | (7.42, 11.75, 16.17) to (8.04, 11.45, 15.90) |
| `extensions-ui` | 66 PASS / 1 FAIL / 1 BLOCKED | (28.16, 18.04, 19.24) to (25.95, 20.69, 20.15) |
| `extensions-ui-retry2` | 71 PASS / 0 FAIL / 1 BLOCKED | (7.22, 8.29, 11.91) to (5.13, 7.30, 11.07) |
| `actions` | 26 PASS / 0 FAIL | (19.62, 18.48, 19.23) to (28.01, 20.63, 19.97) |

The positive and restored P3 runs each passed **19/19**. The five 0704 rows prove:
signed CRX installs with its registry ID; damaged RSA signature returns failed
with `Package is invalid: 'CRX_SIGNATURE_VERIFICATION_FAILED'.`; Cancel has no
ID/error; every request completes once on the main thread; fixtures are removed.
Duplicate consent answers do not duplicate completion delivery.

For the negative proof, only the block invocation in
`OELocalInstallCompletion::OnComplete` was suppressed. The signature row failed
with `timedOut=true` and `events=[]`; old-selector P3 rows and cleanup still passed.
The source was restored byte for byte, rebuilt, and P3 passed 19/19. Original and
restored source SHA-256:
`755c900f6b8f2252881024191f339762f84cb69f0e5f7fa1e0e03e640e46c3cc`.
No injected edit remains.

One queued retry yielded to another section's priority flag without launching
Open. A queued UI command with a mistyped fingerprint was cancelled before launch
and replaced with the recorded hash. System prompts were never dismissed.

## Regression findings and remaining boundaries

- `extensions` failed the uBlock popup row twice: `eval: no page for 6`, then
  `eval: no page for 5`. The other popup providers and Web Store install passed.
  This remains **FAIL**, without a clean main control.
- The first `extensions-ui` run passed 66 rows, then failed with
  `ext-click: Little Open Extensions button did not open its menu`.
  The result table records its diagnostic rerun. Its existing `X13_picker` row
  is BLOCKED by a Site Control presenter/data-source stub.
- The Section 10 main-worktree App includes local `ProfileTeardown.swift` edits,
  so it did not qualify as an unchanged-main control. No other thread's source,
  App, build, or engine root was changed for a control run.
- Section 14's blocked engine-error row is **not runnable on this branch**:
  `App/Import/AppImportExtensions.swift:83` still calls the old initiation selector;
  `firstrun_extensions.py:222` emits BLOCKED and substitutes a missing-file App
  failure. Section 14 must adopt the completion API and rerun its damaged-signature
  queue row. The direct engine completion is proved by 0704's real-App rows.
- Path/count/text at/over-limit runtime rows and a dedicated context-close runtime
  row remain unverified. Their bounds/lifetimes received source review.
- No drawing/UI change needs a 2x display rerun for 0704.

## Full verify-all

**23 PASS / 1 FAIL.** `sitecontrol-render` passed 1547/1548 assertions but
failed `F25 registered native harness produced its result`. Its native
performance diagnostics ran at load1 5.32 and 8.23. This is not either named
main import bug, and no clean main control has qualified it. A focused rerun
is queued under the Section 10 token limit; the original failure stays recorded.

Command: `s10-heavy.sh tools/verify-all.sh`, with the owned engine root exported.
The machine-slot wait was 210 seconds. Execution-start load: (14.14, 19.39, 19.49);
final load: (7.96, 7.69, 10.76). No baseline, comparator, threshold, or allowlist changed.

| NAME | RESULT | SECONDS |
|---|---|---|
| build | PASS | 141 |
| commands-demo | PASS | 4 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 296 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 28 |
| commands-dump | PASS | 0 |
| route | PASS | 15 |
| favicons | PASS | 3 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 1 |
| profiles | PASS | 3 |
| settings-preview | PASS | 82 |
| sidebar-render | PASS | 110 |
| sidebar-compare | PASS | 142 |
| commandbar-render | PASS | 38 |
| features-render | PASS | 93 |
| extensions-render | PASS | 7 |
| sitecontrol-render | FAIL | 600 |
| boosts | PASS | 4 |
| verify-secrets-fixture | PASS | 7 |

## Review checklist

| Checklist item | Result | Evidence |
|---|---|---|
| Input sizes and decoded allocations | PASS (source) | `open_extension_manager.mm:339`: 4096-unit precheck, 4096-byte path, 32 pending requests; `:416`: forwarded text capped at 65536 UTF-16 units (128 KiB). Chromium parses CRX3. |
| Input boundary runtime coverage | UNVERIFIED | The requested CRX result gates exercise real signed/malformed packages. Separate at/over path/count/text-limit rows are not part of this receipt. |
| Callback reentry and context lifetime | PASS (source) | `OEExtension.h:220`; `OEExtensions.mm:276`: clear callback before later main-queue delivery. Manager erases the request before delivery and invalidates weak pointers on close. Context-close runtime row remains unverified. |
| Unique request IDs | PASS | `open_extension_manager.mm:568`: monotonic uint64 IDs, refuses wrap; owner is weak. |
| Real event paths and hidden actions | PASS / N/A | Automation-only, persistent-profile and same-profile guards remain. No key/focus/menu/product action changed. |
| Break-and-restore negative proof | PASS | Suppressed only the bridge invocation; signature row timed out with zero events; restored byte for byte and reran 19/19 PASS. |
| Isolated data and cleanup | PASS | Real-App harness uses private data/cache/socket/fixture keys; no new defaults. Positive P3 owned-process cleanup and fixture cleanup pass. |
| Pixels, dialogs, and timing | N/A | No new image, window-presence or timing assertions. Real Chromium consent is exercised by P3. |
| UI, motion, resize, assets | N/A | No UI/animation/asset change. No 2x capture is needed. |
| Docs and remaining work | PASS | Completion receipt and patch docs reflect the final gate. Section 14 still uses the old selector on this branch. |

Raw logs and JSON remain in the ignored Section 10 `0704-finish-20261107` evidence directory. Only aggregate synthetic-fixture results are committed.
