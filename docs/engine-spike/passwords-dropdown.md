# Hosted autofill dropdown: D4

App base: `s15/prompt-wiring` at `b9d06570c1e1a10ed62dcbee0edfa536155cb63e`.
Engine base: `s15/engine-autofill-bridge` at `9416d74ba45798446f3c525f072eec4fe00ce0b6`.

## Why the helper found no popup

The baseline engine creates a visible `NativeWidgetMacNSWindow` with an
`AXList`, but its native parent is zero. The helper requires a child window,
so it excludes that real dropdown. The same profile's password-manager
internals records `PasswordManager::Autofill`, `wait_for_username`, and
`PasswordAutofillAgent::OnFillPasswordForm`. The popup histogram also records
a password popup. This rules out form detection or 0805 suppressing this popup.

Chromium source: `ui/views/widget/native_widget_mac.mm:278` resolves a Views
parent with `NativeWidgetMacNSWindowHost::GetFromNativeView`.
`ui/views/cocoa/native_widget_mac_ns_window_host.mm:266-294` returns null for
Open's AppKit host. The check in `CanShowRootPopup` permits popup creation;
it does not establish this parent relationship.

0807 calls an overlay hook in `PopupBaseView::DoShow`, before `Show`.
`Engine/fork/src/open/browser/tab_strip/open_browser_window.mm:161` attaches
the popup above the page's native AppKit window. The hook applies only to
Open-hosted WebContents. Chromium keeps popup layout, focus policy,
accessibility, and acceptance checks. H-2 and the modal dialog host are unchanged.

Raw local evidence: `.re/s15/d4/probe-baseline3.log:416-434` has the parentless
popup and both internals pages. `.re/s15/d4/probe-key-trace.log:216-231` has the
native Open parent and passes P-3 after the parent fix.

## Why native keyboard acceptance failed in the reproduction

The host starts key and windowed. While typing the fixture, the asynchronous
renderer fallback calls `OpenBrowserWindow::HandleKeyboardEvent`, then
`NSMenu.performKeyEquivalent`, which runs the Full Screen action. A later native
focus notification clears the host's key flag while `NSApp.keyWindow` still
names it. The automation readiness guard refuses input at that point.
Down and Return never reach the popup in that failed run.

Raw evidence: `.re/s15/d4/native-fullscreen-trace.log:2-29` records the Full
Screen stack through the renderer acknowledgement and menu fallback.
`.re/s15/d4/probe-key-trace.log:216-222` records the inconsistent native key
state and focused renderer. `Engine/OpenEngine/src/OEEngine.mm:93-99` already
limits the shell's reserved shortcut handler to Command/Control. Plain Down
and Return do not enter that handler.

The engine fallback at
`Engine/fork/src/open/browser/tab_strip/open_browser_window.mm:452` now offers
only Command/Control shortcuts to the menu. Plain editing and popup navigation
keys keep the normal AppKit/renderer path. The input-readiness guard is unchanged.
This establishes the cause of the reproduced failure. The old Step 0 PR-2
receipt alone does not prove that its keyboard failure had this same cause.

## Acceptance guards and helper

Chromium rejects early acceptance for 500 ms after paint
(`chrome/browser/ui/autofill/autofill_suggestion_controller.h:59`).
`PopupRowView::OnMouseReleased` also rejects clicks unless the pointer was
observed outside the row (`popup_row_view.cc:315-328`). The helper waits beyond
the paint guard. The mouse variant sends a native exit/enter sequence and lets
the next display turn pass before clicking. These security checks stay enabled.

The helper recognizes reused popup windows. It checks the clicked page's
native parent, native popup class, visibility, and `AXList` role. The automation
`windows` command can return unique roles without credential labels or values;
the walk is bounded to 512 objects and depth 16. Password equality stays inside
the page. No credential popup or filled form screenshot is taken.

## Verification

Final engine framework SHA-256:
`90108efca13c9bbf1f2bc36cde19f2218d0f0ce6d92f55d80c8e03d10b3f1687`.
The final engine has no temporary key, focus, or mouse logging. Strict
`engine-status` passes all 8 checks: 29 active patches and 63 overlay files.

The Debug App build and `tools/verify-all.sh --only commands-dump` pass.
The single bounded full password run records **35 PASS, 1 FAIL, 33 NOT RUN**.
P-3, P-4, and P-4-mouse pass. P-5 fails at `passwords.py:506`: the expected
`passwordUpdate` sheet does not arrive. The runner stops there; it does not
exercise later rows. The cause of that save/update gap is unresolved.

| Check | Result | Load (1 / 5 / 15 min) |
|---|---|---|
| P-3: password child dropdown | PASS | 9.39 / 7.79 / 7.36 |
| P-4: native Down + Return | PASS | 9.39 / 7.79 / 7.36 |
| P-4-mouse: native popup selection | PASS | 11.92 / 8.34 / 7.55 |
| P-5: expected update sheet | FAIL | 11.21 / 8.25 / 7.53 |
| P-10 with a Settings-seeded address | PASS | 5.98 / 6.50 / 7.33 |
| P-12 with a Settings-seeded card | FAIL: child popup visible, field equality fails | 7.09 / 6.33 / 6.94 |

All rows, including those not run, are in
[the compact results](results-passwords-dropdown.json). Exact commands, raw
receipt links and every row's load are in the local `.re/s15/d4/REPORT.md`.

The seeded checks write synthetic records through the Settings WebUI service;
they do not prove the address/card save flows. An earlier focused run reaches
the submitted address page without an address save sheet. The first seeded
card attempt stops in the optional background internals reader before sending
acceptance keys; that attempt is incomplete. The card-only retry removes the
diagnostic reader and fails field equality after Down/Return. Its cause is
unresolved. No authentication guard is disabled for these checks.

Every final run verifies the new framework fingerprint, has zero recorded new
crashes, and passes owned-process cleanup with no remaining processes or
windows. Password equality remains inside the page. The full suite has no
foreground interruption and no retry.
