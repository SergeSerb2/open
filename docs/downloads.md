# Downloads (S11)

The Little Open tray branch includes persisted history from
`s11/downloads-history`. Its separate scope and acceptance are recorded in
[the history report](re/downloads-s11.md#persistent-history-and-profile-filter-2026-11-09-implementation).
[The tray receipt](engine-spike/s11-littleopen-downloads-tray.md) covers the new
per-window session UI; it does not claim a full persisted-history regression.
The older acceptance receipts below apply to the original session-download
implementation.

This branch implements the lead's Downloads design. Transfers and controls use
the real App, native Library rows, native save sheets and the engine automation
socket. The Home ring geometry and recent-download interval remain marked
guesses from the lead's design.

`DownloadsCenter` owns the live list for regular engine contexts. Only engine
`downloadDidUpdate` callbacks supply progress. The Library reads immutable
snapshots and native rows send actions to this center. One queued main-actor
turn coalesces a burst; no timer or display link polls downloads. Completed
files are checked off the main actor. Terminal history is stored per Profile,
with the newest 1,000 records retained. Library loads it lazily below session
rows. The Profile filter appears with two or more Profiles. Private downloads
never enter this provider. Historical rows reuse the file actions and can retry
their source URL. Remove/Trash, Clear Browsing Data and Profile deletion also
remove the corresponding persisted rows.

Folder mode resolves the Profile's folder on a filesystem actor, claims a unique
name against existing files and concurrent requests, and lets Chromium resolve
any external filesystem race. It creates `~/Downloads` when needed. A missing
custom folder falls back there and records `download-directory-fallback`. Ask
mode queues a real save sheet behind the requesting window's existing sheet;
Library Cancel, window close and quit cancel outstanding choices exactly once.
Library Cancel also closes an already visible save sheet.

The Home control observes `SidebarContext.downloadBadge`. Known totals use a
weighted byte fraction; an unknown total uses a 25% arc with a one-second CA
rotation. The finite completion animation uses the evidenced checkmark and
timings; Reduce Motion omits scale/spring. A new transfer interrupts completion
from presentation opacity values. No download animation remains at rest.
Geometry (32 pt plate, 2 pt ring inset/stroke) and the 60-second Home click rule
are the lead's marked guesses, not measured Arc parity. The existing Library
window owns the main list. Little Open now also shows a compact per-window
session tray; see [the tray receipt](engine-spike/s11-littleopen-downloads-tray.md).

The quit guard presents the exact Downloads warning before sleep capture. Keep
browsing cancels termination. Close Open cancels transfers and follows the
existing shutdown path. A confirmed close does not show the alert again when
sleep capture asks to terminate a second time. The generic Warn before quitting
preference has no guessed UI; see [static evidence](re/downloads-s11.md).

## Original session-download verification (2026-11-05)

Builds use `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`, through
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug`. The built engine
was verified by the real-App runner as distribution SHA-256
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.

| Gate | Result / evidence |
|---|---|
| Debug app | PASS after merging `origin/main` `ebcf08d2` (#176 Peek, includes #174 AppleScript / #173 Little Open): `.re/downloads/build-final-head.log`. No new Swift warnings. |
| Real-App `downloads` | **34 PASS, 0 FAIL, 0 INTERRUPTED**, cleanup PASS: `.re/downloads/positive-final.json`. Known/unknown totals, partial failure, folders, save acceptance/cancellation, native controls/menus, file actions, Profile isolation/fallback, Home motion/navigation/new window, shortcut, idle and quit. |
| Native idle observer | Ten zero counters over 2.006 s; publications 68→68; no queued publication or CA keys; load 30.90/15.45/11.78. Real timer canary 1→0. The leaked-timer mutation produces live count 1 and fails both canary/idle gates. |
| Negative proofs | **34/34 covered**, no missing gate: `.re/downloads/negative-summary.json`. Six grouped real behavior mutations cover 33 gates; `cancel-sheet-before.json` proves the final lifecycle fix on the real unfixed App. Faults are absent from final source and binary. |
| Pending sheet cancellation | Before: cancelled item, sheet still visible. After: cancelled item, no sheet/running download, cleanup PASS: `.re/downloads/cancel-sheet-before.json` / `cancel-sheet-after.json`. |
| Early failure while sheet is open | Deliberate exception after `save_sheet` PASS; App cleanup has zero remaining owned processes/windows, no forced kill: `.re/downloads/cleanup-final.json`. |
| `features` | **19 PASS**, cleanup PASS: `.re/downloads/regression-features.json`. |
| `shell` | **7 PASS**, cleanup PASS: `.re/downloads/regression-shell.json`. |
| `app-actions` | **63 PASS**, cleanup PASS: `.re/downloads/regression-app-actions.json`. |
| `window` | **76 PASS**, including all four formerly display-sensitive rows; cleanup PASS: `.re/downloads/regression-window.json`. |
| Focused verify-all | `settings-preview,sidebar-render` PASS: `.re/downloads/verify-focused/summary.txt`; final full run also passes these targets. |
| Full verify-all | Standard `heavy.sh tools/verify-all.sh --with-arc-data`: **22 PASS, one timing-only FAIL**, zero SKIP/INTERRUPTED: `.re/downloads/verify-final-head/summary.txt`. `commandbar-render` quiet rerun passes all rows; accepted combined result **23 targets PASS**. |

The command-bar timing rerun changes no threshold or assertion. The full run
measured CPU p95 9.01 ms / inline overhead +0.571 ms at load 9.7/10.7/12.0.
Under the quiet lock, the target passed at 5.82 ms / +0.007 ms, load
6.0/6.8/9.0. The unchanged `origin/main` binary from the same fresh baseline
build ran under the same lock/session: 6.29 ms / +0.443 ms, load 6.4/6.8/8.9
(the inline row fails there). Both raw attempts and the main comparison remain
in `.re/downloads/commandbar-quiet-1*.log` and `verify-commandbar-quiet-1/`.
This PR changes none of the command-bar/suggestion/command/drawing modules.

The final display is the main AW2726DM at 1×, 2560×1440 (native NSScreen
receipt `.re/downloads/display.json`). The earlier built-in 2× exceptions do not
apply. The final standard sidebar comparison builds its own baseline and passes
all 13 states plus CU5, with no override or reused products. The earlier default
run's display-sensitive values were ΔE00 1.17/1.73/1.95 and its main/branch tables
were byte-identical; unchanged capture/snapshot hashes and fresh-build evidence
are in `sidebar-stock-proof.json` / `sidebar-merged-proof.json`.

An early run stopped at machine load >200 is retained as interrupted and is not
accepted. A baseline-product reuse run is exploratory only. Foreground-loss and
harness-schema-error attempts are retained separately; the final App results
have no interrupted attempts.

The Open action goes through real `NSWorkspace` document delivery to a disposable
background application. That process reads the fixture and returns its URL,
131072-byte length and SHA-256. Show in Finder records the dispatched URL under
an automation flag, as the design permits; it opens no Finder window. Copy writes
the real pasteboard file URL, and Trash uses FileManager.

The suite clones the built App with a unique preferences domain, uses a unique
profile/data/cache root and ephemeral loopback port, cancels sheets in `finally`
and reaps only its own verified PIDs. Quit-preference variants now use transient
launch arguments; the suite no longer issues `defaults` commands. On this macOS,
remote save panels hide their native buttons. The automation uses the allowed
URL-input path through NSSavePanel's native response method. Its existing sheet
completion reads `panel.url`; the automation does not answer the engine directly.
The method's ABI is checked and an unavailable method produces a clear error.
Raw receipts are local in `.re/downloads/`; each attempt also writes
`docs/engine-spike/results-downloads-debug.json`.

## Hooks in shared/other-section files

- AppDelegate: center ownership, download event feed and pre-sleep quit guard.
- EngineWebContentHostFactory: destination routing and Home → Library selection.
- AppSettingsActions: Library snapshot provider and controls.
- OpenSidebar BottomBarView: substitutes the badge-capable Home control only.
- SidebarContext / SidebarView: package-neutral badge state and real control /
  layer evidence accessors.
- OpenSettings: local native Downloads row, formatter and context menu; additive
  Copy/Trash actions and optional cached file availability.
- AutomationController and engine_e2e: dispatch hooks; new work lives in separate
  AutomationDownloads.swift and downloads.py files.
