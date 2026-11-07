# Air Traffic Control acceptance — 2026-11-06

Section 10 adds Profile-scoped routing, native grouped destination menus,
live-window Automatic Test, nested Arc import, and the Settings entry point.
The implementation is `c5597282`. Final integration `3763aa41` merges main
`d5817079` (#209, private windows), after #207's identical screen-worker fix.
Both the post-#209 Debug App build and Release tool build passed; the Release
build reported zero warnings and errors. No engine source changed.

Automatic Test and external intake use the same `AppLinkExecutor.snapshot()`.
Its ordered controllers must have a persistent standard-window ID; private
windows have separate models and never enter that set. The Settings adapter
uses `frontStandardWindowController` for its initial Profile and retains the
shared snapshot provider (`App/Settings/AppSettingsActions.swift:25–26`,
`App/ExternalLink/AppLinkExecutor.swift:12–28`).

Local receipts are under `.re/s10/atc-implementation/` in the project root.
They are excluded from git. Real Arc data stays in that private evidence area;
only aggregate counts appear here.

| Acceptance | Result | Receipt |
|---|---|---|
| Release package build | PASS, no warnings or errors | `full-after-209/build.log` |
| Debug App build, including after main merge | PASS | `debug-after-209.log` |
| Real route CLI | A1–A24 PASS | `full-after-209/route.log` |
| Existing schema-1 nil destination payloads | Byte-identical roundtrip; nil stays `{}` | A21 |
| New payload read by old main decoder | PASS with main `98350a07` release CLI | A22; `OPEN_ROUTE_OLD_CLI` |
| Nested Arc destinations and components | All six forms, fallback count, matches/contains, ordered components PASS | A23–A24 |
| Copied real Arc import | Before/after: 1 routing rule, 0 skipped rules; after: 0 destination fallbacks | `arc-routing-counts.json` |
| Settings preview | 44/44 PASS; render and wrapper validation PASS | `full-after-209/settings-preview.log` |
| Commands and suggestions | PASS; commands missing/extra/different 0/0/0, allowed-missing 11 | `full-after-209/commands-dump.log`, `suggest-check.log` |
| Real-App routing | 13/13 PASS, cleanup PASS | `routing-after-209/results-routing-debug.json` |
| Real-App Little Open | 39/39 PASS, cleanup PASS | `littleopen-after-209/results-littleopen-debug.json` |
| Real-App sidebar | 19/19 PASS; existing durable-storage row SKIP, covered by the dedicated Profiles suite; cleanup PASS | `sidebar-after-209/results-sidebar-debug.json` |
| Sidebar comparison | 13/13 PASS; tables byte-identical | `full-after-209/sidebar-compare.log` |
| Space editor under screen worker | 237/237 PASS on branch and unchanged main | `space-editor-locked-branch.log`, `space-editor-locked-main.log` |

The routing App run proves that a second-Profile Space uses that Profile's
engine context: its cookie is visible in Work and absent in Default. It also
proves the explicit Little Open Profile hint, separate windows for the same URL
in different Profiles, and Settings pane `links` with scroll target `links-rules`.
The App runs have no focus interruptions and leave no owned processes or windows.
Their starting load averages (1/5/15 minutes) were 18.37/26.88/33.17 for routing,
16.90/24.08/31.42 for Little Open, and 18.37/23.44/30.80 for sidebar.

All builds and verify-all runs use `heavy.sh` with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`. New jobs from 17:32 use
the lead's `s10-heavy.sh` token wrapper before entering `heavy.sh`. Each App suite runs alone
under `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`, after the priority check,
with no concurrent build from this worktree. The routing suite restores its four
shared defaults in `finally`. These are real CLI, preview, and App flows; no unit
tests were added.

| New gate | Deliberate regression | Observed negative | Restored positive |
|---|---|---|---|
| A18 | Saved pre-S10 CLI | FAIL Profile standard-window order | PASS |
| A19 | Saved pre-S10 CLI | FAIL stale/empty Profile skip | PASS |
| A20 | Saved pre-S10 CLI | FAIL Little Open Profile hint | PASS |
| A21 | Encode nil Profile as null | FAIL byte/schema guard | PASS |
| A22 | Saved pre-S10 CLI as encoder | FAIL Profile payload preservation | PASS; old decoder also loads new output |
| A23 | Saved pre-S10 CLI | FAIL nested destination context | PASS |
| A24 | Saved pre-S10 CLI | FAIL matches/components | PASS |
| `links-destination-picker` | Disable grouped branch | FAIL native menu order/grouping | PASS |
| `links-profile-issues` | Disable Profile validation | FAIL missing Profile error | PASS |
| `links-profile-destinations` | Drop saved Profile | FAIL on-disk destination | PASS |
| `links-test-automatic` | Ignore snapshot provider | FAIL live front-window choice | PASS |
| `routing_same_url_little_open_profile` | Remove Profile from reuse comparison | FAIL | PASS |
| `routing_air_traffic_control_entry` | Wrong scroll target | FAIL | PASS |

The negative App run also passed engine fingerprint and owned-process cleanup.
Positive source restoration was checked against saved SHA-256 hashes.

Earlier full verify attempts retained timing failures. The first also
exposed the Space editor's missing screen serialization; the identical fix
landed separately on main in #207 before the final merge.

| Run | Load 1/5/15 | CPU p95 (<8 ms) | Inline overhead (≤0.3 ms) | Raw result |
|---|---|---|---|---|
| full-final-1 | 51.2/76.2/62.6 | 7.03 ms | +0.301 ms | 150/151; FAIL |
| full-final-2 | 21.5/31.2/32.5 | 9.38 ms | +0.421 ms | 149/151; FAIL |
| full-post-merge | 25.3/21.9/24.1 | 7.82 ms | +0.419 ms | 150/151; FAIL |
| full-final-head | 23.9/27.1/27.3 | 11.15 ms | -0.012 ms | 150/151; FAIL |
| full-after-209 | 27.4/43.3/40.2 | 10.89 ms | +0.509 ms | 149/151; FAIL |
| commandbar-quiet-strict-2 | 14.0/14.8/21.1 | 11.29 ms | +0.222 ms | 150/151; FAIL |

The original strict command-bar rule applied because this change touches
`OpenCommands` and `OpenSuggest` aliases. The first executed quiet rerun still
failed row 150. A second attempt was stopped before lock acquisition or execution
when the lead reserved the quiet lock for Section 4.

The Section 10 lead's **2026-11-06 18:27 ruling**, for ATC integration
`3763aa41`, requires a paired comparison after “quiet window over”: unchanged
main (`ae0eb050` or later) then branch, repeated three times under the quiet lock,
each at load1 ≤20. Both CLIs run from their own `.build/release` folders with their
resource bundles. Row 150 passes when the branch median is ≤main median ×1.10.
Row 151 passes when its branch median is ≤main median ×1.10 or ≤0.3 ms.
All strict and paired runs must remain visible. Stop and report if the pair fails.
This specific lead ruling replaces strict-only acceptance for this PR; no source
threshold, baseline, comparator, or allowlist was changed. The paired result is
pending the end of the quiet window.

The [1x](profile-destination@1x.png) and [2x](profile-destination@2x.png)
rule-sheet images are synthetic offscreen review renders. The preview inspects
the native menu's sections, enabled state, and item order. Arc editor/menu
captures, Test existence, invalid drafts, empty state, and matches semantics
remain capture follow-ups in `docs/followups.md`; these results do not establish
Arc visual or matching parity.


## Final full verification

The full run after #209 completed with 23 PASS and one timing FAIL; no SKIP.

| Name | Raw result | Seconds |
|---|---|---|
| build | PASS | 111 |
| commands-demo | PASS | 3 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 130 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 31 |
| commands-dump | PASS | 0 |
| route | PASS | 8 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 3 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 93 |
| sidebar-render | PASS | 116 |
| sidebar-compare | PASS | 25 |
| commandbar-render | FAIL | 47 |
| features-render | PASS | 103 |
| extensions-render | PASS | 9 |
| sitecontrol-render | PASS | 160 |
| boosts | PASS | 8 |
| import-arc | PASS | 1 |
