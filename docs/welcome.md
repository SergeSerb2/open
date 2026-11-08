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

The Debug/automation socket command `welcome` returns `visible`, `activeCard`
(1–4 or null), `playlist` (`playing`/`stopped`), `animating`, actual card AX labels
and actions, animation and pending-completion counts, played card order, native
host count, engine content creation count, and count of engine pages with internal
URLs. Actions: `insert`, `replay card=N`, `hover card=N`, `reveal card=N`, and
`link link=shortcuts|settings`. Replay invokes the real accessibility action;
hover delivers an App-local tracking event. Invalid cards and hidden replay fail.

Run the real-App suite as:

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only welcome
```

Check the shared screen-priority flag before running. Screenshots and detailed
receipts go to `.re/handoff/sections/s17/c4/`. The suite uses temporary data and
cache roots, a synthetic loopback site, and owned-process cleanup. It saves, resets,
and restores `open.settings.lastPane`, `open.library.lastSection`, and
`open.import.lastArcDir` in a `finally` path. The common runner preserves its
startup preference keys. It changes no Welcome preference keys.
