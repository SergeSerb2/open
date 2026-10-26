# Step 4: native Boost editor

The native child-panel editor uses the existing Profile BoostStore, matcher and injection planner.
All fixtures use synthetic sites and suite-scoped preferences. The app-shell binding stays in
Steps 3/5; Zap and code tools stay disabled until Steps 6/7.

Lead decisions are recorded in plan §§4.3–4.4: host scopes keep their existing subdomain meaning,
IP scopes offer one host item plus the path item, and the first legacy color edit replaces the
filter as one undoable change. The harness reloads brightness 2 / invert 0.5 from the real file,
edits through a native control, then compares serialized filter bytes after Cmd+Z and reload.

Generate with `sitecontrol-render screens --group editor --out docs/sitecontrol/step-4`.
`sitecontrol-render check` verifies every PNG against [SHA256SUMS](SHA256SUMS), all native flows,
real AX hierarchies, exact panel fill after resize, and the release performance budgets.

The menu contact sheet captures AppKit's actual popup content. CARenderer cannot reproduce the
WindowServer backdrop of NSVisualEffectView, so the contact sheet supplies an opaque panel-color
plate and places the captured content beside the offscreen anchor. Other editor states render
the native child panel directly over the synthetic page.

| State | Light 1x | Light 2x | Dark 1x | Dark 2x |
|---|---|---|---|---|
| editor-interstitial | [light 1x](editor-interstitial-light@1x.png) | [light 2x](editor-interstitial-light@2x.png) | [dark 1x](editor-interstitial-dark@1x.png) | [dark 2x](editor-interstitial-dark@2x.png) |
| editor-simple | [light 1x](editor-simple-light@1x.png) | [light 2x](editor-simple-light@2x.png) | [dark 1x](editor-simple-dark@1x.png) | [dark 2x](editor-simple-dark@2x.png) |
| editor-advanced-color | [light 1x](editor-advanced-color-light@1x.png) | [light 2x](editor-advanced-color-light@2x.png) | [dark 1x](editor-advanced-color-dark@1x.png) | [dark 2x](editor-advanced-color-dark@2x.png) |
| editor-neutral-page | [light 1x](editor-neutral-page-light@1x.png) | [light 2x](editor-neutral-page-light@2x.png) | [dark 1x](editor-neutral-page-dark@1x.png) | [dark 2x](editor-neutral-page-dark@2x.png) |
| editor-not-active | [light 1x](editor-not-active-light@1x.png) | [light 2x](editor-not-active-light@2x.png) | [dark 1x](editor-not-active-dark@1x.png) | [dark 2x](editor-not-active-dark@2x.png) |
| editor-global-off | [light 1x](editor-global-off-light@1x.png) | [light 2x](editor-global-off-light@2x.png) | [dark 1x](editor-global-off-dark@1x.png) | [dark 2x](editor-global-off-dark@2x.png) |
| editor-legacy | [light 1x](editor-legacy-light@1x.png) | [light 2x](editor-legacy-light@2x.png) | [dark 1x](editor-legacy-dark@1x.png) | [dark 2x](editor-legacy-dark@2x.png) |
| editor-menu | [light 1x](editor-menu-light@1x.png) | [light 2x](editor-menu-light@2x.png) | [dark 1x](editor-menu-dark@1x.png) | [dark 2x](editor-menu-dark@2x.png) |

## Verification

Merged origin/main `e44b40d4b1b1beda37673e7209bed958c79cbc11` before the full gate.
Checked code commit: `912f43f16c72dae0a98ca16cfb32509de94fc141`.
`sitecontrol-render check`: 580/580 PASS, including 112 native flows.
All 17 full-gate checks PASS. The existing Boosts browser harness also PASSes.
The release build has no compiler warnings or errors. Machine: Apple M5 Pro.

| NAME | RESULT | SECONDS |
|---|---|---|
| build | PASS | 19 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 1 |
| suggest-check | PASS | 10 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 77 |
| sidebar-render | PASS | 23 |
| commandbar-render | PASS | 13 |
| sitecontrol-render | PASS | 23 |
| boosts | PASS | 2 |

Panel first draw: main-thread CPU p95 4.589 ms; wall p95 4.597 ms; 20 Boosts, 12 tiles, extensions unavailable (section hidden), 2x

Editor idle: 4.576 ms main-thread CPU in 2 s, no host work=true; ten-page refresh max 0.072 ms

Editor: wheel event p95 0.039 ms (500 native events); previews 59 in 1 s / 120 Hz; simple open p95 8.624 ms; hue sample 7.199 ms off-main=true

The documented Boosts acceptance flow also passes 26/26 required H/A/S-A/S/O/E cases
(38/38 checks including the existing extra checks). The run serves this worktree’s production
resources, verifies their HTTP bytes against the source hashes, and uses the existing
headless Chrome driver with only its localhost origin changed. Receipts:
[acceptance results](boosts-acceptance.json) and [served-source hashes](boosts-resources.json).
