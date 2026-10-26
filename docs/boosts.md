# Boosts + Zap

`OpenBoosts` is a Swift 6, macOS 26+ library in OpenKit. It depends only on
`OpenModel` for `ProfileID`. It provides the data, persistence, matching, injection
plans, picker bridge, and page runtimes. It has no engine or App wiring. Editor UI,
Settings storage, sharing, imports, and per-frame engine injection remain future work.

## API

- `Boost`, `SiteMatch`, `ColorAdjustment`, `ZappedElement`, `BoostID`: value types.
  Components are independent. JS is stored verbatim; `containsJS` trims whitespace.
  Text zoom clamps to 0.5–2; transforms are none/uppercase/lowercase/capitalize.
- `BoostStore(root:profileID:)`: load once before mutation. Stores per-profile JSON
  at `Boosts/<UUID>.json`. Mutations normalize and save with a one-second debounce.
  `saveNow()` writes atomically; use it on quit. `flush()` drains in-flight writes
  but does not fire a pending debounce. Neither may run on the private I/O queue.
  Corrupt files are moved aside; newer schema numbers survive subsequent saves.
- `BoostMatcher`: rebuild after edits; lookup probes host suffixes. IP literals are
  exact matches. Order is general to specific, then creation time and ID. Path
  prefixes use slash boundaries and encoded paths. IDNs are lowercase-only.
- `BoostInjectionPlanner.plan`: accepts URL, profile, matcher, global flag, and
  context. Selects the last non-identity color and last valid font/text component.
  Produces a stable FNV-1a content ID and structured `InjectionPlan`.
- `BoostPickerCoordinator.handle`: persists commit/replacement/undo and returns
  whether the caller must rebuild matching and re-plan. Native removal echoes do
  not mutate twice. `BridgeDecode` converts transport pairs to/from typed messages.
  The App adapter must validate envelope version 1 before decoding payloads.
- `BoostResources.applierJS` / `.pickerJS`: cached bundled text. The applier owns
  `window.__openBoosts`; the on-demand picker owns `window.__openZap`. Transport is
  `__open.postMessage(type,payload)` / `__open.receive({v:1,type,payload})`.
  The future engine must adopt existing handlers if it replaces the fallback shim.

The applier uses one document stylesheet and one observer, with rAF throttling.
It restores removed styles after SPA swaps. It adds zap/font/text styles to open
and captured late closed roots. Clear restores owned hooks and removes owned sheets.
The picker uses a closed shadow overlay, click-only semantic selector generation,
related-element previews, session undo, and capture listeners only while active.

## Verification (2026-10-25, America/Vancouver)

Real package callers compiled under `/tmp` against the release library. Browser
checks used only T3 collaborative `preview_*` tools and the production files served
by `Harness/serve.py` on port 8931. A fresh server ran the complete H/A/S-A/S/O/E
sequence from loader.html without a restart. No unit tests were added or run.

**24 checks pass. A7 and A11 pass functionally but their visual portions remain
UNVERIFIED.** `preview_snapshot` failed on the initial tab and on fresh/reopened
tabs, including after an explicit viewport resize. The errors were:

> Preview automation snapshot timed out after 15000ms.

> Protocol error (Page.captureScreenshot): A previous preview capture is still pending. Reopen this tab to capture again.

This is an incomplete visual acceptance gate. No screenshot or full visual pass is
claimed. Functional assertions below are Eval results, not substitutes for visuals.

| Check | Result | Observed evidence |
|---|---|---|
| H0 | PASS | Versions 1/1; `applier: v1, picker: v1`; errors `[]`; bridge snippets identical on all 5 pages. |
| H1 | PASS | Production applier fetch status `200`; fresh state has null plan, empty IDs, zero zaps. |
| A1 | PASS | Outline `solid`; `harness-F1`, one boost, zapCount 1. |
| A2 | PASS | Banner display `none`. |
| A3 | PASS | Fresh load `block`; F1 re-injection changes it to `none`. |
| A4 | PASS | `hue-rotate(90deg) saturate(0.5)`; article Georgia; code monospace. |
| A5 | PASS | JS marker `ran`, counter `1` after two applies; one applied report. |
| A6 | PASS | Banner `block`, outline `none`, appliedPlanID null. |
| A7 | PARTIAL | One `#promo-banner` commit, matches 1, hidden, still picking. Hover overlay visual UNVERIFIED: capture service failure. |
| A8 | PASS | Escape exit reason `esc`; simulated native re-apply keeps banner hidden with preview stylesheet removed. |
| A9 | PASS | Control+Z and bar Undo both restore ad; removed via undo; empty stack returns false. |
| A10 | PASS | 15 sorted, bounded candidates; first `#promo-banner`; rect 1232×58; hash begins `DIV#promo-banner`. |
| A11 | PARTIAL | Unique article pick replaced by 3-match selector; all 3 hidden. Related-preview visual UNVERIFIED: capture service failure. |
| S-A1 | PASS | New view-B marker present, replacement banner hidden without re-apply. |
| S-A2 | PASS | Removed stylesheet restored; banner hidden by next tool Eval, no extra wait needed. |
| S-A3 | PASS | `/Harness/blog/post`, cleared state, banner `block`; direct route reload loads both real runtimes. |
| S1 | PASS | Open-root promo `none`. |
| S2 | PASS | Newly attached open-root promo `none`. |
| S3 | PASS | Pre-apply closed-root promo `block` (known limit); late closed-root promo `none`; created-after flag true. |
| S4 | PASS | Commit `#shadow-promo`, inShadowRoot true; root-local preview hides it. |
| O1 | PASS | First `[data-testid="card-2"] p`; top five avoid bare generated-class terms; commit includes exact test ID. |
| O2 | PASS | Structural `#content :nth-child(7)`, matches 1; widget hidden. |
| O3 | PASS | ≤15 candidates, 1–100 matches, sorted; 6 post-title rects. |
| E1 | PASS | Out-of-bounds candidates `[]`; margin click commits broad body selector; picker remains active; errors `[]`. |
| E2 | PASS | Good zap and outline apply; invalid-zap-selector reported for `!!!invalid`. |
| E3 | PASS | already-active error; subsequent commit retains harness-boost. |
| Appendix C text | PASS | Zoom `1.25`, uppercase text; input, textarea, editable child `none`; Clear restores zoom `1` and transform `none`. |
| Native data/store/matcher | PASS | Stable numeric-date JSON, normalization, clamps, dedupe, atomic replacement, quarantine, schema preservation, debounce; 15 matcher rows including IPv6 and encoded paths. |
| Native planner/bridge | PASS | Stable/edit/empty/context plans; font rejection; coordinator persistence/echo handling; 9 inbound and 7 outbound types; actual Swift-encoded plan applied through browser bridge; persisted list/native remove/version guard and 100-rect cap pass. |
| Release build / existing CLI | PASS | `nice -n 10 swift build -c release -j 6` in OpenKit; zero new warnings. `openkit commands-demo /tmp/boost-check/commands-demo`: 66 passed, 0 failed. |
| Idle | PASS (source reading) | Freshly loaded, never-applied runtime creates no timers or observers. Clear disconnects observer and restores history/attachShadow. Picker exit removes document/window input listeners and cancels rAF; exit grace is bounded to 500 ms. |

| Budget | Values (ms) | Result |
|---|---|---|
| P1 apply, 5 runs | 0.10, 0, 0, 0.10, 0.10; median **0.10** | PASS <1 ms |
| P2 hoveredAt, 20 calls | 19 zero samples, one 0.10; median **0**, max **0.10** | PASS <2 ms; below timer resolution |
| P2 fresh baseline | 17 zero samples, three 0.10; median **0**, max **0.10** | Same resolution/noise floor |
| P3 article candidates, 5 runs | 1.80, 1.20, 1.10, 1.10, 0.90; median **1.10** | Below 50 ms guidance |
| Native matcher | 100 boosts / 10 domains / 10,000 lookups: **53.506 ms total**, **0.0053506 ms/lookup** | Negligible; release library |

Browser timer resolution was about 0.10 ms; zero means below that resolution.
P1 measures style construction after parse. Production document-start timing needs
the engine adapter and is not verified here. Five real hover tool calls completed
without handler errors; visible lag remains unverified because capture failed.
The static gibberish control's top selector was `#content :nth-child(5)`.
The final resource bundle and served source hashes match: applier
`3a9e633b12c8db7a64f1577349387cca767b54823cdf4aab2199b16806de4592`, picker
`3c775acdf86308ac7ea75866e899181ea15c51f54e10811e89a3557030398440`.

## Deviations from plan

- Added `exclude: ["Harness"]` in the minimal Package.swift target declaration to
  keep non-resource fixture files out of SwiftPM's source inventory and bundle.
  Harness pages set a `/Harness/` base URL so real runtime resources still load
  when the SPA fallback serves a nested route on a full reload.
- Used `URL.path(percentEncoded: true)`. Plain Foundation `.path` decodes escapes,
  contrary to §5.3's assumption. Preserved bracketed/bare IPv6 domains instead of
  stripping them at their first colon; IP matching stays exact.
- The returned list reserves a precise stable ID, or exact test-ID path, before
  other equal-count choices. Pure additive scores otherwise selected a scoped
  class before `#promo-banner`, or an attribute suffix before exact `card-2`, which
  conflicts with A7/A10/O1. Remaining candidates use semantic scores, uniform-style
  preference, the allowed five-per-match-count diversity rule, and final count sort.
  Beam pruning uses semantic scores before the final style-uniformity bonus, as
  the Step C then D order requires. Duplicate `:has` constraints cannot earn score.
- `:has(...)` attaches directly to the selected element. The space in §7.5's
  example would select descendants instead. Shadow-local selectors stop inside
  their root; adding the external host term makes a root-local selector invalid.
  Attribute prefix/suffix terms keep their actual space/dash/slash separator.
  The fixture class `card-k8x2` remains unchanged: despite §10.5's description,
  the normative gibberish rules classify it as semantic (only two digits).
- The related preview uses the same closed overlay. Document capture ignores its
  host, since a closed root's composedPath hides the internal bar. Harness controls
  opt out through `data-open-zap-ignore`. Overlay styling uses the specified Open
  values; its appearance has not passed visual review due to capture failures.
- Added an internal zap manifest on the applier-owned style element so an on-demand
  picker can list persisted zaps without a new public API. The §9.2 list-result
  wire shape (counts, not rect arrays) takes precedence over §7.6. Added outbound
  `undoZap` to cover the normative §9.3 command missing from §8.3's enum.
- Shadow font/text selectors use `:host` because body cannot match in a shadow root.
  Text controls also reset form/editable inheritance. Text fields extend the wire
  plan, component selection, and content hash as required by Appendix C.
- Resource loading preflights SwiftPM bundle locations because generated
  `Bundle.module` traps if the whole bundle is missing. Missing resources return
  empty strings and log, as required. Scratch callers copy the real bundle beside
  their executable. The obfuscated fixture was available at Step 6 because that
  step itself requires O1–O3 before the later full harness pass.

Default Q4–Q7 decisions remain: apply in both contexts, pass the global preference
into the planner, enter Zap through the bridge, and store filter values without
editor wheel math. Main-world/document-start injection follows the plan's explicit
assumption, not verified Arc timing. See the [harness README](../Packages/OpenKit/Sources/OpenBoosts/Harness/README.md)
for operation and limits: CSP, arbitrary JS effects, icon fonts, partial-invert media,
pre-injection closed roots, and per-frame engine work.
