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

Continue hides the 1280×800 intro window and opens Section 7's existing
560×520 first-run window. The existing shared importer, source probe, guarded
save and Start Fresh behavior remain its owners. The intro never writes a
snapshot. A small screen (both width ≤1280 and height ≤800) uses its full
screen size minus 72 pt in each dimension. The mouse-transparent dim child
window covers that screen at 85% black. It is excluded from automation window
lists and snapshots and transfers to the existing first-run window. Music keeps playing through Continue.
Only completion or closing fades the music over 0.8 s and the dim over 2.5 s.
`OnboardingWindowController.show(content:)` replaces the foreground above the
shared room for later setup screens, without changing the music clock.

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
