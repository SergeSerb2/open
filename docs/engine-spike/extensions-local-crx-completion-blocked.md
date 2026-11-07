# Local CRX completion 0704: off-screen receipt

2026-11-07, M5 Pro. Branch `s10/engine-0704`, stacked on `s10/engine`.
This is an implementation receipt. Real-App acceptance remains **BLOCKED**
until the Section 10 lead sends **M5 clear**. The observed front application
was `UserNotificationCenter`; no Open process or on-screen suite was launched.

## Patch and engine

0704 is an overlay change in the **03xx extensions area**, using Section 10's
next available number. It adds `CefInstallLocalCrx` and
`CefExtensionLocalInstallCallback`, with the generated export
`cef_install_local_crx`. `OEExtensionManager.installLocalCRX(_:completion:)`
reports installed/ID, cancelled, or failed/Chromium text once on the main
thread. The previous initiation-only path remains a wrapper; production Web
Store completion is unchanged.

Chromium 156 exposes `AddInstallerCallback`, rather than the design's
`set_installer_callback`. The manager retains each installer in a bounded map,
uses non-recycled request IDs and weak owner callbacks, removes the request
before result delivery, and settles pending requests at context closure.
`USER_CANCELED` maps to cancelled; other failures stay failed.

`CrxInstaller::ReportFailureFromUIThread` calls `LoadErrorReporter::ReportError`,
which only stores/logs the error. `ReportLoadError` alone notifies the old
`OnLoadFailure` observer. Evidence: `extensions/browser/crx_installer.cc`
(`ReportFailureFromUIThread`, `RunInstallerCallbacks`) and
`extensions/browser/load_error_reporter.cc` (`ReportError`, `ReportLoadError`).
These are Chromium sources, not Arc reverse engineering.

Engine root: `~/Developer/open-engine-s10`. All apply/build/distribution work
used a detached session and `/usr/bin/lockf -k /tmp/open-engine-build.lock`,
with the scripts' 10 jobs and nice setting. No sync or other engine root was used.

- Apply: PASS, 23 patches already applied; CEF API regenerated; final overlay applied.
- Build: PASS, `engine-build --target "cefsimple cefclient"`, 68 s.
- Distribution: PASS, `engine-distrib --run --skip-build` (dev engine configuration).
- Strict status: **8 PASS, 0 FAIL, 0 WARN**; 117/117 CEF patches, 23 Open patches,
  53 matching overlays, 31 exported symbols.
- Framework SHA-256: `0479c9507d255c7f25b60303a1cf7c47d76c7462e0e3d8b7b983a3517a44a16e`.
- Framework size: 460,892,736 bytes.

Load tuples (1/5/15 minutes): corrected engine job queued at
`(29.44, 26.33, 21.10)`, build start `(25.45, 26.21, 21.41)`,
build end `(26.60, 26.24, 21.79)`, package end `(16.58, 23.63, 21.15)`.
The unchanged page overlay emits its pre-existing overloaded-virtual warning.
The first build failed on Chromium's ref-counted bare-pointer bind check; the
final implementation uses integer request IDs. The first status JSON target
was refused because it was outside this checkout; the saved strict status
receipt under the engine state directory reports all eight checks PASS.

## Off-screen verification

The Section 10 `s10-heavy.sh` wrapper ran:

```sh
OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s10 \
  $HOME/.t3/projects/open/.re/s10/s10-heavy.sh tools/verify-all.sh \
  --only commands-demo,roundtrip,suggest-check,commands-dump,route,favicons,media-demo,sleep-demo,adblock-perf,adblock-catalog,profiles,extensions-render,boosts
```

All 14 selected checks passed. Load tuples: start `(15.51, 23.55, 19.61)`,
end `(28.12, 26.50, 21.75)`. This is a selected off-screen gate, not the full gate.

| Check | Result | Seconds |
|---|---|---|
| build | PASS | 135 |
| commands-demo | PASS | 3 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 26 |
| commands-dump | PASS | 0 |
| route | PASS | 11 |
| favicons | PASS | 2 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| extensions-render | PASS | 9 |
| boosts | PASS | 5 |

Debug App build: **PASS**, `s10-heavy.sh tools/build.sh Debug`, on the new
distribution. Initial build load: `(12.76, 22.04, 20.66)` ->
`(21.04, 22.23, 20.84)`; final build after the automation helper cleanup:
`(10.18, 18.24, 19.44)` -> `(10.36, 17.89, 19.29)`. The final helper uses the
completion API in a synchronous start method, so the socket can answer consent
and the acceptance gate can count callbacks directly.

`engine_e2e.py --config Debug --engine-fingerprint-only --engine-sha256
0479c9507d255c7f25b60303a1cf7c47d76c7462e0e3d8b7b983a3517a44a16e`:
**PASS without launching Open**. Vendor bytes equal the distribution SHA;
Vendor and embedded normalized code both hash to
`0651dd5c9cc2ec474dd9a345fbaf13698d72768d279aeee16a2ea600a364857f`.
Both Mach-O UUIDs are `4C4C4445-5555-3144-A136-E67C0E446848`.

Python syntax and `git diff --check`: PASS. No unit tests were written or run.

## Real-App acceptance still blocked

| Row | Result | Required proof |
|---|---|---|
| Signed CRX | BLOCKED | `0704_installed_completion`: installed, correct live registry ID, main thread |
| Corrupt signature | BLOCKED | `0704_signature_failure_completion`: failed, no ID, Chromium text contains `CRX_SIGNATURE_VERIFICATION_FAILED` |
| User Cancel | BLOCKED | `0704_cancelled_completion`: cancelled, no ID/error, remains absent |
| Exactly once | BLOCKED | `0704_completion_exactly_once`: one result per request after duplicate prompt answers and later UI turns |
| Negative proof | BLOCKED | Drop only the completion call; the signature row must time out with zero completion events; restore, rebuild and pass |
| Cleanup and old-selector regressions | BLOCKED | Fixture removal, full existing `extensions-p3` rows and owned-process cleanup |
| New local-request limit boundaries / closure | BLOCKED | Real-App boundary and context-close cases need the screen |
| Section 14 import queue | BLOCKED | Section 14 reruns its failed-install report row on this distribution |
| Full verify-all | BLOCKED | Includes on-screen checks; no merge performed under the child instruction |

After the lead clears the screen and the priority check passes:

```sh
lsappinfo info -only name $(lsappinfo front)
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s10
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  python3 tools/e2e/engine_e2e.py --style chrome --config Debug --only extensions-p3 \
  --engine-sha256 0479c9507d255c7f25b60303a1cf7c47d76c7462e0e3d8b7b983a3517a44a16e
```

For the negative proof, temporarily replace the single callback invocation in
`OELocalInstallCompletion::OnComplete` with `(void)completion;`, rebuild Debug
through `s10-heavy.sh`, and run that locked suite. Require the signature row
FAIL with `timedOut=true` and an empty event list. Restore the source byte for
byte, rebuild and require the same row PASS. No fault was injected during this
off-screen task. Private logs and the detailed rerun procedure remain under
`.re/s10/0704/` in the project workspace. No private user data is in this receipt.
