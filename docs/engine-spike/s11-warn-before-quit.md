# Generic Warn before quitting (2026-11-09)

Open adds its own generic quit alert when `open.general.warnBeforeQuitting` is on.
The existing default remains `true`. The title, count sentence and button copy
are **GUESS: Open design**, not proved Arc UI. See [the static evidence limits](../re/downloads-s11.md).

Downloads own ordinary quit attempts before the generic warning. Cancel leaves
the model and browser windows intact. Accepted generic approval survives the
async history/sleep retries and resets if page-beforeunload cancels. No new work
runs at normal launch.

Owner-death cleanup and harness quit skip the generic alert. System logout,
restart and shutdown read `kAEQuitReason` from the current Apple event and retain
that reason across retries. Installer relaunch uses an explicit updater flag;
system shutdown and installer relaunch also bypass download/page prompts.

## Verification

M5 Pro only. Build started at 01:15:10 MST, after the requested 01:15 hold.
All builds/checks used the section lock and heavy slot. Every app launch used
the on-screen lock and `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`.

Implementation source commit: `1605e93b`. Final Debug executable SHA-256:
`c7cf6c35ddf6204af3c9fca80b7d33c52de730f44eca66710c4d9ca28ac2f0aa`.

| Real-App row | Result | Receipt under `.re/warn-before-quit/` |
|---|---|---|
| Warning on, Cancel: two windows and all tabs survive | PASS | `final-quit-results.json`, `final-quit.log` |
| Warning on, Quit: one approval across async retries, clean exit | PASS | `final-quit-results.json` |
| Warning off: no alert, clean exit | PASS | `final-quit-results.json` |
| Downloads running, warning on: Keep and Close each show only the downloads alert | PASS | `final-quit-results.json` |
| Harness quit with warning on | PASS | `final-quit-results.json` |
| Existing downloads Keep (both settings), Close and empty quit | 4 PASS | `final-quit-results.json` |
| Early pre-engine harness quit, process-only warning override YES | PASS, exit 0, zero generic alerts | `early-quit.json`, `early-quit.log` |
| Existing owner-death suite: normal, negative control, active download, beforeunload | 4 PASS | `owner-watch/results.json`, `owner-watch.log` |
| New gates broken deliberately in the real App | 6 expected FAILs | `negative-missing.json`, `negative-matrix.json`; matching `.log` files |
| Final Debug build | PASS; no new warnings in changed code | `final-build.log`, `final-xcodebuild.log` |
| `verify-all.sh --only settings-preview,commands-dump` | build, commands-dump, settings-preview PASS | `verify/summary.txt`, `verify.log` |

The focused quit run passed **10/10**. Its owned-process cleanup passed without
forced quits or remaining windows. All six new gates failed with temporary App
faults: missing warning, ignored Quit response, always-on warning, incorrect
download precedence and ignored harness bypass. These faults were removed before
the final build. Both negative runs also cleaned up without forced quits.

The early check sets the warning only through the App process's argument domain;
it does not write a persistent preference. No Apple-domain settings were changed.

**Full Downloads regression: FAIL.** The strict run passed its first 22 rows,
then stopped in the existing second-Profile flow with
`download callback missing for /fast`. An isolated retry with the normal
LaunchServices launch repeated that failure. Both runs cleaned up normally.
This occurs before any quit path runs. No unchanged-main baseline comparison was
run, so this is an unresolved failure, not a claimed known-main failure. Receipts:
`full-attempt-results.json`, `full-attempt.log`, `profile-retry-results.json`,
`profile-retry.log`. The focused quit acceptance above remains separate.

## Review checklist

| Area | Result | Evidence |
|---|---|---|
| Limits | PASS | Automation button values are an allowlist; alert receipts cap at 64. No new file/network input. |
| Lifetimes | PASS | Alert observer is removed after the native modal session; quit approval spans async retries. |
| Real event paths | PASS | `quit-warning` queues the real `quit-open` command; the native alert's own NSButton handles each response. Return/Esc equivalents are asserted, not injected as desktop input. |
| New gates and cleanup | PASS | 10/10 quit rows; all six new gates fail under temporary App faults; positive/negative cleanup leaves no windows or processes. |
| Motion/layout | N/A | Standard NSAlert, no custom animation or layout. |
| Docs | PASS | Status, followups and App shell plan label this copy as Open's guess. |

## Limits and owning-section hooks

No actual system logout/restart/shutdown or update installation was run. Those
exception paths are compiled and source-verified; live system/update acceptance
is not claimed. The full Downloads regression failure above remains open.
The existing updater R2 test intentionally uses a downloads warning to hold a
real Sparkle installer. Its owner must adapt that test to the requested
prompt-free installer relaunch before running it with this change.

Hooks: `AppDelegate.applicationShouldTerminate`, the downloads prompt bypass,
page preflight bypass/approval reset, automation quit commands, the early
pre-engine harness quit, and `OpenUpdateUserDriver` installer/error callbacks.
