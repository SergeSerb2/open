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

The HTTPS-First warning appears but disappears before its action buttons can
be exercised. Its native parent is present. A bounded readiness wait and a
warning-specific accessibility query did not establish working buttons.
`https-dialog-buttons-results.json`, `https-specific-dialog-results.json`
and `https-dialog-ui-results.json` retain those failures. Cause diagnosis and
the three warning decisions remain pending. The warning's existing
close-on-deactivation behavior remains enabled.

## Current distribution

Engine branch `s15/engine-autofill-dropdown` includes main's #204, #222 and
#223, plus main through #238. Distribution SHA-256:
`b24b4776b4f5549f9a7b0e12352be831c5f53d68ffa144aa8c8d3ea8376345ec`.

The engine apply/build/distribution and all 8 strict status checks pass:
31 Open patches, 117 CEF patches, 67 overlay files and 34 symbols. The Debug
App build and commands-dump check pass. Full password and engine regression
acceptance are pending. Intentional crash rows are M1-only by rule and are
not run by this M5 acceptance.
