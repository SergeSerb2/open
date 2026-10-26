# Open scripting core (M7, Steps 1–4)

`OpenScripting` implements the dictionary, live-model wrappers, KVC accessors,
creation helpers, and command handlers from [the AppleScript plan](plans/applescript.md).
The appendix “Lead decisions” sets the scope. App wiring and the real Apple-event
acceptance pass (Steps 5–7) are separate work. This is not full scripting release acceptance.

`App/Resources/Open.sdef` is the only dictionary source. It was written from the
plan, without reading or copying another application's dictionary. Its application-tab
description uses “Little Open” per the lead decision. The package adds one product
and one target, with direct dependencies on `OpenModel` and `OpenCommands` only.
No existing target's source changed. No unit tests or third-party dependencies were added.

## API summary

The dictionary has one `Standard Suite` (`core`), four classes, and ten commands.
Application responds to `quit` without a separate command declaration.

| Object | Read API | Write API / verbs |
|---|---|---|
| application | windows, name, frontmost, version | make window; make tab creates a Little Open window; quit |
| window | id, name, index, closeable, minimizable, minimized, resizable, visible, zoomable, zoomed, active tab, active space, incognito, mode; tabs and spaces | index (1 only), minimized, visible, zoomed; make tab; close; mode/incognito only at creation |
| space | id, title; tabs | make tab; focus |
| tab | id, title, URL, loading, location | URL, location; select, go back, go forward, reload, stop, execute, close |

IDs use the model's `UUID.uuidString`, without a prefix. ID lookup parses UUIDs,
so lowercase input resolves the same object. Caches preserve wrapper identity.
Every read resolves the current model through `ScriptHost.shared.modelProvider`.
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

Tab creation defaults to `about:blank`, appends to Today, and selects the real new
tab. The insertion path never inserts the blank Cocoa wrapper into the model.
Initial title is ignored by the creation helper. `close` archives through
`BrowserModel.closeTab`; window close calls `NSWindow.close` and leaves model-window
removal to the App observer. Back/forward without history and stop while idle are no-ops.

Page commands address the named `ItemID` through `ScriptEngineBridge`. They never
use `CommandDispatcher`. The URL setter calls `navigate`; it does not change the
model URL or `pinnedURL`. Engine events supply the eventual URL, including redirects.
JavaScript returns text. H2 converts null/undefined to empty text, primitives to their
JavaScript string forms, and objects/arrays to JSON. Exceptions map to 1013 with the
first line limited to 300 characters; timeout maps to 1014. Missing engine maps to 1006.

Application tabs are write-only for Apple events. Direct Swift KVC returns `[]`.
The dictionary retains system `NSCreateCommand` and `NSCountCommand`. Per §6.7,
Step 6 must run A9 and A14 before deciding whether to add custom make/count classes.
The command file leaves the explicit hooks. Real-event result specifiers, application-tab
get/count error 1004, window/Space creation dispatch, and dictionary loading remain
unverified until that pass. The scratch insertion check verifies creation helpers and
KVC insertion, not a complete `make` Apple event.

## App hooks (H1–H4)

| Hook | App responsibility |
|---|---|
| H1 | In `applicationDidFinishLaunching`, fill the providers below after the model and window registry exist. Keep them current across model replacement. |
| H2 | Add `App/Scripting/AppScriptEngineBridge.swift`. It alone imports both `OpenScripting` and `OpenEngine`. Implement the protocol below. |
| H3 | Adopt `App/Resources/Open.sdef` and copy it to `Open.app/Contents/Resources/Open.sdef` through Copy Bundle Resources. Do not add a package copy. |
| H4 | Set `NSAppleScriptEnabled=true`, `OSAScriptingDefinition=Open.sdef`, and `NSAppleEventsUsageDescription="Scripts control Open windows, spaces, and tabs."` in the App Info.plist. Confirm `CFBundleName=Open` and the App's own bundle identifier. |

H1 provider types (main actor):

```swift
ScriptHost.shared.modelProvider: (() -> BrowserModel?)?
ScriptHost.shared.windowStateID: ((NSWindow) -> WindowID?)?
ScriptHost.shared.windowForState: ((WindowID) -> NSWindow?)?
ScriptHost.shared.makeWindow: ((Bool) -> WindowID?)?
ScriptHost.shared.makeLittleTab: ((URL?) -> ItemID?)?
ScriptHost.shared.engineBridge: (any ScriptEngineBridge)?
```

Use weak model capture. `windowStateID` must skip panels and non-browser windows.
Install both window mappings. Before that mapping exists, §5.2 requires the model-order
fallback for scratch checks; production must use AppKit windows in front-to-back order.
The lead's earlier `windowProvider` name is superseded by the concrete §5.1/§7.1
closures `windowStateID` and `windowForState`.

The App-owned model observer must call `ScriptHost.shared.purgeRemovedWrappers()`
on external removals and after model replacement. Scripting installs no observers.
The App window close observer removes `BrowserWindowState`. Window creation receives
the incognito Boolean; until supported, return nil for incognito (1010). Little Open
may remain unavailable (1011) until M4. Its current hook result must identify a tab
in the live model; a provider for tabs outside that model is deferred until M4 decides.

H2 protocol (all calls on the main actor):

```swift
func navigate(tabID: ItemID, to url: URL)
func goBack(tabID: ItemID)
func goForward(tabID: ItemID)
func reload(tabID: ItemID)
func stopLoading(tabID: ItemID)
func executeJavaScript(tabID: ItemID, script: String) throws -> String
```

Navigation is fire-and-forget. Wake sleeping content as needed. JavaScript must enforce
a ten-second timeout without pumping the main run loop. Throw `ScriptEngineError`
(`javascriptError(String)`, `timedOut`, `noLiveContent`). The protocol returns text,
so H2 owns value conversion. Scripts run with page privileges and can read tab titles
and URLs. Standard system Automation consent is the v1 gate; there is no extra
in-app permission prompt or speculative JavaScript toggle. Do not log script text.

After the App exists, run Steps 5–7, including `sdef Open.app`, Script Editor,
A1–A14/A16/A17 and R1–R3, then cold-relaunch/ID checks. A15 may report 1011 per the lead.
After dictionary changes, refresh the development bundle's registration as described
in plan §9.4, or remove and rebuild the development app. This task did not change
LaunchServices registration or run the App.

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

## Plan adaptations and limits

- The lead's naming decision replaces the stale “Little Arc” phrase in §3's application-tab description with “Little Open”. Terms and codes are unchanged.
- Foundation's SDK declares `NSObject.objectSpecifier` nonisolated and explicitly marks `NSScriptObjectSpecifier` non-Sendable. Swift rejects a main-actor override. Space/tab overrides therefore use a synchronous `MainActor.assumeIsolated` boundary and a local `nonisolated(unsafe)` result variable. This asserts the main-thread Cocoa call contract without making wrappers or specifiers Sendable. It is a narrow exception to §10's boundary guidance, required to build without warnings.
- Indexed KVC getters return optional wrappers so invalid indices can return nil and error 1000 without a crash. Explicit Objective-C insertion/removal names follow `NSScriptKeyValueCoding.h` (`insertIn<Key>:atIndex:` and `removeFrom<Key>AtIndex:`); the Swift names stay as specified. The final probe calls Cocoa `insertValue`/`removeValue`, not only the Swift methods.
- `removeFavorite` inserts at the start of Today. A second `moveNode(..., at: nil)` enforces the plan's end-of-destination rule for `topApp → unpinned` without editing OpenModel.
- Direct pin/unpin of a split pane remains refused by OpenModel; the plan gives no pane-separation sequence or dedicated error text for that case. No OpenModel source was changed.
- Q1–Q3 use the lead-approved defaults. Only index 1 is supported for window ordering. Little Open may return 1011; incognito creation may return 1010. System make/count integration remains for Step 6 as required.

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
