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
| introAnimation | 0 | 3.3 |
| sellIntro | 3.3 | 9.8 |
| sellCompleted | 9.8 | — |
| Room / orbs | 0 | 1 |
| Dim overlay | 0 | 0.6 |
| Door stroke | 0.3 | 1.9 |
| Sun spring | 1.7 | 2.7 |
| Bell pair | 2.3 | 2.47 |
| Light spill | 2.4 | 3.3 |
| Mark move / wordmark | 3.3 | 4.1 |
| Identity line | 4.3 | 4.9 |
| Value line 1 | 5.6 | 6.8 |
| Value line 2 | 6.8 | 8 |
| Value line 3 | 8 | 9.2 |
| Button fade (enabled at start) | 9.8 | 10.2 |
| Music plateau | 5 | 15 |
| Sub entry | 3.3 | 5.3 |
| Air sweep | 2.4 | 3.3 |
| Music fade | 15 | 19.5 |
| Digital silence | 19.5 | 20 |
| Ambient pause | 23.5 | — |

Other table constants: Reduce Motion fade 0–0.6 s, button enable 1 s;
hand-off fade 0.45 s, sound fade 0.8 s; common audio/CA scheduling lead
0.08 s; sound preparation deadline 0.3 s; frame measurement 0–8 s;
resident measurement 3 s; orb periods 18/22/26 s.

Get Started closes the 1280×800 intro window and opens Section 7's existing
560×520 first-run window. The existing shared importer, source probe, guarded
save and Start Fresh behavior remain its owners. The intro never writes a
snapshot. A small screen (both width ≤1280 and height ≤800) uses its full
screen size minus 72 pt in each dimension. The mouse-transparent dim child
window covers that screen at 85% black. It is excluded from automation window
lists and snapshots and closes with its owner on every exit.

Esc or a scene click completes the visual tracks and enables Get Started.
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
preparation. The master leaves extra headroom below the v1 −1 dBFS peak
ceiling to meet the newer loudness target. No automation run emits audio.

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
