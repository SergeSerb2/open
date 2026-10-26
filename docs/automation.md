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
| `space-create` | `title`, `profile` | New Space; a new `profile` name creates an Open profile (`BrowserModel.createProfile`) with its own engine context in `Profiles/<dir>/Engine` |
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
| `key` | `key`, `modifiers`, `route` | Key press inside Open. `route: "app"` (default) goes through `NSApplication.sendEvent`, like real typing; `route: "window"` goes straight to the window's first responder (the page view), which tests the engine's pre-key hook. `text` sends plain characters to the first responder. |
| `mouse` | `window`, `x`, `y`; `action=move` or `action=hover`; or `from` / `to` point pairs | Own-window click, queued pointer motion, or native resize drag; system cursor stays unchanged. Motion events carry a tag; from the first one on, pointer-driven window logic (the sidebar hover reveal) ignores the hardware pointer, so someone using the Mac cannot disturb a check. `hover` also delivers enter, move, and exit to the owners of the tracking areas under the point (tracking areas follow the hardware pointer) and returns the owners it found |
| `focus` | `tab` | Give the page keyboard focus |
| `find` / `zoom` / `mute` | `tab`, … | Find in page, zoom level, mute |
| `print-pdf` | `tab`, `path` | Print to a PDF file |
| `devtools-open`, `fullscreen-exit` | `tab` | — |
| `extensions` | — | Installed extensions and the window's toolbar actions (through the OpenWeb `ExtensionHost` protocol) |
| `popup` | `extension` | Run the action like a click on its button; returns the popup page |
| `popup-close` | — | Close the open popup |
| `windows` | — | Open's windows: number, class, frame, key, first responder |
| `shell-windows` | — | Standard controller IDs and native window numbers |
| `window-state` | `id` (optional: another standard window, not made key) | Frame, sidebar mode/width/reveal, panel frame, traffic-light centers, frames, and visibility, the title bar frame, the hardware pointer in window coordinates (read only), hover-reveal state (`reveal`: phase, show/hide counts, last dwell, zone, the card's frame and on-screen offset), chrome geometry (`chrome`: URL field, favorites section, Space header band, title frame and baseline, hover states), selection, shown page IDs, engine URL/active ID, native and HTML full-screen state, transition state and completed transition count. Runs the window's pending layout first |
| `window-focus` | `id`, `activate` | Make that own window key; optional own-app activation |
| `appearance` | `name` (`light`, `dark`, or anything else for the system's) | Open's own appearance (`NSApp.appearance`); the system setting is untouched |
| `window-close` | — | Native close for the current standard window; model tabs stay |
| `window-reopen` | — | Real application reopen handler, including after the last window closes |
| `window-fullscreen` | — | Native full-screen toggle; wait for completed transition count before testing the result |
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
tools/build.sh Debug
tools/e2e/engine_e2e.py --only shell                       # model, keyboard, split, persistence
tools/e2e/engine_e2e.py --only window --config Release     # startup, lifecycle failures, real window, persistence, static comparison
tools/e2e/engine_e2e.py --only sidebar                     # intents, correct live page, cache eviction, static comparison
tools/e2e/engine_e2e.py --only peek                        # promotion identity, cleanup, model strip, live pane color
tools/e2e/engine_e2e.py --only features --style alloy      # engine features
tools/e2e/engine_e2e.py --only extensions --style alloy    # needs .re/ext/unpacked/*
tools/e2e/engine_e2e.py --only extensions --style chrome
tools/e2e/engine_e2e.py --only tabstrip --style chrome     # fork patch P1: chrome.tabs sees Open's tabs
OPEN_AUTOMATION=1 tools/build.sh Release
tools/e2e/engine_e2e.py --only measure --config Release    # launch, memory, idle CPU
```

Each suite uses a fresh user data dir under `~/Library/Application Support/Open-E2E-*` and writes `docs/engine-spike/results-*.json` plus screenshots. `tabs` reports `page.chromeTabId` and `page.chromeWindowId` (the `chrome.tabs`/`chrome.windows` ids of a hosted tab, else -1). The `tabstrip` suite loads `tools/e2e/fixtures/tabs-probe` (records tab events, sets a badge) and Bitwarden. Extensions come from `.re/ext/unpacked/{ublock-lite,darkreader,1password,bitwarden}` (CRX files from the Chrome Web Store, unpacked with `tools/crx-unpack.py`, which keeps the store ID).

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
the live page and wrapper context; `durable_profile_storage` remains BLOCKED on
the CEF `root_cache_path` follow-up in docs/followups.md.

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
app PID; the harness retains the launch waiter and closes only that app. Direct
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

`--only actions` runs the complete Step C command-bar/native-menu/action flow,
including page Copy/Paste/Undo/Select All, model undo, lazy duplication, and real
Settings/Library. `--only commandbar` remains available with the same checks.
Use `--style chrome` to exercise production P1 tab hosting. Screenshot comparisons
request the existing `window-frame unconstrained=true` mode and wait for the exact
reference size; their dimensions and ≤1 pt/ΔE00≤2 assertions stay unchanged.


The harness's data root is `.re/e2e-<suite>-<style>/user-data` in its own worktree,
not a shared Application Support path. A native activation helper addresses the
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
