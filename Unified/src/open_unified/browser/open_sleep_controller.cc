// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_sleep_controller.h"

#include <limits>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/pickle.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "ui/base/page_transition_types.h"

namespace open_unified {

namespace {

using Builder = sessions::ContentSerializedNavigationBuilder;

constexpr base::TimeDelta kTickInterval = base::Seconds(15);
constexpr char kChromiumTag[] = "156.0.8078.48";

TimestampSec NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

// Only a controller that never navigated accepts Restore().
bool IsUnused(content::NavigationController& controller) {
  if (controller.GetPendingEntry()) {
    return false;
  }
  const int count = controller.GetEntryCount();
  return count == 0 ||
         (count == 1 && controller.GetEntryAtIndex(0)->IsInitialEntry());
}

std::string_view VisibilityName(content::Visibility visibility) {
  switch (visibility) {
    case content::Visibility::VISIBLE:
      return "visible";
    case content::Visibility::OCCLUDED:
      return "occluded";
    case content::Visibility::HIDDEN:
      return "hidden";
  }
  return "hidden";
}

MediaStreamCaptureIndicator* CaptureIndicator() {
  return MediaCaptureDevicesDispatcher::GetInstance()
      ->GetMediaStreamCaptureIndicator()
      .get();
}

}  // namespace

OpenSleepController::OpenSleepController(OpenBrowserService* service)
    : service_(service) {
  // scheduler_ is a member: its callbacks never outlive this controller
  // (and WeakPtr cannot bind methods that return a value).
  SleepCallbacks callbacks;
  callbacks.on_freeze = base::BindRepeating(&OpenSleepController::DoFreeze,
                                            base::Unretained(this));
  callbacks.on_discard = base::BindRepeating(&OpenSleepController::DoDiscard,
                                             base::Unretained(this));
  callbacks.on_destroy = base::BindRepeating(&OpenSleepController::DoDestroy,
                                             base::Unretained(this));
  callbacks.on_restore = base::BindRepeating(&OpenSleepController::DoRestore,
                                             base::Unretained(this));
  scheduler_.SetCallbacks(std::move(callbacks));
}

OpenSleepController::~OpenSleepController() {
  Shutdown();
}

void OpenSleepController::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  service_->tab_bridge()->AddObserver(this);
  UpdateTimer();
}

void OpenSleepController::Shutdown() {
  if (!started_) {
    return;
  }
  started_ = false;
  tick_timer_.Stop();
  // Keep back/forward and scroll state of every loaded page for the next
  // launch (the store runner is BLOCK_SHUTDOWN).
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
      SaveHistory(tab_id, contents);
    }
    bridge->RemoveObserver(this);
  }
}

// --- History capture / restore -----------------------------------------------

std::optional<SleepHistoryRecord> OpenSleepController::CaptureHistory(
    const ItemID& tab_id,
    content::WebContents* contents) const {
  content::NavigationController& controller = contents->GetController();
  const int count = controller.GetEntryCount();
  if (count < 1 || static_cast<size_t>(count) > kOpnhMaxEntries ||
      (count == 1 && controller.GetEntryAtIndex(0)->IsInitialEntry())) {
    return std::nullopt;  // Nothing committed (or over the OPNH limit).
  }
  int current = controller.GetCurrentEntryIndex();
  if (current < 0 || current >= count) {
    current = controller.GetLastCommittedEntryIndex();
  }
  if (current < 0 || current >= count) {
    return std::nullopt;
  }
  // Each entry is Chromium's session pickle; no string limit (a truncated
  // URL breaks restore), the OPNH codec bounds the total.
  auto serialize = [&](Builder::SerializationOptions options) {
    std::vector<std::vector<uint8_t>> entries;
    entries.reserve(count);
    for (int i = 0; i < count; ++i) {
      content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
      if (!entry) {
        return std::vector<std::vector<uint8_t>>();
      }
      base::Pickle pickle;
      Builder::FromNavigationEntry(i, entry, options)
          .WriteToPickle(std::numeric_limits<int>::max(), &pickle);
      entries.emplace_back(pickle.data(), pickle.data() + pickle.size());
    }
    return entries;
  };
  // Page state (scroll and form values of every frame) is dropped only when
  // the history does not fit otherwise (memory-fork §5.3).
  OpnhContainer container;
  OpnhError error = OpnhError::kNone;
  if (!CaptureOpnhWithFallback(
          static_cast<uint32_t>(current),
          [&] { return serialize(Builder::DEFAULT); },
          [&] { return serialize(Builder::EXCLUDE_PAGE_STATE); }, &container,
          &error)) {
    LOG(WARNING) << "Open: navigation history not captured (OPNH error "
                 << static_cast<int>(error) << ")";
    return std::nullopt;
  }
  SleepHistoryRecord record;
  if (!EncodeOpnh(container, &record.container, &error)) {
    return std::nullopt;
  }
  content::NavigationEntry* entry = controller.GetEntryAtIndex(current);
  record.tab_id = tab_id;
  record.current_index = current;
  record.entry_count = count;
  record.current_url = entry->GetVirtualURL().spec();
  record.current_title = base::UTF16ToUTF8(entry->GetTitle());
  if (entry->GetFavicon().valid && entry->GetFavicon().url.is_valid()) {
    record.favicon_url = entry->GetFavicon().url.spec();
  }
  record.has_page_state = container.has_page_state;
  record.container_version = static_cast<int>(kOpnhVersion);
  record.chromium_tag = kChromiumTag;
  record.captured_at = NowSec();
  return record;
}

bool OpenSleepController::RestoreHistory(
    content::WebContents* contents,
    const OpnhContainer& container) const {
  content::NavigationController& controller = contents->GetController();
  const int count = static_cast<int>(container.entries.size());
  if (!IsUnused(controller) || ValidateOpnh(container) != OpnhError::kNone ||
      count < 1) {
    return false;
  }
  // Decode everything before touching the controller: one bad entry (for
  // example after a Chromium update) changes nothing.
  std::vector<sessions::SerializedNavigationEntry> serialized(count);
  for (int i = 0; i < count; ++i) {
    base::Pickle pickle =
        base::Pickle::WithUnownedBuffer(container.entries[i]);
    base::PickleIterator iterator(pickle);
    if (!serialized[i].ReadFromPickle(&iterator)) {
      LOG(WARNING) << "Open: navigation history entry " << i
                   << " does not decode";
      return false;
    }
  }
  std::vector<std::unique_ptr<content::NavigationEntry>> entries =
      Builder::ToNavigationEntries(serialized, contents->GetBrowserContext());
  if (static_cast<int>(entries.size()) != count) {
    return false;
  }
  controller.Restore(static_cast<int>(container.current_index),
                     content::RestoreType::kRestored, &entries);
  if (controller.GetEntryCount() != count) {
    LOG(ERROR) << "Open: navigation history restore lost entries";
    return false;
  }
  // The first load reports document.wasDiscarded, as after a discard in
  // place. A visible page loads now; a hidden one when shown.
  contents->SetWasDiscarded(true);
  if (contents->GetVisibility() == content::Visibility::VISIBLE) {
    controller.LoadIfNecessary();
  }
  return true;
}

void OpenSleepController::SaveHistory(const ItemID& tab_id,
                                      content::WebContents* contents) {
  if (contents->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  ProfileServices* ps =
      profile ? service_->ProfileServicesFor(*profile) : nullptr;
  std::optional<SleepHistoryRecord> record = CaptureHistory(tab_id, contents);
  if (!ps || !record) {
    return;
  }
  RunOnStore(ps->sleep, base::BindOnce(
                            [](SleepHistoryRecord record, SleepStore* store) {
                              store->Save(record);
                            },
                            std::move(*record)));
}

void OpenSleepController::RestoreOrLoad(const ItemID& tab_id,
                                        content::WebContents* contents,
                                        const GURL& fallback_url) {
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  ProfileServices* ps =
      profile ? service_->ProfileServicesFor(*profile) : nullptr;
  if (!ps) {
    contents->GetController().LoadURLWithParams(
        content::NavigationController::LoadURLParams(fallback_url));
    return;
  }
  RunOnStore(ps->sleep,
             base::BindOnce(
                 [](ItemID tab_id, SleepStore* store) {
                   std::optional<SleepHistoryRecord> record =
                       store->Load(tab_id);
                   if (record) {
                     store->Delete(tab_id);  // One restore per capture.
                   }
                   return record;
                 },
                 tab_id),
             base::BindOnce(&OpenSleepController::OnStoredHistory,
                            weak_factory_.GetWeakPtr(), contents->GetWeakPtr(),
                            fallback_url));
}

void OpenSleepController::OnStoredHistory(
    base::WeakPtr<content::WebContents> contents,
    GURL fallback_url,
    std::optional<SleepHistoryRecord> record) {
  if (!contents || !IsUnused(contents->GetController())) {
    // Gone, or navigated meanwhile (automation `navigate`, the command
    // bar); that navigation wins.
    return;
  }
  if (record && record->chromium_tag == kChromiumTag) {
    OpnhContainer container;
    if (DecodeOpnh(record->container, &container) &&
        RestoreHistory(contents.get(), container)) {
      return;
    }
  }
  if (fallback_url.is_valid()) {
    content::NavigationController::LoadURLParams params(fallback_url);
    params.transition_type = ui::PAGE_TRANSITION_AUTO_BOOKMARK;
    contents->GetController().LoadURLWithParams(params);
  }
}

// --- Policy ------------------------------------------------------------------

SleepMode OpenSleepController::ModeForTab(const ItemID& tab_id) const {
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  const Profile* p =
      profile ? service_->model().FindProfile(*profile) : nullptr;
  return p ? p->settings.sleep_mode : SleepMode::kBalanced;
}

bool OpenSleepController::IsKeepAlive(const ItemID& tab_id,
                                      content::WebContents* contents) const {
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  const Profile* p =
      profile ? service_->model().FindProfile(*profile) : nullptr;
  KeepAliveMatcher matcher(p ? p->settings.keep_alive_sites
                             : std::vector<std::string>());
  return matcher.MatchesUrl(contents->GetLastCommittedURL().spec());
}

bool OpenSleepController::MayChromeDiscard(
    content::WebContents* contents) const {
  std::optional<ItemID> tab_id = OpenTabBridge::TabIdForWebContents(contents);
  if (!tab_id) {
    return true;
  }
  if (ModeForTab(*tab_id) == SleepMode::kOff ||
      IsKeepAlive(*tab_id, contents) || contents->IsCurrentlyAudible()) {
    return false;
  }
  MediaStreamCaptureIndicator* indicator = CaptureIndicator();
  return !(indicator && indicator->IsCapturingUserMedia(contents));
}

void OpenSleepController::Tick() {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!started_ || !bridge) {
    return;
  }
  const TimestampSec now = NowSec();
  std::set<ItemID> visible;
  for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
    if (contents->GetVisibility() == content::Visibility::VISIBLE) {
      visible.insert(tab_id);
    }
    // The scheduler's audio protection needs edges, not levels.
    const bool audible = contents->IsCurrentlyAudible();
    auto [it, inserted] = audible_.try_emplace(tab_id, audible);
    if (inserted || it->second != audible) {
      it->second = audible;
      scheduler_.OnTabAudioChanged(tab_id, audible, now);
    }
  }
  scheduler_.Tick(service_->model(), visible, now);
}

void OpenSleepController::UpdateTimer() {
  OpenTabBridge* bridge = service_->tab_bridge();
  const bool has_pages = bridge && !bridge->LoadedTabs().empty();
  if (started_ && has_pages && !tick_timer_.IsRunning()) {
    tick_timer_.Start(FROM_HERE, kTickInterval,
                      base::BindRepeating(&OpenSleepController::Tick,
                                          weak_factory_.GetWeakPtr()));
  } else if ((!started_ || !has_pages) && tick_timer_.IsRunning()) {
    tick_timer_.Stop();
  }
}

// --- Scheduler callbacks -----------------------------------------------------

bool OpenSleepController::DoFreeze(const ItemID& tab_id) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  // Only hidden pages may freeze (Chromium DCHECKs a visible freeze).
  if (!contents || contents->GetVisibility() == content::Visibility::VISIBLE) {
    return false;
  }
  contents->SetPageFrozen(true);
  return true;
}

bool OpenSleepController::DoDiscard(const ItemID& tab_id) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  if (!contents || contents->GetVisibility() == content::Visibility::VISIBLE ||
      contents->WasDiscarded()) {
    return false;
  }
  SaveHistory(tab_id, contents);
  contents->Discard(base::DoNothing());
  return true;
}

void OpenSleepController::DoDestroy(const ItemID& tab_id) {
  service_->tab_bridge()->UnloadTab(tab_id);
}

bool OpenSleepController::DoRestore(const ItemID& tab_id) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  if (!contents) {
    return true;  // A placeholder loads when OpenTabBridge creates it.
  }
  contents->SetPageFrozen(false);
  // A discarded page reloads by itself once it is shown.
  return true;
}

// --- Direct operations -------------------------------------------------------

base::DictValue OpenSleepController::StateFor(const ItemID& tab_id) const {
  base::DictValue state;
  state.Set("tab", tab_id);
  const Tab* tab = service_->model().FindTab(tab_id);
  state.Set("phase", json::SleepPhaseName(
                         tab ? tab->live_state.sleep_phase
                             : SleepPhase::kPlaceholder));
  content::WebContents* contents =
      service_->tab_bridge() ? service_->tab_bridge()->WebContentsForTab(tab_id)
                             : nullptr;
  state.Set("live", contents != nullptr);
  if (!contents) {
    state.Set("frozen", false);
    state.Set("discarded", false);
    return state;
  }
  state.Set("frozen",
            tab && tab->live_state.sleep_phase == SleepPhase::kFrozen);
  state.Set("discarded", contents->WasDiscarded());
  state.Set("visibility", VisibilityName(contents->GetVisibility()));
  state.Set("chromeTabId",
            sessions::SessionTabHelper::IdForTab(contents).id());
  state.Set("url", contents->GetLastCommittedURL().spec());
  return state;
}

base::DictValue OpenSleepController::Hide(const ItemID& tab_id) {
  if (content::WebContents* contents =
          service_->tab_bridge()->WebContentsForTab(tab_id)) {
    contents->UpdateWebContentsVisibility(content::Visibility::HIDDEN);
  }
  return StateFor(tab_id).Set("ok", true);
}

base::DictValue OpenSleepController::Show(const ItemID& tab_id) {
  if (content::WebContents* contents =
          service_->tab_bridge()->WebContentsForTab(tab_id)) {
    contents->UpdateWebContentsVisibility(content::Visibility::VISIBLE);
  }
  return StateFor(tab_id).Set("ok", true);
}

base::DictValue OpenSleepController::Freeze(const ItemID& tab_id) {
  const bool ok = DoFreeze(tab_id);
  if (ok) {
    model_util::UpdateLive(service_->model(), tab_id, [](TabLiveState& live) {
      live.sleep_phase = SleepPhase::kFrozen;
    });
  }
  return StateFor(tab_id).Set("ok", ok);
}

base::DictValue OpenSleepController::Unfreeze(const ItemID& tab_id) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  if (!contents) {
    return StateFor(tab_id).Set("ok", false);
  }
  contents->SetPageFrozen(false);
  model_util::UpdateLive(service_->model(), tab_id, [](TabLiveState& live) {
    live.sleep_phase = SleepPhase::kLive;
  });
  return StateFor(tab_id).Set("ok", true);
}

void OpenSleepController::Discard(
    const ItemID& tab_id,
    base::OnceCallback<void(base::DictValue)> done) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  if (!contents || contents->GetVisibility() == content::Visibility::VISIBLE ||
      contents->WasDiscarded()) {
    std::move(done).Run(StateFor(tab_id).Set("ok", false));
    return;
  }
  SaveHistory(tab_id, contents);
  contents->Discard(base::BindOnce(
      [](base::WeakPtr<OpenSleepController> self, ItemID tab_id,
         base::OnceCallback<void(base::DictValue)> done) {
        if (!self) {
          return;
        }
        model_util::UpdateLive(self->service_->model(), tab_id,
                               [](TabLiveState& live) {
                                 live.sleep_phase = SleepPhase::kSleeping;
                                 live.is_loading = false;
                                 live.is_audible = false;
                               });
        std::move(done).Run(self->StateFor(tab_id).Set("ok", true));
      },
      weak_factory_.GetWeakPtr(), tab_id, std::move(done)));
}

base::DictValue OpenSleepController::Capture(const ItemID& tab_id) {
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(tab_id);
  base::DictValue state = StateFor(tab_id);
  std::optional<SleepHistoryRecord> record =
      contents ? CaptureHistory(tab_id, contents) : std::nullopt;
  if (!record) {
    return std::move(state).Set("ok", false);
  }
  OpnhContainer decoded;
  std::vector<uint8_t> reencoded;
  const bool round_trip = DecodeOpnh(record->container, &decoded) &&
                          EncodeOpnh(decoded, &reencoded) &&
                          reencoded == record->container;
  base::ListValue urls;
  for (int i = 0; i < contents->GetController().GetEntryCount(); ++i) {
    urls.Append(contents->GetController().GetEntryAtIndex(i)->GetURL().spec());
  }
  return std::move(state)
      .Set("ok", true)
      .Set("history",
           base::DictValue()
               .Set("entries", record->entry_count)
               .Set("currentIndex", record->current_index)
               .Set("pageState", record->has_page_state)
               .Set("opnhBytes", static_cast<int>(record->container.size()))
               .Set("title", record->current_title)
               .Set("urls", std::move(urls))
               .Set("roundTrip", round_trip));
}

// --- OpenTabBridge::Observer -------------------------------------------------

void OpenSleepController::OnTabActivated(const ItemID& tab_id) {
  // A frozen or discarded page that becomes active comes back now.
  scheduler_.OnTabShown(tab_id, NowSec());
  scheduler_.RequestRestore(service_->model(), tab_id, NowSec());
}

void OpenSleepController::OnTabContentsAttached(
    const ItemID& tab_id,
    content::WebContents* contents) {
  UpdateTimer();
}

void OpenSleepController::OnTabContentsDetaching(
    const ItemID& tab_id,
    content::WebContents* contents) {
  audible_.erase(tab_id);
  scheduler_.OnTabClosed(tab_id);
  // The bridge erases the page right after this notification.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OpenSleepController::UpdateTimer,
                                weak_factory_.GetWeakPtr()));
}

void OpenSleepController::OnTabPrimaryPageCommitted(
    const ItemID& tab_id,
    content::WebContents* contents) {
  scheduler_.OnTabCommitted(tab_id, NowSec());
}

}  // namespace open_unified
