# Open AppleScript (M7, Steps 1–7)

`OpenScripting` implements the dictionary, live-model wrappers, KVC accessors,
creation helpers, and command handlers from [the AppleScript plan](plans/applescript.md).
The App hosts it through H1–H4. The appendix “Lead decisions” sets the scope.
External sender consent and the Script Editor hand check remain separate acceptance items.

`App/Resources/Open.sdef` is the only dictionary source. It was written from the
plan, without reading or copying another application's dictionary. Its application-tab
description uses “Little Open” per the lead decision. The library depends directly
on `OpenModel` and `OpenCommands`, with no engine dependency. No unit tests or
third-party dependencies were added.

## API summary

The dictionary has one `Standard Suite` (`core`), four classes, ten browser commands,
and an explicit binding for Cocoa's standard `set` command.
Application responds to `quit` without a separate command declaration.

| Object | Read API | Write API / verbs |
|---|---|---|
| application | windows, name, frontmost, version | make window; make tab creates a fresh Little Open window and returns its transient tab; quit |
| window | id, name, index, closeable, minimizable, minimized, resizable, visible, zoomable, zoomed, active tab, active space, incognito, mode; tabs and spaces | index (1 only), minimized, visible, zoomed; make tab; close; mode/incognito only at creation |
| space | id, title; tabs | make tab; focus |
| tab | id, title, URL, loading, location | URL, location; select, go back, go forward, reload, stop, execute, close |

IDs use the model's `UUID.uuidString`, without a prefix. ID lookup parses UUIDs,
so lowercase input resolves the same object. Caches preserve wrapper identity.
Sidebar-tab reads resolve the current model through `ScriptHost.shared.modelProvider`.
Little Open reads resolve `ScriptHost.shared.littleTab`, an App-owned transient provider.
A retained wrapper for a removed object reports error 1000. Missing model reports
1005, except application windows returns `[]` as required by §5.2.

Space tabs flatten Pinned, then Today, in depth-first folder order and split pane
order. Favorites are excluded. Window tabs concatenate Spaces in model order,
then append favorites from the active Space's profile. If there is no active Space,
the first Space supplies the profile; no Spaces means no window tabs.
Active selection resolves a split to its focused pane and a folder to its first tab.

`location` values are `topApp`, `pinned`, and `unpinned`. Moves use model commands
and append to the destination. Reassigning the same location does nothing. A split
pane cannot become a favorite (1003). The model also refuses direct pin/unpin moves
of individual split panes; the wrapper retains that model restriction rather than
separating panes implicitly. `make new space` is unsupported (1009).

Sidebar-tab creation defaults to `about:blank`, appends to Today, and selects the real new
tab. The insertion path never inserts the blank Cocoa wrapper into the model.
Initial title is ignored by the creation helper. Sidebar-tab `close` archives through
`BrowserModel.closeTab`; window close calls `NSWindow.close` and leaves model-window
removal to the App observer. Back/forward without history and stop while idle are no-ops.

Page commands address the named `ItemID` through `ScriptEngineBridge`. They never
use `CommandDispatcher`. The URL setter calls `navigate`; it does not change the
model URL or `pinnedURL`. Engine events supply the eventual URL, including redirects.
JavaScript returns text. H2 converts null/undefined to empty text, primitives to their
JavaScript string forms, and objects/arrays to JSON. Exceptions map to 1013 with the
first line limited to 300 characters; timeout maps to 1014. Missing engine maps to 1006.

Application tabs are write-only for Apple events. Direct Swift KVC returns `[]`.
`ScriptMakeCommand` and `ScriptCountCommand` replace the system command classes per
§6.7 after the review confirmed their gaps. Make retains Cocoa's placeholder/property
and insertion flow, records the real model wrapper produced by `ScriptCreation`, and
returns that wrapper's specifier. It restores the implicit `at` descriptor from the
Apple event because the locked dictionary omits that parameter. Space creation fails
with 1009 before Cocoa tries to find an application-level Space relationship.

Cocoa rejects a write-only `get` before calling its getter and normally returns -1723.
`ScriptHost` registers `ScriptGetCommand` for the existing implicit `core/getd` command
to return 1004 instead. It restores Cocoa's omitted implicit direct parameter before
checking the specifier and delegates all other reads to `NSGetCommand`. No `get` term
or code was added to the dictionary. The application getter also guards command reads,
while allowing the system creation path to inspect the empty collection.

The scratch NSApplication probe now verifies these Apple-event paths with the actual
Open.sdef. Steps 5–7 add production App wiring and real-engine Apple-event checks, described below.

## App hooks (H1–H4)

| Hook | App responsibility |
|---|---|
| H1 | In `applicationDidFinishLaunching`, install the providers below after the model and window registry exist. Keep them current across model replacement. |
| H2 | Add `App/Scripting/AppScriptEngineBridge.swift`. It alone imports both `OpenScripting` and `OpenEngine`. Implement the protocol below. |
| H3 | Adopt `App/Resources/Open.sdef` and copy it to `Open.app/Contents/Resources/Open.sdef` through Copy Bundle Resources. Do not add a package copy. |
| H4 | Set `NSAppleScriptEnabled=true`, `OSAScriptingDefinition=Open.sdef`, and `NSAppleEventsUsageDescription="Scripts control Open windows, spaces, and tabs."` in the App Info.plist. Confirm `CFBundleName=Open` and the App's own bundle identifier. |

H1 provider types (main actor):

```swift
ScriptHost.shared.modelProvider: (() -> BrowserModel?)?
ScriptHost.shared.windowStateID: ((NSWindow) -> WindowID?)?
ScriptHost.shared.windowForState: ((WindowID) -> NSWindow?)?
ScriptHost.shared.makeWindow: ((Bool) -> WindowID?)?
ScriptHost.shared.littleTab: (any LittleTabProviding)?
ScriptHost.shared.engineBridge: (any ScriptEngineBridge)?
```

Use weak model capture. `windowStateID` must skip panels and non-browser windows.
Install both window mappings. Before that mapping exists, §5.2 requires the model-order
fallback for scratch checks; production must use AppKit windows in front-to-back order.
The lead's earlier `windowProvider` name is superseded by the concrete §5.1/§7.1
closures `windowStateID` and `windowForState`.

The App-owned model observer calls `ScriptHost.shared.purgeRemovedWrappers()`
on external removals and after model replacement. Scripting installs no observers.
The App window close observer removes `BrowserWindowState`. Window creation receives
the incognito Boolean; until supported, return nil for incognito (1010). Little Open uses `LittleTabProviding` for creation, existence, URL/title/loading,
history availability and close. Its transient ID never enters the live model.
An absent provider or a refused creation returns 1011.

H2 protocol (all calls on the main actor):

```swift
func navigate(tabID: ItemID, to url: URL)
func goBack(tabID: ItemID)
func goForward(tabID: ItemID)
func reload(tabID: ItemID)
func stopLoading(tabID: ItemID)
func executeJavaScript(tabID: ItemID, script: String) throws -> String
```

Navigation is fire-and-forget. Wake sleeping content as needed. JavaScript enforces
a ten-second timeout without pumping the main run loop. Throw `ScriptEngineError`
(`javascriptError(String)`, `timedOut`, `noLiveContent`). The protocol returns text,
so H2 owns value conversion. Scripts run with page privileges and can read tab titles
and URLs. External senders need standard macOS Automation consent. View ▸ Developer ▸ Allow
JavaScript from Apple Events is also required and defaults to off. Off returns 1013
with `JavaScript from Apple Events is off. Turn it on in View ▸ Developer.`
The setting uses `open.developer.allowJavaScriptFromAppleEvents` (the page-platform
lead decision supersedes the original Q5 default). Script text is never logged.

For a fresh App build, repeat Steps 5–7, including `sdef Open.app`, Script Editor,
A1–A17 and R1–R3, then cold-relaunch/ID checks. A15 exercises real Little Open tabs.
After dictionary changes, refresh the development bundle's registration as described
in plan §9.4, or remove and rebuild the development app. The Step 1–4 task did not change
LaunchServices registration or run the App. See the App verification below for Steps 5–7.

## App hosting and verification (2026-11-05, America/Vancouver)

`App/Scripting/AppScriptEngineBridge.swift` is the only file importing both
OpenScripting and OpenEngine. H1 is installed after window composition from
`applicationDidFinishLaunching`. Weak closures read the current App model and window
registry, skip panels, and create real normal windows. The existing App observer purges
removed wrappers. The bundle copies the one `App/Resources/Open.sdef` through
`project.yml`, links OpenScripting, and sets all H4 Info.plist keys.

OpenEngine completes JavaScript on the main thread. A semaphore wait from a Cocoa
scripting handler would deadlock. H2 therefore calls `NSScriptCommand.suspendExecution`,
returns from the handler, and resumes the reply once on completion or after ten seconds.
The public protocol is unchanged. The AppleScript sender still waits for its text or
error. There is no nested run-loop pump. See Apple's
[resumeExecution contract](https://developer.apple.com/documentation/foundation/nsscriptcommand/resumeexecution(withresult:)).
The deadline runs only while a request is active. CDP's evaluation timeout bounds
synchronous loops; the Swift reply deadline also bounds unresolved promises. The reply
owns its readiness task and cancels it and its deadline on every finish path. Its
20 ms readiness wait also stops if the host closes or the App starts shutting down.
The engine callback holds the reply weakly, so a late or unresolved evaluation cannot
retain the command or resume it twice. H2 wakes the named
tab through its host/history map, including hidden tabs, without changing selection.
Engine events still own model URL updates and pinned URLs are preserved.

`execute` sends the script itself as CDP `Runtime.evaluate.expression`, with
`awaitPromise=true`, `returnByValue=false`, `timeout=10000`, and `userGesture=false`,
under a dedicated object group. The source is evaluated exactly once.
It does not use page-side `eval`, which fails under a strict Content-Security-Policy.
It sets `allowUnsafeEvalBlockedByCSP=false`: direct DevTools evaluation still works,
but an explicit `eval` inside the user's script must obey the page's policy. CDP
[defaults that bypass to true](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/js_protocol.pdl).
AppleScript execution grants no user activation; the plan requires none. The existing
Allow JavaScript from Apple Events setting still gates execution.

H2 converts primitives directly from the first CDP RemoteObject in Swift:
null/undefined become empty text; strings pass through; booleans become `true`/`false`.
Numbers use the shortest decimal form with JavaScript's decimal/exponent thresholds
and integer formatting. CDP's `unserializableValue` preserves NaN and infinities;
negative zero becomes `0`, as in JavaScript `String(-0)`. BigInt drops its trailing `n`.

CDP rejects symbols when `returnByValue=true` before exposing a description. Per the
lead's review-round decision, only object/function/symbol results take a second CDP
call, `Runtime.callFunctionOn` on the first result's `objectId`, with
`returnByValue=true` and no user gesture. Its fixed serializer returns
`JSON.stringify(this)` for objects/arrays and `String(this)` for symbols/functions.
It does not run the submitted source again or call the returned function. JSON
serialization preserves property order and has its normal `toJSON`/getter behavior.
Unserializable values (including cycles and nested BigInt) fail with plan error 1013.
The §8 error numbers stay unchanged.

Both calls share the original ten-second reply deadline. Since `callFunctionOn`
has no CDP timeout, the deadline also sends `Runtime.terminateExecution` if the
serializer is still running (for example a stuck `toJSON`). Every success, error,
and timeout releases the request's group with `Runtime.releaseObjectGroup`.
There is no second call for primitives and no second deadline task.

Review round 1 CSP proof: the exact `8f5b6aea` bridge unexpectedly passed
`document.title` and `1+1` on the `script-src 'self'` fixture with this engine.
CDP's default unsafe-eval bypass explains that result. A controlled run kept the old
wrapper and changed only `allowUnsafeEvalBlockedByCSP` to false; both expressions
then failed with error 1013 and `EvalError`. The final bridge uses that same false
setting and evaluates the source directly. The suite also checks that explicit
`eval` in the user's script remains blocked. These are separate receipts, not a
claim that the unmodified head failed the plain-execution CSP row:
`.re/review-174/negative-applescript.json` and
`.re/review-174/controlled-old-applescript.json`.

A held Space-contained tab reference must remain valid after `set location` moves it
to Favorites. Space unique-ID lookup now resolves a live model tab by stable ID;
Space enumeration still returns only its own tabs. The first real A12 run exposed this
bug. Closed IDs still return 1000. Application-tab read/count messages match plan §8.

The `applescript` e2e suite uses a fresh data/cache root, local HTTP fixtures, the real
bundled dictionary, real App windows and pages, and actual Apple events. It runs the
A-checks and Raycast query shapes, then quits, relaunches, and repeats them while
checking restored IDs. Provider-unavailability fixtures cover 1005/1006/1012 without
replacing the engine. Every shared preference is reset and restored in `finally`.
The `page` suite D4 uses the same Apple-event check for off → on → off.

External `osascript` was attempted against this build's exact bundle path and timed
out after 12 seconds. Read-only `AEDeterminePermissionToAutomateTarget` with
`askUserIfNeeded=false` returned **-1744** (consent required). No `tccutil`, consent DB,
signing workaround, or system settings change was used. Apple's
[Automation consent guidance](https://developer.apple.com/videos/play/wwdc2019/701/?time=2199)
requires consent for control of another app. Its
[entitlement exception](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
for self/same-team events is not an external TCC grant.

The authorized fallback is automation-build-only `applescript`: an in-process
`NSAppleScript` on a serial queue sends events to **current application**, so another
Open instance cannot be addressed. It compiles using this bundle's terminology and
executes through normal Cocoa scripting handlers. It does not call wrappers or the
engine directly. External osascript/JXA and the Script Editor check stay BLOCKED until
the user supplies consent. A self-scripting PASS is not an external-sender PASS.

Historical #174 limits: incognito creation returned 1010 and app-level tab creation
returned 1011. The Little Open provider below replaces that creation limit. Window
index supports bringing a window to front with 1 and returns 1007 for other values.

Review-round Debug scripting acceptance: **136 PASS, 0 FAIL, 2 TCC BLOCKED**,
with no focus interruptions and clean owned-process cleanup. Receipt:
`.re/review-174/final-applescript.json`. This includes strict-CSP execution, blocked
explicit eval, both gesture checks with inactive preconditions, single source
evaluation, property order, `toJSON`, symbol/function text, and cyclic/nested-BigInt
errors. Never-settling promise: 10.013 s at load 8.22/8.62/12.00. Stuck serializer
(after a 250 ms awaited promise): 10.005 s at load 8.21/8.60/11.95. Both returned
1014, and the next execute returned `42`. The configured deadline stays ten seconds.

Other review-round Debug acceptance on the same App source:

| Suite | Result | Local receipt |
|---|---|---|
| `page` Chrome | 85 PASS, 0 FAIL; 4 existing BLOCKED, 1 DEFERRED; all D4 rows PASS | `.re/review-174/final-page.json` |
| `features` Chrome, candidate attempts 1 and 2 | 18 PASS, 1 FAIL: Widevine CDM unavailable | `.re/review-174/first-features.json`, `.re/review-174/final-features.json` |
| `features` Chrome, unchanged `origin/main` at `8bd3aadb` | 17 PASS, 2 FAIL: identical Widevine result plus PiP gesture refusal | `.re/review-174/main-features.json` |

All runs had clean owned-process cleanup and no focus interruptions. Both candidate
attempts and unchanged main reported no downloaded CDM, unsupported key system, and
no playback. The `feature_checks` function is byte-identical between the candidate
and main; both used engine `f34400e7`. Widevine remains a FAIL. Main also refused Picture-in-Picture for a missing user gesture;
both candidate runs passed that row.
Full `verify-all` and Release verification were not rerun for this review fix; the
lead owns the merge gate. No new shared-file hook or open design question remains.

Original hosting verification at `8f5b6aea`, before the review fix, with engine
`f34400e7` (M5 built-in 2x main display):

| Check | Result | Local receipt |
|---|---|---|
| Debug build + `sdef` + H3/H4 bundle values | PASS; four class codes and ten command codes match | `.re/scripting-final-debug-build.log`, `.re/results-applescript-final-debug.json` |
| Debug `applescript`, warm + cold | 90 PASS, 0 FAIL; external osascript/JXA 2 BLOCKED | `.re/results-applescript-final-debug.json` |
| Release build (`OPEN_AUTOMATION=1`) + `applescript`, warm + cold | 90 PASS, 0 FAIL; external osascript/JXA 2 BLOCKED | `.re/scripting-release-build.log`, `.re/results-applescript-final-release.json` |
| `features` Chrome | 19 PASS, 0 FAIL | `.re/results-features-final-chrome.json` |
| `shell` Chrome | 7 PASS, 0 FAIL | `.re/results-shell-final-debug.json` |
| `page` Chrome | 85 PASS, 0 FAIL, 4 existing BLOCKED, 1 DEFERRED; no focus interruptions; D4 PASS via self Apple events | `.re/results-page-final-chrome.json` |
| Negative gates | H1 absent → window count 0 (A1 fails); gate bypassed → off/on/off returns NO ERROR/3/NO ERROR (D4 fails) | `.re/scripting-negative-results.json` |
| Automation input / failed-flow cleanup | 1 MiB accepted, one byte over refused; script failure after two real windows → 0 windows / 0 processes | `.re/scripting-negative-results.json` |

Timeout receipts: Debug 10.016 s at load 11.64/10.61/12.74; Release 10.019 s at load 12.80/14.44/14.58.
The configured reply deadline is ten seconds. Source text stayed out of App logs.
Hidden frozen and discarded tabs returned the expected page title without changing
selection. All five suite receipts report clean owned-process cleanup. The four `page`
blocks are notification delivery, clients.openWindow, translation assets, and incognito
Capture; smart zoom is deferred. These remain separate from the scripting result.
Full package/release CLI verification is recorded in this change's PR.

A7/R3 now use Raycast's `first space … whose title …` query form. Both final
90-check Debug/Release runs include those variants. They also restore a typed
1,000-entry host array (253 characters per entry) through the closed-App fallback,
then read it through UserDefaults after relaunch. The fallback uses per-key
CFPreferences with in-process binary property-list data; values stay out of argv
and are not limited by exec's argument ceiling. Array/dictionary negative proofs
show the previous string fallback fails the type check.

Full verification: 18 PASS, 3 known built-in-display FAILs, 1 INTERRUPTED on the
first run. The focused Site Control rerun passed after the foreground hold cleared,
so the accepted combined result is **19 PASS, 3 FAIL (machine: built-in display main)**.
The interrupted attempt is retained separately. The package build reports 0 warnings
and 0 errors. `commands-dump` remains missing/extra/different 0/0/0, allowedMissing 11.
Receipts: `.re/verify-all-final/summary.txt`, `.re/verify-sitecontrol-rerun/summary.txt`.

### Script Editor and external sender hand checks

These checks remain BLOCKED by macOS Automation consent (-1744) in [#174](https://github.com/SergeSerb2/open/pull/174). Its final `applescript` suite records 137 PASS / 2 external-consent BLOCKED; self-scripting does not replace these user checks. No agent desktop input:

1. In Script Editor, choose File ▸ Open Dictionary and select the built
   `build/Debug/Open.app`. Confirm Standard Suite, window/tab/space, and all ten
   browser commands and standard set, including execute/javascript and go forward.
2. Launch a separate instance with a fresh data directory. In Script Editor use
   `tell application "/absolute/path/to/build/Debug/Open.app"` and run A1–A14,
   A16–A18 and R1–R3 from plan §11. Allow the macOS Automation prompt if desired.
   Address this bundle path, not an installed app by name.
3. With Allow JavaScript from Apple Events off, `execute active tab of window 1
   javascript "1 + 2"` must error 1013 with the exact off message above. Turn the
   setting on in the test App; the same event must return text `3`. Restore the setting.
4. Quit only the test instance. Confirm Script Editor/JXA results separately from
   the automated self-scripting receipts. Include A15 and the Little Open checks below.
   Incognito creation remains a 1010 limit.

### Arc hand checks (PB4, 2026-11-12)

Three questions only Arc can answer (execute result and error, `make new space`, `location` ordering).
The user runs them in Script Editor against Arc; the list is in
[docs/re/applescript-consent.md](re/applescript-consent.md#arc-hand-checks-for-the-user-do-not-run-as-an-agent).
Consent parity facts are in the same file; `H5_consent_declarations` keeps Open's declarations equal to Arc's.

## Little Open tab references (2026-11-07)

`make new tab with properties {URL:"https://example.com/"}` on the application
creates a fresh Little Open window, including when that URL is already open.
The returned `tab` uses the coordinator session's transient tab ID. It is valid
until that window closes. No sidebar tab, Space or model window is created.
With no URL, `make new tab` returns a reference to Little Open's blank bar with
URL `about:blank`. Setting its URL starts navigation and opens the page state.

Supported properties are `id`, `URL`, `title` and `loading`. `URL` is writable.
Supported verbs are `close`, `reload`, `go back`, `go forward`, `stop` and
`execute … javascript`. JavaScript uses the same off-by-default Apple-events
gate, CSP-safe evaluation, value conversion and shared ten-second deadline as
sidebar tabs. Navigation can target a blank window before its Browser exists.

`select`, `location` reads/writes and explicit Space/window containment return
1009 with a Little Open not-supported message. A closed reference returns 1000
for property reads, setters and every verb, including a second close. Little Open
references are not persisted across launches. Application `tabs` enumeration and
count remain write-only (1004); only unique-ID reference resolution is available.

Cocoa checks write-only access before resolving both reads and command receivers.
`ScriptGetCommand` reads the named transient tab's supported properties directly.
`ScriptTransientTabCommand` resolves only an application unique-ID receiver; normal
receivers keep Cocoa's path. `ScriptSetCommand` handles transient URL writes and
delegates normal writes to NSSetCommand. The dictionary binds the seven tab verbs
to that receiver class; terms, argument types and event codes stay unchanged.
Cocoa's existing `core/setd` command is declared explicitly in the sdef so its
receiver metadata survives decoding. Rebuilding that description at runtime can
reject ordinary setters before dispatch, or crash while coercing the direct
argument. No custom runtime registration is used for `set`.

Automation builds also accept `OPEN_AUTOMATION_SCRIPTING_PREFLIGHT=/absolute/receipt.json`.
With an isolated `--user-data-dir`, this runs real self-sent Apple events against
the App's model before creating a native window or starting Chromium. It checks a
location round trip, invalid URL/index errors, and a stale transient URL write.

`tools/e2e/applescript_littleopen.py` runs these flows through the actual bundled
dictionary and Cocoa Apple events within `applescript`, on warm and cold launches.
It checks the specific native window through `little-open-state`, page values,
loading and request counts, and unchanged sidebar-tab IDs. Shared defaults are
reset and restored in `finally`. External Automation consent remains a separate
user gate.

Final Little Open acceptance on M5 (`ad84b634`, including main `1714a22e`;
engine distribution `c03a5109fc0d8157…`):

| Check | Result | Local receipt |
|---|---|---|
| `applescript`, warm and cold | 208 PASS, 0 FAIL; external osascript/JXA 2 BLOCKED; zero interrupted attempts; cleanup PASS | `.re/applescript-littleopen/final-functional/results-applescript-debug.json` |
| `littleopen` | M5 39 PASS, 0 FAIL; zero interrupted attempts; cleanup PASS | `.re/applescript-littleopen/final-functional/results-littleopen-debug.json` |
| `page` / D4 | M5 85 PASS, 0 FAIL; 4 existing BLOCKED, 1 DEFERRED; all 3 D4 rows PASS; zero interrupted attempts; cleanup PASS | `.re/applescript-littleopen/final-functional/results-page-chrome.json` |
| Core/setd negative → positive | M1 WIP `6c7fec9f` crashed during receiver decoding; fixed M5 App sends real events with zero native windows, exits 0; normal URL setters also pass warm/cold A11 | `.re/applescript-littleopen/set-description-proof.json` |
| Old creation path | M1 unchanged `df4767ad` returns 1011 on warm and cold application make; the new A15 creation gate refuses that result | `.re/applescript-littleopen/old-code-negative.json` |

A15 verifies the returned ID against the specific native session, URL/title/loading,
unchanged model-tab IDs, fresh same-URL creation, all supported page verbs, the JS
permission gate and strict CSP, every stale property/verb/setter returning 1000,
unsupported operations returning 1009, and blank-bar navigation into page mode.
The single deadline check returned 1014 after 10.021 s at load 50.02/28.46/21.09;
its configured deadline remains ten seconds, and a following execute succeeds.
The M1 crashed build was not relaunched. External sender consent remains open.

## Step 1–4 verification (2026-10-25, America/Vancouver)

All package builds ran inside `Packages/OpenKit` with
`nice -n 10 swift build -c release -j 6`, in a new process session.
Final Step 2, 3, and 4 builds reported no warnings or errors and built the existing targets.
The throwaway probe lives under `/tmp/script-check/`, outside the repo. It links the
built release libraries and exercises real wrappers, KVC, `NSScriptCommand`, and
`BrowserModel`, with a counting archive sink. It does not mock an engine or drive the desktop.

| Step | Acceptance check | Result |
|---|---|---|
| 1 | `xmllint --noout App/Resources/Open.sdef` | PASS |
| 1 | Exact `ID  `, `URL `, `CrSuFwd ` padding | PASS: 3 ID properties, 1 URL property, 1 forward command |
| 1 | Generate terms from the new file and compare names/codes/access/Cocoa bindings to §3 | PASS, with lead naming override; generated table below |
| 1 | Opening worktree clean; dictionary was the only new file before Step 2; no bundle path or copied file in the diff | PASS |
| 2 | Release build, zero new warnings; existing targets build | PASS (1.59 s final incremental build) |
| 2 | Scope: only manifest plus new scripting sources, in addition to Step 1 dictionary | PASS; manifest adds 2 lines; no existing target source modified |
| 3 | Two-Space read probe: pinned + Today + nested folder + split; counts, titles, locations | PASS: Work=6, Fun=2; exact output below |
| 3 | Release build stays clean | PASS (2.46 s) |
| 4 | Select a Fun tab and observe window active tab | PASS |
| 4 | `unpinned → pinned → topApp → unpinned` via KVC setter | PASS |
| 4 | Close removes and archives the tab | PASS: one `.closed` archive entry; browser window retained |
| 4 | Release build stays clean | PASS (3.50 s; final selector/error-logging refinement build 3.74 s, zero warnings) |

Additional dictionary checks: `sdp -f h` produced a Scripting Bridge header without
diagnostics. `sdef` successfully extracted the dictionary from a metadata-only temporary
bundle under `/tmp/script-check/Dictionary.app`; the extracted XML passed `xmllint`.
That bundle has no executable and was never launched. It is not the Step 5 Open.app check.
Direct `sdef` on the standalone XML failed with error -192 because `sdef` takes an
application bundle. An exploratory `sdef -h` was treated as a path and returned -43.
`sdp -f st` also generated scratch suite/terminology files, but reported unknown
implicit `item` (four times) and undeclared `quit` (once), both present in the prescribed
§3 dictionary. These diagnostics remain visible for the App integration task; the
normative dictionary was not expanded to suppress them.

Exact final extended probe output:

```text
space tab counts: Work=6, Fun=2
Work titles: Work Pinned, Folder Child, Nested Child, Work Today, Split Left, Split Right
Fun titles: Fun Pinned, Fun Today
window titles: Work Pinned, Folder Child, Nested Child, Work Today, Split Left, Split Right, Fun Pinned, Fun Today, Favorite
locations: topApp, pinned, unpinned
read checks: split focus, folder selection, wrapper identity, UUID lookup, index 0 PASS
STEP 3 PASS
select Fun Today: active Space=Fun, active tab=Fun Today PASS
location round-trip: unpinned -> pinned -> topApp -> unpinned PASS
close Fun Today: removed=true, archive entries=1, reason=closed, window retained=true PASS
KVC insertion: real tab appended and selected, blank ID not inserted PASS
KVC errors: invalid location=1002, invalid URL=1001, no engine=1006, split favorite=1003, mode/incognito=1008, index=1007, missing ID/index=1000 PASS
commands: navigation/stop no-op, reload without engine=1006, empty JS=1002, stale tab=1000, focus preserves selection PASS
empty/not-ready: empty window list; getter error=1005 PASS
STEP 4 PASS
```

The extended probe also checks the real KVC insertion path (new model ID, appended and
selected), invalid URL/location, missing engine, split-pane favorite refusal, mode and
incognito guards, invalid index and ID, history/stop no-ops, missing JavaScript,
stale wrapper command errors, focus preserving selection, and empty/not-ready states.
It does not verify navigation or JavaScript against live web content; H2 and Steps 5–7 own that.

Probe compile/run (single scratch file; no extra package build):

```sh
cd Packages/OpenKit
nice -n 10 xcrun swiftc -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -O -target arm64-apple-macos26.0 \
  -I .build/out/Products/Release -L .build/out/Products/Release \
  -lOpenScripting -lOpenModel /tmp/script-check/Probe.swift \
  -o /tmp/script-check/step4-probe
/tmp/script-check/step4-probe
```

The paths above reflect this Mac's SwiftPM build layout. Probe source and outputs
remain in `/tmp/script-check/`; they are not installed as a product or test target.

## PR #19 review verification (2026-10-25, America/Vancouver)

The same Step 3–4 probe was rebuilt and rerun against the updated release libraries.
It finished with `STEP 3 PASS` and `STEP 4 PASS`. The additional throwaway probe at
`/tmp/script-check/ReviewProbe.swift` uses a real `NSApplication` in
`/tmp/script-check/ReviewProbe.app`, the current `Open.sdef`, real `BrowserModel`
instances, Cocoa KVC insertion, and in-process `NSAppleScript`. Its window-creation
hook adds a real model window; it does not create or show an `NSWindow`. Activation
is prohibited. No desktop input, Arc launch, engine substitute, or unit tests were used.
This verifies the scripting core through Cocoa, not the production App or live pages.

| Finding | Fix | Probe result |
|---|---|---|
| 1. Window/Space creation cannot instantiate wrappers | Public blank placeholder initializers; window insertion calls `ScriptCreation.makeWindow`; Space insertion and make call `makeSpace` | PASS: NSAppleScript make-window returns a real model window ID; unavailable incognito = 1010; make-space at window/application = 1009. Direct Cocoa KVC insertion also returns 1010/1009. |
| 2. Make-tab returns a phantom ID | `ScriptMakeCommand` returns the real wrapper's specifier after insertion and restores the implicit `at` location | PASS: held new-tab reference returns `https://example.com/`; window creation returns the live ID. Space/window targets, end-of-tabs insertion, and nested window tell context pass; real new tab is selected. |
| 3. Application-tab get/count silently return empty | `ScriptCountCommand`, application getter guard, and `ScriptGetCommand` for the existing implicit get command | PASS: NSAppleScript get/count application tabs both return 1004; window/Space reads and counts still succeed; direct Swift KVC returns `[]`. |
| 4. Creation title fails; setters read the absent placeholder tab | Placeholder title stores its value for creation only; URL/location and window setters guard placeholders | PASS: make with URL/title succeeds, initial title is ignored. KVC URL/title/location setters cause no missing-object error; real tab appends to Today with location `unpinned`. |
| 5. Favorite move ignores model refusal | Check `addFavorite` and report 1003 on false or no valid target | PASS: a real model with an absent destination profile refuses the move; KVC and NSAppleScript return 1003 and retain the original parent. Existing split-pane refusal still passes. |
| 6. Favorite ID stops resolving after focus changes | Window unique-ID lookup searches favorites in every model profile | PASS: held favorite specifier resolves after switching profile focus; both windows and lowercase UUID lookup resolve it; NSAppleScript reads its URL. Enumeration still follows the active profile. |
| 7. No-window Space fallback cannot resolve | Remove the application-level name fallback; keep the last valid window-container specifier or return nil | PASS: removing every window retains the prior specifier; a live Space with no prior window container returns nil. No application-level Space key was added. |
| 8. Off-main specifier access can trap | Check the main thread before entering the actor boundary; return nil and emit a debug-only diagnostic off main | PASS: a real background thread requests window/Space/tab specifiers and gets nil without a trap. The permitted release build omits the debug-only log. |

The new probe also verifies default `about:blank`, invalid creation URL (1001),
normal window hook unavailable (1012), and Little Open unavailable (1011).
An out-of-range Space index is rejected by Cocoa with -1719 before an insertion
accessor runs; direct invalid KVC indices retain their existing 1000 behavior.
The probe exits 0 with `REVIEW PROBE PASS`. macOS emits
`sandbox_extension_issue_file_to_process failed … (Operation not permitted)` while
AppleScript loads the scratch bundle's terminology; compilation, execution, and all
assertions still pass. Initial exploratory probes exposed the missing implicit make
location and get parameter; both were fixed before the final passing run.

The final package build uses only the required release command, in its own process
session, and reports no warnings or errors. No OpenModel/OpenCommands source, package
manifest, engine source/build, or production App wiring changed. XML validation passes.
A parsed comparison against the prior dictionary confirms that only make/count's
`cocoa class` values changed (`ScriptMakeCommand`, `ScriptCountCommand`); all terms,
codes, access modes, properties, and relationships are identical.

Review probe compile/run (after the release build, from `Packages/OpenKit`):

```sh
nice -n 10 xcrun swiftc -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -O -target arm64-apple-macos26.0 \
  -I .build/out/Products/Release -L .build/out/Products/Release \
  -lOpenScripting -lOpenModel /tmp/script-check/ReviewProbe.swift \
  -o /tmp/script-check/ReviewProbe.app/Contents/MacOS/review-probe
/tmp/script-check/ReviewProbe.app/Contents/MacOS/review-probe
```

Probe sources and final output remain outside the repo in `/tmp/script-check/`:
`Probe.swift`, `review-step4-output.txt`, `ReviewProbe.swift`,
`review-events-output.txt`, `review-events-stderr.txt`, and `review-build.log`.
The scratch bundle's Info.plist supplies `NSAppleScriptEnabled=true` and
`OSAScriptingDefinition=Open.sdef`; its Resources directory contains the current
Open dictionary. It was executed directly; no LaunchServices registration was changed.

## Plan adaptations and limits

- The lead's naming decision replaces the stale product name in §3's application-tab description with “Little Open”. Terms and codes are unchanged.
- Foundation's SDK declares `NSObject.objectSpecifier` and command overrides nonisolated and explicitly marks scripting types non-Sendable. Swift rejects a main-actor override. Each specifier override first checks `Thread.isMainThread`, returns nil off main, and logs only in debug. Only a checked main-thread call enters the synchronous `MainActor.assumeIsolated` boundary with a local `nonisolated(unsafe)` result. Command overrides use the same checked boundary and a local command reference; no wrapper or Foundation scripting object gains Sendable conformance.
- Indexed KVC getters return optional wrappers so invalid indices can return nil and error 1000 without a crash. Explicit Objective-C insertion/removal names follow `NSScriptKeyValueCoding.h` (`insertIn<Key>:atIndex:` and `removeFrom<Key>AtIndex:`); the Swift names stay as specified. The final probe calls Cocoa `insertValue`/`removeValue`, not only the Swift methods.
- `removeFavorite` inserts at the start of Today. A second `moveNode(..., at: nil)` enforces the plan's end-of-destination rule for `topApp → unpinned` without editing OpenModel.
- Direct pin/unpin of a split pane remains refused by OpenModel; the plan gives no pane-separation sequence or dedicated error text for that case. No OpenModel source was changed.
- Q1–Q3 use the lead-approved defaults. Only index 1 is supported for window ordering. Little Open may return 1011; incognito creation may return 1010. The review required §6.7's custom make/count classes now; the Cocoa probe also required interception of the existing implicit get command. App acceptance is recorded below; external Automation consent remains separate.
- The review supersedes §5.4's proposed no-window name fallback: the application has no Space relationship, so a Space now returns its last valid specifier or nil. A retained specifier can still refer to a closed window; no alternate application-level container is fabricated.

During development, compiler failures exposed the Foundation isolation restrictions
above and were fixed before the clean builds. The first session-launch attempt called
`setsid()` from a process-group leader and failed before building; builds then used
`subprocess.Popen(..., start_new_session=True)`. One build command was accidentally
invoked at the repo root and failed before compilation because no Package.swift was
there; all successful builds ran in `Packages/OpenKit` with the required command.

## Generated dictionary term table

This table was generated by parsing `App/Resources/Open.sdef`. Omitted property/element
access is `rw`. `_` displays a literal space in a code. Empty code cells belong to
relationships or `responds-to`, whose target supplies the code.

| Kind | Container | Name | Code (`_` = space) | Access |
|---|---|---|---|---|
| suite | dictionary | Standard Suite | `core` | — |
| command | Standard Suite | set | `coresetd` | — |
| parameter | set | to | `data` | — |
| command | Standard Suite | make | `corecrel` | — |
| parameter | make | new | `kocl` | — |
| parameter | make | with properties | `prdt` | — |
| command | Standard Suite | count | `corecnte` | — |
| parameter | count | each | `kocl` | — |
| class | Standard Suite | application | `capp` | — |
| element | application | window | `` | rw |
| property | application | name | `pnam` | r |
| property | application | frontmost | `pisf` | r |
| property | application | version | `vers` | r |
| responds-to | application | quit | `` | — |
| element | application | tab | `` | w |
| command | Standard Suite | close | `coreclos` | — |
| class | Standard Suite | window | `WiND` | — |
| element | window | tab | `` | rw |
| element | window | space | `` | rw |
| property | window | id | `ID__` | r |
| property | window | name | `pnam` | r |
| property | window | index | `pidx` | rw |
| property | window | closeable | `hclb` | r |
| property | window | minimizable | `ismn` | r |
| property | window | minimized | `pmnd` | rw |
| property | window | resizable | `prsz` | r |
| property | window | visible | `pvis` | rw |
| property | window | zoomable | `iszm` | r |
| property | window | zoomed | `pzum` | rw |
| property | window | active tab | `acTa` | r |
| property | window | active space | `acSp` | r |
| property | window | incognito | `inco` | rw |
| property | window | mode | `mode` | rw |
| responds-to | window | close | `` | — |
| command | Standard Suite | select | `CrSelect` | — |
| command | Standard Suite | go back | `CrSuBack` | — |
| command | Standard Suite | go forward | `CrSuFwd_` | — |
| command | Standard Suite | reload | `CrSuRlod` | — |
| command | Standard Suite | stop | `CrSustop` | — |
| command | Standard Suite | execute | `CrSuExJa` | — |
| parameter | execute | javascript | `JvSc` | — |
| class | Standard Suite | tab | `tAbB` | — |
| property | tab | id | `ID__` | r |
| property | tab | title | `pnam` | r |
| property | tab | URL | `URL_` | rw |
| property | tab | loading | `ldng` | r |
| property | tab | location | `loca` | rw |
| responds-to | tab | select | `` | — |
| responds-to | tab | go back | `` | — |
| responds-to | tab | go forward | `` | — |
| responds-to | tab | reload | `` | — |
| responds-to | tab | stop | `` | — |
| responds-to | tab | execute | `` | — |
| responds-to | tab | close | `` | — |
| command | Standard Suite | focus | `SpaFocus` | — |
| class | Standard Suite | space | `sPaC` | — |
| property | space | id | `ID__` | r |
| property | space | title | `pnam` | r |
| element | space | tab | `` | rw |
| responds-to | space | focus | `` | — |
