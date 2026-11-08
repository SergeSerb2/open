# Automation channel (test harness)

Extension E11/E12 acceptance runs with `tools/e2e/engine_e2e.py --config Release
--style chrome --only extensions-e2 --extensions PATH` (`PATH` contains the
unpacked `ublock-lite` and `darkreader` fixtures). It uses the real command bar's existing
`key` and `commandbar-state` commands. Command-bar rows include `extension`,
`content`, and `keycaps`. `ext-windows` lists only native extension popup windows:
controller class, page/window/browser ids, Cocoa frame, title, style, autosave
name, and whether the page is the content view. Numeric page handles work for
these windows too. `ext-windows {preference:true}` reads the one frame-autosave
entry; adding `value` writes or removes it so a suite can reset and restore it.
`ext-omnibox` takes `extension` and `op` (`start`, `input`, `reply`, `default`,
`cancel`). It exercises text/style bounds through the public engine API;
`default` reports presence, UTF-16 lengths, and range counts, without page text.

Open's end-to-end tests drive the real app through a local Unix socket. There is no computer use: nothing here moves the system mouse, types on the system keyboard, or touches another app. Key and mouse events are built inside Open and go only to Open's own windows. Pixels come only from Open's own windows.

Every agent command that opens Open on screen must hold the machine-wide lock
for one suite or diagnostic invocation, including launch and cleanup:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --style chrome --only window
```

Release the lock between suite invocations. Do not hold it during builds,
verify-all, or offscreen render checks. Nested peer instances within a suite use
that suite's existing lock; they do not acquire it again. The lock serializes
agents, while native-focus interruption tracking still covers user activity.

Builds, `swift build`, and every `tools/verify-all.sh` invocation use the separate
machine-wide heavy-job slot script (capacity is set by the lead):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Debug
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/verify-all.sh
```

Do not hold the on-screen lock while waiting for a heavy-job slot. Keep the
on-screen lock around one suite only; take the heavy slot around build steps.

## Updater core

`updater-state` is a read-only App query. Before the post-paint startup hook it
returns `created: false, started: false`. Once created, it reports `offReason`
(`invalid-public-key`, `missing-team-identifier`, `start-failed`, or null),
`started`, `canCheck`, `lastCheck` (Unix seconds or null), `automaticallyChecks`,
`automaticallyDownloads`, `automaticPreference`, and `channel` (`stable` or `beta`).
`foundVersion`, `completedChecks`, and `lastErrorCode` expose Sparkle delegate
results. Reading the query does not create an updater or request a feed.
The existing `settings-toggle` command accepts `name=updates` to invoke General's
toggle model and its preference writer; it returns the new boolean value.
The `timing` query includes `updaterCreated`, after first content paint (or the
existing two-second blank-page fallback), always after `sidebarDrawn`.

General's `open.general.automaticallyUpdate` setting defaults to true and controls
both Sparkle automatic flags live. `open.general.updateChannel=beta` allows beta
items as well as stable items on the next check. All other values select stable.
There is no channel UI yet. `check-for-updates` is not a command-bar suggestion
by design (`SuggestAdapter` exclusions); every dispatch of that ID uses the same
App updater path. `SUFeedURL` in Info.plist remains the normal feed.
In `OPEN_AUTOMATION` builds, `open.debug.updateFeedURL` overrides it only with
`OPEN_UPDATER_ALLOW_ADHOC=1` in the environment or defaults. That opt-in also
allows a build without a Team ID. Other builds ignore both defaults keys; only
the environment opt-in can permit ad-hoc signing, and the feed always comes from
Info.plist. The opt-in never bypasses public-key validation. Unconfigured builds never create Sparkle;
their update action opens General with “Updates are not set up in this build.”

Build Debug, then run the real-App `updater` suite:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/updater.py --config Debug
```

Check the shared priority flag before acquiring the screen lock. The suite tests
placeholder/malformed keys, the ad-hoc signing gate, one menu item, command-ID
dispatch, a signed loopback HTTP feed, stable/beta filtering, and live automatic
flags. A loopback canary proves the off paths make no feed requests. It generates
throwaway Ed25519 keys with OpenSSL in TMPDIR and uses Sparkle 2.10.1
`sign_update --ed-key-file`. `generate_keys -h` confirms its `-f` option imports
into Keychain, so the suite never uses it. It only changes and re-signs a temporary
App copy. The server binds only to `127.0.0.1` on an ephemeral port and stops in
`finally`. No ATS exception is added. Sparkle 2.10.1 rejects `file://` feeds with
error 2001: “The download request URL must use http or https” (`SPUDownloader.m`).
The loopback fixture replaces the plan's file feed with the lead's approval.
It resets touched defaults before launch and restores their original
plist types in `finally`, including Sparkle's `SU*` preferences and its
`NSWindow Frame SUUpdateAlert2` geometry entry.

`--force-failure` exits 1 with the real update window open to prove process/window
cleanup. `--tools PATH` selects the pinned tools folder. `--output PATH` selects
the private JSON receipt (default `.re/updater/results.json`). Install and relaunch
are not tested; ad-hoc library validation does not qualify a shipped update.
For a launch receipt, build main and branch Release with `OPEN_AUTOMATION=1`, then
use `--config Release --main-bundle /path/to/main/Open.app`. Wait for load1 ≤ 12,
then take the quiet and screen locks; this pairing needs no heavy slot. Build
under `heavy.sh` first, without the quiet lock. Time an already built CLI under
the quiet lock, then a heavy slot. The pairing alternates main/branch five times and
requires branch median `sidebarDrawn` ≤ main median. Every sample records load.

## Enable automation

- Debug builds always include it (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG OPEN_AUTOMATION`, `project.yml`).
- Release builds include it only with `OPEN_AUTOMATION=1 tools/build.sh Release` (used for measurements). A normal Release build has no socket code at all.
- Socket: `<data root>/automation.sock`, mode 0600. The data root is `$OPEN_USER_DATA` or `--user-data-dir=DIR`, else `~/Library/Application Support/Open-Dev` (Debug) or `.../Open` (Release); it holds `State/browser.json` and `Profiles/<dir>/{Engine,State}` (docs/plans/profiles.md §5). `--automation-socket=PATH` or `$OPEN_AUTOMATION_SOCKET` override the socket path. Code: `App/Automation/AutomationServer.swift`.

First run is detected once, before data-root preparation, when
`State/browser.json` does not exist. `--skip-first-run` or
`OPEN_SKIP_FIRST_RUN=1` selects the normal browser path. `--arc-dir=PATH`
overrides the read-only import source for tests and support. Always use a
disposable Open root and a synthetic source for first-run automation.

The shared e2e `Open` launcher adds `--skip-first-run` by default. Its direct
early-quit, missing-engine, and migration launches do the same. All suite
modules, peer launches, and benchmarks use that launcher. `tools/run.sh` and
the release smoke launch also pass the switch. `tools/openctl` connects to
an existing socket and never launches the App. `verify-all.sh` runs package
CLIs, not the App. The `firstrun` and `onboarding` suites opt into first run.
The former uses the intro's real skip/Continue actions before its existing
Section 7 assertions. Both always pass silent audio unless explicitly off.

The dev launcher `tools/run.sh` always passes `--skip-first-run`. To see first
run by hand, launch the built App binary directly with a disposable data root,
inside the screen lock (omit `--skip-first-run`):

```sh
first_run_root=$(mktemp -d /tmp/open-first-run.XXXXXX)
OPEN_USER_DATA="$first_run_root" \
  /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  build/Debug/Open.app/Contents/MacOS/Open --user-data-dir="$first_run_root" --arc-dir=/path/to/synthetic-arc
```

Use a synthetic source folder for this check. Quit the App before removing
the temporary root.

## Profile context reads

`engine-contexts` returns the sorted identifiers of live engine contexts,
including Default. It works after the last standard window closes.
`focusedBrowser` reads, extension/menu scans, and Settings shortcut-conflict
reads do not load a Profile. A real focus change can attach a window Browser
only when that Profile context is already loaded.

Automation extension, popup, permission, script, filter and download commands
use existing Browsers by default. Pass `create: true` only when a test intends
an extension or site interaction to load the focused Profile. Unloaded read
lists are empty (`extensions.loaded` is false); mutations that need a Browser
return a not-loaded error. Notification reads likewise use an existing context.
A pending Little Open window never borrows a standard window's Browser.

`settings-adblock-engine` reads the applied ad-block configuration without
opening Settings, a store, or a native context. `profiles` contains the store's
`storeReady` (`AdBlockStore.isProfileOpen`), enabled state and excluded domains,
plus each existing regular and OTR context's
`adBlockEnabled`, `listDirectorySet`, `listDirectoryMatchesProfile`,
`excludedDomains`, `adBlockStatus`, and existing pages' native `blockedCount`
and `identifier`. Directory checks are booleans; this query
never returns paths or page URLs. Excluded domains are available only through
automation; copyable debug info contains their count instead.

`settings-adblock` uses the real Settings actions. It accepts `enabled`, or
`host` with `excluded`. `list` with `listEnabled` awaits the real Settings list
action; `resetLists: true` awaits Reset. The response includes list IDs and
enabled states. `copyDebug: true` exercises Copy Debug Info while restoring
the clipboard before returning `copiedDebugInfo`. With native support, these
actions configure the production engine through the App adapter. The real
request flow uses no support override.

The real ad-block flow also checks the bundled resource pin and the active
generation's `_resources` entry. It serves a synthetic redirect rule through
the real downloader, verifies its stub with server and native-count witnesses,
then relaunches from DAT and repeats the request. With all lists off, the
verified generation has no engine or loaded resources and requests reach the
server. Enabling one list advances the generation and restores blocking.

For a placeholder engine, `OEBrowserContext.adBlockSupported` is false, so the
store's engine callback stays nil and launch opens no Profile in the store or
starts its update schedule. No requests are blocked in that build.
Command-service Settings initialization also leaves the store unattached when
the engine is unsupported; showing Settings attaches it on demand.
Opening Settings → Advanced still opens the selected Profile (`ready: true`).
The placeholder row checks this after first paint and a 5 s observation.
Settings reports that blocking is not active. The query also returns
`nativeSupported`, `adapterSupported`, and `bindingInstalled`. Automation builds
in Debug alone accept `OPEN_ADBLOCK_AUTOMATION_FORCE_SUPPORTED=1` to exercise the adapter
against the placeholder. This does not change the engine's support property and
has no effect in any Release build.
Run these flows with `OPEN_E2E_EXTENSIONS_UI_SCOPE=adblock
tools/e2e/engine_e2e.py --only extensions-ui` under the on-screen lock.

The real-App `extensions-ui` suite includes `P10_*` rows for empty-Space focus,
Settings/read laziness, two-window Profile actions, key-window menus and
shortcuts, Work popups/management, context reuse, Little Open, unloaded
Profile deletion and five-second quit cleanup. `OPEN_E2E_EXTENSIONS_UI_SCOPE=profiles`
selects these rows alone. `profiles-memory` selects five fresh two-Profile
launches and the existing OS idle CPU sampler; see [the receipt](profiles-memory.md).
Both modes reset and restore their shared defaults keys in `finally`.

## Protocol

Automation builds can run the Cocoa setter preflight without creating native
windows or starting Chromium. Set `OPEN_AUTOMATION_SCRIPTING_PREFLIGHT` to an
absolute JSON receipt path and launch the built App with an isolated
`--user-data-dir`. The App sends actual Apple events to itself, records setter
round trips/errors and `nativeWindows: 0`, then exits. This launch still takes
the on-screen lock. See [scripting](scripting.md#little-open-tab-references-2026-11-07).

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

`onboarding action=state` reports `active`, `moduleActive`, `screen`, intro
`phase` (`introAnimation`, `sellIntro`, `sellCompleted`), elapsed time,
Reduce Motion, scheduled audio/animation host times, sound decision/events,
player lifetime flags, opt-in frame stats, and resident deltas at 3 s and
after hand-off. `action=skip-intro` completes the visual tracks;
`action=get-started` uses the native button action and refuses before ready.
`action=replay-intro` overlays a running browser without writing data.
Unknown actions/arguments are refused. The dim child window is reported
only inside `onboarding` state; window lists and PNG snapshots exclude it.

Launch options: `--intro-sound=off|silent`; automation-only
`--intro-sound=fail-device`, `--reduce-motion`, `--measure-intro-frames`.
`--replay-onboarding` requires an explicit `--user-data-dir` under the OS
temporary directory or `/tmp`; the default root is refused before preparation.
Debug Help ▸ Troubleshooting contains Replay Intro. Automated runs must use
`--intro-sound=silent` (real player, volume zero) or `off` (no player).

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --style chrome --only onboarding
```

The suite uses a synthetic Arc-shaped source and disposable Open roots,
restores preference keys in `finally`, checks cleanup, and records a negative
proof for each gate using contrasting real App states. Frame statistics
include p50/p95/max, drops and load1. The strict high-refresh row is INFO
unless it runs on the M5 at load1 ≤12 and a display at 120 Hz or faster.
`OPEN_ONBOARDING_FORCE_EARLY_FAILURE=1` makes the suite fail while the intro
and dim are visible, to verify its failure cleanup. Check the shared priority
flag before acquiring the screen lock, as for the other native suites.
`tools/e2e/onboarding_launch.py --main-app PATH --out FILE` measures five
interleaved main/branch returning launches on a real saved root, with no skip
switch. Run it under quiet then screen locks after building both Apps. It
requires load1 ≤12, confirmed first frames, and every shared numeric launch
mark's branch median within 5 ms of main.

`tools/e2e/onboarding_frames.py --out FILE` interleaves three screen/normal
blend pairs on one already-built Debug App. Use quiet then screen locks at
load1 ≤12. It records p50/p95/max/drops and loads, asserts the real layer
filters and muted player state, and requires an absolute median p95 delta
below 0.5 ms with no extra screen drops. `OPEN_INTRO_NORMAL_BLEND=1` disables
the two filters only in automation builds for this comparison.

`first-run` returns `{active, step, completed}` even when there is no browser
window. Optional `action` drives the same view-model methods as the buttons:
`import`, `fresh`, `continue`, `notnow`, `back`, `finish`, `retry`, or
`choose-dir` with `directory=PATH`. `select` sets optional `spaces`, `archive`,
`history`, and `secrets` checkbox booleans on Import. Capability OFF still excludes passwords from the plan. `retry` on a save-error Report retries
the pending model's save. Directory strings are limited to 4096 UTF-8 bytes;
action names to 32. There is no action that changes the system default browser.

For native evidence, `focus` grants input focus to this instance's first-run
window. `inspect` reads its rendered text and top-left text frames using
Vision on a snapshot of that window only. OCR runs on a utility worker and retries only `TextRecognition.CRImageReaderError` code 1, once after 250 ms. `ocrRetries` records 0 or 1; the suite keeps its bounded 180-second timeout and all copy/geometry assertions. State includes its native frame
size, key flag, and traffic-light frames. `snapshot` prefers the first-run
panel while it exists. `OPEN_AUTOMATION_IMPORT_DELAY_MS` (automation builds
only, at most 5000 ms) holds the real progress view for animation captures.
`OPEN_AUTOMATION_PROBE_DELAY_MS` (the same limit) delays probe work so the suite
can close and reopen Welcome before counting finishes. Reopen restarts a
cancelled probe when counts have not landed.

State also includes `importInProgress`, `historyInProgress`, `historyProcessed`, and the main-thread `importAllMilliseconds`. The landing gate clears `importInProgress` before History starts. Progress includes `phase`, `progress`, and `browserHasLanded`. While a Settings import runs,
`settingsStep` reports `Importing`. The same command also drives the visible Settings sheet after first run:
`settings-import` with `directory=PATH`, `settings-select` with `history=true` and optional `historyOnly=true`, `settings-next`, `settings-run`,
and `settings-done`. State then includes `settingsStep`, `settingsOutcome`,
and `settingsError`. These actions use the real cached wizard and shared App
runner. `lastOutcome` and `lastFailures` remain readable after the first-run window closes. History streams through the existing Profile stores; passwords/cookies stay disabled. `OPEN_AUTOMATION_HISTORY_DELAY_MS` (automation builds only, at most 10000 ms per batch) pauses after the reader yields a real batch, before its transaction, so the suite can verify browsing while imported visits are still absent.

`import-extensions` reads the report's candidate rows, selection, per-row
status, queue state, and final counts. It omits manifest and Profile names.
`action=toggle row=ROW on=BOOL` changes an unprocessed checkbox;
`action=install` uses the report's Install Extensions action and returns while
the serial queue waits for normal `ext-prompt` consent. `action=registries`
reads installed IDs by Open Profile for synthetic isolation checks.
`action=fixtures files='{"<candidate-id>":"<signed-local-crx>"}'` supplies at
most 4,096 automation-only ID/file mappings (32 a–p characters per ID and
4,096 UTF-8 bytes per path). Production has no fixture path.
`action=inspect` scrolls and reads pixels from the report window; it is
available only after synthetic fixture mappings are configured. Use it only
with synthetic data. `OPEN_E2E_IMPORT_EXT_ONLY=1` runs this block alone inside
`firstrun`. `OPEN_E2E_IMPORT_EXT_NEGATIVE=detection` and `queue` deliberately
change fixture ownership/classification and real actions, so the matching EI
gates must FAIL; clear both variables for normal acceptance.
The synthetic second Profile uses `custom._0.directoryBasename = Profile 2`.
`EI_default_role_mapping` reimports into a live Default with a different ID;
`EI_default_role_target` checks its actual manager and the other Profile.
The fixture mapping may name a missing file to verify App initiation failure.
Once a local install starts, no App timeout completes it or cancels its sheet.
`EI_failure_reported_engine` stays BLOCKED until the engine supplies completion
for damaged signatures. `OPEN_E2E_IMPORT_EXT_NETWORK=1` adds one INFO Web Store
receipt (no fixture mapping), observed for at most two minutes; no answer leaves
the queue pending. `OPEN_E2E_IMPORT_EXT_NEGATIVE=detection` and `queue` apply
real source/action faults to qualify the EI gates; normal runs restore them.

Run the synthetic first-run flow with:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --style chrome --only firstrun
```

The suite restores shared defaults in `finally`, checks owned-process/window
cleanup, and writes uncommitted receipts and native PNGs under
`docs/engine-spike/`. Its five first-content timing samples include loads;
loaded Debug numbers are upper bounds, not idle Release budget acceptance.

| Command | Args | Result |
|---|---|---|
| `ping` | — | pid, Chromium and CEF versions, engine root (`Profiles/`) and data root |
| `applescript` | `body` (at most 1,048,576 UTF-8 bytes); optional `unavailable` (`model`, `engine`, `window`, `little`) for readiness fixtures | Automation-build TCC fallback: in-process `NSAppleScript` compiles with this bundle's terms and sends real Apple events to current application. Returns `{number,message,text}`. The optional fixture temporarily removes a provider and restores it after the script. This changes no macOS consent. See `docs/scripting.md` for external-sender limits. |
| `tabs` | optional `sidebar:true` | Plain response is an array; `sidebar:true` adds `{tabs,rows,folders,selectedNode}` native row/state readback. Sidebar tabs of the focused Space in row order: id, title, url, section (`favorites`/`pinned`/`today`), selected, visible, loaded, loading, audible, crashed, favicon, and `page` (engine state, below) when loaded |
| `tab-state` | `tab` | Model/live state of one tab, including an inactive Space's tab |
| `tab-strip` | — | Actual engine strips: all-Spaces model IDs, content IDs, active model tab, membership |
| `frame-save-counters` | — | Actual snapshot captures, dirty schedules, factory tree changes and mirror syncs |
| `space-profile` | `space`, `profile` name | Production sidebar profile assignment intent; closes old Space hosts |
| `peek-open`, `peek-expand`, `peek-close`, `peek-state` | `tab`, `url` for open | Production Peek entry, promotion, dismissal and host identity |
| `pages` | — | Every live page: identifier, kind (`tab`, `popup`, `extensionPopup`, `unowned`), url, title, style (`alloy`/`chrome`), context (profile), browser id and index (the `OEBrowser` tab strip), hidden, crash state |
| `credentials` | optional `profile`: UUID, name, or data directory | Counts only: `logins`, `blockedSites`, local `cards` and `addresses`, `cookies`, saving preferences, `canEnable*`, `supportsSecretsImport`, and `usesMockKeychain`. Uses the existing lazy profile-context factory; no credential values. |
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
| `engine-sleep` | `tab`, `op` (`state`, `hide`, `show`, `freeze`, `unfreeze`, `discard`, `capture`) | Test hook for the engine tab-sleep API (docs/engine-api.md, "Tab sleeping"): runs one call on the page and returns `ok` (freeze/unfreeze/discard result), `frozen`, `discarded`, `unloadHandlers`, `chromeTabId`, `identifier`, `live`; `capture` adds `history` (entry count, current index, page state, OPNH bytes, title, URLs, `roundTrip` through `OENavigationHistory(container:)`). It does not change the model's sleep phase |
| `devtools` | `tab`, `method`, `params` | Raw DevTools protocol command; events arrive in `events` |
| `click` | `tab`, `selector` or `text` | Click an element with DevTools input events (a real user gesture inside the page) |
| `rightclick` | `tab`, `x`, `y` | Right click in the page |
| `type` | `tab`, `text` | Insert text in the focused page field |
| `key` | `key`, `modifiers`, `route`, `window` | Key press inside Open. `route: "app"` (default) goes through `NSApplication.sendEvent`, like real typing; `route: "window"` goes straight to the window's first responder (the page view), which tests the engine's pre-key hook. `window: "popup"` targets the action popup's panel instead. `text` sends plain characters to the first responder. |
| `mouse` | `window`, `x`, `y`; `action=move`, `action=hover`, `action=down`, `action=drag`, `action=up`, or `action=click` with `clickCount` and `modifiers` (`option`, `command`, `shift`, `control`); or `from` / `to` point pairs | Own-window click, queued pointer motion, or native resize drag; system cursor stays unchanged. Down/drag/up and the from/to drag send real NSEvents through `OEApplication.sendEvent`; separate actions let a check inspect or snapshot a held drag. The resize handle uses AppKit mouse callbacks, so the socket stays responsive. A double-click uses `clickCount=2` (the suite also sends the first click). `click` runs the window's layout pass first (as real input follows a display cycle) and queues the mouse-up before sending the mouse-down, so controls that track the mouse (the window buttons) finish. Motion events carry a tag; from the first one on, pointer-driven window logic (the sidebar hover reveal) ignores the hardware pointer, so someone using the Mac cannot disturb a check. `move` and `click` also set the automation pointer at once (`BrowserWindowController.automationPointer`), and `hover` sets it after it has delivered enter, move, and exit (it rebuilds every tracking area first, and those rebuilds must still see the old point). A `move` delivers no enter or exit, so it clears `hover`'s record of entered owners and the next `hover` enters the owners under its point again; state that reads where the pointer is, not an event (the window buttons' hover after a full-screen exit, a restore, or a show), reads it instead of the hardware pointer. `hover` also delivers enter, move, and exit to the owners of the tracking areas under the point, title bar included (tracking areas follow the hardware pointer), and returns the owners it found. macOS's own window-button glyphs and tiling menu follow only the hardware pointer |
| `focus` | `tab` | Give the page keyboard focus |
| `find` / `zoom` / `mute` | `tab`, … | Find in page, zoom level, mute |
| `find-state` | — | Read-only lazy Find state: `created`, focused tab, and one row per used pane (`visible`, `query`, `countText`, `active`, `total`, `notFound`, native field focus/selection, placeholder, navigation/separator visibility, bar/pane/page-viewport frames and visible chrome/extension-strip frames in window coordinates with a bottom-left origin; native close-button frame and hit-test owner). Also request/result/layout counters, pending work, and presentation phases (layout, draw, layer flush, field focus). The commit time starts at the native key event timestamp; it measures the flushed layer, not physical display scanout. Reading state creates no Find controller. |
| `find-idle` | `action=begin`, `watch`, `reset`, `read`, `invalidate`, `end` | Harness-only bridge to the already-injected S8 idle observer. Reports draw/layout/display, invalidation, scheduling, timer, and display-link counters. `invalidate` marks the real Find view for layout as an observer canary. No observer library is loaded or attached by this command. Unknown actions fail. |
| `print-pdf` | `tab`, `path` | Print to a PDF file |
| `devtools-open`, `fullscreen-exit` | `tab` | — |
| `extensions` | — | Installed extensions and the window's toolbar actions, with `duplicatesDropped` from the App's first-occurrence normalization. Action fields match `actions` below. |
| `popup` | `extension` | Run the action like a click on its button; returns the popup page |
| `popup-close` | — | Close the open popup |
| `actions` | — | The focused window's toolbar actions from Chrome's model (fork patch P2): `ready`, and per action id, name, title, tooltip, accessible name, badge and colors, enabled, has popup, pinned and pinned index, wants to run, site access, showing popup, `live` (from the live model, else the profile's list), and the toolbar image and plain icon (PNG byte count, hash, point width, `pixels`: each representation's pixel size, and `object`: the image object's identity) |
| `ext-pin` | `extension`, `pinned` (default `true`), optional `index` | Pin or unpin an action; optionally move it through the guarded App host. |
| `ext-move` | `extension`, `index`, optional `engine` | Move only a currently pinned action. Negative automation indices return an error. Clamp to the normalized pinned list and skip a no-op, as a native drag does. `engine=true` directly probes the engine's invalid-index refusal instead. |
| `ext-prompt` | `answer` (`accept`/`cancel`), `hold`, `handler`, `clear`, `twice` | Pending consent: type, extension/name, Open title/buttons (§3.11), `chromiumTitle`/`chromiumButtons`, permissions/details/lines, retained files/devices and weak page/browser ids. Holds by default; `hold=false` releases without answering. `handler=false` preserves Chromium's dialogs. `clear` cancels the queue; `twice` checks duplicate-answer safety. Also returns registry events. |
| `save-prompt` | One of `mock: {kind, host}`, `answer: save\|never\|dismiss`, `state: true`, `withdraw: true` | Automation builds only. `mock` enqueues synthetic metadata for the focused page in the front browser window. Kinds: `password`, `passwordUpdate` (alias `update`), `card`, `address`, `addressUpdate`. State and events use the canonical names. Host limit: 4096 UTF-8 bytes, no control characters; unknown fields/kinds are refused. `answer` clicks the visible sheet's real NSButton; `withdraw` releases it unanswered. State: `visible`, `kind`, `title`, `body`, left-to-right `buttons`, `defaultButton`, `cancelButton`, native sheet `window`, `queueLength` (waiting requests, excludes visible sheet). The `key` command accepts this window number and `.` for Cmd-.. `events` drains `savePrompt` events `{kind, displayHost, answer}` with answer `save`, `never`, `dismiss`, or `ignored` on unanswered release, even after the final window closes. No credentials or storage are involved. |
| `ext-manage` | `extension`, `action` (`enable`, `disable`, `uninstall`, `reload`, `install-webstore`, `install-crx`), `path` | Live per-profile management. Remove always prompts. Web Store completion is recorded in `ext-prompt.events`, leaving the socket free to answer consent. Local CRX is guarded by `--open-automation` and uses the real installer/prompt. |
| `ext-commands` | optional `surface: little` | `{ready, context, commands}`. Each command has extension, name, summary, Cocoa key equivalent/modifier flags, global and action-command flags, normalized shortcut, `dropped` and conflicting `openCommandID`. Uppercase letters encode Shift in Cocoa's pair. |
| `ext-shortcuts` | `action`: `state` (default), `menu` (+ optional `select` title), `record` (+ `id`, one ASCII `key`, `modifiers`), `reset` (+ `id`), `reset-all`, `close` | X-27 real Settings pane. First show `settings-pane pane=shortcuts`. Finds the visible native More shortcut actions menu and performs its actual enabled item; records/resets through `ShortcutsViewModel` → `KeyBindingStore` save → App callback. Returns rendered native `notices`, menu, status, binding count, real command title and window number. `close` closes that window. Suite must restore the binding file and shared defaults in `finally`. |
| `ext-windows` | optional `preference: true`, optional `value` (null removes) | Lists native extension popup controllers with browser/page/window ids, Chrome window id, frame, title, visibility, style, autosave name, toolbar flag and page/content-view identity. Preference mode reads/writes the single `NSWindow Frame ExtensionPopupWindow` entry; reset/restore it in `finally`. |
| `ext-omnibox` | optional `surface: little`, `extension`, `op`: `start`, `cancel`, `default`, `input` (+ `text`), `reply` | Calls the public engine omnibox path. `input` returns whether Chromium accepted it; `reply` reports the latest completion count. `default` reports presence, title/content UTF-16 lengths and match-range count. No page text is returned. |
| `ext-run-command` | `extension`, `name`, optional `surface: little` | `executeExtensionCommand`: named event with active tab, or action with source command; unknown/inactive commands return false. |
| `ext-strip` | `surface` (`url`, `pane`, `toolbar`, `little`) | Visible action ids in order, button and more frames in Cocoa window coordinates, visibility, layout/redraw counts and image conversions. `strips` includes unfocused panes. A missing App presenter reports `blocked`. |
| `ext-hover` | `inside` (default true) | Tagged mouse-moved and tracking events inside Open, over or away from the sidebar. Does not move the hardware pointer. |
| `ext-click` | `extension` (or `more`), `surface`, `button` (`left` or `right`), optional `select` title | Native in-process events to the visible slot; right-click, a disabled left-click, or More returns the rendered menu. `select` performs its actual enabled item. Hidden slots refuse clicks. Little Open's More targets its own button/menu/browser. |
| `ext-ui-menu` | `kind: bar`, or `extension`; optional `select` title | Updates the real Extensions menu through `menuNeedsUpdate`, or builds the rendered action context menu. Selection executes the enabled native menu item. |
| `ext-popup-state` | optional `surface: little` | Shell panel open/visible/ready/key flags, panel/content/anchor frames, anchor kind, ready-to-visible timing and blur keep-open state. Little Open selects its own host. |
| `ext-redraw-measure` | optional `start: true`, optional `surface: little` | Starts a display-frame measurement on the host's real strips; a call without `start` stops it and returns per-action redraw/frame counts and `maxPerActionPerFrame`. Uses the host's actual draw counters, not a synthetic badge counter. |
| `ext-picker` | `keys` | Sends native keys to the presented SCC picker and returns `focusedID`; reports the exact missing App hook while SCC presentation is unavailable. |
| `ext-run` | `extension`, `source` (`toolbar` default, `menu`, `command`) | Run the action as the user would; returns whether it ran (a popup opens, or `chrome.action.onClicked` fires) |
| `ext-menu` | `extension`, `source` (`toolbar` default, `menu`), `select`, `keep`, `stale` | The action's context menu items (title, command, enabled, checked, separator, submenu); with `select`, run the item with that title and return `items` and `ran`. `keep` keeps this menu open (not cancelled); `select` with `stale` then runs the item on that kept menu and cancels the new one |
| `ext-popup` | — | The open popup: `open`, its page, its extension, its source (`user`, `command`, `api`), and `staysOpenOnBlur` |
| `activate` | — | Activate Open and make the focused window key (Chrome's "active window"), even with a popup panel in front; returns `key` |
| `windows` | — | Open's windows: number, class, frame, key, first responder |
| `shell-windows` | — | Standard controller IDs and native window numbers |
| `window-state` | `id` (optional: another standard window, not made key) | Frame, sidebar mode/width/reveal, panel frame, traffic-light centers, frames, and visibility, the title bar frame, the hardware pointer in window coordinates (read only), hover-reveal state (`reveal`: phase, show/hide counts, last dwell, zone, the card's frame and on-screen offset), chrome geometry (`chrome`: URL field, favorites section, Space header band, title frame and baseline, hover states), window buttons (`trafficLightsDimmed`, `trafficLightsHovered`, per button alpha and action, the window's AX button attributes `axWindowButtons` with role and subrole), the automation pointer (`automationPointer`, window coordinates, or null when it is in another window or never moved), `key`, `appActive`, `miniaturized`, `zoomed`, selection, shown page IDs, engine URL/active ID, native and HTML full-screen state, transition state and completed transition count. Runs the window's pending layout first |
| `window-interrupt` | `kind`: `key`, `sheet`, `end-sheet` | Own window only: order out the browser for native key loss, begin a small native sheet, or end that sheet. Used after tagged down/drag events without mouse-up to exercise resize cancellation. No system input. |
| `undo-state` | `clear` (optional bool) | Model undo generation, `canUndo`, and `canRedo`. `clear=true` clears this isolated App's undo stack before a gesture proof. Undo itself uses `sidebar-key` Cmd+Z (focuses the outline, then the App key path). |
| `window-focus` | `id`, `activate`, `readinessTimeout` | Make that own window key; optional own-app activation. Native readiness timeout: 0–5 seconds, default 5. |
| `window-motion` | `reduced` (optional bool), `sampleCard` (optional bool) | Motion tokens and actual animations read back from the sidebar, panel, card, shadow, and Space-pager layers when scheduled; retained after completion. Response and damping come from the scheduled spring's physical values; `mass`, `stiffness`, `physicalDamping`, and `settlingDuration` expose those values and the CA settling estimate. The scheduled `duration` must equal `settlingDuration`; response is not the animation lifetime (Space response 0.20 s, visibly settled ≈ 0.27 s in S2 §20.12). `scheduledDelay` is the scheduled begin time minus its explicit scheduling reference in the layer's clock. `cardCurve` evaluates `Motion.springProgress` in the app. `sampleCard` records the real visible card's presentation offset every 4 ms for 0.32 s; it is off by default. `reduced` overrides only this process, without changing macOS settings. `window-state` also reports the live/model widths, resize-active state, width-commit and gesture-notification counts, geometry changes, and `spaceSwitcherFrames` in root coordinates for native switcher clicks. |
| `appearance` | `name` (`light`, `dark`, or anything else for the system's) | Open's own appearance (`NSApp.appearance`); the system setting is untouched |
| `window-close` | — | Native close for the current standard window; model tabs stay |
| `window-reopen` | — | Real application reopen handler, including after the last window closes |
| `window-fullscreen` | `observeReadiness` (optional bool) | Native full-screen toggle; wait for completed transition count before testing the result. With `observeReadiness:true`, atomically returns the native input readiness predicate and its state after the toggle (`status:observed`), or `status:SKIP` with a reason if AppKit did not report an in-progress transition in that main-actor turn. |
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
| `policy` | `dialogs`, `prompt`, `permissions`, `contextMenu`, `fullscreen` | Answer JS dialogs (`accept`/`dismiss`/`hold`), permissions (`grant`/`deny`), record context menus (`record`: the event lists `items` and `commands` with ids, titles, submenus, and `openItems`, the titles of the menu Open would show, its own items included) or run one command (`run:<id>`, after the right click returns) or one of Open's own items by title (`run-open:<title>`), keep the window size on page fullscreen |
| `dialog` | `accept`, `text` | Complete a held dialog; when visible, click its real OK/Cancel button |
| `dialog-state` | — | Pending count, real sheet title/body/buttons, prompt text, suppression visibility, held/queued flags, and sheet window number |
| `dialog-button` | `accept`, `text`, `suppress` | Click the visible sheet's real OK/Cancel button, optionally edit its prompt and suppression checkbox |
| `permission-prompt` | optional `answer`: `allow`/`notnow` | State: visible, question, kinds, buttons, anchor frame in screen points, window, pending and completion counts. `presentation` is `popover` or `card`; `frame` gives the card rectangle in window coordinates. Pass a Little Open window number in `window` to inspect or answer its prompt. With an answer, call `performClick` on the real button |
| `permission-decisions` | — | Profile data hook: index `ready` and persisted non-ask origin/kind/state rows |
| `events` | optional Little Open `window` number | Drain that Little Open window's page log, or the front browser window's log otherwise: `change`, `load`, `loadError`, `open`, `dialog`, `dialogAnswer`, `permission`, `permissionAnswer`, `contextMenu`, `fullscreen`, `download`, `console`, `devtools`, `extensionPopup`, `tab-request` and `window-request` (P1 requests from Chromium, with `refused` when the shell said no). Also drain the shared `savePrompt` completion log, which remains available after the final browser window closes. |
| `script-add` / `script-remove` | `id`, `source`, `css`, `end`, `matches`, `allFrames`, `world` (`page` default or `open`) | Boost-style user scripts (through the OpenWeb `WebProfile` protocol) |
| `filter` / `filter-stats` | `block` (substrings) | Request filter (ad-block hook) and its counters |
| `permission` | `origin`, `kind`, `state` | Read or set a site permission |
| `download-dir` / `downloads` | `path` | Where downloads go; list downloads |
| `metrics` | `interval` | Chromium task manager rows and the physical footprint of every Open process |
| `timing` | — | Monotonic launch marks from kernel process start, presented-sidebar mark, renderer first contentful paint, and clock-mapping uncertainty |
| `startup` | — | Actual sidebar class, visible window count, page count and context count recorded before engine start |
| `host-counts` | — | Cumulative tab host creations, retained tab hosts, and engine web-content count |
| `sidebar-unload` | `tab` | Production sidebar unload intent without selecting the row |
| `translate` | `action`: `state` (default), `offer`, `translate`, `revert`, `never`, `choose` (+ `target`), `settings`, `dismiss`, `reset`, `detect` (+ `text`), `availability` (+ `source`, `target`) | Page translation of the focused tab (page-platform §8.3). `state`: session state (`idle`/`offered`/`translating`/`translated`/`failed` + `reason`), source/target language codes, host, backend (`apple`/`fixture`), batches applied, `pulls` (answers of the runtime's `nextBatch()`), fallback units, sticky host, probed/loaded document counters, the status button (`shown`, `title`, `frame`), the popover (`presented`, `title`, `buttons`, `error`, `frame`, `window`), recent toasts, `neverTranslateHosts`, and the undo action name. `offer` presses the real status button; `translate`/`revert`/`never`/`choose`/`settings` press the popover's real buttons and menu items (opening it through the status button first). `reset` runs Settings ▸ Advanced "Reset Translated-site Prompts". `detect` runs `PageLanguageDetector` on a text. `availability` asks Apple's `LanguageAvailability`. Launch with `OPEN_AUTOMATION_TRANSLATE_BACKEND=fixture` for the fixed French → English backend (automation builds only; no network, no language assets) |
| `save` | — | Write the snapshot now; returns its path |
| `quit` | — | Quit Open normally |

## Deferred Little Open Browser

`little-open-state` reports `browserID: null`, `content: 0`, and a non-visible
surface until the window's deferred Browser and page exist. `firstFrameRead`
records those absent objects at the first native frame. The later state exposes
the owned Browser, `browserCreationStartedAt` (system uptime), and its Chrome tab.
`browserCount` and `littleOpenBrowserCreations` distinguish live Browsers from
cumulative Little Open creation, including a Browser that immediately closes.

`little-open-action {action:"blank"}` follows the normal deferred path. For
the real-event race checks, add `then:"submit", text:"URL"` or `then:"close"`.
The automation hook runs native `OEApplication.sendEvent` typing/Return or close
before the queued creation. It returns `opened` and `after` state. Text is limited
to 8,192 UTF-8 bytes; 8,193 bytes fail. Submit requires nonempty text. The submit
hook waits for the real navigation intent before resuming creation. The close
hook continues through the production cancellation guard. Normal creation uses
neither hook. See [the deferred Browser report](little-open/deferred-browser.md).

## Window pixels

`snapshot` captures only Open's windows, from inside Open, so it needs no Screen Recording permission:

1. `CGWindowListCreateImageFromArray` with Open's window and its child windows (Chrome-style pages live in child windows). If that returns an empty image, AppKit draws the window's views instead.
2. The window server leaves out the layers that Chromium's GPU process draws into our window. So each visible page's DevTools `Page.captureScreenshot` goes into a temporary layer right above that page's view while the window server captures. Whatever AppKit draws over a page (the hover-reveal card and its shadow, Peek controls, toasts) then composites over real page pixels, as on screen. Pages that cannot get such a layer are pasted in at their frames.

`tools/e2e/engine_e2e.py` uses `snapshot` for the main window and `screencapture -l <Open's window number>` for panels and Chromium dialogs. `screencapture -l` captures that one window only.

## End-to-end suites

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Debug
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only shell                       # model, keyboard, split, persistence
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only window --config Release     # startup, lifecycle failures, real window, persistence, static comparison
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only window --window-chrome-only # focused §3.3 widths, motion, session-2 live pixels
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only sidebar                     # intents, correct live page, cache eviction, static comparison
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only peek                        # promotion identity, cleanup, model strip, live pane color
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only features --style alloy      # engine features
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only passwords --style chrome    # M-* save sheets (mock metadata only)
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only extensions --style alloy    # needs .re/ext/unpacked/*
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only extensions --style chrome
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only extensions-p3 --style chrome --config Release # local signed CRX3, no network dependency
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only tabstrip --style chrome     # fork patch P1: chrome.tabs sees Open's tabs
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only page                       # page-platform §8.3: capture C1–C7, then translation X1–X6
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only actions --style chrome      # fork patch P2: toolbar actions and popups
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only media --style chrome        # media-pip §8.4: mini players, auto-PiP, Now Playing, sleep feed
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only sleep --style chrome        # app-shell Step G: tab sleep, memory-fork §11 F0–F5
OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 tools/build.sh Release
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only measure --config Release    # launch, memory, idle CPU
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only relaunch --config Release   # N same-profile relaunches (OPEN_E2E_RELAUNCH_COUNT, default 20)
```

The `relaunch` suite (section 8 item 14) builds one profile with three local file tabs, then relaunches it `OPEN_E2E_RELAUNCH_COUNT` times (default 20). Each launch must reach automation, restore the same tabs, load only the selected tab, quit with no owned process left, and write no `No zone found` allocator FATAL to its launch log. The suite also fails on any new `Open*`/`cefsimple*` report in `~/Library/Logs/DiagnosticReports`. It is the regression check for the PartitionAlloc launch-zone race (`docs/engine-fork.md`, "PartitionAlloc and the launch race").

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
| `commandbar-state` | Read actual bar mode, text, rows, selection, and monotonic first-result timings. Also `footer` (the (i) privacy footer shows), `hidden`, `panelOpacity` (the panel's presentation opacity), `animationKeys` (bar layers, the self-blinking caret excluded) and `allAnimationKeys`, `panelFrame` (window points, top-left origin), `fieldWidth`, `allowsRemote`. Does not create the bar. |
| `settings-pane` | `pane`: a Settings pane id (`general`, `profiles`, `links`, `shortcuts`, `appIcon`, `advanced`). Shows Settings on that pane through the App's presenter (a fixture step before a check that must switch panes). |
| `commandbar-press` | `control`: `info`, `dismiss`, `searchSettings`, or `privacyLink`. Performs that bar control's AX press action (the control's real action). Returns `pressed` and the new `commandbar-state`. |
| `menu-state`, `menu-perform id=…` | Read native menu validation (including `key`, raw `modifierMask`, nil-target/action and hidden state), or invoke an enabled native menu item. |
| `key observeCommands=true` | Scope a dispatch trace to this real in-process key event. Returns the actual `charactersIgnoringModifiers`, window command entries in `commands`, and native menu dispatches in `menuActions`. It changes no route or target and installs no observer at rest. |
| `menu-key-render path=…` | Copy the real Shift+letter items into an AppKit menu, capture this App's native popup, then cancel it without an action. Run under the on-screen lock. |
| `editor-open kind=create`, `creation-state` | Open or focus the New Space sidebar page; page fullscreen exits before presentation. Read its draft, Profile, native Name focus, actual visibility, theme preview and undo state. The Profile popup stays visible during inline creation; selecting an existing Profile preserves the draft. `themeKey`, `windowActive` and `backgroundActive` report the draft panel and its owning window material. When the form is closed, state includes `modelUndoName` and `modelRedoName` for the actual model step. |
| `editor-act`, `editor-close` | Use the creation form's controls (`click control=theme/icon/create/cancel`, `profile name=…`) or a draft theme preset (`preset index=0…8`). Close the theme editor first, else cancel creation. |
| `reload-keybindings` | Load the actual `State/keybindings.json`, validate conflicts, and rebuild menus and the global registration. |
| `sidebar-duplicate id=…`, `sidebar-tree` | Send the production SidebarDelegate intent; read fresh subtree IDs and load flags. |
| `settings-state`, `settings-toggle name=hotkey\|external` | Read the shared real presenters, including pane-local `generalError`/`advancedStatus`; commit the live Links settings model. |
| `settings-profile` | Read the actual Profiles create-sheet state: `creating`, attached native `sheet` window number, `pane`, selected `spaces`, and `error`. `cancel=true` dismisses through the existing sheet state. |
| `settings-profile-page` | `profile`: an existing Profile ID, `page`: `passwords`, `paymentMethods`, `privacy`, or `notifications`. Selects that Profile in the real Profiles view model and runs its row action (`openProfileSubpage`). Keeps the Settings adapter's Space choice and no-Space fallback. |
| `settings-icon` | Read `selected`, `applied`, pane `error`, `matchesApplication` (exact pixel equality in the actual NSApp icon's output color space and component format, including float16; AppKit copies NSImage), `imageObject` (cache identity), bitmap `pixels`, and `restoreStartedMs`/`restoreElapsedMs` (total main work), `restorePreparationMs` (main preparation), `restoreSetterMs` (AppKit setter), `restoreDecodeMs` (worker decode/TIFF preparation). Restore uses one low-priority turn at least about 1 s after paint. `select=<AppIconOption ID>` uses the real picker action. Default resets `NSApp.applicationIconImage` to nil and does no restore work. |
| `settings-custom-engine template=…` | Save a custom engine through the live Profiles settings model. |
| `library-restore id=…`, `library-history-open url=…` | Exercise the live Library restore transaction or its profile-scoped history action. |
| `history-state` | Optional `profile` UUID and `query`. Drains accepted history writes, then returns the Profile store path, search rows, commit-to-enqueue samples (ms, automation only, bounded at 4,096) and writer operation count. Store opens/searches stay on the HistoryStore actor. |
| `history-clear` | Optional `profile` UUID and `range` (`Last hour`, `Last 24 hours`, `Last 7 days`, `All time`, default All time). Calls the real Settings History-only clear-data adapter and returns `error`. |
| `library-history-state` | Returns the current Library Profile and displayed History rows without reloading. Optional `profile` plus `selectProfile=true` changes the History Profile and reloads it explicitly. |
| `library-history-delete` | `urls` selects row URLs, or `all=true` selects all-time clearing. Calls the Library's confirmed delete/clear handler for its selected Profile. |
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
reports those native flags and screen bounds, plus key-window object identity,
active-Space membership, key eligibility, sheets, and child windows. Native input
also waits for the requested browser window's full-screen transition to end.
The window suite samples the negative predicate inside the App with
`window-fullscreen observeReadiness=true`. It does not require the transition
to outlast later Python RPCs. If that request cannot observe an in-progress
transition, only the negative sample is SKIP with a reason; the positive
readiness wait still runs.
`ensure_key` retries only `window-focus: key focus not ready:` until its own
15-second deadline. Each native wait uses at most the remaining deadline budget.
It logs each attempt's predicates and load average, then returns the last state
on expiry so the caller's assertion decides the result. Foreground interruption
and other errors still abort. This is a readiness wait, not a retry of the
caller's behavior check. Tests poll the resulting UI state
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
Use `--focus-retry-delay-seconds 180` when a run requires three-minute spacing
between interrupted attempts. The option accepts 0–600 seconds and defaults to
0 for existing invocations; the three-attempt limit stays unchanged.

A lead-requested display hold is enforced by `.re/hold-on-screen`. While it exists,
the harness refuses new Open launches. The file must be removed only after an
explicit resume instruction; an elapsed estimate is not permission. Offscreen
renderers and compilation do not require removing the file.


### Step C review: focus and shutdown observations

Automation responses include `observationStart` (process monotonic uptime).
`focus-state` reports the current responder owner, Find text/visibility, its
window-coordinate `findFrame` and native `findCancelFrame`, sheet
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

## Media (media-pip Step 6)

Commands in `App/Automation/AutomationMedia.swift`. `tab` is a tab UUID.

| Command | Args | Result |
|---|---|---|
| `media` | `tab` | The page's media session as the App sees it (`playback`, `controllable`, `hasVideo`, `hasAudio`, `largestVideoArea`, `pictureInPicture`, `pictureInPictureDisabled`, `actions`, `title`/`artist`/`album`, `duration`, `position`), `audible`, `muted` (engine), `modelMuted`, `capturing`, the store `source`, and the last auto-PiP `decision` (value and system-uptime time). |
| `media-action` | `tab`, `action` (`play`, `pause`, `next`, `previous`, `toggle-mute`, `close`, `back-to-tab`, `pip`, `seek` + `value`, `volume` + `value`, `exit-pip` [+ `pause`]); or `action` `mute-all` / `unmute-all` without `tab` | Runs the same `MediaIntent` (or App command) path as the mini player and the command bar. |
| `mini-players` | `window` (window id, default front) | `cards` in order (tab, kind, playback, pip, expanded, level, frame and shown buttons with frames in window coordinates, top-left origin; `drawerOpen`, `height`, the shown volume `slider` value such as `"25%"` or null, the source's `volume`, `microphoneOn`, `cameraOn`), `expanded`, `stackHeight`, `displayed`, `pendingCollapse`, `animations`. |
| `media-click` | `window`, `tab`, `target` (`title`, `play`, `next`, `previous`, `volume`, `pip`, `close`, `favicon`, `microphone`, `camera`, and the volume drawer's `volumeLow`, `volumeHigh`, `slider`), `fraction` (slider only, 0…1 of the knob's travel, default 0.5) | Clicks the real card control through `mouse` events built inside Open. Title-row and volume targets hover the card first (`mouse` `hover`, coming from a point off the card, so an earlier hover that left the stack "entered" cannot swallow the enter) and wait for the expanded stack. `slider` sends a press and a release at `fraction` and returns the slider's new `value`. |
| `pip` | — | Session `state` (`idle`, `requesting`, `active`, `minimized`, `closed` + `reason`), `tab`, `automatic`, `snoozed`, `requests`, `requestedAt`/`enteredAt` (system uptime), `now`, and the visible PiP windows (phase 1: Chromium's `NativeWidgetMacFramelessNSWindow`; phase 2: Open's own window), number, frame, level. With a Document PiP (EM-7): `documentWindow` (number, frame, level, visible, opener `tab`, panel `class`, `topBarHeight`, `pageSize`, `pageInWindow`, `requested` size, `valid`). |
| `capture-permission` | — | macOS camera and microphone authorization for this app (`camera`, `microphone`: `authorized`, `denied`, `restricted`, `notDetermined`). Reading it never prompts. Chromium asks macOS while a status is `notDetermined`, even with fake devices, so e2e `media_recording_card` runs only when both are `authorized` and is BLOCKED otherwise. |
| `pip-frame` | `path` (default: the temporary directory's `open-pip-frame.png`) | Phase 2: writes the engine's composited picture of Open's PiP video view as a PNG and returns `path` and `bytes`. Not a screen capture: the window server leaves out GPU-process layers on macOS 26. Fails with `no Open PiP window` or `no frame` (2 s timeout). |
| `pip-action` | `action` (`close`, `back-to-tab`; phase 2 also `minimize`, `menu` [+ `item`]) | Phase 1: the session paths that Chromium's own window's Close and Back to Tab end in. Phase 2: Open's own window, through its real controls' paths; `menu` without `item` lists the window menu (`✓` marks a checked item). With a Document PiP open and no video PiP, `close` closes its panel (the × path). |
| `now-playing` | — | `MPNowPlayingInfoCenter` title, artist, rate, elapsed, `playbackState`, and whether the remote play, pause, toggle, next and previous commands are enabled (read in-process; Chromium's system media controls own them). |
| `sleep-visibility` | — | The media sleep feed (§4.10): `pictureInPicture`, `mediaControls`, the resulting `visible` set and window states, from `MediaCoordinator.visibility`. |

The App accepts `--pip-site-rules=FILE` in Debug and automation builds; the `media` suite writes a rules file that disallows `blocked.localhost` and gives `inaudible.localhost` `activatesWhenInaudible` (Chromium maps `*.localhost` to the loopback server).

Each `mini-players` card also has `timing`: `event` (`leave` or `engine`), `handledAt` / `insertedAt` (system uptime seconds), and `handledTurn` / `insertedTurn`. The App records handling before publishing a leave and insertion immediately after `MediaControlsView` adds the card. Turns count main-run-loop `afterWaiting` observations; insertion within zero or one turn passes the speed gate. The observer runs only with an explicit automation socket or the e2e harness's `OPEN_E2E_OWNER_PID`, schedules no work and never wakes the run loop. Missing endpoints are null; absent evidence is an empty object. These fields measure insertion, not animation completion or the automation polling round trip. For Auto-PiP, `media.decision.at` records the start of the coordinator's leave handling, before policy evaluation or the PiP request; `pip.enteredAt - media.decision.at` is the full leave-to-enter interval.

## Notifications (page-platform Step 7)

Commands in `App/Automation/AutomationNotifications.swift`.

| Command | Args | Result |
|---|---|---|
| `notifications` | — | `authorization` (macOS status for Open.app: `notDetermined`, `denied`, `authorized`, `provisional`, `ephemeral`), `delivered` (`UNUserNotificationCenter.getDeliveredNotifications` of Open.app: `id`, `title`, `subtitle`, `body`, `thread`; banners only, because alerts come from the Alerts helper's own bundle), and `engine` (the engine list; `BLOCKED` until EP-7, fork patch 0504). |
| `notification-click` | `id` | EP-7 simulated click. Returns `BLOCKED` until EP-7. |
| `notification-authorization` | — | `status` (read now), `denied`, `requests` (one entry per Allow: `requested`, `suppressed`, or `skipped:<status>`), `suppressed`, `settingsURL` (System Settings ▸ Notifications for Open). |
| `window-miniaturize` | — | Minimizes the front window, as its yellow button does. |

`OPEN_AUTOMATION_NOTIFICATION_AUTHORIZATION=record` (automation builds only): when the user allows a site's notifications and macOS has not been asked yet, the App logs `suppressed` instead of showing the macOS prompt. The `page` suite sets it, so a normal run needs no person. For U-N1 (page-platform §8.4), run the suite once with `OPEN_E2E_NOTIFICATION_PROMPT=1` and click Allow in the macOS prompt:

```sh
OPEN_E2E_NOTIFICATION_PROMPT=1 /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only page --style chrome
```

## Tab sleep (app-shell Step G)

Commands in `App/Automation/AutomationSleep.swift`, automation builds only. `tab` is a tab UUID. The clock offset, the explicit pass and the low-power override do not exist in a user build.

| Command | Args | Result |
|---|---|---|
| `sleep-state` | `tab` (optional) | `prepared`, `started` (T5), `scheduled` and `scheduledDelay` (the controller's next timer pass; false/null while parked), `nextPassDelay` (null: only an event can change a hidden tab), `passes`, `lowPowerMode`, `clockOffset`, the `visible` set and the media feed (`pictureInPicture`, `mediaControls`), `criticalCloses`, the last 200 controller `log` lines (`sleep-wake <kind> <id> ms=`, `sleep-capture-failed`, …), `batteryToasts`, and per tab: `phase`, `content` (controller), `hosts` (pages in all windows), `discarded`, `freezeGate`/`discardGate` (first never-sleep gate, or null), `hiddenAt`, `sleptAt`, `retryAfter`, and the live inputs (`audible`, `capturing`, `devTools`, `notificationsAllowed`, `downloading`, `lastFormInteractionAt`). |
| `sleep-now` | `tab` | OpenSleep's debug sleep (freeze + discard now, every gate honored). Returns `refusedBy` (the gate, or null) and the tab's state after. |
| `sleep-tick` | `pressure` (optional: `warning`, `critical`) | Waits for a running pass, then runs one controller pass (or a memory-pressure pass) now. Returns `sleep-state`. |
| `sleep-clock` | `advance` (seconds, 0…604800) and/or `reset` | Moves the controller's clock (hide times, grace periods, delays). Returns `offset`. |
| `sleep-mode` | `mode` (`off`, `conservative`, `balanced`, `aggressive`; optional) | Writes the global Settings key through the actual Advanced setter (`off`→`never`, `balanced`→`automatic`) and reconciles every Profile. Returns the mode per Profile. |
| `sleep-power` | `lowPower` (`true`, `false`, or `null` to follow macOS) | Battery Saver override. Returns `lowPowerMode`, `override`, `system`, `toasts`, `lastToast` (front window). |
| `sleep-start` | — | Starts the controller as T5 does (for flows that never paint). |
| `sleep-store` | — | Every row of every Profile's `sleep.sqlite3`: `tab`, `url`, `title`, `entries`, `pageState`, `tag`, `file`. |

`permission` (kind 8, notifications) also refreshes `notificationsAllowed` on the Profile's pages. The suite's fixture server serves `Engine/fork/verification/fixtures` at `/` and `tools/e2e/fixtures/media` at `/media/`; `*.localhost` names give each page its own site (renderer), and `mail.google.localhost/mail/…` matches the built-in keep-alive table. With `--style chrome` the suite loads `tools/e2e/fixtures/tabs-probe` for the `chrome.tabs.discard` row. It resets the media defaults keys it relies on at start and in `finally`.

## Library Space Manager (App lane 1b)

The `sidebar-completion` suite covers sidebar selection, menus and commands,
previews, archive/restore, and E5/E6 (Library entries and native reorder), plus the manager's
undo, archive/restore, window replacement, and no-browser reopen flows. It uses the
real built App, real model/stores, native menus, and native mouse/key events.
It creates a temporary copy of **Open's own** bundle with a unique bundle ID
and re-signs that copy locally. This gives every run a separate preferences
domain, data root, engine cache, and socket. It uses synthetic data URLs and
no remote debugging port. It never opens or copies Arc.

| Command | Arguments and result |
|---|---|
| `library-open` | `entry=command` (default) dispatches App `manage-spaces` when `section` is omitted; `section=spaces|archive|downloads|captures|media|history` opens that section through the shared presenter. Unknown sections fail. `entry=space-menu` performs the Space-header “Manage Spaces…” item and accepts only omitted/Spaces section. Returns manager/Library state, including `section`. |
| `space-manager-state` | Reads the **attached** native manager, its class/identity/context ID, model and undo identity, isolated/global preview flags, columns, grabber points, up to 200 visible-outline rows per column, browser switcher order from real view positions, real model UndoManager notification count, and this App's window records. Points use the existing `mouse` command's window coordinates. Available after the last browser closes. |
| `space-manager-drag` | `space=<ID> to=<zero-based index>` drags the real visible grabber through `OEApplication.sendEvent`; the native tracking loop dequeues the drag/up events. Rejects invalid IDs/indices and offscreen grabbers. Returns manager state. |
| `space-manager-menu` | `space=<ID> item=<title>` performs the existing manager column menu. Add `node=<ID>` to perform that real outline row's context-menu item instead. No new confirmation policy or model implementation. |
| `space-manager-intent` | `kind=openURL space=<ID> url=<URL> [section=pinned]` sends the production intent that a URL drop on that Manager column sends (index 0 of Today, or Pinned). The native drop mapping itself is checked offscreen by `sidebar-render`. |
| `sidebar-menu` | `item=<A/B path> [node=<ID>] [alternate=true]` builds the same `NSMenu` a right-click shows on that row (no `node`: the Space menu) in the front browser window and performs the item. |
| `sidebar-menu-state` | Same `item=<A/B path> [node=<ID>] [alternate=true]` lookup as `sidebar-menu`, without performing an action. Reports title, enabled state and key, including disabled entries such as Share Space. |
| `sidebar-share` | `[dismiss=true|false] [close=true] [waitClosed=true]` controls the automation-only cancel policy and reads the actual `NSSharingServicePicker` request: URL, node, row anchor, service-query callback, close callback and pending state. The menu action calls the real picker; `dismiss=true` closes it without choosing a service. Always close/reset in `finally`. The copy toast's Share button (page-platform §4.2.2) uses the same picker; its request reports `node: "toast"` and the anchor is the toast's button. |
| `quote-offer` | The front window's last Shared Quotes offer after Copy URL (page-platform §4.2.2): `elapsed` (seconds until the page answered `getSelection()`; the budget is 0.150), `selected`, `shown`. |
| `profile-menu` | `[response=cancel|<existing Profile name>] [close=true] [waitClosed=true]` controls an automation-only response for the actual Set Profile menu opened by `menu-perform id=change-profile`. Reports menu-open callback, native tracking, checked choices, chosen Profile, closure and pending state. A choice performs the existing menu item after ending tracking. Always close in `finally`. |
| `alert` | `[window=library] [button=<title>]` reads the texts and buttons of the alert sheet attached to a browser (or the Library) window; with `button`, clicks it. |
| `toast-undo` | Clicks the newest visible toast's Undo button in the front browser window (its real `ToastCenter` button). |
| `toasts` | The front browser window's toasts, newest first (page-platform §8.3): `title`, `subtitle`, `symbol`, `accessory` (`none`, `keycaps`, or the button's label in lower case: `undo`, `share`, …), `coalescingKey`, `frame` and `accessoryFrame` (window content, top-left origin), `age` and `lifetime` (seconds), `sticky`, `exiting`, `hovered`; plus `panel` (the anchor) and `shown` (toasts shown so far in the window). Exiting toasts stay listed until their exit animation ends. |
| `toast-action` | `[index=<n>]` (default 0, newest first, visible toasts only) clicks that toast's button through the real `NSButton` (Share, Undo, …). Returns false when the toast has no button. |
| `defaults` | `key=open.… [value=…]` reads (and writes) one Open preference. The App suites use the shared domain `io.github.sergeserb2.open`: reset used keys at start and restore them in `finally`. `persistent=true` reads the saved value only (`null` if absent), so suites can restore absence without persisting a registered default. |
| `sound-effect` | `effect=capture|event` calls `SoundEffects.shared.play`; reports `played`, the resource name, and counts. Call it only with `open.advanced.playSoundEffects` off: it plays audio otherwise. |

`window-state` also reports `toolbarButtons` (visible toolbar buttons in order), `hint` (shows, visible, frame, keys, plate), `toast` (title of the newest toast shown in the window, also after it left), and `confirmation` (the pending delete alert's title, text, buttons).
| `library-close` | Closes the shared Library window, cancelling any attached sheet first. Reports `closed` and the sheet window numbers it cancelled. Available with no browser window. |

Use existing `key route=app window=<Library number>` for Cmd+Z and other
Library keys. Undo uses AppKit's nil-target Edit menu action and the Library
window's real model UndoManager. It has no second key handler.
Use existing `library-restore` for archive restore and `snapshot window=<number>`
for full-resolution real-window captures (`window=library` also resolves that window).

On M1, hold the outer validation lock once per job, plus the on-screen lock
for one suite invocation:

```sh
/usr/bin/lockf -k /tmp/open-m1-validation.lock /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --only sidebar-completion
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

`window-motion sidebarDelay=0.29` is a process-only negative control: it delays the actual sidebar layer animations, while the controller records a separate request time before model/layout work. `scheduledDelay` is layer begin time minus that independent request time; normal input must schedule within one frame. Reset the control to zero after use. `snapshot toggleSidebar=true` prepares page underlays, dispatches Cmd+S through `OEApplication.sendEvent`, and captures the window server image after a scheduled 25 ms; `capturedAfterKey` reports the capture request time for load/lateness evidence. This avoids the ordinary snapshot preparation wait hiding a short window animation.

Focused context-menu guard proofs call `context_menu_commands(..., run_all_commands=False)`.
They still capture all six real menu models and run the disabled-child and hidden-native
command selections. The regular tabstrip suite keeps the complete command smoke loop.
The probe popup storage check waits for the extension API, since `isLive` precedes
its document/API injection. Foreground-interruption checks stay enabled in both flows.

## Today auto-archive clock and scheduler

The App owns one `ExpirySweeper`. It sweeps at launch, on the registered
`NSWorkspace.didWakeNotification`, and on a non-repeating timer at the next
Today expiry. Tabs shown in any window, including every selected split pane,
have neither an expiry nor an armed timer for that tab. Activity starts at the
last deselection, Space switch, or window close. Model activity, ancestry, window
selection/visibility, Profile settings, and undo re-arm that
same timer. Never has no deadline. The production clock is wall time; automation
uses a nonpersistent offset that continues to advance with wall time. These
commands are available without an open browser, except the banner commands.

| Command | Args | Result |
|---|---|---|
| `archive-sweep` | Zero or one of `now` (ISO-8601, plain or fractional), `offsetSeconds` (finite number), `reset:true` | Set clock if supplied, then call the shared scheduler with reason `automation`; return archive-state plus this call’s `archivedCount` and `affectedSpaces` |
| `archive-clock` | Exactly one of the same clock args | Change clock and re-arm only; allows a natural timer callback without a manual sweep |
| `archive-state` | None | `now`, `offsetSeconds`, `running`, `nextExpiry` (ISO or null), `timerArmed`, `armedTimerCount` (0/1), `timerGeneration`, `sweepCount`, `countsByReason`, `lastReason`, `lastSweep:{now,archivedCount,affectedSpaces}`, `educationRequested` |
| `archive-wake` | Optional `now` ISO | Post the real workspace wake notification; await its observer and return state |
| `profile-archive-setting` | `profile` UUID, `interval`, `scope:profile\|all` | Real Settings propose/apply path; return affected `profiles:[{id,interval}]` and scheduler `state` after Observation delivery |
| `archive-list` | Optional `profile` UUID, `limit` 1…1000 (default 1000) | Real Profile SQLite `count` and `rows:[{id,kind,reason,space,profile,archivedAt}]` after queued writes; no URLs. Defaults to the focused Profile, or the default Profile without a browser. |
| `archive-banner-state` | Optional model `window` UUID | Actual view visibility, title, message, threshold, request, eligible/dismissed preferences, and frame in that Open window |
| `archive-banner-action` | `action:got-it\|settings`, optional model `window` UUID | Press the real Got it NSButton or invoke the actual Settings text-link delegate; require a visible card; return post-action state |

Intervals are `never`, `oneHour`, `sixHours`, `twelveHours`, `twentyFourHours`,
`sevenDays`, and `thirtyDays`. Profile thresholds live only in the snapshot.
Invalid or conflicting clock arguments and invalid setting values fail before
mutation. Reset the clock before creating/selecting the next fixture: model
creation and selection timestamps continue to use real wall time. `tabs` and
`tab-state` expose `createdAt` and `lastActiveAt` as Unix seconds; `sidebar-tree`
folders expose `expanded`; `settings-state` exposes `pane` and `selectedProfile`.
`metrics` also works after the final browser closes.

```json
{"id":1,"cmd":"archive-clock","args":{"offsetSeconds":43199.8}}
{"id":2,"cmd":"archive-state","args":{}}
{"id":3,"cmd":"archive-sweep","args":{"reset":true}}
{"id":4,"cmd":"profile-archive-setting","args":{"profile":"<Profile UUID>","interval":"never","scope":"profile"}}
```

Use fixture-derived activity times in checks. `sidebar-completion` includes
E16 banner/store flows and AA_APP timer, notification, launch snapshot, Settings,
Never, invalid-clock, all-Profile, and idle checks. `features-render` includes
AA1–AA12 whole flows with the same scheduler, model, SQLite stores, and banner.
The scheduling margin of 1 ms preserves the model's strict expiry comparison;
it is an Open implementation choice. Banner geometry remains unmeasured against
Arc (no banner capture exists).

## Sidebar completion A3

These commands use the browser's real outline, native menu, event router, or
production intent. They do not send system mouse or keyboard input. Input
commands activate the exact owned window and use the harness's focus tracking.

| Command | Arguments and result |
|---|---|
| `command` | `id=<registry ID>` aliases `menu-perform`. Rejects unknown or disabled native menu items. |
| `sidebar-click` | `node=<visible ID> [modifiers=[cmd,shift,option]] [window=<model UUID>]` scrolls an existing outline row into view and sends native down/up at its center. Rejects missing/collapsed targets. Returns ordered `selection`, active `selected` ID, and folder `expanded`/`peekedChildID`. Optional `motion:true` captures the installed folder duration/curve plus eight presentation samples through this same click path. |
| `sidebar-key` | `key=<name> [modifiers=[cmd,opt,ctrl,shift]] [window=<model UUID>]` focuses the real outline and sends the App key path. Includes Delete, `forward-delete`, Esc, Shift+Up/Down, Cmd+D, Cmd+Shift+N and Cmd+Z. Use plain `key` to keep a text editor focused. |
| `selection` | `[window=<model UUID>]` reads ordered multi-selection IDs without changing focus; empty is `[]`. |
| `hover` | Exactly one `node=<visible ID>` or `favorite=<ID>`, plus `ms=0…5000`. Sends native hover and awaits the duration. `leave=true` with no target leaves for a stable page point. Returns `preview-state`. |
| `sidebar-drop` | `nodes=[IDs] parent={kind:today|pinned|folder,id:UUID} index=<nonnegative Int>` calls the same `SidebarContext.performNodeDrop` as native outline acceptDrop. Rejects empty/duplicate/missing IDs, invalid destinations, and forbidden moves. This proves intent ordering and undo, not OS drag-session hit testing. |
| `sidebar-clear-state` | `[window=<model UUID>]` reads the actual divider Clear hit `frame` in root coordinates and hover `visible` state. Use native `mouse action=hover/click` with Option for the Option-Clear flow. |

`sidebar-row` also reads the visible `unreadBadge` and the actual `current` row highlight, without creating an offscreen row. `tabs sidebar:true` reports the selected sidebar node as `selectedNode` (a split ID for split content). Folder nodes in
`sidebar-tree` include `expanded` and `peekedChildID`. `tabs sidebar:true` returns
`{tabs,rows,folders,selectedNode}` with actual native row IDs and each folder's logical state
and visible direct children; plain `tabs` keeps its array response. `tab-strip` includes `pinStates`, read from
`OEBrowser.isPinned(_:)` for each actual engine web content. Mouse and key
commands accept `cmd`/`command`, `opt`/`option`, and `ctrl`/`control` aliases.
`sidebar-menu` rejects malformed node IDs and empty/ambiguous title paths.

The A3 flows and Today sweeper flows share the read-only `archive-list` command
listed above. `sidebar-completion` runs both sets of checks, including E16 and
the scheduler checks, through one definition of each helper.


`tab-switcher-state` reports `created` and `monitoringModifiers` as well as the
active/presented state, selected/item/visible IDs and drawing-view count. Reading
it never constructs the controller. `app-actions` checks that both cold launch
and the first real Cmd+T leave it uncreated. TS rows also check that an empty
Ctrl+Tab creates nothing, and that Control release/Esc remove the modifier monitor.

Section 1 items 9–10 add `I9_*` and `I10_*` rows to `sidebar-completion`.
They perform folder conversion (nested folders, split panes, empty folder,
Undo/Redo), single-item Move to New Space, recursive plain/Markdown folder
copy, the tab Share picker, disabled Share Space, and the four Spaces/Archive
menu entries through `sidebar-menu` / `menu-perform`. Rename commits and
cancels through the real editor; Change Profile opens the shared checked
menu; Clear Archive reads and answers the Library’s actual confirmation
with Cancel and Clear Archive. Every new picker/dialog is closed in a
`finally` path. `spaces` also reports each Space’s Profile ID for ownership
checks; tab descriptions include `pinnedURL` (empty when unpinned). These flows retain the unique disposable app bundle, data root and
preference domain of the existing suite.

For a focused items 9–10 diagnostic run, set `OPEN_SIDEBAR_INTENTS_ONLY=1`
on the same locked `--only sidebar-completion` command. It uses the same
cloned real app, engine provenance check, disposable roots and final cleanup;
it skips the earlier A1/A2/Manager/A3 rows. The default full suite still runs
all earlier rows, all items 9–10 rows, and main’s E16/AA_APP scheduler rows.
The combined suite runs the items 9–10 flows before the scheduler’s final
no-browser idle check.

`waitClosed=true` waits up to 5 s inside the automation command for the
picker/menu callback to finish. These checks verify a request and its
cancellation without sending keys; they do not open a Python timed focus
interval. Native rename and other keyboard checks retain the normal focus
guard.

The Set Profile automation policy observes AppKit’s
`NSMenu.didBeginTrackingNotification` and cancels on the tracking run loop’s
next turn. The Share policy retries `close()` on a bounded 50 ms run-loop
timer after the service query, until the close callback or 100 attempts.
The timer is automation-only and is invalidated on callback/window close.
This avoids queuing cancellation on GCD
behind a nested tracking loop. The Profile observer is removed when the menu
or browser window closes. The share check verifies the picker’s own query
and close callbacks; it chooses no service.

## Page tools: Developer, Appearance, Clear, Troubleshooting (page-platform Steps 4–6)

Suite `page` (`--only page`, both `--style chrome` and `--style alloy`) runs the
rows of `docs/plans/page-platform.md` §8.3 against fixtures in
`tools/e2e/fixtures/page-platform/`, served from 127.0.0.1 by
`page_tools_fixture_server()` (no external network). One function per row group;
`page_checks` calls every group. A row that waits for an engine item reports
`BLOCKED: <item>` and never counts as a pass. The group saves and restores the
two preferences it writes (`open.web.colorScheme`,
`open.developer.allowJavaScriptFromAppleEvents`), because the preferences
domain is shared between runs.

| Command | Args | Does |
|---|---|---|
| `menu-state` | — | Each row also reports `checked` (`state == .on`) and `hidden`. |
| `devtools-frontend` | `tab`, `js` | Evaluates `js` in the open DevTools window of the page (the DevTools front end, `OEWebContent.evaluateInDevToolsFrontend`); fails when no DevTools window of that page is open. D1 reads the selected tab ids (`tab-console`). |
| `devtools-close` | `tab` | Closes the page's DevTools window. |
| `troubleshooting-setup` | `traceDir`, `recordReveals` | Stop writes traces into `traceDir` instead of `~/Downloads`; Finder reveals (Reveal Open Data, the Trace Saved toast's Show in Finder) are recorded instead of shown. |
| `troubleshooting-state` | — | `tracing` (engine), `recording`, `lastTraceFile`, `lastTraceError`, `taskManagerShown`, `reveals`, the stored website appearance and each live context's `websiteColorScheme`, and the Apple Events JavaScript preference. |

The trace toasts are ToastCenter toasts: the H2 row reads them with `toasts` and presses Stop and Show in Finder with `toast-action` (the real buttons).
The existing `appearance name=light|dark|system` command is the plan's
`app-appearance` (it sets `NSApp.appearance`).

## Page engine (page-platform EP-1, EP-2, EP-3; Step 12)

Automation builds pass `--open-automation` to the engine, which turns on the engine's test hooks.
`--only page` runs the rows SW1–SW4 (history swipe and Open's indicator) and Q2 (selection).

| Command | Args | Does |
|---|---|---|
| `page-selection` | `tab` | The page's selection through `requestSelection` (EP-2): `text`, `link` (Chromium's text-fragment link, or null), and `hasSelection` (EP-3). |
| `swipe` | `tab`, `direction` (`back`, `forward`), `progress` (0…2, default 1.2; ≥ 1 navigates), `enabled`, `engineOverlay` | Sets `historySwipeEnabled` / `drawsEngineHistorySwipeOverlay` when given, then replays one history swipe through Chromium's overlay controller (`simulateHistorySwipe`). Phases arrive as `historySwipe` events. Without `direction`, returns the two flags only. Returns `ran`, the flags, and `indicator` (as `swipe-indicator`). It replays the controller sequence and the navigation, not gesture recognition. |
| `swipe-indicator` | `tab` | Open's indicator over the pane that shows the tab: `pane`, `made` (the view is made on the first swipe), `active`, `hidden`, `circle` and `page` frames, `opacity`, `scale`, and `last` (`phase`, `direction`, `progress`). |

## Capture tool (page-platform Step 13)

`--only page` runs the capture rows C1–C7, then the translation rows X1–X6 (page-platform §8.3), against
`tools/e2e/fixtures/page-platform/` (served from a local port). Every step uses the
real paths: the File menu item, own-window mouse events through
`NSApplication.sendEvent` (the window's local monitors see them, as with real input),
the real key path for Esc, and the result card's own buttons.

| Command | Args | Does |
|---|---|---|
| `capture` | `mode` (`area`, `fullPage`, `portrait`), `rect` `[x, y, w, h]` in page points, `entry=drag`, `timeout` | Runs the File menu item. For `area` with `rect`, drags inside the overlay; without `rect`, returns with the overlay up (send `key key=escape` or `return`). `entry=drag` sends a Cmd+Shift press on the page, a 2.2 pt move (still held), then the drag, as the user would (§4.6.2). Waits for the pipeline; returns `steps` and `capture-state`. |
| `capture-state` | — | `phase` (`idle`, `selecting`, `capturing`, `showing`), `overlayActive` (the swipe hook), `held`, counts (`completed`, `cancelled`, `replays`, `hintShows`), `entry`, `error`; `overlay` (frame, page frame, selection, anchor, size label, hint); `card` (frame, actions, Library line, note, scheduled lifetime, time left, `paused`, panel frame); `result` (kind, pixel size, `truncated`, saved row id, host, Save… file name). |
| `capture-action` | `action` (`copy`, `save`, `share`, `library`, `retake`, `delete`, or `cancel`), or `hover` (bool) | Clicks that card button (`performClick`), or sets the card's hover state (the pointer pause), or cancels the overlay or card. |
| `captures` | `probe` `[[x, y], …]` (≤ 64, image pixels), `index` | Rows of `State/captures.json` with file sizes and PNG pixel sizes; `probe` reads RGBA pixels of one row's PNG (default: the last). |

The page context menu event (`policy contextMenu=record`) also lists `open` (Open's own
items, "Capture" and "Capture Full Page") and `shown` (the whole menu as it would show).

P3 negative proof: `OPEN_E2E_P3_CANCEL_INSTALL=1` (automation builds only)
forces the prompt handler to cancel an install acceptance. The
`extensions-p3` X1 row must FAIL. Unset the flag and rerun for PASS. The
suite restores no shared defaults because it changes none; every install,
profile and Chromium preference lives in its fresh data root. Its `finally`
answers pending prompts and closes all owned auxiliary surfaces; the harness
then quits and checks every process it started.

### S11 dialog and permission acceptance

Run `tools/e2e/engine_e2e.py --only page-chrome` under the on-screen lock.
It launches the real App, serves loopback pages, checks native sheet and
popover state, clicks their actual buttons, sends keys through
`OEApplication.sendEvent`, and verifies Profile persistence after relaunch.
The `dialog` event adds `title`, `buttons`, `suppressible`, and `queued`;
automatically answered suppressed dialogs also carry `suppressed:true`.
`dialogAnswer` and `permissionAnswer` record one completion per owned request.
`OPEN_E2E_PAGE_CHROME_EARLY_FAILURE=1` forces failure while the first real
sheet is visible; cleanup must still leave zero owned processes/windows.

## Find in page (Section 11)

Run `--only find --style chrome` through the on-screen lock. The suite serves
`tools/e2e/fixtures/find/` on a unique loopback port and drives the native
application event route. It covers the field editor, page shortcuts, tab
state, navigation, Split View, Peek, selection seeding, query limits, pane
viewport frames, chrome intersections, native close clicks and live resizes
with the toolbar on/off, in Split View and in Peek. It also checks light/dark
window pixels (ΔE00 ≤ 2) and idle request/result/layout counters. PNGs stay in `.re/find/`; JSON uses the ordinary suite receipt.
The Find timing gate uses the project's 120 Hz reference: 8.33 ms from the
native Cmd+F timestamp to the visible layer commit. It reports separate
first-open (including lazy creation) and repeat-open medians and nearest-rank
p95 from twenty fresh windows. Both p95 values must pass. The 240 Hz interval is
printed for information. Take timing receipts with the quiet lock first,
wait for low load while holding only that lock, then take the screen lock.
Fonts, symbols and appearance colors are shared per process. After the first
web paint, one main-queue turn primes those resources and an offscreen native
bar/editor, then releases the temporary controls. `find-state.warmup` reports
the run count, launch-relative times and temporary-control release. This adds
no timer or repeating task. Automation builds accept
`OPEN_FIND_DISABLE_PREWARM=1` for a cache-only comparison;
`OPEN_FIND_COMPARE_PREWARM=1` alternates twenty cache-only and twenty enabled
launches in the Find suite and records both phase and launch measurements.
No shared defaults are changed by this suite. The toolbar toggle changes
only its disposable browser model, and app appearance is restored in `finally`.
`OPEN_FIND_FAIL_AT_PEEK=1` forces an early failure with Peek and Find open;
the normal owned-process cleanup must still pass.

Find and Replace opens Find in web pages. Jump to Selection scrolls the
selection's containing element to the center via the existing main-world
JavaScript API; this API does not provide an isolated world. Use Selection
to Find uses the native menu action and has the 1,000-byte query cap without
the 40-character seed limit. This work changes no command bindings.

## Runner lifetime

E2e launchers pass `OPEN_E2E_OWNER_PID`: the shared `Open` launcher supplies it through LaunchServices, and the direct migration fixture sets it in its subprocess environment. Automation builds watch that runner with a process exit dispatch source before preparing data or windows. A missing owner exits immediately; owner death logs `Open: e2e owner <pid> exited; quitting` and requests normal shutdown (the App's page-beforeunload preflight and engine close prompts are skipped, download quit confirmation is skipped, active transfers and save choices are cancelled, and new download destination prompts are refused). A background deadline forces exit after five seconds if shutdown stalls. There is no polling or idle timer. Normal builds compile out the watcher and environment handling.

`tools/e2e/owner_watch_e2e.py <output-directory>` exercises four real-App
cases: owner death, a missing-owner-environment negative control, an active
download, and a page with a beforeunload handler. `--before-unload` runs only
the last case. That case first observes and cancels a normal held beforeunload
request, then kills the runner and requires shutdown without another request.
Run it under the on-screen lock. Normal user quit keeps the page preflight.

## Session downloads (S11)

`--only downloads` in `tools/e2e/engine_e2e.py` serves known-length, unknown-length,
interrupted and fast transfers on an ephemeral loopback port. It uses real engine
callbacks, Profile settings, Library rows, save sheets and the app-modal quit
warning. Run with the on-screen lock, one suite per invocation.

| Command | Arguments / behavior |
|---|---|
| `downloads-state` | Session items, actual visible native row subtitles/buttons, real Home badge layers, queued publications, pending save sheets, recorded file actions and actual quit-alert strings. |
| `download-settings` | `profile`, optional `directory`, `ask`; changes the real Profiles settings model in the disposable data root. |
| `download-row` | `id`, `action=Pause|Resume|Cancel|Retry|Show in Finder`; presses the visible row's actual `NSButton`. |
| `download-menu` | `id`, optional exact `select` title; reads/performs the same native `NSMenu` returned for a row right-click. Disabled or invisible items fail. |
| `download-save` | Pending sheet `id`; `action=cancel` or destination `path`. Sets `NSSavePanel.directoryURL` and filename, then presses an exposed native Save/Cancel button. For a remote panel with hidden buttons, supplies the URL through its native response method (ABI checked). The existing sheet completion answers the engine. |
| `download-policy` | `quit=close|keep|record` answers the real app-modal alert with its native button (`record` records and keeps browsing); `recordFiles=true` records file-action URLs and suppresses Finder/external default-app launch; `openApp=<bundle path>` runs real NSWorkspace document delivery to the disposable background receiver instead. Copy and Trash still run. |
| `download-home` | Presses the browser's actual Home accessibility control. |
| `download-library-close` | Uses the Library window's normal close action. |
| `download-idle` | S8 observer actions `begin|reset|canary|end` and counts. Available only when the runner injects `feature-idle-probe.m`. Canary is a real repeating timer that is then invalidated. |

The suite gives its cloned App a unique preferences domain and restores each
`open.*` preference it changes in `finally`. It
cancels pending save sheets before verified-PID cleanup, including forced early
failure (`OPEN_DOWNLOADS_FAIL_IN_SHEET=1`). The receiver verifies the real Open
document URL, bytes and SHA-256. Finder dispatch is recorded without opening a
Finder window. Home geometry and the 60-second recent-download click rule remain the
lead's marked guesses. No Little Open tray is added.

The `extensions-e2` suite also checks three-action pin/move/unpin sequences through `ext-pin`, `ext-move`, and `actions`. It checks raw engine ids and pinned indices, plus `extensions.duplicatesDropped == 0` when the App guard is present. `OPEN_E2E_E2_SCOPE=pins` selects this reproduction alone.

`OPEN_E2E_E2_SCOPE=drag` selects the native drag safety row. It pins real uBO
Lite, Dark Reader, and Action Probe, moves Probe 2→0→2, repeats pinning, and
tries unknown/unpinned actions, an empty pinned list, and negative, count,
99, 2³²+1, and Int.max indices. Every snapshot requires unique ids, the exact
order, compact indices, and zero dropped duplicates when the App guard exists.
It then closes its isolated App, writes the old duplicate-pin preference state,
relaunches that profile, and repeats the drag after repair.

`OPEN_E2E_E2_FORCE_FAILURE=popup` stops the suite with its native popup open;
`popup-quit` first quits the App to exercise restoration without the socket.
Frame preferences are restored after quit through the shared defaults fallback.

## Open-world scripts and messages

`eval` accepts `world: "page"` (default) or `"open"`, through OpenWeb's
`evaluateJavaScript(_:in:)`. Invalid world names fail. Open evaluation targets
only the current main-frame document and grants no user gesture.
`script-add` accepts the same world names. Open-world scripts always run at
document start and in the main frame, even with `end` or `allFrames` set.
With `css: true`, the stylesheet keeps its original source and receives no
JavaScript transport prelude.

`open-world-messages` accepts `tab`, optional `clear: true`, and optional `subscribe: true/false`
(to exercise the OpenWeb callback). It returns
`messages` and `callbacks` (type, payloadJSON, documentID, content), and `statistics` (accepted,
oversized, rateLimited, invalid). The App retains only the last 64 messages
across its factory; clearing removes that page's receipt, not engine counters.
The recorder is automation-only and never persists payloads.

Example: add an Open script containing
`__openNative.postMessage("picker:ready", JSON.stringify({boostID:"fixture"}))`,
navigate to a matching page, then read `open-world-messages`. Page and extension
worlds see `typeof __openNative === "undefined"`.


## Site settings, data and security (E1/E2/E3)

All four commands use the selected page's OpenWeb profile/content; optional
`tab` selects another page. These commands do not open Site Control UI.

| Command | Arguments | Result |
|---|---|---|
| `site-settings` | `origin` HTTP(S) URL | `[{kind,state}]` effective exceptions that differ from the global default |
| `site-setting` | `origin`, `kind` Chromium name, `state:allow\|block\|ask\|session` | Boolean acceptance; each kind supports only registered states |
| `site-data-clear` | `origin`, `kinds:[cookies,cache,storage]` (any subset) | Waits for every backend, then returns true or an error. Empty kinds is valid. HTTP cache eviction is origin-specific. |
| `security-state` | Optional `tab` | `{level,certificates:[{bytes,sha256}]}`; leaf first, no certificate subject or private data |

`events` records change bit 16 for visible security/certificate updates.
The `sitedata` suite uses isolated loopback HTTP origins and a temporary
self-signed TLS server; valid HTTPS uses a public control because no new local
trust root is installed. Run it under the on-screen lock after the lead clears
any screen HOLD:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --style chrome --only sitedata
```

## Boost runtime and simple editor (Section 12)

| Command | Arguments | Result |
|---|---|---|
| `boosts` | `action: list\|get`, optional `profile` UUID, `boost` UUID for get | Values from the App's loaded Profile store. No mutation API. |
| `boost-library` | `action: rename\|enabled\|delete`, `boost` UUID, `name` or `enabled` | Requires a visible Boosts Library row; calls its real LibraryActions boundary after confirmation. It does not prove native button or confirmation input. |
| `boost-editor` | `action: open\|close\|state\|drag\|key\|tap\|type\|customize`, optional `boost`, `tab` for open | Real simple/Code editor and session (`mode: simple|code`). Private or non-http(s) tabs refuse open. `customize` invokes the selected tab’s real Customize Page sidebar action and returns its success. `incognito-state` exposes read-only `boostScriptIDs` for private script-isolation checks. |

`drag` takes 2–512 finite `[x,y]` points within the color pad, in editor-view
coordinates. It sends mouse down, drag through the final point, then mouse up.
`key` uses the normal `key` arguments and always routes through OEApplication.
`tap` takes a native control ID (`editor.color.invert`, `editor.undo`), a plan alias
(`font.Avenir`, `size`, `case`, `firstRun.makeABoost`), `menu.<native title>`, or
`alert.Done|Cancel|Delete`. Menus and alerts use their real native actions.
`type text=...` edits the active rename sheet or visible CSS/JS text view through
App key events (16 KiB limit). Empty text clears the selected field through Delete.

State includes the Boost value, bound tab/Profile, interstitial, global and scope
state, undo state, controls, panel frame/key state, specific active alert, and
refresh generation/completion, timing, delivered/skipped page counts, JavaScript
delivery count and apply-failure count. Code state adds `loadedJS` (the current
document's installed script, or null) and `refreshToRun`. The `boosteditor` suite exercises
B1–B3, B5 and B6–B10, plus navigation/close, ten-page refresh, Library, saved-script,
Edit Boost for a disabled saved Boost, discard/wake refresh, Library metadata
reconciliation, Undo/Redo preservation, and Library Delete. The ten-page timing
row requires ten live matching pages with nine hidden pages. B26 saves a Boost,
restores the selected matching tab without a launch URL, and checks CSS and JS
from that document's first inline script. Global off is its negative control.
B4 is blocked by P7.
B5 proves that CSS applies live, JS waits for reload, and Refresh to Run follows
the loaded document rather than the latest stored text. Every row includes a real negative control. The suite restores all
preference keys in `finally` and uses
an ephemeral local fixture server plus the runner's isolated roots/cleanup.
## Space editors (Section 4)

Theme commands use the real App model and the same window controller as the
menu and command bar. Coordinates for `editor-act` are panel content points
from its top-left (including the transparent 13 pt band). Named controls use
`control` with the names returned by `editor-state.controls`.

| Command | Arguments | Result |
|---|---|---|
| `theme-get` | optional `space` (focused by default) | stored `style` or null, derived light/dark palette hex, `contentAppearance` |
| `theme-set` | optional `space`, `style` object or null | session preview/commit, one Update Theme undo step and save |
| `editor-open` | `kind=theme/icon`, optional `space`; icon also accepts `node` | true; unknown kinds return false |
| `editor-act` | `action=click/hover`, `x/y` or named `control` | own-panel NSEvents |
| `editor-act` | `action=drag`, `from/to` point arrays, optional `steps` (1–240) | own-panel mouse down, drag frames, up |
| `editor-act` | `action=down/drag/up`, `x/y` | one event, for interrupted gestures |
| `editor-act` | `action=key`, `key`, optional `modifiers` | `NSApplication.sendEvent`, app routing |
| `editor-state` | — | kind, Space, frame, scale, controls, knob, commit/preview/frame counters, pending frame and process-wide editor display-link count |
| `editor-close` | — | flush and close; safe when already closed |
| `snapshot` | `window=editor`, `path` | real panel PNG |

`command id=edit-theme` reuses the generic menu command runner. The native
`space-editor` e2e suite runs both theme and icon row sets; creation can extend
the kind switch and suite. Model reads can precede a pending display frame: wait
for `editor-state.pendingFrame=false` after a completed gesture before
asserting its committed value. Snapshot checks use empty background regions,
so the auto-archive education banner is not mistaken for a theme pixel.

`editor-state` also exposes the theme session commit ledger: `commitSequence`,
`committedStyle`, `commitPreviews`, `sessionPreviews`, and `undoActionName`.
The committed value is captured in the same MainActor call as the model
undo registration. `A3_committed_style_stable` compares it with the model
after the final frame and after idle, rejects later previews, and checks
the Update Theme action name. A3 undo/redo compares against that ledger.

## Section 7 Settings flows

The `peek` suite opens Settings ▸ Links and uses `defaults` to write the
canonical `open.links.openPeekShiftClick` key bound by that pane; there is no
Settings switch UI driver. It then proves a real Shift-click does not Peek.
The `commandbar` suite includes `settings_live.py`: native New Profile menu
and sidebar sheet, Cmd+, typing guard and Escape, local action errors, actual
1024 px App icon application/cache/reset, restore after content with measured
cost, Peek migration/precedence, and global sleep reconciliation on create and
launch. `OPEN_SETTINGS_FAIL_IN_SHEET=1` forces a failure with Create Profile
open; finally cancels the sheet, restores exact saved preferences, and quits.

The sleep suite uses existing `sleep-clock` and `sleep-tick` hooks to pass the
30 s freeze deadline and 48 h without changing production delays. Never
retains ten loaded hidden pages past the eight-host cap and critical pressure,
and keeps a previously discarded shell beyond the 24 h destroy deadline.
`defaults` changes to `open.advanced.tabSleepMode` also reconcile policy.
These suites save/reset/restore touched keys in the shared defaults domain. The runner also saves canonical Peek values before the first App launch, so startup migration and later Find/Escape launches cannot change the original stored values after cleanup.
Launch marks `appIconRestoreStarted` and `appIconRestored` report deferred icon
work after `windowShown` and first content paint (or the no-paint fallback).

Sidebar resize interruption proof (`window` suite): `resize_lost_up_key` and
`resize_lost_up_sheet_hides` inspect the held drag, native interruption, stale
drag/up rejection, edge-hover recovery, and a new drag. `window-state` exposes
`sidebarResizeHandleDragging`, `sidebarResizeHandleVisible`, `sidebarResizeHasStart`,
and nullable `sidebarWidthOverride` for complete cleanup evidence. `drag_undo_single`
checks three live crossings and two Cmd+Z events through the outline and App key path; `drag_undo_same_mode`
checks that returning to the start mode adds no action. Width commits and the
hidden-gesture notification remain mouse-up effects. The `window` and `sidebar`
suites set the hide-hint flag to a fixed value at each attempt and restore its
pre-launch value (including absence) in `finally`.

## Passwords Step 0 probe

Run `python3 -I tools/e2e/engine_e2e.py --config Debug --style chrome --only passwords-probe`
under the on-screen lock, after the shared priority check. Export the current
`OPEN_ENGINE_ROOT` as for builds. This uses only temporary App data and the
mock Keychain. It records selected PR-1 through PR-9 rows as observations, with
per-row App liveness and new-crash-report checks. It saves no screenshots or secret values.
The reusable fixture server and URL/switch dictionary are documented in
[the fixtures README](../tools/e2e/fixtures/passwords/README.md).

PR-7 stays blocked pending an approved engine-fix distribution hash. After the
lead clears a prior crash dialog, resume remaining rows with
`--passwords-probe-rows PR-8,PR-9`; do not replay the crashed row. Selected runs
write a separate receipt so the primary crash evidence survives.

Boost editor B27 deletes a Profile through the real Settings confirmation with a dirty Boost store, waits beyond its debounce, quits and relaunches. The Profile folder and Boost file must remain absent. A disabled-retirement App supplies the deliberate negative proof.
