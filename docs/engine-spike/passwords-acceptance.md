# Passwords acceptance: D5

This continues [the D4 dropdown investigation](passwords-dropdown.md).
Acceptance is still in progress. Raw receipts live in the engine checkout's
`.re/s15/d5/` directory. No credential values are recorded in those receipts.

## Confirmed causes

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
run crashed during warning cleanup. No warning decision passes on the new
distribution yet.

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
copy of the current source. It is not built or runtime verified yet.
`PW-HF3-tab-close` covers the real tab-close path that crashed the earlier
PW-HF1 cleanup. The decision rows wait for both named actions to become
available before sending input. No crash-prone build will be relaunched on M5.

## Current distribution

Both branches include main `cca168124c668000d1a3dd283cd8a70e4540d366`,
including #204, #222, #223 and #234. Built distribution SHA-256:
`20b0f93667d460c07b1ffa5c6066cd5aaaec8047513a97a2cc52b3df77e590b3`.
This distribution crashes on warning cleanup and is not accepted.

The engine apply/build/distribution and all 8 strict status checks pass:
33 Open patches, 117 CEF patches, 69 overlay files and 34 symbols. The Debug
App build and commands-dump check pass. Full password and engine regression
acceptance are pending. Intentional crash rows are M1-only by rule and are
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
