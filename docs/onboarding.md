# Open intro

`OpenOnboarding` is entered only for a missing `State/browser.json`, or an
explicit replay. Returning and `--skip-first-run` launches leave the optional
App controller nil. No resource lookup, scene construction or player creation
runs on those paths. The `onboarding` automation command reports that boundary
as `moduleActive: false` without calling into the package.

The intro uses Open's own doorway/sun mark, procedural grain and synthesized
score. There are no reference-app assets. All scene and playback beat times
are in `IntroTimeline.beats`; the Python generator reads the same table.

| Beat | Start (s) | End (s) |
|---|---:|---:|
| `introAnimation` | 0 | 3.3 |
| `sellIntro` | 3.3 | 9.8 |
| `sellCompleted` | 9.8 | 9.8 |
| `room` | 0 | 1 |
| `dim` | 0 | 1.5 |
| `dimFinish` | 0 | 2.5 |
| `door` | 0.3 | 1.9 |
| `sun` | 1.7 | 2.7 |
| `bellPair` | 2.3 | 2.47 |
| `spill` | 2.4 | 3.3 |
| `markMove` | 3.3 | 4.1 |
| `wordmark` | 3.3 | 4.1 |
| `line` | 4.3 | 4.9 |
| `value1` | 5.6 | 6.8 |
| `value2` | 6.8 | 8 |
| `value3` | 8 | 9.2 |
| `button` | 9.8 | 10.2 |
| `buttonSpring` | 9.8 | 11.05 |
| `plateau` | 5 | 15 |
| `subEntry` | 3.3 | 5.3 |
| `airSweep` | 2.4 | 3.3 |
| `sound` | 0 | 20 |
| `soundFade` | 15 | 19.5 |
| `idlePause` | 23.5 | 23.5 |
| `reduceFade` | 0 | 0.6 |
| `reduceButton` | 1 | 1 |
| `handoff` | 0 | 0.45 |
| `handoffSound` | 0 | 0.8 |
| `syncLead` | 0 | 0.08 |
| `soundDeadline` | 0 | 0.3 |
| `measureFrames` | 0 | 8 |
| `measureMemory` | 3 | 3 |
| `orbBlue` | 0 | 18 |
| `orbPurple` | 0 | 22 |
| `orbWarm` | 0 | 26 |

Other table constants: Reduce Motion fade 0–0.6 s, button enable 1 s;
hand-off fade 0.45 s, sound fade 0.8 s; common audio/CA scheduling lead
0.08 s; sound preparation deadline 0.3 s; frame measurement 0–8 s;
resident measurement 3 s; orb periods 18/22/26 s.

Continue replaces the foreground inside the same 1280×800 onboarding window.
The room, dim child and music keep their clocks through the setup steps below.
The intro never writes a snapshot. A small screen (both width ≤1280 and height
≤800) uses its full screen size minus 72 pt in each dimension. The mouse-transparent
dim child covers that screen at 85% black, and is excluded from ordinary window
lists and snapshots. Only final completion or closing fades music and the dim.

Esc or a scene click completes the visual tracks and enables Continue.
The music continues on its original clock. Return and Space cannot advance
before the button enable beat. Reduce Motion uses only a final-composition
cross-fade, with static orbs. Increase Contrast raises the identity line to
90% white. Core Animation owns all animation frames. Only the measurement
flag creates a display link; lifecycle work uses one-shot async deadlines.

The sound generator uses only Python's standard library and macOS afconvert.
It pins the little-endian stereo 48 kHz / 16-bit PCM SHA-256. AAC validation
allows 20 ms of duration difference, 1.5 dB per half-second RMS bin, and a
silent tail from 19.5 s (at most 8 PCM quantization steps after AAC decode).
The committed measurement JSON is also compared against regenerated PCM.
The final suspended chord resolves to Dadd9 at 17.75 s. This is the midpoint
of the spec's final phrase, whose exact resolution time was unspecified.

The v2 master plateau is approximately −14 LUFS. Normal playback uses volume
0.5 (about −20 LUFS heard); silent automation sets volume zero before player
preparation. The PCM peak is −2.90 dBFS, below the original −1 dBFS target.
This retains the v2 loudness target. Acceptance of this headroom, or a score
retune to hit both values, is a decision for the lead. No automation run emits audio.

Run the actual offscreen renderer and decoder after building their product:

```sh
Packages/OpenKit/.build/debug/onboarding-render --out .re/handoff/sections/s17/c2
Packages/OpenKit/.build/debug/onboarding-render --check-sound
python3 tools/generate-intro-sound.py --check
```

The renderer samples the same scene tracks as the real view at 0.5, 1.5,
2.6, 3.5, 5.0, 6.5, 8.0 and 10.2 s, plus the Reduce Motion final frame,
at 2x. It creates an unshown window for AppKit backing; it never orders it
front. Real-window acceptance is the separate `onboarding` e2e suite.

## Setup in the same window

Continue replaces only the foreground with Name → Import (when source data exists) → Favorites (unless import brought Favorites) → Theme → Blocker → Default browser → Ready. The shared room, dim overlay and music keep their clocks. Name is optional, trimmed and limited to 40 characters. Every selection stays in memory until Get Started. Closing the window quits without applying those selections.

`OnboardingStepsController` hosts Section 7's `FirstRunView(embeddedImport: true)` and the same `FirstRunViewModel` / `ImportWizardViewModel`. Settings ▸ Import keeps its existing wizard. Consent tokens, import idempotency, progress, reports and save errors stay in the shared implementation. The import landing save is a checkpoint; final setup owns the completed flag.

Favorites use direct site favicon requests (2 seconds, 256 KiB, 64-pixel thumbnail, no cookies and no redirects). A monogram is visible immediately. Theme uses `OpenSpaceEditor`'s preset strip, color pad, state reducer and appearance bar. The selected style is applied to the focused Space at finish. Blocker uses the existing `AdBlockStore.setEnabled` global `nativeAdBlockEnabled` setting in `adblock-settings.json`, the same setting as Advanced.

`OnboardingBrandMark` supplies the intro's trimmed rounded doorway and sun to the intro, Name preview and both marks on the card. The Theme preview keeps its traffic lights, URL bar, four tinted sidebar rows and three neutral page bars live with the selected Space style. The second Favorite suggestion is Google Calendar (`https://calendar.google.com/`).

The Ready card uses one original drawing routine for the screen and 1200 × 750 PNG output. Its gradient midpoint supplies the sRGB relative luminance. Above 0.55, the name uses black at 0.82 and the date uses black at 0.55; otherwise they use white and white at 0.72. The date is 17 points in the card's design coordinates. Save opens `NSSavePanel`; Shuffle cycles six deterministic patterns. The two 32-point circle buttons sit 12 points apart, centered 16 points below the card. Their white fill changes from 0.16 to 0.24 on hover, with white glyphs at 0.9. Confetti emits above the card once for 0.6 seconds, in a separate layer below the card and its text, then removes its layer. Reduce Motion uses cross-fades and no confetti.

The default-browser service runs only on Next with Yes selected. Setup awaits the existing Settings request's completion, then shows its outcome for 1.2 seconds before advancing. Automation sockets always use a bounded outcome stub (`OPEN_AUTOMATION_DEFAULT_BROWSER=already|success|declined|failed`, default declined); they never invoke the system prompt.

Get Started applies choices and uses Section 7's `finishFirstRun`: save the choices, insert and select the ordinary Welcome tab, save again, then set completion. A failure keeps Ready open for retry without adding another Welcome tab. The importer can prepare a browser early for background History and extension installs. During setup, that browser has alpha zero, cannot become key or main, and stays below the dim overlay. Hand-off enables activation and fades its alpha to one below onboarding and above the dim overlay. Onboarding rises 24 points over 0.4 seconds and fades over 0.6 seconds; dim fades over 2.5 seconds. Reduce Motion cross-fades all three over 0.3 seconds. Music fades over 0.8 seconds if still playing. Replay uses the same screens but performs no import, model, preference or default-browser writes.
