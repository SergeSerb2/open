# Automation notification guard: fresh Release acceptance

2026-11-06, M5, external AW2726DM main display at 2560 × 1440 (1x).
The filename preserves Section 11's original blocked-handoff link.

## Change and native boundary

The App and OpenEngine opt out of macOS notification setup only for automation
launches with `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`. The App passes
`--open-automation-skip-macos-notifications` to CEF, skips its native status,
authorization and activation observer, and refuses native list/click automation
commands. OpenEngine skips `CefSetOpenNotificationHandler`. Page and sleep
notification fixtures explicitly opt in. Normal user launches retain their path.

That App-only guard was incomplete. Section 11's fresh Debug Downloads run
passed 34/34 but `usernoted` connected the Alerts helper twice. Its stopped
Window run is INTERRUPTED, not acceptance.

Chromium patch `0506-page-automation-notification-guard.patch` completes the
boundary. `NotificationPlatformBridge::Create()` in
`chrome/browser/notifications/mac/notification_platform_bridge_mac.cc` checks
`base::CommandLine::ForCurrentProcess()` before constructing either dispatcher
and returns null for the opt-out. The existing
`NotificationPlatformBridgeDelegator::OnSystemNotificationPlatformBridgeReady`
uses the message-center fallback; `ENABLE_CHROME_NOTIFICATIONS=1` in this build.
The unchanged dispatcher body follows the guard when the switch is absent.

This prevents `NotificationDispatcherMojo`'s constructor from calling
`CheckIfServiceCanBeTerminated()` → `GetOrCreateService()` → `LaunchProvider()`.
Neither the banner provider, Alerts provider, app-shim factory nor their Mojo
connections are constructed by this native bridge. The switch constant lives
in Chromium and adds no libcef dependency. 0506 is the next page-platform
number after Chromium 0501/0504 and CEF 0505.

## Build and engine state

| Item | Evidence | Result |
|---|---|---|
| Baseline | engine-status: 8 PASS; 21 active patches; distribution `3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738` | PASS |
| Patch round trip | Generated from source, reversed, then `engine-apply --all`: 1 applied, 21 already applied, 0 overlay files copied | PASS |
| Engine build | `engine-build --target "cefsimple cefclient" --jobs 10`: 28 s, exit 0 | PASS |
| Distribution | `engine-distrib --run --skip-build`; status 8 PASS, 0 FAIL, 0 WARN; 22 patches, 50 overlay files, 25 symbols, 117/117 CEF patches | PASS |
| Fresh App | `OPEN_AUTOMATION=1 heavy.sh tools/build.sh Release`, with no pre-existing build directory; `codesign --verify --deep --strict` | PASS |
| Signature | `Signature=adhoc`, no team; CDHash `dcc5f180dfad208df1659861e71afab92efd64d9` | PASS |
| Embedded engine | Each suite requires the Vendor SHA and compares normalized embedded/Vendor code | PASS |

New distribution SHA-256:
`af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`.
Normalized engine code SHA-256:
`49529fd0e9fcab132dcd741c7276e9d1b7190a10cd62bf547673d40069771e66`.
This uses the existing dev engine configuration in a Release App. It does not
claim official Release/PGO engine packaging. The engine root is
`~/Developer/open-engine-s8`; the lead owns the later refresh of
`~/Developer/open-engine-s8-main`.

Engine operations used `lockf -k /tmp/open-engine-build.lock`, nice and 10 jobs.
App/CLI builds used `heavy.sh`. Every on-screen invocation took
`lockf -k /tmp/open-onscreen-e2e.lock`, with the priority flag checked first.
Timing qualification took quiet then on-screen locks. No debugger, process
attach, system input, keychain identity, Arc launch or gclient sync was used.
Every Open launch passed `--use-mock-keychain`.

## Fresh Release runtime receipts

The private collector calls the real `engine_e2e.main()` with
`--config Release --style chrome --only <suite> --engine-sha256 <new SHA>`.
It observes the native setup state, verifies suppressed native list commands
fail, samples `ps -axo pid=,comm=` throughout the run, and saves launch logs.
After each suite it runs:

```sh
log show --start <suite start> --end <suite end> \
  --predicate 'process == "usernoted" OR process == "tccd"' --info
```

| Suite / control | App result | Alerts connections in usernoted | Alerts in ps | Notification disclosures |
|---|---|---|---|---|
| Downloads | 34 PASS, 0 FAIL | 0 | 0 / 384 samples | 0 |
| Window | 76 PASS; two launch-budget FAIL qualified below; one existing material DEFERRED | 0 | 0 / 994 samples | 0 |
| Same fresh build without switch | Native setup reached; helper connected; clean cleanup | 1 | observed | native control |
| Page native opt-in | 85 PASS, 0 FAIL; four existing BLOCKED, one DEFERRED | 2 | observed | native path enabled |
| Extensions P3 | 14 PASS, 0 FAIL | 0 | 0 / 363 samples | 0 |
| Actions | 26 PASS, 0 FAIL | 0 | 0 / 461 samples | 0 |

Downloads' maximum ps sampling gap was 0.114 s; Window's was 0.297 s.
The independent usernoted log also catches short-lived helper connections.
Both suites left authorization unknown, setup suppressed, zero observer-reached
markers, and zero focus interruptions. Cleanup passed.

The same fresh Release native control, with
`OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=0` and recorded authorization, produced
this usernoted line (build-path prefix redacted):

```text
2026-11-06 06:54:05.927 usernoted: Connection io.github.sergeserb2.open.helper.alerts with path: <fresh Release>/Open.app/Contents/Frameworks/Open Helper (Alerts).app
```

It also observed the helper in ps and one observer-reached marker. This control
left no owned process. The initial App-only handoff and this switch-off control
prove the native suppression check discriminates the unguarded path.

The broad first collector counted generic
`TCCAccessLaunchDisclosurePromptIfNeeded` REQUEST/REPLY lines as disclosures.
The initial Downloads run has two such requests: a Safari support helper says `not prompting`,
and the main-app request receives `result=false` from
`TCCAccessCheckIfDisclosurePromptIsNeeded`. Window has three generic requests,
all resolved as not prompting or disclosure not needed. None is attributed to
notifications or the Alerts helper. These raw calls are retained separately;
they are not reported as zero generic TCC calls. The initial collector exit 1
was this classification error; the App suite itself exited 0. A repeat with
the corrected audit passed 34/34 and guardOK, with zero generic TCC requests.
Its earlier raw receipt is preserved in `downloads-initial/`.

Page's N1 engine display/list, N2 bundle/helper/list, N3 activation/click and
N4 fallback all pass on the native opt-in. N1 real delivery stays BLOCKED on
U-N1 (authorized, empty native delivered list). N6 clients.openWindow, U-X1
translation assets and C7 incognito remain the same existing BLOCKED rows.
Smart zoom remains DEFERRED to U-S1. No native authorization prompt was answered.

## Window timing qualification: TANDEM rule 4a

Raw full-suite medians (sidebar / first paint, ms): cold 437 / 744,
warm 420 / 699, at load1 9.248. The absolute 250 ms sidebar budget is not met.
The four required 1x rows all PASS: `chrome_dark_rings`, `traffic_light_look`,
`traffic_light_stale_hover`, and `comparison`.

The unchanged-main control is `75f08364c1d1647d6489a4b0dfecc89540de21a8`,
built from a git archive; all 2,354 tracked source files matched the archive
after build. Its engine is the recorded main distribution, read without
refreshing that root. The existing Window launch loop ran five cold and five
warm samples per part, in main/branch/main/branch order. Unrelated window flows
were omitted. All apps used their own data and cache roots.

| Part | Load1 start → end | Cold sidebar / paint ms | Warm sidebar / paint ms |
|---|---|---|---|
| main 1 | 8.598 → 7.979 | 450 / 929 | 429 / 906 |
| branch 1 | 7.979 → 7.822 | 410 / 670 | 408 / 659 |
| main 2 | 7.822 → 10.509 | 419 / 924 | 414 / 691 |
| branch 2 | 10.509 → 10.443 | 417 / 686 | 431 / 728 |
| Main pooled, 10 each | same session | 427 / 926.5 | 421 / 903 |
| Branch pooled, 10 each | same session | 414.5 / 686 | 418 / 671 |

All four pooled branch medians are no slower than main. The launch rows are
qualified as known-main FAIL under 4a. This does not turn them into absolute
budget passes. An earlier control attempt reached the main launch measurements,
then entered an unrelated peer-window flow that rejected the mixed executable;
that incomplete attempt is retained and excluded from qualification.

## Final regression and private evidence

The final merged-head full-verifier summary and review-checklist tables are
recorded in the PR. Final merged-head App regression receipts are retained
alongside these original fresh-build receipts.
No new design guesses or dependencies. U-N1 and the pre-existing Page gates
above stay open; the automation guard does not claim native delivery acceptance.

Raw receipts stay in ignored `.re/notification-guard/`: engine apply/build/
distribution/status, Release signature/build, `downloads/`, `window/`,
`native-control/`, `launch-control/`, `page/`, `extensions-p3/`, and `actions/`.
Section 11's original handoff retains its raw baseline and interrupted run.
