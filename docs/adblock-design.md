# Ad blocking design for Open

Status: recommendation (2026-10-25). Engine base: Chromium 156.0.8078.48 + CEF branch 8078 in `~/Developer/open-engine/chromium_git/chromium/src` (`src/cef` inside). Swift shell talks only to `OpenEngine` (see [architecture.md](architecture.md)). Arc reference: [features-advanced.md §7](re/features-advanced.md) and [arccore-engine.md §2.7](re/arccore-engine.md).

Goal: Arc-level blocking — network blocking, cosmetic (element) hiding, per-site toggle in the Site Control Center, and list updates for the 46-list catalog — with minimal patch burden in our fork and near-zero cost on page load.

## Recommendation in one paragraph

Ship **Brave `adblock-rust` (crate `adblock`, MPL-2.0) in the browser process**, matched through a `blink::URLLoaderThrottle` patch in our fork, with cosmetic filtering and scriptlets delivered as a document-start stylesheet plus a small injected script. Do not build v1 on stock `subresource_filter` alone, and do not build v1 as an MV3 `declarativeNetRequest` component extension. `subresource_filter` is the fastest network matcher in the tree, but in Chromium 156 it does not hide elements on real pages and it activates only on Safe Browsing / Better Ads lists. Reaching Arc level on it costs the same fork work as `adblock-rust` plus a second cosmetic engine. `declarativeNetRequest` caps quality below uBlock Origin and depends on the extension host that Open does not have yet. A hybrid that uses `subresource_filter` for network and `adblock-rust` only for cosmetic is the fallback if the Rust toolchain blocks the build; it is not the first choice because it pays two parsers, two rule stores, and two update paths for no latency win the user can feel.

## What Arc does (the bar)

Evidence is in [features-advanced.md](re/features-advanced.md) §7 (AD-1 to AD-8) and the raw manifest in `.re/features-advanced/blocklist-manifest.json`:

- Native blocker, separate from extensions. Master key `nativeAdBlockEnabled`. Per-Profile list sets (`blockListsPerProfile`, `enabledBlockLists`, `defaultEnabledBlockLists`).
- Lists use Adblock Plus syntax. The bundle ships only EasyList (80,608 lines) and EasyPrivacy (57,052 lines) as resources. The catalog holds 46 lists in 5 categories (generic, cookies, privacy, regional, `BCNYBlocklists`). All other lists download on first enable.
- Updates fetch a remote manifest, then each enabled list with its stored ETag. A `304` keeps the cache. Unknown list IDs are skipped. EasyList states `Expires: 4 days`.
- Per-site disable lives in the Site Control Center (SC-6). It stores excluded domains (`setAdBlockExcludedDomains`), shows a scope dialog (`AdBlockDisableScopeAction`), and offers a reload (`AdBlockReloadFollowUpAction`). Arc also auto-disables uBlock on an allowlist that includes YouTube.
- The engine hook is custom. [arccore-engine.md](re/arccore-engine.md) §2.7 records `ArcBrowserApplication setBlockLists:` / `setExcludedDomains:` feeding `arc/components/ad_blocker/ad_blocker_service.cc` in the browser and `arc/renderer/ad_blocker_agent.cc` (`AdBlockerAgent::ShouldBlockRequest`, `::GenerateCosmeticFilterStylesheet`) in the renderer, bridged by `arc.mojom.AdBlockerAgent`. The hit count surfaces as `ArcWebContents.blockedResourceCount`. No `adblock-rust` strings exist in either Arc binary. The `subresource_filter` guess in features-advanced.md is therefore weak: Arc built its own service and agent instead of reusing Chrome's ad filter activation. Open should copy that shape (browser-owned engine, renderer cosmetic agent), not Chrome's Better Ads gating.

Rule mix in the two bundled lists (counted with Python over the Arc bundle copies; script in `.re/adblock/` notes):

| List | Lines | Network rules | Cosmetic `##` | Exceptions `@@` |
|---|---|---|---|---|
| EasyList | 80,608 | 54,923 | 24,644 | 756 |
| EasyPrivacy | 57,052 | 55,396 | 35 | 849 |
| Combined | 137,660 | 110,319 | 24,679 | 1,605 |

Cosmetic rules are 30% of EasyList. A network-only engine visibly fails Arc parity on news and social pages even if it blocks every request.

## Options

### A. Chromium `components/subresource_filter`

How it works in this tree:

- Rules live in an indexed FlatBuffer ruleset. `RulesetIndexer` and `IndexedRulesetMatcher` are defined in `components/subresource_filter/core/common/indexed_ruleset.h`. Matching uses `components/url_pattern_index` (N-gram index, `kNGramSize = 5`). The file is memory-mapped. `RulesetDealer` in `components/subresource_filter/core/common/ruleset_dealer.h` maps on first use and unmaps when the last reference drops. The browser reads it through `VerifiedRulesetDealer`; renderers read it through `UnverifiedRulesetDealer`.
- `DocumentSubresourceFilter` in `components/subresource_filter/core/common/document_subresource_filter.h` answers `GetLoadPolicy(url, element_type)` per document. Element types and activation types are in `components/url_pattern_index/proto/rules.proto` (`ELEMENT_TYPE_SCRIPT`, `IMAGE`, `SUBDOCUMENT`, `XMLHTTPREQUEST`, `WEBSOCKET`, and others; `ACTIVATION_TYPE_DOCUMENT`, `ELEMHIDE`, `GENERICHIDE`, `GENERICBLOCK`).
- Text lists become the indexed form with `ruleset_converter` in `components/subresource_filter/tools/ruleset_converter/` (`--input_format=filter-list --output_format=unindexed-ruleset`), then `RulesetService::IndexAndStoreAndPublishRulesetIfNeeded` in `components/subresource_filter/content/browser/ruleset_service.h` indexes, versions, and publishes. Versions live under `Subresource Filter/Indexed Rules/<format>/<content>` (`kSafeBrowsingRulesetConfig` in `components/subresource_filter/core/common/constants.cc` is the only production config in this tree).
- Activation is per page. `ConfigurationList` and `Configuration` in `components/subresource_filter/core/browser/subresource_filter_features.h` pick one configuration per navigation by priority. Presets are `MakePresetForLiveRunOnPhishingSites` (priority 1000), `MakePresetForLiveRunForBetterAds` (800), and `MakePresetForPerformanceTestingDryRunOnAllSites` (500, dry-run only). Scopes are `ALL_SITES`, `ACTIVATION_LIST`, and `NO_SITES` (`ActivationScope`). Chrome's ad filter uses the Better Ads activation list fed by Safe Browsing. The browser sends `mojom::ActivationState` (`kDisabled`, `kDryRun`, `kEnabled`) to the renderer at `ReadyToCommitNavigation` through `ActivationStateComputingNavigationThrottle` and `ContentSubresourceFilterThrottleManager`. The renderer agent `SubresourceFilterAgent::DidCreateNewDocument` in `components/subresource_filter/content/renderer/subresource_filter_agent.cc` builds a `WebDocumentSubresourceFilterImpl` only when the level is not `kDisabled` and a ruleset file exists. Blink then calls `SubresourceFilter::AllowLoad` in `third_party/blink/renderer/core/loader/subresource_filter.cc` for each subresource. Child frames are filtered in the browser by `ChildFrameNavigationFilteringThrottle`.

Cosmetic support: the index stores style rules. `StyleRuleIndexer`, `StyleRuleMatcher`, and `DocumentSubresourceFilter::GetDomainSelectors`, `GetSelectorsByClass`, `GetSelectorsById`, and `MaybeHasStyleRule` all exist, and `WebDocumentSubresourceFilter` in `third_party/blink/public/platform/web_document_subresource_filter.h` exposes them. No caller in `third_party/blink/renderer/core/loader`, `core/dom`, or `core/frame` calls them in this tree (verified with `muse.search` over those directories; the only hit for `SubresourceStyleFilter` is the comment in `web_document_subresource_filter.h` itself). Chrome parses `##` rules and then does not hide elements with them. Cosmetic parity therefore needs a new Blink consumer plus update and exception (`#@#`, `GENERICHIDE`, `ELEMHIDE`) handling. That work does not exist upstream to rebase.

CEF gap: no file under `cef/libcef/browser/` references `SubresourceFilter` (verified by scanning that directory). CEF never creates `ContentSubresourceFilterWebContentsHelper`. Chrome creates it in `chrome/browser/subresource_filter/chrome_content_subresource_filter_web_contents_helper_factory.cc` through `SubresourceFilterProfileContextFactory`. `ChromeContentBrowserClientCef::CreateThrottlesForNavigation` in `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:638` delegates to Chrome and to `throttle::CreateThrottlesForNavigation`, but without the helper and without a `RulesetService` instance the throttles have no dealer and no activation state. Option A in Open therefore needs fork patches to create a second `RulesetService` with its own `RulesetConfig`, a `SubresourceFilterProfileContext` per `CefBrowserContext`, and the helper per `WebContents`. That is a Chrome-layer backport into the CEF layer.

Patch points to reach Arc level on A:

1. Add `kOpenAdBlockRulesetConfig` next to `kSafeBrowsingRulesetConfig` and instantiate a second `RulesetService` in the CEF browser startup (new code in `cef/libcef/browser/`). Feed it `UnindexedRulesetInfo` from Open's list manager instead of the component updater.
2. Add a configuration with `ActivationScope::ALL_SITES`, `ActivationLevel::kEnabled`, and the highest priority, and install it with `GetAndSetActivateConfigurations`. The Safe Browsing presets must stay lower priority or be disabled, or Better Ads decisions will override Open's decision on some pages.
3. Wire the per-site toggle to `SubresourceFilterContentSettingsManager::AllowlistSite` in `components/subresource_filter/content/browser/subresource_filter_content_settings_manager.h`, which writes site metadata that expires after one week by default. Open needs non-expiring exclusions per Profile, so the manager needs a patch or a parallel exclusion store that forces `filtering_disabled_for_document` in `ActivationStateComputingNavigationThrottle`.
4. Add the missing Blink cosmetic consumer. The smallest correct form reads `GetDomainSelectors` at document creation and merges `GetSelectorsByClass` / `GetSelectorsById` results as elements appear. A static stylesheet alone misses late-inserted ad slots, so a `MutationObserver`-equivalent in Blink or repeated style recalculation is required. This is new Blink code with rebase risk on every `Document` and style refactor.

Update path on A: reuse `RulesetService` versioning and the sentinel-file crash guard. Open still writes its own downloader (ETag, manifest) and calls `IndexAndStoreAndPublishRulesetIfNeeded`. Indexing runs on a background sequenced task runner, so updates do not block navigation. Only one `ruleset_flavor` is active at a time (the lexicographically greatest), so per-list toggles collapse into one combined ruleset rebuild on every toggle change.

Cost on A: the network check runs in the renderer against a shared memory-mapped file. There is no per-request IPC and no browser hop. Chromium's own perftest in `components/subresource_filter/core/common/perftests/` reports `median_match_time` and `style_match_time`; the design target is sub-microsecond to low-microsecond per lookup, in the same class as the `adblock-rust` numbers below. Memory cost is the mapped file size (same order as the 6.78 MiB DAT measured for B) shared across renderers, plus one `DocumentSubresourceFilter` per document. Startup cost is near zero because the dealer maps lazily. These are the best raw numbers of any option. They buy network blocking only.

Block quality on A: URL rules support substring, wildcard (`*`, `^`), and regexp patterns with domain, source-type (first/third party), and element-type options. The rule parser in `components/subresource_filter/tools/rule_parser/rule_parser.cc` drops rules with unsupported options. There is no `$removeparam`, no scriptlet injection (`##+js(...)`), no procedural cosmetic (`:has`, `:style` beyond stored selectors), and no resource replacement. Expect parity with Chrome's ad filter, which is well below uBlock Origin on tracker and annoyance lists.

License on A: BSD-style Chromium license. No new dependency.

### B. Brave `adblock-rust` in the browser process

How it works: the Rust crate `adblock` (repository `github.com/brave/adblock-rust`, license MPL-2.0) parses ABP text into a `FilterSet`, builds an `Engine` with `Engine::from_filter_set`, and answers `Engine::check_network_request(&Request)` for network rules. It also answers `Engine::url_cosmetic_resources(url)` for domain-specific hide, style, remove, and scriptlet data, and `Engine::hidden_class_id_selectors(classes, ids, exceptions)` for generic rules matched against the class and ID tokens present on the page. It supports uBlock Origin extensions, resource replacements, CSP directives (`get_csp_directives`), and regex rules with a discard policy. Brave runs this engine in the browser process and consults it from its request handler; the crate README lists network blocking, cosmetic filtering, resource replacements, hosts syntax, and uBlock Origin syntax extensions as features.

Integration shape for Open (detailed plan below): link the Rust code as a static library into the Chromium fork, wrap it in a small C++ `OpenAdBlockService` that owns one `Engine` per Profile, and consult it from a `blink::URLLoaderThrottle` created in `ChromeContentBrowserClientCef::CreateURLLoaderThrottles` (CEF does not override that method today, so the patch adds the override) or, as a no-fork-patch stepping stone, from `CefResourceRequestHandler::OnBeforeResourceLoad` in `cef/include/cef_resource_request_handler.h`. The throttle form is the target because it sees the same `network::ResourceRequest` (URL, initiator, resource type, frame) for navigations, subresources, workers, WebSocket, and WebTransport, and it can cancel, redirect to a replacement resource, or allow without a string round-trip through CEF callback objects. Cosmetic data travels to the renderer once per navigation: the browser asks the service for `url_cosmetic_resources`, sends the hide selectors as a stylesheet and the scriptlets as a document-start script through the frame's agent, and the renderer re-queries generic selectors when the DOM gains new class or ID tokens. Per-site exclusions are checked in the browser before any throttle or cosmetic work.

Measured cost: see the benchmark section below. The headline numbers on EasyList plus EasyPrivacy are about 2.2 microseconds per network check, a 6.78 MiB serialized engine, about 30 milliseconds to parse both text lists, about 130 milliseconds to build the optimized engine, and about 47 milliseconds to load the serialized form. The serialized form is what ships and what loads at startup.

Patch burden on B: one new throttle, one service, one FFI boundary, and build glue to compile Rust in the Chromium build. Brave maintains the same shape in production, so the pattern is proven. The FFI surface is narrow (`Engine` create, deserialize, check, cosmetic query, reload). The main rebase risk is the throttle creation site and the Rust toolchain version, not Blink or style code.

Block quality on B: the highest of the four options. It covers the network and cosmetic rules that A drops, plus scriptlets and procedural filters that neither A nor C (Lite form) cover. With the same lists, expect uBlock Origin-class results. The gap to full uBlock Origin is the scriptlet library and resource files, which Open must bundle from uBlock Origin assets (license-compatible; see risks) and update with the lists.

License on B: MPL-2.0. The crate is file-level copyleft. Open can link it into the browser process if it ships the crate source offer and keeps the MPL files under their license. This needs a written dependency note per repo rules. The filter lists keep their own licenses (EasyList and EasyPrivacy are dual-licensed; the DAT form does not change that).

### C. Built-in MV3 component extension with `declarativeNetRequest`

How it works: an extension declares static JSON rulesets in its manifest. Chromium indexes them into the same `url_pattern_index` FlatBuffer through `extensions/browser/api/declarative_net_request/` and matches them in the browser. Cosmetic hiding is not part of `declarativeNetRequest`; extensions add it with content scripts that inject CSS and observe the DOM. uBlock Origin Lite is the reference product for this shape.

Limits in this tree (from `extensions/common/api/declarative_net_request.webidl` and `extensions/browser/api/declarative_net_request/constants.h`):

| Limit | Value |
|---|---|
| Static rules per Profile (`kMaxStaticRulesPerProfile`) | 300,000 |
| Static rulesets per extension (`MAX_NUMBER_OF_STATIC_RULESETS`) | 100 |
| Enabled static rulesets (`MAX_NUMBER_OF_ENABLED_STATIC_RULESETS`) | 50 |
| Dynamic rules (`MAX_NUMBER_OF_DYNAMIC_RULES`) | 30,000 |
| Session rules (`MAX_NUMBER_OF_SESSION_RULES`) | 5,000 |
| Regex rules (`MAX_NUMBER_OF_REGEX_RULES`) | 1,000 |
| Disabled static rules per extension (`kMaxDisabledStaticRules`) | 5,000 |
| Regex memory per rule (`kRegexMaxMemKb`) | 2 KB |

The combined network rules in EasyList plus EasyPrivacy (110,319) fit under the 300,000 static cap. The full 46-list catalog with regional lists does not reliably fit once AdGuard and uBlock Origin filter lists are added, and conversion from ABP text to DNR JSON is lossy: `$domain` with mixed allow and block entries, `$removeparam`, `$csp`, scriptlets, and procedural cosmetic have no exact DNR form. The converter must drop or approximate those rules. Dynamic rules (30,000) are too few to hold user list updates between extension updates, so list freshness depends on shipping a new extension version through the component updater or the Web Store.

Cost on C: matching uses the same indexed FlatBuffer as A, so per-request latency is in the same class. The extra cost is extension plumbing: ruleset load at extension enable, `RulesMonitorService` file work, content-script injection on every matching page, and a service worker wake for option pages and per-site controls. Startup cost appears when the extension host starts, which Open currently defers. Memory adds the extension's ruleset files plus the content-script world on each page.

Patch burden on C: near zero in the fork if the extension system works. It does not work at Arc level in CEF today (see [arccore-engine.md](re/arccore-engine.md) §4.4: no toolbar-action sync, no popup hosting, no `chrome.tabs` against a sidebar model). A component extension also needs a component-updater registration or a forced install path in the fork, plus a conversion pipeline that runs on every list update. The per-site toggle must go through `declarativeNetRequest` feedback and content-script controls, which give weaker guarantees than a browser-owned exclusion store. This option spends its budget on extension infrastructure that v1 needs for Web Store extensions anyway, but it couples the built-in blocker to that schedule.

Block quality on C: good network blocking within the caps, below B on lists that rely on uBlock extensions. Cosmetic quality depends on the extension's own injector, which runs after parse and often after first paint. Expect visible ad slots on fast pages. This is the uBlock Origin Lite trade-off, not the full uBlock Origin trade-off.

License on C: Chromium BSD for the platform. The extension code would be Open's own. List conversion must respect list licenses.

### D. Hybrids

Two hybrids matter:

- **D1: `subresource_filter` for network, own cosmetic injector for hiding.** Parse the text lists twice in effect: `ruleset_converter` builds the network plus style index, and a small browser-side parser extracts `##`, `#@#`, and domain exceptions into a per-domain selector map. On each navigation, `OpenEngine` injects one `<style>` element at document start through the frame and updates it when the page origin changes. Generic selectors need the class and ID tokens from the page, so the injector ships a tiny script that reports new tokens and receives matching selectors. This reuses A's fast network path and avoids Rust. It still needs all of A's fork patches (second `RulesetService`, `ALL_SITES` configuration, CEF helper wiring) plus the injector, and it still lacks scriptlets and procedural filters unless the injector grows into a second engine. Maintenance pays for two rule pipelines.
- **D2: `subresource_filter` for network, `adblock-rust` only for cosmetic and scriptlets.** This keeps the fastest network path and buys full cosmetic quality. It pays both engines' memory (two indexed forms of the same lists, roughly double the 6 to 7 MiB class), both update paths, and a consistency risk when a network exception (`@@`) and a cosmetic exception disagree because they came from different parsers. The latency win over B alone is about one microsecond per request in the renderer versus the browser. On a page with 200 subresources, that is about 0.2 milliseconds saved against a multi-hundred-millisecond load. The complexity is not justified.

D1 is the credible fallback if Rust cannot enter the build. D2 is not recommended.

## Comparison

| Dimension | A: `subresource_filter` | B: `adblock-rust` (recommended) | C: MV3 DNR extension | D1: A + own cosmetic |
|---|---|---|---|---|
| Block quality vs uBlock Origin | Low to medium. Network subset only; no scriptlets, no `$removeparam`, no procedural. Cosmetic indexed but unused. | High. Network, cosmetic, scriptlets, procedural, resources. Same lists give near-uBlock results. | Medium. Network within caps; conversion lossy. Cosmetic from content scripts, late. Lite-class, not full uBlock. | Medium. Network as A; cosmetic covers `##` and `#@#`. No scriptlets or procedural without more code. |
| Per-request latency | Lowest. In-renderer, memory-mapped, no IPC. Sub-microsecond to low-microsecond class. | About 2.2 µs per check in the browser (measured). No network wait added in practice. | Same matcher class as A, in the browser. Plus extension dispatch overhead. | Network as A. Cosmetic adds one style write per navigation plus token reports. |
| Memory | One mapped ruleset (about 6 to 7 MiB class) shared by all renderers. Small per-document state. | One serialized engine at 6.78 MiB for two lists; live `Engine` heap larger (see benchmark notes). One per Profile in the browser. No per-renderer copy. | Ruleset files per extension plus per-page content-script state. | Mapped ruleset plus selector map in the browser and a style element per page. More than A, less than B plus A. |
| Startup cost | Near zero. Lazy map. Indexing only after a list update, on a background thread. | About 47 ms to deserialize two lists (measured). Bundled DAT loads without text parse. Per-Profile engines load on first use. | Extension host start plus ruleset load. Heavier than A and B for a built-in feature. | Near zero for network. Selector map build (tens of ms) on first use or after update. |
| Update mechanics | Own downloader feeds `RulesetService`. Versioned, crash-guarded. One combined rebuild per change. | Own downloader writes text, rebuilds or replaces the DAT on a background thread, then swaps the `Engine`. Per-list ETag as in Arc. | Extension update through component updater or store. Slowest freshness. Dynamic rules too small for full lists. | Two artifacts to rebuild and keep consistent on every update. |
| Patch size in our fork | Medium to large. Second `RulesetService`, `ALL_SITES` config, CEF helper wiring, non-expiring exclusions, new Blink cosmetic consumer. | Small to medium. One `URLLoaderThrottle`, one service with FFI, cosmetic delivery, build glue for Rust. No Blink style changes. | Small in the fork, large in product code. Converter, component registration, injector, and dependency on the unfinished extension host. | Large. All of A plus the injector and its page script. |
| Maintenance across rebases | Matcher is upstream and stable. Custom activation, CEF wiring, and Blink cosmetic code conflict on `Document`, style, and throttle refactors. | Throttle site is stable. Rust toolchain and FFI need version care. No Blink fork code. Brave carries the same dependency upstream. | Platform is upstream. Converter and injector carry the maintenance. Extension API changes (MV3) are Google-driven. | Highest. Two pipelines, one of them (Blink cosmetic) with no upstream counterpart. |
| License | Chromium BSD. No new dependency. | MPL-2.0 (`adblock` crate). Needs dependency note and source offer. | Chromium BSD plus Open code. | Chromium BSD. No new dependency. |
| Per-site toggle and Site Control Center | Patch `AllowlistSite` for non-expiring, per-Profile exclusions. Panel reads activation state per frame. | Service checks an exclusion set before matching and before cosmetic delivery. Panel calls `OpenEngine` to read and write the set, then reloads. Direct fit for SC-6. | Toggle through extension APIs and content scripts. Weakest guarantee; state lives in the extension. | Exclusions must disable both the network configuration and the injector. Two places to keep in sync. |

## Benchmark: `adblock-rust` on EasyList plus EasyPrivacy

All work ran outside the Chromium tree in `/tmp/adblock-bench`. The Chromium tree was read-only throughout. No `gclient`, `gn`, `ninja`, or `autoninja` ran in `~/Developer/open-engine/chromium_git`.

### Setup

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo --version   # cargo 1.99.1, rustc 1.99.1, stable-aarch64-apple-darwin
mkdir -p /tmp/adblock-bench/src /tmp/adblock-bench/data
cp "/Applications/Arc.app/Contents/Resources/ARCClients_BlockListClient.bundle/Contents/Resources/EasyList.txt" /tmp/adblock-bench/data/easylist.txt
cp "/Applications/Arc.app/Contents/Resources/ARCClients_BlockListClient.bundle/Contents/Resources/EasyPrivacy.txt" /tmp/adblock-bench/data/easyprivacy.txt
wc -l /tmp/adblock-bench/data/*.txt   # 80608 easylist, 57052 easyprivacy
```

`Cargo.toml` pins `adblock = "=0.8.11"` and `rmp = "=0.8.11"`. The pin is required: `adblock 0.10` and `0.13.3` fail to build on `rustc 1.99.1` because `rmp-serde 0.15.5` calls `rmp::decode::read_data_*` functions that no longer exist. Version `0.8.11` with `rmp 0.8.11` builds cleanly and exposes the full API used here (`FilterSet`, `Engine::from_filter_set`, `serialize_raw`, `deserialize`, `check_network_request`, `url_cosmetic_resources`, `hidden_class_id_selectors`). The benchmark source is preserved in `.re/adblock/main.rs`. Raw output is in `.re/adblock/bench-run.txt` and `.re/adblock/bench-host.txt`.

Build and run:

```sh
cd /tmp/adblock-bench && cargo build --release
/usr/bin/time -l /tmp/adblock-bench/target/release/adblock-bench
```

### Results (Apple Silicon, arm64, release build)

Four runs gave consistent results. The table uses the first `/usr/bin/time -l` run; repeat runs follow it.

| Measurement | Value |
|---|---|
| Read both text lists (3,624,845 bytes) | 2.9 to 3.4 ms |
| `FilterSet::add_filter_list` for both lists | 28 to 39 ms |
| `Engine::from_filter_set(optimize=true)` | 116 to 147 ms |
| `serialize_raw` output size | 7,110,504 bytes (6.78 MiB) |
| `serialize_raw` time | 71 to 98 ms |
| `deserialize` time | 46 to 52 ms |
| Network match, 300,000 requests (15 URLs × 20,000) | 635 to 823 ms total |
| Network match, mean per request | 2.12 to 2.74 µs (2.15 µs median run) |
| Per-URL mean (5,000 checks each) | 0.37 to 4.20 µs; most URLs 0.9 to 2.1 µs |
| Requests blocked in the 15-URL set | 8 of 15 (analytics, tag manager, ad scripts, and trackers blocked; first-party CSS, fonts, data, and reCAPTCHA allowed) |
| Cosmetic, 1,000 × (`url_cosmetic_resources` + `hidden_class_id_selectors`) | 35 to 43 ms (35 to 43 µs per page query) |
| Hide selectors for `nytimes.com` | 443 |
| Hide selectors for `youtube.com` | 16 |
| Process peak memory (`/usr/bin/time -l`, whole bench process) | 162 to 189 MB maximum resident set size |

Repeat match means were 2.115 µs, 2.179 µs, and 2.151 µs per request. The 2.74 µs run was the first (cold) run under `/usr/bin/time -l`.

How to read the memory number: the bench process holds both text lists as `String`s (3.6 MB), the `FilterSet`, two live `Engine`s (before and after serialize), and the 7.1 MB serialized buffer at once. Maximum resident set size for that process overstates the browser cost. The durable costs are the 6.78 MiB DAT on disk and one live `Engine` per Profile in the browser process. Plan for 15 to 30 MiB of browser heap per active Profile with two lists enabled, and measure the real number with the integrated build before setting a budget. The key point stands: the engine is browser-resident and shared, not copied into each renderer.

What the numbers mean for page load: a heavy page issues 100 to 300 subresource requests. At 2.2 µs each, matching adds 0.2 to 0.7 ms of browser CPU, spread across the load. That is below one frame (16 ms) and far below network time. Cosmetic delivery adds one browser query (about 36 µs) plus a stylesheet write per navigation. Neither cost touches the renderer's critical path before first paint if the stylesheet is installed at document start (see the plan).

### What was not measured, and why

No `subresource_filter` binary ran. Building `ruleset_converter` or the perftest needs `autoninja` in the shared Chromium tree, which the task forbids. The latency claim for A therefore rests on the in-tree design (memory-mapped FlatBuffer, in-renderer check, no IPC) and on Chromium's perftest metrics (`median_match_time`, `style_match_time` in `components/subresource_filter/core/common/perftests/`), not on a local run. Before committing to D1, build those tools in a separate checkout and measure the indexed size and match time for the same two lists. Expect the same microsecond class as B and a similar 5 to 8 MiB indexed file. The decision does not turn on that difference.

No DNR conversion ran. The caps above come from the source constants. A converter prototype would measure rule loss (dropped ABP rules by option type) more than speed. Run it only if C returns to consideration.

## Recommendation

Adopt **B: `adblock-rust` in the browser process**.

Reasons, in order:

1. It is the only option that reaches Arc-level quality (network plus cosmetic plus scriptlets) with the 46-list catalog, including the 30% cosmetic share of EasyList.
2. The measured per-request cost (about 2.2 µs) is near-zero for page load. The faster A path saves about a microsecond per request and gives up cosmetic and scriptlet quality to save it.
3. The fork patch is smaller than A at Arc parity. A needs CEF wiring that does not exist, an `ALL_SITES` activation change, non-expiring exclusions, and a new Blink cosmetic consumer. B needs one throttle, one service, and build glue.
4. It does not depend on the Web Store extension host, which is the largest open risk in the engine plan ([arccore-engine.md](re/arccore-engine.md) §4.4 and §8).
5. Brave runs this engine in a Chromium browser in production. The integration pattern, the DAT update model, and the MPL-2.0 posture are all proven.

Ship D1 only as a time-boxed fallback if the Rust toolchain cannot enter the Chromium build. Do not ship C as the built-in blocker. Do not ship D2.

Default lists: enable EasyList plus EasyPrivacy by default, matching Arc's bundled set. Enable one regional list by locale only after the catalog UI exists. Keep the master toggle on for a fresh Profile (Arc's factory default is unproven; `nativeAdBlockEnabled = 0` on the inspected machine reflects that user's choice, not a factory value).

## Integration plan

### Data flow

```text
List catalog (46 lists, from Arc manifest shape, Open-hosted URLs)
        |
        v
Open list manager (Swift, OpenFeatures)
  - per-Profile enabled set, ETags, excluded domains
  - downloads text lists on schedule, verifies, writes atomically
        |
        v
OpenEngine (ObjC++)  AdBlockListManager
  - hands enabled text (or DAT) to the browser service
        |
        v
Chromium fork (browser process)
  OpenAdBlockService (one Engine per Profile, background rebuild + swap)
    |-- URLLoaderThrottle ----> allow / cancel / redirect per request
    |-- Cosmetic delivery ----> hide stylesheet + scriptlets per navigation
    |-- Blocked count --------> per-WebContents counter for the panel
        |
        v
OpenEngine events -> Swift BrowserState -> Site Control Center + Settings UI
```

### Chromium fork patches (keep as patch files, per repo convention)

1. **Build glue for Rust.** Add the `adblock` crate as a vendored static library. Follow Brave's shape: a GN target that runs `cargo` (or links a prebuilt `libadblock.a` for the pinned toolchain) and exports a small C header. Pin the Rust toolchain version in the patch. Add the MPL-2.0 license file and a dependency note. Files: new `open/adblock/` directory in the fork (service, throttle, FFI header), plus `BUILD.gn` edits. No changes to upstream `components/subresource_filter` or `extensions` code.
2. **Service.** New `OpenAdBlockService` keyed by `BrowserContext` (one instance per `CefBrowserContext`, which maps to one Open Profile). It owns the current `Engine` behind a read-write lock (or atomic swap), the exclusion set, and the per-tab blocked counters. Rebuilds run on a background `base::SequencedTaskRunner`. A failed rebuild keeps the old engine. The service also answers cosmetic queries and CSP directive queries.
3. **Network throttle.** Add `OpenAdBlockURLLoaderThrottle : public blink::URLLoaderThrottle`. Override `ChromeContentBrowserClientCef::CreateURLLoaderThrottles` (CEF inherits Chrome's version today and does not override it) to append the throttle when the master toggle is on and the frame's top-level origin is not excluded. `WillStartRequest` builds an `adblock::Request` (URL, initiator or document URL, resource type mapped from `network::mojom::RequestDestination`) and calls `check_network_request`. On a block, cancel the load (or redirect to the replacement resource when the result carries one). On an allow with CSP directives, add them in `WillProcessResponseHeaders` equivalent handling. Count blocks per `WebContents` for `blockedResourceCount`. Stepping stone without any fork patch: implement `CefResourceRequestHandler::OnBeforeResourceLoad` in `OpenEngine` and call the same service through a C API. Migrate to the throttle before v1 ships, because the CEF handler misses worker, WebSocket, and WebTransport loads that the throttle sees.
4. **Cosmetic and scriptlet delivery.** On `ReadyToCommitNavigation` for a main frame (and on committed subframe loads that match), the browser queries `url_cosmetic_resources(top_url)` once. It sends the result to the renderer through the existing CEF frame channel: install hide selectors as a user stylesheet at document start (before first paint), and run scriptlets as a document-start script in the main world. For generic rules, inject a small observer script that collects new class and ID tokens (debounced, capped per page) and requests `hidden_class_id_selectors` matches, appending them to the same stylesheet. Excluded origins skip both steps. Zap selectors from Boosts ([features-advanced.md](re/features-advanced.md) §5) merge into the same stylesheet mechanism, after blocker selectors, so one style element carries both.
5. **Per-site toggle plumbing.** The service exposes `IsExcluded(origin)`, `SetExcluded(origin, excluded)`, and `BlockedCount(web_contents)`. Exclusions use registrable domain (eTLD+1) by default, with an exact-host option in the scope dialog (see UI below). Changing an exclusion does not rebuild the engine. The throttle and the cosmetic path check the set on each navigation, so the change takes effect on reload without a restart.

### `OpenEngine` API (ObjC++, Swift-friendly; CEF types do not cross into Swift)

Add to the engine layer, next to the existing browser and web-content surface:

```objc
// Configuration (per Profile / CefRequestContext)
- (void)setAdBlockEnabled:(BOOL)enabled forProfile:(NSString *)profileID;
- (void)setEnabledBlockLists:(NSArray<NSString *> *)listIDs
                 listPayloads:(NSDictionary<NSString *, NSString *> *)idToTextOrDATPath
                  forProfile:(NSString *)profileID;
- (void)setAdBlockExcludedDomains:(NSArray<NSString *> *)domains forProfile:(NSString *)profileID;

// State (per tab)
- (NSInteger)blockedResourceCountForWebContent:(id)webContent;
- (BOOL)isAdBlockExcludedForURL:(NSURL *)url inProfile:(NSString *)profileID;

// Debug (for "Copy AdBlock debug info", AD-8)
- (NSString *)adBlockDebugInfoForProfile:(NSString *)profileID;
```

Swift side (`OpenFeatures`): `AdBlockStore` holds the catalog, per-Profile enabled sets, ETags, exclusions, and the master toggle in `BrowserState`. It mirrors Arc keys where Import needs them (`nativeAdBlockEnabled`, `enabledBlockLists`, `blockListsPerProfile`). The Site Control Center (SC-6) reads the current origin's exclusion state and blocked count from `OpenEngine`, writes changes through the same calls, and then offers the reload follow-up. Settings (AD-8) renders the catalog by category with per-list toggles and info links.

### List catalog, updates, and storage

- **Catalog.** Ship the 46-list catalog shape from the Arc manifest (IDs, display names, categories, info URLs) with Open-hosted download URLs that point at upstream sources, not at Arc's `dia-blocklists-release.diabrowser.engineering` mirror. Bundle EasyList and EasyPrivacy text (or a prebuilt DAT for both) in the app so blocking works offline on first run.
- **Schedule.** Check on launch (delayed until after first paint) and then every 24 hours while the app runs. EasyList asks for 4 days; 24 hours is fresher than the list requires and matches browser norms. Honor each list's stored ETag. A `304` costs one conditional request. Stagger list fetches and rebuild once after all downloads finish.
- **Rebuild.** Download to a staging file, verify size and first-line format (`[Adblock Plus ...]`), then rebuild the `Engine` on a background thread and swap it atomically. Keep the previous DAT until the new engine answers a smoke check (one known-block and one known-allow URL). On failure, keep the old engine and retry at the next interval.
- **Storage.** Under `~/Library/Application Support/Open/Profiles/<profile>/AdBlock/`: `catalog-state.json` (enabled IDs, ETags, last-check times, catalog version), `lists/<id>.txt` (last good text per list), `engine.dat` (serialized engine for fast startup), and `exclusions.json` (excluded domains per Profile). Load `engine.dat` at Profile open (about 47 ms for two lists). Fall back to text parse if the DAT version mismatches the crate version.
- **Per-Profile isolation.** Engines, enabled sets, and exclusions are per Profile, as in Arc (`blockListsPerProfile`). Incognito Profiles get a memory-only engine cloned from the default lists with no disk writes.

### Cold-start configuration (Section 13, 2026-11-09)

The App configures Default at engine readiness and every regular or private
context at creation, before handing it to a page. It sets exclusions, the
deterministic `Profiles/<dataDirectoryName>/AdBlock/lists` path, and the master
switch through OpenEngine. A read-only task prefetches saved settings and
exclusions off the main thread during model installation. Until that task
returns, configuration uses the existing store's in-memory values where
available, otherwise the product default (on, no exclusions). The App does not
wait for this task or perform settings IO on the main thread before paint.

The startup task also performs one `lstat` of `lists/current.json` per Profile;
only `ENOENT` identifies a fresh Profile. There is no main-thread stat. For a
fresh Profile with a live context, `AdBlockStore.openProfile` starts from context
creation, or as soon as that background result returns. Store metadata, settings,
and lease preparation run on a worker; main-actor installation only assigns and
binds the prepared values. Seed/verify and exclusion-file IO run in
`ListRepository`. Concurrent fresh contexts share store preparation and the
existing per-Profile opening task. Warm Profiles keep their after-paint opening.

The store configure event explicitly reloads an already configured directory
after seeding; setting the same path alone would not retry it. In the companion
native branch, a missing pointer keeps the initial load in `awaiting_generation`
with a 1,500 ms deadline per eligible request and a process-wide 128-request
limit. Bad manifests/SHA or other real load errors end that wait and fail open;
a valid zero-list generation completes it. Main-frame navigation stays direct.
This App-only branch still fails open before an engine is ready. Fresh
post-onboarding first-request blocking with its logged hold time, saved-off/
excluded behavior, and launch impact remain pending real-App proof. Fresh and
warm first-paint comparisons each require at least five interleaved main/branch
pairs after the lead releases the build and screen holds.

### Site Control Center and Settings UI

- The panel toggle shows three facts: the master state, whether this site is excluded, and the blocked count for the current page load (from `blockedResourceCount`). Toggling writes the exclusion for the registrable domain, updates the panel without closing it, and shows the reload affordance (`AdBlockReloadFollowUpAction` in Arc). The scope dialog offers “this site” (registrable domain, default) and “this page only” (exact URL, session-scoped). Do not offer “everywhere” in the per-site dialog; that is the master toggle in Settings.
- Settings lists the catalog by category with search, per-list toggles, and an advanced dialog for custom lists (user-supplied URLs, same ETag flow) and for the debug-info copy. Warn when a Web Store blocker extension is also installed, as Arc does in onboarding (`multipleAdBlockersPromptShown`). Reuse Arc's known extension IDs from AD-1 for that detection.

### Performance guardrails

- Keep matching off the UI thread. Throttle checks run where `URLLoaderThrottle` runs today. Cosmetic queries run once per navigation plus debounced token batches (cap at one batch per 100 ms per frame, 500 tokens per batch).
- Install the hide stylesheet at document start. Measure first-paint impact on a news page with and without blocking before v1. The fallback for a slow page is to cap generic-selector work, not to delay the stylesheet.
- Keep one `Engine` per Profile, not per tab. Tab state is limited to a counter and an exclusion check.
- Record `blockedResourceCount`, engine load time, rebuild time, and per-list rule counts in diagnostics (no URLs, no page content).

## Risks and open questions

1. **Rust in the Chromium build.** The build must compile or link Rust for arm64 macOS and keep the toolchain pinned across Chromium rebases. The benchmark already shows toolchain fragility (`rmp-serde` breakage on `rustc 1.99.1` forced a pin to `adblock 0.8.11` plus `rmp 0.8.11`). Mitigation: vendor the crate and its dependency lockfile, build the static library in the same CI job as the engine, and treat a Rust version bump as an engine change with its own verification. This is the top schedule risk for B and the trigger for the D1 fallback.
2. **MPL-2.0 compliance.** Linking `adblock` requires a source offer for the MPL files and a dependency note. Confirm with counsel that the planned distribution (source offer plus license file) satisfies the obligation before the first external build. The filter lists and the uBlock Origin scriptlet resources carry separate licenses and need the same review.
3. **Scriptlet and resource freshness.** Full quality needs uBlock Origin's resource library (scriptlets and redirect resources) versioned with the lists. Shipping stale resources degrades YouTube and news sites first. Bundle a pinned resource set, update it with the catalog, and show its version in debug info.
4. **Anti-adblock and breakage.** Sites detect cosmetic hiding and scriptlet injection. Arc already auto-allowlists at least YouTube for uBlock. Open needs a small, user-visible breakage path: the per-site toggle in the panel, plus a shipped exclusion list that stays empty until a site is proven broken. Do not copy Arc's allowlist without runtime proof.
5. **CEF throttle coverage.** Verify that the `URLLoaderThrottle` sees service-worker, dedicated-worker, WebSocket, and WebTransport loads in the CEF build, and that cancels surface correctly in the network UI. The CEF `OnBeforeResourceLoad` stepping stone does not cover all of these, which is why it is not the shipping form.
6. **Cosmetic timing.** A document-start stylesheet hides known slots before paint. Generic rules that depend on class and ID tokens arrive after the observer reports them, so some slots can flash. Measure the flash rate on the top news and shopping templates. If it is visible, add the domain-specific selectors (443 for `nytimes.com` in the benchmark) to the first stylesheet and keep generic work off the first-paint path.
7. **Memory with the full catalog.** Two lists serialize to 6.78 MiB. The full generic plus privacy set will be larger. Measure DAT size and live heap with all generic and privacy lists enabled, per Profile, before enabling regional lists by default.
8. **Arc unknowns carried over.** Factory default for the master toggle, the exact disable-scope options, update interval, and scriptlet support in Arc remain unproven (features-advanced.md §7.4). Open's choices above (on by default, registrable-domain scope, 24-hour checks, scriptlets on) are product decisions, not Arc facts. Verify Arc's scope dialog and first-run picker at runtime before finalizing labels.
9. **DNR as a future complement.** Web Store blockers that use `declarativeNetRequest` still run as extensions. Their rules and the built-in engine can double-block. The multiple-blocker warning covers the user-facing part. Do not try to merge the two rule stores.

## Verification (end to end, no unit tests per repo rules)

1. Build the real app with the integrated engine. Open a page that loads `https://www.google-analytics.com/analytics.js` and a known ad script. Confirm both are blocked, the panel count increments, and the page still renders.
2. Open a news article with EasyList cosmetic rules. Confirm ad slots are hidden before first paint (screen recording) and that disabling blocking for the site plus reload restores them.
3. Toggle each catalog category in Settings. Confirm the engine rebuilds once, blocking changes match the lists, and a `304` update leaves behavior unchanged.
4. Restart the app. Confirm `engine.dat` loads, blocking is active on the restored tab without a text re-parse delay, and per-Profile exclusions survive.
5. Install a Web Store blocker extension alongside the built-in blocker. Confirm the multiple-blocker warning appears and both engines' states stay independent.
6. Exercise Split View, Peek, and Little Arc windows. Confirm the focused pane's origin drives the panel toggle in each surface.

## Appendix: source map for this tree

| Claim | Source |
|---|---|
| Indexed FlatBuffer, N-gram matching, lazy map | `components/subresource_filter/core/common/indexed_ruleset.h`, `components/subresource_filter/core/common/ruleset_dealer.h`, `components/url_pattern_index/README.md` |
| Activation presets and scopes | `components/subresource_filter/core/browser/subresource_filter_features.h` and `.cc` (`MakePresetForLiveRunForBetterAds`, `ALL_SITES`, `ACTIVATION_LIST`) |
| Only production ruleset config | `components/subresource_filter/core/common/constants.cc` (`kSafeBrowsingRulesetConfig`) |
| Text-to-indexed conversion | `components/subresource_filter/tools/ruleset_converter/`, `components/subresource_filter/tools/rule_parser/rule_parser.cc` |
| Cosmetic APIs with no Blink caller | `components/subresource_filter/core/common/document_subresource_filter.h`, `third_party/blink/public/platform/web_document_subresource_filter.h`; `muse.search` over `third_party/blink/renderer/core/{loader,dom,frame}` returned no `GetDomainSelectors` caller |
| Renderer activation gate | `components/subresource_filter/content/renderer/subresource_filter_agent.cc` (`DidCreateNewDocument`, `ConstructFilter`) |
| Per-site allowlist with expiry | `components/subresource_filter/content/browser/subresource_filter_content_settings_manager.h` (`AllowlistSite`) |
| CEF has no subresource wiring | Scan of `cef/libcef/browser/` found no `SubresourceFilter` reference; helper creation lives in `chrome/browser/subresource_filter/chrome_content_subresource_filter_web_contents_helper_factory.cc` |
| CEF throttle override point | `cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc:638` (`CreateThrottlesForNavigation`); CEF does not override `CreateURLLoaderThrottles` |
| CEF stepping-stone hook | `cef/include/cef_resource_request_handler.h` (`CefResourceRequestHandler::OnBeforeResourceLoad`) |
| DNR caps | `extensions/common/api/declarative_net_request.webidl` (`MAX_NUMBER_OF_DYNAMIC_RULES 30000`, `MAX_NUMBER_OF_REGEX_RULES 1000`, `MAX_NUMBER_OF_ENABLED_STATIC_RULESETS 50`), `extensions/browser/api/declarative_net_request/constants.h:297` (`kMaxStaticRulesPerProfile 300000`) |
| `adblock` license and features | Crate `LICENSE` (MPL-2.0) and `README.md` in `adblock-0.8.11` |
| Arc engine shape | [arccore-engine.md](re/arccore-engine.md) §2.7 (`ad_blocker_service.cc`, `AdBlockerAgent`, `blockedResourceCount`) |

Raw notes, benchmark source, and full benchmark output are in `.re/adblock/` (git-ignored).
