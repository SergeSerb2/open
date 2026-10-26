# Ad blocking in the fork — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not spawn subagents (AGENTS.md rule 8). Do not write unit tests (rule 6).
Verify end to end only: real build, real `cefsimple`, real page loads over
HTTP, Chrome DevTools Protocol (CDP) for page-state checks.
This file is the complete context. The implementer has no other context.
If a fact in this file conflicts with a real file in the repo or in
`~/Developer/open-engine`, stop and report the conflict. Do not redesign
silently.

Authoritative inputs (read before you start):

- [adblock-design.md](../adblock-design.md) — the decision this plan
  implements. Locked: Brave `adblock-rust` crate `adblock` **0.8.11**,
  MPL-2.0, in the **browser process**, matched via a
  `blink::URLLoaderThrottle`, cosmetic filters + scriptlets injected at
  document start. Measured on EasyList + EasyPrivacy: ~2.15 µs per network
  check, 6.78 MiB serialized engine (DAT), ~47 ms DAT load, ~130 ms engine
  build from text, ~36 µs per cosmetic page query. Do not re-decide the
  engine.
- [fork-infra.md](fork-infra.md) — patch layout and scripts. This plan uses
  them, it does not replace them: overlay `Engine/fork/src/open/...` maps to
  `//open/...` in the Chromium tree, patches live in
  `Engine/fork/patches/{chromium,cef,rust}/` with `series` + `manifest`
  files, Rust crates enter via `gnrt`, builds run through
  `Engine/fork/scripts/engine-apply` / `engine-build` (bounded
  `-j 10` + `nice` + `caffeinate`, detached for long jobs, AGENTS.md rule 9).
- [features-advanced.md](../re/features-advanced.md) §7 (AD-1…AD-8) — the
  Arc bar: native blocker separate from extensions, master key
  `nativeAdBlockEnabled`, per-Profile list sets (`blockListsPerProfile`,
  `enabledBlockLists`, `defaultEnabledBlockLists`), 46 lists in 5 categories
  (generic 3, cookies 2, privacy 5, regional 35, bcny 1; only EasyList +
  EasyPrivacy bundled), remote manifest + per-list ETag updates (`304`
  keeps cache, unknown IDs skipped, EasyList `Expires: 4 days`), per-site
  disable in the Site Control Center (`setAdBlockExcludedDomains`, scope
  dialog, reload follow-up), Settings catalog UI, "Copy AdBlock debug info".
  Arc's own engine is custom (`arc/components/ad_blocker/ad_blocker_service.cc`
  + renderer `AdBlockerAgent::ShouldBlockRequest` /
  `::GenerateCosmeticFilterStylesheet`, `ArcWebContents.blockedResourceCount`).
  Open copies that **shape** (browser-owned engine, per-frame cosmetic
  agent, per-tab counter), not Arc code or assets (AGENTS.md rule 1).

Prerequisite gate (check first, stop if false):

1. fork-infra Steps 1–7 are done: `Engine/fork/` exists with `VERSIONS`,
   `scripts/engine-apply`, `scripts/engine-build`, `scripts/engine-status`,
   and a stock `cefsimple` build is green in
   `~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64`.
2. No build is running:
   `pgrep -fl 'autoninja|siso' || echo "no build running"`.
   Never run `gclient`, `gn`, `ninja`, `autoninja`, `git checkout`, or
   `git apply` by hand in the shared tree. Use the fork-infra scripts.
3. Pins still match fork-infra `VERSIONS`: Chromium `156.0.8078.48`
   (`d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`), CEF branch `8078`
   (`4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f`), Chromium Rust toolchain
   `rustc 1.100.0 1edd55dcfcd573872c727fa3e086369a71661ee0`
   (`third_party/rust-toolchain/VERSION` in the tree). The system
   `cargo 1.99.1` from the design benchmark is **not** the build toolchain.
   Every Rust build below must pass under the Chromium toolchain.

How to use this plan:

1. Work §10 in order. Each step lists exact files, signatures, and
   acceptance checks. A step is done only when every check passes. Paste
   real command output into the PR description.
2. Write files only where §3 says. New code is overlay
   (`Engine/fork/src/...`). Existing-file edits are patch files produced by
   the fork-infra §8 workflow (edit tree → `engine-refresh-patches` →
   review the `.patch` in this repo → prove the round-trip). Never
   hand-edit a `.patch` file.
3. User-visible text never uses the Arc brand. Exception: "Import from Arc"
   (not used by this plan). The product name is **Open**. Internal symbols
   use the `Open` / `open::` prefix, never `Arc`.

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Rust vendoring | `adblock 0.8.11` + transitive closure via `gnrt`, captured as `patches/rust/0001-adblock-vendor.patch`, license rows (§4) |
| Rust shim | `//open/adblock/rust` CXX bridge crate: build / serialize / deserialize / check / cosmetic / CSP (§5) |
| C++ service | `//open/adblock`: `OpenAdBlockService` per `CefBrowserContext` (one per Open Profile), atomic engine swap, per-site allowlist, status (§6) |
| Network blocking | `OpenAdBlockURLLoaderThrottle` via a new `ChromeContentBrowserClientCef::CreateURLLoaderThrottles` override; block / redirect / `$removeparam` / CSP; main frame never blocked; per-tab counters (§7) |
| Cosmetic + scriptlets | Per-frame stylesheet + scriptlets at document start via one new method on each existing `cef.mojom` frame interface + a renderer agent in `CefRenderFrameObserver::DidCreateScriptContext`; generic-hide via class/ID token reports; `generichide` / `#@#` exceptions (§8) |
| Lists | Bundled EasyList + EasyPrivacy fetched at build time from official URLs with pinned SHA-256 (never from Arc's bundle or mirror); uBlock Origin resources file for scriptlets/redirects; per-Profile storage, ETag update flow, DAT fast startup (§9) |
| CEF API | New methods on `CefRequestContext` + `CefBrowserHost` in `cef/include/*.h`, translator regeneration, `libcef` implementations (§11 Step 6) |
| OpenEngine + Swift | ObjC++ surface in `Engine/OpenEngine/` and the Swift `AdBlockStore` contract for `OpenFeatures` (§12) |
| Acceptance | `cefsimple` smoke harness (test-only patch), local test site, CDP checks, perf budgets (§13) |

### 0.2 Out of scope (do not build)

- Settings / Site Control Center **UI**. This plan delivers the engine and
  the API the UI calls (§12). UI lands in the M6 app milestone.
- The full 46-list **catalog UI** and regional-list auto-enable by locale.
  The data contract (§9.4) carries all 46 IDs from day one; v1 enables
  EasyList + EasyPrivacy by default.
- Import from Arc of ad-block settings. The Swift store (§12.3) uses Arc's
  key names so the importer can fill it later; importing is M8.
- Web Store extension blockers and the multiple-blocker warning (AD-1).
  The native engine must stay independent of extensions; the warning is UI.
- `$redirect` to binary resources (images, media). v1 redirects scripts
  only and blocks everything else that matches a redirect rule (§7.4).
- Procedural cosmetic operators that the crate returns as style/remove
  actions are applied (§8.3); operators the crate does not resolve
  (for example raw extended-CSS in regional lists) are dropped by the
  crate, not by new Open code.
- A Mojo interface of our own (`open.mojom.*`). Cosmetic traffic reuses the
  existing `cef.mojom.RenderFrame` / `cef.mojom.BrowserFrame` interfaces
  (§8.2). This is the one deliberate deviation from Arc's shape (Arc has
  `arc.mojom.AdBlockerAgent`); it keeps the patch surface inside files CEF
  already owns.

### 0.3 Milestone fit

This is the ad-block half of M6 ("Site tools") in [plan.md](../plan.md),
built on the M0 engine spike. It depends on fork-infra Steps 1–7 and on
nothing in the Swift app except the §12 contract. `cefsimple` is the
acceptance vehicle until the Open app can host a tab.

---

## 1. Locked facts (do not re-derive)

Verified 2026-10-25 by read-only inspection of
`~/Developer/open-engine/chromium_git/chromium/src`. Re-check the starred
items at the step that uses them; if a value differs, stop and report.

| ID | Fact | Evidence |
|---|---|---|
| F-1* | CEF does **not** override `CreateURLLoaderThrottles`. `ChromeContentBrowserClientCef` inherits Chrome's. It **does** override `CreateThrottlesForNavigation` at `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:638`, delegating to Chrome + `throttle::CreateThrottlesForNavigation` | `grep -n CreateURLLoaderThrottles cef/libcef/browser/chrome/*` (no hit); read of the `.h` override list |
| F-2 | `content::ContentBrowserClient::CreateURLLoaderThrottles(request, browser_context, wc_getter, navigation_ui_data, frame_tree_node_id, navigation_id)` is called on the UI thread and returns `std::vector<std::unique_ptr<blink::URLLoaderThrottle>>` | `content/public/browser/content_browser_client.h:1750` |
| F-3 | `blink::URLLoaderThrottle` hooks: `WillStartRequest(network::ResourceRequest*, bool* defer)` (mutating `request->url` causes an internal redirect), `WillRedirectRequest`, `BeforeWillProcessResponse`, `WillProcessResponse(response_url, response_head, defer)` (headers mutable), and `Delegate::CancelWithError(int, std::string_view)`, `Delegate::InterceptResponse(...)` | `third_party/blink/public/common/loader/url_loader_throttle.h` |
| F-4 | `network::ResourceRequest` carries `url`, `request_initiator` (`std::optional<url::Origin>`), `destination` (`network::mojom::RequestDestination`), `is_outermost_main_frame` | `services/network/public/cpp/resource_request.h:91,205,246,255`; enum at `services/network/public/mojom/fetch_api.mojom:26` (`kDocument=3`, `kFrame=6`, `kIframe=7`, `kImage=8`, `kScript=13`, `kStyle=16`, `kFont=5`, `kWorker=20`, `kServiceWorker=14`, …) |
| F-5 | Blocked loads surface as `net::ERR_BLOCKED_BY_CLIENT` | `net/base/net_errors.cc:87` |
| F-6* | Rust vendoring is the `gnrt` flow: direct deps in `third_party/rust/chromium_crates_io/Cargo.toml`, Chromium config in `gnrt_config.toml`, generated `third_party/rust/<crate>/v<epoch>/BUILD.gn` + `README.chromium`, sources in `third_party/rust/chromium_crates_io/vendor/<crate>-v<epoch>/`. Commands: `vpython3 tools/crates/run_gnrt.py {add,vendor,gen}` | `third_party/rust/README-importing-new-crates.md`; template `third_party/rust/adler2/v2/BUILD.gn` (a `cargo_crate("lib")` target, `visibility = ["//third_party/rust/*"]` until listed in `Cargo.toml`) |
| F-7 | First-party Rust uses `rust_static_library` with `cxx_bindings = ["src/lib.rs"]` for CXX bridges | `build/rust/rust_static_library.gni`; example `build/rust/tests/test_rust_static_library/BUILD.gn` |
| F-8* | `adblock 0.8.11` API (from the crate source in the local cargo registry, `~/.cargo/registry/src/*/adblock-0.8.11/`): `lists::FilterSet::add_filter_list(&str, ParseOptions)`; `Engine::from_filter_set(set, optimize=true)`; `Engine::serialize_raw() -> Vec<u8>`; `Engine::deserialize(&mut self, &[u8])`; `Engine::check_network_request(&Request) -> BlockerResult{matched, important, redirect: Option<String>, rewritten_url: Option<String>, exception, filter}`; `Engine::get_csp_directives(&Request) -> Option<String>`; `Engine::url_cosmetic_resources(url: &str) -> UrlSpecificResources{hide_selectors, style_selectors, remove_selectors, remove_attrs, remove_classes, exceptions, injected_script, generichide}`; `Engine::hidden_class_id_selectors(classes, ids, exceptions: &HashSet<String>) -> Vec<String>`; `Engine::use_resources(iter)`, resources are `resources::Resource{name, aliases, kind, content (base64), dependencies, permission}`; `Request::new(url, source_url, request_type: &str)` where the type string accepts `"script"`, `"image"`, `"stylesheet"`, `"font"`, `"media"`, `"subdocument"`, `"document"`, `"websocket"`, `"xhr"`, `"ping"`, `"other"`, … and computes first/third-party itself from the two URLs' registrable domains | `src/engine.rs`, `src/request.rs`, `src/blocker.rs:29`, `src/cosmetic_filter_cache.rs:22`, `src/resources/mod.rs:126` |
| F-9 | With default features (`object-pooling` via `lifeguard`, `unsync-regex-caching`) the crate only asserts `Engine: Send + Sync` when those features are **off**. §5 therefore disables them, keeping `Engine: Send + Sync` so the C++ service can share one engine across throttle calls under a read lock | `src/engine.rs` `_assertions` block; `[features]` in the crate `Cargo.toml` |
| F-10 | CEF frame JS today is **not** document-start: browser `CefFrameHostImpl::ExecuteJavaScript` → `cef.mojom.RenderFrame::SendJavaScript` → renderer `CefFrameImpl::SendJavaScript` → `WebLocalFrame::ExecuteScript`, which runs whenever the Mojo call arrives. The renderer hook that **is** document-start is `CefRenderFrameObserver::DidCreateScriptContext` (`cef/libcef/renderer/render_frame_observer.cc:129`), which calls `CefRenderProcessHandler::OnContextCreated` and then `CefFrameImpl::OnContextCreated`, draining `queued_context_actions_` | Reads of `cef/libcef/browser/frame_host_impl.cc:178,423`, `cef/libcef/common/mojom/cef.mojom:73`, `cef/libcef/renderer/frame_impl.cc:169,404,874`, `cef/libcef/renderer/render_frame_observer.cc:129` |
| F-11 | `cef.mojom` already defines the two frame interfaces cosmetic traffic needs: `RenderFrame` (browser→renderer: `SendJavaScript`, `SendMessage`, `SendCommand`, …) and `BrowserFrame` (renderer→browser: `SendMessage`, `FrameAttached`, …). Mojo bindings regenerate from `cef/libcef/common/mojom/cef.mojom` via GN; the CEF **translator does not** process Mojo files | `cef/libcef/common/mojom/cef.mojom:50,84` |
| F-12 | New CEF C++ API in `cef/include/*.h` (methods marked `/*--cef()--*/`) generates the C API (`cef/include/capi/*_capi.h`, `cef/libcef_dll/cpptoc/`, `cef/libcef_dll/ctocpp/`) with `cef/tools/translator.py` (run via `cef/tools/translator.sh`). New API must be guarded with `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`; never use `CEF_API_VERSION_NEXT` (999998) in committed code | `cef/tools/translator.README.txt`; `cef/include/cef_api_hash.h:40-90` |
| F-13* | Per-Profile browser object: `CefBrowserContext` (`cef/libcef/browser/browser_context.h:92`, UI thread, self-deletes when the last `CefRequestContextImpl` releases it). Accessors that exist today: `CefBrowserContext::FromBrowserContext(const content::BrowserContext*)`, `CefRequestContextImpl::browser_context()` (`cef/libcef/browser/request_context_impl.h:233`), `CefBrowserHostBase::GetWebContents()` (`cef/libcef/browser/browser_host_base.h:401`). CEF keeps **no** `KeyedService` registrations of its own | Reads of the three headers; `grep -rn KeyedService cef/libcef/browser/` (no hits) |
| F-14 | The 46-list catalog shape is `KnownBlockList{id, display_name, type, info_url, urls[], resource_name?}`. Arc's URLs are Arc's mirror (`https://dia-blocklists-release.diabrowser.engineering/<upstream path>`). The upstream URL is recovered by replacing that prefix with `https://` (for example `…/easylist.to/easylist/easylist.txt` → `https://easylist.to/easylist/easylist.txt`). Open never fetches the Arc mirror (adblock-design §"List catalog"; features-advanced AD-4) | `.re/features-advanced/blocklist-manifest.json` (git-ignored raw data; the committed transform is §9.4) |
| F-15 | Budgets from the design benchmark (Apple Silicon, release, system cargo — re-measure in-tree at Step 9): network check ~2.15 µs, cosmetic page query ~36 µs, DAT 6.78 MiB / ~47 ms load for EasyList + EasyPrivacy, text build ~130 ms + ~30 ms parse. App budgets: cold launch to first paint ≤ 700 ms, idle CPU ≈ 0% | [adblock-design.md](../adblock-design.md) §Benchmark, [architecture.md](../architecture.md) §Performance budgets |

### 1.1 Lessons that are rules in this plan

| Rule | Why |
|---|---|
| The engine is consulted **synchronously** in the throttle. No Mojo hop, no CEF callback object per request | 100–300 subresources per page; the design's 0.2–0.7 ms per page assumes an in-process call (F-15) |
| Cosmetic data is computed **once per frame navigation** in the browser and pushed to the renderer before its context runs page scripts (§8). Generic selectors are the only ongoing traffic, debounced in the page | A `MutationObserver` in Blink or per-element style queries would be new Blink code with rebase risk on every `Document` refactor (adblock-design Option A, patch point 4) |
| A failed list rebuild **keeps the old engine**. A failed DAT load falls back to a text build. Neither failure disables blocking silently: status (§6.4) records `last_error` and OpenEngine surfaces it | Arc keeps the cache on `304`/failure (AD-4); a browser that silently stops blocking is worse than one that blocks with old lists |
| Exclusions and the master toggle take effect on the **next navigation**, with no engine rebuild and no restart | The throttle and the cosmetic path check them per request / per navigation (§7.2, §8.4). The Site Control Center reload follow-up (SC-6) is then sufficient |
| Never block the outermost main frame, whatever the lists say | A `$document` or broad rule must not be able to brick navigation. Exceptions inside the crate (`@@`, `$important`) still apply to subresources (§7.4) |

---

## 2. Key decisions

| # | Decision | Rejected alternative | Reason |
|---|---|---|---|
| D-1 | Rust enters **only** via `gnrt` vendoring (fork-infra D-6). The C++ side links the generated `//third_party/rust/adblock/v0:lib` target through our own shim crate (§5) | Brave-style "run cargo, link a prebuilt `libadblock.a`" (adblock-design's first sketch) | The Chromium way survives rebases, uses the pinned toolchain (F-12 in fork-infra), and generates the `README.chromium` license records. fork-infra §7 already superseded the build mechanics; this plan follows it |
| D-2 | The FFI is **one CXX bridge** in `//open/adblock/rust`. All Rust types cross as strings, string vectors, and three flat structs (§5.2). The browser renders CSS text in Rust; C++ never sees a selector container | Hand-written `extern "C"` with manual memory management; returning `UrlSpecificResources` field-by-field to C++ | CXX is the tree's supported bridge (F-7). Pre-rendered strings keep the C++ cosmetic code to "insert this text" and keep crate-type churn inside the shim on crate bumps |
| D-3 | Shim features: `default-features = false`, features `embedded-domain-resolver`, `full-regex-handling`, `resource-assembler`. **Off:** `object-pooling`, `unsync-regex-caching` (keeps `Engine: Send + Sync`, F-9), `css-validation`, `content-blocking` | Default features | A non-`Sync` engine forces a mutex around every 2 µs check and serializes all tabs in a Profile. Pooling/caching are micro-optimizations; thread-safety is the design's core assumption. `resource-assembler` is on so the shim can parse uBlock Origin's resources format (§9.3) |
| D-4 | Service ownership: one `open::OpenAdBlockService` per `CefBrowserContext`, owned by a new `std::unique_ptr` member on `CefBrowserContext` itself (small `cef/` patch, §6.1) | `BrowserContextKeyedServiceFactory` registration in Chrome's profile-service list; a global `BrowserContext* → service` map | CEF registers no keyed services (F-13); a global map needs its own shutdown observer and leaks on context churn. A member dies exactly with the context, in both Alloy and Chrome runtimes, and every caller already knows how to reach the context (F-13) |
| D-5 | Throttle creation is a new `ChromeContentBrowserClientCef::CreateURLLoaderThrottles` **override** that calls the Chrome base implementation first, then appends ours when enabled (§7.1) | Only the zero-patch stepping stone `CefResourceRequestHandler::OnBeforeResourceLoad` in OpenEngine | The CEF handler misses worker, WebSocket, and WebTransport loads and pays a CEF callback round-trip per request (adblock-design Risk 5). The stepping stone is kept as the documented fallback if the override patch must be dropped in a rebase (§7.6) |
| D-6 | Cosmetic delivery reuses `cef.mojom.RenderFrame` / `BrowserFrame` with **one new method on each** (§8.2), applied by the existing renderer observer at `DidCreateScriptContext`. No new Mojo file, no Blink patch | (a) `CefFrame::ExecuteJavaScript` at `OnLoadStart` — too late, ads flash and scriptlets miss early page scripts. (b) A new `open.mojom` + `RegisterBrowserInterfaceBindersForFrame` binder + associated interface — correct but a new interface, a new renderer receiver, and a new patch in the binder registry, for the same timing the queued `cef.mojom` call already gets (F-10) | (b) is the fallback if the `cef.mojom` change proves unstable across a CEF bump; record the trigger in the PR if you switch |
| D-7 | Per-tab blocked counts live in `open::OpenAdBlockTabHelper`, a `content::WebContentsUserData` + `WebContentsObserver` created lazily by the throttle factory (§7.5) | A counter map inside the service keyed by `WebContents*` | UserData dies with the WebContents; a service-side map needs explicit erase on every close path (Split View, Peek, Little Open create and destroy contents at a high rate) |
| D-8 | List **download** is Swift (`URLSession`, ETag, atomic writes); list **parse/build/serialize** is C++ in the browser process. The CEF call passes a **directory**, not list text (§9.2, §11 Step 6) | Downloading in C++ with `network::SimpleURLLoader`; passing 3.6 MB of text across the CEF API per update | Swift owns the Profile's files and schedule everywhere else in Open (architecture.md persistence table). A directory path keeps the CEF surface small, lets the browser read off the UI thread, and makes the DAT sit next to its source lists |
| D-9 | Bundled lists are **fetched at build time** by `tools/fetch-adblock-lists.sh` from the official URLs, verified against SHA-256 pins committed in this repo, and staged under `Vendor/adblock/` (git-ignored). List text is never committed, and never taken from `/Applications/Arc.app` | Committing `easylist.txt` / `easyprivacy.txt` to the repo; copying Arc's bundled copies | AGENTS.md rules 1/3/5 plus adblock-design §"List catalog": facts (URLs, IDs) are fine, Arc's files are not a source. Pins give reproducibility; `--update-pins` is a reviewed, deliberate action (§9.1) |
| D-10 | CEF API additions go on **existing** classes — `CefRequestContext` (per-Profile control) and `CefBrowserHost` (per-tab count) — guarded `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`. No new `CefAdBlock*` classes in v1 | A new `CefAdBlockManager` singleton class + a new handler interface for count callbacks | Two classes' worth of translator output, two impl classes, and a callback registration lifetime to design, to deliver what six methods on classes the client already holds deliver. Count **change callbacks** are deferred: OpenEngine polls on panel open and on load end (§12.2), which is what the Site Control Center needs (SC-6 shows the count for the current load) |

---

## 3. Repo layout for this plan

### 3.1 Files in this repo (`/Users/serge/.t3/projects/open`)

```text
Engine/fork/
  patches/
    chromium/
      series / manifest            # + entries from §3.3 (append; fork-infra owns format)
    cef/
      series / manifest            # + entries from §3.3
    rust/
      series / manifest            # + 0001-adblock-vendor.patch (Step 1, generated)
  src/                             # overlay → chromium/src/
    open/
      BUILD.gn                     # group("open") { deps = ["//open/adblock"] } (§5.4 note)
      adblock/
        BUILD.gn                   # //open/adblock targets (§6.5)
        open_adblock_service.h/.cc
        open_adblock_url_loader_throttle.h/.cc
        open_adblock_navigation_throttle.h/.cc
        open_adblock_tab_helper.h/.cc
        open_adblock_types.h       # shared enums/structs (§6.2)
        rust/
          BUILD.gn                 # //open/adblock/rust:open_adblock_rust (§5.4)
          src/lib.rs               # CXX bridge shim (§5.2–5.3)
        testdata/
          index.html               # local test page (§13.2)
          ads/banner.js            # served file the network rule blocks by path
          track/pixel.gif          # 1×1 GIF (generate per §13.2; do not copy any Arc asset)
          lists/testlist.txt       # hand-written rules for the test page (§13.2)
    cef/
      tests/cefsimple/…            # NO overlay files here — cefsimple changes are a patch (§3.3 P-6)
    third_party/rust/chromium_crates_io/
      Cargo.toml.open              # fork-infra §7.3 fragment, extended by §4.2 of this plan
      gnrt_config.toml.open        # fragment; §4.2 (empty unless gnrt needs a table)
  adblock/
    list-pins.txt                  # official URL + SHA-256 per bundled file (§9.1)
    catalog.json                   # the 46-list catalog with upstream URLs (§9.4, generated once, then committed data)
    resources-pins.txt             # uBlock Origin resources URL + SHA-256 (§9.3)
  licenses/
    THIRD_PARTY.md                 # + rows (§4.5)
    MPL-2.0.txt                    # Step 1, copied from the vendored crate (fork-infra §7.7)
Engine/OpenEngine/
  Sources/OpenEngine/
    include/OpenEngineAdBlock.h    # ObjC API (§12.1)
    OpenEngineAdBlock.mm           # implementation over the CEF C++ API (§12.1)
Packages/OpenKit/Sources/OpenFeatures/   # NEW Swift target only if OpenFeatures does not exist yet;
    AdBlockStore.swift             # §12.3 contract (may land with the M6 UI PR instead — see Step 8)
tools/
  fetch-adblock-lists.sh           # §9.1 (standalone; does not source fork scripts)
```

Notes:

- `src/open/BUILD.gn`: Chromium discovers `//open/...` targets by path; no
  root `BUILD.gn` or `.gn` edit is needed as long as every consumer depends
  on the full path. Create the one-file group target anyway so
  `engine-build --target open` has a stable name.
- Overlay files under `src/cef/` are **not** used by this plan. All CEF-side
  changes to existing files are patches (fork-infra §3.2). The one new file
  that must live beside CEF classes is none — the service is `//open/...`
  and CEF files only gain includes, a member, and method bodies that call
  into it.

### 3.2 What goes where (patch vs overlay)

Same rules as fork-infra §3.2. Summary for this plan: new code = overlay;
edits to existing Chromium/CEF files = one patch per logical change;
generated Rust output = `patches/rust/`; list data = fetched, never
committed (the catalog's IDs/names/URLs in §9.4 are facts and **are**
committed).

### 3.3 Patch inventory (create via fork-infra §8 workflow, in this order)

| Patch | Series | Target files in the tree | Change (detail in the step) |
|---|---|---|---|
| P-1 `0001-adblock-vendor.patch` | `rust` | `third_party/rust/**` (generated) | `gnrt vendor` + `gen` output for the §4 closure. Generated, never hand-edited (Step 1) |
| P-2 `0001-open-adblock-service-owner.patch` | `cef` | `cef/libcef/browser/browser_context.h`, `cef/libcef/browser/browser_context.cc` | `open_adblock_service()` accessor + member + shutdown hook (§6.1) |
| P-3 `0002-open-adblock-throttle-hook.patch` | `cef` | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.h`, `.cc`, `cef/BUILD.gn` (`libcef_static` deps) | `CreateURLLoaderThrottles` override appending both throttles' factory logic; `//open/adblock` dep (§7.1) |
| P-4 `0003-open-adblock-cosmetic-mojom.patch` | `cef` | `cef/libcef/common/mojom/cef.mojom`, `cef/libcef/browser/frame_host_impl.h/.cc`, `cef/libcef/renderer/frame_impl.h/.cc`, `cef/libcef/renderer/render_frame_observer.cc` | Two new methods per direction + renderer agent (§8.2). Mojo-generated files are build output, not patch content |
| P-5 `0004-open-adblock-cef-api.patch` | `cef` | `cef/include/cef_request_context.h`, `cef/include/cef_browser.h`, `cef/libcef/browser/request_context_impl.h/.cc`, `cef/libcef/browser/browser_host_base.h/.cc` + translator output under `cef/include/capi/`, `cef/libcef_dll/` | The §11 Step 6 API. Translator output files **are** committed in the tree and therefore appear in this patch; regenerate, never hand-edit them |
| P-6 `0005-open-adblock-cefsimple-smoke.patch` | `cef` | `cef/tests/cefsimple/simple_app.cc`, `cef/tests/cefsimple/simple_handler.cc/.h` | **Test-only.** Switch-gated harness (§13.1). Keep last in the series so it can be dropped without touching P-2…P-5 |

No `patches/chromium/` entries. If implementation proves a Chromium-side
hunk is required (for example a `BUILD.gn` dep that cannot live in
`cef/BUILD.gn`), stop and add it as `patches/chromium/0001-…` with the
fork-infra §8 round-trip proof, and note why in the PR.

Series order after this plan (append to the fork-infra files; numeric
prefixes are sort hints, the series file wins):

```text
# patches/rust/series
0001-adblock-vendor.patch  # gnrt vendor+gen output for adblock 0.8.11 closure (generated; adblock-fork §4)

# patches/cef/series (ad-block entries, after any existing entries)
0001-open-adblock-service-owner.patch   # CefBrowserContext owns open::OpenAdBlockService (adblock-fork §6)
0002-open-adblock-throttle-hook.patch   # CreateURLLoaderThrottles override appends OpenAdBlock throttles (§7)
0003-open-adblock-cosmetic-mojom.patch  # cef.mojom cosmetic push/report + renderer agent (§8)
0004-open-adblock-cef-api.patch         # CefRequestContext/CefBrowserHost ad-block API + translator output (§11 Step 6)
0005-open-adblock-cefsimple-smoke.patch # test-only cefsimple harness switches (§13)
```

Manifest blocks (fork-infra §6.4 format) mirror the target-file lists
above, one `# <file>.patch` + `paths:` block per patch. For P-1 the single
block is `paths: third_party/rust` (fork-infra §7.5).

### 3.4 GN targets introduced

| Target | Kind | Defined in |
|---|---|---|
| `//third_party/rust/adblock/v0:lib` | `cargo_crate` (generated) | `gnrt gen` output; exact epoch dir confirmed at Step 1 (expect `v0` for 0.8.11) |
| `//open/adblock/rust:open_adblock_rust` | `rust_static_library` with CXX bindings | overlay `open/adblock/rust/BUILD.gn` (§5.4) |
| `//open/adblock:adblock` | `source_set` | overlay `open/adblock/BUILD.gn` (§6.5) |
| `//open/adblock:adblock_hats` — **do not create**. No test targets (AGENTS.md rule 6) | — | — |
| `//open:open` | `group` | overlay `open/BUILD.gn` |

Consumers: `cef/BUILD.gn` target `libcef_static` gains
`deps += [ "//open/adblock" ]` (P-3). Nothing else links the service.
`cefsimple` links only CEF; the smoke harness (P-6) calls the public CEF
API, so it needs no `//open` dep.

---

## 4. Step 1 detail — vendoring `adblock` the Chromium way

Implements fork-infra §7.4 R1–R6 with this plan's pins. Run it as
fork-infra Step 8. All commands run in the Chromium tree **only** through
the fork-infra flow; the tree must be fully applied and idle first
(§Prerequisite gate).

### 4.1 Pins (already in `Engine/fork/VERSIONS` — verify, do not duplicate)

```sh
ADBLOCK_CRATE_VERSION=0.8.11
RMP_CRATE_VERSION=0.8.11
RUST_TOOLCHAIN_VERSION=1.100.0
```

### 4.2 The overlay fragments (exact content)

Replace the fork-infra §7.3 starter fragment
`Engine/fork/src/third_party/rust/chromium_crates_io/Cargo.toml.open` with:

```toml
# Open fragment. Merged into third_party/rust/chromium_crates_io/Cargo.toml
# by the Rust step (adblock-fork §4.3). Direct dependencies only; gnrt finds
# transitive deps. Pins: docs/adblock-design.md §Benchmark (adblock 0.8.11,
# MPL-2.0). Features per adblock-fork D-3: no object-pooling and no
# unsync-regex-caching, so Engine stays Send + Sync in the browser process.
[dependencies.adblock]
version = "=0.8.11"
default-features = false
features = ["embedded-domain-resolver", "full-regex-handling", "resource-assembler"]
```

Merge rule (fork-infra R1, restated for the table form): the fragment is a
`[dependencies.adblock]` **table**, not a one-line dep. When merging into
the tree's `Cargo.toml`, insert the table after the last `[dependencies.*]`
table and before any `[patch.*]` / `[profile.*]` section. If a plain
`adblock = "…"` line already exists from a fork-infra Phase-A merge,
remove it and insert the table (same version → not a conflict; a different
version → stop and report).

`rmp` pin: add the line below to the fragment **only if** Step 4.3's
`Cargo.lock` check shows `rmp` resolved to anything other than `0.8.11`
(the `rmp-serde 0.15` breakage in adblock-design F-13 is version-sensitive;
`adblock 0.8.11` declares `rmp-serde = "0.15"`, which selects `rmp 0.8.x`):

```toml
rmp = "=0.8.11"
```

If you add it, add a `licenses/THIRD_PARTY.md` row for `rmp` in the same
PR and a comment in the fragment: `# Direct pin only to hold rmp-serde
0.15's dependency at the tested version (adblock-fork §4.2).`

`gnrt_config.toml.open`: ship it with **no** `[crate.adblock]` table
(fork-infra §7.3 default). Add a table only when `gnrt gen` fails or
mis-generates, and record the reason in the fragment comment. Expected
non-issue to check at R3: the crate reads no `include_str!` files outside
its `src/`, so `extra_input_roots` should not be needed. Rule-of-2: do
**not** write `group = "sandbox"` — the design runs the engine in the
browser process (D-3 note in fork-infra §7.3 applies: if the generated
`README.chromium` marks the crate `sandbox`-only and GN then refuses the
`libcef_static` dep, stop and escalate to the lead; do not override
silently).

### 4.3 Vendor + gen procedure (exact commands)

From `~/Developer/open-engine/chromium_git/chromium/src`, with
`export_engine_env` active (fork-infra `common.sh`), no build running:

```bash
# R1. Merge the Cargo.toml fragment per §4.2 (by hand or with the
#     engine-apply --only rust helper if fork-infra implemented it there).
# R2. Vendor (needs network; downloads from crates.io):
vpython3 tools/crates/run_gnrt.py vendor
# R3. Generate BUILD.gn files:
vpython3 tools/crates/run_gnrt.py gen
# Inspect what was resolved before building anything:
grep -A2 'name = "adblock"' third_party/rust/chromium_crates_io/Cargo.lock
grep -A2 'name = "rmp"'     third_party/rust/chromium_crates_io/Cargo.lock
ls third_party/rust/adblock/            # expect: v0/BUILD.gn, v0/README.chromium
# R4. Build the crate alone under the Chromium toolchain:
Engine/fork/scripts/engine-build --target third_party/rust/adblock/v0:lib
# (use the real generated target name if the epoch dir is not v0)
```

R4 must use `engine-build` (bounded jobs), not a bare `autoninja`. If R2/R3
fails because `adblock 0.8.11` does not compile under `rustc 1.100.0`,
stop. Do not bump the crate, do not switch to system cargo, and do not
patch crate sources by hand. Report the compiler error verbatim; a crate
bump is a design change that reopens adblock-design §Benchmark (the
`rmp-serde` failure mode) and needs the lead.

### 4.4 Expected transitive closure (review list, not a pin list)

`gnrt` resolves the closure. Expect **at least** these crates to appear
under `third_party/rust/chromium_crates_io/vendor/` (versions from
`adblock 0.8.11`'s manifest; `gnrt` may select newer compatible patches —
record what it actually selected):

`addr`, `base64 0.13` (a second epoch beside Chromium's `base64 0.22` —
expected and supported by the `v<epoch>` layout), `bitflags 1`,
`idna 0.2`, `itertools 0.10`, `memchr`, `once_cell`, `percent-encoding`,
`regex`, `rmp`, `rmp-serde`, `seahash`, `serde`, `serde_json` (via
`resource-assembler`), `thiserror`, `url`, plus their own transitives
(`aho-corasick`, `regex-syntax`, `regex-automata`, `unicode-ident`,
`tinyvec`, `form_urlencoded`, `unicode-bidi`, `unicode-normalization`,
`matches`, `itoa`, `ryu`, `proc-macro2`, `quote`, `syn`, …).

At R5 (fork-infra §7.4), list every **new** vendor directory and check:

1. No license beyond MPL-2.0 / MIT / Apache-2.0 / BSD / Unicode-DFS appears.
   Any GPL/LGPL/AGPL crate → stop for lead review.
2. No crate duplicates a Chromium direct dep at the **same** epoch with a
   different version (epoch splits like `base64` are fine).
3. Every new crate gets a `THIRD_PARTY.md` row (§4.5) from its generated
   `README.chromium`. Do not type license names from memory.

### 4.5 Capture + licenses

Capture with fork-infra §7.5 (`git add -f third_party/rust …` +
`diff --cached` → `patches/rust/0001-adblock-vendor.patch`), add the
§3.3 series line, and copy the license text:
`cp third_party/rust/chromium_crates_io/vendor/adblock-v0/LICENSE
Engine/fork/licenses/MPL-2.0.txt` (use the real vendor path from R2; if
the file is named `LICENSE.txt` or split, copy what exists and note it).

`licenses/THIRD_PARTY.md`: the `adblock` row already exists (fork-infra
§7.7). Add one row per §4.4 crate in the same PR. Filter lists and the
uBlock Origin resources file are **data**, tracked in §9 pins files, not
in this table (fork-infra §7.7 rule).

Size gate: if `0001-adblock-vendor.patch` exceeds ~20 MB, stop and ask
the lead (fork-infra §7.5; lead decision on file: accept ~20 MB).

Acceptance for Step 1: §11 Step 1 list.

---

## 5. The Rust shim — `//open/adblock/rust`

One crate, one CXX bridge, no other Rust in this plan. It exists so that
crate-type churn (a future `adblock` bump) touches exactly one file.

### 5.1 Crate layout (overlay)

```text
Engine/fork/src/open/adblock/rust/
  BUILD.gn        (§5.4)
  src/lib.rs      (the whole shim; expect 350–500 lines)
```

The shim depends on `//third_party/rust/adblock/v0:lib` (GN name from
Step 1) and on nothing else directly: `serde_json` and `base64` reach it
through the `adblock` crate's public API (`Resource` (de)serialization).
If `lib.rs` needs a direct `serde_json` call that the `adblock` API does
not re-export, add `//third_party/rust/serde_json/v1:lib` to the shim's
GN `deps` and a `serde_json = "1"` line to the §4.2 fragment in the same
PR (it is already a Chromium direct dep, so no new vendoring).

### 5.2 CXX bridge surface (exact)

In `src/lib.rs`, one `#[cxx::bridge(namespace = "open_adblock")] mod ffi`.
Generated C++ lands in namespace `open_adblock`. Types:

```rust
pub struct OpenBlockerResult {
    pub matched: bool,          // a blocking rule matched (after exceptions)
    pub important: bool,        // an $important rule matched (informational for C++; the crate already applied precedence)
    pub has_redirect: bool,     // redirect body present (§7.4)
    pub redirect_data_url: String, // "" unless has_redirect; a complete data: URL (§5.3 rule R-5)
    pub rewritten_url: String,  // "" unless $removeparam rewrote the URL
    pub csp_directives: String, // "" unless get_csp_directives returned a value (document/subdocument only; §7.4)
}

pub struct OpenCosmeticResources {
    pub hide_css: String,        // "<sel>, <sel> { display: none !important; }" or ""
    pub style_css: String,       // "<sel> { <decl>; <decl>; }" blocks joined by "\n", incl. remove-as-style fallbacks (§5.3 R-7)
    pub injected_script: String, // scriptlet bundle text ("" if none); already wrapped (§8.3)
    pub exceptions: Vec<String>, // #@# generic exceptions, stored by the renderer, echoed back on token reports
    pub generichide: bool,       // $generichide: renderer must not report class/ID tokens
}

pub struct OpenEngineInfo {
    pub serialized_size: u64,    // bytes of serialize_raw() at build time (0 before first build)
    pub list_count: u32,         // FilterSet inputs consumed by the last build
}
```

Opaque Rust type and functions:

```rust
pub struct OpenAdblockEngine { inner: adblock::Engine }

pub fn open_adblock_create_empty() -> Box<OpenAdblockEngine>;
// Build a new engine from list texts (one String per enabled list, in the
// caller's deterministic order) plus the uBO resources file text (""
// = no resources). Blocking, CPU-heavy: C++ calls this on a background
// task runner only (§6.3). Never fails fatally: a list that parses to
// zero rules still produces an engine; parse problems are logged from
// Rust via eprintln! (visible in --enable-logging=stderr output).
pub fn open_adblock_build(list_texts: &[String], resources_text: &str)
    -> Box<OpenAdblockEngine>;
pub fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8>;
// Returns false on any deserialization error (version skew, truncation).
// C++ then falls back to a text build (§6.3). `engine` must be a
// create_empty() box.
pub fn open_adblock_deserialize(engine: &mut OpenAdblockEngine, dat: &[u8]) -> bool;
pub fn open_adblock_check(engine: &OpenAdblockEngine,
                          url: &str, source_url: &str, request_type: &str)
    -> OpenBlockerResult;
pub fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str)
    -> OpenCosmeticResources;
pub fn open_adblock_hidden_selectors(engine: &OpenAdblockEngine,
                                     classes: &[String], ids: &[String],
                                     exceptions: &[String]) -> Vec<String>;
pub fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo;
```

`request_type` strings are the crate's own vocabulary (F-8): C++ maps
`network::mojom::RequestDestination` through the §7.3 table and passes
the resulting string verbatim. `source_url` is the initiator/document URL
(§7.3); pass `url` itself when no initiator exists (first-party by
construction in the crate's domain comparison).

### 5.3 Shim implementation rules

- **R-1 (threading).** `OpenAdblockEngine` must be `Send + Sync`. Add at
  the bottom of `lib.rs`: `fn _assert() { fn is_send_sync<T: Send + Sync>() {} is_send_sync::<OpenAdblockEngine>(); }`.
  If this fails to compile, a feature crept back on — fix the §4.2
  fragment, not this assertion (D-3, F-9).
- **R-2 (resources).** In `open_adblock_build`, when `resources_text` is
  non-empty, parse it with the `resource-assembler` API
  (`adblock::resources::resource_assembler`, enabled by D-3) and call
  `engine.use_resources(vec)` before returning. If parsing yields zero
  resources, log and continue with no resources — scriptlets then no-op
  and `$redirect` rules produce `has_redirect = false`. Never panic:
  wrap resource parsing so any error path degrades to "no resources".
  The exact assembler entry point in 0.8.11 takes file **paths**
  (`assemble_scriptlet_resources(path)`); if no text-based entry exists,
  the C++ side passes the manifest-verified resources path inside the selected
  generation (§9.2), without rewriting the immutable input, and the shim takes
  `resources_path: &str` instead of `resources_text: &str`. Pick the
  path form if the text form needs new parsing code — record the choice
  in the PR. Do not write a resources.txt parser.
- **R-3 (no panics across FFI).** Every `Request::new` failure (malformed
  URL from the network stack) returns a default allow result
  (`matched = false`, all strings empty). Every `url` that fails to parse
  in the cosmetic path returns an empty `OpenCosmeticResources` with
  `generichide = false`. Use `std::panic::catch_unwind` at each exported
  function boundary if any crate call proves panic-capable in review;
  otherwise rely on `Result` handling. A panic that unwinds into C++ is a
  crash of the browser process — treat any observed panic as a Step 2
  blocking bug.
- **R-4 (check).** `open_adblock_check` builds
  `adblock::Request::new(url, source_url, request_type)`, calls
  `check_network_request`, and additionally calls
  `get_csp_directives(&request)` **only** when `request_type` is
  `"document"` or `"subdocument"` (the crate documents CSP as
  document-only; calling it for other types wastes the 2 µs budget).
- **R-5 (redirect basics).** When `BlockerResult.redirect` is `Some(body)`:
  set `has_redirect = true` and `redirect_data_url` **only** if
  `request_type == "script"` and `body` is valid UTF-8 (it is, for JS
  resources, the decoded script text): value =
  `data:text/javascript;charset=utf-8,` + percent-encoded body
  (percent-encode everything except `A–Z a–z 0–9 - _ . ~`; implement the
  encoder in the shim, ~15 lines, no new dependency). For any other type,
  return `has_redirect = true` with an empty `redirect_data_url`: C++
  then blocks instead of redirecting (§7.4). Binary redirect bodies
  never cross the bridge as strings.
- **R-6 (rewritten URL).** Copy `BlockerResult.rewritten_url` verbatim.
  C++ applies it only when `matched == false` (§7.4).
- **R-7 (cosmetic rendering).** Render in Rust:
  `hide_css`: if `hide_selectors` is non-empty, selectors sorted
  (`BTreeSet` iteration or explicit sort — output must be deterministic
  for the §13 screenshot/CDP diffing), joined with `,`, plus
  ` { display: none !important; }`.
  `style_css`: for each `(selector, declarations)` in `style_selectors`
  (sorted by selector), emit `<selector> { <decl1>; <decl2>; }`.
  `remove_selectors` / `remove_attrs` / `remove_classes` have no pure-CSS
  form: the shim serializes them into the **injected script** payload as
  data for the §8.3 agent script (a JSON object literal on one line,
  prefixed `window.__openAdBlockProcedural=`), **before** the crate's
  `injected_script` text. If the crate already resolved a selector into
  `style_selectors`, do not duplicate it here. `exceptions` crosses as
  the raw vector (renderer stores it, §8.3).
- **R-8 (scriptlets).** `injected_script` = the R-7 procedural line (if
  any) + `\n` + `UrlSpecificResources.injected_script` verbatim. Do not
  wrap, minify, or `eval` it. The renderer executes it as-is in the main
  world at document start (§8.3), which is what uBlock Origin scriptlets
  expect (they are self-contained IIFEs keyed by name in the resources
  file).

### 5.4 Shim `BUILD.gn` (exact, overlay `open/adblock/rust/BUILD.gn`)

```gn
# Copyright 2026 The Open Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import("//build/rust/rust_static_library.gni")

# CXX bridge over the vendored Brave adblock crate (MPL-2.0).
# See docs/plans/adblock-fork.md §5. The only Rust Open writes by hand.
rust_static_library("open_adblock_rust") {
  allow_unsafe = true   # CXX generated code; the shim itself has no unsafe blocks beyond the bridge.
  crate_root = "src/lib.rs"
  sources = [ "src/lib.rs" ]
  cxx_bindings = [ "src/lib.rs" ]
  deps = [ "//third_party/rust/adblock/v0:lib" ]  # fix epoch from Step 1 output
  visibility = [ "//open/adblock:*" ]
}
```

If `rust_static_library` in this tree requires an explicit
`crate_name` or edition argument, copy the spelling from
`build/rust/tests/test_rust_static_library/BUILD.gn` (F-7) and note the
delta in the PR. The generated C++ header is included from C++ as
`#include "open/adblock/rust/src/lib.rs.h"` (CXX convention; confirm the
exact path from the first build's `gen/` output and fix the §6 includes
to match — this is the one include path in the plan that is allowed to
move, and the PR must state the final spelling).

`open/BUILD.gn`:

```gn
group("open") {
  deps = [ "//open/adblock" ]
}
```

Acceptance for Step 2: §11 Step 2 list (includes a `cefsimple`-free
proof: build `//open/adblock/rust:open_adblock_rust` alone, and a
one-off driver invocation — §13.4 describes the throwaway driver in
`/tmp`, never committed).

---

## 6. The C++ service — `//open/adblock`

### 6.1 Ownership (patch P-2)

`CefBrowserContext` (F-13) gains the service. Hunk description for
`cef/libcef/browser/browser_context.h` (anchor: after the
`GetHandler(...)` declaration, before `IsAssociatedContext`):

```cpp
namespace open { class OpenAdBlockService; }  // near the top forward declarations

// Open: per-Profile ad-block service (docs/plans/adblock-fork.md §6).
// Created lazily on first access; lives exactly as long as this context.
// UI thread only, like the rest of this class.
open::OpenAdBlockService* open_adblock_service();
```

And a private member near the other members at the end of the class:

```cpp
std::unique_ptr<open::OpenAdBlockService> open_adblock_service_;
```

In `browser_context.cc`: implement `open_adblock_service()` as
"if null, construct with `AsBrowserContext()` and the cache path of this
context (the same `base::FilePath` the context was created with — find
the existing member/param that carries it; if the base class does not
retain it, pass `AsBrowserContext()->GetPath()`)", and call
`open_adblock_service_->Shutdown()` from the existing `Shutdown()` /
destructor path **before** the member is destroyed (find the context's
existing shutdown method; every `CefBrowserContext` subclass funnels
through it — if a subclass bypasses it, hook the destructor instead and
note it). Add `#include "open/adblock/open_adblock_service.h"` to the
`.cc` only (never the header — fork-infra §9.2 rule 2: no widely-included
header gains a heavy include).

Why the base class and not `ChromeBrowserContext`: Alloy contexts get
the service too, `CefRequestContextImpl::browser_context()` returns the
base, and the throttle hook (P-3) is in the Chrome client which can call
`CefBrowserContext::FromBrowserContext(context)->open_adblock_service()`.

### 6.2 Shared types (overlay `open/adblock/open_adblock_types.h`)

```cpp
namespace open {

// Why a request was stopped. Counted separately (§7.5) but summed for the
// Site Control Center's single number.
enum class AdBlockStopKind { kBlocked, kRedirected };

// Immutable snapshot handed to OpenEngine for the panel / debug info.
// Value type, no pointers into the engine.
struct AdBlockStatus {
  bool enabled = false;          // master toggle for this Profile
  bool engine_loaded = false;    // an engine (DAT or text) is installed
  bool engine_from_dat = false;  // last successful load used engine.dat
  uint32_t list_count = 0;       // .txt files consumed by the current engine
  uint64_t dat_size_bytes = 0;   // serialized size of the current engine (0 if unknown)
  int64_t last_build_ms = -1;    // wall time of last build/load (-1 = never)
  std::string last_error;        // last failure, human-readable, no URLs (§6.4)
  std::vector<std::string> excluded_domains;  // sorted copy
};

}  // namespace open
```

### 6.3 `OpenAdBlockService` (overlay `.h`/`.cc`, exact signatures)

```cpp
namespace open {

// One per CefBrowserContext (= one Open Profile). Owns the current Rust
// engine, the exclusion set, and list-build state for that Profile.
//
// Threading: all public methods are UI-thread unless marked otherwise.
// Check() is the exception — URLLoaderThrottles may call it off the UI
// thread — so engine, toggle, and exclusion state are internally
// synchronized (§6.3.1) and Check() never touches UI-only state.
class OpenAdBlockService {
 public:
  // |profile_dir| is the CefRequestContext cache path. The service
  // resolves current.json from the adblock root and reads only manifest inputs;
  // engine.dat is bound to the selected generation (§9.2).
  explicit OpenAdBlockService(base::FilePath profile_dir);
  ~OpenAdBlockService();

  OpenAdBlockService(const OpenAdBlockService&) = delete;
  OpenAdBlockService& operator=(const OpenAdBlockService&) = delete;

  // Cancels pending builds and drops the engine. Called from the owning
  // CefBrowserContext shutdown path (P-2). After Shutdown(), Check()
  // allows everything.
  void Shutdown();

  // Master toggle + exclusions (CEF API, §11 Step 6, forwards here).
  void SetEnabled(bool enabled);
  bool IsEnabled() const;
  void SetExcludedDomains(std::vector<std::string> registrable_domains);
  bool IsExcluded(const GURL& top_level_url) const;  // any thread

  // Point the service at the adblock root and (re)load current.json (§9.2).
  // Verify manifest inputs before text or a generation-bound DAT load.
  // Always asynchronous; completion swaps the engine atomically (§6.3.1).
  void LoadFromDirectory(base::FilePath list_dir, bool prefer_dat);
  // Re-read the directory given to the last LoadFromDirectory (the
  // "update lists now" trigger after Swift writes new .txt files).
  void ReloadLists();

  // Synchronous match. Any thread. Returns the bridge result verbatim;
  // callers apply §7.4 policy (main-frame exemption lives in the
  // throttle, not here, so cosmetic/CSP callers can reuse this).
  open_adblock::OpenBlockerResult Check(const GURL& url,
                                        const GURL& source_url,
                                        const std::string& request_type) const;
  // Cosmetic for one frame's URL. Any thread (same lock as Check).
  open_adblock::OpenCosmeticResources CosmeticResources(const GURL& url) const;
  std::vector<std::string> HiddenSelectors(
      const std::vector<std::string>& classes,
      const std::vector<std::string>& ids,
      const std::vector<std::string>& exceptions) const;

  AdBlockStatus GetStatus() const;
  base::WeakPtr<OpenAdBlockService> GetWeakPtr();

 private:
  // Background build/load body (runs on build_runner_).
  void BuildOnBackground(base::FilePath list_dir, bool prefer_dat,
                         uint64_t generation);
  void SwapEngine(std::shared_ptr<const EngineHolder> holder,
                  AdBlockStatus status_delta);

  struct EngineHolder { /* rust::Box<open_adblock::OpenAdblockEngine> engine; */ };

  base::FilePath profile_dir_;
  base::FilePath list_dir_;
  std::atomic<bool> enabled_{false};
  mutable std::shared_mutex engine_mutex_;            // §6.3.1
  std::shared_ptr<const EngineHolder> engine_;        // guarded by engine_mutex_
  mutable std::mutex exclusions_mutex_;
  std::set<std::string> excluded_domains_;            // guarded by exclusions_mutex_
  scoped_refptr<base::SequencedTaskRunner> build_runner_;  // base::ThreadPool::CreateSequencedTaskRunner({MayBlock, USER_VISIBLE})
  uint64_t generation_ = 0;  // UI thread; stale build results are dropped
  AdBlockStatus status_;     // UI thread except last_error writes via lock — keep a small status_mutex_
  base::WeakPtrFactory<OpenAdBlockService> weak_ptr_factory_{this};
};

}  // namespace open
```

Implementation notes the implementer must follow:

#### 6.3.1 Locking and atomic swap

- `engine_` is a `std::shared_ptr<const EngineHolder>`. `Check` /
  `CosmeticResources` / `HiddenSelectors` take
  `std::shared_lock<std::shared_mutex>`, copy the `shared_ptr`, release
  the lock, then call the shim through the holder. A swap therefore never
  blocks a check for longer than a pointer copy, and an in-flight check
  keeps the old engine alive via its own reference. This is the "atomic
  swap" the design requires; there is no `Engine` mutation after
  construction anywhere (matching the crate's own model, F-8).
- `EngineHolder` wraps `rust::Box<open_adblock::OpenAdblockEngine>`.
  Because `rust::Box` is move-only, `EngineHolder` is constructed on the
  background runner and published only via the `shared_ptr` swap.
- The master toggle is `std::atomic<bool>` (read on any thread, written
  on UI). Exclusions sit behind a plain `std::mutex` + `std::set` —
  lookups are one `std::set::find` on the registrable domain of the
  **top-level** URL (§7.2), not per subresource URL.
- `generation_` increments on every `LoadFromDirectory` / `ReloadLists`
  call. `BuildOnBackground` captures its generation; `SwapEngine` drops
  the result if the generation is stale (a newer load started) or if
  `Shutdown()` ran. Use `weak_ptr_factory_` for the UI-thread hop back.

#### 6.3.2 Build/load algorithm (`BuildOnBackground`, exact order)

1. Resolve `current.json` from the `adblock/` root and verify the selected
   generation using §9.2, including every input hash. On failure keep the old
   in-memory engine and report the error; Swift handles quarantine/recovery.
2. If `prefer_dat`, accept only that generation's `engine.dat` with the matching
   §9.2 receipt and DAT hash (256 MiB read cap). Otherwise build from the exact
   manifest-listed files in file-name order, after verifying sizes and hashes.
   Never enumerate the directory for additional filter lists or resources.
3. Serialize into that generation's `engine.dat` and write its bound receipt,
   using atomic replacement and fsync. A cache write/serialize failure is logged
   and does not discard the valid in-memory engine. See §9.2 for torn pairs.
4. Publish: post to the UI thread (`GetUIThreadTaskRunner` equivalent in
   CEF: `CefCurrentlyOn(UIT)` posting via the existing CEF task helpers —
   in `//open` code, use `content::GetUIThreadTaskRunner({})`), run
   `SwapEngine`, update `status_` (`engine_loaded`, `list_count`,
   `last_build_ms`, clear `last_error`), and notify OpenEngine through
   the status callback the CEF layer registers (§11 Step 6 — a
   `base::RepeatingCallback<void(const AdBlockStatus&)>` set by
   `CefRequestContextImpl`; no callback = no-op, which is the
   `cefsimple` case).

Timing instrumentation: wrap steps 1–3 in `base::ElapsedTimer` and store
the total in `last_build_ms`. Also emit one `VLOG(1)` line per load:
`OpenAdBlock: loaded <n> lists, <dat|text>, <ms> ms` (no URLs, no file
contents — §6.4 privacy rule).

#### 6.3.3 Exclusion semantics

`IsExcluded(top_level_url)`: return true when the URL's registrable
domain (`net::registry_controlled_domains::GetDomainAndRegistry(url,
INCLUDE_PRIVATE_REGISTRIES)`) is in the set. Normalization happens in
`SetExcludedDomains`: lowercase, strip a single trailing dot, strip a
leading `*.`, reject (log + skip) entries that are empty, contain `/`,
or are a bare TLD per `GetDomainAndRegistry` on `http://<entry>/`
returning empty. The CEF/Swift layers pass registrable domains already
(§12), but the service never trusts that. IP-literal hosts: compare the
host string itself (registrable-domain logic returns empty for IPs).

### 6.4 Diagnostics and privacy

`GetStatus()` returns counters and state only. Never log or return: page
URLs, request URLs, list contents, or selector text. The one allowed
string is `last_error`, which names the failed **operation and file**
(for example `read engine.dat: file too large`), never page data. This
feeds "Copy AdBlock debug info" (AD-8) at the OpenEngine layer (§12.2).

### 6.5 Service `BUILD.gn` (overlay `open/adblock/BUILD.gn`, exact)

```gn
# Copyright 2026 The Open Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

source_set("adblock") {
  sources = [
    "open_adblock_navigation_throttle.cc",
    "open_adblock_navigation_throttle.h",
    "open_adblock_service.cc",
    "open_adblock_service.h",
    "open_adblock_tab_helper.cc",
    "open_adblock_tab_helper.h",
    "open_adblock_types.h",
    "open_adblock_url_loader_throttle.cc",
    "open_adblock_url_loader_throttle.h",
  ]
  deps = [
    "//base",
    "//content/public/browser",
    "//content/public/common",
    "//net",
    "//open/adblock/rust:open_adblock_rust",
    "//services/network/public/cpp",
    "//services/network/public/mojom",
    "//third_party/blink/public/common",
    "//url",
  ]
  # CefBrowserContext / CefFrameHostImpl types are needed by the cosmetic
  # sender (§8.2). libcef_static depends on this target (P-3), so this is
  # a circular-looking dep that GN accepts only as an include-path dep,
  # NOT a link dep. Do NOT add "//cef/libcef" here. Instead:
  #   - service/throttle code forward-declares CEF classes and includes
  #     "cef/libcef/browser/browser_context.h" via the include path that
  #     libcef_static's own build already exposes to itself;
  #   - the two functions that must call CefFrameHostImpl methods live in
  #     the P-4 patch's .cc additions (compiled inside libcef_static),
  #     behind the small free-function interface in §8.2.
  visibility = [ "//cef/*", "//open/*" ]
}
```

If GN rejects the `//cef/*` visibility or the include path at first
build, the fix is mechanical and allowed: move the cosmetic **sender**
function (§8.2) fully into the P-4 patch files (it is ~40 lines) and keep
`//open/adblock` CEF-free. Record which form landed in the PR. Do not add
a `//cef` → `//open` → `//cef` link cycle to make it compile.

Acceptance for Step 3: §11 Step 3 list.

---

## 7. Network blocking — the URLLoaderThrottle

### 7.1 Creation hook (patch P-3)

Add to `ChromeContentBrowserClientCef`
(`cef/libcef/browser/chrome/chrome_content_browser_client_cef.h`, in the
override list near `CreateThrottlesForNavigation`):

```cpp
std::vector<std::unique_ptr<blink::URLLoaderThrottle>> CreateURLLoaderThrottles(
    const network::ResourceRequest& request,
    content::BrowserContext* browser_context,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::NavigationUIData* navigation_ui_data,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id) override;
```

Implementation in the `.cc` (exact logic; signature must match
`content/public/browser/content_browser_client.h:1750` in this tree —
copy the base declaration verbatim, do not retype parameter order):

```cpp
std::vector<std::unique_ptr<blink::URLLoaderThrottle>>
ChromeContentBrowserClientCef::CreateURLLoaderThrottles(
    const network::ResourceRequest& request,
    content::BrowserContext* browser_context,
    const base::RepeatingCallback<content::WebContents*()>& wc_getter,
    content::NavigationUIData* navigation_ui_data,
    content::FrameTreeNodeId frame_tree_node_id,
    std::optional<int64_t> navigation_id) {
  auto result = ChromeContentBrowserClient::CreateURLLoaderThrottles(
      request, browser_context, wc_getter, navigation_ui_data,
      frame_tree_node_id, navigation_id);
  // Open: append the ad-block throttle (§7). Creation is cheap and the
  // throttle self-disables per request, so always append when a service
  // exists; never gate creation on the toggle (the toggle can change
  // mid-load and the throttle must see the new value).
  if (auto* cef_context = CefBrowserContext::FromBrowserContext(browser_context)) {
    if (auto* service = cef_context->open_adblock_service()) {
      result.push_back(open::OpenAdBlockURLLoaderThrottle::MaybeCreate(
          service->GetWeakPtr(), wc_getter));
    }
  }
  return result;
}
```

`cef/BUILD.gn`, target `libcef_static`: add `"//open/adblock"` to `deps`
(find the existing `deps` list for that target; append one line, nothing
else). Includes to add: `.h` — none (the base class header already
declares the types through `chrome_content_browser_client.h`); `.cc` —
`#include "cef/libcef/browser/browser_context.h"`,
`#include "open/adblock/open_adblock_service.h"`,
`#include "open/adblock/open_adblock_tab_helper.h"`,
`#include "open/adblock/open_adblock_url_loader_throttle.h"`.

Note the CEF client today also handles the **Alloy** runtime via other
classes. Open ships the Chrome runtime (fork-infra locked decision), so
P-3 hooks the Chrome client only. If an Alloy browser is created in a
test, it simply gets no throttle — record that as expected, do not hook
Alloy in v1.

### 7.2 When the throttle allows everything (checked in this order)

In `WillStartRequest`, return without touching `*defer` or the delegate
when **any** holds:

1. The service is gone (`WeakPtr` null) or `!service->IsEnabled()`.
2. No engine is loaded yet (`Check` with no engine returns allow — the
   service handles this; the throttle does not special-case it).
3. The request URL scheme is not `http`, `https`, `ws`, or `wss`.
   (`data:`, `blob:`, `file:`, `chrome:`, `cef:`, `about:` always pass.
   The crate marks non-supported schemes `is_supported = false`, but the
   throttle must not spend the check on them at all.)
4. It is the outermost main frame: `request.is_outermost_main_frame ==
   true`, or `destination == network::mojom::RequestDestination::kDocument`
   for the primary main frame. **Main frame is never blocked** (§1.1),
   even for `$document` rules. CSP directives for the main frame are
   also skipped in v1 (a list must not be able to CSP-lock the top page;
   subframe CSP still applies, §7.4).
5. The top-level site is excluded: resolve the top-level URL as
   `wc_getter` → `WebContents::GetLastCommittedURL()` when a WebContents
   exists, else `request.request_initiator`'s URL, else the request URL
   itself; `service->IsExcluded(top_url)` is true. One exclusion check
   per request, on the top-level domain only (§6.3.3).

### 7.3 Request mapping (exact)

Build the three shim arguments from `network::ResourceRequest`:

| Shim arg | Source |
|---|---|
| `url` | `request.url.spec()` |
| `source_url` | `request.request_initiator` → `origin.GetURL().spec()` if present and non-opaque; else the WebContents' last committed URL if `wc_getter` yields one; else `request.url.spec()` (first-party). For workers (`kWorker`, `kServiceWorker`, `kSharedWorker`) with no initiator, use the WebContents URL — worker scripts inherit the page's party status |
| `request_type` | Table below from `request.destination`; `ws`/`wss` scheme overrides to `"websocket"` |

Destination → type string (crate vocabulary, F-8):

```text
kDocument, kFrame, kIframe, kFencedframe  -> "subdocument"  (main frame already returned in §7.2)
kScript, kServiceWorker, kSharedWorker, kWorker, kAudioWorklet, kPaintWorklet -> "script"
kImage                                   -> "image"
kStyle                                   -> "stylesheet"
kFont                                    -> "font"
kAudio, kVideo, kTrack                   -> "media"
kEmbed, kObject                          -> "object"
kXslt                                    -> "other"   (crate has an Xlst type but no string maps to it; "other" is the safe v1 mapping)
default (kEmpty, kManifest, kReport, …)  -> "other"
Fetch/XHR: destination is kEmpty for fetch() — the crate receives
"other". This loses $xmlhttprequest-specific rules for fetch(); that is
a known v1 limitation shared with the CEF stepping stone. Record it in
the PR; do not invent a header-sniffing heuristic to recover it.
WebSocket handshake: scheme override above -> "websocket".
WebTransport: no URLLoaderThrottle exists for it in this tree (F-3
family) — out of coverage, same as Safe Browsing's throttle. Note in PR.
```

First/third-party is computed **by the crate** from `url` vs
`source_url` registrable domains (F-8). C++ never computes a party flag
and never passes one. This is why `source_url` correctness matters more
than any other field: a wrong initiator silently flips `$third-party`
rules. The §13 test page includes one first-party and one third-party
case to prove the mapping.

### 7.4 Result policy (exact, in `WillStartRequest` / `WillProcessResponse`)

Given `open_adblock::OpenBlockerResult r = service->Check(...)`:

1. **`r.rewritten_url` non-empty and `!r.matched`**: set
   `request->url = GURL(r.rewritten_url)`. This is the `$removeparam`
   path; `WillStartRequest` mutation triggers Chromium's internal
   redirect handling (F-3). Do not count it as a block. Continue to
   step 2 evaluation on the **original** result (the crate already
   decided block/allow for the rewritten URL).
2. **`r.matched == false`**: allow. Nothing else. (Exceptions `@@` are
   already resolved inside the crate — `matched` is post-exception.
   C++ must not re-check `exception` strings.)
3. **`r.matched == true` and `r.has_redirect` and
   `r.redirect_data_url` non-empty**: set `request->url =
   GURL(r.redirect_data_url)`, count one `kRedirected` (§7.5), allow
   the load to proceed to the data URL. Script destinations only (the
   shim guarantees this, §5.3 R-5).
4. **`r.matched == true` otherwise** (including `has_redirect` with an
   empty data URL — a binary redirect resource in v1): count one
   `kBlocked`, then `delegate_->CancelWithError(net::ERR_BLOCKED_BY_CLIENT,
   "blocked by Open ad blocker")`. Do not set `*defer`. The custom
   reason string is what DevTools and `net` internals show; keep it
   verbatim so §13 CDP checks can match it.
5. **`$important`**: no C++ action. `r.important` is informational; the
   crate's precedence (important > redirect > block > exception, F-8)
   already produced `matched`. Log it only at `VLOG(2)`.

CSP: in `WillProcessResponse`, when the original request type was
`subdocument` (store the type string + a bool at `WillStartRequest`
time; throttles are per-request objects) and the stored
`csp_directives` from the `WillStartRequest` check is non-empty, append
to the response head: if a `Content-Security-Policy` header exists,
append `, <directives>` to its value; else add the header with the
directives as its value. Use
`response_head->headers->AddHeader("Content-Security-Policy", value)` /
`SetHeader` per the `net::HttpResponseHeaders` API in this tree — read
the existing header first with `GetNormalizedHeader`. Main-frame
responses never reach here with directives (§7.2 rule 4 means the check
that produced them was for a subdocument).

Redirects of allowed requests (`WillRedirectRequest`): re-run the full
§7.2–§7.4 policy on `redirect_info->new_url` with the same source/type.
A redirect chain must not smuggle a blocked URL past the first check.
Implement by factoring steps §7.3–§7.4 into
`Evaluate(url, source_url, type) -> Decision` used by both callbacks.

### 7.5 Per-tab counters (overlay `open_adblock_tab_helper.{h,cc}`)

```cpp
namespace open {

// Per-WebContents blocked/redirected counts for the Site Control Center
// (Arc's blockedResourceCount, features-advanced §6 SC-6). Owned by the
// WebContents via UserData; all methods UI-thread.
class OpenAdBlockTabHelper
    : public content::WebContentsUserData<OpenAdBlockTabHelper>,
      public content::WebContentsObserver {
 public:
  // Creates the helper if absent. Called from the throttle factory
  // (§7.1) whenever wc_getter yields a WebContents.
  static OpenAdBlockTabHelper* GetOrCreate(content::WebContents* wc);
  void AddStop(AdBlockStopKind kind);       // posts to UI if needed (below)
  int blocked_count() const;                // kBlocked since last main-frame commit
  int redirected_count() const;
  int total_count() const;                  // sum; what the panel shows
  void ResetCounts();                       // explicit reset (CEF API, §11 Step 6)
 private:
  // WebContentsObserver: DidFinishNavigation resets both counters when
  // navigation_handle->IsInPrimaryMainFrame() && HasCommitted() &&
  // !IsSameDocument(). Same-document (pushState) navigations keep the
  // count — it is "this page load" from the user's point of view.
  int blocked_ = 0, redirected_ = 0;
  WEB_CONTENTS_USER_DATA_KEY_DECL();  // spelling per this tree's macro
};

}  // namespace open
```

Throttle → helper plumbing: `MaybeCreate` receives the same `wc_getter`
the client got. It runs `wc_getter` **once** at creation (UI thread,
F-2); if it yields a WebContents, the throttle stores
`helper->GetWeakPtr()`-equivalent (WebContentsUserData has no WeakPtr —
store the raw `OpenAdBlockTabHelper*` plus observe WebContents
destruction by also making the **throttle** hold the WebContents'
`WeakPtr` via `wc->GetWeakPtr()` where available in this tree; if the
tree's `WebContents` lacks one, store `FrameTreeNodeId` and re-resolve
through `WebContents::FromFrameTreeNodeId` at count time, dropping the
count when resolution fails). `AddStop` called off the UI thread posts
to `content::GetUIThreadTaskRunner({})` with the helper pointer guarded
by that re-resolution — never capture a bare helper pointer in a posted
task. When `wc_getter` yields null (workers, detached loads), counting
is skipped and blocking still applies. A lost count is acceptable; a
use-after-free is not.

Counter reset timing is load-scoped, matching `blockedResourceCount`
semantics the panel expects: reload and new navigation zero it (via
`DidFinishNavigation`), back/forward cache restores keep it (no commit
fires), SPA route changes keep it.

### 7.6 Fallback note (do not build unless needed)

If P-3 must be dropped in a rebase, the stepping stone is
`CefResourceRequestHandler::OnBeforeResourceLoad`
(`cef/include/cef_resource_request_handler.h:91`) implemented in
OpenEngine, calling the same service through the §11 CEF API's internal
equivalent. It covers main/subresource loads only (no workers/WebSocket).
Record in the PR which form shipped; never ship both active (double
counting).

Header for the throttle (overlay, exact class shape):

```cpp
namespace open {
class OpenAdBlockURLLoaderThrottle : public blink::URLLoaderThrottle {
 public:
  static std::unique_ptr<OpenAdBlockURLLoaderThrottle> MaybeCreate(
      base::WeakPtr<OpenAdBlockService> service,
      const base::RepeatingCallback<content::WebContents*()>& wc_getter);
  ~OpenAdBlockURLLoaderThrottle() override;
  void WillStartRequest(network::ResourceRequest* request, bool* defer) override;
  void WillRedirectRequest(net::RedirectInfo* redirect_info,
                           const network::mojom::URLResponseHead& response_head,
                           bool* defer,
                           network::HttpRequestHeadersUpdateParams* headers) override;
  void WillProcessResponse(const GURL& response_url,
                           network::mojom::URLResponseHead* response_head,
                           bool* defer) override;
  const char* NameForLoggingWillStartRequest() override;  // returns "OpenAdBlock"
 private:
  struct Decision { /* allow | cancel | rewrite(GURL) + count kind + csp */ };
  Decision Evaluate(const GURL& url, const network::ResourceRequest& request);
  base::WeakPtr<OpenAdBlockService> service_;
  // resolved once at creation (§7.5); may be null
  content::FrameTreeNodeId frame_tree_node_id_;
  std::string pending_csp_;  // set by Evaluate for subdocuments
};
}  // namespace open
```

Acceptance for Step 4: §11 Step 4 list.

---

## 8. Cosmetic filtering and scriptlets

### 8.1 Data flow (one diagram, then the rules)

```text
Navigation commits (browser, UI thread)
  OpenAdBlockNavigationThrottle::ReadyToCommitNavigation (P-3 sibling, §8.4)
    -> service->CosmeticResources(frame_url)          (~36 µs, browser)
    -> open::SendOpenAdBlockCosmetic(frame_host, payload)   (P-4, cef.mojom)
Renderer (per frame)
  CefFrameImpl::OpenAdBlockCosmetic(...)  -> store payload; if the script
    context already exists, apply now, else CefFrameImpl::OnContextCreated
    applies it before returning (queued, document-start)
    -> insert <style id="open-adblock-hide"> + <style id="open-adblock-style">
    -> execute injected_script in the main world
    -> if !generichide: install the token observer script (§8.3)
  DOM gains class/ID tokens (debounced 100 ms, cap 500/batch)
    -> cef.mojom.BrowserFrame::OpenAdBlockClassIdTokens(classes, ids, exceptions)
Browser
  CefFrameHostImpl handler -> service->HiddenSelectors(...)
    -> Mojo response callback carries the selectors back (no second channel)
Renderer: append "<sel>,… { display: none !important; }" rules to
  #open-adblock-generic (created empty at document start)
```

### 8.2 The `cef.mojom` additions (patch P-4, exact)

In `cef/libcef/common/mojom/cef.mojom`, inside `interface RenderFrame`
(after `SendJavaScript`):

```mojom
  // Open: cosmetic payload for the frame's next document (adblock-fork §8).
  // Sent at ReadyToCommitNavigation; the renderer applies it at
  // DidCreateScriptContext, before page scripts run. Empty strings mean
  // "nothing to install" for that channel.
  OpenAdBlockCosmetic(string hide_css, string style_css,
                      string injected_script, array<string> exceptions,
                      bool generichide);
```

Inside `interface BrowserFrame` (after `UpdateDraggableRegions`):

```mojom
  // Open: new class/ID tokens observed in the frame's document.
  // |exceptions| echoes the payload's #@# set so the browser stays
  // stateless per frame. Response carries matching generic selectors.
  OpenAdBlockClassIdTokens(array<string> classes, array<string> ids,
                           array<string> exceptions)
      => (array<string> selectors);
```

Final addition: `RenderFrame` +1 method, `BrowserFrame` +1 method.
Generic selectors return through the `OpenAdBlockClassIdTokens`
response callback. There is no second renderer-bound method.

Browser-side plumbing (also P-4):

- `CefFrameHostImpl` gains
  `void SendOpenAdBlockCosmetic(const std::string& hide_css, const std::string& style_css, const std::string& injected_script, const std::vector<std::string>& exceptions, bool generichide)`,
  implemented with the existing `SendToRenderFrame` helper calling
  `render_frame->OpenAdBlockCosmetic(...)` (the Mojo remote method name
  matches the `.mojom` spelling).
- The `BrowserFrame` receiver in `CefFrameHostImpl` (find the existing
  `cef::mojom::BrowserFrame` implementation class for the frame) gains
  the `OpenAdBlockClassIdTokens` handler: it resolves the owning
  `CefBrowserContext` (the frame impl already knows its browser/context
  — follow the existing `UpdateDraggableRegions` handler's path to the
  browser), calls `service->HiddenSelectors(classes, ids, exceptions)`,
  and runs the Mojo callback with the result. No service = empty reply.
  This handler runs on the UI thread (Mojo frame interfaces are
  UI-bound in CEF); `HiddenSelectors` is any-thread (§6.3), so no hop.
- Free-function seam for §6.5's GN constraint, declared in the P-4
  addition to `frame_host_impl.h`:
  `void CefSendOpenAdBlockCosmetic(CefRefPtr<CefFrame> frame, const open_adblock::OpenCosmeticResources& payload);`
  The navigation throttle (§8.4) calls this; it dynamic-casts to
  `CefFrameHostImpl` and forwards. If the §6.5 include-path build works
  without the seam, call the method directly and skip the free function.
  Pick one form at Step 5 and record it.

Renderer-side plumbing (also P-4):

- `CefFrameImpl` gains members `bool open_cosmetic_pending_`,
  `std::string open_hide_css_, open_style_css_, open_script_`,
  `std::vector<std::string> open_exceptions_`, `bool open_generichide_`,
  and methods `OpenAdBlockCosmetic(...)` (store; if `context_created_`,
  apply immediately) + `ApplyOpenAdBlockCosmetic()` (idempotent per
  document: a `bool open_cosmetic_applied_` reset in
  `OnContextReleased`).
- `CefRenderFrameObserver::DidCreateScriptContext` calls
  `framePtr->ApplyOpenAdBlockCosmetic()` **after**
  `handler->OnContextCreated(...)` and after
  `framePtr->OnContextCreated(context)` (the queued-actions drain), so a
  client's own `OnContextCreated` script cannot be reordered behind ours
  and our style lands in the same task as context creation — before the
  parser runs page scripts. This is the document-start guarantee; state
  it exactly this way in the PR (F-10).

### 8.3 The renderer agent (inside `ApplyOpenAdBlockCosmetic`)

Runs in the renderer, in `CefFrameImpl` (compiled in `libcef_static`'s
renderer sources — confirm `frame_impl.cc` is in that target; it is,
per its existing `SendJavaScript` implementation). Using
`blink::WebLocalFrame* frame = ...` (the impl already holds it):

1. **Styles.** If `hide_css` or `style_css` is non-empty, execute one
   script in the main world (via the same
   `frame->ExecuteScript(blink::WebScriptSource(...))` path as
   `SendJavaScript`) that: creates `<style id="open-adblock-hide">`
   with `textContent = hide_css`, `<style id="open-adblock-style">`
   with `style_css`, and `<style id="open-adblock-generic">` (empty),
   appending each to `document.documentElement` (the `<head>` may not
   exist yet at context creation; appending to the root element is
   valid and applies identically). Tag each with
   `data-open-adblock="1"` so §13 CDP checks find them. Build this
   script as a fixed C++ string literal with the payload passed through
   `CefString` JSON-encoding — **never** interpolate raw CSS into a JS
   string literal without encoding. Use `base::JSONWriter`-equivalent
   escaping available in renderer code, or pass the CSS through the
   Mojo strings into a small V8-native path if one exists in
   `frame_impl.cc`'s neighbours; the PR must show the escaping function
   used. An injection bug here is an XSS primitive — this paragraph is
   the security-critical part of Step 5.
2. **Scriptlets + procedural.** If `injected_script` is non-empty,
   execute it verbatim in the main world, after the styles. Its first
   line may be the `window.__openAdBlockProcedural=<json>;` assignment
   (§5.3 R-7). Immediately after, execute the **procedural runner**: a
   fixed script (committed as a C++ raw string in `frame_impl.cc`,
   ~60 lines, written for this plan — not copied from uBlock Origin)
   that reads `__openAdBlockProcedural` and applies `remove_selectors`
   (element.remove()), `remove_attrs`, `remove_classes` once now and
   once on `DOMContentLoaded` (late-inserted nodes beyond that are a
   v1 limitation; generic-hide token reports cover the common case).
3. **Token observer** (only when `!generichide`): execute the fixed
   observer script (~50 lines, same provenance rule): collects
   `class`/`id` tokens from the initial document and from a
   `MutationObserver` on `document.documentElement`
   (`subtree, attributes: [class, id], childList`), debounces 100 ms,
   caps each report at 500 new tokens, never reports the same token
   twice per document, and sends reports through the CEF process-message
   bridge that already reaches `BrowserFrame` — concretely, the script
   cannot call Mojo directly, so the **renderer C++** owns reporting:
   the observer script accumulates into
   `window.__openAdBlockTokens` and a `MutationObserver` in the fixed
   script posts via the existing CEF renderer→browser message channel
   (`CefFrame::SendProcessMessage` equivalent available to renderer
   impl code — find how `CefFrameImpl` sends `SendMessage` today and
   reuse that exact path with message name
   `"OpenAdBlockClassIdTokens"` and a `CefListValue` of
   `[classes_json, ids_json, exceptions_json]`). On the browser side,
   if routing that name through the generic message path proves to
   require client-visible handling, switch to the dedicated Mojo method
   in §8.2 (which is why it is specified): implementer picks the Mojo
   method if the generic path touches `CefRequestHandler` client
   callbacks. Record the pick. The reply selectors are appended by
   renderer C++ (not script) into `#open-adblock-generic` via one
   `ExecuteScript` that sets `textContent +=` the joined rules.
   Exceptions: the script stores the payload `exceptions` JSON it was
   given and echoes it in every report (browser stays stateless, §8.2).

Subframes: every frame gets its own payload for **its own** URL
(§8.4). Scriptlets run per frame (uBlock Origin semantics). Styles are
per-document by construction.

### 8.4 The navigation throttle (overlay, cosmetic sender)

`OpenAdBlockNavigationThrottle : public content::NavigationThrottle`,
created in the **existing** `ChromeContentBrowserClientCef::
CreateThrottlesForNavigation` (P-3 extends that method — second hunk in
the same patch file is allowed because it is one logical change: "hook
Open ad blocking into CEF navigation + loading"):

```cpp
void ChromeContentBrowserClientCef::CreateThrottlesForNavigation(
    content::NavigationThrottleRegistry& registry) {
  ChromeContentBrowserClient::CreateThrottlesForNavigation(registry);
  throttle::CreateThrottlesForNavigation(registry);
  // Open: cosmetic delivery (§8.4).
  if (auto* wc = registry.GetWebContents()) {   // exact accessor per this tree's NavigationThrottleRegistry; adapt name, note in PR
    if (auto* ctx = CefBrowserContext::FromBrowserContext(wc->GetBrowserContext())) {
      if (auto* service = ctx->open_adblock_service()) {
        registry.AddThrottle(std::make_unique<open::OpenAdBlockNavigationThrottle>(
            service->GetWeakPtr(), wc->GetWeakPtr()));
      }
    }
  }
}
```

`OpenAdBlockNavigationThrottle::ReadyToCommitNavigation()` logic:

1. `handle->IsInMainFrame()` or subframe — both proceed (per-frame
   payloads, §8.3). Skip when: service gone/disabled, `handle` URL
   scheme not http/https, top-level site excluded (top-level URL =
   `handle->GetWebContents()->GetLastCommittedURL()` for subframes —
   before commit that is the **previous** top page; for the main frame
   use `handle->GetURL()`), or the service has no engine.
2. `auto payload = service->CosmeticResources(handle->GetURL())`.
   If all fields empty and `!payload.generichide`, still send nothing
   and return `PROCEED` (no Mojo traffic for unlisted pages is the
   common case and must stay free).
3. Resolve the frame: `handle->GetRenderFrameHost()` →
   `CefBrowserContext::FromBrowserContext(...)`'s frame registry — in
   CEF terms, obtain the `CefFrameHostImpl` for the RFH via
   `CefBrowserInfoManager` / `browser_info_->GetFrameForGlobalId` path
   that `CefBrowserContentsDelegate::DidFinishNavigation` already uses
   (F-13 neighbours). Call §8.2's sender with the payload.
4. Return `NavigationThrottle::PROCEED` in all paths. Cosmetic delivery
   never defers or blocks navigation.

Timing claim to verify at Step 5: `ReadyToCommitNavigation` runs before
the renderer commits the new document, and the Mojo call is queued on
the frame's channel ahead of the commit's script-context creation, so
§8.3's apply-at-context-creation holds. If verification shows the
payload can arrive **after** `DidCreateScriptContext` (same-document
navigations, BFCache restores), the renderer's
`context_created_` immediate-apply branch (§8.2) covers it — at the cost
of a possible one-frame flash on those paths only. §13 measures the
main path (fresh navigation) and reports the BFCache path as a known
limitation if it flashes.

Zap merge note: Boosts/Zap selectors (M6 sibling feature) merge into
`#open-adblock-style` **after** blocker CSS when Zap lands. This plan
only reserves the element IDs and the ordering rule; do not build Zap
hooks here.

Acceptance for Step 5: §11 Step 5 list.

---

## 9. List management

Ownership split (D-8): **Swift downloads and stores; the browser builds
and matches.** This section defines both sides' files precisely so the
two implementations meet without further design.

### 9.1 Bundled lists — build-time fetch (new file `tools/fetch-adblock-lists.sh`)

Purpose: stage EasyList + EasyPrivacy (+ the §9.3 resources file) under
`Vendor/adblock/` for the app bundle and for `cefsimple` acceptance.
Never commit list text. Never read `/Applications/Arc.app`.

`Engine/fork/adblock/list-pins.txt` (committed, exact format):

```text
# Open bundled filter lists. One line per file:
# <local-name> <official-url> <sha256-hex-lowercase>
# Update only via: tools/fetch-adblock-lists.sh --update-pins (reviewed PR).
easylist.txt https://easylist.to/easylist/easylist.txt <fill at Step 7>
easyprivacy.txt https://easylist.to/easylist/easyprivacy.txt <fill at Step 7>
```

Script behavior (Bash, `set -euo pipefail`, no fork-script sourcing —
`tools/` stays standalone per fork-infra §6.1):

```text
tools/fetch-adblock-lists.sh [--update-pins] [--dest <dir, default Vendor/adblock>]
```

1. Read `list-pins.txt` (+ `resources-pins.txt`, §9.3). For each entry:
   download with `curl -fsSL --retry 3 -o <dest>/<name>.tmp <url>`
   (follow the official URL only; an HTTP error is fatal, no fallback
   mirror).
2. Verify: first non-empty line matches `^\[Adblock Plus` (lists) and
   `shasum -a 256` equals the pin. On mismatch: delete the temp file,
   print expected vs actual, exit 1. **Never** overwrite a good staged
   file with an unverified one — rename `.tmp` over the target only
   after both checks pass.
3. `--update-pins`: after a successful verify-except-hash download,
   rewrite the pin file with the new hash and print a one-line summary
   per changed file (`<name>: <old> -> <new>`). This mode is how a list
   update is reviewed; a normal run must never edit pins.
4. Print `fetch-adblock-lists: <n> files, <bytes> bytes -> <dest>`.

At Step 7 the implementer runs the script once, then `--update-pins`
once to fill the two `<fill at Step 7>` hashes from the real downloads,
and commits the filled pins. Record the byte sizes and line counts in
the PR (expect ~80k lines EasyList, ~57k EasyPrivacy per the design's
count of the same upstream lists; a wildly different count means the
wrong URL).

App packaging (later, app milestone): the app target copies
`Vendor/adblock/*` into `Open.app/Contents/Resources/AdBlock/`. This
plan does not create the app target; §13 acceptance stages the same
files beside `cefsimple` via the smoke harness switch (§13.1).

### 9.2 Per-Profile storage and directory contract

**Lead decision — 2026-10-25: use generations.** This replaces the earlier
`AdBlock/lists/` layout and any directory-enumeration or unbound-DAT instructions
elsewhere in this plan. The Swift slice uses `<root>/Profiles/<UUID>/adblock/`.
The CEF/OpenEngine directory parameter names this `adblock/` root.

```text
<profile-dir>/adblock/
  catalog-state.json            Swift state, persisted before current.json moves
  exclusions.json               Swift exclusion set
  downloads/<listID>/<n>.body   source caches; never engine inputs
  current.json                  live {generation, manifestSHA256}, previous ref
  generations/<n>/
    <listID>.txt                 exactly one per enabled list
    manifest.json               generation, full file inventory, state snapshot
    engine.dat                  optional browser-owned cache for THIS generation
    engine-inputs.json          browser-owned DAT receipt (see below)
  quarantine/<n>-<unique>/       rejected generation; never engine inputs
```

`current.json` is `{ "live": { "generation": n, "manifestSHA256": "..." },
"previous": { "generation": p, "manifestSHA256": "..." } }`; `previous` can
be absent. Each manifest file entry has `file`, `bytes`, `sha256`, `listID`,
`sourceRevision` (ordered upstream content hashes, or the bundled pin), and
`generation`. The manifest also carries `generation` and an immutable `state`
snapshot (enabled IDs and complete receipts), so a crash after saving state but
before moving the pointer can reconcile to the committed set.

Enable, disable, and every successful update (including all-304) stage a new,
complete generation. Verify every input, write and fsync all files and manifest,
fsync the generation and parent, persist state, then write/fsync a temporary
`current.json` and atomically rename it over the live pointer. Fsync its parent.
Only after that commit may cleanup delete generations other than live and its
previous generation. A crash before the rename leaves the old generation intact;
unreferenced generations are never promoted. Cache writes are outside this
transaction and are hash-checked before reuse.

Before emitting `configure`, Swift verifies the selected manifest hash and the
size and SHA-256 of every listed file. On failure, quarantine that generation,
verify and restore the pointer's previous generation, or reseed pinned bundled
defaults / refetch defaults if no valid previous generation exists. Record the
integrity error and recovery in `lastError`. Reconcile enabled IDs and receipts
from the current manifest, even if a newer catalog-state was saved before a
crash. Ignore extra files, stale list folders, and unreferenced generations.
Legacy settings/exclusions can migrate; legacy list files are refetched.

The engine reads **only** `current.json` → that generation's `manifest.json` →
its listed inputs. It verifies the manifest hash and each input's size/SHA-256
before loading, including before DAT use. It must never enumerate `*.txt` to
choose inputs. Resources, when the deferred resources stage lands, must also be
manifest inputs. An optional `engine.dat` is valid only inside the selected
generation, with an `engine-inputs.json` receipt whose generation, manifest hash,
and complete file→SHA-256 map equal that manifest. The receipt also records the
DAT's own size and SHA-256; reject torn/missing/mismatched DAT/receipt pairs and
build from verified text. Never copy DAT between generations. Serialize and
atomically replace DAT and its receipt in that generation; failure retains the
valid in-memory engine. A stale background build must not publish into another
generation. Engine implementation and runtime acceptance remain deferred.

First run seeds a complete generation from pinned bundled defaults before the
first configure call; without a bundle it fetches verified upstream defaults.
No incomplete list set is passed to the engine.

### 9.3 Scriptlet / redirect resources (uBlock Origin)

File: `Engine/fork/adblock/resources-pins.txt`, same one-line format as
§9.1 (name, URL, sha256). Local name: `resources.txt`. Source (official
uBlock Origin assets, as consumed by the crate's `resource-assembler`,
D-3): use the resources file the `adblock` crate's assembler documents
for 0.8.11 — at Step 7, read
`~/.cargo/registry/src/*/adblock-0.8.11/src/resources/resource_assembler.rs`
and take the input format it actually parses (in 0.8.11:
`assemble_scriptlet_resources` reads uBlock Origin's `scriptlets.js`
-style directory/file layout). Pin **that** upstream file (gorhill/uBlock
`assets/resources/` on the project's official repository host) with its
SHA-256, fetched by the same script with an added entry. If the
assembler wants a directory rather than one file, stage the directory
under `Vendor/adblock/resources/` and change the service's reserved
name in §6.3.2 step 2 from `resources.txt` to that directory — record
the final form in the PR and in this file's errata. Do not hand-convert
uBO resources to JSON; the assembler exists so we do not.

Licensing: uBlock Origin resources are GPL-3.0 code/data. Add a
`THIRD_PARTY.md`-adjacent note in `resources-pins.txt` header
(`# License: GPL-3.0 (uBlock Origin resources). Distribution review
required before any public release — same gate as MPL-2.0, fork-infra
Q-2.`). The pin lands in the same Step 7 PR; the counsel gate blocks
external release, not local development (fork-infra §14 Q-2 default).

Versioning: resources update **with** the lists (§9.5 same schedule,
own ETag). `AdBlockStatus` gains no resources field in v1; debug info
(§12.2) reports the resources file's byte size + first-line version
comment if present.

### 9.4 The 46-list catalog (committed data file)

Create `Engine/fork/adblock/catalog.json` **once** at Step 7 by
transforming the manifest facts (IDs, display names, categories,
info URLs, upstream URLs). Raw manifest is git-ignored RE data
(F-14) — the transform script runs locally, its **output** is what is
committed. Transform rule per list: `urls[]` = each Arc mirror URL with
the prefix `https://dia-blocklists-release.diabrowser.engineering/`
replaced by `https://`; keep `id`, `display_name`, `type` (rename to
`category`), `info_url` verbatim. Drop `resource_name` except record
`"bundled": true` on EasyList and EasyPrivacy.

Schema (exact):

```json
{
  "version": 1,
  "lists": [
    {"id": "EasyList", "display_name": "EasyList", "category": "generic",
     "info_url": "https://easylist.to/",
     "urls": ["https://easylist.to/easylist/easylist.txt"],
     "bundled": true, "default_enabled": true}
  ]
}
```

Facts the implementer must reproduce (from F-14 / features-advanced
AD-3; verify against the local manifest at Step 7 and report any drift
instead of silently matching this plan): 46 lists total; categories
`generic` 3 (`EasyList`, `AdGuardAds`, `uBlock`), `cookies` 2
(`CookieMonster`, `AdGuardCookies`), `privacy` 5 (`EasyPrivacy`,
`AdGuardSpyware`, `EasyListSocial`, `AdGuardSocial`,
`FanBoyThirdParty`), `regional` 35 (IDs are locale-ish codes: `pl`,
`ua`, `de`, `fr`, `jp`, `kr`, …), `bcny` 1 (`BCNYBlocklists` with two
URLs). `default_enabled: true` on exactly EasyList + EasyPrivacy
(adblock-design default). Multi-URL lists (notably `uBlock` with 7,
`ua` with 14, `kr` with 17) download **all** URLs and concatenate in
listed order into the single `<listID>.txt` (separator: newline; the
crate's `FilterSet` receives the concatenation as one list text —
Swift side, §12.3, so the browser still sees one file per ID).

Open never fetches `dia-blocklists-release.diabrowser.engineering`
anywhere. `grep -r diabrowser Engine/fork/adblock/ tools/fetch-adblock-lists.sh`
must print nothing in the Step 7 PR.

### 9.5 Update schedule and ETag flow (Swift side, §12.3 implements)

- **When:** first check 60 s after Profile open (never on the launch
  path — architecture budget), then every 24 h while the app runs, and
  on the manual "update now" action (§12.1 `updateAdBlockListsNow`).
  24 h is fresher than EasyList's `Expires: 4 days` and matches the
  design's choice (adblock-design §"Schedule").
- **What:** for each **enabled** list (plus `resources.txt`): conditional
  GET with `If-None-Match: <stored ETag>` (and `If-Modified-Since` when
  only a date was stored). `304` → retain verified bytes and update `last-check` in the new generation.
  `200` → verify first line (§9.1 rule) and stage bytes plus the new ETag.
  Publish the complete generation using §9.2 after all enabled lists succeed. Unknown list IDs in any remote data are
  skipped, never fatal (AD-4). The catalog itself is **committed data**
  (§9.4) in v1 — there is no remote catalog fetch; a catalog change is
  an app update. (Arc fetches a remote manifest; Open deliberately does
  not operate that infrastructure in v1. Record this divergence in the
  Step 8 PR.)
- **Rebuild:** after a batch in which ≥1 file changed, Swift calls the
  CEF reload trigger **once** (§12.1). The browser rebuilds in the
  background and swaps (§6.3.2); in-flight pages keep the old engine —
  correct, since a half-updated rule set must never apply.
- **Failure:** any network/verify failure keeps the old files and the
  old engine, records the error in `catalog-state.json` (`last_error`,
  no URLs beyond the list ID), and retries after 1 min, 5 min, 30 min, then the normal 24 h interval.
  Busy scheduled attempts use the same backoff. Success resets the retry ladder. No
  user-facing alert in v1; Settings shows the status string (§12.2).

Acceptance for list work: §11 Steps 7–8 lists.

---

## 10. Data flow and threading (summary — normative)

```text
Swift AdBlockStore (main actor)                Browser process (CEF UI thread unless noted)
  catalog.json (committed)                       CefRequestContext (per Profile)
  catalog-state.json (ETags)                       └─ CefBrowserContext::open_adblock_service()
  adblock/current.json ── SetOpenAdBlockListDirectory ──>  OpenAdBlockService
  exclusions.json ── SetOpenAdBlockExcludedDomains ─>   ├─ engine_ (shared_ptr, shared_mutex)
  master toggle ──── SetOpenAdBlockEnabled ────────>    ├─ build_runner_ (ThreadPool, MayBlock)
                                                        └─ status_
URLSession downloads (Swift, background) ── files ──> ReloadOpenAdBlockLists ─> background rebuild ─> atomic swap

Per request (throttle sequence, may be off-UI):
  OpenAdBlockURLLoaderThrottle::WillStartRequest
    -> service->Check(url, source, type)   [shared_lock, shim call, ~2 µs]
    -> allow | CancelWithError | rewrite request->url | count via TabHelper (posted to UI)

Per navigation (UI thread):
  OpenAdBlockNavigationThrottle::ReadyToCommitNavigation
    -> service->CosmeticResources(frame_url)  [~36 µs]
    -> cef.mojom.RenderFrame::OpenAdBlockCosmetic  -> renderer stores payload
  Renderer DidCreateScriptContext:
    -> insert 3 <style> elements, run scriptlets, install token observer
  Token batches (renderer -> browser, debounced):
    -> BrowserFrame::OpenAdBlockClassIdTokens => service->HiddenSelectors
    -> renderer appends rules to #open-adblock-generic

Per tab (UI thread):
  OpenAdBlockTabHelper (WebContentsUserData) counts; reset on main-frame commit.
  CefBrowserHost::GetOpenAdBlockBlockedCount() reads it (§11 Step 6).
```

Thread rules (violations are Step-blocking bugs):

1. The Rust engine is built/deserialized/serialized **only** on
   `build_runner_`. The UI thread never parses a list and never waits on
   a build. Startup DAT load is therefore async: early navigations
   before the first swap completes are **allowed** (engine not loaded =
   allow, §7.2 rule 2). This is the correct cold-start trade: blocking
   the first paint on a 47 ms deserialize would break the 700 ms budget
   for a feature the user can toggle. The §13 perf check measures how
   long the unprotected window lasts (expect < 200 ms after Profile
   open) and the PR reports it.
2. `Check`/`CosmeticResources`/`HiddenSelectors` are any-thread,
   lock-light (§6.3.1), and never post tasks, never allocate file I/O,
   never call back into CEF client code.
3. Counters are UI-thread only; off-thread increments post (§7.5).
4. Mojo cosmetic calls are UI→renderer on the frame channel; token
   replies use the Mojo response callback (no second channel, §8.2).
5. Swift calls CEF on the CEF UI thread via OpenEngine's existing
   threading helpers; OpenEngine never exposes a CEF type to Swift
   (architecture rule).

---

## 11. Implementation order (acceptance per step)

Run fork-infra's gate before every step:
`pgrep -fl 'autoninja|siso' || echo "no build running"`. Long builds use
`Engine/fork/scripts/engine-build --detach` (own session, rule 9).
"Build is green" always means: `engine-build` exit 0 **and**
`Engine/fork/scripts/engine-status` PASS for the touched series **and**
smoke A (`cefsimple` launch, fork-infra §10.3) with no `FATAL`.

### Step 1 — Vendor the crate (fork-infra Step 8, §4 of this plan)

Work: §4.2 fragments, §4.3 R1–R4, §4.4 closure review, §4.5 capture +
licenses. No service code, no throttle, no CEF API in this PR.

Acceptance (all must pass; paste real output in the PR):

- [ ] `vpython3 tools/crates/run_gnrt.py vendor` and `… gen` exit 0;
      `ls third_party/rust/adblock/` shows the epoch dir (expect `v0`)
      with `BUILD.gn` + `README.chromium`.
- [ ] `Cargo.lock` shows `adblock 0.8.11`; `rmp` version recorded
      (fragment pin added iff §4.2 requires it).
- [ ] `engine-build --target third_party/rust/adblock/v0:lib` (real
      target name) exit 0 under the Chromium toolchain; PR states the
      `rustc` version from `third_party/rust-toolchain/VERSION`.
- [ ] Closure table in the PR: every new vendor dir, version, license
      (from `README.chromium`); no GPL-family license present.
- [ ] `Engine/fork/licenses/MPL-2.0.txt` copied from the vendored crate;
      `THIRD_PARTY.md` has one row per new crate.
- [ ] `patches/rust/0001-adblock-vendor.patch` size recorded; > ~20 MB
      → lead decision obtained before proceeding.
- [ ] `engine-apply` second run on the patched tree: 0 patches applied
      (idempotent); smoke B (fork-infra §10.3) passes.

PR: `Engine/fork/patches/rust/**`, the two `.open` fragments,
`Engine/fork/licenses/**`. One PR.

### Step 2 — Rust shim crate (§5)

Work: overlay `open/adblock/rust/{BUILD.gn,src/lib.rs}`, `open/BUILD.gn`.
No C++ consumer yet.

Acceptance:

- [ ] `engine-build --target open/adblock/rust:open_adblock_rust` exit 0.
      (GN target spelling: `autoninja -C out/Release_GN_arm64
      open/adblock/rust:open_adblock_rust -j 10` via `engine-build`.)
- [ ] The `Send + Sync` assertion (R-1) compiles in.
- [ ] Throwaway driver proof (§13.4, file in `/tmp`, never committed):
      build an engine from the two lists in `/tmp/adblock-bench/data/`
      (or re-fetch via §9.1 into `/tmp`), check the design's 15-URL set
      shape — a known tracker URL blocked, a known first-party URL
      allowed — print `serialize_raw` size and deserialize round-trip
      success. Numbers in the PR must be the same order as F-15
      (size ~6.8 MiB); a 10× miss means the wrong lists or features.
- [ ] `engine-status` still green; `cefsimple` smoke A still passes
      (crate linked nowhere yet — state that in the PR).

PR: `Engine/fork/src/open/**` (shim only). One PR.

### Step 3 — C++ service (§6)

Work: overlay `open_adblock_types.h`, `open_adblock_service.{h,cc}`,
`open/adblock/BUILD.gn` (service sources only at this step; throttle
sources join the same file at Step 4 — add them then, not now), patch
P-2 (service owner). The service compiles and is reachable from
`CefBrowserContext`, but nothing calls `LoadFromDirectory` in
production code yet.

Acceptance:

- [ ] `engine-build` (default `cefsimple`) exit 0 with P-2 applied;
      `engine-status` S-3/S-4 PASS for P-2; round-trip proof per
      fork-infra §8 step 5 pasted.
- [ ] Service exercised end to end **through the smoke harness stub**:
      at this step, drive it from a temporary `VLOG`-gated block in the
      P-6 harness location (§13.1) behind `--open-adblock-selftest`:
      load the staged bundled lists, wait for swap, print
      `AdBlockStatus` (expect `engine_loaded=1, list_count=2,
      last_build_ms` in the F-15 order: DAT-absent text build
      ≤ 1000 ms, and on second run with `engine.dat` present
      `engine_from_dat=1`). Remove or keep the selftest behind the
      switch — keeping it is preferred (it is the §13 regression gate).
- [ ] Shutdown cleanliness: quit `cefsimple` mid-build (start a load,
      quit within 1 s) five times; no crash, no hang, no leftover
      renderer processes (`pgrep -f cefsimple` empty).

PR: overlay service files + P-2. One PR.

### Step 4 — URLLoaderThrottle + counters (§7)

Work: overlay `open_adblock_url_loader_throttle.{h,cc}`,
`open_adblock_tab_helper.{h,cc}`,
`open_adblock_navigation_throttle.{h,cc}` (navigation throttle at this
step only reserves `ReadyToCommitNavigation -> PROCEED`; cosmetic
sending joins at Step 5), `BUILD.gn` source additions, patch P-3.
Smoke harness P-6 lands here in its §13.1 form (switches + load-end
count logging) so Steps 4–6 all verify through it.

Acceptance (§13.3 cases N-1…N-6 must all pass; record CDP output):

- [ ] Build green; `cefsimple` with no ad-block switches behaves
      identically to stock (smoke A + the test page fully loads,
      count logging absent).
- [ ] With `--open-adblock-dir` pointing at the §13.2 test lists:
      N-1…N-6 pass, including the main-frame-never-blocked case and
      the per-site exclusion case (via `--open-adblock-exclude`).
- [ ] Blocked subresources show `ERR_BLOCKED_BY_CLIENT` in CDP network
      events with the §7.4 reason string.
- [ ] Counter resets on reload/navigation and survives `pushState`
      (§7.5) — CDP-checked.

PR: overlay throttle files + P-3 + P-6. One PR (P-6 is test-only and
called out as such).

### Step 5 — Cosmetic filtering + scriptlets (§8)

Work: patch P-4 (`cef.mojom` + host/renderer plumbing), the §8.3
renderer agent scripts (fixed strings in `frame_impl.cc`), navigation
throttle cosmetic sending, shim R-7/R-8 already landed at Step 2
(verify, do not rewrite).

Acceptance (§13.3 cases C-1…C-6):

- [ ] Build green. Mojo bindings regenerate with no hand-edited
      generated files in the patch (`git diff --stat` on the patch
      shows only the §3.3 P-4 source files).
- [ ] C-1: `##`-hidden element has `display: none` at first CDP query
      after load (and the style elements carry `data-open-adblock`).
- [ ] C-2: `#@#` exception element stays visible. C-3: `$generichide`
      page gets no generic selectors and no token traffic (assert via
      `--v=1` log absence). C-4: late-inserted ad node (test page adds
      one at +500 ms) is hidden after a token round-trip. C-5:
      scriptlet ran (`window.__openTestScriptlet == 1`). C-6: excluded
      site gets no style elements at all.
- [ ] No page-visible `__openAdBlock*` globals beyond the two documented
      (`__openAdBlockProcedural`, `__openAdBlockTokens`) — CDP
      enumerates them in the test.

PR: P-4 + overlay navigation-throttle changes. One PR. The PR must
quote the §8.3 step 1 escaping function used (security callout).

### Step 6 — CEF C API + translator (patch P-5)

New API (all guarded `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`,
F-12; `/*--cef()--*/` annotations so the translator emits the C API):

In `cef/include/cef_request_context.h` (per-Profile control; impl in
`CefRequestContextImpl`, forwarding to
`browser_context()->open_adblock_service()` — `browser_context()` exists,
F-13):

```cpp
///
/// Open: enable or disable native ad blocking for this request context
/// (one Open Profile). Takes effect on the next navigation; no restart.
/// The default is disabled until SetOpenAdBlockListDirectory has loaded
/// an engine. Can be called on any CEF thread; marshals to the UI thread.
///
/*--cef()--*/
virtual void SetOpenAdBlockEnabled(bool enabled) = 0;

/*--cef()--*/
virtual bool IsOpenAdBlockEnabled() = 0;

///
/// Point the ad-block service at the adblock root and load current.json
/// asynchronously. Verify only manifest-listed generation inputs and use
/// a DAT only with its matching generation/input receipt (§9.2).
///
/*--cef(optional_param=list_dir)--*/
virtual void SetOpenAdBlockListDirectory(const CefString& list_dir) = 0;

///
/// Re-read the directory from the last SetOpenAdBlockListDirectory call
/// (use after the client has written updated list files). No-op if no
/// directory was set.
///
/*--cef()--*/
virtual void ReloadOpenAdBlockLists() = 0;

///
/// Replace the per-site exclusion set (registrable domains, e.g.
/// "example.com"). Excluded top-level sites skip network blocking and
/// cosmetic filtering after the next navigation.
///
/*--cef()--*/
virtual void SetOpenAdBlockExcludedDomains(
    const std::vector<CefString>& domains) = 0;

/*--cef()--*/
virtual void GetOpenAdBlockExcludedDomains(
    std::vector<CefString>& domains) = 0;

///
/// Snapshot of ad-block state for this context as a dictionary with
/// keys: enabled (bool), engine_loaded (bool), engine_from_dat (bool),
/// list_count (int), dat_size_bytes (int), last_build_ms (int),
/// last_error (string), excluded_domains (list of strings). Suitable
/// for a "copy debug info" action. Contains no page URLs.
///
/*--cef()--*/
virtual CefRefPtr<CefDictionaryValue> GetOpenAdBlockStatus() = 0;
```

In `cef/include/cef_browser.h`, class `CefBrowserHost` (per-tab counts;
impl in `CefBrowserHostBase`, reading
`open::OpenAdBlockTabHelper::FromWebContents(GetWebContents())`,
creating nothing — absent helper means 0):

```cpp
/*--cef()--*/
virtual int GetOpenAdBlockBlockedCount() = 0;   // blocked + redirected, current load
/*--cef()--*/
virtual void ResetOpenAdBlockBlockedCount() = 0;
```

Implementation + regeneration procedure (exact):

1. Edit the two headers. Run the translator from `cef/`:
   `cef/tools/translator.sh` (it runs
   `python3 translator.py --root-dir ..`; pass no extra flags for the
   default run). Expect regenerated: `cef/include/capi/cef_request_context_capi.h`,
   `cef/include/capi/cef_browser_capi.h`, the `*_versions` headers,
   `cef/libcef_dll/cpptoc/request_context_cpptoc.cc`,
   `cef/libcef_dll/cpptoc/browser_host_cpptoc.cc` (names per the
   translator's class mapping — accept what it emits), and
   `cef/include/cef_api_versions.h` / hash updates if the tool writes
   them. **Never hand-edit generated files.** If the translator emits
   `AUTO-GENERATED CONTENT - DELETE THIS COMMENT` stubs in impl files,
   that is the signal for step 2.
2. Implement the C++ methods: `CefRequestContextImpl` (in
   `cef/libcef/browser/request_context_impl.{h,cc}` — add the overrides
   to the header's public section; bodies marshal to the UI thread with
   the file's existing `CEF_REQUIRE_UIT` / post-task pattern and call
   the service). `CefBrowserHostBase` (in
   `cef/libcef/browser/browser_host_base.{h,cc}` — it already owns
   `GetWebContents()`, F-13). Status dictionary: build with
   `CefDictionaryValue::Create()` and the service's `AdBlockStatus`
   (§6.2) field-for-field.
3. API version bookkeeping: new methods compile only under the
   experimental API (default). Do **not** run `version_manager.py` and
   do not assign a numbered version — numbered assignment happens at
   CEF upstream-merge time, which Open does not do (F-12).
4. Add the new exported symbols to
   `Engine/fork/verification/expected-symbols.txt` (fork-infra §10.2)
   from real `nm -gU` output on the built framework (expect C symbols
   like `_cef_request_context_set_open_ad_block_enabled` — copy the
   real spellings, mangled C++ listed with a `# demangled:` comment
   where applicable). `engine-status` S-7 must pass with them.
5. Capture as P-5 via `engine-refresh-patches` (paths per §3.3). The
   generated translator files are in-tree files and **do** belong in
   the patch.

Acceptance:

- [ ] Translator run is clean (no `not implemented` warnings left in
      generated impls); re-running it produces no further diff
      (`git -C "$SRC_DIR" status --short` stable across a second run).
- [ ] Build green; `engine-status` all PASS including S-7 with the new
      symbols.
- [ ] §13.3 cases still pass, now driven **only** through the new CEF
      API from the P-6 harness (the harness switches call
      `SetOpenAdBlock*`, never `//open` headers directly).
- [ ] Round-trip: revert P-5 in the tree, `engine-apply`, diff matches
      the captured patch (fork-infra §8 step 5).

PR: P-5 + `expected-symbols.txt`. One PR.

### Step 7 — Bundled lists, catalog, resources (§9.1, §9.3, §9.4)

Work: `tools/fetch-adblock-lists.sh`, `Engine/fork/adblock/list-pins.txt`,
`resources-pins.txt`, `catalog.json` (one-time transform), nothing else.

Acceptance:

- [ ] `tools/fetch-adblock-lists.sh` exits 0 on a clean `Vendor/`;
      `shasum -a 256 Vendor/adblock/*` matches the committed pins;
      first lines verified; `wc -l` within 10% of F-15-era counts
      (~80k / ~57k).
- [ ] Tamper check: flip one byte in a staged file, re-run — must exit
      1 and leave the good file untouched (restore by re-running).
- [ ] `catalog.json` validates (`python3 -m json.tool`), has 46 lists,
      category counts 3/2/5/35/1, `default_enabled` on exactly two,
      and `grep -r diabrowser Engine/fork/adblock/ tools/fetch-adblock-lists.sh`
      prints nothing.
- [ ] Resources staging matches §9.3's final form and its pin; the
      shim loads it (Step 2 driver re-run with resources: a known
      scriptlet name resolves — use the §13.2 test scriptlet instead
      of asserting on real uBO content).

PR: tools + `Engine/fork/adblock/**`. One PR.

### Step 8 — OpenEngine ObjC API + Swift contract (§12)

Work: `Engine/OpenEngine/Sources/OpenEngine/{include/OpenEngineAdBlock.h,
OpenEngineAdBlock.mm}`. Swift `AdBlockStore` lands either here (if the
`OpenFeatures` target exists) or as the contract in §12.3 that the M6 UI
PR implements — decide by whether the target exists at Step 8 start and
state it. Do not create the whole `OpenFeatures` library from this plan.

Acceptance:

- [ ] OpenEngine builds against `Vendor/cef/` (after
      `tools/fetch-engine.sh`) with the app/host target that exists at
      the time; if no host target exists yet, compile-check the `.mm`
      against the CEF headers in the distrib include dir and record
      that as the evidence level (do not claim an app run).
- [ ] End-to-end through the real app when it exists (else through
      `cefsimple` + a 20-line ObjC test host in `/tmp`): enable →
      load test page → `blockedResourceCount` > 0 → exclude site →
      reload → count 0 and ads visible → re-include → blocked again.
- [ ] Per-Profile isolation: two request contexts, different list
      dirs/exclusions, counts and blocking independent (test host or
      app).
- [ ] No CEF type crosses into Swift (grep the Swift surface).

PR: `Engine/OpenEngine/**` (+ Swift target files if applicable). One PR.

### Step 9 — Perf, soak, and rebase notes

Work: §13.4 measurements, a 30-minute `cefsimple` soak on the test site
(reload loop via CDP), and PR-description rebase notes (below).

Acceptance: §13.4 budgets table filled with real numbers; soak with no
crash and stable blocked counts; `engine-status` all PASS.

Rebase notes (write them into the Step 9 PR, future maintainers read
them there): P-2 touches a CEF base header (conflict surface: CEF
adding members to `CefBrowserContext`); P-3's signature must be
re-copied from the new tree's `content_browser_client.h`; P-4's Mojo
additions are additive and should never conflict except on interface
reordering; P-5 requires re-running the translator after any CEF API
change before capturing; P-1 regeneration is fork-infra §12 step 5.

---

## 12. OpenEngine and Swift API surface

CEF types never cross into Swift (architecture rule). OpenEngine is the
only layer that includes CEF headers.

### 12.1 ObjC++ API (new files, exact)

`Engine/OpenEngine/Sources/OpenEngine/include/OpenEngineAdBlock.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Per-Profile ad-block control. One instance per CEF request context.
/// All methods are callable from any queue; they marshal to the CEF UI
/// thread internally. No CEF types appear in this header.
@interface OEAdBlockController : NSObject

/// Designated initializer. |requestContext| is the opaque handle the
/// existing OpenEngine browser layer already wraps (the same object
/// its other per-context APIs take). If OpenEngine has no such wrapper
/// yet, this initializer takes the CefRequestContext* as void* inside
/// the .mm only — the header must still expose no CEF type.
- (instancetype)initWithRequestContextHandle:(void *)requestContext NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Master toggle (Arc key nativeAdBlockEnabled at the Swift layer).
@property (nonatomic) BOOL enabled;

/// Point at <profile>/AdBlock/lists and load (async). Call once at
/// Profile open (seed the directory from bundled lists first, §9.2),
/// then rely on -reloadLists after updates.
- (void)setListDirectory:(NSString *)path;
- (void)reloadLists;

/// Replace per-site exclusions (registrable domains, e.g. @"example.com").
- (void)setExcludedDomains:(NSArray<NSString *> *)domains;
- (NSArray<NSString *> *)excludedDomains;
- (BOOL)isExcludedForHost:(NSString *)host;   // registrable-domain match, Swift-side mirror for instant UI

/// Per-tab blocked count (blocked + redirected, current load). The
/// |browserHandle| is OpenEngine's existing per-browser opaque handle.
/// Returns 0 when no count exists yet. Poll on panel open and on load
/// end; there is no change callback in v1 (D-10).
- (NSInteger)blockedResourceCountForBrowser:(void *)browserHandle;
- (void)resetBlockedResourceCountForBrowser:(void *)browserHandle;

/// "Copy AdBlock debug info" payload (AD-8): the §11 Step 6 status
/// dictionary rendered as sorted "key: value" lines, plus list IDs and
/// ETags from the Swift store appended by the caller. No page URLs.
- (NSDictionary<NSString *, id> *)statusDictionary;

@end

NS_ASSUME_NONNULL_END
```

`OpenEngineAdBlock.mm` implementation: each method forwards to the
corresponding `CefRequestContext` / `CefBrowserHost` method from §11
Step 6 (`SetOpenAdBlockEnabled`, `SetOpenAdBlockListDirectory`, …).
String conversion uses the existing OpenEngine `CefString` helpers; if
none exist, convert via `std::string([s UTF8String])`. Thread marshaling
uses the existing OpenEngine CEF-thread helper; if none exists, use
`CefPostTask(TID_UI, ...)` in the `.mm` only. The count getter resolves
the browser handle to `CefBrowserHost` the same way sibling OpenEngine
APIs do.

### 12.2 What the Site Control Center and Settings read (contract)

- Panel toggle state: `enabled && !isExcludedForHost(currentHost)`.
- Panel count: `blockedResourceCountForBrowser` at panel open + on the
  engine's existing load-end event. No live ticking in v1.
- Toggle action: Swift updates its exclusion set (§12.3), calls
  `setExcludedDomains`, then offers the reload follow-up (SC-6) — the
  engine itself needs no reload for the toggle to be correct on the
  *next* navigation (§1.1), the reload is for the *current* page.
- Scope dialog ("this site" = registrable domain, default;
  "this page only" = exact-host, session-only): v1 engine support is
  registrable domains only. "This page only" is implemented Swift-side
  as a session exclusion that Swift adds on toggle and removes when the
  tab navigates to a different host. Do not extend the CEF API for it.
- Debug info (AD-8): `statusDictionary` lines + Swift's list/ETag lines,
  joined, copied to the pasteboard by the UI. Contents are §6.4-safe.

### 12.3 Swift store contract (`OpenFeatures.AdBlockStore`, M6 UI PR)

State this contract in the Step 8 PR even if the Swift file lands later:

```swift
@MainActor final class AdBlockStore {
  // Mirrors Arc keys for the future importer (AD-6): UserDefaults /
  // BrowserState keys nativeAdBlockEnabled, enabledBlockLists,
  // blockListsPerProfile, plus Open's catalog-state.json per Profile.
  var isEnabled: Bool                       // master, default true (design choice; factory default unproven, AD-6)
  func enabledListIDs(for profile: ProfileID) -> [String]  // default ["EasyList", "EasyPrivacy"]
  func setListEnabled(_ id: String, _ on: Bool, profile: ProfileID)  // publishes a complete generation + reload trigger
  func excludedDomains(for profile: ProfileID) -> [String]
  func setExcluded(_ domain: String, excluded: Bool, profile: ProfileID)  // persists exclusions.json + OEAdBlockController call
  func updateListsNow(profile: ProfileID) async  // §9.5 flow: conditional GETs, atomic writes, one reload trigger
  func debugInfo(profile: ProfileID) -> String
}
```

Rules: downloads use `URLSession` with `If-None-Match`; multi-URL lists
concatenate in catalog order (§9.4); publish all enabled files through the
§9.2 generation transaction; a failed batch keeps the old pointer; the
24 h timer is per Profile and starts 60 s after Profile open (§9.5);
incognito Profiles get an in-memory store seeded from bundled lists
with no disk writes (design §"Per-Profile isolation") — the CEF side
still needs a list directory for incognito, so Swift seeds a
`NSTemporaryDirectory()` dir per incognito session and deletes it at
session end. Record that choice in the Step 8 PR.

Acceptance for Step 8: §11 Step 8 list.

---

## 13. Acceptance harness and checks

No unit tests (AGENTS.md rule 6). Everything below runs the real
`cefsimple` binary against a local HTTP site and inspects the page over
CDP. No desktop driving, no screenshots of other apps.

### 13.1 `cefsimple` smoke harness (patch P-6, test-only)

Edits to `cef/tests/cefsimple/simple_app.cc` (+ `simple_handler` if the
count logging needs `OnLoadEnd` — it does). All behavior is gated by
switches; with no switches, `cefsimple` is byte-for-byte stock in
behavior.

Switches (exact names; read via `CefCommandLine::HasSwitch/GetSwitchValue`
in `SimpleApp::OnContextInitialized`, before browser creation):

```text
--open-adblock-dir=<path>       adblock root (current.json → generation, §9.2) to load
--open-adblock-exclude=<domain> repeatable; seed exclusions
--open-adblock-selftest         Step 3 mode: load dir, poll status until
                                engine_loaded (10 s timeout), print status
                                lines, exit 0/1 without opening a window
--remote-debugging-port=9222    stock CEF switch; the §13.3 driver uses it
```

Behavior when `--open-adblock-dir` is present (in
`OnContextInitialized`, on the global request context — `cefsimple` has
one context; per-Profile isolation is a Step 8 app-level check, not a
cefsimple check):

```cpp
auto context = CefRequestContext::GetGlobalContext();
context->SetOpenAdBlockEnabled(true);
context->SetOpenAdBlockListDirectory(dir);
if (!excludes.empty()) context->SetOpenAdBlockExcludedDomains(excludes);
```

At `CefLoadHandler::OnLoadEnd` for the main frame, log to stderr
(visible with `--enable-logging=stderr`):
`OpenAdBlockSmoke: blocked_count=<n> url_host=<host>` (host only, never
the full URL — §6.4). At `OnLoadStart`, nothing. The harness must call
**only** the §11 Step 6 CEF API at Step 6 and later; at Steps 3–4
(before the API exists) it calls the service directly through
`CefBrowserContext` — and the Step 6 PR rewrites those call sites to
the API and deletes the direct includes. That rewrite is part of P-6's
Step 6 diff, stated here so nobody treats the early form as permanent.

### 13.2 Local test site (overlay `open/adblock/testdata/`)

Serve with: `python3 -m http.server 8931 --bind 127.0.0.1 -d
Engine/fork/src/open/adblock/testdata` (run from the repo; the overlay
files are also in the tree after `engine-apply` — either copy serves).
Third-party cases need a second origin: run a second server on
`127.0.0.2` port 8932 serving the same directory (macOS loopback aliases
work without configuration). The page must not reference the network.

`generations/1/testlist.txt` (include it with its size/hash in a fixture
`manifest.json` and bind that manifest through `current.json`, §9.2; exact rules; ABP syntax; `127.0.0.1` is the
first-party host, `127.0.0.2` the third-party host):

```text
[Adblock Plus 2.0]
! Open ad-block test list. Deterministic rules for docs/plans/adblock-fork.md §13.
/ads/banner.js
||127.0.0.2/track/pixel.gif
@@||127.0.0.1/ads/allowed-banner.js
||127.0.0.1/ads/important.js$important
@@||127.0.0.1/ads/important.js
||127.0.0.1/ads/redir.js$redirect=noop.js
||127.0.0.1/api/data.json$removeparam=utm_source
||127.0.0.1/generichide.html$generichide
127.0.0.1##.ad-slot
127.0.0.1##.late-ad
127.0.0.1##.ad-slot-allowed
127.0.0.1#@#.ad-slot-allowed
##.generic-ad
127.0.0.1##+js(open-test-scriptlet)
```

The `$generichide` rule is scoped to the `generichide.html` URL
pattern, so `index.html` keeps generic hiding and the second page
tests its suppression.

`index.html` must contain (exact element hooks for §13.3):

- `<script src="/ads/banner.js">` (blocked by path rule),
  `<script src="/ads/allowed-banner.js">` (exception-allowed),
  `<script src="/ads/important.js">` (blocked despite exception —
  `$important`), `<script src="/ads/redir.js">` (redirect to the
  `noop.js` resource: the page sets `window.__redirLoaded` only if the
  replacement script runs — the resources payload for the test is a
  `resources.txt` beside `testlist.txt` defining `noop.js` as a script
  containing `window.__redirLoaded = true;`),
  `<img src="http://127.0.0.2:8932/track/pixel.gif">` (third-party
  block), `<img src="/track/pixel.gif">` (first-party allow),
- a `fetch('/api/data.json?utm_source=x&keep=1')` whose final URL the
  page stores on `window.__lastFetchURL` via a same-origin echo
  endpoint — `http.server` cannot echo; instead the page fetches the
  testdata file `api/data.json` and CDP network events assert the
  request URL lost `utm_source` (§13.3 N-5 reads CDP, not the page),
- `<div class="ad-slot">` (domain cosmetic hide),
  `<div class="ad-slot-allowed">` (`#@#` exception — must stay visible;
  note the list also needs `127.0.0.1##.ad-slot-allowed` for the
  exception to have something to except: add it above `#@#`),
  `<div class="generic-ad">` (generic hide via class token),
- a button-free timer: at +500 ms, insert
  `<div class="late-ad">` and `<div class="generic-late">` (the second
  via class `generic-ad` added dynamically — one rule, two paths:
  `.late-ad` is domain-specific so it hides at document start only if
  present then; dynamic insertion tests the token flow. Give the late
  node class `late-ad generic-ad` so both channels are exercised),
- the scriptlet target: rule `##+js(open-test-scriptlet)` + a
  `resources.txt` scriptlet named `open-test-scriptlet` whose body is
  `window.__openTestScriptlet = 1;`.

`generichide.html`: contains `<div class="generic-ad">` (must stay
**visible** — generic hide suppressed) and `<div class="ad-slot">`
(must hide — domain rules still apply under `generichide`).

Static files: `ads/banner.js`, `ads/allowed-banner.js`,
`ads/important.js`, `ads/redir.js` (each: a comment line only; presence
on disk proves blocks are ours, not 404s), `track/pixel.gif` (a real
1×1 GIF — generate with
`printf 'GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b' > track/pixel.gif`
at Step 4; verify with `file`), `api/data.json` (`{}`).
`resources.txt` format: whatever §9.3's assembler decision produced —
for the test, author it in that format with the two resources above.

### 13.3 CDP check cases (driver in `/tmp`, never committed)

Driver: a Python script (`/tmp/open-adblock-check.py`, stdlib only:
`urllib` + `websocket` — if no websocket lib is available, use CEF's
`--remote-debugging-pipe` or the DevTools HTTP `/json` + a minimal
WebSocket client written in the script; do not add repo dependencies).
It: launches `cefsimple` (§13.1 switches, test user-data dir), attaches
to the page target, enables `Network` + `Runtime`, loads the URL, and
asserts. Each case prints `PASS|FAIL <id> <detail>`; exit code is the
failure count. Re-running is idempotent (fresh `--user-data-dir` per
run under `/tmp`).

Network cases (Steps 4+):

| ID | Setup | Assert |
|---|---|---|
| N-1 | test lists | `/ads/banner.js` request fails `ERR_BLOCKED_BY_CLIENT`; `allowed-banner.js` succeeds; page `window.__bannerLoaded` undefined |
| N-2 | test lists | third-party `pixel.gif` (127.0.0.2) blocked; first-party `pixel.gif` succeeds (party mapping, §7.3) |
| N-3 | test lists | `important.js` blocked despite the `@@` rule (`$important`) |
| N-4 | test lists | `redir.js` completes; `window.__redirLoaded == true`; count includes 1 redirected |
| N-5 | test lists | CDP request for `data.json` has `keep=1` and no `utm_source` (`$removeparam`) |
| N-6 | `--open-adblock-exclude=127.0.0.1` | nothing blocked; counts 0; no style elements (also C-6) |
| N-7 | no switches | everything loads; no `OpenAdBlockSmoke` log lines |
| N-8 | list dir removed/empty | page loads fully; status `engine_loaded=0`; no crash (cold-start allow, §10 rule 1) |

Cosmetic cases (Step 5+):

| ID | Page | Assert (via `Runtime.evaluate` `getComputedStyle`) |
|---|---|---|
| C-1 | `index.html` | `.ad-slot` display `none`; `#open-adblock-hide` exists with `data-open-adblock` |
| C-2 | `index.html` | `.ad-slot-allowed` display not `none` |
| C-3 | `generichide.html` | `.generic-ad` visible; `.ad-slot` hidden; no token reports in `--v=1` log |
| C-4 | `index.html` at +2 s | late `.late-ad.generic-ad` node display `none` (token round-trip) |
| C-5 | `index.html` | `window.__openTestScriptlet == 1` |
| C-6 | excluded (N-6 run) | `document.querySelectorAll('style[data-open-adblock]').length == 0` |

Count cases: after `index.html` load, read the harness's
`OpenAdBlockSmoke` stderr line: `blocked_count` equals blocked +
redirected from N-1…N-4 (compute the expected integer from the rules
at Step 4 and hard-code it in the driver with a comment showing the
sum). Reload via CDP: count resets and re-accumulates to the same
value. `history.pushState` + a manual fetch of `banner.js`: count
increments, no reset.

Real-lists case (Step 7+): point `--open-adblock-dir` at a dir holding
the staged `easylist.txt` + `easyprivacy.txt` renamed per §9.2
(`EasyList.txt`/`EasyPrivacy.txt` — file names only need the `.txt`
suffix + header check, §6.3.2). Load `index.html`: nothing on the page
needs blocking, so assert only "page loads, count 0, no crash" plus
the status line shows `list_count=2`. Real-site checks (a news page
with known EasyList cosmetic targets) are manual, on the record in the
PR, never automated against live sites in this harness.

### 13.4 Perf checks (Step 9; budgets are pass/fail)

Method: same `cefsimple` binary, test site, CDP. Five runs each,
median reported. Machine: record `sysctl -n machdep.cpu.brand_string`.

| Check | Method | Budget |
|---|---|---|
| DAT load (warm start) | second launch with `engine.dat` present; time from process start to `OpenAdBlockSmoke` first-load line, minus the same measure with ad blocking off | ≤ 250 ms added (F-15 says ~47 ms deserialize; the rest is harness noise — investigate above 250) |
| Text build (cold) | delete `engine.dat`; same measure | ≤ 1500 ms added, and the first page still paints during it (§10 rule 1 — assert the page's `load` event fires before the status shows `engine_loaded` if the build is slow; if it does not, that is a finding, not a failure) |
| Page overhead | `index.html` + a `many.html` test page with 200 `<img>` tags alternating blocked/allowed paths; `performance.now()` around load via CDP, blocking on vs off | ≤ 5 ms added at 200 requests (≈ 0.7 ms expected from F-15 + throttle overhead; fail above 5 ms) |
| Cosmetic query | from the Step 3 selftest log (`last_build_ms` excludes it — instead time 100 `CosmeticResources` calls in the selftest behind `--open-adblock-selftest` on the real lists and print the mean) | ≤ 100 µs/page (F-15: ~36 µs) |
| Idle CPU | loaded test page, 30 s idle, `top -pid` sample | ≈ 0% (no timers, no observers firing — the token observer is DOM-mutation driven only) |
| Startup regression (app-level) | when the Open app exists: cold launch to first paint, blocking on (DAT warm) vs off | within the architecture 700 ms budget; report both numbers |

The Step 2 throwaway driver lives at `/tmp/adblock-shim-driver/`
(a tiny Cargo or C++ driver linking the shim — implementer's choice;
C++ via the CXX header is closer to production). It is verification
scaffolding, never committed (fork-infra rule: throwaway probes stay in
`/tmp`).

### 13.5 What "verified" means for this plan

A step is verified when: its §11 checkboxes have real output in the PR,
`engine-status` is green, the §13.3 cases for its scope pass, and no
check was narrowed to pass (no case deleted, no budget raised). If a
case cannot run (for example CDP WebSocket unavailable), the PR says so
and states what ran instead. Never substitute a unit test.

---

## 14. Risks and open questions

| # | Risk / question | Plan's handling |
|---|---|---|
| R-1 | `adblock 0.8.11` fails under Chromium `rustc 1.100.0` (toolchain fragility already bit once, F-13/F-15) | Step 1 gate: stop, report verbatim, lead decides (crate bump reopens the design benchmark; D1 `subresource_filter` fallback in adblock-design stays the escape hatch) |
| R-2 | MPL-2.0 (crate) + GPL-3.0 (uBO resources) distribution obligations | Pins + `THIRD_PARTY.md` + license files land with the code (§4.5, §9.3); counsel review gates public release only (fork-infra Q-2) |
| R-3 | GN include-path / visibility friction between `//open/adblock` and `libcef_static` (§6.5) | Two sanctioned forms (seam function in P-4, or direct call); pick at Step 5, record it; never a link cycle |
| R-4 | Cosmetic payload arrives after script-context creation on some navigation kinds (BFCache, same-document) | Immediate-apply branch (§8.2); §13 measures fresh navigations; BFCache flash, if observed, is a documented v1 limitation, not a silent gap |
| R-5 | `fetch()`/XHR type loss (`kEmpty` → `"other"`) weakens `$xmlhttprequest` rules | Documented (§7.3); revisit only with a proven header/initiator signal in this tree |
| R-6 | Scriptlet resources go stale; YouTube/news breakage appears first | Resources versioned with lists (§9.3/§9.5); per-site toggle is the user escape; **no** shipped pre-emptive allowlist (adblock-design Risk 4 — Arc's YouTube entry is for uBlock, not proven for this engine) |
| R-7 | Full 46-list memory: two lists = 6.78 MiB DAT; regional sets grow it | v1 defaults stay at two lists; Step 9 records DAT size + browser RSS with all generic+privacy lists enabled before any regional default is considered |
| Q-1 | Does the app milestone want `OpenFeatures` created by Step 8 or later? | Step 8 decides by target existence (§11 Step 8); the §12.3 contract is normative either way |
| Q-2 | Exact uBO resources input format for crate 0.8.11's assembler | Resolved by reading the crate source at Step 7 (§9.3); if it needs a directory, the reserved-name change there applies |
| Q-3 | Arc's factory default (on/off), exact scope-dialog labels, update interval | Unproven Arc facts (AD-6/§7.4 of features-advanced). Open's choices (on, "this site" default, 24 h) are product decisions recorded in §9.5/§12.2; the lead may revisit after runtime observation of Arc per AGENTS.md RE rules |

Errata rule: when implementation resolves Q-2/Q-3 or picks a sanctioned
fork (R-3, §8.3 message path), append a dated line to this section in
the same PR. This file stays the record.

---

## Appendix A. Command cheat sheet

```bash
# Gate (every step)
pgrep -fl 'autoninja|siso' || echo "no build running"

# Apply + status (fork-infra scripts)
Engine/fork/scripts/engine-apply
Engine/fork/scripts/engine-status

# Build (detached, bounded)
Engine/fork/scripts/engine-build --detach
Engine/fork/scripts/engine-build --target third_party/rust/adblock/v0:lib
Engine/fork/scripts/engine-build --target open/adblock/rust:open_adblock_rust

# Fetch bundled lists (Step 7+)
tools/fetch-adblock-lists.sh
tools/fetch-adblock-lists.sh --update-pins   # reviewed pin updates only

# Serve the test site (two origins)
python3 -m http.server 8931 --bind 127.0.0.1 -d Engine/fork/src/open/adblock/testdata
python3 -m http.server 8932 --bind 127.0.0.2 -d Engine/fork/src/open/adblock/testdata

# Smoke run (after Step 6; OUT = fork-infra dev out dir)
OUT=~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64
"$OUT/cefsimple" --user-data-dir=/tmp/open-adblock-smoke \
  --open-adblock-dir=/tmp/open-adblock-lists \
  --remote-debugging-port=9222 --enable-logging=stderr \
  --url=http://127.0.0.1:8931/index.html
python3 /tmp/open-adblock-check.py   # §13.3 driver (throwaway, in /tmp)
```

## Appendix B. Evidence map (spot-check before implementing)

| Claim in this plan | Source to re-read |
|---|---|
| Throttle override point (F-1, §7.1) | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.{h,cc}`; `content/public/browser/content_browser_client.h:1750` |
| Throttle + request types (F-3, F-4) | `third_party/blink/public/common/loader/url_loader_throttle.h`; `services/network/public/cpp/resource_request.h`; `services/network/public/mojom/fetch_api.mojom:26` |
| Crate API + features (F-8, F-9) | `~/.cargo/registry/src/*/adblock-0.8.11/src/{engine,request,blocker,cosmetic_filter_cache}.rs`, crate `Cargo.toml [features]` |
| Document-start hook (F-10) | `cef/libcef/renderer/render_frame_observer.cc:129`; `cef/libcef/renderer/frame_impl.cc` (`OnContextCreated`, `queued_context_actions_`) |
| CEF translator + API versioning (F-12) | `cef/tools/translator.README.txt`; `cef/include/cef_api_hash.h` |
| Context/service accessors (F-13) | `cef/libcef/browser/browser_context.h`; `cef/libcef/browser/request_context_impl.h:233`; `cef/libcef/browser/browser_host_base.h:401` |
| Catalog facts (F-14, §9.4) | `docs/re/features-advanced.md` §7 (AD-3/AD-4) — committed findings; the raw manifest stays in `.re/` |
| Performance expectations (F-15) | `docs/adblock-design.md` §Benchmark |







## Appendix — Lead decisions (2026-10-25)

- Approved as written. Q-2 (uBO resources format for adblock 0.8.11) is resolved at Step 7 by reading the crate source. R-3: if GN rejects the include path, move the cosmetic sender fully into the CEF patch.
- Licensing: adblock-rust (MPL-2.0) and uBlock Origin resources/scriptlets (GPL-3.0) are allowed for development and private use. Both go on the pre-release license checklist (docs/followups.md) before any public release.
- Phasing: the Swift-side, engine-independent parts (list catalog with the 46 upstream URLs, downloader with ETag + SHA-256 pins, on-disk list directory layout per profile, per-site allowlist and global toggle model, `AdBlockStore` contract) start now as an OpenKit target. Engine Steps 1–8 wait for the stock build and the fork scripts (PR #25).

### Swift-slice implementation notes (2026-10-25)

The Lead decisions Swift slice lands as `OpenAdBlock` in OpenKit. Its catalog and
pins are package resources; `tools/fetch-adblock-lists.sh` reads those same pins.
The source manifest has regional ID `dk` (not the prose's `ndk`) and 18 Korean
sources (not 17). BCNYBlocklists' two mirror-relative paths have no public upstream
host, so its catalog entry is explicitly unavailable rather than using the mirror
or inventing a URL. The Lead's 2026-10-25 generation decision in §9.2 supersedes
the earlier list-directory and DAT placement contract. See [adblock-lists.md](../adblock-lists.md) for the Swift store
contract, real CLI evidence, and the deferred OpenEngine adapter/resources work.

### Step 1 as built (2026-10-26)

- **Target and epoch.** `gnrt` names the epoch `v0_8`, not `v0`: the target is `//third_party/rust/adblock/v0_8:lib`. Steps 2 onward use that label.
- **Pins.** `rmp` resolved to 0.8.15, so the conditional pin `=0.8.11` is in the fragment as its own `[dependencies.rmp]` table (a bare line after `[dependencies.adblock]` would land inside that table).
- **Crate patches** (`third_party/rust/chromium_crates_io/patches/`, captured in the Rust patch):
  - `seahash-v3`: adds upstream's MIT license text (the crate shipped without one).
  - `adblock-v0_8` and `libafl-v0_15`: regex without its `perf` features.
  - `gnrt` applies crate patches only when it downloads a crate, so delete the vendor directory to re-apply one.
- **gnrt config** (`gnrt_config.toml.open`):
  - `regex` moves from `group = 'test'` to `'safe'`. Without that, `adblock` inherits test-only status and `libcef_static` cannot link it.
  - `thiserror` and `idna` get per-epoch configs.
  - Reasons: docs/engine-patches.md P8 "Security review" (lead decisions 2026-10-26).
- **R4 (crate alone).** A vendored crate is not in the GN graph until something depends on it, and a target inside a `.gni` import is rejected. R4 therefore ran with the GN arg `root_extra_deps = [ "//third_party/rust/adblock/v0_8:lib" ]` (not committed): `engine-build --target third_party/rust/adblock/v0_8:lib` exit 0, `libadblock_lib.rlib` 5.1 MB, `rustc 1.100.0 1edd55dcfcd573872c727fa3e086369a71661ee0`. Step 2 makes the crate reachable for real.
- **Size.** `patches/rust/0001-adblock-vendor.patch` is 11.3 MB (gate: 20 MB).
- **Closure.** 23 new crate directories; all MIT, Apache-2.0, Unicode-3.0 or MPL-2.0 (adblock). No GPL-family license. Rows: `Engine/fork/licenses/THIRD_PARTY.md`.
- **List pins.** The bundled list pins are stale: EasyList changed upstream. The perf bench used current lists from the official URLs (never Arc's bundle). Refreshing the pins is a reviewed Step 7 action (`docs/followups.md`).
