# Sidebar S6 handoff

Original S6 base: 2d51f14a1207c00157edb90f51459d97b7b1096b (A2 over A1).
Branch: t3/sidebar-s6-folder-peek. Parent owns the PR/stack.

## PR #135 P2 fixes over d88c839d and main 3130eafa (2026-10-28)

Review comments: [4408016684](https://github.com/SergeSerb2/open/pull/135#discussion_r4408016684)
(unload fallback), [4408016687](https://github.com/SergeSerb2/open/pull/135#discussion_r4408016687)
(peeked drop indices). Original reviewed head:
`d88c839d516da08c46e1d08ddad51fc2cb77cf8e`.

### Reproduction against the reviewed head

The first run adds only the real harness flows to d88c839d. Checkpoint
`5b023d89` preserves those initial flows; its name marks a reproduction checkpoint.
The six drop failures below are valid. The initial unload fixture was later found
to be a placeholder rather than a loaded tab, so its first failure is **invalid as
unload regression proof**. The corrected loaded-tab baseline run is recorded
below; do not use the first feature failure as evidence of the product bug.
Initial command:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render --keep-logs
```

Build PASS. Sidebar-render **597 passed, 6 failed**; features-render **365 passed,
1 failed**. The six exact drop failure messages are `FP-drop node above C`,
`FP-drop node below C`, `FP-drop node on C`, and the corresponding three `URL`
rows, each ending `maps peeked C in [A,B,C] to model order`. Both `on folder`
controls PASS. The initial feature failure (fixture error, not valid product proof) is:

```text
FAIL FP-unload fallback selects containing split, shows both panes and enables split commands
```

The drop flows invoke the native outline's `validateDrop` and `acceptDrop`, the actual
sidebar delegate/model commands, and the real BrowserWindowController/container
flow. They do not call an isolated mapping helper. The existing feature harness
uses its existing web-content factory; the native E20 extension separately covers
the real engine-backed App's hover action. No unit tests were added.

Private initial log: `.re/s6/review-135/before.log`; detailed logs:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-191319.OnKznF/`.

### Corrected loaded-tab baseline proof

Raw `Tab` fixtures start in `.placeholder`. The new fixture must explicitly mark
its tabs `.live`, as the existing feature fixture does, so the controller actually
creates and unloads a host. The earlier first full run fails this invalid fixture;
it is not a product failure or a final green receipt. The corrected fixture also
prints the loaded, accepted, selected-split, pane-count and command states.

Export `git archive d88c839d` to `.re/s6/review-135/baseline-d88`; overlay only the
feature harness flow with live tabs and its state receipt. BrowserWindowController,
SplitViewController and BrowserModel are byte-verified against that exact commit.
No baseline product code or new row-readback API is overlaid. From that export:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only features-render --keep-logs
```

**Expected FAIL, 365 passed / 1 failed; build PASS.** Exact diagnostic and failure:

```text
FP-unload receipt loaded=true accepted=true selectedSplit=false visiblePanes=1 splitCommand=false
FAIL FP-unload fallback selects containing split, shows both panes and enables split commands
```

Baseline log: `.re/s6/review-135/baseline-feature-red.log`; detailed logs:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-193338.HKjNr4/`.
Export provenance is `baseline-d88/REPRO-PROVENANCE.txt`. The same corrected fixture
on the fixed merged source reports `loaded=true accepted=true selectedSplit=true
visiblePanes=2 splitCommand=true`, and **380/380 PASS**, including actual row
highlight readback. Intermediate fixed-source log: `features-valid-fixture.log`;
its first launch used the current worktree rather than the export and is recorded
as a green current-source run, never a baseline failure. The separate baseline
command above runs from the exported directory and supplies the valid red proof.



### Merge and fixes

Merged `3130eafaef8bf3e160b10d2d83023ac8e5b388f7` as `2bd8040b` before the final
checks. Retain main's Cmd+9, Include Favorites, Ctrl+Tab switcher, selection and
cycle paths, commands, automation, harnesses and docs. Conflicts are docs-only:
combine all S6 and TS-C1 followups; use main's refreshed status rows while retaining
S6's implemented peek/motion rows. No code path was dropped. Final audits find
no duplicate top-level Python definitions and no duplicate automation labels
(144 command labels).

- `BrowserModel.sidebarSelectionID(for:)` is a shared O(1) lookup which promotes
  a flattened pane candidate to its containing split. Both unload fallbacks use
  it before selection. Plain tabs and nil retain their prior behavior; selecting
  the split keeps both panes, split commands, row highlighting and shown-tab
  bookkeeping correct. It adds no model mutation or undo step.
- `SpacePageView.dropDestination` maps a peeked folder's displayed 0/1 boundary to
  the retained child's model index / index + 1. Both node and URL acceptance use
  this destination. The ON-child validation retarget remains in displayed outline
  coordinates, avoiding a second translation. Drop ON the folder itself still
  appends at the full model child count. Stale out-of-range peek positions reject.
- Eight FP-drop flows cover above C, below C, ON C and ON the folder for both node
  moves and URLs. The unload feature flow also checks the actual split row highlight.
  E20 uses the native hover dash with a loaded selected folder child and an outside
  split, then polls selected split ID, both visible panes, actual row highlight,
  split menu enablement and unloaded folder hosts.
- Read-only diagnostics: `sidebar-row.current` reads an existing row without
  creating an offscreen row; `tabs sidebar:true` adds `selectedNode`. Plain `tabs`
  keeps its array response. `docs/automation.md` records both fields.

No frozen PNG, visual threshold, folder motion token or engine source changes.

### Final merged-source verification

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --keep-logs
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh
```

Final full gate: **22/22 PASS, exit 0**. Sidebar-render **603/603**, including all
eight FP-drop flows (inherited SW1–SW4 skips); features-render **380/380**, including
the corrected loaded-tab split fallback and real row highlight. Commands-demo
307/307, Site Control 1471/1471. All original frozen-image/comparison checks PASS.
The earlier full invocation's only failure was the invalid placeholder fixture;
it remains recorded in `verify-full.log`, not relabelled as a product failure or
an accepted full gate. The corrected final run is `verify-full-final.log`.

| Full gate row | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 0 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 12 |
| commands-dump | PASS | 0 |
| route | PASS | 0 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 79 |
| sidebar-render | PASS | 108 |
| sidebar-compare | PASS | 97 |
| commandbar-render | PASS | 14 |
| features-render | PASS | 49 |
| sitecontrol-render | PASS | 49 |
| boosts | PASS | 7 |

Full logs: `.re/s6/review-135/verify-full-final.log` and
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-193631.uTHAMb/`.
App rebuild: **BUILD SUCCEEDED** (`.re/s6/review-135/app-build.log`).

Native commands, each in its own lock invocation after the rebuilt App:

```sh
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only window
```

| Native suite | Final result | Focus / cleanup |
|---|---|---|
| sidebar-completion | **190/190 PASS** | 0 interruptions; PASS |
| sidebar | **19/19 PASS**, comparison included | 0 interruptions; PASS |
| window | **74/74 PASS**, all comparison/traffic-light rows included | 0 interruptions; PASS |

`E20_Q18_unload_fallback_to_split` reads the selected split ID, two visible panes,
`current:true`, `splitCommand:true`, `unloaded:true`; its fixture first proves a
loaded selected child and that the first outside candidate belongs to the split.
The feature fallback path and the engine-backed hover action are both covered.

The first native completion invocation stopped in main's new Tab Switcher helper:
its `.re/tab-switcher` output directory did not exist. Add `mkdir(parents=True,
exist_ok=True)` at that harness call site. Keep the stored path a string. A trial
edit stored a Path object and could not serialize the second run's JSON; its
partial artifact is not accepted. That second run also queried a hotkey-only
`next-split-pane` ID through `menu-state`. This ID is not in the installed menu;
read `expand-current-split`, which uses the actual split command validator.
The core second-run state already showed the correct split ID, two visible panes,
row highlight and unloaded hosts. Final corrected run 3 passes all 190 rows.
No product behavior or limit was changed to accommodate these harness errors.
The feature flow separately checks the next-pane dispatcher itself.

Private evidence: `.re/s6/review-135/e2e-completion.log` (missing directory),
`e2e-completion-2.log` / `completion-2-state.json` (invalid harness receipts),
`e2e-completion-3.log`, `completion-final.json`, `e2e-sidebar.log`,
`sidebar-final.json`, `e2e-window.log`, `window-final.json`, and
`E20-folder-peek-final.png`. The partial `completion-2.json` remains explicitly
unaccepted. All jobs completed in the foreground. No owned Open/renderer process
remains. `git diff --check` passes. Generated `docs/engine-spike/*` is restored
before commit. No existing baseline image or visual threshold changed.




## Final integration with origin/main 61ae275a / #133 (2026-10-28)

Regression fix `c128a3a2` is preserved, including native raster contexts and the
Library readiness/failure diagnostics. The user then requested main
`61ae275a2d2bb5c68a7652c8b0f56d547c773253`. Merge it without rewriting either
history. The only conflict is `tools/verification/check.py`: use main's
`onscreen-suite` worker, interruption exit 2, queue-time exclusion and owned-child
cleanup for Site Control; keep S6's FP11 import checks and optional FP10 dispatcher.
AST audits find no duplicate top-level definitions in the runner or native e2e.
Keep all main Site Control product/calibration changes and both sets of followups,
including the peek shown-tab rule. No frozen PNG or visual threshold changes.

The final full command is:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --keep-logs
```

**22/22 rows PASS, exit 0, first invocation on the combined source.** This replaces
the earlier c128a3a2 bounded-retry acceptance as the final full-gate receipt. The
old failures below remain historical. Both legacy gates and sidebar comparison
pass. Sidebar-render is 595/595 (inherited SW1–SW4 skips), features-render 332/332,
commands-demo 307/307, Site Control 1471/1471. Site Control's editor instruction
median is 134,697,355; CPU p95 is 11.406 ms at load1 15.93. The CPU figure is INFO;
quiet-machine latency acceptance remains with the lead, as main's docs require.
Native worker cleanup reports the renderer reaped and the private root removed.

| Full gate row | Result | Seconds |
|---|---|---:|
| build | PASS | 21 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 2 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 13 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 0 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 76 |
| sidebar-render | PASS | 109 |
| sidebar-compare | PASS | 87 |
| commandbar-render | PASS | 13 |
| features-render | PASS | 42 |
| sitecontrol-render | PASS | 53 |
| boosts | PASS | 6 |

Full log: `.re/s6/regressions/verify-full-61ae.log`. Harness directory:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-183013.ktGDHj/`.

FP10 rerun after this merge, same paired fixture and unchanged parent-approved
conditional gate: **3/3 PASS**. Heavy slot wait was 295 s, excluded from timings.
Times below are ms. Each attempt keeps native layouts/frame **18/18**, scroll
p95 ≤8.33 ms and ≤baseline×1.10+0.05 ms.

| Attempt | Load1 start / transition | Parent plain median / p95 | Branch plain median / p95 | Peek median / p95 | Computed p95 limit | Scroll baseline / peek p95 (load1) |
|---|---|---|---|---|---:|---|
| 1 | 10.88 / 10.57 | 2.45 / 3.731 | 2.43 / 3.566 | 2.15 / 3.378 | 3.972 | 2.04 / 2.22 (10.97) |
| 2 | 10.57 / 10.20 | 2.22 / 3.284 | 2.12 / 3.391 | 2.00 / 3.167 | 3.780 | 2.53 / 2.50 (10.57) |
| 3 | 10.20 / 9.79 | 2.28 / 3.252 | 2.21 / 3.432 | 2.03 / 3.313 | 3.825 | 1.54 / 1.62 (10.20) |

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py
```

FP10 log: `.re/s6/regressions/fp10-61ae.log`. Both intended negative failures on
`c128a3a2` are recorded in the regression-fix section below; this merge changes
neither the S6 drawing/reconciliation code nor those controls. They are not
relabelled as another run. The <1 ms median goal remains open. Measurements at
different shared-machine loads do not establish a controlled percentage speedup.

Final combined-source App build and native check, run sequentially after FP10:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion
```

App: **BUILD SUCCEEDED**. Native completion: **164/164 PASS**, including E20 and
main's menu/auto-archive rows. Zero focus interruptions; owned-process/window
cleanup PASS. The Library checkpoint again records Archive identity empty before
the click, then visible Spaces, a nonempty identity and one hosted manager. The
three earlier hardened-flow runs below are also retained; this is a fourth
successful hardened-flow run, on the new main integration. Parent failure remains
unreproduced, rather than relabelled as an established product cause.

Artifacts: `.re/s6/regressions/app-build-61ae.log`, `native-61ae.log`,
`native-61ae.json`, `E20-folder-peek-61ae.png`. All dependent jobs are complete,
`git diff --check` passes, generated `docs/engine-spike/*` is restored before
committing, and no owned Open/renderer process remains. No PR is opened.


## Regression fixes after 34e67d60 (2026-10-28)

The parent found two frozen-image failures and one Library checkpoint failure on
`34e67d6032d7e17f26ce5f3c9153209ba7f97a18`. This round changes product drawing and
the native harness's readiness/diagnostics. It changes no baseline PNG, visual
threshold, Motion/Metrics token, Library product code or FP10 gate.

### Exact legacy pixel diagnosis

Actual CLI renders use the schema-1 fixture, 900×700 at scale 1. Compare each
renderer to **its own** committed reference: `Fixtures/space-schema1/window-N.png`
for `sidebar-render`; `Sources/space-editor-render/Resources/space-schema1/window-N.png`
for `space-editor-render`, both under `Packages/OpenKit`. These two reference sets
have intentionally different window chrome; comparing one set to the other would
produce a false header difference.

Both products had the same changed pixels. Rectangles below are `(x,y,width,height)`
in output pixels, covering each separate horizontal band of differing pixels.

| Window | Different pixels before → after | Exact differing rectangles before the fix | Largest channel delta before |
|---|---:|---|---:|
| 0 | 4,002 → 0 | (45,253,91,14), (45,294,92,14), (45,335,92,14), (45,376,92,14), (45,417,98,14), (45,458,97,14), (44,557,84,14), (44,598,87,14), (44,639,87,11) | 2 |
| 1 | 930 → 0 | (45,253,74,14), (45,294,43,14), (45,335,63,12) | 2 |
| 2 | 1,019 → 0 | folder (17,251,19,16); titles (60,294,60,12), (61,335,94,14), (45,417,65,12) | 57 |

Controlled product changes isolate both causes in `OpenSidebar/SidebarRows.swift`:

1. Flattening the title/favicon into the tab cell's backing context changed Core
   Text antialiased edge pixels. Restoring their independent backing contexts
   alone makes windows 0/1 byte-identical in **both** renderers. Window 2 then has
   exactly 192 differing folder pixels, all within (17,251,19,16).
2. The manually rasterized cached `CGImage` for the folder glyph changes native
   edge pixels. Restore AppKit `draw(_:)` using the existing own vector paths and
   colors. All **six** final PNGs are now byte-identical to their own committed
   references, not just within a perceptual tolerance.

Per-folder incremental reconciliation, cached vector paths, clean-row invalidation
and unchanged-geometry guards remain. They were not the source of these pixel
failures. The earlier receipt's cached glyph bitmap and flattened title claims
are historical and **superseded** by this fix. The strict legacy raster contract
has precedence over these two attempted optimizations.

Private pixel evidence: `.re/s6/regressions/pixels-before-correct.jsonl`,
`pixels-labels-correct.jsonl`, `pixels-fixed.jsonl`, the corresponding PNG/diff
files, and `pixels.py`. The first two files record the original and title-only
controlled product renders; the third records six byte-equal results. Both
`space-legacy` and `space-editor` also pass their original checks in the full gate.

FP6 was rerendered after the native drawing restoration. It still passes: one
solid `SidebarRole.folderPeekDots` **#B5AFFF** for all three dots; ΔE00
**1.434 / 0.837 / 1.511**, body 0.000, dots 3×3 px, pitch 4 pt, position error 0,
hover dash ΔE00 0.15. The capture-authoritative minimax fit still replaces the
rejected white-at-0.65-alpha guess; no per-dot colors or threshold edits.
`fp6-final/table.md` retains the final comparison to the cited Arc capture.

### Library checkpoint: not reproduced; remove the readiness assumption

The failed parent's JSON is unavailable. Its only retained evidence is
`/tmp/s1-gate-s6-e2e-sidebar-completion.log`, assertion after 35 passes. This round
cannot establish that run's exact cache or hosting state. Do not label its root
cause as reproduced or as a known product regression.

The unchanged old App first passed the full suite **164/164**, including the
checkpoint (`library-before.json`). LibraryWindow, LibraryViewModel,
LibrarySpacesSection and AppSettingsActions product source is unchanged from
`dee105e6`. No Library product fix is made.

A concrete harness timing assumption remains: it sampled passive
`space-manager-lifecycle` section coordinates **before** calling
`space-manager-state`, which forces current-window layout. The subsequent layout
can invalidate the earlier coordinates. Returning from `menu-perform` is not a
composition/layout barrier. The old ready predicate also accepted a visible
window with one hosted manager without checking the Spaces section/cache identity.

The check now polls the real condition with a 5 s deadline. It first lays out the
current window, then samples row coordinates and requires visible Archive, an empty
cache identity and the Spaces row. After the real click, it waits for visible
Spaces, a nonempty cache identity and exactly one hosted manager. It does not add
a fixed sleep or accept an eagerly filled Archive cache. On failure, stdout prints
`uncached` and the actual `reopened` state, plus the readiness result; the JSON
receipt retains the states too. This keeps evidence when generated JSON is restored.

All three hardened-flow runs pass **164/164** with zero interruptions and cleanup
PASS (`native-1.json`, `native-2.json`, `native-3.json`). Each records empty Archive
cache before the click and a Spaces cache with one hosted manager afterwards.
The parent's original failure remains unconfirmed; future failures now expose the
states instead of only the assertion name.

### Full gate and rebuilt App

Exact commands, all awaited in the foreground:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --keep-logs
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render --keep-logs
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render --keep-logs
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion
/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py
```

The **full invocation exits 1** for Site Control's documented timing flake; its
other 21 rows pass. Bounded retries leave all rows accepted, with no limit/code
change to Site Control. Its CPU p95 is 18.600 ms at load1 10.91 (full run),
12.102 ms at load1 7.29 (retry 2), then **11.898 ms at load1 8.38** (retry 3,
**1471/1471 PASS**, 12 ms limit). SiteControl/Boosts/Web code is unchanged from
`dee105e6`; `sitecontrol-render` has no OpenSidebar dependency. The failed full
invocation is retained, not rewritten as an exit-0 full run.

| Full gate row | Initial full invocation | Accepted result |
|---|---|---|
| build | PASS | PASS |
| commands-demo | PASS, 307/307 | PASS |
| roundtrip | PASS | PASS |
| space-legacy | PASS | PASS, original frozen PNGs |
| space-editor | PASS | PASS, P1 windows 0/1/2 byte-identical |
| space-pad-compare | PASS | PASS |
| suggest-check | PASS | PASS |
| commands-dump | PASS | PASS |
| route | PASS | PASS |
| favicons | PASS | PASS |
| media-demo | PASS | PASS |
| sleep-demo | PASS | PASS |
| adblock-perf | PASS | PASS |
| adblock-catalog | PASS | PASS |
| profiles | PASS | PASS |
| settings-preview | PASS | PASS |
| sidebar-render | PASS, 595/595; inherited SW1–SW4 skips | PASS |
| sidebar-compare | PASS | PASS |
| commandbar-render | PASS | PASS |
| features-render | PASS, 332/332 | PASS |
| sitecontrol-render | FAIL, 1470/1471 | PASS, 1471/1471 on attempt 3 |
| boosts | PASS | PASS |

App build: **BUILD SUCCEEDED**. Three rebuilt-App completion suites:
**164/164 + 164/164 + 164/164 PASS**, including E20 and the main auto-archive/menu
rows; zero focus interruptions, owned-process/window cleanup PASS each time.

Full logs: `.re/s6/regressions/verify-full.log`, `sitecontrol-retry-2.log`,
`sitecontrol-retry-3.log`, `app-build.log`, `native-1.log`, `native-2.log`,
`native-3.log`. Full harness directory:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-180226.YI61BL/`.

### FP10 after restoring native raster contexts

The parent-approved conditional gate is unchanged. The original strict 2 ms gate
is not relabelled as met. All attempts use the same pinned parent, 1,000 rows,
scale 2, paired/rotating native paths and 1,280×900 window. Times are ms.

| Attempt | Load1 start / transition | Parent plain median / p95 | Branch plain median / p95 | Peek median / p95 | Computed p95 limit | Scroll baseline / peek p95 (load1) |
|---|---|---|---|---|---:|---|
| 1 | 16.17 / 16.08 | 2.01 / 2.482 | 1.81 / 2.179 | 1.58 / 2.250 | 2.447 | 1.54 / 1.54 (16.17) |
| 2 | 16.08 / 15.83 | 2.03 / 2.488 | 1.94 / 2.432 | 1.62 / 2.285 | 2.725 | 1.57 / 1.58 (15.83) |
| 3 | 15.83 / 15.51 | 1.84 / 2.453 | 1.74 / 2.229 | 1.55 / 2.288 | 2.501 | 1.60 / 1.62 (16.25) |

**3/3 PASS**. Native layouts/frame remain **18/18** on every attempt. Scroll is
below both 8.33 ms and the same-run relative limit. Native row/cell allocations
remain zero after warm-up; no bulk height notification or full reload. CA-flush
median on attempt 3 is 0.86 ms, reconcile/display 1.45 ms. The <1 ms median goal
remains open as outline-wide AppKit/backing-layer work. These shared-machine runs
do not establish a controlled percentage speedup over earlier runs.

Both negative controls were rerun on this final drawing code. They must return
exit 1 and did so on their intended gates, not on an unrelated setup failure:

| Final negative control | Load1 start / sample | Matched measurement | Result |
|---|---|---|---|
| O(n) added native layout pass per frame | 16.49 / 15.97 | baseline/peek p95 2.24/265.27 ms; layouts/frame 3/1,000 | Intended work gate FAIL, exit 1 |
| 3 ms busy wait inside reconciliation | 15.14 / 14.73 | busy phase median/p95 3.00/3.00 ms; parent plain p95 1.914, branch plain 1.828, peek 4.953 ms; computed limit 2.000 ms | Intended transition gate FAIL, exit 1 |

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-proof
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-transition-proof
```

FP10 artifacts: `.re/s6/regressions/fp10-final.log`,
`fp10-negative-scroll-final.log`, `fp10-negative-transition-final.log`.
All dependent jobs completed in the foreground. `git diff --check` passes;
generated `docs/engine-spike/*` output is restored before commit. No committed
baseline PNG or threshold changed. No Open/renderer process from this worktree
is left running. The branch is pushed with a new fix commit; no PR is opened.


## Final integration with origin/main dee105e6 (2026-10-28)

The user added #132 while the first merge was ready. Checkpoint merge
`e6b431c36e2e5f2d64c30afc1f77bd635a4ecaf9` contains the resolved/tested 013cdb45
integration below. The final merge adds `dee105e602e66a4fbc4edd8e16a2ab932695e8a1`
(items 9–10) and repeats every requested check on that combined source.

The second merge conflicts only in status rows: retain main's completed menu/share,
Spaces/Archive and copy/link facts, S6's measured motion/peek rows, and A3's merged
status. Keep `App/SidebarMenuActions.swift`, `Turn Folder into Space`, system share
and Profile menu flows, menu-state automation, and all I9/I10 helpers/calls. The
S6 motion extension remains in the single `sidebar-click` implementation. The
repeated dispatch-label/Python-AST audits report zero duplicate definitions.
Model shown-tab bookkeeping, the six combined peek/expiry checks, incremental
outline behavior, Motion/Metrics and the original merge resolutions remain intact.

| Final command | Result |
|---|---|
| `git diff --check` | PASS |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,commands-demo,roundtrip --keep-logs` | PASS: sidebar-render **595/595** (inherited SW1–SW4 skips), features-render **332/332**, commands-demo **307/307** (six FP-AA checks included), roundtrip PASS. Build 53 s; checks 109/43/1/1 s. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py` | **3/3 PASS**, unchanged parent-approved conditional gate; loads and all p95 values below. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | **PASS**, rebuilt App with #132 and S6 automation. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | **164/164 PASS**, including I9/I10 **29/29**, E20 **16/16** and all main auto-archive rows. First final-source invocation; zero focus interruptions; cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar` | **19/19 PASS**, including comparison; existing durable-profile-storage SKIP belongs to the profiles suite. First invocation; zero focus interruptions; cleanup PASS. |

FP10 times in ms. All three native scroll work comparisons remain **18/18**;
absolute 8.33 ms and same-run relative scroll limits pass.

| Attempt | Load1 start / transition | Parent plain p95 | Branch plain p95 | Peek median / p95 | Computed transition limit | Baseline / peek scroll p95 |
|---|---|---:|---:|---|---:|---|
| 1 | 21.82 / 22.47 | 2.940 | 2.289 | 1.61 / 2.271 | 2.567 | 1.77 / 1.69 |
| 2 | 22.47 / 23.71 | 3.668 | 3.116 | 1.82 / 3.057 | 3.477 | 2.01 / 2.19 |
| 3 | 23.71 / 24.38 | 3.655 | 3.208 | 1.80 / 3.087 | 3.578 | 2.12 / 1.80 |

The sub-1-ms median goal and C11 capture choices remain open; no visual threshold
or baseline image changed. No negative-control result is relabelled as a new-head
run: those ff26852f measurements remain below. All dependent checks completed in
the foreground. Generated `docs/engine-spike/*` output is restored before commit.
Private final artifacts: `.re/s6/dee-verify.log`, `dee-fp10.log`,
`dee-app-build.log`, `dee-e2e-completion-1.log`, `dee-e2e-sidebar-1.log`,
`dee-results-completion-final.json`, `dee-results-sidebar-final.json`,
`dee-E20-folder-peek.png`, `dee-sidebar-window.png`, `dee-comparison-sidebar.md`.
Harness logs: `/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-172221.qOnpXB/`.
No PR is opened; the parent owns the stack/PR.

## Integration with origin/main 013cdb45 (2026-10-28)

Merged `013cdb45d42678f16b27087616b854b76c32c2c4` into the S6 head
`ff26852f5409d566174f85c02cffeaa53ac5ad1a`. This brings A2 #127 (HP11–HP14),
A3 #128, #129 spring readbacks, and #130 Today auto-archive into the same branch.
No rebase, squash, baseline-image update, visual-limit change or PR.

Resolutions and combined behavior:

- `features-render/CompletionChecks.swift`: keep async main previews and S6's
  async folder flow. HP13 now collapses its fixture before hover, preserving the
  expanded-folder exclusion while proving the new card-scroll behavior.
- `tools/e2e/engine_e2e.py`: keep both E20 and main's A3/auto-archive helpers and
  their calls. One definition of every Python helper, audited via AST. A3's E1
  fully-collapsed range fixture selects an outside tab before collapse; a selected
  direct child now correctly creates a peek. The initial assertion failure is
  retained as a fixture-integration failure, not an environment interruption.
- `docs/status.md`: keep main's A3 grouping/copy/archive/restore rows and S6's
  motion/peek rows. §9, followups and automation docs reflect the combined branch.
- Git silently retained two `sidebar-click` dispatch cases. Remove the obsolete
  inline case and add its motion capture/result fields to main's existing helper.
  Preserve exact-window activation, modifier handling (including alt/opt), A3
  selection results, and S6 native duration/curve/presentation sampling. The final
  dispatch-label audit has zero duplicates. `tabs sidebar:true` keeps its native
  row readback; plain `tabs` remains an array for main's sweeper flows.
- Model property changes use `registerChange → registerUndo → recordUndo →
  commitMutation`, including no UndoManager/disabled registration; undo/redo also
  commit. The selected direct tab or all selected split panes remain in the shown
  set when their folder is logically peeked. A sidebar-only peek does not make an
  unselected page shown. Expiry clears stale peek in the same sweep. Six new
  combined public-command/undo/SQLite checks pass in `commands-demo` (tab and split:
  selected protection, fresh inactivity on leaving without UndoManager, expiry and
  clearing). No second bookkeeping store or duplicate commit was added.
- Keep S6's per-folder incremental outline caches/clean layer guards alongside
  A3's shared drop path and stale keyboard-focus/deletion handling. Keep folder
  expand 0.20 s easeOut/collapse 0.25 s default, unrelated rowStructure 0.22 s,
  main's spring readbacks and existing peek geometry/color tokens.

| Requested check | Result |
|---|---|
| `git diff --check` | PASS |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,commands-demo,roundtrip --keep-logs` | PASS: sidebar-render 595/595 (inherited SW1–SW4 skips), features-render 332/332 including HP11–HP14 and AA flows, commands-demo 307/307 including all six FP-AA checks, roundtrip PASS. Build 82 s; checks 108/42/2/1 s. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py` | PASS 3/3 under the parent's unchanged conditional gate; table below. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS, rebuilt actual Debug App. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | Final 135/135 PASS, including E20 16/16 and every main auto-archive row; 0 interruptions, cleanup PASS. Initial invocation failed E1's fixture assumption; corrected fixture invocation passes. |

FP10 times are ms; p95 values use full printed precision. Loads show attempt start
and transition sample. Every attempt also has equal native scroll layouts/frame
18/18, peek p95 ≤8.33 ms and ≤baseline×1.10+0.05 ms.

| Attempt | Load1 start / sample | Parent plain p95 | Branch plain p95 | Peek median / p95 | Computed limit | Baseline / peek scroll p95 | Result |
|---|---|---:|---:|---|---:|---|---|
| 1 | 10.86 / 10.63 | 5.425 | 4.884 | 2.68 / 4.708 | 5.422 | 6.43 / 6.85 | PASS |
| 2 | 10.63 / 10.59 | 5.378 | 5.653 | 2.52 / 4.701 | 6.268 | 4.83 / 4.80 | PASS |
| 3 | 10.59 / 10.62 | 5.145 | 4.542 | 2.38 / 4.205 | 5.046 | 4.10 / 4.04 | PASS |

The sub-1-ms median goal remains open. The prior negative-control measurements
below belong to ff26852f; this merge reruns the required default paired gate.
Private evidence: `.re/s6/merge-verify.log`, `merge-fp10.log`, `merge-app-build.log`,
`merge-e2e-completion-1.log` (fixture failure), `merge-e2e-completion-2.log` (135 pass),
`merge-completion-failure-1.json`, `merge-results-completion-final.json`. Harness logs:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-170844.TGtqBW/`.
`/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar`
**PASS 19/19**, including `comparison`, with the existing profile-storage SKIP
owned by the profiles suite. Zero interruptions; cleanup PASS. Evidence:
`merge-e2e-sidebar-1.log`, `merge-results-sidebar-final.json`,
`merge-sidebar-window.png`, `merge-comparison-sidebar.md` and
`merge-E20-folder-peek.png`. Generated `docs/engine-spike/*` output was restored
before committing. No focus retries were needed; the A3 fixture correction was
a functional integration fix. All dependent checks completed in the foreground.


## Matched plain-toggle and rendering round after fffe0395 (2026-10-28)

The pinned parent is `2d51f14a1207c00157edb90f51459d97b7b1096b`. The wrapper exports
that exact commit under `.re/s6/fp10-parent`, adds measurement hooks and the same
portable plain-toggle driver, then builds both release CLIs with the same toolchain.
It does not apply branch rendering or reconciliation changes to the parent.
Each attempt rotates parent plain expand/collapse, branch plain expand/collapse,
and branch expanded → peeked → collapsed → expanded. The metric is the same sum
of real AX input, completed observed reconciliation (including display/CA commit),
and final layout/display. Each sample verifies real native row membership. All
fixtures use 1,000 displayed rows, scale 2, a 1,280×900 window and 228 pt sidebar.
Plain expanded has the same three direct children as the toggled peek folder.
Fixture construction, warm-up, IPC wait, queued observation wait and animation wall
time are excluded; reconciliation/display work is included.

**Parent gate decision:** if the pinned parent plain p95 is >2.00 ms, use
`max(2.00 ms, matched branch plain p95 ×1.10 +0.05 ms)` for that attempt. Otherwise
peek must be ≤2.00 ms. Using the branch control for the allowance is conservative
when the parent is slower. A missing pinned parent gets no exemption. Run all
three attempts to show the requested baseline table; the bounded review retry
rule accepts a run if an attempt meets every gate. Scroll still requires native
layouts/frame peek ≤baseline, peek p95 ≤8.33 ms and ≤baseline p95 ×1.10 +0.05 ms.
The reason is measured existing plain-toggle cost, rather than a fitted tolerance
for peek. §3.17 and FP10 record this rule. The original strict gate's historical
failures below remain failures of that earlier definition.

Final default-window run: **3/3 PASS** (`fp10-geometry-final.log`). Times in ms;
plain columns are median/p95, peek is median/p95/max. Loads print at attempt start
and sample completion; scroll loads below are recorded when scrolling completes.

| Attempt | Load1 start / transition | Parent plain median / p95 | Branch plain median / p95 | Peek median / p95 / max | Computed p95 limit | Result |
|---|---|---|---|---|---:|---|
| 1 | 8.55 / 8.67 | 2.32 / 3.260 | 1.92 / 2.983 | 1.81 / 3.114 / 4.79 | 3.331 | PASS |
| 2 | 8.67 / 8.72 | 2.42 / 3.517 | 2.05 / 3.239 | 1.80 / 3.167 / 4.57 | 3.613 | PASS |
| 3 | 8.72 / 9.06 | 2.43 / 3.275 | 2.09 / 2.892 | 1.79 / 2.883 / 3.48 | 3.231 | PASS |

The parent plain p95 exceeds 2 ms in all three attempts; branch plain also retains
that floor. The earlier parent-run c095ca1d figure was peek median/p95/max
1.84/2.87/5.27 ms at load1 7.5. A median well under 1 ms is **not achieved**.
Remaining outline/AppKit/backing-layer rendering work is tracked in followups;
the paired gate measures added peek cost without relabelling that goal as met.

### Historical rendering evidence (bitmap/title changes superseded above)

- Before this round, the one-transition trace shows AppKit asking every available
  row for display and then calling their `updateLayer`. The folder glyph uses
  `draw` with dirty rect `{{-16,-10},{228,41}}`; a newly exposed bottom cell title
  uses `{{-43,0},{228,24}}`. These are dirty rectangles in their local coordinates,
  not evidence that every neighbor's title/favicon was painted.
- `SidebarRowView` already uses `wantsUpdateLayer`. It now discards native clean
  invalidations before `super.needsDisplay`; model identity/selection observation
  explicitly marks the fill dirty. Hover/current/appearance updates retain their
  direct layer path. The trace after the change shows only the entering/reused row
  background update; unchanged neighbors receive no effective display request.
- At this earlier revision the folder glyph uses `wantsUpdateLayer` and cached CGImage layer contents
  rendered from Open's own existing vectors. The cache holds at most 64 images
  of ≤64×64 RGBA pixels (1 MiB); larger/custom one-off images cap at 256×256
  (262,144 bytes). Typed/legacy/emoji overrides keep their precedence; scale and
  accent are in the cache key. No Arc asset is copied. FP6 remains identical.
- Native insertion does schedule layout across the visible row containers.
  Bounds/indent caching now avoids repeated fill/ring/shadow geometry assignment
  for rows that only moved. In the final 240-transition sample there are about
  19.33 native row-container layouts per transition but **zero layer geometry
  updates**, about 2.33 content-cell layouts and 2.33 visited cached items.
- After warming the real three-state cycle, all three main attempts report
  **zero row allocations and zero cell allocations**. Native reuse supplies
  398–400 cells per 240 transitions (1.66–1.67 per transition). No per-node view
  cache was added. Height queries total 240; `noteHeightOfRows` calls/rows are 0.
  There is no whole-outline reload or all-row height invalidation.
- Final phase medians on attempt 3: native walk/edits 0.41 ms, layout 0.11 ms,
  display 0.24 ms, CA flush 0.89 ms. CA commit remains the largest individual phase.
  The correct-PID sample from the previous round points to
  `syncExpansion → CA::Transaction::flush → NSViewBackingLayer display`.

Each change was measured separately. At load1 17.21/16.40/16.52, the instrumented
pre-change peek medians were 2.18/2.06/2.17 ms, p95 3.29/3.89/3.64 ms. Glyph-only
medians were 1.98/2.62/2.70 ms at load1 16.44/17.37/17.18; p95 2.98/4.09/4.45 ms.
Clean row invalidation medians were 2.32/2.23/2.12 ms (full numbers in
`fp10-row-layer.log`). Final geometry-guard numbers are in the table above.
Loads differ, so these are not a controlled percentage speedup. The deterministic
reductions are the discarded clean invalidations, cached glyph draws, zero view
allocation and zero repeated row layer-geometry assignment.

### Commands and current checks

One command prepares the pinned parent, builds the current CLI and runs all three
matched attempts (offscreen; invoke from this worktree):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py
```

Add `--trace-transition` for one bounded draw/updateLayer/dirty-rect trace per
attempt (excluded from timed samples); add `--visible-rows 10` or
`--visible-rows 30` for the exact native viewport counts. Both negative proofs
are fast, one-attempt real-interface commands and must exit 1 on their intended
gate, using the same baseline measured in that run:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-proof
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verification/folder-peek-bench.py --negative-transition-proof
```

| Attempt | Scroll load1 | Baseline / peek scroll p95 (ms) | Native cell layouts/frame baseline / peek | Result |
|---|---:|---|---|---|
| 1 | 8.55 | 1.50 / 1.47 | 18 / 18 | PASS |
| 2 | 8.69 | 2.06 / 1.83 | 18 / 18 | PASS |
| 3 | 8.72 | 1.46 / 1.39 | 18 / 18 | PASS |

Exact native viewport experiment (same fixture/scale, changing only window height;
three attempts each, 3/3 PASS). Timing/load differences preclude claiming a precise
slope. CA commit does not grow threefold when native row-layout calls do.

| Native visible rows | Attempt loads1 at transition | Transition medians / p95 (ms) | CA-flush medians (ms) | Native row layouts per transition | Layer geometry updates per transition |
|---|---|---|---|---:|---|
| 10 (372 pt clip) | 21.43 / 21.00 / 20.84 | 1.50/2.69; 1.61/2.66; 1.44/2.78 | 0.70 / 0.74 / 0.64 | 10.33 | 0 / 0 / 0 |
| 30 (1,192 pt clip) | 11.49 / 11.29 / 11.35 | 1.71/2.69; 1.78/2.96; 1.91/3.04 | 0.80 / 0.80 / 0.84 | 30.33 | 0 / 0 / 0.67 |

The small number of required geometry updates in the last 30-row case is allowed
only when bounds/indent changes; unchanged neighbor geometry still skips. The
initial exploratory 11/31-row measurements were superseded by these exact 10/30
viewports; the fixture now counts the actual 3 pt spacer.

| Failure control | Measured evidence | Result |
|---|---|---|
| O(n) native layout pass per frame | Load1 10.44, baseline/peek p95 2.50/440.05 ms; native layouts/frame 3/1,000 | Intended work gate FAIL, exit 1 |
| Real 3 ms CPU spin inside transition | Load1 11.16, busy phase median/p95 3.00/3.00 ms; plain/parent/peek transition p95 2.516/3.145/6.037 ms; computed limit 2.817 ms | Intended transition gate FAIL, exit 1 |

Private artifacts: `fp10-paired-before.log`, `fp10-layer-only.log`,
`fp10-row-layer.log`, `fp10-geometry-final.log`, `fp10-visible-10-exact.log`,
`fp10-visible-30-exact.log`, `fp10-fullrow-final.log`, `fp10-busy-final.log`.
Parent export provenance is in `.re/s6/fp10-parent/fp10-manifest.json` (pinned SHA,
portable driver/script fingerprint, measurement-only patch description). No raw
Arc/private content is in those synthetic fixtures.

| Final check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render --keep-logs` | PASS: build 32 s; sidebar-render **595/595** (106 s, inherited SW1–SW4 skips); features-render **293/293** (31 s). |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS: rebuilt Debug Open. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | **80/80 PASS**, including **16/16 E20**; first suite invocation, 0 interruptions, owned-process/window cleanup PASS. No retries required. |
| `sidebar-render plain-toggle-probe --rows 0` | Expected rejection before fixture allocation, exit 1; bounded 1,000-row control enforced. |

The initial functional run before the last geometry guard also passed 595/595 and
293/293; the table above is the repeated final-source check. Default FP10 is a
separate opt-in performance command, not counted as an implicit functional PASS.
A final bench-only review moved fixture cleanup registration before the potentially
throwing parent launch. The release CLI rebuilt successfully (22.08 s), and
`sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --parent-renderer /does-not-exist/FP10-parent`
rejected all three attempted launches and returned exit 1 before any measurement.
Logs: `probe-cleanup-build.log`, `fp10-missing-parent.log`. The production rendering
and App source used by the green checks did not change.

Native JSON/PNG/log receipts are retained under `.re/s6/results-completion-paired-final.json`,
`E20-folder-peek-paired-final.png` and `e2e-paired-1.log`; generated tracked output
was restored, and no existing baseline image was changed. Verification logs:
`verify-paired-final.log` and `/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-164254.1zEKHO/`.

FP6 final-source render/compare (commands in the historical reproduction section,
using `peek-paired-final.png` and `compare-paired-fp6`): **PASS**. Dot ΔE00 remains
1.434/0.837/1.511 with one solid #B5AFFF token; body 0.000, pitch 4 pt, position
error 0, hover dash ΔE00 0.15. The 0.65 opacity guess remains superseded by the
capture-authoritative minimax fit.

`SIDEBAR_BASELINE_REF=fffe03953a5adacb704696ddf1b73222197f3fec ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs`
**PASS 13/13**, tables byte-identical **13/13**, position/ink identical, maximum
paired color drift **0 ΔE00**. CU5 **2/2**, exact divider pixels. Both concatenated
table hashes are `f72963370205cfc5c1eb3b18873eac96cbeb86012a735d20e1c1193b4fcfe203`.
This is the current round's comparison to fffe0395; the previous round's 1/13
byte-identical comparison to c095ca1d remains historical. The check waited 400 s
for a heavy slot, then passed in 117 s. Logs: `compare-paired-final.log` and
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-verify-20261028-165502.qriNHX/`.
No baseline file or visual limit changed. Final process check finds no Open or
sidebar-render process from this worktree.


Changed files in this round:

- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderToggleProbe.swift` (new portable driver)
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `tools/verification/folder-peek-bench.py` (new pinned-parent wrapper)
- `tools/verification/check.py`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `docs/followups.md`

New implementation choices: use the branch plain-toggle control for the relative
allowance, with the pinned parent only establishing whether the exemption applies;
run all three requested measurement attempts even after a pass; use bounded shared
own-vector image contents, rather than a per-node cell cache. The original plan's
keyboard/import/selection/Q17/Q18 choices remain listed below and unchanged.


### Review checklist for this round

| Item | Result / evidence |
|---|---|
| Inputs and allocations | PASS: exact 1,000-row paired fixture, visible rows 1…64, response ≤16 KiB, glyph cache ≤1 MiB, largest bitmap 262,144 bytes; invalid row input rejects. |
| Lifetime and callbacks | PASS: private probe exits/closes its window on quit/EOF; each attempt closes all windows; App native cleanup PASS. No new delegate/engine lifecycle path. |
| Real interface and failure sensitivity | PASS: AX input and native row counts, unchanged functional harnesses, App E20 16/16. O(n) and busy-wait controls both fail their intended computed gates. |
| UI/motion | PASS functional/native E20 duration and presentation checks; cached own vector and clean layer guards preserve geometry/selection semantics. Visual receipt is recorded below. |
| Performance | PASS under the parent's conditional gate, 3/3 default attempts, both controls reject. Sub-1-ms median remains open as outline-wide work. |
| Docs and scope | PASS: §3.17/FP10, §9, status and followups agree. No unit tests, Arc launch, computer use, subagents, engine-tree edits, push or PR. |



## Historical fffe0395 round after c095ca1d (2026-10-28)

Parent's c095ca1d run at load1 7.5: transition median/p95/max 1.84/2.87/5.27 ms; reconciliation+display median 1.74 ms; baseline/peek scroll p95 2.26/2.31 ms; native layouts/frame 18/18.

Profiling used completed-callback phase clocks, native work/draw counters, and `/usr/bin/sample` against the exact bench PID. The first split, before optimization, at load1 17.70 measured reconciliation+display median 1.87 ms: walk/native edits 0.44 ms and forced layout/display 1.41 ms. It visited 1,002 cached items and configured 21 row views per transition. A longer 2,400-transition diagnostic sample after targeting the observation showed Core Animation commit / AppKit backing-layer drawing as the remaining dominant cost (`fp10-transitions.sample`: `SpacePageView.syncExpansion` → `CA::Transaction::flush` → `NSViewBackingLayer display`). Actual title/favicon draws were about two per transition; the trace did not prove painting of unrelated node rows.

Changes retained:

- Each exposed folder owns a weak Observation loop, cancelled when its cache drops. A folder property change starts reconciliation at that folder, rather than scanning the 1,000-row root and every loaded folder. New/hidden Manager folders still reconcile through the existing structural/visibility paths.
- A subset removal/insertion uses one native `IndexSet` edit. A collapsed item's children are supplied once by native expansion. No reloadData, whole-outline reloadItem, height invalidation, or all-row view lookup was added.
- New child rows configure through `didAdd`; only the folder row needs an explicit state refresh. Unrelated row fills and the header are untouched. The measured case visits about two items and configures two row views, with two cell layouts.
- A tab's title and favicon share its cell backing context. Buttons and badges retain separate layers. The native-image-view, bitmap-cache, binding-cache, and transparent-document experiments did not establish a useful reduction and were removed.
- Bench output now reports phase timing, real work, draw counts, and thread CPU time as a diagnostic. It checks the native row count after every measured transition, so a no-op/broken expansion cannot satisfy the timing gate.

The parent's gate definition replaces the earlier max-time and clock-overhead guesses: **transition wall p95 ≤2.00 ms**, up to three fresh matched attempts; maximum native row layouts/frame peek ≤ baseline; scroll p95 ≤8.33 ms and ≤baseline p95 ×1.10 +0.05 ms in each paired, alternating run. Max remains diagnostic. The parent chose the time allowance for shared-machine jitter while retaining the deterministic work detector. CPU time does not change the verdict. All attempts and load1 values are printed. A real 3 ms CPU busy wait inside the transition callback is the second negative control, scoped to its diagnostic window and disabled in the App.

fffe0395 strict command: the historical strict command below, three attempts, all **FAIL** on transition p95. The <1 ms median target is **not met**. CPU diagnostic medians 1.70/1.83/1.80 ms are close to wall time; this is not explained away as scheduling noise. Further rendering/commit optimization is required before FP10 can be accepted.

| Attempt | Load1 start / sample | Transition median / p95 / max (ms) | Reconcile+display median (ms) | Baseline / peek scroll p95 (ms) | Layouts/frame baseline / peek |
|---|---|---|---:|---|---|
| 1 | 5.60 / 5.60 | 1.72 / 2.91 / 3.76 | 1.65 | 1.59 / 1.65 | 18 / 18 |
| 2 | 5.60 / 5.63 | 1.86 / 2.78 / 5.03 | 1.78 | 1.34 / 1.28 | 18 / 18 |
| 3 | 5.63 / 5.63 | 1.83 / 3.20 / 4.18 | 1.72 | 1.23 / 1.25 | 18 / 18 |

All three paired scroll comparisons meet the parent's absolute, relative and native-work conditions. The numerical relative limits were 1.802/1.524/1.401 ms. First-attempt phase medians: walk/native edits 0.36 ms, row-state refresh <0.01 ms, layout 0.10 ms, display 0.10 ms, CA flush 1.06 ms. The work bound improved; complete transition latency did not reach the requested target. Before/after runs had different load; no claimed percentage reduction.

| Required follow-up check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render --keep-logs` | PASS: sidebar-render 595/595, inherited SW1–SW4 skips; features-render 293/293. |
| `SIDEBAR_BASELINE_REF=c095ca1d2472b9763e187f5490ef6560975bf619 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs` | PASS 13/13; same position/ink, max paired color drift ΔE00 0.13; CU5 2/2. Tables byte-identical 1/13, not 13/13. No thresholds or baseline files changed. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS, rebuilt Debug Open. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | INTERRUPTED after 3 bounded focus attempts: 18 accepted checks PASS, 0 FAIL, E20 not reached. Owned-process/window cleanup PASS. The c095ca1d 80/80 receipt below is historical, not a new-head pass. |
| Strict bench (command below) | FAIL 3/3 as shown; FP10 acceptance PENDING. |
| Strict bench plus `--negative-proof` | Expected FAIL, exit 1: actual full native pass gives 1,000 layouts/frame vs 3; baseline/peek p95 1.76/239.21 ms, load1 4.27. |
| Strict bench plus `--negative-transition-proof` | Expected FAIL, exit 1: 24 actual UI transitions, busy-wait phase median/p95 3.00/3.01 ms; transition median/p95/max 4.75/5.83/6.28 ms, load1 5.48. Native scroll layouts 3/3; it fails the transition gate. |
| FP6 capture render/compare (same commands below with `peek-optimized.png` / `compare-optimized`) | PASS: same single dot token, per-dot ΔE00 1.434/0.837/1.511, body 0.000, pitch/footprints/accessory within unchanged limits. |

Current private artifacts: `.re/s6/fp10-profile-before.log`, `fp10-transitions.sample` (2,400-transition diagnostic, not an acceptance run), `fp10-optimized-final.log`, `fp10-negative-optimized.log`, `fp10-negative-transition.log`, `verify-optimization.log`, `compare-optimization.log`, `app-build-optimization.log`, `e2e-completion-optimization.log`. Discarded experiments remain as private logs only; they are not accepted performance receipts.

### Follow-up review status

| Item | Result / evidence |
|---|---|
| Input/model/persistence scope | PASS: no model command, import format, undo behavior or external input size changed in this follow-up. |
| Lifetimes | PASS: per-folder loops hold weak owners and cancel on cache removal/deinit; native interrupted-suite cleanup reports no remaining owned processes/windows. |
| Functional and visual regression | PASS: 595/595 + 293/293; 13/13 unchanged-limit gates, position/ink identical and max color drift 0.13; FP6 capture PASS. No existing image or threshold changed. |
| Failure sensitivity | PASS: real O(n) frame work and real 3 ms transition CPU-spin controls each return exit 1 on the intended gate. |
| Native event path | INTERRUPTED before E20 after three foreground losses to T3 Pretty Internal (Nightly). The prior-head 80/80 receipt does not establish this head. |
| Performance acceptance | FAIL: transition p95 remains >2 ms and median remains >1 ms. Scroll/work gates pass; further rendering/commit optimization is open. |

### Follow-up changed files

- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `docs/followups.md`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `tools/verification/check.py`

## Acceptance boundary

Functional/model/import/render/native verification for c095ca1d is preserved below. The latest matched-baseline round at the top supersedes earlier FP10 gate interpretations and outcomes. Historical native passes do not prove the current head. No image baseline or visual threshold changed. The parent handles pre-PR acceptance.

Historical fffe0395 strict command (no pinned-parent exemption):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50
```

Fast O(n) negative proof (expected nonzero exit, actual full-row work versus the matched baseline):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --negative-proof
```

Fast transition negative proof (expected nonzero exit on transition p95):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --scale 2 --folder-peek 50 --negative-transition-proof
```

`SIDEBAR_FOLDER_PEEK_PERF=1` also enables the strict bench in the `sidebar-render` verification dispatcher. The default functional gate identifies FP10 as a separate performance command and does not count it as a performance pass.

## Measured color fit

Capture S2 08/0090, 1728×1084, sidebar228, row239, scale1. Both embedded ICC inputs are drawn into Display P3, then into sRGB for Lab D65 / CIEDE2000. The old white alpha0.65 guess was replaced by the lead because it missed the measured pixels: worst actual ΔE00 3.268, best possible white-opacity third-dot fit2.209. The capture is authoritative.

One solid token, `SidebarRole.folderPeekDots = #B5AFFF` sRGB, fills all three vector circles. Exhaustive integer sRGB fit over R170…192/G162…186/B248…255 minimizes maximum center ΔE00, then total ΔE00. No per-dot color or opacity is used.

| Sample | Capture sRGB | Render sRGB | ΔE00 |
|---|---|---|---:|
| (22,260) | #B9B4FF | #B5AFFF |1.434|
| (26,260) | #B6B2FF | #B5AFFF |0.837|
| (30,260) | #B0AAFF | #B5AFFF |1.511|
| body(26,264) | #202AFF | #202AFF |0.000|

Dot footprints:3×3 pixels at(21,259),(25,259),(29,259), position error0pt, pitch4pt. The native 20pt host remains; the nominal18pt peek vector aligns to pixel centers. Default peek body is calibrated #202AFF; custom theme accents remain theme-driven. The old open/closed art is unchanged. Hover dash:12×2 at(196,258), position error0pt, ΔE00 .15. §3.17 records the replacement and fit.

## Native evidence

E20 includes actual own-window mouse input, real native outline rows, saved DTO false/b, same-root relaunch with the same IDs/Today selection, second click to full collapse, re-expand/elsewhere/empty cases, and Q18 unloading an actually loaded Pinned descendant while preserving all entries and peek.

`sidebar-completion`:80/80 PASS, no focus interruptions in final run, owned-process/window cleanup PASS. `sidebar`:18/18 PASS, comparison PASS; durable_profile_storage is the existing separate-profiles-suite SKIP.

Installed native row-position animations: collapse.25s with CA default control points(.25,.1,.25,1); expand.20s with easeOut(0,0,.58,1). Presentation samples show41pt/82pt upward movement and123pt expansion. Unread-dot spring/opacity animations remain separate. E20 asserts installed duration/curve and changing row presentations, rather than only checking tokens.

Additional `app-actions`: 1 PASS plus suite INTERRUPTED after 3 exact-PID focus attempts. `window`: 5 PASS plus suite INTERRUPTED after 3 attempts. UserNotificationCenter held foreground; `active=false`, `keyWindow=0`. Both owned-process/window cleanups PASS. These are environment outcomes, not green receipts.

## Implementation choices

- Three model states shared by windows; the acting window alone chooses its selected direct tab/split. No history store.
- Nested descendant selection collapses; Right expands; Left on peek collapses; Return/Space use the common activation cycle. These are the plan's keyboard/nested guesses.
- Exact Expand All/Collapse All clear peek, and Collapse All remains enabled for a peek-only Space.
- Same-parent reorder keeps peek; copies remap to copied direct children; destructive/move/pane/sweep commands clear it with their existing undo record. Stale undo normalizes without resurrecting a child.
- Archive drops root/nested peek metadata; deletion undo retains the live original. Snapshot absent/malformed/stale values normalize safely.
- First standard window supplies both expansion and Pinned section state; little/littleArc windows are excluded. Unknown/absent map entries collapse; no standard window keeps the previous expanded default. These are import guesses selected by the plan.
- Retained row identity and content stay stable; layout compacts it directly under the folder, with no blank gap. Incremental lists/transactions only; untouched root/child lists remain cached.
- Pixel-center geometry, cached own vector paths, custom-icon precedence, and immediate Reduce Motion follow the plan's proposals and the measured capture.
- Pinned hover dash unloads loaded descendant hosts once and keeps entries/expansion; no loaded descendants is a no-op; Today has no dash. Q17/Q18 and expanded-folder hover exclusion remain user-capture questions C11, not confirmed Arc behavior.
- No collapse menu labels were invented; the current folder menu has no collapse entry.

## Original c095ca1d checks and remaining items

All commands below ran from `/Users/serge/.t3/worktrees/open/t3-85f17ccf`, sequentially with heavy-slot/on-screen locks as applicable. The parent handles the stack and the pre-PR merge/full gate. This local receipt does not claim PR or merge acceptance.

| Check / exact command | Result |
|---|---|
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,roundtrip,commands-demo --keep-logs` | PASS: build; sidebar-render 595/595 (SW1–SW4 inherited lead-Q5 skips); features-render 293/293; commands-demo 301/301 plus FP11 6 synthetic import variants; roundtrip PASS. FP10 explicitly PENDING. |
| `SIDEBAR_BASELINE_REF=2d51f14a1207c00157edb90f51459d97b7b1096b ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-compare --keep-logs` | PASS: all 13 states, byte-identical parent/branch tables; maximum paired color drift 0 ΔE00, same position/ink. CU5 2/2. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only settings-preview,commands-dump --keep-logs` | PASS: settings-preview 37/37 and 216 rendered PNGs; command registry 192 commands, missing=0/extra=0/different=0. |
| `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh` | PASS, final Debug app. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar-completion` | PASS: final rebuilt app 80/80, no focus interruptions, owned-process/window cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only sidebar` | PASS: final rebuilt app 18/18, comparison PASS; 1 existing profiles-suite SKIP. One interrupted earlier attempt; bounded retry accepted all 18 checks. Cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only app-actions` | INTERRUPTED: 1 PASS, no accepted full-suite pass; 3 bounded focus attempts, cleanup PASS. |
| `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only window` | INTERRUPTED: 5 PASS, no accepted full-suite pass; 3 bounded focus attempts, cleanup PASS. |

FP1–FP4 use the real public model command/UndoManager/SnapshotStore/SQLite archive flows in `openkit commands-demo`; FP11 uses the real `openkit import-arc` and `roundtrip` commands with six synthetic Arc-shaped variants. FP5–FP9 use real AppKit row views, AX actions, keyboard activation, context menus, multi-selection and the production drop path in `sidebar-render`; `features-render` covers hover eligibility/lifetime, the full folder card and unload behavior. E20 proves the App/engine path, actual native row membership and saved/reloaded DTOs. FP6 and FP10 remain separately reported below.

### Historical FP10 measured receipt and failure control (superseded gate)

The strict run uses 1,000 displayed node rows, 50 folders, 1,100 model nodes, 1,002 native rows including spacer/New Tab, scale 2, 1280×900 window, sidebar 228. Baseline one-child expanded folders and peek folders have matching visible positions. Scroll order alternates; fixture build, queued wait and animation wall time are excluded. Transition timing includes input, completed observed reconciliation/display and final forced layout. No positive performance acceptance is claimed.

| Run | Load1 start / sample | Baseline scroll p95 | Peek scroll p95 | Transition median / p95 / max | Result |
|---|---|---:|---:|---:|---|
| Strict, 400 frames each / 240 transitions | 5.82 / 6.07 | 2.02 ms | 2.39 ms | 2.38 / 3.84 / 4.88 ms | FAIL; acceptance PENDING quiet parent run |
| Fast O(n) negative, 12 frames each | 7.12 / 6.79 | 1.95 ms | 239.47 ms | Not sampled (fails earlier) | Expected exit 1; negative proof PASS |

Strict paired p95 delta +0.363250 ms versus measured clock/read overhead 0.000042 ms. Row layouts/frame 18 baseline / 18 peek. Transition input p95/max 0.24/0.65 ms; reconciliation+display 3.53/4.59 ms; final layout 0.14/0.26 ms. This sample misses the 2 ms transition gate and the unchanged relative-scroll gate; it meets the 8.33 ms absolute scroll limit. The deferral does not assert that load alone explains the miss.

The negative proof adds an actual O(n) pass laying out all native row cells on each frame for the diagnostic peek window only. It detected 1,000 layouts/frame versus 3 in the matched baseline, then returned `FP10 FAIL full-row per-frame work`. Paired p95 delta +237.525792 ms; measured clock/read overhead 0.000042 ms. It runs 2 warm-up plus 12 measured frames per side and fails on measured work even under timing noise. The process-only hook defaults off; there is no artificial sleep.

An earlier extreme-load run gave baseline/peek scroll p95 59.97/59.10 ms and transition max 175.99 ms. That old bench did not print contemporaneous load. Separate `uptime` observations were 83.59 at 12:49 and 85.22 at 12:51; these are context, not a claimed paired load sample.

### FP6 reproduction and artifact receipts

```sh
Packages/OpenKit/.build/release/sidebar-render synth --out .re/s6/final-capture-fixture --folder-peek
Packages/OpenKit/.build/release/sidebar-render render --snapshot .re/s6/final-capture-fixture --out .re/s6/peek-fit-final.png --size 1728x1084 --width 228 --scale 1 --hover pinned:0 --folder-peek
Packages/OpenKit/.build/release/sidebar-render compare --spec folder-peek --arc /Users/serge/.t3/projects/open/.re/runtime/sessions/20261026-102027-08-folder-preview/0090-102246/win-70352.png --ours .re/s6/peek-fit-final.png --out .re/s6/compare-final --scale 1 --width 228 --folder-row-top 239
```

Final FP6 rerun PASS: all three center pixels, uniform dot color, body, footprints/pitch and hover accessory meet the unchanged limits. Raw capture stays outside tracked files. The comparison reads only glyph/accessory pixels, honors the ICC profile, rejects missing samples, checks one uniform rendered dot color, and never emits personal titles or images.

Private local artifacts under `.re/s6/`: `verify-final.log`, `baseline-compare.log`, `app-build-final.log`, `fp10-sample-final.log`, `fp10-negative-final.log`, `compare-final/table.md`, `E20-folder-peek-final.png`, `e2e-completion-final.log`, `e2e-sidebar-final.log`, `results-completion-final.json`, `results-sidebar-final.json`, `verify-extra.log`, and the extra interrupted-suite JSON/logs. Parent/branch concatenated baseline-table SHA-256: `f820361b0b4baa3ad4e24b723ca807462f1b195d2f2391997815445ec77455e1`.

### Review checklist

| Area | Result / evidence |
|---|---|
| Input / persistence | PASS for added optional UUID field and direct-child validation; malformed/stale/missing UUID, expanded+peek, invalid foreign/nested/pane targets covered. No new external file format or increased allocator ceiling. Existing snapshot/import limits remain unchanged. |
| Lifetimes / callbacks | PASS: native view identity retained; undo restores before structural events; stale undo normalizes; hover cancels on state change. Test windows and exact owned process trees clean up. |
| Real event paths | PASS for new row input: E20 uses own-window `NSApp.sendEvent` down plus queued up; hidden row fails. Existing no-argument `tabs` response is unchanged. No new global hotkey or popup focus context. |
| Regression sensitivity | PASS for actual rejected FP6 color fits and FP10 O(n) negative control. Per-case break-and-revert for every new functional assertion was not performed; parent review should not infer that evidence. |
| Pixel / motion checks | PASS FP6 capture pixels, 13 identical baseline tables, native installed .20/.25 curves and changing presentations, Reduce Motion immediate path. No baseline PNG or thresholds changed. Real-window E20 PNG retained; capture comparison uses matched 1x offscreen geometry, not a claim of full native screenshot color parity. |
| Isolation / cleanup | PASS: synthetic roots/profiles, unchanged exact-owned-PID cleanup in finally, no Arc launch or desktop events; no remaining owned processes. E20 adds no dialog. Extra suite focus interruptions retained. |
| Performance | PENDING FP10 strict quiet run; limits unchanged; expected negative FAIL recorded. |
| Docs / scope | PASS: §3.17 fit, §9 row, status and follow-ups agree. No dependency or engine-tree changes; no unit tests, push or PR. |

### Changed files

- `App/Automation/AutomationController.swift`
- `App/MainMenu.swift`
- `App/WebContent/EngineWebContentHostFactory.swift`
- `Packages/OpenKit/Sources/OpenDesign/Icons.swift`
- `Packages/OpenKit/Sources/OpenDesign/Metrics.swift`
- `Packages/OpenKit/Sources/OpenDesign/Motion.swift`
- `Packages/OpenKit/Sources/OpenDesign/Palette.swift`
- `Packages/OpenKit/Sources/OpenFeatures/BrowserWindowController.swift`
- `Packages/OpenKit/Sources/OpenFeatures/HoverPreviewController.swift`
- `Packages/OpenKit/Sources/OpenImport/ArcImport.swift`
- `Packages/OpenKit/Sources/OpenModel/BrowserModel.swift`
- `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift`
- `Packages/OpenKit/Sources/OpenSidebar/Controls.swift`
- `Packages/OpenKit/Sources/OpenSidebar/FolderPreviewView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/HoverPreviewTracker.swift`
- `Packages/OpenKit/Sources/OpenSidebar/ModelSidebarActions.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarContext.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarIntent.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SidebarView.swift`
- `Packages/OpenKit/Sources/OpenSidebar/SpacePageView.swift`
- `Packages/OpenKit/Sources/OpenStore/ArchiveStore.swift`
- `Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift`
- `Packages/OpenKit/Sources/features-render/CompletionChecks.swift`
- `Packages/OpenKit/Sources/openkit/CLI.swift`
- `Packages/OpenKit/Sources/openkit/CommandsDemo.swift`
- `Packages/OpenKit/Sources/openkit/FolderPeekDemo.swift`
- `Packages/OpenKit/Sources/sidebar-render/Bench.swift`
- `Packages/OpenKit/Sources/sidebar-render/Checks.swift`
- `Packages/OpenKit/Sources/sidebar-render/Compare.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekChecks.swift`
- `Packages/OpenKit/Sources/sidebar-render/FolderPeekCompare.swift`
- `Packages/OpenKit/Sources/sidebar-render/PreviewChecks.swift`
- `Packages/OpenKit/Sources/sidebar-render/RenderCLI.swift`
- `docs/followups.md`
- `docs/plans/sidebar-completion.md`
- `docs/plans/sidebar-s6-receipt.md`
- `docs/status.md`
- `tools/e2e/engine_e2e.py`
- `tools/verification/check.py`
