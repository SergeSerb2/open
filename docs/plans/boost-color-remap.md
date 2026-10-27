# Boost Step 4R — engine-level page color remap: implementation plan

Status: plan, 2026-10-26; revised same day for PR #119 review round 1 (Opus architecture review:
transport and per-frame install reworked, scheme channel dropped from v1 by lead ruling, coverage
and gates tightened; see plan §4, §5.2, §5.6, §11). A re-check against the tree then moved the
CEF API to global functions with one owner patch per hook file (§5.4, §10.1) and replaced the
first-paint hook, which does not exist in 156, with view paint stamps (§5.2, §5.4). Revised again
for review round 2 (final, MERGE AFTER FIXES): the small-ρ hue seam is stated and gated (§7.2,
§8), the page background remaps after the blend (§5.3b), print skips the install (§3.4), and
the SVG-gradient threading, G6/G7 timing, per-browser deltas, and document-start URL rules are
fixed (§5.3, §5.4, §5.5, §11). Implementer: one engine agent (tree owner) plus one shell-side helper
(no tree build). Parent decisions: `docs/plans/site-control-boost-editor.md` Step 4R (§10, line
1353), Q12 ruling (§11.2), R-2, D-7, §4.4.5, and the Step 4R gates at §7 (line 1157). Color facts:
`docs/re/features-advanced.md` §4.8, BO-23. Engine boundary facts: `docs/re/arccore-engine.md`
§2.3, §2.7, §5. Fork mechanics: `docs/engine-fork.md`, `docs/engine-patches.md`,
`docs/engine-api.md`. Boost model: `docs/plans/boosts-zap.md`, `Packages/OpenKit/Sources/OpenBoosts/`.

Conventions in this file: "Open choice" is final for v1 without a lead ruling; "guess" means Arc's
behavior is unproven — build the stated value, keep it in one named token, and settle it with the
capture list in §8. Chromium paths are relative to `chromium/src` in the local tree
(`~/Developer/open-engine/chromium_git/chromium/src`, Chromium 156.0.8078.48, verified by
`chrome/VERSION`). Every Chromium claim below was read in that tree during this task; line numbers
are from that checkout and will drift on rebase (§10.4 lists the watch files).

## 1. Goal and success criteria

Replace the interim CSS-filter Boost color runtime (#103, site-control §4.4.5) with an engine-level
paint-time color remap that matches Arc's observed model (BO-23): Swift builds a 20-float matrix
that acts in HSLA space; the engine registers it per host pattern per Profile and per live tab;
each renderer applies it to non-image paint. White and grey page colors take the pad's knob hues;
images, video, and canvas bitmaps keep their colors (capture S2-22). Arc's separate one-value
appearance channel (`registerColorScheme:`; BO-23c, guess) is **out of v1** by lead ruling on
review r1 (§5.6): no v1 control sets it.

Done means all of these hold on the real app (Release, M5 Pro):

1. With the S2-22 knob inputs, a white page pixel reads within ΔE00 3 of `#E4E2F3` and a `#222222`
   pixel within ΔE00 3 of `#56285D` (e2e `boostcolor` G1, G2, §11).
2. Image, background-image, and canvas pixels are unchanged within 1 level per channel (G3).
3. Removing the Boost color restores the original pixels without a reload (G4).
4. The remap is present in same-origin and cross-origin (OOPIF) subframes per the rules in §6,
   survives navigation, process swap, and back/forward (G5, G6, G9), and a live editor drag
   changes pixels within 100 ms (G7).
5. With no Boost color registered anywhere, added paint/scroll cost is zero within the noise band
   in §11.3; with one Boost color, scroll p95 on the three named heavy fixtures stays within the
   budget in §11.3 (G8). These are the site-control §7 Step 4R gates.
6. No unit tests (rule 6). All proof is `tools/e2e/engine_e2e.py --only boostcolor`, the OpenBoosts
   harness, and `tools/verify-all.sh` through `heavy.sh` (rule 10).

Non-goals: changing the Boost editor UI or the pad law (site-control plan owns them); the
light/dark appearance override (§5.6, post-v1); remapping native form controls or Mac scrollbars
(M2, §13 Q-B11), extension pages, DevTools, internal pages, print output, or the PDF viewer in v1
(§6.4); matching
Arc's 20-float byte order or integer encoding (our engine defines its own; only page pixels must
match); the §8 Step-2 math terms before their captures exist.

## 2. Evidence base (what is proven, what is guessed)

| Fact | Evidence |
|---|---|
| Arc's transport is a 20-float matrix in HSLA space, `ArcHSLAMatrix` (`{HSLAMatrix=ffff…}`, `initWithMatrix:` `[20f]`) | BO-23a (`otool -oV`, `.re/arccore/objc-methods.txt` on the main checkout) |
| Per-Profile registry: `ArcBrowserContextEffects registerColorFilter:forHostPattern:` / `unregisterColorFilter:` / `registerColorScheme:forHostPattern:` (one 64-bit int) / `unregisterColorScheme:` | BO-23a; re-verified this task: `strings -a` on `/Applications/Arc.app/.../ArcCore` shows all four selectors (`.re/boost-remap-plan/strings-check.txt`, local) |
| Per-tab live apply: `applyColorFilter:` / `applyColorScheme:` / `removeColorFilter` / `removeColorScheme` on the web contents | BO-23a, BO-23b (one `objc_msgSend` stub and one ADK wrapper each; wrapper addresses in BO-23b) |
| Browser registry file `arc/browser/browser_context/effects_impl.cc`, beside `NotifyBoostConfigChanged` and `arc.mojom.EffectsAgent`; only renderer paths are `arc/renderer/render_frame_agent_impl.cc` and `arc/renderer/ad_blocker_agent.cc` | BO-23d; re-verified this task with the same `strings` run (adjacent lines in both slices) |
| S2-22 outputs: `#FFFFFF → #E4E2F3`, `#FCF5E6 → #D4C7F8`, `#222222 → #56285D`, `#333333 → #632F6F`; images unchanged. Grey fit `L′ = 0.761·L + 0.159`, `S′ ≈ 0.40`, hue from secondary knob (dark) to primary knob (light) | BO-23e; re-fit this task (`.re/boost-remap-plan/fit-check.py`, local): with knob-hue anchors and `S′ = 0.40 + 0.48·S`, all four pairs predict within 2 levels per channel (§7.3) |
| An affine RGBA matrix is refuted (grey ramp is not per-channel linear) | BO-23e |
| The `EffectsAgent` receiver is per frame; the paint hook skips raster images; `registerColorScheme:` forces light/dark | Guesses in BO-23c/d (no symbols; C++ is stripped). This plan does not depend on Arc's exact hook, only on the observed pixels |
| Open today: `Boost` has `colorAdjustment: ColorAdjustment?` only; `BoostInjectionPlanner.plan` keeps the last non-identity color; #103 adds `BoostColorWheel` and derives `colorAdjustment` from it | `OpenBoosts/Boost.swift:106`, `InjectionPlan.swift:51`; site-control §1, §4.4.5 |
| Open's shell reaches the engine only through OpenEngine (`OEWebContent`, `OEBrowserContext`, `OEBrowser`); OpenKit uses the `OpenWeb` protocols | `docs/engine-api.md`; `OpenWeb/OpenWeb.swift:37` |

## 3. The hook: record-time solid-color rewrite in Blink paint (decision)

### 3.1 Decision

Mirror Chromium's own auto-dark mechanism. Add a per-document `blink::BoostColorFilter` that is
consulted at the same two choke points where `DarkModeFilter` rewrites colors today, inside
`third_party/blink/renderer/platform/graphics/graphics_context.cc`:

- the free helper `DarkModeColor(context, color, auto_dark_mode)` (graphics_context.cc, ~line 78),
  which every solid-color `FillRect`/`FillPath`/`StrokePath`/text-fill path funnels through; and
- `GraphicsContext::DarkModeFlags` (same file, ~line 194), which copies `cc::PaintFlags` only when
  dark mode applies and calls `DarkModeFilter::ApplyToFlagsIfNeeded`
  (`dark_mode_filter.cc:252`): if the flags have no shader, it rewrites `flags.getColor4f()` on the
  CPU and records the final color into the `PaintOpBuffer`. No `cc::ColorFilter` is attached.

Boost adds a parallel branch at exactly these points: when the current `GraphicsContext` carries a
`BoostColorFilter*`, rewrite the solid color through the HSLA matrix (§7) before recording. Gradient
stops go through the gradient equivalent: `Gradient` already rewrites each stop color when
`is_dark_mode_enabled_` is set (`gradient.cc:334`, `InvertColorIfNeeded` per stop); Boost adds the
same per-stop rewrite when a matrix is set (§5.3). Image draws (`GraphicsContext::DrawImage` and
friends, graphics_context.cc ~536+) never have their pixels touched; the matrix rides
`ImageDrawOptions` only as a carrier for the gradient path, and image consumers must ignore it
(§5.3, review m7). A small set of colors that bypass both choke points (shadows, document
background, SVG gradients/markers, wavy underlines) get one-line branches at their own sites
(§5.3b, review M1).

**Per frame, not per paint tree (review B2).** `LocalFrameView::PaintTree` runs only on the local
root (`local_frame_view.cc:3240`) and builds the one `GraphicsContext` at :3292; in-process child
frames paint into that same context through `LocalFrameView::Paint` → `PaintFrame`
(:4419, :4454). So the filter is **not** installed at context construction. The context starts null.
Each `LocalFrameView::PaintFrame` installs its own view's filter for its subtree with a scoped
save/restore, then restores the enclosing value. The per-view state is tri-state (§5.2): *unset*
(inherit the enclosing filter — about:blank and srcdoc children), *none* (explicit no remap), or
*value*. `LocalFrameView` owns the filter object, next to its existing `EnsureDarkModeFilter()`
(`local_frame_view.cc:5591`). Because the swap is scoped to `PaintFrame`, the validation-message
overlay, frame color overlay, and DevTools overlays painted after it in `PaintTree` (:3301-3310)
stay unremapped. Painters need no changes: unlike auto-dark, Boost enablement does not travel in
`AutoDarkMode` (derived from `ComputedStyle::ForceDark()`, `computed_style.h:2632`, at 100+
`PaintAutoDarkMode(...)` call sites).

### 3.2 Why this hook, against each requirement

| Requirement | Why the hook satisfies it |
|---|---|
| Images and video keep colors (S2-22) | `<img>`, CSS background images, and favicons record through `DrawImage`, which the hook never enters. Video records a foreign layer (`video_painter.cc`: `RecordForeignLayer(..., DisplayItem::kForeignLayerVideo, ...)`), not solid-color ops |
| Canvas and WebGL keep colors | A canvas element's bitmap is a foreign layer when composited (`html_canvas_painter.cc:87`, `kForeignLayerCanvas` via `ContentsCcLayer()`; WebGL canvases use the same layer) or a `DrawImage` of its snapshot otherwise. The canvas element's own CSS background and border are box paint and do remap (Open choice; capture item C-4R-6) |
| Zero cost with no Boost color | The branch is one null check per solid-color draw, exactly like the existing `auto_dark_mode.enabled` check in `DarkModeColor()`. No filter object is built (`LocalFrameView` creates it lazily on first set, like `EnsureDarkModeFilter`). Recorded ops are byte-identical when off, so raster, compositing, and tile caches see no change |
| 120 Hz scroll | The transform runs once at record time, on the main thread, per distinct solid color (LRU-cached, §7.4). Scrolling replays cached display items and cc tiles; it records nothing new for already-painted content. Raster receives final colors in ordinary `PaintOp`s — no per-tile filter work, no extra render pass |
| Text, borders, backgrounds, selection, inline SVG | All record solid colors through `GraphicsContext` (`TextPainter` takes `AutoDarkMode` and reaches the same flags path, `text_painter.cc:376`ff; SVG shape painters likewise). They remap with no per-painter code, except the §5.3b bypass sites (shadows, SVG gradients/markers, wavy underlines) |
| Composited solid-color layers | Covered for free: Blink derives a solid layer's color from the recorded ops (`drawing_display_item.cc:117-158` reads `flags.getColor4f()`; `pending_layer.cc:736` sets it on the `cc::SolidColorLayer`), so recorded final colors are what composites (review r1). A raster/cc-side filter would miss these |
| Native form controls and Mac scrollbars | **Not remapped in v1** (review M2): native parts paint canvas-direct through `WebThemeEngine::Paint(paint_info.context.Canvas(), …)` (`theme_painter_default.cc:365`ff; Mac scrollbars `scrollbar_theme_mac.cc:222`ff) and never reach either choke point. Author-styled box paint around controls does remap. Follow-up hook if C-4R-11 proves Arc differs: a scoped color-rewriting `cc::PaintCanvas` proxy around only the `WebThemeEngine::Paint` calls (§13 Q-B11) |
| Iframes and OOPIFs | Cross-process subframes paint in their own renderer; in-process subframes share the root's context but swap in their own filter at `PaintFrame` (B2). State is per frame (§5) either way; the parent's `RemoteFrame` never paints child pixels |
| No new paint-op wire format | `cc::ColorFilter` has a fixed serialized `Type` enum (`cc/paint/color_filter.h:52`: kMatrix is an RGBA matrix — refuted for Boost by BO-23e — plus kBlend, kTableARGB, kHighContrast, …). A runtime SkSL filter would need a new `Type`, `PaintOpWriter/Reader` support, and GPU-raster handling. The CPU rewrite records plain colors and needs none of that |
| Display-item caching stays correct | Toggling the matrix invalidates paint for the view and descendants (§6.2), the same invalidation `StyleEngine::PlatformColorsChanged()` performs for a forced-dark toggle (`style_engine.cc:1392`). Cached items with old colors are dropped by the normal paint invalidator |

### 3.3 Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Compositor layer filter (`cc::Layer` filters / `FilterOperations` on the page layer) | Applies to the whole layer, images included — refuted by S2-22 (BO-23d). Also forces a render pass per layer and re-runs on every composite |
| Raster-time filter in cc (like `cc::RasterDarkModeFilter`, `cc/tiles/raster_dark_mode_filter.h`) | That interface exists only to classify **images** at decode/raster (`ApplyToImage`); Chromium deliberately does solid colors at record time. A raster hook would need to distinguish image ops from solid ops inside `PaintOpBuffer` playback, re-run per tile raster (scroll cost), and still need a way to carry the matrix to GPU raster workers |
| SkRuntimeEffect `cc::ColorFilter` on `PaintFlags` for non-image draws | Needs a new serialized `ColorFilter::Type` (above), SkSL compile per matrix change, and per-pixel GPU cost for every solid fill forever, to compute a function whose input is one constant color per draw. The CPU rewrite computes it once per distinct color |
| Remap in style resolution (rewrite `ComputedStyle` colors) | Changes `getComputedStyle()` results (pages and extensions would see fake colors; Arc's behavior here is unobserved — guess: Arc does not, because its hook is at paint). Also misses canvas-adjacent box paint uniformity and forces full style recalc semantics into the color path. Paint-time keeps the DOM truthful |
| Reuse `DarkModeFilter` itself (force-dark + custom classifiers) | Its transform is a fixed lightness inversion with contrast repair (`dark_mode_color_filter.cc`), not a knob-driven HSLA matrix; its settings are process-global constants (`dark_mode_settings_builder.cc:42`, one static `DarkModeSettings`). Boost needs per-frame matrices. Reuse the *shape*, not the object |
| Whole-surface post-process in OpenEngine/AppKit (Core Image over the page view) | Cannot leave images out; adds a full-surface GPU pass per frame; breaks with remote (GPU-process) layers. Refuted by S2-22 like the compositor filter |

### 3.4 Interaction rules at the hook (normative)

1. Order: if both auto-dark inversion and Boost apply to one draw, Boost runs **last** (it sees the
   inverted color). Open never enables Chromium forced dark in v1 (`force_dark_mode_enabled` in
   `web_preferences.mojom:394` stays false), so this is a safety definition, not a product path.
2. Pause scopes: `GraphicsContext::ScopedAutoDarkModeState` (used by `svg_root_painter.cc:88` to
   pause dark inversion inside large inline SVG) does **not** pause Boost. Inline SVG remaps
   (guess, BO-23f; capture C-4R-5). Boost has no pause scope in v1.
3. SVG-as-image documents never remap: they paint in an isolated `Page` whose frame has no
   renderer agent (§5.2), so no filter is ever set there. This falls out of the data path; do not
   add a special case.
4. Fully transparent colors (`fA == 0`) pass through unchanged (Open choice: transparent black is a
   common default in flags; tinting it would still be invisible, but skipping keeps the LRU clean
   and avoids surprising `SkColor4f` values in ops).
5. Colors with a shader (gradients, patterns) are handled only by the gradient-stop path (§5.3).
   `ApplyToFlags`-style rewrite must return "no change" when `flags.HasShader()`, exactly like
   `DarkModeFilter::ApplyToFlagsIfNeeded` (`dark_mode_filter.cc:256`). The one shader-carrying
   exception is wavy decorations, handled before the blend is built (§5.3b).
6. Masks (review m6): the matrix is not applied while painting mask content, so CSS
   `mask-image` gradients with `mask-mode: luminance` keep their coverage. Mechanism: a scoped
   boost pause on the context at the CSS mask paint entry (implementer checkpoint: find where
   mask phases build their recording context; SVG `<mask>` already uses a fresh builder and is
   safe, `layout_svg_resource_masker.cc:56`). The fixture carries a luminance-mask swatch (G3).
7. Printing (review r2 N2): print also paints through `PaintFrame` (`PrintPage` →
   `PaintOutsideOfLifecycle` → `PaintFrame`, `local_frame_view.cc:4459-4468`). So `PaintFrame`
   skips the scoped install while this frame's document or its local root's document is
   printing (`Document::Printing()`, `document.h:1074`). The print context starts null, so a
   skipped frame and its skipped children paint unremapped: print output is unremapped in v1
   (Open choice; Arc unobserved, §13 Q-B9). Paint preview (`web_local_frame_impl.cc:607-613`),
   the selection drag image (`drag_controller.cc:1231-1236`), and `WebViewImpl::PaintContent`
   (`web_view_impl.cc:1603`) are not printing, so they follow the screen and remap.

## 4. Data path overview

```text
OpenKit (Swift)                     App                     OpenEngine (ObjC++)          CEF / Chromium (fork)
─────────────────                   ───                     ───────────────────          ─────────────────────
Boost.colorWheel (#103)
  └─ BoostColorMatrix.make ──► BoostEngineAdapter ──► OEBrowserContext            ──► CefRegisterBoostColorFilter
     (20 floats)                 (pattern diff +        -registerBoostColorFilter:      (global fn, cef_boost_color.h)
                                  per-page apply)       forHostPattern:pathPrefix:  └─► open_engine::BoostColorRegistry
                                OEWebContent                                            (per BrowserContext)
                                  -applyBoostColorFilter: ──► CefApplyBoostColorFilter│  on every change: snapshot
                                  -removeBoostColorFilter     (global fn)            │  (patterns + per-browser values
                                                                                     │   + generation) to every
renderer (each process of the Profile)                                               │  renderer process, over a
  BoostColorThreadObserver (RenderThreadObserver) ◄──────────────────────────────────┘  channel-associated interface
    owns the process snapshot; on update re-resolves every live frame
  BoostColorFrameAgent (per RenderFrame): resolves its frame locally at document start
    └─► blink glue ──► LocalFrameView tri-state (unset / none / filter)
          └─► PaintFrame scoped swap ──► solid-color rewrite at record time (§3)
```

**One delivery mechanism (review B1): a process-level snapshot pushed over a channel-associated
interface**, in Chrome's `RendererConfiguration` pattern. It replaces both earlier directions
(sync pull and per-frame push), which review r1 rejected: the pull blocked every document start
on the AppKit main thread (CEF's UI thread) and trusted renderer-supplied `url`/`browser_id`;
the push raced navigations (`CefFrameHostImpl` queues frame actions while the pipe is unbound,
`frame_host_impl.cc:644-648`, and replays them onto the *next* document, `:711-714`).

- Browser side: for each renderer process of the Profile,
  `host->GetChannel()->GetRemoteAssociatedInterface(&remote)`
  (`chrome/browser/profiles/renderer_updater.cc:176-185`). The initial snapshot is sent from
  `RenderProcessWillLaunch` (CEF already overrides it,
  `chrome_content_browser_client_cef.cc:311`); every registry change re-sends the full snapshot
  with a bumped generation.
- Renderer side: a `content::RenderThreadObserver` registers the receiver in
  `RegisterMojoInterfaces` (`content/public/renderer/render_thread_observer.h:29`; Chrome's use at
  `chrome_render_thread_observer.cc:171-182`). Channel-associated messages are FIFO with the
  frame commit messages on the same channel, so a document always sees every snapshot sent
  before its commit — first paint is correct with no sync IPC and no UI-thread wait. Evidence
  that commits ride the same channel: `CommitNavigation` goes over `mojom::NavigationClient`,
  an associated remote from the frame's route provider
  (`render_frame_host_impl.cc:14157-14160`, `:3969-3975`), whose agent scheduling group uses
  the process channel (`agent_scheduling_group_host.cc:248-252`) while `kMBIMode` stays legacy
  (off by default; its own comment says other modes break cross-group ordering,
  `content_features.cc:705-731`). The ordering mechanism: `IPC::ChannelAssociatedGroupController`
  posts every channel-associated message to the one proxy task runner, unless an endpoint was
  bound off-sequence on purpose (`ipc/ipc_mojo_bootstrap.cc:1073-1101`), and the renderer
  channel has one listener task runner (`content/child/child_thread_impl.cc:608-611`). So the
  thread observer's endpoint and `NavigationClient` (`kInternalNavigationAssociated`,
  `render_frame_impl.cc:2166`) dispatch in send order. G6 proves the ordering on the real build,
  and its break arm shows the gate fails when the order is wrong (§11.2).
- The renderer resolves locally: the snapshot holds the pattern table (with optional path
  prefixes, m4) plus per-browser values keyed by CEF browser id. Each frame agent resolves its
  own frame at document start from its real URL (no renderer-supplied strings cross a trust
  boundary — resolution happens renderer-side from the frame's own state); on each snapshot
  update the thread observer re-resolves every live frame in the process, which also covers
  prerendered and BFCached frames (m5).
- A registry that has never held an entry sends nothing — not at launch, not ever — so "off"
  has no IPC at all. The launch send skips any empty snapshot. A change broadcast always sends,
  because a change that empties the registry must still clear live frames (§5.4). The one
  exception is the verification switch `--open-boost-color-paint-reports` (§5.4 readback):
  with it, the launch send also carries an empty snapshot so the reports turn on. Only the e2e
  suite sets that switch, and the zero-cost gates run without it (§11.3).
- Cost accepted: every renderer of the Profile learns the Boosted-host list. Chrome accepts the
  same exposure for content-setting rules, and the rejected pull allowed probing for it anyway.
- This removes the `cef.mojom` method, the `CefFrameImpl` receiver, all browser-side frame
  enumeration, and the sync IPC. Live preview (BO-13; site-control D-6) is the same snapshot with
  a newer per-browser value, sent as a ~100 B delta on the same interface: one small message
  per coalesced drag frame (§5.4, §6.2).

Registration stays two-level, mirroring Arc (BO-23a/b): per-host-pattern registration on the
Profile covers future navigations; per-tab apply covers live preview. The registry is the single
source of truth inside the engine; both levels ride the one snapshot (§5.4).

## 5. Engine implementation (fork)

All new code lives in the overlay (§10); hook patches touch only the files named here. Threading
follows CEF's rules: browser-side API on the UI thread, renderer state on the renderer main thread.

### 5.1 Blink: `BoostColorFilter` and the matrix type

New files `third_party/blink/renderer/platform/graphics/boost_color_filter.h/.cc` (overlay, §10.2),
added to the platform graphics sources by the BUILD.gn hook in patch 0401.

```cpp
namespace blink {

// Row-major 4x5 matrix applied to (H, S, L, A, 1), H in turns [0,1).
// Rows produce H', S', L', A'. Wire and storage order is m[0..19], row-major.
struct BoostHslaMatrix {
  float m[20];
  bool IsIdentity() const;  // exact float compare against the identity rows
};

class PLATFORM_EXPORT BoostColorFilter {
 public:
  explicit BoostColorFilter(const BoostHslaMatrix& matrix);
  // CPU remap of one unpremultiplied sRGB color. LRU-cached by quantized color.
  SkColor4f RemapColor(const SkColor4f& color);
  // Mirrors DarkModeFilter::ApplyToFlagsIfNeeded: nullopt if the flags have a
  // shader or the color is fully transparent; otherwise a copy with the color
  // rewritten. Never attaches a cc::ColorFilter.
  std::optional<cc::PaintFlags> ApplyToFlags(const cc::PaintFlags& flags);
  const BoostHslaMatrix& matrix() const { return matrix_; }
 private:
  BoostHslaMatrix matrix_;
  base::HashingLRUCache<uint32_t, SkColor4f> cache_;  // key: SkColor (ARGB8)
};
}
```

Rules:

- HSL conversion is implemented in this file on float channels (standard sRGB↔HSL formulas; the
  integer helpers in `ui/gfx/color_utils.h` lose the sub-8-bit precision that `SkColor4f` carries
  from CSS Color 4 values). Convert **in the color's own components as stored** — `PaintFlags`
  colors reaching this point are sRGB `SkColor4f` (implementer checkpoint in E1: verify with a
  `color(display-p3 …)` probe; if components arrive outside [0,1], clamp before conversion and
  record the deviation in the PR — v1 accepts gamut clamping, §13 Q-B16).
- Cache key is the quantized `SkColor` (`color.toSkColor()`), capacity 256, exactly the
  `DarkModeInvertedColorCache` shape (`dark_mode_filter.cc`, `HashingLRUCache<SkColor, SkColor4f>`).
  The remap is computed **from the quantized key color**, not from the incoming float (review
  m2): output then depends only on the key, never on paint order. Sub-8-bit CSS colors quantize
  before remapping, like DarkMode's cache. A new matrix makes a new filter object, so no cache
  invalidation logic exists.
- `IsIdentity()` matrices are never turned into a filter object: `LocalFrameView` stores null.
  This is what makes "Boost exists but its color is identity" cost the same as "no Boost".

### 5.2 Blink: per-frame state and the paint hook

Per-view state is tri-state (review B2): `enum class BoostColorState { kUnset, kNone, kValue }`.
`kUnset` means "no resolution ran for this frame" (non-http(s) documents, §6.4) and inherits the
enclosing context's filter at paint time; `kNone` is an explicit no-remap resolution; `kValue`
carries the matrix. Resolution (§5.5) always produces `kNone` or `kValue` for http(s) documents,
including the empty-snapshot case.

Hook patch 0401 touches exactly these upstream files:

| File | Change |
|---|---|
| `third_party/blink/renderer/platform/graphics/graphics_context.h` | Add `void SetBoostColorFilter(BoostColorFilter*)` (non-owning), `BoostColorFilter* GetBoostColorFilter() const`, a `ScopedBoostColorFilter` RAII (save/set/restore, modeled on `ScopedAutoDarkModeState`), and member `BoostColorFilter* boost_color_filter_ = nullptr;` next to `dark_mode_filter_` |
| `third_party/blink/renderer/platform/graphics/graphics_context.cc` | In `DarkModeColor()`: after the dark-mode branch, `if (auto* f = context.GetBoostColorFilter()) return f->RemapColor(color);` (order rule §3.4.1 — apply to the possibly-inverted color). In `DarkModeFlags` ctor: after the dark-mode branch, if a boost filter exists, run `ApplyToFlags` on the (possibly dark-rewritten) flags. In `CopyConfigFrom` (:232-237): copy `boost_color_filter_` (SVG markers record through `PaintRecordBuilder(paint_info.context)`, `svg_shape_painter.cc:314` — review M1). Rename no helper; keep each hunk small |
| `third_party/blink/renderer/platform/graphics/gradient.h/.cc` | §5.3 |
| `third_party/blink/renderer/core/frame/local_frame_view.h/.cc` | Add `void SetBoostColorState(BoostColorState, std::optional<BoostHslaMatrix>)`, members `boost_state_`, `std::unique_ptr<BoostColorFilter> boost_color_filter_;`, `std::optional<BoostHslaMatrix> boost_matrix_;`, and `uint64_t boost_generation_ = 0;` (snapshot generation that produced the state). Paint stamps for the §5.4 readback: `std::optional<BoostPaintStamp> boost_first_paint_` (set once, at this view's first `PaintFrame`) and `BoostPaintStamp boost_last_paint_` (updated at every `PaintFrame`), each `{generation, state}` and `mutable`, because `PaintFrame` is `const` (`:4454`, review r2 N12); that is two small stores per frame paint, not per draw op, so recorded ops do not change. A cross-document navigation makes a new `LocalFrameView`, so "first" means the document's first paint. In `PaintFrame` (:4454): wrap the body in the scoped swap — `kUnset` leaves the context as-is, `kNone` installs nullptr, `kValue` installs the filter — except while printing, when it installs nothing (§3.4 rule 7). Do **not** touch the :3292 construction site (the context starts null, B2). `SetBoostColorState` compares (state, matrix) exactly, no-ops when equal (generation still updates), otherwise replaces the filter and invalidates paint (§6.2). Identity matrix collapses to `kNone`. Also the `DocumentBackgroundColor` branch (§5.3b) |
| `third_party/blink/renderer/core/paint/box_painter_base.cc` | `ResolveShadowColor` boost branch (§5.3b) |
| `third_party/blink/renderer/core/paint/text_painter.cc` | `CreateDrawLooper` text-shadow branch (§5.3b) |
| `third_party/blink/renderer/core/paint/decoration_line_painter.cc` | Wavy-decoration branch (§5.3b; optional — may be stated as a gap instead, one line either way) |
| `third_party/blink/renderer/core/paint/svg_object_painter.{h,cc}`, `svg_shape_painter.cc`, `svg_container_painter.cc`, and `third_party/blink/renderer/core/layout/svg/layout_svg_resource_gradient.cc` (plus `text_painter.cc` and the `AutoDarkMode` field in `graphics_context.h`, both listed above) | SVG gradient threading (§5.3, review r2 N4) |
| `third_party/blink/renderer/platform/BUILD.gn` (or the graphics sources list it includes) | Add the two new overlay sources. Implementer checkpoint: find where `dark_mode_filter.cc` is listed and add beside it |

No `web_local_frame_impl.{h,cc}` change: the renderer agent reaches the view through one overlay
glue function (review m8, §5.5), keeping Blink-core includes out of the agent, as CEF concentrates
them in `cef/libcef/renderer/blink_glue.cc`. Nothing in `cc/`, `components/viz/`, or the GPU
process changes. Nothing in `ComputedStyle` or `StyleEngine` changes.

### 5.3 Gradients

`Gradient` rewrites stop colors at shader-build time when dark mode is on: member
`is_dark_mode_enabled_`, set from `ImageDrawOptions.apply_dark_mode` (`gradient.cc:350`), stops
rewritten at :334. Boost mirrors it, with review m1's corrections:

- `Gradient` **borrows** the frame's filter; it never owns one (heavy-2 has ~500 gradients — no
  per-gradient filter or LRU). It keeps **no pointer**: beside `is_dark_mode_enabled_` it stores
  the 20 floats of the matrix it last applied, and it uses the borrowed pointer only inside
  `ApplyToFlags`. A `Gradient` shared through `StyleSheetContents` can outlive the
  `LocalFrameView` that owns the filter (review r2 N12).
- `ImageDrawOptions` (`graphics_context.h:99`) gains `BoostColorFilter* boost_filter = nullptr`
  (the borrowed pointer, not the matrix). Constructions that build `ImageDrawOptions` from an
  `AutoDarkMode` also pass the current context's filter. Implementer checkpoint: enumerate the
  `ImageDrawOptions(` constructions in `graphics_context.cc` (three `DrawImage` variants at
  ~537/577/653), in `platform/graphics/image.cc`, and — the one a first pass misses —
  `LayoutSVGResourceGradient::ApplyShader`, which builds its own options with no context
  (`layout_svg_resource_gradient.cc:165-170`). `SVGObjectPainter` has no context either: its
  constructor takes `(LayoutObject, SvgContextPaints*)` (`svg_object_painter.h:32-46`), and it
  builds the `AutoDarkMode` from style (`svg_object_painter.cc:38-44`). Thread it this way
  (review r2 N4): add a `const BoostColorFilter*` argument to the `SVGObjectPainter`
  constructor; the callers that have a context pass `paint_info.context.GetBoostColorFilter()`
  (`svg_shape_painter.cc:119`, `:147`, `:322`; `text_painter.cc:252`;
  `svg_container_painter.cc:122`); the painter copies the pointer into a new `AutoDarkMode`
  field, which reaches `ApplyShader` with no change to that virtual's signature
  (`layout_svg_resource_paint_server.h:36-41`). The fresh-builder callers
  (`svg_fe_image.cc:243`, `layout_svg_resource_pattern.cc:249`,
  `layout_svg_resource_masker.cc:65`) pass null by design. The gradient path is the only consumer of the new field;
  image consumers must ignore it. Do not set it during mask paint (§3.4 rule 6).
- **Compare by value, not pointer, for shader reuse:** CSS gradient images can be shared across
  frames through shared `StyleSheetContents`, and two frames can hold different filter objects
  with equal matrices. In `ApplyToFlags`, rebuild `cached_shader_` when the incoming filter's
  matrix differs by value from the last-applied 20 floats.
- **Subdivide stops (m1):** per-stop remap + sRGB interpolation drifts from per-pixel remap
  (black→white midpoint `#8F7D96` vs `#935BB9`, ΔE00 17.2 in the review's fit). When a filter is
  set, subdivide each stop interval into 8 stops interpolated in the gradient's own interpolation
  space before remapping each stop color. 8 is a token (`kBoostGradientSubdivisions`); the
  black→white fixture gradient is gated at its midpoint (G10).
- Order: dark inversion first, then boost (§3.4 rule 1), same as solid colors.

Whether Arc remaps gradient stops at all is unobserved (guess: yes, BO-23f; capture C-4R-4). The
per-stop choice is one branch; if the capture refutes it, delete the branch and gradients behave
like images.

### 5.3b Colors that bypass both choke points (review M1)

Each row was verified in source during review r1. "Branch" means: after the existing dark-mode
handling at that site (if any), apply `context.GetBoostColorFilter()` when non-null.

| Path | Site | v1 rule |
|---|---|---|
| box-shadow | Color goes into a `DrawLooper` that `DarkModeFlags` never rewrites; dark mode patches it in `ResolveShadowColor` (`box_painter_base.cc:251`) | One boost branch in `ResolveShadowColor` |
| text-shadow | `CreateDrawLooper` (`text_painter.cc:83-104`); dark mode misses it too | Remap the shadow color where the looper is built (the painter has the context) |
| Document background (compositor + browser) | `LocalFrameView::DocumentBackgroundColor` has its own dark branch (`local_frame_view.cc:2054`, dark at ~2085-2092); feeds `LayerTreeHost::set_background_color` and the browser's background-color change (`web_frame_widget_impl.cc:1863-1869`). Without a hook, Mac rubber-band gutters and the pre-first-frame fill stay white on a tinted page | Remap the **returned** value, after the blend (`:2093-2095`, both return paths), when the view's effective filter is non-null — not `doc_bg` alone (review r2 N3). A page with no CSS background has a transparent `doc_bg`, which rule 4 passes through, so the function returns the base white (`BaseBackgroundColor()`, `:2059`), while `ViewPainter` fills that same base through `FillRect` and the `DarkModeColor` path (`view_painter.cc:365-369`) and the canvas tints. Effective filter: the view's own for `kValue`; none for `kNone` and for a `kUnset` main frame. Gated deterministically via the browser-side background readback on a page with and a page without a CSS background (G10), not by screenshotting a gutter |
| SVG markers | `CopyConfigFrom` does not copy the pointer | Copy it (§5.2 table) |
| Wavy decorations (spelling, CSS `wavy`) | Color applied as `ColorFilter::MakeBlend` on shader-carrying flags (`decoration_line_painter.cc:518-519`), so `ApplyToFlags` declines | Remap the color before `MakeBlend`, or state the gap in the PR — one line either way; do not leave it undecided |
| SVG `<pattern>`, `feImage`, `-webkit-box-reflect` | Fresh `PaintRecordBuilder` with no config copy (`layout_svg_resource_pattern.cc:246`, `svg_fe_image.cc:242`, `box_reflection_utils.cc:62`) | **Unremapped in v1, like images** (stated in §6.4). Remapping patterns would also need `pattern_map_` invalidation |
| CSS `filter: drop-shadow()`, SVG `flood-color`/`lighting-color`, `theme-color` | Colors live in `PaintFilter`s or browser UI | **Unremapped in v1** (§6.4) |

The fixture gains swatches for every row above, and C-4R-1 captures them in the same Arc shot (§8).

### 5.4 Browser side: registry, snapshot broadcast, CEF API

Overlay `open/browser/boost_color/` (§10.2):

```cpp
namespace open_engine {

struct BoostColorValue {
  float matrix[20];  // blink::BoostHslaMatrix layout. No scheme field (dropped, §5.6).
};

// One per content::BrowserContext (Profile), stored as BrowserContext user data.
// UI thread only. Every mutation bumps generation_ and broadcasts a full snapshot.
class BoostColorRegistry : public base::SupportsUserData::Data {
 public:
  static BoostColorRegistry* Get(content::BrowserContext*);
  // path_prefix empty = whole host. Refused (logged, no crash) past the limits below.
  void Register(std::string host_pattern, std::string path_prefix, BoostColorValue value);
  void Unregister(const std::string& host_pattern, const std::string& path_prefix);
  // Also attaches a WebContentsObserver; WebContentsDestroyed clears the entry.
  // Sends a per-browser delta, not a full snapshot (review r2 N7).
  void SetPerBrowserValue(int browser_id, content::WebContents* contents,
                          std::optional<BoostColorValue> value);
  static BoostColorRegistry* GetIfExists(content::BrowserContext*);  // launch send only
  // Launch send: skips an empty snapshot unless paint reports are on (§4).
  void SendSnapshotTo(content::RenderProcessHost* host);
  uint64_t generation() const { return generation_; }
  uint64_t snapshots_sent() const { return snapshots_sent_; }  // G8 zero-cost readback
 private:
  void Broadcast();  // change send: always, to every live process of this context
  uint64_t generation_ = 0;
  uint64_t snapshots_sent_ = 0;
  // patterns_ keyed by (host_pattern, path_prefix); per_browser_ by CEF browser id.
};
}
```

- **Pattern grammar (Open choice).** A key is a host pattern plus an optional path prefix
  (review m4 — the resolver has the full URL, so path-scoped Boosts no longer need the per-tab
  path or its first-paint flash). Host: exact (`example.com`) or suffix (`*.example.com`,
  matching the host and any subdomain). Path prefix, when present, matches
  `SiteMatch.matches` semantics (`Boost.swift:43-47`: equal, or prefixed with a `/` boundary).
  Scheme and port are not part of the key; only `http`/`https` frame URLs can match. Matching
  runs **renderer-side** in the snapshot resolver (§5.5) — one matcher implementation in the
  overlay shared header, used by no browser-side code except validation.
- **Limits (review checklist §1).** At most 1024 pattern entries and 256 per-browser entries per
  registry; host pattern ≤ 253 chars, path prefix ≤ 1024 chars. Over-limit registrations are
  refused and logged. Matrix floats are validated at the CEF API boundary (§5.4 CEF API): every
  value finite and |m| ≤ 16, else the call is refused and logged (review m3; the Swift builder
  emits |m| ≤ ~2).
- **Broadcast.** `Broadcast()` iterates `content::RenderProcessHost::AllHostsIterator`, keeps
  hosts whose `GetBrowserContext()` is this registry's context, and sends via
  `host->GetChannel()->GetRemoteAssociatedInterface(...)` (the `RendererUpdater` shape,
  `renderer_updater.cc:176-185`; a null channel is skipped — that process gets the snapshot at
  its launch send instead). No remote is cached across calls, so dead processes need no pruning.
  Implementer checkpoint: confirm a CEF renderer process serves exactly one `BrowserContext`
  (Chromium's model); if a process can serve two Open contexts, key the snapshot by context id
  in the payload and resolve per frame's context — do not ship a build where one Profile's
  snapshot reaches another's frames.
- **Launch send.** Hook in CEF's existing `RenderProcessWillLaunch` override
  (`chrome_content_browser_client_cef.cc:311`): after the base call, an overlay entry point
  does `BoostColorRegistry::GetIfExists(host->GetBrowserContext())` and, if a registry exists,
  `SendSnapshotTo(host)`. A launch in a context that never registered anything creates no
  registry (review r2 N12). Because the interface is channel-associated, this
  message is ordered before any frame commit on that channel.
- **Per-tab apply** is `SetPerBrowserValue`: same interface and FIFO, no second pipe, but a
  **delta** (review r2 N7). It bumps the generation and sends
  `SetBoostColorBrowserValue(generation, browser_id, matrix?)` (~100 B) to every live process
  of the context — not only the processes that host that browser today, because an existing
  process can later receive one of its frames. The renderer patches its snapshot copy and
  re-resolves only that browser's frames. Pattern changes still send the full snapshot, and a
  launch snapshot carries the current per-browser values. A 60 Hz drag therefore costs one
  ~100 B message per renderer per frame instead of the full pattern table.
  Precedence is resolved renderer-side: per-browser value beats pattern value for every frame of
  that browser (§5.5). The registry clears the entry when that browser's `WebContents` is
  destroyed (its own `content::WebContentsObserver`, overlay code, no CEF hook), so a reused
  browser id never inherits a value.
- **Paint readback (for G5/G6/G7, review M5).** The browser must be able to prove which
  generation and state a document's first paint used, and when a changed value reached the
  screen, without polling screenshots. This is on only when the browser process has the
  switch `--open-boost-color-paint-reports`; the registry reads it once and sets
  `paint_reports` in every snapshot it sends. With the bit on, the frame agent asks for a
  presentation callback after each resolution (document start, a changed snapshot, a BFCache
  restore) through `WebFrameWidget::NotifyPresentationTime` (`web_frame_widget.h:171`). In the
  callback it reads the view's paint stamps (§5.2) through the blink glue and sends one report:
  frame host, renderer pid (`base::GetCurrentProcId()`), first-paint `{generation, state}`,
  last-paint `{generation, state}`, the presentation `base::TimeTicks`, and
  `presentation_failed` (`FrameTimingDetails.presentation_feedback.failed()`). The callback also
  runs, with a failure timestamp, when no frame was presented (`ReportTimeSwapPromise::DidNotSwap`
  on `COMMIT_NO_UPDATE` / `SWAP_FAILS`, `web_frame_widget_impl.cc:3975-4002`; review r2 N6): on
  a failure the agent re-arms, and a failure never counts toward the tries below. If the view has
  no paint stamp yet, it asks again, at most 10 times, then sends a "never painted" report.
  Asking does not request a frame (`QueueSwapPromise`, `cc/trees/layer_tree_host.cc:361-365`),
  so the loop relies on frames being produced; the e2e fixture pages carry a small CSS
  animation so frames keep coming (product use never turns reports on). The
  callback holds a weak pointer to the agent, so a frame destroyed first sends nothing. The
  report travels over the existing CEF process-message path (`CefFrame::SendProcessMessage`,
  name `OpenBoostColorPaint`); OpenEngine keeps the latest report per frame and exposes them to
  automation (§9.2). This is a verification channel only. No product behavior reads it, it
  carries no page content, and without the switch it costs nothing (no callback, no message).

CEF public API: a new overlay header `cef/include/cef_boost_color.h` with **global functions
only**, in the `CefSetOSModalLoop` style (a global function guarded by `#if CEF_API_ADDED(…)`,
`cef/include/cef_app.h:142`). Every function is guarded with
`CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`; the version manager regenerates the C API and it
is never hand-edited (`docs/engine-patches.md` storage rules). Global functions keep every
existing CEF header and implementation class untouched. That matters for two reasons. First,
`CefBrowser` is also implemented in the renderer (`CefBrowserImpl`,
`cef/libcef/renderer/browser_impl.h:35`), so a browser-only method does not belong there.
Second, `cef/libcef/browser/browser_host_base.h` already belongs to patch 0302, and two logical
patches must never share a path (`docs/engine-fork.md:119`).

```cpp
#if CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)
// UI thread. path_prefix may be empty (whole host). matrix must hold exactly 20
// finite values with |m| <= 16. Returns false on invalid input, a malformed
// pattern, or a full registry.
/*--cef(optional_param=path_prefix)--*/
bool CefRegisterBoostColorFilter(CefRefPtr<CefRequestContext> context,
                                 const CefString& host_pattern,
                                 const CefString& path_prefix,
                                 const std::vector<float>& matrix);
/*--cef(optional_param=path_prefix)--*/
void CefUnregisterBoostColorFilter(CefRefPtr<CefRequestContext> context,
                                   const CefString& host_pattern,
                                   const CefString& path_prefix);
// Per-tab value for every frame of this browser, regardless of pattern.
// An empty matrix clears it (frames fall back to pattern resolution).
/*--cef()--*/
bool CefApplyBoostColorFilter(CefRefPtr<CefBrowser> browser,
                              const std::vector<float>& matrix);
// Verification readback (§11): {"generation", "snapshots_sent"} for the context,
// plus "page_background" (ARGB int; absent when the page reported none) from
// content::WebContents::GetBackgroundColor() (web_contents.h:686) when a
// browser is given.
/*--cef(optional_param=browser)--*/
CefRefPtr<CefDictionaryValue> CefGetBoostColorDebugState(
    CefRefPtr<CefRequestContext> context, CefRefPtr<CefBrowser> browser);
#endif
```

Implementer checkpoint: the translator already accepts vectors of simple types
(`cef_task_manager.h:52`, `std::vector<int64_t>`; `float` is in `_simpletypes`,
`cef/tools/cef_parser.py:559`). If it refuses `std::vector<float>` as an input parameter, pass a
`CefRefPtr<CefBinaryValue>` of exactly 80 bytes (20 little-endian float32) instead. Do not use a
raw `float[20]`: the translator has no fixed-array type. No scheme function ships in v1 (§5.6).
The functions live in `open/browser/boost_color/boost_color_api.cc`. They reach the
`BrowserContext` through `CefRequestContextImpl::GetBrowserContext()`
(`request_context_impl.h:75`) and the `WebContents` through `CefBrowserHostBase::FromBrowser`
(`browser_host_base.h:139`, `GetWebContents()` at :406), both internal to `libcef_static`. A
request context that has not initialized yet has no browser context: the call returns false,
and OpenEngine queues registrations until
`CefRequestContextHandler::OnRequestContextInitialized`. The only upstream hunk on the browser
side is the launch send (§10.1).

Mojom (overlay, `open/boost_color/mojom/boost_color.mojom`) — one channel-associated interface,
browser → renderer only:

```mojom
module open_engine.mojom;
struct BoostColorPatternEntry {
  string host_pattern;
  string path_prefix;  // empty = whole host
  array<float, 20> matrix;
};
struct BoostColorBrowserEntry { int32 browser_id; array<float, 20> matrix; };
struct BoostColorSnapshot {
  uint64 generation;
  bool paint_reports;  // verification switch only (§5.4 readback); false in product use
  array<BoostColorPatternEntry> patterns;
  array<BoostColorBrowserEntry> browsers;
};
interface BoostColorConfiguration {
  SetBoostColorSnapshot(BoostColorSnapshot snapshot);
  // Per-tab live apply (review r2 N7): null matrix clears that browser's value.
  SetBoostColorBrowserValue(uint64 generation, int32 browser_id,
                            array<float, 20>? matrix);
};
```

### 5.5 Renderer side: thread observer, snapshot store, frame agent

Overlay `open/renderer/boost_color/`:

```cpp
namespace open_engine {

// One per renderer process. Owns the snapshot; created in RenderThreadStarted.
class BoostColorThreadObserver : public content::RenderThreadObserver,
                                 public mojom::BoostColorConfiguration {
 public:
  // RegisterMojoInterfaces: bind BoostColorConfiguration on the associated registry.
  // SetBoostColorSnapshot: store, then re-resolve every live frame agent.
  static BoostColorThreadObserver* Get();  // process singleton, may be null pre-init
  // Resolve one frame: per-browser value wins, else pattern match on the frame URL.
  ResolvedBoostColor Resolve(int browser_id, const GURL& url) const;
};

// One per content::RenderFrame. Deletes itself (RenderFrameObserver contract).
class BoostColorFrameAgent : public content::RenderFrameObserver {
 public:
  explicit BoostColorFrameAgent(content::RenderFrame* render_frame);
  void ResolveNow();  // from snapshot; http(s) only; sets tri-state via blink glue;
                      // with paint_reports on, arms the §5.4 presentation callback
  // RenderFrameObserver (render_frame_observer.h):
  void DidCreateDocumentElement() override;  // :129, ResolveNow (document start)
  void DidSetPageLifecycleState(blink::BFCacheStateChange change) override;
      // :121, ResolveNow on kRestoredFromBFCache only
  void OnDestruct() override;
};
}
```

- **Creation hooks.** The thread observer is created in
  `ChromeContentRendererClientCef::RenderThreadStarted`
  (`cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc:30`):
  `content::RenderThread::Get()->AddObserver(...)` with process-lifetime ownership (leaked
  singleton, like other thread observers — state the ownership in the header). The frame agent
  is created in the same file's `RenderFrameCreated` (:42), after the `CefRenderFrameObserver`:
  `new open_engine::BoostColorFrameAgent(render_frame);  // Deletes itself.`
  Both lines go into the one owner patch of that file. The ad-block agent hook uses the same
  file, so the file has one owner patch shared by both features (§10.1).
- **Resolution.** At `DidCreateDocumentElement` the agent reads its frame's committed URL from
  the `RenderFrame` itself and stores it as `document_start_url_`. Every later re-resolution of
  that document (snapshot update, delta, BFCache restore) uses the stored URL, never the current
  `Document::Url()`, so `pushState` or a hash change cannot flip a path-scoped Boost at the next
  unrelated broadcast (review r2 N8). It gets its CEF browser id from
  `CefRenderManager::Get()->GetBrowserForView(render_frame->GetWebView())`
  (`cef/libcef/renderer/render_manager.h:65`) → `CefBrowserImpl::browser_id()`
  (`browser_impl.h:81`). If no CEF browser exists for the view, per-browser values do not
  apply and the frame resolves by pattern only. Non-http(s) documents do not resolve:
  the view stays `kUnset` and inherits at paint (about:blank / srcdoc children, §6.4). Every
  http(s) document resolves to `kNone` or `kValue` — including with an empty snapshot, which is
  what makes an unboosted child under a boosted parent paint unremapped (G5).
- **Snapshot updates** re-resolve every live agent (the observer keeps a registry of agents by
  routing id and by CEF browser id); a per-browser delta re-resolves only that browser's agents. Equal results no-op in `LocalFrameView` (§5.2), so a drag broadcast costs one
  compare per frame plus repaints only where the value changed.
- **Blink entry (review m8).** The agent never includes Blink core headers. One overlay glue
  pair, `open/renderer/boost_color/boost_color_blink_glue.{h,cc}`, does:
  `WebLocalFrameImpl::FromFrame(frame)->GetFrame()->View()->SetBoostColorState(...)` (checkpoint:
  exact accessor names; the glue file is the only place allowed to include
  `web_local_frame_impl.h`, mirroring `cef/libcef/renderer/blink_glue.cc`).
- **Generation stamp.** `ResolveNow` passes the snapshot generation into
  `SetBoostColorState`; `PaintFrame` copies `{generation, state}` into the view's paint stamps
  (§5.2), and the presentation callback reports them (§5.4 readback). `RenderFrameObserver` has
  no first-paint hook in 156, which is why the stamp lives in the view. A document with no report
  is a failure in the e2e, not a skip.
- **Prerender.** No activation hook is needed. Blink activates a prerendered page through
  `WebViewImpl::ActivatePrerenderedPage` (`web_view_impl.cc:3736`), which does not call
  `DidSetPageLifecycleState`. The prerendered frame is a live agent, so every snapshot update
  has already re-resolved it (m5).

### 5.6 Color scheme channel: dropped from v1 (lead ruling, review r1 M4)

Arc's `registerColorScheme:` carries one integer (BO-23a); "forced light/dark appearance" is a
strong guess about it (BO-23c), never proven. **v1 ships no scheme channel**: no v1 editor
control sets an appearance (the captured editor has none), so any mechanism would be dead code
with a maintenance cost. Removed everywhere: CEF API, mojom, OpenEngine, OpenKit, e2e (old G10
scheme gate deleted; G10 is now coverage probes).

Why not the originally planned mechanism, for the record: writing
`Page` Settings from the renderer does not stick — `WebViewImpl::ApplyWebPreferences` rewrites
`settings->SetPreferredColorScheme(prefs.preferred_color_scheme)` on every preferences update
(`web_view_impl.cc:1933`), and subframes do not read Settings at all
(`style_engine.cc:4473-4477` uses `owner_preferred_color_scheme_`). If a post-v1 control needs
this, build it browser-side on the per-tab WebContents preferences path — CEF's existing
`OverrideWebPreferences` override (`chrome_content_browser_client_cef.cc:438`) plus
`WebContents::OnWebPreferencesChanged()` — which survives prefs updates and reaches every
process with no Blink patch. §13 Q-B7/Q-B15 record the ruling; C-4R-9 stays on the capture list
as a fact-finding item only.

## 6. Lifetime rules (normative)

### 6.1 State ownership summary

| State | Owner | Key | Lifetime |
|---|---|---|---|
| Pattern registrations | `BoostColorRegistry` (browser) | (host pattern, path prefix), per `BrowserContext` | Until unregister or context teardown. Not persisted by the engine; the App re-registers from `BoostStore` at context creation (§9.3) |
| Per-tab applied value | `BoostColorRegistry` (browser) | CEF browser identifier | Until cleared or the browser closes (entry cleared on browser-host close, §5.4) |
| Process snapshot | `BoostColorThreadObserver` (renderer) | renderer process | Replaced wholesale per broadcast; initial send at process launch. Dies with the process |
| Per-frame resolution | `BoostColorFrameAgent` + `LocalFrameView` tri-state (renderer) | `RenderFrame` | Resolved locally at each document start and on every snapshot update; dies with the frame |

### 6.2 Invalidation on change

`LocalFrameView::SetBoostColorState` with a changed (state, matrix) does exactly:

1. Replace `boost_color_filter_` (null unless `kValue` with a non-identity matrix).
2. `GetLayoutView()->InvalidatePaintForViewAndDescendants()` — the paint half of
   `StyleEngine::PlatformColorsChanged()` (`style_engine.cc:1392`). No style recalc: Boost colors
   are not in `ComputedStyle`.
3. Ensure a frame is scheduled (the invalidation already does this through the normal paint
   lifecycle; do not add a second scheduler call unless G7 shows a missed frame).

One full repaint per changed frame is the accepted cost (same as a forced-dark toggle, BO-23g
guess for Arc). A snapshot broadcast re-resolves every frame in the process, but only frames
whose resolution changed repaint (equal values no-op, §5.2). During an editor drag at ≤ 60 Hz
(site-control D-6), each drag frame sends one ~100 B per-browser delta to every live process of
the Profile, and only that browser's frames re-resolve (§5.4); the LRU (256 entries) is
rebuilt per filter object, so drag cost is bounded by distinct colors, not pixels. If G8's drag
case misses its budget, the fix is coalescing in the App (drop to 30 Hz, the R-3 precedent), not
caching in the engine.

### 6.3 Event table

| Event | Rule |
|---|---|
| Same-document navigation (pushState, hash) | No re-resolution. Resolution is per document-start URL; an SPA route change keeps it, including for path-scoped patterns (Arc unobserved). Later re-resolutions of the same document also use the stored document-start URL (§5.5, review r2 N8) |
| Cross-document navigation, same process | The agent resolves locally at `DidCreateDocumentElement` from the process snapshot — document-start, before first paint, no IPC. Channel FIFO guarantees the snapshot includes every change sent before this document's commit (§4) |
| New subframe (any origin) | Its agent resolves its own URL at its document start. Per-browser value (if any) wins; else pattern+path match on the subframe's own URL. Non-http(s) children (about:blank, srcdoc) do not resolve and inherit (§6.4) |
| Renderer process swap (cross-site navigation, crash + reload) | The new process received the current snapshot at `RenderProcessWillLaunch`, before any commit on its channel. No replay, no browser-side frame tracking |
| Prerendered page activation (review m5) | The prerendered frame's agent resolved at its document start and re-resolves on every snapshot update like any live frame, so at activation it already holds the latest value. Activation does not fire `DidSetPageLifecycleState` (`web_view_impl.cc:3736`), and no extra step is needed (§5.5). If CEF never prerenders in Open's configuration, the row is inert |
| Back/forward, incl. BFCache restore | While frozen, snapshot updates still re-resolve the frame (it is a live agent; the snapshot arrives on the thread observer, not on a frozen frame queue). On restore Blink calls `DidSetPageLifecycleState(kRestoredFromBFCache)` on every local frame (`web_view_impl.cc:2742-2752`), and the agent re-resolves once more (normally an equal-value no-op). A Boost changed while cached therefore takes effect before the restored page paints. G9 proves the restore really came from BFCache |
| Tab sleep / discard (shell unloads the page) | The `OEWebContent` closes; the per-browser entry clears. On reload the pattern resolution reapplies. Chromium never discards hosted tabs itself (P1, patch 0303) |
| Peek pages | Peek pages are Alloy `OEWebContent`s in a Profile context (P1 shell rules). Their renderer processes get the same snapshot — the Site Control *panel* is unavailable in Peek (site-control non-goals), but an existing Boost still applies. Arc parity unobserved (guess: applies; capture C-4R-10) |
| Little Open pages | Same rule: any live page in a context with registrations remaps |
| Boost disabled, deleted, or color reset while the page shows | App unregisters (or clears the per-browser value) → one broadcast → affected frames re-resolve to `kNone` → repaint with original colors, no reload (G4). A frame mid-navigation resolves its new document from the latest snapshot; FIFO ordering makes stale application impossible |
| Global Boosts switch off (`open.advanced.enableBoosts`, site-control D-5) | App unregisters every pattern of the Profile and clears every per-tab value. Engine sees ordinary unregisters |
| Profile (context) teardown, incognito window close | Registry dies with the `BrowserContext`. Ephemeral contexts get their own registry; Boost editing is disabled in incognito but existing Boosts apply (site-control D-10), so the App registers the same patterns on the ephemeral context |
| Space switch, tab switch, window focus | No engine traffic. State is per frame, already applied |
| Two Boosts match one host | One value per pattern by construction. Which Boost wins is the planner's existing rule (last non-identity in matcher order, `InjectionPlan.swift:51`); the App registers only the winning value (§9.3) |

### 6.4 Exclusions and inheritance (never resolve)

Non-http(s) documents never resolve; their view stays `kUnset`:

- **Main-frame** non-http(s) (`about:`, `chrome://`, `devtools://`, `chrome-extension://`,
  `view-source:`): the paint-tree context starts null, so `kUnset` paints unremapped. Extension
  popups are `chrome-extension://` documents and excluded (Open choice; §13 Q-B9).
- **Child-frame** non-http(s) (`about:blank`, `srcdoc`): `kUnset` **inherits the enclosing
  frame's filter** at paint (Open choice; Arc unobserved — capture C-4R-5 addendum). This is the
  only inheritance in the design; every http(s) frame resolves explicitly to `kNone` or `kValue`,
  so inheritance can never leak a matrix across origins.
- Internal error pages commit with the failed http(s) URL and therefore resolve and remap like
  the target page (accepted in v1; implementer checkpoint: skip if `DidFailProvisionalLoad`
  makes it cheap — §13 Q-B14).
- Unremapped by construction or by statement in v1: the PDF viewer's plugin surface and its
  internal-page chrome; print output (`PaintFrame` skips the install while printing, §3.4
  rule 7; paint preview and drag images do remap); SVG `<pattern>`, `feImage`,
  `-webkit-box-reflect`, CSS `filter: drop-shadow()`, SVG `flood-color`/`lighting-color`,
  `theme-color` (§5.3b); native form controls and Mac scrollbars (§3.2 M2 row); DevTools,
  validation, and frame-color overlays (they paint outside `PaintFrame`, §3.1).

## 7. The math (normative for Step 4R v1)

### 7.1 Matrix semantics

For each painted solid color, in unpremultiplied sRGB float:

```text
(H, S, L) = RGBtoHSL(r, g, b)          // H in turns [0,1); S, L in [0,1]; grey (S=0) has H := 0
[H']       [m0  m1  m2  m3  m4 ] [H]
[S']   =   [m5  m6  m7  m8  m9 ] [S]
[L']       [m10 m11 m12 m13 m14] [L]
[A']       [m15 m16 m17 m18 m19] [A]
                                  [1]
H' := fract(H')                        // wrap into [0,1), also for negative results
S' := clamp(S', 0, 1);  L' := clamp(L', 0, 1);  A' := clamp(A', 0, 1)
(r', g', b') = HSLtoRGB(H', S', L')
```

This is BO-23e's "one consistent reading" made normative (it is a guess about Arc's internal
layout; Open's own wire order does not need Arc's). The identity matrix is
`H'=H, S'=S, L'=L, A'=A`. `BoostColorFilter::RemapColor` implements exactly this; nothing else in
the engine knows what the floats mean.

### 7.2 Building the matrix in Swift (BO-23 rows)

Inputs are the stored scheme fields (#103's `BoostColorWheel` plus the advanced sliders; field
names below are the BO-17 stored names with the #103 mapping in site-control §4.4.2):
`primaryHueDegrees` Hp (= stored `hue` θ), `primarySaturation` ρ (= stored `intensity` t),
`secondaryHueOffset` Δ (fixed +45° in the captured editor; secondary hue Hs = Hp + Δ),
`invertLightness`, and sliders Contrast / Brightness / Original Saturation at 0…100, 50 neutral
(site-control §4.5). `baseHue` (h0) is **not** an input to the remap — it existed only for the
filter runtime's hue-rotate (§9.4 migration).

The builder runs in two stages and multiplies them into one matrix (review M3: no jump at small
ρ, invert-only Boosts do not recolor). All angles in turns (/360).

**Stage A — lightness/saturation controls (ρ-independent, always applied).** This is what
invert-only and slider-only Boosts get: hues and (at neutral saturation) saturations pass through.

```text
H' = H
S' = satMul · S                        // satMul = OriginalSaturation slider / 50  (50 → 1, range 0…2)
L' = aA · L + bA,  or  1 − (aA · L + bA) when invertLightness
     aA = 0.5 + Contrast/100           // 50 → 1, range 0.5…1.5 (filter-runtime map, §4.4.4)
     bA = (Brightness − 50) / 200      // 50 → 0, range −0.25…0.25
A' = A
```

**Stage B — the knob remap (BO-23 rows), faded in by `w`.** First form the full-strength knob
matrix K:

```text
H' = Hp + Δ·(1 − L)                     // dark end takes the secondary hue, light end the primary
S' = s0 + k·S
L' = a0·L + b0
A' = A
```

then interpolate K toward the identity matrix: `B = I + w·(K − I)`, with
`w = clamp(ρ / rampEnd, 0, 1)`. Matrix interpolation is exact for this affine form: the H row
becomes a lerp between input hue and the knob hue (in turns; the wrap in §7.1 handles the result,
and the lerp path at small `w` is short by construction), `a` and `k` ramp to 1 and `b`, `s0` to 0
as ρ → 0 — the review's ramp requirement, with no threshold anywhere. Final matrix: `M = A ∘ B`
(4×5 affine composition in the builder; the engine still sees one matrix). At ρ = 0, `B = I` and
only Stage A applies: invert-only maps `#FF0000` to its lightness-inverted self, not to a knob
purple. Emit nil only when the final matrix **is** the identity (ρ = 0, no invert, sliders
neutral). There is no ρ < 0.02 snap — that filter-runtime identity rule (site-control §4.4.5)
does not carry over; tell the site-control owner, since their F10 flow asserts stored-value
equality, not runtime identity.

Constants. Measured values are from the single S2-22 sample (ρ ≈ 0.69, so w = 1; sliders
neutral, so Stage A = I — the fit constrains K only). Everything generalizing them is a guess in
one token block (`BoostColorMatrix.Tokens`, §9.1):

| Symbol | v1 value | Basis |
|---|---|---|
| `a0` (K's L slope) | 0.761 | Measured grey fit (BO-23e; re-fit §2) |
| `b0` (K's L offset) | 0.159 | Measured grey fit |
| `s0` at ρ=0.69 | 0.40 | Measured (grey `S′` constant across the ramp) |
| `s0(ρ)` in K | `0.58 · ρ` | **Guess**: linear through the measured point and the origin (capture C-4R-2). Note B's interpolation applies w on top; at ρ ≥ rampEnd the product is as measured |
| `k` in K | 0.5 (normative) | **Guess** (BO-23e fitted ≈ 0.48 at the neutral slider; §7.3's fit check used 0.48 as a sensitivity check — 0.5 is the shipped constant, review m7) |
| `rampEnd` | 0.20 | **Guess**: full knob strength from ρ = 0.2 up; below it the whole knob effect fades linearly to nothing. Settles with C-4R-2's ρ ≈ 0.05 / 0.1 shots |
| `aA`, `bA`, `satMul` maps | Above | **Guess** (Open choice; same slider ranges the filter runtime used, site-control §4.4.4) |
| Composition order `A ∘ B` | Knob first, then sliders/invert | **Guess** (Open choice; unobservable at neutral sliders, which is all S2-22 measured) |

Harness continuity cases (normative, §9.1): the output is a continuous function of ρ — for the
fixture swatch set, the worst per-channel step from 0 to 0.2 is ≤ 8 levels at Δρ = 0.001 and
≤ 5 at Δρ = 0.0005 (bounds measured from this builder during review r1; a true discontinuity
fails the second bound because its step does not shrink with Δρ); invert-only (ρ = 0)
saturated swatches keep their hue within 2° (only L flips). These can fail: they fail on the
pre-review builder (`#FF0000 → #954DC6` at ρ = 0.03 full-strength vs unchanged at 0.019).

One stated defect, the **hue seam** (review r2 N1). The interpolated H row is
`H′ = (1 − w)·H + w·knobHue(L)`. For 0 < w < 1 the input-hue coefficient (1 − w) is not an
integer, so the map is discontinuous on the hue circle at H = 0 ≡ 1, and two reds that look the
same split. With Hp 252°, Δ 45°, rampEnd 0.2 (`.re/boost-remap-plan/seam-r2.py`, local; it
reproduces the review's table):

| ρ | `#FF0008` (H 358.1°) → | `#FF0800` (H 1.9°) → | hue gap |
|---|---|---|---|
| 0.02 | `#F90831` | `#F97D08` | 40° |
| 0.05 | `#F01468` | `#CBF014` | 93° |
| 0.10 | `#E425B0` (magenta) | `#25E45F` (green) | 178° |
| 0.20 | `#9441D2` | `#9441D2` | 0° |

A red at H ≈ 2° sweeps through orange, yellow, green, and cyan on its way to the knob purple,
and every pad drag out of the center crosses this band. Reds are common in page UI (badges,
errors, links). No affine H row avoids this: to respect the wrap, the input-hue coefficient
must be 0 or 1, and a switch between those values is a jump in ρ (the jump review r1 removed).
v1 keeps this form because it is continuous in ρ and keeps invert-only hues. The ρ-continuity
cases cannot see the seam, because the defect is in input hue, not in ρ, so the harness
records it with its own case (§9.1). C-4R-2's small-radius shots include the seam pair to show
which artifact Arc has, and §8 item 4 names the engine terms S4 can choose instead. S4 already
waits for C-4R-2 (§12).

Note what full-strength K implies and accept it: at w = 1 hue never reads the input hue, so a
colored page loses its hues to the knob gradient. That is what the grey evidence proves (hue
reads L when S=0); whether saturated colors keep part of their hue is the §8 question. Do not
soften this speculatively — §8 isolates that change so its capture can be judged alone.

### 7.3 Fit quality of §7.2 against S2-22 (derived, this task)

Re-running the BO-23 fit with §7.2's stage-B matrix K at w = 1, Stage A = identity (knob anchors Hp 253.6°, Hs 297.9°, k = 0.48 as the sensitivity check; normative k = 0.5 predicts the same four values within a level):
predicted `#E6E2F3, #D5C8F8, #56285D, #64306F` against measured `#E4E2F3, #D4C7F8, #56285D,
#632F6F` — every channel within 2 levels (script and output in `.re/boost-remap-plan/`, local).
Two honest caveats:

1. BO-23e reports ΔE00 7.4 for the saturated near-white pair `#FCF5E6 → #D4C7F8` under its fitted
   parameters (which anchor the hue line partly on measured outputs). Under the knob anchors the
   same pair fits within 1 level per channel, and white becomes the outlier instead: measured
   white output hue is 247.1°, but the knob anchor predicts 253.6° (the 6.5° shortfall, BO-23e).
   So one sample set cannot simultaneously prove the anchor law and a missing saturated-color
   term — the residual moves depending on which anchor you trust. §8's captures exist to break
   this tie; v1 ships the knob-anchor reading because the stored fields (BO-17) name knob hues.
2. The knob **fill** hues (253.6° / 297.9°, measured from gradient centers) may differ from the
   stored `primaryHueDegrees` / offset by a few degrees (site-control §4.4.2 derives fill from a
   fitted HSB law). A stored Hp of ≈247° would explain the white outlier with no extra term.

### 7.4 Engine-side numeric rules

- HSL gray edge: when S = 0 the input hue is undefined; define H := 0 before the matrix (the v1
  H row ignores H anyway; §8's hue-preservation term must keep this definition so greys still
  take pure knob hues).
- Hue wrap uses `fract` on the matrix result, so builders may emit m4 > 1 or negative slopes
  freely (Hs = Hp + 45° can exceed 360°).
- The LRU caches the final `SkColor4f` per quantized input color, including alpha. Two alphas of
  one RGB are two entries (alpha is in the `SkColor` key). Capacity 256 (§5.1).
- No dithering, no gamut mapping beyond the HSL clamp. Out-of-range input components (wide-gamut
  CSS) clamp per §5.1 checkpoint.

## 8. Step 2 math (separate, marked; do not build until its captures land)

Step 2 changes **only the Swift matrix builder and, if needed, one extra engine term** — in that
order of preference:

1. **Hue anchor law.** Test, against C-4R-1/C-4R-2 outputs: (a) hue interpolated by input L
   (v1), (b) by output L′, (c) stored hue = knob fill hue − δ with a fitted constant δ. All three
   are builder-only changes (the H row stays affine in L for (a)/(c); for (b) substitute
   L = (L′ − b)/a to keep the row affine — write the substitution in the builder, not the engine).
2. **Saturation-preservation refinement.** v1 already has `S′ = s0 + k·S`. Step 2 fits `k` and
   `s0(ρ)` from the ρ sweep and the saturated swatch grid (C-4R-2, C-4R-3), replacing the guessed
   tokens. Builder-only.
3. **Hue preservation for saturated colors (only if 1–2 leave ΔE00 > 3 on saturated swatches).**
   `H′ = knobHue(L)·(1 − w·S) + H·(w·S)` is **not** affine in (H, S, L) — it has an H·S cross
   term and hue-wrap problems the 4×5 form cannot express. If captures prove it, the engine
   gains one optional post-matrix term, versioned explicitly: `BoostColorValue` gets
   `hue_preserve` w (0 = off, v1 wire value), `RemapColor` applies circular lerp of hue by
   `w·S_in` after the matrix. This is an engine change with its own patch revision and its own
   e2e cases; it is not smuggled into v1 "just in case". BO-17's stored `curves`/`points` fields
   (advanced mapper) are a possible alternative explanation for the residual; if a capture with
   advanced sliders moved shows curve-shaped behavior, stop and take it to the lead before
   building either form.
4. **Small-ρ fade term (review r2 N1; decide with C-4R-2 before S4).** No hue-only fade can be
   continuous on the whole hue circle. It would have to deform the identity map of the circle
   into the constant knob hue, and that is impossible (the identity has winding number 1, a
   constant map has 0). So any fade either splits hues somewhere or passes through low
   saturation. Two engine terms fit; each adds one branch in `RemapColor` after the matrix, the
   builder emits the full-strength knob rows, and the CEF API is EXPERIMENTAL, so the wire can
   grow (numbers from `.re/boost-remap-plan/seam-r2.py`, local):
   - **T1, hue mix** (the review's proposal): `H′ = H_in + m·shortestArc(H_in → H_matrix)`,
     with `m = w` and the S/L rows interpolated as in v1. One float on the wire. It removes the
     red seam but moves the split to the antipode of the knob hue. At ρ 0.1 the knob hue at
     L 0.5 is 274.5°, so `#73FF00` (93°) → `#E43125` (red) and `#66FF00` (96°) → `#25D3E4`
     (cyan), 178° apart.
   - **T2, RGB mix:** `C′ = C_base + m·(C_matrix − C_base)` in sRGB, with `m = w`, where `C_base`
     is Stage A alone and `C_matrix` is the full-strength `A ∘ K`. Stage A rides as a second
     20-float matrix (41 floats on the wire). It is continuous everywhere, in ρ and in input
     color: both ends are continuous maps of RGB, and the mix passes through low saturation at
     any split point. At ρ 0.1 the seam pair → `#C9246A` / `#C92866` and the antipode pair →
     `#83A466` / `#7DA466`. The worst per-channel step over the swatch set at Δρ 0.001 is
     1.1 levels (v1: 6.2, T1: 3.8).
   The capture decides. Reds that split in Arc → keep v1. A smooth sweep along the short arc →
   T1. A greyed midpoint → T2. If C-4R-2 does not settle it, prefer T2, the only form with no
   split. Neither term blocks E1–E5 or S1–S3; each needs its own e2e seam case in S4.

Acceptance for Step 2: the §11 G1/G2 gates keep passing, plus new saturated-swatch gates (ΔE00 ≤ 3
against the Arc capture values) added to the same suite. Until then, G1/G2 use the S2-22 pairs
only, and saturated non-fixture colors have no parity claim.

### Capture list for the user's next Arc session (feeds §8 and §13)

The shell helper ships the fixture page first (§12 S3): `tools/e2e/fixtures/boost-color/fixture.html`
— one static page with labeled swatches: grey ramp (L = 0, .1, …, 1), saturated hues (H = 0, 30, …,
330 at S = 1, L = .25/.5/.75/.92), a semi-transparent black and white overlay pair (50% alpha over a
known background, review m9), a black→white two-stop gradient and a multi-stop gradient, box-shadow
and text-shadow samples, a wavy underline, an SVG gradient icon, inline SVG rects with a marker, the
"unremapped in v1" rows of §5.3b (an SVG `<pattern>` fill, an `feImage`, a `-webkit-box-reflect`
box, a CSS `drop-shadow()`, an `feFlood`), an SVG `<img>`, a raster `<img>`, a luminance-mask sample, a canvas rect, a `<video>` with poster, form
controls (button/input/select/checkbox), selected text, a same-origin iframe, and a `srcdoc` iframe
(both with the grey ramp), the seam pair `#FF0008` / `#FF0800` beside pure `#FF0000`, and a fine
hue strip (120 swatches, 3° apart, S 1, L 0.5) so a hue split shows wherever a knob puts it
(review r2 N1). The fixture also runs a small CSS animation, so frames keep coming for the
§5.4 paint reports. The user opens this exact file in Arc (agents never launch Arc, rule 4)
and screenshots it at:

| # | Capture | Settles |
|---|---|---|
| C-4R-1 | S2-22 repeat on the fixture: primary knob 252°, radius ≈ 0.69 (same as S2 10/0039), sliders neutral. The whole fixture in frame (shadows, wavy, SVG gradient, alpha pair, srcdoc child included), plus one overscroll flick so the rubber-band gutter color shows | Anchor law on 11 greys (Step 2.1); every §5.3b row; alpha blending (m9); gutter/document-background behavior |
| C-4R-2 | ρ sweep: radius ≈ 0.05 / 0.1 / 0.25 / 0.5 / 1.0 at hues 0°, 120°, 240° (grey ramp + saturated row; the 0.05/0.1 radii need a note of the knob position since they are small). At ρ ≈ 0.05 and 0.1, the seam pair, pure `#FF0000`, and the fine hue strip must be in frame | `s0(ρ)`, `rampEnd`, the small-ρ fade law: v1 split, T1, or T2 (§7.2, §8 item 4). **Blocks S4** (§12) |
| C-4R-3 | Saturated grid close-up at ρ ≈ 0.69, hue 252° and hue 0° | `k`, hue preservation (Step 2.2/2.3) |
| C-4R-4 | Gradient bars close-up, any one color set (read the black→white midpoint) | Per-stop vs per-pixel vs skipped (§5.3) |
| C-4R-5 | Inline SVG vs SVG-`<img>` vs `srcdoc` iframe region | §3.4 rules 2–3; srcdoc inheritance (§6.4) |
| C-4R-6 | Canvas rect + its CSS border/background, video poster region | Canvas bitmap untouched; element box paint remapped? |
| C-4R-7 | Invert lightness on, knob untouched (ρ = 0), sliders neutral — grey ramp **and the saturated row** | Stage-A invert form (§7.2) and that invert-only does not recolor. **Blocks S4** (§12) |
| C-4R-8 | Each advanced slider alone at 0 and at 100 (6 shots, grey ramp + one saturated row) | Stage-A slider maps; BO-17 curve suspicion |
| C-4R-9 | Fact-finding only (scheme dropped, §5.6): does any Boost editor control change the page's own light/dark styling? Note the control, if any | Post-v1 scheme existence |
| C-4R-10 | The same boosted page in Peek and in Little Arc | §6.3 Peek/Little Open rows |
| C-4R-11 | Form controls close-up (default button, checkbox, text field) | Whether Arc remaps native-theme paint — decides the M2 follow-up hook (§13 Q-B11). Open v1: unremapped |
| C-4R-12 | Boost on an already dark-mode-native site (site's own dark theme on) | Sanity; no Open change expected |

Each screenshot needs the editor visible (knob position readable) or a note of hue/radius/sliders.
Pixel values are read from the screenshots by an agent afterward, converted from the display ICC
profile to sRGB before any compare (the S2-22 convention, interaction-states §20.15); frames stay
local (rule 5 applies to Arc user data — the fixture is ours, so its screenshots may be committed
redacted of anything personal).

**What blocks what (review r1, recorded):** no capture blocks E1–E5 or S1–S3. **C-4R-7 and the
extended C-4R-2 must land before S4** (switching the App to the remap runtime), because they
decide the small-ρ/invert builder law that every existing Boost will suddenly use. C-4R-1 should
land before G1/G2 are treated as final (S2-22 suffices for the first runs). C-4R-11 decides only
the M2 follow-up.

## 9. Shell side: OpenEngine, OpenKit, App (no tree build needed)

### 9.1 OpenKit (`Packages/OpenKit/Sources/OpenBoosts/`)

New file `BoostColorMatrix.swift`:

```swift
/// 20-float HSLA matrix (docs/plans/boost-color-remap.md §7). Row-major 4x5 over (H,S,L,A,1).
public struct BoostColorMatrix: Codable, Hashable, Sendable {
    public var values: [Float]            // always 20; init clamps/pads defensively
    public var isIdentity: Bool { ... }   // exact compare with identity rows
    public enum Tokens {                   // every guess lives here, one line each (§7.2)
        public static let lightnessSlope = 0.761
        public static let lightnessOffset = 0.159
        public static let saturationBasePerIntensity = 0.58
        // ...
    }
}
extension BoostColorWheel {                // type added by #103
    /// Engine remap value (two-stage builder, §7.2), or nil for identity.
    /// Replaces `adjustment` as the runtime once Step 4R lands;
    /// `adjustment` stays for legacy filters (§9.4). No scheme value (§5.6).
    public var hslaMatrix: BoostColorMatrix? { ... }
}
```

`BoostColorMatrix.init(values:)` refuses (returns nil from a failable init) any non-finite value
or |m| > 16 — the same bound the engine enforces (review m3); the builder's own outputs are
always finite and small, so a refusal means corrupt stored data.

`InjectionPlan` gains `colorMatrix: BoostColorMatrix?`; `BoostInjectionPlanner.plan` fills it
with the same last-non-identity rule it uses for `colorAdjustment` today
(`InjectionPlan.swift:51`), and folds it into the `planID` hash input beside `colorText` (:68)
so plan identity changes when the matrix changes. The `boost-applier.js` runtime: when the plan
carries a `colorMatrix`, the native side does **not** put a `colorAdjustment` in the page
payload at all (`PickerMessages.swift` wire type keeps the field for legacy plans; a matrix plan
sends `colorAdjustment: nil`). The applier JS itself is unchanged — it already does nothing
color-wise when the field is absent. The OpenBoosts harness gains numeric cases: S2-22 inputs →
the four §7.3 predicted hex values, the §7.2 continuity bounds, invert-only hue preservation,
and the seam pair (`#FF0008` / `#FF0800` at ρ 0.02 and 0.1 must give §7.2's table values, so a
later builder change shows up; review r2 N1). Swift HSL helpers live in the harness only —
product code never converts colors in Swift.

Op-log exactness rule (review r2 N9). G1, G2, and G10 compare the prediction with the recorded
8-bit op color exactly. That holds only if: the harness HSL helpers use `Float`, not `Double`,
with the same operation order as `boost_color_filter.cc`; neither side fuses multiply-adds
(Chromium builds with `-ffp-contract=off`, `build/config/compiler/BUILD.gn:668-670`; implementer
checkpoint for the Swift side); and quantization matches `SkColor4f::toSkColor` (the op log
prints `paint.getColor()`). The e2e suite reads the predictions the harness writes; it never
recomputes them in Python doubles. If exactness cannot be reached, the gates use ±1 level and
the implementation PR says why.

### 9.2 OpenEngine (ObjC++, `Engine/OpenEngine/`)

New header `include/OpenEngine/OEBoostColor.h` (umbrella `OpenEngine.h` imports it), new
implementation in `src/OEBoostColor.mm` plus small additions to `OEBrowserContext` and
`OEWebContent`. Exact surface (names mirror Arc's verbs with Open's prefix; main-thread,
`NS_SWIFT_UI_ACTOR` like the neighboring classes, `docs/engine-api.md`):

```objc
@interface OEBoostColorFilter : NSObject <NSCopying>
// Exactly 20 finite values with |m| <= 16, else nil.
+ (nullable instancetype)filterWithMatrixValues:(NSArray<NSNumber *> *)values;
- (nullable instancetype)initWithMatrix:(const float[_Nonnull 20])matrix;
- (void)getMatrix:(float[_Nonnull 20])outMatrix;
@property (nonatomic, readonly, getter=isIdentity) BOOL identity;
@end

// Paint readback (§5.4; verification only, no product behavior reads it).
// Reports exist only when the engine runs with --open-boost-color-paint-reports.
typedef NS_ENUM(NSInteger, OEBoostColorState) {
  OEBoostColorStateUnset, OEBoostColorStateNone, OEBoostColorStateValue };
@interface OEBoostColorPaintReport : NSObject
@property (nonatomic, readonly, copy) NSString *frameIdentifier;  // CEF frame id
@property (nonatomic, readonly, copy) NSString *host;             // document host
@property (nonatomic, readonly) int32_t processIdentifier;        // renderer pid (G5b)
@property (nonatomic, readonly) BOOL painted;                     // NO = "never painted"
@property (nonatomic, readonly) uint64_t firstPaintGeneration;    // document's first paint
@property (nonatomic, readonly) OEBoostColorState firstPaintState;
@property (nonatomic, readonly) uint64_t lastPaintGeneration;     // latest paint
@property (nonatomic, readonly) OEBoostColorState lastPaintState;
@property (nonatomic, readonly) NSTimeInterval presentationTime;  // seconds, TimeTicks clock
@property (nonatomic, readonly) BOOL presentationFailed;  // DidNotSwap time, not a real frame (r2 N6)
@end

// OEBrowserContext (profile registry; calls the cef_boost_color.h functions, §5.4)
- (BOOL)registerBoostColorFilter:(OEBoostColorFilter *)filter
                  forHostPattern:(NSString *)hostPattern
                      pathPrefix:(nullable NSString *)pathPrefix;
- (void)unregisterBoostColorFilterForHostPattern:(NSString *)hostPattern
                                      pathPrefix:(nullable NSString *)pathPrefix;
- (nullable OEBoostColorFilter *)boostColorFilterForHostPattern:(NSString *)hostPattern
                                                      pathPrefix:(nullable NSString *)pathPrefix;
@property (nonatomic, readonly) uint64_t boostColorGeneration;     // debug state "generation"
@property (nonatomic, readonly) uint64_t boostColorSnapshotsSent;  // debug state "snapshots_sent"

// OEWebContent (per-tab live apply; calls CefApplyBoostColorFilter)
- (BOOL)applyBoostColorFilter:(OEBoostColorFilter *)filter;
- (void)removeBoostColorFilter;                       // clears; frames fall back to patterns
@property (nonatomic, readonly, nullable) OEBoostColorFilter *boostColorFilter;  // last applied
@property (nonatomic, readonly) NSTimeInterval boostColorApplyTime;      // last apply/remove, TimeTicks clock
@property (nonatomic, readonly) uint64_t boostColorApplyGeneration;      // generation that call produced
@property (nonatomic, readonly, copy) NSArray<OEBoostColorPaintReport *> *boostColorPaintReports;
    // latest report per frame, at most 64 frames (oldest dropped); empty without the switch
@property (nonatomic, readonly, nullable) NSColor *pageBackgroundColor;  // debug state "page_background" (G10)
```

Rules: a nil or identity filter to `registerBoostColorFilter:` unregisters (one code path in the
App); pattern and prefix strings are validated here (non-empty host, optional `*.` prefix,
lowercased host, prefix normalized to start with `/`; anything else is logged and refused —
never a crash on App input). Matrix validation (finite, |m| ≤ 16) happens in
`OEBoostColorFilter` construction **and** again at the CEF boundary (§5.4), so no caller of
either layer can smuggle a NaN into a renderer. On stock CEF (`CEF_SOURCE=cdn`) these methods
exist but log once and no-op, so the App builds and runs against both distributions;
`boostColorFilter` still returns the last applied value and `boostColorPaintReports` stays
empty, so automation can tell "applied but engine ignored it" apart from "never applied" (the
G-suite break proof, §11.2). Apply latency (G7): `applyBoostColorFilter:` and
`removeBoostColorFilter` record `boostColorApplyTime` from `mach_absolute_time()` converted to
microseconds, which is the same clock as `base::TimeTicks::Now()` on macOS
(`base/time/time_apple.mm:87`). They then read `boostColorApplyGeneration` from
`CefGetBoostColorDebugState` in the same UI-thread turn. Automation computes latency as the
`presentationTime` of the first report with `lastPaintGeneration` ≥ that generation, minus
`boostColorApplyTime`. It never polls screenshots. OpenEngine receives the
`OpenBoostColorPaint` process messages in its existing CEF client and stores them per frame.

`OpenWeb` protocols gain the neutral mirror so OpenKit never imports OpenEngine
(`docs/engine-api.md` layering): `WebBoostColorFilter` (20 `[Float]`),
`WebProfile.registerBoostColor(_:hostPattern:pathPrefix:)` /
`unregisterBoostColor(hostPattern:pathPrefix:)`, `WebContent.applyBoostColor(_:)` /
`removeBoostColor()`. `App/EngineBridge.swift` converts.

### 9.3 App (`App/Boosts/BoostEngineAdapter.swift`, planned in app-shell §4.5)

The adapter owns all engine color state. On every `BoostStore` mutation for a Profile:

1. Recompute the pattern set: for each enabled Boost with a non-nil `hslaMatrix`, one entry
   (`*.domain`, `siteMatch.pathPrefix`) → filter (last in matcher order wins per key, the
   planner rule; path-scoped Boosts register with their prefix — review m4). Diff against what
   the adapter last registered on that context; register/unregister only the delta. Contexts are
   created lazily per Profile (engine-api E1); register the full set when a context first
   appears, including ephemeral (incognito) contexts. Every registration change is one engine
   broadcast; batch a mutation's delta into the fewest register/unregister calls practical.
2. Live preview (site-control D-6): during a pad drag, only the editor's bound page gets
   `applyBoostColor` (≤ 60 Hz, existing coalescing); pattern registration happens once on store
   commit (mouse up). On commit the per-tab value is cleared so patterns become the single
   source again (`removeBoostColor()` after registering — order matters: register first, then
   clear, so no frame falls back to "no value" in between). The per-page plan flow
   (app-shell §4.5) no longer carries color at all for wheel Boosts: patterns cover future and
   live pages alike, including pages opened before the Boost existed (snapshot re-resolution,
   §5.5). The plan flow still carries CSS/JS/font/zaps and legacy filters (§9.4).
3. Automation: add `boosts color` readback to the automation channel in the same style as the
   existing `boosts` commands (`docs/automation.md`). It returns the registered patterns, the
   context's `boostColorGeneration` and `boostColorSnapshotsSent`, and for the selected tab
   `boostColorFilter`, `boostColorApplyTime`, `boostColorApplyGeneration`,
   `boostColorPaintReports`, and `pageBackgroundColor` (§9.2). The e2e suite uses store-level
   Boost creation (existing automation) plus this readback; no new "set matrix directly" test
   hook — tests go through the real store path. The suite passes two engine switches through
   `OEEngineConfiguration.additionalSwitches` (`docs/engine-api.md`; implementer checkpoint):
   host-resolver rules (`a.boost.test` / `b.boost.test` → 127.0.0.1) for checks that need a
   second host, and `--open-boost-color-paint-reports` for the readback, except in the
   zero-cost runs (§11.3).

### 9.4 Migration from the filter runtime

| Stored state | After Step 4R |
|---|---|
| `colorWheel` set (#103) | `hslaMatrix` drives the engine remap. The derived `colorAdjustment` is no longer sent to pages (kept in the file, still derived by the one writer in site-control §5.2, so undo and the editor's displayed values do not change). `baseHue` becomes unused by the runtime; keep the field (no file migration), stop sampling it for new colors |
| Legacy `colorAdjustment` only (no `colorWheel`) | Unchanged: CSS filter path until the first color edit (site-control §4.4.5 legacy rule). The first edit creates a `colorWheel` and from then on the remap path. A legacy Boost and a wheel Boost matching one page: planner keeps one color winner; if the winner is legacy, the page gets the filter and no matrix (never both — the planner emits at most one of `colorMatrix` / `colorAdjustment` per plan; assert this in the harness) |
| No color | No registration, no apply. Zero-cost case (§11.3) |

R-2 closes when G1–G8 pass: white/grey pages tint. The site-control plan's neutral-page hint
stays (it now describes pages whose dominant colors are images, which still do not change).

## 10. Patch and overlay layout

Series numbering: `03xx` is taken (extensions/P1 `0301`–`0304`, ad-block `0310`/`0314` in the
CEF series as of 2026-10-26), `01xx` tab sleeping per `docs/engine-patches.md`. Boost color
takes **`04xx`** — recheck both `series` files before creating the patches. New CEF API follows the standing rules
(experimental guard, generated C API, `Engine/fork/scripts/engine-apply` runs the version manager
when overlay headers under `cef/include/` change — `docs/engine-fork.md`, P1 section).

### 10.1 Patches (`Engine/fork/patches/`)

| Patch | Series file line (rationale after `#`) | Upstream files touched (manifest `paths:`) |
|---|---|---|
| `chromium/0401-open-boost-color-blink.patch` | `0401-open-boost-color-blink.patch  # Step 4R: per-frame HSLA remap in Blink paint (GraphicsContext, Gradient, LocalFrameView, shadow/text bypass sites)` | `third_party/blink/renderer/platform/graphics/graphics_context.{h,cc}`, `gradient.{h,cc}`, `third_party/blink/renderer/core/frame/local_frame_view.{h,cc}`, `third_party/blink/renderer/core/paint/box_painter_base.cc`, `text_painter.cc`, `decoration_line_painter.cc` (if the §5.3b branch is taken), `svg_object_painter.{h,cc}`, `svg_shape_painter.cc`, `svg_container_painter.cc` (all in `third_party/blink/renderer/core/paint/`), `third_party/blink/renderer/core/layout/svg/layout_svg_resource_gradient.cc`, `third_party/blink/renderer/platform/BUILD.gn` (or its graphics sources `.gni` — checkpoint §5.2) |
| `cef/0401-open-browser-client-hooks.patch` (owner patch, see below) | `0401-open-browser-client-hooks.patch  # Open hooks in ChromeContentBrowserClientCef, one forwarding line per feature: Boost color snapshot send at RenderProcessWillLaunch (Step 4R)` | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.h`, `.cc`. Boost adds one include and one call after the base call in `RenderProcessWillLaunch` (`:311`); no `.h` change, because CEF already overrides it |
| `cef/0402-open-renderer-client-hooks.patch` (owner patch, see below) | `0402-open-renderer-client-hooks.patch  # Open hooks in ChromeContentRendererClientCef, one creation line per feature: Boost color thread observer + frame agent (Step 4R)` | `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc`. Boost adds one include, the observer in `RenderThreadStarted` (`:30`), and the agent in `RenderFrameCreated` (`:42`) |

No other CEF file is patched. The API is global functions in an overlay header (§5.4), so
`cef_browser.h`, `cef_request_context.h`, `browser_host_base.*`, and `request_context_impl.*`
stay untouched. The C API and wrappers are generated and untracked
(`docs/engine-fork.md:307-311`). `cef/BUILD.gn` stays untouched too: it belongs to 0302, whose
generic `open_libcef_deps` hook already reads `open/open_libcef_sources.gni`. There is **no
`cef.mojom` edit and no `frame_impl.{h,cc}` hunk** (review B1 removes both).

**One owner patch per file.** Two logical patches must never share a path
(`docs/engine-fork.md:119`); refresh captures every hunk of a path into the one patch whose
manifest lists it. The ad-block plan puts its hooks in these same two files (adblock-fork P-3
owns `chrome_content_browser_client_cef.{h,cc}`, P-4 owns `chrome_content_renderer_client_cef.cc`).
Neither patch is in the CEF series on 2026-10-26 (`0302`, `0303`, `0310`, `0314`). So:
- If ad-block's P-3/P-4 land first, Boost creates no patch for these files. It adds its lines to
  their owner patches and appends "Boost color (Step 4R)" to those series rationales.
- If Boost lands first, E2 creates the two feature-neutral owner patches above, and ad-block's
  P-3/P-4 add their lines to them. Tell the ad-block owner in the E2 PR.
Either way, each file ends with one owner patch.

Never hand-edit patch hunks; refresh via `engine-refresh-patches` and prove the round-trip
(`docs/engine-fork.md` patch workflow).

### 10.2 Overlay (`Engine/fork/src/`, mirrors `chromium/src`)

```text
third_party/blink/renderer/platform/graphics/boost_color_filter.h
third_party/blink/renderer/platform/graphics/boost_color_filter.cc
cef/include/cef_boost_color.h
open/boost_color/boost_color_value.h            # shared C++ value, matcher, converters
open/boost_color/mojom/BUILD.gn                 # mojom("mojom") — open_engine.mojom.BoostColorConfiguration
open/boost_color/mojom/boost_color.mojom
open/browser/boost_color/boost_color_registry.h
open/browser/boost_color/boost_color_registry.cc   # registry + snapshot broadcast (§5.4)
open/browser/boost_color/boost_color_api.h      # launch-send entry point for the 0401 hook
open/browser/boost_color/boost_color_api.cc     # the cef_boost_color.h global functions (§5.4)
open/renderer/boost_color/boost_color_thread_observer.h
open/renderer/boost_color/boost_color_thread_observer.cc  # snapshot store + resolver (§5.5)
open/renderer/boost_color/boost_color_frame_agent.h
open/renderer/boost_color/boost_color_frame_agent.cc
open/renderer/boost_color/boost_color_blink_glue.h   # the only Blink-core include (m8)
open/renderer/boost_color/boost_color_blink_glue.cc
open/open_libcef_sources.gni                    # edited: add browser+renderer sources above
```

The Blink files are the one exception to "new code goes under `open/`": a class inside the
`blink_platform` target must be listed in that target's sources, so the files live at their
upstream path via the overlay and the BUILD.gn hook adds them. Everything else follows the P1
precedent (`open/browser/tab_strip/*`).

### 10.3 GN changes

- `open/boost_color/mojom/BUILD.gn`: `mojom("mojom") { sources = [ "boost_color.mojom" ] }`
  (shape-copy `open/adblock/mojom/BUILD.gn` — adblock-fork §8.2). The interface is bound as a
  **channel-associated** interface at both ends (`GetRemoteAssociatedInterface` browser-side,
  associated registry renderer-side); no mojom annotation is needed for that, but the PR must
  show the associated binding in code, not a plain `Remote` (FIFO ordering is the design, §4).
- `open/open_libcef_sources.gni`: add the browser/renderer `.cc` files; they compile into
  `libcef_static` like the tab-strip sources. New deps for that target, if not already present
  (checkpoint): `//open/boost_color/mojom`, `//url`, `//mojo/public/cpp/bindings`,
  `//ipc` (ChannelProxy). Only `boost_color_blink_glue.cc` includes a Blink core header
  (`web_local_frame_impl.h`, m8) — checkpoint: `libcef_static` already depends on the Blink
  targets that make it available (CEF's `blink_glue.cc` compiles in the same target).
- Blink hook (patch 0401): two filenames in the platform sources list. No new GN target.
- No `args.gn` change. No feature flag: the code is inert without a registered matrix (§5.2
  identity rule). Do not add a kill switch beyond "App registers nothing".

### 10.4 Rebase watch (add to the rebase checklist when these land)

| Upstream file | Why it will conflict | Watch for |
|---|---|---|
| `graphics_context.cc` (`DarkModeColor`, `DarkModeFlags`) | Auto-dark is actively refactored upstream (new `ScopedAutoDarkModeState`, image policies) | Helper renames; keep the Boost branch to one `if` in each helper so re-applying is trivial |
| `dark_mode_filter.*`, `graphics_context.h` (`AutoDarkMode`, `ImageDrawOptions`) | Same refactor surface | `ImageDrawOptions` constructor changes hit §5.3's new field |
| `gradient.cc` | Stop-color handling moves with CSS gradient work | The `is_dark_mode_enabled_` block is the anchor; re-find it by that member name |
| `local_frame_view.cc` (`PaintFrame`, `DocumentBackgroundColor`) | Lifecycle/paint churn | Anchors: the `PaintFrame` signature and the dark branch inside `DocumentBackgroundColor` |
| `svg_object_painter.{h,cc}`, `svg_shape_painter.cc`, `svg_container_painter.cc`, `layout_svg_resource_gradient.cc` | SVG paint-server refactors (review r2 N4) | Anchors: the `SVGObjectPainter` constructor and the `AutoDarkMode` built in it; keep the filter in an `AutoDarkMode` field so `ApplyShader`'s virtual signature never changes |
| `content/public/common/content_features.cc` `kMBIMode` | The B1 FIFO guarantee needs the legacy mode (`:705-731`) | If upstream changes the default away from legacy, stop the rebase: frame commits would leave the process channel and the no-flash ordering (§4) breaks. G6 catches it |
| `box_painter_base.cc`, `text_painter.cc` | Shadow/decoration paint churn (review r1: rebase risk concentrates here with `graphics_context.cc`) | Anchors: `ResolveShadowColor` and `CreateDrawLooper` by name; keep each boost branch ≤ 3 lines |
| `chrome_content_renderer_client_cef.cc` | One owner patch shared with ad-block's agent hook (§10.1) | Keep every feature's creation lines; each is one line, so re-adding them is trivial |
| `chrome_content_browser_client_cef.cc` `RenderProcessWillLaunch` | CEF launch-hook churn; one owner patch shared with ad-block's network hooks (§10.1) | One overlay call after the base call; re-add beside it. (No `ExposeInterfacesToRenderer` or `cef.mojom` hunk remains after B1) |
| `cef/include/cef_boost_color.h` (overlay) and the translator | Global-function rules or the experimental guard change per CEF branch | Re-run the version manager; never merge generated C API by hand. If the translator stops accepting `std::vector<float>`, switch to the 80-byte `CefBinaryValue` form (§5.4) |
| `content/public/renderer/render_frame_observer.h`, `web_frame_widget.h` | `DidSetPageLifecycleState`, `DidCreateDocumentElement`, and `NotifyPresentationTime` signatures | Overlay code only (no hunk), but the build breaks on rename: re-find by name |

## 11. Acceptance checks (all must be able to fail)

No unit tests (rule 6). Two harnesses, both real-app/real-engine:

- **OpenBoosts harness** (Swift, existing `boosts` check in `tools/verify-all.sh`): matrix-builder
  numeric cases (§9.1) — S2-22 inputs produce §7.3's predicted outputs; continuity bounds and
  invert-only hue preservation (§7.2); planner never emits both `colorMatrix` and a page
  `colorAdjustment`.
- **Engine e2e**: new suite `boostcolor` in `tools/e2e/engine_e2e.py` (`--only boostcolor`,
  choices list at `engine_e2e.py:3736`), run under the on-screen lock (rule 11):
  `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only boostcolor`.
  The suite serves `tools/e2e/fixtures/boost-color/` from a local HTTP server on an ephemeral
  port and creates Boosts through the real automation/store path. Hosts: `a.boost.test` and
  `b.boost.test` via host-resolver rules (§9.3) — same site, different hosts. They share a
  process because origin-keyed processes are off by default in 156
  (`kOriginKeyedProcessesByDefault`, `content/public/common/content_features.cc:875`), and the
  gate checks that precondition through the report pids instead of trusting it. `127.0.0.1` vs
  `localhost` give the cross-process (OOPIF) case.

**Color space of every compare (review M5).** Window snapshots carry the display ICC profile;
S2-22 values were converted from display ICC to sRGB (interaction-states §20.15 header). Rule:
every pixel read from a snapshot is converted to **sRGB** before any ΔE00 or level compare, and
the suite prints both values. The deterministic primary assert avoids color management entirely:
exact recorded op colors via DevTools `LayerTree.snapshotCommandLog` (through the existing
automation `devtools` call, `docs/automation.md:92`; suite precedent `engine_e2e.py:397`) — a
solid swatch's recorded fill color must equal the Swift-builder prediction **exactly** (the
builder and the engine implement the same §7.1 math on the same quantized input, §5.1 m2).
Pixel probes then confirm the composited result in sRGB. A check that cannot get an op log for
its swatch says so and falls back to the pixel probe — it does not silently pass.
`getComputedStyle` and canvas `getImageData` are not valid color probes (by design they report
unremapped values); G11 asserts exactly that.

Timing checks follow review checklist §4: assert engine-reported scheduled values, not wall-clock
polling; at most one real-time check per behavior, ≤ 3 attempts, printing lateness and load
average. G5/G6/G7 use the §5.4 engine readbacks (`boostColorPaintReports`, registry
generation, apply time and generation) — no screenshot polling anywhere.

Fixture pages (shell helper, §12 S3): `fixture.html` (§8 capture fixture — the same file the user
opens in Arc), `frame.html` (grey ramp, iframe content on both host pairs), `heavy-1.html` (5,000
bordered/text divs, tall), `heavy-2.html` (500 gradient/shadow boxes, tall), `heavy-3.html`
(mixed text + 200 images, tall).

### 11.1 Pixel and behavior gates

| # | Check | Pass |
|---|---|---|
| G1 | White page: Boost with S2-22 inputs (θ 252°, ρ 0.69) on `fixture.html`; `#FFFFFF` and `#FCF5E6` swatches | Op-log fill equals the builder prediction exactly; sRGB pixel within ΔE00 3 of `#E4E2F3` / `#D4C7F8` |
| G2 | Dark: `#222222`, `#333333` swatches (same Boost) | Op-log exact; sRGB pixel within ΔE00 3 of `#56285D` / `#632F6F` |
| G3 | Untouched: raster `<img>`, CSS `background-image`, canvas rect, luminance-mask coverage, default `<button>` face and checkbox box (M2 guard; probe points away from label text, which is ordinary text paint and does remap) | Each channel within 1 level (sRGB) of the same run's no-Boost baseline |
| G4 | Remove while showing: delete the Boost's color via automation; JS marker (`window.__alive`) survives; re-probe G1–G3 | All points back within 1 level of baseline; marker intact (no reload); op log shows original colors |
| G5 | Frames, five cases. (a) same-origin child, own pattern matches; (b) **same-site different host** (`a.boost.test` page, `b.boost.test` child, pattern for b only — the B2 case); (c) cross-process child (`127.0.0.1` → `localhost`), pattern for parent only; (d) `srcdoc` child under a boosted parent; (e) **same-origin child under an unboosted parent** (`a.boost.test/` page, child at `/child/`, Boost path-scoped to `/child/` — in-process by definition, so the B2 case cannot fall back to OOPIF) | (a) child remapped; (b) and (e) child remapped, parent not, and the parent's and child's reports carry the **same pid** (else the case FAILs as "precondition not met", never passes as an OOPIF); (c) child unchanged, pids differ; (d) child inherits the parent's remap (§6.4). Second pass with per-tab apply: all frames remapped. Child assertions read the child's own `#FFFFFF` swatch and the child's report state |
| G6 | **No-flash proof:** register the pattern, read `boostColorGeneration` (G_reg), then navigate (same-process and cross-site/process-swap variants). Read the main frame's report in `boostColorPaintReports` | `painted`, `firstPaintState == Value`, and `firstPaintGeneration ≥ G_reg`: the document's very first paint already used the registration. Break arm (§11.2, review r2 N5): navigate first, wait until the main frame's report for that document says `painted`, then register; for that same document the predicate must be false (`firstPaintGeneration < G_reg` or `firstPaintState == None`). Registering only "after navigation start" is not enough: the snapshot can still arrive before the commit and the arm would pass |
| G7 | Live preview latency (the D-6 path, review r2 N6): one `applyBoostColorFilter:` with a value that differs from the current one → `boostColorApplyTime` / `boostColorApplyGeneration` vs the `presentationTime` of the first report with `presentationFailed == NO` and `lastPaintGeneration` ≥ that generation (one clock, §9.2). Not a store commit: a commit ends with `removeBoostColor()`, which re-resolves to an equal value, paints nothing, and would wait forever | < 100 ms, ≤ 3 attempts, lateness + load average printed. Final color probed once (G1 method), not polled |
| G8 | Performance (§11.3) | Budgets below |
| G9 | Back/forward with **proven BFCache**: boosted page → other page → back; assert `pageshow.persisted === true` by eval (a fresh load fails the gate, not skips it) | Remapped on return; disable the Boost on the other page, back again → unremapped, `persisted` still true |
| G10 | Coverage (M1/M2/m1/m9): box-shadow and text-shadow swatch pixels; browser-side document background readback (`pageBackgroundColor`, from `WebContents::GetBackgroundColor()`, §5.4) on two white boosted pages, one with `background:#FFFFFF` and one with no CSS background at all (review r2 N3); black→white gradient midpoint; 50%-alpha overlay pair | Shadows within ΔE00 3 of builder prediction for their colors; background readback on **both** pages equals the builder's remapped white exactly, and plain white with the Boost removed; gradient midpoint within ΔE00 3 of the per-pixel prediction (subdivision, §5.3); alpha pair within ΔE00 3 of remap-then-blend prediction (remap runs before compositing) |
| G11 | DOM truth: with the remap on, `getComputedStyle(document.body).backgroundColor` and canvas `getImageData` | Original values (paint-only effect, §3.3) |
| G12 | Two Boosts, one host (one wheel, one legacy-filter); plus a path-scoped Boost (`/only/`) probed on matching and non-matching paths | Exactly one color system active (planner rule §9.4); path-scoped: remapped under the prefix from first paint (generation check as G6), unremapped outside it |

B2 (site-control §8.2, line 1277) is rewritten when S4 lands, per the Step 4R acceptance text:
pad drag → probe a white background pixel (tinted) and an image pixel (unchanged), in sRGB,
instead of `getComputedStyle().filter`. That edit belongs to the site-control plan's owner; this
plan's PR does not touch that file.

### 11.2 Break proofs (review checklist §4)

1. **CDN build:** run `--only boostcolor` against a `CEF_SOURCE=cdn` build (OpenEngine no-ops,
   §9.2): G1, G2, G5, G6, G7, G10, G12 must FAIL; G3/G11 PASS. Record the FAIL lines in the
   implementation PR next to the fork-build PASS run.
2. **Late-registration arm (G6):** with the fork build, navigate, wait for the document's
   `painted` report, then register, and show that G6's predicate is false for that document —
   proving the no-flash gate measures ordering, not just color (review r2 N5).
3. **B2 arm (G5b):** during E1/E2 development, run G5 once against a build with the filter
   (incorrectly) installed at the `:3292` site and record G5b FAILing while G5a passes — or, if
   that variant is never built, state in the PR that G5b is the regression guard and show it
   failing by resolving the child to `kUnset` in a one-off local change. Do not merge either
   variant.
4. A gate that passes on both builds/arms proves nothing and must be rewritten before merge.

### 11.3 Performance budgets (the §7 Step 4R gates, made numeric)

rAF deltas quantize to vsync (8.33 ms at 120 Hz) and cannot resolve sub-millisecond record cost
(review M5), so record cost is measured with DevTools protocol through the existing automation
`devtools` call: `Tracing` paint/record durations over a scripted scroll, and
`LayerTree.snapshotCommandLog` for byte-level op compares. rAF frame times remain only as the
120 Hz sanity signal. Release, M5 Pro, 2x; load average printed with every result; ≤ 3 attempts,
median reported.

| Gate | Budget |
|---|---|
| **Zero cost when off (exact):** `snapshotCommandLog` for heavy-1, fork build with empty registry vs `CEF_SOURCE=cdn` build, both without the paint-report switch. First run CDN vs CDN once to prove the log is stable between runs (heavy-1 has no images, so no image `uniqueID`, `logging_canvas.cc:229`; review r2 N9) | **Byte-identical op logs.** This proves the §3.2 claim directly: no Boost → the recorded display list does not change at all. Also `boostColorSnapshotsSent == 0` on the fork build (no launch message, readback §9.2) |
| Zero cost when off (time): Tracing paint+record total over the heavy-1 scroll script, fork (empty registry) vs CDN build | Δ ≤ 2% (paired medians). The op-log identity above is the real gate; this bounds anything outside recording |
| Navigation with empty registry | No budget needed beyond identity: no IPC exists to pay for (§4). Without the paint-report switch, load heavy-1, navigate 10 times (same- and cross-process), then assert `boostColorSnapshotsSent == 0` and `boostColorGeneration == 0`. A count, not a duration. Break arm: the same run with one registered-then-removed pattern must read `boostColorSnapshotsSent > 0` |
| One Boost color: Tracing paint+record total per scroll pass on heavy-1/2/3, remap on vs off, same build/run | On ≤ off × 1.10 per fixture, and rAF p95 stays ≤ 8.3 ms (120 Hz) on each. Scroll replay after first paint records nothing new, so steady-scroll cost should be ~0; > 10% means invalidation is over-firing |
| Toggle: apply a matrix to the visible heavy-1 page | One full repaint only: Tracing shows one paint of the view between apply stamp and first-paint stamp (G7's numbers); no second full paint within the following 500 ms at rest |
| Drag: 2 s of 60 Hz per-browser deltas to the visible page, with 50 registered patterns and at least 10 other renderers of the Profile open | rAF p95 during drag ≤ pre-drag p95 + one vsync step (8.3 ms); if missed, App coalescing drops to 30 Hz (§6.2) and the gate reruns. The run prints the delta message size and the messages sent per second (review r2 N7). Lateness + load printed |
| Snapshot size sanity | 100 registered patterns: broadcast payload printed in the run log; no budget in v1, but a payload > 256 KiB fails review (it would mean the entry encoding is wrong — 100 × (host+path+80 B matrix) is ~35 KiB) |

Idle CPU stays at the existing near-zero budget: registry, observer, and agents hold no timers.

## 12. Work order

Engine steps are sized for the one tree-owning engine agent and run in order; each ends with the
tree in a buildable state and the patch refreshed. Shell steps need no tree build and run in
parallel from day one. Estimates are guesses for planning, not commitments.

| Step | Owner | Work | Proof before moving on |
|---|---|---|---|
| E1 | engine | Blink filter + per-frame hook + gradient + §5.3b branches (§5.1–5.3b, patch 0401). No transport yet; the tri-state is unreachable (every view `kUnset`, context null) so the patch is inert — do not add an env-var back door | Dev build green (`engine-build`, own session per rule 9); cefsimple loads example.com; op-log identity spot check (§11.3 zero-cost method) on a fixture page; patch round-trip (`engine-apply` after manual revert, byte-identical — the P1 proof shape) |
| E2 | engine | Registry + snapshot broadcast + thread observer + frame agent + blink glue (§5.4–5.5; the two CEF owner-patch hooks, §10.1). No scheme (§5.6) | Dev build green; patch round-trip; the zero-cost op-log identity still holds with the transport in (an empty registry sends nothing). Remap behavior is first proven in E3, once the API exists — no temporary registration back door |
| E3 | engine | CEF global functions (§5.4) + translator run + OpenEngine ObjC incl. the paint readback and debug state (§9.2) | App builds against the new headers (`heavy.sh tools/build.sh`); G1–G12 pass in the suite except perf |
| E4 | engine | Distrib (`engine-distrib --run` in its own session), app fetch, full e2e | `--only boostcolor` green incl. all §11.2 break arms recorded |
| E5 | engine | Perf gates (§11.3); tune only if a gate misses (LRU size, invalidation scope, drag rate — in that order) | G8 table filled with measured numbers in the PR |
| S1 | shell | `BoostColorMatrix.swift` (two-stage builder) + planner fields + harness numeric/continuity cases (§9.1) | `boosts` harness green under `verify-all.sh --only boosts` (through `heavy.sh`) |
| S2 | shell | OpenWeb mirror types + `BoostEngineAdapter` registration/apply logic (§9.3), capability-gated so the App works on the current distrib (calls no-op) | App runs; existing `boosts` automation unchanged; filter runtime still live |
| S3 | shell | Fixtures (§8/§11) + `boostcolor` suite with G1–G12 written against the spec | Suite runs and FAILs G1/G2/G5/G7/G10/G12 on the current engine (the §11.2.1 break proof, recorded early) |
| S4 | shell | Flip: planner emits `colorMatrix`, applier payload drops the filter for wheel Boosts (§9.4), B2 rewrite handed to the site-control owner. **Blocked until C-4R-7 and the extended C-4R-2 have landed** (§8), the §7.2 tokens are re-fitted, and the small-ρ fade law is chosen (v1, T1, or T2, §8 item 4) | Full suite green on the E4 distrib; `verify-all.sh` full run for the flip PR |

Landing order: S1–S3 can merge before E1–E5 (all inert). E1–E5 land as one engine PR series
(patches + overlay + OpenEngine), then S4 flips the runtime. Step 4R starts after #103 merges
(site-control §10); S1 depends on #103's `BoostColorWheel` type existing. **No capture blocks
E1–E5 or S1–S3; C-4R-7 + extended C-4R-2 block only S4** (§8).

## 13. Open questions and guesses (each marked)

| # | Question | v1 behavior (guess unless noted) | Settles by |
|---|---|---|---|
| Q-B1 | Hue anchor law: input L, output L′, or stored-hue offset? (§7.3) | Input L, knob anchors | C-4R-1, C-4R-2 (Step 2.1) |
| Q-B2 | `s0(ρ)` curve; do `a`/`b` move with ρ? | Linear `0.58·ρ`; a/b fixed | C-4R-2 |
| Q-B3 | Do saturated colors keep part of their hue at full strength? | No (K's H row ignores input hue; the §7.2 fade only blends at small ρ) | C-4R-3 (Step 2.3, may need an engine term) |
| Q-B4 | Stage-A slider maps and composition order; BO-17 `curves`/`points` relevance | §7.2 token maps | C-4R-8 |
| Q-B5 | Gradient stops remapped (subdivided) or skipped? | Remapped per subdivided stop | C-4R-4 |
| Q-B6 | Inline SVG vs SVG-as-image; srcdoc inheritance | Inline remaps, image does not (falls out of §5); srcdoc inherits (§6.4) | C-4R-5 |
| Q-B7 | ~~Scheme scope/mechanism~~ **Ruled (lead, review r1): dropped from v1** (§5.6). Post-v1 only, on per-tab WebContents preferences if a control ever needs it | Nothing ships | C-4R-9 (fact-finding only) |
| Q-B8 | Per-tab apply covering non-matching subframes | Yes (whole WebContents, resolved renderer-side) | No dedicated capture; Arc's `applyColorFilter:` is per web contents (name only) |
| Q-B9 | Print, PDF chrome, extension popups, DevTools | Excluded (Open choice, §6.4). Print is excluded by the `Printing()` skip in `PaintFrame` (§3.4 rule 7); paint preview and drag images follow the screen | Lead decision if a user-visible gap appears; no capture planned |
| Q-B10 | Peek / Little Open recoloring in Arc | Applies | C-4R-10 |
| Q-B11 | Form controls and Mac scrollbars | **Unremapped in v1** — native-theme paint is canvas-direct and never reaches the hook (review M2, §3.2). Selection highlight *does* remap (solid-color paint). Follow-up if C-4R-11 shows Arc remaps controls: scoped `cc::PaintCanvas` proxy around `WebThemeEngine::Paint` calls only (never a canvas-wide hook — canvas 2D shares `RecordPaintCanvas`) | C-4R-11 decides the follow-up; nothing blocks v1 |
| Q-B12 | Stage-A invert form | `L′ = 1 − (aA·L + bA)`, hues untouched | C-4R-7 (blocks S4) |
| Q-B13 | Arc's exact paint hook and cache (BO-23d/g) | Not needed: Open matches pixels, not the hook (Open choice) | — |
| Q-B14 | Error pages resolving with the failed URL (§6.4) | Remap accepted in v1 | Implementer checkpoint during E2 |
| Q-B15 | ~~Which editor control sets the scheme~~ **Ruled with Q-B7:** no v1 control, no channel | Nothing ships | C-4R-9 (fact-finding only) |
| Q-B17 | Small-ρ fade law: v1 matrix interpolation (splits reds at the hue seam for 0 < ρ < rampEnd, §7.2), T1 hue mix (splits at the knob's antipode), or T2 RGB mix (no split) (§8 item 4); `rampEnd` value | v1 matrix interpolation, `rampEnd` 0.20 | C-4R-2 small radii with the seam pair and hue strip (blocks S4) |
| Q-B16 | Wide-gamut (`display-p3`, `oklch`) solid colors: exact Arc behavior unknown (Arc's HSL is presumably sRGB too) | Convert as stored, clamp (§5.1); e2e probe asserts no crash and a stable color, not parity | Future capture if p3-heavy sites look wrong |

## 14. Review checklist self-run (this docs PR)

Per `docs/review-checklist.md`; N/A where the item cannot apply to a plan-only change. The
implementation PRs run the full list for real; §11 above is written so items 4.x can be answered
with commands, not prose.

| Item | Result | Evidence |
|---|---|---|
| 1. Input and memory limits | N/A (docs) — planned: matrix is fixed 20 floats at every boundary, finite and \|m\| ≤ 16 refused otherwise (review m3); registry caps 1024 patterns / 256 per-browser values, pattern ≤ 253 chars, prefix ≤ 1024; LRU 256 | §5.4, §9.1, §9.2 |
| 2. Lifetimes and callbacks | N/A (docs) — planned: per-tab registry entries cleared when the browser's `WebContents` is destroyed (registry-owned observer); the presentation callback re-reads the frame through the agent and drops the report if the frame is gone; equal-value resolutions no-op; snapshot broadcast is one-way (no callback can free its caller); browser-id reuse cannot inherit a value | §6.1, §5.2, §5.4 |
| 3. Real event paths | N/A — no keys or focus paths | — |
| 4. Checks that prove the change | PASS for the plan: every gate names its failing mode; break arms cover the CDN build, late registration (G6), and the B2 install-site variant; op-log asserts are color-management-free, pixel asserts state sRGB | §11 |
| 5. UI and motion | N/A (docs) — no UI in this plan; the editor plan owns Reduce Motion | — |
| 6. Docs and comments | PASS: this file is the doc; numbers cite their source (BO-23, S2-22, tree line numbers) and guesses are marked | §2, §7.2, §13 |
