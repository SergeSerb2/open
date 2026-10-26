# Open memory design — tab sleeping, lazy creation, and process policy

Status: research design (2026-10-25). This file is the recommendation for the
fork patch plan. It does not change code yet.

Evidence base. Every claim below cites a file in the local tree
`~/Developer/open-engine/chromium_git/chromium/src` (Chromium
`156.0.8078.48`, CEF `156.0.14+g4fa4ab5+chromium-156.0.8078.48` in
`cef/VERSION.stamp`, CEF commit `4fa4ab5…`) or in this repo. The Release
build in `out/Release_GN_arm64` was read only. No build was run in that
tree. Raw notes are in `.re/memory/`.

Open constraints that shape the design:

- [architecture.md](architecture.md) budgets: cold launch to sidebar
  `≤ 250 ms`, first web paint `≤ 700 ms`, live tab switch `≤ 16 ms`,
  idle CPU `≈ 0%`. Tactics already locked: "Create web content only for
  visible or recently used tabs. Put tabs to sleep after a period
  without use (configurable)."
- [model.md](model.md) and `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift`:
  a persisted `Tab` holds `id`, `url`, `title`, `customTitle`,
  `pinnedURL`, `customIcon`, `createdAt`, `lastActiveAt`, `isMuted`,
  `openerID`, `isUnread`. Runtime state is separate in `TabLiveState`
  (`isLoading`, `progress`, `isAudible`, `isCrashed`, `canGoBack`,
  `canGoForward`, `faviconPNG`) and is never persisted. The model
  therefore already has what a placeholder needs. It has no field for
  navigation history, scroll, or form state today.
- [arccore-engine.md](re/arccore-engine.md) §2.3: Arc's `ArcWebContents`
  exposes `discard`, `clone`, `willRunUnloadEvents`, `emitFreezingVote:`
  (`ArcFreezingVoteToken`), `state`, and `visibility`. Arc proves a
  first-class discard and freeze vote belong on the web-content API.
  §4.4 and §8.4: CEF has no equivalent, and tab identity must be Open's
  own stable ID, not a CEF browser integer.
- [architecture-map.md](re/architecture-map.md) §4.3: Arc keeps one
  sidebar tab ↔ one `WebContentFrame` ↔ one Chromium web contents, and
  crosses the bridge with `restorableSessionID` + `ArcSessionTab`
  (`currentNavigationIndex`, `navigations`, `isPinned`, `groupId`).
  Open needs the same stable mapping, with sleeping as a third state
  beside live and never-loaded.

## Recommendation in one paragraph

Use a three-state tab: **Placeholder → Live → Sleeping**, with two
sleep depths. Depth 1 is **freeze** (keep the renderer, stop its work).
Depth 2 is **discard** (release the renderer and the frame tree, keep
only serialized history). Restore a discarded tab by creating a fresh
CEF browser and calling `NavigationController::Restore` with entries
built from `sessions::SerializedNavigationEntry` values captured before
the discard. Capture those values through a new CEF API, because stock
CEF can read history but cannot write it back. Do not port Chrome's
`performance_manager` graph or `TabLifecycleUnit` into the fork. Open's
Swift shell already owns tab order, `lastActiveAt`, audibility, and
pin state, so the sleep policy lives in Swift. The fork only supplies
four primitives: freeze, discard, serialize history, and restore
history. Everything else is policy in the shell.

---

## 1. Tab sleeping

### 1.1 What "sleep" must preserve

A slept tab must come back with:

1. Full back/forward list, in order, with the correct current index.
2. Scroll position and form entries for each entry, where the page
   allows it.
3. Title and favicon, without a network load.
4. `wasDiscarded` semantics, so the page can tell it was discarded
   (the Web Lifecycle API bit).

Chromium already stores items 1 and 2 in one place. See §1.3.

### 1.2 The three options

| Option | Mechanism in the tree | Renderer after sleep | History and page state | Restore cost |
|---|---|---|---|---|
| (a) Chrome discard | `TabLifecycleUnit::Discard` in `chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`; policy in `chrome/browser/performance_manager/mechanisms/page_discarder.cc` (`PageDiscarder::DiscardPageNode`) | Released (old path) or frame discarded in place (new path) | Copied with `NavigationController::CopyStateFrom` (old path) or kept in place (new path); `encoded_page_state` travels with each entry | One navigation of the current entry. Other entries stay as data until visited. |
| (b) Destroy CEF browser, restore with `NavigationController::Restore` | `content::NavigationController::Restore(int, RestoreType, std::vector<std::unique_ptr<NavigationEntry>>*)` in `content/public/browser/navigation_controller.h:473`; builder in `components/sessions/content/content_serialized_navigation_builder.h` | Released. The whole `WebContents` and its process go away. | Serialized first with `ContentSerializedNavigationBuilder::FromNavigationEntry`, rebuilt with `ToNavigationEntry` / `ToNavigationEntries`. Includes `encoded_page_state` unless `EXCLUDE_PAGE_STATE` is set. | Process start plus one navigation. The cheapest restore to run, the most state to store. |
| (c) Keep `WebContents`, freeze or discard the renderer only | Freeze: `WebContents::SetPageFrozen(bool)` in `content/public/browser/web_contents.h:1180`. Discard: `WebContents::Discard` in the same file at line 876, gated by `features::kWebContentsDiscard` | Freeze keeps the process and the DOM. Discard releases the frame tree but keeps the `WebContents` shell and its `NavigationController`. | Nothing to serialize. The controller already holds every entry and its page state. | Freeze: near zero (unfreeze on show). Discard: one navigation, no new `WebContents` and no view re-attach. |

Read the table as a ladder. Freeze is cheapest to restore and saves
the least. Full destroy (b) saves the most and costs the most to
restore. Discard-in-place (the new Chrome path inside (a), and option
(c) discard) sits in the middle and is the best default for Open.

### 1.3 How history, scroll, and form state survive

The key type is `sessions::SerializedNavigationEntry` in
`components/sessions/core/serialized_navigation_entry.h`. Its own
comment calls it a "freeze-dried" version of `NavigationEntry`. It
holds `index_`, `virtual_url_`, `title_`, `encoded_page_state_`,
`transition_type_`, `has_post_data_`, `post_id_`,
`original_request_url_`, `referrer_url_`, `favicon_url_`,
`http_status_code_`, and `timestamp_`. It pickles with
`WriteToPickle` / `ReadFromPickle`.

`encoded_page_state_` is the scroll and form carrier.
`content::NavigationEntry::GetPageState` / `SetPageState` in
`content/public/browser/navigation_entry.h:136` document it directly:
"Page state is an opaque blob created by Blink that represents the
state of the page. This includes form entries and scroll position for
each frame." Blink fills it on commit and on unload. When an entry is
restored, Blink decodes it and reapplies scroll and form values. No
JavaScript snapshot can match this, because it covers subframes and
it runs before the page's own restore handlers.

Two limits apply to every option, so state them once:

- A `POST` entry keeps `has_post_data_` and `post_id_`, but the raw
  body is not persisted for session restore
  (`NavigationEntry::SetPostData` in the same header: "is not
  persisted in session restore"). A restored `POST` page may show the
  browser's repost prompt or reload as a `GET`. This matches Chrome.
- `encoded_page_state` can be large on deep iframe trees.
  `ContentSerializedNavigationBuilder::FromNavigationEntry` offers
  `SerializationOptions::EXCLUDE_PAGE_STATE` ("Serializing page state
  data can involve heavy processing on pages with deep iframe trees").
  Open keeps page state by default and drops it only under the size
  cap in §1.7.

`ContentSerializedNavigationBuilder` in
`components/sessions/content/content_serialized_navigation_builder.h`
is the only converter Open needs:

- `FromNavigationEntry(index, entry, options)` → one
  `SerializedNavigationEntry`.
- `ToNavigationEntry(navigation, browser_context, restore_context)` →
  one `NavigationEntry`. The `restore_context` dedupes per-frame state
  that repeats across entries, so capture the whole list with one
  context.
- `ToNavigationEntries(span, browser_context)` → the whole list.

`NavigationController::Restore(selected_navigation, type, entries)`
then installs the list on a fresh controller. Pass
`RestoreType::kRestored` (session restore) so entries are marked
restored and the current entry loads on show, not at restore time.
Chrome's session restore uses the same call. Nothing in this path
needs the `components/sessions` command store
(`command_storage_manager`, `base_session_service_commands`). Open
persists its own blob (see §1.7) and calls `Restore` directly.

### 1.4 Option (a) in detail: what Chrome does today

Chrome has two discard implementations, and the fork contains both.

**Old path — replace the `WebContents`.**
`TabLifecycleUnitSource::TabLifecycleUnit::FinishDiscard` in
`tab_lifecycle_unit.cc:270` creates a replacement `WebContents` with
`CreateParams::kNoRendererProcess` ("Creation of WebContents should
not spawn a new OS process"), copies history with
`null_contents->GetController().CopyStateFrom(&old_contents->GetController(), false)`,
sets `SetWasDiscarded(true)` on the replacement, then swaps it in with
`TabStripModel::DiscardWebContents` and destroys the old contents.
The tab keeps its strip slot, title, and favicon. The renderer dies
with the old contents.

**New path — discard in place.** When
`features::kWebContentsDiscard` is on, `Discard` at
`tab_lifecycle_unit.cc:408` calls
`FinishDiscardAndPreserveWebContents` instead, which calls
`WebContents::Discard` on the same object.
`content_features.cc:381` defines
`kWebContentsDiscard` as `FEATURE_DISABLED_BY_DEFAULT` on desktop and
enabled on Android, so desktop Chrome still takes the old path by
default. `WebContentsImpl::Discard` in
`content/browser/web_contents/web_contents_impl.cc:2801` checks the
feature, fires `AboutToBeDiscarded(this)`, calls
`primary_frame_tree_.Discard(cb)`, then `NotifyWasDiscarded()`.
`FrameTree::Discard` in
`content/browser/renderer_host/frame_tree.cc:1197` sets
`was_discarded` on the root, calls
`RenderFrameHostImpl::DiscardFrame`, calls
`NavigationControllerImpl::SetNeedsReload`, and flushes the
back-forward cache. `RenderFrameHostImpl::DiscardFrame` in
`render_frame_host_impl.cc:13351` marks the document discarded,
disables BFCache for that frame with reason `kDiscarded`, and asks the
renderer local main frame to discard. The renderer releases the
document, the frame tree collapses to an empty root, and the process
is free to exit once no other frame uses it. The `WebContents`, its
`NavigationController`, its view, and every observer stay alive.

On reactivation, `TabLifecycleUnit` reloads because the controller
has `needs_reload` set. The page sees `document.wasDiscarded`.

**Policy around the mechanism.** Open should copy the eligibility
idea, not the code. `performance_manager::mechanism::PageDiscarder`
only forwards to `TabLifecycleUnit::DiscardTab`. The decisions live in
`chrome/browser/performance_manager/policies/discard_eligibility_policy.h`
(`DiscardEligibilityPolicy`, `CanDiscardResult` of `kEligible`,
`kProtected`, `kDisallowed`) and the reason list in
`cannot_discard_reason.h`: `kVisible`, `kAudible`,
`kRecentlyAudible`, `kRecentlyVisible`, `kPictureInPicture`, `kPdf`,
`kPinnedTab`, `kDevToolsOpen`, `kFormInteractions`, `kUserEdits`,
`kCapturingVideo`, `kCapturingAudio`, `kExtensionProtected`,
`kOptedOut`, and more. Freezing has a parallel list,
`CannotFreezeReason` in
`components/performance_manager/public/freezing/cannot_freeze_reason.h`
(`kVisible`, `kAudible`, `kHoldingWebLock`,
`kHoldingIndexedDBLock`, `kConnectedToBluetoothDevice`, `kWebRTC`,
`kLoading`, …). `MemorySaverModePolicy` in
`chrome/browser/performance_manager/policies/memory_saver_mode_policy.h`
is only a timer: one `base::OneShotTimer` per background tab, started
on `OnIsVisibleChanged`, firing `DiscardPageTimerCallback`. The
default delay is `kDefaultMemorySaverModeTimeBeforeDiscardInMinutes =
120` in
`components/performance_manager/public/user_tuning/prefs.h:41`, with
aggressiveness `kConservative` / `kMedium` / `kAggressive` in the same
file. Chrome's two hours is a desktop compromise. Open can be faster
because its tabs start as placeholders (see §2).

What to take from (a): the in-place discard semantics, the
`wasDiscarded` bit, the eligibility reason list as a checklist, and
the timer-per-tab shape. What to leave: the `performance_manager`
graph (`PageNode`, `ProcessNode`, decorators, voters), `TabStripModel`
coupling, and the old replace-the-contents path. Open has no tab
strip model to swap contents in, and its Swift store already holds
every input the eligibility check needs except three engine signals
(form edits, WebLock use, capture state). Those three come back as
flags on the new CEF API (see §6).

### 1.5 Option (c) in detail: freeze first, discard later

`WebContents::SetPageFrozen(true)` in
`content/public/browser/web_contents.h:1177` — "Freezes or unfreezes
the current page. A frozen page runs as few tasks as possible. This
cannot be called when the page is visible. If the page is made
visible after this is called, it is automatically unfrozen."
`performance_manager::Freezer::MaybeFreezePageNode` in
`components/performance_manager/freezing/freezer.cc` is the whole
mechanism: check `GetVisibility() != VISIBLE`, then
`contents->SetPageFrozen(true)`. Freeze stops timers, rendering, and
most task queues in the renderer. It does not release memory. The
DOM, JS heap, decoded images, and the process all stay.

So freeze and discard solve different problems:

- Freeze solves CPU. A frozen background tab costs near-zero cycles.
  Restore is instant because nothing was torn down.
- Discard solves memory. Only discard returns the renderer's private
  footprint to the OS.

Open uses both, in order. A tab freezes soon after it hides. It
discards later if it stays hidden. This two-step shape also matches
Chrome's own direction: `FreezingPolicy` in
`components/performance_manager/freezing/freezing_policy.h` freezes
sets of connected pages, and
`features::kDiscardFrozenBrowsingInstancesWithGrowingPMF` in
`components/performance_manager/public/features.h:145` discards a
frozen instance whose private footprint keeps growing. Open does not
need the voting system (`kInfiniteTabsFreezing` and its
`NumProtectedTabs` / `UnfreezeInterval` params in the same header are
useful prior art for values, not code to port).

Visibility is the gate for both. `WebContents::WasShown` /
`WasHidden` / `GetVisibility` in
`content/public/browser/web_contents.h:1037` drive it, and
`WebContentsImpl::WasShown` at `web_contents_impl.cc:3179` forwards to
`UpdateVisibilityAndNotifyPageAndView`. A hidden page also gets
Blink timer throttling for free (see §4.1), so freeze is the second
step, not the first.

### 1.6 What CEF exposes today, and what it does not

Stock CEF at this commit gives Open exactly half of the sleep cycle.

What exists:

- `CefBrowserHost::CloseBrowser(bool)` and `TryCloseBrowser` in
  `cef/include/cef_browser.h:362`. This destroys the browser. It is
  the teardown half of option (b).
- `CefBrowserHost::GetNavigationEntries(visitor, current_only)` in
  `cef/include/cef_browser.h:669`, implemented in
  `CefBrowserHostBase::GetNavigationEntries` at
  `cef/libcef/browser/browser_host_base.cc:771`. It walks
  `web_contents->GetController()` and visits each
  `content::NavigationEntry`. This is the read half of history.
- `CefNavigationEntry` in `cef/include/cef_navigation_entry.h`
  exposes `GetURL`, `GetDisplayURL`, `GetOriginalURL`, `GetTitle`,
  `GetTransitionType`, `HasPostData`, `GetCompletionTime`,
  `GetHttpStatusCode`, and `GetSSLStatus`. Note what is missing:
  no page state, no referrer, no favicon URL, no timestamp setter
  source, and no way to build an entry.
- `CefBrowser::CanGoBack` / `GoBack` / `CanGoForward` / `GoForward` /
  `Reload` in `cef/include/cef_browser.h:82`. Enough for the UI, not
  for sleep.
- `CefBrowserHost::WasHidden(bool)` in `cef/include/cef_browser.h:707`,
  but read the implementations before relying on it. The doc says
  "This method is only used when window rendering is disabled."
  `AlloyBrowserHostImpl::WasHidden` at
  `cef/libcef/browser/alloy/alloy_browser_host_impl.cc:360` DCHECKs
  for non-windowless browsers.
  `ChromeBrowserHostImpl::WasHidden` at
  `cef/libcef/browser/chrome/chrome_browser_host_impl.cc:240` is
  `NOTIMPLEMENTED()`. `CefBrowserPlatformDelegate::WasHidden` at
  `cef/libcef/browser/browser_platform_delegate.cc:388` is a
  `DCHECK(false)` stub; only the OSR delegate forwards to
  `web_contents->WasHidden()` / `WasShown()`. Open uses windowed
  (Views / native) browsers, so stock CEF gives Open no working
  visibility call. Arc hit the same wall and put `visibility` on
  `ArcWebContents` itself.

What does not exist anywhere in `cef/include/*.h` (searched for
`Discard`, `Freeze`, `SetPageFrozen`, `Restore`, `Serialized`):

- No `Discard`. No freeze call. No `SetPageFrozen`.
- No history write-back. No `Restore`. No serialized entry type.
- No `initially_hidden` creation flag and no
  `kNoRendererProcess` equivalent. `CefWindowInfo` can make a child
  or popup window, but it cannot ask for a `WebContents` with no
  renderer. Every `CreateBrowser` pays for a process up front, which
  is why session restore in stock CEF loads pages eagerly.
- In Chrome style, the `WebContents` is owned by the Chrome
  `Browser` and its tab strip (`ChromeBrowserHostImpl::browser()` in
  `cef/libcef/browser/chrome/chrome_browser_host_impl.h:112`, and the
  ownership note in `browser_host_base.h:192`: "With Chrome style the
  WebContents is owned by the Browser's TabStripModel"). Discard in
  Chrome assumes that owner. Open must not let a sleep call delete a
  `WebContents` that the Chrome browser thinks it owns.

Conclusion: option (b) is buildable today only in its lossy form
(close the browser, reopen the current URL, lose back/forward, scroll,
and form state). That fails the task requirement. Options (a) new-path
and (c) need new CEF surface. Section 6 lists the exact additions.
They are small because the Chromium primitives already exist; the
work is plumbing, plus one ownership decision for Chrome style.

### 1.7 The Open sleep cycle (recommended)

Swift owns the policy. The engine owns four primitives. The store
owns one new blob per tab.

**New persisted state.** Add an optional `sleepState` to the tab DTO
in the snapshot (schema stays versioned; old files decode with the
field absent, as `model.md` already handles for enum additions):

- `entries`: an ordered list of serialized navigations. Store the
  `base::Pickle` bytes from `SerializedNavigationEntry::WriteToPickle`
  as one base64 string per entry, or one blob for the whole list with
  a count prefix. Bytes are opaque to Swift. Cap the whole list at
  2 MiB per tab (see the risk in §7). Over the cap, re-serialize with
  `EXCLUDE_PAGE_STATE`, which keeps URLs, titles, and order and drops
  scroll and form data. Log the drop in the automation channel.
- `currentIndex`: the selected entry index.
- `wasDiscarded`: always true for a depth-2 sleep. It sets
  `document.wasDiscarded` on restore.
- `sleptAt`: wall time, for the discard ring and for age policy.

Capture cost matters. `FromNavigationEntry` with page state walks
each frame. Capture on the transition into sleep, on the browser UI
thread, once. Do not capture on every navigation "just in case":
that taxes the hot path to save work in the cold path. Capture on
navigation commit only the cheap fields (URL, title, index) into the
existing Swift `Tab` update, and take the full serialized snapshot
at sleep time. If the renderer is already gone (crash), the cheap
fields still give a single-entry restore.

**Sleep sequence (depth 2, discard):**

1. Swift checks eligibility (§5.2). Ineligible tabs stop at depth 1.
2. Engine: `CaptureNavigationHistory` returns the serialized list,
   the current index, title, and favicon URL. Swift stores it in
   `sleepState` and flushes the snapshot (debounced write already
   exists in `SnapshotStore`).
3. Engine: `Discard` (new CEF call) runs
   `WebContents::Discard` in place. The view stays attached but
   empty. The renderer releases. Set the tab's placeholder visual
   (§2) from the stored title and favicon.
4. Swift marks the tab sleeping. `TabLiveState.isLoading` clears.
   `canGoBack` / `canGoForward` are recomputed from `currentIndex`
   and the entry count, so the UI stays correct with no engine.

**Wake sequence:**

1. If the tab still has a live `WebContents` in discarded state,
   show it. The controller reloads the current entry automatically
   (`SetNeedsReload` from `FrameTree::Discard`). No `Restore` call
   is needed. This is the common case within a session.
2. If the browser was destroyed (app relaunch, or the aggressive
   destroy variant below), create the browser with the new
   no-renderer flag, call `RestoreNavigationHistory` with the stored
   blob before the first show, then show it. The current entry loads
   on show. Back/forward entries load only when visited.
3. Clear `sleepState.wasDiscarded` after the first successful commit
   and report the restore latency to the automation channel.

**Destroy variant.** Discard-in-place keeps a `WebContents` object,
its view, and its observers alive. That costs a few hundred KB of
browser-process memory per tab, not the tens of MB a renderer costs.
At 100 tabs it is still worth removing. So add a second, later step:
after a tab has slept at depth 2 for a long time (default 24 h, or
under memory pressure), destroy the CEF browser entirely and keep
only `sleepState`. Wake then takes path 2. This gives option (b)'s
savings with option (c)'s fast common case, and it bounds the cost
of the `Restore` plumbing to the rare path. Build discard-in-place
first. Add destroy second, behind the same `sleepState` format, so
the format is proven before the slower path depends on it.

**What is lost, honestly:**

- JS heap, canvas, WebGL contexts, media playback position inside
  the page, in-flight fetches, and WebSocket connections. Discard
  is a reload. Chrome has the same loss.
- `POST` bodies (see §1.3). The entry survives; the body may not.
- Pages that opt out. A page with an active `beforeunload` prompt
  must not be discarded silently. `WebContents::NeedToFireBeforeUnloadOrUnloadEvents`
  and `DispatchBeforeUnload(auto_cancel)` in
  `content/public/browser/web_contents.h:1068` let the engine check
  and run the handler without a dialog during the eligibility test.
  If the page refuses, keep it frozen and mark it protected.

### 1.8 Restore latency

No latency was measured in this research task, because the new CEF
calls do not exist yet and the running build must not be disturbed.
These are budgets to verify, derived from the path lengths:

- **Unfreeze:** one visibility change. The renderer is alive, so the
  first frame is a normal repaint. Budget: `≤ 16 ms` to content
  visible, same as a live tab switch in
  [architecture.md](architecture.md). Risk: a frozen page may need a
  timer catch-up burst on thaw. Measure it.
- **Wake from discard-in-place:** renderer start (or spare claim,
  see §3.4) plus one navigation of the current entry. Network and
  cache decide the tail. Budget: first paint `≤ 700 ms` on a cached
  page, matching the cold-launch first-paint budget. The back list
  adds no cost until visited.
- **Wake from destroyed:** the above plus `WebContents` and view
  creation. This is the same work as opening a new tab to a known
  URL, plus a `Restore` that is pure data (entry count is small;
  page-state decode happens in Blink per entry on visit).

Measure all three through the automation channel (§5.4) with the
same page set, cold cache and warm cache, and record p50 and p95.
Do not publish a single "restore is fast" number without the cache
state next to it.

---

## 2. Lazy creation: the placeholder tab

### 2.1 The rule

A tab has a `WebContents` only if it is visible now, was visible
recently, or is preloading on purpose. Every other tab is a
placeholder: a `Tab` in the Swift model with no CEF browser.

This is the default state at launch. [architecture.md](architecture.md)
already requires it: "build the window and sidebar from the snapshot
before the engine finishes starting" and "Create web content only
for visible or recently used tabs." Arc does the same shape with
`storeBrowserlessWebContent` and `WindowContentPlaceholderViewController`
([architecture-map.md](re/architecture-map.md) §4.1, §4.3).

### 2.2 What a placeholder shows

Everything comes from Open's own stores. No engine call is made.

| UI need | Source |
|---|---|
| Title | `Tab.displayTitle` (`customTitle ?? title` in `LiveNodes.swift:41`), falling back to the host of `pinnedURL ?? url` |
| Favicon | `Tab.customIcon` if set; else the favicon cache keyed by host (Arc keeps a `SidebarItemsFaviconCache`; Open's store needs the same small cache); else a letter tile drawn by the sidebar |
| URL (command bar, hover) | `Tab.pinnedURL ?? Tab.url`. For pinned and favorite tabs the reset target is `pinnedURL` (see `resetPinnedTab` in [model.md](model.md)) |
| Back/forward affordance | From `sleepState`: enabled when `currentIndex > 0` or `< entries.count - 1`. With no `sleepState`, both disabled. The engine corrects them on first commit. |
| Audible, loading, crashed badges | None. `TabLiveState` defaults are all false, which is correct for a tab that has never loaded. |
| Thumbnail (hover card, Space switch) | No live bitmap. Show the favicon tile on the Space gradient. Do not keep per-tab screenshots by default: [architecture-map.md](re/architecture-map.md) §6 row 8 warns that snapshot caches are a weight source in Arc. Capture a bitmap only at the moment a live tab sleeps, keep at most one per tab at sidebar width, and delete it on wake. Even that is optional for v1. |

Pinned tabs and favorites are placeholders most often, because users
keep many and touch few. That is safe: selecting one loads
`pinnedURL` (its canonical URL), not whatever transient URL a prior
session left in `url`. Today tabs load `url`.

### 2.3 First selection of a placeholder

1. Swift creates the engine web content for the tab's stable ID.
   It passes the target URL, the profile's request context, and, if
   `sleepState` exists, the serialized history.
2. Engine creates the CEF browser. With the §6 creation flag it
   starts with no renderer. If history exists, it calls
   `NavigationController::Restore` before returning. The current
   entry is now the controller's visible entry, so the address bar,
   title, and back/forward state are correct before any bytes load.
3. Swift attaches the native view and shows it. Show triggers the
   load of the current entry only.
4. On first commit, the engine reports URL, title, and favicon
   through the normal delegate path, and Swift updates the `Tab`
   exactly as it does for any navigation.

A placeholder with no `sleepState` is a fresh load of one URL. A
placeholder with `sleepState` is a session restore of one tab. The
user cannot tell the two apart except by pressing Back.

### 2.4 Session restore at launch

Do not restore browsers at launch. Restore the model, draw the
sidebar, then create content only for each window's selected tab
(one per window, plus split panes). Every other restored tab stays
a placeholder with its `sleepState` intact from the prior session's
sleep capture or from a launch-time capture (see the gap below).

One gap must be closed: `sleepState` is captured at sleep time. A
tab that is live when the app quits has no `sleepState`. On quit,
capture history for every live tab before teardown, the same call
as sleep step 2, without discarding. Quit stays fast because the
capture is in-memory serialization on the UI thread; budget it and
capture only tabs whose cheap fields changed since the last capture.
If quit is forced (crash, kill), the last sleep-time or periodic
capture stands, and the worst case is a single-entry restore from
`Tab.url`. Never block quit on a renderer round trip: read the
controller from the browser process, which is where
`GetNavigationEntries` already reads it
(`browser_host_base.cc:791`).

### 2.5 Interaction with existing model commands

- `archiveExpiredTabs` and auto-archive act on `Tab.lastActiveAt`
  and never need a browser. Placeholders archive exactly like live
  tabs. Archiving a sleeping tab keeps its `sleepState` in the
  archive record payload, so `restoreArchivedTab` can rebuild a
  placeholder that still has its history.
- `closeTab` on a placeholder destroys nothing in the engine. On a
  sleeping tab it destroys the discarded `WebContents` (cheap) or
  nothing (destroy variant). The §7 checklist item in
  [arccore-engine.md](re/arccore-engine.md) about stable tab IDs
  applies: close by Open ID, map to the engine object if one exists.
- Split View: a split has 2–4 panes (`Split.panes` in
  `LiveNodes.swift:82`). Each pane is a tab with its own placeholder
  state. Showing a split creates content for its panes, but a split
  that is not the selected node in its Space creates nothing. On
  sleep, panes sleep independently; a split with one live pane and
  three placeholders is a normal state.
- Peek and hover previews must not create content. Use the
  placeholder tile. Arc uses frame thumbnails for this
  ([architecture-map.md](re/architecture-map.md) §4.3); Open starts
  with tiles and adds sleep-time bitmaps only if the design review
  asks for them.

---

## 3. Process model on macOS

### 3.1 What Chromium does by default

Chromium uses site isolation: one renderer process per site
instance, with process reuse when a limit is hit.
`RenderProcessHost::GetMaxRendererProcessCount` in
`content/browser/renderer_host/render_process_host_impl.cc:1505`
gives the desktop formula. It takes total physical memory, halves
it, and divides by `kEstimatedWebContentsMemoryUsage = 85` MB
(64-bit), clamped by a minimum of 3 and a platform maximum. On a
16 GB Mac that is about 96 renderer hosts before reuse is forced.
`--renderer-process-limit` (`kRendererProcessLimit` in
`content/public/common/content_switches.h:180`) overrides the count.
`--process-per-site` (`kProcessPerSite` in the same file) collapses
to one process per site across all tabs. Site instances decide reuse
through `SiteInstanceImpl::ReuseExistingProcessIfPossible` and
`ProcessReusePolicy` in
`content/browser/site_instance_impl.h:210`.

Each renderer is a separate macOS process (a Helper app). The cost
per process on Apple Silicon is the 85 MB estimate above as a
planning number, plus per-process overhead that sharing does not
remove: a V8 heap, a compositor, decoded image caches, and the
seatbelt sandbox. Two tabs on the same site share a process only
when they are in the same browsing instance or when the process
limit forces reuse; two tabs opened independently to the same site
usually get sibling processes under site isolation. That is a
security property, not waste. Do not trade it away casually (see
the `--process-per-site` note below).

CEF inherits all of this. CEF adds no process policy of its own; it
creates `WebContents` and lets content decide. Open therefore sets
process policy with command-line switches through
`CefApp::OnBeforeCommandLineProcessing` in
`cef/include/cef_app.h:208` (call
`CefCommandLine::AppendSwitchWithValue`), which is the supported
place to add switches per process type.

### 3.2 Cost shape with sleeping

Sleeping changes the process math more than any switch does. A
discarded tab holds no renderer. A placeholder never had one. So
the live process count is bounded by the number of live tabs, not
the number of tabs. With the §5 policy (keep at most 5 live
background tabs, freeze the rest, discard on a timer), a 100-tab
profile runs about 6 renderers plus the GPU, network, and browser
processes. The process limit then almost never binds, which is the
point: policy first, limit as a safety net.

### 3.3 Recommended settings

Set these in `OnBeforeCommandLineProcessing` for the browser
process. Renderer and GPU processes inherit the feature switches;
verify inheritance in the smoke test, because CEF forwards only
some switches automatically.

| Setting | Value | Why |
|---|---|---|
| `--renderer-process-limit` | Leave unset by default. Set `32` only as a guard on low-memory machines (≤ 8 GB). | The built-in formula already scales with RAM. A hard low limit forces unrelated sites to share a process, which hurts isolation and makes one crash take many tabs. With sleeping, the live count stays low without it. |
| Site isolation | Keep default (on). Do not pass `--process-per-site` or any site-isolation-disabling switch. | `--process-per-site` saves processes but puts different tabs of one site in one renderer, so one heavy tab blocks its siblings and one crash kills them all. The memory it saves is smaller than what discard saves. |
| Spare renderer | Keep one warm spare. See §3.4. | It hides process-start latency on wake and on new tab. |
| `--disable-features` / `--enable-features` | See the table in §4.5. | Feature switches are the cheapest memory and CPU win in the fork. |

### 3.4 Spare renderer

`content::SpareRenderProcessHostManager` (interface in
`content/public/browser/spare_render_process_host_manager.h`,
implementation `SpareRenderProcessHostManagerImpl` in
`content/browser/renderer_host/spare_render_process_host_manager_impl.h`)
keeps a pre-started renderer with an initialized `blink::WebView`.
`WarmupSpare(browser_context)` creates it, `MaybeTakeSpare` claims it
for a navigation, and `PrepareForFutureRequests` schedules the next
one. It already handles memory pressure:
`kKillSpareRenderOnMemoryPressure`,
`kSpareRPHKeepOneAliveOnMemoryPressure`, and
`kSpareRPHUseCriticalMemoryPressure` are declared in the same header,
and `OnReleaseMemory` cleans spares up. The spare is bound to one
`BrowserContext` and its default storage partition; a claim for a
different profile discards it.

For Open: keep exactly one spare per active profile, warmed after
the selected tab's first paint, not during launch (launch budget).
Re-warm after each claim with the existing deferred path so a wake
never waits on `fork` plus V8 snapshot load. Under memory pressure,
let the built-in consumer kill it. Do not keep a spare per Space:
Spaces share a profile in Open's model, so one spare serves all of
them. The cost is one idle renderer (the 85 MB planning number,
less in practice for a blank spare). The benefit is that a wake
from discard feels like a tab switch instead of a launch. Measure
the delta (§5.4) and make the spare the first thing the aggressive
policy drops if the budget fails.

Note the interaction with §1.7: a `WebContents` created with
`kNoRendererProcess` must not claim the spare at creation. It claims
a process at first navigation. That is already how
`CreateParams::desired_renderer_state` is documented to behave
(`web_contents.h:306`).

---

## 4. Other memory and CPU wins in the fork

Ordered by value per line of patch. Items 4.1 to 4.3 are behaviour
Chromium already has; Open's job is to call it and not defeat it.
Item 4.5 is switches only. Nothing here needs the
`performance_manager` graph ported.

### 4.1 Background timer throttling (already on, do not defeat)

Blink throttles timers in hidden pages, and
`features::kIntensiveWakeUpThrottling` in
`third_party/blink/public/common/features.h:630` aligns the rest.
It is `FEATURE_ENABLED_BY_DEFAULT` in
`third_party/blink/common/features.cc:881`, with a grace period of
`kIntensiveWakeUpThrottling_GracePeriodSeconds_Default = 5 * 60`
and `…Loaded_Default = 60` in
`third_party/blink/renderer/platform/scheduler/common/features.h:40`.
After the grace period, JS timer wake-ups in a hidden page are
aligned to at most one per minute.

Open's duties are negative: never pass
`--disable-background-timer-throttling`, never keep a background
tab's visibility at `VISIBLE` for the sake of thumbnails or media
controls, and drive `WasHidden` honestly (which needs the §6
visibility fix, since Chrome-style CEF ignores `WasHidden` today).
One honest `WasHidden` buys timer throttling, rendering stop, and
freeze eligibility at once.

### 4.2 Freezing background tabs

Freeze is §1.5. Policy: freeze a tab 30 s after it hides, if it has
no `CannotFreezeReason`. The list in
`cannot_freeze_reason.h` is the contract. Open can observe most of
it from existing engine signals (audible from `TabLiveState.isAudible`,
loading, PiP, capture, WebRTC via media state). Three reasons need
new engine flags (§6): holding a WebLock or IndexedDB lock, having
unsaved form edits, and being opted out by the page. Until those
flags exist, freeze only tabs that are not audible, not loading,
and not capturing, and accept that a page with a background lock
may notice the freeze. Frozen pages thaw automatically on show
(`SetPageFrozen` contract), so the failure mode is a delayed
notification, not data loss.

Add periodic thaw only if a real site needs it. Chrome's
`kInfiniteTabsFreezing_UnfreezeInterval` exists because frozen
pages miss notifications and socket keepalives. Open's default is
no periodic thaw in v1; discard follows freeze anyway, and a
discarded tab has nothing to keep alive.

### 4.3 Back-forward cache size

BFCache keeps a live copy of a page you navigated away from, so
Back is instant. `features::kBackForwardCache` in
`content/public/common/content_features.h:90` is enabled by
default, with `kBackForwardCacheMemoryControls` beside it.
`BackForwardCacheImpl` in
`content/browser/back_forward_cache/back_forward_cache_impl.cc`
holds `entries_`, pushes with `entries_.push_front`, and enforces a
size limit in `EnforceCacheSizeLimit`, reacting to
`RenderProcessPriorityChanged`. Each entry pins a renderer process
and its full page. BFCache is therefore the opposite of sleeping:
it spends memory to buy speed on Back.

For Open: keep BFCache on for the visible tab's history (Back must
feel instant, per the tab-switch budget's spirit), but cap it
small. Set the existing field-trial params for
`kBackForwardCache` through feature parameter overrides at
startup: limit cached entries to 3 and keep the default entry
timeout. Never cache pages from background tabs, and note that
`FrameTree::Discard` already flushes BFCache on discard
(`frame_tree.cc:1197`), so sleeping and BFCache do not fight. If
the 50-tab budget in §5.5 fails, BFCache size is the second knob
after the spare renderer.

### 4.4 GPU raster and compositing

`features::kDefaultEnableGpuRasterization` in
`gpu/config/gpu_finch_features.cc:212` is enabled by default on
Apple platforms. Keep it. GPU raster moves raster work off the
renderer CPU, which matters more as tab count grows. Do not pass
`--disable-gpu`, `--disable-gpu-compositing`, or
`--disable-gpu-rasterization` (switches declared in
`content/public/common/content_switches.h:53`). Keep the single
GPU process shared by all tabs; Chromium already does this. The
one GPU memory lever worth exposing later is per-tab capture:
a tab that is being captured (mirroring, PiP recording) opts out
of hidden optimizations through `IncrementCapturerCount` in
`web_contents.h:939`. Open's shell must balance every increment
with the returned `ScopedClosureRunner`, or a slept tab will keep
producing frames. That is a code-review rule, not a patch.

### 4.5 Features to turn off by default

Set these with `--disable-features` in
`OnBeforeCommandLineProcessing`. Each row names the
`base::Feature`, where it is declared, the default in this tree,
what Open loses, and the switch value. All of these are Chrome
browser-layer or component features. CEF's Chrome style links the
Chrome layer, so the switches take effect; verify each one in the
smoke test by reading back feature state, because a feature the
embedder never instantiates costs nothing to "disable" and proves
nothing.

| Feature (`base::Feature` name) | Declared in | Default here | Turn off? | Trade-off |
|---|---|---|---|---|
| `OptimizationHints`, `OptimizationGuidePredictionModelKillswitch` family (`kOptimizationHints` and siblings) | `components/optimization_guide/core/optimization_guide_features.h:54` | `kOptimizationHints` enabled | Yes: `OptimizationHints,OptimizationTargetPrediction,OptimizationGuideModelExecution,PageTextExtraction` | Loses Chrome's page-load hints and on-device model predictions. Open has no consumer for them in v1. Saves a service, model downloads, and background fetches. Keep the killswitch feature itself available. |
| `SegmentationPlatform` (`kSegmentationPlatformFeature`) | `components/segmentation_platform/public/features.h:15` | Enabled | Yes: `SegmentationPlatform,SegmentationPlatformUkmEngine` and the segment features | Loses ML user segmentation that drives Chrome UI adaptations. Open's UI is Arc-shaped and does not consume segments. Saves a database, UKM uploads, and periodic model runs. |
| `MediaRouter` (`kMediaRouter`) | `chrome/browser/media/router/media_router_feature.h:36` | Enabled | Yes, in v1: `MediaRouter` | Loses Cast. Arc has casting, but Open's v1 scope in [AGENTS.md](../AGENTS.md) does not list Cast, and `ArcBrowser.isCastEnabled` exists only as a flag. Saves the media-router service and sink discovery (`kDelayMediaSinkDiscovery` shows it polls). Turn it back on as one switch when Cast is scheduled. |
| Translate auto-offer (`TranslateRankerEnforcement`, `TranslateRankerQuery`) | `components/translate/core/browser/translate_ranker_impl.cc:92` | Enabled | Partial: disable the ranker and auto-offer, keep manual translate | `ArcWebContents.translateToTargetLanguage:` proves Arc offers translate. Keep the engine path and the menu item. Disable only the ML ranker that decides to pop the bubble, which removes a model and its fetches. Do not use `--disable-features=Translate` blindly: no single `kTranslate` master feature exists in this tree, so that string may match nothing. Verify the exact name in the smoke test. |
| Safe Browsing extended modes | `components/safe_browsing/core/common/features.h` (many `kSafeBrowsing…` features) | Mixed | Keep standard Safe Browsing on. Disable only telemetry-heavy extras if the smoke test shows them running. | Safe Browsing protects users and costs a small database plus hash-prefix updates. Open must not ship without it to save memory. The saving from disabling it is small and the risk is large. This row is a deliberate "do not turn off". |
| `BackForwardCache` | `content/public/common/content_features.h:90` | Enabled | No. Cap it (§4.3). | Turning it off makes Back slow on every tab to save memory only on navigated-away pages. The cap gets most of the saving. |
| `IntensiveWakeUpThrottling` | `third_party/blink/public/common/features.h:630` | Enabled | No. Never disable. | See §4.1. |
| `WebContentsDiscard` (`kWebContentsDiscard`) | `content/public/common/content_features.h:136` | Disabled on desktop | Yes, enable: `--enable-features=WebContentsDiscard` | This is the discard-in-place path of §1.4. Enabling it is required for the new CEF `Discard` call to work on desktop. Test the speculative-navigation guard in `FrameTree::Discard` (a pending-commit speculative frame makes discard a no-op) so a sleep request during a navigation is retried, not lost. |

Two more savings need no feature switch:

- Ship fewer locales. [arccore-engine.md](re/arccore-engine.md) §6
  measures 220 `.lproj` folders at 50.1 MB in Arc, most of it base
  locales Open's Swift UI never uses. Ship `en` plus the small set
  Open actually translates. This is disk, not RAM, but it is the
  largest single size win available.
- Do not start DevTools, tracing, or the component updater's
  optional components at launch. They are lazy already in CEF;
  keep them lazy by not touching them from Swift at startup.

### 4.6 What not to build

Do not port `performance_manager`. Its graph, decorators, and
voting system solve Chrome's problem (many embedder surfaces, one
shared policy). Open has one surface and a Swift store that already
holds the inputs. Porting it would add a browser-process subsystem
to save memory, which defeats the purpose. Borrow its reason lists
and its timer shape. Leave the code.

---

## 5. Measurement, policy, and budgets

### 5.1 How to measure per-tab memory

Three independent views. Use all three, because they disagree in
known ways.

**View 1 — CEF task manager (shipping path).**
`CefTaskManager::GetTaskManager` in
`cef/include/cef_task_manager.h:60` gives `GetTasksCount`,
`GetTaskIdsList`, `GetTaskInfo`, `KillTask`, and
`GetTaskIdForBrowserId`. `CefTaskInfo` (`cef_task_info_t` in
`cef/include/internal/cef_types.h:4224`) carries `memory` (task
footprint in bytes, `-1` when unavailable), `gpu_memory`,
`cpu_usage`, `type`, and `title`. Map a tab to its task with
`GetTaskIdForBrowserId(CefBrowser::GetIdentifier())`. Caveat: tasks
are per process, not per tab. Two tabs that share a renderer share
a task, and the memory is reported once. Attribute shared memory
by dividing by the tab count only in reports, never in policy.
This is the only view available to the shipped app, so the
automation channel exposes it.

**View 2 — `performance_manager` process nodes (engine debug).**
`ProcessNode::GetPrivateFootprint`, `GetResidentSet`, and
`GetPrivateSwap` in
`components/performance_manager/public/graph/process_node.h:45`
are the values Chrome's own tooling uses ("private, anonymous,
non-discardable, resident or swapped memory"). They require a
component to register interest
(`ProcessMetricsDecorator::RegisterInterestForProcessMetrics`).
Useful while developing the patch, because private footprint is
the honest per-process number. Do not ship a dependency on the
graph for this; read the same OS counters directly if the shipped
app needs them (view 3).

**View 3 — OS processes (ground truth).**
Each renderer is a Helper process. From the shell:
`ps -axo pid,rss,vsz,comm | grep -i "Open Helper (Renderer)"` and
`top -l 1 -pid <pid>`, or `proc_pid_rusage` from Swift for a known
PID. RSS overcounts shared pages (the framework, V8 snapshot, ICU
data are mapped into every renderer). Private footprint (view 2)
is the better budget number; RSS is the better "will the OS kill
us" number. Record both. Get renderer PIDs from the task manager
view where possible; `ps` name matching is a fallback, because
helper names change with branding.

**Idle CPU.** Sample `CefTaskInfo.cpu_usage` per task over a
window, and cross-check with `ps -axo pid,%cpu,comm` and
`powermetrics` on a test machine. Report CPU for the whole app
(browser plus all helpers) at idle with no media, because a single
wakeful background tab hides inside a per-tab average. The budget
is [architecture.md](architecture.md)'s "Idle CPU (no media
playing): ≈ 0%". Measure over 60 s after a 60 s settle. Any
sustained value above 1% of one core fails the budget and names
the task that caused it.

### 5.2 Default sleep policy

Swift implements this policy. Times are configurable. "Hidden"
means not the selected tab in its window and not a visible split
pane. All times reset on show, on audible start, and on user
interaction with the tab.

Never sleep (keep live, at most frozen-off) when any of these hold.
This list merges `CannotDiscardReason` and `CannotFreezeReason`
into signals Open can actually observe, and marks the ones that
need the §6 engine flags:

- The tab is visible, focused, or in a visible split.
- The tab is audible now, or was audible in the last 1 minute
  (`kTabAudioProtectionTime` in `discard_eligibility_policy.h:38`
  uses 1 minute; `kNonVisiblePagesUrgentProtectionTime` protects
  non-visible pages from urgent discard for 10 minutes on desktop).
- The tab is loading, or a navigation committed in the last 10 s.
- Media is capturing, mirroring, in picture-in-picture, or on a
  WebRTC call.
- DevTools is open on the tab.
- The tab has an in-progress download.
- The page has unsaved form edits the user typed (needs engine
  flag; until then, treat "user interacted with a form in the
  last 5 minutes" from Swift-side focus events as the proxy).
- The page holds a WebLock or IndexedDB lock (needs engine flag;
  until then, these pages are frozen but not discarded).
- The user pinned the tab *and* it is audible or has media. A
  quiet pinned tab sleeps like any other: pinning is an ordering
  choice in Open's model, not a keep-alive request. Chrome lists
  `kPinnedTab` as a discard blocker; Open deliberately diverges,
  because Arc users keep dozens of pinned tabs. State this in the
  settings UI.

Sleep ladder for every other tab:

| Step | Trigger | Engine action | Saves |
|---|---|---|---|
| Hide | Tab loses visibility | `WasHidden` (honest visibility) | Rendering and timer wake-ups (Blink throttling) |
| Freeze | Hidden for 30 s | `SetPageFrozen(true)` via the new CEF call | Near-zero CPU. No memory. |
| Discard | Hidden for 5 min (conservative 15 min, aggressive 2 min) | Capture history, then `Discard` | The renderer's private footprint, minus the small `WebContents` shell |
| Destroy | Sleeping for 24 h, or memory pressure, or live-renderer count over the §5.5 cap | `CloseBrowser(true)` after capture | The remaining shell and view cost |

The 5-minute default sits between Chrome's 120-minute Memory Saver
default and the aggressive mode. It is justified by the placeholder
design: because unselected tabs cost nothing, the user loses
nothing when a tab they return to must reload, and the reload is
the same path as selecting a never-loaded tab. Expose three modes
in settings (Conservative 15 min, Balanced 5 min, Aggressive
2 min), mapped to the discard step only. Freeze stays at 30 s in
all modes. Battery Saver, when the OS reports low power, uses the
aggressive discard time and drops the spare renderer.

Under memory pressure (OS pressure notification), discard
immediately, oldest-hidden first, skipping the never-sleep list.
This mirrors Chrome's urgent discard and
`kDiscardFrozenBrowsingInstancesWithGrowingPMF`: pressure order is
frozen tabs first (they promised to use little), then hidden
unfrozen tabs by age.

### 5.3 Expected savings

Estimates, not measurements. The only hard number in the tree is
Chromium's own planning estimate of 85 MB per `WebContents`
(`render_process_host_impl.cc`, `kEstimatedWebContentsMemoryUsage`).
Real pages vary from about 30 MB (a document) to several hundred
MB (a web app). Use 60 MB as the conservative per-renderer private
footprint until §5.4 produces Open's own numbers, and present
savings as a range.

For a profile with N tabs where the user actively uses about 3:

- No policy: N live renderers (subject to the process limit and
  same-site sharing). At N = 50, roughly 40 to 50 processes.
- This design: at most 5 live background renderers plus the active
  tab, 1 spare, the GPU process, and the browser process. Sleeping
  tabs cost the serialized blob (KB to low MB) plus, until the
  destroy step, a `WebContents` shell.
- Expected renderer memory saving at 50 tabs: about 85 to 92% of
  renderer private memory. At 10 tabs the saving is smaller in
  percent (about 50 to 65%) because the active set is a larger
  share. These percents follow from the counts above at 60 MB per
  renderer; they are arithmetic, not a benchmark. The design doc
  must be updated with measured values before the policy ships.

Disk cost of sleeping: one `sleepState` blob per slept tab, capped
at 2 MiB, typically far less. 100 slept tabs cost less disk than
one live renderer costs RAM.

### 5.4 Verification through the automation channel

No unit tests, per [AGENTS.md](../AGENTS.md) rule 6 and
[architecture.md](architecture.md) §Testing. Verify end to end on
the real app through the automation channel
(`docs/automation.md`, built by the engine spike). Required flows:

1. Open 12 known pages in 12 tabs. Select tab 1. Wait past the
   freeze and discard times (use a debug time override exposed
   only to the automation channel, never a user setting). Read
   back: tabs 2–12 report sleeping, task count drops, total
   private memory drops. Screenshot the sidebar: placeholder
   tiles and favicons are correct.
2. In one tab, build history: load A, then B, then C; scroll C;
   type into a form on C without submitting. Sleep the tab. Wake
   it. Assert: Back reaches B, then A; forward reaches C; scroll
   and form values on C are restored; `document.wasDiscarded`
   was true on wake (read it with the channel's JS execution
   before any navigation).
3. Sleep a tab with audio playing. Assert it does not discard.
   Pause the audio, wait past the protection minute, assert it
   discards.
4. Quit with a mix of live, frozen, discarded, and placeholder
   tabs. Relaunch. Assert: sidebar draws inside 250 ms, only the
   selected tab has a task, and waking a restored tab restores
   its back list.
5. Measure: record per-task memory and CPU from `CefTaskManager`
   and from `ps` for the 10, 50, and 100 tab fixtures in §5.5,
   plus wake latency p50 and p95 for unfreeze, discard-wake, and
   destroy-wake, warm and cold cache.

### 5.5 Budgets with sleeping

Release build, Apple Silicon, the fixture pages from flow 5.
"Live" is the active tab plus background tabs still inside their
freeze window. These budgets extend
[architecture.md](architecture.md); they do not replace it.

| Tabs in profile | Live renderers (max) | Renderer private memory | Idle CPU (whole app) | Sidebar state |
|---|---|---|---|---|
| 10 | 6 (5 background + active) + 1 spare | ≤ 420 MB | ≈ 0% (under 1% of one core, 60 s window) | All rows drawn from the model. No scroll jank at 120 Hz. |
| 50 | 6 + 1 spare | ≤ 420 MB (sleeping tabs add no renderer) | ≈ 0% | Same. Memory must not grow with tab count beyond the `sleepState` blobs. |
| 100 | 6 + 1 spare | ≤ 420 MB | ≈ 0% | Same. 100 rows still scroll at 120 fps. |

The flat memory line across 10, 50, and 100 tabs is the design's
whole claim. If renderer memory grows with total tab count, the
policy is not running, whatever the per-tab numbers say. The
destroy step (§1.7) is what keeps the browser-process shell cost
flat too; without it, 100 discarded `WebContents` objects add a
slow slope that the 100-tab row must catch.

Process budget: at most 9 helper processes at idle in the 100-tab
fixture (browser, GPU, network, storage, up to 6 renderers, 1
spare), against 40 to 100 without sleeping. Count them with `ps`
in flow 5.

---

## 6. Patch plan: exact fork changes

Numbered for the fork series files in
[plans/fork-infra.md](plans/fork-infra.md). New code goes in the
overlay (`Engine/fork/src/…`), patches hold only the wiring hunks,
per that plan's rules D-2 and D-3. CEF API additions follow CEF's
translator format (`/*--cef()--*/` comments, a capi header, and an
entry in `cef_api_versions.json` through the translator, never by
hand).

**P-MEM-01 — Visibility that works in Chrome style.**
Files: `cef/libcef/browser/chrome/chrome_browser_host_impl.cc`
(`ChromeBrowserHostImpl::WasHidden`, today `NOTIMPLEMENTED()`),
and the Alloy path for consistency. Make `WasHidden(bool)` forward
to `web_contents->WasHidden()` / `WasShown()` on the UI thread,
matching the OSR delegate in
`cef/libcef/browser/osr/browser_platform_delegate_osr.cc:226`.
Without this, no throttling, freezing, or discarding signal is
honest in the style Open ships. Small patch. Do first.

**P-MEM-02 — `CefBrowserHost::SetPageFrozen(bool)` and
`IsPageFrozen()`.**
New API in `cef/include/cef_browser.h`, implemented in
`CefBrowserHostBase` over `GetWebContents()->SetPageFrozen`.
Guard: no-op with a false return when the contents is visible,
matching the `WebContents` contract. Needed by §4.2.

**P-MEM-03 — `CefBrowserHost::Discard(CefRefPtr<CefCallback>)`
and `WasDiscarded()`.**
New API over `content::WebContents::Discard` and `WasDiscarded`
(`web_contents.h:876`, `:887`). The callback maps to the
`base::OnceClosure` that `FrameTree::Discard` already accepts,
so Swift learns when the renderer actually released. Requires
`--enable-features=WebContentsDiscard` (§4.5) until the content
feature defaults on for desktop. Handle the speculative-frame
no-op in `FrameTree::Discard`: if discard is refused because a
navigation is pending commit, retry once after
`DidFinishNavigation`. Also expose
`NeedsReload` state indirectly: after discard, the next show
reloads; Swift needs no extra flag.

**P-MEM-04 — History capture and restore (the core patch).**
New types and calls:

- `CefNavigationHistory` (new file `cef/include/cef_navigation_history.h`):
  an opaque value holding `entries` (a list of byte blobs, one
  pickled `SerializedNavigationEntry` each), `current_index`,
  `title`, and `favicon_url`. Opaque bytes keep Chromium's pickle
  format out of the Swift API and let the format change under
  Open.
- `CefBrowserHost::GetNavigationHistory()` → `CefNavigationHistory`:
  walk the controller like `GetNavigationEntries` does
  (`browser_host_base.cc:791`), convert each entry with
  `ContentSerializedNavigationBuilder::FromNavigationEntry` using
  one shared `NavigationEntryRestoreContext` on the write side
  is not needed; dedupe happens on restore. Link
  `//components/sessions/content` into `libcef` (check the
  existing `cef/libcef` BUILD deps; this is the one new library
  dependency in the plan).
- `CefBrowserHost::RestoreNavigationHistory(history)`:
  rebuild with `ToNavigationEntries`, then call
  `controller.Restore(current_index, RestoreType::kRestored, &entries)`.
  Must be called before the first navigation and before first
  show. Return false after first commit.
- Extend `CefNavigationEntry` with `GetReferrerURL`,
  `GetFaviconURL`, and `GetTimestamp` for the placeholder UI.
  These read fields that `SerializedNavigationEntry` already
  carries; the current CEF entry omits them.

Capture must run on the UI thread from the browser process. It
must not round-trip to the renderer. `GetNavigationEntries`
proves the pattern.

**P-MEM-05 — Create with no renderer, and restore before show.**
Add `CefBrowserSettings`-adjacent creation support, or a
`CefWindowInfo`-level flag, that maps to
`WebContents::CreateParams` with
`desired_renderer_state = kNoRendererProcess` and
`initially_hidden = true` (`web_contents.h:256`, `:306`). In
Chrome style the `WebContents` is created by the Chrome
`Browser`; the patch threads the flag through
`ChromeBrowserHostImpl::Create` and the `Browser::CreateParams`
`cef_params`. This is the patch most likely to conflict on
rebase, because it touches Chrome browser creation. Keep the
hunk to the flag plumbing only. It serves both uses: a restored
tab that must hold history without a process (§2.3), and the
discarded replacement state.

**P-MEM-06 — Eligibility flags (small, can ship after v1).**
On the existing display/load handler path, or as
`CefBrowserHost` getters refreshed on change: `HasFormUserEdits`,
`HasActiveLocks` (WebLock plus IndexedDB), `IsCapturing`,
`HasBeforeUnloadHandler`. Sources: `PageLiveStateDecorator`
data behind `CannotDiscardReason`, and
`WebContents::NeedToFireBeforeUnloadOrUnloadEvents`
(`web_contents.h:1068`). Until this lands, §5.2 uses proxies and
discard stays conservative.

**P-MEM-07 — Feature and switch defaults (no C++ if avoidable).**
Set the §4.5 switches in the app's
`CefApp::OnBeforeCommandLineProcessing` implementation, in
OpenEngine, not in `libcef`. Only move a default into the fork
(a `BASE_FEATURE` default flip) if a switch proves unreliable
across process types. Prefer switches: they survive rebases for
free.

**OpenEngine (Swift-facing) surface.** Mirror the four primitives
as one small protocol, in the shape of Arc's `discard` and
freezing vote ([arccore-engine.md](re/arccore-engine.md) §2.3).
Do not expose `CefBrowser` to Swift beyond OpenEngine, per
[AGENTS.md](../AGENTS.md). Suggested surface:

- `WebContent.sleepState` (live, frozen, discarded, placeholder)
- `WebContent.freeze()`, `WebContent.discard() async`
- `WebContent.captureHistory() -> Data` (the opaque blob)
- `WebContent.restoreHistory(Data)` (pre-show only)
- `WebContent.setVisible(Bool)` (drives P-MEM-01)

**Series order.** P-MEM-01, P-MEM-05, P-MEM-04, P-MEM-02,
P-MEM-03, P-MEM-06. Visibility first because everything reads it.
Creation and history next because placeholders need them. Freeze
and discard last because they are useless until a tab can come
back.

---

## 7. Risks and open questions

1. **Chrome-style ownership.** In Chrome style, the Chrome
   `Browser` owns the `WebContents` through its tab strip
   (`browser_host_base.h:192`). `WebContents::Discard` keeps the
   object alive, so discard-in-place is compatible with that
   owner. Destroying the `WebContents` outside the tab strip is
   not. The destroy step in §1.7 must therefore go through
   `CloseBrowser`, never through a direct `WebContents` delete.
   Verify in the spike that closing a Chrome-style CEF browser
   with a discarded contents completes without the tab strip
   resurrecting it. If Chrome style fights the sleep cycle,
   the fallback is Alloy style for tab browsers, which owns its
   `WebContents` directly — at the cost of the Chrome-layer
   extension surface that
   [arccore-engine.md](re/arccore-engine.md) §4.4 says Open
   needs. Decide with a spike before committing to either.
2. **Pickle format stability.** `SerializedNavigationEntry`
   pickles are version-tolerant within Chromium's session
   restore, but Open stores them across app updates that may
   cross a Chromium rebase. On decode failure, drop to a
   single-entry restore from the stored current URL and title.
   Keep those two fields in Swift, outside the blob, for every
   entry's current index, so the fallback never loses the page
   itself. Test the fallback in flow 4 with a corrupted blob.
3. **Page-state size.** Deep iframe trees make
   `encoded_page_state` large and slow to serialize
   (`content_serialized_navigation_builder.h:33`). The 2 MiB
   cap and the `EXCLUDE_PAGE_STATE` fallback bound it. A tab
   that hits the cap loses scroll and form restore. It keeps
   its history. That is the right order of loss.
4. **Pages that notice.** A discarded page loses WebSockets,
   media position, and JS state, and sees `wasDiscarded`. Some
   sites handle this badly (single-page apps that assume the
   document lives forever). The never-sleep list and the
   conservative default exist for this. Ship the discard ring
   or an equivalent "this tab slept" affordance so the reload
   is explained, as Chrome does with its discard indicator.
5. **`POST` and payment flows.** §1.3: bodies do not persist.
   A slept checkout tab may repost or restart. The form-edit
   and recent-interaction protections reduce this. They do
   not remove it. Chrome has the same behaviour; match it,
   do not try to outsmart it by keeping such tabs live forever.
6. **Extension tabs.** An extension may hold state against a
   tab through `chrome.tabs`. Discarding must keep the tab's
   Open ID and its strip-visible properties stable, or
   extensions will see a tab vanish and reappear. This is the
   §8.4 risk in [arccore-engine.md](re/arccore-engine.md). The
   discarded `WebContents` keeps its identity in place, which
   is another reason to prefer discard-in-place over destroy.
7. **`kWebContentsDiscard` is off by default on desktop.**
   Turning it on (§4.5) opts Open into a path Chrome still
   gates. The speculative-navigation guard and the Android-only
   default say the path is newer. Budget spike time to run it
   under the §5.4 flows before the policy depends on it. The
   fallback, if the in-place path proves unstable, is option
   (b) destroy-and-restore for every sleep, at higher wake
   latency. The `sleepState` format serves both, by design.
8. **Open question: does Arc sleep pinned tabs?** [model.md](model.md)
   open question 3 asks whether closing a pinned tab only unloads
   it. That is a UI-command question, separate from sleeping.
   For sleeping itself this design treats quiet pinned tabs as
   sleepable (§5.2). If Arc evidence later shows pinned tabs
   never unload, add pinned tabs to the never-sleep list and
   accept the memory cost. The policy change is one branch in
   Swift.
9. **Open question: BFCache and freeze interaction.** A frozen
   page that enters BFCache on navigation is a second kind of
   sleep, owned by the navigation, not by the tab. The budgets
   in §5.5 count BFCache-pinned renderers as live. If Back
   latency matters less than the 50-tab memory line on low-end
   machines, cap BFCache to 1 entry there. Measure Back
   latency both ways in flow 5 before deciding.

## Appendix: evidence index

Chromium and CEF paths are under
`~/Developer/open-engine/chromium_git/chromium/src`.

- Discard API and feature: `content/public/browser/web_contents.h:867`
  (`Discard`, `WasDiscarded`), `content/public/common/content_features.cc:381`
  (`kWebContentsDiscard`, disabled on desktop),
  `content/browser/web_contents/web_contents_impl.cc:2801`,
  `content/browser/renderer_host/frame_tree.cc:1197`
  (`FrameTree::Discard`),
  `content/browser/renderer_host/render_frame_host_impl.cc:13351`
  (`DiscardFrame`).
- Discard policy: `chrome/browser/resource_coordinator/tab_lifecycle_unit.cc:270`
  (`FinishDiscard`, `CopyStateFrom`, `kNoRendererProcess`),
  `:337` (`FinishDiscardAndPreserveWebContents`), `:408` (feature
  branch); `chrome/browser/performance_manager/mechanisms/page_discarder.cc:44`;
  `chrome/browser/performance_manager/policies/discard_eligibility_policy.h`,
  `…/cannot_discard_reason.h`,
  `…/policies/memory_saver_mode_policy.h`;
  `components/performance_manager/public/user_tuning/prefs.h:41`
  (120-minute default), `:43` (aggressiveness).
- Freeze: `content/public/browser/web_contents.h:1177`
  (`SetPageFrozen`), `components/performance_manager/freezing/freezer.cc`
  (`MaybeFreezePageNode`), `…/freezing/freezing_policy.h`,
  `components/performance_manager/public/freezing/cannot_freeze_reason.h`,
  `components/performance_manager/public/features.h:145`
  (discard frozen with growing footprint), `:177`
  (`kInfiniteTabsFreezing`).
- History and restore: `content/public/browser/navigation_controller.h:473`
  (`Restore`), `:751` (`CopyStateFrom`);
  `components/sessions/core/serialized_navigation_entry.h:29`
  ("freeze-dried", `encoded_page_state_`);
  `components/sessions/content/content_serialized_navigation_builder.h:25`
  (`FromNavigationEntry`, `ToNavigationEntries`, `EXCLUDE_PAGE_STATE`);
  `content/public/browser/navigation_entry.h:126` (page state is
  scroll plus form), `:176` (post data not persisted).
- No-renderer creation: `content/public/browser/web_contents.h:256`
  (`initially_hidden`), `:283` (`desired_renderer_state`,
  `kNoRendererProcess` at `:306`).
- CEF surface and gaps: `cef/include/cef_browser.h:362`
  (`CloseBrowser`), `:669` (`GetNavigationEntries`), `:707`
  (`WasHidden`, windowless only);
  `cef/include/cef_navigation_entry.h:48` (read-only entry);
  `cef/libcef/browser/browser_host_base.cc:771` (history read),
  `cef/libcef/browser/chrome/chrome_browser_host_impl.cc:240`
  (`WasHidden` `NOTIMPLEMENTED`),
  `cef/libcef/browser/alloy/alloy_browser_host_impl.cc:360`,
  `cef/libcef/browser/osr/browser_platform_delegate_osr.cc:226`
  (the working visibility forward),
  `cef/libcef/browser/chrome/chrome_browser_host_impl.h:112`
  (Chrome `Browser` ownership), `cef/include/cef_app.h:208`
  (`OnBeforeCommandLineProcessing`), `cef/include/cef_task_manager.h:50`
  and `cef/include/internal/cef_types.h:4224` (`CefTaskInfo.memory`,
  `cpu_usage`).
- Process model: `content/browser/renderer_host/render_process_host_impl.cc:1505`
  (`GetMaxRendererProcessCount`, 85 MB estimate),
  `content/public/common/content_switches.h:165` (`kProcessPerSite`),
  `:180` (`kRendererProcessLimit`),
  `content/browser/site_instance_impl.h:210` (reuse policy),
  `content/browser/renderer_host/spare_render_process_host_manager_impl.h:77`
  (spare manager and its memory-pressure features),
  `content/public/browser/spare_render_process_host_manager.h`.
- Throttling, BFCache, GPU: `third_party/blink/public/common/features.h:630`
  (`kIntensiveWakeUpThrottling`),
  `third_party/blink/renderer/platform/scheduler/common/features.h:40`
  (grace periods), `content/public/common/content_features.h:90`
  (`kBackForwardCache`), `content/browser/back_forward_cache/back_forward_cache_impl.cc`
  (`EnforceCacheSizeLimit`), `gpu/config/gpu_finch_features.cc:212`
  (`kDefaultEnableGpuRasterization` on Apple).
- Features to disable: `components/optimization_guide/core/optimization_guide_features.h:54`,
  `components/segmentation_platform/public/features.h:15`,
  `chrome/browser/media/router/media_router_feature.h:36`,
  `components/translate/core/browser/translate_ranker_impl.cc:92`,
  `components/safe_browsing/core/common/features.h` (keep on).
- Measurement: `components/performance_manager/public/graph/process_node.h:45`
  (`GetPrivateFootprint`), `cef/include/cef_task_manager.h:60`.
- Open repo: [architecture.md](architecture.md) (budgets, lazy
  creation), [model.md](model.md) and
  `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift:24` (tab
  fields, `TabLiveState`),
  [re/arccore-engine.md](re/arccore-engine.md) §2.3 (Arc `discard`,
  freezing vote), §4.4 (CEF extension gap), §6 (locale weight),
  [re/architecture-map.md](re/architecture-map.md) §4.3 (one tab,
  one frame, one contents).
