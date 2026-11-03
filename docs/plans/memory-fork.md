# Memory fork — implementation plan for Open (tab sleeping on the Chromium fork)

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not spawn subagents (AGENTS.md rule 8). Do not write unit tests (rule 6).
Verify end to end only: real build, real `cefsimple`, real app, `ps`, and the
`openkit` CLI. This file is the complete context. You have no other context.
If a fact in this file conflicts with a real file in the repo or in
`~/Developer/open-engine`, stop and report the conflict. Do not redesign silently.

Product decision (already made, do not re-decide): a tab has three states,
**Placeholder → Live → Sleeping**, with two sleep depths. Depth 1 is **freeze**
(keep the renderer, stop its work). Depth 2 is **discard in place** (release
the renderer and frame tree, keep the `WebContents` shell). A later destroy
step closes the CEF browser and keeps only serialized history. Restore uses
`content::NavigationController::Restore` with entries built by
`sessions::ContentSerializedNavigationBuilder`. The Swift shell owns all sleep
policy. The fork supplies four primitives only: honest visibility, freeze,
discard, capture/restore of navigation history. Do not port Chrome's
`performance_manager` graph or `TabLifecycleUnit`.

## 0. How to use this plan

1. Work §12 in order. Steps marked **[NOW]** touch only this repo
   (`/Users/serge/.t3/projects/open`). Do them while the stock build runs.
   Steps marked **[WAIT]** touch `~/Developer/open-engine`. Do not start a
   [WAIT] step while any `autoninja` / `siso` / `ninja` process for
   `out/Release_GN_arm64` is alive. Check first:
   `pgrep -fl 'autoninja|siso|ninja' || echo no-build-running`.
   Never run `gclient`, `gn`, `ninja`, or `autoninja` in the shared tree
   until a [WAIT] step says so, and then only through the fork-infra scripts
   (`Engine/fork/scripts/engine-*`, see `docs/plans/fork-infra.md`). Never
   run `gclient sync` in that tree for this plan.
2. Each step lists exact files, exact content or pseudocode, and acceptance
   checks. A step is done only when every check passes. Paste real command
   output into the PR description. Do not claim a check you did not run.
3. The Chromium tree is dirty by design after CEF patching. Never "clean" it
   with `git checkout .` or `git reset --hard`.
4. Long jobs (builds) run in their own session so an app restart does not
   kill them (AGENTS.md rule 9). Use the `engine-build` wrapper from
   fork-infra, which already does this. Never start a bare background `&` job.
5. User-visible text never uses the Arc brand. Exception: "Import from Arc".
   The product name in every new file is **Open**.
6. `docs/engine-api.md` and `docs/engine-patches.md` do not exist yet
   (checked 2026-10-25). This plan is the engine-patches input for memory.
   Do not wait for them and do not invent their other patches.

## 1. Locked facts (verified 2026-10-25 by read-only inspection)

Re-check each pin before Step S1 with the commands in fork-infra §4.3. If a
value differs, stop and report. All Chromium paths below are under
`SRC=~/Developer/open-engine/chromium_git/chromium/src`.

| ID | Fact | Evidence |
|---|---|---|
| F-1 | Chromium `156.0.8078.48`, commit `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c`; CEF `156.0.14+g4fa4ab5+chromium-156.0.8078.48`, CEF commit `4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f`, branch `8078` | `cef/VERSION.stamp`; fork-infra F-1/F-2 |
| F-2 | Live out dir is `out/Release_GN_arm64`. Build with `-j 10` + `nice -n 10` + `caffeinate -dimsu` only (watchdog panics at default parallelism) | fork-infra F-6/F-7 |
| F-3 | `ChromeBrowserHostImpl::WasHidden` is `NOTIMPLEMENTED()` at `cef/libcef/browser/chrome/chrome_browser_host_impl.cc:240`. `AlloyBrowserHostImpl::WasHidden` at `cef/libcef/browser/alloy/alloy_browser_host_impl.cc:360` DCHECKs for non-windowless browsers. The only working forward is `CefBrowserPlatformDelegateOsr::WasHidden` at `cef/libcef/browser/osr/browser_platform_delegate_osr.cc:226`, which calls `web_contents->WasHidden()` / `WasShown()`. `CefBrowserPlatformDelegate::WasHidden` at `cef/libcef/browser/browser_platform_delegate.cc:388` is a `DCHECK(false)` stub | Read of those four files |
| F-4 | `content::WebContents::Discard(base::OnceClosure)` is at `content/public/browser/web_contents.h:876`; `WasDiscarded()` at `:887`; `SetPageFrozen(bool)` at `:1180` with the contract "cannot be called when the page is visible; if made visible it is automatically unfrozen". There is **no** `IsPageFrozen` getter on `WebContents` | `grep IsPageFrozen content/public/browser/web_contents.h` returns nothing |
| F-5 | `features::kWebContentsDiscard` (`content/public/common/content_features.h:136`) is `FEATURE_DISABLED_BY_DEFAULT` on desktop, enabled on Android (`content/public/common/content_features.cc:381`). `WebContentsImpl::Discard` at `content/browser/web_contents/web_contents_impl.cc:2801` hits `NOTREACHED()` if the feature is off, returns **without running the callback** if already discarded, else calls `AboutToBeDiscarded(this)`, `primary_frame_tree_.Discard(cb)`, `NotifyWasDiscarded()` | Read of both files |
| F-6 | `FrameTree::Discard` at `content/browser/renderer_host/frame_tree.cc:1197`: if the speculative frame host has a pending-commit navigation, the attempt returns `false` and the callback is dropped unrun. Otherwise it sets `was_discarded`, calls `DiscardFrame(cb)`, `NavigationControllerImpl::SetNeedsReload()`, and flushes the back-forward cache | Read of `frame_tree.cc:1197` |
| F-7 | `WebContentsImpl::SetPageFrozen` at `web_contents_impl.cc:4429` DCHECKs the page is not `VISIBLE` and forwards `SetIsFrozen` to every `RenderViewHostImpl`. `WebContentsImpl::SetWasDiscarded(bool)` ignores `false`: it always sets the bit. Only ever call it with `true` | Read of `web_contents_impl.cc:4429` and `:2822` |
| F-8 | `WebContents::CreateParams` (`web_contents.h:214`): `initially_hidden` at `:256`; `desired_renderer_state` at `:327`, default `kOkayToHaveRendererProcess`; `kNoRendererProcess` at `:310` ("creation should not spawn a new OS process and should not reuse a spare") | Read of `web_contents.h:250` |
| F-9 | `NavigationController::Restore(int, RestoreType, std::vector<std::unique_ptr<NavigationEntry>>*)` at `content/public/browser/navigation_controller.h:473`. `RestoreType` is `content/public/browser/restore_type.h:11`: `kRestored`, `kNotRestored`. Use `kRestored` | Read of both headers |
| F-10 | `sessions::ContentSerializedNavigationBuilder` (`components/sessions/content/content_serialized_navigation_builder.h`): `FromNavigationEntry(index, entry, options)`, `ToNavigationEntry(navigation, browser_context, restore_context)`, `ToNavigationEntries(span, browser_context)`. Options: `DEFAULT`, `EXCLUDE_PAGE_STATE` ("heavy processing on pages with deep iframe trees") | Read of the header |
| F-11 | `sessions::SerializedNavigationEntry` (`components/sessions/core/serialized_navigation_entry.h:29`) is the "freeze-dried" `NavigationEntry`. It holds `virtual_url_`, `title_`, `encoded_page_state_`, `transition_type_`, `has_post_data_`, `referrer_url_`, `favicon_url_`, `http_status_code_`, `timestamp_`. It pickles with `WriteToPickle(int max_size, base::Pickle*)` / `ReadFromPickle(base::PickleIterator*)`. Strings past `max_size` are truncated, not failed | Read of the header and `serialized_navigation_entry.cc:116` |
| F-12 | `encoded_page_state` is the scroll and form carrier: `NavigationEntry::GetPageState`/`SetPageState` at `content/public/browser/navigation_entry.h:136` — "includes form entries and scroll position for each frame". Raw POST bodies are **not** persisted (`SetPostData` comment at `:187`). `content::NavigationEntry` also has `GetReferrer()` (`:90`, returns `content::Referrer` with `.url`) and `GetFavicon()` (`:196`, returns `FaviconStatus` with `GURL url` at `content/public/browser/favicon_status.h:23`) | Read of both headers |
| F-13 | Stock history read: `CefBrowserHost::GetNavigationEntries(visitor, current_only)` at `cef/include/cef_browser.h:669`, implemented at `cef/libcef/browser/browser_host_base.cc:771`. It posts to the UI thread (`CEF_UIT`), walks `web_contents->GetController()` (`GetEntryCount`, `GetCurrentEntryIndex`, `GetEntryAtIndex`), and wraps each entry in `CefNavigationEntryImpl` (`cef/libcef/browser/navigation_entry_impl.{h,cc}`). Stock `CefNavigationEntry` (`cef/include/cef_navigation_entry.h:48`) has no page state, no referrer, no favicon URL, and no builder | Read of all three files |
| F-14 | In Chrome style the `WebContents` is owned by the Chrome `Browser`'s tab strip (`cef/libcef/browser/browser_host_base.h:192`). `ChromeBrowserHostImpl::Create` at `cef/libcef/browser/chrome/chrome_browser_host_impl.cc:29` calls `CreateBrowser(params, …)` then `chrome::AddTabAt(browser, url, kNoTab, foreground=true)` and reads back `GetActiveWebContents()`. CEF params travel as `ChromeBrowserHostImpl::DelegateCreateParams` (`chrome_browser_host_impl.h:29`) via `BrowserWindowCreateParams.cef_params` (`chrome_browser_host_impl.cc:418`). Alloy creates its `WebContents` directly at `cef/libcef/browser/alloy/browser_platform_delegate_alloy.cc:47` (`WebContents::CreateParams(browser_context, nullptr)`) | Read of those files |
| F-15 | Chrome's own restored-tab precedent: `CreateRestoredTab` in `chrome/browser/ui/browser_tabrestore.cc:74` sets `create_params.initially_hidden`, `desired_renderer_state = kNoRendererProcess`, creates with `WebContents::CreateWithSessionStorage`, converts with `ToNavigationEntries`, calls `GetController().Restore(selected_navigation, RestoreType::kRestored, &entries)`, and calls `WasHidden()` on the inserted tab when hidden (`:220`). CEF's Chrome path exposes none of this today | Read of `browser_tabrestore.cc:55` |
| F-16 | `CefWindowInfo` already has `hidden` (`cef/include/internal/cef_types_mac.h:110`, "create the view initially hidden"). It hides the **view**. It does not set `initially_hidden` or `desired_renderer_state` on the `WebContents`. Do not reuse it for the no-renderer flag | Read of `cef_types_mac.h:94` |
| F-17 | `cef_browser_settings_t` is the C struct at `cef/include/internal/cef_types.h:595`; its C++ wrapper is `CefBrowserSettingsTraits::set` at `cef/include/internal/cef_types_wrappers.h:537`. New optional fields use the existing pattern: guard with `#if CEF_API_ADDED(CEF_EXPERIMENTAL)` in the struct (see `ax_viewport_collapse`) and copy with `CEF_MEMBER_EXISTS` in the wrapper | Read of both files |
| F-18 | Translator: run from `cef/tools` as `python3 translator.py --root-dir ..` (`translator.sh` does exactly this). It regenerates `cef/include/capi/*.h`, `cef/include/capi/*_versions.h`, and `cef/libcef_dll/cpptoc` + `ctocpp`. Generated files must never be hand-edited. API versioning: default `CEF_API_VERSION` is `CEF_API_VERSION_EXPERIMENTAL` (999999) (`cef/include/cef_api_hash.h:69`), so fork API added as `added=experimental` compiles by default. `cef/tools/version_manager.py` with no args updates translated files and hashes; `-n` prints the next version. Never hand-edit `cef/cef_api_versions.json` or `cef/include/cef_api_versions.h` | `translator.py -h`, `version_manager.py -h`, read of `cef_api_hash.h:40` |
| F-19 | `libcef_static` is a `source_set` in `cef/BUILD.gn:516`. Its `deps` list (alphabetical) has no `//components/sessions` entry today. The sessions target is `component("sessions")` in `components/sessions/BUILD.gn`, label `//components/sessions`. Adding it is one `deps` line plus new source files in the same `BUILD.gn` | Read of both `BUILD.gn` files |
| F-20 | Feature-name rule (`base/feature.h:97`): `BASE_FEATURE(kFoo, state)` with two args names the feature `"Foo"` (leading `k` stripped). A three-arg form uses its explicit string. Verified defaults in §10. `CefApp::OnBeforeCommandLineProcessing` is at `cef/include/cef_app.h:208`; an empty `process_type` means the browser process | Read of `base/feature.h` and `cef_app.h:195` |
| F-21 | Open repo today: `Packages/OpenKit` has targets `OpenModel`, `OpenStore`, `OpenImport`, `OpenSuggest`, `OpenCommands`, `openkit`, `commands-dump` (`Packages/OpenKit/Package.swift`). There is **no** `App/` target and **no** `Engine/OpenEngine/` yet, and `docs/automation.md` does not exist. `Tab` persisted fields and `TabLiveState` runtime fields are in `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift:8` (`isLoading`, `progress`, `isAudible`, `isCrashed`, `canGoBack`, `canGoForward`, `faviconPNG` — never persisted). `Tab.lastActiveAt` is at `:34`. `ProfileSettings` is at `Packages/OpenKit/Sources/OpenModel/Containers.swift:20`. Snapshot DTOs are at `Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift`; `SnapshotFileDTO.schemaVersion` is 1 and `TabDTO` at `:56` must not gain a history field (see §7) | Read of those files |

## 2. Key decisions

| # | Decision | Rejected alternative | Reason |
|---|---|---|---|
| D-1 | Sleep depths in order: honest `WasHidden` → freeze at 30 s hidden → discard in place → destroy (close browser) after 24 h sleeping or under critical pressure. Discard in place is the default depth 2 | Destroy-and-restore for every sleep | Discard keeps the `WebContents`, its controller, its view, and the tab's engine identity (extensions keep their tab). Wake needs no `Restore` call. Destroy is the rare path and reuses the same blob format |
| D-2 | History blob is captured **at sleep time and at quit**, never on every navigation. Cheap fields (URL, title, index) already flow through normal delegate updates | Capture on every commit "just in case" | `FromNavigationEntry` with page state walks every frame. Taxing the hot path to save cold-path work fails the tab-switch budget |
| D-3 | The blob lives in a **separate SQLite store** (`SleepStore`, §7), never in the JSON snapshot and never on `TabDTO` | Add `sleepState` to the snapshot DTO | Blobs are up to 2 MiB per tab. The JSON snapshot is rewritten debounced on every command; embedding blobs would rewrite megabytes per keystroke and break the 5,000-item snapshot bench in `docs/model.md` |
| D-4 | Freeze state is tracked in the CEF layer (`page_frozen_` on `CefBrowserHostBase`), not queried from content | Add a content getter | F-4: no `IsPageFrozen` exists. Adding one means a content patch that can conflict on rebase. The CEF-layer bool is exact because CEF is the only caller of `SetPageFrozen` |
| D-5 | Discard completion uses the existing `CefCompletionCallback` (`cef/include/cef_callback.h`, `OnComplete`), wrapped around the `base::OnceClosure`. Swift must re-check `WasDiscarded()` after the callback | Trust the callback alone | F-5/F-6: the closure is not run when already discarded, and is dropped unrun when a speculative navigation is pending. The callback means "released or gave up", never "released" |
| D-6 | No-renderer creation flag travels in `CefBrowserSettings` as a new experimental field `no_renderer`, copied into the internal `CefBrowserCreateParams`. `CefWindowInfo.hidden` is left alone | Reuse `CefWindowInfo.hidden`; add a `CefWindowInfo` field | F-16: `hidden` already means "view initially hidden" and Views code reads it. Overloading it would hide views for live tabs. Settings already has the experimental-field pattern (F-17) |
| D-7 | New CEF API is added as `added=experimental` and built with the default `CEF_API_VERSION` (experimental). Hashes are updated only by `version_manager.py`. No new numbered CEF version is minted in this plan | Run `version_manager.py -a` to mint `15601` | Open ships one fork build to one app. Numbered versions buy back/compat Open does not need, and `-a` rewrites `CEF_NEXT` placeholders across headers the fork does not own |
| D-8 | Swift policy lives in a new OpenKit target `OpenSleep` that depends only on `OpenModel`. It talks to the engine through a Swift protocol (`SleepEngine`). Only the future App target implements that protocol over OpenEngine. OpenKit never imports OpenEngine or CEF | Put policy in the App target; put policy in C++ | `docs/architecture.md`: Packages never import `OpenEngine` or CEF. Policy needs `lastActiveAt`, pin state, and audibility, which the model already owns. C++ policy would need the `performance_manager` graph (rejected above) |
| D-9 | Feature switches are set in OpenEngine's `CefApp::OnBeforeCommandLineProcessing`, not by flipping `BASE_FEATURE` defaults in the fork | Patch each feature default | Switches survive rebases for free. A default flip is a patch that conflicts forever. Move a default into the fork only if the §10 smoke check proves a switch unreliable across process types |
| D-10 | Back-forward cache is left at Chromium defaults in v1. No cap patch | Set field-trial params for `kBackForwardCache` now | The param names were not verified in this tree, and `FrameTree::Discard` already flushes BFCache on discard (F-6), so sleeping and BFCache do not fight. Revisit only if the §11 50-tab budget fails |

Corrections to `docs/memory-design.md` that this plan applies (source wins):

- §4.5 lists `PageTextExtraction` as a switch value. Wrong string. The feature
  `kPageTextExtraction` has the explicit name `OptimizationGuidePageContentExtraction`
  (`components/optimization_guide/core/optimization_guide_features.cc:67`). Using
  `PageTextExtraction` would silently match nothing. §10 uses the verified strings.
- §6 P-MEM-02 assumes an `IsPageFrozen()` query exists. It does not (F-4). See D-4.
- §6 P-MEM-03 names the callback `CefCallback`. The completion type is
  `CefCompletionCallback::OnComplete`. See D-5.
- §6 P-MEM-05 says "thread the flag through `Browser::CreateParams`". The real
  carrier is `CefBrowserCreateParams` → `DelegateCreateParams` →
  `BrowserWindowCreateParams.cef_params` (F-14), and the Chrome branch must
  create the `WebContents` itself following `browser_tabrestore.cc` (F-15).
  `chrome::AddTabAt` cannot be used for the no-renderer case because it creates
  the contents internally with a renderer. §5.2 gives the exact branch.

## 3. Patch and overlay map

Fork layout is owned by `docs/plans/fork-infra.md` §3: patches in
`Engine/fork/patches/{chromium,cef}/` with `series` files, new files in the
overlay `Engine/fork/src/` mirroring `chromium/src/` paths, applied by
`Engine/fork/scripts/engine-apply`. If `Engine/fork/` does not exist yet when
you start, create only the directories named below and tell the lead; do not
re-run fork-infra Phase A inside this plan.

All P-MEM edits touch existing files under `src/cef/`, so every patch below is
a `patches/cef/` entry. There are **no** `patches/chromium/` entries in this
plan. New files are overlay files. Translator output is never a patch by hand:
you edit the `cef/include/*.h` source, run the translator in the tree (§6), and
`engine-refresh-patches` captures the regenerated files into the same patch
because they are existing files under `src/cef/`.

| Patch | Series line (append in this order) | Existing files edited (smallest hunks only) | New overlay files |
|---|---|---|---|
| P-MEM-01 | `0101-mem-visibility.patch  # WasHidden forwards to WebContents in Chrome+Alloy windowed styles` | `cef/libcef/browser/chrome/chrome_browser_host_impl.cc`, `cef/libcef/browser/alloy/alloy_browser_host_impl.cc` | none |
| P-MEM-05 | `0105-mem-no-renderer-create.patch  # CefBrowserSettings.no_renderer -> kNoRendererProcess creation (Chrome branch + Alloy)` | `cef/include/internal/cef_types.h`, `cef/include/internal/cef_types_wrappers.h`, `cef/libcef/browser/browser_host_base.h`, `cef/libcef/browser/browser_host_create.cc`, `cef/libcef/browser/chrome/chrome_browser_host_impl.cc`, `cef/libcef/browser/alloy/browser_platform_delegate_alloy.cc` | none |
| P-MEM-04 | `0104-mem-navigation-history.patch  # CefNavigationHistory capture/restore over ContentSerializedNavigationBuilder + Restore` | `cef/include/cef_browser.h`, `cef/include/cef_navigation_entry.h`, `cef/libcef/browser/navigation_entry_impl.h`, `cef/libcef/browser/navigation_entry_impl.cc`, `cef/libcef/browser/browser_host_base.h`, `cef/libcef/browser/browser_host_base.cc`, `cef/BUILD.gn` (+ translator output, §6) | `Engine/fork/src/cef/include/cef_navigation_history.h`, `Engine/fork/src/cef/libcef/browser/navigation_history_impl.h`, `Engine/fork/src/cef/libcef/browser/navigation_history_impl.cc` |
| P-MEM-02 | `0102-mem-page-frozen.patch  # CefBrowserHost SetPageFrozen/IsPageFrozen over WebContents::SetPageFrozen` | `cef/include/cef_browser.h`, `cef/libcef/browser/browser_host_base.h`, `cef/libcef/browser/browser_host_base.cc` (+ translator output) | none |
| P-MEM-03 | `0103-mem-discard.patch  # CefBrowserHost Discard/WasDiscarded over WebContents::Discard (needs WebContentsDiscard on)` | `cef/include/cef_browser.h`, `cef/libcef/browser/browser_host_base.h`, `cef/libcef/browser/browser_host_base.cc` (+ translator output) | none |
| P-MEM-06 | `0106-mem-eligibility-flags.patch  # CefBrowserHost HasUnloadHandlers only; no stub-false flags` | `cef/include/cef_browser.h`, `cef/libcef/browser/browser_host_base.h`, `cef/libcef/browser/browser_host_base.cc` (+ translator output) | none |
| P-MEM-07 | no patch. OpenEngine switch code only (§10) | none in the tree | none |

Series order is apply order: `0101`, `0105`, `0104`, `0102`, `0103`, `0106`.
Visibility first because freeze and discard read it. Creation and history next
because placeholders need them. Freeze and discard last because they are
useless until a tab can come back. Keep each patch to one logical change
(fork-infra D-3). If two patches must edit the same line region in
`cef_browser.h`, refresh them in series order so each patch applies cleanly on
top of the previous one.

## 4. Threading rules for every new CEF call

All `content::WebContents`, `NavigationController`, and freeze/discard state
lives on the CEF UI thread (`CEF_UIT`). In the Open app the UI thread is the
main thread. The rules below copy the patterns already in
`cef/libcef/browser/browser_host_base.cc`:

- A setter that can be called from any thread checks `CEF_CURRENTLY_ON_UIT()`
  and re-posts with `CEF_POST_TASK(CEF_UIT, base::BindOnce(...))` when off
  thread. Copy the `SetZoomLevel` shape at `browser_host_base.cc:438`.
- A synchronous getter requires the UI thread. When off thread it does
  `DCHECK(false)` and returns the empty value. Copy
  `GetVisibleNavigationEntry` at `browser_host_base.cc:827`. OpenEngine always
  calls getters on the UI thread, so this never fires in production.
- No new call ever round-trips to the renderer. History capture reads the
  controller in the browser process (F-13 proves the pattern). Freeze and
  discard forward to `WebContents` calls that themselves message the renderer.
- Callbacks (`CefCompletionCallback::OnComplete`) always fire on `CEF_UIT`.
  If the discard closure runs on another thread, re-post before calling it.
- `CefBrowserHostBase::GetWebContents()` may return `nullptr` during teardown.
  Every new method checks it first and returns the failure value. Never cache
  a raw `WebContents*` across calls.

## 5. The P-MEM patches

### 5.1 P-MEM-01 — Visibility that works in Chrome style

Purpose: make `CefBrowserHost::WasHidden(bool)` honest for windowed browsers.
Without it there is no timer throttling, no freeze eligibility, and no discard
signal in the style Open ships.

Exact hunks:

1. `cef/libcef/browser/chrome/chrome_browser_host_impl.cc`, function
   `ChromeBrowserHostImpl::WasHidden(bool)` (today the whole body is
   `NOTIMPLEMENTED();`). Replace the body with:

   ```cpp
   void ChromeBrowserHostImpl::WasHidden(bool hidden) {
     if (!CEF_CURRENTLY_ON_UIT()) {
       CEF_POST_TASK(CEF_UIT,
                     base::BindOnce(&ChromeBrowserHostImpl::WasHidden, this, hidden));
       return;
     }
     if (auto* web_contents = GetWebContents()) {
       if (hidden) {
         web_contents->WasHidden();
       } else {
         web_contents->WasShown();
       }
     }
   }
   ```

   Add `#include "cef/libcef/browser/thread_util.h"` only if the file does not
   already include it (check first; it already includes it at the top — do not
   add a duplicate). No header change: the method is already declared in
   `chrome_browser_host_impl.h`.

2. `cef/libcef/browser/alloy/alloy_browser_host_impl.cc`, function
   `AlloyBrowserHostImpl::WasHidden(bool)` (today: DCHECK + return for
   non-windowless, else post + `platform_delegate_->WasHidden(hidden)`).
   Keep the post-to-UIT block. Replace the windowless check with a branch:
   if `IsWindowless()`, keep the existing `platform_delegate_` forward;
   else forward to `GetWebContents()->WasHidden()` / `WasShown()` with the
   same null check as hunk 1. Delete the `DCHECK(false)` early return.

Do not touch `browser_platform_delegate.cc` or the OSR delegate. The OSR path
at `browser_platform_delegate_osr.cc:226` is already correct and windowless
Alloy still uses it through hunk 2.

New CEF API: none. The C++ signature already exists
(`cef/include/cef_browser.h:707`). No translator run for this patch.

Failure modes: called during teardown → `GetWebContents()` is null → no-op.
Called for a windowless browser through the Chrome class → impossible (Chrome
style is never windowless; `ChromeBrowserHostImpl::IsWindowless()` returns
false). Double `WasHidden(true)` → `WebContents` tolerates repeat calls;
Swift must still send only real transitions.

### 5.2 P-MEM-05 — Create with no renderer, restore before show

Purpose: create a `WebContents` that holds restored history with no renderer
process and no load until first show. Serves placeholder wake (§8) and the
destroyed-tab restore path.

Public carrier (D-6). In `cef/include/internal/cef_types.h`, inside
`cef_browser_settings_t`, immediately after `chrome_zoom_bubble` and before
the existing `#if CEF_API_ADDED(CEF_EXPERIMENTAL)` block, add:

```c
#if CEF_API_ADDED(CEF_EXPERIMENTAL)
  ///
  /// Set to true (1) to create the WebContents with no renderer process
  /// (WebContents::CreateParams::kNoRendererProcess) and initially hidden.
  /// The current navigation entry loads on first show. Only valid at
  /// creation; changing it later has no effect.
  ///
  int no_renderer;
#endif
```

In `cef/include/internal/cef_types_wrappers.h`, in
`CefBrowserSettingsTraits::set`, after the `chrome_zoom_bubble` copy and
next to the existing `ax_viewport_collapse` guarded copy, add:

```cpp
#if CEF_API_ADDED(CEF_EXPERIMENTAL)
    if (CEF_MEMBER_EXISTS(src, no_renderer)) {
      target->no_renderer = src->no_renderer;
    }
#endif
```

Internal carrier. In `cef/libcef/browser/browser_host_base.h`, in
`struct CefBrowserCreateParams` (line 31), add two fields after
`extra_info`:

```cpp
  // True to create the WebContents initially hidden (maps to
  // WebContents::CreateParams::initially_hidden).
  bool initially_hidden = false;

  // True to create the WebContents with no renderer process (maps to
  // WebContents::CreateParams::kNoRendererProcess). Implies initially_hidden.
  bool no_renderer = false;
```

In the `operator=` copy block of the same struct, add
`initially_hidden = that.initially_hidden; no_renderer = that.no_renderer;`.
Where `CefBrowserCreateParams` is built from the public settings (find it in
`cef/libcef/browser/browser_host_create.cc`; confirm with
`grep -n "CefBrowserCreateParams" cef/libcef/browser/browser_host_create.cc`),
copy the flag across in every place that builds params:
`params.no_renderer = settings.no_renderer != 0;` and
`params.initially_hidden = params.no_renderer;` (if that file already maps
`CefWindowInfo.hidden` to a params field, OR the two values instead).
Do not change `CefWindowInfo` handling.

Alloy branch. In
`cef/libcef/browser/alloy/browser_platform_delegate_alloy.cc`,
`CreateWebContents` (line 33), after `wc_create_params` is constructed and
before `content::WebContents::Create(wc_create_params)`, add:

```cpp
  if (create_params.no_renderer) {
    wc_create_params.initially_hidden = true;
    wc_create_params.desired_renderer_state =
        content::WebContents::CreateParams::kNoRendererProcess;
  } else if (create_params.initially_hidden) {
    wc_create_params.initially_hidden = true;
  }
```

Add `#include "content/public/browser/web_contents.h"` only if not present.

Chrome branch (the delicate hunk). In
`cef/libcef/browser/chrome/chrome_browser_host_impl.cc`,
`ChromeBrowserHostImpl::Create` (line 29): keep the `CreateBrowser` call.
Replace the unconditional `chrome::AddTabAt(...)` block with a branch:

- If `params.no_renderer` is false: existing code, unchanged.
- If true: follow F-15. Build
  `content::WebContents::CreateParams wc_params(browser->GetProfile());`
  with `wc_params.initially_hidden = true;` and
  `wc_params.desired_renderer_state = content::WebContents::CreateParams::kNoRendererProcess;`.
  Create with `content::WebContents::Create(wc_params)` (not
  `CreateWithSessionStorage` — CEF has no session-storage handle to pass;
  record this divergence in the patch commit message). Insert with
  `browser->tab_strip_model()->InsertWebContentsAt(TabStripModel::kNoTab, std::move(web_contents), AddTabTypes::ADD_NONE)`.
  Then call `raw_contents->WasHidden()`. Read the host back with
  `GetBrowserForContents(raw_contents)` exactly as the existing path does.
  Skip the `OnSetFocus(FOCUS_SOURCE_NAVIGATION)` call in this branch.
  Add includes for `content/public/browser/web_contents.h` and
  `chrome/browser/ui/tabs/tab_strip_model.h` only if not already included
  (the file already includes `tab_strip_model.h` — check, do not duplicate).

Threading: `Create` already runs the browser creation on the UI thread
(`CreateBrowserSync` requires it; async `CreateBrowser` posts). No new posts.

Failure modes: profile mismatch (params request context vs Browser profile)
→ `CHECK` fails in debug; OpenEngine must pass the same request context it
used for the window. Insert into a closing Browser → host read-back returns
null; return null host and let OpenEngine treat creation as failed (tab stays
a placeholder; no crash, no half tab). A restored tab shown before
`RestoreNavigationHistory` → loads `about:blank`/new-tab URL; the Swift
contract (§8) forbids show before restore, and §5.3 restore returns false
after first commit so the error is visible in logs.

Rebase risk: highest in this plan. Keep the Chrome branch to the flag check
plus the create/insert lines. Nothing else in `Create` changes.

### 5.3 P-MEM-04 — History capture and restore (core patch)

Purpose: capture the full back/forward list with scroll and form state into
opaque bytes, and install it on a fresh controller before first show.

New public header (overlay file
`Engine/fork/src/cef/include/cef_navigation_history.h`; it copies to
`src/cef/include/cef_navigation_history.h`). Follow the translator format of
`cef/include/cef_navigation_entry.h` exactly (license header, include guard,
`/*--cef(source=library)--*/`). Content:

```cpp
class CefNavigationHistory : public virtual CefBaseRefCounted {
 public:
  // Creates a history for restore from pickled entries (one CefBinaryValue
  // per entry, in back-to-forward order) and the current entry index.
  // Returns nullptr if |entries| is empty or |current_index| is out of range.
  /*--cef()--*/
  static CefRefPtr<CefNavigationHistory> Create(
      CefRefPtr<CefListValue> entries, int current_index);

  /*--cef()--*/
  virtual int GetEntryCount() = 0;
  /*--cef(index_param=index)--*/
  virtual CefRefPtr<CefBinaryValue> GetEntryAt(int index) = 0;
  /*--cef()--*/
  virtual int GetCurrentIndex() = 0;
  // Title of the current entry at capture time. Empty for created histories.
  /*--cef()--*/
  virtual CefString GetTitle() = 0;
  // Favicon URL of the current entry at capture time. Empty if none.
  /*--cef()--*/
  virtual CefString GetFaviconURL() = 0;
  // True if entries carry page state (scroll/form). False after the
  // size-cap fallback dropped it (see plan §7).
  /*--cef()--*/
  virtual bool HasPageState() = 0;
};
```

Include `cef_values.h` for `CefListValue`/`CefBinaryValue` and `cef_base.h`.
If the translator does not emit `cef/include/capi/cef_navigation_history_capi.h`
after the §6 run, the new header is not in the translator file list: find the
list (`grep -rn "cef_navigation_entry" cef/tools/*.py cef/*.gypi 2>/dev/null`)
and add `cef_navigation_history.h` next to `cef_navigation_entry.h` in that
same file. That list edit is part of this patch.

New C++ API on the host. In `cef/include/cef_browser.h`, in
`class CefBrowserHost`, immediately after `GetNavigationEntries` (line 669),
add an `#include "include/cef_navigation_history.h"` at the top include block
and:

```cpp
  ///
  /// Capture the full navigation history (back/forward list with scroll and
  /// form state) as opaque pickled entries. Must be called on the UI thread.
  /// Returns nullptr on failure (no WebContents, empty history, or a
  /// serialization error). Capture before Discard or CloseBrowser; the
  /// renderer is not contacted.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefNavigationHistory> GetNavigationHistory() = 0;

  ///
  /// Install a captured history on an unused controller. Must be called on
  /// the UI thread before the first navigation and before first show.
  /// Returns false if the controller already has entries, if any entry
  /// fails to decode, or if |history| is empty. On success the current
  /// entry loads on show and document.wasDiscarded is set for the first load.
  ///
  /*--cef()--*/
  virtual bool RestoreNavigationHistory(
      CefRefPtr<CefNavigationHistory> history) = 0;
```

Entry extensions. In `cef/include/cef_navigation_entry.h`, after
`GetHttpStatusCode` and before `GetSSLStatus`, add:

```cpp
  /*--cef()--*/
  virtual CefString GetReferrerURL() = 0;
  /*--cef()--*/
  virtual CefString GetFaviconURL() = 0;
```

Do not add a timestamp getter: `GetCompletionTime()` already returns
`NavigationEntry::GetTimestamp()` (see `navigation_entry_impl.cc`).

Implementation (overlay files `navigation_history_impl.{h,cc}` plus hunks in
existing files). Class `CefNavigationHistoryImpl : public CefNavigationHistory`
holding `std::vector<std::vector<unsigned char>> entries_`,
`int current_index_`, `CefString title_`, `CefString favicon_url_`,
`bool has_page_state_`. It is a plain ref-counted value: no `CefValueBase`,
no detached state. `Create` validates `entries` non-null, size ≥ 1,
`0 ≤ current_index < size`, and that every list item is a binary value
(`entries->GetBinary(i)` non-null); it copies bytes with
`GetData(buffer, size, 0)`. All methods are const reads of immutable state,
safe on any thread.

In `cef/libcef/browser/navigation_entry_impl.{h,cc}` declare and implement
the two getters over `mutable_value()` (F-12):
`GetReferrerURL` returns `mutable_value()->GetReferrer().url.spec()`;
`GetFaviconURL` returns `mutable_value()->GetFavicon().url.spec()` (empty
when the `GURL` is invalid). Guard each with the existing
`CEF_VALUE_VERIFY_RETURN(false, CefString())` macro used by siblings.

In `cef/libcef/browser/browser_host_base.{h,cc}` declare the two host
methods on `CefBrowserHostBase` and implement them next to
`GetNavigationEntries`. Both require the UI thread (D-4 getter rule; for
restore also the setter rule — restore never re-posts, it fails off thread
so a show cannot race it). Capture algorithm, exactly:

1. `auto* wc = GetWebContents(); if (!wc) return nullptr;`
2. `auto& controller = wc->GetController();` Read
   `count = controller.GetEntryCount()`, `current = controller.GetCurrentEntryIndex()`.
   If `count == 0` return nullptr.
3. For each index `i`: `auto* entry = controller.GetEntryAtIndex(i);` If
   null, return nullptr (whole capture fails; no partial history).
   `auto serialized = sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(i, entry, sessions::ContentSerializedNavigationBuilder::DEFAULT);`
   Serialize with one `base::Pickle pickle; serialized.WriteToPickle(std::numeric_limits<int>::max(), &pickle);`
   Copy `pickle.size()` bytes from `pickle.data()` into the entry blob.
   (Pass max size, not a small cap: F-11 truncates strings, and a truncated
   URL breaks restore. The cap is enforced on the total in step 4.)
4. Total = sum of blob sizes. If total > 2 MiB (2 * 1024 * 1024), redo step 3
   with `EXCLUDE_PAGE_STATE` and set `has_page_state = false`. If still over,
   return nullptr.
5. Title and favicon come from the serialized current entry
   (`serialized.title()`, `serialized.favicon_url().spec()`), not from a
   second controller read. Build `CefNavigationHistoryImpl` and return it.

Restore algorithm, exactly:

1. Validate: on UI thread, `history` non-null, `GetEntryCount() ≥ 1`,
   `wc = GetWebContents()` non-null. Else return false.
2. `auto& controller = wc->GetController();` If
   `controller.GetEntryCount() != 0` return false (already used; this also
   covers "after first commit"). If `controller.GetPendingEntry()` is
   non-null return false.
3. For each blob: construct `base::Pickle pickle(data, size)` and
   `base::PickleIterator it(pickle)`; `sessions::SerializedNavigationEntry s;`
   If `!s.ReadFromPickle(&it)` return false with no controller change.
4. `auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(base::span<const sessions::SerializedNavigationEntry>(list), wc->GetBrowserContext());`
   If `entries.size()` != blob count return false.
5. `controller.Restore(history->GetCurrentIndex(), content::RestoreType::kRestored, &entries);`
   Then `wc->SetWasDiscarded(true);` (F-7: only ever pass true). Return true.
   Do not load: the current entry loads on show.

GN wiring. In `cef/BUILD.gn`, `libcef_static` target: add
`"libcef/browser/navigation_history_impl.cc"` and `.h` to `sources`
(alphabetical, next to `navigation_entry_impl.cc`), and add
`"//components/sessions"` to `deps` (alphabetical). Add
`"include/cef_navigation_history.h"` wherever `includes_common` lists public
headers if such a list exists (`grep -n "cef_navigation_entry.h" cef/BUILD.gn`);
if no such list exists, change nothing there.

Includes for `browser_host_base.cc`: `base/pickle.h`,
`components/sessions/content/content_serialized_navigation_builder.h`,
`components/sessions/core/serialized_navigation_entry.h`,
`content/public/browser/navigation_controller.h`,
`content/public/browser/restore_type.h`, and the new impl header.

Threading: both methods UI-thread only (above). Capture never contacts the
renderer, so it is safe on a frozen or about-to-discard tab and at quit.

Failure modes: renderer already gone (crash) → controller still readable in
the browser process; capture succeeds from committed entries. Capture after
discard-in-place → controller intact (D-1); succeeds. Decode failure after a
Chromium rebase → restore step 3 returns false; Swift falls back to a
single-entry load from the sidecar URL (§7). Empty history (new tab never
navigated) → capture returns nullptr; Swift stores no blob and treats the tab
as a plain placeholder.

### 5.4 P-MEM-02 — Freeze

Purpose: stop renderer work for a hidden tab at near-zero restore cost.

In `cef/include/cef_browser.h` after the P-MEM-04 methods add:

```cpp
  /*--cef()--*/
  virtual bool SetPageFrozen(bool frozen) = 0;
  /*--cef()--*/
  virtual bool IsPageFrozen() = 0;
```

In `CefBrowserHostBase` add a protected `bool page_frozen_ = false;` member
(UI thread only; protected because the P-MEM-01 show path clears it, below).
Implement in `browser_host_base.cc`:

- `SetPageFrozen`: re-post to UI thread when off thread (setter rule).
  On thread: `wc = GetWebContents()`; if null return false. If `frozen` and
  `wc->GetVisibility() == content::Visibility::VISIBLE` return false without
  calling content (F-4 contract; do not rely on the content DCHECK).
  Else `wc->SetPageFrozen(frozen); page_frozen_ = frozen; return true;`
- `IsPageFrozen`: UI thread required; return `page_frozen_`.
- Clear `page_frozen_ = false` in `OnWebContentsDestroyed` and wherever the
  host observes a show. Content auto-unfreezes on show (F-4), so the flag
  must clear even if Swift forgets: also clear it at the top of the
  `WasHidden(false)` forwards from P-MEM-01 by setting the flag there.
  P-MEM-01 lands first, so add this one line in this patch to both
  `WasHidden` implementations: `page_frozen_ = false;` on the show path
  (Chrome class needs access — make `page_frozen_` protected, not private).

C API: translator generates `set_page_frozen` / `is_page_frozen` on
`cef_browser_host_t` (§6). No new types.

Failure modes: freeze a visible tab → false, no state change (Swift bug;
log it). Freeze a discarded tab → `SetPageFrozen` iterates no live view
hosts; harmless; Swift policy never does this (discard supersedes freeze).

### 5.5 P-MEM-03 — Discard in place

Purpose: release the renderer while keeping the `WebContents` shell (D-1).

In `cef/include/cef_browser.h` after the P-MEM-02 methods add:

```cpp
  /*--cef(optional_param=callback)--*/
  virtual bool Discard(CefRefPtr<CefCompletionCallback> callback) = 0;
  /*--cef()--*/
  virtual bool WasDiscarded() = 0;
```

Implement in `CefBrowserHostBase`:

- `WasDiscarded`: UI thread required; `wc ? wc->WasDiscarded() : false`.
- `Discard`: re-post to UI thread when off thread, carrying the callback.
  On thread:
  1. `wc = GetWebContents()`; if null, run callback (if any) and return false.
  2. If `wc->WasDiscarded()` already true: run callback immediately and
     return true (idempotent success; F-5 never runs the closure itself).
  3. If `!base::FeatureList::IsEnabled(content::features::kWebContentsDiscard)`:
     do **not** call `wc->Discard` (F-5 `NOTREACHED`). Run callback and
     return false. (With §10 switches this never happens; the guard keeps a
     misconfigured build from crashing in debug.)
  4. Else wrap the callback: `auto closure = base::BindOnce([](CefRefPtr<CefCompletionCallback> cb) { if (cb) cb->OnComplete(); }, callback);`
     Call `wc->Discard(std::move(closure));` Clear `page_frozen_`.
     Return true.
  5. Speculative-refusal cover (F-6): after the call, if
     `!wc->WasDiscarded()`, post a one-shot delayed retry on `CEF_UIT`
     (100 ms; use `CefPostDelayedTask(CEF_UIT, retry_task, 100)` via a small
     `CefTask` or `base::SingleThreadTaskRunner` equivalent already used in
     libcef — copy the delayed-task pattern from the nearest sibling in
     `browser_host_base.cc`, do not invent a timer class). The retry repeats
     steps 2–4 once. If still not discarded, run the callback (if not yet
     run) so Swift is never left waiting. Track "callback run" with a
     `std::shared_ptr<std::atomic_bool>` shared by the closure and the retry,
     or simpler: in the retry path, only the retry runs the callback when
     step 4 was skipped. Keep exactly one run: guard with a bool captured in
     a ref-counted helper struct if needed. Do not run Swift-visible code
     twice.

Add includes: `base/feature_list.h`, `content/public/common/content_features.h`.

Swift contract (normative): `Discard` returning true means accepted, not
released. The callback means settled. After either, Swift checks
`WasDiscarded()`; false means "still live, retry later", and the tab stays
frozen. Never mark a tab sleeping on the callback alone.

Failure modes: discard during pending-commit navigation → retried once,
then settled false (above). Discard a visible tab → content has no such
guard; Swift policy forbids it (visible is never eligible, §9). Discard with
a `beforeunload` handler → §5.6 gate runs first; this method itself does not
prompt and never shows a dialog.

### 5.6 P-MEM-06 — Eligibility flags (deferred sources, v1 subset)

Purpose: give Swift the engine signals the never-sleep list needs (§9).

In `cef/include/cef_browser.h` after the P-MEM-03 methods add exactly one
method in v1:

```cpp
  /*--cef()--*/
  virtual bool HasUnloadHandlers() = 0;
```

Implement in `CefBrowserHostBase` on the UI thread:
`wc ? wc->NeedToFireBeforeUnloadOrUnloadEvents() : false`
(`content/public/browser/web_contents.h:1068`, verified).

Do **not** add `HasFormUserEdits`, `HasActiveLocks`, or `IsCapturing` C++
methods in v1. Their content sources (form-edit tracking, WebLock/IndexedDB
lock state, capturer count query) were not verified to a public getter in
this tree. Swift uses the documented proxies in §9 until a follow-up patch
proves each source. Adding stub-false getters now would silently mark locked
pages discardable. That is worse than no getter.

Failure mode: `HasUnloadHandlers` true → Swift keeps the tab frozen and
never discards it silently (§9). The page keeps its unload prompt rights.

### 5.7 P-MEM-07 — Feature and switch defaults

No fork patch. All switches live in OpenEngine (§10). The only tree-visible
requirement is that `--enable-features=WebContentsDiscard` is on before any
`Discard` call (§5.5 step 3 guards the off case instead of crashing).

## 6. CEF C API and translator regeneration (exact procedure)

Every new C++ method in §5.2–§5.6 needs its C API twin. The translator owns
that twin. Never hand-edit anything under `cef/include/capi/`,
`cef/libcef_dll/cpptoc/`, `cef/libcef_dll/ctocpp/`, or
`cef/include/cef_api_versions.h`, and never hand-edit
`cef/cef_api_versions.json`.

C API that must exist after regeneration (names follow the translator rule
CamelCase → lowercase_underscore on `cef_browser_host_t`):

| C++ (on `CefBrowserHost`) | C API (on `cef_browser_host_t`) |
|---|---|
| `GetNavigationHistory()` | `get_navigation_history` |
| `RestoreNavigationHistory(history)` | `restore_navigation_history` |
| `SetPageFrozen(bool)` | `set_page_frozen` |
| `IsPageFrozen()` | `is_page_frozen` |
| `Discard(callback)` | `discard` |
| `WasDiscarded()` | `was_discarded` |
| `HasUnloadHandlers()` | `has_unload_handlers` |

Plus a new `_cef_navigation_history_t` for `CefNavigationHistory` (with
`create`, `get_entry_count`, `get_entry_at`, `get_current_index`, `get_title`,
`get_favicon_url`, `has_page_state` as the translator derives them) and the two
new entry getters on `_cef_navigation_entry_t` (`get_referrer_url`,
`get_favicon_url`). After regeneration, confirm each name with
`grep -n "get_navigation_history\|set_page_frozen\|_cef_navigation_history_t" cef/include/capi/*.h`.
If a name differs from this table, the generated name wins; fix this plan's
§8 glue to match and note it in the PR. Do not rename generated output.

Regeneration procedure (run in the tree, [WAIT] only, once per patch that
touches `cef/include/*.h` — P-MEM-05 settings field included, because
`cef_types.h` feeds the wrapper):

```sh
SRC=~/Developer/open-engine/chromium_git/chromium/src
cd "$SRC/cef/tools"
python3 translator.py --root-dir ..
cd "$SRC/cef/tools"
python3 version_manager.py
```

`translator.sh` (`python3 translator.py --root-dir ..`) is the same first
command; use either, not both. `version_manager.py` with no arguments updates
translated files and the experimental/next hashes (F-18). Do not run it with
`-a` (D-7). Expected results: new or changed files under
`cef/include/capi/`, `cef/libcef_dll/`, and a hash update in
`cef/cef_api_versions.json` / `cef/include/cef_api_versions.h`. If
`version_manager.py` reports a changed **versioned** (numbered) hash as an
error, stop: a numbered API was edited. Fork API must stay experimental.

Stub bodies: the translator emits new `libcef_dll` impl stubs marked
`AUTO-GENERATED CONTENT - DELETE THIS COMMENT BEFORE MODIFYING` (or
`BEGIN DELETE BEFORE MODIFYING` in CToCpp/CppToC impls). For library classes
(`CefNavigationHistory`, host methods) the real body lives in `libcef`,
already written in §5; delete only the stub comment in the wrapper file when
the wrapper forwards to it. If a stub warns "is not implemented", the wrapper
does not forward yet — fix the wrapper to call the `CefBrowserHostBase` /
`CefNavigationHistoryImpl` method. Never implement logic inside a generated
file beyond the one-line forward the file's siblings already show.

Version guard rule for all new API: declare it inside
`#if CEF_API_ADDED(CEF_EXPERIMENTAL)` where the surrounding header uses
guards, with `/*--cef(added=experimental)--*/` on the method (copy the shape
at `cef/include/cef_browser.h:1076`). Client code (OpenEngine) builds with
the default `CEF_API_VERSION`, which is experimental (F-18), so no client
define is needed. Do not use `CEF_NEXT`.

After each translator run, capture everything into the patch with
`engine-refresh-patches` (fork-infra §6.4). A second `engine-apply` on the
patched tree must be a no-op. That no-op is part of every header patch's
acceptance.

## 7. Serialized history format and Swift persistence

### 7.1 Two layers: CEF pickle bytes, Open container bytes

Layer 1 (inside libcef, never seen by Swift): one `base::Pickle` byte string
per navigation entry, produced by `SerializedNavigationEntry::WriteToPickle`
(§5.3). Chromium owns this format. It is tied to the Chromium pin (F-1).
Swift treats each entry blob as opaque bytes.

Layer 2 (owned by OpenEngine, stored by Swift): one container `Data` per
sleeping tab that packs the entries so OpenKit never links CEF types.
OpenEngine builds it from `CefNavigationHistory` on capture and parses it
back to `CefNavigationHistory::Create` on restore. All integers are
little-endian. Layout, version 1:

```text
offset  size  field
0       4     magic: ASCII "OPNH" (0x4F 0x50 0x4E 0x48)
4       4     containerVersion: UInt32 = 1
8       4     entryCount: UInt32 (≥ 1)
12      4     currentIndex: UInt32 (< entryCount)
16      1     flags: UInt8 (bit 0 = hasPageState; other bits must be 0)
17      3     reserved: must be 0
20      …     per entry, entryCount times:
                UInt32 byteLength, then byteLength raw pickle bytes
```

No title, URL, or favicon inside the container. Those live as sidecar
columns (§7.2) so the fallback in §7.3 works even when the container is
unreadable. Container overhead is 20 bytes plus 4 bytes per entry.

OpenEngine validation on parse (any failure → reject the whole container,
never a partial restore): magic matches; `containerVersion == 1`;
`entryCount` in `1...512`; `currentIndex < entryCount`; reserved bytes and
unknown flag bits are 0; total length matches the sum of entry lengths
exactly (no trailing bytes); every `byteLength` in `1...2 MiB`. Entry-count
cap rationale: 512 matches a long-lived tab's history with wide margin and
bounds parse work. Reject, do not clamp.

### 7.2 Size limits

- Per-tab container cap: **2 MiB** (2 * 1024 * 1024 bytes) total, enforced
  twice: in libcef capture (§5.3 step 4, with the `EXCLUDE_PAGE_STATE`
  retry) and again in `SleepStore.save` (reject over-cap writes with an
  error the caller logs; never truncate a container).
- Typical size is kilobytes to low hundreds of kilobytes. A tab that still
  exceeds the cap without page state fails capture (§5.3). Swift then keeps
  the tab frozen and discards only via the destroy-with-fallback path: on
  wake it loads the sidecar current URL as a fresh single-entry tab.
  History is lost for that tab; the page itself is never lost.
- Disk budget: 100 sleeping tabs cost at most 200 MiB worst case, typically
  under 20 MiB. No global cap in v1; `SleepStore.totalBytes()` exposes the
  sum for the §11 report.

### 7.3 Versioning and fallback

- `containerVersion` versions the Open packing only. Bump it when the
  layout above changes. The pickle payload inside is versioned by Chromium
  session restore itself (F-11) and by the engine pin.
- Every stored row also records `chromiumTag` (the `CHROMIUM_TAG` from
  `Engine/fork/VERSIONS`, passed in by the App at capture; OpenKit never
  reads `VERSIONS`). On restore, OpenEngine attempts decode regardless of
  tag. If `RestoreNavigationHistory` returns false (decode failure after a
  rebase is the expected case), Swift falls back to a single-entry wake:
  create the browser normally and load the sidecar `currentURL`. Log
  `sleep-restore-fallback` with the tab ID prefix. Never block wake on a
  blob error and never surface a user dialog for it.
- Corrupt-container test (§11 flow F4) uses this path: flip one byte in a
  stored blob, wake the tab, expect the current page at the sidecar URL
  with Back disabled.

### 7.4 OpenModel changes (runtime only, plus one setting)

In `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift`:

- Add next to `TabLiveState`:
  `public enum SleepPhase: Sendable { case placeholder, live, frozen, sleeping }`.
  Meanings: `placeholder` = no engine content exists; `live` = content
  exists and is not frozen; `frozen` = depth 1; `sleeping` = depth 2
  (discarded in place, or destroyed — which one is tracked by `OpenSleep`'s
  content set, not by the model). Default for a new `Tab` is `placeholder`;
  the App adapter sets
  `live` when it creates content.
- Add to `TabLiveState`: `public var sleepPhase: SleepPhase = .placeholder`,
  `public var isCapturing: Bool = false`,
  `public var devToolsOpen: Bool = false`,
  `public var lastFormInteractionAt: Date? = nil`.
  All runtime-only, never persisted, same rule as the existing fields.
  `isCapturing`/`devToolsOpen` are written by the App engine adapter from
  engine callbacks; OpenKit code only reads them. `lastFormInteractionAt`
  is written by the App adapter on form-focus events as the §9 proxy until
  P-MEM-06 grows real flags.

In `Packages/OpenKit/Sources/OpenModel/Containers.swift`:

- Add `public enum SleepMode: String, Codable, CaseIterable, Sendable { case off, conservative, balanced, aggressive }`
  with `discardDelay: TimeInterval?` = off → nil, conservative → 900,
  balanced → 300, aggressive → 120. Freeze delay is always 30 s; destroy
  delay is always 24 h. Neither is a mode value.
- Add `public var sleepMode: SleepMode` to `ProfileSettings` with default
  `.balanced`, including the `init` parameter. Update every `ProfileSettings(...)`
  call site the compiler finds; do not add a second init.

No change to persisted `Tab` fields. No change to `BrowserModel` commands.
Sleeping is not a model command: it changes no sidebar structure, emits no
`TreeChange`, and registers no undo. `closeTab` on a placeholder or sleeping
tab already works (it archives by ID); the App adapter destroys engine
content if any exists (§9). Archiving keeps the sleep row (§7.5), so
`restoreArchivedTab` rebuilds a tab whose history is still restorable.

### 7.5 OpenStore changes: new `SleepStore` (separate store, not the JSON snapshot)

Create `Packages/OpenKit/Sources/OpenStore/SleepStore.swift`. Copy the shape
of `ArchiveStore.swift` in the same target: main-actor entry points that
snapshot plain values, one private serial `DispatchQueue`
(`open.sleep`, `.utility`), lazy `openOnQueue()`, reuse of `SQLiteDB` from
`SQLiteSupport.swift`, WAL already handled by that helper if it sets it —
check `SQLiteSupport.swift` first and match `HistoryStore`/`ArchiveStore`
conventions. File URL: `root.appendingPathComponent("State/sleep.sqlite3")`
with the same injectable `root` as `SnapshotStore` (default
`~/Library/Application Support/Open`).

Schema (create in `openOnQueue`, `IF NOT EXISTS`):

```sql
CREATE TABLE IF NOT EXISTS sleep_history(
  tab_id TEXT PRIMARY KEY,
  container BLOB NOT NULL,
  current_index INTEGER NOT NULL,
  entry_count INTEGER NOT NULL,
  current_url TEXT NOT NULL,
  current_title TEXT NOT NULL,
  favicon_url TEXT,
  has_page_state INTEGER NOT NULL,
  container_version INTEGER NOT NULL,
  chromium_tag TEXT NOT NULL,
  captured_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS sleep_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

Public API (all writes copy values on the main actor, all SQLite on the
queue; reads are `async` like `ArchiveStore` queries):

```swift
public struct SleepHistoryRecord: Sendable {
    public var tabID: ItemID
    public var container: Data
    public var currentIndex: Int
    public var entryCount: Int
    public var currentURL: URL
    public var currentTitle: String
    public var faviconURL: URL?
    public var hasPageState: Bool
    public var containerVersion: Int
    public var chromiumTag: String
    public var capturedAt: Date
}

public func save(_ record: SleepHistoryRecord)   // upsert; rejects container > 2 MiB (log + drop, no throw across actors: surface via onError callback below)
public func load(tabID: ItemID) async -> SleepHistoryRecord?
public func delete(tabID: ItemID)
public func delete(tabIDs: [ItemID])
public func allTabIDs() async -> [ItemID]
public func totalBytes() async -> Int
public func flushQueue()  // CLI/test helper, same as ArchiveStore
```

Error surfacing: `SleepStore` has
`public var onError: ((String) -> Void)?` called with a plain message for
over-cap or SQLite failures. Persistence failure must never crash the app
(same rule as `SnapshotStore.write`). The `openkit` demo and the App both
set it (stderr / automation log respectively).

Snapshot DTO wiring (`SnapshotDTOs.swift`): the **only** snapshot change is
`ProfileSettingsDTO.sleepMode`. Add `public var sleepMode: String?` (optional
so schema-1 files written before this plan still decode — synthesized
`Codable` treats a missing optional key as nil). Map nil → `.balanced` in
`SnapshotMapper`. Do not bump `schemaVersion`. Do not add any field to
`TabDTO`. Prove old-file decode in acceptance (§12 Step S0): load a
pre-change snapshot fixture, save, reload, `roundtrip OK`.

Quit capture: at quit the App adapter calls capture for every live or frozen
tab that has engine content and whose cheap fields changed since the last
capture, then `saveNow` on the snapshot plus `flushQueue()` on the sleep
store. Never block quit on a renderer round trip — capture reads the
browser-process controller (§5.3), so this is bounded memory work. If quit
is forced, the last sleep-time capture stands; worst case is the §7.3
single-entry fallback.

## 8. OpenEngine surface (ObjC++ and Swift)

The App target and `Engine/OpenEngine/` do not exist yet (F-21). This section
is the contract the engine spike implements. Do not create a parallel CEF
wrapper elsewhere. Only OpenEngine includes CEF headers
(`docs/architecture.md`).

### 8.1 Swift protocol (in OpenKit, no engine imports)

File `Packages/OpenKit/Sources/OpenSleep/SleepEngine.swift`. The App target's
adapter is the only conformer. All methods are `@MainActor` (CEF UI thread is
the main thread). `ItemID` keys every call (Open's stable ID, never a CEF
browser integer).

```swift
public protocol SleepEngine: AnyObject {
    func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool
    func destroyContent(tabID: ItemID)
    func setVisible(tabID: ItemID, visible: Bool)
    func freeze(tabID: ItemID) -> Bool
    func discard(tabID: ItemID) async -> Bool
    func wasDiscarded(tabID: ItemID) -> Bool
    func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope?
    func hasUnloadHandlers(tabID: ItemID) -> Bool
    func handleCriticalPressure()
}
```

Semantics the adapter must honor:

- `createContent(history:)`: when `history` is non-nil, create with
  `no_renderer` set, call `RestoreNavigationHistory` before any show, then
  show. Return false when restore fails; the caller then retries once with
  `history: nil` and loads `history.currentURL` (the §7.3 fallback). When
  `history` is nil, create normally and load `url`.
- `captureHistory`: returns the full record (container built by OpenEngine
  from `CefNavigationHistory`, sidecars from the history's title/favicon and
  the tab's current URL/title). Returns nil on capture failure. Never
  returns a partial record.
- `discard`: calls `CefBrowserHost::Discard`, awaits the completion
  callback, then returns `wasDiscarded(tabID:)`. The return value is the
  re-check (D-5), never the callback alone.
- `setVisible`: forwards to `WasHidden(!visible)`. The caller sends only
  real transitions.
- `destroyContent`: `CloseBrowser(true)`. Never delete a `WebContents`
  directly (Chrome-style ownership, F-14).

### 8.2 ObjC++ glue (in OpenEngine, when it exists)

One new file pair in the OpenEngine target, next to the existing web-content
wrapper (find it by the class that owns `CefBrowserHost`; do not create a
second browser registry):

- `OpenSleepBridge.h/.mm`: owns the `ItemID (NSString UUID) → CefRefPtr<CefBrowserHost>`
  lookup through the existing registry, implements the §8.1 calls, and the
  container pack/unpack of §7.1 as two C functions:
  `NSData* _Nullable OpenPackHistory(CefRefPtr<CefNavigationHistory>)` and
  `CefRefPtr<CefNavigationHistory> OpenUnpackHistory(NSData*)` (returns null
  on any §7.1 validation failure). Little-endian reads/writes with explicit
  byte shifts, never struct casts (alignment). All CEF calls dispatch to the
  UI thread: if not on the main thread, `dispatch_async(dispatch_get_main_queue(), …)`
  for void calls; synchronous getters assert main thread in debug and the
  Swift layer already guarantees `@MainActor`.
- Discard completion: a small `CefCompletionCallback` subclass whose
  `OnComplete` resumes the Swift continuation exactly once (guard with an
  atomic flag; the §5.5 retry can settle without the closure).

No Swift file outside the App adapter imports OpenEngine. No OpenKit file
imports CEF, OpenEngine, or Chromium headers. Enforce by target dependencies
in `Package.swift` (§9.1) and by review.

## 9. Swift policy layer (`OpenSleep` target)

### 9.1 Target wiring

In `Packages/OpenKit/Package.swift` add a library product `OpenSleep` and a
target `OpenSleep` with `dependencies: ["OpenModel"]` only. Add `OpenSleep`
to the `openkit` executable's dependencies for the §12 demo. Do not add
`OpenStore` as a dependency of `OpenSleep`: the controller receives the
store through the narrow protocol in §9.2 so `OpenSleep` stays store-free
and the App can substitute stores. Files:

```text
Packages/OpenKit/Sources/OpenSleep/
  SleepEngine.swift      # §8.1 protocol + SleepPhase helpers
  SleepPolicy.swift      # pure eligibility + timing decisions (§9.3)
  SleepController.swift  # timers, pressure source, engine/store orchestration (§9.4)
```

### 9.2 Store seam

In `SleepEngine.swift` also declare the envelope and the store seam.
`SleepHistoryRecord` is defined in `OpenStore` (§7.5), so `OpenSleep` must
never name it:

```swift
public struct SleepHistoryEnvelope: Sendable {
    public var container: Data
    public var currentIndex: Int
    public var entryCount: Int
    public var currentURL: URL
    public var currentTitle: String
    public var faviconURL: URL?
    public var hasPageState: Bool
    public var containerVersion: Int
    public var chromiumTag: String
    public var capturedAt: Date
}

public protocol SleepHistoryStoring: AnyObject {
    func saveSleepHistory(tabID: ItemID, envelope: SleepHistoryEnvelope)
    func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope?
    func deleteSleepHistory(tabID: ItemID)
}
```

The `SleepEngine` protocol in §8.1 already uses `SleepHistoryEnvelope`
for its two history methods. The App adapter maps
envelope ↔ `SleepHistoryRecord` (field-for-field, plus `tabID`) over
`SleepStore`. `SleepStore` itself does not conform to
`SleepHistoryStoring`; the App's one-file adapter does. The `openkit` demo
(§12 Step S0) uses a tiny in-memory `SleepHistoryStoring` plus the real
`SleepStore` through the same mapping, written inside the CLI target only.
`OpenSleep` imports `Foundation` and `OpenModel` only. This keeps the D-8
dependency rule true.

### 9.3 Policy (pure decisions, fake-clock friendly)

`SleepPolicy` is a value type with `mode: SleepMode`,
`freezeDelay = 30`, `destroyDelay: TimeInterval = 24 * 3600`,
`audioProtection: TimeInterval = 60`, `loadProtection: TimeInterval = 10`,
`formProtection: TimeInterval = 300`. It reads only `Tab`, `TabLiveState`,
visibility, and `now`. Visibility is passed in as a `Set<ItemID>` of
currently visible tabs (selected tab per window plus visible split panes),
computed by the controller from `BrowserModel.windows`
(`selectedNodeBySpace`, focused split pane). No timers, no engine calls.

Eligibility gates (check in this order, return the first reason for
logging). Rules 1–6 block both freeze and discard. Rules 7–8 block discard
only:

1. Tab is visible (in the passed-in visible set).
2. `live.isAudible` now, or audible within `audioProtection` (controller
   tracks `lastAudibleAt` per tab from `isAudible` transitions).
3. `live.isLoading`, or last commit within `loadProtection` (controller
   tracks `lastCommitAt` from loading transitions).
4. `live.isCapturing` (includes mirroring, PiP, WebRTC — the adapter sets
   one flag from capturer/media callbacks).
5. `live.devToolsOpen` is true.
6. Tab has an in-progress download (adapter-maintained set passed in).
7. Engine `hasUnloadHandlers` is true (controller caches the §5.6 result
   per live tab, refreshed each tick; a true value blocks discard only,
   never freeze — a frozen page keeps its handler and prompts on real close).
8. Form proxy: `live.lastFormInteractionAt` within `formProtection`
   blocks discard only (until P-MEM-06 proves real edit state).

Pinned rule (state it in the settings UI copy): a quiet pinned tab or
favorite sleeps like any other tab. Pin state alone never protects. A pinned
tab that is audible, capturing, or playing media is protected by rules 2/4,
not by pinning. `isPinned(tabID:)` is therefore not an input to sleep
eligibility at all.

Freeze eligibility: hidden (rule 1 false) and rules 2–6 false, hidden for
≥ `freezeDelay` (`now - lastActiveAt`, where `lastActiveAt` already updates
on selection — `BrowserModel` sets it; verify at `BrowserModel.swift` the
`selectNode` path sets `lastActiveAt = Date()` and do not add a second
clock). Discard eligibility: freeze-eligible (or already frozen), rules
7–8 false, hidden for ≥ `mode.discardDelay` (nil delay in `.off` mode means
never auto-discard; freeze still applies). Destroy eligibility: phase
`.sleeping`, sleeping for ≥ `destroyDelay` (controller records `sleptAt`
per tab at discard), or critical memory pressure (§9.4).

### 9.4 Controller (timers, pressure, orchestration)

`SleepController` is `@MainActor`, init with `model: BrowserModel`,
`engine: SleepEngine`, `store: SleepHistoryStoring`,
`chromiumTag: String`, and `now: () -> Date` (injectable clock; production
passes `Date.init`, the demo passes a fake). State per tab (dictionaries
keyed by `ItemID`): `lastAudibleAt`, `lastCommitAt`, `sleptAt`,
`downloading: Set<ItemID>` (fed by the App), `unloadCache: [ItemID: Bool]`.

- `start()`: schedules one repeating 5-second tick (`Task` loop with
  `Task.sleep`, cancelled in `stop()`) and installs the memory-pressure
  source (below). One global tick, never one timer per tab. Each tick:
  compute the visible set, refresh `unloadCache` for live tabs, then walk
  tabs oldest-`lastActiveAt` first and apply at most one transition per tab
  per tick in ladder order (hide is driven by selection changes, not the
  tick; the tick handles freeze → discard → destroy).
- Selection changes: the App calls `controller.tabBecameVisible(tabID)` /
  `tabBecameHidden(tabID)` (or the controller observes `BrowserModel`
  windows directly — pick observation in implementation, one mechanism
  only). Visible: `engine.setVisible(true)`; if phase is `.frozen`, content
  auto-unfreezes on show (clear phase to `.live`); if `.sleeping` with
  content, show triggers reload (`SetNeedsReload`, F-6) and phase becomes
  `.live` on first commit; if `.sleeping` destroyed or `.placeholder`,
  run the wake path: `store.sleepHistory` → `engine.createContent`.
  Hidden: `engine.setVisible(false)` and stamp the hidden time from
  `lastActiveAt`.
- Freeze action: `engine.freeze` true → phase `.frozen`. False (visible
  race) → leave `.live`, retry next tick.
- Discard action, in exact order: (1) `engine.captureHistory` — nil means
  keep frozen, log `sleep-capture-failed`, stop. On success stamp
  `envelope.chromiumTag = chromiumTag` (the init value wins over whatever
  the adapter returned); (2) `store.saveSleepHistory(tabID:envelope:)`;
  (3) `await engine.discard` — false means keep frozen (blob stays stored;
  it is refreshed at next successful discard or quit); (4) phase
  `.sleeping`, `sleptAt = now`, clear `live.isLoading`, set
  `live.canGoBack = currentIndex > 0` and
  `live.canGoForward = currentIndex < entryCount - 1` from the envelope so
  the UI stays correct with no engine.
- Destroy action: `engine.destroyContent`; phase stays `.sleeping`
  (content-exists tracking is the controller's `liveContent: Set<ItemID>`,
  not the model). Wake from destroyed uses the stored envelope.
- Wake latency logging: stamp `wakeStartedAt` at selection, log elapsed at
  first commit (adapter reports commit through the controller's
  `tabDidCommit(tabID)`) with the wake kind (`unfreeze`, `discard`,
  `destroyed`) to the automation log. Budgets in §11.
- Memory pressure: in `start()`,
  `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)`,
  `setEventHandler` reads `source.data` — `.warning`: discard every
  freeze-eligible frozen tab oldest first (skip never-sleep rules; capture
  first, same order as timed discard). `.critical`: additionally destroy
  every `.sleeping` tab's content immediately and call
  `engine.handleCriticalPressure()` (§8.1; the adapter lets
  `SpareRenderProcessHostManager` reap the spare — no new CEF API).
  `resume()` the source; cancel it in `stop()`. Never discard the visible
  tab under any pressure level.
- `captureAllForQuit() async`: for every tab in `liveContent`, capture and
  save (skip tabs whose envelope already matches current URL + entry count
  — cheap compare only; when in doubt, capture). Called by the App before
  snapshot `saveNow`. Budget: log total elapsed; no per-tab renderer wait
  exists (§5.3), so no timeout logic.
- `debugSleepNow(tabID:)`: automation/demo-only helper that runs the
  discard action for one tab immediately, ignoring delays but never the
  never-sleep rules. The `openkit` demo and the automation channel may call
  it. No user-facing UI calls it, and it is not a setting.

User setting surface: `ProfileSettings.sleepMode` (§7.4) per profile. The
controller uses the mode of the profile that owns the tab's Space
(`Space.profileID` → `BrowserModel` profile lookup). Settings UI copy must
include the pinned sentence from §9.3. Changing mode to `.off` stops future
auto-discards; already-sleeping tabs stay sleeping until selected.

No engine imports in `OpenSleep`: it imports `Foundation` and `OpenModel`
only. `DispatchSource` is `Foundation`/`Dispatch` and is allowed.

## 10. Engine feature switches (P-MEM-07, exact strings)

Set these in OpenEngine's `CefApp` subclass,
`OnBeforeCommandLineProcessing` (F-20), browser process only
(`process_type` empty). Use `CefCommandLine::AppendSwitchWithValue` for
`disable-features` / `enable-features` (comma-joined, no spaces). Renderer
and GPU processes inherit the feature list from the browser command line;
the smoke check below proves inheritance instead of assuming it.

Feature-name derivation (F-20): two-arg `BASE_FEATURE(kFoo, …)` means the
switch string is `Foo`. Three-arg form uses its explicit string. Every row
was read in this tree; file and line are the declaration or definition.

Disable by default (`--disable-features=`):

| Switch string | C++ symbol | Declared / defined in | Default here | What Open loses |
|---|---|---|---|---|
| `OptimizationHints` | `kOptimizationHints` | `components/optimization_guide/core/optimization_guide_features.h:54`, defined `.cc:60` | Enabled | Chrome page-load hints. No Open consumer in v1 |
| `OptimizationTargetPrediction` | `kOptimizationTargetPrediction` | same header `:58`, `.cc:63` | Enabled | On-device target prediction models and fetches |
| `OptimizationGuidePageContentExtraction` | `kPageTextExtraction` (explicit name) | same header `:60`, `.cc:67` | Enabled | Page-text extraction for models. Note: `PageTextExtraction` matches nothing |
| `OptimizationGuideModelExecution` | `kOptimizationGuideModelExecution` | same header `:74`, `.cc:98` | Enabled | On-device model execution service |
| `SegmentationPlatform` | `kSegmentationPlatformFeature` (explicit name) | `components/segmentation_platform/public/features.h:15`, `features.cc:14` | Enabled | ML user segmentation for Chrome UI. Open's UI does not consume segments |
| `SegmentationPlatformUkmEngine` | `kSegmentationPlatformUkmEngine` | same header, `features.cc:18` | Enabled (non-ChromeOS) | UKM segmentation uploads |
| `MediaRouter` | `kMediaRouter` | `chrome/browser/media/router/media_router_feature.h:36`, `media_router_feature.cc:47` | Enabled | Cast in v1. Re-enable as one switch when Cast is scheduled |
| `TranslateRankerQuery,TranslateRankerEnforcement` | `kTranslateRankerQuery`, `kTranslateRankerEnforcement` | declared `components/translate/core/browser/translate_ranker_impl.h:45`, defined `translate_ranker_impl.cc:92` | Both enabled | ML auto-offer of translate. Manual translate stays; there is no single `Translate` master feature — do not pass `Translate` |

Full disable value (one switch):
`OptimizationHints,OptimizationTargetPrediction,OptimizationGuidePageContentExtraction,OptimizationGuideModelExecution,SegmentationPlatform,SegmentationPlatformUkmEngine,MediaRouter,TranslateRankerQuery,TranslateRankerEnforcement`

Enable by default (`--enable-features=`):

| Switch string | Symbol | Where | Why |
|---|---|---|---|
| `WebContentsDiscard` | `kWebContentsDiscard` | `content/public/common/content_features.h:136`, `content_features.cc:381` (disabled on desktop) | Required for §5.5. Without it `WebContentsImpl::Discard` hits `NOTREACHED` (F-5) |

Keep on (deliberate non-changes): standard Safe Browsing (no switch change;
do not disable any `kSafeBrowsing…` feature to save memory), `BackForwardCache`
(D-10), `IntensiveWakeUpThrottling` (never pass
`--disable-background-timer-throttling`), GPU rasterization defaults. Never
pass `--disable-gpu`, `--process-per-site`, or
`--disable-background-timer-throttling`. `--renderer-process-limit` stays
unset by default (Chromium's RAM-scaled formula governs); OpenEngine may
set `32` only when physical memory is ≤ 8 GB. Spare renderer: keep
Chromium's one warm spare per profile; no fork change.

Smoke check for every row (part of §11 flow F0): launch the app (or
`cefsimple` with the same `CefApp`) and, for each disabled feature, prove
the service did not start — no optimization-guide model download in the
profile dir, no media-router sink discovery in logs, feature state read back
through the automation channel when it exists. A feature whose embedder
code never instantiates proves nothing; record "not instantiated" instead
of "disabled" for that row. If any switch proves unreliable across process
types, only then propose a `BASE_FEATURE` default flip as a separate patch
with the failed smoke output attached.

## 11. Acceptance (end to end, no unit tests)

Two tracks. Track A (`cefsimple`) proves the fork builds and launches after
every engine step; it cannot exercise sleep policy because stock `cefsimple`
has no Open tabs. Track B (real Open app through its automation channel,
`docs/automation.md` when the engine spike lands it; until then the manual
checklist below with the same assertions) proves behavior. Never substitute
a unit test for either track (AGENTS.md rule 6). Never drive the user's
desktop or mouse (rule 4).

Fixtures (create once, Step S0): `Engine/fork/verification/fixtures/` with
plain HTML files served locally — `a.html` → links to `b.html` → `c.html`
(a visible chain for history), `c.html` tall (≥ 5 viewport heights) with a
text input `id="q"`, a `document.wasDiscarded` reporter line, scroll
position display on `pageshow`, and a `?unload=1` query flag that adds a
`beforeunload` listener (for S5); `audio.html` with a start/stop tone button;
`ticker.html` with a 1-second timer counter (freeze check). Serve with
`python3 -m http.server 8765 --bind 127.0.0.1` from that directory. No
external network in any flow.

Memory measurement (both tracks): helpers are separate processes. Before
and after each flow run
`ps -axo pid,rss,vsz,comm | grep -i "Helper (Renderer)"` (Track A binary
name is the `cefsimple` helper; Track B is `Open Helper (Renderer)` —
record the exact `comm` strings from the first run and reuse them). Report
per-process RSS and the sum. RSS overcounts shared pages; it is the
"will the OS kill us" number. Also record renderer process count. Do not
report a per-tab memory number derived by dividing a shared process.

- **F0 Switch smoke (Track A then B).** Launch with §10 switches. Check:
  process starts, fixture `a.html` loads, no `FATAL`/`NOTREACHED` in the
  log, and the §10 per-row evidence (started / not instantiated). Fail if
  `WebContentsDiscard` reads back disabled in the browser process.
- **F1 Sleep drops processes (Track B; manual until automation exists).**
  Open the 10 fixture tabs (chain pages + ticker + audio idle). Select
  tab 1. Record baseline RSS sum and renderer count. Force sleep with the
  automation-only debug override (expose `SleepController.debugSleepNow(tabID:)`
  compiled in but callable only from the automation channel / `openkit`
  demo — never a user setting; if the channel does not exist yet, set
  mode `.aggressive` and wait, recording which path was used). Sleep 9
  tabs. Pass: sidebar still shows 10 tabs with correct titles/favicons;
  9 report sleeping; renderer count falls to ≤ 2 (selected + spare);
  RSS sum falls. Record before/after numbers. Fail if RSS grows with tab
  count or any sleeping tab still owns a renderer.
- **F2 Wake restores history, scroll, and form (Track B).** In one tab
  load A → B → C. On C, scroll halfway and type `open-sleep-check` into
  `#q` without submitting. Sleep the tab (capture must include page
  state). Wake it. Assert in order: the page is C; `document.wasDiscarded`
  was true on wake (read via automation JS before any navigation; manual
  track: the fixture prints it — screenshot or log it); scroll position
  matches (± 1 viewport row); `#q` value is `open-sleep-check`; Back
  reaches B then A; Forward reaches C. Any missing item fails the flow.
  This flow is the task's core acceptance: do not split it.
- **F3 Protection (Track B).** Start audio on `audio.html`, hide the tab,
  attempt sleep past the discard delay. Pass: tab does not discard while
  audible. Stop audio, wait past the 60 s audio protection, sleep again.
  Pass: tab discards. Repeat the shape for a capturing tab when a capture
  fixture exists; until then record capture as unverified, not passed.
- **F4 Relaunch and fallback (Track B).** Mix live, frozen, discarded,
  placeholder tabs. Quit (quit-capture runs). Relaunch. Pass: sidebar
  draws with only the selected tab owning a renderer; waking a restored
  tab restores its back list. Then corrupt one stored container (flip a
  byte in `sleep.sqlite3` via `sqlite3` CLI on a **copy** of the profile,
  never the user's live profile), wake that tab. Pass: current page loads
  from the sidecar URL, Back disabled, `sleep-restore-fallback` logged,
  no dialog, no crash.
- **F5 Latency (Track B).** For each wake kind (unfreeze, discard-in-place,
  destroyed) measure selection → first commit over 20 wakes, warm cache,
  and report p50/p95 from the controller's wake log. Budgets: unfreeze
  ≤ 16 ms to content visible; discard wake first paint ≤ 700 ms on a
  cached page; destroyed wake = discard wake + content creation (report
  separately, no budget until measured once). Publish numbers with cache
  state. A single average without p95 fails this flow.

Budgets that close the feature (release build, fixture pages). At 10 tabs
with 9 sleeping: live renderers ≤ 2 (selected + spare). The binding check
is flat scaling: at 50 tabs (placeholders + sleeping), renderer count must
equal the 10-tab sleeping count, and the RSS sum must not grow beyond one
spare renderer. Report RSS sums at 10 and 50 tabs side by side; do not
convert them to a per-tab average. Idle CPU (whole app, no media, 60 s
window after a 60 s settle) stays under 1% of one core. If memory grows
with total tab count, the policy is not running, whatever the per-tab
numbers say.

## 12. Step order (each step: acceptance before the next step starts)

Prepare everything marked [NOW] while the stock build runs. [WAIT] steps
need the build finished and the lead's go-ahead in the thread (fork-infra
§11 gate). Never kill the running build to start a [WAIT] step.

| Step | Tag | Work | Acceptance (all must pass; paste real output in the PR) |
|---|---|---|---|
| S0 Swift data + policy, no engine | **[NOW]** | §7.4 model/setting edits; §7.5 `SleepStore`; §9 target + policy + controller with a fake `SleepEngine`; `openkit sleep-demo DIR` command (below); §11 fixtures; series file kept empty | Below |
| S1 Visibility spike | **[WAIT]** | P-MEM-01 only; `engine-apply`; dev build of `cefsimple` via `engine-build` | Below |
| S2 No-renderer creation | **[WAIT]** | P-MEM-05; translator step (§6) for the settings field; rebuild `cefsimple` | Below |
| S3 History core | **[WAIT]** | P-MEM-04 overlay + hunks + `//components/sessions` dep; translator (§6); rebuild | Below |
| S4 Freeze, then discard | **[WAIT]** | P-MEM-02, then P-MEM-03 (two patches, two builds); §10 enable switch wired in the test `CefApp` used for Track A | Below |
| S5 Flags + switches | **[WAIT]** for build, **[NOW]** for the string table | P-MEM-06 (`HasUnloadHandlers` only); OpenEngine §10 switch code when OpenEngine exists, else the same strings in the Track A test app | Below |
| S6 App integration | **[WAIT]** (needs App + OpenEngine from the engine spike) | §8 adapter + bridge; controller wiring to selection, downloads, quit capture; settings UI mode picker with the pinned sentence | §11 F0–F5 on the real app |

`openkit sleep-demo DIR` (add to the `openkit` executable; precedent is
`commands-demo` in `docs/model.md`): builds a synthetic model in `DIR`,
runs `SleepPolicy`/`SleepController` with a fake clock and a fake engine
that records calls, and prints `OK`/`FAIL` per check, exiting non-zero on
any failure. Checks: hidden tab freezes at 30 s and not before; audible tab
never freezes; discard waits for mode delay (all three modes + off);
unload/form proxies block discard but not freeze; quiet pinned tab
discards; discard order is capture → save → discard; wake restores
`canGoBack`/`canGoForward` from the envelope; pressure warning discards
oldest first and never the visible tab; `SleepStore` round trip (save,
load, equal fields; over-cap save rejected and logged; delete works);
old-snapshot decode (pre-change fixture loads, `roundtrip OK`). This demo
is end-to-end through the real store and policy objects. It is not a unit
test and must not mock SQLite or the model.

Per-step acceptance details:

- **S0.** `swift build -c release` in `Packages/OpenKit` with zero warnings
  and zero errors (Swift 6 strict concurrency). `openkit sleep-demo` on a
  fresh dir prints all OK. `openkit roundtrip` still OK on an imported Arc
  snapshot. `openkit commands-demo` still 66 checks passed. No file under
  `Packages/OpenKit/Sources/OpenSleep/` imports `OpenStore`, `OpenEngine`,
  AppKit, or CEF (check: `grep -rn "^import" Packages/OpenKit/Sources/OpenSleep/`).
- **S1.** `engine-status` passes; `cefsimple` launches to a fixture page
  with no `NOTIMPLEMENTED` log line for `WasHidden` (grep the log);
  hiding/showing via window minimize/restore does not crash. Patch applies
  cleanly from a pristine patched-by-CEF tree (`engine-apply` twice: second
  run no-op).
- **S2.** `cefsimple` still launches normally (default path unchanged).
  With `no_renderer` set in the test harness creation, the browser shows
  no renderer helper in `ps` until first show, then exactly one. If no
  test harness exists yet, prove it with a temporary `cefsimple` flag
  added and removed in the same PR, and paste the `ps` output. Do not ship
  the temporary flag.
- **S3.** Translator emits `_cef_navigation_history_t` (§6 grep passes);
  `nm` on the built framework shows the new C API symbols (add them to
  `Engine/fork/verification/expected-symbols.txt` in the same PR, per
  fork-infra §10.2). Capture/restore round trip proven in Track B as soon
  as S6 wires it; at S3, prove link + launch only and record history
  behavior as pending S6. Never claim F2 at S3.
- **S4.** Freeze: hidden `ticker.html` counter stops advancing while
  frozen and resumes on show (Track A manual observation + log). Discard:
  with §10 enable switch on, helper RSS for that tab's renderer disappears
  after discard and the tab reloads on show with `wasDiscarded` true. With
  the switch off, `Discard` returns false and nothing crashes (guard in
  §5.5 step 3). Debug build stays `NOTREACHED`-free in both configs.
- **S5.** F0 passes. `HasUnloadHandlers` true on a fixture page with a
  `beforeunload` listener (add one to `c.html` behind a query flag, e.g.
  `c.html?unload=1` sets the handler) and false without it.
- **S6.** §11 F1–F5 all pass on the real app. Any flow that cannot run
  (automation channel missing) runs as the manual checklist with the same
  assertions and is reported as manual, with the missing channel named.

Rollback per step: each patch is one series line. Disable a bad patch with
the fork-infra `# DISABLED:` series prefix, re-apply, rebuild. Swift steps
roll back by reverting the OpenKit PR; `SleepStore` files left on disk are
harmless (nothing reads them without the controller).

### 12.1 Verification (Section 8, 2026-11-02)

S1–S5 are built (docs/engine-patches.md, "Tab sleeping") and proven on Track B, the real App, instead of the `cefsimple` Track A: e2e `tabstrip --style chrome` rows `sleep_hosted_visibility` (S1: a background hosted tab is HIDDEN, show/hide through 0302's path), `sleep_hosted_freeze` (S4: refused while visible; the hidden ticker stops for 6 s and runs again after unfreeze), `sleep_hosted_unload_flag` (S5: `HasUnloadHandlers` true with `beforeunload`, false without), `sleep_hosted_capture` (S3: ≥ 3 entries, current index, page state, title, OPNH round trip), `sleep_hosted_discard` (S4: renderer count drops; the woken page has `document.wasDiscarded`, the form value and the scroll position), `sleep_hosted_discard_keeps_tab_id` (the `chrome.tabs` id stays; 0303 untouched) and `sleep_hosted_cleanup`. `engine-status` 8/8 and `expected-symbols.txt` cover the C API. F0 (§10 switches) is in `OEApp.mm`; its App rows run with the App wiring (app-shell Step G, PR G2). S2's no-renderer creation is exercised by the App's restore path in G2.

## 13. Risks and open questions

1. **Chrome-style creation branch (P-MEM-05) may fight the tab strip.**
   `InsertWebContentsAt` with a renderer-less contents is Chrome's own
   restore shape (F-15), but CEF's `Browser` adds tab helpers CEF expects.
   If the spike shows the strip spawning a renderer or dropping CEF host
   association, stop and report with logs. Fallback: Alloy style for tab
   browsers owns its `WebContents` directly (F-14 Alloy branch is trivial),
   at the cost of the Chrome-layer extension surface. Lead decides; do not
   switch styles silently.
2. **In-place discard is gated off on desktop (F-5).** Open opts into a
   path desktop Chrome does not default to. If S4 shows instability, the
   fallback is destroy-and-restore for every sleep (same blob, higher wake
   latency). The format already serves both (D-1).
3. **Pickle stability across rebases.** Handled by §7.3 fallback. Test it
   (F4) before the first Chromium bump, not after.
4. **POST and payment flows.** Bodies do not persist (F-12). A slept
   checkout may repost or restart. Form proxy + load protection reduce,
   not remove, this. Match Chrome; do not keep such tabs live forever.
5. **Extensions see discards.** Discard in place keeps tab identity (D-1).
   Destroy changes it. Extension-heavy tabs are destroy candidates last;
   pressure destroy (§9.4) accepts this trade under critical pressure only.
6. **Open question — capture timing on quit for split panes.** Each pane
   is a tab with its own history (§7.4 phases are per `Tab`, panes
   included). Quit capture iterates panes the same way. No decision
   needed, but S6 must include one split in F4 or record it unverified.
7. **Open question — thumbnail on wake.** Placeholders show title/favicon
   tiles only in v1. Sleep-time bitmaps are out of scope unless design
   review asks. Do not add screenshot capture to any step above.

## Appendix A. File checklist (create / edit, nothing else)

Repo (`/Users/serge/.t3/projects/open`):

```text
CREATE  Packages/OpenKit/Sources/OpenStore/SleepStore.swift
CREATE  Packages/OpenKit/Sources/OpenSleep/SleepEngine.swift
CREATE  Packages/OpenKit/Sources/OpenSleep/SleepPolicy.swift
CREATE  Packages/OpenKit/Sources/OpenSleep/SleepController.swift
CREATE  Engine/fork/verification/fixtures/{a,b,c,audio,ticker}.html
CREATE  Engine/fork/src/cef/include/cef_navigation_history.h            (overlay, S3)
CREATE  Engine/fork/src/cef/libcef/browser/navigation_history_impl.h    (overlay, S3)
CREATE  Engine/fork/src/cef/libcef/browser/navigation_history_impl.cc   (overlay, S3)
EDIT    Packages/OpenKit/Package.swift                                  (OpenSleep target)
EDIT    Packages/OpenKit/Sources/OpenModel/LiveNodes.swift              (§7.4)
EDIT    Packages/OpenKit/Sources/OpenModel/Containers.swift             (§7.4)
EDIT    Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift           (sleepMode only)
EDIT    Packages/OpenKit/Sources/openkit/…                              (sleep-demo command)
EDIT    Engine/fork/patches/cef/series                                  (six lines, §3 order)
EDIT    Engine/fork/verification/expected-symbols.txt                   (S3, fork-infra §10.2)
LATER   Engine/OpenEngine/… OpenSleepBridge.h/.mm + CefApp switches     (§8.2, §10; engine-spike target)
```

Tree (`~/Developer/open-engine/chromium_git/chromium/src`, [WAIT] only,
always through `engine-apply` / `engine-refresh-patches`, never by hand as
a final state): the existing files listed per patch in §3 and §5, plus
translator output under `cef/include/capi/` and `cef/libcef_dll/`.

## Appendix B. Command cheat sheet

```sh
# NOW (repo only)
cd Packages/OpenKit && nice -n 10 swift build -c release
./.build/release/openkit sleep-demo /tmp/open-sleep-demo
./.build/release/openkit roundtrip <dir-with-imported-snapshot>
python3 -m http.server 8765 --bind 127.0.0.1 --directory Engine/fork/verification/fixtures

# WAIT (tree; only with no build running and lead go-ahead)
pgrep -fl 'autoninja|siso|ninja' || echo no-build-running
Engine/fork/scripts/engine-apply
Engine/fork/scripts/engine-build            # dev cefsimple, -j 10 + nice (fork-infra)
cd ~/Developer/open-engine/chromium_git/chromium/src/cef/tools && python3 translator.py --root-dir .. && python3 version_manager.py
ps -axo pid,rss,vsz,comm | grep -i "Helper (Renderer)"
```

## Appendix — Lead decisions (2026-10-25)

- Chrome-style vs Alloy: never switch tabs to Alloy style (it lacks Chrome extension support, a v1 requirement). If discard-in-place via `InsertWebContentsAt` breaks the CEF host association in Chrome style, the fallback is destroy + recreate the CEF browser and restore history with P-MEM-04/P-MEM-05. Decide at S3 with evidence.
- Defaults accepted as planned (freeze 30 s; discard 15/5/2 min by mode; destroy 24 h; never-sleep gates). Mode names in the Settings UI come later from the designer.
- Phasing: S0 now (OpenKit only, no engine). S1–S6 after the stock build and the engine foundation PR land.
- Split-pane quit capture (F4): include split panes; each pane is its own sleeping tab.
