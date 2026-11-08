# Onboarding validation

Recorded on the M5, 2026-11-07. Final visual implementation head: `f607d01e`; the final report commit also
rejects a non-string automation action instead of silently reading state.
Early requested WIP push: `74871062`. Main `cca16812` was merged by
`228f9505`; a fresh fetch before this report found no newer remote main.

## Current acceptance state

The final Debug App build, renderer and sound check pass. This is a **draft,
not merge-ready**. The user has kept M5 native checks paused after a real
Open crash left UserNotificationCenter in front. This child has no evidence
that the dialog has been cleared. It has not touched the dialog, resumed
native checks, used the M1 screen, or left a native job queued.

The following checks remain blocked by that pause:

- Final-head `onboarding`, including non-string action rejection and the new
  `light_uses_screen_blend` and
  `native_intro_close_quits` gates and their broken-condition proofs.
- `OPEN_ONBOARDING_FORCE_EARLY_FAILURE=1` cleanup proof with the intro/dim up.
- Existing `firstrun` suite after its launcher was taught the intro handoff.
- Final real-window PNG review and a measured screen-blend cost comparison.
- Interleaved main/branch returning launches, five each, using a real saved
  `State/browser.json` and no `--skip-first-run`. No medians or ≤5 ms claim
  are available. The comparison runner is `tools/e2e/onboarding_launch.py`.
- A quiet Site Control timing rerun and main control, and a fully green full
  verification run. Neither full run below passed every check.

Absolute 120 Hz acceptance also remains pending: the recorded run was at
load1 19.33, above the required 12. All automated sound routes were silent
or off. No unit tests, desktop input, Arc launch/assets or engine edits were
used. Shared status and followup files are left to the lead.

**PARTIAL. M5 native checks remain paused by the user since 21:15 on 2026-11-07.** Run 3 below is from clean head `c71a03c3`, before the final lighting, spacing, close/cleanup gates and main merge. It is not final-head acceptance.

Real Debug App on the M5, synthetic Arc source, disposable Open roots. Automated audio uses volume zero or the off path. No desktop input, unit tests, reference-app launch or copied assets.

Exact implemented beats are in [the timeline](onboarding.md). Continue opens Section 7’s existing 560×520 window for v1. The shared room controller also provides `show(content: NSViewController)` for later screens. Music keeps playing through Continue.

## Native onboarding gates — pre-light revision only

| Gate | Result | Broken-condition proof | Load1 / 5 / 15 |
|---|---|---|---|
| `closing_setup_releases_music_and_dim` | PASS | expected FAIL, observed FAIL | 16.40 / 21.84 / 24.67 |
| `device_failure_completes` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `dim_overlay` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `early_keys_do_not_advance` | PASS | expected FAIL, observed FAIL | 19.33 / 22.81 / 25.09 |
| `escape_skips_to_final` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `finish_releases_player` | PASS | expected FAIL, observed FAIL | 16.40 / 21.84 / 24.67 |
| `first_launch_shows_intro` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `frame_stats_recorded` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `get_started_handoff` | PASS | expected FAIL, observed FAIL | 17.94 / 22.31 / 24.87 |
| `handoff_import_fresh_choices` | PASS | expected FAIL, observed FAIL | 17.94 / 22.31 / 24.87 |
| `idle_pauses` | PASS | expected FAIL, observed FAIL | 17.94 / 22.31 / 24.87 |
| `intro_browser_shortcuts_guarded` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `music_continues_after_continue` | PASS | expected FAIL, observed FAIL | 16.40 / 21.84 / 24.67 |
| `native_return_handoff` | PASS | expected FAIL, observed FAIL | 16.40 / 21.84 / 24.67 |
| `owned_window_cleanup` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `phases_reached_in_order` | PASS | expected FAIL, observed FAIL | 19.33 / 22.81 / 25.09 |
| `quit_during_animation_fixture` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `reduce_motion_crossfade_only` | PASS | expected FAIL, observed FAIL | 16.29 / 21.73 / 24.62 |
| `replay_default_root_refused` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `replay_does_not_write` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `replay_over_browser` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `replay_temp_root_allowed` | PASS | expected FAIL, observed FAIL | 16.58 / 21.70 / 24.59 |
| `resident_3_seconds` | PASS | expected FAIL, observed FAIL | 19.33 / 22.81 / 25.09 |
| `returning_inactive` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `scene_click_skips` | PASS | expected FAIL, observed FAIL | 16.29 / 21.73 / 24.62 |
| `setting_mutes_without_player` | PASS | expected FAIL, observed FAIL | 16.29 / 21.73 / 24.62 |
| `silent_playback_sync` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `skip_first_run_inactive` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `sound_off_mutes_without_player` | PASS | expected FAIL, observed FAIL | 16.29 / 21.73 / 24.62 |
| `start_fresh_browser` | PASS | expected FAIL, observed FAIL | 17.31 / 22.11 / 24.79 |
| `strict_120hz` | INFO | INFO only | 19.33 / 22.81 / 25.09 |
| `unknown_automation_input_refused` | PASS | expected FAIL, observed FAIL | 19.33 / 22.81 / 25.09 |

Each negative row uses the same predicate against a real contrasting state: before its trigger, an inactive launch, a muted/failed sound route, unmeasured frames, or a changed snapshot. The repeated-phase proof applies the phase-order predicate to the captured states with completion missing. These are negative proofs of the gates, not altered runtime telemetry.

## Commands and receipts

Loads are load1 / load5 / load15. A missing historical load is marked
unrecorded; no current load has been substituted for it. Raw receipts are
in the git-ignored `.re/handoff/sections/s17/c2/` directory of this checkout.
All build/verify/SwiftPM jobs used `heavy.sh` with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. Each native suite
used its own invocation of `lockf -k /tmp/open-onscreen-e2e.lock`, after the
priority check. No native launch ran during an owned build.

| Command / receipt | Exact result | Load evidence |
|---|---|---|
| `tools/build.sh Debug` and package renderer builds during implementation (`build-debug.log`, `build-debug2.log`, `build-coordinate-fix.log`, `build-integrated.log`, `build-lifecycle.log`, `build-final.log`, `build-render-final.log`) | PASS; earlier superseded builds | Individual loads unrecorded |
| Main Debug control build (`build-main.log`) | PASS; `cca16812`; App never measured for launch acceptance | Individual load unrecorded |
| `tools/verify-all.sh --only settings-preview,onboarding-render` (`verify-focused.log`) | build PASS 199 s; settings-preview PASS 86 s; onboarding-render PASS 22 s | load1 start 13.79, sampled peak 119.14, finish 26.89; load5/15 unrecorded |
| First full `tools/verify-all.sh` (`verify-full.log`) | 24 PASS / 1 FAIL; summary below | load1 start 17.83; observed samples 9.08–48.59; Site Control highlight row 36.10; load5/15 unrecorded |
| `engine_e2e.py --only onboarding` run 1, 20:03 (`results-onboarding-run1.json`) | 51 PASS / 4 FAIL / 1 INFO; cleanup PASS | start 24.21 / 32.23 / 37.62 |
| Same suite run 2, 20:35 (`results-onboarding-run2.json`) | 60 PASS / 2 FAIL / 1 INFO; cleanup PASS | start 17.11 / 20.90 / 25.88 |
| Same suite run 3, 20:41 (`results-onboarding-run3.json`) | 62 PASS / 1 INFO, 31 positive gates + 31 contrasting-state proofs; cleanup PASS; pre-light head only | start 20.63 / 23.22 / 25.28; per-gate loads above |
| Merged Debug App builds (`build-merged.log`) | PASS, including branch and prepared main control | 18.20 / 20.45 / 23.74 → 16.47 / 19.71 / 23.28 |
| Full merged `tools/verify-all.sh` (`verify-merged.log`) | 24 PASS / 1 FAIL; summary below; pre-light revision | 52.84 / 30.69 / 26.70 → 30.63 / 28.79 / 29.39 |
| Final-light App + first Metal renderer build (`build-light-renderer.log`) | PASS | 36.06 / 30.17 / 29.80 → 38.96 / 31.68 / 30.37 |
| Corrected 2x Metal renderer build (`build-render-scale.log`) | PASS, 2.48 s SwiftPM build | 30.79 / 33.23 / 31.42 → 30.24 / 33.08 / 31.38 |
| Final Debug App + Debug renderer build, then `tools/verify-all.sh --only onboarding-render` (`verify-light-focused.log`) | PASS; verifier build PASS 17 s; onboarding-render PASS 22 s | 27.54 / 31.61 / 31.13 → 28.71 / 31.65 / 31.20 |
| `python3 tools/generate-intro-sound.py --check` (`sound-check-final.json`) | PASS, exit 0, 28.077 s | 18.51 / 19.97 / 23.24 → 16.49 / 19.32 / 22.89 |
| Final typed-action Debug App build (`build-report-final.log`) | PASS, exit 0, 13 s | 11.17 / 20.39 / 26.20 → 12.33 / 20.16 / 26.02 |
| Final `onboarding-render --out …` (`render-light-final.json`) | PASS, exit 0, 1.776 s; nine 2560×1600 PNGs | 32.66 / 32.49 / 31.48 at start/end |
| Credits generator preview + actual App resource inventory (`license-resource-audit-final.json`) | PASS, 75 paragraphs; all 3 new resource paths present in manifest | 22.96 / 29.10 / 30.26 |
| Debug App/object size inventory (`size-final.json`) | PASS; exact values below | 17.48 / 20.41 / 25.81 |
| Python syntax (five touched Python sources) + `git diff --check` (`static-final.json`) | PASS | 12.33 / 20.16 / 26.02 |

There is no separate license verifier target. The all-product build checks
Package.swift's target graph. The actual App bundle audit checks the three
new manifest paths; the license row identifies Open-owned generated art and
score. Existing release-credit limitations remain: the public MPL source
offer is unset and full Chromium credits are missing/sample. The preview
printed both existing warnings; it is not a release-license acceptance.

Run 1 exposed late button/idle wakeups, presentation sampling, replay path
handling and stale caption checks. These were fixed. Run 2 failed the old
"Get Started" caption assertion and the sync row on a cold preparation that
correctly exceeded the 300 ms deadline. The sync assertion now belongs to a
dedicated successful silent launch; the deadline was not widened. Run 3's
measured launch still exercised the silent timeout path, while its dedicated
silent launch played successfully. Earlier receipts remain retained.

The renderer initially used CALayer.render, whose radial fallback differed
from native Core Animation. The final renderer uses CARenderer into Metal,
with the actual scene tree and track samples. Its initial scale/orientation
error was corrected before the final nine images were accepted offscreen.
Earlier image receipts are superseded; `render-light-final.json` is current.

### Full verification summaries

Both commands were actually run. No comparator or threshold was changed.
The first run failed only the Site Control CSS highlight budget: 2.977 ms
against 2 ms, load1 36.10 (1548/1549). The merged run was 1536/1539 with 4
INFO and retained 2 earlier INTERRUPTED entries: three F25 attempts lost
foreground to UserNotificationCenter, so the F25 result gate failed. Its
highlight budget also missed at 2.343 ms, load 31.23 / 28.81 / 29.45.
These are reported as recorded failures/interruptions, not accepted passes.

**First full run: 24 PASS / 1 FAIL**

```text
NAME                   RESULT SECONDS
build                  PASS   3
commands-demo          PASS   7
roundtrip              PASS   1
space-legacy           PASS   2
space-editor           PASS   244
space-pad-compare      PASS   3
suggest-check          PASS   37
commands-dump          PASS   1
route                  PASS   19
favicons               PASS   4
media-demo             PASS   0
sleep-demo             PASS   1
adblock-perf           PASS   1
adblock-catalog        PASS   0
profiles               PASS   4
settings-preview       PASS   81
sidebar-render         PASS   114
sidebar-compare        PASS   159
commandbar-render      PASS   36
features-render        PASS   97
extensions-render      PASS   7
sitecontrol-render     FAIL   403
onboarding-render      PASS   30
boosts                 PASS   5
verify-secrets-fixture PASS   9
```

**Merged full run: 24 PASS / 1 FAIL**

```text
NAME                   RESULT SECONDS
build                  PASS   62
commands-demo          PASS   8
roundtrip              PASS   1
space-legacy           PASS   3
space-editor           PASS   183
space-pad-compare      PASS   3
suggest-check          PASS   35
commands-dump          PASS   1
route                  PASS   20
favicons               PASS   3
media-demo             PASS   1
sleep-demo             PASS   0
adblock-perf           PASS   1
adblock-catalog        PASS   0
profiles               PASS   3
settings-preview       PASS   85
sidebar-render         PASS   113
sidebar-compare        PASS   191
commandbar-render      PASS   41
features-render        PASS   101
extensions-render      PASS   9
sitecontrol-render     FAIL   349
onboarding-render      PASS   32
boosts                 PASS   5
verify-secrets-fixture PASS   11
```

### Native metrics before the final visual revision

The successful silent playback receipt records audio and CA scheduled start
host times with a 0 ms difference (limit 20 ms), at load 17.31 / 22.11 /
24.79. This is the common-clock scheduling proof; it is not a microphone or
hardware-output latency measurement.

Frames over 0–8 s: p50 4.167 ms, p95 4.167 ms, max 122.838 ms, 54 drops in
1837 callbacks, nominal 4.167 ms (240 Hz display), load 19.33 / 22.81 / 25.09.
The strict row was INFO. These callback intervals do not establish final
screen-blend GPU cost. No normal launch creates a frame-measurement display
link. The native resident deltas were 191,954,944 bytes at 3 s and
237,240,320 after browser landing; the latter includes browser/engine work
and is not leak proof.

### Broken-condition proofs

Every one of run 3's 31 functional gates applied the same predicate to an
observed contrasting App state. Each positive passed and each contrasting
state was rejected. The table above gives each gate and its load. These
proofs include before/after trigger states, returning/skip roots, absent
measurement, muted/failed playback, and changed saved snapshots. The phase
order predicate also rejected the captured states with completion missing.
This validates the gate predicates; it does not claim a mutated production
binary was run. The final two new gates and forced-failure cleanup have not
run while the native hold is active.

Offline break-and-restore checks:

| Broken condition | Observed result | Load1 / 5 / 15 |
|---|---|---|
| Changed pinned PCM SHA | Expected FAIL, exit 1 | 29.19 / 34.05 / 38.46 |
| Reference RMS bin raised 10 dB | Expected FAIL, exit 1; delta 10.003 dB | Unrecorded |
| Truncated AAC to 19 s | Expected FAIL, exit 1 | 30.74 / 22.04 / 27.93 |
| Non-silent tail, peak 0.01108 | Expected FAIL, exit 1 | 33.56 / 22.77 / 28.15 |
| Trailing renderer argument | Expected FAIL, exit 64 | 33.56 / 22.77 / 28.15 |

The modified Debug resources were restored in finally paths, then generator
and real decoder checks passed again. These probes never played sound.

## Sound and size

Original Python stdlib synthesis plus system afconvert, no third-party DSP
or reference sound. Deterministic little-endian stereo 48 kHz / 16-bit PCM:

```text
980936f5cb2cf2d3488e6ff160e57dabf5ef27e55902d3aa23481936d21859b5
```

| Measurement | Result |
|---|---:|
| Decoded duration | 20.000 s |
| Container duration, including AAC padding | 20.053333 s |
| Plateau integrated loudness, 5–15 s (`ffmpeg ebur128`) | −14.0 LUFS |
| Loudness-range low / high | −14.3 / −13.7 LUFS |
| Player volume / calculated heard plateau | 0.5 / −20.02 LUFS |
| PCM peak | −2.900217 dBFS |
| AAC decoded peak (AVFoundation) | −3.108826 dBFS |
| AAC LC target / measured stream rate | 128,000 / 121,769 bit/s |
| m4a size | 313,428 bytes |
| Generator runtime / latest check runtime | 45.583 s / 28.077 s |
| Largest AAC vs PCM 0.5 s RMS difference | 0.032 dB, limit 1.5 dB |
| Source tail from 19.5 s / AAC 16-bit decoded tail | Digital zero / ≤1 quantization step (limit 8) |

The curve rises from about −36 dBFS, reaches the plateau at 5 s, holds
through 15 s, falls to about −44 dBFS before 19.5 s, then becomes silent.
The v2 LUFS target changes the absolute RMS plateau from the old v1 value;
the requested rise/hold/fall/silence shape is retained. Source PCM RMS for
each consecutive 0.5 s bin, starting at t=0:

```text
-35.899, -35.725, -33.158, -30.246, -27.327, -24.396, -21.495, -18.201
-17.087, -15.507, -15.256, -15.526, -15.324, -15.451, -15.410, -15.534
-15.166, -15.587, -15.379, -15.276, -15.127, -16.060, -15.551, -15.140
-15.312, -15.499, -15.679, -15.186, -15.394, -15.636, -15.433, -17.741
-21.511, -25.038, -30.197, -35.409, -39.259, -43.903, -44.341, -180.000
```

**Spec deviation / decision for the lead:** the original −1 dBFS master
peak target is not met (actual −2.90). The score keeps v2's −14 LUFS master
plateau. The lead approved its sound curve at 20:56; explicit acceptance of
this peak deviation remains open. The final suspended chord resolves at
17.75 s, the midpoint of the unspecified final phrase. The screen blend
fallback decision also remains open until its frame cost can be measured.

Debug size comparison against main `cca16812`, summing regular App files
without following symlinks: main 628,336,121 bytes, branch 629,147,000,
delta **810,879 bytes**. Executable delta **493,088 bytes**. New Debug
OpenOnboarding objects total **695,560 bytes**. The package Release
OpenOnboarding object is **300,272 bytes**; a Release App was not built.

## Final design images and handoff

All nine final images are Display P3, 2560×1600 (2x), under the canonical
project directory `/Users/serge/.t3/projects/open/.re/handoff/sections/s17/c2/`:

- `intro-00.5@2x.png`
- `intro-01.5@2x.png`
- `intro-02.6@2x.png`
- **`intro-03.5@2x.png`**
- `intro-05.0@2x.png`
- `intro-06.5@2x.png`
- `intro-08.0@2x.png`
- **`intro-10.2@2x.png`**
- `intro-reduce-motion-final@2x.png`

These contain the revised light gradient, screen-blended spill/warm orb,
and tight final spacing. The final offscreen PNGs were viewed. Native
captures are retained with a `pre-light-` prefix in the canonical directory;
they must not be presented as final-head real-window approval. Final PNG
SHA-256 values are in `render-light-final.json`.

The exact implemented timing table and final light/spacing constants are in
[onboarding.md](onboarding.md). The v1 handoff is Continue → Section 7's
existing 560×520 import/Start Fresh window. Music and the dim window continue
through that handoff and fade only on finish/close. Later setup screens can
use `OnboardingWindowController.show(content: NSViewController)` above the
same room background, without resetting sound or ambient clocks.

New implementation files live in `OpenOnboarding`, `onboarding-render`,
`App/FirstRun/{AppOnboarding,OnboardingWindowController}.swift`,
`App/Automation/AutomationOnboarding.swift`, the sound generator and the two
`tools/e2e/onboarding*.py` files. Local hooks touch AppDelegate, MainMenu,
LaunchOptions, first-run close, the automation dispatcher/window snapshots,
Package.swift/project.yml, engine_e2e and verify-all/check. Docs and license
inventory entries describe the generated resources. No shared status or
followup row was edited.

## Review checklist

The source checklist is `docs/review-checklist.md`. PARTIAL/BLOCKED rows
remain open for this draft and are not represented as passes.

| Review item | Result | Evidence |
|---|---|---|
| External sizes and decoded bounds | PASS | Fixed bundled score/reference; renderer output path ≤4096 UTF-8 bytes; automation action ≤32 bytes + exact allowlist; decoder ≤965000 frames, stereo 48 kHz; frame list ≤4096. |
| Worst single allocation | PASS | 2x RGBA canvas 16,384,000 bytes; bounded decoded audio <8 MiB. Source comments state bounds. |
| Boundary input proofs | PARTIAL | Pre-light native unknown/33-byte action and extra-key refusal passed, with valid allowlisted actions accepted. Offline 19 s duration and tail rejection passed. All numeric boundary pairs were not exercised. |
| Unknown/trailing data | PASS | Exact renderer CLI argument shape; generator argparse; automation allowlist and extra-key refusal. |
| Callback may release owner | PASS | onClose/final release defer owner work to Tasks; weak captures; close delegate documents deferred termination. |
| Close / repeated / animated close | PARTIAL | Pre-light setup Cmd-W and quit-during-animation cleanup passed; idempotent finishing/stop guards reviewed. Final intro Cmd-W gate and forced-failure cleanup are blocked by M5 hold. |
| Unique IDs / old generations | N/A | No new request-ID protocol; local NSWindow identifiers and direct controller ownership. |
| Flush held state | PASS | Intro writes no snapshot; Section 7 owns save and browser landing. Replay snapshot unchanged proof passed pre-light. |
| Real key paths | PARTIAL | Pre-light OEApplication Return, Space, Esc, Cmd-T/L and setup Cmd-W passed. Final intro Cmd-W and numeric-action rejection rows not run. Run 3 per-gate load1 16.29–19.33. |
| Key ownership after main merge | PARTIAL | MainMenu/AppDelegate routes reviewed; nil-window identity guard fixed. Final native rerun after merge remains blocked. |
| Hidden flags hide actions | PASS | Replay menu #if DEBUG; fail-device/reduce/measurement #if OPEN_AUTOMATION. Before enable beat the native button has no default key and is disabled. |
| Each new check rejects broken conditions | PARTIAL | Pre-light 31/31 positive + 31/31 same-predicate contrasting states; five offline altered-input failures. Final light/intro-close negatives and forced cleanup not run. |
| Pixel comparison | N/A | PNGs are manual design-review artifacts; no file-size or PNG-length visual assertion. |
| Specific window assertions | PARTIAL | Pre-light intro/window ID, FirstRunNativeWindow and BrowserWindow assertions passed. Final real-window pass blocked. Dim excluded from ordinary snapshots/window lists. |
| Configured timing/deadline checks | PASS | Single IntroTimeline; shared audio/CA schedule; zero-tolerance button/idle deadlines; recorded schedule delta 0 ms. Strict frame row INFO at load1 19.33. |
| Isolated roots/cache/ports/preferences | PASS | Launcher temp root/cache/socket and synthetic Arc fixture; touched shared defaults captured/reset/restored in finally. No remaining owned App process. |
| No human-dependent cleanup | PARTIAL | Run 3 cleanup PASS for every owned launch, no remaining windows/processes. No new dialogs. Explicit forced-early-failure proof is blocked. |
| Reduce Motion | PARTIAL | Pre-light native crossfade-only/static-orb check and negative passed at load1 16.29. Final offscreen Reduce Motion PNG viewed; final native rerun blocked. |
| Interrupted animation uses presentation | PASS | Handoff reads presentation opacity; idle freeze converts current local time; skip explicitly selects the final state. |
| Resize/frame changes | PASS | Nonresizable window; layout disables implicit actions; small-screen size follows v2. |
| Real-window visual review | BLOCKED | Pre-light OUR-window PNGs retained; final 2x offscreen frames viewed. M5 native hold prevents final live comparison; original art has no copied Arc capture. |
| Docs match implementation | PASS | docs/onboarding.md exact beat table; docs/onboarding-validation.md actual results, loads and open peak deviation. |
| Plan / followups / PR agree | PASS | Draft remains partial. Native hold, full-verifier failure, launch comparison, screen-blend cost and sound peak are explicit. Shared status/followup files are lead-owned. |
