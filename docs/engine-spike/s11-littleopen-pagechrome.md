# Little Open page chrome

The Section 11 lead's 2026-11-06 design extends the existing page-chrome queue
to standalone surfaces. The App uses the current main engine, framework
SHA-256 `3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738`.
No engine source changed.

Dialogs use NSAlert sheets on the originating Little Open window. Close
preflight uses Chromium's existing Page.close path. Cancel keeps the same page;
OK removes the session after the engine callback returns. Repeated close cannot
bypass the pending sheet. Quit includes standalone pages after the existing
Downloads warning. Owner-death automation quit remains prompt-free.

Permissions use PermissionPromptView in a content child card. Allow persists in
the engine Profile. Not Now resolves one request and restores the previous
setting. The surface visibility feed queues hidden dialogs and dismisses cards.
The real answer command clicks the card's buttons. Return and Escape do not
reach the page; answering returns focus to it.

The in-window attachment and 0.1 s show/hide durations are facts from
[page-chrome §3](../re/page-chrome.md#3-site-permission-prompts):
`0x10002b8d4`, `0x10002bbbc`, and
`LittleWindowViewController.permissionRequestView`. The lead specifies 10 pt
leading/top insets, 320 pt maximum width, 10 pt corners and easing as guesses.
The card uses Find's shadow and an explicit shadowPath. Reduce Motion uses no
fade. No timer, polling, launch-order change or dependency was added.

## Hooks in Section 9 files

- `App/LittleOpen/AppLittleOpen.swift`: one call installs the page-close adapter.
- `Packages/OpenKit/Sources/OpenFeatures/LittleOpenCoordinator.swift`: optional
  `requestPageClose` preflight, followed by the existing close body only after
  acceptance. Auto-archive keeps its existing path.
- `App/LittleOpen/LittleOpenWebContent.swift`: no change.
- `App/Automation/AutomationLittleOpen.swift`: `close-button` presses the real
  close button for the end-to-end close flow.

`EngineWebContentHost.webContentDidRequestClose` first resolves a pending App
preflight; the existing unsolicited-close callback stays deferred. MainMenu's
sheet shortcut guard includes standalone owners. Automation commands with an
explicit Little Open window resolve that window's factory.

## Verification

The restored implementation passes all 21 new Little Open flows in one
combined MIDI run (`page-chrome`: 62/62). The required regression results
and the known-main Downloads interruption are recorded in the PR. The first complete full verifier passed
23/23 with no skips on AW2726DM, scale 1.0; the final-head rerun is also recorded
in the PR. Display gates count as real checks.

[Negative proof](s11-littleopen-negative-proof.json): disabling standalone
visibility fails all 21 new rows. The dialog states remain queued, with no sheet.
Forcing the existing NSPopover path produces a visible popover and fails both
card rows with `Expected an in-window permission card`. Both negative runs have
zero interruptions, clean owned-process shutdown and no forced cleanup.
Production code was restored before final builds.

The intentional visible-sheet failure (`little_dialog_alert`,
`OPEN_E2E_LITTLE_CHROME_EARLY_FAILURE=1`) also completed cleanup: zero
interruptions, zero owned windows or processes after quit, no forced cleanup.
The full owner-watch suite passes all four scenarios, including active-download
and beforeunload owner death. Their private receipts are
`.re/s11-littleopen/results-visible-sheet-cleanup.json` and
`.re/s11-littleopen/owner-watch-final/results.json`.

## Authorization prompt and fixture correction

The first Little Open permission run used notifications, including Allow,
with `OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record`. Its timing overlaps
the 05:18 macOS notification-authorization dialog. Saved app output does not
prove which process requested that dialog; this run is a possible source.
The engine startup path described below can request the disclosure independently
of the Swift notification Allow path, so attribution to this fixture is unproved.
The lead confirmed the last UserNotificationCenter window closed at 05:25:39.
Runs before 05:26 that lost focus remain INTERRUPTED, not failed acceptance.

All new Little Open permission rows now use real
`navigator.requestMIDIAccess({sysex:true})` and `OEPermissionKind.MIDI` (32).
MIDI needs no attached device or macOS notification grant. No real OS
authorization prompt or notification delivery is part of this acceptance.
The existing normal-window page-chrome fixture retains its record-only
notification authorization setting.

## Known-main Alerts helper disclosure

The two branch Downloads attempts lost focus to `UserNotificationCenter`,
including at the first live-progress row. They remain INTERRUPTED; passing
assertions inside an interrupted attempt do not count as acceptance. No run
was still active when the lead reported the prompt. The lead's system-log
evidence identifies a notification disclosure for
`io.github.sergeserb2.open.helper.alerts` at 05:54:34 on 2026-11-06.

One comparison used unchanged main `75f08364`'s Debug build and the same
fresh-bundle Downloads controls flow. All ten controls rows passed, with zero
interruptions and clean process cleanup. At 05:58:13.977, `usernoted` connected
the Alerts helper (PID 40998) from that run's unique `downloads-attempt` copy.
This proves main launches the helper too; it does not claim a second disclosure
was shown. The main source checkout was clean. Raw receipts stay private:
`.re/s11-littleopen/downloads-main-once.log`,
`results-downloads-main-controls.json`, and `alerts-main-system.log`.
The diagnostic wrapper limited the harness to one attempt, with no product or
fixture behavior changed. No further Downloads retries were made.

The source path is `OEBrowserContext.oe_contextInitialized` →
`CefSetOpenNotificationHandler` → automation `NotificationState` →
`NotificationDisplayServiceFactory::GetForProfile` →
`NotificationPlatformBridge::Create` → `NotificationDispatcherMojo` constructor
→ `CheckIfServiceCanBeTerminated` → `GetOrCreateService` →
`MacNotificationProviderFactory::LaunchOutOfProcessProvider`
(`kChildProcessHelperAlerts`). The Chromium constructor explicitly force-starts
the service for first-start permission. There is no notification delivery or
authorization call in the App's download-completion or quit path.
The Swift `OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record` guard does not
cover this engine startup. Engine changes are outside this PR's scope.
Downloads counts as INTERRUPTED by a known-main system prompt for this PR,
per the lead's ruling. The follow-up belongs to Section 8 / lead.
