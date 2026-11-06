# Split View in the App

Base audit: `main` at `7254c0a3`, 2026-11-05. The table distinguishes source wiring from real-App acceptance. The base had the offscreen S1–S6 checks and a two-page `shell` smoke check; it had no `split` suite. Source references below refer to that exact base.

| Item | Real-App status on main | Base evidence |
|---|---|---|
| C1 Ctrl+Shift+= | Wired to an empty pane; no dedicated App acceptance row | `App/MainMenu.swift:39`; `OpenFeatures/SplitViewController.swift:55,89`; `BrowserWindowController.swift:904` |
| C2 sidebar tab → page edge | Live container is a dragging destination; only handler-level offscreen proof | `OpenFeatures/WebContentContainer.swift:371,376`; `SplitViewController.swift:128` |
| C3 tab → pane to combine | Live destination computes an insertion index; no native-session proof | `WebContentContainer.swift:376`; `SplitViewController.swift:128` |
| C4 sidebar context menu | Wired to OpenFeatures; no dedicated split suite | `SplitViewController.swift:64`; `BrowserWindowController.swift:985` |
| C5 command bar / plus menu | Command registry and sidebar intent exist; plus menu incorrectly remains enabled for no tab, Favorites and four panes | `OpenCommands/CommandRegistry.swift` `add-split-view`; `OpenSidebar/SidebarMenus.swift:288`; `BrowserWindowController.swift:980` |
| Focus panes 1–4 | OpenFeatures owns dispatch; only keys 1–2 were available in the automation key map | `BrowserWindowController.swift:904`; `SplitViewController.swift:89`; `App/Automation/AutomationController.swift` `sendKey` |
| Next / previous pane | Wired, wraps; brace keys missing from the automation key map | `SplitViewController.swift:99`; `OpenCommands/CommandRegistry.swift:412` |
| Close focused pane | Wired; minus key missing from automation | `SplitViewController.swift:75,94` |
| Expand, restore, Esc | Transient maximized state exists, Esc handled before key routing; no App split receipt | `SplitViewController.swift:96`; `BrowserWindowController.swift:856` |
| Separate focused pane | Wired; collapsed split retains the model's surviving selection | `SplitViewController.swift:75–86,95`; `OpenModel/BrowserModel.swift:2039` |
| Separate All | Pane and sidebar menus both call unsplit | `SplitViewController.swift:117`; `OpenSidebar/SidebarMenus.swift:187` |
| Flip orientation | Both menus call the model; keeps focus/fractions | `SplitViewController.swift:109`; `OpenSidebar/SidebarMenus.swift:180`; `BrowserModel.swift:1991` |
| Add Tab… through four panes | Sidebar and pane menus exist and disable at four | `OpenSidebar/SidebarMenus.swift:188`; `SplitViewController.swift:54,108` |
| Divider drag + fraction save | Native mouse methods update live frames; commit fractions on release | `SplitDividerView.swift:17–25`; `WebContentContainer.swift:322,365`; `BrowserModel.swift:1981` |
| Pane ring + sidebar focus reflection | Ring and URL follow focus. Sidebar retains one selected row; cells intentionally have equal fills | `WebContentContainer.swift:310,313`; `OpenSidebar/SidebarRows.swift:850–854`; measured `re/interaction-states.md` §7, F0081 |
| Focused close / 2→1 collapse | Model retargets selection to survivor; App code preserves it | `SplitViewController.swift:75–86`; `BrowserModel.swift:2039` |
| Relaunch: orientation, fractions, focus, ≥3 | Persisted in SplitDTO; no dedicated real-App ≥3-pane proof | `OpenStore/SnapshotDTOs.swift:134`; `features-render` S6 |
| Four horizontal / vertical panes | Shared layout handles 1–4; offscreen evidence only | `SplitLayout.swift:8–43`; `WebContentContainer.swift:336` |
| Narrow content below 800 pt | Equal below-minimum sizing already exists; no real-window resize proof | `SplitLayout.swift:19–20` |
| Two and four real pages | `shell` proves two live pages; four unproved | `tools/e2e/engine_e2e.py:1038–1044`; `WebContentContainer.swift:177–184` |
| Idle / switch / sidebar speed | No split-specific App gates | `architecture.md` ≤16 ms live-tab budget; `s8-speed-gates.md` observer precedent |

Paths without a prefix in the evidence column are under `Packages/OpenKit/Sources/` beside their named module. These findings use Open source only; they add no reverse-engineering claims.

The measured sidebar specification supersedes the old plan's focus-cell guess. F0081 has equal cell fills and no separate focused-cell mark (`docs/re/interaction-states.md` §7). The suite checks the selected split row, focused pane ring and sidebar URL. No visual metric changes. The focus-ring motion fix below removes an extra animation introduced by view reuse.

The new drag checks exercise the real `WebContentContainer` destination callbacks with an `NSDraggingInfo` object and a unique pasteboard containing `com.open.sidebar.node`. `SplitDropOverlayView` is the drawing child, not the registered destination. The virtual pointer does not supply the WindowServer drag loop consumed synchronously by `NSOutlineView.mouseDown`. This is the permitted destination-callback fallback; it does not prove a real `NSDraggingSession` or an external drag.

Raw process logs and PNGs stay in `.re/s9-split/`; synthetic timing samples are committed in `split-app-timings.json`. The final results below distinguish App acceptance from the older offscreen checks.

## Verification scope

The real App suite uses fresh data/cache roots, local HTTP pages and the automation socket. It saves and resets `open.advanced.showFullURLWithToolbar`, then restores the exact persistent value in `finally`, including after relaunch. Keys use `key route=app`. Divider events use the in-App pointer. Option-click uses native event dequeue so `NSApp.currentEvent` carries the flags. No desktop input is sent.

Split IDs remain on OpenFeatures. The plus menu now disables Split for an empty selection, a Favorite and the four-pane cap. Pane chrome stays with cached hosts, with a separate fixed cap of eight parked views. Close, profile teardown and host transfer release the matching view. Repeated placeholder/chrome refreshes and unchanged display assignments are removed. Geometry, colors and motion tokens stay measured values. Equal child frames are skipped only when their window-relative rectangle also stays equal; moving a cached pane still updates OpenEngine’s Chrome child window. The OpenEngine view’s frame setters call geometry synchronization even for equal values (`OEWebContent.mm:183–190,685–687`).

The idle observer runs only inside the suite-owned first App. It starts before pane creation, attributes schedulers to split/container call sites, then watches the live view/layer tree after divider release. Five seconds require zero layout/draw/invalidation/scheduling events, live split-owned timers/display links and CA animation keys. Other framework/engine display links are reported separately; no nonzero split baseline is allowed. The socket sends no polling requests during the interval. This measures split-owned work, not whole-App CPU. The relaunched App used for latency has no idle observer.

## Section 9 decision: split gate endpoint

Approved in this task on 2026-11-05, subject to the main comparison and negative proof below. The old endpoint waited for a JavaScript query to return after the renderer was already visible. Its retained branch single/split p95 values are **14.277/18.992 ms**, labelled **old endpoint, diagnostic only** (`switch-ack-overhead.json`).

The new endpoint is the maximum of native selection/layout through the existing `CATransaction.flush()` return and the first `requestAnimationFrame` timestamp after a fresh `visibilitychange` in **every** shown pane. The last pane wins. The renderer timestamp uses `performance.timeOrigin`; the probe checks its epoch against native time. The 16 ms p95 **target remains NOT MET consistently**; an earlier valid 7b490905-engine quiet run reached 17.710 ms at load1 10.09. The historical budget-decision fixture is labelled separately below. The approved gate is branch p95 ≤ interleaved main p95 + 1 ms, with an absolute 25 ms ceiling, on both single→single and single→split paths. Physical presentation is out of scope. This is the approved renderer frame endpoint, not a screenshot/monitor measurement. See [High Resolution Time](https://www.w3.org/TR/hr-time-3/) and [page visibility](https://html.spec.whatwg.org/multipage/interaction.html#page-visibility).

The native endpoint does not add an explicit CA transaction or a completion block. A diagnostic observer did so and waited for animations: main single/split p95 **233.392/242.181 ms**, branch **266.130/270.870 ms**, across three interleaved pairs. Those rejected samples stay in `app-paired-animation-end.json`. Apple's [completion-block documentation](https://developer.apple.com/documentation/quartzcore/catransaction/setcompletionblock%28_%3A%29) defines that callback as animation completion. The diagnostic motion probe compares ordinary selections with this added transaction and records layer keys/durations to explain the extra time; it does not count as root-tab selection acceptance.

`tools/verification/split-app-speed.py` interleaves main, branch, main, branch, main, branch under one quiet/on-screen session. Each process has fresh data and 40 samples per path. Every sample and query-return diagnostic is retained. The branch must meet the relative main + 1 ms gate and absolute 25 ms ceiling on both paths. The standalone `split` row enforces the ceiling and reports the 16 ms target; the separate interleaved tool enforces the relative gate. Main is an archive of `ffcf4649` with only the identical benchmark observer and one automation dispatch hook; its production selection, container and chrome sources match the commit byte for byte (`timing-main-manifest.json`). Both locks use `lockf -k`. The quiet lock is acquired before the on-screen lock, using the priority flag while waiting. Before launching a timing receipt, the runner waits for load1 ≤12; no measured sample is discarded.

The first `ebcf08d2` comparison failed the nominal single relative gate: main/branch p95 19.151/20.448 ms (split 29.083/24.743 ms). Its three-tab setup selected a split pane ID as the single target. That showed one page but was not a selectable root single row. All earlier paired results are therefore diagnostic for that fixture, including the historical budget-decision numbers. The final comparison uses four tabs: two root singles disjoint from a separate two-pane split, asserted through the actual sidebar tree. All earlier samples remain labelled superseded; no threshold changes.

## Motion investigation

The 30 ms difference in that diagnostic workload came from cache reuse. The invalid single target changed a cached pane between single and split roles, which exposed extra implicit ring motion. The same frame-assignment fix protects normal pane relayouts too. Every one of the three interleaved pairs showed the same result, both during ordinary selection and with the diagnostic transaction wrapper:

| Layer/property | Unchanged main | Branch before fix |
|---|---|---|
| Slot bounds/position | 0.22 s | 0.22 s |
| Focus ring bounds/position | No independent animation | 0.25 s |

Reused `PaneSlotView` layers already have geometry. Assigning the ring's new frame added default CA `bounds` and `position` animations. Fresh main layers did not add those animations. The fix disables implicit CA actions only while assigning the ring frame. The ring follows the slot's existing layout; the slot keeps `Motion.splitExpand` at 0.22 s. No measured color, frame or motion token changes. `pane_motion_no_extra_ring_animation` checks the real native animation records, including the diagnostic wrapped case. A separate negative proof adds a real 0.25-second ring geometry animation and requires the new motion gate to fail.

Before this fix, the older diagnostic comparison used the every-pane rAF endpoint but the superseded pane-ID fixture: main single/split p95 14.606/24.265 ms; branch 16.084/20.249 ms. These remain `app-paired-ring-before.json`, with all samples and per-run loads. The corrected root-row comparison below proves the approved relative/25 ms gate and absence of independent ring animations. The 16 ms target is tracked separately in `docs/followups.md`.

## Sidebar speed

The unchanged 1,000-row native sidebar workload runs from base and branch binaries in three paired runs, AB/BA/AB, under the quiet lock. It compares the median of each revision's three p95 values with ±10%, retaining every run.

| Receipt | Main p95 ms | Branch p95 ms | Median change | Load range (1/5/15) | Result |
|---|---|---|---|---|---|
| Initial | 4.12/5.20/3.01 | 4.32/3.34/5.89 | 4.12→4.32, +4.85% | 10.96–11.59 / 11.72–11.86 / 11.28–11.33 | PASS |
| Final, persistent quiet lock and literal uptime | 1.35/1.32/1.32 | 1.32/1.51/1.30 | 1.32→1.32, +0.00% | 7.22–7.76 / 7.46–7.57 / 8.50–8.53 | raw gate PASS; machine-noise ruling retained |

Raw receipts are `sidebar-speed.json` and `sidebar-final.json`. No sidebar rendering work is added.

Lead ruling (2026-11-05 23:48 Vancouver): **machine noise, not a branch regression**. The unchanged ±10% gate is retained. The two identical-main controls measured 2.75→3.77 ms (+37.09%, load ranges 7.32–7.91 / 8.63–8.79 / 12.44–12.54) and 2.30→1.64 ms (−28.70%, load ranges 7.48–8.08 / 11.22–11.28 / 13.12–13.13). The earlier actual branch comparison was 2.65→3.64 ms (+37.36%). All control samples and loads remain in the artifact. The current same-main-binary control is 1.61→1.34 ms (-16.77%), raw FAIL; the current branch comparison is 1.32→1.32 ms (+0.00%), raw PASS. No threshold, sample-selection rule or benchmark code was tuned.

## Negative proofs

Fault edits target the real App or real native sidebar workload. They are reverted before clean builds. No threshold, baseline or allowlist changes.

| Gate | Deliberate fault | Observed rejection |
|---|---|---|
| Idle after divider release | Split-owned repeating timers, live CA links and layout invalidation | 200 layouts, 100 invalidations, 3 live timers and 3 owned CA links after 5.025 s; FAIL. Load 5.12/12.91/16.19. |
| Approved every-pane rAF / 25 ms ceiling | 25 ms extra synchronous production work | Single/split p95 41.329/41.149 ms; FAIL. Load 10.53/12.97/14.78; cleanup PASS. |
| No extra ring motion | Explicit 0.25 s ring bounds animation in production layout | Six unexpected ring animations; FAIL. Load 8.64/12.47/14.00; cleanup PASS. |
| Original tab-switch gate | 25 ms extra synchronous production work | Single/split p95 69.947/73.420 ms; FAIL. Load 5.10/12.27/15.87. The approved rAF/25 ms proof is listed above. |
| Sidebar scroll ±10% | 10 ms extra in the real TabCellView layout | Median paired p95 3.46→51.58 ms, +1390.75%; FAIL. Load 9.02–10.32 / 9.75–9.96 / 10.47–10.51. Source and clean main binary restored. |
| Ring PNG | Hide the real focused ring | Expected focus comes from the model; focused-ring pixel ΔE00 about 57 against ≤2; FAIL. |
| Pane commands/geometry | Remove focus update, ignore maximize, distort divider/narrow frames, remove slot cap, enable invalid plus states | Focus, maximize, both divider, narrow-frame, cache-bound and three plus-enable rows FAIL. |

The combined Chrome negative run rejects 12 rows and cleanup passes (`negative-v2.json`). Prompt-interrupted attempts and the server-restart-killed attempt are excluded and retained separately. The five-second idle interval uses only in-App probes. The historical native trace was captured before rule 4b; no prohibited process inspector is invoked by this work now.

## Limits and diagnostic receipts

No new product guess is introduced. The measured equal sidebar cell fills remain unchanged. Divider keyboard resizing stays skipped as plan §3.4 permits. Existing unresolved visual choices remain reported to the lead: orientation-only changes have no explicit 0.22-second frame animation; removed slots have no separate 0.14-second fade. The existing narrow-bar fallback guess can overlap fixed focused controls below roughly 220 pt. Narrow-window acceptance proves page frames and equal scaling, not redesigned bar metrics.

Earlier instrumented latency runs accidentally re-injected a startup-armed idle observer on relaunch. Their numbers are diagnostic, not normal latency (`split-release-queued.json`, `split-layout.json`). Uninstrumented old-query retries and loads remain `switch-warm-redundancy.json`, `switch-warm-ui.json`, `switch-ack-overhead.json`. The visibility-only clock experiment (`clock-control.json`) is superseded by the approved every-pane rAF endpoint and does not count toward the three accepted runs. The intrusive CA animation-end experiment is retained above. Raw traces, logs and PNGs stay in `.re/s9-split/`.

## Final interleaved receipt (1× display)

Main is `ffcf4649`, including Downloads, extensions UI, native dialogs and Little Open App. The branch includes this main commit. The fixture uses two root single rows disjoint from a two-pane split, checked through the actual sidebar tree. The approved relative/25 ms gate result is **PASS**. The 16 ms target remains open across tested loads; the earlier full acceptance run reached 16.581 ms. Physical presentation is out of scope. All synthetic samples, loads and motion records, including the earlier accepted `ebcf08d2` comparison, remain in [the committed artifact](split-app-timings.json).

| Revision | Single median / p95 ms | Split median / p95 ms | Old query p95 single / split ms | Native p95 single / split ms | Renderer p95 single / split ms |
|---|---:|---:|---:|---:|---:|
| main | 5.711 / 7.652 | 12.105 / 14.736 | 10.227 / 14.888 | 5.885 / 11.996 | 7.652 / 14.736 |
| branch | 5.509 / 7.774 | 7.189 / 10.060 | 7.776 / 10.188 | 5.450 / 7.008 | 7.774 / 10.060 |

| Pair | Revision | Single p95 ms | Split p95 ms | Load before → after (1/5/15) |
|---|---|---:|---:|---|
| 1 | main | 7.875 | 14.890 | 7.03/7.38/8.52 → 7.67/7.51/8.56 |
| 1 | branch | 7.774 | 10.101 | 7.67/7.51/8.56 → 8.25/7.63/8.60 |
| 2 | main | 7.296 | 13.730 | 8.25/7.63/8.60 → 7.99/7.59/8.58 |
| 2 | branch | 7.940 | 9.615 | 8.39/7.68/8.60 → 8.12/7.63/8.58 |
| 3 | main | 7.652 | 25.640 | 8.12/7.63/8.58 → 7.71/7.56/8.55 |
| 3 | branch | 7.307 | 8.354 | 7.71/7.56/8.55 → 7.89/7.60/8.56 |

All three ordinary/wrapped motion cohorts have no independent ring animation. Existing changed-frame slot motion keeps its 0.22-second duration; unchanged cached frames need no new animation.

## Final real-App acceptance

| Real-App receipt | Result |
|---|---|
| `split` Chrome Release run 1 | 40/40 PASS; cleanup PASS |
| `split` Chrome Release run 2 | 40/40 PASS; cleanup PASS |
| `split` Chrome Release run 3 | 40/40 PASS; cleanup PASS |
| `window` Chrome Release | 76 PASS; 2 launch-budget known main FAIL under 4h; cleanup PASS |
| `sidebar` Chrome Release | 19 PASS; cleanup PASS |
| `sidebar-completion` Chrome Release | 193 PASS; cleanup PASS |
| `numbering` Chrome Release | 3 PASS; cleanup PASS |
| `commandbar` Chrome Release | 63 PASS; cleanup PASS |

The complete quiet window rerun has cold/warm sidebar-drawn medians 320/323 ms and first-paint medians 538/538 ms at load 10.95/7.13/7.89. Both launch rows fail their original budgets. Classification: **known main FAIL under 4h**. The final interleaved startup comparison against main `ffcf4649` has strict no-slower result **PASS**, load qualification **PASS**. No startup fix is claimed. All four 1× window pixel rows pass.

The earlier main/branch/main/branch launch comparison (main e4d40ce0, branch d5d2666a, engine 7b490905) also FAILS: pooled cold sidebar 328→348 ms, warm 332.5→343 ms; first paint 550.5→578.5 and 547→580 ms. All earlier samples remain retained.

Final startup control:

| Pair | Revision | Cold sidebar / paint ms | Warm sidebar / paint ms | Load before → after (1/5/15) |
|---|---|---|---|---|
| 1 | main | 327 / 532 | 321 / 515 | 8.27/7.62/8.03 → 9.19/7.84/8.10 |
| 1 | branch | 326 / 523 | 327 / 523 | 9.19/7.84/8.10 → 10.14/8.07/8.18 |
| 2 | main | 328 / 523 | 331 / 520 | 10.14/8.07/8.18 → 10.02/8.12/8.19 |
| 2 | branch | 328 / 527 | 308 / 502 | 10.02/8.12/8.19 → 9.51/8.07/8.17 |


Final standalone split switch p95 (single / split ms), with loads:

| Run | Single p95 | Split p95 | Load (1/5/15) |
|---|---:|---:|---|
| 1 | 8.313 | 8.571 | 6.27/7.23/8.37 |
| 2 | 7.017 | 8.231 | 4.32/6.56/8.06 |
| 3 | 7.394 | 8.011 | 3.10/5.94/7.75 |

All split-owned five-second idle counters are zero. The three consecutive split runs and regression suites use fresh roots and the final merged App; all owned processes/windows close. Full verification and command-bar quiet attempts are recorded in the PR.

## Current timing result

Current paired gate: **PASS**. Single-tab p95 main→branch 7.652→7.774 ms against main +1 ms; margin 0.878 ms. Split p95 14.736→10.060 ms. Both absolute 25 ms ceilings pass. All six cleanups pass. No timing rerun or threshold change is used to select a passing result.

## Retained failed attempts

The prior `be4f75ab` main / `6c6372ad` branch comparison, using engine `7b490905`, failed the single-tab relative gate: p95 9.715→10.848 ms, 0.133 ms above main +1 ms. Split p95 was 17.924→11.985 ms. This failure and all six cohorts remain in `earlierBe4Engine7bReceipt` in the committed artifact. The current comparison follows the required main and engine refresh.

On that prior head, the first sidebar-completion attempt failed `TS_highlight_does_not_create_hosts`: created/retained hosts stayed 16/9 while engine contents fell 11→9. The unchanged assertion then passed in a complete 193/193 branch rerun and a 193/193 unchanged-main control. Both attempts remain retained. Current-head sidebar-completion passes 193/193.

The earlier 7b490905-engine trio on source d5d2666a passed its functional, idle and cleanup rows, but its third timing row failed: split p95 29.945 ms at load1 14.85. A permitted quiet rerun then passed 40/40 three times, with split p95 17.710/14.895/14.052 ms. The current receipts follow the later main merge; all earlier arrays remain committed. The earlier full loaded window run measured cold/warm sidebar 548/549 ms and paint 887/901 ms at load1 32.77. Its slower paired startup comparison remains a failure. The final quiet window is classified under rule 4h only with medians within 400/700 ms or a qualifying current-main no-slower comparison.

Source for the final App receipts: `f7fb6148239d223bb5cbf77023a2fe9f6f67f3be`; main control: `ffcf464927a98308ac364b4a2f4350da38a8cbcc`; engine distribution `3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738`. Final evidence changes are documentation only.
