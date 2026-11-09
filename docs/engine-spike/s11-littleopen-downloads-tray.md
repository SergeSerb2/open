# Little Open downloads tray (2026-11-09)

`DownloadsCenter` feeds both Library and the Little Open tray with the same live
session snapshots. A title-bar button appears after the window starts a download
and remains while its session has visible downloads. This keeps the existing
minimal title bar quiet before the first download. The arrow shows the aggregate
byte fraction for known active totals; unknown totals use a static ring, with no
idle animation or progress polling.

The exact tray appearance is a **guess**, authored for Open. Arc facts come from
[FA LA-10](../re/features-advanced.md#31-behavior-spec): the strings pass recorded
`LittleBrowserDownloadsTrayViewController`, `LittleBrowserDownloadsTrayItemView`
and `LittleBrowserDownloadsTrayAction` in
`.re/features-advanced/little-strings.txt` (`strings` on Arc's read-only binary).
These facts establish a compact tray sharing main downloads data. They do not
establish the tray dimensions, colors, placement or toolbar icon. No Arc assets
or code were copied. The implementation follows Open's existing title-bar
accessory spacing and native transient popover, with semantic text colors and
13/11 pt typography. It shows up to five rows before scrolling.

## Ownership and lifetime

`OEDownload.webContent` is the existing source page. Progress callbacks may
precede the destination callback; `OEClient` now passes its source page into
`OEBrowserContext.oe_handleDownloadUpdated` so the early wrapper keeps that
link (it previously initialized `webContent:nil`). `DownloadsCenter.updated`
captures its Little Open controller's stable session ID on the first callback.
That ID is immutable for this transfer. Later progress does not use the key
window, URL or Profile as a substitute. Main-window downloads have no Little
Open session ID. Historical rows loaded from disk have no source session and
never appear in the tray. No new attribution is written to disk.

The existing App delegate's download-owner lookup searched main factories only.
It now also resolves `littleOpenHosts` so a standalone page can receive its real
destination callback. This fixes the destination routing as well as feeding the
tray. The App's coordinator change callback removes a tray when its owning
session closes. The tray holds that controller weakly. Closing a tray or its
source window leaves the shared Library item intact.

Rows show filename, source host, received/total bytes or terminal state, with
Pause, Resume, Cancel, Open and Show in Finder controls as applicable. They call
`DownloadsCenter`'s existing actions. Completed files use its cached off-main
file availability check. Missing files disable Open and Show in Finder.
Terminal rows remain for this session, subject to the existing shared
1,000-session-entry bound and explicit Library removal/clear. The tray creates no
row views before it is opened. It reuses rows during progress callbacks, and
releases them when closed. It adds no timer, display link or disk I/O on the
main actor.

## Verification

Engine fingerprint: vendor `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`,
embedded code `983ddb7a61e82970c8315db8f980881bd2495fe996148436d016b17c5610a1ba`.
These are the new #266 engine, not the older distribution.

Base: `origin/main` `7ae68e4a`, plus `origin/s11/downloads-history` through
`4423de80` because #286 was not on main. Work is on
`s11/littleopen-downloads-tray`; no PR or merge is requested.

The M1 is on hold. All on-screen receipts below are M5, under
`/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`, with
`OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1` and `/tmp/dlg.js` before and after each
run. The focused flow uses the normal built bundle, avoiding the old downloads
suite's cloned CEF bundle teardown. `CFFIXED_USER_HOME` isolates normal App
preference saves in a temporary home (Foundation home resolution checked). No
`defaults` command or automation-defaults mutation is used. All pages, folders,
files and transfer sources are synthetic. Open uses a disposable data root and
loopback port. The existing `download-opener.swift` application reads the actual
file and records its byte count and SHA-256 without launching user apps. Reveal
uses the existing record-only automation policy.

Run:

```sh
OPEN_DOWNLOADS_CASE=littleopen OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1 \
  tools/e2e/engine_e2e.py --only downloads --style chrome --stop-on-app-death
```

| Check | Result | Evidence |
|---|---|---|
| Debug build | PASS | `.re/littleopen-downloads/build-popover-focus.log` |
| Tray real-App rows (M5) | 16 PASS, cleanup PASS | `.re/littleopen-downloads/positive-6.json`, `e2e-positive-6.log` |
| Attribution break-and-revert (M5) | Expected attribution FAIL detected; source restored byte for byte; final rerun pending | `.re/littleopen-downloads/negative-attribution.json`, `e2e-negative-attribution.log`, `attribution-mutation.log` |
| Touched render checks | Pending | |
| Light/dark tray screenshots inspected (M5) | PASS, visual inspection only | `.re/littleopen-downloads/tray-light.png`, `tray-dark.png` |

## Review checklist

| Item | Result / evidence |
|---|---|
| Input/memory limits | Existing center bounds session entries to 1,000. No new parser, file schema, network buffer or unbounded source is added. |
| Lifetimes/callbacks | Weak source controller; immutable session ID; popover close clears its delegate before close; coordinator cleanup removes session-owned trays. Real-App Escape and source-close rows pass. |
| Real event paths | Real page input starts transfers; automation presses the title-bar and row NSButtons. The native popover root and the existing Little Open pre-key hook own Escape; real-App Escape passes. |
| Checks prove the change | The deliberate early-source removal fails `little_tray_attribution`; final restored rerun pending. Screenshots are for human inspection, not a file-size claim of pixel parity. |
| Isolation/cleanup | Disposable data/cache roots and port. No defaults writes or system appearance changes. Failed attempts and the 16-row run leave zero owned processes/windows, with no forced kill (`cleanup-*.json`). |
| UI/motion | Popovers do not animate. Progress changes only on engine callbacks, with disabled layer implicit actions. No rest animation. |
| Docs | Followups, status, App-shell plan and Downloads guide link this receipt. Arc visual parity remains explicitly unproved. |

## Changed files

| Area | Files |
|---|---|
| Tray and ownership | `App/PageChrome/LittleOpenDownloadsTray.swift`, `App/PageChrome/DownloadsCenter.swift`, `App/LittleOpen/AppLittleOpen.swift`, `App/AppDelegate.swift` |
| Native title bar | `Packages/OpenKit/Sources/OpenFeatures/LittleOpenTitleBarView.swift` |
| Download source bridge | `Engine/OpenEngine/src/OEClient.mm`, `Engine/OpenEngine/src/OEBrowserContext.mm`, `Engine/OpenEngine/src/OEInternal.h` |
| Automation / E2E | `App/Automation/AutomationLittleOpen.swift`, `App/Automation/AutomationLittleOpenDownloads.swift`, `tools/e2e/downloads.py`, `tools/e2e/littleopen_downloads.py` |
| Documentation | This receipt, `docs/automation.md`, `docs/downloads.md`, `docs/followups.md`, `docs/plans/app-shell.md`, `docs/status.md` |

## Limits

The exact Arc tray look remains unproved. The static Arc evidence establishes
only existence and shared download data. This tray follows Open's current
native controls and the implementation above.

The session tray uses the existing 1,000-entry session bound. It does not restore
an old Little Open window's downloads after an App relaunch. Persisted terminal
history remains available in the main Library. Reveal is verified through the
suite's record-only file-action policy; the real Finder is not opened. Open is
verified with the actual downloaded file through the existing background file
opener. No full Downloads-history regression or full verify-all is claimed by
this focused tray task.

## Retained attempts

All attempts used the M5 and the new #266 engine. Dialog checks stayed at zero.

| Attempt | Result and change |
|---|---|
| `positive-1.json`, `positive-2.json` | Fixture setup failed: the main tab and blank Little Open used the same URL, so command-bar Switch to Tab closed Little Open. Unique fixture URLs fix this. The first wrapper's reserved zsh `status` variable blocked its automatic final dialog query; an immediate manual query returned zero, and the wrapper now uses `tray_suite_rc`. |
| `positive-3.json` | Empty case PASS; attribution FAIL. This exposed the missing source page on early progress wrappers. |
| `positive-4.json` | 14 core rows PASS. The generic key harness refused the transient popover's contradictory native key-window state before dispatching Escape. |
| `positive-5.json` | 14 core rows PASS; actual Escape dispatch failed to dismiss the tray. Fixed by reusing `PageChromePopoverView`, focusing the root, and handling Escape through the existing Little Open pre-key route when AppKit keeps its parent key. |
| `positive-6.json` | All 16 rows PASS, cleanup PASS, no forced kill. |
| `negative-attribution.json` | Deliberate `webContent:nil` mutation reproduces the attribution FAIL. Cleanup PASS; no forced kill; dialog checks zero. |

Attempt JSON, screen-run logs, build logs and cleanup reports are retained under
`.re/littleopen-downloads/`. Screenshots are manual visual evidence, without a
pixel-parity assertion against Arc.
