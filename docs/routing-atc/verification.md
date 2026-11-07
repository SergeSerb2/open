# Air Traffic Control acceptance — 2026-11-06

Section 10 adds Profile-scoped routing, native grouped destination menus,
live-window Automatic Test, nested Arc import, and the Settings entry point.
The implementation is `c5597282`; the final App receipts use `713d13cb`.
Merge `528f2446` includes main `ae0eb050` and leaves that source tree unchanged.
The post-merge Debug build also passed. No engine source changed.

Local receipts are under `.re/s10/atc-implementation/` in the project root.
They are excluded from git. Real Arc data stays in that private evidence area;
only aggregate counts appear here.

| Acceptance | Result | Receipt |
|---|---|---|
| Release package build | PASS, no warnings or errors | `release-2.log` |
| Debug App build, including after main merge | PASS | `debug-final.log`, `debug-post-merge.log` |
| Real route CLI | A1–A24 PASS | `full-final-2/route.log` |
| Existing schema-1 nil destination payloads | Byte-identical roundtrip; nil stays `{}` | A21 |
| New payload read by old main decoder | PASS with main `98350a07` release CLI | A22; `OPEN_ROUTE_OLD_CLI` |
| Nested Arc destinations and components | All six forms, fallback count, matches/contains, ordered components PASS | A23–A24 |
| Copied real Arc import | Before/after: 1 routing rule, 0 skipped rules; after: 0 destination fallbacks | `arc-routing-counts.json` |
| Settings preview | 44/44 PASS; render and wrapper validation PASS | `full-final-2/settings-preview.log` |
| Commands and suggestions | PASS; commands missing/extra/different 0/0/0, allowed-missing 11 | `full-final-2/commands-dump.log`, `suggest-check.log` |
| Real-App routing | 13/13 PASS, cleanup PASS | `routing-positive-final/results-routing-debug.json` |
| Real-App Little Open | 39/39 PASS, cleanup PASS | `littleopen-final/results-littleopen-debug.json` |
| Real-App sidebar | 19/19 PASS; existing durable-storage row SKIP, covered by the dedicated Profiles suite; cleanup PASS | `sidebar-final/results-sidebar-debug.json` |
| Sidebar comparison | 13/13 PASS; tables byte-identical | `full-final-2/sidebar-compare.log` |
| Space editor under screen worker | 237/237 PASS on branch and unchanged main | `space-editor-locked-branch.log`, `space-editor-locked-main.log` |

The routing App run proves that a second-Profile Space uses that Profile's
engine context: its cookie is visible in Work and absent in Default. It also
proves the explicit Little Open Profile hint, separate windows for the same URL
in different Profiles, and Settings pane `links` with scroll target `links-rules`.
The App runs have no focus interruptions and leave no owned processes or windows.
Their starting load averages (1/5/15 minutes) were 15.87/22.30/36.87 for routing,
17.16/19.80/33.32 for Little Open, and 21.52/19.58/30.37 for sidebar.

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

The first two full verify attempts retained timing failures. The first also
exposed the Space editor's missing screen serialization; the identical fix
landed separately on main in #207 before the final merge.

| Earlier command-bar attempt | Load 1/5/15 | CPU p95, limit <8 ms | Inline overhead, limit ≤0.3 ms | Raw result |
|---|---|---|---|---|
| `full-final-1` | 51.2/76.2/62.6 | 7.03 ms PASS | 0.301 ms FAIL | FAIL |
| `full-final-2` | 21.5/31.2/32.5 | 9.38 ms FAIL | 0.421 ms FAIL | FAIL |
| `full-post-merge` | 25.3/21.9/24.1 | 7.82 ms PASS | 0.419 ms FAIL | FAIL |

This change touches `OpenCommands` and `OpenSuggest` aliases, so the strict
command-bar rule applies: every row must pass in one run. Split-pass and paired
main exceptions do not apply. No threshold, baseline, comparator, or allowlist
was changed.

The [1x](profile-destination@1x.png) and [2x](profile-destination@2x.png)
rule-sheet images are synthetic offscreen review renders. The preview inspects
the native menu's sections, enabled state, and item order. Arc editor/menu
captures, Test existence, invalid drafts, empty state, and matches semantics
remain capture follow-ups in `docs/followups.md`; these results do not establish
Arc visual or matching parity.
