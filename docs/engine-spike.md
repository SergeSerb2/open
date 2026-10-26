# Engine spike and M1 engine foundation

Date: 2026-10-25. Engine: CEF 156.0.14+g4fa4ab5 (Chromium 156.0.8078.48), the same CEF commit as our fork's base, from the Spotify CDN (`tools/fetch-cef.sh`). Machine: Apple Silicon, 18 cores, macOS 27.2 beta. A Chromium build ran in parallel during every measurement (load average about 26), so the timings are pessimistic.

All results come from the real app driven through the automation channel ([automation.md](automation.md)) by `tools/e2e/engine_e2e.py`. Raw results: `docs/engine-spike/results-*.json`. Screenshots show Open's own windows only.

## Verdict

**Engine: go.** CEF's embedding layer on Chromium 156 hosts any number of pages in our own NSViews with every feature the shell needs (table below: all 19 checks pass in the final run). The shell talks only to OpenEngine, which already has Arc's ADK shape (`OEEngine`, `OEBrowserContext`, `OEBrowser`, `OEWebContent`).

**Extensions: the runtime works today; the UI integration needs our fork.** In stock CEF, with pages in our own views (Alloy style):

1. Content scripts, MV3 service workers, and declarativeNetRequest blocking work for uBlock Origin Lite, Dark Reader, 1Password, and Bitwarden. Options pages work as tabs.
2. Our own toolbar shows every action with its icon, and a click opens the popup page in our panel: uBO Lite, Dark Reader, and 1Password render and work.
3. `chrome.tabs` and `chrome.windows` do not see our tabs ("No current window"), so popups that ask for the current tab break (Bitwarden stays on its spinner), and dynamic action state (badge, `setIcon`) never reaches us.
4. Web Store install and `chrome://extensions` work only in Chrome-style pages, which stock CEF on macOS can host only in a separate Chrome window, with one window per tab as far as `chrome.windows` is concerned.
5. Fork patches P1 (tab-strip bridge), P2 (actions and popups), and P3 (management and prompts) close all of these with code paths that Chromium 156 already has for its WebUI toolbar and for Android (estimate 7–11 engineer-weeks): [engine-patches.md](engine-patches.md).

## Extensions in detail

Extensions: uBlock Origin Lite 2026.1021.1354, Dark Reader 4.9.133, 1Password 8.12.42.36, Bitwarden 2026.10.0 (CRX files from the Chrome Web Store, unpacked with their store IDs, loaded with `--load-extension`), plus Google Translate installed from the Web Store page.

Runs: `tools/e2e/engine_e2e.py --only extensions --style alloy|chrome` (Debug build): `results-extensions-alloy.json`, `results-extensions-chrome.json`, and the `alloy-*`/`chrome-*` screenshots.

| Check | Alloy: page in our NSView (Open's default) | Chrome style: page in a CEF Views window glued over our view |
|---|---|---|
| Enumerate installed extensions, actions, and icons for our own toolbar | pass (from Preferences + manifests) | pass |
| MV3 service workers running (DevTools targets) | pass, all 4 | pass, all 4 |
| Content scripts: isolated worlds for all 4; Dark Reader dark theme applied | pass (`alloy-content-script-darkreader.png`) | pass |
| declarativeNetRequest blocking (uBO Lite blocks both ad-script probes; without extensions they load) | pass | pass |
| Options pages as tabs (uBO Lite dashboard, Dark Reader settings) | pass | pass |
| Action popup opened from our toolbar button, in our panel | renders and runs: uBO Lite, Dark Reader, and 1Password (`alloy-popup-*.png`; 1Password from the final run, the others from the run before it). Under heavy machine load the popup page took about 10 s to commit, so in the final run only 1Password rendered within the 15 s probe. Bitwarden never leaves its spinner (no current tab, see next row; guess) | unreliable: the popup is itself a Views window over our panel; uBO Lite works, the others failed or timed out |
| `chrome.tabs`/`chrome.windows` from inside a popup | `chrome.windows.getCurrent()`: "No current window"; `tabs.query({})`: `[]` | 4 windows for 3 tabs + popup (one window per page); the "active tab" is the popup itself |
| Pages that extensions open (welcome pages, `chrome.tabs.create`) | none opened in this run | adopted as Open tabs: 1Password welcome, Dark Reader help |
| Web Store install: "Add to Chrome", Chrome's dialog, "Add extension" | **fail**: the dialog opens as a free-standing window; the install does not complete | pass: dialog as a sheet, Google Translate installed (`chrome-webstore-dialog.png`) |
| `chrome://extensions` | **fail**: does not render | pass: lists the 4 extensions (`chrome-chrome-extensions.png`) |

What this means: everything that runs inside the extension system works in Alloy style. What is missing is the bridge between the extension system and our UI: the window/tab model (P1), live action state and real popup hosts (P2), and management/prompts (P3). Chrome style shows that the stock Chrome UI paths work, but it cannot be Open's hosting model: on macOS it needs a separate Views window per page, and `chrome.windows` sees one window per tab.

## Engine features

`tools/e2e/engine_e2e.py --only features --style alloy` (Debug build): `results-features-alloy.json`.

| Check | Result | Evidence |
|---|---|---|
| JS dialogs | pass | `alert`, `confirm`, `prompt` reach our delegate; prompt text returns to the page |
| Permission prompts | pass | Notification request reaches our delegate; grant returns "granted" (geolocation not exercised: it would trigger the macOS location prompt for the user) |
| Popups and new tabs | pass | `window.open` with size goes to a panel; `target=_blank` becomes a Today tab at the top |
| Find in page | pass | 132 matches for "browser" on the Wikipedia page |
| Zoom | pass | level 1 → `innerWidth` 1084 → 903 |
| Context menu hook | pass | Chromium's items arrive in our delegate (Back, Forward, Print, View Page Source) |
| Audible state and mute | pass | audible while a WAV plays, not after pause; mute works |
| HTML fullscreen | pass | delegate called, `document.fullscreenElement` set |
| Picture in Picture | pass | `requestPictureInPicture()` resolves; Chromium shows its PiP window |
| PDF viewer | pass | Chromium's PDF extension renders (`alloy-pdf-viewer.png`) |
| Print to PDF | pass | 440 KB file |
| Downloads | pass | destination from our delegate, progress events, file written |
| User scripts (Boosts) | pass | CSS and JS injected before page scripts on the matched site only |
| Request filter (ad-block hook) | pass | a matched request is blocked, then loads after the filter is cleared |
| Profiles | pass | a second Space with a new profile "Work" gets its own context in `Profiles/<dir>/Engine` (the M5 layout): no cookie, no localStorage from Default |
| Ad-block control | pass | without extensions the ad URLs load (so the DNR result above is real) |
| Codecs | pass (as expected) | VP9, AV1, Opus, MP3 yes; H.264, AAC, HEVC no in stock CEF (the fork's GN args turn on proprietary codecs: P4). Fork build: H.264, AAC, HEVC yes (`results-features-alloy-fork.json`) |
| Widevine | pass, once the CDM is downloaded | Chromium's component updater fetched the Widevine CDM (4.10.3112.0) into `Profiles/WidevineCdm`; then EME was available and a Widevine-encrypted test stream played (123 frames in 5 s). In three earlier runs the CDM had not arrived within the 120 s wait and EME was unavailable. v1 does not ship Widevine by lead decision (`Engine/fork/gn/release.args.gn`: `enable_widevine=false`). |
| Renderer crash | pass | crash state reaches the model; reload recovers |

## M1 shell

`tools/e2e/engine_e2e.py --only shell` (Debug build): `results-shell-debug.json`, `shell-window.png`, `shell-split-view.png`.

| Check | Result |
|---|---|
| Fresh start | Default model (one profile, one Space) when the snapshot folder is empty |
| Tab strip mirror | The window's `OEBrowser` holds the loaded pages in sidebar order (favorites, pinned, today) |
| Keyboard | With a page focused that calls `preventDefault()` on every key: Cmd-L (sent straight to the page view) and Cmd-T (sent through `NSApplication`) focus our address field; typing a host and Return opens it as a new tab; Cmd-W archives it; Cmd-Shift-T restores it with the same tab ID |
| Split View | Two live pages side by side in one window |
| Window PNG | From inside the app, no Screen Recording permission |
| Persistence | Quit and relaunch: same tabs, IDs, sections, and URLs from `State/browser.json`; only the selected tab loads at launch |

The shell uses the M5 data layout (`OpenDataRoot.prepare`, `ProfileDirectories`, `ProfileArchiveSink`): `State/browser.json` for the model and `Profiles/<dir>/{Engine,State}` per profile. The shell is deliberately plain: a list of the focused Space's tabs (favorites, pinned with folders and splits, today), an address field, a Space menu, the extension toolbar, and the page. OpenSidebar replaces the left side.

## Measurements

Release build with the automation channel (`OPEN_AUTOMATION=1 tools/build.sh Release`), `tools/e2e/engine_e2e.py --only measure --config Release`: `results-measure-release.json`. Load average 9–14 on 18 cores during the run (other work was running), so these are upper bounds.

Launch (process start to each mark; median of 3 launches of an existing profile with a restored `example.com` tab, and the very first launch of a fresh profile):

| Mark | Existing profile | First launch, fresh profile |
|---|---|---|
| `main()` | 40 ms | 53 ms |
| `CefInitialize` returned | 257 ms | 1522 ms |
| Engine initialized | 309 ms | 1558 ms |
| Window and sidebar shown | 452 ms | 1669 ms |
| Restored tab: main-frame load end | 606 ms | 1902 ms |
| Restored tab: first contentful paint | **649 ms** | 1927 ms |

Budgets (docs/architecture.md): sidebar ≤ 250 ms, first web paint ≤ 700 ms, on an idle machine. We are at 452 ms and 649 ms under load. A fresh profile spends about 1.3 s more inside `CefInitialize` (Chrome's first-run work; P5 trims it). In an earlier run under heavier load, the first launch after a rebuild also lost about 1.9 s before `main()` (macOS checking the new 226 MB framework; guess). Two easy wins remain: build the window before `CefInitialize` returns (today it is built when the engine reports ready, at about 300 ms, and takes about 140 ms to appear), and keep the CEF framework signature stable so that first-launch check is paid once per release.

Memory (physical footprint of all Open processes, as Activity Monitor counts it; Chromium's task manager split by kind):

| Pages | Total | Browser | GPU | Renderers | Utility (network, storage) | Processes |
|---|---|---|---|---|---|---|
| 1 (`example.com`) | **220 MB** | 64 MB | 45 MB | 65 MB | 46 MB | 6 |
| 10 (example.org, Wikipedia, IANA, MDN, Hacker News, W3C, GitHub, rust-lang.org, python.org) | **974 MB** | 85 MB | 245 MB | 594 MB | 59 MB | 15 |

With one tab there are two renderer processes; the second is probably Chromium's spare renderer kept warm for the next navigation (guess). The GPU process grows to 245 MB with 10 pages that were each shown once; tab sleeping ([memory-design.md](memory-design.md)) targets exactly these two lines.

Idle CPU with 10 pages loaded, 10 s window: 1.3 % of one core in total (Chromium task manager, all processes; Hacker News, GitHub, and MDN keep timers running).

### Fork vs prebuilt (2026-10-25)

Same machine, same harness (`--only measure --config Release`), back to back at a load average of about 10 on 18 cores. Before each run, one throwaway launch warmed the new framework, so the first-launch check after a rebuild is not counted. Fork: our dev build (`Engine/fork/gn/dev.args.gn`: `is_official_build=false`, no ThinLTO, no PGO) from `engine-distrib`. Prebuilt: the CDN build of the same CEF commit, an official build. Files: `results-measure-release-fork.json`, `results-measure-release-cdn.json`.

| Measure | Fork (dev args) | Prebuilt (CDN, official) |
|---|---|---|
| `CefInitialize` returned (median of 3) | 256 ms | 179 ms |
| Window and sidebar shown | 386 ms | 299 ms |
| Restored tab: first contentful paint | **584 ms** | **450 ms** |
| Fresh profile: first contentful paint | 517 ms | 424 ms |
| Memory, 1 page (total footprint, 6 processes) | 239 MB | 235 MB |
| Memory, 10 pages (15 processes) | 1210 MB | 1215 MB |
| Idle CPU, 10 pages, 10 s | 1.2 % | 1.0 % |
| Framework binary | 455 MB (`__TEXT` 257 MB, `__LINKEDIT` 186 MB: 1.33 M local symbols) | 226 MB (`__TEXT` 221 MB, `__LINKEDIT` 2 MB) |
| Open.app, all locales | 545 MB | 329 MB |

- Launch: the fork is about 80–130 ms slower at each mark. This is what a non-official build costs (no ThinLTO, no PGO). The release args (`gn/release.args.gn`) build the shipping engine officially; that build waits for the PGO profile (docs/engine-fork.md, Step 10).
- Memory and idle CPU: equal within run-to-run noise. A first round without the warm-up launch gave 1552 MB (fork) and 1265 MB (CDN) for 10 pages, with the GPU process at 618 and 495 MB: page content (ads, animations) moves this number more than the engine does.
- Size: dev builds keep local symbols (for readable crash stacks during patch work) and are not stripped. Official builds strip them (`enable_stripping = is_official_build`). Do not ship a dev framework.
- First launch after a rebuild: in the first round, the prebuilt's fresh-profile launch spent 1514 ms in `CefInitialize`, right after its framework was copied and re-signed; with a warmed framework the same fresh-profile launch took 186 ms. So the "fresh profile costs about 1.3 s more" result above is mostly the first launch of a new framework binary, not first-run profile work (guess: macOS scans the new 226–455 MB binary once).

### Bundle size

| Part | Size |
|---|---|
| Open.app (Release, all locales) | 329 MB |
| Chromium Embedded Framework binary (arm64 only) | 226 MB |
| CEF resources: 220 locale folders | 50 MB |
| CEF resources: `resources.pak` / `icudtl.dat` | 20 MB / 10 MB |
| CEF `Libraries/` (SwiftShader software GL 16 MB, Vulkan loader, sandbox) | 16 MB |
| OpenEngine.framework / app binary / 5 helpers | 1.3 MB / 2.0 MB / 48 KB each |
| **Open.app with `OPEN_KEEP_LOCALES="en"`** (clean clone, measured) | **279 MB** |

What can go:

- Locales: 219 of 220 `.lproj` folders, about 49 MB, with no visible change for an English UI (Open's own UI strings live in the app). `OPEN_KEEP_LOCALES="en"` does it at build time.
- SwiftShader (16 MB): only used when the GPU is unavailable (VMs, GPU process crash loops). Keep for v1; reconsider with crash data.
- The CEF binary: an `is_official_build=true` fork build (LTO, PGO) and turning off unused Chrome services (P5) shrink it. Arc's ArcCore arm64 slice is 239 MB for comparison (docs/re/arccore-engine.md §6).

## Build

- From a clean clone: `git clone …` then `OPEN_KEEP_LOCALES="en" tools/build.sh Release` took 1 min 20 s on this loaded machine with the CDN download and extraction cached in `~/Library/Caches/Open/cef` (2 min 8 s when the extraction is not cached yet). The result is 279 MB, passes `codesign -v --deep` (ad-hoc), leaves `git status` clean, and loads `https://example.com` (title read through the DevTools endpoint).
- `tools/fetch-cef.sh` (default `CEF_SOURCE=fork`) hands over to `tools/fetch-engine.sh --run` (docs/engine-fork.md), which copies the fork's recorded distribution into `Vendor/cef/`; then the wrapper is rebuilt. Exercised end to end on 2026-10-25: `tools/build.sh Release` against the fork took 57 s, the shell and feature suites pass on our framework (`results-shell-release-fork.json`, `results-features-alloy-fork.json`), and the Measurements section compares it with the CDN build. `CEF_SOURCE=cdn` switches back for comparisons.

## Bugs found and fixed on the way

- OpenKit `SnapshotStore.scheduleSave` crashed every app that called it: the debounced write closure was formed on the main actor, and Swift 6 traps when the background queue runs it (`_dispatch_assert_queue_fail` from `swift_task_checkIsolated`). Fixed with a `@Sendable` closure. The `openkit` CLI never hit it because it uses `saveNow`.
- CEF rejects a cache path under a symlinked folder (`/tmp` → `/private/tmp`) and silently falls back to in-memory storage. OpenEngine now resolves the user data folder first.
- With the Chrome bootstrap, Chromium can finish initializing before `applicationDidFinishLaunching`; the shell now builds windows at whichever comes first.
- AppKit's "reopen windows?" alert after a crash: Open restores from its own snapshot, so AppKit state restoration is off.
- Release builds hung page loads on the shared "Chromium Safe Storage" keychain item, which belongs to other Chromium-based apps and makes macOS ask for access. OpenEngine now uses its own item ("Open Safe Storage"), and ad-hoc signed builds use Chromium's mock key.
- The browser process crashed twice during the extension suite, inside the stripped CEF framework. Symbolicated with CEF's release symbols: CEF's zombie detector caught a message to a freed object in `CefBrowserPlatformDelegateNativeMac::CreateHostWindow()`, run from the asynchronous `CefBrowserHost::CreateBrowser` task. A page closed or released while its browser creation was still in flight freed the parent NSView that CEF uses later (it also leaked that browser). Pages now keep themselves alive from `CreateBrowser` to `OnAfterCreated` and close the new browser at once if they were closed meanwhile; they also stay alive until `OnBeforeClose`, and a released page parks CEF's view. A quit-time race (`oe_quitIfDone` after `shutdown`) was fixed too.

## Decisions for the lead

1. Approve the patch order P1 → P2 → P3 in [engine-patches.md](engine-patches.md) and assign P1 (largest, blocks the other two).
2. `chrome.windows` mapping: one Chrome window per Open window (proposed) or per Space.
3. Folders as `chrome.tabGroups`: yes or no.
4. Default profile folder: CEF always keeps the global context (the default profile) at `<root_cache_path>/Default` and ignores the `Profiles/Default/Engine` path that docs/plans/profiles.md §6.2 sets (verified: Chromium wrote `Profiles/Default/Preferences`). The shell therefore uses `Profiles/Default/` as the default profile's engine folder and `Profiles/<dir>/Engine/` for the others. Accept this, or make the default profile a non-global context (then `--load-extension` and Chromium-created windows go to an unused global profile)? Resolved 2026-10-25: `root_cache_path` is `<root>/Engine`, with `Engine/Default` for the default profile and `Engine/<dir>` for the others (docs/plans/profiles.md §6.2).
5. Until P1 lands, ship extensions in Alloy style (runtime works; `chrome.tabs`-dependent popups do not), or keep a Chrome-style fallback page for the Web Store and `chrome://extensions` (the shell does this today from View › Extensions)?
