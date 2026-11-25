// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_tab_bridge.h"

#include <algorithm>
#include <set>
#include <utility>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/base_window.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"

namespace open_unified {

namespace {

RGBAColor ToRGBA(SkColor color) {
  return RGBAColor{SkColorGetR(color) / 255.0, SkColorGetG(color) / 255.0,
                   SkColorGetB(color) / 255.0, SkColorGetA(color) / 255.0};
}

// Marks the blank WebContents that keeps an otherwise empty TabStripModel
// (and so its window) alive while the selected sidebar item has no page
// (Arc's empty Space state). Never mirrored into the model; removed as soon
// as a real tab is inserted.
class OpenEmptyStateMarker
    : public content::WebContentsUserData<OpenEmptyStateMarker> {
 public:
  ~OpenEmptyStateMarker() override = default;

 private:
  friend class content::WebContentsUserData<OpenEmptyStateMarker>;
  explicit OpenEmptyStateMarker(content::WebContents* contents)
      : content::WebContentsUserData<OpenEmptyStateMarker>(*contents) {}
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenEmptyStateMarker);

bool IsEmptyState(content::WebContents* contents) {
  return contents && OpenEmptyStateMarker::FromWebContents(contents);
}

}  // namespace

// ---------------------------------------------------------------------------
// OpenTabObserver: page -> model propagation for one tab.

class OpenTabObserver : public content::WebContentsObserver,
                        public favicon::FaviconDriverObserver {
 public:
  OpenTabObserver(base::WeakPtr<OpenTabBridge> bridge,
                  content::WebContents* contents,
                  ItemID tab_id)
      : content::WebContentsObserver(contents),
        bridge_(std::move(bridge)),
        tab_id_(std::move(tab_id)) {
    if (auto* driver =
            favicon::ContentFaviconDriver::FromWebContents(contents)) {
      favicon_observation_.Observe(driver);
    }
  }
  ~OpenTabObserver() override = default;

  // content::WebContentsObserver:
  void TitleWasSet(content::NavigationEntry* entry) override {
    if (bridge_) {
      bridge_->OnTabTitleOrUrlChanged(tab_id_, web_contents());
    }
  }

  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (!bridge_ || !handle->IsInPrimaryMainFrame() ||
        !handle->HasCommitted()) {
      return;
    }
    bridge_->OnTabTitleOrUrlChanged(tab_id_, web_contents());
    if (!handle->IsSameDocument() && !handle->IsErrorPage()) {
      const bool typed = ui::PageTransitionCoreTypeIs(
          handle->GetPageTransition(), ui::PAGE_TRANSITION_TYPED);
      bridge_->OnTabPrimaryPageCommitted(tab_id_, web_contents(), typed);
    }
    UpdateLive();
  }

  void PrimaryMainDocumentElementAvailable() override {
    if (bridge_) {
      bridge_->OnTabDocumentAvailable(tab_id_, web_contents());
    }
  }

  void DidStartLoading() override { UpdateLive(); }
  void DidStopLoading() override { UpdateLive(); }
  void LoadProgressChanged(double progress) override { UpdateLive(); }
  void OnAudioStateChanged(bool audible) override { UpdateLive(); }
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override {
    UpdateLive();
  }
  void OnBackgroundColorChanged() override { UpdateLive(); }

  // favicon::FaviconDriverObserver:
  void OnFaviconUpdated(favicon::FaviconDriver* favicon_driver,
                        NotificationIconType notification_icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override {
    if (!bridge_ || image.IsEmpty() ||
        notification_icon_type != NON_TOUCH_16_DIP) {
      return;
    }
    std::optional<std::vector<uint8_t>> png =
        gfx::PNGCodec::EncodeBGRASkBitmap(*image.ToSkBitmap(),
                                          /*discard_transparency=*/false);
    if (!png) {
      return;
    }
    OpenBrowserService* service = OpenBrowserService::Get();
    if (!service) {
      return;
    }
    model_util::UpdateLive(service->model(), tab_id_, [&](TabLiveState& live) {
      live.favicon_png = *png;
    });
    // Persist per page URL so placeholders show icons after a relaunch.
    if (auto profile_id =
            model_util::ProfileOfNode(service->model(), tab_id_)) {
      if (ProfileServices* ps = service->ProfileServicesFor(*profile_id);
          ps && !web_contents()->GetBrowserContext()->IsOffTheRecord()) {
        RunOnStore(ps->favicons,
                   base::BindOnce(
                       [](std::string url, std::vector<uint8_t> png,
                          std::optional<std::string> icon_url,
                          FaviconStore* store) {
                         store->Put(url, png, {}, icon_url);
                       },
                       web_contents()->GetLastCommittedURL().spec(),
                       std::move(*png),
                       icon_url.is_valid()
                           ? std::optional<std::string>(icon_url.spec())
                           : std::nullopt));
      }
    }
  }

  void set_tab_id(const ItemID& id) { tab_id_ = id; }

 private:
  void UpdateLive() {
    OpenBrowserService* service = OpenBrowserService::Get();
    if (!service) {
      return;
    }
    content::WebContents* wc = web_contents();
    std::optional<SkColor> background = wc->GetBackgroundColor();
    model_util::UpdateLive(service->model(), tab_id_, [&](TabLiveState& live) {
      live.has_web_content = true;
      live.is_loading = wc->IsLoading();
      live.progress = wc->GetLoadProgress();
      live.is_audible = wc->IsCurrentlyAudible();
      live.is_crashed = wc->IsCrashed();
      live.can_go_back = wc->GetController().CanGoBack();
      live.can_go_forward = wc->GetController().CanGoForward();
      if (!wc->IsLoading()) {
        live.has_loaded_in_this_launch = true;
      }
      if (background) {
        live.page_background_color = ToRGBA(*background);
      }
    });
  }

  base::WeakPtr<OpenTabBridge> bridge_;
  ItemID tab_id_;
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation_{this};
};

// ---------------------------------------------------------------------------
// OpenTabHandle

OpenTabHandle::OpenTabHandle(content::WebContents* contents, ItemID tab_id)
    : content::WebContentsUserData<OpenTabHandle>(*contents),
      tab_id_(std::move(tab_id)) {}

OpenTabHandle::~OpenTabHandle() = default;

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenTabHandle);

// ---------------------------------------------------------------------------
// OpenTabBridge

OpenTabBridge::WindowBrowsers::WindowBrowsers() = default;
OpenTabBridge::WindowBrowsers::~WindowBrowsers() = default;
OpenTabBridge::WindowBrowsers::WindowBrowsers(WindowBrowsers&&) = default;
OpenTabBridge::WindowBrowsers& OpenTabBridge::WindowBrowsers::operator=(
    WindowBrowsers&&) = default;

OpenTabBridge::OpenTabBridge(OpenBrowserService* service)
    : service_(service) {}

OpenTabBridge::~OpenTabBridge() {
  Shutdown();
}

void OpenTabBridge::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  service_->model().AddObserver(this);
  browser_collection_observation_.Observe(
      GlobalBrowserCollection::GetInstance());
  AdoptStartupBrowsers();
}

void OpenTabBridge::Shutdown() {
  if (!started_) {
    return;
  }
  started_ = false;
  service_->model().RemoveObserver(this);
  browser_collection_observation_.Reset();
  strip_observations_.RemoveAllObservations();
  windows_.clear();
  contents_.clear();
}

void OpenTabBridge::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenTabBridge::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

// --- Startup -----------------------------------------------------------------

void OpenTabBridge::AdoptStartupBrowsers() {
  const WindowID main = service_->MainWindowId();
  std::vector<std::pair<BrowserWindowInterface*, content::WebContents*>>
      startup_tabs;
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* browser) {
        if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
          return true;
        }
        std::optional<ProfileID> profile =
            service_->OpenProfileIdFor(browser->GetProfile());
        if (!profile || browser->GetProfile()->IsOffTheRecord()) {
          return true;
        }
        WindowBrowsers& wb = windows_[main];
        if (!wb.by_profile.contains(*profile)) {
          wb.by_profile[*profile] = browser;
          strip_observations_.AddObservation(browser->GetTabStripModel());
        }
        // Chromium's startup tabs (NTP, session restore, command-line URLs)
        // are not Open's; Open's model is the session.
        TabStripModel* strip = browser->GetTabStripModel();
        for (int i = 0; i < strip->count(); ++i) {
          startup_tabs.emplace_back(browser, strip->GetWebContentsAt(i));
        }
        return true;
      });

  for (const BrowserWindowState& window : service_->model().windows()) {
    ShowBrowserForSpace(window.id, window.focused_space_id);
    ApplySelectionFromModel(window.id);
  }

  // Close the startup tabs only now, after Open's own tabs are in the
  // strips, so no window closes for being empty.
  base::AutoReset<bool> applying(&applying_, true);
  for (auto& [browser, contents] : startup_tabs) {
    TabStripModel* strip = browser->GetTabStripModel();
    EnsureNonEmpty(browser);
    const int index = strip->GetIndexOfWebContents(contents);
    if (index != TabStripModel::kNoTab && strip->count() > 1) {
      strip->CloseWebContentsAt(index, TabCloseTypes::CLOSE_NONE);
    }
  }
}

BrowserWindowInterface* OpenTabBridge::EnsureBrowser(
    const WindowID& window_id,
    const ProfileID& profile_id) {
  WindowBrowsers& wb = windows_[window_id];
  if (auto it = wb.by_profile.find(profile_id); it != wb.by_profile.end()) {
    return it->second;
  }
  ::Profile* profile = service_->ChromeProfileFor(profile_id);
  if (!profile) {
    return nullptr;
  }
  const BrowserWindowState* window = service_->model().FindWindow(window_id);
  BrowserWindowCreateParams params(BrowserWindowInterface::TYPE_NORMAL,
                                   *profile, /*from_user_gesture=*/true);
  if (window) {
    params.initial_bounds = gfx::Rect(
        static_cast<int>(window->frame_x), static_cast<int>(window->frame_y),
        static_cast<int>(window->frame_width),
        static_cast<int>(window->frame_height));
  }
  base::AutoReset<bool> applying(&applying_, true);
  BrowserWindowInterface* browser = CreateBrowserWindow(std::move(params));
  if (!browser) {
    return nullptr;
  }
  wb.by_profile[profile_id] = browser;
  strip_observations_.AddObservation(browser->GetTabStripModel());
  return browser;
}

void OpenTabBridge::ShowBrowserForSpace(const WindowID& window_id,
                                        const SpaceID& space_id) {
  const Space* space = service_->model().FindSpace(space_id);
  if (!space) {
    return;
  }
  BrowserWindowInterface* target = EnsureBrowser(window_id, space->profile_id);
  if (!target) {
    return;
  }
  WindowBrowsers& wb = windows_[window_id];
  gfx::Rect bounds;
  for (auto& [profile_id, browser] : wb.by_profile) {
    if (browser != target && browser->GetWindow()->IsVisible()) {
      bounds = browser->GetWindow()->GetBounds();
      browser->GetWindow()->Hide();
    }
  }
  EnsureNonEmpty(target);
  if (!bounds.IsEmpty()) {
    target->GetWindow()->SetBounds(bounds);
  }
  if (!target->GetWindow()->IsVisible()) {
    target->GetWindow()->Show();
  }
}

// --- Model -> Chromium -------------------------------------------------------

void OpenTabBridge::OnTreeChanged(const TreeChange& change) {
  // kUpdate covers titles, URLs and live state: nothing structural. The
  // bridge's own model writes (applying_) are mirrored already.
  if (applying_ || !started_ || change.kind == TreeChange::Kind::kUpdate) {
    return;
  }
  ScheduleResync();
}

void OpenTabBridge::ScheduleResync() {
  if (resync_pending_) {
    return;
  }
  resync_pending_ = true;
  // One pass after a burst of changes (a folder move emits one change per
  // node; Undo can emit many).
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OpenTabBridge::RunScheduledResync,
                                weak_factory_.GetWeakPtr()));
}

void OpenTabBridge::RunScheduledResync() {
  resync_pending_ = false;
  if (!started_) {
    return;
  }
  ResyncAll();
  for (const BrowserWindowState& window : service_->model().windows()) {
    ApplySelectionFromModel(window.id);
  }
}

void OpenTabBridge::ResyncAll() {
  for (auto& [window_id, wb] : windows_) {
    for (auto& [profile_id, browser] : wb.by_profile) {
      ResyncBrowser(browser);
    }
  }
}

std::vector<ItemID> OpenTabBridge::StripOrderFor(
    const ProfileID& profile_id) const {
  std::vector<ItemID> order;
  std::set<ItemID> seen;
  for (const Space& space : service_->model().spaces()) {
    if (space.profile_id != profile_id) {
      continue;
    }
    // OrderedTabIds() starts with the Profile's Favorites in every Space;
    // keep them once, at the front.
    for (const ItemID& id :
         model_util::OrderedTabIds(service_->model(), space.id)) {
      if (seen.insert(id).second) {
        order.push_back(id);
      }
    }
  }
  return order;
}

void OpenTabBridge::ResyncBrowser(BrowserWindowInterface* browser) {
  std::optional<ProfileID> profile = ProfileOfBrowser(browser);
  if (!profile) {
    return;
  }
  base::AutoReset<bool> applying(&applying_, true);
  TabStripModel* strip = browser->GetTabStripModel();
  const std::vector<ItemID> order = StripOrderFor(*profile);
  const std::set<ItemID> wanted(order.begin(), order.end());

  // 1. Close pages whose sidebar item is gone.
  EnsureNonEmpty(browser);
  for (int i = strip->count() - 1; i >= 0; --i) {
    content::WebContents* wc = strip->GetWebContentsAt(i);
    std::optional<ItemID> id = TabIdForWebContents(wc);
    if (!id || wanted.contains(*id)) {
      continue;
    }
    for (Observer& observer : observers_) {
      observer.OnTabContentsDetaching(*id, wc);
    }
    contents_.erase(*id);
    if (strip->count() == 1) {
      EnsureNonEmpty(browser);
    }
    strip->CloseWebContentsAt(strip->GetIndexOfWebContents(wc),
                              TabCloseTypes::CLOSE_NONE);
  }

  // 2. Order loaded pages like the sidebar (chrome.tabs indices).
  int target = 0;
  for (const ItemID& id : order) {
    auto it = contents_.find(id);
    if (it == contents_.end()) {
      continue;
    }
    const int current = strip->GetIndexOfWebContents(it->second);
    if (current == TabStripModel::kNoTab) {
      continue;  // In another window's strip.
    }
    if (current != target) {
      strip->MoveWebContentsAt(current, target, /*select_after_move=*/false);
    }
    ++target;
  }
}

int OpenTabBridge::TargetStripIndex(BrowserWindowInterface* browser,
                                    const ItemID& tab_id) const {
  std::optional<ProfileID> profile = ProfileOfBrowser(browser);
  if (!profile) {
    return browser->GetTabStripModel()->count();
  }
  const TabStripModel* strip = browser->GetTabStripModel();
  int index = 0;
  for (const ItemID& id : StripOrderFor(*profile)) {
    if (id == tab_id) {
      break;
    }
    auto it = contents_.find(id);
    if (it != contents_.end() &&
        strip->GetIndexOfWebContents(it->second) != TabStripModel::kNoTab) {
      ++index;
    }
  }
  return std::min(index, strip->count());
}

void OpenTabBridge::ApplySelectionFromModel(const WindowID& window_id) {
  const BrowserWindowState* window = service_->model().FindWindow(window_id);
  if (!window) {
    return;
  }
  ShowBrowserForSpace(window_id, window->focused_space_id);
  auto selected = window->selected_node_by_space.find(window->focused_space_id);
  if (selected == window->selected_node_by_space.end()) {
    return;
  }
  const SidebarNode* node = service_->model().FindNode(selected->second);
  if (!node) {
    return;
  }

  ItemID to_activate;
  if (const Tab* tab = node->as_tab()) {
    to_activate = tab->id;
  } else if (const Split* split = node->as_split()) {
    // Every pane of a Split View is live; the focused pane is the active
    // Chromium tab (keyboard focus, extensions' "active tab").
    for (const Tab& pane : split->panes) {
      EnsureLoaded(pane.id);
    }
    to_activate = split->focused_pane_id.value_or(
        split->panes.empty() ? ItemID() : split->panes.front().id);
  } else if (const Folder* folder = node->as_folder()) {
    to_activate = folder->peeked_child_id.value_or(ItemID());
  }
  if (to_activate.empty()) {
    return;
  }
  content::WebContents* wc = EnsureLoaded(to_activate);
  BrowserWindowInterface* browser = BrowserForTab(to_activate);
  if (!wc || !browser) {
    return;
  }
  base::AutoReset<bool> applying(&applying_, true);
  TabStripModel* strip = browser->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(wc);
  if (index != TabStripModel::kNoTab && index != strip->active_index()) {
    strip->ActivateTabAt(index);
  }
  for (Observer& observer : observers_) {
    observer.OnTabActivated(to_activate);
  }
}

void OpenTabBridge::EnsureNonEmpty(BrowserWindowInterface* browser) {
  TabStripModel* strip = browser->GetTabStripModel();
  if (strip->count() > 1) {
    return;
  }
  if (strip->count() == 1 && IsEmptyState(strip->GetWebContentsAt(0))) {
    return;
  }
  // Insert a blank page that keeps the window alive if the last real page
  // goes away; OpenBrowserView paints the empty state over it.
  if (strip->count() == 0 || TabIdForWebContents(strip->GetWebContentsAt(0))) {
    content::WebContents::CreateParams params(browser->GetProfile());
    params.initially_hidden = true;
    std::unique_ptr<content::WebContents> blank =
        content::WebContents::Create(params);
    OpenEmptyStateMarker::CreateForWebContents(blank.get());
    base::AutoReset<bool> applying(&applying_, true);
    strip->InsertWebContentsAt(strip->count(), std::move(blank),
                               AddTabTypes::ADD_NONE);
  }
}

// --- Lazy creation -----------------------------------------------------------

std::unique_ptr<content::WebContents> OpenTabBridge::CreateContentsFor(
    const Tab& tab,
    BrowserWindowInterface* browser) {
  content::WebContents::CreateParams params(browser->GetProfile());
  params.initially_hidden = true;
  std::unique_ptr<content::WebContents> contents =
      content::WebContents::Create(params);
  TabHelpers::AttachTabHelpers(contents.get());
  AttachHandle(contents.get(), tab.id);
  if (tab.is_muted) {
    contents->SetAudioMuted(true);
  }
  return contents;
}

void OpenTabBridge::AttachHandle(content::WebContents* contents,
                                 const ItemID& tab_id) {
  // Blocked-request counts for Site Control and automation.
  OpenAdBlockProfileService::EnsureTabHelper(contents);
  OpenTabHandle::CreateForWebContents(contents, tab_id);
  OpenTabHandle* handle = OpenTabHandle::FromWebContents(contents);
  handle->tab_id_ = tab_id;
  handle->observer_ = std::make_unique<OpenTabObserver>(
      weak_factory_.GetWeakPtr(), contents, tab_id);
}

void OpenTabBridge::InsertIntoStrip(
    BrowserWindowInterface* browser,
    std::unique_ptr<content::WebContents> contents,
    const ItemID& tab_id,
    bool activate) {
  base::AutoReset<bool> applying(&applying_, true);
  TabStripModel* strip = browser->GetTabStripModel();
  content::WebContents* raw = contents.get();
  const int index = TargetStripIndex(browser, tab_id);
  int add_types = AddTabTypes::ADD_FORCE_INDEX;
  if (activate) {
    add_types |= AddTabTypes::ADD_ACTIVE;
  }
  strip->InsertWebContentsAt(index, std::move(contents), add_types);
  contents_[tab_id] = raw;

  // Drop the empty-state page now that a real one exists.
  for (int i = strip->count() - 1; i >= 0; --i) {
    if (IsEmptyState(strip->GetWebContentsAt(i)) && strip->count() > 1) {
      strip->DetachAndDeleteWebContentsAt(i);
    }
  }
  PushLiveState(tab_id, raw);
  for (Observer& observer : observers_) {
    observer.OnTabContentsAttached(tab_id, raw);
  }
}

content::WebContents* OpenTabBridge::EnsureLoaded(const ItemID& tab_id) {
  if (auto it = contents_.find(tab_id); it != contents_.end()) {
    return it->second;
  }
  const Tab* tab = service_->model().FindTab(tab_id);
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  if (!tab || !profile) {
    return nullptr;
  }
  BrowserWindowInterface* browser =
      EnsureBrowser(service_->MainWindowId(), *profile);
  if (!browser) {
    return nullptr;
  }
  const GURL url(tab->url);
  std::unique_ptr<content::WebContents> contents =
      CreateContentsFor(*tab, browser);
  content::WebContents* raw = contents.get();
  InsertIntoStrip(browser, std::move(contents), tab_id, /*activate=*/false);
  // Restores the slept tab's OPNH history when the sleep store has one,
  // else loads the tab's URL.
  if (OpenSleepController* sleep = service_->sleep_controller()) {
    sleep->RestoreOrLoad(tab_id, raw, url);
  } else {
    raw->GetController().LoadURLWithParams(
        content::NavigationController::LoadURLParams(url));
  }
  return raw;
}

void OpenTabBridge::UnloadTab(const ItemID& tab_id) {
  auto it = contents_.find(tab_id);
  if (it == contents_.end()) {
    return;
  }
  content::WebContents* wc = it->second;
  BrowserWindowInterface* browser = BrowserForTab(tab_id);
  for (Observer& observer : observers_) {
    observer.OnTabContentsDetaching(tab_id, wc);
  }
  contents_.erase(it);
  model_util::UpdateLive(service_->model(), tab_id, [](TabLiveState& live) {
    live.has_web_content = false;
    live.is_loading = false;
    live.is_audible = false;
    live.sleep_phase = SleepPhase::kSleeping;
  });
  if (!browser) {
    return;
  }
  base::AutoReset<bool> applying(&applying_, true);
  TabStripModel* strip = browser->GetTabStripModel();
  EnsureNonEmpty(browser);
  const int index = strip->GetIndexOfWebContents(wc);
  if (index != TabStripModel::kNoTab) {
    strip->DetachAndDeleteWebContentsAt(index);
  }
}

// --- Commands ----------------------------------------------------------------

ItemID OpenTabBridge::OpenTab(const GURL& url, bool background) {
  BrowserModel& model = service_->model();
  const WindowID window_id = service_->MainWindowId();
  const BrowserWindowState* window = model.FindWindow(window_id);
  if (!window) {
    return ItemID();
  }
  const SpaceID space_id = window->focused_space_id;
  ItemID id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    // Arc placement: the top of Today.
    id = model.NewTab(space_id, url.spec(), std::string(), size_t{0});
    if (id.empty()) {
      return id;
    }
    if (!background) {
      model.SelectNode(window_id, space_id, id);
    }
  }
  if (background) {
    EnsureLoaded(id);
  } else {
    ApplySelectionFromModel(window_id);
  }
  return id;
}

bool OpenTabBridge::SelectNode(const ItemID& node_id) {
  BrowserModel& model = service_->model();
  std::optional<SpaceID> space = model_util::SpaceOfNode(model, node_id);
  const WindowID window_id = service_->MainWindowId();
  const BrowserWindowState* window = model.FindWindow(window_id);
  if (!window || !model.FindNode(node_id)) {
    return false;
  }
  // A Favorite belongs to the Profile; it opens in the focused Space.
  const SpaceID target_space = space.value_or(window->focused_space_id);
  {
    base::AutoReset<bool> applying(&applying_, true);
    if (target_space != window->focused_space_id) {
      model.FocusSpace(window_id, target_space);
    }
    // A split pane selects its Split (BrowserModel::SidebarSelectionId).
    const ItemID select = model.SidebarSelectionId(node_id).value_or(node_id);
    model.SelectNode(window_id, target_space, select);
  }
  ApplySelectionFromModel(window_id);
  return true;
}

bool OpenTabBridge::SelectIndex(size_t index) {
  const BrowserWindowState* window =
      service_->model().FindWindow(service_->MainWindowId());
  if (!window) {
    return false;
  }
  const std::vector<ItemID> ids =
      model_util::OrderedTabIds(service_->model(), window->focused_space_id);
  return index < ids.size() && SelectNode(ids[index]);
}

bool OpenTabBridge::CloseNode(const ItemID& node_id) {
  BrowserModel& model = service_->model();
  if (!model.FindNode(node_id)) {
    return false;
  }
  // Today tabs archive (BrowserModel::ArchiveSink -> ArchiveStore); pinned
  // tabs and Favorites stay in the sidebar and only unload.
  const bool closed = model.CloseTab(node_id);
  if (model.FindNode(node_id)) {
    UnloadTab(node_id);
  }
  return closed;
}

bool OpenTabBridge::TogglePin(const ItemID& tab_id) {
  BrowserModel& model = service_->model();
  return model.IsPinned(tab_id) ? model.UnpinTab(tab_id)
                                : model.PinTab(tab_id);
}

std::optional<ItemID> OpenTabBridge::ToggleSplit(const ItemID& tab_id) {
  BrowserModel& model = service_->model();
  std::optional<NodeParent> parent = model.GetParent(tab_id);
  if (!parent) {
    return std::nullopt;
  }
  if (parent->kind == NodeParentKind::kSplitPane) {
    model.Unsplit(parent->owner_id);
    return std::nullopt;
  }
  std::optional<SpaceID> space = model_util::SpaceOfNode(model, tab_id);
  if (!space) {
    return std::nullopt;
  }
  // Arc: Split View pairs the tab with the next tab below it.
  const std::vector<ItemID> ids = model_util::OrderedTabIds(model, *space);
  auto it = std::find(ids.begin(), ids.end(), tab_id);
  ItemID next;
  for (auto candidate = it == ids.end() ? ids.end() : std::next(it);
       candidate != ids.end(); ++candidate) {
    auto candidate_parent = model.GetParent(*candidate);
    if (candidate_parent &&
        candidate_parent->kind != NodeParentKind::kFavorites &&
        candidate_parent->kind != NodeParentKind::kSplitPane) {
      next = *candidate;
      break;
    }
  }
  if (next.empty()) {
    return std::nullopt;
  }
  const ItemID split =
      model.MakeSplit({tab_id, next}, SplitOrientation::kHorizontal);
  if (split.empty()) {
    return std::nullopt;
  }
  SelectNode(split);
  return split;
}

bool OpenTabBridge::Navigate(const ItemID& tab_id, const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  content::WebContents* wc = EnsureLoaded(tab_id);
  if (!wc) {
    return false;
  }
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  wc->GetController().LoadURLWithParams(params);
  return true;
}

bool OpenTabBridge::GoBack(const ItemID& tab_id) {
  content::WebContents* wc = WebContentsForTab(tab_id);
  if (!wc || !wc->GetController().CanGoBack()) {
    return false;
  }
  wc->GetController().GoBack();
  return true;
}

bool OpenTabBridge::FocusSpace(const SpaceID& space_id) {
  if (!service_->model().FindSpace(space_id)) {
    return false;
  }
  const WindowID window_id = service_->MainWindowId();
  {
    base::AutoReset<bool> applying(&applying_, true);
    service_->model().FocusSpace(window_id, space_id);
  }
  ApplySelectionFromModel(window_id);
  return true;
}

// --- Chromium -> model -------------------------------------------------------

void OpenTabBridge::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  if (applying_ || !started_) {
    return;
  }
  BrowserWindowInterface* browser = nullptr;
  for (auto& [window_id, wb] : windows_) {
    for (auto& [profile_id, candidate] : wb.by_profile) {
      if (candidate->GetTabStripModel() == tab_strip_model) {
        browser = candidate;
      }
    }
  }
  if (!browser) {
    return;
  }

  switch (change.type()) {
    case TabStripModelChange::kInserted:
      for (const auto& inserted : change.GetInsert()->contents) {
        content::WebContents* wc = inserted.contents;
        if (!IsEmptyState(wc) && !TabIdForWebContents(wc)) {
          AdoptChromiumTab(browser, wc, inserted.index);
        }
      }
      break;
    case TabStripModelChange::kRemoved:
      for (const auto& removed : change.GetRemove()->contents) {
        std::optional<ItemID> id = TabIdForWebContents(removed.contents);
        if (!id) {
          continue;
        }
        for (Observer& observer : observers_) {
          observer.OnTabContentsDetaching(*id, removed.contents);
        }
        if (auto it = contents_.find(*id);
            it != contents_.end() && it->second == removed.contents) {
          contents_.erase(it);
        }
        // A window closing (or browser shutdown) keeps the sidebar intact;
        // only a single page closing (window.close(), chrome.tabs.remove,
        // Chromium's own close commands) closes the sidebar item.
        if (removed.remove_reason == TabRemovedReason::kDeleted &&
            !tab_strip_model->closing_all()) {
          OnChromiumClosedTab(removed.contents);
        }
      }
      break;
    case TabStripModelChange::kReplaced: {
      const auto* replace = change.GetReplace();
      if (std::optional<ItemID> id =
              TabIdForWebContents(replace->old_contents)) {
        AttachHandle(replace->new_contents, *id);
        contents_[*id] = replace->new_contents;
        PushLiveState(*id, replace->new_contents);
        for (Observer& observer : observers_) {
          observer.OnTabContentsAttached(*id, replace->new_contents);
        }
      }
      break;
    }
    case TabStripModelChange::kMoved:
      // The sidebar order is canonical; a chrome.tabs.move or drag is put
      // back after the notification (no TabStripModel re-entry).
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](base::WeakPtr<OpenTabBridge> self,
                 BrowserWindowInterface* browser) {
                if (self && self->ProfileOfBrowser(browser)) {
                  self->ResyncBrowser(browser);
                }
              },
              weak_factory_.GetWeakPtr(), base::Unretained(browser)));
      break;
    case TabStripModelChange::kSelectionOnly:
      break;
  }

  if (selection.active_tab_changed() && selection.new_contents) {
    std::optional<ItemID> id = TabIdForWebContents(selection.new_contents);
    std::optional<WindowID> window_id = WindowOfBrowser(browser);
    if (id && window_id) {
      BrowserModel& model = service_->model();
      std::optional<SpaceID> space = model_util::SpaceOfNode(model, *id);
      const BrowserWindowState* window = model.FindWindow(*window_id);
      if (window) {
        const ItemID select = model.SidebarSelectionId(*id).value_or(*id);
        base::AutoReset<bool> applying(&applying_, true);
        const SpaceID target = space.value_or(window->focused_space_id);
        if (target != window->focused_space_id) {
          model.FocusSpace(*window_id, target);
        }
        model.SelectNode(*window_id, target, select);
      }
      for (Observer& observer : observers_) {
        observer.OnTabActivated(*id);
      }
    }
  }
}

void OpenTabBridge::AdoptChromiumTab(BrowserWindowInterface* browser,
                                     content::WebContents* contents,
                                     int index) {
  std::optional<ProfileID> profile = ProfileOfBrowser(browser);
  std::optional<WindowID> window_id = WindowOfBrowser(browser);
  if (!profile || !window_id) {
    return;
  }
  BrowserModel& model = service_->model();
  const BrowserWindowState* window = model.FindWindow(*window_id);
  // The focused Space when it belongs to this Profile, else the Profile's
  // first Space.
  SpaceID space_id;
  if (window) {
    const Space* focused = model.FindSpace(window->focused_space_id);
    if (focused && focused->profile_id == *profile) {
      space_id = focused->id;
    }
  }
  if (space_id.empty()) {
    for (const Space& space : model.spaces()) {
      if (space.profile_id == *profile) {
        space_id = space.id;
        break;
      }
    }
  }
  if (space_id.empty()) {
    return;
  }

  ItemID id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    id = model.NewTab(space_id, contents->GetVisibleURL().spec(),
                      base::UTF16ToUTF8(contents->GetTitle()), size_t{0});
  }
  if (id.empty()) {
    return;
  }
  AttachHandle(contents, id);
  contents_[id] = contents;
  PushLiveState(id, contents);
  for (Observer& observer : observers_) {
    observer.OnTabContentsAttached(id, contents);
  }
  // Move it to its sidebar position once the insert notification is over.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenTabBridge> self,
                        BrowserWindowInterface* browser) {
                       if (self && self->ProfileOfBrowser(browser)) {
                         self->ResyncBrowser(browser);
                       }
                     },
                     weak_factory_.GetWeakPtr(), base::Unretained(browser)));
}

void OpenTabBridge::OnChromiumClosedTab(content::WebContents* contents) {
  std::optional<ItemID> id = TabIdForWebContents(contents);
  if (!id) {
    return;
  }
  base::AutoReset<bool> applying(&applying_, true);
  // Archiving goes through BrowserModel's ArchiveSink.
  service_->model().CloseTab(*id);
}

void OpenTabBridge::OnBrowserCreated(BrowserWindowInterface* browser) {
  if (applying_ || !started_ ||
      browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
      browser->GetProfile()->IsOffTheRecord()) {
    return;
  }
  // A normal window Open did not ask for (Ctrl+N from Chromium code paths,
  // chrome.windows.create, a dragged-out page): its pages join the main
  // window's sidebar; the window itself is kept for the extension that
  // asked for it.
  std::optional<ProfileID> profile =
      service_->OpenProfileIdFor(browser->GetProfile());
  if (!profile) {
    return;
  }
  WindowBrowsers& wb = windows_[service_->MainWindowId()];
  if (!wb.by_profile.contains(*profile)) {
    wb.by_profile[*profile] = browser;
  }
  strip_observations_.AddObservation(browser->GetTabStripModel());
}

void OpenTabBridge::OnBrowserClosed(BrowserWindowInterface* browser) {
  for (auto& [window_id, wb] : windows_) {
    std::erase_if(wb.by_profile, [browser](const auto& entry) {
      return entry.second == browser;
    });
  }
  if (strip_observations_.IsObservingSource(browser->GetTabStripModel())) {
    strip_observations_.RemoveObservation(browser->GetTabStripModel());
  }
}

void OpenTabBridge::OnTabStripModelDestroyed(TabStripModel* tab_strip_model) {
  if (strip_observations_.IsObservingSource(tab_strip_model)) {
    strip_observations_.RemoveObservation(tab_strip_model);
  }
}

// --- Page -> model -----------------------------------------------------------

void OpenTabBridge::OnTabTitleOrUrlChanged(const ItemID& tab_id,
                                           content::WebContents* contents) {
  const GURL& url = contents->GetLastCommittedURL();
  if (url.is_empty()) {
    return;
  }
  service_->model().UpdateTabNavigation(
      tab_id, url.spec(), base::UTF16ToUTF8(contents->GetTitle()));
}

void OpenTabBridge::OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                              content::WebContents* contents,
                                              bool typed) {
  if (!contents->GetBrowserContext()->IsOffTheRecord()) {
    if (std::optional<ProfileID> profile =
            model_util::ProfileOfNode(service_->model(), tab_id)) {
      const GURL& url = contents->GetLastCommittedURL();
      if (url.SchemeIsHTTPOrHTTPS()) {
        service_->RecordVisit(*profile, url.spec(),
                              base::UTF16ToUTF8(contents->GetTitle()), typed);
      }
    }
  }
  for (Observer& observer : observers_) {
    observer.OnTabPrimaryPageCommitted(tab_id, contents);
  }
}

void OpenTabBridge::OnTabDocumentAvailable(const ItemID& tab_id,
                                           content::WebContents* contents) {
  for (Observer& observer : observers_) {
    observer.OnTabDocumentAvailable(tab_id, contents);
  }
}

void OpenTabBridge::PushLiveState(const ItemID& tab_id,
                                  content::WebContents* contents) {
  model_util::UpdateLive(service_->model(), tab_id, [&](TabLiveState& live) {
    live.has_web_content = true;
    live.sleep_phase = SleepPhase::kLive;
    live.is_loading = contents->IsLoading();
    live.progress = contents->GetLoadProgress();
    live.is_audible = contents->IsCurrentlyAudible();
    live.is_crashed = contents->IsCrashed();
    live.can_go_back = contents->GetController().CanGoBack();
    live.can_go_forward = contents->GetController().CanGoForward();
  });
}

// --- Lookups -----------------------------------------------------------------

content::WebContents* OpenTabBridge::WebContentsForTab(
    const ItemID& tab_id) const {
  auto it = contents_.find(tab_id);
  return it == contents_.end() ? nullptr : it->second.get();
}

// static
std::optional<ItemID> OpenTabBridge::TabIdForWebContents(
    content::WebContents* contents) {
  if (!contents) {
    return std::nullopt;
  }
  OpenTabHandle* handle = OpenTabHandle::FromWebContents(contents);
  if (!handle) {
    return std::nullopt;
  }
  return handle->tab_id();
}

BrowserWindowInterface* OpenTabBridge::MainBrowser() const {
  auto it = windows_.find(service_->MainWindowId());
  if (it == windows_.end()) {
    return nullptr;
  }
  for (const auto& [profile_id, browser] : it->second.by_profile) {
    if (browser->GetWindow()->IsVisible()) {
      return browser;
    }
  }
  return it->second.by_profile.empty()
             ? nullptr
             : it->second.by_profile.begin()->second.get();
}

BrowserWindowInterface* OpenTabBridge::BrowserForTab(
    const ItemID& tab_id) const {
  content::WebContents* wc = WebContentsForTab(tab_id);
  if (!wc) {
    return nullptr;
  }
  for (const auto& [window_id, wb] : windows_) {
    for (const auto& [profile_id, browser] : wb.by_profile) {
      if (browser->GetTabStripModel()->GetIndexOfWebContents(wc) !=
          TabStripModel::kNoTab) {
        return browser;
      }
    }
  }
  return nullptr;
}

content::WebContents* OpenTabBridge::ActiveWebContents() const {
  BrowserWindowInterface* browser = MainBrowser();
  if (!browser) {
    return nullptr;
  }
  content::WebContents* wc =
      browser->GetTabStripModel()->GetActiveWebContents();
  return IsEmptyState(wc) ? nullptr : wc;
}

std::optional<ItemID> OpenTabBridge::ActiveTabId() const {
  return TabIdForWebContents(ActiveWebContents());
}

std::vector<std::pair<ItemID, content::WebContents*>>
OpenTabBridge::LoadedTabs() const {
  std::vector<std::pair<ItemID, content::WebContents*>> result;
  result.reserve(contents_.size());
  for (const auto& [id, wc] : contents_) {
    result.emplace_back(id, wc.get());
  }
  return result;
}

std::optional<WindowID> OpenTabBridge::WindowOfBrowser(
    BrowserWindowInterface* browser) const {
  for (const auto& [window_id, wb] : windows_) {
    for (const auto& [profile_id, candidate] : wb.by_profile) {
      if (candidate == browser) {
        return window_id;
      }
    }
  }
  return std::nullopt;
}

std::optional<ProfileID> OpenTabBridge::ProfileOfBrowser(
    BrowserWindowInterface* browser) const {
  for (const auto& [window_id, wb] : windows_) {
    for (const auto& [profile_id, candidate] : wb.by_profile) {
      if (candidate == browser) {
        return profile_id;
      }
    }
  }
  return std::nullopt;
}

}  // namespace open_unified
