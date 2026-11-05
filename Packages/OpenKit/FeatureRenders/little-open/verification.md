# Little Open library — Step 6a

2026-11-05, M5 Pro, built-in 2× Retina display. Source base: `7254c0a3`.
The App still shows `showLittleOpenStub`; no App source is changed here.

The real unordered AppKit windows, command bar, picker, BrowserModel and SQLite
ArchiveStore are exercised by `features-render`. Only the page host is fake.
No Arc launch, copied Arc assets, desktop input, unit tests, Chromium tree edit
or Chromium build was used. Native App key delivery and B9/B10 remain Step 6b.

## Renders

These contain generated Profiles/Spaces and `example.com` pages only. Dimensions
are pixels at 2×; geometry checks use points. The exporter keeps native backing
scale before taking its CARenderer snapshot. A requested 1× export downsamples
that complete image, avoiding the native text-store loss on a 2×→1× rehost.

| Scene | Point size | PNG |
|---|---|---|
| `little-bar` | 490×329 | [980×658](little-bar.png) |
| `little-page` | 1185×832 | [2370×1664](little-page.png) |
| `little-picker` | 244×192 | [488×384](little-picker.png) |

Commands: `features-render render --scene little-bar|little-page|little-picker
--out FILE.png`. All three PNGs were inspected. They are offscreen evidence;
they do not claim native pixel acceptance against the Arc capture.

## Focused verification

`features-render check --only little-open`: **47 passed, 0 failed**. L1 checks
the injected AppKit frame `[2050,1061,490,329]`, focus, window controls, new blank
windows and URL resurface without reload. L4 checks the 1185×832 transition,
fixed top-right, full-bleed page, title controls at W=1185 and W=800, including the exact 14 pt Profile icon, name origin and 13 Regular host centering with two Profiles, the smaller
screen clamp `[120,220,860,610]`, minimum size, no autosave/animation, 32 pt NUX
band and automation state. L5 covers recent Profile Space, focus Undo/Redo,
pill/command moves, Profile filtering, typing, Up/Down, Return and Escape. L6
covers same-key timestamps and a second press 0.2 s later. L7 covers all bar
intents and confirms no user-close archive. L8 checks exact deadlines, activity
notification, Never, no sessions and the SQLite reason/location/Profile/time.

The old R-T5 Little Open toast expectation is superseded by the Step 6a copy
contract: the title-bar button writes the URL without creating a library toast.

## Negative proofs

The production source was deliberately changed, built and run through the same
CLI. All changed files were then restored byte-for-byte. No baseline or limit
was changed. The combined negative run failed 16 of 42 Little Open assertions;
the additional focus proof failed 1 of 43. The 15 pt Profile-icon mutation failed 2 of 47. The command-bar negative run failed
2 of 113 flows.

| Gate | Broken production behavior | Expected failures |
|---|---|---|
| L1 | screen inset 20→21 | 2 |
| L4 | title-bar height 47→48, plus inset above | 3 |
| L4 Profile | Profile icon width 14→15 | 2 |
| L5 | case-insensitive filter→literal comparison | 4, including dependent moves |
| L5 focus | skip focus-history updates during Undo/Redo | 1 |
| L6 | same-press tolerance 0.05→0 | 2 |
| L7 | close emits programmatic dismissal; disable switch callback | 2 |
| L8 | earliest→latest deadline, wrong reason and location prefix | 3 |
| Command bar | `.littleOpen` emits `.newTab`; close emits programmatic dismissal | 2 |

## Guesses kept from the lead's v1 decisions

- Pointer-screen `visibleFrame` placement, fixed first/page defaults, commit as
  the growth trigger, screen clamp, no animation, per-window changes and no
  autosave. The no-display 1440×900 fallback is also a guess.
- Every distinct blank press creates a window, including while another blank
  window is key. Escape closes the bar state.
- Fixed dark solid fills replace the unproven material and unknown Space tint.
  Close-plate internals, Profile/host gaps, Profile width cap, narrow-window chip
  hiding, fitted host centering, divider and keycap internals are guesses.
- Multi-Profile chip visibility and menu action, host click/Cmd+L overlay, and
  the 20 pt page-overlay margins follow the plan's guesses.
- The pill uses the model's most recent focused Space of this Profile. Picker
  Profile scope, substring filtering and keys are guesses. Its interior insets,
  icon treatment and eight-row scrolling viewport are guesses around the
  measured approximately 244 pt width and 46 pt row pitch.
- The intro uses the specified copy and a 32 pt title-bar-colored band. Its
  simple placement and marking Seen when first shown are guesses.

The App must pass the same key-down timestamp from the menu and global hotkey,
set `onSwitchToTab`, `performCommand` and `isActionEnabled`, bind main-window
promotion, and use `onChange`/`nextExpiry(now:)` with its single ExpirySweeper.
Native global/menu delivery, focus, real-window comparison and App integration
are intentionally pending.


## Full verification receipts

The first full run checked `471fca84`, starting at 14:13 with load
**4.68 / 6.29 / 7.72**. It returned 19 PASS, 3 FAIL, no SKIP. The three failures
are exactly the built-in-display main baseline: Space 0 PNG, the editor's three
P1 PNGs (175 functional rows pass), and the sidebar color gates below.

| Display baseline | Result on this branch and unchanged main |
|---|---|
| `space-legacy` | legacy Space 0 PNG differs |
| `space-editor` | 175 pass; 3 P1 PNG identity failures |
| `sidebar-compare` | static-inactive ΔE00 1.31 > 1.17; selected-pinned 2.71 > 1.73; yellow 2.25 > 1.95 |

The sidebar comparison reports 13/13 main/branch tables byte-identical and
zero position/ink/color drift. Site Control passed 1469/1469, including F24
frame `(-34,258,250,232)`. All timing gates passed; no quiet rerun was needed.
The command bar passed 136/136 (CPU p95 3.59 ms; completion overhead +0.151 ms),
sidebar 624/624, features 556/556 plus idle 19/19. `commands-dump` remained
missing/extra/different **0/0/0**, allowed missing **11**. The 21 existing
command-bar PNGs were rerendered on the final source and remain byte-identical
to the initial `7254c0a3` exports.

Debug App build passed against `open-engine-s8-main`'s recorded distribution;
load at start **5.67 / 7.69 / 9.20**. That build checked the implementation before the final Profile-icon frame correction.
The corrected production library receives a new Debug build before publication.

After the first run, main advanced to `b913e127` (PR #170, docs only). That main
was merged before PR publication; a second full gate checks the merged head.


Final geometry audit: the Profile icon now owns an explicit `[97,17,14,14]`
view and the name starts at x114. Two-Profile checks at W=1185 and W=800 also
assert centered 13 Regular host text. The focused flow passes **47/47**.
Deliberately restoring a 15 pt icon produces **45 PASS / 2 expected FAIL**;
source was restored byte-for-byte. The page PNG above was regenerated and
inspected after this correction.

The fresh Debug App build on `d6c94a36` **passed** with the final production
source. Its initial load was **29.44 / 19.97 / 14.26**. The final full run is
on this merged production source; its complete table is included in the PR.


## Final merged-source gate

Production source and PNGs checked at `edd5118069d63fba0a093ae83497a02b6ecd12a4`,
after merging main `b913e127`. This receipt-only update changes neither.

The full run started with load **44.01 / 30.54 / 19.76**. Raw result:
**18 PASS, 4 FAIL, 0 SKIP**. The ad-block failure was timing only (matches
5000/10000, configuration verified): lookup p95 **1.652 ms > 1 ms**.
Per CHILD-RULES item 4, only `adblock-perf` was rerun under the quiet lock.
That run started with load **10.31 / 10.00 / 13.17** and passed: lookup p95
**0.277 ms**, Profile open/integrity p95 **3.9316 ms < 10 ms**. Neither source
nor thresholds changed between the two runs.

| Check | Result | Seconds |
|---|---|---|
| build | PASS | 20 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| space-legacy | FAIL | 1 |
| space-editor | FAIL | 3 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 14 |
| commands-dump | PASS | 0 |
| route | PASS | 0 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | FAIL | 2 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 86 |
| sidebar-render | PASS | 113 |
| sidebar-compare | FAIL | 103 |
| commandbar-render | PASS | 33 |
| features-render | PASS | 289 |
| sitecontrol-render | PASS | 239 |
| boosts | PASS | 9 |

Quiet rerun (`lockf quiet` outside `heavy.sh`, `--only adblock-perf`):

| Check | Result | Seconds |
|---|---|---|
| build | PASS | 3 |
| adblock-perf | PASS | 6 |

All functional gates pass. The remaining three failures are
**FAIL (machine: built-in display main)**, with the same rows/numbers listed
above. Features pass **560/560**, including **47/47** Little Open flows, plus
idle **19/19**. Command bar passes **136/136** (CPU p95 **3.17 ms**, completion
overhead **+0.024 ms**). Sidebar passes **624/624**; Site Control **1469/1469**.
`commands-dump` remains **0/0/0**, allowed missing **11**.

The 289 s features receipt includes the wait for another run's on-screen
priority flag; its offscreen child completed normally. The 239 s Site Control
receipt includes lock queue time. Native cleanup reaped its renderer, found
zero surviving owned apps and removed its private root. Cancelled/incomplete
pre-final runs are not counted. No privileged process inspector was used.
