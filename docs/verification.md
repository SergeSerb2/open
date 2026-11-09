# Full CLI verification

Run from any directory on macOS with Swift and Python 3 installed:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --quick
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only route,favicons
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --with-arc-data --keep-logs
```

The Site Control check opens native menus and acquires
`/tmp/open-onscreen-e2e.lock` around that suite. Do not hold this lock around the
whole runner: the release build needs no on-screen lock. Standalone native-menu
harness commands still need the lock, per AGENTS.md rule 11.

The runner uses `/bin/bash` 3.2. It builds `Packages/OpenKit` exactly once with
`nice -n 10 swift build -c release -j "${VERIFY_JOBS:-6}"`. The build runs in its
own process session. A compiler error, any output line containing `warning:`,
or a nonzero build exit stops the run. The build log records warning/error line
counts. Checks use the resulting release executables; they never call `swift run`.

`--quick` selects commands-demo, suggest-check, and commands-dump after the build.
`--only NAME[,NAME]` selects checks from the table below, preserving table order.
The build always runs; `--only build` runs just the build. Combined with `--quick`,
`--only` must select from the quick set. Unknown names and invalid flags exit 2.
`VERIFY_JOBS` sets build concurrency. `VERIFY_LOG_DIR` can name a **new** log
directory; an existing directory is refused to protect earlier evidence.

Every check runs in a fresh `mktemp -d` directory, with its own working directory
and `TMPDIR`. Synthetic snapshot prerequisites come from commands-demo. A check
selected alone creates that prerequisite through the real CLI. Roundtrip copies
the demo's output before saving it. It does not change the original fixture.

Each command must exit as expected **and** print its required success evidence.
The runner records PASS, FAIL, or SKIP and elapsed whole seconds. A failed check
does not stop later checks, except for a failed build. Exit 0 means there were no
FAIL rows. An unavailable command or executable is SKIP, detected from openkit's
usage tokens or `.build/release/<executable>`. A command that exists but fails,
prints incomplete results, or misses a dependency is FAIL. Missing node or Chrome
also makes the optional Boosts check SKIP. Checks excluded by flags have no row.

| Name | What PASS proves | Typical duration after build |
|---|---|---|
| `commands-demo` | Real BrowserModel commands, undo/redo, placement refusal, archive/restore, and persistence report all checks passed and zero failed. See [model.md](model.md). | <1 s |
| `roundtrip` | A commands-demo snapshot loads, saves, and reloads with `roundtrip OK`. | <1 s |
| `suggest-check` | The existing suggestion CLI reports N/N passed, with N > 0, including local HTTP remote-provider paths and its main-thread CPU budget. See [suggest.md](suggest.md). | 5–20 s |
| `commands-dump` | The real headless NSMenu and keyboard registry match the reference table (`missing=0 extra=0 different=0`). Default and override bindings have no unexpected conflicts. See [commands.md](commands.md). | <1 s |
| `route` | Runs an existing `tools/route-check.sh`, `tools/verify-routing.sh`, `tools/verify-route.sh`, release `route-check`, or `openkit route-check` runner when present. Otherwise exercises [routing.md](routing.md) A1–A10 through `openkit route`: host boundaries, containment, first-match order, source normalization, toggle, rejected scheme, stale target, and JSON/text agreement. Every accepted result has an explicit expected destination. | <2 s |
| `favicons` | A tiny generated site served by Python http.server on loopback fetches through the release debug flags. Concurrent fetches succeed, a second process uses the cache, 32/64-pixel PNGs read back, and a page without an icon reports missing and absent readback. All requested page/icon URLs are local. See [favicons.md](favicons.md). | <2 s |
| `sleep-demo` | The existing real model/controller/store CLI reports N checks passed and zero failed. The 5,000-tab/200-pass gate uses thread CPU p95 <2 ms; wall time is informational. Its engine boundary and policy clock remain the CLI's simulation. Expected deliberate storage errors are allowed. See [sleep.md](sleep.md). | 1–5 s |
| `adblock-perf` | Both current budgets pass: 1,000 lookups p95 <1 ms and 40 profile opens with full integrity scanning p95 <10 ms. Open max is informational. The ten lookup groups yield exactly 5,000 matches in 10,000 lookups. Official default-list downloads may be needed. See [adblock-lists.md](adblock-lists.md). | 5–30 s; network dependent |
| `adblock-catalog` | Real CLI output contains all 46 catalog IDs, category counts 3/2/5/35/1, and only EasyList/EasyPrivacy enabled by default. | <1 s |
| `profiles` | When `openkit profiles` exists, exercises the planned P-1–P-8 and P-10 flow: create, duplicate refusal, assign Space, both delete refusals with unchanged snapshot bytes, reassignment, temporary-profile deletion with retained directory, and roundtrip. Contract: [profiles plan §9.1](plans/profiles.md#91-openkit-profiles--cli-new-file-openkitprofilescliswift). | <2 s |
| `sidebar-render` | When present, `sidebar-render check` reports N/N passed, N checks passed with zero failed, or `checks: N passed, 0 failed`. | 1–5 s |
| `commandbar-render` | When present, `commandbar-render check` accepts the same summary formats as sidebar-render. | 1–5 s |
| `boosts` | Headless system Chrome loads the actual Boosts harness and production scripts. A7 asserts banner highlight geometry/color, selector commit, hidden banner, and active picker. A11 asserts the precise pick, two aligned related previews, three-match replacement, and hidden posts. Saves both PNGs and rejects runtime errors. See [boosts.md](boosts.md). | 5–20 s; npm install dependent |
| `import-arc` | Opt-in only. Read-only copies of Arc's top-level JSON files pass sidebar/archive accounting, `archive-list --limit 0`, and roundtrip. Also inspects default-profile output when profiles exists (P-9). | <2 s |

### Focused checks for intermediate pushes

`AGENTS.md` rule 10 asks for the full gate before a PR opens and when it is reported ready. For pushes in between, run the build plus the checks for what you changed. Shared targets (`OpenDesign`, `OpenModel`, `OpenStore`) reach many checks, so use the full gate when you change them.

| You changed | Run at least |
|---|---|
| `OpenSidebar`, `OpenMedia` sidebar views | `sidebar-render,sidebar-compare,media-demo` |
| `OpenCommandBar`, `OpenSuggest`, `OpenCommands` | `commandbar-render,suggest-check,commands-dump` |
| `OpenFeatures` (Split, Peek, Little Open, PiP, Site Control) | `features-render` |
| `OpenSpaceEditor`, theme tokens | `space-editor,space-legacy` |
| `OpenSettings` | `settings-preview,profiles` |
| `OpenRouting` | `route` |
| `OpenSleep` | `sleep-demo` |
| `OpenAdBlock` | `adblock-perf,adblock-catalog` |
| `OpenBoosts` | `boosts` |
| `OpenWeb` favicons | `favicons` |
| `App/` or `Engine/` | the e2e suites for the flow (`tools/e2e/engine_e2e.py --only …`) plus `build` |

An initial release build usually takes 20–90 seconds. An incremental build usually
takes 1–3 seconds. Host load, cold compiler caches, npm, and list downloads can
increase these estimates. The final table and each log give actual times/results.
Performance budgets are never retried or relaxed by the runner.

### Display and timer portability (Section 16)

Visual references use the exact key `scale-<native backing scale>-icc-<SHA256>`.
The ICC digest covers the color profile of the render host's screen. The host
is never ordered on screen. Its screen is explicit, so selection does not use
the requested synthetic render scale, a hostname, or a machine name. Both scale
and the full profile digest must match. Each renderer also checks its actual
host window against the selected key before drawing. A display change fails.
An unknown key fails with its key and a
recording instruction. There is no fallback and no automatic recording.

| Display | Native scale | ICC SHA-256 | Reference |
|---|---:|---|---|
| M5 AW2726DM | 1 | `b1e0db75fbfcbecd866fb49106037ef7f806728e9a9f2f797d3deb8d4503fc43` | Original PNGs and original color caps |
| M1 built-in | 2 | `b33d3996c56e94d25097d38213687e26e0e8224ed0c215634a8c350ed44f6856` | New exact 2x PNGs and recorded color caps |
| M5 built-in, expected from its installed Color LCD profile | 2 | `689713e234c3a538d0c88d0ad0693b98d983cee00aefa50522cc6d9d001062fa` | Unknown key: FAIL; display rerun pending (lead/user) |

The M5 built-in key is an offline profile inventory, not a runtime selection
proof. No display setup was changed. Its actual selection and render proof are
**display rerun pending (lead/user)** and are not a merge requirement.

`space-legacy` and editor P1 retain all six original PNGs. The M5 renders at
scale 1 and requires the same exact PNG bytes. The new M1 references render at
scale 2 (1800×1400 pixels for the 900×700-point scene). They also require exact
PNG bytes. The two renderers have separate references. Their metadata records
trusted `origin/main` SHA `df4767ad235106863983b45b2a1ffd87c7bd1b46`, the build
binary hashes, and each PNG hash. The recorder checks that the package source
matches that commit. It refuses existing keys and writes only a new proposal
directory. It never changes a reference in place.

`sidebar-compare` keeps the original M5 absolute limits, positions, masks,
element counts, exact paired geometry/ink, and 0.15 ΔE00 paired color drift.
Its render scale remains 1 to match the reference capture scale. The display
key uses the native screen scale and ICC profile because AppKit text and symbol
rasterization depends on that environment. Three fresh trusted-main renders
per state recorded the M1 limits with no added headroom. The three different
caps are static-inactive **1.31**, selected-pinned **2.71**, and yellow **2.25**;
the original M5 caps remain **1.17**, **1.73**, and **1.95**. Other M1 caps are
equal to or lower than the original M5 caps. The manifest keeps all 39 measured
samples and the trusted-main binary hash. The older checkpoint's OS-build-only
key and its unverified recordings were not adopted.

Suggestion check #31 remains a real wall-clock check. On every M5 CPU, its
acceptance is exactly the original raw **<600 ms**, with at most three attempts.
An unavailable CPU identity also uses that strict rule. Other CPUs compare
against a same-run fixed reference: the real local query with networking off,
then an independent 380 ms sleep, sampled three times. Acceptance requires
`elapsed / max(1, medianReference / 380) < 600 ms`. A median outside
`380..<600 ms` fails portable acceptance. The reference never invokes the remote
provider or its timeout. Each receipt prints all reference samples, the raw
elapsed time, calibrated time, lateness past 380 ms, CPU model, and load. The
separate 80 ms debounce / 300 ms configured-timeout behavior check is unchanged.
Calibration measures scheduler and local-query overhead. It does not claim that
CPU counters measure sleeping time or that a busy host meets a quiet latency
budget.

The explicit negative-proof switch only breaks checks. It cannot make a gate
pass. `OPEN_VERIFY_BREAK=all` changes one channel of one rendered pixel by
1/255 in each legacy check, changes one sampled URL-field fill by 6/255 in the
sidebar branch output, and increases the real remote timeout by 300 ms. It does
not change any reference. Individual values are `legacy`, `editor`, `color`,
and `suggest`. Leave this variable unset for positive and full runs.

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main # M5 only
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh
~/Library/Caches/OpenRE/scripts/heavy.sh env OPEN_VERIFY_BREAK=all \
  tools/verify-all.sh --only space-legacy,space-editor,sidebar-compare
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only build
/usr/bin/lockf -k /tmp/open-m5-quiet.lock \
  ~/Library/Caches/OpenRE/scripts/heavy.sh env OPEN_VERIFY_BREAK=suggest \
  Packages/OpenKit/.build/release/openkit suggest-check
```

Run M1 jobs through `m1.sh` in a detached checkout of the pushed branch, per
TANDEM §4M. Never commit or edit source there. The normal runner retains the
on-screen lock and owned-window cleanup for the native editor suite. Private
capture inputs and comparison images remain in ignored `.re/` or private
receipt directories; the committed references use synthetic fixtures only.
The standing lock order is quiet lock, then heavy slot, then screen lock when
needed. Build first under `heavy.sh` alone. Time the already-built command;
never hold the quiet lock during a build. Visual negative proofs take no
quiet lock; only the timer proof does.

#### Recorded controls (2026-11-07)

The trusted-main control used `df4767ad235106863983b45b2a1ffd87c7bd1b46`.
On the M5 AW2726DM, all four focused gates passed. Its timer measured 395 ms
at load 13.8/25.6/24.3. All 13 sidebar tables were byte-identical between the
paired processes. On the M1, unchanged main failed the original three visual
gates: legacy Space 0, all three editor P1 PNGs, and the three color caps
listed above. Its timer happened to pass at 390 ms, load 54.7/34.3/16.5.
The historical timer miss is load dependent; this control does not reproduce it.

The strictness receipt compares all six original PNG files with that trusted
commit: every byte is unchanged. All 13 original color caps also match exactly.
The M5 timer decision still compares the raw elapsed time with 600 ms.
These checks are recorded in `m5-strictness-proof.json` under
`.re/s16/gate-portability/` in the main checkout.

Unknown-key proof used disposable copies of the real command scripts and
metadata. Removing only the current display entry while keeping the other
committed key made both legacy and sidebar `--probe` exit 1 on each machine,
with the actual key and `no fallback` in the error. Missing private captures
cannot turn that unknown-display failure into SKIP.
The real renderer also rejected the other committed key on each machine.
The M5 requested render scale 2 with the M1 key; its actual host reported the
1x AW2726DM key and exited 1 before creating a PNG. The M1 rejected the
opposite request in the same way. Both errors included `no fallback`.

The first M1 focused positive run passed all four gates. Timer #31 measured
398.894 ms raw, 376.058 ms calibrated, reference median 403.075 ms, at load
22.4/29.1/22.2. All 13 paired sidebar tables were byte-identical, with zero
color drift. Both PNG checks required exact bytes.

M1 negative proof changed one rendered pixel by 1/255: legacy Space 0 and all
three editor P1 PNG rows failed. The real 300 ms timeout break failed all three
attempts: raw 712.104/724.916/715.039 ms, calibrated
693.081/705.551/695.938 ms, reference 390.430 ms, load 18.9/23.6/21.9.
The first color probe used 2/255 and did not fail selected-pinned. The final
6/255 probe failed all 13 states on all three paired attempts. The required
static-inactive/selected-pinned/yellow drifts were 0.18/0.83/1.40 ΔE00,
each above the unchanged 0.15 limit. References stayed unchanged.

The first full runs used `33b60a4a` and each had 22 PASS / 2 FAIL. A branch
regression moved ordered motion hosts onto the screen: sidebar RI and two MC15
rows failed on both machines. `50bb3808` restores those hosts to their original
offscreen position; only never-ordered snapshot hosts use a screen-associated
frame. The M5 also missed command-bar CPU p95 (10.26 ms against 8 ms, load
12.0/13.9/17.9). The M1 also missed unrelated suggestion row #56 (extension actions
p95 0.3120 ms against 0.2 ms, load 8.31/12.78/17.29). Its quiet rerun passed
all 56 suggestion checks: row #56 p95 0.1608 ms, load 14.11/10.49/12.39.
These original misses remain in the receipts.

The next M1 run confirmed RI/MC15 passed, but two folder-hover checks failed
(622 sidebar checks passed). They use ordinary snapshot hosts, which also need
the original offscreen frame. `5c443a56` limits screen association to explicitly
keyed verification renders. Ordinary snapshots and motion hosts keep the
original placement. The reference and color-comparison paths remain keyed.

#### M5 negative proof and quiet control

The M5 visual negative run exited 1 with build PASS and all three selected
visual gates FAIL. One 1/255 pixel change failed legacy Space 0 and all three
editor P1 PNG rows (276 functional rows still passed). The 6/255 URL-field
fill change failed all 13 sidebar states on all three paired attempts. Its
fill drifts for static-inactive/selected-pinned/yellow were 0.18/0.83/1.40 ΔE00
on every attempt, above the unchanged 0.15 limit. One static-inactive attempt
also had text drift up to 0.61; the deliberate fill alone failed every attempt.
Yellow also exceeded its original absolute cap: 2.04 > 1.95. End load was
15.22/12.48/12.04.

The separate M5 timer negative run failed only row #31: raw
694.309/702.882/723.817 ms, reference median 390.280 ms, load 14.5/12.4/12.0.
The printed calibrated values were 676.020/684.367/704.750 ms; the M5 decision
used raw times. No cap changed. All three attempts failed.

The M5 quiet command-bar rerun passed 151/151: CPU p95 3.20 ms, inline
completion +0.114 ms, load 10.3/11.5/11.7. The unchanged trusted-main export
`7f405f3b3e5ccf5716d2664b1f6e91e36b219df3` ran next under the same lock and
passed 151/151: CPU p95 3.64 ms, inline completion +0.097 ms, load
9.7/11.2/11.6. Its exported package's 801 tracked files were checked against
the Git blobs (including symlinks), and the cached sidebar binary hash matched
its first full-run receipt. No fresh reference was recorded from branch code.

The later M5 command-bar check in the full run missed only row #151: inline completion
+0.415 ms against +0.3 ms, CPU p95 7.44 ms against 8 ms, load 26.0/23.5/18.3.
The strict quiet run above passed both rows #150 and #151, with its main
control in the same session. This meets TANDEM §4b for changes outside the
command-bar product code. The full-run miss remains in its summary table;
no timing threshold or comparator was changed.

The first M5 final sequence was interrupted by the lead's lock-order change.
Its partial receipt remains. The completed negative runs above used the lead's
temporary heavy-before-quiet ruling, before its 16:50 withdrawal. The standing
order is documented above; new timing runs build first without quiet, then
take quiet before heavy for the already-built command. Visual negative proofs
held no quiet lock. All remaining owned children of the interrupted sequence
were reaped before the restart.

#### Final M1 full gate

The detached M1 run on `5c443a56` passed **24/24**, with zero FAIL and zero
SKIP. Start load was 5.85/8.44/9.50; end load was 4.96/5.57/7.02. Timer #31
measured 384.295 ms raw, 365.684 ms calibrated, reference median 399.340 ms,
load 7.6/7.4/8.7. Sidebar passed 624/624. Its 13 paired color tables were
byte-identical, with zero drift. The preceding `50bb3808` full run ended
23 PASS / 1 FAIL (the two folder-hover rows); its receipt is retained.

The receipts were copied back before the owned detached M1 worktree was
removed. No owned M1 job remains. `CLAUDE.md` remains a symlink to `AGENTS.md`.

#### Final M5 full gate and complete tables

The M5 full run on `e21c62e4` (same check source as M1's `5c443a56`) ended
**23 PASS / 1 FAIL / 0 SKIP**. Only command-bar timing row #151 missed under
load; the strict quiet branch/main controls above satisfy TANDEM §4b.
All four portability gates passed. Sidebar passed 624/624, and all 13 paired
color tables were byte-identical with zero drift. Original M5 color maxima
were 1.17/1.73/1.95. Timer #31 used raw 400.981 ms against 600 ms; reference
median 394.832 ms, load 63.3/24.1/16.2. Full-run start load was
9.65/11.19/11.57; end load was 26.06/26.58/22.09. Neither machine skipped a target.

After the completed full gates, main advanced to
`300a587546a8145b4d0d5b2af67e19a05ecfbdce`. Its overlap was only
`docs/followups.md`; the merge was clean (`e69b81b1`). The CLI package,
verification helpers, and runner are byte-for-byte unchanged from the tested
source. The required post-merge `heavy.sh tools/build.sh Debug` passed with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`, start/end load
37.66/29.00/23.36 and 50.86/39.43/28.55. TANDEM §4 rule 5a requires no new full gate
or unrelated e2e suite for this merge. No App was launched.

The table preserves the actual full-run result. Command-bar acceptance comes
from the separately recorded strict quiet PASS, with no budget change.

| Check | M5 full result | Seconds | M1 full result | Seconds |
|---|---|---:|---|---:|
| `build` | PASS | 2 | PASS | 39 |
| `commands-demo` | PASS | 5 | PASS | 1 |
| `roundtrip` | PASS | 1 | PASS | 0 |
| `space-legacy` | PASS | 2 | PASS | 2 |
| `space-editor` | PASS | 119 | PASS | 160 |
| `space-pad-compare` | PASS | 4 | PASS | 3 |
| `suggest-check` | PASS | 31 | PASS | 35 |
| `commands-dump` | PASS | 1 | PASS | 0 |
| `route` | PASS | 16 | PASS | 2 |
| `favicons` | PASS | 3 | PASS | 0 |
| `media-demo` | PASS | 0 | PASS | 0 |
| `sleep-demo` | PASS | 1 | PASS | 1 |
| `adblock-perf` | PASS | 1 | PASS | 1 |
| `adblock-catalog` | PASS | 0 | PASS | 0 |
| `profiles` | PASS | 3 | PASS | 0 |
| `settings-preview` | PASS | 91 | PASS | 94 |
| `sidebar-render` | PASS | 110 | PASS | 115 |
| `sidebar-compare` | PASS | 21 | PASS | 20 |
| `commandbar-render` | FAIL | 41 | PASS | 41 |
| `features-render` | PASS | 96 | PASS | 94 |
| `extensions-render` | PASS | 9 | PASS | 7 |
| `sitecontrol-render` | PASS | 488 | PASS | 76 |
| `boosts` | PASS | 5 | PASS | 4 |
| `verify-secrets-fixture` | PASS | 7 | PASS | 4 |

#### Review checklist

| Checklist item | Result | Evidence |
|---|---|---|
| 1. Input limits | PASS | Display keys are exact scale/ICC pairs; metadata ≤1 MiB, ICC ≤4 MiB, PNG ≤16 MiB, CPU string ≤256 bytes. Unknown-key CLI proofs fail on both machines. |
| 1. Allocator ceilings / new product parser boundaries | N/A | No product input parser or allocation path changed; new references are committed synthetic fixtures. |
| 2. Lifetimes / callbacks | PASS | Keyed snapshot hosts are never ordered; mismatch closes the host before exit. Other hosts keep original placement. No callback, ID, or deferred-state contract changed. |
| 3. Real keys / focus / visibility paths | N/A | No production key router, menu, focus, or visibility change. |
| 4. Checks fail with a deliberate break | PASS | One rendered pixel, one fill color, and a real +300 ms timeout fail the required gates on M5 and M1; all original references stay unchanged. |
| 4. Image comparisons | PASS | Exact PNG bytes; original M5 caps; exact paired geometry/ink and ≤0.15 ΔE00 drift. Both full runs pass the four portable gates. |
| 4. Specific dialog identity | N/A | No new dialog assertion. Existing editor native-picker checks remain unchanged and pass. |
| 4. Configured timing / bounded real-time check | PASS | Existing 80/300 ms configuration check retained. One behavior, ≤3 attempts, bounded independent reference, raw time/lateness/load printed. M5 raw <600 ms retained. |
| 4. Isolated roots / ports / cleanup | PASS | Existing runner uses private per-check scratch roots; real suggestion HTTP fixture uses an ephemeral port. Negative editor runs finish and reap children. Owned M1 worktree removed; no owned dependent job remains at handoff. |
| 5. UI / motion product behavior | N/A | No product motion change. Original unkeyed host placement is restored; sidebar 624/624 on both machines. No new visual-parity claim. |
| 6. Docs / comments / follow-ups | PASS | `docs/verification.md`, portability follow-ups, and Machines paragraph agree. `CLAUDE.md` remains a symlink to `AGENTS.md`. M5 built-in proof is explicitly pending. |

## Section 1 completion (2026-10-28)

Sidebar implementation PRs #123–#135 are merged through main `52212f17`.
The lead will fill the final-main results below. Saved PR receipts do not close
this soak, the user capture list (calibration C, C1–C11 except completed C10,
TS-C1 and `favorites-hover`), or quiet-machine absolute latency acceptance.
C10's exact drag-hide threshold refinement also remains open.

| Final-main check | Result |
|---|---|
| verify-all (final main 52212f17) | **PASS 22/22** (2026-10-28 20:46 PDT) |
| sidebar-render check x3 | **PASS** 608/608 ×3 |
| e2e sidebar x3 | **PASS** 21/21 ×3 |
| e2e sidebar-completion x3 | **PASS** 195/195 ×3 (run 1 had one foreground interruption that the suite retried and passed) |
| e2e app-actions x3 | **PASS** 50/50 ×3 (run 2 had one foreground interruption, retried and passed) |
| e2e window x3 | On 52212f17: 76/76, 76/76, then run 3 **FAIL** (`window-focus: key focus not ready: active=true … targetIsKey=false keySameObject=true frontmost=Open`; `ensure_key()` did not retry the not-ready error and the suite aborted after `traffic_light_actions`). Fixed in `be6ea83f` (readiness waits for full-screen completion; `ensure_key()` retries only the native not-ready error within its 15 s deadline). On `be6ea83f`: **PASS** 76/76 ×3 consecutive. |
| crash reports | **None**: no new Open report in `~/Library/Logs/DiagnosticReports/` during the soak |

Speed receipts already recorded in the merged PRs:

| Gate / scope | Saved receipt | Source |
|---|---|---|
| SM6 main-thread instruction gate | 679,842,406 ≤ 745,172,115; added O(n) title-sizing pass FAIL at 785,999,099; restored PASS at 680,827,395. | [#125](https://github.com/SergeSerb2/open/pull/125) |
| Stored-icon scroll, 1,000 rows | p95 0.86 ms; delayed-draw negative proof FAIL at 30.88 ms. | [#131](https://github.com/SergeSerb2/open/pull/131) |
| FP10 paired folder-peek gate | 3/3 PASS; peek p95 2.663/2.766/2.812 ms (2.66–2.81 ms), native scroll layouts/frame 18/18; O(n) layout and added 3 ms spin controls FAIL. This uses the parent-approved matched-plain rule; the <1 ms median goal stays open. | [#135](https://github.com/SergeSerb2/open/pull/135), [receipt](plans/sidebar-s6-receipt.md) |
| Site Control simple editor instruction gate | Reference 135,203,676; ceiling 148,724,044; added O(n) construction FAIL at 365,893,368. The <12 ms CPU p95 target still needs quiet-machine acceptance. | [#133](https://github.com/SergeSerb2/open/pull/133) |
| Cold command bar, App Debug entry to first results applied to views | Earlier three runs 3.35/3.42/3.28 ms; final PR run 4.78 ms (rounded range 3.3–4.8 ms), versus the unchanged 50 ms budget. This excludes key routing, transport and presented-frame latency. | [#134](https://github.com/SergeSerb2/open/pull/134), [earlier receipts](re/sidebar-completion.md#13-numbered-shortcuts-and-recent-tab-switcher-2026-10-28) |

## Performance gates for offscreen harnesses

Offscreen performance regression gates use **main-thread retired instructions**
with accepted counts per CPU brand and macOS build. CPU p95, wall p95 and load
remain printed diagnostics. Scheduling onto different cores under heavy load can
change CPU milliseconds; it does not change the amount of instruction work in
the same span. Absolute product time targets still need a quiet-machine check.

`sitecontrol-render` applies this method to the full 2x cold-open workload
(20 Boosts, 12 Settings rows, fresh native tree and first draw). It discards five
warmups, measures 30 opens, takes their median (rounded up to an instruction), and
requires `median <= ceil(accepted × 1.10)`. The small versioned fixture is
`Packages/OpenKit/Sources/sitecontrol-render/Fixtures/instruction-baselines.json`.
M5 Pro / 26B5112a records the lead-accepted 95,035,968 instructions; the limit is
104,539,565. Add an M1 entry only after its accepted measurement. An unknown
CPU/build prints the count and reason as **INFO**, not PASS. A missing counter
or invalid fixture fails; neither CPU nor process totals substitute for it.
The lightweight skeleton timing is informational; the full cold workload owns
the regression gate.

The helper resolves `thread_selfcounts` with `dlsym`, checks the THSC_CPI=1 C ABI,
and reads the current main thread. It is compiled only in the harness executable,
never in App or library targets. It reuses the SM6 measurement helper. A negative
proof adds an O(n) native row-construction pass inside the measured span and must
fail the unchanged instruction limit, then restores the source.

After a release build, this exact command prints the CPU p95 for the lead's
quiet M5 check (the product target remains **<8 ms**):

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh Packages/OpenKit/.build/release/sitecontrol-render bench --fixture cold
```

`cold-measure --thread-instructions` prints the sample counts for independent A/B
runs. Raw traces stay local; commit only synthetic numeric evidence and hashes.
The Site Control A/B report is in `docs/sitecontrol/step-2/performance/README.md`.
This method does not claim that other existing harnesses have already migrated.

### Simple Boost editor open: load-robust gate (2026-10-28)

The old `EditorBench` row already used `CLOCK_THREAD_CPUTIME_ID`, rather than
wall time. Untouched `origin/main` `64e54195` failed only this row:
**17.964 ms CPU p95**, load1 **77.35**, **1470/1471** Site Control checks passed.
The same run's cold fixture printed 11.615 ms CPU / 189.481 ms wall p95 at
load1 84.21. That wall/CPU gap includes time off the CPU (preemption or blocked native
calls). Such waits were already excluded from the editor's old CPU gate.
CPU execution rate still varies under load.
Core choice, frequency and memory contention were not measured separately.

Temporary thread-CPU splits in `BoostEditorController.present` and the real
settle path located the cost. At load1 6.28, CPU p95 was 13.336 ms: presentation
7.432 ms, separate layout 0.069 ms, display 0.181 ms, transaction flush 6.328 ms.
These are independent p95 values; do not add them. Within presentation, fresh
view/session/panel construction took about 3.4–4.7 ms in the measured opens.
The font cells called font lookup and text rasterization on each fresh tree.
PNG hue sampling runs separately on a worker; it was 7.640 ms in the failing
stock run and is outside the open span. The temporary probes are removed.

`EditorButton` now caches only the fixed 26×26 font-cell images, keyed by family,
1x/2x scale, selected/pressed/hovered state and enabled state. The 128-entry cap
bounds retained images. Core Graphics measured a 224-byte row at 2x: 11,648 bytes
per bitmap, at most 1.43 MiB for the cache on this M5. Every native control,
accessibility node, focus layer and selection transition remains live.

`EditorOpenBench` retains the same workload: one real 2x editor panel creation,
layout, native first display and transaction flush; five discarded warmups and
20 measured opens. Each open now has its own autorelease pool; panel close and
pool draining remain outside the measured span. The full `check` path drains
completed UI suites before starting the next suite. It also requires successful presentation and a native content
view. The existing harness-only `ThreadInstructions` sampler brackets that span.
The hard regression gate uses the rounded-up median main-thread instruction
count, with the existing CPU-brand/macOS-build fixture and ×1.10 method.
Missing/backward counters or an invalid fixture fail. An unknown editor reference
reports INFO, with no cost PASS. No CPU or wall-time fallback or retry exists.
CPU p95, wall p95, presentation/settle CPU p95, lateness versus **12 ms**, and
load1 are printed on every run. A separate **INFO** table row prints main-thread
CPU p95 versus **12 ms**, its lateness and load1. It is excluded from acceptance
counts, including when p95 exceeds 12 ms. GPU completion and deferred work remain outside
this existing native-display span.

Cost acceptance and reference recording use only the complete
`sitecontrol-render check` procedure, as invoked by the verification runner.
Standalone `bench --group editor` prints raw instructions and CPU INFO but has
no instruction-budget acceptance. Its process history differs from the full
check. Only `check` passes `acceptInstructionCost: true` to `EditorBench`.

The **initial editor instruction reference** in `54b636bc` was recorded before
the font-image optimization. Three separate processes with the **original product
sources** produced the values below; the median of their medians was
**141,542,712**, with a ceiling of **155,696,984**. These values are retained as
history. The first parent review re-recorded the optimized product, but used a
standalone benchmark with different process history. Both references below are
historical; the current reference uses the corrected full gate procedure,
described after them. The cold-open and SM6 references remain unchanged.

| Process | Original median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| 1 | 141,176,621 | 14.967 | 17.113 | 11.48 |
| 2 | 141,865,163 | 15.342 | 22.943 | 8.31 |
| 3 | 141,542,712 | 17.062 | 20.806 | 8.31 |

The instruction medians have 0.49% full spread, while CPU p95 varies by 14.0%.
With the font cache, the same three-process bench gave:

| Process | Cached median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| 1 | 136,812,486 | 13.282 | 14.599 | 8.13 |
| 2 | 136,139,868 | 13.423 | 15.325 | 8.13 |
| 3 | 136,352,450 | 12.874 | 14.710 | 7.88 |

The median work fell **3.67%**. These loaded CPU values do not establish quiet
`<12 ms` acceptance. The parent explicitly prohibited synthetic burners; none were started. All later checks use real shared load.

The first parent review (`c3628d9e`) re-recorded a reference from the optimized product in
`54b636bc`, with the explicit INFO row added outside the measured span. Following
SM6's recording method, discard one fresh process, then take the median of five
fresh-process medians. Each editor process still discards five opens and measures
20. The exact command is
`Packages/OpenKit/.build/release/sitecontrol-render bench --group editor`.
The recording used the shipping font-image cache without product-source changes;
`review-reference.json` retains all 20 samples per process, source/binary hashes
and the raw logs. No process was retried or selected out of the five.

| Process | Optimized median instructions | CPU p95 ms | Wall p95 ms | Load1 |
|---|---:|---:|---:|---:|
| Discarded warmup | 136,266,026 | 13.930 | 16.686 | 14.55 |
| 1 | 136,469,336 | 13.835 | 18.617 | 14.55 |
| 2 | 136,091,821 | 12.957 | 15.291 | 14.91 |
| 3 | 135,985,517 | 13.295 | 14.156 | 14.75 |
| 4 | 136,063,236 | 8.981 | 10.841 | 14.37 |
| 5 | 135,987,601 | 9.525 | 11.424 | 13.94 |

That historical optimized reference was **136,063,236**; its ceiling was
**149,669,560 = ceil(136,063,236 × 1.10)**. It lowered the initial ceiling by
6,027,424 instructions, but the later review below found mismatched procedures.
The original **141,542,712** reference above is historical only. Some INFO values
are below 12 ms, but these are shared-load recordings; the lead's quiet-machine
acceptance before merge remains required.

The next parent review found a procedure mismatch: `c3628d9e`'s two full gate
runs measured **144,265,719 / 144,230,413**, or **+6.028% / +6.002%** above its
standalone reference. Instruction probes located the extra work in the global
`CATransaction.flush()`. Both paths used scale 2, five warmups and twenty measured
opens; they had different populations of autoreleased native windows.

| Instrumented procedure | Start/end native window list | Present median instructions | Layout/display median | Flush median | Total median |
|---|---:|---:|---:|---:|---:|
| Standalone bench | 2 → 27 | 90,921,755 | 1,225,610 | 44,258,568 | 136,524,128 |
| Full check, before pool fix | 133 → 158 | 90,896,645 | 1,230,301 | 51,708,916 | 143,835,526 |
| Full check, drain completed suites | 5 → 30 | 90,115,887 | 1,214,082 | 43,836,864 | 135,037,759 |

Phase medians are independent and need not sum to the total median. The first
two rows differ by **7,450,348 instructions in flush**, while presentation differs
by only 25,110. All three rows had **400 font-image cache hits and zero misses**
in the twenty measured opens. The cache had 20 entries in standalone and 44 in
the full path, but neither path decoded/rasterized font cells during measurement.

The controlled change was to drain autorelease pools after completed cold,
flow, editor-flow, render and skeleton suites. This released the earlier suites'
closed native window objects before the editor's global transaction flush.
The full gate's start list fell **133 → 5**, and its total work fell
**143,835,526 → 135,037,759**. This identifies prior-suite window lifetime as the
cause of the extra work; it is not a scheduler or warm/cold font-cache explanation.
Raw probes are `procedure-profile-bench.log`, `procedure-profile-check/` and
`procedure-pool-profile-check/`. All temporary `[DEBUG-procedure]` probes and
font-cache counters were removed before recording the final reference.

The benchmark also drains a pool after closing each sample's panel. This keeps
closed windows from accumulating across its own five warmups and twenty samples,
matching AppKit's usual event-loop pool lifetime. The real open/layout/display/
flush remains inside the counters; earlier suites and panel teardown are outside.
Every final run prints its procedure and before/after native-window counts.

The current accepted reference is recorded by **five complete fresh-process gate runs**, using exactly this command each time:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
```

Each invokes the full `check` path, after pooled suites, at 2x with five discarded
opens and twenty measured opens in a per-open pool. No whole process was discarded
or retried. The reference is the median of the five process medians.

| Reference process | Median instructions | CPU p95 INFO ms | Load1 | Native window list | Full check |
|---|---:|---:|---:|---:|---|
| 1 | 135,418,826 | 14.775 | 8.70 | 5 → 5 | 1471/1471 PASS |
| 2 | 135,732,992 | 13.486 | 7.60 | 5 → 5 | 1471/1471 PASS |
| 3 | 135,059,155 | 11.272 | 9.94 | 5 → 5 | 1471/1471 PASS |
| 4 | 135,203,676 | 14.056 | 8.20 | 5 → 5 | 1471/1471 PASS |
| 5 | 134,606,189 | 10.124 | 10.00 | 5 → 5 | 1471/1471 PASS |

**Accepted reference: 135,203,676; ceiling: 148,724,044 = ceil(reference × 1.10)**.
The five medians span **0.833%** of the reference. Source hashes, executable
hashes, all twenty samples per process, per-command loads and the unchanged
procedure label are retained in `procedure-reference.json` and
`procedure-reference-1/`…`procedure-reference-5/`. All five started and ended
with five entries in the native window list. The fifth command waited 375 s
for a heavy slot; its on-screen check duration also includes lock queue time,
which is outside the unchanged 180 s execution deadline.

The 28 editor render images before/after cover 1x/2x and all editor states.
All 28 font-card regions are pixel-identical. 23 full images are identical;
the other five differ at nine pixels outside the font card by at most 1/255,
within the pre-existing `CLI.stablePixels` 2/255 native redraw tolerance. No
comparison threshold or saved render baseline changed.

Initial negative proof against the historical ceiling: temporarily construct four extra `BoostEditorView` trees inside
`BoostEditorController.present`, before constructing the actual view. Each tree
performs the real O(n) native font/control construction. The unchanged gate
reported:

```text
| FAIL | simple editor build/layout/first draw median 372869037 instructions <= 155696984 (ceil(141542712 x1.10)); Apple M5 Pro / 26B5112a |
5/6 passed
```

The other five benchmark checks passed (CPU p95 41.261 ms, load1 7.71). The
extra trees and all debug probes were then removed and the release binary
rebuilt. This proof adds real work inside the production open path; it does
not alter the gate or its fixture.

At `c3628d9e`, the parent-review negative proof repeated the real four-extra-tree construction
inside `BoostEditorController.present`, including each extra view's native
layout, against the **optimized** reference and lower ceiling:

```text
| INFO | simple editor build/layout/first draw main-thread CPU p95 38.466 ms vs 12 ms; lateness +26.466 ms; load1 17.04 (quiet-machine acceptance by lead) |
| FAIL | simple editor build/layout/first draw median 396669877 instructions <= 149669560 (ceil(136063236 x1.10)); Apple M5 Pro / 26B5112a |
5/6 passed
1 INFO (no acceptance result for these entries)
```

This run exited 1 as required; all five other acceptance checks passed. The
extra work was removed in a `finally` path and the release binary rebuilt.
`BoostEditorPanel.swift` is byte-identical to `54b636bc`. The new INFO row
therefore stays visible even on failure, without raising the pass count.
Raw evidence is `review-negative.log` and `review-negative-proof.json`.

The current negative proof uses the **same full gate command as calibration**:
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render`.
Temporarily construct and lay out four extra real `BoostEditorView` trees inside
`BoostEditorController.present`, before constructing the actual editor. The
unused sessions have no interactions and are released without calling the host's
close action, so the proof adds native construction/layout without changing the
flow's expected close count or deleting a new empty Boost. Against the current
reference, the real command reported:

```text
| INFO | simple editor build/layout/first draw main-thread CPU p95 22.861 ms vs 12 ms; lateness +10.861 ms; load1 11.95 (quiet-machine acceptance by lead) |
| FAIL | simple editor build/layout/first draw median 365893368 instructions <= 148724044 (ceil(135203676 x1.10)); Apple M5 Pro / 26B5112a |
1470/1471 passed
2 INFO (no acceptance result for these entries)
```

The full verification command exited **1**; only the editor instruction budget
failed. The renderer was reaped and no native app remained. The temporary trees
were removed in a `finally` path and the release binary rebuilt before the three
final gate runs. `BoostEditorPanel.swift` is byte-identical to `c3628d9e`.
Evidence: `procedure-negative/`, `procedure-negative-proof.json` and the restored
release-build log. The ×1.10 ceiling and 12 ms product target were unchanged.

F25 native focus also needed an environment classification. Earlier runs
closed and hid the editor while the app became inactive and its parent was not
key. At load1 29.45 all three old attempts lost activation (`green-8/`). The user
then confirmed active use of this Mac, often with T3 Pretty frontmost, plus other
agents that may activate apps. External foreground loss is **INTERRUPTED**, not
an Open failure.

F25 now follows `tools/e2e/engine_e2e.py`: at most three attempts, each from a
fresh registered app, model and windows. Every attempt records foreground app
name, bundle ID and PID plus load1; strings are bounded and line/pipe sanitized.
A focus-dependent assertion outside the owned harness/renderer processes is
recorded as `INTERRUPTED (foreground lost to <app>)`, even if its local assertion
was true. Historical interrupted rows remain visible and never count as passes.
A later complete attempt can PASS; an owned-foreground wrong-key/loss result is
FAIL without retry. The cached app flag alone is not sufficient. No app is
activated and no window is made key to repair a tested Done action.

If all three attempts are interrupted, the native CLI, locked worker and
`verify-all.sh` propagate **INTERRUPTED / exit 2**, not FAIL or PASS. Real failures
retain exit 1, and available interrupted checks are not relabeled SKIP. The
native 20 s process bound, 3 s setup/close bounds and configured 0.120 s close
remain unchanged. Foreground status is collected only from app identity, never
window titles or URLs.

A separate fixture isolation issue was proved. `padAndWindowFlows` had closed
two controllers but left their two offscreen `EditorParentWindow` objects ordered
in the renderer while the registered native suite ran. The new guard failed on
the old caller:

```text
| FAIL | F25 native key suite has no competing editor parent windows (found 2) |
93/94 passed
```

The other 93 editor flow checks passed. `EditorFlows` now closes both parents
before native launch, and the zero-competing-parents guard remains. The native
fixture creates its activating browser parent first, then waits for that window
to be active, frontmost, main and key before presenting the nonactivating panel.
This establishes a valid browser precondition without relying on a windowless
app becoming frontmost. Only the on-screen fixture changes; offscreen render
and benchmark geometry remain unchanged. Fixture isolation does not claim to
prevent the external app changes confirmed by the user.

A second runner flake was found before final verification. The old runner
applied `run(..., timeout=180)` to **lockf plus the renderer**, so lock queue time
consumed the execution deadline. It failed after 180 s and left renderer PID
40906 running with PPID 1 after lockf exited. That process had exited before the
resume audit; no owned renderer or harness app remained.

`check.py` now runs an internal worker that **retains the shared lock itself**.
It opens `/tmp/open-onscreen-e2e.lock` and waits in a blocking `fcntl.flock(fd, LOCK_EX)`, joining the kernel queue alongside `lockf` waiters without polling. While blocked, a cancellation signal raises out of `flock`; setup and child assignment still defer cancellation until their owned resources are recorded. This uses the same shared open-file-description lock as `lockf`, without a spinning child. Default-mode callers use `lockf -k` to preserve the lock path. After acquisition, the worker checks that its inode still matches the current path and retries if an older caller unlinked or replaced it. No renderer or private suite root starts
before acquisition; lock queue time has no suite deadline. The worker keeps the
unchanged **180-second** renderer deadline, starts the renderer in a fresh process
group, and terminates that group and reaps the renderer on timeout, exception or
cancellation. Registered
LaunchServices apps escape that process group, so the worker also owns a private
suite root and removes only harness apps whose full executable path is under
that root. Foundation used its system temp directory despite `TMPDIR` in the
observed CLI; `OPEN_VERIFY_SUITE_ROOT` now explicitly places the registered app
copy under the owned root. A relative, missing or oversized root is refused.
The runner checks full paths before each signal and waits for app disappearance.

The real timeout proof held the lock with an explicit release handshake, observed
2.067 s queue time with no suite startup before release, then paused only its
renderer and real registered app. The unchanged deadline reported:

```text
On-screen cleanup: renderer 86332 reaped; native apps stopped=1
FAIL: on-screen suite timed out after 180s (owned children reaped)
```

Both PIDs were absent and the private root was removed. The log lifetime was
182.387 s including the queue and cleanup. The proof controller's final assertion
incorrectly assumed the shared lock would remain free; another job had acquired
it (observed lockf PID 90590). That assertion was corrected to check our wrapper's
exit, not exclude other users. The actual timeout artifacts and process absence
were independently audited in `runner-timeout-proof.json`; no extra 180-second
fault run was used to replace the recorded result. The invalid-root CLI also
failed as intended (`0/1 passed`) before launching any app.

PR #133 review comment **4407550548** found an additional cancellation hole on
`715198ed`. Default SIGTERM exits Python without unwinding `finally`, while the
detached renderer survives. The end-to-end negative proof ran the old file from
`git show 715198ed:tools/verification/check.py`, under `lockf` with a private test
lock and `/bin/sleep 30`. It stopped the owned child and sent SIGTERM to the
worker/wrapper process group. The first queued contender acquired the lock while
the child and private root still existed:

```text
715198ed SIGTERM: lock command exit=-15, expected worker exit=143
child PID 24049 gone=false; private root removed=false
lock busy during cleanup=false; cleanup log count=0
contender: child_gone=false, root_removed=false -> FAIL
```

The proof controller then killed only that owned child and removed its leaked
root. This case opened no UI and used no CPU burner. Raw evidence is
`signal-old-term-sleep.log` and `.json` under `.re/sidebar-flakes/`.

The first handler-only experiment also showed why the worker must own the lock:
macOS `lockf` kept a separate wrapper (27416) and Python worker (27417), even with
`-k`. Group cancellation killed the wrapper and unlocked before the worker's
cleanup completed. FD-mode acquisition fixes that ownership problem; there is
no long-lived lock wrapper to die before cleanup. The worker is entered directly
as `python3 tools/verification/check.py onscreen-suite <command>` and acquires
the machine lock internally. Do not wrap this internal command in another
`lockf` on the same path.

SIGTERM, SIGINT and SIGHUP handlers record the first signal. They do not raise
across temporary-root or `Popen` assignment, which could lose a just-created
child. Bounded 0.25 s communication waits observe cancellation while preserving
one absolute 180 s execution deadline. One idempotent cleanup function masks
those signals, reaps a queued lock helper, sends TERM to the unreaped renderer's
process group, retains the leader PID through the existing 2 s grace, and sends
KILL if live group members remain. Zombie-only groups need no further signal.
It reaps the renderer, stops registered apps by their exact owned-root executable
paths, removes the root, then closes the lock descriptor **last**. Repeated
cleanup calls are no-ops. Exit is **128 + signum** only after cleanup. A closed
parent output pipe cannot replace that status with Python's exit-time flush
error: cancellation uses `_exit` after all owned resources are gone.

Fixed end-to-end proofs use the real internal worker and the real machine lock.
An independent queued contender checks child/App absence and root removal at its
first lock acquisition. The first four active-child cases stop the owned children
before cancellation; the closed-pipe case keeps its child running. No case waits
for the 30 s command to complete naturally.
The native case runs the actual `sitecontrol-render native-key-check`, including
its LaunchServices-registered `EditorHarness.app`; no desktop input was driven.

| Case | Worker | Renderer/child | Registered App | Exit | Lock held during cleanup | State when contender acquired |
|---|---:|---:|---:|---:|---|---|
| SIGTERM, then repeated INT/HUP/TERM | 32940 | 32943 | — | 143 | yes | child gone, root removed |
| SIGINT | 35247 | 41368 | — | 130 | yes | child gone, root removed |
| SIGHUP | 41470 | 41472 | — | 129 | yes | child gone, root removed |
| Real renderer/App, SIGTERM and repeats | 41507 | 41510 | 41516 | 143 | yes | renderer and App gone, root removed |
| Queued SIGTERM | 44317 | never started | — | 143 | original holder retained its lock | helper 44319 reaped; no root created |
| SIGTERM, running child, parent pipe closed | 44323 | 44325 | — | 143 | yes | child gone, root removed |

The four active-child cases with an open output pipe each printed exactly one
cleanup line; the queued-cancellation case also printed one.
The native proof printed:

```text
On-screen cleanup: renderer 41510 reaped; native apps stopped=1; private root removed
On-screen cancellation: SIGTERM; owned cleanup complete; exit 143
contender: child_gone=true, app_gone=true, root_removed=true
```

The closed-pipe case verifies status and resource state independently of log
delivery. The queued case verifies cancellation before the renderer/deadline
starts. Receipts are `signal-fixed-*.json` and matching logs; the proof drivers
are local under `.re/sidebar-flakes/`. No threshold, instruction reference,
native focus deadline or suite execution deadline changed.

Requested review verification:
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render,sidebar-render`
passed: build **PASS** (3 s, no warnings/errors), sidebar **564/564** (106 s),
Site Control **1471/1471** (81 s including lock queue time). The command recorded
load1 **17.98 → 11.20**, waited 10 s for a heavy slot, and completed in 200.298 s.
The editor instruction median was **134,821,383** against unchanged reference
**135,203,676**; native window list **5 → 5**, CPU p95 INFO **9.255 ms** at load1
**11.20**. All owned test processes and private roots were gone at the final audit.
Logs and summary: `.re/sidebar-flakes/signal-review-verify/`.

Initial foreground verification for `54b636bc`, `verified-1`…`verified-6` (real shared load;
no synthetic burners):

| Run | Editor median instructions | CPU p95 ms | Wall p95 ms | Load1 | Result |
|---|---:|---:|---:|---:|---|
| 1 | 144,209,011 | 13.374 | 14.888 | 19.56 | 1471/1471 PASS; renderer reaped |
| 2 | 144,169,435 | 10.983 | 12.800 | 30.52 | 1471/1471 PASS; renderer reaped |
| 3 | 144,738,612 | 14.213 | 16.421 | 22.37 | 1471/1471 PASS; renderer reaped |
| 4 | 144,747,754 | 16.770 | 18.063 | 23.71 | 1471/1471 PASS; renderer reaped |
| 5 | 144,454,806 | 18.684 | 20.127 | 15.73 | 1471/1471 PASS; renderer reaped |
| 6 | 145,503,985 | 17.520 | 21.647 | 14.54 | 1471/1471 PASS; renderer reaped |

All six final native suites passed on attempt 1; no interruption was needed in
this series. The foreground app/bundle, PID and load are retained per attempt.
The full-run receipts recorded real load1 from 16.38 at entry to 14.54 at the
last exit, peaking at a run boundary of 30.52. These are observed shared-machine
conditions, not controlled quiet runs. Instruction medians stayed below
155,696,984 while CPU p95 varied from 10.983 to 18.684 ms. Quiet `<12 ms`
acceptance remains with the parent as requested.

`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,settings-preview`
passed: build (no warnings/errors), sidebar **568/568**, features **288/288**,
settings **37/37** plus **216** render PNGs/dimension checks. Real load1 was
14.07 at entry and 8.25 at exit (`verified-7/`). No further flakes appeared in these targets.
Three earlier separate `sidebar-render check` runs also passed **568/568** each;
HP1 fired on its first attempt in 0.502 / 0.504 / 0.500 s, lateness +2 / +4 / +0 ms,
load1 7.94 / 7.41 / 10.18. SM4 and MC6 passed in all three. Main already contains
`1fe805a3` (PR #115); no sidebar timing code or baseline changed here.

Verification for `c3628d9e` used its historical **149,669,560** ceiling and the explicit
CPU INFO row. Both requested foreground runs of
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render`
passed **1471/1471**. The INFO rows do not change that acceptance count:

| Run | Editor median instructions | CPU p95 INFO ms | Lateness vs 12 ms | Load1 at INFO row | Result |
|---|---:|---:|---:|---:|---|
| 1 | 144,265,719 | 19.254 | +7.254 ms | 18.29 | 1471/1471 PASS; renderer reaped |
| 2 | 144,230,413 | 16.296 | +4.296 ms | 15.38 | 1471/1471 PASS; renderer reaped |

Run 1 recorded load1 18.02 at command entry and 18.29 at exit; run 2 recorded
16.78 and 14.55. Each complete CLI report has **2 INFO** entries: the existing
skeleton diagnostic and the new CPU-target row. The editor-only command has
**1 INFO** entry. Both native suites passed on attempt 1. Evidence:
`review-verify-1/`, `review-verify-2/`, `review-verification-results.json`.

The requested review command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render`
also passed: build **PASS** (no warnings/errors), sidebar **568/568** and features
**288/288**. It recorded load1 **14.55** at entry and **12.59** at exit, with
145.261 s total command time (`review-verify-3/`). No synthetic load was started.

Current final verification repeats the **same full gate command and procedure**
as the five reference recordings, after restoring the negative-proof source:

| Gate run | Reference | Measured median instructions | Delta from reference | CPU p95 INFO ms | Load1 | Result |
|---|---:|---:|---:|---:|---:|---|
| 1 | 135,203,676 | 135,164,914 | -0.029% | 11.054 | 11.14 | 1471/1471 PASS |
| 2 | 135,203,676 | 134,538,031 | -0.492% | 10.786 | 9.46 | 1471/1471 PASS |
| 3 | 135,203,676 | 134,613,556 | -0.436% | 8.770 | 7.93 | 1471/1471 PASS |

All three medians are within **0.50%** of the accepted reference. All three
started and ended with **5 → 5** native window entries; all twenty samples per
process and the procedure label are retained in `procedure-verification-results.json`
and `procedure-verify-1/`…`procedure-verify-3/`. Each renderer was reaped and each
private suite root removed. No synthetic CPU load was started. The CPU INFO
values are shared-load diagnostics; quiet-machine acceptance remains with the
lead before merge.

A real standalone `bench --group editor` invocation also passed **5/5** behavior
checks with **2 INFO** rows and **2 → 2** native window entries. Its instruction
row explicitly requires `sitecontrol-render check` for cost acceptance; it has
no instruction-budget PASS. This verifies the CLI cannot silently compare the
standalone procedure with the full gate reference (`procedure-standalone.log`).

Merged-main verification at `013cdb45` ran the full command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh`: **22/22 PASS**,
no FAIL or SKIP. Editor median **135,900,397** versus reference **135,203,676**
(**+0.515%**), CPU p95 11.314 ms at load1 17.19, native window list
**5 → 5**. The reference remains unchanged because the difference is below 2%.
The command waited 180 s for a heavy slot; total command time was 688.137 s.
Generated `docs/engine-spike/` files were restored before the merge commit.
Raw summary and logs: `.re/sidebar-flakes/merge-full-013cdb45/`.

Final merged-main verification includes `dee105e6` (items 9–10, PR #132) on top
of the tested `013cdb45` merge. The full command
`~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh` ran once on this
updated tree: **22/22 PASS**, no FAIL, INTERRUPTED or SKIP.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 59 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 13 |
| commands-dump | PASS | 1 |
| route | PASS | 0 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 78 |
| sidebar-render | PASS | 106 |
| sidebar-compare | PASS | 88 |
| commandbar-render | PASS | 15 |
| features-render | PASS | 42 |
| sitecontrol-render | PASS | 52 |
| boosts | PASS | 6 |

Editor median **135,491,848** versus reference **135,203,676**
(**+0.213%**), ceiling **148,724,044**. The native window list remained
**5 → 5**. No reference was re-recorded because the difference is below 2%.
CPU p95 INFO was **10.012 ms**, lateness versus 12 ms **-1.988 ms**, load1
**17.28**. The 12 ms target remains unchanged; lead quiet-machine acceptance
is still required before merge. The command recorded load1
**20.87 → 19.46**, waited 50 s for a heavy slot, and
completed in **521.831 s** including the wait.

The editor renderer was reaped, its private native-app root was removed, and
no owned Open/renderer process remained. `docs/engine-spike/` was restored to
the tested merge tree before the evidence commit. Raw summary and logs:
`.re/sidebar-flakes/merge-full-dee105e6/`; receipt:
`.re/sidebar-flakes/merge-dee-handoff-receipt.json`. No PR was opened.

Scope: `BoostEditorViews.swift` caches font pixels; `EditorBench.swift`, the new
`EditorOpenBench.swift`, `InstructionBaseline.swift` and `instruction-baselines.json`
own the editor cost gate. `main.swift` drains completed suites and is the sole
caller that enables editor cost acceptance; standalone bench is diagnostic only.
`EditorNativeKey.swift` owns the F25 activation barrier, wait/retry and
explicit suite-root contract; `EditorScenes.swift` establishes only the on-screen
parent activation/main/key precondition, and `EditorFlows.swift` closes the
competing offscreen parents before native launch. `tools/verification/check.py` owns lock ordering,
execution deadline, foreground-interruption propagation and child cleanup. No App/engine code, comparison assets,
sidebar timing logic, CPU-ms target, cold-open reference or SM6 reference changed.
Parent review lowers only the accepted editor reference to the optimized product.

| Review checklist | Result | Evidence |
|---|---|---|
| Input/memory limits | PASS | 128 fixed font images; bounded reference values/resource; absolute existing suite root capped at 4096 UTF-8 bytes; invalid-root CLI refuses input |
| Lifetimes/callbacks | PASS | Completed-suite and per-open pools keep the final native window list at 5 → 5 in five reference and three gate runs; native attempts and timeout cleanup release their owned processes |
| Real event paths | PASS / N/A | Existing real NSApp native key flow retained; no App key router or command path changed |
| Checks/proof/isolation | PASS | Old CPU gate red; real added native work red; real 180 s timeout/cleanup red as intended; two-window isolation guard red on old caller; unique suite root and UUID preferences |
| UI/motion | PASS | 28 exact font-card regions; full images within existing 2/255 tolerance; configured 0.120 s close unchanged |
| Docs | PASS | Full-gate reference, procedure mismatch evidence and original history recorded; quiet `<12 ms` lead acceptance remains open in followups |

Reproduction commands from the repo root:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
# Standalone diagnostic only, wholly offscreen; no instruction cost acceptance.
Packages/OpenKit/.build/release/sitecontrol-render bench --group editor
Packages/OpenKit/.build/release/sidebar-render check
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sidebar-render,features-render,settings-preview
```

The **lead must run the quiet-machine 12 ms acceptance check before merge**.
With other build/encode work idle and the load average recorded, run the same
full gate procedure from the repo root:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only sitecontrol-render
```

Read the `INFO` row `simple editor build/layout/first draw main-thread CPU p95
... vs 12 ms; lateness ...; load1 ...`. Quiet-machine acceptance requires CPU
p95 **<12 ms**; an instruction-gate PASS alone is not latency acceptance. The
lead records the value and actual load. This shared-machine task does not claim
that acceptance. The runner builds first, then serializes the native UI suite
with the on-screen lock. Standalone `bench --group editor` remains a timing
diagnostic and cannot replace the full procedure for acceptance or calibration.

Raw synthetic receipts, all 20 instruction samples per bench, build logs, phase
probes, binary SHA-256 and before/after render comparisons remain local under
`.re/sidebar-flakes/`. No Arc process, user data, desktop input, engine tree or
unit tests were used.

### SM6 structural and machine-specific cost gates

SM6 constructs the real 10-Space × 100-row Library and lays it out at 900×700,
scale 1, with three synchronous settle passes. It requires page builds to equal
built visible columns (1…4), exactly one full outline reload per built page,
zero incremental outline item updates during first layout, and model-matching
row counts. Existing scroll-builds-once and rename-no-reload checks remain.
Production diagnostics use plain main-actor integer increments without locks,
allocation or logging. AppKit layout callback counts remain unpinned.

The default `sidebar-render check` also runs `sm6-cost`: one discarded warm-up
process, then five fresh `sm6-measure --thread-instructions` processes. Each child
has isolated home/tmp/preferences, a 15-second timeout, a 65,536-byte output cap
and owned-PID cleanup. Known CPU-brand/macOS-build keys enforce
`median <= ceil(acceptedMedian × 1.10)` from the versioned resource
`sidebar-render/Resources/sm6-cost-baselines.json`. Fixture updates need lead
approval. Unknown keys report the measured count as INFO, never cost PASS.
Invalid or unavailable known-machine counters fail without fallback.

Only the harness binary resolves `thread_selfcounts` through `dlsym`; no App or
OpenKit library uses it. Wall time, lateness versus 120 ms, thread CPU, process
instructions, load and the wider thread census are diagnostics. Raw output and
cleanup state are retained in `SM6_JSON`. Instructions do not guarantee latency:
the 120 ms product budget is checked separately in a quiet M5 window. Helper
threads, draw/GPU completion and deferred work remain gaps; see
`docs/followups.md`.

Build before running:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only build
Packages/OpenKit/.build/release/sidebar-render sm6-measure --thread-instructions
Packages/OpenKit/.build/release/sidebar-render sm6-cost
python3 tools/sm6-proof.py --binary Packages/OpenKit/.build/release/sidebar-render \
  --out /tmp/sm6-cleanup-UNIQUE --load low --case early-failure --runs 1
```

`sm6-measure --fail-after-host` and `sm6-cost --fail-child-after-host` intentionally
fail and must clean all owned hosts/processes. Proof output directories must be
new. The proof tool bounds runs to 1…5, reaps only its recorded children and
records cleanup in `receipt.json`. Its `--load high` mode starts owned burners;
use it only for an explicitly authorized load proof. A full `--case check` run
also needs `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`, with no concurrent build.

M5 review r2 (section 1, 2026-10-27, M5 Pro / 26B5112a, built-in 2x panel as the
main display, load1 4.5–5.2). The sampler is stable: three `sm6-cost` runs gave
medians 680,241,245 / 680,144,454 / 683,041,525 (within-run range/median 0.6–0.8 %),
0.4–0.8 % above the accepted 677,429,195, so the accepted M5 fixture stands. Wall time
stayed diagnostic at 61.7–67.8 ms. Negative proof: one temporary O(n) pass in
`SpaceManagerView.layout` that sizes every row title once with the real system font
(1,000 rows) kept every structural check at 4 builds / 4 reloads / 0 item updates but
raised the median to 785,999,099 > 745,172,115, and `sm6-cost` exited 1. The source was
restored and the gate passed again at 680,827,395. `sm6-proof.py --case early-failure`
and `sm6-cost --fail-child-after-host` both reaped their children (`cleanup: True`,
hosts 0, visible 0).

## Logs and privacy

The default directory is `$TMPDIR/open-verify-<local timestamp>.<unique suffix>/`
(`/tmp` when TMPDIR is unset). The runner prints its absolute path at the end.
It contains a log per check, `openkit-usage.log`, `results.tsv`, `summary.txt`,
and available favicon/Boosts PNGs. Failed checks keep their output there.
`--keep-logs` additionally retains synthetic scratch files under `artifacts/`,
including the temporary npm installation. Ordinary runs remove scratch files.
Logs always remain, so the final path works with or without `--keep-logs`.

`--with-arc-data` is the only path that reads
`~/Library/Application Support/Arc/*.json`. The importer reads private copies.
Only allowlisted count/check lines reach the persistent log. Full importer output,
hosts, titles, source JSON copies, snapshots, and SQLite files are discarded when
the check ends, including on failure and with `--keep-logs`. No keychain, History,
Cookies, or browser profile databases are opened. Arc is never launched.

The Boosts check follows the temporary `puppeteer-core` approach used by
`.re/qa/shot.mjs`: it copies this repo's portable driver into its scratch directory,
runs `npm i puppeteer-core` there, and launches system Google Chrome with a fresh
headless profile. There is no repo npm dependency or lockfile. Both local servers
bind a dynamically assigned loopback port and stop in a `finally` block. Chrome
closes in the driver's `finally` block. The harness runs in the page world; this
check does not prove native session authority or the future isolated-world engine
adapter. The runner does not launch Open, drive the desktop, build Chromium, or
claim app/engine acceptance. [scripting.md](scripting.md) describes separate
App/AppleScript gates; no scripting CLI exists in this checkout.

## Verify the failure path

Use a disposable copy of the checkout and edit its copy of
`tools/verification/check.py` to point `cli` at a nonexistent absolute path. Run
`tools/verify-all.sh --only suggest-check`. The real package build must still
pass, then suggest-check must report FAIL with exit 1. Keep that edit outside the
working branch. A missing advertised command is SKIP; a missing executable at
execution time or a command with a wrong result is FAIL.

## Data-root and gate corrections, 2026-10-25

Verified `fix/dataroot-lock` against base `5de74ee` on macOS
(America/Vancouver). The initial release build used only
`nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`, in its own
process session: exit 0, zero warnings, zero errors, 75.93 s. No unit tests
were added. Host load was approximately 23–26 during the initial build.

The full run used `VERIFY_JOBS=6 tools/verify-all.sh --keep-logs`, with
`VERIFY_LOG_DIR` set to the receipt directory below. It exited 0 with
**13 PASS, 0 FAIL, 1 SKIP**. The runner's incremental release build also
reported zero warnings and zero errors.

| Name | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 15 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| sidebar-render | PASS | 13 |
| commandbar-render | SKIP: target absent | 0 |
| boosts | PASS | 4 |

Sidebar's real output was `checks: 81 passed, 0 failed`. The shared parser
now accepts this format, the existing N/N formats, and `N checks passed,
0 failed`. It still refuses zero/incomplete pass counts, nonzero failed
counts, and explicit failure lines. No `docs/commandbar.md` or commandbar
target exists in this checkout, so its future check uses that same parser;
no commandbar runtime result is claimed. `import-arc` was not selected
because this run did not opt in to personal Arc data.

Additional real CLI checks used fresh synthetic roots:

| Check | Result |
|---|---|
| `commands-demo` loop | 50/50 PASS, 103 checks each; zero lock failures |
| `sleep-demo` loop | 50/50 PASS, 105 checks each; zero lock failures; second-connection reload passed every time |
| Sleep loop thread CPU p95 | 0.612–1.872 ms across 50 runs; all below 2 ms |
| Sleep loop wall p95, informational | 0.979–6.776 ms across 50 runs |
| Same-root processes | Second process exits 1 in 0.131 s with a clear lock error while the first holds the kernel lock; first exits 0 after resuming |
| Same root through a symlink | Second process exits 1 in 0.122 s with the same lock error |
| Different-root processes | Both hold their locks concurrently and finish with exit 0 |
| Release before owner process exits | A completed Sleep scenario releases its root; a second CLI opens that root while the first process remains alive; both finish with exit 0 |

The full runner's Sleep result was 105/105. Its 200-pass CPU p50/p95/max was
0.257/0.413/0.669 ms; wall p50/p95/max was 0.260/0.562/2.797 ms. The workload
and 2 ms p95 budget remain unchanged; only thread CPU time gates acceptance.
The adblock lookup/profile-open p95 values were 0.1461/2.8964 ms, within
their unchanged 1/10 ms budgets. No check was retried.

Receipts, external CLI drivers, and synthetic artifacts:
`/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-dataroot-fix-dkc382ib`.
The full table and per-check logs are in its `verify-all/` directory;
`cli-results.json` and `release-result.json` record the extra lock checks.
See [model.md](model.md#data-root-lock) for token ownership and process-check
details. No Chromium build/sync, Arc launch, desktop automation, personal-data
read, or subagent ran. These CLI results do not close native app/engine gates.

Release `openkit` SHA-256:
`b10ff50c87fee7ba6f8d59f2c6fa8c839a1cbe5f4803d6f469ebd8cb2b9a1db8`.

# Toast and history-swipe idle work (Section 8)

`tools/verify-all.sh` runs this gate as part of `features-render`. To run it
alone after a Release harness build:

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh swift build --package-path Packages/OpenKit -c release -j 6 --product features-render
/usr/bin/lockf -k /tmp/open-m5-quiet.lock python3 tools/verification/features-idle.py
```

Use a separate session for long jobs. The helper compiles a temporary native
observer, loads it only into the harness, bounds the flow to 90 seconds, and
reaps its owned child on failure or interruption. It is never linked into Open.
The gate uses real window controllers, toast expiry/dismissal and history-swipe
events with the production clock. It covers both Reduce Motion paths. Each
2-second idle interval requires zero feature-owned live native timers, display
links, layer animations, draw/layout/display calls, invalidations and new work
scheduling. A native canary proves each observer works before feature sampling.
Missing observation support and tracking overflow fail closed.

The windows stay offscreen and the web host is synthetic. This gate makes no
whole-App idle CPU or frame-presentation claim. See
[the Section 8 report](s8-speed-gates.md) for the runtime observation boundary,
break-and-revert proofs, load averages and the pre-#153 A/B comparison. Keep
Section 2's existing command-bar budgets unchanged.

For the Section 8 milestone, the lead's final instruction defers full and targeted regression suites to one run on final main. This PR records the completed negative proofs and current-display before/after measurements; it does not claim a new full-suite PASS.

## Instruction calibration (lead ruling, 2026-11-08 09:30)

The SM6, Site Control cold-open and simple-editor instruction ceilings are
`ceil(main median × 1.10)`. Calibrate each from at least five unchanged-main
pairs at load1 ≤30. Each pair is two back-to-back release CLI runs. Build first
under the Section 16 `s16-heavy.sh` wrapper, without a quiet or screen lock.
Wait for load outside every lock. Hold the quiet lock only while measuring;
recheck load after acquisition and record start, end and peak load for each run.
SM6 takes one quiet hold per pair. The five-pair Site Control calibration uses
one quiet → screen hold, with no low-load wait inside that hold.
Keep each gate's existing measured span. Use CPU brand plus macOS build as the
fixture key, never hostname. Other machine/build references remain unchanged.

Re-baseline rule (lead, 2026-11-08 11:55): the current ceilings are keyed to
Apple M5 Pro / macOS 26B123. After a macOS update, or on a new machine, the key
changes and the gate fails with "unknown key". Then record a new key with the
same five-pair method from unchanged `origin/main`, in its own PR, and keep
every older key as it is.

This calibration uses unchanged `origin/main` at
`cdd147cac296ea4ea8a9da244299636aee28deb9`, Apple M5 Pro / `26B123`.
Five SM6 pairs ran first; five full Site Control pairs followed. A table sample
is one full CLI run's instruction median. The accepted count is the median of
the ten run medians (round the mean of the two middle values up to one
instruction). Then round the 10% ceiling up. No outlier removal is permitted.

`sidebar-render sm6-cost` is offscreen: `SM6Measure.swift` sets activation to
`.prohibited`; `OffscreenRenderer.host` creates a never-ordered host at
(-20000,-20000). It needs only the quiet lock. Full `sitecontrol-render check`
also needs the screen lock: `main.swift` calls `EditorFlows.run`, which calls
`EditorNativeKey.run`; that launches `EditorHarness.app`, sets regular
activation and calls `makeKeyAndOrderFront`. The standalone editor bench cannot
record an accepted cost reference (`EditorOpenBench.run`). Keep quiet → screen
for the full-check pairs and honor screen priority before acquisition.

SM6 keeps one discarded warm-up and five fresh measured child processes in
every run. All ten runs exited 0 and all 60 child reports confirmed cleanup.
The instruction baseline was unavailable for this new OS key during sampling;
its original INFO verdicts are retained in the raw receipts.

| SM6 pair | Run | Run median instructions | Load1 start | End | Peak |
|---|---|---:|---:|---:|---:|
| 1 | 1 | 671,256,097 | 12.496 | 12.496 | 12.496 |
| 1 | 2 | 670,719,279 | 12.496 | 12.496 | 12.496 |
| 2 | 1 | 670,496,615 | 12.496 | 11.976 | 12.496 |
| 2 | 2 | 670,580,802 | 11.976 | 11.976 | 11.976 |
| 3 | 1 | 671,603,177 | 11.976 | 11.497 | 11.976 |
| 3 | 2 | 671,256,210 | 11.497 | 11.497 | 11.497 |
| 4 | 1 | 670,797,129 | 11.497 | 11.497 | 11.497 |
| 4 | 2 | 670,248,900 | 11.497 | 11.938 | 11.938 |
| 5 | 1 | 670,494,664 | 11.938 | 11.938 | 11.938 |
| 5 | 2 | 670,627,361 | 11.938 | 11.702 | 11.938 |

SM6 accepted median: **670,673,320**. Ceiling: **737,740,652** instructions.

Raw command logs, every fresh-child report, binary hashes and per-run load
receipts are in `.re/budget-rulings/`. The versioned fixture retains the ten
run medians, all ten discarded warm-ups, source head and release binary hash.

Full `sitecontrol-render check` keeps five warm-ups and 30 measured cold opens
at process entry, followed by its pooled suites and the editor's five warm-ups
and 20 measured opens. All ten unchanged-main full checks exited 0. Every
private root was removed and no native helper remained after cleanup. All
loads below are observed load1; no run was excluded.

| Site Control pair | Run | Cold median instructions | Editor median instructions | Load1 start | End | Peak |
|---|---|---:|---:|---:|---:|---:|
| 1 | 1 | 92,494,287 | 133,851,524 | 13.967 | 20.187 | 20.657 |
| 1 | 2 | 93,335,648 | 133,230,208 | 20.187 | 19.731 | 23.325 |
| 2 | 1 | 92,542,494 | 133,113,330 | 19.731 | 16.403 | 19.810 |
| 2 | 2 | 92,541,418 | 132,926,967 | 16.403 | 16.932 | 18.145 |
| 3 | 1 | 92,502,418 | 133,260,271 | 16.932 | 17.431 | 18.426 |
| 3 | 2 | 92,470,901 | 133,588,461 | 17.431 | 20.821 | 21.763 |
| 4 | 1 | 92,570,936 | 133,149,444 | 20.821 | 22.128 | 29.266 |
| 4 | 2 | 92,561,231 | 133,301,521 | 22.128 | 17.339 | 22.128 |
| 5 | 1 | 92,462,013 | 133,143,982 | 17.339 | 17.994 | 21.171 |
| 5 | 2 | 92,526,458 | 133,185,919 | 17.994 | 13.331 | 17.994 |

| Gate, Apple M5 Pro / 26B123 | Accepted median | Ceiling, ceil(median ×1.10) |
|---|---:|---:|
| SM6 | 670,673,320 | 737,740,652 |
| Site Control cold open | 92,533,938 | 101,787,332 |
| Site Control simple editor | 133,208,064 | 146,528,871 |

The Site Control versioned fixture retains all ten run medians for both spans,
every run's start/end/peak load, source head and binary hash. Its existing
CPU-brand/macOS-build lookup and ceiling arithmetic are unchanged. The SM6
reader accepts the ten run medians and preserves legacy five-sample entries.

### Idle ruling report proof

The real `tools/budgets.sh --report` interface re-rendered the saved November 8
00:30 window receipt. This does not launch the App or repeat the idle window.
Static idle is **0.1230% PASS** against ≤0.5% (load1 5.917 → 4.562). Animated
idle is **3.5927% NO NUMERIC BUDGET** (load1 8.508 → 5.917). The report exits 1
with 69 PASS, 14 FAIL and 1 NO NUMERIC BUDGET: all other window budget misses
remain unchanged. Source receipt SHA-256:
`2b1c2decc6b0766e8ff1b895138880e86b0dd7a0b608819415c5e33e6ce53976`.

### SM6 gate proof

After installing the fixture and its ten-sample reader, the unchanged main
workload passes. A temporary loop inside `SM6Fixture.measure`, after native
first layout and before the counters stop, adds 16,000,000 dependent integer
iterations. It adds measured work; the fixture and comparator stay fixed.

| Control | Median instructions | Ceiling | CLI exit | Load1 start | End | Peak | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| Main workload | 675,180,953 | 737,740,652 | 0 | 29.723 | 28.063 | 29.723 | PASS (CLI prints OK) |
| Injected cost, first | 772,346,206 | 737,740,652 | 1 | 28.935 | 30.061 | 30.061 | Expected FAIL |
| Injected cost, confirmation | 767,593,738 | 737,740,652 | 1 | 25.674 | 25.674 | 25.674 | Expected FAIL |

The first negative proof peaked at 30.061; a second confirmation stayed at
25.674. Neither negative sample sets a reference. All three runs reaped their
children and removed their private roots. The temporary source change was
restored byte-for-byte; the rebuilt release binary is byte-identical to the
positive-proof binary. The real CLI also refused an eleven-sample private
fixture before starting a child; the valid ten-sample fixture passed above.

### Site Control gate proof

After installing the reference, the unchanged main workload passes both gates.
The temporary negative proof adds 2,500,000 dependent integer iterations inside
`Bench.run`'s cold-open measured span and 3,500,000 inside the editor's measured
span. Each loop retains a printed sink so the release compiler cannot remove
it. The fixture hash is identical in the positive and negative proofs; neither
the comparator nor reference changes.

| Control | Cold median instructions / ceiling | Editor median instructions / ceiling | CLI exit | Cold load1 | Editor load1 | Verdict |
|---|---:|---:|---:|---:|---:|---|
| Main workload | 92,464,623 / 101,787,332 | 133,200,352 / 146,528,871 | 0 | 10.57 | 10.86 | Both PASS |
| Injected cost | 109,649,251 / 101,787,332 | 157,985,592 / 146,528,871 | 1 | 22.25 | 45.41 | Both expected FAIL |

These are functional proofs at any load, under the screen lock, not calibration
or latency acceptance. Including the screen queue, the positive proof's load1
was 5.198 → 10.310 (peak 13.067); the negative proof was 36.883 → 44.658 (peak
46.940). The negative run has exactly two FAIL rows, both instruction gates.
Its CPU p95 values, 19.421 ms cold and 20.285 ms editor, remain diagnostic.
Both runs reaped the renderer, stopped all owned native helpers and removed
the private root. Both injected source files were restored byte-for-byte to
main. Final full verification rebuilds and runs the restored source.


## Quiet-machine budgets

Window 2 record (Section 16, 2026-11-09): 2026-11-08 23:45–2026-11-09
00:11, **main e8d4acd4, engine 619324d3, pre-#271**, load1 4.3–7.1.
Two misses remain without an owner fix: Site Control cold-open CPU p95
8.07 ms against <8 ms, and adblock profile-integrity scan p95 11.24 ms
against <10 ms (forwarded to Section 13). Source:
`.re/s16/window2/budgets.out`. Find first-open p95 25.2 ms was one outlier;
the 00:25 rerun on `518471aa` passed at p95 5.67 ms
(`.re/s16/window3/find.out`). The post-#271 static ten-page idle A/B had
median total CPU 0.21 % before and 0.42 % after, five runs per revision
(window 2 plus `.re/s16/window3/` receipts). These records do not clear the
remaining budget misses.

`tools/budgets.sh --out <receipt.json>` runs the existing performance
measurements against an already-built Release App and release OpenKit CLIs.
It prints one table: row, unchanged budget, measured value, samples, PASS/FAIL,
and load1 at the start and end of the workload. JSON retains all launch samples,
per-process idle CPU, process churn, cleanup and budget sources. Raw harness
logs remain in `<receipt.json>.logs/`. Use a new output name for each run.

Build before taking the quiet lock. Follow the current lead's engine and
heavy-slot rules. On the M5:

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main
OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release
~/Library/Caches/OpenRE/scripts/heavy.sh swift build -c release --package-path Packages/OpenKit
mkdir -p .re/e2e-tools
xcrun swiftc -O -swift-version 6 -parse-as-library tools/e2e/activate-own-app.swift -o .re/e2e-tools/activate-own-app
xcrun swiftc -O -swift-version 6 -parse-as-library tools/e2e/owned-window-count.swift -o .re/e2e-tools/owned-window-count
xcrun clang -dynamiclib -fblocks -fobjc-arc -Wno-deprecated-declarations tools/verification/feature-idle-probe.m -framework AppKit -framework QuartzCore -framework CoreVideo -o .re/e2e-tools/budgets-idle-probe.dylib
/usr/bin/lockf -k /tmp/open-m5-quiet.lock tools/budgets.sh --out .re/budgets/m5.json
```

`--app <path>` defaults to `build/Release/Open.app`. The App needs automation.
Missing CLIs or missing/stale automation helpers cause refusal with exact build
commands. The runner never builds. It refuses hardened-runtime Apps and Apps
mounted from images, per the Section 16 no-crash rule. Use the normal development
App from `tools/build.sh`, not a release artifact.

Use `--preflight --out <preflight.json>` to check the same App, release CLIs,
resource bundles, signatures and prepared helpers without launching the App or
any measurement CLI. It also computes every App socket path from the same
profile roots the workloads use, including the resolved `/private/tmp` path.
It refuses any path over 100 encoded bytes, below macOS's 104-byte `sun_path`
limit. JSON records the paths, the longest path, `mode: preflight`,
`preflight: PASS`, empty measurement rows and executable hashes. This is
preparation evidence only.

`--report <saved.json> --out <new.json>` renders the saved worker receipts with
the current reporting rules and launches nothing. It preserves the original
values, sample counts, loads, guard settings, executable hashes and source
provenance. The original receipt stays unchanged. The derived JSON records its
source receipt hash and the reporter hash. This mode can update a report label
without repeating a measurement.

For a lead-granted stopped-machine window, add `--quiet-start`. It refuses
immediately if load1 exceeds `--max-load N` (default 4) or an Open/App helper,
release CLI, `xcodebuild` or `siso` process exists. The table header and JSON
record the chosen ceiling and whether the guard is enabled. A lead-approved
window can use `--quiet-start --max-load 12` per TANDEM 4a. This operator guard
does not change product budgets. It never waits for load. The default whole-run deadline
is 2,220 seconds (37 minutes), with up to three minutes reserved for cleanup.
`--max-seconds` can set a shorter deadline. An expired deadline leaves an
incomplete FAIL receipt; it does not accept or silently omit remaining rows.

The caller owns the quiet lock. The runner takes only the on-screen lock, once
per App/native-window workload. It checks `/tmp/open-onscreen-priority` before
each hold. It never waits for low load. A loaded-machine failure stays FAIL,
with its loads. Only a lead-arranged quiet M5 run establishes quiet-machine
acceptance. Follow current screen holds; the command does not clear them.

Workloads use a private, short `/tmp/ob.*` root for profiles, home and temporary
data. This root does not depend on `--out` or the caller's `TMPDIR`. Logs and
receipts remain beside `--out`. Each worker removes its data after owned process
cleanup; the parent removes the run root in `finally`, including preflight.
App workloads use the existing LaunchServices/socket harness. The keys used by
these flows are reset before launch and restored with
their original plist types in `finally`. Each worker reaps owned processes
before releasing its screen hold. It removes disposable profiles, home and
temporary data. A launch, crash or cleanup error stops the run before more
screen work. Tell the lead before any further launch.

Budget inventory (the Python source cites each numeric limit):

First-run definition after Section 17 (#267/#270, 2026-11-09): keep both
numeric budgets and both clocks. Five fresh Release automation profiles measure
kernel process start → `sidebarDrawn` (median ≤250 ms). `App/main.swift` records
that mark only after `FirstWindowFrameObserver` confirms the first frame of
`AppDelegate.firstContentView`. That view is now the initial Intro composition,
before its animation completes. Capture its timing and onboarding state before
using the same `skip-intro` → `get-started` actions as the `firstrun` e2e factory
to reach Name (the shared first-run model's `welcome` step). Do not restart the
clock at Continue, include the intro's duration, or substitute the later Name
frame. Use `--intro-sound=silent`: the real player prepares at volume zero.

Imported paint stays `firstContentfulPaint - firstRunLandingStarted` (median
≤700 ms), using the existing renderer Performance-clock mapping and synthetic
import with deterministic local saved pages. `showFirstRunBrowser` marks the
landing checkpoint and prepares the selected imported page during import.
Capture that page's identity and FCP before final setup inserts/selects native
`open://welcome`, which has no renderer FCP. Then complete the real setup and
verify the native Welcome tab. No new timer, mock import, bypass flag, page
reselection or navigation is used. Receipts retain per-sample loads, both clocks,
the initial Intro state, Name/Welcome state, imported tab and final completion.
The report reader still accepts the older `welcome` timing field.

**Meaning for lead review:** the first-frame span is unchanged, but its surface
changed from the old native Welcome panel to Intro. The imported renderer FCP
still measures preparation from the same landing mark; Section 17 now keeps
that prepared browser at alpha zero until final hand-off. It does not measure
the later native Welcome reveal, the 2.5-second dim fade, or physical visibility
of the imported page. These distinctions follow the first-run plan's Section 17
errata and `docs/onboarding.md` / `docs/welcome.md`; quiet acceptance remains
separate from a loaded functional run. The runner resets/restores the onboarding
name and sound preference along with its existing App defaults. It never writes
an Apple defaults domain.

Functional receipt (2026-11-09, M5, automation App at main `518471aa`, runner
`b1b21881`): `tools/budgets.sh --only first-run --app build/Release/Open.app
--max-seconds 600 --out /tmp/s16-fr-20261109.json`. No quiet lock or load guard.
All five fresh profiles reached Intro, Name/Welcome, the imported local page and
final native Welcome. Every Intro reported sound reason `silent`. All five App
cleanups passed with zero remaining windows/processes; defaults and private roots
were restored/removed. This proves the flow, not quiet timing acceptance.

| Row | Budget | Median | p95 | Samples | Result | Load1 start → end |
|---|---|---|---|---|---|---|
| First content | ≤250 ms | 486 ms | 3119 ms | 5 | FAIL | 5.50 → 6.11 |
| Imported paint | ≤700 ms | 194 ms | 232 ms | 5 | PASS | 5.50 → 6.11 |

First-content samples: 3119, 432, 486, 568, 412 ms. Imported-paint samples:
232, 194, 204, 177, 160 ms. Keep the first-content miss; the thresholds and
process-start clock are unchanged.

| Workload | Existing measurement and limits |
|---|---|
| Existing-profile launch | `engine_e2e.py` `warm_existing_profile`, extracted from S16 `run_launch.py`: seven launches; sidebar median ≤250 ms, first paint median ≤700 ms. Also main ≤50 ms and modelLoaded ≤120 ms intermediate marks from the app-shell plan. Kernel process birth and a confirmed sidebar frame are required. Process-cold, warm file caches. |
| First run | `firstrun.py` F12 and the saved Release-timing procedure: five fresh first-run roots, median first confirmed Intro content frame ≤250 ms, selected imported-tab renderer FCP from `firstRunLandingStarted` ≤700 ms. Intro skip/handoff uses the real onboarding actions with silent playback; capture imported paint before native Welcome replaces the selection. See the definition and review note above. |
| Idle, animated and static | S16 `run_idle.py` and `process_cpu_window`: Section 8's ordered ten-page set, Python selected last; second row replaces that page with a deterministic local static page. Each settles 90 s, then samples 60 s without polling or tracing. JSON retains Mach/ps counters, per-process/per-kind splits and churn. Lead ruling, 2026-11-08 09:30: static total CPU ≤0.5%; always print and retain its measured value. The animated row has no numeric ceiling and shows `NO NUMERIC BUDGET` with measured CPU. Missing data or failed cleanup still fails in either row. See `docs/architecture.md` performance budgets. |
| Site Control | Full `sitecontrol-render check`: cold-open CPU p95 <8 ms; simple-editor CPU p95 <12 ms using the required full-check procedure; both instruction gates; idle <10 ms CPU/2 s; ten-page refresh <100 ms; pad CPU p95 <2 ms; off-main hue <15 ms; ≤61 previews/120 inputs; code highlight CPU p95 <2 ms. Unknown instruction baselines fail closed. |
| SM6 and mini-player | `sidebar-render check`: one declared warm-up and five fresh processes, accepted instruction ceiling, first-layout wall median ≤120 ms, structural gates, MC8 paused idle CPU ≤0.5%. |
| Command bar keystrokes | `commandbar-render check` (#132/#135/#136, now 150/151): CPU p95 <8 ms, completion added p95 ≤0.3 ms, ≤1 panel layout pass. Retains the full combined gate. |
| Live tab switch | `split-app-speed.py` fixture and `split op=bench`: 40 samples each for root single→single and single→split, p95 ≤16 ms. Native layout/CA flush and every-pane first rAF combine by max. Physical presentation is unproved. The separate paired-main 25 ms allowance does not replace 16 ms. |
| Sidebar | `sidebar-render bench --rows 1000`: scroll and model drag/move p95 ≤8.33 ms. Existing selection toggle p95 ≤1 ms; 50-row bulk move/archive/folder/Space p95 ≤16 ms; Expand All p95 ≤16 ms. |
| Folder Peek | Existing 50-folder/1,000-row FP10: all three declared attempts, transition p95 ≤2 ms, the open median goal <1 ms, scroll p95 ≤8.33 ms and matched plain ×1.10 +0.05 ms. Standalone invocation uses the strict 2 ms limit without building a pinned parent or taking its exception. Raw native row-layout comparisons remain in the harness verdict. |
| Suggestions | `openkit suggest-check`: #31 stream <600 ms with its existing up-to-three attempts, all retained; extension actions p95 <0.2 ms; first/inline snapshots CPU p95 <5 ms; completion check p95 ≤0.05 ms. |
| Ad blocking | `openkit adblock perf`: 1,000 lookups p95 <1 ms and profile-open integrity scan p95 <10 ms, ten groups each. Combined time is informational. |
| Cold command bar | Existing `app-actions` first-open key route and `openFirstResultsMs`: ≤50 ms, entry to first snapshot applied; excludes frame presentation. |
| Find | `find_checks.py` F04 native-key timing: first and repeat open p95 ≤1000/120 ms, twenty fresh windows, lazy creation and visible pane proof. This uses the built-in presentation marks and does not build the separate idle observer. |
| Theme editor | `space-editor-render check`: B1 two-window CPU p95 ≤4 ms/240 ticks; cold texture tile <500 ms and field composition <250 ms. |
| Feature harnesses | `features-render check`: PiP idle CPU ≤0.5%; `favicon-check`: 1,000-row stored-icon scroll p95 ≤8.33 ms; S8 observer: zero owned resources/events in ten two-second toast/swipe windows across both motion modes. The observer is built before the run. |

Each reused CLI has a harness-exit row. A functional failure or interrupted
native suite stays visible when timing passes. Missing metrics fail. The runner
does not retry workloads. Existing internal FP10 and suggest attempts remain;
raw results are retained and each FP10 attempt is shown separately.

Other values in the named docs are diagnostics or two-build comparisons:
memory has no budget; ad-block combined time, sleep-pass CPU, engine startup
marks and editor full-drag wall time have no separate limits. The S8 sidebar
±10% comparison, MC9 media-versus-parent mean delta and paired-main regressions
need a reference build and remain separate comparison procedures. First-run
and imported-content timings use their own fixture, apart from the required
existing-profile launch.

To prove failure detection, copy the cold-command-open limit to 1 ms for one
real run. Product thresholds and files do not change:

```sh
/usr/bin/lockf -k /tmp/open-m5-quiet.lock tools/budgets.sh --only command-open --fail-demo --out .re/budgets/fail-demo.json
```

The row is labelled `FAIL DEMO`. A budget or harness failure exits 1. A complete
run exits 0 when all numeric gates pass; `NO NUMERIC BUDGET` rows do not assert
acceptance and do not cause failure. `--only <workload>` is for diagnosis and marks JSON `partial`.
Default invocation runs the complete inventory once. No unit tests, desktop
input, cache purge, threshold edits or engine-tree builds are involved.

A subset on the M1 can prove the command flow after the lead clears its screen
hold. Label it M1 smoke; its timings do not establish the M5 budgets.

# Renderer recovery without a system crash report (Section 16)

The `features` suite's `crash_recovery` row terminates a real renderer with
`chrome://kill`. It checks Open's killed crash state (`2`) and the sidebar
model's crashed flag. It then navigates the same tab back to `example.com`,
checks crash state `0`, the cleared model flag, and the loaded page title.
It also checks that another tab still runs JavaScript and that Open keeps
the same PID. The tab closes in `finally`.

The old row used `chrome://crash`. It checked a nonzero engine crash state,
the model's crashed flag, and recovery to state `0` at the expected URL
after navigation. It did not assert visible sad-tab pixels, the reload
command, the model flag after recovery, or another tab's survival. Those
visual and reload-command claims remain outside this row's evidence.
The existing `OPEN_E2E_NO_CRASH_PROBES=1` opt-out remains unchanged.

Source evidence (strictly read-only, no engine build or change):

- In `~/Developer/open-engine-s8/chromium_git/chromium/src/`,
  `third_party/blink/common/chrome_debug_urls.cc:160-192` handles both URLs.
  `chrome://crash` calls `CrashIntentionally`; `chrome://kill` sends the
  renderer itself `SIGTERM` on POSIX, including macOS.
- `third_party/blink/common/crash_helpers.cc:13-23` implements the null
  pointer write. `base/process/kill_posix.cc:40-63` classifies `SIGTERM`
  and `SIGKILL` as `TERMINATION_STATUS_PROCESS_WAS_KILLED`.
- `cef/libcef/browser/browser_contents_delegate.cc:427-450` converts that
  result to `TS_PROCESS_WAS_KILLED` and calls `OnRenderProcessTerminated`.
- In this repo, `Engine/OpenEngine/src/OEClient.mm:666-678` maps that
  callback to `OEWebContentCrashStateKilled`. Its value is `2` in
  `Engine/OpenEngine/include/OpenEngine/OEWebContent.h:70-75`.
  `App/WebContent/EngineWebContentHost.swift:42-45` maps every nonzero crash
  state to the model's `isCrashed` flag.

An automation `SIGKILL` command would need renderer PID discovery or a new
engine hook. The existing debug URL reaches the same killed state with no
new App API. `~/Developer/open-engine-s8-main/README.txt` confirms that the
permitted main engine view contains a recorded distribution, not source;
the source reads above used the separately authorized Section 12 tree.

Negative evidence, M1, 2026-11-07: the exact old row ran once from WIP
`6eac2d72`, through the real App and its automation socket. It passed with
crash state `1`, model crashed `true`, and recovery state `0`. macOS wrote
`Open Helper (Renderer)-2026-11-07-162618.ips`, with process name
`Open Helper (Renderer)`, exception `EXC_BAD_ACCESS`, signal `SIGSEGV`, and
address zero. A null-checked Swift `CGWindowListCopyWindowInfo` probe counted
windows owned by UserNotificationCenter, ReportCrash, Problem Reporter,
and CrashReporter names. The before/peak/after counts were `0/0/0`, through
60.1 seconds after App exit. No dialog was observed in that interval; the
system report is the negative evidence that requires avoiding this fault.
Load averages before/after were `4.75/7.15/8.86` and `3.94/6.60/8.53`.

The negative run used the old row body extracted from its source, without
edits or mocks, inside the normal real-App suite launcher. Its observer
would terminate the owned suite on a new report or reporter window and
never replay it. The report arrived after the suite had exited cleanly.
The complete `features` suite is the positive validation command.
Raw receipts and the temporary observer live in the shared project's
`.re/s16/crash-row-dialog/`; they contain no copied Arc code or assets.

Positive evidence, M1, code commit `b2a64381`: the full command
`python3 -I tools/e2e/engine_e2e.py --only features --keep` passed all
19 rows, without an interrupted attempt. Its source receipt is clean.

| Proof | Observed result |
|---|---|
| Real renderer termination reaches Open | killed crash state `2`, model crashed `true` |
| Same tab recovers by navigation | state `0`, model recovered `true`, URL `https://example.com/`, title `Example Domain` |
| Another tab remains live | JavaScript title unchanged, model not crashed |
| Open remains alive | same App PID before and after termination |
| No system crash UI or report | reporter windows before/peak/after `0/0/0`; no new `.ips`, through 60.3 seconds after App exit |
| Owned cleanup | graceful quit, no forced cleanup, no remaining processes, zero owned windows |

Loads before/after the positive observation were `2.37/4.19/6.19` and
`3.46/4.03/5.82`. Both Debug builds passed: baseline start/end loads were
`4.11/6.86/9.36` and `10.59/10.13/10.19`; merged App start/end loads were
`3.65/6.17/8.09` and `7.52/6.11/7.32`. The new exact state-`2` requirement
rejects the old row's observed state `1`; no fault was replayed for this
negative proof. All listed results are functional M1 evidence.

This change touches only the e2e harness and this document.
`grep -n engine_e2e tools/verify-all.sh` returns no matches. The task's
harness-only exception therefore omits the full M5 `verify-all` gate.
Every App build ran through the M1's `heavy.sh`, and each on-screen run
held its `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`. No crash probe ran
on the M5. No CrashReporter, ReportCrash, launchctl, or system setting changed.
