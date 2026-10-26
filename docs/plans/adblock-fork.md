# Ad blocking in the fork — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Revised 2026-10-26 after engine review round 1 of #97/#98/#100 (findings C-1,
C-2, 98-1, 98-2, 98-4, 100-1, 100-5): the network hook (§7), the thread and
cost model (§7.6–§7.8), cosmetic delivery (§8), the DAT and resources model
(§9.2, §9.3) and memory (§6.6) changed. The appendix entry "Lead decisions
(2026-10-26)" lists every change and why. Where an older paragraph conflicts
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
  injected at document start. The design said "matched via a
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
| Cosmetic + scriptlets | Revised 2026-10-26: the renderer pulls the frame's sanitized selector lists at `DidCreateDocumentElement` over one process-level Mojo interface served on the matcher sequence, inserts them as user-origin style sheets, runs scriptlets in the main world and the class/ID observer in an isolated world; procedural selectors are dropped in v1; `generichide` / `#@#` exceptions (§8) |
| Lists | Bundled EasyList + EasyPrivacy fetched at build time from official URLs with pinned SHA-256 (never from Arc's bundle or mirror); a bundled, pinned `resources.json` for scriptlets/redirects (no runtime update in v1); per-Profile storage, ETag update flow, DAT fast startup only for lossless list sets (§9) |
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
- `$redirect` stub responses for CORS-mode requests (fetch/XHR across
  origins, module scripts, `crossorigin` elements). Revised 2026-10-26: the
  proxy serves the crate's redirect resource as a stub response for
  no-CORS and same-origin requests of any type, and blocks CORS-mode
  requests that match a redirect rule (§7.4).
- Procedural cosmetic filters (`#?#`, `:has-text()`, `:-abp-*`, `:xpath()`,
  `:upward()`, `:matches-css*()` and the other uBO/ABP extended operators).
  Revised 2026-10-26: the crate passes them through as plain selectors
  when `css-validation` is off (review 98-1), so the shim drops them (§8.3).
  `:style()` and the uBO `:remove*()` actions stay in v1 (§8.3).
- `$removeparam` on main-frame and subframe navigations. v1 rewrites
  subresource GET/HEAD requests only (§7.4).
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
| F-22 | Factory call sites: document subresources and the fetch-keepalive factory (`render_frame_host_impl.cc:14255-14268`, `:8469-8477`); dedicated and shared worker subresources (`dedicated_worker_host.cc:726`, `shared_worker_host.cc:529`); worker main scripts (`worker_script_fetcher.cc:523`); service worker scripts and fetches (`embedded_worker_instance.cc:385,399`); navigations (`navigation_url_loader_impl.cc:711`); early hints (`navigation_request.cc:5704`); DevTools (`devtools/protocol/network_handler.cc:4154`). WebUI and other non-network scheme factories are also wrapped as `kDocumentSubResource` (`render_frame_host_impl.cc:12860-12875`, `:12985-13005`) | `grep -rn 'URLLoaderFactoryType::k' content/browser` |
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
| D-2 | The FFI is **one CXX bridge** in `//open/adblock/rust`. All Rust types cross as strings, string vectors, and three flat structs (§5.2). The browser renders CSS text in Rust; C++ never sees a selector container | Hand-written `extern "C"` with manual memory management; returning `UrlSpecificResources` field-by-field to C++ | CXX is the tree's supported bridge (F-7). Pre-rendered strings keep the C++ cosmetic code to "insert this text" and keep crate-type churn inside the shim on crate bumps |
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
| D-14 | The cosmetic payload is **sanitized vectors**, not CSS text. The shim drops procedural selectors and unsafe selector and declaration text. The renderer builds one rule per selector and inserts it with `WebDocument::InsertStyleSheet(…, blink::WebCssOrigin::kUser)` (F-29). §8.3 | As built in #98: one combined `hide_css` rule and `<style>` elements made by a main-world script | One non-CSS selector removed all hiding on the page (98-1). Lists could inject CSS with `url()` beacons into every page (98-2). `<style>` elements are visible to and removable by page scripts, and building them in JS needed hand escaping. A user-origin `!important` declaration also wins over the page's `!important` |
| D-15 | A DAT is reused only when its build was **lossless** and its receipt carries the running `engineFormat`. Resources are never in the DAT and are applied after every deserialize. `resources.json` is a bundled, pinned build artifact and a manifest input of every generation; v1 never downloads resources at run time. §9.2, §9.3 | Reuse any DAT whose input receipt matches (as built in #100); resources updated with the lists (old §9.3) | A v0 DAT drops `$removeparam` and the `:remove*()` actions (F-31) and carries no resources (98-4, 100-1(b)). After a crate or shim change an old DAT can still decode with old semantics (100-1(a)). Resources are code that runs in the main world of every page; list hosts can already change CSS on every page (review "Check 5") |
| D-16 | Profiles whose verified inputs are identical **share one engine** through a process-wide registry keyed by content hashes. Every engine is freed on the build runner. Builds run one at a time per process, with a 128 MiB total input cap. §6.6 | One engine per `CefBrowserContext` (as built in #100) | N Profiles on the default lists cost N × ~32 MiB (100-5). Toggle, exclusions, counts and storage stay per Profile; only immutable rule data is shared |
| D-17 | **Match input cap.** The shim matches at most the first 8 KiB of the URL spec, with the fragment removed, cut after the last ABP separator character inside the cap. `$removeparam` never applies to a capped URL. §7.7 | No cap; a 16–32 KiB cap (review C-2) | The page controls URL length (up to 2 MiB) and cost grows linearly with it (F-35), while each check holds the engine mutex for the whole process. 8 KiB keeps one check under ~1 ms with the D-12 regex features (estimate from F-35; a guess until gate G-3 measures it) |

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
          open_adblock_renderer_agent.h/.cc  # document-start pull, style insertion, scriptlets (§8.3)
          open_adblock_page_script.h/.cc     # fixed isolated-world script as a C++ raw string (§8.3)
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
| P-3 `03xx-open-adblock-network-hooks.patch` (revised 2026-10-26) | `cef` | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.h`, `.cc` only | One call at the top of the CEF branch of `WillCreateURLLoaderFactory`; one line in `ExposeInterfacesToRenderer`; three new one-line overrides `WillInterceptWebSocket`, `CreateWebSocket`, `WillCreateWebTransport` that forward to `open_engine::` free functions; one include (§7.1, §8.2). Budget: about +45/−0 lines. `//open/adblock` already reaches `libcef_static` through `open_libcef_deps` (Step 3 as built), so no `cef/BUILD.gn` hunk |
| P-4 `03xx-open-adblock-renderer-hook.patch` (revised 2026-10-26) | `cef` | `cef/libcef/renderer/chrome/chrome_content_renderer_client_cef.cc` only | In `RenderFrameCreated` (`:41-50`), one line after the `CefRenderFrameObserver` is made: `new open_engine::OpenAdBlockRendererAgent(render_frame);  // Deletes itself.`, plus one include (§8.3). The agent is its own `content::RenderFrameObserver`. Budget: about +3/−0 lines. **No** `cef.mojom`, `frame_host_impl`, `frame_impl` or `render_frame_observer` change |
| P-5 `0004-open-adblock-cef-api.patch` | `cef` | `cef/include/cef_request_context.h`, `cef/include/cef_browser.h`, `cef/libcef/browser/request_context_impl.h/.cc`, `cef/libcef/browser/browser_host_base.h/.cc` + translator output under `cef/include/capi/`, `cef/libcef_dll/` | The §11 Step 6 API. Translator output files **are** committed in the tree and therefore appear in this patch; regenerate, never hand-edit them |
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

Revised 2026-10-26: R-5, R-7 and R-8 are replaced by §5.5 and §8.3
(sanitized vectors, no CSS or procedural script text from Rust, redirect
URLs for every type).

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

### 5.5 Shim surface changes (revised 2026-10-26; entry gates)

Engine review round 1 found that the as-built shim (#98) cannot serve the
revised §7–§9. The engine lead fixes #98 separately; this plan does not
say whether each change lands in #98 or in the step that needs it. A step
must not start until every row it needs exists. These rows replace
§5.2's `OpenCosmeticResources`, R-5, R-7 and R-8 where they conflict.

| Change | Needed by | Finding | Rule |
|---|---|---|---|
| `OpenRequestType`, a shared CXX enum (`Document`, `Subdocument`, `Script`, `Image`, `Stylesheet`, `Font`, `Media`, `Object`, `Xmlhttprequest`, `Ping`, `Websocket`, `CspReport`, `Other`), replaces the `request_type: &str` argument. The shim maps it to the crate's strings (F-25) | Step 4 | 98-6 | No free-form string crosses the bridge, so no unknown string can change matching and no invalid UTF-8 can reach `rust::Str` |
| Match input cap inside `open_adblock_check` (§7.7). `OpenBlockerResult` gains `truncated: bool`; when it is true, `rewritten_url` is empty | Step 4 | C-2 | One place enforces the cap for every caller |
| `redirect_data_url` is filled for **every** request type, not only scripts. It is the crate's `data:<mime>;base64,…` string verbatim (F-32). C++ decides whether to serve it (§7.4) | Step 4 | — | The stub-response path (§7.4) serves any MIME type |
| `open_adblock_deserialize(engine, dat, resources_json) -> bool` returns false when `dat.len() <= 4` before calling the crate, and calls `use_resources` after a successful deserialize | Step 4 (guard), Step 7 (resources) | 98-3, 98-4 | F-31: the DAT carries no resources |
| `open_adblock_build` returns a build report next to the engine: `lossless: bool` and `lossy_kinds: Vec<String>` (subset of `removeparam`, `remove`, `remove-attr`, `remove-class`), plus `resources_loaded: u32` and an error kind for resources JSON | Step 4 | 98-4, 98-5, 100-1(b) | `lossless` comes from a conservative scan of the list texts: a non-comment line that contains `removeparam`, `:remove(`, `:remove-attr(` or `:remove-class(` makes the set lossy. False positives only cost a text build |
| `open_adblock_engine_format() -> String`: `adblock=0.8.11;shim=<N>;features=<sorted crate features>;regex=<sorted regex features>;dat=v0`. `N` is a constant in `lib.rs`, bumped on any change to `ParseOptions`, permissions, features or bridge semantics | Step 4 | 100-1(a) | The receipt binds it (§9.2) |
| Cosmetic result as sanitized vectors: `OpenCosmeticResources { hide_selectors: Vec<String>, style_rules: Vec<OpenStyleRule { selector, declarations }>, remove_selectors: Vec<String>, remove_attrs: Vec<OpenRemoveRule { selector, names }>, remove_classes: Vec<OpenRemoveRule>, scriptlets: String, exceptions: Vec<String>, generichide: bool, dropped_procedural: u32, dropped_unsafe: u32 }`, all vectors sorted. `open_adblock_hidden_selectors` sanitizes its output the same way. No CSS text is built in Rust | Step 5 | 98-1, 98-2 | Sanitizer rules: §8.3 |

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

Revised 2026-10-26: the "any thread" `Check()` / `CosmeticResources()` /
`HiddenSelectors()` and the `shared_mutex` below are replaced at Step 4
by the matcher-sequence model of §6.7 and §7.6. The namespace is
`open_engine` (Step 3 as built).

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

Revised 2026-10-26: the throttle sources below are replaced by the §3.1
files (matcher, registry, factory proxy, socket hooks, hooks, cosmetics
host, renderer agent, page script, tab helper) and a dep on
`//open/adblock/mojom`. The include-path note stays.

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
| Resources JSON | 4 MiB read cap (bundled file; Step 7 records its real size) | Guess at headroom; the uBO resources set is about 1 MiB today (guess) |

**Budgets (Step 9 gates, measured as `phys_footprint` of the browser
process, `footprint` tool or `vmmap --summary`):**

| Measure | Budget | Basis |
|---|---|---|
| One EasyList + EasyPrivacy engine, steady state, with the D-12 regex features | ≤ 40 MiB | 32 MiB measured standalone (F-35); the in-tree allocator and the regex lazy-DFA caches can add some (guess) |
| Second Profile with the same lists | ≤ +2 MiB | Shared engine; only matcher state (exclusions, toggle) is per Profile |
| Text build transient | ≤ +100 MiB above steady state, back to steady state ≤ 5 s after the swap | 80 MiB measured |
| All 5 generic + privacy lists enabled | Record only (no gate in v1) | R-7; decides whether any non-default list becomes a default |

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
  only on the matcher sequence (`SEQUENCE_CHECKER`). It holds the
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
  starts no thread. The service makes its matcher in its constructor
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
     If the check allows, the continuation calls Chrome's
     `CreateWebSocket` when `ChromeContentBrowserClient::WillInterceptWebSocket(frame)`
     is true; otherwise it runs `factory` itself with the user agent as
     its only additional header, as WebRequest's socket proxy does
     (`web_request_proxying_websocket.cc:347-348`). Content's own
     path also adds DevTools override headers (`websocket_connector_impl.cc:153-158`);
     an intercepted socket loses them, as it does with WebRequest today. If the
     check blocks, the overlay calls
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
   per page, so one round trip each is acceptable.
4. **Include.** `#include "open/adblock/open_adblock_hooks.h"` in the `.cc`.

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
| `kEarlyHints` | yes | Preloads that a main-frame `103` response asks for |
| `kDownload` | no | A user action |
| `kPrefetch` | no | Speculation-rules prefetch of documents, which are main-frame loads |
| `kDevTools` | no | DevTools-initiated loads |

The factory context is captured on the UI thread and is immutable:

- the Profile's `scoped_refptr<OpenAdBlockMatcher>` (§6.7);
- the type and `request_initiator`;
- the **top site**: the registrable domain (or the host, for IP literals
  and hosts without one) of `isolation_info.top_frame_origin()` when it
  is set (renderer factories, F-17); otherwise of
  `frame->GetOutermostMainFrame()->GetLastCommittedOrigin()` when `frame`
  is set; otherwise of `request_initiator`. For a service worker this is
  its own storage top site, so an excluded site's service worker is
  excluded too;
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
   excluded, the URL is not `http`/`https`, or
   `request.is_outermost_main_frame` is true (defensive; such factories
   are not wrapped). The proxy calls the target's `CreateLoaderAndStart`
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
   factory is not a navigation factory, and the rewritten URL has the
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

**Regex features.** The gates assume review 97-1 lands with #97: regex
features `std`, `unicode`, `perf-dfa`, `perf-onepass`, `perf-backtrack`,
`perf-cache`, `perf-inline`, without `perf-literal`, so aho-corasick stays
out of the build. With only `std` + `unicode` the review measured 28.8 µs
per realistic URL (F-35): G-2 would fail, and that failure is the lead's
trigger to take 97-1.

### 7.7 Match input cap (D-17)

In the shim's `open_adblock_check` (§5.5):

1. Remove the fragment (`#…`). Fragments never go to the server. Guess:
   lists rarely target them.
2. If the rest is at most 8,192 bytes, match it whole.
3. Else cut after the last ABP separator byte at or before byte 8,192
   (a separator is any byte that is not `A–Z a–z 0–9 _ - . %`, the class
   that `^` matches), match that prefix, set `truncated = true`, and leave
   `rewritten_url` empty.

Effect on filter correctness:

- Rules anchored on the host (`||host^`) and rules that match within the
  first 8 KiB behave as before. Guess: these are almost all rules that
  matter for ads; real ad-tech URLs in the review were at most 2,040
  characters (F-35). Step 4 reports the share of corpus requests that hit
  the cap (expected 0).
- A rule that could match only after byte 8,192 is missed (a false
  negative). This is the accepted cost.
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

Corpus: capture at least 2,000 subresource URLs from at least 20 public
news and media pages with the §13.3 CDP driver, in a fresh
`--user-data-dir`, signed in to nothing. Store it under
`.re/adblock-corpus/` (git-ignored, AGENTS.md rule 2). Commit only the
summary in the PR: count, length percentiles, third-party share. The
pass/fail runs read the stored corpus; they never load live sites.
`corpus.html` requests every corpus URL with its scheme changed to `http`
and host, path and query kept; `cefsimple` runs with
`--host-resolver-rules="MAP * 127.0.0.1:8931"`, so the real host names are
matched and the local server answers (a 404 is fine).

Gates. All pass before Step 4 merges; real output in the PR; five runs,
medians unless stated:

| ID | Measure | Method | Pass |
|---|---|---|---|
| G-1 | No engine call on the UI or IO thread | `DCHECK_CALLED_ON_VALID_SEQUENCE` on every matcher entry point; in non-official builds also `CHECK(!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) && !content::BrowserThread::CurrentlyOn(content::BrowserThread::IO))` in the C++ check wrapper. The self-test prints the matcher thread name once | No CHECK during N-1…N-18 and the Step 9 soak; the name is a ThreadPool worker |
| G-2 | Check cost on real URLs | `--open-adblock-selftest --open-adblock-bench=<corpus file>` (non-official only): each corpus URL 10× through the real shim on the matcher sequence, real lists | mean ≤ 8 µs, p99 ≤ 60 µs, max ≤ 1 ms |
| G-3 | Long URLs | same bench with synthetic 8 KiB, 100 KiB and 2 MiB URLs (path of random letters) | each ≤ 1 ms |
| G-4 | Added request latency | proxy histogram from `CreateLoaderAndStart` arrival to the forward, printed at `--v=1` when the factory dies, on `corpus.html` | p50 ≤ 50 µs, p99 ≤ 500 µs |
| G-5 | Page wall time | `corpus.html`, `performance.now()` at `load` over CDP, real lists, blocking on vs off | median delta ≤ 5 ms; matcher busy time ≤ 3 ms per load |
| G-6 | Stalls | log every check > 1 ms with its cause (length, first regex use) during the G-5 runs and the Step 9 soak | ≤ 1 per 1,000 checks; none > 10 ms |
| G-7 | Off costs nothing | the same page in a Profile with blocking off vs a build without P-3 | delta within run-to-run spread; report both medians |

The gate numbers are guesses derived from F-35 with about 1.6× headroom
for the in-tree build. If a gate fails, the PR reports it and the lead
decides; nobody raises a budget to pass (§13.5).

### 7.9 Coexistence with extensions (#93, P1) and with CEF's proxy

Order, outer to inner: **Open ad block** → WebRequest proxy (UI thread;
present only while an extension with webRequest or declarativeNetRequest
is enabled, F-21) → other Chrome proxies → CEF's proxy (IO thread) →
DevTools → network service. Open's proxy wraps WebRequest's.

- A request that Open blocks never reaches extensions. `chrome.webRequest`
  listeners and declarativeNetRequest rules do not see it, and an
  extension's "allow" rule cannot unblock it. Brave makes the same choice
  (F-33). The user's override is the per-site toggle.
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

## 8. Cosmetic filtering and scriptlets (revised 2026-10-26)

This section replaces the 2026-10-25 design (a browser push over
`cef.mojom` and `<style>` elements made by a main-world script). Reasons:
the push cannot arrive before the document starts (F-27), one non-CSS
selector removed all hiding (98-1), and lists could inject CSS with
`url()` beacons (98-2). Decisions: D-13 (delivery), D-14 (payload and
insertion).

Arc baseline (F-34): Arc's renderer agent generates a cosmetic style
sheet; no evidence shows procedural filters or scriptlets in Arc 1.170
(guess). Open v1 hides with plain CSS like Arc, drops procedural selectors
like Arc (guess), and also runs scriptlets and the uBO `:style()` and
`:remove*()` actions, as adblock-design locked. That part is a superset of
Arc; the appendix lists it for the lead to confirm.

### 8.1 Data flow

```text
Renderer main thread, each frame document with an http(s) URL
  OpenAdBlockRendererAgent::DidCreateDocumentElement     (own RenderFrameObserver, P-4)
    -> [Sync] AdBlockCosmetics.GetDocumentCosmetics(document_url, top_origin)
         browser, matcher sequence (never the UI thread):
           matcher off, or top site excluded  -> null
           engine CosmeticResources(document_url)   (66 µs mean as built, Step 3)
         <- AdBlockDocumentCosmetics? (sanitized vectors, §8.3)
    -> WebDocument::InsertStyleSheet(hide rules,  kUser)   one rule per selector
    -> WebDocument::InsertStyleSheet(style rules, kUser)
    -> WebLocalFrame::ExecuteScript(scriptlets)            main world
    -> WebLocalFrame::ExecuteScriptInIsolatedWorld(world, page script)
         page script: apply removals now, at DOMContentLoaded, and on mutations;
         if !generichide: collect class/ID tokens, debounce 100 ms
  page script -> __openAdBlock.report(classes, ids)         binding, isolated world only
    -> AdBlockCosmetics.GetGenericSelectors(classes, ids, exceptions)   async
         browser, matcher sequence: HiddenSelectors(...)
    <- selectors -> InsertStyleSheet(batch rules, kUser)
```

### 8.2 The interface and its binding (D-13)

Overlay `open/adblock/mojom/open_adblock.mojom` (the only Open-owned Mojo
interface in this plan):

```mojom
module open_engine.mojom;

import "url/mojom/origin.mojom";
import "url/mojom/url.mojom";

struct AdBlockStyleRule {
  string selector;
  string declarations;   // sanitized, ';'-separated, '!important' added (§8.3)
};

struct AdBlockRemoveRule {
  string selector;
  array<string> names;   // attribute or class names
};

struct AdBlockDocumentCosmetics {
  array<string> hide_selectors;
  array<AdBlockStyleRule> style_rules;
  array<string> remove_selectors;
  array<AdBlockRemoveRule> remove_attrs;
  array<AdBlockRemoveRule> remove_classes;
  string scriptlets;          // main-world script; "" if none
  array<string> exceptions;   // #@# generic exceptions; echoed back
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

  // Generic class/ID selectors for tokens the page script has not sent before.
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

- `GetDocumentCosmetics`: return null unless the matcher is enabled, the
  URL is `http`/`https`, and the registrable domain (or host) of
  `top_origin` is not excluded. Else run the shim's cosmetic query and
  convert the vectors to the mojom struct. No UI-thread step, no file I/O.
- `GetGenericSelectors`: cap the input at 500 classes plus 500 IDs per
  call (drop the rest), run `HiddenSelectors`, reply.
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

**Cost.** One sync round trip per http(s) document: IPC to the matcher
sequence, queue time, the query (66 µs mean as built), and the reply.
Guess: 0.1–0.3 ms per document on an idle machine, also when blocking is
off (the browser answers null). CEF already makes a sync call for each new
browser on the same kind of pipe (F-28). Step 5 gates it (C-G1, C-G2 in
§11). If C-G2 (blocking off) fails, the remedy is a per-process "off"
flag that the browser pushes on a second, renderer-bound interface, so the
agent can skip the call; that is a Step 5 decision, not v1 default.

### 8.3 Payload: sanitizing, insertion, and what v1 drops (D-14)

**Sanitizer (shim, Rust, §5.5).** It runs on every selector and
declaration that crosses the bridge, including generic selectors.
Matching is ASCII case-insensitive.

A selector is **dropped** when any of these holds:

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

A `:style()` declaration list is **dropped** when it contains `url(`,
`image(`, `image-set(`, `cross-fade(`, `element(`, `attr(`,
`expression(`, `\`, `/*`, `{`, `}`, `@`, `<`, or a quote (`"` or `'`).
Otherwise the shim splits it on `;` and appends ` !important` to every
declaration that lacks it, so the rule wins in the user origin (below).
The quote rule keeps `;` splitting safe; guess: few `:style()` rules use
strings.

Each frame payload is capped at 256 KiB of selector text; selectors past
the cap are dropped in sorted order. The shim counts drops
(`dropped_procedural`, `dropped_unsafe`) and `AdBlockStatus` reports the
sums for debug info (AD-8).

With the sanitizer, no list text can open a new rule, close a block, load
a resource, or run script from CSS. Hide rules have a fixed declaration
with no URL. That closes 98-2 at the source, and per-rule insertion
(below) closes 98-1 even for a selector the sanitizer lets through but
Blink rejects.

**Insertion (renderer).** In `DidCreateDocumentElement`, when the reply is
non-null:

1. Build the hide sheet text in C++: one rule per selector,
   `<selector>{display:none!important}` joined by newlines. Insert it with
   `frame->GetDocument().InsertStyleSheet(text, nullptr, blink::WebCssOrigin::kUser, blink::BackForwardCacheAware::kAllow)`
   (F-29). Blink's parser drops a rule with an invalid selector and keeps
   the rest; one rule per selector costs no extra matching (F-29).
2. Build and insert the style sheet the same way, one
   `<selector>{<declarations>}` rule per entry.
3. Chunking: the initial payload is at most two sheets (hide, style).
   Each generic reply becomes one more sheet of at most 500 rules. A
   document gets at most 64 generic sheets; after that the agent stops
   asking and logs once at `--v=1`. Several insertions in one task cost
   one style recalc. Guesses, measured at Step 5 (C-G3).
4. Why the user origin: a user `!important` declaration beats an author
   `!important` declaration in the cascade, so a page cannot undo the
   hiding with its own `!important`. The sheets are not in the
   document's style sheet list (F-29), so page scripts cannot read or
   remove them; C-8 checks `document.styleSheets` stays unchanged. No
   DOM element is added and no JS string is built from CSS, so the old
   §8.3 escaping hazard is gone.

**Scriptlets.** `scriptlets` is the crate's injected script (uBO
scriptlets from the bundled `resources.json`, §9.3), with arguments
escaped by the crate (F-32). The agent runs it once per document with
`frame->ExecuteScript(blink::WebScriptSource(...))` in the main world, in
`DidCreateDocumentElement`, after the style sheets and before the parser
runs page scripts (the extension `document_start` point, F-29). Guess:
an embedder `ExecuteScript` is not subject to the page's CSP; C-9 checks
it on a page with `script-src 'self'`. No list gets scriptlet
permissions, so trusted scriptlets never run (F-32).

**Removals and tokens (isolated world).** The agent runs one fixed page
script (a C++ raw string in `open_adblock_page_script.cc`, written for
this plan, not copied from uBlock Origin or Brave) with
`ExecuteScriptInIsolatedWorld(ISOLATED_WORLD_ID_CHROME_INTERNAL, ...)`
(`chrome/common/chrome_isolated_world_ids.h:19-20`, "internal Chrome
features"; P7 may later give Open its own world). In
`DidCreateScriptContext` for that world only, the agent installs one
native object `__openAdBlock` with two functions: `payload()` returns the
removal rules, exceptions and `generichide` as V8 values (no JSON string
is spliced into script), and `report(classes, ids)` sends one
`GetGenericSelectors` call. The script:

- applies `remove_selectors` (`element.remove()`), `remove_attrs` and
  `remove_classes` once at start, once at `DOMContentLoaded`, and after
  each debounced mutation batch; a selector that throws in
  `querySelectorAll` is skipped;
- when `generichide` is false, collects `class` and `id` tokens from the
  document and from a `MutationObserver` on `document.documentElement`
  (`subtree`, `childList`, `attributes: ["class", "id"]`), debounces
  100 ms, sends at most 500 new tokens per batch, and never sends a token
  twice per document.

The page cannot see the isolated world's objects. The old page-visible
globals `__openAdBlockProcedural` and `__openAdBlockTokens` no longer
exist. `CefRenderFrameObserver` passes every world's context to CEF's
`OnContextCreated` (F-29), so OpenEngine's own context hook also runs in
this world; it must ignore contexts it does not own (P7 follow-up).

**What happens to each filter kind in v1:**

| Kind | v1 | Why |
|---|---|---|
| `##sel`, `###id`, `##.class`, generic and domain-specific | Hidden by the user sheet | Arc does the same (F-34) |
| `#@#sel` exceptions | Applied inside the crate; generic exceptions echoed with token reports | — |
| `$generichide` | No token observer; domain rules still apply | — |
| `#?#`, `:has-text()`, `:-abp-contains()`, `:-abp-has()`, `:xpath()`, `:upward()`, `:matches-css*()` and the other extended operators | **Dropped** by the shim, counted | They are not CSS; the crate passes them through as plain selectors when `css-validation` is off (98-1). Arc shows no support either (F-34, guess) |
| `##sel:has(...)` (native CSS) | Hidden | Chromium 156 supports `:has()` |
| `##sel:style(decl)` | Inserted as a user rule after sanitizing, `!important` added | 98-2 |
| `##sel:remove()`, `:remove-attr()`, `:remove-class()` | Applied by the isolated-world script | Not in a DAT: a set with these rules builds from text (§9.2) |
| `##+js(...)` scriptlets | Main world, document start | adblock-design locked; Arc shows no support (F-34, guess) |
| `#$#` (ABP snippets), `##^` (HTML filters) | Ignored | The crate does not apply them |

Subframes: each frame asks for its own document URL; scriptlets run per
frame (uBO semantics). Back/forward cache restores keep the document and
its injected sheets (`BackForwardCacheAware::kAllow`), so they need no new
payload and do not flash. Same-document navigations keep the sheets.

Zap merge note: Boosts and Zap selectors (M6 sibling feature) use the
same user-origin insertion when Zap lands; their sheets go in after the
blocker's. This plan only reserves that order.

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

#### 9.2.1 When a DAT may be reused (revised 2026-10-26, D-15)

A v0 DAT is not a full copy of the engine (F-31): it loses `$removeparam`
rules, the `:remove()`, `:remove-attr()` and `:remove-class()` actions,
scriptlet permissions and the regex discard policy, and it never carries
resources. After a crate or shim change, an old DAT can still decode and
silently keep the old semantics (review 100-1(a)). Rules:

1. **Write** a DAT only when the text build reported `lossless == true`
   (§5.5). A lossy set (any list with `$removeparam` or `:remove*()`
   rules) builds from text on every load and writes no DAT and no
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

### 9.3 Scriptlet / redirect resources (uBlock Origin)

**Revised 2026-10-26 (D-15).** These rules replace the paragraphs below
where they conflict:

- **Format.** The shim takes the crate's own serialized `Vec<Resource>`
  as JSON (Step 2 as built in #98), not a path, because the crate's
  assembler reads only paths, has a deprecated scriptlet entry point and
  panics on malformed files. The runtime file is `resources.json`.
- **Production.** Step 7 makes `resources.json` at build time on the
  developer machine: fetch the pinned uBlock Origin `assets/resources/`
  sources from the official repository host, run the crate's assembler
  offline in a throwaway Cargo driver under `/tmp` (never in the browser),
  and pin the **output** SHA-256 in `resources-pins.txt` next to the
  source pin. `tools/fetch-adblock-lists.sh` stages it under
  `Vendor/adblock/`; it is not committed (GPL-3.0 data, same rule as list
  text).
- **Manifest input.** Swift copies the bundled `resources.json` into every
  generation and lists it in `manifest.json` (`file: "resources.json"`,
  `listID: "_resources"`, `sourceRevision` = the pin), so the engine
  verifies its size and SHA-256 like a list. The engine key (§6.6) and
  the DAT receipt (§9.2.1) include its hash.
- **No runtime download in v1.** Resources are code that runs in the
  main world of every page. v1 changes them only with an app update,
  never from the network. The old "Versioning: resources update with the
  lists" paragraph below is void; §9.5 no longer fetches resources.
- **Version.** The resources version is its pinned SHA-256. Debug info
  (AD-8) reports the first 12 hex digits and `resources_loaded`.

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
    -> pass through | open_adblock_check (≤ 8 KiB input) -> block | stub | 307 rewrite | proxied loader
  OpenAdBlockURLLoader::OnReceiveRedirect -> check new URL -> block | forward
  counts -> at most one UI task per factory per 100 ms -> OpenAdBlockTabHelper

Per socket (UI -> matcher -> UI):
  CreateWebSocket / WillCreateWebTransport -> check -> OnFailure / WebTransportError | Chrome's path

Per document (renderer main thread -> matcher sequence):
  OpenAdBlockRendererAgent::DidCreateDocumentElement
    -> [Sync] AdBlockCosmetics.GetDocumentCosmetics -> sanitized vectors
    -> InsertStyleSheet(kUser) x2, ExecuteScript(scriptlets), isolated-world page script
  Token batches (isolated world, debounced) -> GetGenericSelectors (async) -> InsertStyleSheet(kUser)

Per tab (UI thread):
  OpenAdBlockTabHelper (WebContentsUserData) counts; reset on primary main-frame commit.
  CefBrowserHost::GetOpenAdBlockBlockedCount() reads it (§11 Step 6).
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
- [ ] Shutdown cleanliness: quit `cefsimple` mid-build (start a load,
      quit within 1 s) five times; no crash, no hang, no leftover
      renderer processes (`pgrep -f cefsimple` empty).

PR: overlay service files + P-2. One PR.

### Step 4 — URLLoaderFactory proxy, sockets, counters (§7; revised 2026-10-26)

Entry gate (stop if any is false):

- #97, #98 and #100 are merged, and these review fixes are in: 97-1
  (regex features) or a lead decision against it; 98-3 (4-byte DAT
  guard); 100-1(a) (`engineFormat` in the receipt); 100-2 (engines freed
  off the UI thread); 100-3 (switches out of official builds); 100-4
  (exclusion matching). The §5.5 rows marked "Step 4" exist.
- No build is running (§Prerequisite gate).

Work:

- §6.6 and §6.7: matcher state on the matcher sequence, process-wide
  build runner and engine registry, build-runner deleter, caps.
- Overlay `open_adblock_matcher.*`, `open_adblock_engine_registry.*`,
  `open_adblock_url_loader_factory.*`, `open_adblock_socket_hooks.*`,
  `open_adblock_hooks.*`, `open_adblock_tab_helper.*`, `BUILD.gn` source
  additions. The cosmetics binder is wired at Step 5, not here.
- Patch P-3 without the `ExposeInterfacesToRenderer` line (Step 5 adds it
  to the same patch).
- Self-test bench switch `--open-adblock-bench=<file>` (non-official only).
- Smoke harness P-6 in its §13.1 form (switches + load-end count logging),
  so Steps 4–6 verify through it.

Acceptance (record CDP output and the gate table in the PR):

- [ ] Build green; `cefsimple` with no ad-block switches behaves like
      stock (smoke A + the test page fully loads, no count logging).
- [ ] §13.3 N-1…N-18 pass, including main frame never blocked (N-13) and
      the per-site exclusion case (N-6).
- [ ] Blocked subresources show `net::ERR_BLOCKED_BY_CLIENT` in CDP
      `Network.loadingFailed` (`errorText`).
- [ ] Counter resets on reload and navigation and survives `pushState`
      (§7.5), CDP-checked; counts of a closed document are dropped.
- [ ] Gates G-1…G-7 (§7.8) pass, with the corpus summary in the PR.
- [ ] `phys_footprint` of the browser with one engine, and with two
      Profiles on the same lists (`engine_shared=1` in the second's
      status): within §6.6 budgets.
- [ ] Patch size: P-3 diff stat in the PR, about +45/−0 in two files.

PR: overlay files + P-3 + P-6. One PR (P-6 is test-only and called out as
such).

### Step 5 — Cosmetic filtering + scriptlets (§8; revised 2026-10-26)

Entry gate: the §5.5 cosmetic row (sanitized vectors, review 98-1 and
98-2) exists in the shim. If #98 merged with the combined `hide_css`
output, this step does not start until the vector output replaces it.

Work: overlay `mojom/` (interface + `BUILD.gn`),
`open_adblock_cosmetics_host.*`, `renderer/open_adblock_renderer_agent.*`,
`renderer/open_adblock_page_script.*`; the `ExposeInterfacesToRenderer`
line in P-3; patch P-4 (one line in the renderer client).

Acceptance (§13.3 C-1…C-10 and the gates below; real output in the PR):

- [ ] Build green. Mojo bindings are generated by GN; the patches contain
      no generated files (`git diff --stat` shows only the §3.3 files).
- [ ] C-1…C-10 pass.
- [ ] **C-G1 (blocking on):** renderer-side time of the sync
      `GetDocumentCosmetics` call, logged at `--v=1` per document, on
      `index.html` and 20 corpus pages through `--host-resolver-rules`:
      p50 ≤ 0.5 ms, p99 ≤ 3 ms (guesses; F-28 precedent, query 66 µs as
      built).
- [ ] **C-G2 (blocking off):** the same with blocking off: p50 ≤ 0.3 ms.
      If it fails, record it; the Step 5 remedy is the per-process "off"
      push of §8.2.
- [ ] **C-G3 (insertion):** renderer time for the two initial
      `InsertStyleSheet` calls on gamedev.net-sized payloads (≥ 400
      selectors, from the corpus): ≤ 2 ms (guess).
- [ ] No page-visible `__openAdBlock*` global, and `document.styleSheets`
      unchanged by Open (CDP enumerates both).

PR: P-4 + the P-3 line + overlay files. One PR. The PR quotes the
sanitizer rules as implemented (security callout, 98-2).

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
/// Added 2026-10-26: engine_shared (bool, §6.6), dat_policy ("dat" |
/// "text-only"), lossy_kinds (list of strings), resources_version
/// (first 12 hex digits), resources_loaded (int), cosmetic_dropped_procedural
/// (int), cosmetic_dropped_unsafe (int), checks_truncated (int, §7.7).
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
- [ ] Revised 2026-10-26 (§9.3, §9.2.1): `resources.json` is produced
      offline by the `/tmp` assembler driver and its output SHA-256 is
      pinned; Swift copies it into each new generation as the
      `_resources` manifest entry; the engine verifies it, and after a
      DAT load `resources_loaded > 0` and C-5 still passes (review 98-4).
- [ ] The lossy §13.2 `testlist.txt` generation never writes a DAT: two
      runs both report `engine_from_dat=0 dat_policy=text-only`, and N-5
      passes on both runs (review 100-1(b)). The lossless
      `scriptlet-list.txt` generation loads from its DAT on the second run
      and C-5 passes there.

Entry gate (revised 2026-10-26): the §5.5 deserialize row (resources
after deserialize, review 98-4) exists before this step starts.

PR: tools + `Engine/fork/adblock/**` + the Swift manifest change. One PR.

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
--open-adblock-bench=<file>     added 2026-10-26, with --open-adblock-selftest:
                                check every URL of <file> (one per line,
                                optional "<type> <source-origin>" columns)
                                10x on the matcher sequence, print mean,
                                p50, p99, max and the matcher thread name (G-1..G-3)
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
Revised 2026-10-26: the file is `resources.json` (§9.3), listed in the
fixture manifest as `_resources`.

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
127.0.0.1##.style-evil:style(background: url(http://127.0.0.2:8932/beacon.gif))
127.0.0.1##.proc-ad:has-text(Sponsored)
127.0.0.1##x{} .exfil{background:url(http://127.0.0.2:8932/exfil.gif)} y
127.0.0.1##.remove-me:remove()
```

`testlist.txt` is lossy (`$removeparam`, `:remove()`), so it always
builds from text. A second fixture generation, `scriptlet-list.txt`, is
lossless: only `127.0.0.1##.ad-slot` and `127.0.0.1##+js(open-test-scriptlet)`,
with the same `resources.json`. It proves the DAT path with resources.

New test files:

- `worker.html`: starts `worker.js` (a dedicated worker that fetches
  `/ads/worker-ad.js` and `/api/data.json` and posts both outcomes) and
  registers `sw.js` (a service worker that fetches `/ads/sw-ad.js` on
  `install` and stores the outcome in Cache Storage). `127.0.0.1` is a
  secure context, so the service worker can register over HTTP.
- `frames.html`: iframes `http://127.0.0.2:8932/frame-ad.html` (blocked)
  and `/csp-frame.html` (allowed; its inline script sets
  `window.__cspInlineRan = 1`, which the list CSP must stop). It also has
  `<div class="style-target">`, `<div class="style-evil">`,
  `<div class="proc-ad">Sponsored</div>`, `<div class="exfil">`,
  `<div class="remove-me">` and, for the per-rule check, a page whose
  hostname rules include both `.ad-slot` and `.proc-ad:has-text(...)`.
- `fetch.html`: `fetch('/api/xhr-only.json')` (blocked: XHR type) and
  `<script src="/api/xhr-only.json">` (allowed: script type);
  `fetch('http://127.0.0.2:8932/ads/banner.js', {headers: {'X-Open-Test': '1'}})`
  (a request that would need a preflight); `new WebSocket('ws://127.0.0.2:8932/ws')`
  (blocked) and `new WebSocket('ws://127.0.0.1:8931/ws')` (allowed; fails
  at the server); `fetch('/api/data.json?' + 'a'.repeat(2 * 1024 * 1024))`
  (long URL); `<script src="/redirect?to=http://127.0.0.2:8932/ads/redirect-target.js">`.
- `csp.html`: served with `Content-Security-Policy: script-src 'self'`
  and the scriptlet rule active, for C-9.
- `blocked-main.html`: a plain page; the `$document` rule must not block it.

Server: `python3 -m http.server` cannot redirect, set headers or log
methods. Use a throwaway stdlib server `/tmp/open-adblock-server.py`
(never committed) for both origins. It serves the testdata directory,
answers `/redirect?to=<url>` with a 302, sends the CSP header on
`csp.html`, and logs every request line with its method, so N-14 can
assert that no `OPTIONS` reached it.

Extension fixture (N-15), throwaway under `/tmp/open-adblock-ext/`, loaded
with `--load-extension`: an MV3 extension with `webRequest` (it records
every `onBeforeRequest` URL in `chrome.storage.session`) and one
declarativeNetRequest rule that redirects `/ext-redirect.js` to
`http://127.0.0.2:8932/ads/redirect-target.js`.

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

Network cases (Steps 4+; N-9…N-16 added 2026-10-26):

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
| N-18 | WebTransport | if no local HTTP/3 server exists, state it in the PR and check only that `new WebTransport('https://127.0.0.2:8933/x')` on a test rule `\|\|127.0.0.2:8933^` logs one block at `--v=1` |

Cosmetic cases (Step 5+; revised 2026-10-26):

| ID | Page | Assert (via `Runtime.evaluate` `getComputedStyle`) |
|---|---|---|
| C-1 | `index.html` | `.ad-slot` display `none`; no `<style>` element was added by Open |
| C-2 | `index.html` | `.ad-slot-allowed` display not `none` |
| C-3 | `generichide.html` | `.generic-ad` visible; `.ad-slot` hidden; no `GetGenericSelectors` call in the `--v=1` log |
| C-4 | `index.html` at +2 s | late `.late-ad.generic-ad` node display `none` (token round-trip) |
| C-5 | `index.html`, and again after a DAT load of `scriptlet-list.txt` | `window.__openTestScriptlet == 1` (resources re-applied after deserialize, review 98-4) |
| C-6 | excluded (N-6 run) | `.ad-slot` visible; the sync call returned null (`--v=1`) |
| C-7 | `frames.html` | 98-1: `.ad-slot` hidden although the page's rules include a `:has-text()` selector; `.proc-ad` visible (procedural dropped); `.style-target` has the red outline; 98-2: `.style-evil` and `.exfil` have no background image and the 127.0.0.2 server log has no `beacon.gif` or `exfil.gif`; `.remove-me` is gone from the DOM after `DOMContentLoaded`; status `cosmetic_dropped_procedural ≥ 1`, `cosmetic_dropped_unsafe ≥ 2` |
| C-8 | `index.html` | `document.styleSheets.length` equals the page's own count; a page script that sets `.ad-slot { display: block !important }` cannot show `.ad-slot` (user-origin `!important` wins) |
| C-9 | `csp.html` | `window.__openTestScriptlet == 1` despite `script-src 'self'` (checks the §8.3 guess) |
| C-10 | `index.html` | no own property of `window` whose name starts with `__openAdBlock` |

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
| Page overhead | Revised 2026-10-26: gate G-5 (§7.8) on `corpus.html` with real URLs, replacing the short-path `many.html` | ≤ 5 ms added per 200 requests; matcher busy ≤ 3 ms per load |
| Request checks | gates G-1…G-4, G-6, G-7 (§7.8) | as stated there |
| Cosmetic query | time 100 cosmetic queries on the matcher sequence in the selftest on the real lists and print the mean; plus the renderer-side sync call (C-G1, C-G2) | ≤ 100 µs/page query (as built: 66 µs); C-G1/C-G2 as in §11 Step 5 |
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

---

## 14. Risks and open questions

| # | Risk / question | Plan's handling |
|---|---|---|
| R-1 | `adblock 0.8.11` fails under Chromium `rustc 1.100.0` (toolchain fragility already bit once, F-13/F-15) | Step 1 gate: stop, report verbatim, lead decides (crate bump reopens the design benchmark; D1 `subresource_filter` fallback in adblock-design stays the escape hatch) |
| R-2 | MPL-2.0 (crate) + GPL-3.0 (uBO resources) distribution obligations | Pins + `THIRD_PARTY.md` + license files land with the code (§4.5, §9.3); counsel review gates public release only (fork-infra Q-2) |
| R-3 | GN include-path / visibility friction between `//open/adblock` and `libcef_static` (§6.5) | Two sanctioned forms (seam function in P-4, or direct call); pick at Step 5, record it; never a link cycle |
| R-4 | Cosmetic payload arrives after the document starts | Revised 2026-10-26: resolved by the renderer pull at `DidCreateDocumentElement` (§8.2). BFCache restores keep their sheets; same-document navigations keep them |
| R-5 | `fetch()`/XHR type loss (`kEmpty` → `"other"`) weakens `$xmlhttprequest` rules | Revised 2026-10-26: resolved with `is_fetch_like_api` (F-25, §7.3, N-12) |
| R-6 | Scriptlet resources go stale; YouTube/news breakage appears first | Resources versioned with lists (§9.3/§9.5); per-site toggle is the user escape; **no** shipped pre-emptive allowlist (adblock-design Risk 4 — Arc's YouTube entry is for uBlock, not proven for this engine) |
| R-7 | Full 46-list memory: two lists = 6.78 MiB DAT; regional sets grow it | v1 defaults stay at two lists; Step 9 records DAT size + browser RSS with all generic+privacy lists enabled before any regional default is considered. 2026-10-26: shared engines and caps (§6.6) bound the per-Profile part |
| R-8 | Head-of-line blocking on the one matcher sequence (a regex compile, a long URL) delays every request in the process | Input cap (§7.7); regex features (97-1); G-6 counts stalls; remedy is a longer regex discard time, never a second matcher sequence (the crate mutex serializes anyway, F-30) |
| R-9 | The sync cosmetics call adds latency to every http(s) document, also with blocking off | C-G1/C-G2 gates (§11 Step 5); remedy: per-process "off" push (§8.2) |
| R-10 | Open's proxy is outermost, so extension blockers and DNR "allow" rules cannot see or unblock what Open blocks | Intended (§7.9, same as Brave, F-33); the per-site toggle is the override. Lead may revisit if an extension's documented feature breaks |
| R-11 | Sanitizer drops valid list rules (quotes in `:style()`, long selectors) | Counted in status (`cosmetic_dropped_*`); Step 5 reports the counts on 20 corpus pages; loosen a rule only with a new review of 98-2 |
| R-12 | P-3 hunk position in CEF's `WillCreateURLLoaderFactory` moves on a CEF bump | Rebase note (§11 Step 9): the Open call stays first in the CEF branch; N-15 proves the order after every rebase |
| R-13 | Worker WebSockets and frameless sockets are not checked | Known v1 gap (§7.2); Brave needed a content patch for it (F-33) |
| Q-1 | Does the app milestone want `OpenFeatures` created by Step 8 or later? | Step 8 decides by target existence (§11 Step 8); the §12.3 contract is normative either way |
| Q-2 | Exact uBO resources input format for crate 0.8.11's assembler | Resolved by reading the crate source at Step 7 (§9.3); if it needs a directory, the reserved-name change there applies |
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

Status: proposed by the design agent in this PR. Each item becomes a lead
decision when the lead approves the PR. Items marked **Confirm** need an
explicit answer from the lead. Inputs: engine review round 1
(`.re/reviews/adblock-97-98-100-r1.md`, git-ignored), a read-only pass over
the shared tree with #93 and ad-block Steps 1–3 applied, the adblock 0.8.11
source, Brave's public source (facts only, F-33), and ArcCore strings
(F-34, `.re/adblock-plan-r2/`). Steps 1–3 (#97, #98, #100) are not changed
here; the engine lead fixes them. This entry only adds entry gates.

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
   order (F-33). **Confirm** (R-10).
3. **Thread model (C-2).** One process-wide matcher sequence runs every
   engine call except builds. The proxy is bound on it and matches inline:
   no UI or IO thread work, no PostTask round trip per request (D-12,
   §7.6). The crate's per-engine mutex (F-30) is then never contended.
4. **Input cap (C-2).** The shim matches at most the first 8 KiB of a URL,
   cut at a separator; no `$removeparam` on a capped URL (D-17, §7.7).
   **Confirm** the 8 KiB value (the review suggested 16–32 KiB).
5. **Perf gate.** Step 4 must pass G-1…G-7 on a real-URL corpus (§7.8),
   which replaces the short-path `many.html` check. The numbers assume
   review 97-1 (regex `perf-*` features without `perf-literal`).
   **Confirm** 97-1 for #97; without it G-2 is expected to fail.
6. **Request types.** `is_fetch_like_api` → XHR and keepalive → ping, as
   WebRequest maps them (F-25). R-5 is closed.
7. **Sockets.** WebSocket (frames only) and WebTransport hooks (§7.1).
   Worker sockets are a known gap (R-13).
8. **`$redirect` and `$removeparam`.** A redirect match is served as a stub
   response for no-CORS and same-origin requests of any type; CORS-mode
   requests are blocked instead. A rewrite is a synthetic 307 for
   subresource GET/HEAD only, never on a redirect hop or a navigation
   (§7.4). **Confirm** no `$removeparam` on navigations in v1.
9. **Cosmetic delivery.** The renderer pulls its payload with one sync call
   at `DidCreateDocumentElement` on a new process-level interface,
   `open_engine.mojom.AdBlockCosmetics`, bound on the matcher sequence
   (D-13, §8.2). The `cef.mojom` push could not arrive in time (F-27).
   This reverses D-6 and §0.2's "no Mojo interface of our own".
   **Confirm** one sync IPC per http(s) document (gates C-G1, C-G2).
10. **Cosmetic payload (98-1, 98-2).** Sanitized selector vectors, one rule
    per selector, inserted as user-origin sheets with
    `InsertStyleSheet(kUser)`; procedural selectors dropped; `:style()`
    sanitized (no `url(` and similar) with `!important` added; removals and
    the class/ID observer in an isolated world; scriptlets in the main world
    (D-14, §8.3). **Confirm** that v1 keeps scriptlets although Arc shows no
    scriptlet support (F-34, guess), and the use of
    `ISOLATED_WORLD_ID_CHROME_INTERNAL` until P7 gives Open its own world.
11. **DAT reuse (98-4, 100-1).** A DAT is written and reused only for a
    lossless list set, with `engineFormat` and the resources hash in the
    receipt; resources are applied after every deserialize (D-15, §9.2.1).
12. **Resources.** `resources.json` is built offline, pinned, bundled, and a
    manifest input of every generation; no runtime download in v1 (§9.3).
    This changes §9.3 and §9.5 of 2026-10-25 and needs a Swift manifest
    change at Step 7. **Confirm.**
13. **Memory (100-5, 100-2).** Profiles with identical verified inputs share
    one engine (content-hash key); every engine is freed on the build
    runner; one build at a time per process; 128 MiB input cap; budgets in
    §6.6. **Confirm** cross-Profile engine sharing (privacy note in §6.6).
14. **Service contract at Step 4** (§6.7): matcher state as a
    `RefCountedThreadSafe` object (100-8), Swift's exclusion rule (100-4),
    `nullptr` after shutdown (100-6), switches out of official builds (100-3).
15. **Plan errors fixed.** The old §8.4 used
    `NavigationThrottle::ReadyToCommitNavigation`, which does not exist
    (F-27). The old CSP edit in a throttle would never reach the CSP parser
    (F-26). The old note that Alloy pages get no hooks is wrong for branch
    8078 (F-36). The old CDP "reason string" check cannot work, because
    completion carries only an error code (§7.4).
16. **Entry gates.** Step 4: #97/#98/#100 merged with the listed review
    fixes and the §5.5 Step 4 rows. Step 5: the sanitized cosmetic vectors
    (98-1, 98-2). Step 7: resources after deserialize (98-4).

Not changed: the crate and its version, the engine in the browser
process, the list catalog, the generation contract of §9.2, the CEF API
shape (only new status keys), and the Swift store contract.

### Swift-slice implementation notes (2026-10-25)

The Lead decisions Swift slice lands as `OpenAdBlock` in OpenKit. Its catalog and
pins are package resources; `tools/fetch-adblock-lists.sh` reads those same pins.
The source manifest has regional ID `dk` (not the prose's `ndk`) and 18 Korean
sources (not 17). BCNYBlocklists' two mirror-relative paths have no public upstream
host, so its catalog entry is explicitly unavailable rather than using the mirror
or inventing a URL. The Lead's 2026-10-25 generation decision in §9.2 supersedes
the earlier list-directory and DAT placement contract. See [adblock-lists.md](../adblock-lists.md) for the Swift store
contract, real CLI evidence, and the deferred OpenEngine adapter/resources work.
