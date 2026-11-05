# Extension engine P3 receipt

2026-11-05, M5 Pro, macOS built-in 2× display. Branch `s6/engine-p3`.
The engine root is `~/Developer/open-engine-s8`; the main distribution view
`~/Developer/open-engine-s8-main` was not changed.

## Engine provenance

Before edits, `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8
Engine/fork/scripts/engine-status` reported 8 PASS, 0 FAIL, 0 WARN:
18 active Open patches, 44 matching overlay files, 23 exported symbols,
117/117 CEF patches. The framework SHA-256 matched main:
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.

After P3, the same status command reports 8 PASS, 0 FAIL, 0 WARN:
19 active Open patches, 47 matching overlay files, 24 exported symbols,
117/117 CEF patches. New distribution framework SHA-256:
`e65426c9ffa518d7cae75479c4ede2aa189f87ff8ec78ba5fec3c3dcfa2c7415`.
The signed App framework and distribution have the same normalized code
SHA-256 `0d78c64d7a1037569b075286817487080bded30c3e76f88ef93dbf77a5903352`.

Engine apply/build/distrib used `/tmp/open-engine-build.lock`, the scripts'
nice setting, 10 jobs, and a separate session. Release App build used
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8 OPEN_AUTOMATION=1
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release`:
`** BUILD SUCCEEDED **`. The new 0305 hook patch also passed a clean-file
apply round trip for both Chromium hook files.

## P3 end to end

Each App launch passes `--use-mock-keychain`. Plain suites wait for a foreign
timing-priority flag, then take `/tmp/open-onscreen-e2e.lock`. They run one
suite per call, without an engine or App build from this child in parallel.
The P3 suite requires no network. It signs an ephemeral local CRX3 and sends
it through Chromium's real `CrxInstaller`, validation, consent and registrar.

Command: `tools/e2e/engine_e2e.py --only extensions-p3 --style chrome
--config Release --engine-sha256 e65426c9ffa518d7cae75479c4ede2aa189f87ff8ec78ba5fec3c3dcfa2c7415`.

| Assertion | Result |
|---|---|
| Registry ready, live metadata and ready/change/commands/install events | PASS |
| X-1: cancel keeps absent; dropping prompt cancels; accept installs; duplicate answer is harmless | PASS |
| Probe's two command shortcuts and action snapshot shortcut | PASS |
| Named command receives the active tab; action command opens with source `command`; unknown command refused | PASS |
| Menu kept across last-tab close/browser recreation cannot select a new menu | PASS |
| X-14: Deny returns false; Allow returns true; Open text and Chromium permissions retained | PASS |
| Disable/enable round trip, action removal/restoration, open popup closes | PASS |
| Registrar reload | PASS |
| X-15: menu removal Cancel keeps; manager removal Accept removes action and closes popup | PASS |
| Manifest icon limits: 2,048² accepted; oversized dimensions, bytes and bit depth refused | PASS |
| Non-default profile installs through its own registry and prompt hook; default remains isolated | PASS |
| No prompt delegate: specific native install dialog appears and installs | PASS |
| Exact owned-process/window cleanup | PASS |

All 14 P3 feature rows passed. Full machine-readable receipt:
[results-extensions-p3-release.json](results-extensions-p3-release.json).

The icon cases modify only the installed fixture under this run's isolated
profile after Chromium has sanitized its initially valid icon. They check the
metadata decoder's actual input boundaries. The native fallback respects
Chromium's existing 500 ms Add-button guard; it does not change native UI.

Negative proof on the same engine and App: `OPEN_E2E_P3_CANCEL_INSTALL=1`
deliberately changes an automation install Accept to Cancel. X-1 reports
`FAIL`, `injectedCancel: true`, `installed: false`; cleanup reports `PASS`.
With the flag removed, X-1 and the complete P3 suite report `PASS`.

## Regression gates

Final regression and full verification results are recorded in the PR.

## Limits and next engine work

- E11 popup windows and E12 omnibox events are separate work. Metadata already
  exposes each profile's `omniboxKeyword`; the probe has the planned delayed
  suggestions, deletion, navigation dispositions and cancel counter.
- Chromium's Cocoa accelerator pair encodes Shift in an uppercase letter:
  `Y` plus Command means Command-Shift-Y. The shell's key router must preserve
  that meaning. In-window shortcut routing is the lead's App step.
- Every profile creates Chromium's global command registry. OS-level global
  key delivery is not proved by the in-process execution gate.
- Permission and uninstall requests can carry a native parent only.
  `webContent` then stays nil; `browser` resolves through the same profile's
  hosted pages. The presenter must otherwise choose a window of that profile.
- Chromium 156 has no retained-file/device fields in `InstallPromptData`;
  the two public arrays are empty. Enterprise/parent-approval prompt types
  continue through Chromium's native UI.
- Guess (child): `byUser` identifies fresh non-policy, non-command-line installs;
  the registry observer has no user-gesture argument. Icon decoder safety caps
  (4 MiB encoded, 2,048² pixels, at most 8-bit components) are also child choices.
