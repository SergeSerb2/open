# Session Downloads (S11)

This branch implements the lead's Downloads design. Transfers and controls use
the real App, native Library rows, native save sheets and the engine automation
socket. The Home ring geometry and recent-download interval remain marked
guesses from the lead's design.

`DownloadsCenter` owns the session list for all engine contexts. Only engine
`downloadDidUpdate` callbacks supply progress. The Library reads immutable
snapshots and native rows send actions to this center. One queued main-actor
turn coalesces a burst; no timer or display link polls downloads. Completed
files are checked off the main actor, and no download history is written.

Folder mode resolves the Profile's folder on a filesystem actor, claims a unique
name against existing files and concurrent requests, and lets Chromium resolve
any external filesystem race. It creates `~/Downloads` when needed. A missing
custom folder falls back there and records `download-directory-fallback`. Ask
mode queues a real save sheet behind the requesting window's existing sheet;
window close and quit cancel outstanding choices exactly once.

The Home control observes `SidebarContext.downloadBadge`. Known totals use a
weighted byte fraction; an unknown total uses a 25% arc with a one-second CA
rotation. The finite completion animation uses the evidenced checkmark and
timings; Reduce Motion omits scale/spring. A new transfer interrupts completion
from presentation opacity values. No download animation remains at rest.
Geometry (32 pt plate, 2 pt ring inset/stroke) and the 60-second Home click rule
are the lead's marked guesses, not measured Arc parity. The existing Library
window owns the list; no toolbar popover or Little Open tray is added.

The quit guard presents the exact Downloads warning before sleep capture. Keep
browsing cancels termination. Close Open cancels transfers and follows the
existing shutdown path. A confirmed close does not show the alert again when
sleep capture asks to terminate a second time. The generic Warn before quitting
preference has no guessed UI; see [static evidence](re/downloads-s11.md).

## Verification state

Builds use `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`, through
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug`. The built engine
was verified by the real-App runner as distribution SHA-256
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.

| Gate | Result / evidence |
|---|---|
| Debug app | Final run pending; engine distribution is pinned above. |
| Real-App `downloads` | Final 32-gate run pending. Covers known/unknown totals, partial failure, folders, save acceptance/cancellation, native controls/menus, file actions, Profile isolation, fallback, Home navigation/motion, shortcut and quit. |
| Native idle observer | S8 observer is reused with a Downloads ownership filter. A real repeating timer canary proves the observer is live; settled counts, publication count and CA keys must remain zero. |
| Negative proofs | Grouped real behavior mutations run outside committed code; final coverage pending. The source is restored before the final build. |
| `features` | 19 PASS, 0 FAIL: `.re/downloads/regression-features.json`. |
| `shell` | 7 PASS, 0 FAIL: `.re/downloads/regression-shell.json`. |
| `app-actions` | 63 PASS, 0 FAIL: `.re/downloads/regression-app-actions-recovered.json`. |
| `window` | 72 PASS, 4 FAIL (machine: built-in display main): `.re/downloads/regression-window.json`. Only `chrome_dark_rings`, `traffic_light_look`, `traffic_light_stale_hover`, `comparison`; comparison worst ΔE00 3.65, position 1 pt, dark ring rows ΔE00 6.21–6.71. |
| Focused verify-all | `build`, `settings-preview`, `sidebar-render` PASS (78/84/113 s): `.re/downloads/verify-focused/summary.txt`. |
| Full verify-all | Final run pending after merging current `origin/main`. |

The Open action goes through real `NSWorkspace` document delivery to a disposable
background application. That process reads the fixture and returns its URL,
131072-byte length and SHA-256. Show in Finder records the dispatched URL under
an automation flag, as the design permits; it opens no Finder window. Copy writes
the real pasteboard file URL, and Trash uses FileManager.

The suite clones the built App with a unique preferences domain, uses a unique
profile/data/cache root and ephemeral loopback port, restores its keys in
`finally`, cancels sheets and reaps only its own verified PIDs. On this macOS,
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
