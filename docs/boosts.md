# Boosts + Zap

Profiles integration: pass `fileURL: ProfileDirectories(root: root).boostsFileURL(for: profile)` to `BoostStore(root:profileID:fileURL:)`. The current destination is `Profiles/<dataDirectoryName>/Boosts/boosts.json`. The original `root:profileID:` constructor remains available for standalone callers; the App must pass the explicit Profile path. No App caller exists yet.

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
- `BoostPickerCoordinator.enterZap(boostID:for:)`: arms a native session for an
  engine-owned document/frame identity and returns the command to send. Each new
  session gets a random UUID nonce. Re-entry keeps the same active session.
  `handle(_:from:)` accepts commits/replacements/undo/list/lifecycle messages only
  for that page, Boost, and nonce. It returns whether matching/plans need rebuilding.
  `listZaps(for:)` supplies persisted selectors in the command. Native removal
  echoes do not mutate twice. `exitZap(for:)` expires the capability before send;
  a valid `picker:exited` also expires it. Call `invalidate(pageID:)` on navigation,
  frame destruction, transport loss, or failed send. `BridgeDecode` handles wire
  pairs; the App adapter must validate envelope version 1 before decoding.
- `BoostResources.applierJS` / `.pickerJS`: cached bundled text. The applier owns
  `window.__openBoosts`; the on-demand picker owns `window.__openZap`. Transport is
  `__open.postMessage(type,payload)` / `__open.receive({v:1,type,payload})`.
  The future engine must adopt existing handlers if it replaces the fallback shim.

The applier uses one document stylesheet and one observer, with rAF throttling.
It restores removed styles after SPA swaps. It adds zap/font/text styles to open
and captured late closed roots. Clear restores owned hooks and removes owned sheets.
The picker uses a closed shadow overlay, click-only semantic selector generation,
related-element previews, session undo, and capture listeners only while active.

## Engine requirements and session contract

True overlay secrecy requires the engine adapter to inject the picker in an
**ISOLATED WORLD** (Chromium content-script world). A closed shadow root and
captured functions alone do not protect a main-world picker from page code that
ran before injection. Inject the managed applier in that world too, so its state
and Boost IDs remain private. User-authored Boost JS still runs in the main world
through its script element. This is a required engine integration gate, not an
implemented App/engine adapter in this milestone.

The engine must deliver native commands directly into that isolated world and
accept its native binding there. Do not forward capabilities through page-visible
DOM attributes, events, main-world globals, or a main-world receive relay. Derive
`pageID` from the engine's document/frame identity, never from message JSON. Use a
new identity on navigation, and invalidate the old native session. Capture the
pristine built-ins before page code can replace them in the injection world.
Both IIFEs retain the listed DOM queries/hit tests, shadow attachment, computed
style/rect functions, Array helpers, Map/Set/WeakMap methods, JSON, and
MutationObserver references.

An isolated applier's prototype hooks see calls from its own world. The engine
must provide late closed-root style injection for roots created by main-world
page code. The main-world harness S2/S3 checks do not prove that engine path.

Every `zap:*` and `picker:*` payload now includes `boostID` and `sessionNonce`.
Native creates that nonce when it arms `zap:enter`; the picker echoes it in every
reply. `zap:exit`, `zap:undo`, `zap:remove`, and `zap:list` commands also carry the
session pair. `zap:list` additionally carries `selectors: [String]` from the native
store. There is no DOM manifest. The stylesheet contains CSS only, with no Boost
ID comments or attributes. Hide selectors are inherently observable CSS; they are
not secrets. A page-created `__openZap.enter({boostID})` does not enter picking.
A page-invented nonce cannot pass the native session check.

## Verification (2026-10-25, America/Vancouver)

The complete **26/26 H/A/S-A/S/O/E checks pass**, including visual A7/A11.
The earlier T3 hidden-tab snapshot failure is superseded by this run. As directed,
verification used `puppeteer-core` and system Google Chrome in `headless: "new"`
mode, Chrome 156.0.8078.48, at 1280×900, serving the production files on port 8931. The existing server
was reused; its served files were verified against this worktree. No desktop was
driven, and no unit tests or permanent verification dependencies were added.

| Check | Result | Observed evidence |
|---|---|---|
| H0 | PASS | Both runtimes v1; loader status correct; runtime errors empty; identical bridge/bar snippets across all six pages. |
| H1 | PASS | Production applier fetch 200; fresh null plan, empty IDs, zero zaps. |
| A1 | PASS | Header outline solid; harness-F1, one Boost, one zap. |
| A2 | PASS | Banner display none. |
| A3 | PASS | Fresh banner visible; re-injection hides it. |
| A4 | PASS | Hue 90°, saturation 0.5; article Georgia; code monospace. |
| A5 | PASS | JS counter stays 1 after two identical applies. |
| A6 | PASS | Clear restores banner and outline; plan null. |
| A7 | PASS | Screenshot shows blue border/tint on banner only. Click commits #promo-banner, matches 1; banner hidden, picker active. |
| A8 | PASS | Escape exit reason esc; native-style re-apply keeps banner hidden after preview style removal. |
| A9 | PASS | Control+Z and Undo button each restore the ad; two undo removals; empty stack false. |
| A10 | PASS | 15 sorted, bounded candidates; #promo-banner first; one positive rect; DIV#promo-banner hash. |
| A11 | PASS | Precise first-article pick widens to a 3-match selector; all articles hidden. Screenshot shows live related preview on Second/Third only. |
| S-A1 | PASS | View B replaces content; banner stays hidden without re-apply. |
| S-A2 | PASS | Removed stylesheet returns on rAF; replacement banner stays hidden. |
| S-A3 | PASS | Path-clear restores banner; nested-route reload loads both runtimes. |
| S1 | PASS | Existing open-root promo hidden. |
| S2 | PASS | Newly attached open-root promo hidden. |
| S3 | PASS | Pre-apply closed-root promo visible (known limit); late closed-root promo hidden. |
| S4 | PASS | #shadow-promo commit marked inShadowRoot; root-local preview hides it. |
| O1 | PASS | Card-2 body pick includes exact data-testid; top five avoid bare obfuscated classes. |
| O2 | PASS | Structural widget selector matches one; widget hidden. |
| O3 | PASS | ≤15 candidates, 1–100 matches, sorted; six title rects. |
| E1 | PASS | Out-of-bounds candidates empty; margin click commits broad body selector, picker stays active, no errors. |
| E2 | PASS | Valid zap/outline apply; invalid selector reports one error. |
| E3 | PASS | Double-enter reports already-active; next commit retains the original Boost/session. |

Additional checks pass:

| Finding / check | Evidence |
|---|---|
| Native authority and persistence | 18 assertions pass. A temporary real Swift executable used BoostStore, coordinator, decode/encode, and file reloads. Chrome isolated-world messages traversed that caller over a native binding. Valid pick/list/undo/related replacement/native removal persisted correctly. Missing, invented, wrong-page, wrong-Boost, wrong-nonce, and expired capabilities did not change the file. |
| Session expiry | Picker Escape, native exit before delivery, and navigation invalidation each reject replay. New sessions rotate the nonce. All picker/zap replies carry the pair. |
| Captured built-ins / isolated world | Page attachShadow interception before isolated injection captured zero overlay roots; main-world picker/applier globals absent, host.shadowRoot null. Replacing all named query/hit-test/rect/style/shadow, Array, Map/Set, JSON, and observer functions after capture triggered zero replacement calls; 15 candidates and closed overlay still worked. |
| Hover cost | 100 mousemove events before a frame: zero immediate hit tests, exactly one after rAF. |
| Picture invert | picture filter none; nested img and standalone img have the same counter-filter and matching visible colors. |
| Selector identity / diagnostics / roots | Giving every page element the same __open_id did not affect the precise pick. A distinct new plan reports the invalid selector again. Two list selectors share one document root scan; adding a live shadow root changes both match counts from 1 to 2 with one new scan. The inventory invalidates on mutation, including pending observer records. |
| Live related rects | First post is hidden. Only two boxes: (24,268,920,84) on Second post and (24,364,920,84) on Third post. Hidden/zero-size matches are skipped. |
| Picker controls | Hovering related or Done hides the page highlight and label; hoveredAt over the pill returns null. No body tint. |
| Appendix C | Zoom 1.25 and uppercase; input, textarea, editable child unchanged; Clear restores zoom 1 / transform none. |
| Build | `nice -n 10 swift build -c release -j 6` in Packages/OpenKit succeeds. Temporary caller target/source was removed before the final clean-manifest build. |

Screenshots were opened with the image viewer and checked: `a7-hover.png` shows the
banner highlight; `a11-related.png` shows two aligned live boxes; `pill-hover.png`
shows no page highlight over Done; `picture-invert.png` shows equal standalone and
picture image colors. PNGs remain in the local temporary evidence directory and
are not committed. Browser receipts are `acceptance.json`, `native-browser.json`,
`hardening.json`, `roots.json`, and the before/after latency JSON there. The local
evidence directory for this run is `/var/folders/s6/_07cr4w13vsg_myjkv9ldpqc0000gn/T/open-boost-fixes-8fuqghwj`.

| Measurement | Raw values (ms) | Median (ms) | Max (ms) |
|---|---|---|---|
| Large candidates, before (10) | 55.6, 49.1, 47.8, 47.1, 45.1, 55, 50.5, 56.5, 49.2, 45 | 49.15 | 56.5 |
| Large candidates, after (10) | 12.4, 8.7, 9.8, 8.4, 7.8, 7.4, 7.5, 7.8, 7.4, 7.4 | 7.80 | 12.40 |
| Large complete clicks, after (10) | 14.7, 9.7, 12, 11.4, 10.7, 12, 11.5, 13.1, 11.1, 8.7 | 11.45 | 14.70 |
| P1 static | 0.1, 0, 0.1, 0, 0 | 0.00 | 0.10 |
| P2 static | 0, 0, 0, 0, 0, 0, 0, 0.1, 0, 0, 0, 0.1, 0, 0, 0, 0, 0, 0, 0, 0 | 0.00 | 0.10 |
| P3 static | 1.4, 0.9, 0.6, 0.6, 0.5 | 0.60 | 1.40 |

The 20,000-element fixture is generated client-side in `Harness/large.html`:
100 sections, each with a caption and 18 obfuscated cards of 11 elements each.
The timed target is the first article's padding. Candidate generation caches
selector node lists for one pick, narrows expansions from those lists, and ranks
and fingerprints only beam/phase-2 survivors. The full click timing runs from the
document capture listener to `zap:committed`, including preview-hide work.
All raw samples are retained; medians of even sample counts average the middle two.
Browser timers resolve about 0.1 ms; zero means below that resolution.

The bundled and served resource bytes match the final source: applier SHA-256
`2d1dcd10e425cef993de62ce95179fc4d915a0fd26acd23113618fac65edb3be`, picker
`067102a53aed582e04c2b23cca3f7b50a1eb234830591081f58e90b1baeefba5`.
The fallback bridge can be replaced after runtime load while retaining handlers;
apply, ready, and a real banner-click commit reach the adopted transport.

Production document-start timing and the actual OpenEngine adapter remain
unverified. This pass proves package/Chrome runtime behavior and the real native
coordinator/store bridge. Existing model/store/matcher baseline results from the
initial milestone were not repeated for this bounded fix.

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
  values; the updated screenshots pass visual review.
- The initial DOM manifest was removed in the review fix. Native now supplies
  persisted selectors in authenticated list commands. Native-issued sessions and
  isolated-world injection supersede the plan's main-world assumption. The §9.2
  list-result wire shape (counts, not rect arrays) takes precedence over §7.6.
  Outbound undoZap covers the normative §9.3 command missing from §8.3's enum.
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
editor wheel math. Managed runtime injection requires the isolated-world engine
contract above; document-start remains unverified Arc timing. See the [harness README](../Packages/OpenKit/Sources/OpenBoosts/Harness/README.md)
for operation and limits: CSP, arbitrary JS effects, icon fonts, partial-invert media,
pre-injection closed roots, and per-frame engine work.
