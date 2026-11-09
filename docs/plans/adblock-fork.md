# Ad blocking in the fork — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Revised 2026-10-26 after engine review round 1 of #97/#98/#100 (findings C-1,
C-2, 98-1, 98-2, 98-4, 100-1, 100-5): the network hook (§7), the thread and
cost model (§7.6–§7.8), cosmetic delivery (§8), the DAT and resources model
(§9.2, §9.3) and memory (§6.6) changed. The lead approved the revision on
2026-10-26 with eight rulings (v1 has no scriptlets, `:style()` or
procedural filters; a 16 KiB match cap). The appendix entry "Lead
decisions (2026-10-26)" lists every change, every ruling, and why; the
entry "Review r1 changes (2026-10-26)" maps each plan-review finding to
the section that fixes it. Where an older paragraph conflicts
with a section marked "revised 2026-10-26", the revised section wins.
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
  MPL-2.0, in the **browser process**, cosmetic filters + scriptlets
  injected at document start. Lead ruling 6 (2026-10-26) narrows v1 to
  network blocking plus plain CSS hiding; scriptlets move to post-v1
  (§8.5). The design said "matched via a
  `blink::URLLoaderThrottle`"; that hook sees only browser-initiated
  requests (F-16), so since 2026-10-26 matching runs in a URLLoaderFactory
  proxy (§7, D-11). Measured on EasyList + EasyPrivacy: ~2.15 µs per network
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
| C++ service | `//open/adblock`: `OpenAdBlockService` per `CefBrowserContext` (one per Open Profile), per-site allowlist, status (§6). Since 2026-10-26: all engine calls on one matcher sequence, engines shared between Profiles with identical inputs, engines freed off the UI thread (§6.6, §7.6) |
| Network blocking | Revised 2026-10-26: `OpenAdBlockURLLoaderFactory`, a URLLoaderFactory proxy installed by `ChromeContentBrowserClientCef::WillCreateURLLoaderFactory` ahead of Chrome's interceptors, plus WebSocket and WebTransport hooks; block / stub response for `$redirect` / `$removeparam` / subframe CSP; main frame never blocked; per-tab counters (§7) |
| Cosmetic hiding | Revised 2026-10-26: the renderer pulls the frame's sanitized hide selectors at `DidCreateDocumentElement` over one process-level Mojo interface served on the matcher sequence, inserts them as user-origin style sheets, and runs the class/ID observer in an isolated world; `generichide` / `#@#` exceptions (§8). Plain CSS hiding only (lead ruling 6): no scriptlets, `:style()`, `:remove*()` or procedural filters in v1 (post-v1 design: §8.5) |
| Lists | Bundled EasyList + EasyPrivacy fetched at build time from official URLs with pinned SHA-256 (never from Arc's bundle or mirror); a bundled, pinned `resources.json` that in v1 serves only `$redirect` stubs (changes only with an app update, lead ruling 7); per-Profile storage, ETag update flow, DAT fast startup only for lossless list sets (§9) |
| CEF API | Six free functions in overlay `cef_open_adblock.h`, translator-generated C API/wrappers and a libcef overlay implementation; no new context/browser virtuals (§11 Step 6) |
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
- `$redirect` stub responses for CORS-mode requests (fetch/XHR across
  origins, module scripts, `crossorigin` elements). Revised 2026-10-26: the
  proxy serves the crate's redirect resource as a stub response for
  no-CORS and same-origin requests of any type, and blocks CORS-mode
  requests that match a redirect rule (§7.4).
- Procedural cosmetic filters (`#?#`, `:has-text()`, `:-abp-*`, `:xpath()`,
  `:upward()`, `:matches-css*()` and the other uBO/ABP extended operators).
  Revised 2026-10-26: the crate passes them through as plain selectors
  when `css-validation` is off (review 98-1), so the shim drops them (§8.3).
- Lead ruling 6 (2026-10-26): scriptlets (`##+js(...)`), `:style()` and the
  uBO `:remove*()` actions are **not** in v1 either. v1 is network blocking
  plus plain CSS hiding. Their design is kept in §8.5 (post-v1).
- `$removeparam` on main-frame and subframe navigations (confirmed by lead
  ruling 4, 2026-10-26). v1 rewrites subresource GET/HEAD requests only
  (§7.4).
- Revised 2026-10-26: Open now has **one** Mojo interface of its own,
  `open_engine.mojom.AdBlockCosmetics` (process-level, §8.2). The
  `cef.mojom` frame pipes connect only after commit, so they cannot carry
  document-start data (F-27). Arc also has its own interface
  (`arc.mojom.AdBlockerAgent`). No `cef.mojom` change remains in this plan.

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
| F-1* | CEF does **not** override `CreateURLLoaderThrottles`. `ChromeContentBrowserClientCef` inherits Chrome's. It **does** override `CreateThrottlesForNavigation` at `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:638`, delegating to Chrome + `throttle::CreateThrottlesForNavigation`. Still true 2026-10-26; Open no longer plans to add the override (D-11) | `grep -n CreateURLLoaderThrottles cef/libcef/browser/chrome/*` (no hit); read of the `.h` override list |
| F-2 | `content::ContentBrowserClient::CreateURLLoaderThrottles(request, browser_context, wc_getter, navigation_ui_data, frame_tree_node_id, navigation_id)` is called on the UI thread and returns `std::vector<std::unique_ptr<blink::URLLoaderThrottle>>`. It sees browser-initiated requests only (F-16) | `content/public/browser/content_browser_client.h:1750` |
| F-3 | `blink::URLLoaderThrottle` hooks: `WillStartRequest(network::ResourceRequest*, bool* defer)` (mutating `request->url` causes an internal redirect), `WillRedirectRequest`, `BeforeWillProcessResponse`, `WillProcessResponse(response_url, response_head, defer)` (headers mutable), and `Delegate::CancelWithError(int, std::string_view)`, `Delegate::InterceptResponse(...)` | `third_party/blink/public/common/loader/url_loader_throttle.h` |
| F-4 | `network::ResourceRequest` carries `url`, `request_initiator` (`std::optional<url::Origin>`), `destination` (`network::mojom::RequestDestination`), `is_outermost_main_frame` | `services/network/public/cpp/resource_request.h:91,205,246,255`; enum at `services/network/public/mojom/fetch_api.mojom:26` (`kDocument=3`, `kFrame=6`, `kIframe=7`, `kImage=8`, `kScript=13`, `kStyle=16`, `kFont=5`, `kWorker=20`, `kServiceWorker=14`, …) |
| F-5 | Blocked loads surface as `net::ERR_BLOCKED_BY_CLIENT` | `net/base/net_errors.cc:87` |
| F-6* | Rust vendoring is the `gnrt` flow: direct deps in `third_party/rust/chromium_crates_io/Cargo.toml`, Chromium config in `gnrt_config.toml`, generated `third_party/rust/<crate>/v<epoch>/BUILD.gn` + `README.chromium`, sources in `third_party/rust/chromium_crates_io/vendor/<crate>-v<epoch>/`. Commands: `vpython3 tools/crates/run_gnrt.py {add,vendor,gen}` | `third_party/rust/README-importing-new-crates.md`; template `third_party/rust/adler2/v2/BUILD.gn` (a `cargo_crate("lib")` target, `visibility = ["//third_party/rust/*"]` until listed in `Cargo.toml`) |
| F-7 | First-party Rust uses `rust_static_library` with `cxx_bindings = ["src/lib.rs"]` for CXX bridges | `build/rust/rust_static_library.gni`; example `build/rust/tests/test_rust_static_library/BUILD.gn` |
| F-8* | `adblock 0.8.11` API (from the crate source in the local cargo registry, `~/.cargo/registry/src/*/adblock-0.8.11/`): `lists::FilterSet::add_filter_list(&str, ParseOptions)`; `Engine::from_filter_set(set, optimize=true)`; `Engine::serialize_raw() -> Vec<u8>`; `Engine::deserialize(&mut self, &[u8])`; `Engine::check_network_request(&Request) -> BlockerResult{matched, important, redirect: Option<String>, rewritten_url: Option<String>, exception, filter}`; `Engine::get_csp_directives(&Request) -> Option<String>`; `Engine::url_cosmetic_resources(url: &str) -> UrlSpecificResources{hide_selectors, style_selectors, remove_selectors, remove_attrs, remove_classes, exceptions, injected_script, generichide}`; `Engine::hidden_class_id_selectors(classes, ids, exceptions: &HashSet<String>) -> Vec<String>`; `Engine::use_resources(iter)`, resources are `resources::Resource{name, aliases, kind, content (base64), dependencies, permission}`; `Request::new(url, source_url, request_type: &str)` where the type string accepts `"script"`, `"image"`, `"stylesheet"`, `"font"`, `"media"`, `"subdocument"`, `"document"`, `"websocket"`, `"xhr"`, `"ping"`, `"other"`, … and computes first/third-party itself from the two URLs' registrable domains | `src/engine.rs`, `src/request.rs`, `src/blocker.rs:29`, `src/cosmetic_filter_cache.rs:22`, `src/resources/mod.rs:126` |
| F-9 | With default features (`object-pooling` via `lifeguard`, `unsync-regex-caching`) the crate only asserts `Engine: Send + Sync` when those features are **off**. §5 therefore disables them, keeping `Engine: Send + Sync` so the C++ service can share one engine across throttle calls under a read lock. Correction 2026-10-26: `Sync` buys no parallel matching, because the crate serializes every check of one engine on an internal mutex (F-30). `Send` is still needed: engines move from the build runner to the matcher sequence (§7.6) | `src/engine.rs` `_assertions` block; `[features]` in the crate `Cargo.toml` |
| F-10 | CEF frame JS today is **not** document-start: browser `CefFrameHostImpl::ExecuteJavaScript` → `cef.mojom.RenderFrame::SendJavaScript` → renderer `CefFrameImpl::SendJavaScript` → `WebLocalFrame::ExecuteScript`, which runs whenever the Mojo call arrives. The renderer hook that **is** document-start is `CefRenderFrameObserver::DidCreateScriptContext` (`cef/libcef/renderer/render_frame_observer.cc:129`), which calls `CefRenderProcessHandler::OnContextCreated` and then `CefFrameImpl::OnContextCreated`, draining `queued_context_actions_` | Reads of `cef/libcef/browser/frame_host_impl.cc:178,423`, `cef/libcef/common/mojom/cef.mojom:73`, `cef/libcef/renderer/frame_impl.cc:169,404,874`, `cef/libcef/renderer/render_frame_observer.cc:129` |
| F-11 | `cef.mojom` already defines the two frame interfaces cosmetic traffic needs: `RenderFrame` (browser→renderer: `SendJavaScript`, `SendMessage`, `SendCommand`, …) and `BrowserFrame` (renderer→browser: `SendMessage`, `FrameAttached`, …). Mojo bindings regenerate from `cef/libcef/common/mojom/cef.mojom` via GN; the CEF **translator does not** process Mojo files. 2026-10-26: these pipes connect only after commit (F-27), so v1 cosmetics no longer use them | `cef/libcef/common/mojom/cef.mojom:50,84` |
| F-12 | New CEF C++ API in `cef/include/*.h` (methods marked `/*--cef()--*/`) generates the C API (`cef/include/capi/*_capi.h`, `cef/libcef_dll/cpptoc/`, `cef/libcef_dll/ctocpp/`) with `cef/tools/translator.py` (run via `cef/tools/translator.sh`). New API must be guarded with `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`; never use `CEF_API_VERSION_NEXT` (999998) in committed code | `cef/tools/translator.README.txt`; `cef/include/cef_api_hash.h:40-90` |
| F-13* | Per-Profile browser object: `CefBrowserContext` (`cef/libcef/browser/browser_context.h:92`, UI thread, self-deletes when the last `CefRequestContextImpl` releases it). Accessors that exist today: `CefBrowserContext::FromBrowserContext(const content::BrowserContext*)`, `CefRequestContextImpl::browser_context()` (`cef/libcef/browser/request_context_impl.h:233`), `CefBrowserHostBase::GetWebContents()` (`cef/libcef/browser/browser_host_base.h:401`). CEF keeps **no** `KeyedService` registrations of its own | Reads of the three headers; `grep -rn KeyedService cef/libcef/browser/` (no hits) |
| F-14 | The 46-list catalog shape is `KnownBlockList{id, display_name, type, info_url, urls[], resource_name?}`. Arc's URLs are Arc's mirror (`https://dia-blocklists-release.diabrowser.engineering/<upstream path>`). The upstream URL is recovered by replacing that prefix with `https://` (for example `…/easylist.to/easylist/easylist.txt` → `https://easylist.to/easylist/easylist.txt`). Open never fetches the Arc mirror (adblock-design §"List catalog"; features-advanced AD-4) | `.re/features-advanced/blocklist-manifest.json` (git-ignored raw data; the committed transform is §9.4) |
| F-15 | Budgets from the design benchmark (Apple Silicon, release, system cargo — re-measure in-tree at Step 9): network check ~2.15 µs, cosmetic page query ~36 µs, DAT 6.78 MiB / ~47 ms load for EasyList + EasyPrivacy, text build ~130 ms + ~30 ms parse. App budgets: cold launch to first paint ≤ 700 ms, idle CPU ≈ 0%. The 2.15 µs figure used short URLs; see F-35 | [adblock-design.md](../adblock-design.md) §Benchmark, [architecture.md](../architecture.md) §Performance budgets |

Facts added 2026-10-26 (read-only inspection of the same tree, which then
had #93 and ad-block Steps 1–3 applied, and of the crate source in
`~/.cargo/registry/src/*/adblock-0.8.11/`):

| ID | Fact | Evidence |
|---|---|---|
| F-16 | `CreateURLLoaderThrottles` is for "a browser-initiated request. These include navigation requests and requests for web worker scripts." Renderer subresources (images, scripts, CSS, fetch, XHR) never reach it, so the old §7 would block almost nothing (review C-1) | `content/public/browser/content_browser_client.h:1733-1735`; single caller `CreateContentBrowserURLLoaderThrottles` (`content/browser/loader/url_loader_throttles.cc:50`) |
| F-17 | `ContentBrowserClient::WillCreateURLLoaderFactory(browser_context, frame, render_process_id, type, request_initiator, isolation_info, navigation_id, ukm_source_id, factory_builder, header_client, bypass_redirect_checks, disable_secure_dns, factory_override, navigation_response_task_runner, is_for_network_service)` runs on the UI thread for each factory. `URLLoaderFactoryType`: `kNavigation`, `kDownload`, `kDocumentSubResource`, `kWorkerMainResource`, `kWorkerSubResource`, `kServiceWorkerScript`, `kServiceWorkerSubResource`, `kPrefetch`, `kDevTools`, `kEarlyHints`. `frame` is null for service-worker and shared-worker factories. `isolation_info` is set only for untrusted (renderer) factories | `content_browser_client.h:1843-1876` (enum), `:1879-1993` (doc + declaration) |
| F-18 | `network::URLLoaderFactoryBuilder`: a request passes the interceptors in the order of the `Append()` calls. The first `Append()` is the outermost interceptor | `services/network/public/cpp/url_loader_factory_builder.h:21-53` |
| F-19 | CEF's override: non-CEF profiles go straight to Chrome (`:499-510`); then Chrome's `WillCreateURLLoaderFactory` runs (`:536-541`); then CEF appends `net_service::ProxyURLLoaderFactory` (`:568-571`). Chrome installs the WebRequest proxy first (`chrome_content_browser_client.cc:6811-6827`), then enterprise-header, sign-in and other proxies. Content appends DevTools interceptors after all embedder ones (`content/browser/loader/url_loader_factory_utils.cc:245-267`). Chain today: WebRequest → Chrome proxies → CEF proxy → DevTools → network service | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:482-572`; `chrome/browser/chrome_content_browser_client.cc:6794-6886` |
| F-20 | CEF's proxy runs on the **IO thread** (`CreateProxy` posts `CreateOnIOThread`), re-implements parts of CORS, and never sees CORS preflights: "CORS preflight requests are handled in the network process" | `cef/libcef/browser/net_service/proxy_url_loader_factory.cc:1451-1477`, `:495-591`, `:203-204` |
| F-21 | WebRequest's proxy is **UI-thread**; it exists only while an extension with webRequest or declarativeNetRequest is enabled (or for WebView embedders); it expresses a changed URL as a synthetic `307` with `Non-Authoritative-Reason: WebRequest API` | `extensions/browser/api/web_request/web_request_proxying_url_loader_factory.cc:1573,1617`, `:733-765`; `web_request_api.cc:849-876` |
| F-22 | Factory call sites (not exhaustive; revised 2026-10-26, review r1 finding 16): document subresources and the fetch-keepalive factory (`content/browser/renderer_host/render_frame_host_impl.cc:14255-14268`, `:8469-8477`); dedicated and shared worker subresources (`content/browser/worker_host/dedicated_worker_host.cc:726`, `content/browser/worker_host/shared_worker_host.cc:529`); worker main scripts (`content/browser/worker_host/worker_script_fetcher.cc:523`); service worker scripts and fetches (`content/browser/service_worker/embedded_worker_instance.cc:385,399`); the service-worker context wrapper's script factory (`content/browser/service_worker/service_worker_context_wrapper.cc:1998-2004`, `kServiceWorkerScript`, frame null); service-worker navigation preload (`content/browser/service_worker/service_worker_client.cc:1424-1434`, `kNavigation`, `factory_override` null); network navigations (`content/browser/loader/navigation_url_loader_impl.cc:2309-2322`); WebUI navigations (`navigation_url_loader_impl.cc:711`); DevTools (`content/browser/devtools/protocol/network_handler.cc:4154`; built with `CreatePendingRemote` and no `ContentClientParams`, so like early hints it never calls the hook — the outcome "not proxied" is the same, §7.2). WebUI and other non-network scheme factories are also wrapped as `kDocumentSubResource` (`render_frame_host_impl.cc:12860-12875`, `:12985-13005`). Early hints (`content/browser/renderer_host/navigation_request.cc:5704`) are labeled `kEarlyHints` but never call the hook (§7.2) | `grep -rn 'URLLoaderFactoryType::k' content/browser` |
| F-23 | WebSocket: content calls `WillInterceptWebSocket(frame)` and, if true, gives the connection to `CreateWebSocket(frame, factory, url, site_for_cookies, user_agent, handshake_client, options)`. `frame` can be null (workers). Chrome returns true only for a frame that has WebRequest proxies and proxies in `CreateWebSocket`. A handshake fails with `WebSocketHandshakeClient::OnFailure(message, net_error, response_code)`. CEF overrides none of these | `content/browser/websockets/websocket_connector_impl.cc:146-150`; `chrome_content_browser_client.cc:6960-6980`, `:6998-7021`; `services/network/public/mojom/websocket.mojom:71` |
| F-24 | WebTransport: content calls `WillCreateWebTransport(process_id, frame_routing_id, url, initiator_origin, handshake_client, callback)` before it connects. The callback takes an optional `WebTransportError`; an error refuses the connection. Chrome forwards to WebRequest. CEF does not override it | `content/browser/webtransport/web_transport_connector_impl.cc:297-301`; `chrome_content_browser_client.cc:7023-7055` |
| F-25 | Type signals on `network::ResourceRequest`: `is_fetch_like_api` marks fetch and XHR, and WebRequest maps it to XHR before it looks at the destination; `keepalive` with `kEmpty` is a ping; `mode` (`kNoCors` default, `kCors`, …) | `extensions/browser/api/web_request/web_request_info.cc:176-230`; `resource_request.h:236,250,267` |
| F-26 | Navigation responses: if a proxy clears `URLResponseHead::parsed_headers`, `NavigationURLLoaderImpl::ParseHeaders` re-parses the modified headers in the network service. A header edit that keeps the old `parsed_headers` never reaches the CSP parser | `content/browser/loader/navigation_url_loader_impl.cc:2048-2126` |
| F-27 | The `cef.mojom` frame pipes connect **after commit**: the renderer calls `ConnectBrowserFrame` from `OnDidCommitProvisionalLoad` and sends `FrameAttached`, with retries when the browser declines the binding during navigation; the browser queues `RenderFrame` actions until `FrameAttached`. A push at browser `ReadyToCommitNavigation` therefore arrives after the new document has started. Also, `ReadyToCommitNavigation` is a `WebContentsObserver` method, not a `NavigationThrottle` method, so the old §8.4 throttle could not be written as specified | `cef/libcef/renderer/frame_impl.cc:328-335`, `:521`, `:660-716`; `cef/libcef/browser/frame_host_impl.cc:644-651`, `:695-718`; `content/public/browser/web_contents_observer.h:359`; `navigation_throttle.h:155-216` |
| F-28 | Process-level interfaces: CEF already overrides `ExposeInterfacesToRenderer` and binds `cef.mojom.BrowserManager` there. Its renderer side binds through `RenderThread::BindHostReceiver` and makes `[Sync]` calls for each new browser. A registry binder runs on the IO thread unless a task runner is passed | `chrome_content_browser_client_cef.cc:711-720`; `cef/libcef/browser/browser_manager.cc:21-33`; `cef/libcef/renderer/render_manager.cc:176-180`, `:296-299`; `cef/libcef/common/mojom/cef.mojom:131-140`; `content_browser_client.h:1457-1464` |
| F-29 | Document-start CSS: extensions insert `run_at: document_start` CSS from `RenderFrameObserver::DidCreateDocumentElement` with `WebDocument::InsertStyleSheet(source, key, origin, bfcache_aware)`. A `kUser` sheet is stored in `StyleEngine::injected_user_style_sheets_`, apart from the document's own sheets. Blink stores one `RuleData` per selector of a selector list, so one rule per selector costs no extra matching. `CefRenderFrameObserver` does not override `DidCreateDocumentElement` and ignores `world_id` in `DidCreateScriptContext` | `extensions/renderer/script_injection_manager.cc:142-146`; `script_injection.cc:453-455`; `third_party/blink/public/web/web_document.h:151-161`; `third_party/blink/renderer/core/css/style_engine.cc:327-341`; `rule_set.cc:1471-1474`; `cef/libcef/renderer/render_frame_observer.h:23-34`, `.cc:129-165` |
| F-30 | Crate locking: each engine has one `std::sync::Mutex<RegexManager>`. `check_parameterised`, `get_csp_directives` and `check_generic_hide` take it; `url_cosmetic_resources` calls `check_generic_hide`; `hidden_class_id_selectors` does not lock. Regex discard: cleanup every 30 s, discard after 180 s unused; `Engine::set_regex_discard_policy` takes `&mut self` | `adblock-0.8.11/src/blocker.rs:138,160-167,196,442`; `engine.rs:207-231`; `regex_manager.rs:31-32,164-186` |
| F-31 | What a v0 DAT loses: `deserialize` replaces blocker and cosmetic cache but keeps `self.resources`; v0 restores `removeparam` empty, drops the `:remove()`, `:remove-attr()` and `:remove-class()` actions and their exceptions, resets scriptlet permissions to default, and resets the regex manager (so a custom discard policy is lost). Resources are never serialized | `adblock-0.8.11/src/engine.rs:110-128`; `src/data_format/v0.rs:106,113-123,429,441` |
| F-32 | Scriptlet arguments are escaped as JS strings; a resource with non-default permission is injectable only by a list with that permission; a `$redirect` resource is returned as `data:<mime>;base64,…` | `adblock-0.8.11/src/resources/resource_storage.rs:40-80`, `:153-216` |
| F-33 | Brave, as a fact reference only (public brave-core source read 2026-10-26; no code copied into this repo): `BraveContentBrowserClient::WillCreateURLLoaderFactory` installs `BraveProxyingURLLoaderFactory` **before** it calls Chrome's. The proxy takes requests on the UI thread; the ad-block check runs on the ad-block service's task runner and replies to the UI thread. Main-frame and extension-initiated requests are skipped; the source is the request initiator. A `$redirect` match becomes a synthesized stub response, not a redirect. A rewritten URL becomes a synthetic 307 and is accepted only for GET, HEAD and OPTIONS. Blocks complete with `ERR_BLOCKED_BY_CLIENT`. Server redirects are re-checked when the client follows them. Its renderer inserts cosmetic CSS with `InsertStyleSheet(kUser)` on some paths, runs its page scripts in an isolated world and scriptlets in the main world. Brave patches content to proxy frameless WebSockets (`CreateWebSocketWithFrameId`) | `github.com/brave/brave-core` master: `browser/brave_content_browser_client.cc`, `browser/net/brave_proxying_url_loader_factory.cc`, `browser/net/brave_ad_block_tp_network_delegate_helper.cc`, `components/cosmetic_filters/renderer/cosmetic_filters_js_handler.cc` |
| F-34 | Arc (RE, AGENTS.md rule 7): ArcCore names a renderer agent that **generates a cosmetic style sheet** (`AdBlockerAgent::GenerateCosmeticFilterStylesheet`, `NotifyCosmeticFilterRulesetChanged`, `../../arc/renderer/ad_blocker_agent.cc`) and a renderer-side `AdBlockerAgent::ShouldBlockRequest`. Neither ArcCore nor the Arc main binary contains `has-text`, `-abp-`, `+js(`, `scriptlet` or `:style(`. ArcCore has two bare `removeparam` strings with no proven owner. Guess: Arc 1.170 hides elements with plain CSS only and runs no procedural filters and no scriptlets | `strings -a /Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Versions/A/ArcCore \| grep -E 'ad_block\|AdBlock\|adblock\|has-text\|-abp-\|\+js\(\|scriptlet\|removeparam\|:style\(\|cosmetic\|Cosmetic'` → `.re/adblock-plan-r2/arccore-adblock-strings.txt` (34 lines); the same grep on `Contents/MacOS/Arc` prints nothing |
| F-35 | Measured cost (engine review round 1, standalone probe on the vendored crate, system rustc 1.99.1, M5 Pro under load; ratios are the evidence, not the absolute numbers): six real ad-tech URLs (58–2,040 chars) average **28.8 µs** per check with the shipped regex features (`std`, `unicode`) and **4.9 µs** with `perf-dfa`, `perf-onepass`, `perf-backtrack`, `perf-cache`, `perf-inline` (no `perf-literal`, no aho-corasick). Cost grows with URL length: 1 KB 85–165 µs vs 6–87 µs, 100 KB 8.1–12.5 ms vs 0.1–4.6 ms, 2 MB 168–248 ms vs 2.0–123 ms. Aggregate throughput falls as threads are added (1 thread 329k checks/s, 8 threads 168k/s). A regex rule compiles on first use under the mutex (worst real rule 6.78 ms). A DAT-loaded engine is ~32 MiB RSS; a text build adds ~80 MiB transiently; freeing an engine takes 14.5–18 ms | `.re/reviews/adblock-97-98-100-r1.md` (git-ignored), sections C-2, 97-1, 100-2, 100-5 and the appendix |
| F-36 | Branch 8078 has one content client pair: `ChromeContentBrowserClientCef` and `ChromeContentRendererClientCef`, both made by `ChromeMainDelegateCef`. `cef/libcef/browser/alloy/` holds only browser-host and platform-delegate code. Alloy-style browsers therefore pass the same browser and renderer hooks. The renderer client creates one `CefRenderFrameObserver` per frame in `RenderFrameCreated` | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.h:19`; `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.h:22`, `.cc:41-50`; `cef/libcef/common/chrome/chrome_main_delegate_cef.cc:568-569`; `ls cef/libcef/browser/alloy/` |

### 1.1 Lessons that are rules in this plan

| Rule | Why |
|---|---|
| Revised 2026-10-26: every engine call runs on **one matcher sequence** in the browser process, never on the UI or IO thread. The URLLoaderFactory proxy is bound on that sequence, so a request is matched in the task that receives it: no extra PostTask round trip, no CEF callback object per request (§7.6) | 100–300 subresources per page, a crate mutex per engine that serializes checks anyway (F-30), and a tail of milliseconds per check for long URLs and first regex use (F-35) |
| Revised 2026-10-26: cosmetic data is **pulled by the renderer** once per document at `DidCreateDocumentElement`, with one sync call to the matcher sequence, and inserted as user-origin style sheets before the parser runs page scripts (§8). Generic selectors are the only ongoing traffic, debounced in the page | A browser push cannot reach the renderer before the document starts (F-27). A `MutationObserver` in Blink or per-element style queries would be new Blink code with rebase risk on every `Document` refactor (adblock-design Option A, patch point 4) |
| A failed list rebuild **keeps the old engine**. A failed DAT load falls back to a text build. Neither failure disables blocking silently: status (§6.4) records `last_error` and OpenEngine surfaces it | Arc keeps the cache on `304`/failure (AD-4); a browser that silently stops blocking is worse than one that blocks with old lists |
| Exclusions and the master toggle take effect on the **next navigation**, with no engine rebuild and no restart | The proxy checks them per request and the cosmetic path per document (§7.2, §8.2). The Site Control Center reload follow-up (SC-6) is then sufficient |
| Never block the outermost main frame, whatever the lists say | A `$document` or broad rule must not be able to brick navigation. Exceptions inside the crate (`@@`, `$important`) still apply to subresources (§7.4) |

---

## 2. Key decisions

| # | Decision | Rejected alternative | Reason |
|---|---|---|---|
| D-1 | Rust enters **only** via `gnrt` vendoring (fork-infra D-6). The C++ side links the generated `//third_party/rust/adblock/v0:lib` target through our own shim crate (§5) | Brave-style "run cargo, link a prebuilt `libadblock.a`" (adblock-design's first sketch) | The Chromium way survives rebases, uses the pinned toolchain (F-12 in fork-infra), and generates the `README.chromium` license records. fork-infra §7 already superseded the build mechanics; this plan follows it |
| D-2 | The FFI is **one CXX bridge** in `//open/adblock/rust`. All Rust types cross as strings, string vectors, one enum and flat structs (§5.2, final surface). Superseded 2026-10-26 by D-14: "the browser renders CSS text in Rust; C++ never sees a selector container" no longer holds; selectors cross as sanitized vectors | Hand-written `extern "C"` with manual memory management; returning `UrlSpecificResources` field-by-field to C++ | CXX is the tree's supported bridge (F-7). Flat strings, vectors and structs keep crate-type churn inside the shim on crate bumps; C++ builds one rule per sanitized selector (D-14) |
| D-3 | Shim features: `default-features = false`, features `embedded-domain-resolver`, `full-regex-handling`, `resource-assembler`. **Off:** `object-pooling`, `unsync-regex-caching` (keeps `Engine: Send + Sync`, F-9), `css-validation`, `content-blocking` | Default features | A non-`Sync` engine forces a mutex around every 2 µs check and serializes all tabs in a Profile. Pooling/caching are micro-optimizations; thread-safety is the design's core assumption. `resource-assembler` is on so the shim can parse uBlock Origin's resources format (§9.3). Correction 2026-10-26 (review 98-7): the crate takes its own per-engine mutex on every check (F-30), so checks of one engine are serialized whatever these features are. Open accepts that and runs all engine calls on one sequence (D-12). Regex features: see D-12 and review 97-1 |
| D-4 | Service ownership: one `open::OpenAdBlockService` per `CefBrowserContext`, owned by a new `std::unique_ptr` member on `CefBrowserContext` itself (small `cef/` patch, §6.1) | `BrowserContextKeyedServiceFactory` registration in Chrome's profile-service list; a global `BrowserContext* → service` map | CEF registers no keyed services (F-13); a global map needs its own shutdown observer and leaks on context churn. A member dies exactly with the context, in both Alloy and Chrome runtimes, and every caller already knows how to reach the context (F-13) |
| D-5 | **Superseded 2026-10-26 by D-11.** Was: throttle creation in a new `ChromeContentBrowserClientCef::CreateURLLoaderThrottles` override | — | That hook sees only browser-initiated requests (F-16) |
| D-6 | **Superseded 2026-10-26 by D-13.** Was: cosmetic push over one new method on each `cef.mojom` frame interface, applied at `DidCreateScriptContext` | — | The `cef.mojom` frame pipes connect after commit (F-27), so the push is late on every navigation that reconnects the frame |
| D-7 | Per-tab blocked counts live in `open_engine::OpenAdBlockTabHelper`, a `content::WebContentsUserData` + `WebContentsObserver`, created lazily on the UI thread when the first count for a WebContents arrives (§7.5) | A counter map inside the service keyed by `WebContents*` | UserData dies with the WebContents; a service-side map needs explicit erase on every close path (Split View, Peek, Little Open create and destroy contents at a high rate) |
| D-8 | List **download** is Swift (`URLSession`, ETag, atomic writes); list **parse/build/serialize** is C++ in the browser process. The CEF call passes a **directory**, not list text (§9.2, §11 Step 6) | Downloading in C++ with `network::SimpleURLLoader`; passing 3.6 MB of text across the CEF API per update | Swift owns the Profile's files and schedule everywhere else in Open (architecture.md persistence table). A directory path keeps the CEF surface small, lets the browser read off the UI thread, and makes the DAT sit next to its source lists |
| D-9 | Bundled lists are **fetched at build time** by `tools/fetch-adblock-lists.sh` from the official URLs, verified against SHA-256 pins committed in this repo, and staged under `Vendor/adblock/` (git-ignored). List text is never committed, and never taken from `/Applications/Arc.app` | Committing `easylist.txt` / `easyprivacy.txt` to the repo; copying Arc's bundled copies | AGENTS.md rules 1/3/5 plus adblock-design §"List catalog": facts (URLs, IDs) are fine, Arc's files are not a source. Pins give reproducibility; `--update-pins` is a reviewed, deliberate action (§9.1) |
| D-10 | CEF API additions go on **existing** classes — `CefRequestContext` (per-Profile control) and `CefBrowserHost` (per-tab count) — guarded `CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`. No new `CefAdBlock*` classes in v1 | A new `CefAdBlockManager` singleton class + a new handler interface for count callbacks | Two classes' worth of translator output, two impl classes, and a callback registration lifetime to design, to deliver what six methods on classes the client already holds deliver. Count **change callbacks** are deferred: OpenEngine polls on panel open and on load end (§12.2), which is what the Site Control Center needs (SC-6 shows the count for the current load) |

Decisions added 2026-10-26 (detail in the named sections; the appendix
entry of the same date lists them with their review findings):

| # | Decision | Rejected alternative | Reason |
|---|---|---|---|
| D-11 | The network hook is Open's own URLLoaderFactory proxy, `open_engine::OpenAdBlockURLLoaderFactory`. `ChromeContentBrowserClientCef::WillCreateURLLoaderFactory` appends it **before** it calls Chrome's implementation, so it is the outermost interceptor (F-18, F-19). WebSocket and WebTransport use their own content hooks (F-23, F-24). §7 | (a) A hook inside CEF's `net_service/proxy_url_loader_factory.cc` / `InterceptedRequestHandler`. (b) `CreateURLLoaderThrottles` (old D-5) | (a) CEF's proxy runs on the IO thread (F-20), so matching would either block IO or add a second hop; its files (1,652 + 1,504 lines) are CEF-owned CORS and handler emulation, the riskiest place for an Open hunk on a CEF bump; and it sits after WebRequest, so extensions would see ad requests first. Own proxy: one call in a function Open already patches, all logic in the overlay, the same position Brave chose (F-33). (b) misses subresources (F-16) |
| D-12 | One process-wide **matcher sequence**, `base::ThreadPool::CreateSequencedTaskRunner({base::TaskPriority::USER_BLOCKING, base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN})`. The proxies, the cosmetics host and the per-Profile matcher state are bound on it. Every crate call except build, deserialize and serialize runs on it. Builds stay on the `MayBlock` build runner. §7.6 | (a) Check on the UI thread (old plan; WebRequest's thread). (b) Proxy on the UI or IO thread plus PostTaskAndReply to an ad-block runner (Brave's model, F-33). (c) Several matcher sequences | (a) 100–300 checks per page with millisecond tails (F-35) on the thread that must hit 120 Hz. (b) two extra hops per request and a UI-thread dependency for every request. (c) the per-engine mutex serializes anyway, and throughput falls with threads (F-35) |
| D-13 | Cosmetic delivery is a **renderer pull**: at `DidCreateDocumentElement` the renderer agent makes one `[Sync]` call on a process-level interface, `open_engine.mojom.AdBlockCosmetics`, that `ExposeInterfacesToRenderer` binds on the matcher sequence (F-28). §8.2 | (a) Old D-6 push over `cef.mojom`. (b) A frame-scoped binder from `RegisterBrowserInterfaceBindersForFrame` | (a) arrives late (F-27). (b) the frame's interface broker is reset at commit, so a document-start call races that reset (`frame_impl.cc:668-679`), and frame binders run on the UI thread. A process-level pipe is connected long before any navigation and never touches the UI thread. Cost: one sync IPC per http(s) document; Step 5 gates it (§11) |
| D-14 | The cosmetic payload is **sanitized hide-selector vectors**, not CSS text. The shim drops procedural and unsafe selectors, and in v1 also drops `:style()`, `:remove*()` and scriptlets (lead ruling 6). The renderer builds one rule per selector and inserts it with `WebDocument::InsertStyleSheet(…, blink::WebCssOrigin::kUser)` (F-29). §8.3 | As built in #98: one combined `hide_css` rule and `<style>` elements made by a main-world script | One non-CSS selector removed all hiding on the page (98-1). Lists could inject CSS with `url()` beacons into every page (98-2). `<style>` elements are visible to and removable by page scripts, and building them in JS needed hand escaping. A user-origin `!important` declaration also wins over the page's `!important` |
| D-15 | A DAT is reused only when its build was **lossless** and its receipt carries the running `engineFormat`. Resources are never in the DAT and are applied after every deserialize. `resources.json` is a bundled, pinned build artifact and a manifest input of every generation; v1 never downloads resources at run time. §9.2, §9.3 | Reuse any DAT whose input receipt matches (as built in #100); resources updated with the lists (old §9.3) | A v0 DAT drops `$removeparam` and the `:remove*()` actions (F-31) and carries no resources (98-4, 100-1(b)). After a crate or shim change an old DAT can still decode with old semantics (100-1(a)). Resources are untrusted third-party content, and list hosts can already change CSS on every page (review "Check 5"). In v1 resources serve only `$redirect` stubs (lead ruling 7); post-v1 scriptlets would run them as main-world code |
| D-16 | Profiles whose verified inputs are identical **share one engine** through a process-wide registry keyed by content hashes. Every engine is freed on the build runner. Builds run one at a time per process, with a 128 MiB total input cap. §6.6 | One engine per `CefBrowserContext` (as built in #100) | N Profiles on the default lists cost N × ~32 MiB (100-5). Toggle, exclusions, counts and storage stay per Profile; only immutable rule data is shared |
| D-17 | **Match input cap** (lead ruling 2, 2026-10-26). The shim matches at most the first **16 KiB** of the URL spec, with the fragment removed, cut after the last ABP separator character inside the cap. `$removeparam` never applies to a capped URL. Step 4 measures gates G-1…G-3 at 8 KiB and at 16 KiB; 16 KiB stays unless a gate fails there, and then the cap falls back to 8 KiB with the numbers recorded. §7.7 | No cap; 8 KiB (this plan's first proposal); 32 KiB (review C-2's upper end) | The page controls URL length (up to 2 MiB) and cost grows linearly with it (F-35), while each check holds the engine mutex for the whole process. 16 KiB misses fewer rules than 8 KiB. F-35 puts one 16 KiB check between about 0.02 ms and 1.4 ms with the D-12 regex features (a guess until G-3 measures it), so the 8 KiB fallback is measured too |

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
        open_adblock_types.h       # shared enums/structs (§6.2)
        # Revised 2026-10-26 (§6.6, §7, §8). Replaces the old
        # open_adblock_url_loader_throttle.* and open_adblock_navigation_throttle.*:
        open_adblock_matcher.h/.cc          # per-Profile matcher state, matcher sequence (§7.6)
        open_adblock_engine_registry.h/.cc  # shared engines, build-runner deleter (§6.6)
        open_adblock_url_loader_factory.h/.cc  # the proxy + per-request loader (§7.3–§7.5)
        open_adblock_socket_hooks.h/.cc     # WebSocket + WebTransport checks (§7.2)
        open_adblock_hooks.h/.cc            # the free functions the CEF patches call (§7.1, §8.2)
        open_adblock_cosmetics_host.h/.cc   # browser side of the mojom, matcher sequence (§8.2)
        open_adblock_tab_helper.h/.cc
        mojom/
          BUILD.gn                 # mojom("mojom") target
          open_adblock.mojom       # open_engine.mojom.AdBlockCosmetics (§8.2)
        renderer/
          open_adblock_renderer_agent.h/.cc  # document-start pull, style insertion (§8.3)
          open_adblock_page_script.h/.cc     # fixed isolated-world class/ID observer, C++ raw string (§8.3)
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
    bench/corpus-manifest.json     # Step 4: corpus count, percentiles, SHA-256s; never corpus URLs (§7.8)
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
| P-3 `03xx-open-adblock-network-hooks.patch` (revised 2026-10-26) | `cef` | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.h`, `.cc` only (plus `cef/libcef/browser/chrome/chrome_browser_main_extra_parts_cef.h`, `.cc` only if Step 5 builds the §7.6 priority lane) | One call at the top of the CEF branch of `WillCreateURLLoaderFactory`; one line in `ExposeInterfacesToRenderer`; three new one-line overrides `WillInterceptWebSocket`, `CreateWebSocket`, `WillCreateWebTransport` that forward to `open_engine::` free functions; one include (§7.1, §8.2). With the lane only: a `PostDestroyThreads()` override that stops the lane thread (§7.6 lane rule 3). Budget: about +45/−0 lines (about +10 more with the lane). `//open/adblock` already reaches `libcef_static` through `open_libcef_deps` (Step 3 as built), so no `cef/BUILD.gn` hunk. **Shared owner patch:** Boost Step 4R also hooks this file (`RenderProcessWillLaunch`; `docs/plans/boost-color-remap.md` §10.1). One path has one owner patch (`docs/engine-fork.md:119`), so whichever feature lands second adds its hunks to the existing owner patch. Prefer the feature-neutral name `0401-open-browser-client-hooks.patch` for both |
| P-4 `03xx-open-adblock-renderer-hook.patch` (revised 2026-10-26) | `cef` | `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc` only | In `RenderFrameCreated` (`:41-50`), one line after the `CefRenderFrameObserver` is made: `new open_engine::OpenAdBlockRendererAgent(render_frame);  // Deletes itself.`, plus one include (§8.3). The agent is its own `content::RenderFrameObserver`. Budget: about +3/−0 lines. **No** `cef.mojom`, `frame_host_impl`, `frame_impl` or `render_frame_observer` change. **Shared owner patch:** Boost Step 4R also hooks this file (`RenderThreadStarted`, `RenderFrameCreated`; `docs/plans/boost-color-remap.md` §10.1). Whichever feature lands second adds its hunks to the existing owner patch. Prefer the feature-neutral name `0402-open-renderer-client-hooks.patch` for both |
| P-5 (overlay, revised 2026-11-07) | `src` | `cef/include/cef_open_adblock.h`, `open/adblock/open_adblock_api.cc`, `open/open_libcef_sources.gni` | Six free functions (§11 Step 6); engine-apply regenerates translator outputs and build entries from the overlay header. No upstream patch or virtual-method change is needed |
| P-6 `0005-open-adblock-cefsimple-smoke.patch` | `cef` | `cef/tests/cefsimple/simple_app.cc`, `cef/tests/cefsimple/simple_handler.cc/.h` | **Test-only.** Switch-gated harness (§13.1). Keep last in the series so it can be dropped without touching P-2…P-5 |

No `patches/chromium/` entries. If implementation proves a Chromium-side
hunk is required (for example a `BUILD.gn` dep that cannot live in
`cef/BUILD.gn`), stop and add it as `patches/chromium/0001-…` with the
fork-infra §8 round-trip proof, and note why in the PR.

Numbering note (2026-10-26): as built, Open's CEF series uses `03xx`
names (`0310-open-adblock-service-owner.patch` for P-2,
`0314-open-adblock-cefsimple-smoke.patch` for P-6). P-3, P-4 and P-5 take
the next free numbers before `0314` (expected `0311`–`0313`); the series
file wins. The block below is the original sketch.

Series order after this plan (append to the fork-infra files; numeric
prefixes are sort hints, the series file wins):

```text
# patches/rust/series
0001-adblock-vendor.patch  # gnrt vendor+gen output for adblock 0.8.11 closure (generated; adblock-fork §4)

# patches/cef/series (ad-block entries, after any existing entries)
0001-open-adblock-service-owner.patch   # CefBrowserContext owns open::OpenAdBlockService (adblock-fork §6)
0002-open-adblock-network-hooks.patch   # URLLoaderFactory proxy, WebSocket/WebTransport, cosmetics binder (§7, §8.2; revised 2026-10-26)
0003-open-adblock-renderer-hook.patch   # renderer client creates the per-frame OpenAdBlockRendererAgent (§8.3; revised 2026-10-26)
# Control API is an overlay header + implementation; engine-apply runs the translator (§11 Step 6).
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
| `//open/adblock/mojom:mojom` | `mojom` (revised 2026-10-26) | overlay `open/adblock/mojom/BUILD.gn` (§8.2) |
| `//open/adblock:adblock_hats` — **do not create**. No test targets (AGENTS.md rule 6) | — | — |
| `//open:open` | `group` | overlay `open/BUILD.gn` |

Consumers: `cef/BUILD.gn` target `libcef_static` gains
`deps += [ "//open/adblock" ]` (P-3). As built at Step 3, this goes through
the generic `deps += open_libcef_deps` line and the overlay
`open/open_libcef_sources.gni`, so P-3 no longer touches `cef/BUILD.gn`.
Renderer code (`open/adblock/renderer/*`) is in the same target: CEF's
browser and renderer code link into one `libcef_static`. Nothing else links the service.
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

### 5.2 CXX bridge surface (final v1 surface; revised 2026-10-26)

This is the **only** full statement of the bridge (review r1 finding 8).
The 2026-10-25 surface (`hide_css`, `style_css`, `injected_script`,
`request_type: &str`, script-only `redirect_data_url`) is superseded and
not repeated here. §5.5 says which PR lands each part.

In `src/lib.rs`, one `#[cxx::bridge(namespace = "open_adblock")] mod ffi`.
Generated C++ lands in namespace `open_adblock`.

```rust
#[cxx::bridge(namespace = "open_adblock")]
mod ffi {
    // Mapped to the crate's type strings inside the shim (F-25, §7.3).
    enum OpenRequestType {
        Document, Subdocument, Script, Image, Stylesheet, Font, Media,
        Object, Xmlhttprequest, Ping, Websocket, CspReport, Other,
    }

    struct OpenBlockerResult {
        matched: bool,            // a blocking rule matched (after exceptions)
        important: bool,          // informational; the crate applied precedence
        has_redirect: bool,       // a $redirect rule matched
        redirect_data_url: String,// crate's "data:<mime>;base64,..." for ANY type, or "" (F-32)
        rewritten_url: String,    // $removeparam result, or ""; always "" when truncated
        csp_directives: String,   // Subdocument only, or ""
        truncated: bool,          // input exceeded max_input_bytes (§7.7)
    }

    struct OpenBuildReport {
        lossless: bool,           // false when a list line contains "removeparam" (§9.2.1)
        lossy_kinds: Vec<String>, // any of "removeparam", "remove", "remove-attr", "remove-class" (as built, 98-4)
        resources_loaded: u32,
        resources_error: String,  // "" or a short kind ("json", "too-large")
        list_count: u32,
        refused: String,          // "" or why the build was refused before parsing (R3-2)
    }

    struct OpenHiddenSelectors {  // review R3-4
        selectors: Vec<String>,      // sanitized like hide_selectors (§8.3), sorted
        dropped_procedural: u32,
        dropped_unsafe: u32,
        dropped_over_cap: u32,
    }

    struct OpenCosmeticResources {
        hide_selectors: Vec<String>, // sanitized (§8.3), sorted, total <= 256 KiB
        exceptions: Vec<String>,     // #@# generic exceptions, sorted
        generichide: bool,
        dropped_procedural: u32,     // §8.3 rule 3
        dropped_unsafe: u32,         // §8.3 rules 1, 2, 4
        dropped_style: u32,          // :style() (lead ruling 6)
        dropped_remove: u32,         // :remove*() (lead ruling 6)
        dropped_scriptlet: u32,      // ##+js(...) (lead ruling 6)
        dropped_over_cap: u32,       // past the 256 KiB payload cap
    }

    struct OpenEngineInfo {
        serialized_size: u64,
        list_count: u32,
    }

    extern "Rust" {
        type OpenAdblockEngine;

        fn open_adblock_engine_format() -> String;
        fn open_adblock_create_empty() -> Box<OpenAdblockEngine>;
        // Build runner only. resources_json: the crate's Vec<Resource> JSON, "" = none.
        fn open_adblock_build(list_texts: &[String], resources_json: &str)
            -> Box<OpenAdblockEngine>;
        fn open_adblock_build_report(engine: &OpenAdblockEngine) -> OpenBuildReport;
        fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8>;
        // false when the DAT walk refuses it (R2-1, R3-1, R3-5) or on any error;
        // then use_resources(resources_json).
        fn open_adblock_deserialize(engine: &mut OpenAdblockEngine, dat: &[u8],
                                    resources_json: &str) -> bool;
        // The DAT walk's verdict: "" or the first problem (logs, self-test).
        fn open_adblock_dat_check(dat: &[u8]) -> String;
        // Matcher sequence only (§7.6).
        fn open_adblock_check(engine: &OpenAdblockEngine, url: &str, source_url: &str,
                              request_type: OpenRequestType, max_input_bytes: u32)
            -> OpenBlockerResult;
        fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str)
            -> OpenCosmeticResources;
        // Output sanitized like hide_selectors (§8.3).
        fn open_adblock_hidden_selectors(engine: &OpenAdblockEngine, classes: &[String],
                                         ids: &[String], exceptions: &[String])
            -> OpenHiddenSelectors;
        fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo;
    }
}
```

Rules that bind this surface:

- `source_url` is the request initiator as an origin URL (§7.3); pass `url`
  itself when no initiator exists (first-party by construction).
- Input limits are enforced **in the shim** (reviews R2-1, R3-1, R3-2): a DAT
  passes a walk before the crate reads it (every length and count fits in the
  bytes left, at most 2^24 values and 32 levels, nothing after the root
  value), and `open_adblock_build` refuses more than 2^21 list lines or more
  than 64 MiB of cosmetic selector copies before it parses; C++ turns a
  refused build into a failed load. `docs/engine-patches.md` P8 has the
  measured worst allocations under PartitionAlloc's ceiling.
- The 256 KiB payload cap is enforced **in the shim**, in
  `open_adblock_cosmetic`: the unit is the sum of the UTF-8 bytes of the
  kept hide selectors, without the fixed declaration that the renderer
  adds. Selectors past the cap are dropped in sorted order and counted in
  `dropped_over_cap`, which `AdBlockStatus` reports (review r1 finding 14).
- Post-v1 fields (style rules, removals, scriptlets) are in §8.5. Adding
  them bumps the shim version inside `open_adblock_engine_format()`.

### 5.3 Shim implementation rules

Revised 2026-10-26: R-5, R-7 and R-8 are superseded by the final surface
in §5.2 and by §8.3 (sanitized vectors, no CSS or procedural script text
from Rust, redirect URLs for every type).

- **R-1 (threading).** `OpenAdblockEngine` must be `Send + Sync`. Add at
  the bottom of `lib.rs`: `fn _assert() { fn is_send_sync<T: Send + Sync>() {} is_send_sync::<OpenAdblockEngine>(); }`.
  If this fails to compile, a feature crept back on — fix the §4.2
  fragment, not this assertion (D-3, F-9).
- **R-2 (resources; revised in review r2, N-10, to the as-built form).**
  `open_adblock_build` takes `resources_json`, the crate's own serialized
  `Vec<Resource>` (§5.2, §9.3). When it is non-empty, the shim decodes it
  with `serde_json` and calls `engine.use_resources(vec)` before
  returning (#98 as built). A decode error or zero resources: log,
  report it in the build report (`resources_error`, `resources_loaded`),
  and continue with no resources, so `$redirect` rules produce
  `has_redirect = false`. Never panic. The browser never runs the
  crate's assembler; only the offline Step 7 driver does (§9.3).
- **R-3 (no panics across FFI).** Every `Request::new` failure (malformed
  URL from the network stack) returns a default allow result
  (`matched = false`, all strings empty). Every `url` that fails to parse
  in the cosmetic path returns an empty `OpenCosmeticResources` with
  `generichide = false`. Use `std::panic::catch_unwind` at each exported
  function boundary if any crate call proves panic-capable in review;
  otherwise rely on `Result` handling. A panic that unwinds into C++ is a
  crash of the browser process — treat any observed panic as a Step 2
  blocking bug.
- **R-4 (check).** `open_adblock_check` applies the §7.7 cap, maps
  `OpenRequestType` to the crate's string, builds
  `adblock::Request::new(url, source_url, type_str)`, calls
  `check_network_request`, and additionally calls
  `get_csp_directives(&request)` **only** for `Subdocument` (the crate
  documents CSP as document-only; main frames are never checked, §7.2).
- **R-5 — superseded 2026-10-26.** Was: a percent-encoded `data:` URL for
  scripts only. Now `redirect_data_url` is the crate's own data URL for
  every type, and C++ decides (§5.2, §7.4 rule 3).
- **R-6 (rewritten URL).** Copy `BlockerResult.rewritten_url` verbatim,
  except leave it empty when `truncated` is true. C++ applies it only
  under §7.4 rule 4.
- **R-7 — superseded 2026-10-26.** Was: CSS text rendered in Rust as one
  combined rule (review 98-1, 98-2). Now: sanitized selector vectors
  (§5.2, §8.3); the renderer builds one rule per selector.
- **R-8 — superseded 2026-10-26.** Was: scriptlets and a page-visible
  procedural payload in the main world. v1 runs no scriptlets (lead
  ruling 6); the post-v1 design is in §8.5.

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

### 5.5 Shim changes and their owner PRs (revised 2026-10-26)

Engine review round 1 found that the as-built shim (#98) cannot serve the
revised §7–§9. Each row below names the PR that lands it (review r1
finding 7, lead ruling). Default owner: the step that first needs the row;
that step's Work list includes `Engine/fork/src/open/adblock/rust/src/lib.rs`
(§11). If the engine lead's #98 fix PR lands a row first, the owner step
only verifies it. The entry gates in §11 are verification, not the
assignment. §5.2 is the resulting surface.

| Change | Owner PR | Finding | Rule |
|---|---|---|---|
| `OpenRequestType` enum replaces `request_type: &str`; the shim maps it to the crate's strings (F-25) | Step 4 | 98-6 | No free-form string crosses the bridge, so no unknown string can change matching and no invalid UTF-8 can reach `rust::Str` |
| `max_input_bytes` argument and the §7.7 cap inside `open_adblock_check`; `truncated` in `OpenBlockerResult`; `rewritten_url` empty when truncated. C++ passes `kOpenAdBlockMatchCapBytes` (16,384), except the non-official bench, which passes `--open-adblock-bench-cap` | Step 4 | C-2 | One place enforces the cap; the bench measures both caps on one build (lead ruling 2) |
| `redirect_data_url` for **every** type: the crate's `data:<mime>;base64,…` verbatim (F-32) | Step 4 | — | C++ decides whether to serve it (§7.4 rule 3) |
| `open_adblock_deserialize` returns false when `dat.len() <= 4` | Step 4 | 98-3 | A 4-byte DAT panics the crate today |
| `open_adblock_deserialize` takes `resources_json` and calls `use_resources` after a successful deserialize | Step 7 | 98-4 | F-31: the DAT carries no resources; N-19 proves it |
| `open_adblock_build_report`: `lossless`, `lossy_kinds`, `resources_loaded`, `resources_error`, `list_count` | Step 4 | 98-4, 98-5, 100-1(b) | `lossless` comes from a conservative scan of the list texts: a non-comment line that contains `removeparam` makes the set lossy. False positives only cost a text build. As built (98-4), the scan also reports `remove`, `remove-attr`, and `remove-class` (`:remove*()` lines), and any reported kind makes the set lossy, so such lists take a text build. v1 still ignores what the `:remove*()` actions do (lead ruling 6); counting them only costs a text build (F-31) |
| `open_adblock_engine_format()`: `adblock=0.8.11;shim=<N>;features=<sorted crate features>;regex=<sorted regex features>;dat=v0`. `N` is a constant in `lib.rs`, bumped on any change to `ParseOptions`, permissions, features or bridge semantics | Step 4 | 100-1(a) | The receipt binds it (§9.2.1) |
| Sanitized cosmetic vectors (`OpenCosmeticResources` of §5.2), the 256 KiB payload cap with `dropped_over_cap`, and sanitized `open_adblock_hidden_selectors` output. The crate's style, remove and scriptlet output is discarded and counted (lead ruling 6). No CSS text is built in Rust | Step 5 | 98-1, 98-2, r1-14 | Sanitizer rules: §8.3. Post-v1 fields: §8.5 |

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

// How one LoadFromDirectory() ended. Its `done` callback always gets
// exactly one value (#100 review R2-5, as built).
enum class AdBlockLoadResult {
  kLoaded,     // the new engine is installed
  kFailed,     // the load failed; the old engine stays (status last_error)
  kStale,      // a newer load started first; this result was dropped
  kCancelled,  // Shutdown() ran or the service was destroyed before the
               // result arrived, or the load was asked for after Shutdown()
};

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

### 6.3 `OpenAdBlockService` and `OpenAdBlockMatcher` (final v1 shape; revised 2026-10-26)

Tombstone: the 2026-10-25 class sketch (namespace `open`, an "any
thread" `Check(..., const std::string& request_type)`, a `shared_mutex`
around the engine, a per-service `build_runner_`) is superseded and not
repeated (review r1 finding 8). The as-built #100 header is the starting
point; Step 4 turns it into the shape below (§6.7 lists the reasons).

```cpp
namespace open_engine {

// UI thread. One per CefBrowserContext (= one Open Profile).
class OpenAdBlockService {
 public:
  // Makes matcher_ at once (disabled, no engine), so the §8.2 binder
  // always has one.
  explicit OpenAdBlockService(base::FilePath profile_dir);
  ~OpenAdBlockService();

  // Drops the engine reference and stops loads. Afterwards the matcher
  // answers "off" and CefBrowserContext::open_adblock_service() returns
  // nullptr (§6.7).
  void Shutdown();

  void SetEnabled(bool enabled);       // posts to the matcher; keeps a UI mirror
  bool IsEnabled() const;              // UI mirror, for AdBlockWantsWebSocket and status
  // Normalized here (§6.3.3, §6.7), then posted to the matcher.
  void SetExcludedDomains(std::vector<std::string> registrable_domains);
  bool IsExcludedOnUi(std::string_view top_site) const;  // UI mirror, factory-time skip (§7.2)

  // §9.2 load on the process-wide build runner (§6.6); the result is
  // posted to the matcher as SetEngine(). `done` (optional) runs exactly
  // once, on the UI thread, with the load's AdBlockLoadResult (§6.2):
  // kLoaded or kFailed for a load that finished, kStale for a load that
  // a newer one replaced, kCancelled after Shutdown() or the service's
  // destruction. A load asked for after Shutdown() runs `done` with
  // kCancelled before LoadFromDirectory returns (as built), so callers
  // must not assume `done` is always asynchronous.
  void LoadFromDirectory(base::FilePath adblock_root, bool prefer_dat,
                         base::OnceCallback<void(AdBlockLoadResult)> done = {});
  // Loads the root of the last LoadFromDirectory() again, with no `done`
  // (as built); no root set: no-op. Callers learn the outcome from the
  // status callback.
  void ReloadLists();

  AdBlockStatus GetStatus() const;
  void SetStatusCallback(
      base::RepeatingCallback<void(const AdBlockStatus&)> callback);

  scoped_refptr<OpenAdBlockMatcher> matcher() const;
  base::WeakPtr<OpenAdBlockService> GetWeakPtr();
};

// Mutable state lives on the matcher sequence (SEQUENCE_CHECKER).
// Construction and the reference count are thread-safe.
class OpenAdBlockMatcher
    : public base::RefCountedThreadSafe<OpenAdBlockMatcher> {
 public:
  // The old engine reference is dropped here; the §6.6 deleter frees the
  // engine on the build runner.
  void SetEngine(std::shared_ptr<const EngineHolder> engine);
  void SetEnabled(bool enabled);
  void SetExclusions(base::flat_set<std::string> normalized_domains);

  // enabled && engine loaded && top site not excluded (label-boundary
  // rule, §6.7).
  bool IsActiveFor(std::string_view top_site) const;

  open_adblock::OpenBlockerResult Check(const GURL& url,
                                        const GURL& source_url,
                                        open_adblock::OpenRequestType type,
                                        uint32_t max_input_bytes) const;
  open_adblock::OpenCosmeticResources Cosmetic(const GURL& document_url) const;
  std::vector<std::string> HiddenSelectors(
      const std::vector<std::string>& classes,
      const std::vector<std::string>& ids,
      const std::vector<std::string>& exceptions) const;
};

}  // namespace open_engine
```

#### 6.3.1 Locking and atomic swap — superseded 2026-10-26

Was: a `shared_mutex` around a `shared_ptr` engine, read from any thread.
Now: the engine reference lives on the matcher sequence and changes only
there (`SetEngine`), so no lock guards it; an in-flight check keeps the
old engine alive through its own reference; stale loads are dropped by a
load id (as built in #100) and by the §6.6 stale-build check (§6.7, §7.6).

#### 6.3.2 Build/load algorithm (`BuildOnBackground`, exact order)

Revised 2026-10-26: this runs on the process-wide build runner (§6.6),
checks the registry and the stale-load id first (§6.6), and publishes by
posting `SetEngine` to the matcher (§6.3) instead of a locked swap.

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
4. Publish (revised 2026-10-26 with #100 review R2-5): the build runner
   replies to the UI thread (`PostTaskAndReplyWithResult`, as built). If
   the service is gone or shut down, the reply frees the engine off the
   UI thread and runs `done(kCancelled)`. If a newer load started, it
   frees the engine and runs `done(kStale)`. Otherwise it updates
   `status_` (`engine_loaded`, `list_count`, `last_build_ms`,
   `last_error`), posts `SetEngine` to the matcher (§6.3) when an engine
   was built, notifies OpenEngine through the status callback the CEF
   layer registers (§11 Step 6 — a
   `base::RepeatingCallback<void(const AdBlockStatus&)>` set by
   `CefRequestContextImpl`; no callback = no-op, which is the
   `cefsimple` case), and then runs `done(kLoaded)`, or `done(kFailed)`
   when no engine was built (the old engine stays).

Timing instrumentation: wrap steps 1–3 in `base::ElapsedTimer` and store
the total in `last_build_ms`. Also emit one `VLOG(1)` line per load:
`OpenAdBlock: loaded <n> lists, <dat|text>, <ms> ms` (no URLs, no file
contents — §6.4 privacy rule).

#### 6.3.3 Exclusion semantics

Revised 2026-10-26: §6.7 replaces the lookup rule below (the host and
each parent label down to the registrable domain, Swift's rule, review
100-4). The normalization rules still apply.

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

### 6.5 Service `BUILD.gn` (overlay `open/adblock/BUILD.gn`; final v1 list, revised 2026-10-26)

Tombstone: the 2026-10-25 list (URL-loader and navigation throttles, a
`//cef/*` include-path workaround for a cosmetic sender in a CEF patch) is
superseded (review r1 finding 8). v1 has no cosmetic sender in a CEF
patch, so `//open/adblock` needs no CEF frame types.

```gn
# Copyright 2026 The Open Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

source_set("adblock") {
  sources = [
    "open_adblock_cosmetics_host.cc",
    "open_adblock_cosmetics_host.h",
    "open_adblock_engine_registry.cc",
    "open_adblock_engine_registry.h",
    "open_adblock_hooks.cc",
    "open_adblock_hooks.h",
    "open_adblock_matcher.cc",
    "open_adblock_matcher.h",
    "open_adblock_service.cc",
    "open_adblock_service.h",
    "open_adblock_socket_hooks.cc",
    "open_adblock_socket_hooks.h",
    "open_adblock_tab_helper.cc",
    "open_adblock_tab_helper.h",
    "open_adblock_types.h",
    "open_adblock_url_loader_factory.cc",
    "open_adblock_url_loader_factory.h",
    "renderer/open_adblock_page_script.cc",
    "renderer/open_adblock_page_script.h",
    "renderer/open_adblock_renderer_agent.cc",
    "renderer/open_adblock_renderer_agent.h",
  ]
  # As built (Step 3): the shim is a public dep, because the service
  # header includes lib.rs.h.
  public_deps = [ "//open/adblock/rust:open_adblock_rust" ]
  deps = [
    "//base",
    "//content/public/browser",
    "//content/public/common",
    "//content/public/renderer",
    "//mojo/public/cpp/bindings",
    "//net",
    "//open/adblock/mojom",
    "//services/network/public/cpp",
    "//services/network/public/mojom",
    "//third_party/blink/public:blink",
    "//url",
  ]
  visibility = [ "//cef/*", "//open/*" ]
}
```

The self-test sources (as built in #100) are added only when
`!is_official_build` (review 100-3, §6.7). Hooks that need CEF types
(`CefBrowserContext::FromBrowserContext`) are compiled inside
`libcef_static` through `open_libcef_deps` (Step 3 as built), so the
include path is the one that target already has. Never add a
`//cef` → `//open` → `//cef` link cycle.

Acceptance for Step 3: §11 Step 3 list.

### 6.6 Memory: shared engines and caps (revised 2026-10-26, D-16)

Measured (F-35, standalone, system malloc): a DAT-loaded EasyList +
EasyPrivacy engine is about 32 MiB RSS, and a text build adds about
80 MiB while it runs. As built (#100) every `CefBrowserContext` has its own
engine, so N Profiles on the default lists cost about N × 32 MiB, and two
Profiles that build at the same time add about 160 MiB.

**Engine key.** SHA-256 over: the shim's `engine_format` string (§5.5),
then each enabled list as `<listID>\n<sha256>\n` in manifest order, then
`resources\n<sha256>\n` (or `resources\nnone\n`). The key uses content
hashes only. It does not contain the generation number, the manifest hash
or a path, because two Profiles with the same lists have different
generations and paths. The service computes the key on the build runner
after it has verified every input (§9.2).

**Registry.** `open_engine::OpenAdBlockEngineRegistry` is a process-wide
singleton owned by the build runner. It maps engine key →
`std::weak_ptr<const EngineHolder>`. A load does this, in order:

1. Verify inputs, compute the key.
2. `registry.Find(key)`: if a live engine exists, use it. No DAT read, no
   build. Status reports `engine_shared=1`.
3. Else load from a valid DAT (§9.2) or build from text, then
   `registry.Insert(key, engine)`.

**Deleter.** Every `EngineHolder` is created as
`std::shared_ptr<const EngineHolder>(raw, deleter)`, where the deleter
posts `delete raw` to the build runner (`build_runner->DeleteSoon(...)`).
The last reference can drop on any sequence (matcher sequence, UI at
Profile close); the 15–18 ms free (F-35) always runs on the build runner.
This replaces the three free sites in review 100-2 with one rule.
`Shutdown()` swaps the matcher's reference out and lets the deleter run;
it never destroys an engine under a lock.

**Caps (v1).**

| Cap | Value | Why |
|---|---|---|
| Total list input per build | 128 MiB (sum of verified file sizes); a larger set fails the load with `last_error = "inputs too large"` and keeps the old engine | 100-5: 46 lists × 64 MiB was unbounded |
| Concurrent builds | 1 per process: one shared build runner for all Profiles, so a burst of toggles in several Profiles queues | Peak transient memory is one build (~80 MiB measured for the defaults) |
| Stale builds | A build checks an atomic "latest load id" for its Profile before it parses and before it writes the cache, and drops itself when stale | 100-7; also bounds wasted memory |
| Text lifetime | List texts are freed right after `open_adblock_build` returns, before serialize and the cache write; the DAT is written from the Rust `Vec<u8>` through a `base::span`, with no `std::string` copy | 100-5 |
| Resources JSON | 4 MiB read cap (bundled file; Step 7: 142,493 bytes, 47 redirect resources) | Headroom above the pinned payload; source and output hashes are recorded in §9.3 |

**Budgets (browser-process `phys_footprint`, except the Step 8 AD3
allocator predicate below; the step that gates each row is named):**

| Measure | Budget | Basis | Gated at |
|---|---|---|---|
| One EasyList + EasyPrivacy engine, steady state, with the D-12 regex features | ≤ 57 MiB, text and DAT, median of 5 | Lead footprint ruling §13.5.1 item 4a (2026-11-07 20:40); record PA allocated breakdown | Step 4 (single context, `cefsimple`) |
| After the full-corpus check plus one idle purge | ≤ 60 MiB, text and DAT, median of 5 | Same ruling 4a; one idle-triggered, rate-limited purge, no request-path purge or idle timer loop; G-2/G-4 unchanged | Step 4 (single context, `cefsimple`) |
| Second Profile with the same verified inputs | `engine_shared=true`; median of 5 attachment-only PA allocated deltas ≤ +2 MiB; median non-PA malloc in-use delta ≤ +2 MiB | Both contexts and stores exist before baseline; store IO stays idle. Different-list control must show `engine_shared=false` and PA allocated delta ≥8 MiB, else AD3 is INVALID (insensitive). Record PA committed deltas and whole-process paired median/spread; whole-process deltas do not gate AD3. See Step 8 acceptance errata (2026-11-08) | Step 8 (two request contexts need the App; `cefsimple` has one context) |
| Text build transient | ≤ +100 MiB above steady state, back to steady state ≤ 5 s after the swap | 80 MiB measured | Step 9 |
| All 5 generic + privacy lists enabled | Record only (no gate in v1) | R-7; decides whether any non-default list becomes a default | Step 9 |
| Renderer, worst-case cosmetic payload: the initial sheet at the 256 KiB cap plus 64 generic sheets of 500 rules (about 163,000 user-origin rules at most: the cap bounds bytes, so the shortest selectors give the largest count — 256 KiB / 2 B ≈ 131k, plus 64 × 500 generic; review r2 N-7) | Record only in v1: renderer `phys_footprint` delta and style-recalc time with that payload | Review r1 finding 14: the rule count has no other bound | Step 5 |

Lead ruling 8 (2026-10-26) confirms engine sharing between Profiles,
with this note kept.

Privacy note: a shared engine shares only immutable rule data and the
crate's compiled-regex cache. Guess: the only cross-Profile signal is
timing (a regex compiled by Profile A is faster for Profile B), which
reveals at most that some page in another Profile used the same filter.
Off-the-record Profiles share with their parent when the lists match.

### 6.7 Service changes at Step 4 (revised 2026-10-26)

The as-built service (#100) guards one engine with a `shared_mutex` and
offers an "any thread" `Check()`. Step 4 changes that as follows (the
engine lead owns the code; this is the contract):

- Matcher state per Profile moves into `open_engine::OpenAdBlockMatcher`,
  a `base::RefCountedThreadSafe` object whose mutable state is touched
  only on the matcher sequence (`SEQUENCE_CHECKER`; a thread checker if
  the §7.6 priority lane is built). It holds the
  current engine (`std::shared_ptr<const EngineHolder>`), the enabled
  flag, the normalized exclusion set, and per-Profile counters. Proxies
  and the cosmetics host keep a `scoped_refptr` to it, which fixes 100-8
  (no raw or UI-bound pointer off the UI thread).
- The UI-thread service updates the matcher only by posting to the
  matcher sequence (`SetEngine`, `SetEnabled`, `SetExclusions`). The
  `shared_mutex`, `exclusions_mutex_` and the "any thread" methods go
  away. `Check()`, `CosmeticResources()` and `HiddenSelectors()` move to
  the matcher and become matcher-sequence-only.
- The per-service `build_runner_` is replaced by the one process-wide
  build runner that the registry owns (§6.6). The matcher sequence is
  also process-wide (D-12). Both are ThreadPool sequences: creating one
  starts no thread (the §7.6 priority lane, built only if a Step 5 gate
  fails, is the one exception: one dedicated thread). The service makes its matcher in its constructor
  (disabled, no engine), so the §8.2 binder always has one; with
  blocking off the matcher sequence runs only the null replies of §8.2.
- Exclusion matching follows Swift's rule (review 100-4): an entry
  covers its registrable domain and every subdomain on a label
  boundary. `IsExcluded(host)` checks the host, then each parent label
  down to the registrable domain. IPv6 entries are bracketed before any
  `GURL` step. A leading `*.` is stripped.
- `CefBrowserContext::open_adblock_service()` returns `nullptr` after
  `Shutdown()` (review 100-6); every Step 4 caller handles `nullptr`.
- The self-test switches stay out of official builds (review 100-3):
  `#if !defined(OFFICIAL_BUILD)` around the switch block, self-test
  sources only when `!is_official_build`, and the release check
  `strings <framework> | grep -c open-adblock-` prints 0.

---

## 7. Network blocking — the URLLoaderFactory proxy (revised 2026-10-26)

This section replaces the URLLoaderThrottle design of 2026-10-25.
`CreateURLLoaderThrottles` sees only browser-initiated requests (F-16), so
the old design would have missed every subresource (review C-1). Decisions:
D-11 (hook), D-12 (thread), D-17 (input cap).

### 7.1 Hooks (patch P-3)

All hunks are in `cef/libcef/browser/chrome/chrome_content_browser_client_cef.{h,cc}`.
Each hunk calls one free function from the overlay header
`open/adblock/open_adblock_hooks.h`. All logic lives in the overlay.

1. **Factories.** In `WillCreateURLLoaderFactory` (`.cc:482-572`), insert
   one call right after the early return for non-CEF profiles
   (`:499-510`) and **before** the call to
   `ChromeContentBrowserClient::WillCreateURLLoaderFactory` (`:536`):

   ```cpp
     // Open: ad blocking, outermost interceptor (docs/plans/adblock-fork.md §7).
     open_engine::MaybeProxyURLLoaderFactoryForAdBlock(
         browser_context, frame, render_process_id, type, request_initiator,
         isolation_info, factory_builder);
   ```

   It is the first `Append()` on the builder, so it is the outermost
   interceptor (F-18). The chain becomes: Open ad block → WebRequest
   (only while an extension with webRequest or declarativeNetRequest is
   enabled, F-21) → other Chrome proxies → CEF's proxy → DevTools →
   network service (F-19).
2. **Cosmetics binder.** In `ExposeInterfacesToRenderer` (`.cc:711-720`),
   one line after `CefBrowserManager::ExposeInterfacesToRenderer(...)`:
   `open_engine::ExposeAdBlockInterfacesToRenderer(registry, host);` (§8.2).
3. **Sockets.** Three new overrides; CEF has none today (F-23, F-24).
   Each `.cc` body is at most six lines and passes a continuation that
   runs the Chrome base implementation:
   - `WillInterceptWebSocket(frame)`: returns
     `open_engine::AdBlockWantsWebSocket(frame) || ChromeContentBrowserClient::WillInterceptWebSocket(frame)`.
     `AdBlockWantsWebSocket` is true when `frame` is non-null and its
     Profile's ad blocking is enabled and the top site is not excluded.
   - `CreateWebSocket(frame, factory, url, site_for_cookies, user_agent, handshake_client, options)`:
     calls `open_engine::AdBlockCreateWebSocket(...)` with a continuation.
     If the check allows and `ChromeContentBrowserClient::WillInterceptWebSocket(frame)`
     is true, the continuation calls Chrome's `CreateWebSocket` with the
     same arguments, including `options`. Otherwise it runs `factory`
     exactly as content's own path does
     (`websocket_connector_impl.cc:152-167`, review r1 finding 13):
     `std::move(factory).Run(url, additional_headers, std::move(handshake_client), mojo::NullRemote(), std::move(options.header_client))`,
     where `additional_headers` holds one `User-Agent` header when
     `user_agent` has a value and nothing else; the fourth argument is
     the `WebSocketAuthenticationHandler` remote, null as in content; the
     fifth is the `TrustedHeaderClient` (`WebSocketFactory`,
     `content_browser_client.h:2014-2019`). `options` is not Open's to
     build: content computes it before the call from
     `GetWebSocketOptions(frame)` (`websocket_connector_impl.cc:136-137`),
     which CEF does not override, so Chrome's version supplies
     `options.header_client` (enterprise header injection,
     `chrome_content_browser_client.cc:6982-6997`), and
     `options.options` is already bound into `factory`
     (`websocket_connector_impl.cc:139-144`). Open does not override
     `GetWebSocketOptions`. **Accepted difference, tested by nothing:**
     content's path also adds DevTools override headers
     (`websocket_connector_impl.cc:156-157`); an intercepted socket loses
     them, as it does with WebRequest's socket proxy today
     (`web_request_proxying_websocket.cc:347-348` sets only the user
     agent). If the check blocks, the overlay calls
     `handshake_client->OnFailure("Blocked by Open's ad blocker", net::ERR_BLOCKED_BY_CLIENT, 0)`
     (F-23) and drops `factory`.
   - `WillCreateWebTransport(process_id, frame_routing_id, url, initiator_origin, handshake_client, callback)`:
     calls `open_engine::AdBlockWillCreateWebTransport(...)`. Allow:
     continue with Chrome's implementation. Block: run `callback` with
     the handshake client and
     `network::mojom::WebTransportError::New(net::ERR_BLOCKED_BY_CLIENT, 0, "Blocked by Open's ad blocker", false)`
     (`services/network/public/mojom/web_transport.mojom:24-39`).
   Socket checks run on the matcher sequence through
   `PostTaskAndReplyWithResult` (UI → matcher → UI). Sockets are rare
   per page, so one round trip each is acceptable. **Frame lifetime
   (review r2 N-9):** never carry the raw `RenderFrameHost*` across the
   hop. Capture its `content::GlobalRenderFrameHostId` (and every other
   argument by value or move); on the UI reply, re-look the frame up
   with `RenderFrameHost::FromID` (`content/public/browser/render_frame_host.h:169`; the id comes from `GetGlobalId()`, `:285`).
   If it is gone, drop the factory and the handshake client without
   running either continuation — the frame that asked is dead, so no
   socket may start for it. `WillCreateWebTransport` already receives a
   process and routing id, so it needs no pointer rule beyond this one.
4. **Include.** `#include "open/adblock/open_adblock_hooks.h"` in the `.cc`.

**`factory_override` and the builder chain (review r1 finding 5).** Open's
`Append()` interceptor sits in the builder chain, which content connects
in front of the network service's outer `CorsURLLoaderFactory`
(`url_loader_factory_utils.cc:245-279`, `Finish(...)` at `:314-317`). A
`factory_override` is a different layer: it replaces only the network
service's *internal* factory behind CORS
(`services/network/public/mojom/network_context.mojom:756-780`) and
reaches the network service through `factory_params->factory_override`
(`url_loader_factory_utils.cc:302`). Who passes one:

- Renderer subresource factories allow it (`FactoryOverrideOption::kAllow`,
  `render_frame_host_impl.cc:14268-14273`). CEF then gives the network
  service a pass-through override (`chrome_content_browser_client_cef.cc:515-530`,
  `:552-557`). Open's interceptor is not affected; it still sees every
  request first.
- Navigation factories pass `factory_override = nullptr` ("CORS is no-op
  for navigations", `navigation_url_loader_impl.cc:2309-2322`; the same
  for service-worker navigation preload, `service_worker_client.cc:1424-1434`).
  CEF then takes its other branch: one more pass-through `Append()` after
  Chrome's interceptors, plus its own proxy (`chrome_content_browser_client_cef.cc:545-551`,
  `:568-571`). Open's `Append()` came first, so it stays outermost for
  subframe navigations too, and `OnReceiveResponse` from Open's loader
  reaches `NavigationURLLoaderImpl`, which re-parses headers when
  `parsed_headers` is null (F-26).

So the subframe block and the list CSP (N-10) need no other hook. Step 4
proves this first, as an early spike (§11 Step 4). If the spike fails,
the named alternative for subframe navigations only is a
`blink::URLLoaderThrottle` from a `CreateURLLoaderThrottles` override
(F-1, F-2, F-16: that hook does see navigations): cancel
`Subdocument` matches in `WillStartRequest`, and in `WillProcessResponse`
append the CSP header and clear `parsed_headers`. Guess: a throttle sees
the response head before `NavigationURLLoaderImpl::ParseHeaders`; the
spike must prove it before the fallback is built.

Patch budget: about +45/−0 lines in the two files. No `cef/BUILD.gn` hunk
(Step 3 as built already links `//open/adblock` through
`open_libcef_deps`). No `CreateURLLoaderThrottles` override and no change
to `CreateThrottlesForNavigation`.

Alloy note (corrects the old §7.1): branch 8078 has one content client
pair, `ChromeContentBrowserClientCef` and `ChromeContentRendererClientCef`
(F-36). Alloy-*style* pages, such as Peek pages (engine-patches P1), run on
the same clients, so these hooks cover them too. Step 4 proves it with
N-16.

### 7.2 What is proxied

`MaybeProxyURLLoaderFactoryForAdBlock` runs on the UI thread once per
factory, not per request. It does nothing (zero cost for that factory)
when any of these holds:

1. `CefBrowserContext::FromBrowserContext(browser_context)` is null, or
   `open_adblock_service()` returns null (after `Shutdown()`, §6.7).
2. Ad blocking is disabled for the Profile, or the top site (below) is
   excluded. Such factories stay unproxied for the life of their
   document. Turning blocking on, or removing an exclusion, takes effect
   on the next navigation (§1.1); turning it off or adding an exclusion
   also takes effect at once for proxied factories (§7.4 rule 1).
3. The factory type is not in the table below, or its row says "no".
4. `request_initiator` is not opaque and its scheme is not `http` or
   `https` (WebUI, `chrome-extension://`, `devtools://`, `file:`). Extension
   pages, extension service workers and the #93 popups are the
   extension's own traffic; Brave also skips extension-initiated requests
   (F-33). An opaque initiator (sandboxed frame) is proxied.

| Factory type (F-17) | Proxied | Notes |
|---|---|---|
| `kDocumentSubResource` | yes | Images, scripts, CSS, fonts, media, fetch, XHR, beacons. Also the fetch-keepalive factory (F-22). Non-network-scheme factories are skipped by rule 4 or carry no http(s) requests |
| `kWorkerSubResource` | yes | Dedicated workers (`frame` = ancestor frame) and shared workers (`frame` null) |
| `kServiceWorkerSubResource` | yes | `frame` null: blocked requests are not counted per tab |
| `kWorkerMainResource`, `kServiceWorkerScript` | yes | A worker script on a block list is blocked as `Script` |
| `kNavigation` | only when `frame` is a subframe or a fenced frame (`frame->GetParentOrOuterDocument() != nullptr`) | Main-frame navigation factories are never wrapped: the main frame is never blocked, and top-level loads get no extra hop. Subframe navigations are `Subdocument` and may get CSP (§7.4) |
| `kEarlyHints` | **never reaches the hook** (revised 2026-10-26) | The early-hints factory is built with no `ContentClientParams`, so `WillCreateURLLoaderFactory` never runs for it (`content/browser/renderer_host/navigation_request.cc:5701-5707`, with Chromium's own TODO "Support DevTools instrumentation and extension's WebRequest API"; default `content_client_params = std::nullopt`, `url_loader_factory_utils.h:218-223`; the hook runs only from `ContentClientParams::Run`, `url_loader_factory_utils.cc:178-190`). Early hints exist only for outermost main frames (`navigation_url_loader_impl.cc:1413-1419`). Known gap R-14 below |
| `kDownload` | no | A user action |
| `kPrefetch` | no | Speculation-rules prefetch of documents, which are main-frame loads |
| `kDevTools` | no — and it **never reaches the hook** | Like early hints, this factory is built with `CreatePendingRemote` and no `ContentClientParams` (`content/browser/devtools/protocol/network_handler.cc:4154`), so `WillCreateURLLoaderFactory` never runs for it. The outcome is the wanted one (DevTools-initiated loads are not proxied); this row records why, so nobody looks for a skip branch that does not exist |

The factory context is captured on the UI thread and is immutable:

- the Profile's `scoped_refptr<OpenAdBlockMatcher>` (§6.7);
- the type and `request_initiator`;
- the **top site**: the registrable domain (or the host, for IP literals
  and hosts without one) of the first of these that exists:
  1. `isolation_info.top_frame_origin()`, set for untrusted factories
     (F-17): document subresources (`render_frame_host_impl.cc:14262-14276`),
     dedicated and shared workers (`dedicated_worker_host.cc:716-732`,
     `shared_worker_host.cc:518-536`), and service workers. For a service
     worker, content passes `request_initiator = storage_key.origin()` and
     `isolation_info = storage_key.ToPartialNetIsolationInfo()`
     (`content/browser/service_worker/embedded_worker_instance.cc:881-883`,
     `:913-915`), whose top frame origin is the worker's own origin in a
     first-party context and the storage key's top-level site otherwise
     (`third_party/blink/common/storage_key/storage_key.cc:793-800`). So an
     excluded site's service worker is excluded too, and a third-party
     worker follows the page that embeds it. This is read from the
     source, not a guess (review r1 finding 6).
  2. `frame->GetOutermostMainFrame()->GetLastCommittedOrigin()` when
     `frame` is set (subframe navigation factories; for these the
     outermost main frame has already committed the page that contains
     the subframe).
  3. `request_initiator` (the service-worker context wrapper's script
     factory passes the scope origin and an empty `IsolationInfo`,
     `service_worker_context_wrapper.cc:1998-2004`).
  Early hints, if a later Chromium ever routes them through the hook,
  must use the navigation's **target** origin (`tentative_origin` at
  `navigation_request.cc:5694`), never the last committed origin, which
  is still the page the user is leaving (lead ruling on finding 6);
- `frame->GetWeakDocumentPtr()` for frame-bearing factories, used only to
  route counts (`render_frame_host.h:1162`, `weak_document_ptr.h:42`);
- `subframe_navigation`.

Then `factory_builder.Append()` returns a receiver and a target remote,
and the function posts `OpenAdBlockURLLoaderFactory::Bind(receiver, target, context)`
to the matcher sequence. Requests sent before the bind wait in the pipe.

WebSocket coverage: frames only. A worker's socket has a null `frame`
(F-23), and content gives the embedder no Profile for it; Brave patches
content for that (F-33). v1 does not; record it as a known gap.

### 7.3 Request mapping

For each `CreateLoaderAndStart(receiver, request_id, options, request, client, annotation)`:

| Shim argument | Source |
|---|---|
| `url` | `request.url.spec()` (only `http` and `https`; others pass through, §7.4 rule 1) |
| `source_url` | `request.request_initiator` as an origin URL when present and not opaque; else the factory's `request_initiator`; else `request.url`. The initiator is the party source; Brave uses the same (F-33). The crate computes first/third party from the two hosts (F-8) |
| `request_type` (`OpenRequestType`, §5.5) | First match: `request.is_fetch_like_api` → `Xmlhttprequest`; `request.keepalive` and destination `kEmpty` → `Ping`; then destination: `kIframe`, `kFrame`, `kFencedframe` → `Subdocument`; `kScript`, `kJson`, `kWorker`, `kSharedWorker`, `kServiceWorker`, `kAudioWorklet`, `kPaintWorklet` → `Script`; `kImage` → `Image`; `kStyle`, `kXslt` → `Stylesheet`; `kFont` → `Font`; `kAudio`, `kVideo`, `kTrack` → `Media`; `kEmbed`, `kObject` → `Object`; `kReport` → `CspReport`; anything else → `Other` |

The first two rows follow WebRequest's own mapping (F-25). This resolves
R-5: `fetch()` and XHR now match `$xmlhttprequest` rules.

The top site from the factory context is checked against the exclusions
per request (rule 1 below), so an exclusion added while a page is open
stops blocking at once for that page's later requests.

### 7.4 Result policy

Rules, in order:

1. **Pass through** when the matcher is disabled, the top site is
   excluded, the URL is not `http`/`https`, or the request is a main-frame
   document (`request.destination == kDocument`; defensive, such factories
   are not wrapped). Corrected at Step 4: not `is_outermost_main_frame`,
   which is true for every request the main frame makes, its subresources
   included (`url_request.mojom`: "True if |frame_id| is the outermost main
   frame"); the first N-1 run passed every page subresource through. The proxy calls the target's `CreateLoaderAndStart`
   with the original `receiver` and `client` and keeps nothing: the
   request then flows without Open's hop.
2. Otherwise run `open_adblock_check`. **Block** when `matched` is true
   and rule 3 does not apply: call
   `client->OnComplete(network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT))`,
   drop `receiver`, count one `kBlocked`. The page, DevTools and CDP see
   `net::ERR_BLOCKED_BY_CLIENT` (F-5). There is no custom reason string:
   `URLLoaderCompletionStatus` carries an error code, so the old §7.4
   "reason string" checks are void.
3. **Stub response** when `matched`, `has_redirect` and a non-empty
   `redirect_data_url`, the factory is not a navigation factory, and the
   request is not CORS-mode (`request.mode` is `kNoCors`, or the request
   URL is same-origin with the source): parse the URL with `net::DataURL::Parse`; if the body is
   larger than 1 MiB or the parse fails, apply rule 2 instead. Build a
   `URLResponseHead` (status 200, `Content-Type` from the data URL,
   `Content-Length`, `response_type` `kBasic` when same-origin and
   `kOpaque` otherwise), write the body into a data pipe created with
   that capacity, send `OnReceiveResponse` and then `OnComplete(net::OK)`
   with the body length. Count one `kRedirected`. A CORS-mode request
   that matches a redirect rule is blocked by rule 2 (v1 limit, §0.2).
   Brave also answers with a stub, not a redirect (F-33).
4. **Rewrite** (`$removeparam`) when `matched` is false, `rewritten_url`
   is non-empty, `truncated` is false, the method is GET or HEAD, the
   factory is not a navigation factory (lead ruling 4), and the rewritten URL has the
   same origin as the request URL (ignore it otherwise). Send the client
   a synthetic internal redirect, as WebRequest does (F-21): a
   `net::RedirectInfo` with status 307 and the new URL, and a head with
   `Location` and `Non-Authoritative-Reason: Open ad blocker`. When the
   client calls `FollowRedirect`, start the request at the new URL on the
   target through the allowed path (rule 5). A request gets at most one
   rewrite. Not counted. Brave accepts rewrites for GET, HEAD and OPTIONS
   (F-33); v1 drops OPTIONS because preflights never pass the proxy
   (§7.5).
5. **Allow**: start the target request through an `OpenAdBlockURLLoader`
   (§7.5), so that redirects are checked.

`$important` needs no C++ action: `matched` already includes the crate's
precedence. Exceptions (`@@`) are resolved in the crate.

**CSP (`$csp`)**, subframe navigation factories only: `open_adblock_check`
also returns the crate's CSP directives for `Subdocument` (§5.3 R-4). The loader
stores them. In `OnReceiveResponse` it appends them as a
`Content-Security-Policy` header (`head->headers->AddHeader(...)`) and sets
`head->parsed_headers = nullptr`, so `NavigationURLLoaderImpl::ParseHeaders`
parses the changed headers (F-26). Main frames get no list CSP (they are
never proxied; a list must not be able to CSP-lock the top page).

### 7.5 The proxied loader, redirects, preflights, counters

`OpenAdBlockURLLoader` implements `network::mojom::URLLoader` toward the
client and `network::mojom::URLLoaderClient` toward the target, both on
the matcher sequence:

- It forwards `FollowRedirect`, `SetPriority`, `PauseReadingBodyFromNet`
  and `ResumeReadingBodyFromNet` to the target, and `OnReceiveEarlyHints`,
  `OnReceiveResponse`, `OnUploadProgress`, `OnTransferSizeUpdated` and
  `OnComplete` to the client. The response body pipe passes through; no
  byte is copied.
- **Redirects.** `OnReceiveRedirect(info, head)` checks `info.new_url`
  with the request's source and type, before the client sees it. If it
  matches: `OnComplete(ERR_BLOCKED_BY_CLIENT)` to the client, reset the
  target, count one `kBlocked`. Else forward the redirect. This covers
  server redirects and redirects made by an inner extension proxy (§7.9).
  v1 applies no stub and no rewrite on a redirect hop (Brave re-runs its
  full check when the client follows, F-33).
- **CORS preflight.** Preflights are made inside the network service and
  never pass through URLLoaderFactory proxies (F-20). Open checks the
  actual request before the network service decides to preflight, so a
  blocked request sends no `OPTIONS` at all. An allowed request's
  preflight has the same URL and needs no second check.
- **Sync XHR** needs nothing special; the renderer waits on its side.
- A disconnect on either side destroys the loader.

Size guess: about 350 lines for factory and loader together.

**Per-tab counters** (`OpenAdBlockTabHelper`, below): the factory adds
blocked and redirected counts on the matcher sequence and flushes them to
the UI thread at most once per 100 ms per factory, as one task that
carries the `WeakDocumentPtr` and the two deltas. On the UI thread:
`document.AsRenderFrameHostIfValid()`; if null (the document is gone) or
`!rfh->GetPage().IsPrimary()` (back/forward cache, prerender), drop the
counts; else `OpenAdBlockTabHelper::GetOrCreate(WebContents::FromRenderFrameHost(rfh))->AddStops(blocked, redirected)`.
Frameless factories (shared and service workers) do not count. Socket
blocks count directly on the UI thread. A lost count is acceptable; a
use-after-free is not.

```cpp
namespace open_engine {

// Per-WebContents blocked/redirected counts for the Site Control Center
// (Arc's blockedResourceCount, features-advanced §6 SC-6). Owned by the
// WebContents via UserData; all methods UI-thread.
class OpenAdBlockTabHelper
    : public content::WebContentsUserData<OpenAdBlockTabHelper>,
      public content::WebContentsObserver {
 public:
  static OpenAdBlockTabHelper* GetOrCreate(content::WebContents* wc);
  void AddStops(int blocked, int redirected);
  int blocked_count() const;     // since the last primary main-frame commit
  int redirected_count() const;
  int total_count() const;       // sum; what the panel shows
  void ResetCounts();            // CEF API, §11 Step 6
 private:
  // DidFinishNavigation resets both counters when
  // IsInPrimaryMainFrame() && HasCommitted() && !IsSameDocument().
  // Same-document (pushState) navigations keep the count.
  int blocked_ = 0, redirected_ = 0;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace open_engine
```

Counter reset timing is load-scoped: reload and new navigation zero it,
back/forward cache restores keep it (no commit), SPA route changes keep it.
Counts that a closed document flushes late are dropped by the
`WeakDocumentPtr` check, so they never leak into the next page.

### 7.6 Threads, waiting, and the crate mutex (review C-2)

| Sequence | Runs | Never runs |
|---|---|---|
| **Matcher sequence** (D-12), process-wide, `USER_BLOCKING`, `SKIP_ON_SHUTDOWN`, created on first use | proxy factories and loaders; every `open_adblock_check`; cosmetic and generic-selector queries (§8.2); matcher state updates | file I/O; builds; engine destruction; timers while idle |
| **Build runner**, process-wide, `MayBlock`, `USER_VISIBLE`, `CONTINUE_ON_SHUTDOWN` (as built) | input verification; text build; DAT deserialize and serialize; cache writes; engine destruction (§6.6 deleter) | checks |
| **UI thread** | factory context capture (one lookup, one `Append()`, one post per factory); socket continuations; counter flushes; settings and status | any engine call |
| **IO thread** | nothing from ad blocking (CEF's own proxy keeps its IO work) | any engine call |

**How a request waits.** The proxy's receivers are bound on the matcher
sequence. The renderer's `CreateLoaderAndStart` message is dispatched to
that sequence; the check runs inline in that task, and the forward to the
next hop is sent from the same task. So a request waits for one hop (IPC
to the matcher sequence), queue time, and the check. Each response
message adds one hop (target → matcher sequence → renderer). There is no
PostTaskAndReply round trip as in Brave's model (UI → ad-block runner →
UI, F-33). An IO-bound proxy that posts only the check would cost the same
on the request path and one hop less per response message, but it adds
cross-thread state and IO-thread work; the gates below decide whether
that trade is ever worth revisiting. Guess: one hop costs 5–30 µs on an
idle M-series machine.

**The crate mutex.** Every engine has one `Mutex<RegexManager>` that each
check and each cosmetic query takes (F-30). Because all engine calls run
on one sequence, the mutex is never contended; each call pays an
uncontended lock. Sharing engines between Profiles (§6.6) changes nothing,
because the sequence is shared too. The real cost of the design is
head-of-line blocking: a slow call delays every request queued behind it
in the process. Two causes, both bounded:

- long URLs, bounded by the input cap (§7.7);
- the first use of a regex rule, which compiles it under the mutex (worst
  real rule 6.78 ms, F-35). The crate discards a regex after 180 s
  without use (F-30), so a compile can repeat. v1 keeps the crate's
  default policy (it bounds regex memory) and gate G-6 counts the stalls.
  If G-6 fails, the first remedy is a longer discard time set after every
  build and deserialize (a deserialize resets the policy, F-31).

Cosmetic queries take the same mutex (`check_generic_hide`, F-30). That is
the reason they run on the matcher sequence and never on the UI thread,
where a 7 ms wait would drop frames at 120 Hz.

**Cosmetic calls in the queue (review r1 finding 3, lead ruling).** The
renderer's `[Sync] GetDocumentCosmetics` (§8.2) blocks the renderer main
thread until the matcher sequence answers. In v1 the sequence is one FIFO,
so the call waits behind every task queued before it, including network
checks of other tabs. `TaskPriority::USER_BLOCKING` does not help: it
orders ThreadPool work, not tasks inside one sequence. Expected wait,
with the §7.7 cap and a compile budget of 10 ms (the G-6 ceiling for any
one check; the worst real-list regex compiles in 6.78 ms, F-35):

- **v1, FIFO:** wait ≤ (queued checks × 1 ms worst per check at the cap,
  G-3) + 10 ms (one compile) + the query itself (77–79 µs as built, sorted output included). On
  realistic URLs a check costs about 5–10 µs (F-35, G-2), so three pages
  that load at once (about 600 queued checks) add about 3–6 ms (guess),
  and the worst case is bounded only by the queue length.
- **Escalation, named now: a priority lane.** If the contended C-G1 or
  C-G2 fails (§11 Step 5), the matcher sequence becomes a dedicated
  `base::Thread` that runs a `base::sequence_manager::SequenceManager`
  through a `base::Thread::Delegate` (`base/threading/thread.h:139`;
  precedent: the browser IO thread's prioritized queues,
  `content/browser/scheduler/browser_io_thread_delegate.h:21-66`) with
  two `TaskQueue`s: a high-priority queue for the cosmetics host and
  a normal queue for the proxies and socket checks. Both queues drain on
  that one thread, so engine access stays single-threaded and the crate
  mutex stays uncontended; it is one sequence of execution, not a second
  thread of matching. With the lane, a cosmetic call waits at most for
  the one engine call that is running: ≤ 1 ms at the cap, or ≤ 10 ms for a
  compile, plus its own query. The cost is one idle thread (no timers, so
  idle CPU stays near zero). Step 5 builds it only if the gate fails, and
  records the before and after numbers. Note what the lane bound does not
  prove: a cosmetic call can still wait ≤ 10 ms behind one compile, so
  C-G1's p99 ≤ 3 ms holds with the lane only if stalls over 3 ms sit
  ahead of fewer than 1 % of cosmetic calls. Gate G-6 (≤ 1 check
  > 1 ms per 1,000, none > 10 ms) is the supporting rate; if G-6 is near
  its limit the lane can still fail C-G1, and §8.2 rules 4–5 then apply.

*Lane mechanics (review r2 N-3; specified now so the lane is not a Step 5
design spike).* Three rules, all part of the escalation:

1. **Checker.** Two `TaskQueue`s on one thread are two sequences, so the
   matcher's `SEQUENCE_CHECKER` (§6.3, §6.7) would fire when the other
   queue touches the same state. In lane mode every matcher-state checker
   becomes a thread checker (`THREAD_CHECKER` /
   `DCHECK_CALLED_ON_VALID_THREAD`, `base/threading/thread_checker.h:82-83`)
   bound to the dedicated thread. Both queues run on that thread, so the
   checker still proves single-threaded access.
2. **Runners.** The process-wide matcher owner has two accessors from
   Step 4 on: `open_engine::AdBlockCosmeticsTaskRunner()` and
   `open_engine::AdBlockMatcherTaskRunner()`. Without the lane, both
   return the one matcher-sequence runner, so no call site changes when
   the lane is built. With the lane, the first returns the **high**
   queue's runner and the second the **normal** queue's runner. Every
   caller uses exactly one of them:
   - **High:** the `AdBlockCosmetics` binder and receiver of §8.2
     (`registry->AddInterface` takes `AdBlockCosmeticsTaskRunner()`), so
     `GetDocumentCosmetics` and `GetGenericSelectors` never queue behind
     request checks. The service's `SetEngine` / `SetEnabled` /
     `SetExclusions` posts (§6.7) also use the high runner. They make no
     engine call, so they cost a cosmetic call almost nothing, and on
     the normal queue a cosmetic call could overtake a pending toggle or
     exclusion change and answer the next navigation with the old state
     (§1.1 "next navigation" rule).
   - **Normal:** `OpenAdBlockURLLoaderFactory::Bind` and its loaders, the
     socket checks' `PostTaskAndReplyWithResult` (§7.1), the G-4
     histogram feeds, and all bench work (the G-2/G-3 bench and the C-G2
     bench load of §11 Step 5). Bench load must contend like request
     traffic, never preempt cosmetics.
3. **Stop.** The dedicated thread belongs to the same process-wide
   matcher owner, which creates it on first use. It is stopped with
   `base::Thread::Stop` (which joins it) from one named place: a new
   `ChromeBrowserMainExtraPartsCef::PostDestroyThreads()` override that
   calls `open_engine::StopAdBlockMatcherThread()`. That hunk goes into
   P-3 (`cef/libcef/browser/chrome/chrome_browser_main_extra_parts_cef.{h,cc}`,
   added to P-3's file list and manifest block) only if the lane is
   built. The hook runs after Profile teardown
   (`chrome/browser/chrome_browser_main.cc:2291`, inside
   `PostMainMessageLoopRun`), after render-process cleanup and
   `ThreadPoolInstance::Shutdown()` (`content/browser/browser_main_loop.cc:1245`,
   `:1305`), from `BrowserMainLoop::ShutdownThreadsAndCleanUp`
   (`browser_main_loop.cc:1349-1350` → `chrome_browser_main.cc:2309-2310`),
   where joining a thread is allowed (`:1211`). Unlike a
   `SKIP_ON_SHUTDOWN` sequence, the lane keeps running tasks until that
   stop. That is safe: each task holds its own references to the matcher
   and the engine, and an engine whose last reference drops after
   ThreadPool shutdown leaks at exit (shutdown rule 3 below). `Stop()`
   drops the queued tasks and disconnects the pipes bound on the lane. By
   then no render process host is left, so no renderer can still wait in
   the sync cosmetics call; if one did, it would get the failed call of
   shutdown rule 1 below ("no cosmetics for this load"). A dropped
   `SetEngine` is a no-op (the process is exiting). A socket check whose
   reply never runs starts no socket (§7.1 frame rule). Nothing waits for
   the lane thread from the lane thread itself.

**Shutdown (review r1 finding 11).** Three lifetimes meet at quit:

1. Pending matcher tasks may be dropped (`SKIP_ON_SHUTDOWN`). Mojo
   disconnect is the teardown signal. A renderer that waits in the sync
   cosmetics call gets a failed call when the pipe closes; the agent
   treats a failed call or a null reply as "no cosmetics for this load"
   and never dereferences an empty result (§8.2 rule 1).
2. Factories, loaders and the cosmetics host are deleted by their own
   disconnect handlers on the matcher sequence. During ThreadPool
   shutdown those tasks may never run; that leak is harmless at process
   exit. The rule "a disconnect destroys the loader" (§7.5) holds outside
   shutdown only.
3. Engine deletion through the §6.6 deleter is best effort once ThreadPool
   shutdown has begun: the build runner is `CONTINUE_ON_SHUTDOWN`, so a
   posted delete still runs if it was posted in time; a later drop leaks
   at exit.

Step 5 adds a quit-during-load check (§11).

**Regex features (lead ruling 3, 2026-10-26: 97-1 confirmed).** Step 4
depends on review 97-1, which is in the engine lead's queue for #97:
regex features `std`, `unicode`, `perf-dfa`, `perf-onepass`,
`perf-backtrack`, `perf-cache`, `perf-inline`, without `perf-literal`, so
aho-corasick stays out of the build. With only `std` + `unicode` the
review measured 28.8 µs per realistic URL (F-35), and G-2 would fail.

### 7.7 Match input cap (D-17; lead ruling 2, 2026-10-26)

In the shim's `open_adblock_check` (§5.5), with `cap` =
`kOpenAdBlockMatchCapBytes` = **16,384** bytes:

1. Remove the fragment (`#…`). Fragments never go to the server. Guess:
   lists rarely target them.
2. If the rest is at most `cap` bytes, match it whole.
3. Else cut after the last ABP separator byte at or before byte `cap`
   (a separator is any byte that is not `A–Z a–z 0–9 _ - . %`, the class
   that `^` matches), match that prefix, set `truncated = true`, and leave
   `rewritten_url` empty.

**Measured fallback.** Step 4 runs gates G-1, G-2 and G-3 (§7.8) twice on
the real ad-URL corpus: once with `--open-adblock-bench-cap=8192` and
once with `--open-adblock-bench-cap=16384`. The PR records both result
sets. The cap stays 16 KiB unless a gate fails at 16 KiB. If one fails,
the constant becomes 8,192, and the PR records the failing gate and both
sets of numbers. If a gate also fails at 8 KiB, the lead decides (§13.5).
Only the gated (post-warm-up) numbers of §7.8 feed this choice: a regex
first-compile in the excluded first pass can fail neither cap and can
never force the 8 KiB fallback (review r2 N-2).

Effect on filter correctness:

- Rules anchored on the host (`||host^`) and rules that match within the
  first `cap` bytes behave as before. Guess: these are almost all rules
  that matter for ads; real ad-tech URLs in the review were at most 2,040
  characters (F-35). Step 4 reports the share of corpus requests that hit
  each cap (expected 0 at 16 KiB).
- A rule that could match only after the cap is missed (a false
  negative). This is the accepted cost. A 16 KiB cap misses fewer such
  rules than 8 KiB.
- The prefix ends at a separator, so a pattern that ends in `^` sees the
  same thing at the cut as in the full URL. Only a pattern with an end
  anchor right after a separator (for example `…&|`) can match the cut
  point falsely. Step 4 counts such network rules in EasyList and
  EasyPrivacy and records the number (guess: 0).
- `$removeparam` never rewrites a capped URL, so no URL loses its tail.
- `source_url` is an origin URL and never hits the cap.

### 7.8 Cost model and the Step 4 perf gate

Page budget, re-derived (all inputs from F-35 unless marked):

- One check on a realistic ad-tech URL: 4.9 µs mean with the 97-1 regex
  features (standalone probe; the in-tree build with rustc 1.100 and
  PartitionAlloc can differ, hence G-2).
- Proxy bookkeeping per request: guess 5 µs (Mojo message handling, two
  pipes, one small heap object).
- A 200-request page: matcher busy time ≈ 200 × (4.9 + 5) µs ≈ 2 ms,
  spread over the load. Added latency per request: one hop + check on the
  request path, one hop per response message (guess 20–50 µs total),
  overlapped across parallel requests.
- The wall-time budget of §13.4 ("≤ 5 ms added per 200 requests") stays,
  now measured on real URLs. The old `many.html` (200 short local paths)
  is replaced by `corpus.html` (G-5).

**Corpus (revised 2026-10-26, review r1 finding 4).**

*Capture procedure.* Run once per corpus version, on the developer
machine, with the §13.3 CDP driver and a stock-behaving `cefsimple`
(ad blocking off):

1. Page list: the front pages of at least 20 public news and media sites,
   chosen for heavy ad tech. The list (front-page URLs only, no query
   strings) is committed in the manifest below; it holds no user data.
2. A fresh `--user-data-dir` per page; signed in to nothing; consent
   banners left as they appear (not clicked); window 1280×800.
3. Load each page, wait for `load` plus 10 s, and record the `url` of
   every CDP `Network.requestWillBeSent` event whose `type` is not
   `Document`, `http`/`https` only.
4. **Early hints (R-14, lead ruling 2026-10-26).** During the same load,
   record every CDP `Network.responseReceivedEarlyHints` event
   (experimental; raw `103` headers,
   `third_party/blink/public/devtools_protocol/domains/Network.pdl:1766-1774`).
   From its `Link` header values, keep each entry with `rel=preload` (and
   `rel=modulepreload`), resolve its URL against the page URL, and keep its
   `as=` value. Write `<url> <as> <page origin>` lines to
   `.re/adblock-corpus/early-hints.txt` (git-ignored), one per page and
   URL. Early hints exist only for outermost main frames (§7.2), so these
   come from the front pages themselves. The event exists in this tree
   (`NetworkHandler::OnResponseReceivedEarlyHints`,
   `content/browser/devtools/protocol/network_handler.cc:4080-4089`,
   needs the Network domain enabled before navigation), and CEF's CDP
   serves the same agents; whether the run's pipeline delivers it is
   proved, not assumed. **Positive control (review r2 N-4):** before the
   first corpus page, the same `cefsimple` process and CDP session load
   the local N-21 server's `early-hints.html` (§13.2), which always sends
   a `103` with one `Link: rel=preload`. The control passes only if that
   load produces a `responseReceivedEarlyHints` event that carries the
   control's own preload URL. If it does not, the capture is
   **invalid**: stop, fix the pipeline, and do not record
   `"early_hints_seen": false`. Without the control, "no site sent 103"
   and "CDP never delivered the event" look the same. With the control
   passed, a corpus in which no page sends `103` records
   `"early_hints_seen": false` in the manifest and the PR, and the
   trigger below cannot fire on that corpus.
   The local server speaks HTTP/1.1, so the capture runs with
   `--enable-features=EnableEarlyHintsOnHttp11`. That feature is not
   local-only: it makes Chromium accept `103` on **every** HTTP/1.1
   connection, HTTPS included (`EarlyHintsAreAllowedOn`,
   `net/http/http_network_transaction.cc:130-142`; HTTP/2 and HTTP/3
   accept `103` with or without it). Stock Open ignores `103` on
   HTTP/1.1, so the capture drops every corpus `103` whose document
   arrived over HTTP/1.1 (the `response.protocol` of the page's
   `Network.responseReceived` event for the same `requestId` is
   `http/1.1`) and states the number dropped in the PR.
5. Write the union of step 3 to `.re/adblock-corpus/corpus.txt`: one URL
   per line, fragments removed, de-duplicated, sorted byte-wise
   (git-ignored, AGENTS.md rule 2). At least 2,000 lines.
6. Count blocked preloads with the real engine and the staged lists:
   `--open-adblock-selftest --open-adblock-bench=early-hints.txt`
   (non-official; the bench takes the optional `<type> <source-origin>`
   columns, §13.1), with `as=` mapped to `OpenRequestType` as in §7.3
   (`script` → `Script`, `style` → `Stylesheet`, `image` → `Image`,
   `font` → `Font`, `fetch` → `Xmlhttprequest`, anything else → `Other`).
   A preload counts as blocked when `matched` is true.

*Manifest (committed, never corpus URLs; the `pages` list holds the
public front-page URLs of step 1, which the capture needs to be
reproducible and which hold no user data).*
`Engine/fork/adblock/bench/corpus-manifest.json`, written by the Step 4
PR: `{ "version", "captured", "cefsimple_build", "pages": [front-page
URLs], "url_count", "length_bytes": { "p50", "p90", "p99", "max" },
"third_party_share", "corpus_sha256", "sample_rule", "samples": {
"0": sha256, "1": sha256, "2": sha256 }, "early_hints": {
"early_hints_control_seen", "early_hints_seen", "pages_with_103",
"http11_hints_dropped", "preload_urls", "blocked_preload_urls",
"pages_with_blocked_preload", "pages_with_blocked_preload_share" } }`.
`corpus_sha256` is the SHA-256 of `corpus.txt` as written in step 5.
`pages_with_blocked_preload` counts pages with at least one blocked
103-preload URL; its share is that count divided by the number of pages
in the list. Neither counts the HTTP/1.1 `103`s that step 4 drops
(`http11_hints_dropped`). `early_hints_control_seen` records the step 4
positive control; a manifest with it false is invalid and is never
committed.

*R-14 trigger (restated as a page count, review r2 N-4; lead ruling
2026-10-26).* The trigger fires if `pages_with_blocked_preload` is
**2 or more**, that is, if at least two corpus pages each have at least
one blocked `103` preload. Then the main-frame factory wrap (R-14) goes
back to the lead **before Step 8** starts. The Step 4 PR states the
count, the share (`pages_with_blocked_preload_share`, reported for
context; it is not the trigger) and whether the trigger fired. The old
"2 % of pages" form fired on one page at any corpus size of 20–49
pages, which is not what the ruling meant. Any later run (rebase,
another machine) first checks its `corpus.txt` against `corpus_sha256`;
a mismatch means a new corpus version and a new manifest, never a silent
swap. Third-party share uses the crate's own rule (request host vs
initiator page host, F-8).

*Samples: exactly 200 URLs, everywhere.* Every `corpus.html` run loads
exactly **200** corpus URLs (G-4, G-5, C-G1, C-G2, §13.4). Sample *k*
(k = 0, 1, 2) is the 200 URLs with the smallest
`SHA-256("<k>\n" + url)`, in that order. The rule is deterministic and
independent of line order. The manifest records each sample's SHA-256
(of its 200 lines joined by `\n`). G-2 and G-3 read the full
`corpus.txt` through the bench switch; they do not load pages.

`corpus.html?sample=<k>` requests the sample's URLs with the scheme
changed to `http`, host, path and query kept. `cefsimple` runs with
`--host-resolver-rules="MAP * 127.0.0.1:8931"`, so the real host names
are matched and the local server answers (a 404 is fine). The pass/fail
runs never load live sites.

Gates. All pass before Step 4 merges; real output in the PR; five runs,
medians unless stated:

| ID | Measure | Method | Pass |
|---|---|---|---|
| G-1 | No engine call on the UI or IO thread (run at both caps, §7.7) | `DCHECK_CALLED_ON_VALID_SEQUENCE` on every matcher entry point; in non-official builds also `CHECK(!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) && !content::BrowserThread::CurrentlyOn(content::BrowserThread::IO))` in the C++ check wrapper. The self-test prints the matcher thread name once. If Step 5 builds the §7.6 priority lane, the sequence checks become thread checks (lane rule 1) and the CHECK stays | No CHECK during N-1…N-18 and the Step 9 soak; the name is a ThreadPool worker (the lane's own thread name if the lane is built) |
| G-2 | Check cost on real URLs, at both caps | `--open-adblock-selftest --open-adblock-bench=<corpus file> --open-adblock-bench-cap=<8192\|16384>` (non-official only): each corpus URL 10× through the real shim on the matcher sequence, real lists. **Warm-up (review r2 N-2):** repetition 1 of every URL is warm-up and is left out of mean, p99 and max, because a first-use regex compile can hold the engine for up to 6.78 ms (F-35) whatever the cap is. The bench prints the first-pass max on its own line; no gate reads it (G-6 still counts such stalls in page loads) | at each cap, over repetitions 2–10: mean ≤ 8 µs, p99 ≤ 60 µs, max ≤ 1 ms |
| G-3 | Long URLs, at both caps | same bench with synthetic 8 KiB, 16 KiB, 100 KiB and 2 MiB URLs (path of random letters), each checked 10× under the same warm-up rule as G-2 (repetition 1 excluded, first-pass max reported apart), so G-3 measures the cap, not a first compile | each ≤ 1 ms over repetitions 2–10, at each cap |
| G-4 | Added request latency | one **process-wide** histogram (fixed log-scale buckets from 1 µs to 100 ms, atomic counters, no locks), fed by every factory on the matcher sequence with the time from `CreateLoaderAndStart` arrival to the forward. **Print site (review r2 N-9):** printed at `--v=1` synchronously on the UI thread from `OpenAdBlockService::Shutdown()` (§6.3), once per process (the first `Shutdown()` prints; `cefsimple` has one context). A normal quit after the loads therefore always prints it, where a matcher task could be dropped by `SKIP_ON_SHUTDOWN` (§7.6); the self-test bench also prints it at the end of its own run. Runs: `corpus.html?sample=0`, five loads in one process (the G-5 on-launch), then quit normally and read the print. G-4 keeps load 1: a first regex compile delays one request of about 1,000, so it moves p99 only if more than 1 % of requests compile, and G-6 counts those stalls | p50 ≤ 50 µs, p99 ≤ 500 µs over all requests of the five loads |
| G-5 | Page wall time | `corpus.html?sample=0` (exactly 200 requests), `performance.now()` at `load` over CDP, real lists, blocking on vs off. **Process and warm-up (review r2 N-2):** the five loads of each condition share one `cefsimple` process (two launches: on, then off). That is how the harness really runs them: one CDP target reloads the page, and G-4's process-wide histogram is fed by the same on-loads. Five fresh processes would fold process start and first regex compiles into wall time, which is not the per-page cost this gate prices (real browsing is warm). Load 1 of each condition is warm-up: its wall time and busy time are reported apart, and the gate reads loads 2–5 only | blocking on faster than off; median busy thread CPU of loads 2–5 ≤ 9 ms per 200-request load, off the UI thread; quiet load1 ≤ 12 (§13.5.1 item 2a) |
| G-6 | Stalls | log every check > 1 ms with its URL length and duration (no cause: the shim cannot see a regex compile inside the crate) during the G-5 runs and the Step 9 soak | ≤ 1 per 1,000 checks; none > 10 ms |
| G-7 | Off costs nothing | the same page in a Profile with blocking off vs a build without P-3 | delta within run-to-run spread; report both medians |

The gate numbers are guesses derived from F-35 with about 1.6× headroom
for the in-tree build. The thresholds are the same at both caps. F-35's
worst single-URL rate (87 µs per KB) would put a 16 KiB check near
1.4 ms, while its 100 KB range (1–46 µs per KB) would put it at
0.02–0.7 ms, so G-3 at 16 KiB may be close to its limit (guess). The
8-versus-16 KiB choice follows §7.7. If a gate fails, the PR reports it and the lead
decides; nobody raises a budget to pass (§13.5).

### 7.9 Coexistence with extensions (#93, P1) and with CEF's proxy

Order, outer to inner: **Open ad block** → WebRequest proxy (UI thread;
present only while an extension with webRequest or declarativeNetRequest
is enabled, F-21) → other Chrome proxies → CEF's proxy (IO thread) →
DevTools → network service. Open's proxy wraps WebRequest's.

- A request that Open blocks never reaches extensions. `chrome.webRequest`
  listeners and declarativeNetRequest rules do not see it, and an
  extension's "allow" rule cannot unblock it. Brave makes the same choice
  (F-33). The user's override is the per-site toggle. Confirmed by lead
  ruling 1 (2026-10-26); the user-facing wording is in §8.4.
- A request that Open allows reaches extensions unchanged. After a
  `$removeparam` rewrite, extensions see only the rewritten request: the
  internal redirect goes to the renderer, and the followed request is a
  new request for WebRequest.
- A redirect that an extension makes (webRequest blocking or a DNR
  redirect) reaches Open's loader as `OnReceiveRedirect` from the inner
  proxy, and Open checks the new URL (§7.5). An extension cannot redirect
  a page into an ad URL past Open.
- `bypass_redirect_checks` is set only by WebRequest (F-19). Open does
  its own redirect check and never sets it. Open does not use
  `header_client`.
- P1 hosted tabs and the #93 action popups: hosted tabs are Chrome-style
  `WebContents` of the Profile's `BrowserContext`, so their factories
  pass the hook and need no tab-strip code. Extension pages (popups,
  options pages, background service workers) have a `chrome-extension://`
  initiator and are skipped (§7.2 rule 4), so an extension's own fetches,
  such as an extension blocker's list downloads, are never blocked by Open.
- CEF's proxy and OpenEngine's `requestFilter` stepping stone
  (engine-patches P8) are inside Open's proxy. A request that Open blocks
  never reaches `CefResourceRequestHandler`. Rule kept: never run
  `requestFilter`-based blocking and the fork proxy at the same time.
- An extension ad blocker can run beside Open (AD-1). Open blocks first.
  The multiple-blocker warning stays UI work (§0.2).

### 7.10 How Brave structures the same thing (fact reference only)

From F-33 (public source, read only; no code copied into this repo):
Brave wraps every factory with its own proxy installed before Chrome's
interceptors, skips main frames and extension-initiated requests, uses
the initiator as the source, serves `$redirect` matches as stub responses,
expresses rewrites as synthetic 307s, and re-checks redirects. Open
differs in three ways:

1. Open binds the proxy on the matcher sequence and matches inline.
   Brave takes requests on the UI thread and posts each check to its
   ad-block task runner, with the reply on the UI thread.
2. Open has no CNAME uncloaking in v1.
3. Open covers WebSockets of frames only. Brave patches content for
   worker sockets.

### 7.11 Fallback (do not build unless needed)

If P-3's factory hunk cannot survive a CEF rebase, the fallback is D-11's
alternative (a): the decision inside CEF's `InterceptedRequestHandler`,
with an asynchronous post to the matcher sequence. Record the trigger in
the PR. The zero-patch `CefResourceRequestHandler::OnBeforeResourceLoad`
stepping stone stays the last resort, with its old limits (no sockets, a
CEF callback per request).

Overlay header shapes (names are binding; signatures follow the tree):

```cpp
namespace open_engine {

// Context of one wrapped factory, captured on the UI thread (§7.2).
struct AdBlockFactoryContext {
  scoped_refptr<OpenAdBlockMatcher> matcher;
  content::ContentBrowserClient::URLLoaderFactoryType type;
  url::Origin initiator;
  std::string top_site;             // registrable domain, or host
  bool subframe_navigation = false;
  content::WeakDocumentPtr document;  // empty for frameless factories
};

// open_adblock_hooks.h — called from the P-3 hunk on the UI thread.
void MaybeProxyURLLoaderFactoryForAdBlock(
    content::BrowserContext* browser_context,
    content::RenderFrameHost* frame,
    int render_process_id,
    content::ContentBrowserClient::URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    network::URLLoaderFactoryBuilder& factory_builder);

// Lives on the matcher sequence. Owns its loaders. Deletes itself when its
// receivers and the target disconnect.
class OpenAdBlockURLLoaderFactory : public network::mojom::URLLoaderFactory {
 public:
  static void Bind(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
      AdBlockFactoryContext context);
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& annotation) override;
  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory>
                 receiver) override;
};

}  // namespace open_engine
```

Acceptance for Step 4: §11 Step 4 list.

---

## 8. Cosmetic filtering (revised 2026-10-26)

This section replaces the 2026-10-25 design (a browser push over
`cef.mojom` and `<style>` elements made by a main-world script). Reasons:
the push cannot arrive before the document starts (F-27), one non-CSS
selector removed all hiding (98-1), and lists could inject CSS with
`url()` beacons (98-2). Decisions: D-13 (delivery), D-14 (payload and
insertion).

**v1 scope (lead ruling 6, 2026-10-26).** v1 is network blocking plus
**plain CSS hiding**, both domain-specific and generic, including the
class/ID observer in an isolated world. Scriptlets (`##+js(...)`),
`:style()`, the uBO `:remove()`, `:remove-attr()` and `:remove-class()`
actions, and procedural filters are **not** in v1. §8.5 keeps their
design for a later milestone. Evidence for the scope: Arc's renderer agent
generates a cosmetic style sheet, and neither Arc binary contains
scriptlet, procedural or `:style(` strings (F-34; Arc's real scope is a
guess). The scope also keeps the app light: no main-world script runs on
any page in v1. This ruling overrides adblock-design's "cosmetic filters
+ scriptlets injected at document start" for v1.

### 8.1 Data flow

```text
Renderer main thread, each frame document with an http(s) URL
  OpenAdBlockRendererAgent::DidCreateDocumentElement     (own RenderFrameObserver, P-4)
    -> [Sync] AdBlockCosmetics.GetDocumentCosmetics(document_url, top_origin)
         browser, matcher sequence (never the UI thread):
           matcher off, or top site excluded  -> null
           engine cosmetic query(document_url)   (77–79 µs as built, Step 3, sorted output included)
         <- AdBlockDocumentCosmetics? (sanitized hide selectors, §8.3)
    -> WebDocument::InsertStyleSheet(hide rules, kUser)    one rule per selector
    -> if !generichide:
         GetScriptContextFromWorldId(world)   creates the isolated context if needed
           -> agent's own DidCreateScriptContext(world): install __openAdBlock
         (context already there: install into it directly)
         then ExecuteScriptInIsolatedWorld(world, observer)   only after install
         observer: collect class/ID tokens, debounce 100 ms
  observer -> __openAdBlock.report(classes, ids)            binding, isolated world only
    -> AdBlockCosmetics.GetGenericSelectors(classes, ids, exceptions)   async
         browser, matcher sequence: HiddenSelectors(...)
    <- selectors -> InsertStyleSheet(batch rules, kUser)
```

### 8.2 The interface and its binding (D-13)

Overlay `open/adblock/mojom/open_adblock.mojom` (the only Open-owned Mojo
interface in this plan). The v1 payload carries hide selectors only:

```mojom
module open_engine.mojom;

import "url/mojom/origin.mojom";
import "url/mojom/url.mojom";

struct AdBlockDocumentCosmetics {
  array<string> hide_selectors;   // sanitized (adblock-fork §8.3)
  array<string> exceptions;       // #@# generic exceptions; echoed back
  bool generichide;
};

// Renderer -> browser. One pipe per renderer process, bound on the
// ad-block matcher sequence (adblock-fork §8.2). Never touches the UI thread.
interface AdBlockCosmetics {
  // Once per http(s) document, at DidCreateDocumentElement. Null when
  // blocking is off for the Profile or the top site is excluded.
  [Sync]
  GetDocumentCosmetics(url.mojom.Url document_url,
                       url.mojom.Origin top_origin)
      => (AdBlockDocumentCosmetics? cosmetics);

  // Generic class/ID selectors for tokens the observer has not sent before.
  GetGenericSelectors(array<string> classes, array<string> ids,
                      array<string> exceptions)
      => (array<string> selectors);
};
```

**Browser side.** `open_engine::ExposeAdBlockInterfacesToRenderer(registry, host)`
(called from the P-3 hunk in `ExposeInterfacesToRenderer`, F-28) runs on
the UI thread when a renderer process host is set up. It resolves the
process's `BrowserContext` to the Profile's `OpenAdBlockMatcher` and calls
`registry->AddInterface<open_engine::mojom::AdBlockCosmetics>(binder, matcher_task_runner)`.
With a task runner, the binder and the receiver run on the matcher sequence
(`content_browser_client.h:1457-1464`). `OpenAdBlockCosmeticsHost` is a
self-owned receiver that holds the matcher reference.

**Why one pipe per render process is enough (review r1 finding 1).** The
binder picks one matcher per render process, so every frame in that
process must belong to one Profile. That holds in this tree:

1. A `RenderProcessHostImpl` gets its `BrowserContext` and
   `StoragePartition` once, at construction
   (`content/browser/renderer_host/render_process_host_impl.cc:1617-1632`,
   `:1727-1728`), and only clears it at teardown (`:4686-4687`); nothing
   reassigns it.
2. A process is reused only for the same `BrowserContext`:
   `IsSuitableHost` returns false on a different context
   (`render_process_host_impl.cc:4946-4951`); the spare renderer is used
   only for the same context
   (`content/browser/renderer_host/spare_render_process_host_manager_impl.cc:473`); the
   initial-WebUI scan for an existing process compares the context too
   (`render_process_host_impl.cc:1921`; label corrected in review r2).
   Single-process mode supports one context only (`:4940-4944`).
3. CEF maps one `BrowserContext` to one `CefBrowserContext` by identity
   (`cef/libcef/browser/browser_context.cc:100-113`). Request contexts
   with the same cache path share one `CefBrowserContext`; an empty cache
   path makes a new, isolated one (`cef/libcef/browser/request_context_impl.cc:785-812`).

So one render process → one `BrowserContext` → one `CefBrowserContext` →
one service and one matcher. Two request contexts that share a cache path
share a Profile in CEF's own model, and therefore share the matcher and
its exclusions; Open gives every Profile its own path. Guess: CEF never
creates two `CefBrowserContext`s for one `BrowserContext` (the lookup
returns the first match). Step 8 proves the result end to end with two
request contexts (§11 Step 8), because `cefsimple` has one context
(§13.1). If a later CEF or Chromium breaks the invariant, the fix is to
carry the matcher identity per call and resolve it from the frame token,
as `GetNewBrowserInfo(render_frame_token)` does (`cef.mojom:138-140`).

- `GetDocumentCosmetics`: return null unless the matcher is enabled, the
  URL is `http`/`https`, and the registrable domain (or host) of
  `top_origin` is not excluded. Else run the shim's cosmetic query and
  convert the vectors to the mojom struct. No UI-thread step, no file I/O.
- `GetGenericSelectors`: cap the input at **500 tokens in total**
  (classes plus IDs) per call, drop the rest, run `HiddenSelectors`,
  reply. This is the one batch limit, shared with the observer in §8.3
  (review r2 N-9), so a reply holds at most 500 selectors and becomes
  one generic sheet (§8.3).
- Trust: the renderer supplies `top_origin`. A compromised renderer can
  ask for any site's rules (public list data) and learn whether a site is
  on this Profile's exclusion list. Accepted under the browser's threat
  model (a compromised renderer already sees its own site's data).

**Renderer side.** `OpenAdBlockRendererAgent` binds one
`mojo::Remote<open_engine::mojom::AdBlockCosmetics>` per render thread,
lazily, with `content::RenderThread::Get()->BindHostReceiver(...)`, as
`CefRenderManager::GetBrowserManager()` does (F-28). A process-level pipe
is connected before any navigation, so the call at document start never
races a frame broker reset (D-13).

**Cost and the no-block rule (lead ruling 5, 2026-10-26).** One sync round
trip per http(s) document: IPC to the matcher sequence, queue time, the
query (77–79 µs as built, with the shim's always-sorted hide selectors;
§13.4 budget ≤ 100 µs), and the reply. Guess: 0.1–0.3 ms per document
on an idle machine, also when blocking is off (the browser answers null).
CEF already makes a sync call for each new browser on the same kind of
pipe (F-28). Gates C-G1 (blocking on) and C-G2 (blocking off) in §11
Step 5 measure it. Rules:

1. The renderer never waits on anything but this one call. If the pipe is
   disconnected or the host fails, the call returns at once, and that load
   gets no cosmetic hiding. The agent checks both the call's return value
   and the reply for null before it touches the payload (§7.6 shutdown).
   Network blocking still applies.
2. The gates measure the **contended** case (review r1 finding 3). For
   C-G1 (on), at least three corpus pages load at the same time. For
   C-G2 (off), that setup alone contends nothing: off factories wrap
   nothing, so the matcher queue stays empty (review r2 N-1). C-G2
   therefore uses **injected bench load** (lead ruling, review r2): the
   non-official switch `--open-adblock-bench-load` (§13.1) drives the
   matcher with synthetic checks, one task per check, at the rate of
   three concurrent corpus page loads, while the measured context has
   blocking off (§11 Step 5). Expected wait: §7.6 "Cosmetic calls in the
   queue". The `cefsimple` harness has one request context, so Step 5
   cannot run the real cross-Profile case, an off-Profile document that
   waits behind another Profile's checks; the bench load stands in for
   those checks. The real cross-Profile wait is measured again at
   Step 8, where two request contexts exist (§11 Step 8, R-9).
3. If the contended C-G1 or C-G2 fails, Step 5 builds the named
   escalation first: the **priority lane** (§7.6), then measures again.
4. If C-G2 still fails with the lane, Step 5 ships the **no-wait
   fallback** (lead ruling 5): the agent sends `GetDocumentCosmetics` as a
   normal async call from its renderer-side `ReadyToCommitNavigation`
   (`content/public/renderer/render_frame_observer.h:117`). At
   `DidCreateDocumentElement` it inserts the payload if the reply has
   arrived. If not, that load has **no cosmetic hiding**: the late reply
   is dropped, nothing is inserted later, and the renderer is never
   blocked. Record the numbers and the choice in the Step 5 PR.
5. If C-G1 still fails with the lane, the lead decides (§13.5); nobody
   raises the gate.

### 8.3 Payload: sanitizing, insertion, and what v1 drops (D-14)

**Sanitizer (shim, Rust, §5.5).** It runs on every hide selector and
every generic selector that crosses the bridge. Matching is ASCII
case-insensitive. A selector is **dropped** when any of these holds:

1. It contains `{`, `}`, `;`, `/*`, `<` or `@`.
2. Its `[`/`]` or `(`/`)` are unbalanced, or a quote is not closed.
3. It contains a procedural operator: `:has-text(`, `:-abp-`, `:xpath(`,
   `:upward(`, `:matches-css`, `:matches-attr(`, `:matches-prop(`,
   `:matches-media(`, `:matches-path(`, `:min-text-length(`,
   `:watch-attr(`, `:others(`, `:nth-ancestor(`, `:if(`, `:if-not(`,
   `:contains(`, `:-ext-`, `:remove(`, `:style(`.
4. It is longer than 2,048 bytes.

The native `:has()` is plain CSS in Chromium 156 and is kept. `\`
escapes are kept (Tailwind-style class names need them, for example
`.dark\:border-gray-700`); an escape cannot close a block.

The shim also discards, and counts, everything that is not a hide
selector in v1: the crate's `style_selectors` (`:style()`),
`remove_selectors`, `remove_attrs` and `remove_classes` (`:remove*()`),
and `injected_script` (scriptlets) (F-8, `adblock-0.8.11/src/cosmetic_filter_cache.rs:22-48`).
The counters are `dropped_procedural`, `dropped_unsafe`, `dropped_style`,
`dropped_remove` and `dropped_scriptlet`; `AdBlockStatus` reports the sums
for debug info (AD-8).

Each frame payload is capped at 256 KiB. Owner: the shim, in
`open_adblock_cosmetic`; unit: the sum of the UTF-8 bytes of the kept hide
selectors, not counting the fixed declaration; selectors past the cap are
dropped in sorted order and counted in `dropped_over_cap`, which status
reports (§5.2, review r1 finding 14). Generic replies are capped by the
500-token batch limit below.

With the sanitizer, no list text can open a new rule, close a block, load
a resource, or run script. Every rule Open builds has the fixed
declaration `display:none!important`, with no URL. That closes 98-2 at the
source. Per-rule insertion (below) closes 98-1, even for a selector that
the sanitizer lets through but Blink rejects.

**Insertion (renderer).** In `DidCreateDocumentElement`, when the reply is
non-null:

1. Build the hide sheet text in C++: one rule per selector,
   `<selector>{display:none!important}` joined by newlines. Insert it with
   `frame->GetDocument().InsertStyleSheet(text, nullptr, blink::WebCssOrigin::kUser, blink::BackForwardCacheAware::kAllow)`
   (F-29). Blink's parser drops a rule with an invalid selector and keeps
   the rest; one rule per selector costs no extra matching (F-29).
2. Chunking: the initial payload is one sheet. Each generic reply becomes
   one more sheet of at most 500 rules. A document gets at most 64 generic
   sheets; after that the agent stops asking and logs once at `--v=1`.
   Several insertions in one task cost one style recalc. Guesses, measured
   at Step 5 (C-G3). Worst case per document (revised, review r2 N-7):
   the capped initial sheet plus 64 × 500 generic rules. The cap bounds
   bytes, not rules, so the most rules come from the shortest
   selectors: 256 KiB / 2 B ≈ 131,000, plus 32,000 generic, so at most
   about **163,000** user-origin rules (the old figure, 45,000, assumed
   20-byte selectors). This is an upper bound: the crate returns
   distinct selectors (`HashSet`,
   `adblock-0.8.11/src/cosmetic_filter_cache.rs:25`), so only a few
   thousand can be 2 bytes long, and a real fill lands lower (guess:
   about 90,000 in the initial sheet). Generic sheets are capped by
   count, not bytes: at the 2,048-byte limit (sanitizer rule 4),
   32,000 generic selectors could carry about 62 MiB of text. Real
   generic selectors are short, and v1 measures the rule-count case
   only. Step 5 records renderer memory and style-recalc time for the
   synthetic short-selector fill (§6.6, §11 Step 5; record only in v1).
3. Why the user origin: a user `!important` declaration beats an author
   `!important` declaration in the cascade, so a page cannot undo the
   hiding with its own `!important`. The sheets are not in the document's
   style sheet list (F-29), so page scripts cannot read or remove them;
   C-8 checks that `document.styleSheets` stays unchanged. No DOM element
   is added and no script text is built from CSS, so the old §8.3 escaping
   hazard is gone.

**Class/ID observer (isolated world).** Only when `generichide` is false,
the agent runs one fixed observer script (a C++ raw string in
`open_adblock_page_script.cc`, written for this plan, not copied from
uBlock Origin or Brave) in `ISOLATED_WORLD_ID_CHROME_INTERNAL`
(`chrome/common/chrome_isolated_world_ids.h:19-20`, "internal Chrome
features"; P7 may later give Open its own world). The binding is one
native object `__openAdBlock` with two functions: `exceptions()` returns
the payload's generic exceptions as V8 values (no JSON string is spliced
into script), and `report(classes, ids)` sends one `GetGenericSelectors`
call.

*Install before execute (review r1 finding 2, lead ruling).* The agent
is a `content::RenderFrameObserver` and implements
`DidCreateScriptContext(context, world_id)` itself
(`content/public/renderer/render_frame_observer.h:139`). In
`DidCreateDocumentElement` it does, in this order:

1. Ask Blink for the world's context with
   `frame->GetScriptContextFromWorldId(isolate, ISOLATED_WORLD_ID_CHROME_INTERNAL)`
   (`third_party/blink/public/web/web_local_frame.h:449`). This creates
   the context when it does not exist yet
   (`web_local_frame_impl.cc:1248-1254`; `ToV8ContextEvenIfDetached`
   "does [force context creation] through WindowProxy() call",
   `third_party/blink/renderer/bindings/core/v8/v8_binding_for_core.cc:734-737`),
   and context creation calls `DidCreateScriptContext(context, world_id)`
   on every frame observer synchronously, before it returns
   (`third_party/blink/renderer/bindings/core/v8/local_window_proxy.cc:243`,
   `:300-308`).
2. In its own `DidCreateScriptContext`, for that world id only, the agent
   installs `__openAdBlock` and sets a per-document flag
   `binding_installed_`.
3. If the context already existed for this document (another co-tenant
   created it first), step 1 fires no callback; the agent then installs
   `__openAdBlock` into the returned context itself.
4. Only when `binding_installed_` is true does the agent call
   `ExecuteScriptInIsolatedWorld(ISOLATED_WORLD_ID_CHROME_INTERNAL, observer)`.
   At `--v=1` it logs `OpenAdBlock: binding installed (callback|existing)`
   and then `OpenAdBlock: observer started`, once per document; Step 5
   checks that order on every page (§11).

*Binding lifecycle (review r2 N-6).* A co-tenant can create the world's
context before `DidCreateDocumentElement`, and the agent's
`DidCreateScriptContext` then runs early, before the payload exists.
Three rules make every order safe:

1. **Install is idempotent.** `binding_installed_` means "the frame's
   current context of this world holds `__openAdBlock`". Steps 2 and 3
   install only when it is false. So an early callback installs once,
   and step 3 then finds the flag true and does nothing (the log says
   `callback`).
2. **The flag follows the context, not the navigation.** The agent keeps
   the context it installed into as a `v8::Global<v8::Context>`. The
   flag turns false only in `WillReleaseScriptContext(context, world_id)`
   (`content/public/renderer/render_frame_observer.h:141`) for that same
   context. A new document that gets a new context therefore installs
   again. If Blink keeps the window and its contexts for the next
   document (the initial empty document case), the binding stays and
   stays valid, because of rule 3. The per-document payload is cleared
   in `DidCreateNewDocument()` (`:128`) and set again by the sync call
   in `DidCreateDocumentElement`.
3. **The binding reads the payload lazily.** The two native functions
   hold a `base::WeakPtr` to the agent and read the agent's current
   payload each time they are called. Nothing from the payload is
   captured at install. Before the payload arrives, after a null reply,
   or after the agent is gone, `exceptions()` returns an empty array and
   `report()` does nothing. `report()` also does nothing when the
   payload says `generichide`.

The observer collects `class` and `id` tokens from the document and
from a `MutationObserver` on `document.documentElement` (`subtree`,
`childList`, `attributes: ["class", "id"]`), debounces 100 ms, sends at
most 500 new tokens per batch (classes and IDs together: the one batch
limit of §8.2, review r2 N-9), and never sends a token twice per
document.

The page cannot see the isolated world's objects, and v1 adds no
page-visible global. `CefRenderFrameObserver` passes every world's
context to CEF's `OnContextCreated` (F-29), so OpenEngine's own context
hook also runs in this world; it must ignore contexts it does not own
(P7 follow-up).

*Co-tenants of the shared world (review r1 finding 10; v1 keeps the ID by
lead ruling).* An isolated world separates scripts from the **page**, not
from other browser code in the same world: code in one world shares one
V8 global. In this tree the world also hosts the DOM Distiller observer
(`chrome/renderer/chrome_content_renderer_client.cc:741-742`) and the
Wallet boarding-pass extractor
(`chrome/renderer/wallet/boarding_pass_extractor.cc:149-151`), and the
browser runs scripts in it for tab helpers, Read Anything, Glic and web
apps (`chrome/browser/ui/tab_helpers.cc:362`,
`read_anything_untrusted_page_handler.cc:495`,
`glic_no_webview_contents_manager.cc:727,737`,
`glic_page_features_manager.cc:116`, `web_app_utils.cc:191`). That code is
inside the trust boundary and can call `__openAdBlock`. The harm if it
did: forged `report()` calls cost extra selector queries on the matcher
sequence, and `exceptions()` reveals the list's generic exceptions for
this page (public list data). The Profile's exclusion set never reaches
the renderer; at most, a missing binding shows that the current site is
excluded or that blocking is off. Task kept in the plan: allocate an
Open world ID (with P7) before any co-tenant ships that enumerates the
world's globals.

**What happens to each filter kind in v1:**

| Kind | v1 | Why |
|---|---|---|
| `##sel`, `###id`, `##.class`, generic and domain-specific | Hidden by the user sheet | Arc does the same (F-34) |
| `#@#sel` exceptions | Applied inside the crate; generic exceptions echoed with token reports | — |
| `$generichide` | No observer; domain rules still apply | — |
| `##sel:has(...)` (native CSS) | Hidden | Chromium 156 supports `:has()` |
| `#?#`, `:has-text()`, `:-abp-contains()`, `:-abp-has()`, `:xpath()`, `:upward()`, `:matches-css*()` and the other extended operators | **Dropped** by the shim, counted | Not CSS; the crate passes them through as plain selectors when `css-validation` is off (98-1). No Arc evidence (F-34). Post-v1: §8.5 |
| `##sel:style(decl)` | **Dropped**, counted (lead ruling 6) | Removes a CSS-injection surface (98-2); no Arc evidence (F-34). Post-v1: §8.5 |
| `##sel:remove()`, `:remove-attr()`, `:remove-class()` | **Dropped**, counted | Not plain CSS hiding (ruling 6 scope). Post-v1: §8.5 |
| `##+js(...)` scriptlets | **Dropped**, counted (lead ruling 6) | No Arc evidence (F-34); no main-world script in v1. Post-v1: §8.5 |
| `#$#` (ABP snippets), `##^` (HTML filters) | Ignored | The crate does not apply them |

Subframes: each frame asks for its own document URL. Back/forward cache
restores keep the document and its injected sheets
(`BackForwardCacheAware::kAllow`), so they need no new payload and do not
flash. Same-document navigations keep the sheets.

Zap merge note: Boosts and Zap selectors (M6 sibling feature) use the
same user-origin insertion when Zap lands; their sheets go in after the
blocker's. This plan only reserves that order.

### 8.4 User-facing behavior notes (v1)

These notes are product behavior. Settings help text, the Site Control
Center and support answers must agree with them (§12.2).

- **Open's blocker runs before extensions (lead ruling 1).** A request
  that Open blocks never reaches an extension. An extension's
  `chrome.webRequest` listener does not see it, and an extension's
  declarativeNetRequest "allow" rule cannot unblock it (§7.9). To let a
  site's requests through, the user turns Open's blocking off for that
  site in the Site Control Center. An extension ad blocker can still run;
  it sees only what Open allowed.
- **Extension traffic is not blocked.** Requests from extension pages and
  extension service workers (for example an extension that downloads its
  own filter lists) pass Open untouched (§7.2).
- **What v1 hides.** Network requests that match the lists are blocked,
  and page elements that match plain CSS rules are hidden. v1 does not
  run scriptlets, `:style()` rules, `:remove*()` actions or procedural
  filters (§8.3). Guess: ads that only a scriptlet can stop (for example
  some in-video ads served from the site's own host) still play in v1.
- **The main page is never blocked.** A list can block subresources and
  subframes, but never the page in the address bar (§1.1).
- **When hiding is skipped.** If the browser cannot answer a page's
  cosmetic request in time, that page load shows without element hiding;
  network blocking still applies (§8.2 rules 1 and 4). The page never waits on
  the blocker.
- **Profiles.** The toggle, the per-site exclusions, the lists and the
  blocked count belong to one Profile. Profiles with the same lists share
  one engine in memory; nothing else is shared (§6.6).

### 8.5 Post-v1: scriptlets, `:style()`, `:remove*()` and procedural filters

Moved out of v1 by lead ruling 6 (2026-10-26). This is the design
written for v1 on 2026-10-26, kept so nothing is lost. It is not
scheduled. A later milestone that takes any part of it needs a new lead
decision, a shim version bump (`engineFormat`, §5.5), and its own gates.

**Payload additions.** The mojom struct gains
`array<AdBlockStyleRule> style_rules` (`{ string selector; string declarations; }`),
`array<string> remove_selectors`, `array<AdBlockRemoveRule> remove_attrs`
and `array<AdBlockRemoveRule> remove_classes` (`{ string selector; array<string> names; }`),
and `string scriptlets`. The shim returns them as sanitized, sorted
vectors instead of discarding them.

**`:style()` sanitizer.** A declaration list is dropped when it contains
`url(`, `image(`, `image-set(`, `cross-fade(`, `element(`, `attr(`,
`expression(`, `\`, `/*`, `{`, `}`, `@`, `<`, or a quote (`"` or `'`).
Otherwise the shim splits it on `;` and appends ` !important` to every
declaration that lacks it, so the rule wins in the user origin. The quote
rule keeps `;` splitting safe; guess: few `:style()` rules use strings.
The renderer inserts the style sheet after the hide sheet, one
`<selector>{<declarations>}` rule per entry. Test: `.style-target` gets
its outline; `.style-evil` gets no background and no beacon request.

**Scriptlets.** `scriptlets` is the crate's injected script (uBO
scriptlets from `resources.json`, §9.3), with arguments escaped by the
crate (F-32). The agent runs it once per document with
`frame->ExecuteScript(blink::WebScriptSource(...))` in the main world, in
`DidCreateDocumentElement`, after the style sheets and before the parser
runs page scripts (the extension `document_start` point, F-29). Guess: an
embedder `ExecuteScript` is not subject to the page's CSP; a test page
with `script-src 'self'` checks it. No list gets scriptlet permissions,
so trusted scriptlets never run (F-32). Risk: resources go stale and
video and news sites break first; the per-site toggle is the user escape.

**`:remove*()` actions.** The isolated-world script also gets the removal
rules through `__openAdBlock.payload()`. It applies `remove_selectors`
(`element.remove()`), `remove_attrs` and `remove_classes` once at start,
once at `DOMContentLoaded`, and after each debounced mutation batch; a
selector that throws in `querySelectorAll` is skipped. A v0 DAT drops
these actions (F-31), so when this lands the shim's lossless scan must
add `:remove(`, `:remove-attr(` and `:remove-class(` as lossy kinds.

**Procedural filters.** Not designed. Options for a later milestone: turn
on the crate's `css-validation` and translate `:-abp-has()` to native
`:has()`, or run a procedural engine in the isolated world. Either needs
its own perf and security review.

**Test cases kept for that milestone:** a scriptlet rule with a test
resource (`window.__openTestScriptlet == 1`, also after a DAT load and on
a CSP page), the `:style()` pair above, and `.remove-me` gone after
`DOMContentLoaded`.

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

**Erratum — 2026-11-07:** EasyList republishes its live URL many times per
day. A release hash on that URL breaks clean builds and seed repair after
upstream moves. Bundled seeds now use immutable URLs from the official
`easylist/easylist` repository's `gh-pages` branch. Both files use the same
40-character commit. Runtime updates and their ETag flow still use the
catalog's live `easylist.to` URLs.

`Packages/OpenKit/Sources/OpenAdBlock/Resources/list-pins.txt`
(committed, exact format):

```text
# Open bundled filter lists. One line per file:
# <local-name> <seed-url> <sha256-hex-lowercase>
# Update only via: tools/fetch-adblock-lists.sh --update-pins (reviewed PR).
easylist.txt https://raw.githubusercontent.com/easylist/easylist/<40-hex-commit>/easylist.txt <sha256>
easyprivacy.txt https://raw.githubusercontent.com/easylist/easylist/<same-commit>/easyprivacy.txt <sha256>
```

Script behavior (Bash, `set -euo pipefail`, no fork-script sourcing —
`tools/` stays standalone per fork-infra §6.1):

```text
tools/fetch-adblock-lists.sh [--update-pins] [--dest <dir, default Vendor/adblock>]
```

1. Read `list-pins.txt` (+ `resources-pins.txt`, §9.3). Allow only the
   exact `https://raw.githubusercontent.com/easylist/easylist/<40 lowercase hex>/`
   seed URL with the matching `easylist.txt` or `easyprivacy.txt` filename.
   Without `--update-pins`, fetch exactly that URL (or reuse a verified cache).
   For each missing entry, download with `curl -fsSL --retry 3 -o <dest>/<name>.tmp <url>`
   (follow the official URL only; an HTTP error is fatal, no fallback
   mirror).
2. Verify: first non-empty line matches `^\[Adblock Plus` (lists) and
   `shasum -a 256` equals the pin. On mismatch: delete the temp file,
   print expected vs actual, exit 1. **Never** overwrite a good staged
   file with an unverified one — rename `.tmp` over the target only
   after both checks pass.
3. `--update-pins`: resolve `refs/heads/gh-pages` once with
   `git ls-remote https://github.com/easylist/easylist refs/heads/gh-pages`.
   Download both lists at that commit, then rewrite both URLs and hashes
   after successful header verification. Print old → new URLs and hashes.
   This mode is how a list update is reviewed; a normal run must never edit pins.
4. Print `fetch-adblock-lists: <n> files, <bytes> bytes -> <dest>`.

Use `--update-pins` to refresh both committed URLs and hashes together.
Record the resolved commit, byte sizes, and line counts in
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
elsewhere in this plan.

**Folder correction — 2026-11-07.** The caller passes
`ProfileDirectories.adBlockDirectory(dataDirectoryName:)` to
`AdBlockStore.openProfile(_:directory:)`: `<root>/Profiles/<dataDirectoryName>/AdBlock/`.
Swift settings and exclusions stay there; list generations, download caches and
`current.json` live under `AdBlock/lists/`. The CEF/OpenEngine directory parameter
names that **lists** directory. A UUID is the Profile identity, not its folder name.
On first open with no new state, the old `Profiles/<UUID>/adblock/` contents migrate
through a staged copy and atomic destination rename; failure leaves the old data
untouched and opens defaults. Existing `AdBlock/exclusions.json` remains readable.
The App registers its lazy store owner with `ProfileTeardown`; retirement marks
the Profile deleted, cancels its schedule and tracked IO task, waits for IO to
finish, drops state and emits `closed` before teardown removes its folder.

```text
<profile-dir>/AdBlock/
  catalog-state.json              Swift state, persisted before current.json moves
  exclusions.json                 Swift exclusion set
  lists/                          engine directory
    downloads/<listID>/<n>.body    source caches; never engine inputs
    current.json                  live {generation, manifestSHA256}, previous ref
    generations/<n>/
      <listID>.txt                exactly one per enabled list
      manifest.json              generation, full file inventory, state snapshot
      engine.dat                 optional browser-owned cache for THIS generation
      engine-inputs.json         browser-owned DAT receipt (see below)
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

#### 9.2.1 When a DAT may be reused (revised 2026-10-26, D-15)

A v0 DAT is not a full copy of the engine (F-31): it loses `$removeparam`
rules, the `:remove()`, `:remove-attr()` and `:remove-class()` actions,
scriptlet permissions and the regex discard policy, and it never carries
resources. After a crate or shim change, an old DAT can still decode and
silently keep the old semantics (review 100-1(a)). Rules:

1. **Write** a DAT only when the text build reported `lossless == true`
   (§5.5). In v1 a lossy set is any list set with `$removeparam` rules.
   The `:remove*()` actions do not count in v1, because v1 never applies
   them (lead ruling 6); the post-v1 design adds them (§8.5). A lossy set
   builds from text on every load and writes no DAT and no
   receipt; status reports `dat_policy = "text-only"` and the lossy kinds.
   EasyList + EasyPrivacy are lossless today (the review found 0
   `$removeparam` rules), so the default set keeps the fast path.
2. **Receipt fields** (`engine-inputs.json`), in addition to the as-built
   generation, manifest SHA-256, file→SHA-256 map, DAT size and DAT
   SHA-256: `engineFormat` (the shim's string, §5.5), `lossless: true`,
   and `resourcesSHA256` (or `null`).
3. **Reuse** a DAT only when every receipt field equals the value rebuilt
   from the verified inputs **and** `engineFormat` equals the running
   shim's string. Any mismatch: build from text and replace DAT and
   receipt (DAT first, receipt second, as built).
4. **After every deserialize**: call `use_resources` with the verified
   `resources.json` of the same generation (the DAT has none), then apply
   any non-default regex policy (a deserialize resets it, F-31).
5. **Never** copy a DAT between generations or between Profiles. Profiles
   share engines in memory only (§6.6); the registry key is content-based,
   so a second Profile with the same lists needs no DAT at all.
6. The DAT check is integrity at rest against accidents, not a defense
   against a same-user writer: such a writer can forge a matching pair,
   and `deserialize` is not a hostile-input parser (review 98-3, 100-9).
   This is accepted under the same-user threat model; the fuzz follow-up
   (docs/followups.md) stays before public release.

### 9.3 Redirect resources (uBlock Origin)

**Revised 2026-10-26 (D-15, lead rulings 6 and 7).** These rules are the
final form; review r2 (N-10) removed the pre-revision paragraphs they
used to override. v1 runs no scriptlets, so in v1 resources serve
**only** `$redirect` stub responses (§7.4 rule 3).

- **Format.** The shim takes the crate's own serialized `Vec<Resource>`
  as JSON (Step 2 as built in #98), not a path, because the crate's
  assembler reads only paths, has a deprecated scriptlet entry point and
  panics on malformed files. The runtime file is `resources.json`.
- **Production.** Step 7 makes `resources.json` at build time on the
  developer machine: fetch the pinned uBlock Origin sources from the
  official repository host, run the crate's assembler offline in a
  throwaway Cargo driver under `/tmp` (never in the browser), and pin
  the **output** SHA-256 in `resources-pins.txt` next to the source pin.
  The driver calls `assemble_web_accessible_resources(web_accessible_resource_dir,
  redirect_resources_path)` (`adblock-0.8.11/src/resources/resource_assembler.rs:267-280`):
  uBlock Origin's web-accessible-resources directory plus its
  `redirect-resources.js` index (guess for the paths in the uBlock
  Origin repository: `src/web_accessible_resources/` and
  `src/js/redirect-resources.js`; Step 7 confirms them). It never calls
  the deprecated `assemble_scriptlet_resources` (`:293-297`). Do not
  hand-convert uBlock Origin resources to JSON; the assembler exists so
  we do not. v1 keeps only resources whose kind supports redirects
  (`ResourceType::supports_redirect()`, `adblock-0.8.11/src/resources/mod.rs:187-189`)
  and leaves out scriptlet templates, so no scriptlet code ships in v1.
  `tools/fetch-adblock-lists.sh` stages it under `Vendor/adblock/`; it is
  not committed (GPL-3.0 data, same rule as list text).
- **Manifest input.** Swift copies the bundled `resources.json` into every
  generation and lists it in `manifest.json` (`file: "resources.json"`,
  `listID: "_resources"`, `sourceRevision` = the pin), so the engine
  verifies its size and SHA-256 like a list. The engine key (§6.6) and
  the DAT receipt (§9.2.1) include its hash.
- **No runtime download in v1 (lead ruling 7).** Resources change only
  with an app update, never from the network. In v1 they are stub bodies
  for `$redirect`; post-v1 scriptlets would make them main-world code on
  every page (§8.5), which is one more reason to keep them app-bound.
  §9.5 does not fetch resources.
- **Version.** The resources version is its pinned SHA-256. Debug info
  (AD-8) reports the first 12 hex digits and `resources_loaded`.

File: `Engine/fork/adblock/resources-pins.txt`, same one-line format as
§9.1 (name, URL, sha256). It holds the source pin (the upstream
revision of the assembler's inputs; one archive line or one line per
input file, Step 7 chooses and records it) and the output pin
(`resources.json` and its SHA-256). The build and the manifest verify
only the output pin. The assembler inputs exist only in the `/tmp`
driver's workspace: the browser reads `resources.json` alone, so the
service has no reserved resources name to change (the old "stage a
directory and rename the reserved name" path is void).

Licensing: uBlock Origin resources are GPL-3.0 code/data. Add a
`THIRD_PARTY.md`-adjacent note in `resources-pins.txt` header
(`# License: GPL-3.0 (uBlock Origin resources). Distribution review
required before any public release — same gate as MPL-2.0, fork-infra
Q-2.`). The pin lands in the same Step 7 PR; the counsel gate blocks
external release, not local development (fork-infra §14 Q-2 default).

Versioning: see the **Version** bullet above (the pinned SHA-256; an
app update is the only way it changes). Tombstone: the pre-revision
"resources update with the lists on the §9.5 schedule" rule is
superseded by lead ruling 7.

**Step 7 resources as built (2026-11-08).** Official uBO commit
`3762a26fd65df422080c116e6a70d13bc8d57d62` confirms both input paths:
`src/web_accessible_resources/` and `src/js/redirect-resources.js`.
`Engine/fork/adblock/resources-pins.txt` pins the official source archive
(`addfeba80c8e231cd4882160c01b64aaf2b632b3399972fc5c0819c2158b7991`)
and output (`6d4a87b8f0e44e0ffad66c5b66694c4a1da27383eaa11acae218030a29d9575e`).
The redirect index SHA-256 is
`870666664a8cc95a4d55566c440d71a5ee00e0f3f4326a15287aa55f138b547a`.
`Engine/fork/adblock/resources-inputs.sha256` records each input file's hash;
the source archive pin verifies all of them before assembly.
`tools/fetch-adblock-resources.py` copies the checked-in Cargo driver and
lockfile from `tools/adblock-resources/` into `/tmp`, fetches locked crates,
then runs `cargo run --offline --locked`. It uses crates.io `adblock =0.8.11`
with D-3's features. The lock holds `rmp` at the fork's 0.8.11 (0.8.15
removed APIs required by `rmp-serde` 0.15). No scriptlet assembler is called.
The crate's serialized `Vec<Resource>` is 142,493 bytes: 47 kept, 0 dropped;
all are `ResourceType::Mime`, with `Template=0` and `Mime(FnJavascript)=0`.
Kinds: ApplicationJavascript 31, ApplicationJson 1, AudioMp3 2, ImageGif 1,
ImagePng 3, TextCss 1, TextHtml 1, TextPlain 1, TextXml 4, Unknown 1,
VideoMp4 1. The driver prints these counts before and after filtering.

`tools/fetch-adblock-lists.sh` stages the verified output in `Vendor/adblock/`
and the ignored SwiftPM resource directory; `tools/embed-adblock.sh` copies
it into `Open.app/Contents/Resources/AdBlock/`. The package's pins receipt
mirrors the engine-side file, with byte equality required at staging.
M5 has Cargo 1.99.1 in `~/.cargo/bin`; M1 has no Cargo installed (checked
2026-11-08). A matching output cache needs no Rust. The verified source archive is cached
too, for bundling original source text and LICENSE.txt under `AdBlock/Source`
for acknowledgements. Both matching caches avoid network use. A clean or
stale output cache needs Cargo and pinned inputs; M1 can receive the verified
142,493-byte output and source archive before its build. Never substitute unverified bytes.
The assembler reads only `/tmp` inputs. The bundled source text is license
material, not an engine input: 42 original text files, 136,725 bytes (the
kept redirect stubs' text, redirect index and LICENSE.txt).

Every new Swift generation has `_resources`, independently of
`enabledBlockLists`. Old generations remain verifiable and gain the current
bundle on the next publication (open, update, reset or list change). An app
resource-pin change also republishes on open without changing enabled lists.
Copyable debug info includes `resources=6d4a87b8f0e4`.
Engine resources-after-DAT N-19 passes in E3's merged 32/32 set. The strict real App scope also passes text stubs, verified DAT relaunch/reapplication, and a no-engine zero-list generation followed by one-list restoration.

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
- **What:** for each **enabled** list (revised 2026-10-26: no longer
  `resources.txt`; resources change only with an app update, §9.3): conditional
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

## 10. Data flow and threading (summary — normative; revised 2026-10-26)

```text
Swift AdBlockStore (main actor)                Browser process
  catalog.json (committed)                       CefRequestContext (per Profile, UI thread)
  catalog-state.json (ETags)                       └─ CefBrowserContext::open_adblock_service()
  adblock/current.json ── SetOpenAdBlockListDirectory ──>  OpenAdBlockService (UI)
  exclusions.json ── SetOpenAdBlockExcludedDomains ─>   ├─ status_
  master toggle ──── SetOpenAdBlockEnabled ────────>    └─ matcher_ (scoped_refptr, state on the matcher sequence)
URLSession downloads (Swift, background) ── files ──> ReloadOpenAdBlockLists
  -> build runner (process-wide, MayBlock): verify inputs, engine key, registry hit
     | DAT load (lossless + format match) | text build -> post SetEngine to the matcher sequence
  -> old engine reference dropped; the last drop deletes it on the build runner (§6.6)

Per factory (UI thread, once per document or worker):
  WillCreateURLLoaderFactory -> MaybeProxyURLLoaderFactoryForAdBlock
    -> skip (off, excluded, unproxied type, extension initiator) | Append() + post Bind

Per request (matcher sequence):
  OpenAdBlockURLLoaderFactory::CreateLoaderAndStart
    -> pass through | open_adblock_check (≤ 16 KiB input, §7.7) -> block | stub | 307 rewrite | proxied loader
  OpenAdBlockURLLoader::OnReceiveRedirect -> check new URL -> block | forward
  counts -> at most one UI task per factory per 100 ms -> OpenAdBlockTabHelper

Per socket (UI -> matcher -> UI):
  CreateWebSocket / WillCreateWebTransport -> check -> OnFailure / WebTransportError | Chrome's path

Per document (renderer main thread -> matcher sequence):
  OpenAdBlockRendererAgent::DidCreateDocumentElement
    -> [Sync] AdBlockCosmetics.GetDocumentCosmetics -> sanitized vectors
    -> InsertStyleSheet(kUser) (hide rules), isolated-world class/ID observer (no main-world script in v1)
  Token batches (isolated world, debounced) -> GetGenericSelectors (async) -> InsertStyleSheet(kUser)

Per tab (UI thread):
  OpenAdBlockTabHelper (WebContentsUserData) counts; reset on primary main-frame commit.
  CefGetOpenAdBlockBlockedCount(browser) reads it (§11 Step 6).
```

Thread rules (violations are Step-blocking bugs):

1. The Rust engine is built, deserialized and serialized **only** on the
   build runner, and every engine is destroyed there (§6.6). The UI
   thread never parses a list and never waits on a build. Startup DAT
   load is therefore async: early navigations before the first engine
   arrives are **allowed** (no engine = allow). This is the correct
   cold-start trade: blocking the first paint on a 47 ms deserialize
   would break the 700 ms budget for a feature the user can toggle. The
   §13 perf check measures how long the unprotected window lasts (expect
   < 200 ms after Profile open for a lossless set; a lossy set builds
   from text, so expect about 250 ms — guess from Step 3's 226 ms) and
   the PR reports it.
2. Every other engine call (checks, cosmetic queries, generic selectors)
   runs **only** on the matcher sequence (D-12, gate G-1). Those calls
   never do file I/O, never post a task to wait for a result, and never
   call CEF client code.
3. Counters are UI-thread only; the matcher sequence posts coalesced
   deltas (§7.5).
4. The renderer reaches the browser for cosmetics only through
   `open_engine.mojom.AdBlockCosmetics`, which is bound on the matcher
   sequence (§8.2). No ad-block traffic uses the `cef.mojom` frame
   interfaces.
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
- [ ] Load results (#100 review R2-5, as built): the self-test waits on
      the load's `done` result, not on a status poll, and expects
      `kLoaded`. It also checks the other three paths of §6.2:
      `kCancelled` for a load whose service is destroyed first and for a
      load asked for after `Shutdown()`, and `kStale` for a load that a
      newer load replaced.
- [ ] Shutdown cleanliness: quit `cefsimple` mid-build (start a load,
      quit within 1 s) five times; no crash, no hang, no leftover
      renderer processes (`pgrep -f cefsimple` empty).

PR: overlay service files + P-2. One PR.

### Step 4 — URLLoaderFactory proxy, sockets, counters (§7; revised 2026-10-26)

Entry gate (stop if any is false):

- #97, #98 and #100 are merged, and these review fixes are in: 97-1
  (regex features; confirmed by lead ruling 3, Step 4 depends on it);
  100-2 (engines freed off the UI thread); 100-3 (switches out of
  official builds); 100-4 (exclusion matching).
- Not entry conditions (review r2 N-5): 98-3 (4-byte DAT guard) and
  100-1(a) (`open_adblock_engine_format()` and `engineFormat` in the
  receipt) are §5.5 rows owned by Step 4. This step lands every row
  whose owner is "Step 4" unless the #98 or #100 fix PR already did,
  and its acceptance verifies all of them (§5.5: gates verify, they do
  not assign).
- No build is running (§Prerequisite gate).

Work, in this order:

1. **Early spike (review r1 finding 5).** Before the full proxy: the
   factory hook (P-3 hunk 1), a minimal pass-through proxy that blocks
   one fixed `Subdocument` URL and appends one CSP header on subframe
   navigations, and N-10. This proves that Open's `Append()` sees
   subframe navigations as outermost on the `factory_override == nullptr`
   path and that the CSP edit reaches `ParseHeaders` (§7.1). Record the
   spike result in the PR. If it fails, stop and switch the subframe path
   to the named throttle fallback (§7.1) before going on.
2. Shim rows owned by Step 4 (§5.5), each unless the #98 or #100 fix PR
   already landed it: edit `Engine/fork/src/open/adblock/rust/src/lib.rs`
   (enum, cap and `truncated`, all-type `redirect_data_url`, 4-byte DAT
   guard, build report, `open_adblock_engine_format()`). The PR lists
   which rows it landed and which it only verified.
3. §6.6 and §6.7: matcher state on the matcher sequence, process-wide
   build runner and engine registry, build-runner deleter, caps, and
   the two runner accessors of §7.6 lane rule 2 (both return the one
   matcher-sequence runner until a lane exists).
4. Overlay `open_adblock_matcher.*`, `open_adblock_engine_registry.*`,
   `open_adblock_url_loader_factory.*`, `open_adblock_socket_hooks.*`,
   `open_adblock_hooks.*`, `open_adblock_tab_helper.*`, `BUILD.gn` source
   additions. The cosmetics binder is wired at Step 5, not here.
5. Patch P-3 without the `ExposeInterfacesToRenderer` line (Step 5 adds
   it to the same patch).
6. Self-test bench switches `--open-adblock-bench=<file>` and
   `--open-adblock-bench-cap=<bytes>` (non-official only; repetition 1
   is warm-up, §7.8 G-2), and the process-wide G-4 histogram with its
   print in `OpenAdBlockService::Shutdown()` (§7.8).
7. Corpus capture (§7.8) and the committed
   `Engine/fork/adblock/bench/corpus-manifest.json`.
8. Smoke harness P-6 in its §13.1 form (switches + load-end count
   logging), so Steps 4–6 verify through it.

Acceptance (record CDP output and the gate table in the PR):

- [ ] Build green; `cefsimple` with no ad-block switches behaves like
      stock (smoke A + the test page fully loads, no count logging).
- [ ] The early spike (Work 1) passed, recorded in the PR.
- [ ] §13.3 N-1…N-18 and N-21 pass (N-19 belongs to Step 7, N-20 to
      Step 6), including main frame never blocked (N-13) and the per-site
      exclusion case (N-6). N-18 is recorded as "hook reachability only;
      error-object correctness unverified" unless the PR stands up a
      local HTTP/3 endpoint.
- [ ] Blocked subresources show `net::ERR_BLOCKED_BY_CLIENT` in CDP
      `Network.loadingFailed` (`errorText`).
- [ ] Counter resets on reload and navigation and survives `pushState`
      (§7.5), CDP-checked; counts of a closed document are dropped.
- [ ] Gates G-1…G-7 (§7.8) pass. G-1…G-3 run at both 8 KiB and 16 KiB
      caps; the PR records both result sets and the cap that ships
      (16 KiB unless a gate fails there, §7.7). The PR states that
      `corpus.txt` matched `corpus_sha256` of the committed manifest, and
      that every `corpus.html` run used one 200-URL sample.
- [ ] The manifest's `early_hints` block is filled (§7.8 capture steps 4
      and 6), and the capture's positive control passed
      (`early_hints_control_seen: true`; the PR quotes the control's
      `responseReceivedEarlyHints` event). The PR states
      `pages_with_blocked_preload`, its share, `http11_hints_dropped`,
      and whether the R-14 trigger (**2 or more** corpus pages with a
      blocked `103` preload) fired; if it did, the PR asks the lead to
      rule on the wrap before Step 8.
- [ ] G-2, G-3 and G-5 report their warm-up pass apart (first-pass max;
      load 1 wall and busy time) next to the gated numbers (§7.8).
- [ ] `phys_footprint` of the browser with one engine (single context in
      `cefsimple`): within the §6.6 budget. The two-Profile footprint and
      `engine_shared=1` are Step 8 checks (review r1 finding 9).
- [ ] Patch size: P-3 diff stat in the PR, about +45/−0 in two files.

PR: overlay files + `open/adblock/rust/src/lib.rs` + P-3 + P-6 +
`Engine/fork/adblock/bench/corpus-manifest.json`. One PR (P-6 is
test-only and called out as such).

### Step 5 — Cosmetic filtering (§8; revised 2026-10-26)

Entry gate: Step 4 is merged and no build is running. The §5.5 cosmetic
row (sanitized vectors, review 98-1 and 98-2) is **not** an entry
condition (review r2 N-5): Step 5 owns it. This step lands it unless
the #98 fix PR already did (as of 2026-10-26 the #98 branch has the
sorted, sanitized vectors), and its acceptance verifies it. If the
combined `hide_css` output is still in the shim, this step replaces it
with the vector output before any renderer work.

Work: the §5.5 cosmetic row in `Engine/fork/src/open/adblock/rust/src/lib.rs`
(sanitized vectors, 256 KiB cap) unless the #98 fix PR already landed it;
overlay `mojom/` (interface + `BUILD.gn`), `open_adblock_cosmetics_host.*`,
`renderer/open_adblock_renderer_agent.*`, `renderer/open_adblock_page_script.*`
(the class/ID observer only); the `ExposeInterfacesToRenderer` line in
P-3; patch P-4 (one line in the renderer client); in P-6, the
non-official switches `--open-adblock-off` and `--open-adblock-bench-load`
(§13.1) for C-G2. No scriptlet, `:style()`, `:remove*()` or procedural
code (lead ruling 6; post-v1 design in §8.5). The priority lane (§7.6)
only if the contended gates fail, built to lane rules 1–3 (thread
checkers, the two named runners, the `PostDestroyThreads()` stop hunk
in P-3).

Acceptance (§13.3 C-1…C-10 and the gates below; real output in the PR):

- [ ] Build green. Mojo bindings are generated by GN; the patches contain
      no generated files (`git diff --stat` shows only the §3.3 files).
- [ ] C-1…C-10 pass.
- [ ] **Contended setup for C-G1 and C-G2 (review r1 finding 3).**
      Three CDP targets (`Target.createTarget`) reload
      `corpus.html?sample=0`, `?sample=1` and `?sample=2` in a loop, all
      at once, while a fourth target loads `index.html` **100 times**.
      Guess: CEF's Chrome style honors `Target.createTarget`; if it does
      not, use `contended.html`, a page with three cross-site iframes
      on three different sites (`corpus-a.test`, `corpus-b.test`,
      `corpus-c.test`, mapped by `--host-resolver-rules`). Different
      sites get separate renderer processes under site isolation;
      subdomains of one site (the old `a.corpus.test` form) are one
      site and may share a process (review r2 N-10). Either way, the
      three loads contend the browser-side matcher queue, which is what
      C-G measures. The renderer logs each sync call's time at
      `--v=1`. The first call in each renderer process (pipe setup) is
      reported separately and left out of the percentiles (review r1
      finding 12).
- [ ] **C-G1 (blocking on), contended:** over the 100 `index.html`
      documents: p50 ≤ 0.5 ms, p99 ≤ 3 ms (guesses; F-28 precedent, query
      77–79 µs as built with the shim's always-sorted hide selectors;
      §7.6 bounds the expected wait).
- [ ] **C-G2 (blocking off), contended by injected bench load (review r2
      N-1, lead ruling):** `cefsimple --open-adblock-dir=<staged lists>
      --open-adblock-off --open-adblock-bench-load=<corpus file>
      --open-adblock-bench-load-rate=<R>`. The lists load, the toggle
      stays off, so every factory is unwrapped and every cosmetic reply
      is null. The bench load posts synthetic checks of the URLs of
      samples 0–2, one task per check, to `AdBlockMatcherTaskRunner()`
      (§7.6 lane rule 2), at rate R = 600 / T checks per second, where
      600 is three concurrent `corpus.html` loads of 200 requests and T
      is the median on-load wall time of loads 2–5 from Step 4's G-5
      (in seconds). The bench calls `OpenAdBlockMatcher::Check` directly:
      the toggle gates factories and cosmetic replies (§7.2, §8.2), not
      `Check` itself. The three looping corpus targets still run (they
      add renderer and IPC load) while the fourth target loads
      `index.html` 100 times. The PR states T, R and the number of bench
      checks that ran. Pass: p50 ≤ 0.3 ms over the 100 documents. The
      real cross-Profile wait (an off context behind an on context) is
      measured again at Step 8.
- [ ] If either fails: build the priority lane (§7.6) and measure again.
      If C-G2 still fails, Step 5 ships the no-wait fallback of §8.2
      rule 4 (lead ruling 5): a load whose reply has not arrived at
      `DidCreateDocumentElement` gets no cosmetic hiding, and the renderer
      never blocks. If C-G1 still fails, the lead decides. The PR records
      every number and which mode shipped.
- [ ] **Install-before-execute (review r1 finding 2):** on every page of
      C-1…C-10 and of the contended runs, the `--v=1` log shows
      `binding installed` before `observer started` for each document
      that starts the observer, and C-4 passes 10 runs out of 10.
- [ ] **Quit during load (review r1 finding 11):** quit `cefsimple`
      (SIGTERM) during a `corpus.html` load with blocking on, five times.
      No renderer hang, `pgrep -f cefsimple` is empty within 2 s, no new
      crash report.
- [ ] Failure case: with the cosmetics host made to fail (non-official
      test switch that drops the receiver), pages load with network
      blocking and without hiding, and no renderer waits (§8.2 rule 1).
- [ ] **C-G3 (insertion):** renderer time for the initial
      `InsertStyleSheet` call on a payload of at least 400 selectors:
      ≤ 2 ms (guess). Offline construction (review r1 finding 12): with
      the staged real lists, `cefsimple --host-resolver-rules="MAP * 127.0.0.1:8931"`
      loads `http://www.gamedev.net/`; the throwaway server answers any
      path with a small HTML page, so the cosmetic query runs for that
      real host name. The `--v=1` log records the selector count. If the
      real lists give that host fewer than 400 selectors, C-G3 uses the
      first 400 selectors of the worst-case fill below instead, and the
      PR says so.
- [ ] **Worst-case payload (review r1 finding 14, review r2 N-7), record
      only:** renderer `phys_footprint` delta and style-recalc time for
      the §8.3 worst case. The synthetic list fills the 256 KiB cap with
      the **shortest** distinct valid selectors, shortest first (1-byte,
      then 2-byte, then 3-byte type selectors that are not HTML element
      names, so they match nothing on the test page), as
      `127.0.0.1##<selector>` rules; plus a fixture page with 32,000
      distinct class tokens and one generic `##.<token>` rule each, so
      the observer fills 64 generic sheets of 500 rules. The `--v=1` log
      records the kept initial-sheet count and `dropped_over_cap`.
- [ ] No page-visible `__openAdBlock*` global, and `document.styleSheets`
      unchanged by Open (CDP enumerates both).

PR: P-4 + the P-3 line (and the lane's `PostDestroyThreads()` hunk, if
the lane is built) + the P-6 switches + overlay files +
`open/adblock/rust/src/lib.rs` (if this step landed the cosmetic row;
otherwise the PR states that it verified the #98 form). One PR. The PR
quotes the sanitizer rules as implemented (security callout, 98-2).

### Step 6 — CEF control API + translator (overlay, revised 2026-11-07)

The binding Section 13 design uses free functions in
`Engine/fork/src/cef/include/cef_open_adblock.h`, guarded by
`CEF_API_ADDED(CEF_EXPERIMENTAL)` and annotated for the CEF translator.
No virtual methods are added to `cef_request_context.h` or `cef_browser.h`.

- `CefSetOpenAdBlockEnabled(context, enabled)` sets the context's switch.
- `CefSetOpenAdBlockListDirectory(context, list_dir)` starts an asynchronous
  load from the root holding current.json. The same path is a no-op; an
  empty path unloads and invalidates pending loads.
- `CefReloadOpenAdBlockLists(context)` re-reads the last directory.
- `CefSetOpenAdBlockExcludedDomains(context, domains)` replaces exclusions.
- `CefGetOpenAdBlockStatus(context)` returns enabled, engine_loaded,
  engine_from_dat, engine_shared, dat_policy, list_count, resources_loaded,
  last_build_ms, last_error, excluded_count and load_generation. No URLs,
  paths or exclusion names enter the dictionary. Errors use a fixed summary.
- `CefGetOpenAdBlockBlockedCount(browser)` reads the existing current-document
  helper's blocked plus redirected count, or zero without a helper. There
  is no manual reset API; navigation owns resets.

Enable/exclusion changes reset existing factories in the context's loaded
storage partitions, using Chromium's proxy-transition path. Disabled/excluded
documents have no proxy (§7.2), so this permits enabling without navigation.
The real-App acceptance run `s15-adblock-r5` proves the next blocked
request after enabling or re-including the current document, and the
next allowed request after disabling, without navigation.

All calls run on the browser-process UI thread. Mutators return false for
an unavailable or uninitialized context; status returns null. They never
wait for an engine build and never fall back to Default. The implementation
is a libcef overlay in `open/adblock/open_adblock_api.cc`, compiled
through `open_libcef_sources.gni`. The existing translator generates C API,
wrapper, dylib and build-file entries when engine-apply copies the header;
no new upstream wiring patch is required.

Each OTR context has its own service, switch and exclusions. The App supplies
its parent's list directory, allowing the registry to share the engine.
Native close shuts down the OTR service before its parent and all setters
reject a retained closed OTR wrapper.

Acceptance:

- [x] Engine build and built-artifact engine-status PASS; generated C API has all six
  functions and the framework exports their C symbols.
- [x] Headless real-CEF control flow (21 PASS): defaults/status schema, enable/off/on,
  exclusions, same-path no-op, generation reload, failed load, unload during
  a pending load, OTR settings isolation/sharing and closed-context refusal.
- [x] Real App request/control integration after the recorded distribution:
  §12.1 and Step 8. F's accepted allocation capture replaces the historical
  whole-process AD3 predicate; merged rerun/full-gate acceptance remains below.

Step 4, Step 6 and Step 8 ship as one engine milestone under the lead's
integration gate. Smoke switches remain non-official only.

### Step 7 — Bundled lists, catalog, resources (§9.1, §9.3, §9.4)

Entry gate (revised in review r2, N-5): Step 6 is merged and no build is
running. The §5.5 deserialize row (resources after deserialize, review
98-4) is **not** an entry condition: Step 7 owns it, lands it unless
the #98 fix PR already did, and its acceptance (N-19) verifies it.

Work: `tools/fetch-adblock-lists.sh`, `Engine/fork/adblock/list-pins.txt`,
`resources-pins.txt`, `catalog.json` (one-time transform); the §5.5
resources-after-deserialize row in `Engine/fork/src/open/adblock/rust/src/lib.rs`
(owner: Step 7, unless the #98 fix PR landed it); the Swift manifest
change for `_resources` (§9.3); nothing else.

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
      shim loads it (Step 2 driver re-run with resources: the §13.2
      `noop.js` redirect resource resolves — do not assert on real uBO
      content). Revised 2026-10-26: the staged file holds only
      redirect-capable resources, no scriptlet templates (§9.3).
- [ ] Revised 2026-10-26 (§9.3, §9.2.1): `resources.json` is produced
      offline by the `/tmp` assembler driver and its output SHA-256 is
      pinned; Swift copies it into each new generation as the
      `_resources` manifest entry; the engine verifies it, and after a
      DAT load `resources_loaded > 0` and N-19 passes (review 98-4).
- [ ] The lossy §13.2 `testlist.txt` generation never writes a DAT: two
      runs both report `engine_from_dat=0 dat_policy=text-only`, and N-5
      passes on both runs (review 100-1(b)). The lossless
      `redirect-list.txt` generation loads from its DAT on the second run
      and N-19 passes there.

PR: tools + `Engine/fork/adblock/**` + `open/adblock/rust/src/lib.rs`
(if this step landed the deserialize row; otherwise the PR states that
it verified the #98 form) + the Swift manifest change. One PR.

### Step 8 — OpenEngine ObjC API + Swift adapter (revised 2026-11-08)

`OEAdBlock.h`/`OEAdBlock.mm` implement the §12.1 categories. Before CEF
initialization they retain the latest values and queue one weak ready
callback; closed contexts ignore mutations and report defaults. The Swift
`AdBlockEngineAdapter` binds only when native `adBlockSupported` is YES,
opens loaded/new Profiles after first paint, and configures late regular
and OTR contexts. Store events drive configure, enabled, exclusions,
reload and closed transitions. Profile retirement remains the #241 path.
The automation support override is for placeholder binding coverage only;
the real-engine flow omits it and requires native support.

This milestone combines Steps 4/6/8, per API-DESIGN (2026-11-07). It is
network blocking before Step 5 cosmetics. Acceptance through the real M5
App and its production API:

- [x] Debug App builds against the recorded integrated distribution.
- [x] Enable -> page: native blocked count >0, CDP ERR_BLOCKED_BY_CLIENT,
      ad absent at the fixture server; an allowed control script runs.
- [x] Exclude -> reload: count 0 and ad loads; re-include blocks again.
- [x] Global off/on works without relaunch. Re-including/enabling also
      blocks the next request from a document created while unproxied.
- [x] Two Profiles keep exclusions/lists independent; identical lists
      produce engine_shared=true in the second context.
- [x] AD3 requires matching verified input hashes and engine_shared=true;
      median of n=5 attachment-only PA allocated deltas <=2 MiB, and median
      non-PA malloc in-use delta <=2 MiB. Both contexts/stores exist before
      baseline, with store IO idle. Different-list control must show
      sharing=false and PA allocated delta >=8 MiB, else AD3 is INVALID.
      Record PA committed deltas and whole-process on/off paired median/spread.
      F's accepted capture and E3's strict 79/79 scope pass (below).
- [x] OTR shares its parent's engine and follows later parent exclusions.
- [x] Settings list toggle publishes a generation, advances load_generation
      and changes blocking. All lists off verifies a no-engine generation, with no loaded resources or error.
- [x] Deleting a Profile during held real HTTP with its native engine
      loaded retires the context; no crash; folder absent after relaunch.
- [x] Debug copy has the 11-key native schema and no path, page URL or site.
- [x] Real opposite request states reject the corresponding new gates;
      Cancel deletion retains the native context and folder.
- [x] Forced failure with a delete sheet open proves finally cleanup:
      `s15-adblock-delete-cleanup-r1`, exact expected failure, zero
      owned processes/windows after finally.
- [x] Existing page/features/extensions-ui/settings-preview scopes complete
      with the explicit existing qualifiers below; all runnable rows pass.
      Full verification passes 25/25 on the final merged source.

**Step 8 acceptance errata (lead ruling, 2026-11-08).** This AD3 predicate
supersedes the API-DESIGN-derived single `phys_footprint` delta. Five real
App on/off pairs had a net median of +1,064,936 B, with a range from
−10,584,088 to +10,862,616 B (20.45 MiB spread). That process noise cannot
decide a 2 MiB allocation budget. Keep five whole-process empty→reset pairs
as record-only rows. Measure five native attachments separately, after
stores and verified inputs exist and update timers have been cancelled.
Use fixed 6 s settles before five own-process counter samples per phase;
this wait does not prove an idle purge. Record purge occurrence from the
native log. Background memory-infra dumps provide PA allocated/committed
direct-root totals without counting parent/child totals twice. Documented
malloc-zone counters provide non-PA in-use/allocated bytes. PA serves Swift
as well as native code, so non-PA counters alone are not Swift attribution.
Missing dumps/counters, changed inputs, active store IO, or a weak negative
control make the capture INVALID, never PASS or SKIP. These errata change
only the two-Profile AD3 gate; Step 4 single-engine budgets stay as written.

No CEF type crosses the Swift surface. Section 12 owns the existing Site
Control tile: .on when enabled/not excluded, .off when excluded and
.unavailable when globally off or the binding/Profile is unavailable.
The conditional tile proof runs only once its App source is on main;
E3 must not create a second tile.

**Historical whole-process predicate, real App (2026-11-08).** `s15-adblock-r5` records 61 PASS
and one FAIL, AD3 footprint owned by F. All nine direct App launches quit
cleanly, with no foreground interruption or surviving process/window.
The run uses main `40c2ab94` and the recorded `8e8a461c…` distribution.
Its wrapper takes 146.963 s, at endpoint loads 20.40/94.13/91.93 ->
16.06/63.92/79.97. The raw harness exits 1; continuation of the exact
owned AD3 row does not convert it to PASS.

| Real App acceptance | Result and witness |
|---|---|
| Enable, exclude, re-include, global off/on | PASS: native counts, CDP blocked-by-client errors, script completion and server request log agree; same-document next requests also change without navigation. |
| Profile independence and sharing | PASS: independent exclusions/lists, shared holder for identical inputs; a different-list control creates a separate engine and exceeds 2 MiB. |
| AD3 incremental footprint | **FAIL, owned by F:** 5.734 MiB net, `engine_shared=true`, against 2 MiB, at load 18.54/71.19/83.19. |
| OTR | PASS: shared parent engine; later parent exclusions and re-inclusion change real requests. |
| Settings list generation | PASS: native generations 1 -> 3 -> 4 and opposite allowed/blocked requests. An unchanged scheduled download publishes disk generation 2 while correctly retaining native generation 1. |
| Resources and verified DAT | PASS: 47 pinned resources, real text stub, verified DAT relaunch and reapplied stub. |
| Zero lists and one-list restore | PASS: generation 4 has count 0, no engine/resources/error and allowed requests; generation 5 has exactly one list and resumes blocking/stubs. |
| Delete during load | PASS: native engine loaded, real held HTTP request, Cancel control retains folder/context; deletion retires them and folder stays absent after relaunch. |
| Debug copy | PASS: exact 11-key schema, no path, URL or site name. |
| Warning and adapter scopes | PASS: AD1 11 rows and AD2 9 rows, with no native support override. |
| Forced delete-sheet cleanup | PASS: expected failure in the specific real sheet, then zero owned processes/windows. |
| Section 12 App tile | N/A: its App adapter is absent from this main. |

The forced-sheet control takes 1,377.209 s including its screen queue,
at endpoint loads 16.06/63.92/79.97 -> 6.00/10.09/26.08.
Its raw expected failure and the separate AD3 failure are retained.
Page passes 81 rows with no FAIL or foreground interruption. Five known
BLOCKED rows, the hosted-tab activation SKIP and the user smart-zoom
DEFERRED row remain explicit. The later Features, Chrome Extensions UI,
Settings preview and final full-gate results are recorded below.

**AD3 accepted capture, 20:53 lead ruling.** F's `d5e44abe` records 79/79
PASS on its full adblock scope, including 11 record-only whole-process
rows. Attachment-only PA allocated median is −26,464 bytes; non-PA malloc
in-use delta is zero. The different-list control allocates 25,461,840 bytes
with `engine_shared=false`. E3 merges that harness and the list-change
wait fix in `11dd8b60`, keeping its live-page and disk-publication waits.
The Debug rebuild passes in 50.600 s, including 20 s in the heavy queue,
at endpoint loads 12.19/11.36/11.12 -> 12.57/11.61/11.22.
No native engine or production adapter change is needed. The merged E3
scopes below use the strict harness without the historical AD3 bypass.
The earlier failed receipts keep their original predicate and result.

**Merged E3 strict scope.** `s15-adblock-r7` passes 79/79, including 11
record-only whole-process rows, with no foreground interruption. All nine
owned App launches close without force and leave zero processes/windows.
The accepted AD3 n=5 PA allocated median is −4,016 bytes (range −307,488
through +24,976; spread 332,464; MAD 21,920); PA committed median is zero,
and non-PA malloc in-use delta is zero. The different-list control has
`engine_shared=false` and PA allocated +25,117,360 bytes. Verified input
hashes and all requested background dumps pass. Endpoint loads are
9.12/9.73/10.34 -> 10.84/12.65/11.92; wrapper time is 1,031.002 s including
the screen queue. Real held-HTTP deletion, Cancel control and relaunch pass.

The preceding strict attempt passed AD3 but stopped during deletion setup:
its load helper read a newly created Profile before its asynchronous native
context existed. The readiness poll now waits for that context within the
same 40 s. The successful run records `sawMissingContext=true`, then a loaded
engine for that exact Profile, and passes both deletion controls. No engine
or App production change is involved; the prior failed receipt is retained.

**Final default-Chrome acceptance and gate.** `s15-adblock-r10` passes
79/79 with nine clean launches. AD3 n=5 PA allocated median is −46,144 B,
non-PA malloc in-use delta zero; different-list control +25,129,024 B with
sharing=false. Resources-only generation4 -> one-list generation5 and
held-load Cancel/deletion/relaunch pass. Full Chrome Extensions UI has
71 PASS and one existing BLOCKED picker row. Features has27PASS; Page
has81PASS with five existing BLOCKED, one SKIP and one DEFERRED qualifier.
Settings preview passes47functional checks plus native pane renders.
Main e8d4acd4 is merged with no further Engine/fork change; its Debug
rebuild and full verification gate pass (25/25, noFAIL/SKIP). Exact final
commands, load averages and the complete gate table are in E3's
VALIDATION.md and PR-BODY.md. Step4-as-built below records provenance.

Later Step 5/9 acceptance remains open: two renderer processes with
independent cosmetic selectors/exclusions, and cross-Profile C-G2 wait
under real matcher contention (p50 <=0.3 ms, first call reported apart).
The earlier Step 8 cosmetic rows move to that later integration gate;
network-only completion does not claim them.

### Step 9 — Perf, soak, and rebase notes

Work: §13.4 measurements, a 30-minute `cefsimple` soak on the test site
(reload loop via CDP), and PR-description rebase notes (below).

Acceptance: §13.4 budgets table filled with real numbers; soak with no
crash and stable blocked counts; `engine-status` all PASS. Revised
2026-10-26: the §6.6 memory budgets are measured and reported (one
engine, a second Profile with the same lists, text-build transient, all
generic + privacy lists); G-1 and G-6 hold over the soak; the framework
size before and after ad blocking is recorded (review 97-6).

Rebase notes (write them into the Step 9 PR, future maintainers read
them there): P-2 touches a CEF base header (conflict surface: CEF
adding members to `CefBrowserContext`); P-3 adds one call inside CEF's
`WillCreateURLLoaderFactory` and three socket overrides — re-copy the
override signatures from the new tree's `content_browser_client.h` and
check that CEF's override still calls Chrome's implementation after the
Open call; P-4 is one line in `ChromeContentRendererClientCef::RenderFrameCreated`;
P-5 requires re-running the translator after any CEF API change before
capturing; P-1 regeneration is fork-infra §12 step 5.

---

## 12. OpenEngine and Swift API surface

**API-DESIGN errata (Section 13 H, 2026-11-09; runtime proof pending):**
The App adapter's OTR inheritance in API-DESIGN §3 and the Site Control contract
in §5 also need session-only exclusions. `AdBlockStore.siteSnapshot(for:privateSession:)`
and `setExcluded(_:excluded:profile:privateSession:)` take the parent Profile ID
and the engine's existing `Private-N` context identifier. The effective set is
parent saved exclusions ∪ session additions. Private removal cannot override a
saved parent exclusion. The adapter registers the session when it configures
the OTR and drops it when the last private window closes. Saved-parent changes
recompute each open OTR's union; private events target only that OTR. No private
choice is serialized. Profile close and retirement notify observers, including
an immediate retirement notification before IO drains. Site Control remains
Section 12's responsibility; its parent/session call-site handoff is in
`.re/s13/h/S12-HANDOFF.md` in the project root. H's source checkpoint has no
build, App run, negative-control receipt, or merge-readiness claim while the
06:30 / M5-clear hold applies.

CEF types never cross into Swift (architecture rule). OpenEngine is the
only layer that includes CEF headers.

### 12.1 ObjC++ API (categories, revised 2026-11-07)

Public header `Engine/OpenEngine/include/OpenEngine/OEAdBlock.h`, imported
by `OpenEngine.h`; implementation `Engine/OpenEngine/src/OEAdBlock.mm`.
No CEF type or opaque handle crosses into Swift. Main thread only.

```objc
@interface OEBrowserContext (OEAdBlock)
@property(class, nonatomic, readonly) BOOL adBlockSupported;
@property(nonatomic, getter=isAdBlockEnabled) BOOL adBlockEnabled;
@property(nonatomic, copy, nullable) NSURL* adBlockListDirectory;
- (void)reloadAdBlockLists;
@property(nonatomic, copy) NSArray<NSString*>* adBlockExcludedDomains;
@property(nonatomic, readonly, copy) NSDictionary<NSString*, id>* adBlockStatus;
@end

@interface OEWebContent (OEAdBlock)
@property(nonatomic, readonly) NSInteger adBlockBlockedCount;
@end
```

`adBlockSupported` is YES only with the native implementation. The App binds
its store events only when it is supported. Before context initialization,
the category remembers values and queues one weak callback through
`oe_whenReady`. It applies exclusions, directory and enabled in that order
using the final remembered values. A pending reload follows configuration.
A closing/closed context ignores setters and returns defaults. Status maps
the CEF snapshot's scalar values to NSNumber/NSString; count comes directly
from `CefGetOpenAdBlockBlockedCount`.

The App adapter (`App/AdBlock/AdBlockEngineAdapter.swift`) configures every
regular context and its OTR children, and reapplies the parent's config to
contexts created later. Profile opening/list updates run after first paint.
Profile retirement drains the store and closes native state before deleting
its folder. Section 12 owns the existing Site Control tile. The tile is
unavailable unless the adapter is bound, that Profile is open and global
blocking is enabled. No blocked count appears in the UI.

### 12.2 What the Site Control Center and Settings read (contract)

- Panel toggle state: `enabled && !isExcludedForHost(currentHost)`.
- No blocked count in the panel (Section 13 lead decision 4). The engine
  count is for tests and debug only.
- Toggle action: Swift updates its exclusion set (§12.3), calls
  `adBlockExcludedDomains` on the context, then offers the reload follow-up (SC-6) — the
  engine itself needs no reload for the toggle to be correct on the
  *next* navigation (§1.1), the reload is for the *current* page.
- Scope dialog ("this site" = registrable domain, default;
  "this page only" = exact-host, session-only): v1 engine support is
  registrable domains only. "This page only" is implemented Swift-side
  as a session exclusion that Swift adds on toggle and removes when the
  tab navigates to a different host. Do not extend the CEF API for it.
- Debug info (AD-8): sorted `adBlockStatus` lines + Swift's list/ETag lines,
  joined, copied to the pasteboard by the UI. Contents are §6.4-safe.
- Help text and support answers follow the user-facing behavior notes in
  §8.4 (added 2026-10-26), including lead ruling 1: Open's blocker runs
  before extensions, and an extension cannot see or unblock what Open
  blocks.

### 12.3 Swift store contract (`OpenAdBlock.AdBlockStore`, as built)

The existing store owns persistence, downloads and retirement. The App adapter
consumes its events; no CEF types enter this package:

```swift
@MainActor final class AdBlockStore {
  // Mirrors Arc keys for the future importer (AD-6): UserDefaults /
  // BrowserState keys nativeAdBlockEnabled, enabledBlockLists,
  // blockListsPerProfile, plus Open's catalog-state.json per Profile.
  var isEnabled: Bool                       // master, default true (design choice; factory default unproven, AD-6)
  func enabledListIDs(for profile: ProfileID) -> [String]  // default ["EasyList", "EasyPrivacy"]
  func setListEnabled(_ id: String, _ on: Bool, profile: ProfileID) async throws  // publishes a complete generation + reload trigger
  func excludedDomains(for profile: ProfileID) -> [String]
  func setExcluded(_ domain: String, excluded: Bool, profile: ProfileID) throws  // persists exclusions.json + adapter event
  func updateListsNow(profile: ProfileID) async throws  // §9.5 flow: conditional GETs, atomic writes, one reload trigger
  func debugInfo(profile: ProfileID) -> String
}
```

Rules: downloads use `URLSession` with `If-None-Match`; multi-URL lists
concatenate in catalog order (§9.4); publish all enabled files through the
§9.2 generation transaction; a failed batch keeps the old pointer; the
24 h timer is per Profile and starts 60 s after Profile open (§9.5);
OTR contexts use their parent Profile's existing list directory and receive
its current enabled state and exclusions. They have separate native service
state and share the immutable engine. No second OTR store, temporary seed
folder or private-site persistence is created. Weakly tracked OTR wrappers
receive later parent events without extending their lifetime. Native close
shuts the service down before the shell tears down the wrapper.

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
--open-adblock-selftest         Step 3 mode: load dir, wait for the load's
                                done result (§6.2; as built since #100
                                review R2-5), print status lines, exit 0/1
                                without opening a window
--open-adblock-bench=<file>     added 2026-10-26, with --open-adblock-selftest:
                                check every URL of <file> (one per line,
                                optional "<type> <source-origin>" columns)
                                10x on the matcher sequence; repetition 1 is
                                warm-up: print its max on its own line, then
                                mean, p50, p99, max over repetitions 2-10,
                                and the matcher thread name (G-1..G-3)
--open-adblock-off              added in review r2, with --open-adblock-dir:
                                load the lists but leave the master toggle
                                off (C-G2)
--open-adblock-bench-load=<file>  added in review r2 (C-G2): post synthetic
                                checks of the URLs of <file> (samples 0-2),
                                one task per check, to AdBlockMatcherTaskRunner()
                                (§7.6), calling OpenAdBlockMatcher::Check
                                directly, in 10 ms ticks, until exit; print
                                the number of checks run at exit
--open-adblock-bench-load-rate=<checks/s>  rate for the switch above
                                (R = 600 / T, §11 Step 5)
--remote-debugging-port=9222    stock CEF switch; the §13.3 driver uses it
--host-resolver-rules="MAP * 127.0.0.1:8931"   stock Chromium switch; G-5 and
                                C-G1 corpus runs keep real host names local
--use-alloy-style               stock cefsimple switch (simple_app.cc:123); N-16
```

As built (Step 3), the `--open-adblock-*` switches are read in
`CefBrowserContext::Initialize()`; since review 100-3 they exist only in
non-official builds (§6.7).

Behavior when `--open-adblock-dir` is present (in
`OnContextInitialized`, on the global request context — `cefsimple` has
one context; per-Profile isolation is a Step 8 app-level check, not a
cefsimple check):

The non-official initialization switches configure the owned service during
`CefBrowserContext::Initialize()`, before a usable CEF request context exists.
This remains diagnostic-only code. The separate headless
`--open-adblock-api-proof` flow waits for a real context's initialized callback
and drives all configuration through the six production CEF free functions.
The App uses only the OpenEngine categories and this production CEF path.

Native smoke readings include `blocked_count`, committed `document_id` and
`phase=commit|load|count|same-document`, with host only (no full URL). Navigation
resets the count; pushState/replaceState reads it without resetting. The strict
closed-document predicate is recorded in "Step 4 as built".

### 13.2 Local test site (overlay `open/adblock/testdata/`)

Serve with the throwaway server below, from the repo copy (the overlay
files are also in the tree after `engine-apply`; either copy serves).
**As built (Step 4):** the pages use port-free URLs (`http://127.0.0.1/…`,
`http://127.0.0.2/…`), and `cefsimple` gets
`--host-resolver-rules="MAP 127.0.0.1 127.0.0.1:<first>, MAP 127.0.0.2 127.0.0.1:<third>"`
for the server's two ephemeral ports. Two reasons: macOS has no
`127.0.0.2` without an interface alias (`bind` fails with `EADDRNOTAVAIL`),
and the crate's `||host/path` rules need the path right after the host,
so `||127.0.0.2/frame-ad.html` never matches `127.0.0.2:8932/frame-ad.html`
(`check_pattern_hostname_left_anchor_filter`, `get_url_after_hostname`).
Rules and party still see the real hosts. The page must not reference
the network.

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
  `resources.json` beside `testlist.txt` defining `noop.js` as a script
  containing `window.__redirLoaded = true;`),
  `<img src="http://127.0.0.2/track/pixel.gif">` (third-party
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
- the scriptlet target: rule `##+js(open-test-scriptlet)`, with **no**
  resource of that name. v1 must **not** run it (C-5); the rule stays as
  a must-drop case. The test `resources.json` holds only `noop.js`,
  because v1 resources exclude scriptlet templates (§9.3).

`generichide.html`: contains `<div class="generic-ad">` (must stay
**visible** — generic hide suppressed) and `<div class="ad-slot">`
(must hide — domain rules still apply under `generichide`).

Static files: `ads/banner.js`, `ads/allowed-banner.js`,
`ads/important.js`, `ads/redir.js` (each: a comment line only; presence
on disk proves blocks are ours, not 404s), `track/pixel.gif` (a real
1×1 GIF — generate with
`printf 'GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b' > track/pixel.gif`
at Step 4; verify with `file`), `api/data.json` (`{}`).
`resources.json` format: the crate's serialized `Vec<Resource>` (§9.3),
with one entry, `noop.js`. Make it with the Step 7 `/tmp` driver from a
one-file input, or write it by hand in the crate's serde form; it is
Open's own test data, not converted uBlock Origin content. It is listed
in the fixture manifest as `_resources`.

**Additions 2026-10-26** (Steps 4–5). New lines at the end of
`testlist.txt`:

```text
||127.0.0.2^$websocket
||127.0.0.1/ads/worker-ad.js
||127.0.0.1/ads/sw-ad.js
||127.0.0.2/frame-ad.html$subdocument
||127.0.0.2/ads/redirect-target.js
||127.0.0.1/api/xhr-only.json$xmlhttprequest
||127.0.0.1/blocked-main.html$document
||127.0.0.1/csp-frame.html$csp=script-src 'none'
127.0.0.1##.style-target:style(outline: 3px solid red)
127.0.0.1##.style-evil:style(background: url(http://127.0.0.2/beacon.gif))
127.0.0.1##.proc-ad:has-text(Sponsored)
127.0.0.1##x{} .exfil{background:url(http://127.0.0.2/exfil.gif)} y
127.0.0.1##.remove-me:remove()
||127.0.0.2/wt-blocked
```

As built, the list also has `/ads/allowed-banner.js` above the
`@@||127.0.0.1/ads/allowed-banner.js` exception. Without it the exception
excepts nothing (`/ads/banner.js` is not a substring of
`/ads/allowed-banner.js`), so N-1's "exception-allowed" proved nothing.

`testlist.txt` is lossy (`$removeparam`), so it always builds from text.
Its `##+js(...)`, `:style()`, `:remove()` and `:has-text()` lines are
**must-drop** cases in v1 (lead ruling 6, C-5, C-7). A second fixture
generation, `redirect-list.txt`, is lossless: only `127.0.0.1##.ad-slot`
and `||127.0.0.1/ads/redir.js$redirect=noop.js`, with the same
`resources.json`. It proves the DAT path with resources (N-19).

New test files:

- `worker.html`: starts `worker.js` (a dedicated worker that fetches
  `/ads/worker-ad.js` and `/api/data.json` and posts both outcomes) and
  registers `sw.js` (a service worker that fetches `/ads/sw-ad.js` on
  `install` and stores the outcome in Cache Storage). `127.0.0.1` is a
  secure context, so the service worker can register over HTTP.
- `frames.html`: iframes `http://127.0.0.2/frame-ad.html` (blocked)
  and `/csp-frame.html` (allowed; its inline script sets
  `window.__cspInlineRan = 1`, which the list CSP must stop). It also has
  `<div class="style-target">`, `<div class="style-evil">`,
  `<div class="proc-ad">Sponsored</div>`, `<div class="exfil">`,
  `<div class="remove-me">` and, for the per-rule check, a page whose
  hostname rules include both `.ad-slot` and `.proc-ad:has-text(...)`.
- `fetch.html`: `fetch('/api/xhr-only.json')` (blocked: XHR type) and
  `<script src="/api/xhr-only.json">` (allowed: script type);
  `fetch('http://127.0.0.2/ads/banner.js', {headers: {'X-Open-Test': '1'}})`
  (a request that would need a preflight); `new WebSocket('ws://127.0.0.2/ws')`
  (blocked) and `new WebSocket('ws://127.0.0.1/ws')` (allowed; fails
  at the server); `fetch('/api/data.json?' + 'a'.repeat(2 * 1024 * 1024))`
  (long URL; as built `2 * 1024 * 1024 - 64` characters, because a URL
  over `url::kMaxURLChars` (2 MiB) never leaves the renderer);
  `<script src="/redirect?to=http://127.0.0.2/ads/redirect-target.js">`.
- `blocked-main.html`: a plain page; the `$document` rule must not block it.
- `early-hints.html` (N-21): `<script src="/ads/banner.js">`; the throwaway
  server sends it with a `103 Early Hints` response first (Python's
  `BaseHTTPRequestHandler.send_response(103)` + `Link` header +
  `end_headers()`, then the `200`). Chromium accepts early hints over
  HTTP/1.1 only with `EnableEarlyHintsOnHttp11` (`net/base/features.cc:433`,
  off by default), so N-21 runs with that feature on.
- `excluded-start.html` (N-20): a page with a button-free script that
  fetches `/ads/banner.js` when CDP calls `window.__fetchBanner()`.

Server: `python3 -m http.server` cannot redirect, set headers or log
methods. Use a throwaway stdlib server `/tmp/open-adblock-server.py`
(never committed) for both origins. It serves the testdata directory,
answers `/redirect?to=<url>` with a 302, sends `103` before
`early-hints.html`, answers unknown paths with a small HTML page (for
C-G3's `www.gamedev.net`), and logs every request line
with its method, so N-14 can
assert that no `OPTIONS` reached it.

Extension fixture (N-15), throwaway under `/tmp/open-adblock-ext/`, loaded
with `--load-extension`: an MV3 extension with `webRequest` (it records
every `onBeforeRequest` URL in `chrome.storage.session`) and one
declarativeNetRequest rule that redirects `/ext-redirect.js` to
`http://127.0.0.2/ads/redirect-target.js`.

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

Network cases (Steps 4+; N-9…N-21 added 2026-10-26):

| ID | Setup | Assert |
|---|---|---|
| N-1 | test lists | `/ads/banner.js` fails with `errorText` `net::ERR_BLOCKED_BY_CLIENT`; `allowed-banner.js` succeeds; page `window.__bannerLoaded` undefined |
| N-2 | test lists | third-party `pixel.gif` (127.0.0.2) blocked; first-party `pixel.gif` succeeds (party mapping, §7.3) |
| N-3 | test lists | `important.js` blocked despite the `@@` rule (`$important`) |
| N-4 | test lists | `redir.js` completes from the stub response (no network request reaches the server log); `window.__redirLoaded == true`; count includes 1 redirected |
| N-5 | test lists | the request that reaches the server for `data.json` has `keep=1` and no `utm_source` (server log and CDP); the page saw one internal redirect |
| N-6 | `--open-adblock-exclude=127.0.0.1` | nothing blocked; counts 0; no injected sheets (also C-6) |
| N-7 | no switches | everything loads; no `OpenAdBlockSmoke` log lines |
| N-8 | list dir removed/empty | page loads fully; status `engine_loaded=0`; no crash (cold-start allow, §10 rule 1) |
| N-9 | `worker.html` | the dedicated worker's `/ads/worker-ad.js` fetch fails, its `/api/data.json` succeeds; the service worker's `/ads/sw-ad.js` fetch fails (outcome read from Cache Storage over CDP) |
| N-10 | `frames.html` | the `127.0.0.2/frame-ad.html` iframe fails with `ERR_BLOCKED_BY_CLIENT`; in `csp-frame.html`, `window.__cspInlineRan` is undefined (list CSP applied, F-26) |
| N-11 | `fetch.html` | the `/redirect?to=…/redirect-target.js` script: the server logs the 302, and the target never reaches the 127.0.0.2 server log (redirect re-check, §7.5) |
| N-12 | `fetch.html` | `fetch('/api/xhr-only.json')` blocked; `<script src="/api/xhr-only.json">` loads (`is_fetch_like_api` → XHR, §7.3) |
| N-13 | navigate the main frame to `blocked-main.html` | the page loads; the `$document` rule never blocks a main frame |
| N-14 | `fetch.html` | the preflighted cross-origin fetch fails; the 127.0.0.2 server log has **no** `OPTIONS` line (§7.5) |
| N-15 | extension fixture loaded | `/ads/banner.js` is blocked and absent from the extension's `onBeforeRequest` record (Open is outermost, §7.9); `/ext-redirect.js` is redirected by the extension and the redirect target is blocked by Open; an allowed request appears in the record |
| N-16 | `--use-alloy-style` | N-1 and C-1 pass in an Alloy-style browser (F-36) |
| N-17 | `fetch.html` sockets and long URL | the 127.0.0.2 WebSocket logs one block at `--v=1` and adds 1 to the count; the 127.0.0.1 one logs no block; the 2 MiB fetch adds 1 to `checks_truncated`, and no check took > 1 ms (G-3) |
| N-18 | WebTransport | **Hook reachability only; error-object correctness unverified** (review r1 finding 15), unless the PR stands up a local HTTP/3 endpoint (then also assert the page's `WebTransport.ready` rejects and the endpoint saw no session). Default check: `new WebTransport('https://127.0.0.2/wt-blocked')` on a test rule `\|\|127.0.0.2/wt-blocked` logs one block at `--v=1` (as built; a port-anchored rule never matches in the crate, §13.2). The PR template carries the bold label |
| N-19 | Step 7+: `redirect-list.txt` generation, second run (DAT load) | status `engine_from_dat=1 resources_loaded ≥ 1`; `redir.js` completes from the `noop.js` stub and `window.__redirLoaded == true` (resources re-applied after deserialize, review 98-4) |
| N-20 | Step 6+: mid-page exclusion through the CEF API (review r1 finding 15) | (1) Load `index.html`, not excluded: `fetch('/ads/banner.js')` from the page is blocked. (2) Add `127.0.0.1` with `SetOpenAdBlockExcludedDomains`; fetch again from the same page: it loads (the proxied factory re-checks per request, §7.4 rule 1). (3) Remove the exclusion; fetch again from the same page: blocked (same proxied factory). (4) Add the exclusion, navigate to `excluded-start.html` (initially unproxied, §7.2 rule 2), remove the exclusion, call `window.__fetchBanner()`: blocked, because the API resets loaded storage-partition factories. (5) Reload: blocked |
| N-21 | `early-hints.html` after a page on the excluded `127.0.0.2` (`--open-adblock-exclude=127.0.0.2`, `--enable-features=EnableEarlyHintsOnHttp11`, `net/base/features.cc:433`) | The server answers `early-hints.html` with `103` and `Link: </ads/banner.js>; rel=preload; as=script`, then `200`. The page's own `<script src="/ads/banner.js">` fails with `net::ERR_BLOCKED_BY_CLIENT` (its factory's top site is the new page, not the excluded previous one, §7.2). The PR records whether the server log shows the preload `GET /ads/banner.js` (expected: yes; known gap R-14, preloads never reach the hook). **Validity (review r2 N-4):** the CDP log must show `Network.responseReceivedEarlyHints` for `early-hints.html` with the `/ads/banner.js` preload (the same check as the §7.8 capture control). Without that event N-21 is **invalid**, not passed, because the `103` path never ran |

Cosmetic cases (Step 5+; revised 2026-10-26):

| ID | Page | Assert (via `Runtime.evaluate` `getComputedStyle`) |
|---|---|---|
| C-1 | `index.html` | `.ad-slot` display `none`; no `<style>` element was added by Open |
| C-2 | `index.html` | `.ad-slot-allowed` display not `none` |
| C-3 | `generichide.html` | `.generic-ad` visible; `.ad-slot` hidden; no `GetGenericSelectors` call in the `--v=1` log |
| C-4 | `index.html` at +2 s | late `.late-ad.generic-ad` node display `none` (token round-trip) |
| C-5 | `index.html` | v1 runs no scriptlet: `window.__openTestScriptlet` is undefined and status `cosmetic_dropped_scriptlet ≥ 1` (lead ruling 6) |
| C-6 | excluded (N-6 run) | `.ad-slot` visible; the sync call returned null (`--v=1`) |
| C-7 | `frames.html` | 98-1: `.ad-slot` hidden although the page's rules include a `:has-text()` selector; `.proc-ad` visible (procedural dropped). Lead ruling 6: `.style-target` has no red outline and `.remove-me` is still in the DOM after `DOMContentLoaded`. 98-2: `.style-evil` and `.exfil` have no background image and the 127.0.0.2 server log has no `beacon.gif` or `exfil.gif`. Status: `cosmetic_dropped_procedural ≥ 1`, `cosmetic_dropped_unsafe ≥ 1`, `cosmetic_dropped_style ≥ 2`, `cosmetic_dropped_remove ≥ 1` |
| C-8 | `index.html` | `document.styleSheets.length` equals the page's own count; a page script that sets `.ad-slot { display: block !important }` cannot show `.ad-slot` (user-origin `!important` wins) |
| C-9 | — | Moved to post-v1 with scriptlets (lead ruling 6, §8.5). The ID stays reserved |
| C-10 | `index.html` | no own property of `window` whose name starts with `__openAdBlock` |

Count cases: after `index.html` load, read the harness's
`OpenAdBlockSmoke` stderr line: `blocked_count` equals blocked +
redirected from N-1…N-4 (compute the expected integer from the rules
at Step 4 and hard-code it in the driver with a comment showing the
sum). Reload via CDP: count resets and re-accumulates to the same
value. `history.pushState` + a manual fetch of `banner.js`: count
increments, no reset.

The closed-document row uses a real top-level pagehide handler and native
document IDs. Matched keepalive URLs must add three to the old count and
reach the server zero times; unmatched control URLs must leave that count
unchanged and complete three server GETs. The new count stays zero at
commit, load and the late reading. The allowed and wrong-document negative
controls must fail the positive predicate. See "COUNT-closed-document
erratum" in "Step 4 as built" for the exact witnesses and the unusable
outgoing unload CDP predicate.

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
| Page overhead | Revised 2026-10-26: gate G-5 (§7.8) on `corpus.html?sample=0`, exactly 200 real corpus URLs (review r1 finding 4), replacing the short-path `many.html` | blocking on faster than off; busy thread CPU ≤ 9 ms per 200-request load, off the UI thread; quiet load1 ≤ 12 (§13.5.1 item 2a) |
| Request checks | gates G-1…G-4, G-6, G-7 (§7.8) | as stated there |
| Cosmetic query | time 100 cosmetic queries on the matcher sequence in the selftest on the real lists and print the mean; plus the renderer-side sync call (C-G1, C-G2) | ≤ 100 µs/page query (as built: 77–79 µs; hide selectors are always sorted in the shim, and that sort is inside the measured cost); C-G1/C-G2 as in §11 Step 5 |
| Memory | §6.6 budgets: one engine, a second Profile with the same lists, text-build transient | as in §6.6 |
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

#### 13.5.1 Lead rulings on the Step 4 FAIL rows (2026-11-07 15:10)

Made by the lead on the user's go-ahead ("go with recommended steps").
Nobody raised a budget before these rulings; each one names the new
budget and what must be tried first. They replace the matching rows of
§6.6, §7.8 and §13.4.

1. **G-2 max.** The slowest check took 178–370 µs of thread CPU time;
   the 1.1–1.2 ms maxima were wall time spent waiting for a core at
   load 12–24. The G-2 max gate now counts **thread CPU time, ≤ 500 µs
   per check**. Every run still records the wall max, and the Step 9
   quiet run must show a wall max **≤ 2 ms at load1 ≤ 4**.
2. **G-5 busy** (9 ms thread CPU per 200-request load against 3 ms).
   Optimize first: cut the client-callback and `GURL`-rebuild costs
   (4.9 + 1.4 ms of the profile; batch or avoid copies) and keep the
   crate check. New budget: **≤ 5 ms thread CPU per 200-request load**,
   measured off the UI thread. If 5 ms is not reachable after a real
   attempt, the breakdown goes to the lead; the section does not raise
   the budget itself. G-5 wall already passes.

2a. **G-5 ruling (2026-11-07 20:58, lead):** accepted for v1 at
≤ 9 ms busy thread CPU per 200-request load, off the UI thread; G-5 wall
(blocking on faster than off) is a hard gate. The final number comes from
a quiet run (load1 ≤ 12); the remaining cost is the proxy's Mojo decode and
re-issue (~3.3 ms), client callbacks (~2.5 ms) and the crate check (~2.3 ms);
a throttle-based interception for allowed subresources is post-v1.

3. **G-6** (first-use regex compiles up to 15 ms). Compile or warm every
   regex filter in the background engine build, before the new engine is
   swapped in, so that no compile runs on the request path. The gate
   stays as written.
4. **Footprint** (+62–70 MiB against 40 MiB). Optimize first: one engine
   shared by all Profiles (lead ruling 8), no resident copy of list text
   or resources after the build, the 97-2 domain resolver (drops about
   825 KiB of crate data), and DAT against text measured both ways. New
   budget: **≤ 50 MiB**, stretch 40 MiB. If still above, the breakdown
   (vmmap tag 14, PartitionAlloc) goes to the lead.

4a. **Footprint ruling (2026-11-07 20:40, lead):** accepted for v1 at
≤ 57 MiB steady state (text and DAT, median of 5) and ≤ 60 MiB after the
full-corpus check plus one idle purge; the 50 MiB budget is replaced; the
remaining cost is the crate's own rule data and indexes (~37 MiB allocated),
whose restructuring is post-v1.

The purge is idle-triggered and rate-limited, on the matcher sequence;
it never runs per request or on the request path. One idle period causes
one purge, with no timer loop after it. Record the allocated breakdown,
prove G-2/G-4 unchanged, and observe 60 seconds without activity to show
zero extra purges after the first.

---

## 14. Risks and open questions

| # | Risk / question | Plan's handling |
|---|---|---|
| R-1 | `adblock 0.8.11` fails under Chromium `rustc 1.100.0` (toolchain fragility already bit once, F-13/F-15) | Step 1 gate: stop, report verbatim, lead decides (crate bump reopens the design benchmark; D1 `subresource_filter` fallback in adblock-design stays the escape hatch) |
| R-2 | MPL-2.0 (crate) + GPL-3.0 (uBO resources) distribution obligations | Pins + `THIRD_PARTY.md` + license files land with the code (§4.5, §9.3); counsel review gates public release only (fork-infra Q-2) |
| R-3 | GN include-path / visibility friction between `//open/adblock` and `libcef_static` (§6.5) | Two sanctioned forms (seam function in P-4, or direct call); pick at Step 5, record it; never a link cycle |
| R-4 | Cosmetic payload arrives after the document starts | Revised 2026-10-26: resolved by the renderer pull at `DidCreateDocumentElement` (§8.2). BFCache restores keep their sheets; same-document navigations keep them |
| R-5 | `fetch()`/XHR type loss (`kEmpty` → `"other"`) weakens `$xmlhttprequest` rules | Revised 2026-10-26: resolved with `is_fetch_like_api` (F-25, §7.3, N-12) |
| R-6 | Revised 2026-10-26: v1 runs no scriptlets (lead ruling 6), so ads that only a scriptlet can stop are not blocked (guess: some in-video ads served from the site's own host). Scriptlet staleness is a post-v1 risk (§8.5) | Documented in §8.4; per-site toggle is the user escape for breakage; **no** shipped pre-emptive allowlist (adblock-design Risk 4 — Arc's YouTube entry is for uBlock, not proven for this engine) |
| R-7 | Full 46-list memory: two lists = 6.78 MiB DAT; regional sets grow it | v1 defaults stay at two lists; Step 9 records DAT size + browser RSS with all generic+privacy lists enabled before any regional default is considered. 2026-10-26: shared engines and caps (§6.6) bound the per-Profile part |
| R-8 | Head-of-line blocking on the one matcher sequence (a regex compile, a long URL) delays every request in the process | Input cap (§7.7); regex features (97-1); G-6 counts stalls; remedy is a longer regex discard time, never a second matcher sequence (the crate mutex serializes anyway, F-30) |
| R-9 | The sync cosmetics call adds latency to every http(s) document, also with blocking off, and waits behind queued network checks (review r1 finding 3) | Contended C-G1/C-G2 gates (§11 Step 5); C-G2 is contended by injected bench load, because off factories queue no checks and `cefsimple` has one request context (review r2 N-1); expected wait bounded in §7.6; named escalation: the priority lane (§7.6, lane rules 1–3); then, for C-G2, the no-wait fallback (lead ruling 5): no cosmetic hiding for that load, never a blocked renderer (§8.2). At Step 5 the real cross-Profile wait (an off-Profile document behind another Profile's checks) is bounded only by §7.6; it is measured again at Step 8 with two request contexts (§11 Step 8) |
| R-10 | Open's proxy is outermost, so extension blockers and DNR "allow" rules cannot see or unblock what Open blocks | Intended (§7.9, same as Brave, F-33); the per-site toggle is the override. Lead may revisit if an extension's documented feature breaks |
| R-11 | Sanitizer drops valid list rules (long selectors, unbalanced-looking escapes); v1 also drops all `:style()`, `:remove*()` and scriptlet rules by design | Counted in status (`cosmetic_dropped_*`); Step 5 reports the counts on 20 corpus pages; loosen a rule only with a new review of 98-2 |
| R-12 | P-3 hunk position in CEF's `WillCreateURLLoaderFactory` moves on a CEF bump | Rebase note (§11 Step 9): the Open call stays first in the CEF branch; N-15 proves the order after every rebase |
| R-13 | Worker WebSockets and frameless sockets are not checked | Known v1 gap (§7.2); Brave needed a content patch for it (F-33) |
| R-14 | Early-hints (`103`) preloads never reach `WillCreateURLLoaderFactory` (§7.2, F-22), so a preload of a blocked URL still goes to the network before the page commits (review r1 finding 6) | **Accepted gap for v1 (lead ruling, 2026-10-26).** Reason: the fix costs one extra hop on every main-frame load, while the leak is only the network fetch. The page's own request for the preloaded URL is still checked and blocked (N-21), so the page never loads the preloaded response as a page resource. The preload fetch itself is not blocked: `NavigationEarlyHintsManager` fetches it through the same unhooked factory (`content/browser/loader/navigation_early_hints_manager.cc:405-462`), so it reaches the network with the user's cookies and may fill the HTTP cache. That fetch is the accepted leak, and N-21 records it (review r2 wording note). Post-v1 fix (not built in v1): wrap main-frame navigation factories as well, only to drop blocked `Link: rel=preload` entries in `OnReceiveEarlyHints` (`navigation_url_loader_impl.cc:1390-1432`). Chromium has no switch that turns early-hints preloads off (only `EnableEarlyHintsOnHttp11`, `net/base/features.cc:433`). Measured: the Step 4 corpus capture counts blocked 103-preload URLs (§7.8), with a local positive control that makes a broken CDP pipeline an invalid capture, never a zero. **Trigger (page count, review r2 N-4):** if **2 or more** corpus pages each have at least one blocked 103 preload, the wrap goes back to the lead before Step 8; the share is reported too. Tracked in `docs/followups.md` |
| Q-1 | Does the app milestone want `OpenFeatures` created by Step 8 or later? | Step 8 decides by target existence (§11 Step 8); the §12.3 contract is normative either way |
| Q-2 | Exact uBO resources input format for crate 0.8.11's assembler | Resolved: the offline driver calls `assemble_web_accessible_resources` with a directory and an index file (§9.3); the browser reads only `resources.json`, so no reserved name changes (review r2 N-10) |
| Q-3 | Arc's factory default (on/off), exact scope-dialog labels, update interval | Unproven Arc facts (AD-6/§7.4 of features-advanced). Open's choices (on, "this site" default, 24 h) are product decisions recorded in §9.5/§12.2; the lead may revisit after runtime observation of Arc per AGENTS.md RE rules |

2026-10-26: Q-2 is answered (resources cross as the crate's JSON,
`resources.json`, §9.3). R-3 no longer applies to cosmetics: no cosmetic
sender is in a CEF patch, and the renderer agent is an overlay
`RenderFrameObserver` (§8.3).

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

# Serve the test site (two origins; as built at Step 4: one throwaway
# stdlib server on two ephemeral ports, §13.2), then map the hosts to them
python3 /tmp/open-adblock/server.py Engine/fork/src/open/adblock/testdata /tmp/server.log
#   prints {"ports": [<first>, <third>]}

# Smoke run (OUT = fork-infra dev out dir); copy the fixture root first,
# because a run writes engine.dat into it
OUT=~/Developer/open-engine/chromium_git/chromium/src/out/Release_GN_arm64
cp -R Engine/fork/src/open/adblock/testdata/adblock-root /tmp/open-adblock-root
"$OUT/cefsimple.app/Contents/MacOS/cefsimple" --use-mock-keychain \
  --user-data-dir=/tmp/open-adblock-smoke --open-adblock-dir=/tmp/open-adblock-root \
  --host-resolver-rules="MAP 127.0.0.1 127.0.0.1:<first>, MAP 127.0.0.2 127.0.0.1:<third>" \
  --remote-debugging-port=0 --enable-logging=stderr --vmodule='open_adblock*=1' \
  --url=http://127.0.0.1/index.html
python3 /tmp/open-adblock/check.py   # §13.3 driver (throwaway, in /tmp)
```

## Appendix B. Evidence map (spot-check before implementing)

| Claim in this plan | Source to re-read |
|---|---|
| Throttle override point (F-1, F-2, F-16; superseded) | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.{h,cc}`; `content/public/browser/content_browser_client.h:1733-1756` |
| Factory proxy hook and chain order (F-17…F-22, §7.1–§7.2) | `content_browser_client.h:1843-1993`; `url_loader_factory_builder.h:21-53`; `chrome_content_browser_client_cef.cc:482-572`; `chrome_content_browser_client.cc:6794-6886`; `url_loader_factory_utils.cc:245-267` |
| Sockets (F-23, F-24) | `websocket_connector_impl.cc:146-150`; `web_transport_connector_impl.cc:297-301`; `chrome_content_browser_client.cc:6960-7055` |
| Cosmetic timing and insertion (F-27…F-29, §8) | `cef/libcef/renderer/frame_impl.cc:328-335,521`; `frame_host_impl.cc:644-651,695-718`; `browser_manager.cc:21-33`; `script_injection_manager.cc:142-146`; `style_engine.cc:327-341` |
| Crate mutex, DAT loss, scriptlet escaping (F-30…F-32) | `adblock-0.8.11/src/{blocker.rs,engine.rs,regex_manager.rs,data_format/v0.rs,resources/resource_storage.rs}` |
| Measured cost (F-35) | `.re/reviews/adblock-97-98-100-r1.md` (git-ignored) |
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

### Lead decisions (2026-10-26): design revision after engine review round 1

Status: **approved by the lead on 2026-10-26, with the eight rulings
below.** The step text in this file already follows the rulings. Inputs:
engine review round 1 (`.re/reviews/adblock-97-98-100-r1.md`,
git-ignored), a read-only pass over the shared tree with #93 and ad-block
Steps 1–3 applied, the adblock 0.8.11 source, Brave's public source (facts
only, F-33), and ArcCore strings (F-34, `.re/adblock-plan-r2/`). Steps 1–3
(#97, #98, #100) are not changed here; the engine lead fixes them. This
entry only adds entry gates.

**Lead rulings (2026-10-26)** on the items the design agent asked the lead
to confirm:

| # | Ruling | Where the step text changed |
|---|---|---|
| 1 | **Confirmed:** Open runs before extensions. Extensions never see or unblock what Open blocks. Also documented in the user-facing behavior notes | §7.9; §8.4 (new user-facing notes); §12.2 |
| 2 | **Input cap 16 KiB**, not 8 KiB, cut at a separator. Step 4 measures G-1…G-3 at both 8 and 16 KiB on the real ad-URL corpus. 16 KiB stays unless a gate fails there; if one fails, the cap falls back to 8 KiB and the PR records the numbers | D-17; §5.5; §7.7; §7.8; Step 4 |
| 3 | **Confirmed:** review 97-1 (regex perf features except `perf-literal`). It is in the engine lead's queue; Step 4 depends on it | §7.6; Step 4 entry gate |
| 4 | **Confirmed:** no `$removeparam` on navigations in v1 | §0.2; §7.4 rule 4 |
| 5 | **Confirmed:** one sync call per web page at document start, gated by C-G1 and C-G2. If C-G2 fails, the fallback is a page without cosmetic hiding for that load, never a blocked renderer | §8.2 (no-block rules); Step 5; R-9 |
| 6 | **Not in v1:** scriptlets. v1 is network blocking plus plain CSS hiding, both specific and generic, including the class/ID observer in an isolated world. Procedural filters are dropped. `:style()` is also dropped. Scriptlets, `:style()` and procedural filters move to a post-v1 section with their design | §0.1; §0.2; D-14; §5.5; §8 (rewritten); §8.5 (post-v1); §9.2.1; §10; Steps 5 and 7; §13; R-6, R-11 |
| 7 | **Confirmed:** resources change only with an app update. Without scriptlets, resources serve only `$redirect`. The manifest change stays in Step 7 | D-15; §9.3; Step 7 |
| 8 | **Confirmed:** Profiles share identical engines. The timing side-channel note stays | §6.6 |

Design-agent notes on applying the rulings (for the lead to correct if
they read the rulings differently):

- Ruling 6 names scriptlets, `:style()` and procedural filters. The uBO
  `:remove()`, `:remove-attr()` and `:remove-class()` actions are not
  plain CSS hiding either, so v1 drops them too, and §8.5 keeps their
  design. A consequence: in v1 only `$removeparam` makes a list set lossy
  for the DAT (§9.2.1).
- Ruling 7: v1's `resources.json` keeps only redirect-capable resources
  and leaves out scriptlet templates, so no scriptlet code ships (§9.3).
- Ruling 2: the G-2 and G-3 thresholds stay as written (≤ 1 ms per check)
  at both caps. F-35 suggests that a 16 KiB check may come close to 1 ms,
  so the 8 KiB fallback may be needed (§7.8).
- The isolated world stays `ISOLATED_WORLD_ID_CHROME_INTERNAL` until P7
  gives Open its own (not separately ruled).

What changed, and why:

1. **Network hook (C-1).** Matching moves from a `URLLoaderThrottle` to
   Open's own URLLoaderFactory proxy, appended first in CEF's
   `WillCreateURLLoaderFactory` (D-11, §7.1–§7.5). The throttle hook sees
   only browser-initiated requests (F-16). CEF's own proxy was rejected:
   IO thread, CEF-owned CORS emulation, and it sits after WebRequest
   (F-19, F-20). P-3 becomes about +45 lines in two files.
2. **Order with extensions.** Open's proxy wraps WebRequest's: Open sees a
   request first, extensions never see what Open blocks, and Open
   re-checks redirects that extensions make (§7.9). Brave uses the same
   order (F-33). Ruling 1.
3. **Thread model (C-2).** One process-wide matcher sequence runs every
   engine call except builds. The proxy is bound on it and matches inline:
   no UI or IO thread work, no PostTask round trip per request (D-12,
   §7.6). The crate's per-engine mutex (F-30) is then never contended.
4. **Input cap (C-2).** The shim matches at most the first 16 KiB of a
   URL, cut at a separator; no `$removeparam` on a capped URL; the 8 KiB
   fallback is measured (D-17, §7.7). Ruling 2.
5. **Perf gate.** Step 4 must pass G-1…G-7 on a real-URL corpus (§7.8),
   which replaces the short-path `many.html` check. The numbers assume
   review 97-1. Ruling 3.
6. **Request types.** `is_fetch_like_api` → XHR and keepalive → ping, as
   WebRequest maps them (F-25). R-5 is closed.
7. **Sockets.** WebSocket (frames only) and WebTransport hooks (§7.1).
   Worker sockets are a known gap (R-13).
8. **`$redirect` and `$removeparam`.** A redirect match is served as a stub
   response for no-CORS and same-origin requests of any type; CORS-mode
   requests are blocked instead. A rewrite is a synthetic 307 for
   subresource GET/HEAD only, never on a redirect hop or a navigation
   (§7.4). Ruling 4.
9. **Cosmetic delivery.** The renderer pulls its payload with one sync call
   at `DidCreateDocumentElement` on a new process-level interface,
   `open_engine.mojom.AdBlockCosmetics`, bound on the matcher sequence
   (D-13, §8.2). The `cef.mojom` push could not arrive in time (F-27).
   This reverses D-6 and §0.2's "no Mojo interface of our own". The
   renderer never blocks on anything else; if C-G2 fails, a load whose
   reply is late gets no cosmetic hiding. Ruling 5.
10. **Cosmetic payload (98-1, 98-2).** Sanitized hide-selector vectors, one
    rule per selector, inserted as user-origin sheets with
    `InsertStyleSheet(kUser)`; the class/ID observer in an isolated world.
    Procedural filters, `:style()`, `:remove*()` and scriptlets are
    dropped and counted in v1 (D-14, §8.3); their design is in §8.5.
    Ruling 6.
11. **DAT reuse (98-4, 100-1).** A DAT is written and reused only for a
    lossless list set, with `engineFormat` and the resources hash in the
    receipt; resources are applied after every deserialize (D-15, §9.2.1).
12. **Resources.** `resources.json` is built offline, pinned, bundled, and a
    manifest input of every generation; no runtime download; in v1 it
    serves only `$redirect` (§9.3). This changes §9.3 and §9.5 of
    2026-10-25 and needs a Swift manifest change at Step 7. Ruling 7.
13. **Memory (100-5, 100-2).** Profiles with identical verified inputs share
    one engine (content-hash key); every engine is freed on the build
    runner; one build at a time per process; 128 MiB input cap; budgets in
    §6.6. Ruling 8.
14. **Service contract at Step 4** (§6.7): matcher state as a
    `RefCountedThreadSafe` object (100-8), Swift's exclusion rule (100-4),
    `nullptr` after shutdown (100-6), switches out of official builds (100-3).
15. **Plan errors fixed.** The 2026-10-25 §8.4 used
    `NavigationThrottle::ReadyToCommitNavigation`, which does not exist
    (F-27). The old CSP edit in a throttle would never reach the CSP parser
    (F-26). The old note that Alloy pages get no hooks is wrong for branch
    8078 (F-36). The old CDP "reason string" check cannot work, because
    completion carries only an error code (§7.4).
16. **Entry gates.** Step 4: #97/#98/#100 merged with the listed review
    fixes (including 97-1) and the §5.5 Step 4 rows. Step 5: the sanitized
    cosmetic vectors (98-1, 98-2). Step 7: resources after deserialize
    (98-4).
17. **User-facing behavior notes** (§8.4, new): blocker before extensions,
    extension traffic untouched, what v1 hides and does not, main page
    never blocked, hiding skipped rather than a waiting page, per-Profile
    state.

Not changed: the crate and its version, the engine in the browser
process, the list catalog, the generation contract of §9.2, the CEF API
shape (only new status keys), and the Swift store contract.

### Review r1 changes (2026-10-26): plan review of PR #105 at `908be96`

The plan review (`.re/reviews/pr105-adblock-plan-r1.md`, git-ignored)
gave **APPROVE AFTER CHANGES** with 16 findings and no architecture
change. The lead ruled where the review left a choice. Every finding is
fixed in the text:

| # | Finding | Fix (lead ruling where one applies) | Where |
|---|---|---|---|
| 1 | One cosmetics pipe per render process assumed one Profile per process | **Proved** with `file:line`: a render process keeps one `BrowserContext` for life and is reused only for the same one; CEF maps one `BrowserContext` to one `CefBrowserContext`. The per-call frame-token fallback is named in case a later tree breaks it. Two-context acceptance at Step 8 (`cefsimple` has one context) | §8.2 "Why one pipe…"; Step 8 |
| 2 | The isolated-world binding might not exist when the observer runs | Ruled mechanism: the agent forces the context with `GetScriptContextFromWorldId`, installs `__openAdBlock` in its own `DidCreateScriptContext` (or into an existing context), and only then runs the observer. Ordering check in Step 5 | §8.1; §8.3 "Install before execute"; Step 5 |
| 3 | The sync cosmetic call waits behind every network check; gates measured the idle case | Contended gates (three corpus pages at once, 100 measured documents). Expected wait bounded with the cap and a 10 ms compile budget. Escalation named now: a priority lane (two queues drained by one sequence on one thread) | §7.6 "Cosmetic calls in the queue"; §8.2 rules 2–5; Step 5; R-9 |
| 4 | G-5 inconsistent (2,000 vs 200 URLs); corpus not reproducible | Exactly 200 deterministically sampled URLs per `corpus.html` run, everywhere. Committed manifest (count, length percentiles, third-party share, SHA-256 of the sorted file and of each sample), never the URLs. Capture procedure written | §7.8 "Corpus"; G-4, G-5; §13.4; §3.1; Step 4 |
| 5 | `factory_override` path not discussed | Paragraph with evidence: navigations pass `factory_override = nullptr`, so CEF takes its pass-through `Append()` branch and Open stays outermost; the override is an inner network-service layer. N-10 is an early Step 4 spike. Alternative hook named now (a navigation-only `URLLoaderThrottle`) | §7.1 "`factory_override` and the builder chain"; Step 4 Work 1 |
| 6 | Top site for early hints and service workers | Service workers: proved from the storage key (not a guess). Early hints: found that they **never reach the hook** in this tree; ruled rule recorded (target origin, if they ever do). 103-preload case N-21 added; gap R-14 with a named remedy | §7.2 table and top-site bullets; N-21; R-14 |
| 7 | §5.5 shim rows had no owner | Every row names its owner PR (default: the step that first needs it, whose Work list now includes `lib.rs`) | §5.5; Steps 4, 5, 7 |
| 8 | Superseded surfaces still fully specified | One final bridge surface (§5.2) and final service/matcher shapes (§6.3) and BUILD list (§6.5); tombstones where the old designs stood (D-2, R-5, R-7, R-8, §6.3, §6.3.1, §6.5) | §5.2; §5.3; §6.3; §6.5; D-2 |
| 9 | Two-Profile memory gate not runnable in `cefsimple` | Moved to Step 8; single-engine footprint stays in Step 4 | §6.6 budgets; Steps 4 and 8 |
| 10 | Shared isolated world not assessed | Documentation only (ruling): co-tenants named with `file:line`, trust boundary and concrete harm stated, task kept to allocate an Open world ID | §8.3 "Co-tenants of the shared world" |
| 11 | Shutdown ordering unspecified | Shutdown paragraph (dropped tasks, null-checked failed sync call, best-effort engine delete); quit-during-load check in Step 5 | §7.6 "Shutdown"; §8.2 rule 1; Step 5 |
| 12 | Gate mechanics | G-6 logs length and duration only (no "cause"); G-4 uses one process-wide histogram; C-G1/C-G2 use 100 documents and report the first call per process apart; C-G3 states its offline payload construction | §7.8 G-4, G-6; Step 5 |
| 13 | WebSocket fallback call underspecified | Argument-for-argument call against content's own path; who supplies `header_client`; DevTools-header loss recorded as an accepted, untested difference | §7.1 hook 3 |
| 14 | 256 KiB cap had no owner; renderer rule count unbounded | Owner: the shim, unit: selector bytes, counted in `dropped_over_cap`; worst-case renderer payload recorded at Step 5 | §5.2; §8.3; §6.6; Step 5 |
| 15 | Mid-page exclusion untested; N-18 could pass untested | N-20 (mid-page exclusion through the CEF API, Step 6); N-18 labeled "hook reachability only; error-object correctness unverified" unless a local HTTP/3 endpoint is stood up | §13.3 N-18, N-20; Steps 4 and 6 |
| 16 | Citation drift in F-22 | Full paths; the two missing service-worker call sites added; early hints marked as not reaching the hook | F-22 |

**Lead ruling on R-14 (2026-10-26).** Accept the early-hints gap for v1;
do not build the main-frame factory wrap. Reason: the wrap adds a hop to
every main-frame load, and the leak is only the network fetch, because
the page's own request for the preloaded URL is still blocked (N-21). The
gap is measured: the Step 4 corpus capture records every `103`
`Link: rel=preload` URL and counts those the staged lists block, and the
committed manifest carries the count and the number of affected pages
(§7.8). Trigger: blocked 103-preload URLs on 2 % or more of corpus pages
send the wrap back to the lead before Step 8. Where: R-14; §7.8 capture
steps 4 and 6, manifest, trigger; Step 4 acceptance; `docs/followups.md`.
Restated in review r2 (lead ruling): the trigger is a page count, 2 or
more corpus pages with a blocked 103 preload, because 2 % of a
20–49-page corpus is less than one page; the share is still reported.

New facts this round (read-only, same tree): early hints build their
factory without `ContentClientParams` and exist only for outermost main
frames (§7.2); content passes the service worker's storage key as
initiator and isolation info (§7.2); `GetScriptContextFromWorldId` forces
isolated-context creation and `DidCreateScriptContext` runs synchronously
(§8.3); navigation factories pass `factory_override = nullptr` (§7.1); a
render process keeps one `BrowserContext` (§8.2).

### Review r2 changes (2026-10-26): plan re-check of PR #105 at `056b5bf`

The re-check (`.re/reviews/pr105-adblock-plan-r2.md`, git-ignored) gave
**APPROVE AFTER CHANGES**: 5 required changes and recommended ones
(N-1…N-10), no architecture change. The lead chose where the review
left options. Every item is fixed in the text:

| # | Finding | Fix (lead ruling where one applies) | Where |
|---|---|---|---|
| N-1 (required 2) | C-G2 with blocking off had nothing to contend with | **Injected bench load** (lead): `--open-adblock-bench-load` posts synthetic checks, one task each, to the matcher's normal runner at R = 600 / T (three concurrent 200-request loads per median load time), while `--open-adblock-off` keeps the measured context off. The real cross-Profile wait is measured again at Step 8 | §8.2 rule 2; §11 Step 5 C-G2; §13.1; §11 Step 8; R-9 |
| N-2 (required 1) | A first regex compile could fail G-2's `max ≤ 1 ms` at both caps and force the 8 KiB fallback | Repetition 1 is warm-up, left out of mean, p99 and max; its max is printed apart (lead). G-3 follows the same rule. G-5: the five loads of each condition share one process, which is how the harness runs; load 1 is warm-up and reported apart. G-4 keeps load 1, with the reason | §7.7; §7.8 G-2…G-5; §13.1; Step 4 |
| N-3 (required 5) | The priority lane was named but not buildable without design work | Lane rules 1–3: thread checkers in lane mode; two named runner accessors from Step 4 on (cosmetics and state updates on the high queue; factories, sockets, histogram and bench on the normal queue); stop in a new `ChromeBrowserMainExtraPartsCef::PostDestroyThreads()`, after Profile teardown and ThreadPool shutdown. The lane meets C-G1's p99 only under G-6's stall rate. The lane stays the named escalation (lead) | §7.6; §6.7; §3.3 P-3; §7.8 G-1; Step 4 Work 3; Step 5 |
| N-4 (required 3) | The 2 % trigger fired on one page, and a zero could come from a broken pipeline | Trigger is a **page count**: 2 or more pages with a blocked 103 preload; share reported (lead). The N-21 server is a positive control in the capture: no control event means an invalid capture (lead). New fact: `EnableEarlyHintsOnHttp11` affects every HTTP/1.1 connection (`net/http/http_network_transaction.cc:130-142`), so HTTP/1.1 `103`s are dropped from the counts (`http11_hints_dropped`). N-21 is invalid without its own event | §7.8 step 4, manifest, trigger; Step 4 acceptance; N-21; R-14; Appendix R-14 ruling; `docs/followups.md` |
| N-5 (required 4) | Step 4/5/7 entry gates contradicted §5.5 ownership | Each step lands its own §5.5 rows unless the #98 or #100 fix PR already did; its acceptance verifies; the entry gate keeps only real preconditions (lead). `lib.rs` added to Step 7's PR line | §11 Steps 4, 5, 7 |
| N-6 | Binding lifecycle around a pre-created isolated context | Idempotent install; the flag follows the installed context (cleared in `WillReleaseScriptContext`); the payload is cleared in `DidCreateNewDocument` and read lazily through a `WeakPtr` | §8.3 "Binding lifecycle" |
| N-7 | The 45,000-rule worst case was not the worst case | Upper bound about 163,000 rules (shortest selectors); note on distinct selectors and on generic bytes; the Step 5 fill uses the shortest distinct selectors | §6.6; §8.3 insertion 2; Step 5 |
| N-8 | The +2 MiB gate had no window | Baseline after both contexts exist; the delta runs from the second context's `LoadFromDirectory` to `engine_shared=1` | §6.6; Step 8 |
| N-9 | Socket frame lifetime, G-4 print site, two batch caps | `GlobalRenderFrameHostId` captured and re-looked-up with `RenderFrameHost::FromID`, dropped if gone; G-4 prints from `OpenAdBlockService::Shutdown()`; one limit of 500 tokens in total | §7.1 hook 3; §7.8 G-4; §8.2; §8.3 |
| N-10 | Leftovers | D-2 reason updated; §9.3 pre-revision paragraphs replaced (the driver calls `assemble_web_accessible_resources`); §5.3 R-2, §13.2 fixtures and Q-2 moved to `resources.json`; `kDevTools` marked never-hooked (F-22, §7.2); the contended fallback uses three different sites; cite fixes (`render_process_host_impl.cc:1921` label, `local_window_proxy.cc` path) | D-2; §5.3; §9.3; §13.2; §14 Q-2; F-22; §7.2; §8.2; §8.3; Step 5 |
| R-14 wording | "the page never uses the preloaded response" | The page never loads it as a page resource; the preload fetch, with cookies, reaches the network and may fill the HTTP cache, and that is the accepted leak | R-14 |
| #100 R2-5 (lead, added) | `done` ran without a result | `AdBlockLoadResult` (`kLoaded`, `kFailed`, `kStale`, `kCancelled`) with one line per value; the result-form signature; `ReloadLists()` as built; §6.3.2 publish step; Step 3 self-test; §13.1 | §6.2; §6.3; §6.3.2; Step 3; §13.1 |
| Sorted selectors (lead, added) | Cost of the always-sorted hide selectors | Cosmetic query 77–79 µs as built, sort included, under the 100 µs budget | §7.6; §8.1; §8.2; Step 5 C-G1; §13.4 |
| r1 F4 nit | "never the URLs" vs the committed front-page list | "Never corpus URLs"; the `pages` list holds public front pages only | §3.1; §7.8 manifest |

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

### Step 2 as built (2026-10-26)

- **Files.** `open/adblock/rust/{BUILD.gn,src/lib.rs}` (about 250 lines) and `open/BUILD.gn` (`group("open")`). The shim's `deps`: `//third_party/rust/adblock/v0_8:lib` and `//third_party/rust/serde_json/v1:lib`. `serde_json` is already a Chromium direct dependency with no visibility limit, so the §4.2 fragment needs no line. `visibility` also lists `//open:*`, so the root group can hold the shim until Step 3 adds `//open/adblock`.
- **Include path.** The generated header is `gen/open/adblock/rust/src/lib.rs.h`. C++ includes `open/adblock/rust/src/lib.rs.h`, namespace `open_adblock` (the plan's expected spelling).
- **R-2 (resources): JSON form.** `open_adblock_build(list_texts, resources_json)` takes the crate's own serialized `Vec<Resource>`, parsed with `serde_json` (a `Result`, no new parser). The crate's assembler only reads paths, its scriptlet entry point is `#[deprecated]`, and it panics on malformed files (`resource_assembler.rs:125,168,190,248-254,271,295`). Step 7 must produce `resources.json` in that format.
- **R-3 (no panics).** Chromium builds Rust with `-Cpanic=abort` (`build/config/compiler/BUILD.gn:1035-1041`), so `catch_unwind` cannot help. The shim calls only crate functions that return a `Result` or an empty value: `Request::new`, `deserialize`, `serialize_raw`, and `url_cosmetic_resources` (which returns empty for a bad URL). A failed deserialize resets the engine to empty. Fuzzing the crate's parsers remains a follow-up.
- **R-5 (redirect).** In 0.8.11, `BlockerResult.redirect` is already a complete `data:` URL (base64; the crate's tests at `blocker.rs:1405,1691`), so there is no percent-encoder. Scripts get the crate's URL. Any other type gets `has_redirect = true` with an empty URL, so C++ blocks it.
- **R-7.** Selectors are sorted. Removals (`remove_selectors`, `remove_attrs`, `remove_classes`) go to the agent as `window.__openAdBlockProcedural=<JSON>;` ahead of the scriptlets. `exceptions` is sorted.
- **Build.** `engine-build --target open/adblock/rust:open_adblock_rust` exit 0. The target is reachable through a temporary `root_extra_deps = [ "//open" ]`, which is not committed (Step 3 wires `//open/adblock` into `libcef_static`).
- **Driver** (`/tmp/adblock-shim-driver`, a Cargo crate with Chromium's `rustc 1.100.0` that compiles this `lib.rs` as a module; not committed):
  - Build 124 ms. Trackers blocked, first-party CSS and reCAPTCHA allowed, the same after a serialize round trip.
  - DAT 6.47 MiB (F-15: ~6.8 MiB); serialize 46 ms, deserialize 31 ms.
  - Script redirect gives a `data:application/javascript;base64,…` URL; image redirect is blocked.
  - nytimes.com gets 443 hide selectors; `.ad--300x250` gets a generic selector.
  - Bad URLs, a garbage or truncated DAT, and broken resources JSON all degrade without a panic.

### Step 2, engine review r1 (2026-10-26)

The shim now has the surface the revised plan's §5.5 asks for (PR #105), so
Steps 4 and 5 need no bridge change. Evidence: the Step 3 self-test in
cefsimple (`--open-adblock-selftest`, in #100) and a throwaway Cargo driver.

- **98-1, 98-2 (cosmetics).** No CSS text is built in Rust.
  `OpenCosmeticResources` is sanitized vectors: `hide_selectors`,
  `style_rules` (`selector`, `declarations`), `remove_selectors`,
  `remove_attrs`, `remove_classes`, `scriptlets`, `exceptions`,
  `generichide`, `dropped_procedural`, `dropped_unsafe`. Selector rules
  (§8.3): no `{ } ; < @` or `/*` outside quoted strings, no newline at all,
  balanced brackets and quotes (`\` escapes), no procedural operator, at most
  2,048 bytes, a 256 KiB payload cap. **Refinement of §8.3 rule 1:** those
  characters count only outside quotes, because real list selectors quote
  `;` in attribute values (`div[id^="st"][style^="z-index: 999999999;"]`, in
  the generic set every page gets) and a CSS string can only end early at a
  newline. `:style()` declarations with `url(`, `image(`, `image-set(`,
  `cross-fade(`, `element(`, `attr(`, `expression(`, `\`, `/*`, braces, `@`,
  `<` or quotes are dropped; the others get `!important`. `hide_selectors` is
  in the crate's order (sorting about 450 selectors cost some 30 µs per
  document); it is sorted only when the payload cap applies. The other vectors
  are sorted.
- **Cost.** One cosmetic query on nytimes.com: 56 µs in-tree (budget 100 µs;
  the crate's own query is about 33 µs of it). The review's injection lines
  give no CSS; gamedev.net keeps 431 plain selectors and drops one
  `:has-text()` selector.
- **98-3.** `open_adblock_deserialize` returns false for a DAT of 4 bytes or
  less before calling the crate. README and `lib.rs` now say what is true:
  `Result`-returning crate calls can still panic; known cases are guarded;
  the rest needs the fuzz follow-up.
- **98-4 (part).** `open_adblock_deserialize(engine, dat, resources_json)`
  applies resources after a load. `open_adblock_build_report` returns
  `lossless`, `lossy_kinds` (`removeparam`, `remove`, `remove-attr`,
  `remove-class`, from a conservative scan of the list texts),
  `resources_loaded` and `resources_error`.
- **98-6.** `OpenRequestType`, a shared enum, replaces the request type
  string.
- **§5.5 rows for Step 4.** `open_adblock_engine_format()`
  (`adblock=0.8.11;shim=2;features=…;regex=…;dat=v0`; bump `SHIM_VERSION`
  on any semantic change); the 8 KiB match cap with `truncated` (a capped URL
  is never rewritten); `redirect_data_url` for every request type.
- **Not done here:** 98-5's per-rule failure counts (the crate does not
  report them); 98-7 is recorded in the revised plan (D-12).

### Step 3 as built (2026-10-26)

- **Namespace.** `open_engine`, not `open`. A namespace named `open` clashes with POSIX `open()` from `<fcntl.h>`, which Chromium includes widely. The P1/P2 overlay already uses `open_engine`.
- **Files.**
  - Overlay: `open/adblock/{open_adblock_types.h, open_adblock_service.{h,cc}, open_adblock_selftest.{h,cc}, BUILD.gn}`. The shim is a `public_deps` because the service header includes `lib.rs.h`.
  - CEF patch `0310-open-adblock-service-owner.patch`: `CefBrowserContext::open_adblock_service()` (lazy) and the member; `Shutdown()` stops the service first.
  - Test-only CEF patch `0314-open-adblock-cefsimple-smoke.patch`: no window in `--open-adblock-selftest` mode.
- **Wiring (deviation).** The plan put `deps += [ "//open/adblock" ]` in P-3. But `browser_context.cc` needs it now, and patch 0302 already owns `cef/BUILD.gn`. So 0302's Open block gains one generic line, `deps += open_libcef_deps`, and the overlay `open/open_libcef_sources.gni` lists `//open/adblock`. Future overlay targets need no CEF patch change.
- **Self-test location (deviation from §13.1).** cefsimple links only the public C API, so it cannot reach `CefBrowserContext`. The switches are read in `CefBrowserContext::Initialize()` for the first (global) context:
  - `--open-adblock-dir` (with or without `--open-adblock-selftest`) enables blocking and loads that root.
  - The self-test ends with `CefQuitMessageLoop()`; cefsimple's exit code is always 0, and the verdict is the `OpenAdBlockSelftest: PASS|FAIL` line.
  - Step 6 moves the switches to P-6 on the new CEF API and deletes the direct includes.
- **Verification as built (§9.2).**
  - Reads only `current.json`, then the live generation's `manifest.json` (SHA-256 against the pointer), then each listed `<listID>.txt` (size and SHA-256). Never enumerates.
  - Read caps: 64 KiB pointer, 4 MiB manifest and receipt, 64 MiB list, 256 MiB DAT. Links are rejected.
  - The receipt `engine-inputs.json` = generation, manifest SHA-256, every file's SHA-256, plus the DAT's size and SHA-256. The DAT is used only if the receipt equals the one rebuilt from the verified inputs.
  - Writes go DAT first, then receipt, each with `ImportantFileWriter::WriteFileAtomically`. A failed write keeps the in-memory engine and sets `last_error`.
- **Threading as built.** The build runs on a `MayBlock`, `USER_VISIBLE`, `CONTINUE_ON_SHUTDOWN` sequence and holds no service pointer. The reply is posted back to the UI thread with a weak pointer and a load id, so a stale or post-shutdown result is dropped. Checks copy a `shared_ptr` under a shared lock. List text and page tokens cross into Rust with `rust::String::lossy`, because invalid UTF-8 would otherwise abort.
- **Results** (cefsimple, dev build, root written by `openkit adblock update`, live generation 2 with EasyList + EasyPrivacy):
  - Run 1, no DAT: `engine_loaded=1 engine_from_dat=0 list_count=2 dat_size_bytes=6786699 last_build_ms=226`, all checks PASS.
  - Run 2: `engine_from_dat=1 last_build_ms=48`, PASS; the whole process took 0.31 s.
  - Cosmetic query: mean 66 µs per page (budget ≤ 100 µs).
- **Shutdown.** Five quits (SIGTERM at 0.3, 0.5, 0.6, 0.8 and 1.0 s) during a 480 ms text build of a 12 MB `/tmp` fixture root. All exited with code 0 within 0.1 s, no `FATAL`, no new crash report, and zero cefsimple processes 1 s later.


### Step 3, engine review r1 (2026-10-26)

- **100-1(a).** The DAT receipt binds `engineFormat`
  (`open_adblock_engine_format()`) and `lossless: true`. A DAT written by
  another crate, shim or feature set no longer matches, so it is rebuilt
  from text.
- **100-1(b) (D-15).** A build whose lists have `$removeparam` or `:remove*()`
  rules (the shim's build report) writes no DAT, so a DAT never drops them.
- **100-2.** Engines are freed on the build runner: the old engine after a
  swap, a dropped stale result, and the engine at `Shutdown()`, which takes
  it out under the lock and frees it outside it.
- **100-3.** Patch 0310 reads `--open-adblock-dir` and
  `--open-adblock-selftest` only without `OFFICIAL_BUILD`, and the self-test
  sources build only when `!is_official_build`. `tools/release.sh` fails an
  official framework that contains `open-adblock-`. The dev framework has 3
  such strings, as it should.
- **100-4.** `IsExcluded` checks the host and each parent domain at label
  boundaries down to the registrable domain (the Swift rule), and down to
  the last label when Chromium knows no registrable domain. IPv6 entries are
  bracketed before parsing. The self-test asserts behavior:
  `a.news.example.org`, `news.example.org`, `www.example.com`, `example.com`
  and `[::1]` are excluded; `example.org`, `other.example.org` and
  `notexample.com` are not.
- **100-5 (part).** A 128 MiB cap on a generation's lists together; the texts
  are freed right after the build; the DAT is written from the Rust buffer
  without a copy. Sharing engines across Profiles stays with Step 4 (D-16).
- **100-6.** The accessor returns `nullptr` after `Shutdown()`.
- **100-9 (part).** `LoadFromDirectory` after shutdown still runs `done`.
- **Self-test.** Exit code 0 only on PASS (1 on FAIL, 2 without
  `--open-adblock-dir`, 3 after 10 s). New checks: the review's CSS
  injection lines give no CSS, a 4-byte DAT is refused, a `$removeparam`
  list is lossy, the 8 KiB cap, gamedev.net keeps its plain selectors. It
  prints the network check cost on six realistic URL shapes (about 6 µs in
  this build). Its last step starts a text build and quits at once, so
  `Shutdown()` runs with a build in flight.
- **Results.** Run 1 builds from text and writes the DAT; run 2 loads it
  (`engine_from_dat=1`, 62 ms). Both PASS. Cosmetic query 56 µs. Quitting
  during a build: three runs, exit 0, no `FATAL`, no process left after 3 s
  (a temporary `LOG(WARNING)` confirmed that `Shutdown()` runs; not
  committed). SIGTERM in cefsimple does not reach `Shutdown()` at all: the
  process exits at once with code 0, so the earlier SIGTERM test did not
  exercise it.
- **Correction.** Links are rejected for the leaf files and the generation
  folder only, not for `adblock/` or `generations/` (defense in depth under
  the same-user threat model, review 100-9).
- **Follow-ups** (`docs/followups.md`): 100-7, 100-8, the rest of 100-9, the
  0301 build-hook patch.
### Step 4 status (2026-10-26, checkpoint; no PR yet)

Paused at the user's order (22:25): no new PRs. Branch `m6/adblock-step4`
(main 4c40ebd merged). All numbers below are from `cefsimple` dev builds
on an Apple M5 Pro (18 cores) with load averages of 12–24 from other jobs.
The CDP driver, server, capture and gate scripts are throwaway files in
`/tmp/open-adblock/` (§13.3); raw output is in `.re/adblock-corpus/`.

**Built.** The proxy (`open_adblock_url_loader_factory`), the matcher
sequence and engine registry, the factory and socket hooks, the tab counts
(`open_adblock_tab_helper`), CEF patch 0311 (P-3, +98/−0), 0310's smoke
switches and load line, the test site and two fixture roots
(`testdata/adblock-root`, lossy; `testdata/adblock-root-dat`, lossless with
`noop.js`), the bench switches, and `Engine/fork/adblock/bench/corpus-manifest.json`.
The §5.5 shim rows owned by Step 4 had already landed in #98; Step 4 only
verifies them (N-4, N-17, N-19).

**Deviations from the plan** (each also corrected in the section named):

- §7.4 rule 1 tested `is_outermost_main_frame`, which is true for every
  request the main frame makes; the first N-1 run passed every page
  subresource through. Now `destination == kDocument`.
- §13.2: port-free test URLs plus `--host-resolver-rules`, because macOS has
  no `127.0.0.2` and the crate's `||host/path` needs the path right after
  the host. `/ads/allowed-banner.js` is added to the list (the exception
  excepted nothing); the N-18 rule is `||127.0.0.2/wt-blocked`; the long
  fetch is just under `url::kMaxURLChars`.
- The service comes from `CefBrowserContext` inside the P-3 hunks, not from
  the `BrowserContext`: the context's `Initialize()` runs before its Profile
  exists. The top site is the full host (exclusion matching walks its labels
  down to the registrable domain). The smoke count is printed by the libcef
  tab helper, which the factory hook creates for every frame of an enabled
  Profile, so a page with no stop still prints 0. `--open-adblock-exclude`
  takes a comma list.
- Review-checklist fixes found while testing: `ServeStub()` no longer
  consumes the client when it refuses a stub (a refused stub now ends with
  `ERR_BLOCKED_BY_CLIENT`, not a closed pipe); list CSP values over 8 KiB or
  not valid as a header value are dropped, never cut; the `$removeparam`
  redirect ignores a client-supplied `new_url`.

**N-cases.** The last full run (before two counter-only changes: the
thread-CPU busy counter and the bench's CPU column) passed every case except
COUNT-closed-document, which then passed twice on its own once it had a
control run. Passing: N-1…N-17,
N-19 (DAT load with resources re-applied), N-21 (valid: the
`responseReceivedEarlyHints` event was seen; the page's script was blocked;
the server log shows the preload GET, the known R-14 gap), N-15
(extension: Open is outermost; the DNR redirect target is blocked by the
redirect re-check), N-16 (Alloy). N-18: **hook reachability only;
error-object correctness unverified.** N-20 belongs to Step 6. Added cases,
all PASS: COUNT-load/reload/pushState, COUNT-closed-document (three
keepalive fetches from `pagehide` are checked and blocked, and the next
page's count stays 0), CAP-stub (a 1 MiB stub is served, 1 MiB + 1 is
blocked), CAP-csp (an 8,192-byte list CSP applies, 8,193 is dropped),
LIFE-1 (five page exits with 40 loads in flight, then a quit with loads in
flight: exit 0 in 0.3 s), NO-LEFTOVER. The early spike (Work 1) passed:
the blocked subframe commits an error page with `unreachableUrl`, the list
CSP stops the inline script, and its control run (site excluded) runs it.

**Corpus.** 25 front pages, 20,311 URLs (`corpus_sha256` d758ee66…). The
positive control passed in every process; no page sent a `103`
(`early_hints_seen: false`, `http11_hints_dropped: 0`), so the R-14 trigger
did not fire on this corpus.

**Gates** (five runs, medians; caps 8 KiB and 16 KiB):

| Gate | Result | Numbers |
|---|---|---|
| G-1 | PASS | Matcher thread `ThreadPoolForegroundWorker`; no CHECK in any N-case run, bench run or gate run |
| G-2 | mean, p99 PASS; max **FAIL** on wall time | 8 KiB: mean 4.73 µs, p99 25.9 µs, max 1,134 µs. 16 KiB: 4.62, 26.4, 1,208 µs. Thread CPU time of the slowest check is 178–370 µs in all ten runs, nearly always the same 3,256-byte URL; the wall-time maxima of 1–29 ms fall on 85–153-byte URLs, which is time spent waiting for a core |
| G-3 | PASS | Every long-URL max ≤ 281 µs at both caps (2 MiB: 145–245 µs) |
| G-4 | PASS | p50 ≤ 32 µs, p99 ≤ 256 µs over 1,005 requests (5 loads) |
| G-5 wall | PASS | On 54–61 ms, off 117–144 ms (blocked requests never reach the network) |
| G-5 busy | **FAIL** | 9.9 ms wall, 9.0 ms thread CPU per 200-request load (budget 3 ms). Profile per load: the crate's check 3.0 ms, Mojo decoding of incoming requests 3.8 ms, client callbacks 4.9 ms, `GURL` building 1.4 ms. The plan's 5 µs per-request proxy guess is several times too low |
| G-6 | **FAIL** | 2–4 checks over 1 ms per 1,075 (max 14.6–15.4 ms), all in load 1: first-use regex compiles (F-35), under load |
| G-7 | PASS (within spread) | Blocking off with P-3: medians 117.4 and 144.0 ms; without P-3: 124.8 and 127.8 ms |
| §6.6 footprint | **FAIL** | Browser `phys_footprint` +70 MiB with a DAT-loaded engine, +62 MiB after a text build (budget 40 MiB). All of it is PartitionAlloc (vmmap tag 14, +69.8 MiB dirty), unchanged at 30 s and after a simulated critical memory-pressure signal |

The cap that ships stays 16 KiB: both caps give the same verdicts on the
corpus (14,467 matched; 14 URLs cut at 8 KiB) and the same costs.

**Left before a PR:**

1. Lead rulings on the four FAIL rows (G-2 max on wall time, G-5 busy, G-6,
   footprint). Nobody raised a budget. **Ruled 2026-11-07 15:10**
   (§13.5.1): G-2 max counts thread CPU ≤ 500 µs (wall max ≤ 2 ms at
   load1 ≤ 4 in the Step 9 quiet run); G-5 busy ≤ 5 ms thread CPU per
   200-request load after cutting the callback and `GURL` costs; G-6
   stays, and regexes compile in the background build; footprint
   ≤ 50 MiB (stretch 40) after the shared engine, no resident list text,
   the 97-2 domain resolver, and DAT against text measured both ways.
2. Break-and-revert proof (checklist §4): run the N-cases on a build without
   P-3 and record the FAIL lines (two attempts were killed by T3 restarts).
3. Docs: an engine-patches row for P-3, a `docs/followups.md` entry for N-18
   (HTTP/3 endpoint), and the "Step 4 as built" section.
4. Re-record the engine distribution with Step 4 when the lead asks, then
   `tools/verify-all.sh` and the review-checklist table.

**Shared tree at the checkpoint:** exactly main 4c40ebd + #93 (338c920,
the same engine files as 65c6a780), the source state of the recorded
distribution (stamp 5602914f…). Step 4 is not applied there. To put it
back: copy `Engine/fork/src/open/adblock/` from this branch into the tree,
then replace 0310 and apply 0311 from this branch's `patches/cef/`.

### Cold-start App erratum (2026-11-09, App-only verification)

The adapter now posts exclusions, the deterministic Profile list directory,
and enabled state when a context is created, including Default at engine
readiness. Context configuration does not need an IO-backed store. A separate
read-only background task prefetches saved settings/exclusions; until it
returns, the existing store's in-memory values win, otherwise defaults are
on/no exclusions. **Lead fresh-profile ruling (2026-11-09 04:30):** one
background `lstat` of `lists/current.json` identifies `ENOENT`. A live fresh
context starts `openProfile` immediately after detection, without waiting for
paint; existing generations retain after-paint opening. Store metadata/lease
preparation and repository seed/verify/exclusion IO stay off the main thread.
The first store configure explicitly reloads an already configured directory,
because the early load may have failed before seeding created `current.json`.
The companion native change keeps an unpublished pointer in
`awaiting_generation` under the same 1,500 ms per-request / 128 process-wide
limits. Real manifest/SHA/read errors end pending; an engine or valid zero-list
generation completes the initial load. This App-only branch still fails open
before an engine arrives. The M5 App-only probe blocked the first
post-onboarding script with an allowed control while the after-paint adapter
was still unstarted; its generation was already published before onboarding
finished. Warm relaunch exposed the remaining first-engine gap. Saved-off and
excluded controls loaded. The Chrome-style App ad-block suite passed 81 rows.
Raw receipts are in `.re/s13/i/resume-0952/`. Main's engine exposes no cold-hold
counters; browser resource durations do not prove native hold time. Five
interleaved Release pairs for each of fresh/warm Profiles at load1 7.82–9.35
showed no first-paint slowdown against main `1a37e49a`: fresh medians main
797 ms / branch 719 ms, warm 755 / 655 ms; paired median differences were
−92 / −100 ms. All samples, including the slow first fresh pair, were kept.
Native deadline/boundary proofs still belong to the companion branch.

### Section 13 lead decisions (2026-11-07)

1. **Order.** Step 4 (with the §13.5.1 rulings) first. Then the control
   API (Step 6 and Step 8 together) and the App adapter, so that the App
   blocks requests before cosmetic filtering lands. Then Step 5
   (cosmetics), Step 7 (resources, lists), Step 9. Reason: the App
   integration is the long pole, and Step 5 does not change the API.
2. **CEF API shape (revises Step 6).** The control API is a fork overlay
   header `cef/include/cef_open_adblock.h` with free functions that take
   a `CefRequestContext` (and a `CefBrowser` for the tab count), the same
   pattern as `cef_open_page.h` (0505) and `cef_open_omnibox.h`. It does
   not add virtual methods to `cef_request_context.h`. The translator
   still generates the C API for it.
3. **OpenEngine shape (revises §12.1).** The API is a category on the
   existing `OEBrowserContext` (enable, list directory, reload,
   exclusions, status dictionary) and a read-only blocked count on
   `OEWebContent`, not a new `OEAdBlockController` with `void*` handles.
4. **No blocked count in the UI.** Arc 1.170 shows none. Its Site
   Control tile is "Block Ads & Trackers" with three tooltip states:
   "The built-in ad blocker is turned on for this site.", "The built-in
   ad blocker is disabled for this site.", and "The built-in ad blocker
   is off. You can change this in Settings." (`strings -a` of the main
   binary, `.re/features-advanced/strings-main.txt` lines 113200–113207).
   The engine count stays for tests and debug info.
5. **Other blockers.** Arc lists 19 Chrome Web Store IDs beside its
   `AdBlockerExtensionID` cases (`strings-main.txt`, the block that
   starts with `bcjindcccaagfpapjjmafapmmgkkhgoa`). Open warns in
   Settings when native blocking is on and the Profile has an enabled
   extension from that set.

### Section 13 engine bring-up (2026-11-07, work in progress)

Branch `s13/step4-engine` starts at `6839eba9`. Its assigned root is
`~/Developer/open-engine-s10`; no other engine root is used. The recorded
starting state has 564 Chromium status lines, 39 CEF status lines, and
23 applied patch records (main through #223).

To insert Step 4 in series order, reverse main's 0505 and 0310, then run
`engine-apply --all`. This applies Step 4's 0310, then 0311, then 0505.
The shared files in 0311 and 0505 apply without a context refresh; 0701
has separate manifest paths. Status is 8 PASS, 0 FAIL, 0 WARN: 24 patches,
94 overlays, and 117/117 CEF patches. The dev `cefsimple cefclient` build
passes in 112 s with 10 jobs and nice. Root apply and build run under
`/tmp/open-engine-build.lock`, in detached sessions. This is build proof;
break-and-revert, the four rulings, final N-cases, gates, OTR lifetime,
App checks, and the new distribution remain pending.

Raw receipts are in `.re/s13/e1/` in the project root. The corpus remains
20,311 URLs with the committed SHA-256 `d758ee6639488dab875b54b729feead7251e482c3671b9f44bc990edf240d5b0`.
The new measurements use the official immutable seed snapshot from
`s13/app-a` commit `60deca0c` (EasyList SHA-256 `756ddc9a…`, EasyPrivacy
`c1d09df3…`), checked before staging; these differ from the historical
October measurements. The same staged bytes will be used before and
after each optimization.

**Working measurement support (E1, 2026-11-07).** The non-official
`--open-adblock-selftest --open-adblock-diagnostic` path loads the real
service once, without the synthetic selftest engines. It prints in-process
`task_info` physical footprint and PartitionAlloc allocated, active,
resident, committed, decommittable and discardable bytes before the load
and after a settling interval. `--open-adblock-text` forces a text build;
the next run can load its verified DAT. `--open-adblock-measure-only`
omits the corpus. `--open-adblock-settle-seconds` accepts 0–60 seconds;
pass the bench switch as well to use the existing 300-second deadline.
G-3 now prints thread CPU beside wall time. The opt-in
`--open-adblock-verdict-dump=<private path>` writes every result field for
each corpus row, in order, on the build runner. No URL is added to a log.

The first working measurement (load1 14, no quiet lock, P-3 temporarily
removed for the negative proof) has identical text/DAT verdict files:
20,311 rows each, SHA-256 `10c74cb4…` at 16 KiB and `ba80db77…` at 8 KiB.
One-engine physical-footprint deltas are 56.6–58.0 MiB after a text build
and 67.2 MiB after DAT load. These are baselines before the four rulings'
optimizations, not final acceptance. Receipts are in the E1 directory.

**Regex and DAT working checkpoint (E1, 2026-11-07).** Compile all network
regex programs on the build runner, without a warm match. Disable the crate's
program-discard cleanup: it discards programs, so enabling it would compile
again on requests. Bound eager DFA and one-pass accelerators to zero and the
lazy DFA cache to 8 KiB per program. A preferred 64 KiB NFA ceiling retries
at the upstream 10 MiB ceiling on `CompiledTooBig`; the real matcher correctly
blocks a synthetic URL with a 623,832-byte program that takes that fallback.
The full corpus adds zero regex compiles after publication.

Only generated ABP patterns use explicit ASCII separator and wildcard classes.
`url/gurl.h:25-26,109` guarantees ASCII percent-escaped canonical specs.
User-written `/regex/` syntax is unchanged: the pinned source lists contain
25 such lines (19 EasyList, 6 EasyPrivacy), optimized to 16 compiled objects
using 4,358,248 program bytes. Text program bytes drop from 32,376,108 to
7,254,660. Both caps and text/DAT retain byte-identical 20,311-row full-result
verdict dumps. Sixteen separator, IDN, Unicode-path and fallback inputs also
have identical results in all eight before/after, text/DAT, cap combinations.

DAT serializes Arc values independently. Re-sharing rules by all eleven
immutable fields restores 262 duplicate references, reducing DAT regex objects
from 1,195 to 1,000 and program bytes from 8,524,772 to 7,251,132. All four
full-corpus dumps remain identical. Working load1 27-50 receipts still exceed
the 50 MiB footprint budget (about 62 MiB DAT, 68-72 MiB text); the resolver,
earlier buffer release and final quiet receipts remain pending. These values
are measurements for optimization, not final gate acceptance.


### Step 4 as built (2026-11-08, integrated engine)

Branch `s13/step4-engine` uses only `~/Developer/open-engine-s10`.
Source now includes main `50028c98`, including the final Section 15 App
and imported-secrets integration,
the final App adapter `fcd1ef25`, and Step 7 resources. Engine inputs are
unchanged since main `d26300e6` (Section 15's Chromium 0801–0810). Every main patch
is retained. The engine applies Chromium's 08xx before the CEF series,
including ad-block 0310/0311/0314; 0601/0602 precede 0701 within CEF.
There are no Section 15 08xx entries in the CEF series.

The merged dev build of `cefsimple cefclient` passed built-artifact
engine-status: 8 PASS, 0 FAIL, 0 WARN, with 38 patches, 123 overlays and
49 required exports. The production API passed 21 rows and native lifetime
passed 14 rows on this build. The resources-only generation API flow
passed 26 rows, including no-engine status, the same-context unload
control and exactly one restored list at generation 3. The zero-file
fixture and official pinned-list/resources flow also passed 26 rows each.
The root's clone hold ended at 14:00; M5 screen clearance arrived at
16:30. Headless corpus/footprint/G-2/G-6 passed. The merged N run passes
32/32, production COUNT and its allowed control pass, and quiet page
G-4/G-5/G-6 pass. Both COUNT negative controls and the merged URL
edge rerun also pass.
The same-context explicit-unload control for zero-list memory passed
offscreen. The dev distribution and Debug App build also passed offscreen;
the App's normalized engine code matches the recorded framework. Its bundle
contains the 47 pinned redirect resources. Real App acceptance records
79 PASS and zero FAIL, including 11 record-only whole-process rows. The forced delete-sheet
cleanup control passes. Remaining regression suites and the full gate
remain in progress.
Before distribution and again before the done report,
fetch main and check `Engine/fork` changes since the last merged main.
Any new engine change requires merge, rebuild and engine reproof first.
The distribution receipt identifies main `d26300e6` and framework SHA-256
`8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`.
Distribution took 73.991 s at endpoint loads 13.48/15.48/18.08 ->
13.86/15.23/17.78. The Debug App build took 108.305 s at
13.59/15.12/17.71 -> 12.66/14.95/17.37. The existing no-window
CEF command also passes 47 load/matcher/safety checks, including decoded
limits, trailing-data refusal and bounded fuzz input. These native checks
do not replace browser N rows or document COUNT witnesses. The current
browser driver creates windows for every N/COUNT case.

After the final Section 15 App merge, the Debug rebuild also passed:
37.755 s, endpoint loads 15.56/13.40/13.27 -> 18.65/14.68/13.76.
App acceptance and regression receipts use this merged build. The queued
earlier App attempt was canceled before launch; it is not test evidence.

Main `dd240186` was then merged in `eb88d72a`. The fresh `Engine/fork`
log since `40c2ab94` is empty, so the recorded distribution is unchanged.
The Debug rebuild passes in 47.107 s at endpoint loads
10.99/10.55/11.78 -> 7.92/9.82/11.44. Before the queued suites launch,
updater PR #253 reaches main `25b9c950`. This overlapping main update is
merged in `e864ca1d`; its Engine/fork log is also empty. The next Debug
build passes in 49.824 s at loads 6.86/8.69/10.73 -> 10.13/9.40/10.88.
Features and extensions-ui reruns use that build. Both earlier Features
waiters were canceled before launch and provide no test result.

**Request path and lifetime.** Open's outermost factory proxy checks
subresources and redirects on one matcher sequence. Main documents pass
through. WebSocket and WebTransport use the same service. Parsed GURLs
and factory initiators are reused, and ordinary requests avoid a
ResourceRequest copy. Response/client pipes remain proxied through
completion. The attempted post-response pipe fusion violated Mojo's
unwritten-endpoint precondition (`mojo/public/c/system/message_pipe.h:330-338`)
and broke N-9 worker completion; `dc98292e` removed it. Removing P-3 from
the real binary made 24 blocking rows FAIL while 6 controls passed.

Matcher state is ref-counted on its sequence. The engine registry shares
immutable engines by list contents, independently of directory paths;
enabled state and exclusions remain per context. Native OTR close shuts
the service down before shell notification. The real native parent/OTR
lifetime flow passes 14 rows, including pending-load cancellation,
retained-wrapper refusal, repeated shutdown and ordered parent deletion.
The latest-load id is checked before parsing and before cache writes,
including after serialization (100-7).

**Regexes, rule storage and memory.** Every network regex compiles on the
build runner before publication, without a warm match. Upstream regex
builder defaults are restored; the bounded-cache/accelerator candidate
raised CPU maxima and was removed. Program-discard cleanup stays disabled
because it would force request-path compilation. User `/regex/` semantics
are unchanged. Only crate-generated ABP separators, wildcards and generated
word/digit classes use ASCII forms: canonical GURL specs are ASCII and
percent-escaped (`url/gurl.h:25-26,109`). The pinned lists contain 25 user
regex lines, optimized into 16 programs. The final default builder has
1,000 program objects, 7,278,276 total bytes and 4,385,392 user-program bytes.

DAT re-sharing compares all eleven immutable NetworkFilter fields and
restores 262 duplicate references; an id-only comparison is insufficient.
A lossless text build serves the engine decoded from its already-serialized
DAT bytes, then drops the original. Resources are reapplied. Lossy rules
(such as removeparam) and failed decoding retain the valid text engine.
List text, resources JSON, conversion buffers and DAT input buffers are
released before compilation. Chromium's registry-controlled-domain resolver,
including private registries, replaces the embedded PSL/addr closure (97-2).
Shim version 4 invalidates old receipts.

After temporary build buffers are freed, the build runner calls PA
`MemoryReclaimer::ReclaimAll()`. Request activity arms one matcher-sequence
idle task: reclaim after five seconds without activity, at most once per
minute. No task remains after it runs until new activity. It retains no
Profile or engine, and no purge runs on a request path. The same-binary
purge-off/on control at corpus +6 s measured 65.19/62.48 MiB without purge
and 57.19/53.33 MiB with purge (16 KiB text/DAT, median five, load1
9.23-22.73). All 80 initial/resumed verdict dumps match baseline.
Three 60-second windows per input retain exactly one purge and zero extra
runs. Browser CPU medians are 86.103/88.604 ms text/DAT versus 113.418 ms
without an engine; these loaded whole-browser samples do not establish a
precise causal CPU delta. Raw control receipts remain in `.re/s13/e1/`.

**Integrated headless proof.** The final main `d26300e6` build passed five
runs per cap/input, each followed by another full corpus. Its framework
SHA-256 is `8e8a461c8cf3242e5fbcc3cc6ebe706a6a8ad8054a1e077830bc7094048295b1`;
the recorded dev distribution has the same bytes. All 20 native
processes exited cleanly. The 40 dumps each have 20,311 rows and match
the pre-integration baseline byte for byte.
SHA-256: 16 KiB `10c74cb476adccafc4f750bbc2ae6c1a85363b9945a6fe1470507e9dc845fe02`;
8 KiB `ba80db77c8651ce7ec35b71bfeade9e04624d4f564ada4cf8fde16c229f475b6`.
Every initial and resumed burst adds zero regex compiles, and every run
observes exactly one production idle purge. These are medians of per-run
statistics under the quiet lock; endpoint load1 spans 9.87-24.34. They
support the CPU/footprint rulings and are not Step 9's load1 <=4 wall proof.

| Cap / input | CPU mean / p99 / warm max, µs | First CPU max, µs | Warm wall max, µs | Steady / post-corpus+purge, MiB |
|---|---:|---:|---:|---:|
| 16 KiB text | 3.488 / 15.125 / 132.333 | 142.791 | 132.167 | 55.157 / 57.094 |
| 16 KiB DAT | 3.505 / 15.542 / 135.333 | 147.125 | 135.209 | 52.110 / 54.188 |
| 8 KiB text | 3.444 / 15.209 / 134.500 | 193.750 | 143.917 | 56.407 / 58.266 |
| 8 KiB DAT | 3.399 / 14.875 / 135.333 | 154.459 | 136.750 | 52.844 / 54.860 |

The following-burst warm CPU max medians are 134.625/130.791 µs
for 16 KiB text/DAT and 128.834/134.458 µs for 8 KiB. All four
groups meet the 500 µs CPU limit. No native check exceeds 1 ms;
the largest is 360 µs.

| PA component, median 16 KiB, all roots | Text MiB | DAT MiB |
|---|---:|---:|
| Rules/index/build residual allocated delta | 36.785 | 36.484 |
| Immutable regex programs (exact crate counter) | 6.941 | 6.941 |
| Regex caches/metadata/rounding residual | 6.505 | 6.575 |
| Other to settled | -0.191 | -0.202 |
| Settled allocated delta | 50.066 | 49.793 |
| Settled resident delta | 52.266 | 49.750 |
| Post-idle allocated delta | 50.970 | 50.754 |

PA phase deltas include concurrent browser allocations and rounding; the
residuals are not exact ownership tags. Physical footprint is a separate
`task_info` measure. Median text service load is 427 ms, including parse
140.510, serialize 81.694, decode/replace/free 147.161, regex compile 42.695
and build reclaim 2.538 ms. DAT load is 182 ms, including decode 132.503,
compile 43.574 and reclaim 0.963 ms. Separate medians need not sum.
Receipts: `.re/s13/e3/s15-headless-r3-accepted-gates.json`,
`s15-headless-r3-summary.json` and `s15-headless-r3-pa-phases.json`.

The first merged attempt completed its measured bursts, then exited 1
when Chromium's 10-second macOS teardown watchdog expired. That failed
receipt remains in `s15-headless-r1.log`. The unchanged retry r2 and
the final-artifact refresh r3 each had 20 clean exits. The cause of
the first shutdown failure is unproven;
no watchdog or assertion was disabled for the retry.

**Valid empty generation.** All lists off publishes a valid zero-file
manifest in the Swift store. The first fix loaded a zero-rule engine
instead of retaining old blocking rules; its API flow passed 21 rows and
eight additional full-corpus dumps remained identical. Step 7 now includes
`_resources` even when no list is enabled. That resources-only generation
failed the old loader through the real API (async load deadline).

The lead's 2026-11-08 12:29 ruling replaces the zero-rule engine with a
verified no-engine generation. Both zero-file and resources-only manifests
are verified normally. With zero lists the service skips registry lookup,
DAT work and engine/resource construction, clears the matcher and reclaims
freed pages after its old holder is destroyed. Status advances
`load_generation`, with `list_count=0`, `engine_loaded=false`,
`resources_loaded=0` and empty `last_error`. The valid generation is a
successful API load. Nonempty generations retain the normal build path.

The rebuilt native API flow passes 26 rows for zero-file, resources-only
and official pinned EasyList/EasyPrivacy/resources inputs. Each restores
exactly one list at generation 3. The official-input run observes the
native no-build marker and no empty-generation DAT or cache receipt.
Its resources-only phase exceeds an explicit unload in the same warmed
context by 49,152 physical bytes and 14,368 PA allocated bytes; resident
and committed bytes are equal. These are raw process-wide differences,
including other browser allocations, with no new memory tolerance.
The initial pre-build baseline has a separate 3,211,576-byte physical
delta and does not isolate engine retention. Endpoint load1 is
22.07 -> 21.55. Evidence:
`.re/s13/e3/s15-empty-resources-warm-control-evidence.json` and
`s15-zero-list-official-r2.log`. App zero-list/restore request proofs also pass in the strict 79-row scope;
the distribution and Debug App build are ready.
Historical receipts: `.re/s13/e3/empty-generation-before.log`,
`empty-generation-after.log` and `empty-corpus-identity.json`; Step 7
reproduction: `empty-resources-before.log`.

**COUNT-closed-document erratum.** The original pagehide stimulus observed
no requests. Its replacement waited for three blocked fetches and then
navigated; its predicate incorrectly rejected an old-document reading of
8 before the new commit. The 21:12-21:14 run is diagnostic only because it
may overlap another section's crash dialog. It does not count as a full N run.

The subsequent CDP predicate required three outgoing request events,
three terminal events and three `ERR_BLOCKED_BY_CLIENT` errors. It is
**not usable at unload (DevTools rebinds to the incoming RFH at
ReadyToCommitNavigation)**. Chromium's
`content/browser/devtools/render_frame_devtools_agent_host.cc:531-558`
calls `UpdateFrameHost(request->GetRenderFrameHost())`; lines 1015-1053
bind the renderer channel to that host. In E3's r2/r3 runs, real top-level
pagehide fired and the allowed server received three GETs, but the Network
domain reported zero outgoing starts and terminals. The old predicate and
its failed receipts remain in `.re/s13/e3/count-proof-cdp-unload-unusable.py`
and `count-identity-r3-focused-results.json`.

The lead replaced that observer requirement on 2026-11-08 at 10:45.
The row uses a real top-level pagehide handler, a localStorage sentinel
and three keepalive GETs. The blocked variant sends matched URLs: the
server must receive zero, and the outgoing document's native count must
rise by exactly three from its pre-unload value. The allowed control uses
the same page with unmatched URLs: the server must finish exactly three
GETs, and the outgoing native count must remain unchanged. A native
`before-commit` reading records the outgoing count before reset. Every
reading carries its committed document id. The new id must have count zero
at commit, at load and at least two seconds after the native/server
witnesses; `replaceState` obtains the late reading without resetting it.
The allowed variant must fail the positive blocking predicate. A temporary
wrong-document variant must fail because its new-document count is nonzero.
Neither control changes the shipping policy. The production positive and
allowed control passed on 2026-11-08: blocked old id 2 counted 5 -> 8
with zero server GETs; allowed old id 2 stayed at 5 with three completed
GETs. New id 4 stayed at zero at commit, load and the late readings
(4.014/4.012 seconds after the witnesses). Receipt:
`.re/s13/e3/count-native-positive-focused-results.json`. The temporary
wrong-document control also failed as required: its old count stayed at 5,
its new id rose to 3 after load, and the server received zero GETs. Its
allowed control still completed three GETs with unchanged old count and
new count zero. Receipt: `count-native-wrong-focused-results.json`.
Production was restored and strict engine status passed before running
that saved private artifact. The counted full integrated N run passed
all 32 rows (`integrated-N-r2.results.json`), including the native/server
count predicate, limits, workers, sockets, extension ordering, DAT reload
and in-flight close/driver-failure cleanup.

The post-Section-15 rerun also passes 32/32 (`s15-N-r1.results.json`).
The production-default focused COUNT rerun (`s15-count-positive-r2`)
records blocked old id 2 at 5 -> 8, new id 4 at zero at commit, load
and 4.013 s after the witness, with zero server GETs. Its allowed control
completes exactly three GETs, keeps the old count at 5 and the new count
at zero through the same late reading. Outgoing unload CDP events remain
zero in both variants and are not part of the predicate.

The post-Section-15 wrong-document control also passes (`s15-count-wrong-r2`).
Its blocked URLs never reach the server, while the old id stays at 5 and
new id 4 rises to 3 after load and remains 3 at the late reading. The
predicate fails specifically for the incorrect document attribution. Its
allowed control completes three GETs, with unchanged old count and new
count zero. Production remains byte-identical to the recorded distribution.

**Unicode/IDN page edges.** All 16 cases pass against both the saved
pre-ASCII build and the integrated build (32 rows). CDP observes the
actual canonical ASCII specs, and allow/block verdicts remain identical
for IDN hosts, escaped UTF-8 paths, separators, end anchors and user regex
ASCII classes. Receipt: `.re/s13/e3/ascii-edge-page-results.json`.

The post-Section-15 browser rerun passes 32 fresh rows: the same 16
Unicode/IDN inputs through current text and verified DAT loads. Every
actual canonical ASCII spec and verdict matches the retained pre-ASCII
browser witness. The original `/tmp/open-adblock` fixture and saved
pre-ASCII app were missing; the first attempt stopped before browser
launch. E3 restored the exact original inputs and rules in its canonical
private evidence directory. The baseline rows remain historical. Receipts:
`.re/s13/e3/s15-edges-r1.log` and `s15-edges-r2-results.json`.

**Page timing after idle.** The integrated page run observed exactly one
idle purge before measured load 2. All 15 loads had 200 requests and 200
terminal events. G-4 passed (p50 <=32 us, p99 <=256 us). G-5 wall passed:
blocking-on median 118.2 ms versus off 144.7 ms. G-5 busy CPU failed at
12.756 ms against 9 ms, at measured load1 48.09–49.93. The preceding
20-minute load1 <=12 opportunity expired without launching a browser.
Receipt: `.re/s13/e3/integrated-page-loaded-r1-page-scopes.json`. These
loaded numbers do not establish the quiet gate or a cause for the miss.

The lead's 17:43 priority instruction enabled a post-Section-15 quiet
run after the App build. It passes G-4, G-5 CPU/wall and G-6, with
all sampled load1 values 8.13–9.07 (limit 12). Loads 2–5 have on-load
wall times 58.9/61.4/68.4/70.7 ms, median **64.900 ms**; off median is
113.200 ms. Median busy thread CPU is **8.500 ms**, within 9 ms.
The production idle purge occurs before measured load 2. G-4 includes
all five loads: 1,000 requests, p50 <=32 µs, p99 <=256 µs, max <=512 µs.
G-6 records zero added compiles, 0/1,070 checks over 1 ms and maximum
262 µs. Receipt: `.re/s13/e3/s15-page-quiet-r2-page-scopes.json`.
The 64.900 ms value is Step 5's C-G2 input T for this engine.

An earlier App source merge includes main `50028c98` (imported-secrets
App and harness changes), with no further Engine/fork change. The Debug
rebuild passes in 38.887 s at endpoint loads 11.76/10.84/10.80 ->
12.27/11.08/10.89. Its strict App rerun (`s15-adblock-r9`) passes 79/79,
with zero interruptions and nine clean launches. AD3 PA allocated median
is +26,704 bytes, non-PA malloc in-use delta zero, and different-list
control +25,074,288 bytes with sharing=false. Resources-only generation 4
has no engine/resources/error; one-list generation 5 blocks and redirects
again. The earlier r8 run lost foreground at its first row and is
INTERRUPTED, with cleanup PASS; it is not acceptance evidence.

**Default App hosting and regression.** Default-Chrome acceptance
(`s15-adblock-r10`) passes 79/79, including resources/DAT, zero-list restore,
independent Profiles/OTR and held-load deletion/relaunch. All nine launches
clean up with no interruption. AD3 PA allocated median is −46,144 bytes;
non-PA malloc in-use delta zero; different-list control +25,129,024 bytes
with sharing=false. F's harness/ruling is merged from `d5e44abe` and
recorded in the Step 8 erratum. Forced-sheet cleanup also passes.

The page regression has 81 PASS, five existing BLOCKED, one SKIP and one
DEFERRED row. Features has 27 PASS. Full default-Chrome Extensions UI has
71 PASS and the existing X13 picker BLOCKED because the App Site Control
presenter is absent. Settings preview passes 47 functional checks plus
native pane renders. Raw receipts retain all qualifiers.

The private runner initially omitted `--style`, selecting legacy Alloy.
Its full and focused P10 runs fail the exact Work popup assertion. Changing
only to `--style chrome` passes all 16 P10 rows and the runnable full
Extensions UI scope. The App defaults to Chrome (`App/LaunchOptions.swift`),
and the prior P10 receipt also used Chrome. No product code, assertion,
threshold or baseline changed. Both Alloy failures remain retained; this
work does not claim that Alloy's popup is fixed.

The final source merge is main `e8d4acd4` in `bd006cc3`, after a fresh
Engine/fork log found no changes since the recorded distribution's base
`d26300e6`. The Debug rebuild passes in 37.101 s at endpoint loads
8.88/8.99/9.14 -> 8.17/8.81/9.07. It adds opt-in launch diagnostics and the
Welcome hover fix, with no ad-block policy, adapter or fixture logic change.
The Chrome App receipts above bind the main50028c98 build separately.
Full verification passes **25/25**, with no FAIL or SKIP, on that merged
source. The wrapper takes 969.011 s including lock waits, at endpoint loads
8.44/8.71/9.01 -> 6.80/7.03/8.00. Exact commands and the complete summary
are in `.re/s13/e3/VALIDATION.md` and `s15-full-gate-r1-logs/summary.txt`.
The final fresh fetch still resolves main to `e8d4acd4`; its Engine/fork
log since the last merge is empty. The review checklist is complete and
the final audit finds no owned process or screen-priority flag. The child
hands the branch and PR body draft to the lead; it opens no PR.

Historical whole-process AD3 FAILs remain unchanged: E3 5.734/6.078 MiB
and E4 11.11 MiB. Whole-process on/off pairs are now record-only under the
explicit lead ruling. The earlier private continuation is retired; the
current scope uses the strict harness with no AD3 bypass. F also observes
browser PA growth of about 32 MB over 25 s with both engines unloaded;
the owner is unknown and the allocation-stack follow-up remains open.
The optional Section 12 App tile adapter is absent from this main, so its
acceptance is N/A; E3 does not create a second tile.
The no-engine generation, distribution, Debug build and quiet G-5 gates
pass. Retain the earlier loaded CPU receipts (12.756 ms at load1 48–50
and 8.576 ms at 40–42) as historical attempts.
N-18 currently proves hook reachability only: no HTTP/3
endpoint establishes ready rejection. N-21 retains the accepted early-hints
network-fetch gap (R-14). Step 5 cosmetics and Step 9 soak remain later work.
