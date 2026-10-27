# Boost Step 4R — engine-level page color remap: implementation plan

Status: plan, 2026-10-26. Implementer: one engine agent (tree owner) plus one shell-side helper
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
images, video, and canvas bitmaps keep their colors (capture S2-22). A separate one-value channel
forces the page's light/dark appearance (Arc's `registerColorScheme:`; BO-23c, guess).

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

Non-goals: changing the Boost editor UI or the pad law (site-control plan owns them); remapping
extension pages, DevTools, internal pages, print output, or the PDF viewer in v1 (§6.4); matching
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
friends, graphics_context.cc ~536+) are never touched.

The filter pointer is per `GraphicsContext`, set by `LocalFrameView` right after it constructs the
context for a paint (`local_frame_view.cc:3292`, the one production construction site;
`PaintForTest` at :4539 is upstream-test only). `LocalFrameView` owns the filter object, next to its
existing `EnsureDarkModeFilter()` (`local_frame_view.cc:5591`). Painters need no changes: unlike
auto-dark, Boost enablement does not travel in `AutoDarkMode` (which is derived from
`ComputedStyle::ForceDark()`, `computed_style.h:2632`, at 100+ `PaintAutoDarkMode(...)` call
sites). One pointer on the context covers every painter that records through it.

### 3.2 Why this hook, against each requirement

| Requirement | Why the hook satisfies it |
|---|---|
| Images and video keep colors (S2-22) | `<img>`, CSS background images, and favicons record through `DrawImage`, which the hook never enters. Video records a foreign layer (`video_painter.cc`: `RecordForeignLayer(..., DisplayItem::kForeignLayerVideo, ...)`), not solid-color ops |
| Canvas and WebGL keep colors | A canvas element's bitmap is a foreign layer when composited (`html_canvas_painter.cc:87`, `kForeignLayerCanvas` via `ContentsCcLayer()`; WebGL canvases use the same layer) or a `DrawImage` of its snapshot otherwise. The canvas element's own CSS background and border are box paint and do remap (Open choice; capture item C-4R-6) |
| Zero cost with no Boost color | The branch is one null check per solid-color draw, exactly like the existing `auto_dark_mode.enabled` check in `DarkModeColor()`. No filter object is built (`LocalFrameView` creates it lazily on first set, like `EnsureDarkModeFilter`). Recorded ops are byte-identical when off, so raster, compositing, and tile caches see no change |
| 120 Hz scroll | The transform runs once at record time, on the main thread, per distinct solid color (LRU-cached, §7.4). Scrolling replays cached display items and cc tiles; it records nothing new for already-painted content. Raster receives final colors in ordinary `PaintOp`s — no per-tile filter work, no extra render pass |
| Text, borders, backgrounds, selection, inline SVG | All record solid colors through `GraphicsContext` (`TextPainter` takes `AutoDarkMode` and reaches the same flags path, `text_painter.cc:376`ff; SVG shape painters likewise). They remap with no per-painter code |
| Iframes and OOPIFs | Each `LocalFrame` paints in its own renderer process through its own `LocalFrameView`. State is per frame (§5), so a cross-process subframe remaps in its own process; the parent's `RemoteFrame` never paints child pixels |
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
   `DarkModeFilter::ApplyToFlagsIfNeeded` (`dark_mode_filter.cc:256`).
6. Printing and paint preview: `LocalFrameView` sets the filter only on the production paint path
   (:3292). Print rendering constructs its own contexts through the printing code, which never
   receives the pointer. Print output is therefore unremapped in v1 (guess; §13 Q-B9).

## 4. Data path overview

```text
OpenKit (Swift)                     App                     OpenEngine (ObjC++)          CEF / Chromium (fork)
─────────────────                   ───                     ───────────────────          ─────────────────────
Boost.colorWheel (#103)
  └─ BoostColorMatrix.make ──► BoostEngineAdapter ──► OEBrowserContext            ──► CefRequestContext
     (20 floats + scheme)        (pattern diff +        -registerBoostColorFilter:      ::RegisterBoostColorFilter
                                  per-page apply)       forHostPattern:            └─► open_engine::BoostColorRegistry
                                                                                        (per BrowserContext)
                                OEWebContent                                     ┌─► push: cef.mojom.RenderFrame
                                  -applyBoostColorFilter: ──► CefBrowser            │     ::SetBoostColorFilter
                                  -removeBoostColorFilter     ::ApplyBoostColorFilter│  (live frames, after commit)
                                                                                     └─► pull: open_engine.mojom
renderer (each process)                                                                 .BoostColorHost::GetBoostColor
  open_engine::BoostColorFrameAgent (RenderFrameObserver) ◄──────────────────────────────┘  ForDocument [Sync]
    └─► WebLocalFrameImpl::SetBoostColorMatrix ──► LocalFrameView (owns BoostColorFilter)
          └─► GraphicsContext (per paint) ──► solid-color rewrite at record time (§3)
```

Two delivery directions, both required:

- **Pull (first paint).** The renderer agent asks the browser registry for the frame's filter at
  document start, before first paint. This is a process-level Mojo interface bound through
  `ExposeInterfacesToRenderer`, the same shape the ad-block fork chose after its F-27/F-28
  findings (`docs/plans/adblock-fork.md` D-13): the `cef.mojom` frame pipes connect only after
  commit (`cef/libcef/renderer/frame_impl.cc:328-335`), so a push-only design flashes unremapped
  colors on every navigation that reconnects a frame.
- **Push (live change).** Editor drags and enable/disable must recolor already-open pages without
  a reload (BO-13; site-control D-6). The browser pushes the new matrix to every live frame of
  the affected browsers over the existing per-frame pipe (`cef.mojom.RenderFrame`, browser →
  renderer). Late binding is fine here: the document already exists.

Registration is two-level, mirroring Arc (BO-23a/b): per-host-pattern registration on the Profile
covers future navigations; per-tab apply covers live preview and pages that are already open. The
registry is the single source of truth inside the engine; the per-tab apply is a push from the
same registry code path with an explicit value (§5.4).

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
  A new matrix makes a new filter object, so no cache invalidation logic exists.
- `IsIdentity()` matrices are never turned into a filter object: `LocalFrameView` stores null.
  This is what makes "Boost exists but its color is identity" cost the same as "no Boost".

### 5.2 Blink: per-frame state and the paint hook

Hook patch 0401 touches exactly these upstream files:

| File | Change |
|---|---|
| `third_party/blink/renderer/platform/graphics/graphics_context.h` | Add `void SetBoostColorFilter(BoostColorFilter*)` (non-owning), `BoostColorFilter* GetBoostColorFilter() const`, member `BoostColorFilter* boost_color_filter_ = nullptr;` next to `dark_mode_filter_` |
| `third_party/blink/renderer/platform/graphics/graphics_context.cc` | In `DarkModeColor()`: after the dark-mode branch, `if (auto* f = context.GetBoostColorFilter()) return f->RemapColor(color);` (order rule §3.4.1 — apply to the possibly-inverted color). In `DarkModeFlags` ctor: after the dark-mode branch, if a boost filter exists, run `ApplyToFlags` on the (possibly dark-rewritten) flags. Rename neither helper; keep the diff to ~15 lines |
| `third_party/blink/renderer/platform/graphics/gradient.h/.cc` | §5.3 |
| `third_party/blink/renderer/core/frame/local_frame_view.h/.cc` | Add `void SetBoostColorMatrix(std::optional<BoostHslaMatrix>)`, member `std::unique_ptr<BoostColorFilter> boost_color_filter_;`, and `std::optional<BoostHslaMatrix> boost_matrix_;`. At the :3292 construction site: `graphics_context.SetBoostColorFilter(boost_color_filter_.get());`. `SetBoostColorMatrix` compares against the stored matrix (exact float compare), no-ops when equal, otherwise replaces the filter and invalidates paint (§6.2). Identity or nullopt clears both members |
| `third_party/blink/renderer/core/frame/web_local_frame_impl.h/.cc` | Add `void SetBoostColorMatrix(std::optional<BoostHslaMatrix>)` forwarding to `GetFrame()->View()->SetBoostColorMatrix(...)`. This is the only entry the renderer agent calls; no `blink/public` API change (the agent is fork code and may include `web_local_frame_impl.h`, as `cef/libcef/renderer/frame_impl.cc` already includes Blink core headers — verify the include is already present; if not, the agent goes through `content::RenderFrame::GetWebFrame()` + `WebLocalFrameImpl::FromFrame`) |
| `third_party/blink/renderer/platform/BUILD.gn` (or the graphics sources list it includes) | Add the two new overlay sources. Implementer checkpoint: find where `dark_mode_filter.cc` is listed and add beside it |

Nothing in `cc/`, `components/viz/`, or the GPU process changes. Nothing in `ComputedStyle`,
`StyleEngine`, or the painters changes.

### 5.3 Gradients

`Gradient` rewrites stop colors at shader-build time when dark mode is on: member
`is_dark_mode_enabled_`, set from `ImageDrawOptions.apply_dark_mode` (`gradient.cc:350`), stops
rewritten at :334. Boost mirrors it:

- Add `std::optional<BoostHslaMatrix> boost_matrix_;` and a lazily built
  `std::unique_ptr<BoostColorFilter> boost_filter_;` to `Gradient` (next to `dark_mode_filter_` /
  `EnsureDarkModeFilter()`, gradient.cc:367).
- `ImageDrawOptions` (`graphics_context.h:99`) gains `const BoostHslaMatrix* boost_matrix = nullptr`.
  Every place that builds `ImageDrawOptions` from an `AutoDarkMode` also passes the current
  context's matrix. Implementer checkpoint: enumerate the `ImageDrawOptions(` constructions in
  `graphics_context.cc` (three `DrawImage` variants at ~537/577/653) and in
  `platform/graphics/image.cc`; the gradient path is the only consumer of the new field — image
  consumers must ignore it.
- In the stop-rewrite block, apply dark inversion first, then boost remap (order rule §3.4.1).
  Changing the matrix must drop `cached_shader_` (the existing code already rebuilds when
  `is_dark_mode_enabled_` flips; extend that condition to "matrix changed").

Whether Arc remaps gradient stops at all is unobserved (guess: yes, BO-23f; capture C-4R-4). The
per-stop choice is one `if` in one function; if the capture refutes it, delete the branch and
gradients behave like images.

### 5.4 Browser side: registry, CEF API, push

Overlay `open/browser/boost_color/` (§10.2):

```cpp
namespace open_engine {

// One per content::BrowserContext (Profile), stored as BrowserContext user data.
// UI thread only.
class BoostColorRegistry : public base::SupportsUserData::Data {
 public:
  static BoostColorRegistry* Get(content::BrowserContext*);
  void Register(const std::string& host_pattern, BoostColorValue value);
  void Unregister(const std::string& host_pattern);
  std::optional<BoostColorValue> Lookup(const GURL& url) const;
  // Push the value that applies to each frame of one browser, now.
  void PushToBrowser(CefBrowserHostBase* browser);
  // Push to every live browser of this context whose frames match a pattern.
  void PushPatternChange(const std::string& host_pattern);
};

struct BoostColorValue {
  float matrix[20];            // blink::BoostHslaMatrix layout
  int32_t scheme = 0;          // 0 none, 1 light, 2 dark (OEBoostColorScheme)
};
}
```

- **Pattern grammar (Open choice).** A host pattern is either an exact host (`example.com`) or a
  suffix pattern (`*.example.com`, matching the host and any subdomain). Scheme, port, and path
  are not part of the pattern; only `http`/`https` frame URLs can match. This matches Arc's
  `forHostPattern:` name and OpenKit's `SiteMatch` host rule (`Boost.swift:44`: host equals the
  domain or ends with `.` + domain, IPs match exactly only). Path-scoped Boosts (`SiteMatch.pathPrefix`)
  cannot be expressed per pattern; the App handles them with per-tab apply only (§9.3) — stated
  there as a rule, not discovered later as a bug.
- **Browser enumeration.** `PushPatternChange` iterates the context's live browsers via
  `CefBrowserInfoManager::GetBrowserInfoList()` (`cef/libcef/browser/browser_info_manager.h:146`),
  filtered to this registry's `BrowserContext`, then each browser's frames
  (`CefBrowser::GetFrameIdentifiers`, `cef/include/cef_browser.h:193`, or the browser-host
  equivalent). For each frame it sends the lookup result for the frame's current URL. Implementer
  checkpoint: prefer `content::WebContents::ForEachRenderFrameHost` on the browser's WebContents
  if the CEF frame list lags OOPIF creation; either is acceptable if G5 passes.
- **Push transport.** One new method on the existing browser→renderer frame interface in
  `cef/libcef/common/mojom/cef.mojom` (`RenderFrame`, ~line 50):
  `SetBoostColorFilter(array<float, 20>? matrix, int32 scheme);`
  Plain arrays keep `cef.mojom` free of an `//open` import. The renderer receiver is
  `CefFrameImpl` (`cef/libcef/renderer/frame_impl.cc`), which forwards to the frame agent (§5.5).
  CEF mojom bindings regenerate from GN; the CEF translator does not process mojom files
  (adblock-fork F-11).
- **New-frame coverage on the browser side.** The registry does not observe navigations. The pull
  (§5.5) covers every new document, including the first document in a swapped-in renderer process.
  Push is only for changes to already-open documents. This split is what makes process swaps and
  OOPIFs need no browser-side frame tracking.

CEF public API (new header `cef/include/cef_boost_color.h`, overlay; all new methods guarded with
`CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`, C API regenerated by the version manager, never
hand-edited — `docs/engine-patches.md` storage rules):

```cpp
// On CefRequestContext (cef/include/cef_request_context.h):
virtual void RegisterBoostColorFilter(const CefString& host_pattern,
                                      const float matrix[20],
                                      cef_boost_color_scheme_t scheme) = 0;
virtual void UnregisterBoostColorFilter(const CefString& host_pattern) = 0;

// On CefBrowser (cef/include/cef_browser.h):
// Applies to every frame of this browser now, regardless of host pattern.
// A null matrix clears the per-tab value (frames fall back to the registry).
virtual void ApplyBoostColorFilter(const float* matrix /*[20] or nullptr*/,
                                   cef_boost_color_scheme_t scheme) = 0;
```

`cef_boost_color_scheme_t` is a new enum in `cef_boost_color.h` (`CEF_BOOST_SCHEME_NONE=0`,
`_LIGHT=1`, `_DARK=2`). Implementations live in the overlay and are called from hook patches in
`cef/libcef/browser/request_context_impl.cc` and `cef/libcef/browser/browser_host_base.cc`
(one forwarding function each; implementer checkpoint: match how P1's
`0302-open-hosted-tabs.patch` forwards into `//open` code).

Precedence (normative): a per-tab applied value beats the pattern value for every frame of that
browser, until cleared. Clearing the per-tab value re-pushes the pattern lookup per frame. The
registry stores the per-tab value keyed by browser identifier so a frame created later in that
browser (new subframe, process swap) pulls the per-tab value, not the pattern value — the pull
therefore carries the browser identifier, not just the URL (§5.5).

### 5.5 Renderer side: frame agent and pull

Overlay `open/renderer/boost_color/`:

```cpp
namespace open_engine {
// One per content::RenderFrame. Deletes itself (RenderFrameObserver contract).
class BoostColorFrameAgent : public content::RenderFrameObserver {
 public:
  explicit BoostColorFrameAgent(content::RenderFrame* render_frame);
  void SetFilter(std::optional<BoostColorValue> value);  // from push and pull
  // RenderFrameObserver:
  void DidCreateDocumentElement() override;   // pull, before first paint
  void DidSetPageLifecycleState(...) override; // BFCache restore: re-pull (§6)
  void OnDestruct() override;
};
}
```

- **Creation hook.** One line in `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc`
  `RenderFrameCreated` (~:41-50), after the `CefRenderFrameObserver` is made:
  `new open_engine::BoostColorFrameAgent(render_frame);  // Deletes itself.`
  This is the same hook the ad-block fork uses for its agent (adblock-fork P-4, revised
  2026-10-26). The two agents are independent objects; series order decides patch stacking
  (§10.3). This line is its own patch (0402) so the shared file never carries two features in
  one hunk.
- **Pull.** Process-level interface `open_engine.mojom.BoostColorHost` (overlay mojom, §10.2):

```mojom
module open_engine.mojom;
struct BoostColorValue { array<float, 20> matrix; int32 scheme; };
interface BoostColorHost {
  // Called once per http(s) document, at document start. browser_id is the CEF
  // browser identifier (0 if unknown); url is the frame URL spec.
  [Sync] GetBoostColorForDocument(int32 browser_id, string url)
      => (BoostColorValue? value);
};
```

  Bound in `ExposeInterfacesToRenderer` (hook beside CEF's `BrowserManager` binding,
  `chrome_content_browser_client_cef.cc:711-720`; adblock-fork F-28). The browser implementation
  runs on the UI thread (registry is UI-thread; a registry-binder with an explicit task runner —
  implementer checkpoint: pass the UI task runner so the sync call never touches the IO-thread
  default). Cost: one sync IPC per http(s) document, only when the process has ever bound the
  interface — the agent binds lazily on first http(s) document and caches the remote per process
  (pattern: `cef/libcef/renderer/render_manager.cc:176-180` `BindHostReceiver`). Non-http(s)
  documents (about:blank, chrome://, devtools://, extension pages) never pull and never remap
  (§6.4). A registry with zero patterns and zero per-tab values must still answer — the answer is
  null; the IPC itself is the only cost, gated in §11.3 (G8 includes a navigation-time check).
- **Apply.** `SetFilter` converts the value to `blink::BoostHslaMatrix` and calls
  `WebLocalFrameImpl::SetBoostColorMatrix`, then handles the scheme (§5.6). Equal values no-op
  inside `LocalFrameView` (§5.2), so duplicate push+pull deliveries are harmless.
- **Push receive.** `CefFrameImpl::SetBoostColorFilter` (new `cef.mojom.RenderFrame` method)
  forwards to the agent. Lookup: the agent registers itself in a map keyed by render-frame routing
  id in `open/renderer/boost_color/boost_color_agent_registry.{h,cc}`, or — preferred if it
  compiles without new deps — `CefFrameImpl` holds the agent pointer via the existing
  `CefRenderFrameObserver::AttachFrame` pattern (`render_frame_observer.h:36`). Implementer picks
  one; the map is the fallback. State the choice in the PR.

### 5.6 Color scheme channel

Arc's one-int registration is, by strong guess, a forced light/dark appearance (BO-23c). Open
implements it as a per-Page preferred-color-scheme override, independent of the matrix (either
can be set without the other, as in Arc):

- Renderer: when a pulled/pushed value carries `scheme != 0`, the agent (main frame only) calls
  `Page::GetSettings().SetPreferredColorScheme(...)` — the same setter SVG images use
  (`svg_image.cc:306`) — then `StyleEngine::UpdateColorScheme`-equivalent invalidation. The exact
  public path: `WebLocalFrameImpl` gains `SetBoostColorScheme(int)` beside `SetBoostColorMatrix`;
  it sets the Settings value and calls the document's style engine update so
  `PlatformColorsChanged()` (`style_engine.cc:1392`) re-resolves `prefers-color-scheme` and
  invalidates paint. Subframes inherit the owner's scheme automatically
  (`style_engine.cc`, `owner_preferred_color_scheme_`), including OOPIFs. Implementer checkpoint:
  Settings are per `Page`; an OOPIF has its own `Page` in its own process and receives the scheme
  through the normal frame-owner propagation — verify with G10's cross-origin iframe case, and if
  propagation does not cross processes, the agent applies the scheme in every frame of the page
  instead (the value rides the same push/pull, so no protocol change).
- Clearing (`scheme == 0` after a non-zero value, or filter cleared) restores the Settings value
  from the current `WebPreferences` (`preferred_color_scheme`, `web_preferences.mojom:454`).
  The agent remembers whether it overrode the scheme; it never writes Settings when it did not.
- Scope (Open choice): the scheme follows the **top-level** page's value. A subframe whose own
  host matches a different pattern gets its own matrix but not its own scheme. Arc's scope is
  unobserved (§13 Q-B7; capture C-4R-9).

## 6. Lifetime rules (normative)

### 6.1 State ownership summary

| State | Owner | Key | Lifetime |
|---|---|---|---|
| Pattern registrations | `BoostColorRegistry` (browser) | host pattern, per `BrowserContext` | Until unregister or context teardown. Not persisted by the engine; the App re-registers from `BoostStore` at context creation (§9.3) |
| Per-tab applied value | `BoostColorRegistry` (browser) | CEF browser identifier | Until cleared or the browser closes. Browser identifiers must not be reused while an entry exists — clear the entry when the browser-host closes (hook beside the `ApplyBoostColorFilter` forwarder) |
| Per-frame current value | `BoostColorFrameAgent` + `LocalFrameView` (renderer) | `RenderFrame` | Set by pull at each document start; updated by push; dies with the frame. A new document in the same frame re-pulls before its first paint |

### 6.2 Invalidation on change

`LocalFrameView::SetBoostColorMatrix` with a changed value does exactly:

1. Replace `boost_color_filter_` (null for identity/none).
2. `GetLayoutView()->InvalidatePaintForViewAndDescendants()` — the paint half of
   `StyleEngine::PlatformColorsChanged()` (`style_engine.cc:1392`). No style recalc: Boost colors
   are not in `ComputedStyle`. (The scheme channel separately triggers the full platform-colors
   path, §5.6.)
3. Ensure a frame is scheduled (the invalidation already does this through the normal paint
   lifecycle; do not add a second scheduler call unless G7 shows a missed frame).

One full repaint per change is the accepted cost (same as a forced-dark toggle, BO-23g guess for
Arc). During an editor drag at ≤ 60 Hz (site-control D-6), each pushed value repaints the view;
the LRU (256 entries) is rebuilt per filter object, so drag cost is bounded by distinct colors,
not pixels. If G8's drag case misses its budget, the fix is coalescing in the App (drop to 30 Hz,
the R-3 precedent), not caching in the engine.

### 6.3 Event table

| Event | Rule |
|---|---|
| Same-document navigation (pushState, hash) | No pull, no change. The matrix is per frame/document-start URL; an SPA route change keeps it. Path-scoped Boosts therefore apply for the whole SPA session once matched at load (consequence of §9.3; Arc unobserved) |
| Cross-document navigation, same process | Agent pulls at `DidCreateDocumentElement` for the new URL. Until the answer lands the old document is gone (commit already happened), so no frame paints with the wrong matrix as long as the pull precedes first paint — `DidCreateDocumentElement` is document-start, before layout/paint of the new document (the same hook adblock-fork uses for cosmetics, D-13) |
| New subframe (any origin) | Its agent pulls for its own URL with the browser id. Per-tab value (if any) wins (§5.4 precedence); else pattern lookup on the subframe's own host |
| Renderer process swap (cross-site navigation, crash + reload) | New process, new agents, pull covers it. The browser keeps no per-process state. Crash recovery needs no push replay |
| Back/forward, incl. BFCache restore | BFCache: the frozen document keeps its `LocalFrameView` filter; on restore the agent re-pulls (`DidSetPageLifecycleState`, the `CefRenderFrameObserver` precedent at `render_frame_observer.h:23`) so a Boost changed while the page was cached takes effect. Equal values no-op (§5.2), so the common case costs one comparison |
| Tab sleep / discard (shell unloads the page) | The `OEWebContent` closes; engine state dies with it. On reload, pull reapplies. Chromium never discards hosted tabs itself (P1, patch 0303), so no engine-side discard case exists |
| Peek pages | Peek pages are Alloy `OEWebContent`s in a Profile context (P1 shell rules). They get the remap through the same registry/pull — the Site Control *panel* is unavailable in Peek (site-control non-goals), but an existing Boost still applies. Arc parity for Peek recoloring is unobserved (guess: applies; capture C-4R-10) |
| Little Open pages | Same rule: any live page in a context with registrations remaps. The App's per-tab apply enumerates `OEEngine.allWebContents` (§9.3), which includes Little Open windows' pages |
| Boost disabled, deleted, or color reset while the page shows | App unregisters the pattern (or clears the per-tab value) → `PushPatternChange`/`PushToBrowser` sends null → agent clears → repaint with original colors, no reload (G4). If the frame's pipe is mid-navigation, the next document's pull gets the new answer; no queue is needed |
| Global Boosts switch off (`open.advanced.enableBoosts`, site-control D-5) | App unregisters every pattern of the Profile and clears every per-tab value. Engine sees ordinary unregisters |
| Profile (context) teardown, incognito window close | Registry dies with the `BrowserContext`. Ephemeral contexts get their own registry; Boost editing is disabled in incognito but existing Boosts apply (site-control D-10), so the App registers the same patterns on the ephemeral context |
| Space switch, tab switch, window focus | No engine traffic. State is per frame, already applied |
| Two Boosts match one host | One value per pattern by construction. Which Boost wins is the planner's existing rule (last non-identity in matcher order, `InjectionPlan.swift:51`); the App registers only the winning value (§9.3) |

### 6.4 Exclusions (never remap, never pull)

Non-http(s) main-frame and subframe documents: `about:`, `chrome://`, `devtools://`,
`chrome-extension://`, `view-source:`, internal error pages (they commit with the failed URL but
render Chromium's error document — implementer checkpoint: error pages pull with the http(s) URL
and would remap; accept this in v1 and note it, or skip documents whose navigation failed if the
agent can see it cheaply via `DidFailProvisionalLoad`). The PDF viewer's plugin surface is
foreign content and stays untouched by construction; its surrounding chrome is an internal page
and excluded. Print output excludes itself (§3.4.6). Extension popups are `chrome-extension://`
documents and excluded (Open choice; §13 Q-B9).

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

Rows (all angles converted to turns by /360):

```text
H' = Hp + Δ·(1 − L)                     // dark end takes the secondary hue, light end the primary
   → m0=0, m1=0, m2=−Δ/360, m3=0, m4=(Hp+Δ)/360
S' = s0 + k·S
   → m5=0, m6=k, m7=0, m8=0, m9=s0
L' = a·L + b,  or  1 − (a·L + b) when invertLightness
   → m10=0, m11=0, m12=±a, m13=0, m14=b or (1−b)
A' = A
   → m15..m19 = 0,0,0,1,0
```

Constants and slider maps. Measured values are from the single S2-22 sample (ρ ≈ 0.69, sliders
neutral); everything that generalizes them is a guess kept in one token block
(`BoostColorMatrix.Tokens` in OpenBoosts, §9.1):

| Symbol | v1 value | Basis |
|---|---|---|
| `a0` (L slope at neutral) | 0.761 | Measured grey fit (BO-23e; re-fit §2) |
| `b0` (L offset at neutral) | 0.159 | Measured grey fit |
| `s0` at ρ=0.69 | 0.40 | Measured (grey `S′` constant across the ramp) |
| `s0(ρ)` | `0.58 · ρ` | **Guess**: linear through the one measured point (0.40 / 0.69 ≈ 0.58) and the origin (ρ=0 must be identity). One capture cannot distinguish linear from any other curve through those points (capture C-4R-2) |
| `k` at slider 50 | 0.5 | **Guess** (BO-23e: fitted ≈ 0.48; slider 0…100 → keep factor 0…1, neutral 0.5) |
| `k(slider)` | `slider / 100` (Original Saturation) | **Guess**, same basis |
| `a(Contrast)` | `a0 · (0.5 + slider/100)` → 0.761 at 50, range ≈ [0.38, 1.14] | **Guess** (Open choice; the filter runtime mapped sliders to 0.5…1.5 multipliers, site-control §4.4.4) |
| `b(Brightness)` | `b0 + (slider − 50) / 200` → 0.159 at 50, range ≈ [−0.09, 0.41], then the engine clamps L′ | **Guess** (Open choice) |
| Identity | ρ < 0.02, no invert, all sliders 50 → no matrix (nil) | Same identity rule shape as §4.4.5's filter identity |

Note what the rows imply and accept it: hue never reads the input hue in v1 (m0 = 0), so an
already-colored page loses its hues to the knob gradient. That is what the grey evidence proves
(hue reads L when S=0); whether saturated colors keep part of their hue is the §8 question. Do
not soften this speculatively — §8 isolates that change so its capture can be judged alone.

### 7.3 Fit quality of §7.2 against S2-22 (derived, this task)

Re-running the BO-23 fit with the §7.2 rows (knob anchors Hp 253.6°, Hs 297.9°, k = 0.48):
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

Acceptance for Step 2: the §11 G1/G2 gates keep passing, plus new saturated-swatch gates (ΔE00 ≤ 3
against the Arc capture values) added to the same suite. Until then, G1/G2 use the S2-22 pairs
only, and saturated non-fixture colors have no parity claim.

### Capture list for the user's next Arc session (feeds §8 and §13)

The shell helper ships the fixture page first (§12 S3): `tools/e2e/fixtures/boost-color/fixture.html`
— one static page with labeled swatches: grey ramp (L = 0, .1, …, 1), saturated hues (H = 0, 30, …,
330 at S = 1, L = .25/.5/.75/.92), a two-stop and a multi-stop CSS gradient, inline SVG rects, an
SVG `<img>`, a raster `<img>`, a canvas rect, a `<video>` with poster, form controls
(button/input/select/checkbox), selected text, and a same-origin iframe with the grey ramp. The
user opens this exact file in Arc (agents never launch Arc, rule 4) and screenshots it at:

| # | Capture | Settles |
|---|---|---|
| C-4R-1 | S2-22 repeat on the fixture: primary knob 252°, radius ≈ 0.69 (same as S2 10/0039), sliders neutral | Anchor law on 11 greys at once (Step 2.1); gradient/SVG/canvas behavior in the same shot |
| C-4R-2 | ρ sweep: radius ≈ 0.25 / 0.5 / 1.0 at hues 0°, 120°, 240° (9 shots, grey ramp region enough) | `s0(ρ)`, whether a/b move with ρ |
| C-4R-3 | Saturated grid close-up at ρ ≈ 0.69, hue 252° and hue 0° | `k`, hue preservation (Step 2.2/2.3) |
| C-4R-4 | Gradient bar region, any one color set | Per-stop remap vs skipped (§5.3) |
| C-4R-5 | Inline SVG vs SVG-`<img>` region | §3.4.2/3.4.3 rules |
| C-4R-6 | Canvas rect + its CSS border/background, video poster region | Canvas bitmap untouched; element box paint remapped? |
| C-4R-7 | Invert lightness on, sliders neutral (grey ramp) | `L′ = 1 − (aL + b)` guess (§7.2) |
| C-4R-8 | Each advanced slider alone at 0 and at 100 (6 shots, grey ramp + one saturated row) | `a(·)`, `b(·)`, `k(·)` maps; BO-17 curve suspicion |
| C-4R-9 | A page with `prefers-color-scheme: dark` styling + a cross-origin iframe, with a dark-forcing Boost appearance if the editor exposes one; note what the iframe does | Scheme scope (§5.6) |
| C-4R-10 | The same boosted page in Peek and in Little Arc | §6.3 Peek/Little Open rows |
| C-4R-11 | Form controls + text selection close-up | Theme-painted colors and selection (Open: remapped via GraphicsContext) |
| C-4R-12 | Boost on an already dark-mode-native site (site's own dark theme on) | Whether Arc's remap composes with the page's dark colors the same way (sanity; no Open change expected) |

Each screenshot needs the editor visible (knob position readable) or a note of hue/radius/sliders.
Pixel values are read from the screenshots by an agent afterward; frames stay local (rule 5
applies to Arc user data — the fixture is ours, so its screenshots may be committed redacted of
anything personal).

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
    /// Engine remap value, or nil for identity. Replaces `adjustment` as the
    /// runtime once Step 4R lands; `adjustment` stays for legacy filters (§9.4).
    public var hslaMatrix: BoostColorMatrix? { ... }
    public var boostColorScheme: BoostColorScheme { ... }  // from baseAppearance/invert (BO-17; Open: .none unless the editor sets an appearance)
}
public enum BoostColorScheme: Int, Codable, Sendable { case none = 0, light = 1, dark = 2 }
```

`InjectionPlan` gains `colorMatrix: BoostColorMatrix?` and `colorScheme: BoostColorScheme`
(default `.none`); `BoostInjectionPlanner.plan` fills them with the same last-non-identity rule it
uses for `colorAdjustment` today (`InjectionPlan.swift:51`), and folds both into the `planID`
hash input beside `colorText` (:68) so plan identity changes when the matrix changes. The
`boost-applier.js` runtime: when the plan carries a `colorMatrix`, the native side does **not**
put a `colorAdjustment` in the page payload at all (`PickerMessages.swift` wire type keeps the
field for legacy plans; a matrix plan sends `colorAdjustment: nil`). The applier JS itself is
unchanged — it already does nothing color-wise when the field is absent. The OpenBoosts harness
gains numeric cases: S2-22 inputs → the four §7.3 predicted hex values (Swift HSL helpers in the
harness only — product code never converts colors in Swift; the engine does).

### 9.2 OpenEngine (ObjC++, `Engine/OpenEngine/`)

New header `include/OpenEngine/OEBoostColor.h` (umbrella `OpenEngine.h` imports it), new
implementation in `src/OEBoostColor.mm` plus small additions to `OEBrowserContext` and
`OEWebContent`. Exact surface (names mirror Arc's verbs with Open's prefix; main-thread,
`NS_SWIFT_UI_ACTOR` like the neighboring classes, `docs/engine-api.md`):

```objc
typedef NS_ENUM(NSInteger, OEBoostColorScheme) {
    OEBoostColorSchemeNone = 0, OEBoostColorSchemeLight = 1, OEBoostColorSchemeDark = 2,
};

@interface OEBoostColorFilter : NSObject <NSCopying>
+ (instancetype)filterWithMatrixValues:(NSArray<NSNumber *> *)values  // exactly 20, else nil
                                scheme:(OEBoostColorScheme)scheme;
- (instancetype)initWithMatrix:(const float[_Nonnull 20])matrix
                        scheme:(OEBoostColorScheme)scheme;
- (void)getMatrix:(float[_Nonnull 20])outMatrix;
@property (nonatomic, readonly) OEBoostColorScheme scheme;
@property (nonatomic, readonly, getter=isIdentity) BOOL identity;
@end

// OEBrowserContext (profile registry; forwards to CefRequestContext, §5.4)
- (void)registerBoostColorFilter:(OEBoostColorFilter *)filter
                  forHostPattern:(NSString *)hostPattern;
- (void)unregisterBoostColorFilterForHostPattern:(NSString *)hostPattern;
- (nullable OEBoostColorFilter *)boostColorFilterForHostPattern:(NSString *)hostPattern; // readback for automation

// OEWebContent (per-tab live apply; forwards to CefBrowser::ApplyBoostColorFilter)
- (void)applyBoostColorFilter:(OEBoostColorFilter *)filter;
- (void)removeBoostColorFilter;                       // clears; frames fall back to the registry
@property (nonatomic, readonly, nullable) OEBoostColorFilter *boostColorFilter;  // last applied (nil = registry-driven)
```

Rules: a nil or identity filter to `registerBoostColorFilter:` unregisters (one code path in the
App); pattern strings are validated here (non-empty host, optional `*.` prefix, lowercased;
anything else is logged and ignored — never a crash on App input). On stock CEF
(`CEF_SOURCE=cdn`) these methods exist but log once and no-op, so the App builds and runs against
both distributions; `-[OEWebContent boostColorFilter]` still returns the last applied value so
automation can tell "applied but engine ignored it" apart from "never applied" (the G-suite
break proof, §11.2).

`OpenWeb` protocols gain the neutral mirror so OpenKit never imports OpenEngine
(`docs/engine-api.md` layering): `WebBoostColorFilter` (20 `[Float]` + `WebBoostColorScheme`),
`WebProfile.registerBoostColor(_:hostPattern:)` / `unregisterBoostColor(hostPattern:)`,
`WebContent.applyBoostColor(_:)` / `removeBoostColor()`. `App/EngineBridge.swift` converts.

### 9.3 App (`App/Boosts/BoostEngineAdapter.swift`, planned in app-shell §4.5)

The adapter owns all engine color state. On every `BoostStore` mutation for a Profile:

1. Recompute the pattern set: for each enabled Boost with a non-nil `hslaMatrix` and
   `siteMatch.pathPrefix == nil`, one entry `*.domain` → filter (last in matcher order wins per
   domain, the planner rule). Diff against what the adapter last registered on that context;
   register/unregister only the delta. Contexts are created lazily per Profile (engine-api E1);
   register the full set when a context first appears, including ephemeral (incognito) contexts.
2. Path-scoped Boosts (`pathPrefix != nil`) get no pattern. Their color rides the existing
   per-page plan flow: on main-frame commit (app-shell §4.5 apply path) the adapter calls
   `applyBoostColor` on that page when the plan has a matrix, `removeBoostColor()` when it does
   not. Accept the §6.3 SPA consequence.
3. Live preview (site-control D-6): during a pad drag, only the editor's bound page gets
   `applyBoostColor` (≤ 60 Hz, existing coalescing); pattern registration happens once on store
   commit (mouse up). On commit the per-tab value is cleared so the registry becomes the single
   source again (`removeBoostColor()` after registering — order matters: register first, then
   clear, so no frame falls back to "no value" in between).
4. Automation: add `boosts color` readback to the automation channel (registered patterns of the
   selected tab's context + the tab's `boostColorFilter`) in the same style as the existing
   `boosts` commands (`docs/automation.md`). The e2e suite uses store-level Boost creation
   (existing automation) plus this readback; no new "set matrix directly" test hook — tests go
   through the real store path.

### 9.4 Migration from the filter runtime

| Stored state | After Step 4R |
|---|---|
| `colorWheel` set (#103) | `hslaMatrix` drives the engine remap. The derived `colorAdjustment` is no longer sent to pages (kept in the file, still derived by the one writer in site-control §5.2, so undo and the editor's displayed values do not change). `baseHue` becomes unused by the runtime; keep the field (no file migration), stop sampling it for new colors |
| Legacy `colorAdjustment` only (no `colorWheel`) | Unchanged: CSS filter path until the first color edit (site-control §4.4.5 legacy rule). The first edit creates a `colorWheel` and from then on the remap path. A legacy Boost and a wheel Boost matching one page: planner keeps one color winner; if the winner is legacy, the page gets the filter and no matrix (never both — the planner emits at most one of `colorMatrix` / `colorAdjustment` per plan; assert this in the harness) |
| No color | No registration, no apply. Zero-cost case (§11.3) |

R-2 closes when G1–G8 pass: white/grey pages tint. The site-control plan's neutral-page hint
stays (it now describes pages whose dominant colors are images, which still do not change).

## 10. Patch and overlay layout

Series numbering: `00xx` ad-block, `01xx` tab sleeping, `03xx` extensions/P1 are taken
(`docs/engine-patches.md`). Boost color takes **`04xx`**. New CEF API follows the standing rules
(experimental guard, generated C API, `Engine/fork/scripts/engine-apply` runs the version manager
when overlay headers under `cef/include/` change — `docs/engine-fork.md`, P1 section).

### 10.1 Patches (`Engine/fork/patches/`)

| Patch | Series file line (rationale after `#`) | Upstream files touched (manifest `paths:`) |
|---|---|---|
| `chromium/0401-open-boost-color-blink.patch` | `0401-open-boost-color-blink.patch  # Step 4R: per-frame HSLA remap in Blink paint (GraphicsContext, Gradient, LocalFrameView)` | `third_party/blink/renderer/platform/graphics/graphics_context.{h,cc}`, `gradient.{h,cc}`, `third_party/blink/renderer/core/frame/local_frame_view.{h,cc}`, `web_local_frame_impl.{h,cc}`, `third_party/blink/renderer/platform/BUILD.gn` (or its graphics sources `.gni` — checkpoint §5.2) |
| `cef/0401-open-boost-color-api.patch` | `0401-open-boost-color-api.patch  # Step 4R: CefRequestContext/CefBrowser boost color API, frame push, browser binder` | `cef/include/cef_browser.h`, `cef/include/cef_request_context.h`, `cef/libcef/common/mojom/cef.mojom`, `cef/libcef/browser/browser_host_base.cc`, `cef/libcef/browser/request_context_impl.cc`, `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc` (binder), `cef/libcef/renderer/frame_impl.{h,cc}` (push receiver), `cef/BUILD.gn` (only if the `.gni` include needs a new entry — prefer extending `open_libcef_sources.gni` with no BUILD.gn change) |
| `cef/0402-open-boost-color-renderer-agent.patch` | `0402-open-boost-color-renderer-agent.patch  # Step 4R: create BoostColorFrameAgent per RenderFrame` | `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc` only (one include, one line) |

Never hand-edit patch hunks; refresh via `engine-refresh-patches` and prove the round-trip
(`docs/engine-fork.md` patch workflow). Paths of different logical patches must not overlap —
0402 exists solely so the renderer-client file (shared with the ad-block agent hook) carries one
feature per patch.

### 10.2 Overlay (`Engine/fork/src/`, mirrors `chromium/src`)

```text
third_party/blink/renderer/platform/graphics/boost_color_filter.h
third_party/blink/renderer/platform/graphics/boost_color_filter.cc
cef/include/cef_boost_color.h
open/boost_color/boost_color_value.h            # shared C++ value + converters (CEF<->mojom<->blink layout)
open/boost_color/mojom/BUILD.gn                 # mojom("mojom") — open_engine.mojom.BoostColorHost
open/boost_color/mojom/boost_color.mojom
open/browser/boost_color/boost_color_registry.h
open/browser/boost_color/boost_color_registry.cc
open/browser/boost_color/boost_color_host.h     # BoostColorHost browser impl (UI thread)
open/browser/boost_color/boost_color_host.cc
open/browser/boost_color/boost_color_api.h      # entry points the CEF forwarders call
open/browser/boost_color/boost_color_api.cc
open/renderer/boost_color/boost_color_frame_agent.h
open/renderer/boost_color/boost_color_frame_agent.cc
open/renderer/boost_color/boost_color_agent_registry.{h,cc}   # only if the §5.5 map fallback is chosen
open/open_libcef_sources.gni                    # edited: add browser+renderer sources above
```

The Blink files are the one exception to "new code goes under `open/`": a class inside the
`blink_platform` target must be listed in that target's sources, so the files live at their
upstream path via the overlay and the BUILD.gn hook adds them. Everything else follows the P1
precedent (`open/browser/tab_strip/*`).

### 10.3 GN changes

- `open/boost_color/mojom/BUILD.gn`: `mojom("mojom") { sources = [ "boost_color.mojom" ] }`
  (shape-copy `open/adblock/mojom/BUILD.gn` — adblock-fork §8.2; deps: none beyond mojom
  defaults if the URL stays a `string`).
- `open/open_libcef_sources.gni`: add the six browser/renderer `.cc` files; they compile into
  `libcef_static` like the tab-strip sources. New deps for that target, if not already present
  (checkpoint): `//open/boost_color/mojom`, `//url`, `//mojo/public/cpp/bindings`. The renderer
  agent includes Blink core headers (`web_local_frame_impl.h`) — checkpoint: `libcef_static`
  already depends on the Blink targets that make this header available (CEF's `frame_impl.cc`
  compiles in the same target and includes Blink headers today).
- Blink hook (patch 0401): two filenames in the platform sources list. No new GN target.
- No `args.gn` change. No feature flag: the code is inert without a registered matrix (§5.2
  identity rule). Do not add a kill switch beyond "App registers nothing".

### 10.4 Rebase watch (add to the rebase checklist when these land)

| Upstream file | Why it will conflict | Watch for |
|---|---|---|
| `graphics_context.cc` (`DarkModeColor`, `DarkModeFlags`) | Auto-dark is actively refactored upstream (new `ScopedAutoDarkModeState`, image policies) | Helper renames; keep the Boost branch to one `if` in each helper so re-applying is trivial |
| `dark_mode_filter.*`, `graphics_context.h` (`AutoDarkMode`, `ImageDrawOptions`) | Same refactor surface | `ImageDrawOptions` constructor changes hit §5.3's new field |
| `gradient.cc` | Stop-color handling moves with CSS gradient work | The `is_dark_mode_enabled_` block is the anchor; re-find it by that member name |
| `local_frame_view.cc` paint entry | Lifecycle/paint churn | Anchor on `GraphicsContext graphics_context(*paint_controller)` |
| `cef/libcef/common/mojom/cef.mojom` | CEF adds frame methods per branch | Our one method re-adds cleanly; check method-id ordering rules in the new branch file |
| `chrome_content_renderer_client_cef.cc` | Shared with ad-block's agent hook (same function) | Series order: keep ad-block's renderer-hook patch and 0402 adjacent; resolve by keeping both `new` lines |
| `chrome_content_browser_client_cef.cc` `ExposeInterfacesToRenderer` | Shared with ad-block's binder | Same: keep both binder registrations |
| `cef/include/cef_browser.h`, `cef_request_context.h` | API additions per CEF branch | Re-run the version manager; never merge generated C API by hand |

## 11. Acceptance checks (all must be able to fail)

No unit tests (rule 6). Two harnesses, both real-app/real-engine:

- **OpenBoosts harness** (Swift, existing `boosts` check in `tools/verify-all.sh`): matrix-builder
  numeric cases (§9.1) — S2-22 inputs produce §7.3's predicted outputs; identity rule; planner
  never emits both `colorMatrix` and a page `colorAdjustment`.
- **Engine e2e**: new suite `boostcolor` in `tools/e2e/engine_e2e.py` (`--only boostcolor`,
  choices list at `engine_e2e.py:3736`), run under the on-screen lock (rule 11):
  `/usr/bin/lockf /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --style chrome --only boostcolor`.
  The suite serves `tools/e2e/fixtures/boost-color/` from a local HTTP server on an ephemeral
  port (two origins: `127.0.0.1` and `localhost`, for the cross-origin iframe), creates Boosts
  through the real automation/store path, and reads pixels from automation window snapshots
  (`docs/automation.md` `snapshot`) at named fixture coordinates. Pixel decode: reuse the pixel
  helpers the `sidebar-compare`/snapshot checks already use (checkpoint: `tools/verification/check.py`);
  if none fits, add a minimal stdlib PNG reader to the suite — no new dependency. Every check
  prints the expected and read RGB values. `getComputedStyle` and canvas `getImageData` are
  **not** valid probes (by design they report unremapped values, §3.3) — one check (G11) asserts
  exactly that.

Fixture pages (shell helper, §12 S3): `fixture.html` (§8 capture fixture — the same file the user
opens in Arc), `frame.html` (grey ramp, used as iframe content on both origins), `scheme.html`
(`prefers-color-scheme` background flip), `heavy-1.html` (5,000 bordered/text divs, tall),
`heavy-2.html` (500 gradient/shadow boxes, tall), `heavy-3.html` (mixed text + 200 images, tall).

### 11.1 Pixel and behavior gates

| # | Check | Pass |
|---|---|---|
| G1 | White page: Boost with S2-22 inputs (θ 252°, ρ 0.69) on `fixture.html`; probe the `#FFFFFF` and `#FCF5E6` swatches | Within ΔE00 3 of `#E4E2F3` / `#D4C7F8` |
| G2 | Dark page: probe `#222222`, `#333333` swatches | Within ΔE00 3 of `#56285D` / `#632F6F` |
| G3 | Untouched regions: raster `<img>` swatch, CSS `background-image` swatch, canvas rect | Each channel within 1 level of the no-Boost baseline shot of the same run |
| G4 | Remove while showing: delete the Boost's color via automation; page JS marker (`window.__alive`) survives; re-probe G1–G3 points | All points back within 1 level of baseline; marker intact (no reload) |
| G5 | Iframes: `fixture.html` (127.0.0.1) embeds `frame.html` same-origin and cross-origin (localhost). Pattern matches only 127.0.0.1 | Same-origin frame remapped (its `#FFFFFF` within ΔE00 3 as G1); cross-origin frame unchanged. Second pass with per-tab apply: both frames remapped (§5.4 precedence) |
| G6 | Process swap: from the boosted page, navigate the tab cross-site to `frame.html` on the other origin (registered), screenshot at load-complete | First screenshot already remapped (pull, no flash frame in between: also assert no intermediate automation snapshot taken during the wait shows the unremapped white — best-effort, recorded either way) |
| G7 | Live preview latency: `applyBoostColor` via a store edit; poll the white swatch | Pixel reaches the G1 value in < 100 ms (site-control success criterion 2) |
| G8 | Performance (§11.3) | Budgets below |
| G9 | Back/forward: boosted page → other page → back (BFCache-eligible) | Remapped on return; then disable the Boost while on the other page, go back again → unremapped (BFCache re-pull) |
| G10 | Scheme: Boost with appearance dark on `scheme.html` (incl. its cross-origin iframe case, §5.6 checkpoint) | `matchMedia('(prefers-color-scheme: dark)')` true by eval; background pixel is the page's dark value; clearing restores light |
| G11 | DOM truth: with the remap on, `getComputedStyle(document.body).backgroundColor` and canvas `getImageData` | Original values (paint-only effect, §3.3) |
| G12 | Two Boosts, one host (one wheel, one legacy-filter) | Exactly one color system active (planner rule §9.4): pixel matches the winner's prediction, and `boosts color` readback names the winner |

B2 (site-control §8.2, line 1277) is rewritten when this lands, per the Step 4R acceptance text:
pad drag → probe a white background pixel (tinted) and an image pixel (unchanged) instead of
`getComputedStyle().filter`. That edit belongs to the site-control plan's owner; this plan's PR
does not touch that file — the rewrite rides the Step 4R implementation PR that flips the App.

### 11.2 Break proof (review checklist §4)

Run `--only boostcolor` once against a `CEF_SOURCE=cdn` build (OpenEngine no-ops, §9.2):
G1, G2, G5, G7, G10 must FAIL with unremapped pixels, G3/G11 PASS. Record the FAIL lines in the
implementation PR, then the PASS run on the fork build. A gate that passes on both builds proves
nothing and must be rewritten.

### 11.3 Performance budgets (the §7 Step 4R gates, made numeric)

Method (paired, same app run where possible; Release, M5 Pro, 2x; print load average with every
result; up to 3 attempts, report the median — review checklist §4 timing rule). Scroll measurement:
scripted continuous scroll of the heavy fixture for 3 s via automation, frame times collected from
`requestAnimationFrame` deltas in the page; paint cost from the same run's frame-time distribution
(the fixture is record-heavy by construction). Heavy pages are the local `heavy-1/2/3.html`
fixtures — hermetic, so the gate can run in review; real-site spot checks are manual, not gates.

| Gate | Budget |
|---|---|
| Zero-cost (no Boost color anywhere): scroll frame-time p95 on heavy-1, fork build vs the same build with patterns registered-then-unregistered (filter objects existed, now null) | Δp95 ≤ 0.5 ms **and** ≤ 2% (the noise band). This proves the null branch + dead registry cost nothing steady-state |
| Navigation cost (pull): time from navigation start to load-complete on `fixture.html`, registry empty, fork vs `CEF_SOURCE=cdn` build, median of 5 | Δ ≤ 10 ms (one sync IPC; anything larger means the binder is on the wrong thread) |
| One Boost color: scroll p95 on each of heavy-1/2/3, remap on vs off, same run | On ≤ off + 1.0 ms on each fixture; no fixture may miss 120 Hz (p95 ≤ 8.3 ms) solely because of the remap |
| Toggle cost: apply a matrix to the visible heavy-1 page | First remapped frame ≤ 100 ms (G7 shares this); exactly one full repaint (assert via the agent's repaint count if exposed, else by screenshot only — no partial-tile intermediate state is acceptable in the final screenshot) |
| Drag: 2 s of 60 Hz matrix updates to the visible page | Page frame-time p95 during the drag ≤ pre-drag p95 + 4 ms (the R-3 threshold shape); if missed, the App coalescing drops to 30 Hz (§6.2) and the gate reruns |

Idle CPU stays at the existing near-zero budget: the registry and agents hold no timers.

## 12. Work order

Engine steps are sized for the one tree-owning engine agent and run in order; each ends with the
tree in a buildable state and the patch refreshed. Shell steps need no tree build and run in
parallel from day one. Estimates are guesses for planning, not commitments.

| Step | Owner | Work | Proof before moving on |
|---|---|---|---|
| E1 | engine | Blink filter + hook + gradient (§5.1–5.3, patch 0401). No transport yet: temporarily drive `SetBoostColorMatrix` from an env-var-reading line in the agent-less build? **No** — instead land E1 together with the header + a `cefsimple` smoke (engine smoke checklist) and keep the matrix unreachable until E2. Revert plan: the patch is inert (null pointer everywhere) | Dev build green (`engine-build`, own session per rule 9); cefsimple loads example.com; patch round-trip (`engine-apply` after manual revert, byte-identical — the P1 proof shape) |
| E2 | engine | Registry + mojom pull + cef.mojom push + renderer agent + scheme (§5.4–5.6, patches 0401-cef, 0402) | Dev build green; with S2's App wiring behind the capability check, G1–G3 pass by hand on the fixture |
| E3 | engine | CEF API surface (§5.4) + translator run + OpenEngine ObjC (§9.2) | App builds against the new headers (`heavy.sh tools/build.sh`); G1–G12 pass in the suite except perf |
| E4 | engine | Distrib (`engine-distrib --run` in its own session), app fetch, full e2e | `--only boostcolor` green incl. break proof (§11.2) on the CDN build |
| E5 | engine | Perf gates (§11.3); tune only if a gate misses (LRU size, binder thread, drag rate — in that order) | G8 table filled with measured numbers in the PR |
| S1 | shell | `BoostColorMatrix.swift` + planner fields + harness numeric cases (§9.1) | `boosts` harness green under `verify-all.sh --only boosts` (through `heavy.sh`) |
| S2 | shell | OpenWeb mirror types + `BoostEngineAdapter` registration/apply logic (§9.3), capability-gated so the App works on the current distrib (calls no-op) | App runs; existing `boosts` automation unchanged; filter runtime still live |
| S3 | shell | Fixtures (`fixture.html` etc., §11) + `boostcolor` suite skeleton with G1–G12 written against the spec | Suite runs and FAILs G1/G2/G5/G7/G10 on the current engine (this is the §11.2 break proof, recorded early) |
| S4 | shell | Flip: planner emits `colorMatrix`, applier payload drops the filter for wheel Boosts (§9.4), B2 rewrite handed to the site-control owner | Full suite green on the E4 distrib; `verify-all.sh` full run for the flip PR |

Landing order: S1–S3 can merge before E1–E5 (all inert). E1–E5 land as one engine PR series
(patches + overlay + OpenEngine), then S4 flips the runtime. Step 4R starts after #103 merges
(site-control §10); S1 depends on #103's `BoostColorWheel` type existing.

## 13. Open questions and guesses (each marked)

| # | Question | v1 behavior (guess unless noted) | Settles by |
|---|---|---|---|
| Q-B1 | Hue anchor law: input L, output L′, or stored-hue offset? (§7.3) | Input L, knob anchors | C-4R-1, C-4R-2 (Step 2.1) |
| Q-B2 | `s0(ρ)` curve; do `a`/`b` move with ρ? | Linear `0.58·ρ`; a/b fixed | C-4R-2 |
| Q-B3 | Do saturated colors keep part of their hue? | No (m0 = 0) | C-4R-3 (Step 2.3, may need an engine term) |
| Q-B4 | Slider maps for `a`, `b`, `k`; BO-17 `curves`/`points` relevance | §7.2 token maps | C-4R-8 |
| Q-B5 | Gradient stops remapped or skipped? | Remapped per stop | C-4R-4 |
| Q-B6 | Inline SVG vs SVG-as-image | Inline remaps, image does not (falls out of §5) | C-4R-5 |
| Q-B7 | Scheme scope and whether Arc's int is appearance at all (BO-23c) | Appearance, top-level page scope | C-4R-9; BO-23 left the int encoding undetermined — ours is our own enum |
| Q-B8 | Per-tab apply covering non-matching subframes | Yes (whole WebContents) | Capture C-4R-9's iframe half; Arc's `applyColorFilter:` is per web contents (name only) |
| Q-B9 | Print, PDF chrome, extension popups, DevTools | Excluded (Open choice, §6.4) | Lead decision if a user-visible gap appears; no capture planned |
| Q-B10 | Peek / Little Open recoloring in Arc | Applies | C-4R-10 |
| Q-B11 | Form controls, scrollbars, selection highlight | Remapped (they paint solid colors through `GraphicsContext`; overlay scrollbars paint in cc — checkpoint: if the Mac scrollbar path bypasses Blink paint, scrollbars stay original and that is accepted for v1) | C-4R-11 |
| Q-B12 | `invertLightness` row form | `L′ = 1 − (aL + b)` | C-4R-7 |
| Q-B13 | Arc's exact paint hook and cache (BO-23d/g) | Not needed: Open matches pixels, not the hook (Open choice) | — |
| Q-B14 | Error pages pulling with the failed URL (§6.4) | Remap accepted in v1 | Implementer checkpoint during E2 |
| Q-B15 | `baseAppearance` (BO-17) vs `invertLightness` driving the scheme: which editor control sets Open's scheme? | The editor has no appearance control in the captured UI; Open sends `.none` until site-control adds one (the channel ships now so the engine needs no second change) | Site-control plan decision; C-4R-9 if Arc exposes one |
| Q-B16 | Wide-gamut (`display-p3`, `oklch`) solid colors: exact Arc behavior unknown (Arc's HSL is presumably sRGB too) | Convert as stored, clamp (§5.1); e2e probe asserts no crash and a stable color, not parity | Future capture if p3-heavy sites look wrong |

## 14. Review checklist self-run (this docs PR)

Per `docs/review-checklist.md`; N/A where the item cannot apply to a plan-only change. The
implementation PRs run the full list for real; §11 above is written so items 4.x can be answered
with commands, not prose.

| Item | Result | Evidence |
|---|---|---|
| 1. Input and memory limits | N/A (docs) — planned: matrix is fixed 20 floats at every boundary (ObjC nil on ≠20, mojom `array<float,20>`, LRU 256); pattern strings validated in OpenEngine | §5.4, §9.2 |
| 2. Lifetimes and callbacks | N/A (docs) — planned: per-tab registry entries cleared on browser close; equal-value pushes no-op; no callback frees its caller (push is fire-and-forget mojo) | §6.1, §5.2 |
| 3. Real event paths | N/A — no keys or focus paths | — |
| 4. Checks that prove the change | PASS for the plan: every gate names its failing mode, incl. the CDN-build break proof and per-check pixel values | §11 |
| 5. UI and motion | N/A (docs) — no UI in this plan; the editor plan owns Reduce Motion | — |
| 6. Docs and comments | PASS: this file is the doc; numbers cite their source (BO-23, S2-22, tree line numbers) and guesses are marked | §2, §7.2, §13 |
