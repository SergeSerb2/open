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

## The basics page

The page follows the reference layout, copy structure and timing measured in a
capture session ([re/onboarding.md §6](re/onboarding.md)). Open's own words, mark
and background art are used; no reference asset is copied.

- **Layout.** Open's doorway mark, then "You're all set." / "Here are the basics."
  (32 pt heavy), then a four-step accordion in a 336 pt column 31 pt from the page
  edge. A collapsed step is 72 pt high (number and title); steps are 8 pt apart.
  The active step is white, shows its icon, body copy and a 3 pt progress bar along
  its lower edge; step 4 also shows ⌘ T keycaps. One 16:10 clip panel sits 32 pt to
  the right of the column, from 19.6 % of the page height down to 4.5 % above the
  bottom, and runs past the right edge. "Learn Essential Shortcuts" and
  "Help & Resources" sit at the top right (23.5 pt insets). Narrow pages put the
  clip under the steps and scroll.
- **Reveal.** On first show the parts fade in (0.28 s, ease-in-out) at +0.28 s
  (mark), +1.2 s (heading), +2.26 s (steps), +2.9 s (clip panel, which starts the
  first clip) and +3.85 s (links). The fades are layer animations with begin times;
  nothing lays out per frame.
- **Playlist.** Pin → Spaces → Split → New tab. Each clip is 8.5 s; the next step
  starts 0.5 s after a clip ends, so the playlist ends at 38.8 s. A step change is
  a critically damped spring (stiffness 1600, damping 80; about 0.25 s) on the
  step layers' position and bounds, and the body fades with the same spring.
  The progress bar is one linear `transform.scale.x` animation per clip.
- **End.** The last frame blurs and dims (a bundled blurred poster, 0.28 s fade)
  and "Replay All" appears over the clip. Replay All restarts the playlist.
- **Input.** Hover changes only the step surface; it never plays. A click,
  Return, Space or the VoiceOver Replay action expands that step and plays only
  its clip, with a 0.28 s crossfade; the clip then ends in the end state.
- **Hidden.** Hiding the tab, minimizing, covering the window or hiding the app
  pauses the clip and releases the player and its decoder. A paused frame is
  copied once (off the main thread) into the poster layer. Showing the page again
  resumes the same step from the same time.
- **Reduce Motion.** No reveal and no autoplay: step 1 is expanded and its poster
  (the clip's last frame) shows. A click still plays that step's clip.

Clips are bundled in `App/Resources/Basics/` (HEVC Main `hvc1`, 1920 × 1200,
60 fps, hardware decoded by AVFoundation), with a last-frame poster and a blurred
poster each; 3.3 MB in all. They are recorded from the real app with
`tools/basics` ([README](../tools/basics/README.md));
`tools/basics/clips-manifest.json` records the source commit and file hashes.
Re-record them when the sidebar, command bar or split chrome changes.

`WelcomeContentHost` opens the existing Essential Shortcuts window and the
`help-center` command (Open's help page in a new tab).

## Automation and tests

The Debug/automation socket command `welcome` returns `visible`, `activeCard`
(1–4), `playlist` (`playing`/`stopped`), `animating`, `revealed`, `ended`,
`paused`, `reduceMotion`, `playedCards`, `completionCount`, `pendingCompletion`,
`animationCount`, `decoders` and a `clip` object (`loaded`, `decoder`, `playing`,
`end`, `replayAllVisible`, bundled `movies`), the step AX labels and actions, and
`layout` (viewport, document, column, steps, clip, links and text frames).
Actions: `insert`, `replay card=N`, `replay-all`, `hover card=N [phase=exit]`,
`reveal card=N`, `link link=shortcuts|help`. Invalid cards and hidden replay fail.

`tools/e2e/engine_e2e.py --only welcome` checks the reveal schedule, the playlist
order and end time, the decoder lifecycle, hover without replay, click and keyboard
replay, Replay All, pause/resume on tab switch, minimize and cover, links, session
restore, archive and reopen, refusal of external `open://welcome`, the layout at
1280 × 800, 1000 × 700 and a tall window (dark and light app appearance), heading
contrast on real window pixels (at least 7:1), and Reduce Motion.
`OPEN_E2E_WELCOME_IDLE_ONLY=1` runs the idle contract (complete playlist, then
below 1 % App CPU in Release). Evidence goes to `.re/welcome-e2e/`.

`tools/basics/pacing.py` records stock frame-detector ledgers for the step change,
Replay All and the steps' reveal fade; score them with `tools/perf/pacing_gate.py`.

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only welcome
```
