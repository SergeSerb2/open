# Passwords and autofill acceptance (Section 15)

This continues [the D4 dropdown investigation](passwords-dropdown.md).
The App save/update, fill and Manage integration is **implemented and verified**
on the Section 15 branch, awaiting PR review and merge. User and release gates
below remain open. The engine is main's PR #264, framework SHA-256
`619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`.

## Final H3 acceptance (2026-11-08)

Final native fix: `c60340f3`; final code head: `d7dd37ba`, containing merged main
`d26300e6`. H3 changes the Little Open harness and plan text only. All runtime
suites below exercised that final native code. The final Debug build and full
gate ran after the H3 harness corrections were committed. This receipt and
status reconciliation are documentation-only additions after that code gate.
[The sanitized receipt](results-passwords-h3.json) includes every row, load,
source head, working-diff hash, cleanup result, command and prior attempt.

| Run | Result | Load at screen acquisition 1 / 5 / 15 | Load after 1 / 5 / 15 |
|---|---|---|---|
| littleopen-initial | 8 PASS; ownership FAIL; suite FAIL (harness) | 16.52 / 19.54 / 18.65 | 18.14 / 19.77 / 18.75 |
| littleopen-cold-failure | 37 PASS; suite FAIL (cold fixture) | 33.40 / 24.25 / 20.60 | 42.83 / 28.04 / 22.19 |
| littleopen | 41 PASS | 25.42 / 24.80 / 23.36 | 20.80 / 23.70 / 23.03 |
| passwords-m-interrupted | 20 PASS then INTERRUPTED; excluded | 27.85 / 24.61 / 23.45 | 23.48 / 23.99 / 23.27 |
| passwords-m-interrupted-2 | 13 PASS then INTERRUPTED; excluded | 8.96 / 16.45 / 20.17 | 8.12 / 15.78 / 19.84 |
| passwords-m | 22 PASS | 8.84 / 10.40 / 15.18 | 9.54 / 10.45 / 15.03 |
| passwords | 77 PASS, 2 BLOCKED | 6.08 / 7.40 / 11.83 | 7.11 / 7.18 / 11.10 |
| features | 26 PASS, 1 DEFERRED | 17.09 / 9.68 / 11.04 | 11.15 / 10.27 / 11.15 |
| page | 85 PASS, 4 BLOCKED, 1 DEFERRED | 17.34 / 11.61 / 10.38 | 10.21 / 10.69 / 10.15 |

The accepted runs each have zero interruptions and cleanup PASS. Passwords has
only the accepted C-2 M1-only and PW-KC1 user-hand-check blocks. Features passes
Widevine encrypted playback; its intentional crash row stays M1-only. Page's
existing exclusions are `N1_macos_delivered`, `N6_click_opens_tab`,
`X1_apple_backend` (language pack absent), `capture_c7_incognito` (fixture gap),
and deferred `Z3_smart_zoom` (user gesture). These are not new acceptance claims.

Debug build: PASS, 19.15 s; load 12.33 / 9.76 / 9.52 before and
18.03 / 11.15 / 10.02 after. Targeted `verify-all --only settings-preview`:
build PASS (112 s), settings PASS (949 s including lock waits), load
9.53 / 10.50 / 10.09 before and 9.23 / 9.16 / 9.32 after.
The full gate below has 24 PASS and one timing FAIL in `commandbar-render`.
Inline completion added 0.510 ms against the 0.3 ms limit at measured load
15.6 / 19.0 / 17.9; its main CPU p95 row passed at 6.77 ms. The single
quiet rerun below passes: overhead 0.181 ms, main CPU p95 4.74 ms, measured
load 10.1 / 12.9 / 15.3 (pre-lock load1 8.32). No threshold changed,
and no other full-gate check failed. Check seconds include shared lock waits.

| Name | Result | Seconds | Load before 1 / 5 / 15 | Load after 1 / 5 / 15 |
|---|---|---:|---|---|
| build | PASS | 4 | 21.71 / 14.06 / 11.26 | 21.89 / 14.23 / 11.33 |
| commands-demo | PASS | 10 | 21.89 / 14.23 / 11.33 | 25.52 / 15.27 / 11.74 |
| roundtrip | PASS | 1 | 25.52 / 15.27 / 11.74 | 25.52 / 15.27 / 11.74 |
| space-legacy | PASS | 3 | 25.52 / 15.27 / 11.74 | 24.84 / 15.30 / 11.77 |
| space-editor | PASS | 426 | 24.84 / 15.30 / 11.77 | 15.13 / 16.45 / 13.76 |
| space-pad-compare | PASS | 2 | 15.13 / 16.45 / 13.76 | 15.13 / 16.45 / 13.76 |
| suggest-check | PASS | 25 | 15.13 / 16.45 / 13.76 | 15.50 / 16.37 / 13.80 |
| commands-dump | PASS | 0 | 15.50 / 16.37 / 13.80 | 15.50 / 16.37 / 13.80 |
| route | PASS | 22 | 15.50 / 16.37 / 13.80 | 19.13 / 17.24 / 14.20 |
| favicons | PASS | 4 | 19.13 / 17.24 / 14.20 | 19.13 / 17.24 / 14.20 |
| media-demo | PASS | 1 | 19.13 / 17.24 / 14.20 | 19.13 / 17.24 / 14.20 |
| sleep-demo | PASS | 1 | 19.13 / 17.24 / 14.20 | 18.64 / 17.17 / 14.19 |
| adblock-perf | PASS | 1 | 18.64 / 17.17 / 14.19 | 18.64 / 17.17 / 14.19 |
| adblock-catalog | PASS | 5 | 18.64 / 17.17 / 14.19 | 18.03 / 17.07 / 14.17 |
| profiles | PASS | 5 | 18.03 / 17.07 / 14.17 | 18.11 / 17.10 / 14.20 |
| settings-preview | PASS | 603 | 18.11 / 17.10 / 14.20 | 32.82 / 23.13 / 18.30 |
| sidebar-render | PASS | 110 | 32.82 / 23.13 / 18.30 | 19.06 / 21.90 / 18.47 |
| sidebar-compare | PASS | 134 | 19.06 / 21.90 / 18.47 | 16.46 / 19.65 / 18.03 |
| commandbar-render | FAIL | 37 | 16.46 / 19.65 / 18.03 | 15.63 / 18.98 / 17.85 |
| features-render | PASS | 90 | 15.63 / 18.98 / 17.85 | 11.29 / 16.80 / 17.13 |
| extensions-render | PASS | 7 | 11.29 / 16.80 / 17.13 | 10.95 / 16.64 / 17.07 |
| sitecontrol-render | PASS | 165 | 10.95 / 16.64 / 17.07 | 10.34 / 14.39 / 16.08 |
| onboarding-render | PASS | 22 | 10.34 / 14.39 / 16.08 | 9.51 / 13.94 / 15.88 |
| boosts | PASS | 3 | 9.51 / 13.94 / 15.88 | 10.11 / 13.99 / 15.89 |
| verify-secrets-fixture | PASS | 8 | 10.11 / 13.99 / 15.89 | 9.62 / 13.76 / 15.78 |

| Quiet rerun | Result | Seconds | Load before 1 / 5 / 15 | Load after 1 / 5 / 15 |
|---|---|---:|---|---|
| build | PASS | 4 | 8.32 / 13.12 / 15.49 | 8.14 / 13.00 / 15.44 |
| commandbar-render | PASS | 34 | 8.14 / 13.00 / 15.44 | 10.08 / 12.92 / 15.30 |

Every shell exports `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` and
`OPEN_E2E_NO_CRASH_PROBES=1`. Builds/checks use heavy lock `a` and `heavy.sh`.
Each App suite has its own screen `lockf -k`, priority checks and strict
`--stop-on-app-death --row-timeout 120 --suite-timeout 900` bounds. No owned App
is left behind. M1 stayed held. No intentional crash was run on M5.

## The 14:02 crash and regression proof

H2's `Open-2026-11-08-140223.ips` crash at 14:02:21 MST occurred while presenting
a Little Open save sheet. Its repeated `SavePromptPresenter.showNext` /
`pageDidBecomeFocused` frames through `standaloneSurfaceVisibilityChanged` and
`LittleOpenWindowController.windowDidResignKey` establish reentrant sheet
parking: `beginSheet` transfers the key window, which the old focus predicate
treated as page loss. The local crash and failed run remain under `.re/s15/h2/`.
That failed build was not replayed on M5.

The fix coalesces presenter triggers to the next main turn, guards sheet
presentation/removal against reentry, and checks the focused page inside the
presenter's own window. Closing requests release before window/page metadata
dies; AppKit sheet teardown is deferred. A sheet's own key transfer preserves
its request. `littleopen_events_owner` proves the owning window's attached
sheet, correct page/event routing (including Section 11 #240), exactly one
answer and App survival. `littleopen_save_sheet_focus_visibility_stress`
passes six real hide/show and own-window focus cycles with the same sheet,
one answer and no extra answer. Both pass at load 24.11 / 24.54 / 23.29.

H3 corrected two harness defects without changing native code. The first
attempt's ownership assertion used `NSWindow.parent`; AppKit sheets instead
use `attachedSheet`/`sheetParent`. The accepted row requires a real sheet and
the owner's `attachedSheet`, and records every page/window/answer condition.
It observes `sheetOwned=true` and `childParentMatches=false`. The next attempt
passed 37 rows, then strict cold launch dropped the real startup open-URL
event. Only those cold fixtures now retain LaunchServices delivery; the owner
watcher, unique root, crash guard and verified-PID/window cleanup stay active.
A missing session is a failed row, not an index exception. Both full cold rows
pass in the final 41-row run. Two M-only attempts lost foreground to Messages
and T3 Pretty Internal; both are INTERRUPTED and excluded, with clean cleanup.

No new real crash report appeared during H3. One non-fatal `ExcUserFault`
(bug_type 309, simulated) matches the passing features run at 17:21:51 and
crosses `ISMutableIcns addCGImage:scale:error:` →
`NSWorkspace setIcon:forFile:options:` → Chromium `shortcuts::SetIconForFile`.
The App exited cleanly. TANDEM §8c classifies this as a fault, not a crash.
Its cause and regression attribution are unknown; it remains a follow-up.
Six other faults do not match the recorded H3 App PIDs.

## Open user and integration gates

Arc captures S-1…S-6, PW-KC1, signed-build K-1…K-3 after release U-1/U-2,
HTTP-auth sheet/save/fill acceptance, iCloud passkeys U-9, and real hardware
security-key/phone authentication remain open. Imported-secret engine/App
integration is separate and `canImportPasswordsAndCookies` remains false.
No real Keychain or Arc secret was read. Fixture acceptance does not qualify
those gates or Arc pixel parity.

## Earlier H/H2 diagnosis

The earlier H password run had 77 PASS before the presenter fix. H initially
stopped when the component updater did not supply Widevine within its bounded
wait. The harness starts the named row and limits that wait to 60 s inside the
120 s cap; it still requires encrypted playback. H2 on `221f2127` passed all
26 runnable features rows, including Widevine, and 85 page rows before the
Little Open crash. H3 repeats these suites on the fixed native code, so those
older receipts do not stand in for fixed-head acceptance. Historical receipts
remain [H](results-passwords.json) and [H2](results-passwords-h2.json).

The sections below retain D5/D6 diagnosis history. D5's old framework is not
accepted or replayed. Raw historical receipts stay in the engine checkout's
`.re/s15/d5/` and `.re/s15/d6/`; App H/H2/H3 evidence stays under `.re/s15/`.

## Historical D5 causes

P-5 submitted the saved password as its new password. Chromium correctly
selected a metadata-only update. Password-manager internals distinguish that
decision from a new-password update (`p5-before-complete.log` and
`p5-refill-idle.log`). The realistic change form now has distinct current and
new passwords with the same username. The update sheet and refill of the
updated password passed. The router already handles
`PENDING_PASSWORD_UPDATE_STATE` at
`Engine/fork/src/open/browser/autofill/open_password_prompt_router.cc:23` and
maps it to the update kind at line 56.

The address importer found one valid profile, and Chromium requested its
bubble. A subsequent password UI state change withdrew the page's shared
prompt. Internals recorded Ignored (7), with no stored address. The password
router now withdraws only password kinds 0/1 through
`open_autofill_handler_registry.cc:73`. P-9 and P-10 then passed, with Accepted
(2) and one stored address (`address-import-count-results.json` and
`merged-focused-1-results.json`). The fixture did not need weaker importer
requirements.

The original card dropdown on HTTP was an insecure-payment warning. It had
no accepted card suggestion and did not start re-authentication
(`card-accept-trace.log`). Chromium's fill predicate requires HTTPS and an
acceptable security level (`chrome_autofill_client.cc:1098`). Its local-card
save path does not use that predicate (`chrome_payments_autofill_client.cc:299`).
An HTTP negative check reproduced a real save offer and dismissed it without
saving. Open now applies `IsContextSecure()` before forwarding card offers
(`open_autofill_handler_registry.cc:99`). The HTTP rejection and HTTPS
save/fill checks passed on the subsequent distribution.

The harness creates a throwaway localhost certificate in a private temporary
directory. Python's SSL server serves the card and WebAuthn pages on a second
port. Only that certificate's SPKI pin is passed to the disposable App. The
harness removes the key at shutdown. It does not change system trust or the
product's certificate policy. Password fixtures retain HTTP URLs.

Card re-authentication stays ON by default. P-12 disables it through
`credentials-prefs` only in its synthetic profile and restores it in a
`finally` block. Separate rows check the fresh-profile default and an actual
authentication request. The latter observes only the verified
`com.apple.SecurityAgent` focus handoff, App survival and crash counts. It
does not enter system credentials or bypass authentication.

WebAuthn produced a visible native Views dialog with no AppKit parent
(`private-page-and-dialogs-results.json`). Patch 0808 supplies the missing
parent and page-relative position through
`open_browser_window.mm:199`, on show and resize. Chromium retains the modal
manager, focus policy and decision callbacks. P-20 create/get and P-21 native
dialog cancellation pass on this distribution. P-21 also checks that Escape
leaves its AppKit parent visible (`private-dialogs-retry-1-results.json`).

P-19 initially reached the HTTPS-First path rather than the login form.
Chromium records interstitial reason 5, `kIncognito`, for that public HTTP
origin (`components/security_interstitials/core/https_only_mode_metrics.h:262`).
The row now submits the existing HTTP localhost form. It retains the private
context, parent-context, no-offer, no-save and unchanged-store assertions.
Those checks pass in the focused run. The full run exercises the Work Profile
left focused by P-17. No security preference is disabled for P-19.

The HTTPS-First warning was registered during navigation completion. The
native modal manager then received the same cross-site commit and closed it.
`https-close-trace.log` records `shown native=1`, then `cross-domain navigation
closes modal count=1`, closing reason 0 and model destruction. Chromium's
normal `TabDialogManager` path sets `close_on_navigate=false` for this ordering
(`ask_before_http_dialog_controller.cc:270`). The native manager closes its
dialogs at `web_contents_modal_dialog_manager.cc:203`. Patch 0809 defers the
hosted warning until every observer has seen that commit. A weak tab reference
and navigation generation cancel a stale deferred show. The next focused
run crashed during warning cleanup. At that D5 checkpoint no warning decision had passed on that
distribution. The final 619324d3 framework passes the full HF decision/lifetime set.

At 21:05, closing the tab with the warning still open destroyed its
`AskBeforeHttpDialogController` inside `TabModel::DestroyTabFeatures()`.
The controller's widget closure unblocked the tab through `SetTabBlocked()`.
That sent a tab UI event while `GetTabFeatures()` was already null, and
`TabUIHelper::GetFavicon()` dereferenced it. Source evidence is
`tab_model.cc:471`, `tab_strip_model.cc:4974` and `:1417`,
`ask_before_http_dialog_controller.cc:184`, and `tab_ui_helper.cc:199`.
The local `Open-2026-11-07-210523.ips` stack confirms that order. The suite
stopped at its first App death and cleanup left no owned process or window.
The M5 screen was held at that checkpoint until the user dismissed the crash dialog.

Prepared engine patch 0810 keeps the blocked-state update and skips only
the UI event after tab features are gone. Modal security checks, fullscreen
handling, and live-tab notifications stay intact. It applies to a scratch
copy of the current source. It was not built or runtime verified at that D5 checkpoint; PR #264 later built it and passed the real warning teardown flows.
`PW-HF3-tab-close` covers the real tab-close path that crashed the earlier
PW-HF1 cleanup. The decision rows wait for both named actions to become
available before sending input. No crash-prone build will be relaunched on M5.

## Historical D5 distribution (not accepted)

Both branches include main `cca168124c668000d1a3dd283cd8a70e4540d366`,
including #204, #222, #223 and #234. Built distribution SHA-256:
`20b0f93667d460c07b1ffa5c6066cd5aaaec8047513a97a2cc52b3df77e590b3`.
This distribution crashes on warning cleanup and is not accepted.

The engine apply/build/distribution and all 8 strict status checks pass:
33 Open patches, 117 CEF patches, 69 overlay files and 34 symbols. The Debug
App build and commands-dump check pass. Full password and engine regression
acceptance were pending at that D5 checkpoint; the H and PR #264 results supersede it. Intentional crash rows are M1-only by rule and are
not run by this M5 acceptance.

### HTTPS warning Return on macOS (D6)

The real app routes Return to the warning's key `NativeWidgetMacNSWindow` and
`BridgedContentView`; no App command or menu action runs. The warning stays
visible and the HTTPS-First decision histogram records SHOW only. This is
Chromium's configured behavior: `AskBeforeHttpDialogController::CreateDialogModel`
sets `OverrideDefaultButton(kNone)`, and `ui/views/style/platform_style.h` sets
`kReturnClicksFocusedControl` false on macOS. PW-HF2-return checks that Return
makes no decision, then uses real Escape input and checks DONT_PROCEED and the
previous page. It does not change a security guard or invoke a controller
callback directly. The red diagnostic and per-run loads are in the D6 handoff.

### Automatic policy fixture isolation (D6)

The first full D6 run passed 61 rows, then PW-POLICY-never saw no prompt. A
focused real sign-in observed no prompt events or sheet and a login-count
change from 1 to 2. That diagnostic was interrupted by foreground loss and
is not acceptance. Chromium's `ShouldPromptUserToSavePassword` in
`components/password_manager/core/browser/password_manager.cc` returns false
for PSL/grouped matches, then its no-prompt path saves the successful login.
Earlier policy rows used sibling `example.com` hosts in the same Profile.
Each automatic-policy row now uses an empty synthetic Profile, requires a
new password-save offer and the real sheet-button answer, checks both saved
logins and blocked-site counts, and checks that its parent Profile store stays
unchanged. Chromium's matching and save behavior remain enabled.

P-22 also needs a new credential, rather than an existing sibling-host match.
The D6 red run kept the same Space and measured login counts 1 before quit,
1 after relaunch, and 2 only after submission, with no sheet or prompt event.
Chromium's `password_manager.cc:237-271,1746-1770` deliberately saves PSL/grouped
matches without a prompt. The corrected row uses an empty Profile after the
same no-opt-in relaunch and retains no-sheet/no-event/disabled-capability checks,
requires zero logins/blocked sites, and checks the parent store is unchanged.
The real-App focused P-22 and PW-MOCK-offers rows pass on framework `619324d3`;
no engine policy or persisted preference changed. Raw D6 receipts retain both
that red run and the isolated pass. Full-suite acceptance is recorded separately.
