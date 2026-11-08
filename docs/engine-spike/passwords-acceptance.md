# Passwords and autofill acceptance (Section 15)

This continues [the D4 dropdown investigation](passwords-dropdown.md).
The current App integration uses engine PR #264, framework SHA-256
`619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`.
The post-main-merge H run passes the full password suite: **77 PASS**,
**C-2 M1-only by rule**, **PW-KC1 user hand check**. It has zero interrupted
attempts, zero new crash reports and clean owned-process/window shutdown.
The sanitized per-row loads are in [results-passwords.json](results-passwords.json).
H stopped before PR creation: the features suite passed 17 rows, then failed
because the Widevine component updater provided no CDM in its bounded wait.
The first attempt expired at the 120 s row watchdog; the suite correction
starts the named row and limits the download wait to 60 s, preserving the
playback acceptance criterion. The corrected attempt reports the missing
component at load 21.29 / 45.44 / 47.58, with clean owned-process/window
shutdown and zero interruptions. This is a component prerequisite failure;
no engine root was changed and no engine regression cause is inferred.

Per the engine-side stop rule, page, littleopen, settings-preview and the full
verify-all gate are NOT RUN on this H checkpoint. The new Little Open
page/save-completion ownership row is also NOT RUN. The App PR remains
pending this gate; there is no all-suite acceptance claim. Full local rows,
commands and loads are in `.re/s15/h/REPORT.md`.

The sections below retain D5/D6 diagnosis history. D5's old framework is not
accepted or replayed. Raw historical receipts remain in the engine checkout's
`.re/s15/d5/` and `.re/s15/d6/`; H receipts are under `.re/s15/h/` in the App
checkout. Receipts contain no credential values.

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
The M5 screen is held until the user dismisses the crash dialog.

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
