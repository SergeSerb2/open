# Automation channel (test harness)

Open's end-to-end tests drive the real app through a local Unix socket. There is no computer use: nothing here moves the system mouse, types on the system keyboard, or touches another app. Key and mouse events are built inside Open and go only to Open's own windows. Pixels come only from Open's own windows.

Every agent command that opens Open on screen must hold the machine-wide lock
for one suite or diagnostic invocation, including launch and cleanup:

```sh
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --style chrome --only window
```

Release the lock between suite invocations. Do not hold it during builds,
verify-all, or offscreen render checks. Nested peer instances within a suite use
that suite's existing lock; they do not acquire it again. The lock serializes
agents, while native-focus interruption tracking still covers user activity.

Builds, `swift build`, and every `tools/verify-all.sh` invocation use the separate
machine-wide heavy-job slot script (two jobs at a time):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Debug
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/verify-all.sh
```

Do not hold the on-screen lock while waiting for a heavy-job slot. Keep the
on-screen lock around one suite only; take the heavy slot around build steps.

## Enable

- Debug builds always include it (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG OPEN_AUTOMATION`, `project.yml`).
- Release builds include it only with `OPEN_AUTOMATION=1 tools/build.sh Release` (used for measurements). A normal Release build has no socket code at all.
- Socket: `<data root>/automation.sock`, mode 0600. The data root is `$OPEN_USER_DATA` or `--user-data-dir=DIR`, else `~/Library/Application Support/Open-Dev` (Debug) or `.../Open` (Release); it holds `State/browser.json` and `Profiles/<dir>/{Engine,State}` (docs/plans/profiles.md §5). `--automation-socket=PATH` or `$OPEN_AUTOMATION_SOCKET` override the socket path. Code: `App/Automation/AutomationServer.swift`.

## Protocol

One JSON object per line in each direction.

```text
-> {"id": 1, "cmd": "open", "args": {"url": "https://example.com"}}
<- {"id": 1, "ok": true, "result": {...}}
<- {"id": 2, "ok": false, "error": "no tab 1234"}
```

Commands run on the main actor, one at a time per connection (`App/Automation/AutomationController.swift`).

## Client

```sh
export OPEN_USER_DATA=/tmp/open-test      # same as the app's
tools/openctl ping
tools/openctl open url=https://example.com
tools/openctl tabs
tools/openctl eval js='document.title'
tools/openctl key key=t modifiers='["cmd"]'
tools/openctl snapshot path=/tmp/window.png
tools/openctl raw '{"cmd":"pages"}'
```

Arguments are `key=value`; values that parse as JSON are sent as JSON.

## Addressing pages

- `tab`: a sidebar tab ID (UUID string from `tabs`). A tab that is not loaded yet is loaded first.
- `tab`: a page identifier (number from `pages`). Use it for popups and extension popups.
- `tab: "popup"`: the open extension popup.
- `index`: position in the focused Space's tab order (favorites, pinned, today).
- No `tab`: the selected tab.

## Commands

| Command | Args | Result |
|---|---|---|
| `ping` | — | pid, Chromium and CEF versions, engine root (`Profiles/`) and data root |
| `tabs` | — | Sidebar tabs of the focused Space in row order: id, title, url, section (`favorites`/`pinned`/`today`), selected, visible, loaded, loading, audible, crashed, favicon, and `page` (engine state, below) when loaded |
| `tab-state` | `tab` | Model/live state of one tab, including an inactive Space's tab |
| `tab-strip` | — | Actual engine strips: all-Spaces model IDs, content IDs, active model tab, membership |
| `frame-save-counters` | — | Actual snapshot captures, dirty schedules, factory tree changes and mirror syncs |
| `space-profile` | `space`, `profile` name | Production sidebar profile assignment intent; closes old Space hosts |
| `peek-open`, `peek-expand`, `peek-close`, `peek-state` | `tab`, `url` for open | Production Peek entry, promotion, dismissal and host identity |
| `pages` | — | Every live page: identifier, kind (`tab`, `popup`, `extensionPopup`, `unowned`), url, title, style (`alloy`/`chrome`), context (profile), browser id and index (the `OEBrowser` tab strip), hidden, crash state |
| `spaces` | — | Spaces with focus and counts |
| `space` | `space` | Focus a Space |
| `space-create` | `title`, `profile` | New Space; a new `profile` name creates an Open profile (`BrowserModel.createProfile`) with its own engine context in `Engine/<dir>` |
| `open` | `url`, `background` | New Today tab at the top (Arc placement) |
| `select` | `tab` or `index` | Select a tab |
| `close` | `tab` (id or page number) | Like Cmd-W on that tab; a page number closes that popup |
| `pin` | `tab` | Pin or unpin (Cmd-D) |
| `split` | — | Add Split View with the next tab, or unsplit |
| `navigate` / `back` | `tab`, `url` | Load a URL / go back |
| `wait` | `tab`, `timeout` | Wait until the page is live and not loading |
| `eval` | `tab`, `js` | Run JavaScript in the page's main world (through the OpenWeb `WebContent` protocol); promises are awaited |
| `devtools` | `tab`, `method`, `params` | Raw DevTools protocol command; events arrive in `events` |
| `click` | `tab`, `selector` or `text` | Click an element with DevTools input events (a real user gesture inside the page) |
| `rightclick` | `tab`, `x`, `y` | Right click in the page |
| `type` | `tab`, `text` | Insert text in the focused page field |
| `key` | `key`, `modifiers`, `route`, `window` | Key press inside Open. `route: "app"` (default) goes through `NSApplication.sendEvent`, like real typing; `route: "window"` goes straight to the window's first responder (the page view), which tests the engine's pre-key hook. `window: "popup"` targets the action popup's panel instead. `text` sends plain characters to the first responder. |
| `mouse` | `window`, `x`, `y`; `action=move`, `action=hover`, or `action=click` with `modifiers` (`option`, `command`, `shift`, `control`); or `from` / `to` point pairs | Own-window click, queued pointer motion, or native resize drag; system cursor stays unchanged. `click` runs the window's layout pass first (as real input follows a display cycle) and queues the mouse-up before sending the mouse-down, so controls that track the mouse (the window buttons) finish. Motion events carry a tag; from the first one on, pointer-driven window logic (the sidebar hover reveal) ignores the hardware pointer, so someone using the Mac cannot disturb a check. `move` and `click` also set the automation pointer at once (`BrowserWindowController.automationPointer`), and `hover` sets it after it has delivered enter, move, and exit (it rebuilds every tracking area first, and those rebuilds must still see the old point). A `move` delivers no enter or exit, so it clears `hover`'s record of entered owners and the next `hover` enters the owners under its point again; state that reads where the pointer is, not an event (the window buttons' hover after a full-screen exit, a restore, or a show), reads it instead of the hardware pointer. `hover` also delivers enter, move, and exit to the owners of the tracking areas under the point, title bar included (tracking areas follow the hardware pointer), and returns the owners it found. macOS's own window-button glyphs and tiling menu follow only the hardware pointer |
| `focus` | `tab` | Give the page keyboard focus |
| `find` / `zoom` / `mute` | `tab`, … | Find in page, zoom level, mute |
| `print-pdf` | `tab`, `path` | Print to a PDF file |
| `devtools-open`, `fullscreen-exit` | `tab` | — |
| `extensions` | — | Installed extensions and the window's toolbar actions (through the OpenWeb `ExtensionHost` protocol) |
| `popup` | `extension` | Run the action like a click on its button; returns the popup page |
| `popup-close` | — | Close the open popup |
| `actions` | — | The focused window's toolbar actions from Chrome's model (fork patch P2): `ready`, and per action id, name, title, tooltip, accessible name, badge and colors, enabled, has popup, pinned and pinned index, wants to run, site access, showing popup, `live` (from the live model, else the profile's list), and the toolbar image and plain icon (PNG byte count, hash, point width, `pixels`: each representation's pixel size, and `object`: the image object's identity) |
| `ext-pin` | `extension`, `pinned` (default `true`) | Pin or unpin an action |
| `ext-move` | `extension`, `index` | Move a pinned action to a pinned index |
| `ext-run` | `extension`, `source` (`toolbar` default, `menu`, `command`) | Run the action as the user would; returns whether it ran (a popup opens, or `chrome.action.onClicked` fires) |
| `ext-menu` | `extension`, `source` (`toolbar` default, `menu`), `select`, `keep`, `stale` | The action's context menu items (title, command, enabled, checked, separator, submenu); with `select`, run the item with that title and return `items` and `ran`. `keep` keeps this menu open (not cancelled); `select` with `stale` then runs the item on that kept menu and cancels the new one |
| `ext-popup` | — | The open popup: `open`, its page, its extension, its source (`user`, `command`, `api`), and `staysOpenOnBlur` |
| `activate` | — | Activate Open and make the focused window key (Chrome's "active window"), even with a popup panel in front; returns `key` |
| `windows` | — | Open's windows: number, class, frame, key, first responder |
| `shell-windows` | — | Standard controller IDs and native window numbers |
| `window-state` | `id` (optional: another standard window, not made key) | Frame, sidebar mode/width/reveal, panel frame, traffic-light centers, frames, and visibility, the title bar frame, the hardware pointer in window coordinates (read only), hover-reveal state (`reveal`: phase, show/hide counts, last dwell, zone, the card's frame and on-screen offset), chrome geometry (`chrome`: URL field, favorites section, Space header band, title frame and baseline, hover states), window buttons (`trafficLightsDimmed`, `trafficLightsHovered`, per button alpha and action, the window's AX button attributes `axWindowButtons` with role and subrole), the automation pointer (`automationPointer`, window coordinates, or null when it is in another window or never moved), `key`, `appActive`, `miniaturized`, `zoomed`, selection, shown page IDs, engine URL/active ID, native and HTML full-screen state, transition state and completed transition count. Runs the window's pending layout first |
| `window-focus` | `id`, `activate` | Make that own window key; optional own-app activation |
| `appearance` | `name` (`light`, `dark`, or anything else for the system's) | Open's own appearance (`NSApp.appearance`); the system setting is untouched |
| `window-close` | — | Native close for the current standard window; model tabs stay |
| `window-reopen` | — | Real application reopen handler, including after the last window closes |
| `window-fullscreen` | — | Native full-screen toggle; wait for completed transition count before testing the result |
| `window-deminiaturize` | — | Restores a minimized window, as a click on its Dock tile does; wait for `miniaturized` false |
| `sidebar-move` | `tab`, `section` or `folder`, `index` | Production SidebarDelegate move intent; model and engine strip share the resulting order |
| `folder-create` / `folder-toggle` | `title` / `folder` | Create fixture folder through the model; production sidebar expand/collapse intent |
| `folder` | `tabs`, `section` (`today`/`pinned`), `title`, `at` | Folder in the focused Space holding `tabs` in order, moved to index `at` |
| `favorite` | `tab` | Move a tab to its profile's Favorites |
| `dismiss` | — | End what a Chromium command opened: a modal panel (Print), sheets (Save As), Chromium's own Views windows (DevTools, Chrome windows). Returns what it closed |
| `sidebar-clear` | — | Production sidebar Clear Today intent |
| `archive` | — | Recent real archive rows for the focused profile |
| `window-frame` | `frame` `[x, y, w, h]`, `unconstrained` | Move/resize the main window; `unconstrained: true` keeps the exact frame even past the screen (capture-size comparisons on a smaller display) |
| `snapshot` | `path`, `window` or `tab` | PNG of one of Open's windows (default: the main window), or of one page |
| `policy` | `dialogs`, `prompt`, `permissions`, `contextMenu`, `fullscreen` | Answer JS dialogs (`accept`/`dismiss`/`hold`), permissions (`grant`/`deny`), record context menus (`record`: the event lists `items` and `commands` with ids, titles, submenus) or run one command (`run:<id>`, after the right click returns), keep the window size on page fullscreen |
| `dialog` | `accept`, `text` | Complete a held dialog |
| `events` | — | Drain the event log: `change`, `load`, `loadError`, `open`, `dialog`, `permission`, `contextMenu`, `fullscreen`, `download`, `console`, `devtools`, `extensionPopup`, `tab-request` and `window-request` (P1 requests from Chromium, with `refused` when the shell said no) |
| `script-add` / `script-remove` | `id`, `source`, `css`, `end`, `matches`, `allFrames` | Boost-style user scripts (through the OpenWeb `WebProfile` protocol) |
| `filter` / `filter-stats` | `block` (substrings) | Request filter (ad-block hook) and its counters |
| `permission` | `origin`, `kind`, `state` | Read or set a site permission |
| `download-dir` / `downloads` | `path` | Where downloads go; list downloads |
| `metrics` | `interval` | Chromium task manager rows and the physical footprint of every Open process |
| `timing` | — | Monotonic launch marks from kernel process start, presented-sidebar mark, renderer first contentful paint, and clock-mapping uncertainty |
| `startup` | — | Actual sidebar class, visible window count, page count and context count recorded before engine start |
| `host-counts` | — | Cumulative tab host creations, retained tab hosts, and engine web-content count |
| `sidebar-unload` | `tab` | Production sidebar unload intent without selecting the row |
| `save` | — | Write the snapshot now; returns its path |
| `quit` | — | Quit Open normally |

## Window pixels

`snapshot` captures only Open's windows, from inside Open, so it needs no Screen Recording permission:

1. `CGWindowListCreateImageFromArray` with Open's window and its child windows (Chrome-style pages live in child windows). If that returns an empty image, AppKit draws the window's views instead.
2. The window server leaves out the layers that Chromium's GPU process draws into our window. So each visible page's DevTools `Page.captureScreenshot` goes into a temporary layer right above that page's view while the window server captures. Whatever AppKit draws over a page (the hover-reveal card and its shadow, Peek controls, toasts) then composites over real page pixels, as on screen. Pages that cannot get such a layer are pasted in at their frames.

`tools/e2e/engine_e2e.py` uses `snapshot` for the main window and `screencapture -l <Open's window number>` for panels and Chromium dialogs. `screencapture -l` captures that one window only.

## End-to-end suites

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Debug
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only shell                       # model, keyboard, split, persistence
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only window --config Release     # startup, lifecycle failures, real window, persistence, static comparison
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only sidebar                     # intents, correct live page, cache eviction, static comparison
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only peek                        # promotion identity, cleanup, model strip, live pane color
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only features --style alloy      # engine features
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only extensions --style alloy    # needs .re/ext/unpacked/*
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only extensions --style chrome
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only tabstrip --style chrome     # fork patch P1: chrome.tabs sees Open's tabs
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only actions --style chrome      # fork patch P2: toolbar actions and popups
OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Release
/usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only measure --config Release    # launch, memory, idle CPU
```

Every run is isolated, because several agents run the harness at once: it gets its own data root `~/Library/Application Support/Open-E2E-<suite>-<style>-<pid>-<random>`, the matching Chromium cache root `~/Library/Caches/<same name>` (Chromium's rule for roots under Application Support), and a scratch folder in the system temp folder. All three are deleted when the run ends, also after `timeout` or Ctrl-C; `--keep` keeps them and prints their paths. A run also deletes the folders of earlier runs whose process is gone. No folder name is shared between runs. Each suite writes `docs/engine-spike/results-*.json` plus screenshots. `tabs` reports `page.chromeTabId` and `page.chromeWindowId` (the `chrome.tabs`/`chrome.windows` ids of a hosted tab, else -1). The `tabstrip` suite loads `tools/e2e/fixtures/tabs-probe` (records tab events, sets a badge) and Bitwarden. Extensions come from `.re/ext/unpacked/{ublock-lite,darkreader,1password,bitwarden}` (CRX files from the Chrome Web Store, unpacked with `tools/crx-unpack.py`, which keeps the store ID).

The `actions` suite loads a copy of `tools/e2e/fixtures/action-probe` and Bitwarden. It checks extension toolbar actions, menus and popups, including update, reload, renderer crash and window teardown. `--only app-actions` retains main's app-command suite (also available through `--only commandbar`).

Startup regression flags exist only in automation builds:
`OPEN_AUTOMATION_SKIP_DISPLAY_LINK=1` leaves the real three-second first-frame
timer running without a display link. Engine startup must continue with
`firstFrameConfirmed=false`, `firstFrameWaitTimedOut`, and no `sidebarDrawn` mark.
`OPEN_AUTOMATION_QUIT_BEFORE_ENGINE=1` requests Open's native terminate action
during the first-frame wait; `OPEN_AUTOMATION_EARLY_NAVIGATION=<URL>` submits
Open's address action before readiness; `OPEN_AUTOMATION_DISMISS_ENGINE_FAILURE=1`
clicks Open's own Quit alert button after a real engine-load failure. They send
no input to the system or other applications.

The window and sidebar suites compare the live app against F0001 when the
capture-time snapshot and capture exist in the main checkout's `.re/`.
`OPEN_ARC_CAPTURE_ROOT` can name that `.re` directory explicitly. With no
captures, only the comparison is reported SKIP; functional flows still run.
Private screenshots and snapshot data stay in `.re/app-shell-comparison-*`.
Only the per-element measurement tables are written to `docs/engine-spike/`.

The window suite reports `kernel_process_start` separately and requires the
kernel timestamp in all ten benchmark launches. Debug timing rows print named
SKIP results with a Release-only reason. Sidebar `space_switch_wrapper` proves
the live page and wrapper context; `durable_profile_storage` points to the
`profiles` suite.

`tools/e2e/engine_e2e.py --only profiles` checks the engine data layout
(`<root>/Engine`, docs/plans/profiles.md §6.2):
- each profile's copy of the tabs probe sees only its own tabs and windows
  (both directions), with the default profile's probe allowed in incognito;
- every disk profile is on disk (its `Preferences`, a `Local State` entry, a
  Chrome window);
- a second profile's persistent and session cookies and localStorage survive
  a relaunch;
- a legacy layout (the default profile's Chromium files in `Profiles/Default`,
  installation files in `Profiles/`, the cache in `~/Library/Caches/<root>/
  Profiles/Default`) migrates with an identical file inventory and a
  byte-identical `browser.json`, also with unreadable files; a locked file
  gives one launch in the old layout, then migrates;
- `Engine/Default` already in use is left alone and reported;
- a crash at each step (`OPENKIT_DEBUG_MIGRATION_CRASH=engine-journaled|
  engine-moved|engine-installation|engine-staged|engine-published|
  engine-cleanup`) leaves every file in exactly one place and finishes on
  the next launch.

`OPENKIT_DEBUG_MIGRATION_FAIL=engine-publish` simulates an I/O error at the
publish rename (the rollback path). `openkit profiles DIR engine-layout
[--json]` runs the App's layout step alone and prints its timing.

### App shell commands and Settings (Step C)

`--only commandbar` drives the real command bar field editor with `key`
(`route=app` and `route=window`), a loopback HTTP page that prevents default key
handling, native menus, and the real Settings and Library presenters. It covers
background opens, Pin/Unpin actions, profile isolation, custom search engines,
key overrides, tab/folder/split duplication, Archive restore, and relaunch.
It uses the app's existing snapshot writer. No unit or mocked engine checks
stand in for these flows.

Additional socket commands:

| Command | Purpose |
|---|---|
| `commandbar-state` | Read actual bar mode, text, rows, selection, and monotonic first-result timings. Does not create the bar. |
| `menu-state`, `menu-perform id=…` | Read native menu validation or invoke an enabled native menu item. |
| `reload-keybindings` | Load the actual `State/keybindings.json`, validate conflicts, and rebuild menus and the global registration. |
| `sidebar-duplicate id=…`, `sidebar-tree` | Send the production SidebarDelegate intent; read fresh subtree IDs and load flags. |
| `settings-state`, `settings-toggle name=hotkey\|external` | Read the shared real presenters; commit the live Links settings model. |
| `settings-custom-engine template=…` | Save a custom engine through the live Profiles settings model. |
| `library-restore id=…`, `library-history-open url=…` | Exercise the live Library restore transaction or its profile-scoped history action. |
| `hotkey-state` | Read Carbon registration, attempts, and any nonfatal registration error. Does not send a global key. |
| `save-page-state` | Read the real Save panel request and pending state. |

Reports identify the engine source from the vendor source stamp and the matching
embedded/vendor Mach-O UUIDs. Release socket runs require
`OPEN_AUTOMATION=1 nice -n 10 tools/build.sh Release`. A normal Release build
keeps the socket off. The first-open command-bar budget includes construction
and service work; the fixture waits for the normal post-paint prewarm before
opening the bar. The repeat-open timing is reported separately.


### Foreground GUI launch and readiness (Step C main merge)

Normal e2e sessions launch the exact built `.app` through LaunchServices
(`open -n -W`), with a fresh suite data root. The socket `ping` supplies the actual
app PID; the harness retains the launch waiter and closes only that app.
The LaunchServices waiter can end before app readiness, including with an
`open -W` GetProcessPID error. The harness keeps its existing 60-second deadline
for the real socket/PID handshake. The window suite verifies this with a real
`open -n` launch without `-W` during the three-second first-frame-timeout fixture:
the launcher ends, then the engine starts and the page must load.
Direct
executable launches remain only in the intentional early-quit/missing-engine
checks. A raw executable can have a visible window but no foreground activation
grant on macOS 26. `NSApp.activate()` is a request, not a synchronous grant.

Key and page-focus commands require the real application and requested
window to become active/key; they fail before sending events if readiness times out. `focus` waits
for both the page's native responder and `document.hasFocus()`. `window-state`
reports those native flags and screen bounds. Tests poll the resulting UI state
instead of treating the key response as proof that the UI has finished changing.
`activation-events` returns a bounded list of this app's native activation and
resignation notifications, with monotonic uptime and its key-window number.
The trace includes the frontmost application's name and PID, as does
`native-focus-state`. Input responses include the native readiness-grant uptime.
Window-chrome receipts retain this timeline to distinguish foreground loss from
an edge or animation failure. Only foreground app metadata is read; input goes
only to Open, and no other app's window content is read.

`--only app-actions` runs the complete Step C command-bar/native-menu/action flow,
including page Copy/Paste/Undo/Select All, model undo, lazy duplication, and real
Settings/Library. `--only commandbar` remains available with the same checks.
Use `--style chrome` to exercise production P1 tab hosting. Screenshot comparisons
request the existing `window-frame unconstrained=true` mode and wait for the exact
reference size; their dimensions and ≤1 pt/ΔE00≤2 assertions stay unchanged.


Each run uses its unique `Open-E2E-*` data and cache roots described above. A native activation helper addresses the
PID returned by that socket and first checks its exact executable path; it never
activates an Open instance by bundle identifier. App cleanup waits for that PID
to exit even if the LaunchServices waiter has ended. Native mouse moves carry a
request tag and return only after the local monitor and reveal tracker have
consumed that request. Coalescing stays enabled and production chrome is unchanged.
While the tagged pointer filter is installed, unrelated app deactivation does
not dismiss the virtual pointer's reveal card. Ordinary app sessions still dismiss
it on deactivation. Pointer checks assert socket state without requiring activation.

`yield-activation pid=…` allows a cooperative handoff only to another instance
of the exact same Open executable. The harness uses a second owned instance with
private data to verify inactive tagged hover and to exercise interrupted native
input. It never activates or sends input to an unrelated app.

Native-focus assertions use the activation trace from their readiness grant to
the assertion boundary. An outside foreground change makes that attempt
`INTERRUPTED`, even if its assertion succeeded. The original assertion, app name
and trace remain in the receipt. The harness retries at most three attempts,
from a fresh workflow fixture: replaying a single destructive key could otherwise
close a second tab or apply an edit twice. Interrupted attempts never enter the
accepted pass count. Exhausting attempts prints `INTERRUPTED` and exits 2;
an ordinary failed assertion still prints FAIL and exits 1. No check, tolerance,
timing budget or native event route is replaced by a successful no-op.

A lead-requested display hold is enforced by `.re/hold-on-screen`. While it exists,
the harness refuses new Open launches. The file must be removed only after an
explicit resume instruction; an elapsed estimate is not permission. Offscreen
renderers and compilation do not require removing the file.


### Step C review: focus and shutdown observations

Automation responses include `observationStart` (process monotonic uptime).
`focus-state` reports the current responder owner, Find text/visibility, sheet
state, and the count/result of post-navigation focus decisions. It accepts an
optional standard-window `id` without activating that window. `activation-events`
starts before the first window/engine turn and reports native resignation and
workspace foreground changes. The e2e runner guards every timed poll/capture
interval as well as native-input intervals. An unexpected foreground change
stores INTERRUPTED, preserves the original assertion and trace, and allows at
most three fresh workflow attempts. No interrupted assertion counts as a pass.
Intentional inactive-window controls first verify the exact owned peer's PID and
native handoff event, then start a new background-state observation interval.

`commandbar-state.timingScope` labels the existing 50 ms bar timings exactly:
showCommandBar entry to first snapshot applied. They exclude preceding key
routing, socket transport and frame presentation.

`save-page-choose(path:)` replies to Open's pending Save presenter through the
socket and runs its same capture completion. The native sheet is shown and closed;
the remote system Save button is not driven. The actual engine capture and file
write run unchanged.
`background-read` starts the selected live host's real background-color read.
`async-engine-state` reports owned pending capture and background tasks. With
`OPEN_AUTOMATION_SHUTDOWN_TRACE=1`, the own-profile State/shutdown-order.json
records prepare, hostsClosed, engineShutdownBegin and engineShutdownEnd. The
ordering check queues actual Save/background work with the automation-only
`OPEN_AUTOMATION_ASYNC_TASK_DELAY_MS` scheduling delay, then quits. Cancellation
must clear work and close hosts before the actual engine shutdown boundary. The
flag delays scheduling; it does not replace engine responses.

## Library Space Manager (App lane 1b)

The `sidebar-completion` suite currently covers E5/E6 (menu, App command,
Space-header menu, and command bar search plus Return), plus the manager's
undo, archive/restore, window replacement, and no-browser reopen flows. It uses the
real built App, real model/stores, native menus, and native mouse/key events.
It creates a temporary copy of **Open's own** bundle with a unique bundle ID
and re-signs that copy locally. This gives every run a separate preferences
domain, data root, engine cache, and socket. It uses synthetic data URLs and
no remote debugging port. It never opens or copies Arc.

| Command | Arguments and result |
|---|---|
| `library-open` | `entry=command` (default) dispatches App `manage-spaces`; `entry=space-menu` performs the existing Space-header menu's “Manage Spaces…” item. Both use the shared Library presenter on `.spaces`. For the app menu, use existing `menu-perform id=manage-spaces`. Returns manager state. |
| `space-manager-state` | Reads the **attached** native manager, its class/identity/context ID, model and undo identity, isolated/global preview flags, columns, grabber points, up to 200 visible-outline rows per column, browser switcher order from real view positions, real model UndoManager notification count, and this App's window records. Points use the existing `mouse` command's window coordinates. Available after the last browser closes. |
| `space-manager-drag` | `space=<ID> to=<zero-based index>` drags the real visible grabber through `OEApplication.sendEvent`; the native tracking loop dequeues the drag/up events. Rejects invalid IDs/indices and offscreen grabbers. Returns manager state. |
| `space-manager-menu` | `space=<ID> item=<title>` performs the existing manager column menu. Add `node=<ID>` to perform that real outline row's context-menu item instead. No new confirmation policy or model implementation. |
| `library-close` | Closes the shared Library window, cancelling any attached sheet first. Reports `closed` and the sheet window numbers it cancelled. Available with no browser window. |

Use existing `key route=app window=<Library number>` for Cmd+Z and other
Library keys. Undo uses AppKit's nil-target Edit menu action and the Library
window's real model UndoManager. It has no second key handler.
Use existing `library-restore` for archive restore and `snapshot window=<number>`
for full-resolution real-window captures.

On M1, hold the outer validation lock once per job, plus the on-screen lock
for one suite invocation:

```sh
/usr/bin/lockf /tmp/open-m1-validation.lock /usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only sidebar-completion
```

The suite saves rest/hover PNGs, its App log, and `cleanup.json` in
`.re/space-manager/run-<unique ID>/`. C2/session2 manager references are not
available on M1. Supplied Settings/folder session2 frames do not contain this
manager page. These are capture-ready artifacts, without a claimed pixel
comparison. The M5 lead owns capture comparison and design review.

Every exit cancels opened sheets, closes Library/browser windows, terminates
only processes whose executable is inside this suite's copied bundle, and
checks the system's on-screen window metadata for those PIDs. A dialog left
at cleanup makes the suite fail, even if it was cancelled during cleanup.
`OPEN_SPACE_MANAGER_EARLY_FAILURE=1` forces an assertion immediately after the
real Library opens; the suite must fail and still write a passing cleanup
receipt. Remove that environment variable for the passing flow.

For a recorded engine refresh, pin `OPEN_SPACE_MANAGER_ENGINE_SHA256` to the
supplied framework SHA256. The suite streams hashes of both the embedded App
framework and `Vendor/cef/Release` framework, and records the fork stamp.
The recorded framework must match the pinned hash. Because `embed-cef.sh`
re-signs the embedded copy, the suite reproduces that existing ad-hoc signing
step on a disposable APFS clone and requires exact embedded-byte equality
with the re-signed clone. It records all three hashes and fails before launch
on a mismatch. It never changes the recorded distribution. `OPEN_SPACE_MANAGER_ENGINE_PROVENANCE`
records the supplied distribution label; it is a label, not an inferred build
revision. `OPEN_SPACE_MANAGER_EVIDENCE_ROOT` separates current and historical
receipts/PNGs. Rebuild against the refreshed distribution before rerunning real
flow, forced-failure cleanup, and break-and-revert proofs.

### Unattended cleanup

Every suite closes owned dialogs and popups from `finally`, then terminates every
process it started. Cleanup records exact executable paths for the app and its
children, sends the normal quit request, and kills any verified owned PID that
remains. A small CoreGraphics helper checks only on-screen window numbers for
those PIDs; it reads no other app's UI. Each result has a `cleanup` receipt and
fails if an owned process or on-screen window remains.

The extension `actions` suite matches the uninstall confirmation by Chromium's
window class, the probe extension's name and the Cancel/Remove controls. Its menu
case always dismisses the dialog from `finally`. Set
`OPEN_E2E_FAIL_UNINSTALL=1` for an intentional failure after that exact dialog
appears; cleanup must still report PASS with zero owned windows and processes.
`popup-callback-close phase=open|resize|ready toggle=true|false` closes from a
real engine delegate callback (`phase=clear` cancels the policy).
`ext-run` / `ext-menu focusTab=<split pane>` focuses a real Split View pane and
runs the action/menu in the same socket turn. `ext-menu snapshot=true` returns
the action snapshot before yielding. `window-close releaseBrowsers=true` drops
the mirror's browsers without calling `OEBrowser.close` and reports whether they
were released; this covers the destructor path with an open popup.

The tabstrip fixture includes `visible: false` and a disabled extension submenu
with an enabled child. `context_menu_allowlist` checks delivered top-level and
leaf titles on each target; `context_menu_disabled_submenu_refused` sends the
child's raw command id and requires both the engine refusal log and no extension
click event. These use the same real context-menu policy/selection path as the
existing hidden-native-command check. Live refusal logs are read from the
LaunchServices stderr file before app quit.

For a revision-specific engine gate, pass `--engine-sha256 <64 lowercase hex>`.
The runner requires the complete Vendor framework to match that exact digest.
Xcode re-signs the embedded copy, so it also compares every byte of both binaries
after removing signatures on private APFS clones and normalizing only the
signature-storage `__LINKEDIT.vmsize` and `filesize` fields. It refuses to launch if the code
fingerprints differ. Receipts record raw and code fingerprints, the required
Vendor hash, UUIDs and source stamp. UUID equality alone does not identify an
engine revision. Real app/Vendor bundles are never modified by the comparison.

### Manager review acceptance (round 1)

`sidebar-completion` also drives pinned-row Delete, the real loaded-row unload
button, Copy Link and the native pasteboard, Unmute against the live engine
host after the real command bar mutes tabs, and the pinned URL reset button. Selected Today archive must keep a live
neighbor selected. With no browser, Copy Link still works and the existing retained model window
remains the sole saved window. The App fallback refuses pinned close/unload.

For each window lifetime case, a real Space drag comes first, then actual New
Window or Close Window, then Library Cmd+Z with no intervening edit. The suite
requires exactly one model undo notification, the prior Space order, and saved
window IDs equal to shell controller IDs. This ordering detects undoable window
creation and closed-window ghosts. Window lifetime suppression preserves an
already-disabled UndoManager registration state.

The bounded `space-manager-lifecycle` readout reports cached view identity,
context, built-column count, horizontal origin, section row coordinates, App and
manager appearance, key/visible state, and undo-registration state. It does not
layout or build a hidden manager. `space-manager-scroll x=<0...100000>` scrolls
the real manager clip view (clamped to the document). `space-manager-row-controls
space=<ID> node=<ID>` reads the real row frame and visible accessibility labels
and control points; traversal is limited to 200 rows, 256 views and 12 levels.
Input still uses existing `mouse`/`key route=app` events. `key=delete` supplies the
native Delete key. Browserless Copy Link uses the existing real manager menu
and creates no browser or model.

The suite checks that hidden Library focus changes keep its cache and built
columns, visible replacement preserves horizontal origin, a native Library
section click fills the cache, and App-only appearance changes reach the manager
and are restored in `finally`. Focus assertions require Library visibility/key
ownership after Cmd+L, Escape and Return, command bar dismissal after each Escape,
and unchanged browser tab IDs across Library Cmd+W. The invalid drag-index case
is named `automation_reorder_index_boundary_self_check`; it proves only the
harness boundary, not a product reorder rule.

Focused context-menu guard proofs call `context_menu_commands(..., run_all_commands=False)`.
They still capture all six real menu models and run the disabled-child and hidden-native
command selections. The regular tabstrip suite keeps the complete command smoke loop.
The probe popup storage check waits for the extension API, since `isLive` precedes
its document/API injection. Foreground-interruption checks stay enabled in both flows.
