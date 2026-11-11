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

The page uses native AppKit cards with real miniature Open views and original room artwork. Four
finite demonstrations (4.2, 4.0, 6.8 and 4.0 seconds) play once in order and stop.
The whole pass has a 20-second budget; its planned length is 19 seconds. Only
holds are shortened; native travel durations and easing stay the same. One one-shot timer
advances the playlist. It is invalidated while hidden and after completion. A
hidden playlist stays stopped when the page becomes visible again. Hover,
click, Return, Space, and the VoiceOver Replay action play one card and end the
playlist. No display link, polling task, video, audio, or repeating animation is used.
Favicons use the bounded existing fetch/store path. Other windows create no Welcome page or notification observers.
Window occlusion, minimization, application hiding, and removal from the selected
content pane stop animations. Interrupted frames are copied from the presentation
layers before removing the animations.

Reduce Motion uses the final drawing for each card and schedules no playlist or
completion timer. Automation builds also accept `OPEN_E2E_REDUCE_MOTION=1`; this
local hook can be unified with the intro's launch option by the Section 17 lead.
Cards form one keyboard and accessibility element each. Footer buttons open the
existing Essential Shortcuts and Settings windows. Text can wrap within a card so
all of the lead's exact copy remains readable in narrow windows.

The room lights the header from a small doorway at the upper right. The hero
stays at the upper left. A centered, capped column holds four cards and two
32-point native footer buttons. Card art has a common 12-point top/side inset and
an eight-point radius. Miniatures fill that area; short viewports scroll.

`OnboardingMiniature` shares the real sidebar, Favorite grid, tab rows, command
bar, pager and split divider. Each card has a different Space palette and
composition: a command bar opens over New tab; Pin lifts a native row over the
divider; Spaces swipes two real windows; Split divides the content. Spaces settles
to one full window. The second window exists only for finite playback. Every
miniature uses a throwaway model with no engine contents. The editorial page has
an original landscape, a title, and at most two short text lines per block.

All resting card borders are identical. Only hover or keyboard focus adds the
one-point warm outline. Active playlist state alone does not change the border.
The native demo rows use a local font/color override for readability at small
scale; normal browser rows retain their own typography and theme. Descendants
of a miniature stay out of the keyboard/VoiceOver loop: each card is one Replay
action. At rest all native layer animations are removed, including sidebar
material/row transitions.

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
leaves the page stopped until an explicit replay. The miniaturized page has no
pending animation, completion timer, or theme display update within one second,
and stays below 1% App CPU over five seconds in Release. The suite also covers
Welcome with a second owned Open window. If that cover does not change AppKit's
occlusion state, the row records INFO with the observed state. The harness moves only its own window
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

Welcome text uses each actual, opaque content surface. Theme foreground tokens
are seeds, not guaranteed content text colors. `WelcomeTextColors` composites
alpha in sRGB, computes WCAG relative luminance with the sRGB transfer function,
and keeps a seed that passes. A failing seed changes only OKLab lightness toward
black or white, with a 0.2 contrast margin where the surface allows it. Header
text is measured on the page background; card text is measured on the card fill.
Secondary text meets 4.5:1 and primary text has stronger contrast. The small card
titles also use 4.5:1, above the requested 3:1 heading minimum. Colors update on
theme, app/view appearance, and key-state changes. Cached inputs prevent layout
or animation frames from repeating the color math. Welcome adds no inactive tint.

The `W36_contrast_*` rows cover light/dark Space themes × Light/Dark app appearance
× active/inactive windows. The existing `appearance` command overrides only
`NSApp.appearance`; the user's macOS setting stays unchanged. An owned second
Open process establishes the inactive case without touching a user's app. Each
row requires the expected theme, appearance, app activation, and native key state,
plus a real window-server capture. The capture's ICC profile is converted to sRGB
before sampling. Each label's modal background is its surface; the median of 12
strongest glyph-core pixels is its ink. The gate checks both headers, all four
card titles and bodies, and the illustration labels. Its three summary ratios
are the lowest header, title, and body ratios, not a selected best card. Glyph
sample coordinates and RGB values are retained in `.re/welcome-contrast/` with
all eight PNGs. Run just this matrix with
`OPEN_E2E_WELCOME_CONTRAST_ONLY=1 tools/e2e/engine_e2e.py --only welcome` under the
same screen lock and priority rules. The temporary old-palette build patch and
negative receipt also stay in `.re/`; no mutation switch ships in the App.

Footer button labels and native miniature row labels are mandatory pixel
assertions in every contrast case. The checker samples their real glyph-core
pixels after ICC-to-sRGB conversion. Title contrast correction stays local to
the miniature: it does not change the user's real sidebar palette. The New tab
command bar, Pin row, Space title and split-row labels all remain real components.

See [the eight-case contrast evidence](welcome-contrast.md) for the captured
ratios, the original-color failure control, and two representative App images.

[Room Welcome before/after, Light and Dark](images/welcome-room-before-after.png).
These M3 window captures use synthetic Example data on the M1 built-in 2x panel.
