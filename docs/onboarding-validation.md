# Onboarding validation — M5, 2026-11-08

Native implementation receipt: `bc50f2fac3b4ddc6452b82b9ff03f6d81892f5c8`. Main `cdd147ca` is merged; the lead’s `dea70ba3` RE merge is retained. Continue bridges to Section 7’s existing 560×520 import/Start Fresh window in this PR. The steps PR replaces that bridge. The stable seam is `OnboardingWindowController.show(content: NSViewController)`.

M5 screen clearance is explicit in CHILD-RULES item 24. M1 screen remains unused. Builds and functional checks run at any load under the required wrappers (updated item 9). Only one owned heavy job runs at a time. All App launches use synthetic Arc fixtures, disposable roots, and silent/off audio. No unit tests, desktop input, Arc assets, engine edits or audible playback.

## Build and native receipts

Both Debug Apps use engine distribution `47af3007153a883fac2acd10e491451de0abcac030c4fbebb14f15f1052115d9`; normalized embedded code is `b6620f962c2b50490d43c45557db0c51389279956d7bc0afa62077edbbdddfba`. Fingerprint checks pass for branch and unchanged main. Raw receipts are in `.re/handoff/sections/s17/c2/resume/`.

| Command / receipt | Result | Load1 / 5 / 15, start → end |
|---|---|---|
| Merged Debug build (`build-debug.log`) | PASS | 10.40 / 8.14 / 7.23 → 48.32 / 21.29 / 12.39 |
| Blend-switch Debug build + engine fingerprint (`build-blend.log`) | PASS | 44.08 / 25.81 / 14.70 → 38.41 / 25.71 / 14.93 |
| Unchanged main Debug control build (`build-main.log`) | PASS | 6.75 / 17.68 / 28.42 → 16.26 / 17.41 / 26.93 |
| `engine_e2e.py --only onboarding` (`onboarding.log`) | 66 PASS / 1 INFO; cleanup PASS | 26.99 / 25.20 / 15.65 → 17.27 / 22.84 / 15.37 |
| `engine_e2e.py --only firstrun` (`firstrun.log`) | 87 PASS / six existing Boost BLOCKED rows; cleanup PASS | 23.97 / 23.62 / 15.94 → 156.23 / 98.17 / 50.65 |
| Onboarding with `OPEN_ONBOARDING_FORCE_EARLY_FAILURE=1` (`early-failure.log`) | Expected exit 1; forced suite failure; cleanup PASS | 11.72 / 49.92 / 42.11 → 10.99 / 48.51 / 41.70 |

No real Open crash report was created during these native runs. Idle timing waiters were stopped without child Apps or lock holders to allow builds/functional verification; they are not measurement attempts.

## Native onboarding gates

| Gate | Result | Contrasting-state proof | Load1 / 5 / 15 |
|---|---|---|---|
| `closing_setup_releases_music_and_dim` | PASS | expected FAIL observed | 20.10 / 23.64 / 15.52 |
| `device_failure_completes` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `dim_overlay` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `early_keys_do_not_advance` | PASS | expected FAIL observed | 23.30 / 24.47 / 15.56 |
| `escape_skips_to_final` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `finish_releases_player` | PASS | expected FAIL observed | 20.10 / 23.64 / 15.52 |
| `first_launch_shows_intro` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `frame_stats_recorded` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `get_started_handoff` | PASS | expected FAIL observed | 21.85 / 24.09 / 15.58 |
| `handoff_import_fresh_choices` | PASS | expected FAIL observed | 21.85 / 24.09 / 15.58 |
| `idle_pauses` | PASS | expected FAIL observed | 21.85 / 24.09 / 15.58 |
| `intro_browser_shortcuts_guarded` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `light_uses_screen_blend` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `music_continues_after_continue` | PASS | expected FAIL observed | 20.10 / 23.64 / 15.52 |
| `native_intro_close_quits` | PASS | expected FAIL observed | 17.27 / 22.84 / 15.37 |
| `native_return_handoff` | PASS | expected FAIL observed | 20.10 / 23.64 / 15.52 |
| `owned_window_cleanup` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `phases_reached_in_order` | PASS | expected FAIL observed | 23.30 / 24.47 / 15.56 |
| `quit_during_animation_fixture` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `reduce_motion_crossfade_only` | PASS | expected FAIL observed | 19.13 / 23.38 / 15.47 |
| `replay_default_root_refused` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `replay_does_not_write` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `replay_over_browser` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `replay_temp_root_allowed` | PASS | expected FAIL observed | 18.08 / 23.09 / 15.42 |
| `resident_3_seconds` | PASS | expected FAIL observed | 23.30 / 24.47 / 15.56 |
| `returning_inactive` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `scene_click_skips` | PASS | expected FAIL observed | 19.13 / 23.38 / 15.47 |
| `setting_mutes_without_player` | PASS | expected FAIL observed | 19.13 / 23.38 / 15.47 |
| `silent_playback_sync` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `skip_first_run_inactive` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `sound_off_mutes_without_player` | PASS | expected FAIL observed | 19.13 / 23.38 / 15.47 |
| `start_fresh_browser` | PASS | expected FAIL observed | 20.98 / 23.87 / 15.55 |
| `strict_120hz` | INFO | INFO only | 23.30 / 24.47 / 15.56 |
| `unknown_automation_input_refused` | PASS | expected FAIL observed | 23.30 / 24.47 / 15.56 |

Silent playback was `played`, with a common-clock scheduled audio/CA delta of 0.000 ms (limit 20 ms), load 20.98 / 23.87 / 15.55. This measures scheduling, not microphone/hardware latency.
The measured launch’s cold audio preparation exceeded the unchanged 300 ms deadline and correctly failed silently. The dedicated silent launch played successfully. The deadline was not widened.
Loaded frame run: `{"count": 1839, "drops": 49, "maxMS": 131.24408334260806, "nominalMS": 4.166666666666667, "p50MS": 4.16716665495187, "p95MS": 4.167166684055701, "running": false}`, load 23.30 / 24.47 / 15.56. The strict 120 Hz row is INFO because load1 exceeds 12. Frame intervals come from CADisplayLink callbacks, not a GPU trace.

## Existing first-run suite

| Gate | Result | Load1 / 5 / 15 |
|---|---|---|
| `E1_corrupt_sidebar` | PASS | 73.06 / 35.69 / 20.76 |
| `E1_relaunch` | PASS | 77.94 / 37.32 / 21.42 |
| `E2_history_failure` | PASS | 146.63 / 63.74 / 32.28 |
| `EI_already_installed` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_cancel_skips` | PASS | 156.21 / 82.23 / 41.38 |
| `EI_candidates` | PASS | 160.17 / 70.78 / 35.33 |
| `EI_click_required` | PASS | 160.17 / 70.78 / 35.33 |
| `EI_default_role_mapping` | PASS | 158.03 / 83.83 / 42.18 |
| `EI_default_role_target` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_empty_selection` | PASS | 160.17 / 70.78 / 35.33 |
| `EI_failure_reported_app` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_failure_reported_engine` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_finish_without_install` | PASS | 156.21 / 82.23 / 41.38 |
| `EI_internal_hidden` | PASS | 160.17 / 70.78 / 35.33 |
| `EI_metadata_limits` | PASS | 154.53 / 88.92 / 45.22 |
| `EI_no_candidates` | PASS | 154.78 / 85.58 / 43.29 |
| `EI_profile_labels` | PASS | 160.17 / 70.78 / 35.33 |
| `EI_result_counts` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_settings_section` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_target_profile` | PASS | 156.59 / 84.77 / 42.75 |
| `EI_undo_keeps_installs` | PASS | 156.59 / 84.77 / 42.75 |
| `F10_passwords_off` | PASS | 122.10 / 51.15 / 26.88 |
| `F11_relaunch` | PASS | 73.06 / 35.69 / 20.76 |
| `F11_save_guard` | PASS | 73.06 / 35.69 / 20.76 |
| `F12_first_content` | PASS | 164.84 / 96.69 / 49.29 |
| `F13_copy` | PASS | 164.84 / 96.69 / 49.29 |
| `F1_welcome` | PASS | 24.05 / 23.64 / 15.99 |
| `F2_import_choices` | PASS | 25.41 / 23.93 / 16.14 |
| `F2_probe` | PASS | 24.05 / 23.64 / 15.99 |
| `F3_import` | PASS | 25.41 / 23.93 / 16.14 |
| `F4_default_offer` | PASS | 25.41 / 23.93 / 16.14 |
| `F4_finish` | PASS | 25.41 / 23.93 / 16.14 |
| `F4_relaunch` | PASS | 26.25 / 24.13 / 16.26 |
| `F5_settings_reimport` | PASS | 26.25 / 24.13 / 16.26 |
| `F6_relaunch` | PASS | 62.40 / 32.44 / 19.46 |
| `F6_start_fresh` | PASS | 51.38 / 29.79 / 18.46 |
| `F7_choose_folder` | PASS | 66.45 / 33.77 / 20.00 |
| `F7_no_data` | PASS | 66.45 / 33.77 / 20.00 |
| `F8_wal_writer` | PASS | 122.10 / 51.15 / 26.88 |
| `F9_browse_during_history` | PASS | 125.54 / 53.04 / 27.69 |
| `F9_close_keeps_history` | PASS | 134.25 / 57.29 / 29.49 |
| `F9_settings_history_only_repeat` | PASS | 139.37 / 60.93 / 31.11 |
| `MP_archive` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_collision` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_defaultRole` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_favorites` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_history` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_noRepairs` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_profiles` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_reimport` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_routing` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_session` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_spaceProfiles` | PASS | 163.68 / 94.17 / 47.86 |
| `MP_undoModel` | PASS | 163.68 / 94.17 / 47.86 |
| `N4_import_save_failure` | PASS | 89.08 / 40.30 / 22.57 |
| `N4_import_save_retry` | PASS | 89.08 / 40.30 / 22.57 |
| `N9_indeterminate_animation` | PASS | 25.41 / 23.93 / 16.14 |
| `R1_settings_import_quit_save` | PASS | 28.08 / 24.54 / 16.45 |
| `R2_empty_sidebar_continue` | PASS | 34.23 / 25.88 / 16.97 |
| `R2_empty_sidebar_report` | PASS | 34.23 / 25.88 / 16.97 |
| `R3_reopen_restarts_probe` | PASS | 40.62 / 27.34 / 17.53 |
| `all_failed_continue` | PASS | 116.45 / 48.86 / 25.94 |
| `all_failed_retry` | PASS | 116.45 / 48.86 / 25.94 |
| `all_failed_unsaved` | PASS | 116.45 / 48.86 / 25.94 |
| `automation_limits` | PASS | 24.05 / 23.64 / 15.99 |
| `boost_app_disabled` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_app_imported_count` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_app_matching_page` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_app_page_cleared` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_app_probe` | PASS | 162.13 / 97.26 / 49.77 |
| `boost_app_reimport` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_app_report_empty_zero` | PASS | 161.48 / 98.20 / 50.38 |
| `boost_app_report_seam` | PASS | 162.13 / 97.26 / 49.77 |
| `boost_app_report_unavailable_red` | PASS | 161.48 / 98.20 / 50.38 |
| `boost_app_undo` | BLOCKED | 161.48 / 98.20 / 50.38 |
| `boost_cli_app_lock` | PASS | 162.13 / 97.26 / 49.77 |
| `fresh_save_failure` | PASS | 77.94 / 37.32 / 21.42 |
| `fresh_save_retry` | PASS | 77.94 / 37.32 / 21.42 |
| `import_manual_archive_stays_archived` | PASS | 151.54 / 66.13 / 33.30 |
| `import_old_today_repeat` | PASS | 151.54 / 66.13 / 33.30 |
| `import_settings_today_age` | PASS | 154.70 / 68.21 / 34.23 |
| `import_today_age_after_relaunch` | PASS | 151.54 / 66.13 / 33.30 |
| `notnow_finish` | PASS | 102.21 / 43.83 / 23.92 |
| `notnow_offer` | PASS | 102.21 / 43.83 / 23.92 |
| `partial_archive_failure` | PASS | 102.21 / 43.83 / 23.92 |
| `routing_reimport` | PASS | 26.25 / 24.13 / 16.26 |
| `settings_import_never_policy` | PASS | 26.25 / 24.13 / 16.26 |
| `settings_merge_live` | PASS | 26.25 / 24.13 / 16.26 |
| `settings_merge_one_undo` | PASS | 28.08 / 24.54 / 16.45 |
| `settings_merge_save_rollback` | PASS | 28.08 / 24.54 / 16.45 |
| `titlebar_clearance` | PASS | 25.41 / 23.93 / 16.14 |
| `welcome_keyboard_guards` | PASS | 24.05 / 23.64 / 15.99 |
| `window_size` | PASS | 24.05 / 23.64 / 15.99 |

The six Boost rows are existing harness BLOCKED gates (`Section 12 AppBoosts (app.stores.boosts)`). Expected missing/invalid-extension failures count as PASS because the App reports the correct failure. All 87 boolean gates and cleanup passed; suite exit 0.

## Timing and final full verification

The final numerical tables and complete `verify-all` summary are attached to [PR #248](https://github.com/SergeSerb2/open/pull/248). Local receipts: `resume/blend-comparison.json`, `resume/returning-launch.json`, `resume/verify-final/summary.txt`, and their logs. All attempts and loads are retained, including any initial failure and focused rerun. No baseline or threshold is changed.

`tools/e2e/onboarding_frames.py` interleaves screen/normal blend three times each on the same already-built App. It asserts actual layer filters, uses sound off, records p50/p95/max/drops and start/end loads, and requires an absolute median p95 difference <0.5 ms with no additional summed screen drops. `OPEN_INTRO_NORMAL_BLEND=1` is read only in automation builds. Production uses screen blend unless the authorized fallback is applied and documented in the PR.

`tools/e2e/onboarding_launch.py` seeds a real saved browser.json using main’s Start Fresh flow, then interleaves five main/branch launches each without skip-first-run. It verifies the first frame/foreground and branch onboarding inactivity, retains every common numeric timing mark, and requires branch medians ≤main+5 ms. Both timing tools run under quiet then screen lock, at load1 ≤12. Shared defaults are restored in finally.

Final full command: `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main heavy.sh tools/verify-all.sh`. Functional checks run at any load, inside one owned heavy slot. Its all-product build covers the Package.swift target and resource bundle. License inventory has the original-score row and both new bundle files; there is no dedicated license-bundle verifier.

## Size, decisions and remaining limits

Against Debug main `cdd147ca`, regular App files without following symlinks: main 629,482,377 bytes; branch 630,285,816 bytes; delta **803,439 bytes**. New package Debug objects: 697,160 bytes; new App controller/automation objects: 393,256 bytes; total 1,090,416 bytes. The m4a is 313,428 bytes. No Release App build is required or claimed.

- Continue bridges to Section 7’s existing window here; the steps PR replaces it. Music keeps its clock across Continue and fades only on finish/close.
- The original −1 dBFS master peak target remains a documented deviation: PCM −2.900217 dBFS. The approved curve meets v2’s −14 LUFS plateau and player volume 0.5 (~−20.02 LUFS heard). No score retune is included.
- The final suspended chord resolves at 17.75 s, the midpoint of the unspecified final phrase.
- Existing Boost BLOCKED rows and release-credit preview warnings remain distinct from intro acceptance.

Exact timeline/copy/lighting/window/audio rules: [onboarding.md](onboarding.md). All nine 2x PNGs, including **intro-03.5@2x.png** and **intro-10.2@2x.png**, are under `/Users/serge/.t3/projects/open/.re/handoff/sections/s17/c2/`. Final native initial/completed/Reduce Motion captures are in `resume/`; they replace pre-light native captures as current evidence. Full sound measurements, all 40 half-second RMS bins and historical attempts remain below.

## Review checklist

Source: `docs/review-checklist.md`. Native evidence below comes from the merged-main build; historical pre-light receipts are not substituted for it.

| Review item | Result | Evidence |
|---|---|---|
| External sizes and decoded bounds | PASS | Fixed bundled score/reference; renderer path ≤4096 UTF-8 bytes; exact automation allowlist and ≤32-byte action; decoded score ≤965000 stereo frames at 48 kHz; frame samples ≤4096. |
| Worst single allocation | PASS | Fixed 2x RGBA canvas 16,384,000 bytes; decoded audio <8 MiB. Bounds stated in source. |
| Boundary input proofs | PASS | Real command path accepts all valid actions; refuses 33-byte/unknown/non-string actions and extra keys. Offline malformed-duration/tail and CLI-shape proofs reject altered inputs. Fixed bundled assets do not accept arbitrary external media. |
| Unknown/trailing data | PASS | Exact renderer argument shape, argparse, automation key/action allowlists. Native `unknown_automation_input_refused` and its negative pass. |
| Callback may release owner | PASS | Final owner work deferred to Tasks, weak captures, documented close delegate. |
| Close / repeated / animated close | PASS | Native intro Cmd-W quits; setup Cmd-W releases music/dim; animation-interruption cleanup and forced early failure clean all owned windows. Idempotent finish/stop guards. |
| Unique IDs / old generations | N/A | No new external request-ID protocol. Controllers own their NSWindow instances directly. |
| Flush held state | PASS | Intro writes no snapshot. Existing guarded Section 7 save and browser landing passed; replay preserves saved bytes. |
| Real key paths | PASS | OEApplication Return, Space, Esc, Cmd-T/L guards, setup Cmd-W and intro Cmd-W exercised through `key route=app`. |
| Key ownership after main merge | PASS | Merged cdd147ca retains menu/key routes; merged-build native onboarding and firstrun flows pass. |
| Hidden flags hide actions | PASS | Replay menu is Debug-only; device failure/reduce/measurement and blend override are automation-only. Native button disabled without a default key before its beat. |
| Each new check rejects broken conditions | PASS | 33/33 real contrasting-state checks reject the same predicates; five offline altered-input failures preserved. |
| Pixel comparison | N/A | Renders and native PNGs are manual design artifacts. No assertion uses PNG length or file size as a visual comparator. |
| Specific window assertions | PASS | Actual onboarding ID/size, dim alpha/parent, FirstRunNativeWindow and BrowserWindow checked. Dim is excluded from ordinary window snapshots/lists. |
| Configured timing/deadline checks | PASS | Single IntroTimeline; recorded common-clock schedule delta 0 ms; configured button/idle deadlines. Loaded strict-120-Hz row is INFO. Separate blend/launch receipts state all loads. |
| Isolated roots/cache/ports/preferences | PASS | Disposable roots/cache/socket, synthetic Arc source, finally-restored shared defaults; native cleanup passes. |
| No human-dependent cleanup | PASS | Forced early suite failure while intro+dim visible exits 1 as intended; owned cleanup reports zero windows/processes. No new real Open crash report during native checks. |
| Reduce Motion | PASS | Real `--reduce-motion` crossfade-only/static-orb predicate and contrasting state pass; native and 2x final PNGs retained. |
| Interrupted animation uses presentation | PASS | Handoff reads presentation opacity; idle converts local time; skip explicitly selects the final state. |
| Resize/frame changes | PASS | Nonresizable window; layout disables implicit actions; v2 small-screen sizing. |
| Real-window visual review | PASS | Final native initial/completed/Reduce Motion PNGs captured from OUR window. Completed PNG viewed; lead approved layout/beats and requested light/spacing fixes, present in final images. No reference-app capture copied. |
| Docs match implementation | PASS | Exact timeline in docs/onboarding.md; current validation includes every gate, load, historical attempt and peak deviation. |
| Plan / followups / PR agree | PASS | Current PR records the Section 7 bridge, six existing Boost BLOCKED rows, timing results, full-verifier results and sound peak deviation. Shared status/followups remain lead-owned. |


<details>
<summary>Historical receipts from 2026-11-07 (superseded acceptance state)</summary>

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

</details>

