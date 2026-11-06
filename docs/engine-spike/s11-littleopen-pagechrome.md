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

Final receipts and negative proofs are pending. The initial current-engine
real-App run passed every existing page-chrome row and the Little Open dialog,
beforeunload and permission-persistence flows. Its Cmd+T assertion used the
wrong expected destination and was corrected to the main command bar.
Subsequent attempts were INTERRUPTED by foreground loss to macOS
UserNotificationCenter and are not acceptance evidence.
