# Welcome tab

`App/Welcome/WelcomeTab.swift` exposes
`WelcomeTab.insert(into: BrowserModel, spaceID: SpaceID) -> ItemID` for the
onboarding hand-off. Call it before creating the browser window. It inserts a
normal Today tab at index zero and selects it in existing model windows focused
on that Space. The caller must pass an existing Space. Help ▸ Open Basics selects
an existing Welcome tab in the current Space, including one in a folder or split,
or inserts one. It does not search another Space.

The tab stores `open://welcome` and `Welcome to Open` in the normal model. Session
save, close, archive, reopen, and import need no new schema or special record type.
`EngineWebContentHostFactory.makeHost` returns an App-owned native host before
asking for an engine context. Its normal engine creation, ensure, page-load,
popup, and navigation-policy paths refuse the internal scheme. External URL
intake already accepts only HTTP and HTTPS, so it rejects `open://welcome` before
queueing or creating a tab. The application registers no new URL scheme.

Navigating away through Cmd+L replaces the native host with an engine host in the
same model tab. The native URL is never added to engine history. Back starts at
the first web destination; use Help ▸ Open Basics to return. This is a deliberate
limit of the small content-host hook, rather than an extra history implementation.

The page uses native AppKit cards with original Core Animation drawings. Four
finite 8.5-second demonstrations play in order and stop. One one-shot timer
advances the playlist. It is invalidated while hidden and after completion. A
hidden playlist resumes its current card when the page becomes visible. Hover,
click, Return, Space, and the VoiceOver Replay action play one card and end the
playlist. No display link, polling task, video, audio, downloaded image, or repeating
animation is used. Other windows create no Welcome page or notification observers.
Window occlusion, minimization, application hiding, and removal from the selected
content pane stop animations. Interrupted frames are copied from the presentation
layers before removing the animations.

Reduce Motion uses the final drawing for each card and schedules no playlist or
completion timer. Automation builds also accept `OPEN_E2E_REDUCE_MOTION=1`; this
local hook can be unified with the intro's launch option by the Section 17 lead.
Cards form one keyboard and accessibility element each. Footer buttons open the
existing Essential Shortcuts and Settings windows. Text can wrap within a card so
all of the lead's exact copy remains readable in narrow windows.

The centered column is at most 960 pt wide. A 76 pt header and two 80 pt card-text
blocks leave room for both rows and the footer in a content viewport of 640 pt or
higher. The header starts 56 pt down through 820 pt content height, then 80 pt.
Illustrations shrink to 120 pt and grow up to the column's half-width at 16:10.
Their scenes scale uniformly and remain centered. The footer has 24 pt above it
and at least 32 pt below it. Shorter viewports retain native scrolling.

Illustrations use the content background with 4% white contrast in dark appearance
and 6% black in light. Mock sidebars use the Space's theme tint at 55% opacity;
plain rows use white at 14% or black at 10%. Active elements use `#3D6BFF` at 90%
with white text. Other mock text uses white or black at 75%. The only mock labels
are `+ New Tab` and the second Space name, `Home`.

The Debug/automation socket command `welcome` returns `visible`, `activeCard`
(1–4 or null), `playlist` (`playing`/`stopped`), `animating`, actual card AX labels
and actions, animation and pending-completion counts, played card order, native
host count, engine content creation count, and count of engine pages with internal
URLs. Its `layout` field reports actual viewport, document, card, text, and footer
frames, measured text size, rendered layer colors/labels, and scene scale. The
suite checks compact layout, contrast, permitted labels, and dark/light captures
at 1280×800 and 1000×700, plus the 640 pt content boundary. Actions:
`insert`, `replay card=N`, `hover card=N`, `reveal card=N`, and
`link link=shortcuts|settings`. Replay invokes the real accessibility action;
hover delivers an App-local tracking event. Invalid cards and hidden replay fail.
Each card keeps one tracking area. Repeated entered events beneath a stationary
pointer do not replay it; an exit or hiding the page resets the hover transition.
Automation can send `hover card=N phase=exit` before the next entered transition.

`welcome window=<window UUID>` reads an existing window without focusing it.
`windowState` includes the raw AppKit occlusion state, key/main state, visibility,
and minimization. The suite hides a playing window and verifies that restoring it
restarts the current card and finishes the playlist. It also covers Welcome with
a second owned Open window. If that cover does not change AppKit's occlusion
state, the row records INFO with the observed state and still requires the
playlist to finish after the cover closes. The harness moves only its own window
away from the read-only hardware pointer position before starting the playlist.

Run the real-App suite as:

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only welcome
```

Check the shared screen-priority flag before running. Screenshots and detailed
receipts go to `.re/handoff/sections/s17/c4/`. The suite uses temporary data and
cache roots, a local file page, and owned-process cleanup. It saves, resets,
and restores `open.settings.lastPane`, `open.library.lastSection`, and
`open.import.lastArcDir` in a `finally` path. The common runner preserves its
startup preference keys. It changes no Welcome preference keys.
