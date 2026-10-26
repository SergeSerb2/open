# Automation channel (test harness)

Open's end-to-end tests drive the real app through a local Unix socket. There is no computer use: nothing here moves the system mouse, types on the system keyboard, or touches another app. Key and mouse events are built inside Open and go only to Open's own windows. Pixels come only from Open's own windows.

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
