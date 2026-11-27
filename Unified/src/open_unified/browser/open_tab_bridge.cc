// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_tab_bridge.h"

#include <algorithm>
#include <set>
#include <utility>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "build/build_config.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/devtools/devtools_window.h"  // nogncheck
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_sleep_controller.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "third_party/blink/public/common/input/web_input_event.h"
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

bool IsChromiumNewTabUrl(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  if (url.SchemeIs("chrome") &&
      base::EqualsCaseInsensitiveASCII(url.host(), "newtab")) {
    return true;
  }
  if (url.SchemeIs("chrome-search") &&
      base::StartsWith(url.host(), "local-ntp",
                       base::CompareCase::INSENSITIVE_ASCII)) {
    return true;
  }
  return false;
}

bool IsWebContentsCapturingMedia(content::WebContents* wc) {
  if (!wc) {
    return false;
  }
  if (wc->IsBeingCaptured()) {
    return true;
  }
  MediaStreamCaptureIndicator* indicator =
      MediaCaptureDevicesDispatcher::GetInstance()
          ->GetMediaStreamCaptureIndicator()
          .get();
  if (!indicator) {
    return false;
  }
  return indicator->IsCapturingUserMedia(wc) ||
         indicator->IsCapturingVideo(wc) || indicator->IsCapturingAudio(wc) ||
         indicator->IsBeingMirrored(wc) || indicator->IsCapturingTab(wc) ||
         indicator->IsCapturingWindow(wc) || indicator->IsCapturingDisplay(wc);
}

bool IsDevToolsOpenForWebContents(content::WebContents* wc) {
  if (!wc) {
    return false;
  }
  if (DevToolsWindow::GetInstanceForInspectedWebContents(wc) != nullptr ||
      content::DevToolsAgentHost::IsDebuggerAttached(wc)) {
    return true;
  }
  scoped_refptr<content::DevToolsAgentHost> agent =
      content::DevToolsAgentHost::GetForTab(wc);
  return agent && DevToolsWindow::FindDevToolsWindow(agent.get()) != nullptr;
}

bool AreNotificationsAllowedForWebContents(content::WebContents* wc) {
  if (!wc) {
    return false;
  }
  const GURL& url = wc->GetLastCommittedURL();
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  HostContentSettingsMap* map =
      HostContentSettingsMapFactory::GetForProfile(wc->GetBrowserContext());
  return map && map->GetContentSetting(url, url,
                                       ContentSettingsType::NOTIFICATIONS) ==
                    CONTENT_SETTING_ALLOW;
}

void AppendNodeTabIds(const std::vector<SidebarNode>& nodes,
                      std::vector<ItemID>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      out->push_back(tab->id);
    } else if (const Folder* folder = node.as_folder()) {
      AppendNodeTabIds(folder->children, out);
    } else if (const Split* split = node.as_split()) {
      for (const Tab& pane : split->panes) {
        out->push_back(pane.id);
      }
    }
  }
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

bool IsBrowserClosing(BrowserWindowInterface* browser) {
  return !browser || !browser->GetTabStripModel() ||
         browser->GetTabStripModel()->closing_all() ||
         browser->IsDeleteScheduled();
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
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (bridge_) {
      bridge_->OnTabVisibilityChanged(tab_id_, web_contents(),
                                      visibility == content::Visibility::VISIBLE);
    }
  }
  void DidGetUserInteraction(const blink::WebInputEvent& event) override {
    const blink::WebInputEvent::Type type = event.GetType();
    if (type != blink::WebInputEvent::Type::kKeyDown &&
        type != blink::WebInputEvent::Type::kRawKeyDown &&
        type != blink::WebInputEvent::Type::kChar) {
      return;
    }
    const TimestampSec now = base::Time::Now().InSecondsFSinceUnixEpoch();
    if (now - last_form_interaction_at_ < 1.0) {
      return;
    }
    last_form_interaction_at_ = now;
    if (bridge_) {
      bridge_->OnTabFormInteraction(tab_id_);
    }
  }
  void WebContentsDestroyed() override { favicon_observation_.Reset(); }

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
    const bool capturing = IsWebContentsCapturingMedia(wc);
    const bool devtools = IsDevToolsOpenForWebContents(wc);
    const bool notifications = AreNotificationsAllowedForWebContents(wc);
    model_util::UpdateLive(service->model(), tab_id_, [&](TabLiveState& live) {
      live.has_web_content = true;
      live.is_loading = wc->IsLoading();
      live.progress = wc->GetLoadProgress();
      live.is_audible = wc->IsCurrentlyAudible();
      live.is_crashed = wc->IsCrashed();
      live.is_capturing_media = capturing;
      live.devtools_open = devtools;
      live.notifications_allowed = notifications;
      live.can_go_back = wc->GetController().CanGoBack();
      live.can_go_forward = wc->GetController().CanGoForward();
      if (!wc->IsLoading()) {
        live.has_loaded_in_this_launch = true;
      }
      if (background) {
        live.page_background_color = ToRGBA(*background);
      }
    });
    if (OpenSleepController* sleep = service->sleep_controller()) {
      sleep->OnTabUnloadHandlersChanged(
          tab_id_, wc->NeedToFireBeforeUnloadOrUnloadEvents());
    }
  }

  base::WeakPtr<OpenTabBridge> bridge_;
  ItemID tab_id_;
  TimestampSec last_form_interaction_at_ = 0.0;
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
// OpenTabBridge::MediaCaptureObserver (kept separate to avoid inheriting from
// base::CheckedObserver twice alongside BrowserCollectionObserver).

class OpenTabBridge::MediaCaptureObserver final
    : public MediaStreamCaptureIndicator::Observer {
 public:
  explicit MediaCaptureObserver(OpenTabBridge* bridge) : bridge_(bridge) {
    if (MediaStreamCaptureIndicator* indicator =
            MediaCaptureDevicesDispatcher::GetInstance()
                ->GetMediaStreamCaptureIndicator()
                .get()) {
      observation_.Observe(indicator);
    }
  }
  ~MediaCaptureObserver() override = default;

  void OnIsCapturingVideoChanged(content::WebContents* web_contents,
                                 bool /*is_capturing_video*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }
  void OnIsCapturingAudioChanged(content::WebContents* web_contents,
                                 bool /*is_capturing_audio*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }
  void OnIsBeingMirroredChanged(content::WebContents* web_contents,
                                bool /*is_being_mirrored*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }
  void OnIsCapturingTabChanged(content::WebContents* web_contents,
                               bool /*is_capturing_tab*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }
  void OnIsCapturingWindowChanged(content::WebContents* web_contents,
                                  bool /*is_capturing_window*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }
  void OnIsCapturingDisplayChanged(content::WebContents* web_contents,
                                   bool /*is_capturing_display*/) override {
    bridge_->OnMediaCaptureChanged(web_contents);
  }

 private:
  raw_ptr<OpenTabBridge> bridge_;
  base::ScopedObservation<MediaStreamCaptureIndicator,
                          MediaStreamCaptureIndicator::Observer>
      observation_{this};
};

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
  media_capture_observer_ = std::make_unique<MediaCaptureObserver>(this);
  content::DevToolsAgentHost::AddObserver(this);
  AdoptStartupBrowsers();
}

void OpenTabBridge::Shutdown() {
  if (!started_) {
    return;
  }
  started_ = false;
  service_->model().RemoveObserver(this);
  browser_collection_observation_.Reset();
  media_capture_observer_.reset();
  content::DevToolsAgentHost::RemoveObserver(this);
  ClearObservedStrips();
  single_profile_closing_browsers_.clear();
  windows_.clear();
  browsers_.clear();
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
  BrowserModel& model = service_->model();
  // Assign each startup Chromium TYPE_NORMAL browser to its own distinct
  // WindowID (binding to saved windows first, creating new ones for extras,
  // and creating ephemeral Incognito windows for OTR startup browsers).
  std::vector<WindowID> unbound_windows;
  for (const BrowserWindowState& window : model.windows()) {
    if (window.style == WindowStyle::kStandard && !window.is_incognito) {
      unbound_windows.push_back(window.id);
    }
  }
  size_t next_unbound = 0;
  std::vector<std::pair<BrowserWindowInterface*, content::WebContents*>>
      startup_tabs;
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* browser) {
        if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
          return true;
        }
        std::optional<ProfileID> profile =
            service_->OpenProfileIdFor(browser->GetProfile());
        if (!profile) {
          return true;
        }
        const bool is_otr = browser->GetProfile()->IsOffTheRecord();
        WindowID assigned_window;
        if (is_otr) {
          base::AutoReset<bool> applying(&applying_, true);
          assigned_window = model.CreateIncognitoWindow(*profile);
        } else if (next_unbound < unbound_windows.size()) {
          assigned_window = unbound_windows[next_unbound++];
        } else {
          SpaceID target_space;
          for (const Space& space : model.spaces()) {
            if (space.profile_id == *profile) {
              target_space = space.id;
              break;
            }
          }
          if (target_space.empty() && !model.spaces().empty()) {
            target_space = model.spaces().front().id;
          }
          if (!target_space.empty()) {
            base::AutoReset<bool> applying(&applying_, true);
            assigned_window = model.CreateWindow(
                target_space, WindowStyle::kStandard, /*register_undo=*/false);
          }
        }
        if (assigned_window.empty()) {
          return true;
        }
        WindowBrowsers& wb = windows_[assigned_window];
        const bool primary = !wb.by_profile.contains(*profile);
        if (primary) {
          wb.by_profile[*profile] = browser;
        }
        TrackBrowser(browser, assigned_window, *profile, primary, is_otr);
        // Chromium's startup tabs (NTP, session restore, command-line URLs)
        // are not Open's; Open's model is the session.
        TabStripModel* strip = browser->GetTabStripModel();
        for (int i = 0; i < strip->count(); ++i) {
          startup_tabs.emplace_back(browser, strip->GetWebContentsAt(i));
        }
        return true;
      });

  // Collect window IDs first because ShowBrowserForSpace / ApplySelection
  // may inspect windows while running.
  std::vector<WindowID> all_windows;
  for (const BrowserWindowState& window : model.windows()) {
    if (window.style == WindowStyle::kStandard) {
      all_windows.push_back(window.id);
    }
  }
  for (const BrowserWindowState& window : model.incognito_windows()) {
    all_windows.push_back(window.id);
  }
  for (const WindowID& window_id : all_windows) {
    if (const BrowserWindowState* window = model.FindWindow(window_id)) {
      ShowBrowserForSpace(window->id, window->focused_space_id);
      ApplySelectionFromModel(window->id);
    }
  }

  // Close ALL Chromium startup tabs (including chrome://newtab when a Space
  // has 0 tabs!) after guaranteeing an OpenEmptyStateMarker page keeps any
  // empty window alive on Open's clean tinted empty Space canvas.
  base::AutoReset<bool> applying(&applying_, true);
  for (auto& [browser, contents] : startup_tabs) {
    if (!browsers_.contains(browser)) {
      continue;
    }
    TabStripModel* strip = browser->GetTabStripModel();
    const int index = strip->GetIndexOfWebContents(contents);
    if (index == TabStripModel::kNoTab || IsEmptyState(contents) ||
        TabIdForWebContents(contents).has_value()) {
      continue;
    }
    if (strip->count() == 1) {
      EnsureEmptyStatePresent(browser);
    }
    const int updated_index = strip->GetIndexOfWebContents(contents);
    if (updated_index != TabStripModel::kNoTab && strip->count() > 1) {
      strip->CloseWebContentsAt(updated_index, TabCloseTypes::CLOSE_NONE);
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
  const bool is_incognito = window && window->is_incognito;
  if (is_incognito) {
    profile = profile->GetPrimaryOTRProfile(/*create_if_needed=*/true);
    if (!profile) {
      return nullptr;
    }
  }
  BrowserWindowCreateParams params(BrowserWindowInterface::TYPE_NORMAL,
                                   *profile, /*from_user_gesture=*/true);
  if (window) {
    params.initial_bounds = gfx::Rect(
        static_cast<int>(window->frame_x), static_cast<int>(window->frame_y),
        static_cast<int>(window->frame_width),
        static_cast<int>(window->frame_height));
  }
  base::AutoReset<bool> applying(&applying_, true);
  BrowserWindowInterface* browser = nullptr;
  {
    base::AutoReset<std::optional<WindowID>> pending_window(
        &pending_window_id_, window_id);
    browser = CreateBrowserWindow(std::move(params));
  }
  if (!browser) {
    return nullptr;
  }
  wb.by_profile[profile_id] = browser;
  TrackBrowser(browser, window_id, profile_id, /*primary=*/true, is_incognito);
  return browser;
}

void OpenTabBridge::TrackBrowser(BrowserWindowInterface* browser,
                                 const WindowID& window_id,
                                 const ProfileID& profile_id,
                                 bool primary,
                                 bool incognito) {
  ManagedBrowser& managed = browsers_[browser];
  managed.window = window_id;
  managed.profile = profile_id;
  managed.primary = managed.primary || primary;
  managed.incognito = managed.incognito || incognito;
  AddObservedStrip(browser->GetTabStripModel());
  for (Observer& observer : observers_) {
    observer.OnBrowserWindowBound(browser, window_id);
  }
}

void OpenTabBridge::ScrubNewTabPagesLater(BrowserWindowInterface* browser) {
  if (IsBrowserClosing(browser)) {
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<OpenTabBridge> self,
             base::WeakPtr<BrowserWindowInterface> browser) {
            if (!self || !browser || IsBrowserClosing(browser.get()) ||
                !self->browsers_.contains(browser.get())) {
              return;
            }
            TabStripModel* strip = browser->GetTabStripModel();
            base::AutoReset<bool> applying(&self->applying_, true);
            std::vector<content::WebContents*> ntps;
            for (int i = 0; i < strip->count(); ++i) {
              content::WebContents* wc = strip->GetWebContentsAt(i);
              if (!IsEmptyState(wc) && !TabIdForWebContents(wc).has_value() &&
                  (IsChromiumNewTabUrl(wc->GetVisibleURL()) ||
                   IsChromiumNewTabUrl(wc->GetLastCommittedURL()))) {
                ntps.push_back(wc);
              }
            }
            for (content::WebContents* wc : ntps) {
              if (strip->count() == 1) {
                self->EnsureEmptyStatePresent(browser.get());
              }
              const int idx = strip->GetIndexOfWebContents(wc);
              if (idx != TabStripModel::kNoTab && strip->count() > 1) {
                strip->CloseWebContentsAt(idx, TabCloseTypes::CLOSE_NONE);
              }
            }
          },
          weak_factory_.GetWeakPtr(), browser->GetWeakPtr()));
}

void OpenTabBridge::ResyncBrowserLater(BrowserWindowInterface* browser) {
  if (IsBrowserClosing(browser)) {
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<OpenTabBridge> self,
             base::WeakPtr<BrowserWindowInterface> browser) {
            if (self && browser && !IsBrowserClosing(browser.get()) &&
                self->ProfileOfBrowser(browser.get())) {
              self->ResyncBrowser(browser.get());
            }
          },
          weak_factory_.GetWeakPtr(), browser->GetWeakPtr()));
}

void OpenTabBridge::ForgetContents(const ItemID& tab_id,
                                   content::WebContents* contents) {
  auto it = contents_.find(tab_id);
  if (it == contents_.end() || it->second != contents) {
    return;  // Already forgotten, or the tab is backed by another page.
  }
  for (Observer& observer : observers_) {
    observer.OnTabContentsDetaching(tab_id, contents);
  }
  contents_.erase(tab_id);
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
    BrowserWindowInterface* browser = BrowserForWindow(window.id);
    if (!browser || IsBrowserClosing(browser)) {
      continue;
    }
    ApplySelectionFromModel(window.id);
  }
  for (const BrowserWindowState& window :
       service_->model().incognito_windows()) {
    BrowserWindowInterface* browser = BrowserForWindow(window.id);
    if (!browser || IsBrowserClosing(browser)) {
      continue;
    }
    ApplySelectionFromModel(window.id);
  }
}

void OpenTabBridge::ResyncAll() {
  std::vector<BrowserWindowInterface*> browsers;
  for (const auto& [browser, managed] : browsers_) {
    browsers.push_back(browser);
  }
  for (BrowserWindowInterface* browser : browsers) {
    if (browsers_.contains(browser)) {
      ResyncBrowser(browser);
    }
  }
}

std::vector<ItemID> OpenTabBridge::StripOrderFor(
    BrowserWindowInterface* browser) const {
  auto it = browsers_.find(browser);
  if (it == browsers_.end()) {
    return {};
  }
  if (it->second.incognito) {
    std::vector<ItemID> order;
    if (const BrowserWindowState* window =
            service_->model().FindWindow(it->second.window)) {
      if (const Space* space =
              service_->model().FindSpace(window->focused_space_id)) {
        AppendNodeTabIds(space->pinned, &order);
        AppendNodeTabIds(space->today, &order);
      }
    }
    return order;
  }
  return StripOrderFor(it->second.profile);
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
  if (IsBrowserClosing(browser)) {
    return;
  }
  auto managed = browsers_.find(browser);
  if (managed == browsers_.end()) {
    return;
  }
  const bool primary = managed->second.primary;
  base::AutoReset<bool> applying(&applying_, true);
  TabStripModel* strip = browser->GetTabStripModel();
  const std::vector<ItemID> order = StripOrderFor(browser);
  const std::set<ItemID> wanted(order.begin(), order.end());

  // 1. Close pages whose sidebar item is gone. The tab stays tracked until
  // TabStripModel reports the removal (kRemoved, handled even while
  // |applying_|): a beforeunload handler may delay or cancel the close.
  // Only the primary Browser keeps its window alive with an empty-state
  // page; another window of the Profile closes with its last page.
  if (primary) {
    EnsureNonEmpty(browser);
  }
  std::vector<content::WebContents*> doomed;
  for (int i = strip->count() - 1; i >= 0; --i) {
    content::WebContents* wc = strip->GetWebContentsAt(i);
    std::optional<ItemID> id = TabIdForWebContents(wc);
    if (id && !wanted.contains(*id)) {
      doomed.push_back(wc);
    }
  }
  for (content::WebContents* wc : doomed) {
    const int index = strip->GetIndexOfWebContents(wc);
    if (index == TabStripModel::kNoTab) {
      continue;
    }
    if (primary && strip->count() == 1) {
      EnsureNonEmpty(browser);
    }
    strip->CloseWebContentsAt(strip->GetIndexOfWebContents(wc),
                              TabCloseTypes::CLOSE_NONE);
  }
  if (!primary) {
    return;  // Extra windows keep Chromium's order.
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
  const TabStripModel* strip = browser->GetTabStripModel();
  int index = 0;
  for (const ItemID& id : StripOrderFor(browser)) {
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
  const std::optional<ItemID> previous_active = ActiveTabIdForWindow(window_id);
  ShowBrowserForSpace(window_id, window->focused_space_id);
  auto selected = window->selected_node_by_space.find(window->focused_space_id);
  if (selected == window->selected_node_by_space.end()) {
    // Empty Space state: ensure the window displays Open's clean tinted empty
    // Space canvas (never chrome://newtab or a stale tab from another Space).
    if (BrowserWindowInterface* browser = BrowserForWindow(window_id)) {
      EnsureEmptyStatePresent(browser);
      TabStripModel* strip = browser->GetTabStripModel();
      for (int i = 0; i < strip->count(); ++i) {
        if (IsEmptyState(strip->GetWebContentsAt(i))) {
          if (strip->active_index() != i) {
            base::AutoReset<bool> applying(&applying_, true);
            strip->ActivateTabAt(i);
          }
          break;
        }
      }
    }
    if (previous_active) {
      if (OpenSleepController* sleep = service_->sleep_controller()) {
        sleep->OnTabHidden(*previous_active);
      }
    }
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
      EnsureLoaded(pane.id, window_id);
    }
    to_activate = split->focused_pane_id.value_or(
        split->panes.empty() ? ItemID() : split->panes.front().id);
  } else if (const Folder* folder = node->as_folder()) {
    to_activate = folder->peeked_child_id.value_or(ItemID());
  }
  if (to_activate.empty()) {
    return;
  }
  content::WebContents* wc = EnsureLoaded(to_activate, window_id);
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
  if (wc->GetController().NeedsReload()) {
    wc->GetController().LoadIfNecessary();
  }
  if (previous_active && *previous_active != to_activate) {
    if (OpenSleepController* sleep = service_->sleep_controller()) {
      sleep->OnTabHidden(*previous_active);
    }
  }
  for (Observer& observer : observers_) {
    observer.OnTabActivated(to_activate);
  }
}

void OpenTabBridge::EnsureEmptyStatePresent(BrowserWindowInterface* browser) {
  if (IsBrowserClosing(browser)) {
    return;
  }
  TabStripModel* strip = browser->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    if (IsEmptyState(strip->GetWebContentsAt(i))) {
      return;
    }
  }
  content::WebContents::CreateParams params(browser->GetProfile());
  params.initially_hidden = true;
  std::unique_ptr<content::WebContents> blank =
      content::WebContents::Create(params);
  OpenEmptyStateMarker::CreateForWebContents(blank.get());
  base::AutoReset<bool> applying(&applying_, true);
  strip->InsertWebContentsAt(strip->count(), std::move(blank),
                             AddTabTypes::ADD_NONE);
}

void OpenTabBridge::EnsureNonEmpty(BrowserWindowInterface* browser) {
  if (IsBrowserClosing(browser)) {
    return;
  }
  TabStripModel* strip = browser->GetTabStripModel();
  if (strip->count() > 1) {
    return;
  }
  if (strip->count() == 1 && IsEmptyState(strip->GetWebContentsAt(0))) {
    return;
  }
  // Insert a blank page that keeps the window alive if the last real page
  // goes away; OpenBrowserView paints the empty state over it.
  EnsureEmptyStatePresent(browser);
}

// --- Lazy creation -----------------------------------------------------------

std::unique_ptr<content::WebContents> OpenTabBridge::CreateContentsFor(
    const Tab& tab,
    BrowserWindowInterface* browser) {
  content::WebContents::CreateParams params(browser->GetProfile());
  params.initially_hidden = true;
  std::unique_ptr<content::WebContents> contents =
      content::WebContents::Create(params);
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

WindowID OpenTabBridge::ResolveTargetWindowForTab(
    const ItemID& tab_id,
    const WindowID& preferred) const {
  const BrowserModel& model = service_->model();
  if (model.IsIncognitoNode(tab_id)) {
    std::optional<SpaceID> space = model_util::SpaceOfNode(model, tab_id);
    if (space) {
      for (const BrowserWindowState& w : model.incognito_windows()) {
        if (w.focused_space_id == *space) {
          return w.id;
        }
      }
    }
  }
  if (!preferred.empty() && model.FindWindow(preferred) &&
      !model.IsIncognitoWindow(preferred)) {
    return preferred;
  }
  if (std::optional<SpaceID> space = model_util::SpaceOfNode(model, tab_id)) {
    const WindowID focused = FocusedWindowId();
    if (const BrowserWindowState* fw = model.FindWindow(focused);
        fw && !fw->is_incognito && fw->focused_space_id == *space) {
      return fw->id;
    }
    for (const BrowserWindowState& w : model.windows()) {
      if (w.focused_space_id == *space) {
        return w.id;
      }
    }
  }
  return FocusedWindowId();
}

content::WebContents* OpenTabBridge::EnsureLoaded(const ItemID& tab_id) {
  return EnsureLoaded(tab_id, WindowID());
}

content::WebContents* OpenTabBridge::EnsureLoaded(
    const ItemID& tab_id,
    const WindowID& preferred_window_id) {
  if (auto it = contents_.find(tab_id); it != contents_.end()) {
    if (it->second && it->second->GetController().NeedsReload()) {
      it->second->GetController().LoadIfNecessary();
    }
    return it->second;
  }
  const Tab* tab = service_->model().FindTab(tab_id);
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  if (!tab || !profile) {
    return nullptr;
  }
  const WindowID target_window =
      ResolveTargetWindowForTab(tab_id, preferred_window_id);
  BrowserWindowInterface* browser = EnsureBrowser(target_window, *profile);
  if (!browser) {
    return nullptr;
  }
  const GURL url(tab->url);
  std::unique_ptr<content::WebContents> contents =
      CreateContentsFor(*tab, browser);
  content::WebContents* raw = contents.get();
  InsertIntoStrip(browser, std::move(contents), tab_id, /*activate=*/false);
  // Restores the slept tab's OPNH history when the sleep store has one,
  // else loads the tab's URL (never for Incognito).
  if (!browser->GetProfile()->IsOffTheRecord()) {
    if (OpenSleepController* sleep = service_->sleep_controller()) {
      sleep->RestoreOrLoad(tab_id, raw, url);
      return raw;
    }
  }
  if (url.is_valid()) {
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
  if (browser) {
    base::AutoReset<bool> applying(&applying_, true);
    TabStripModel* strip = browser->GetTabStripModel();
    if (browsers_[browser].primary) {
      EnsureNonEmpty(browser);
    }
    const int index = strip->GetIndexOfWebContents(wc);
    if (index != TabStripModel::kNoTab) {
      // kRemoved (handled while |applying_|) forgets the page.
      strip->DetachAndDeleteWebContentsAt(index);
    }
  }
  ForgetContents(tab_id, wc);  // No-op when kRemoved already did it.
  model_util::UpdateLive(service_->model(), tab_id, [](TabLiveState& live) {
    live.has_web_content = false;
    live.is_loading = false;
    live.is_audible = false;
    live.sleep_phase = SleepPhase::kSleeping;
  });
}

// --- Commands ----------------------------------------------------------------

ItemID OpenTabBridge::OpenTab(const GURL& url, bool background) {
  return OpenTab(url, background, FocusedWindowId());
}

ItemID OpenTabBridge::OpenTab(const GURL& url,
                              bool background,
                              const WindowID& window_id) {
  BrowserModel& model = service_->model();
  const WindowID target_window =
      window_id.empty() ? FocusedWindowId() : window_id;
  const BrowserWindowState* window = model.FindWindow(target_window);
  if (!window) {
    return ItemID();
  }
  return OpenTabInSpace(url, window->focused_space_id, background,
                        target_window);
}

ItemID OpenTabBridge::OpenTabInSpace(const GURL& url,
                                     const SpaceID& space_id,
                                     bool background,
                                     const std::optional<WindowID>& window_id) {
  BrowserModel& model = service_->model();
  if (!model.FindSpace(space_id)) {
    return ItemID();
  }
  WindowID target_window = window_id.value_or(WindowID());
  if (target_window.empty()) {
    if (model.IsIncognitoSpace(space_id)) {
      for (const BrowserWindowState& w : model.incognito_windows()) {
        if (w.focused_space_id == space_id) {
          target_window = w.id;
          break;
        }
      }
    } else {
      const WindowID focused = FocusedWindowId();
      if (const BrowserWindowState* fw = model.FindWindow(focused);
          fw && !fw->is_incognito) {
        target_window = fw->id;
      } else {
        target_window = service_->MainWindowId();
      }
    }
  }
  const BrowserWindowState* window = model.FindWindow(target_window);
  if (!window) {
    return ItemID();
  }
  ItemID id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    // Arc placement: the top of Today.
    id = model.NewTab(space_id, url.spec(), std::string(), size_t{0});
    if (id.empty()) {
      return id;
    }
    if (!background) {
      if (window->focused_space_id != space_id && !window->is_incognito) {
        model.FocusSpace(target_window, space_id);
      }
      model.SelectNode(target_window, space_id, id);
    }
  }
  if (background) {
    EnsureLoaded(id, target_window);
  } else {
    ApplySelectionFromModel(target_window);
  }
  return id;
}

bool OpenTabBridge::SelectNode(const ItemID& node_id) {
  return SelectNode(node_id, FocusedWindowId());
}

bool OpenTabBridge::SelectNode(const ItemID& node_id,
                               const WindowID& window_id) {
  BrowserModel& model = service_->model();
  std::optional<SpaceID> space = model_util::SpaceOfNode(model, node_id);
  const WindowID target_window =
      window_id.empty() ? ResolveTargetWindowForTab(node_id, WindowID())
                        : window_id;
  const BrowserWindowState* window = model.FindWindow(target_window);
  if (!window || !model.FindNode(node_id)) {
    return false;
  }
  // A Favorite belongs to the Profile; it opens in the focused Space.
  const SpaceID target_space = space.value_or(window->focused_space_id);
  {
    base::AutoReset<bool> applying(&applying_, true);
    if (target_space != window->focused_space_id) {
      model.FocusSpace(target_window, target_space);
    }
    // A split pane selects its Split (BrowserModel::SidebarSelectionId).
    const ItemID select = model.SidebarSelectionId(node_id).value_or(node_id);
    model.SelectNode(target_window, target_space, select);
  }
  ApplySelectionFromModel(target_window);
  return true;
}

bool OpenTabBridge::SelectIndex(size_t index) {
  return SelectIndex(index, FocusedWindowId());
}

bool OpenTabBridge::SelectIndex(size_t index, const WindowID& window_id) {
  const WindowID target_window =
      window_id.empty() ? FocusedWindowId() : window_id;
  const BrowserWindowState* window =
      service_->model().FindWindow(target_window);
  if (!window) {
    return false;
  }
  std::vector<ItemID> ids;
  if (window->is_incognito) {
    if (const Space* space =
            service_->model().FindSpace(window->focused_space_id)) {
      AppendNodeTabIds(space->pinned, &ids);
      AppendNodeTabIds(space->today, &ids);
    }
  } else {
    ids = model_util::OrderedTabIds(service_->model(),
                                    window->focused_space_id);
  }
  return index < ids.size() && SelectNode(ids[index], target_window);
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
  return FocusSpace(space_id, FocusedWindowId());
}

bool OpenTabBridge::FocusSpace(const SpaceID& space_id,
                               const WindowID& window_id) {
  if (!service_->model().FindSpace(space_id)) {
    return false;
  }
  WindowID target_window = window_id.empty() ? FocusedWindowId() : window_id;
  if (service_->model().IsIncognitoWindow(target_window) &&
      !service_->model().IsIncognitoSpace(space_id)) {
    target_window = service_->MainWindowId();
  }
  {
    base::AutoReset<bool> applying(&applying_, true);
    if (!service_->model().FocusSpace(target_window, space_id)) {
      return false;
    }
  }
  ApplySelectionFromModel(target_window);
  return true;
}

WindowID OpenTabBridge::OpenNewWindow(const std::optional<SpaceID>& space_id) {
  BrowserModel& model = service_->model();
  SpaceID target_space = space_id.value_or(SpaceID());
  if (target_space.empty() || !model.FindSpace(target_space) ||
      model.IsIncognitoSpace(target_space)) {
    const BrowserWindowState* focused = model.FindWindow(FocusedWindowId());
    if (focused && !focused->is_incognito &&
        model.FindSpace(focused->focused_space_id)) {
      target_space = focused->focused_space_id;
    } else if (!model.spaces().empty()) {
      target_space = model.spaces().front().id;
    }
  }
  if (target_space.empty()) {
    return WindowID();
  }
  WindowID window_id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    window_id = model.CreateWindow(target_space, WindowStyle::kStandard,
                                   /*register_undo=*/false);
  }
  if (window_id.empty()) {
    return WindowID();
  }
  ShowBrowserForSpace(window_id, target_space);
  ApplySelectionFromModel(window_id);
  return window_id;
}

WindowID OpenTabBridge::OpenNewIncognitoWindow(
    const std::optional<ProfileID>& parent_profile_id,
    const std::optional<GURL>& initial_url) {
  BrowserModel& model = service_->model();
  ProfileID parent_id = parent_profile_id.value_or(ProfileID());
  if (parent_id.empty() || !model.FindProfile(parent_id)) {
    parent_id = service_->ActiveProfileId();
  }
  if (parent_id.empty() || !model.FindProfile(parent_id)) {
    return WindowID();
  }
  WindowID window_id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    window_id = model.CreateIncognitoWindow(parent_id);
  }
  if (window_id.empty()) {
    return WindowID();
  }
  const BrowserWindowState* window = model.FindWindow(window_id);
  if (!window) {
    return WindowID();
  }
  ShowBrowserForSpace(window_id, window->focused_space_id);
  if (initial_url && initial_url->is_valid()) {
    OpenTab(*initial_url, /*background=*/false, window_id);
  } else {
    ApplySelectionFromModel(window_id);
  }
  return window_id;
}

ItemID OpenTabBridge::AdoptLiveWebContentsAsTab(
    std::unique_ptr<content::WebContents> contents,
    const SpaceID& space_id,
    bool background,
    const std::optional<WindowID>& window_id,
    std::optional<size_t> position) {
  if (!contents) {
    return ItemID();
  }
  BrowserModel& model = service_->model();
  const Space* space = model.FindSpace(space_id);
  if (!space) {
    return ItemID();
  }
  WindowID target_window = window_id.value_or(WindowID());
  if (target_window.empty()) {
    if (model.IsIncognitoSpace(space_id)) {
      for (const BrowserWindowState& w : model.incognito_windows()) {
        if (w.focused_space_id == space_id) {
          target_window = w.id;
          break;
        }
      }
    } else {
      const WindowID focused = FocusedWindowId();
      if (const BrowserWindowState* fw = model.FindWindow(focused);
          fw && !fw->is_incognito) {
        target_window = fw->id;
      } else {
        target_window = service_->MainWindowId();
      }
    }
  }
  BrowserWindowInterface* browser =
      EnsureBrowser(target_window, space->profile_id);
  if (!browser) {
    return ItemID();
  }

  // Chromium requires a WebContents inserted into a TabStripModel to belong to
  // the exact same BrowserContext (Profile + OTR status). If the live page
  // came from a different Profile or OTR boundary, fall back to opening its
  // URL cleanly in the target Space instead of crashing.
  if (contents->GetBrowserContext() != browser->GetProfile()) {
    const GURL fallback_url = contents->GetLastCommittedURL().is_valid()
                                  ? contents->GetLastCommittedURL()
                                  : contents->GetVisibleURL();
    return fallback_url.is_valid()
               ? OpenTabInSpace(fallback_url, space_id, background,
                                target_window)
               : ItemID();
  }

  const GURL url = contents->GetLastCommittedURL().is_valid()
                       ? contents->GetLastCommittedURL()
                       : contents->GetVisibleURL();
  const std::string title = base::UTF16ToUTF8(contents->GetTitle());

  ItemID id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    id = model.NewTab(space_id, url.is_valid() ? url.spec() : "about:blank",
                      title, position.value_or(size_t{0}));
    if (id.empty()) {
      return ItemID();
    }
    if (!background) {
      if (const BrowserWindowState* w = model.FindWindow(target_window);
          w && w->focused_space_id != space_id && !w->is_incognito) {
        model.FocusSpace(target_window, space_id);
      }
      model.SelectNode(target_window, space_id, id);
    }
  }

  // Detach from any previous overlay/Little Open delegate so Browser adopts it.
  contents->SetDelegate(nullptr);
  content::WebContents* raw = contents.get();
  AttachHandle(raw, id);
  InsertIntoStrip(browser, std::move(contents), id, /*activate=*/!background);
  if (!background) {
    ShowBrowserForSpace(target_window, space_id);
    ApplySelectionFromModel(target_window);
  }
  return id;
}

std::unique_ptr<content::WebContents> OpenTabBridge::DetachWebContentsForTransfer(
    const ItemID& tab_id,
    bool remove_from_model) {
  auto it = contents_.find(tab_id);
  if (it == contents_.end()) {
    return nullptr;
  }
  content::WebContents* wc = it->second;
  BrowserWindowInterface* browser = BrowserForTab(tab_id);
  if (!browser) {
    return nullptr;
  }
  std::unique_ptr<content::WebContents> detached;
  {
    base::AutoReset<bool> applying(&applying_, true);
    TabStripModel* strip = browser->GetTabStripModel();
    if (browsers_[browser].primary && strip->count() == 1) {
      EnsureEmptyStatePresent(browser);
    }
    const int index = strip->GetIndexOfWebContents(wc);
    if (index == TabStripModel::kNoTab) {
      return nullptr;
    }
    detached = strip->DetachWebContentsAtForInsertion(
        index, TabRemovedReason::kInsertedIntoOtherTabStrip);
  }
  ForgetContents(tab_id, wc);
  if (detached) {
    detached->RemoveUserData(OpenTabHandle::UserDataKey());
  }
  if (remove_from_model) {
    base::AutoReset<bool> applying(&applying_, true);
    service_->model().CloseTab(tab_id);
  } else {
    model_util::UpdateLive(service_->model(), tab_id, [](TabLiveState& live) {
      live.has_web_content = false;
      live.is_loading = false;
      live.is_audible = false;
    });
  }
  return detached;
}

void OpenTabBridge::CloseBrowsersForProfile(const ProfileID& profile_id) {
  std::vector<BrowserWindowInterface*> targets;
  for (const auto& [browser, managed] : browsers_) {
    if (managed.profile == profile_id) {
      targets.push_back(browser);
    }
  }
  for (BrowserWindowInterface* browser : targets) {
    if (browsers_.contains(browser) && browser->GetWindow()) {
      single_profile_closing_browsers_.insert(browser);
      browser->GetWindow()->Close();
    }
  }
}

void OpenTabBridge::UpdateTabProtectionState(const ItemID& tab_id,
                                             content::WebContents* contents) {
  if (!contents || !service_) {
    return;
  }
  const bool capturing = IsWebContentsCapturingMedia(contents);
  const bool devtools = IsDevToolsOpenForWebContents(contents);
  const bool notifications = AreNotificationsAllowedForWebContents(contents);
  const Tab* tab = service_->model().FindTab(tab_id);
  if (tab && (tab->live_state.is_capturing_media != capturing ||
              tab->live_state.devtools_open != devtools ||
              tab->live_state.notifications_allowed != notifications)) {
    model_util::UpdateLive(service_->model(), tab_id, [&](TabLiveState& live) {
      live.is_capturing_media = capturing;
      live.devtools_open = devtools;
      live.notifications_allowed = notifications;
    });
  }
  if (OpenSleepController* sleep = service_->sleep_controller()) {
    sleep->OnTabUnloadHandlersChanged(
        tab_id, contents->NeedToFireBeforeUnloadOrUnloadEvents());
  }
}

void OpenTabBridge::RefreshProtectionStates() {
  for (const auto& [tab_id, wc] : contents_) {
    if (wc) {
      UpdateTabProtectionState(tab_id, wc.get());
    }
  }
}

void OpenTabBridge::OnTabVisibilityChanged(const ItemID& tab_id,
                                           content::WebContents* contents,
                                           bool visible) {
  if (!started_ || !service_) {
    return;
  }
  UpdateTabProtectionState(tab_id, contents);
  if (!visible) {
    if (OpenSleepController* sleep = service_->sleep_controller()) {
      sleep->OnTabHidden(tab_id);
    }
  }
}

void OpenTabBridge::OnTabFormInteraction(const ItemID& tab_id) {
  if (!started_ || !service_) {
    return;
  }
  const TimestampSec now = base::Time::Now().InSecondsFSinceUnixEpoch();
  model_util::UpdateLive(service_->model(), tab_id, [now](TabLiveState& live) {
    live.last_form_interaction_at = now;
  });
}

void OpenTabBridge::OnMediaCaptureChanged(content::WebContents* web_contents) {
  if (!started_ || !web_contents) {
    return;
  }
  if (std::optional<ItemID> id = TabIdForWebContents(web_contents)) {
    UpdateTabProtectionState(*id, web_contents);
  }
}

void OpenTabBridge::DevToolsAgentHostAttached(
    content::DevToolsAgentHost* agent_host) {
  if (!started_ || !agent_host) {
    return;
  }
  content::WebContents* wc = agent_host->GetWebContents();
  if (std::optional<ItemID> id = TabIdForWebContents(wc)) {
    UpdateTabProtectionState(*id, wc);
  }
}

void OpenTabBridge::DevToolsAgentHostDetached(
    content::DevToolsAgentHost* agent_host) {
  if (!started_ || !agent_host) {
    return;
  }
  content::WebContents* wc = agent_host->GetWebContents();
  if (std::optional<ItemID> id = TabIdForWebContents(wc)) {
    UpdateTabProtectionState(*id, wc);
  }
}

// --- Chromium -> model -------------------------------------------------------

void OpenTabBridge::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  if (!started_) {
    return;
  }
  BrowserWindowInterface* browser = nullptr;
  for (const auto& [candidate, managed] : browsers_) {
    if (candidate->GetTabStripModel() == tab_strip_model) {
      browser = candidate;
      break;
    }
  }
  if (!browser) {
    return;
  }

  // Tracking (contents_, OnTabContentsDetaching/Attached) follows every
  // removal and replacement, also the bridge's own (|applying_|); only
  // model mutations are suppressed while the bridge applies the model.
  switch (change.type()) {
    case TabStripModelChange::kInserted:
      if (applying_) {
        break;
      }
      for (const auto& inserted : change.GetInsert()->contents) {
        content::WebContents* wc = inserted.contents;
        if (IsEmptyState(wc) || TabIdForWebContents(wc)) {
          continue;
        }
        // Never adopt Chromium's raw chrome://newtab page into Open's sidebar;
        // scrub it so empty Spaces render Open's tinted empty Space canvas.
        if (IsChromiumNewTabUrl(wc->GetVisibleURL()) ||
            IsChromiumNewTabUrl(wc->GetLastCommittedURL())) {
          ScrubNewTabPagesLater(browser);
          continue;
        }
        AdoptChromiumTab(browser, wc, inserted.index);
      }
      break;
    case TabStripModelChange::kRemoved:
      for (const auto& removed : change.GetRemove()->contents) {
        std::optional<ItemID> id = TabIdForWebContents(removed.contents);
        if (!id) {
          continue;
        }
        ForgetContents(*id, removed.contents);
        // A window closing (or browser shutdown) keeps the sidebar intact;
        // only a single page closing (window.close(), chrome.tabs.remove,
        // Chromium's own close commands) closes the sidebar item.
        if (!applying_ &&
            removed.remove_reason == TabRemovedReason::kDeleted &&
            !tab_strip_model->closing_all()) {
          OnChromiumClosedTab(removed.contents);
        }
      }
      break;
    case TabStripModelChange::kReplaced: {
      const auto* replace = change.GetReplace();
      if (std::optional<ItemID> id =
              TabIdForWebContents(replace->old_contents)) {
        for (Observer& observer : observers_) {
          observer.OnTabContentsDetaching(*id, replace->old_contents);
        }
        replace->old_contents->RemoveUserData(OpenTabHandle::UserDataKey());
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
      if (!applying_) {
        ResyncBrowserLater(browser);
      }
      break;
    case TabStripModelChange::kSelectionOnly:
      break;
  }

  if (applying_) {
    return;
  }
  if (selection.active_tab_changed()) {
    std::optional<ItemID> old_id = TabIdForWebContents(selection.old_contents);
    std::optional<ItemID> new_id = TabIdForWebContents(selection.new_contents);
    if (old_id && old_id != new_id) {
      if (OpenSleepController* sleep = service_->sleep_controller()) {
        sleep->OnTabHidden(*old_id);
      }
    }
  }
  if (selection.active_tab_changed() && selection.new_contents) {
    std::optional<ItemID> id = TabIdForWebContents(selection.new_contents);
    std::optional<WindowID> window_id = WindowOfBrowser(browser);
    if (id && window_id) {
      BrowserModel& model = service_->model();
      model.TouchWindowFocus(*window_id);
      std::optional<SpaceID> space = model_util::SpaceOfNode(model, *id);
      const BrowserWindowState* window = model.FindWindow(*window_id);
      if (window) {
        const ItemID select = model.SidebarSelectionId(*id).value_or(*id);
        base::AutoReset<bool> applying(&applying_, true);
        const SpaceID target = space.value_or(window->focused_space_id);
        if (target != window->focused_space_id && !window->is_incognito) {
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
  ResyncBrowserLater(browser);
}

void OpenTabBridge::OnChromiumClosedTab(content::WebContents* contents) {
  std::optional<ItemID> id = TabIdForWebContents(contents);
  if (!id) {
    return;
  }
  base::AutoReset<bool> applying(&applying_, true);
  // Archiving goes through BrowserModel's ArchiveSink.
  service_->model().CloseTab(*id);
  // Pinned tabs and Favorites stay in the sidebar without a page: reset
  // their live state so the row shows them unloaded (as UnloadTab()).
  if (service_->model().FindNode(*id)) {
    model_util::UpdateLive(service_->model(), *id, [](TabLiveState& live) {
      live.has_web_content = false;
      live.is_loading = false;
      live.is_audible = false;
      live.sleep_phase = SleepPhase::kSleeping;
    });
  }
}

void OpenTabBridge::OnBrowserCreated(BrowserWindowInterface* browser) {
  if (applying_ || !started_ ||
      browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
      browsers_.contains(browser)) {
    return;
  }
  // Every TYPE_NORMAL Chromium Browser (including Off-The-Record / Incognito)
  // gets its own distinct WindowID in BrowserModel.
  std::optional<ProfileID> profile =
      service_->OpenProfileIdFor(browser->GetProfile());
  if (!profile) {
    return;
  }
  BrowserModel& model = service_->model();
  const bool is_otr = browser->GetProfile()->IsOffTheRecord();
  WindowID window_id;
  {
    base::AutoReset<bool> applying(&applying_, true);
    if (is_otr) {
      window_id = model.CreateIncognitoWindow(*profile);
    } else {
      SpaceID target_space;
      if (const BrowserWindowState* focused =
              model.FindWindow(FocusedWindowId());
          focused && !focused->is_incognito) {
        if (const Space* sp = model.FindSpace(focused->focused_space_id);
            sp && sp->profile_id == *profile) {
          target_space = sp->id;
        }
      }
      if (target_space.empty()) {
        for (const Space& space : model.spaces()) {
          if (space.profile_id == *profile) {
            target_space = space.id;
            break;
          }
        }
      }
      if (target_space.empty() && !model.spaces().empty()) {
        target_space = model.spaces().front().id;
      }
      if (!target_space.empty()) {
        window_id = model.CreateWindow(target_space, WindowStyle::kStandard,
                                       /*register_undo=*/false);
      }
    }
  }
  if (window_id.empty()) {
    return;
  }
  WindowBrowsers& wb = windows_[window_id];
  wb.by_profile[*profile] = browser;
  TrackBrowser(browser, window_id, *profile, /*primary=*/true, is_otr);

  // Adopt any real URL already in the strip; scrub raw chrome://newtab so a
  // fresh OS window opens on Open's clean empty Space canvas.
  TabStripModel* strip = browser->GetTabStripModel();
  bool has_ntp = false;
  for (int i = 0; i < strip->count(); ++i) {
    content::WebContents* wc = strip->GetWebContentsAt(i);
    if (IsEmptyState(wc) || TabIdForWebContents(wc)) {
      continue;
    }
    if (IsChromiumNewTabUrl(wc->GetVisibleURL()) ||
        IsChromiumNewTabUrl(wc->GetLastCommittedURL())) {
      has_ntp = true;
    } else {
      AdoptChromiumTab(browser, wc, i);
    }
  }
  if (has_ntp) {
    ScrubNewTabPagesLater(browser);
  }
}

void OpenTabBridge::OnBrowserClosed(BrowserWindowInterface* browser) {
  const bool closing_single_profile =
      single_profile_closing_browsers_.erase(browser) > 0;
  std::optional<ManagedBrowser> closed_info;
  if (auto it = browsers_.find(browser); it != browsers_.end()) {
    closed_info = it->second;
    browsers_.erase(it);
  }
  for (auto& [window_id, wb] : windows_) {
    std::erase_if(wb.by_profile, [browser](const auto& entry) {
      return entry.second == browser;
    });
  }
  RemoveObservedStrip(browser->GetTabStripModel());

  if (closed_info) {
    auto win_it = windows_.find(closed_info->window);
    if (!closing_single_profile && win_it != windows_.end() &&
        !win_it->second.by_profile.empty()) {
      // Close remaining hidden sibling profile Browsers that belong to this
      // Open window (ShowBrowserForSpace only calls Hide(), never Close(), so
      // leaving hidden siblings alive leaks a zombie process on Windows/Linux
      // after the visible window closes).
      std::vector<BrowserWindowInterface*> siblings;
      siblings.reserve(win_it->second.by_profile.size());
      for (const auto& [profile_id, sibling] : win_it->second.by_profile) {
        if (sibling && !IsBrowserClosing(sibling)) {
          siblings.push_back(sibling);
        }
      }
      for (BrowserWindowInterface* sibling : siblings) {
        if (browsers_.contains(sibling) && !IsBrowserClosing(sibling) &&
            sibling->GetWindow()) {
          sibling->GetWindow()->Close();
        }
      }
      // Re-lookup in case closing siblings synchronously triggered recursive
      // OnBrowserClosed notifications.
      win_it = windows_.find(closed_info->window);
    }
    if (win_it != windows_.end() && win_it->second.by_profile.empty()) {
      windows_.erase(win_it);
      // When an OS window closes during normal operation (not shutdown), remove
      // it from BrowserModel: Incognito windows vanish completely, and normal
      // windows record last_closed_window_ for Dock reopen.
      // On Windows/Linux, closing the last standard window exits the app; keep
      // it in model_.windows_ so browser.json preserves window geometry,
      // sidebar_width, sidebar_mode, focused_space_id, and
      // selected_node_by_space for the next launch.
      if (started_ && service_ && service_->started()) {
        // Preserve standard windows in model_.windows_ during app-wide quit on
        // all platforms (and on Windows/Linux when the last standard window
        // closes, since closing the last window exits the app) so browser.json
        // retains window geometry, sidebar_width, sidebar_mode, focused Space,
        // and selected_node_by_space for the next launch.
        const bool preserve_standard_window =
            !closed_info->incognito &&
            (browser_shutdown::IsTryingToQuit()
#if !BUILDFLAG(IS_MAC)
             || service_->model().windows().size() <= 1
#endif
            );
        if (!preserve_standard_window) {
          base::AutoReset<bool> applying(&applying_, true);
          service_->model().CloseWindow(closed_info->window);
        }
      }
    }
  }
}

void OpenTabBridge::OnTabStripModelDestroyed(TabStripModel* tab_strip_model) {
  RemoveObservedStrip(tab_strip_model);
}

void OpenTabBridge::AddObservedStrip(TabStripModel* strip) {
  if (!strip || observed_strips_.contains(strip)) {
    return;
  }
  strip->AddObserver(this);
  observed_strips_.insert(strip);
}

void OpenTabBridge::RemoveObservedStrip(TabStripModel* strip) {
  if (!strip) {
    return;
  }
  if (observed_strips_.erase(strip) > 0) {
    strip->RemoveObserver(this);
  }
}

void OpenTabBridge::ClearObservedStrips() {
  for (TabStripModel* strip : observed_strips_) {
    strip->RemoveObserver(this);
  }
  observed_strips_.clear();
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
  const bool capturing = IsWebContentsCapturingMedia(contents);
  const bool devtools = IsDevToolsOpenForWebContents(contents);
  const bool notifications = AreNotificationsAllowedForWebContents(contents);
  model_util::UpdateLive(service_->model(), tab_id, [&](TabLiveState& live) {
    live.has_web_content = true;
    live.sleep_phase = SleepPhase::kLive;
    live.is_loading = contents->IsLoading();
    live.progress = contents->GetLoadProgress();
    live.is_audible = contents->IsCurrentlyAudible();
    live.is_crashed = contents->IsCrashed();
    live.is_capturing_media = capturing;
    live.devtools_open = devtools;
    live.notifications_allowed = notifications;
    live.can_go_back = contents->GetController().CanGoBack();
    live.can_go_forward = contents->GetController().CanGoForward();
  });
  if (OpenSleepController* sleep = service_->sleep_controller()) {
    sleep->OnTabUnloadHandlersChanged(
        tab_id, contents->NeedToFireBeforeUnloadOrUnloadEvents());
  }
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

bool OpenTabBridge::IsIncognitoWindow(const WindowID& window_id) const {
  if (service_->model().IsIncognitoWindow(window_id)) {
    return true;
  }
  BrowserWindowInterface* browser = BrowserForWindow(window_id);
  return browser && browser->GetProfile()->IsOffTheRecord();
}

WindowID OpenTabBridge::FocusedWindowId() const {
  for (const auto& [browser, managed] : browsers_) {
    if (browser->GetWindow() && browser->GetWindow()->IsActive()) {
      return managed.window;
    }
  }
  for (const auto& [browser, managed] : browsers_) {
    if (browser->GetWindow() && browser->GetWindow()->IsVisible()) {
      return managed.window;
    }
  }
  return service_->MainWindowId();
}

BrowserWindowInterface* OpenTabBridge::BrowserForWindow(
    const WindowID& window_id) const {
  auto it = windows_.find(window_id);
  if (it == windows_.end()) {
    return nullptr;
  }
  // Prefer the Browser matching the window's focused Space's Profile.
  if (const BrowserWindowState* window =
          service_->model().FindWindow(window_id)) {
    if (const Space* space =
            service_->model().FindSpace(window->focused_space_id)) {
      if (auto pit = it->second.by_profile.find(space->profile_id);
          pit != it->second.by_profile.end()) {
        return pit->second;
      }
    }
  }
  for (const auto& [profile_id, browser] : it->second.by_profile) {
    if (browser->GetWindow() && browser->GetWindow()->IsVisible()) {
      return browser;
    }
  }
  return it->second.by_profile.empty()
             ? nullptr
             : it->second.by_profile.begin()->second.get();
}

BrowserWindowInterface* OpenTabBridge::MainBrowser() const {
  return BrowserForWindow(service_->MainWindowId());
}

BrowserWindowInterface* OpenTabBridge::BrowserForTab(
    const ItemID& tab_id) const {
  content::WebContents* wc = WebContentsForTab(tab_id);
  if (!wc) {
    return nullptr;
  }
  for (const auto& [browser, managed] : browsers_) {
    if (browser->GetTabStripModel()->GetIndexOfWebContents(wc) !=
        TabStripModel::kNoTab) {
      return browser;
    }
  }
  return nullptr;
}

content::WebContents* OpenTabBridge::ActiveWebContentsForWindow(
    const WindowID& window_id) const {
  BrowserWindowInterface* browser = BrowserForWindow(window_id);
  if (!browser) {
    return nullptr;
  }
  content::WebContents* wc =
      browser->GetTabStripModel()->GetActiveWebContents();
  return IsEmptyState(wc) ? nullptr : wc;
}

std::optional<ItemID> OpenTabBridge::ActiveTabIdForWindow(
    const WindowID& window_id) const {
  return TabIdForWebContents(ActiveWebContentsForWindow(window_id));
}

content::WebContents* OpenTabBridge::ActiveWebContents() const {
  return ActiveWebContentsForWindow(FocusedWindowId());
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
  auto it = browsers_.find(browser);
  return it == browsers_.end() ? std::nullopt
                               : std::optional<WindowID>(it->second.window);
}

std::optional<ProfileID> OpenTabBridge::ProfileOfBrowser(
    BrowserWindowInterface* browser) const {
  auto it = browsers_.find(browser);
  return it == browsers_.end() ? std::nullopt
                               : std::optional<ProfileID>(it->second.profile);
}

}  // namespace open_unified
