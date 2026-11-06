# Automation notification guard: blocked on the native force-start

This is an incomplete local prototype, not a ready fix or a claim that R-4 is
closed. The Section 11 lead requested a separate guard after Little Open
[#191](https://github.com/SergeSerb2/open/pull/191). Engine: current main CEF
SHA-256 `3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738`.
No Chromium/CEF fork source was changed.

The e2e launchers pass `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`. Only the
notification fixtures explicitly opt in. The App converts the environment flag
into `--open-automation-skip-macos-notifications` inside `OPEN_AUTOMATION`.
OpenEngine checks the App configuration, rather than raw process arguments,
before installing the notification observer. Swift skips native status reads,
activation observation and authorization; disabled list/click commands fail.
Normal user launches and normal Release configuration keep their existing path.

The fresh Debug build passes Downloads 34/34 with zero focus interruptions and
clean process cleanup. Its runtime observer counters are skipped 2 + 1, reached
0. The native authorization state stays unknown and reports setup suppressed.
The 2026-11-06 06:25:26–06:26:03 `log show` receipt has **zero**
`TCCAccessLaunchDisclosurePromptIfNeeded` entries from tccd.

This is insufficient: `usernoted` still connects the Alerts helper from that
exact fresh-copy Downloads bundle at 06:25:36.854 and 06:26:00.665. Skipping
`CefSetOpenNotificationHandler` does not suppress every path that constructs
Chromium's native dispatcher. The helper still registers with macOS, so a new
signing identity can still show the disclosure. R-4 remains open.

The window experiment was stopped with SIGTERM at 06:29:06 when this was found.
It is intentionally INTERRUPTED, not acceptance. All owned processes exited.
Raw receipts are private under `.re/notification-guard/downloads/` and
`.re/notification-guard/window/`; `setup-receipt.json`, `system.log` and copied
`launch-*.log` files retain the evidence. The prototype's observer marker is
not a complete native-suppression gate.

The next change belongs to Section 6 / the lead. Exact fork locations:

- `chrome/browser/notifications/mac/notification_dispatcher_mojo.cc:39`:
  the constructor explicitly force-starts the service through
  `CheckIfServiceCanBeTerminated()`.
- The same file's `GetOrCreateService()` calls
  `provider_factory_->LaunchProvider()` and binds the native notification service.
- `chrome/browser/notifications/mac/mac_notification_provider_factory.cc:28`:
  `LaunchOutOfProcessProvider()` uses `kChildProcessHelperAlerts`.
- `chrome/browser/notifications/mac/notification_platform_bridge_mac.cc:46`:
  `NotificationPlatformBridge::Create()` constructs both dispatchers.

The new switch already reaches CEF and is available for a native guard. The
lead must route that work to the fork owner. The App prototype has no ready PR,
no full-verifier qualification, and no U-N1 native notification delivery proof.
U-N1 remains a user hand check for each signing identity; no system prompt was
accepted or dismissed by this work.
