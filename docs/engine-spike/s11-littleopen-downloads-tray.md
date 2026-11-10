# Little Open downloads tray (2026-11-09)

`DownloadsCenter` feeds Library and each Little Open tray with the same session
snapshots. The title-bar button appears after that window starts a download and
stays while its session has visible items. This keeps the existing minimal title
bar quiet before the first download. Finished items remain for the session.

Arc evidence is limited to the tray's existence and shared data. [FA LA-10](../re/features-advanced.md#31-behavior-spec)
records `LittleBrowserDownloadsTrayViewController`,
`LittleBrowserDownloadsTrayItemView` and `LittleBrowserDownloadsTrayAction` from
`strings` on Arc's read-only binary, retained in
`.re/features-advanced/little-strings.txt`. No Arc assets or code were copied.
Exact Arc geometry, colors and placement remain **guesses**. Lead design decision
F6 uses the same opaque `LittleOpenMetrics.titleBarFill` and explicit `darkAqua`
appearance as `LittleOpenSpacePicker.swift:27`, in both App appearances.

## Implementation and round 1 fixes

| Finding | Change |
|---|---|
| F1 | Capture the source session synchronously in `decide()`, before destination selection yields. Resolve `OEDownload.webContent` through `littleOpenHosts` by content identity. Retry while nil; preserve a known session ID. No `view.window`, key-window, URL or Profile attribution. |
| F2 | Explicit dismissal makes Little Open key and restores the page container or Downloads button as first responder. Outside clicks preserve their new focus. |
| F3 | Parent and popover key events enter `OEApplication.sendEvent`. Parent Escape reaches `handleLittleOpenKey` then tray `handleKey`. Return activates the focused action and consumes the event. Cmd+W resolves the popover's Little Open owner. |
| F4 | Native Ask sheet ownership is read from `sheetParent`; the real save-sheet controls finish the transfer. |
| F5 | `prepareToClose()` closes the tray directly. Move/close removes the session and tray while the transfer remains in Library. The source browser stays detached only while its transfers are pending/active; the next queued publication closes it after the last terminal callback. Profile retirement and shutdown release detached browsers too. |
| F6 | Space picker fill and explicit appearance; fresh light/dark images over an actual rendered page. |
| F7 | Rows expose ordered action buttons as AX children with explicit AXButton roles and labels. Opening focuses the first enabled action. |
| F8 | 32 pt file-type icons, Retry on failed rows, and the magnifier for Show in Finder. Actions reuse DownloadsCenter. |
| F9 | Only `.inProgress` items contribute to the active count and byte ring. Paused-only transfers say paused and have no running ring. |
| F10 | Render only the newest 100 session items; reuse one shared ByteCountFormatter. |
| F11 | Symbol images have a safe fallback. Equal snapshots skip tray rendering and title-bar updates. |

The tray shows at most five rows before scrolling. Row views are lazy, reused
while open, and released on close. The existing center bounds session history to
1,000 items; active transfers are not evicted. Historical disk rows have no
Little Open session ID and do not appear in a session tray. No attribution is
persisted. Completed-file availability checks stay off the main actor. No new
polling timer, display link or idle animation is added.

The existing App download-owner lookup also resolves `littleOpenHosts` for
standalone destination callbacks. The earlier source bridge fix passes source
content into wrappers created by progress before destination selection.

## M5 verification

This round merged `origin/main` through `dc8c7709` (#290), merge `1f45d06f`, before
building and acceptance. It keeps `s11/downloads-history` through `4423de80`
because #286 is not yet on main. Delivery is a push to
`s11/littleopen-downloads-tray` only. No PR or delivery merge is performed.

The M1 remains on hold. Every screen run uses the M5 screen lock, honors the
priority flag and sets `OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1`. `/tmp/dlg.js`
runs before and after each run and stops work for a nonzero count. Builds and
render verification use `heavy.sh` and
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Engine fingerprint:

- Vendor: `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`
- Embedded code: `983ddb7a61e82970c8315db8f980881bd2495fe996148436d016b17c5610a1ba`

The focused flow uses the normal built bundle. It avoids the old Downloads
suite's cloned CEF bundle teardown. A temporary Foundation home, data/cache
roots and loopback port isolate the run. No defaults command is used. Pages,
files and transfer sources are synthetic. The existing background
`download-opener.swift` probe reads the actual downloaded file and records its
hash and byte count. Reveal uses the existing record-only automation policy.

```sh
OPEN_DOWNLOADS_CASE=littleopen OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1 \
  tools/e2e/engine_e2e.py --only downloads --style chrome \
  --engine-sha256 346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd \
  --stop-on-app-death --suite-timeout 300
```

Evidence below is relative to `.re/littleopen-downloads/review-r1/`. The native
verifier owns its screen lock internally. A private run-only wrapper adds
`dlg.js` before and after each Settings preview invocation after that lock is
acquired; verification assertions are unchanged.

| Check (M5) | Result | Evidence |
|---|---|---|
| Expanded flow before screenshot-composition change | 31/31 PASS; cleanup PASS; no forced kill; dialog counts 0→0 | `positive-3.json`, `e2e-3.log`, `build-4.log` |
| Destination-capture break-and-revert | PASS: removing only early capture fails `early_move`; restored byte for byte, restored build PASS; cleanup PASS; dialogs 0→0 | `negative-early-capture.json`, `e2e-negative.log`, `attribution-proof.log` |
| Restored final Debug build and full tray flow | PASS: 31/31, cleanup PASS, no forced kill, no interruptions; dialogs 0→0 | `build-restored.log`, `positive-final.json`, `e2e-final.log` |
| features-render, extensions-render, settings-preview | PASS: all three targets plus build; Settings 47 checks/240 renders; Features 689 functional + 19 idle; Extensions 16; dialogs 0→0 | `verify.log`, `verify/summary.txt` |
| Light/dark tray and page images inspected | PASS: opaque picker surface, clear icons/text/actions over both real page appearances; visual inspection only | `tray-light.png`, `tray-dark.png`, `tray-light-page.png`, `tray-dark-page.png` |

| Real-App row (M5, `little_tray_` prefix) | Result | Assertion |
|---|---|---|
| `empty` | PASS | No button, item or popover before the first download. |
| `early_move` | PASS | Move at the destination-before-progress boundary; original session attribution survives and tray/session are gone. |
| `early_move_finish` | PASS | Transfer completes in Library and detached source browser is released. |
| `attribution` | PASS | Progress appears only in the source Little Open tray. |
| `progress` | PASS | Visible host/state/bytes and a fraction between zero and one. |
| `accessibility` | PASS | Downloads, row and action labels. |
| `ax_order` | PASS | Actual AX row order and Pause/Cancel child order, AXButton roles, initial Pause responder, file icon. |
| `return` | PASS | Popover-key Return is consumed by the tray, pauses the real transfer and keeps both Little Open windows. |
| `pause` | PASS | Bytes stop; paused-only label, no active ring. |
| `mixed_progress` | PASS | Paused plus running: count and ring use only running bytes. |
| `resume` | PASS | Bytes grow and Pause returns. |
| `cancel` | PASS | Real transfer and visible row become Cancelled. |
| `two_windows` | PASS | Two same-Profile Little Open windows keep separate trays. |
| `main_excluded` | PASS | A main-window transfer appears in neither tray. |
| `finish` | PASS | Actual transfer completes and row says Completed. |
| `retained` | PASS | Completed and cancelled session items remain. |
| `open_file` | PASS | Native Open invokes the file-opener probe; actual 1,048,576 bytes and expected SHA-256. |
| `reveal` | PASS | Native magnifier records the correct file through the existing reveal policy. |
| `retry` | PASS | Failed row exposes Retry and icon; pressing Retry starts a real new transfer for its source URL. |
| `ask_owner` | PASS | Visible native save sheet belongs to the source Little Open window. |
| `ask_finish` | PASS | Accept the real sheet, download finishes, sheet disappears. |
| `active_move` | PASS | Move with active visible tray: tray/session removed, Library transfer completes, detached browser released. |
| `active_close` | PASS | Close with active visible tray: same lifecycle assertions. |
| `cmd_w` | PASS | With popover key, Cmd+W closes only its Little Open owner; second Little Open and main tab survive. |
| `library_shared` | PASS | Real Library rows contain all tested shared download IDs. |
| `escape` | PASS | Popover-targeted Escape closes tray and preserves item. |
| `escape_parent` | PASS | Parent-targeted Escape records the parent `handleKey` path and closes tray. |
| `focus_restore` | PASS | Little Open is key with page container/button focus after Escape. |
| `row_bound` | PASS | 101 real page-input transfers; visible rows are exactly the newest 100. |
| `unchanged` | PASS | Coordinator focus refresh with equal snapshots leaves tray update count unchanged. |
| `source_close` | PASS | Closing the source preserves its completed Library item and actual file. |
The early-move fixture holds real progress only at the App callback boundary.
After the real destination continuation, it moves the source to Space and
releases callbacks. It creates no snapshots or fake transfers. The mutation
removes only `updated(download, context: context, atDestination: true)` from
`decide()`. The source is restored byte for byte before the final build/run.

The page screenshots combine the real page capture and the owned transient
popover at its actual window position. The native popover is not always a child
window, so `snapshot.overlayWindows` explicitly names owned visible windows.
These images are visual inspection, not Arc pixel-parity assertions.

## Round 1 changed files

| Area | Files |
|---|---|
| Lifetime and attribution | `App/PageChrome/DownloadsCenter.swift`, `App/LittleOpen/LittleOpenWebContent.swift`, `App/AppDelegate.swift` (one shutdown hook) |
| Tray and keys | `App/PageChrome/LittleOpenDownloadsTray.swift`, `App/LittleOpen/AppLittleOpen.swift`, `Packages/OpenKit/Sources/OpenFeatures/LittleOpenWindowController.swift` |
| Snapshot equality | `Packages/OpenKit/Sources/OpenSettings/SettingsTypes.swift` |
| Automation and screenshots | `App/Automation/AutomationDownloads.swift`, `App/Automation/AutomationLittleOpenDownloads.swift`, `App/Automation/AutomationController.swift` (owned-window overlay option), `App/Automation/WindowSnapshot.swift` |
| Real-App rows | `tools/e2e/littleopen_downloads.py` |
| Documentation | This receipt, `docs/automation.md`, `docs/downloads.md`, `docs/status.md`, `docs/followups.md`, `docs/plans/app-shell.md` |

## Review checklist and limits

| Area | Result / limit |
|---|---|
| Input/memory | 100 rendered rows; existing 1,000-session bound. The 101-transfer boundary is exercised through real page input. No new file schema/parser. |
| Lifetime | Weak tray owner; stable source ID; explicit close hook; detached browsers close after terminal callbacks, retirement or shutdown. Active-move/close rows check zero retained browsers. |
| Event paths | Escape from parent and popover, Return and Cmd+W enter NSApp. Return's handled-key receipt proves consumption before fallback; no audio capture is used. |
| Proof | Early-capture mutation is the required new negative proof. Other rows provide real-App positive coverage, not separate negative controls for every review finding. |
| Cleanup | Run-owned processes/windows are checked after quit; no user app is stopped. |
| Motion | Non-animated popovers; engine callbacks alone drive progress; implicit progress layer actions are disabled. |
| Docs | Automation, Downloads, status, followups and App-shell plan link this receipt. |

Exact Arc tray appearance remains unproved. Session attribution does not restore
an old Little Open tray across App launches; terminal history remains in Library.
A paused transfer keeps its detached source browser until resume/cancel or quit.
Retry reuses the Library source-URL action, which starts its new transfer in the
main window. Reveal is record-only; Open uses the actual file and background
probe. No full Downloads-history regression or full verify-all is claimed.

Retained round 1 attempts: `positive-1.json` exposed the detached-browser lifetime
failure after early move; `positive-2.json` exposed AXUnknown roles on image
buttons. Both left no owned processes/windows and dialog counts were zero.
The earlier 16-row acceptance and original source-wrapper mutation remain under
`.re/littleopen-downloads/`; this round's 31 rows and destination-capture mutation
supersede them for review acceptance.
