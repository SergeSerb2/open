// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_media_bridge.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/open_media_controls.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/media_session/public/cpp/media_image.h"
#include "services/media_session/public/cpp/media_image_manager.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"

namespace open_unified {

namespace {

constexpr int kMinArtworkSizePx = 48;
constexpr int kDesiredArtworkSizePx = 128;

// Built-in site rules matching Packages/OpenKit/Sources/OpenMedia/Resources/
// pip-site-rules.json.
constexpr std::array<std::string_view, 3> kBuiltInDisallowedPiPHosts = {
    "slack.com",
    "meet.google.com",
    "teams.microsoft.com",
};

constexpr std::array<std::string_view, 1> kBuiltInInaudiblePiPHosts = {
    "youtube.com",
};

bool IsBuiltInDisallowedPiPHost(std::string_view host) {
  for (std::string_view rule : kBuiltInDisallowedPiPHosts) {
    if (OpenMediaBridge::HostMatchesRule(host, rule)) {
      return true;
    }
  }
  return false;
}

bool ActivatesWhenInaudibleHost(std::string_view host) {
  for (std::string_view rule : kBuiltInInaudiblePiPHosts) {
    if (OpenMediaBridge::HostMatchesRule(host, rule)) {
      return true;
    }
  }
  return false;
}

gfx::ImageSkia ImageSkiaFromMediaBitmap(const SkBitmap& bitmap) {
  if (bitmap.isNull() || bitmap.empty()) {
    return gfx::ImageSkia();
  }
  if (bitmap.info().colorType() == kN32_SkColorType) {
    return gfx::ImageSkia::CreateFrom1xBitmap(bitmap);
  }
  SkImageInfo n32_info = bitmap.info().makeColorType(kN32_SkColorType);
  SkBitmap converted;
  if (!converted.tryAllocPixels(n32_info)) {
    return gfx::ImageSkia();
  }
  if (!bitmap.readPixels(n32_info, converted.getPixels(), converted.rowBytes(),
                         0, 0)) {
    return gfx::ImageSkia();
  }
  return gfx::ImageSkia::CreateFrom1xBitmap(converted);
}

}  // namespace

OpenMediaSessionState::OpenMediaSessionState() = default;
OpenMediaSessionState::OpenMediaSessionState(const OpenMediaSessionState&) =
    default;
OpenMediaSessionState::OpenMediaSessionState(OpenMediaSessionState&&) noexcept =
    default;
OpenMediaSessionState& OpenMediaSessionState::operator=(
    const OpenMediaSessionState&) = default;
OpenMediaSessionState& OpenMediaSessionState::operator=(
    OpenMediaSessionState&&) noexcept = default;
OpenMediaSessionState::~OpenMediaSessionState() = default;

// Per-tab observer bridging WebContentsObserver +
// media_session::mojom::MediaSessionObserver into OpenMediaSessionState.
class OpenMediaBridge::TabSessionObserver
    : public content::WebContentsObserver,
      public media_session::mojom::MediaSessionObserver {
 public:
  TabSessionObserver(OpenMediaBridge* bridge,
                     ItemID tab_id,
                     content::WebContents* contents)
      : content::WebContentsObserver(contents),
        bridge_(bridge),
        tab_id_(std::move(tab_id)) {
    state_.tab_id = tab_id_;
    SyncFromWebContents();
    // Silent tabs must not eagerly instantiate a MediaSession: only attach
    // to one that already exists, and bind lazily later.
    BindMediaSession(/*create_if_needed=*/false);
  }

  TabSessionObserver(const TabSessionObserver&) = delete;
  TabSessionObserver& operator=(const TabSessionObserver&) = delete;
  ~TabSessionObserver() override = default;

  const OpenMediaSessionState& state() const { return state_; }
  OpenMediaSessionState& mutable_state() { return state_; }
  bool in_auto_pip() const { return in_auto_pip_; }
  void SetAutoPiPActive(bool active) { in_auto_pip_ = active; }

  content::MediaSession* GetMediaSession() const {
    content::WebContents* wc = web_contents();
    return wc ? content::MediaSession::GetIfExists(wc) : nullptr;
  }

  // Binds to the tab's MediaSession. Without |create_if_needed| this only
  // attaches to an already-existing session (never instantiates one).
  void BindMediaSession(bool create_if_needed) {
    content::WebContents* wc = web_contents();
    if (!wc || observer_receiver_.is_bound()) {
      return;
    }
    content::MediaSession* session =
        create_if_needed ? content::MediaSession::Get(wc)
                         : content::MediaSession::GetIfExists(wc);
    if (!session) {
      return;
    }
    session->AddObserver(observer_receiver_.BindNewPipeAndPassRemote());
    ApplySessionInfo(session->GetMediaSessionInfoSync());
    ApplyMetadata(session->GetMediaSessionMetadata());
    ApplyActions(session->GetMediaSessionActionsSync());
  }

  void SyncFromWebContents() {
    content::WebContents* wc = web_contents();
    if (!wc) {
      return;
    }
    state_.source_url = wc->GetLastCommittedURL();
    state_.source_host = std::string(state_.source_url.host());
    if (state_.title.empty()) {
      state_.title = base::UTF16ToUTF8(wc->GetTitle());
    }
    state_.is_muted = wc->IsAudioMuted();
    state_.is_audible = wc->IsCurrentlyAudible();
    state_.in_pip =
        wc->HasPictureInPictureVideo() || wc->HasPictureInPictureDocument();
    state_.volume =
        static_cast<float>(content::GetOpenTabVolumeMultiplier(wc));
  }

  // content::WebContentsObserver:
  void OnAudioStateChanged(bool audible) override {
    state_.is_audible = audible;
    if (audible) {
      state_.dismissed = false;
    }
    // An audible tab is genuinely playing media: create the session if
    // needed. Otherwise only bind to one that already exists.
    BindMediaSession(/*create_if_needed=*/audible);
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void DidUpdateAudioMutingState(bool muted) override {
    state_.is_muted = muted;
    BindMediaSession(/*create_if_needed=*/false);
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void MediaPictureInPictureChanged(bool is_picture_in_picture) override {
    state_.in_pip = is_picture_in_picture;
    if (is_picture_in_picture) {
      if (bridge_->active_pip_tab_id_ == tab_id_ &&
          bridge_->active_pip_is_automatic_) {
        in_auto_pip_ = true;
      }
    } else if (in_auto_pip_ || (bridge_->active_pip_tab_id_ == tab_id_ &&
                                bridge_->active_pip_is_automatic_)) {
      in_auto_pip_ = false;
      bridge_->SnoozeAutoPiP(tab_id_);
    }
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    if (!navigation_handle || !navigation_handle->IsInPrimaryMainFrame() ||
        !navigation_handle->HasCommitted()) {
      return;
    }
    SyncFromWebContents();
    if (!navigation_handle->IsSameDocument()) {
      state_.artwork = gfx::ImageSkia();
      state_.dismissed = false;
    }
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void TitleWasSet(content::NavigationEntry* /*entry*/) override {
    if (content::WebContents* wc = web_contents()) {
      if (metadata_title_.empty()) {
        state_.title = base::UTF16ToUTF8(wc->GetTitle());
        bridge_->OnTabStateUpdated(tab_id_);
      }
    }
  }

  void WebContentsDestroyed() override {
    observer_receiver_.reset();
    bridge_->OnTabWebContentsDestroyed(tab_id_);
  }

  // media_session::mojom::MediaSessionObserver:
  void MediaSessionInfoChanged(
      media_session::mojom::MediaSessionInfoPtr info) override {
    ApplySessionInfo(std::move(info));
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void MediaSessionMetadataChanged(
      const std::optional<media_session::MediaMetadata>& metadata) override {
    ApplyMetadata(metadata);
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void MediaSessionActionsChanged(
      const std::vector<media_session::mojom::MediaSessionAction>& actions)
      override {
    ApplyActions(actions);
    bridge_->OnTabStateUpdated(tab_id_);
  }

  void MediaSessionImagesChanged(
      const base::flat_map<media_session::mojom::MediaSessionImageType,
                           std::vector<media_session::MediaImage>>& images)
      override {
    content::MediaSession* session = GetMediaSession();
    if (!session) {
      return;
    }

    media_session::MediaImageManager manager(kMinArtworkSizePx,
                                             kDesiredArtworkSizePx);
    std::optional<media_session::MediaImage> selected;
    if (auto it =
            images.find(media_session::mojom::MediaSessionImageType::kArtwork);
        it != images.end()) {
      selected = manager.SelectImage(it->second);
    }
    if (!selected) {
      if (auto it = images.find(
              media_session::mojom::MediaSessionImageType::kSourceIcon);
          it != images.end()) {
        selected = manager.SelectImage(it->second);
      }
    }

    if (!selected) {
      state_.artwork = gfx::ImageSkia();
      bridge_->OnTabStateUpdated(tab_id_);
      return;
    }

    session->GetMediaImageBitmap(
        *selected, kMinArtworkSizePx, kDesiredArtworkSizePx,
        base::BindOnce(&TabSessionObserver::OnArtworkBitmap,
                       weak_factory_.GetWeakPtr()));
  }

  void MediaSessionPositionChanged(
      const std::optional<media_session::MediaPosition>& /*position*/)
      override {}

 private:
  void ApplySessionInfo(media_session::mojom::MediaSessionInfoPtr info) {
    if (!info) {
      state_.is_playing = false;
      state_.is_active = false;
      state_.is_controllable = false;
      state_.has_video = false;
      return;
    }

    const bool was_playing = state_.is_playing;
    state_.is_playing =
        info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying;
    state_.is_active =
        info->state !=
        media_session::mojom::MediaSessionInfo::SessionState::kInactive;
    state_.is_controllable = info->is_controllable;
    if (state_.is_playing && !was_playing) {
      // Re-playing media brings back a previously dismissed mini-player card.
      state_.dismissed = false;
    }

    bool has_video = false;
    if (info->audio_video_states) {
      for (auto av : *info->audio_video_states) {
        if (av == media_session::mojom::MediaAudioVideoState::kAudioVideo ||
            av == media_session::mojom::MediaAudioVideoState::kVideoOnly) {
          has_video = true;
          break;
        }
      }
    }
    state_.has_video = has_video;
    if (has_video) {
      state_.pip_available = true;
    }

    content::WebContents* wc = web_contents();
    const bool session_pip =
        info->picture_in_picture_state ==
        media_session::mojom::MediaPictureInPictureState::kInPictureInPicture;
    state_.in_pip = session_pip ||
                    (wc && (wc->HasPictureInPictureVideo() ||
                            wc->HasPictureInPictureDocument()));
    state_.is_muted = info->muted || (wc && wc->IsAudioMuted());
    if (wc) {
      state_.is_audible = wc->IsCurrentlyAudible();
      state_.volume =
          static_cast<float>(content::GetOpenTabVolumeMultiplier(wc));
    }
    if (state_.is_controllable) {
      state_.can_play_pause = true;
    }
  }

  void ApplyMetadata(
      const std::optional<media_session::MediaMetadata>& metadata) {
    if (metadata) {
      metadata_title_ = base::UTF16ToUTF8(metadata->title);
      state_.artist = base::UTF16ToUTF8(metadata->artist);
      state_.album = base::UTF16ToUTF8(metadata->album);
      if (state_.source_host.empty() && !metadata->source_title.empty()) {
        state_.source_host = base::UTF16ToUTF8(metadata->source_title);
      }
    } else {
      metadata_title_.clear();
      state_.artist.clear();
      state_.album.clear();
    }

    if (!metadata_title_.empty()) {
      state_.title = metadata_title_;
    } else if (content::WebContents* wc = web_contents()) {
      state_.title = base::UTF16ToUTF8(wc->GetTitle());
    }
  }

  void ApplyActions(
      const std::vector<media_session::mojom::MediaSessionAction>& actions) {
    bool can_play_pause = state_.is_controllable;
    bool can_next = false;
    bool can_previous = false;
    bool pip_available = state_.has_video;
    bool has_chromium_auto_pip = false;

    for (auto action : actions) {
      switch (action) {
        case media_session::mojom::MediaSessionAction::kPlay:
        case media_session::mojom::MediaSessionAction::kPause:
          can_play_pause = true;
          break;
        case media_session::mojom::MediaSessionAction::kNextTrack:
          can_next = true;
          break;
        case media_session::mojom::MediaSessionAction::kPreviousTrack:
          can_previous = true;
          break;
        case media_session::mojom::MediaSessionAction::kEnterPictureInPicture:
        case media_session::mojom::MediaSessionAction::kExitPictureInPicture:
          pip_available = true;
          break;
        case media_session::mojom::MediaSessionAction::
            kEnterAutoPictureInPicture:
          has_chromium_auto_pip = true;
          pip_available = true;
          break;
        default:
          break;
      }
    }

    state_.can_play_pause = can_play_pause;
    state_.can_next = can_next;
    state_.can_previous = can_previous;
    state_.pip_available = pip_available;
    state_.has_chromium_auto_pip = has_chromium_auto_pip;
  }

  void OnArtworkBitmap(const SkBitmap& bitmap) {
    state_.artwork = ImageSkiaFromMediaBitmap(bitmap);
    bridge_->OnTabStateUpdated(tab_id_);
  }

  raw_ptr<OpenMediaBridge> bridge_;
  ItemID tab_id_;
  std::string metadata_title_;
  OpenMediaSessionState state_;
  bool in_auto_pip_ = false;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> observer_receiver_{
      this};
  base::WeakPtrFactory<TabSessionObserver> weak_factory_{this};
};

// --- OpenMediaBridge ---

OpenMediaBridge::OpenMediaBridge() = default;

OpenMediaBridge::~OpenMediaBridge() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  UntrackAll();
}

void OpenMediaBridge::AddObserver(Observer* observer) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (observer) {
    observers_.AddObserver(observer);
  }
}

void OpenMediaBridge::RemoveObserver(Observer* observer) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (observer) {
    observers_.RemoveObserver(observer);
  }
}

void OpenMediaBridge::TrackTab(const ItemID& tab_id,
                               content::WebContents* web_contents) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (tab_id.empty() || !web_contents) {
    return;
  }
  auto it = tabs_.find(tab_id);
  if (it != tabs_.end() && it->second->web_contents() == web_contents) {
    return;
  }
  tabs_[tab_id] = std::make_unique<TabSessionObserver>(this, tab_id, web_contents);
  NotifySessionsChanged();
}

void OpenMediaBridge::UntrackTab(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (tabs_.erase(tab_id) == 0) {
    return;
  }
  snoozed_tabs_.erase(tab_id);
  if (active_pip_tab_id_ == tab_id) {
    active_pip_tab_id_.reset();
    active_pip_is_automatic_ = false;
  }
  NotifySessionsChanged();
}

void OpenMediaBridge::UntrackAll() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  tabs_.clear();
  snoozed_tabs_.clear();
  active_pip_tab_id_.reset();
  active_pip_is_automatic_ = false;
}

// --- Controls ---

bool OpenMediaBridge::TogglePlayPause(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  return it->second->state().is_playing ? Pause(tab_id) : Play(tab_id);
}

bool OpenMediaBridge::Play(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  it->second->mutable_state().dismissed = false;
  session->Resume(content::MediaSession::SuspendType::kUI);
  return true;
}

bool OpenMediaBridge::Pause(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  session->Suspend(content::MediaSession::SuspendType::kUI);
  return true;
}

bool OpenMediaBridge::NextTrack(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  session->NextTrack();
  return true;
}

bool OpenMediaBridge::PreviousTrack(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  session->PreviousTrack();
  return true;
}

bool OpenMediaBridge::ToggleMute(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end() || !it->second->web_contents()) {
    return false;
  }
  content::WebContents* wc = it->second->web_contents();
  const bool next_muted = !wc->IsAudioMuted();
  wc->SetAudioMuted(next_muted);
  it->second->mutable_state().is_muted = next_muted;
  NotifySessionsChanged();
  return true;
}

bool OpenMediaBridge::SetVolume(const ItemID& tab_id, float volume) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end() || !it->second->web_contents()) {
    return false;
  }
  const float clamped =
      std::isfinite(volume) ? std::clamp(volume, 0.0f, 1.0f) : 1.0f;
  content::SetOpenTabVolumeMultiplier(it->second->web_contents(),
                                      static_cast<double>(clamped));
  it->second->mutable_state().volume = clamped;
  NotifySessionsChanged();
  return true;
}

bool OpenMediaBridge::TogglePictureInPicture(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end() || !it->second->web_contents()) {
    return false;
  }
  content::WebContents* wc = it->second->web_contents();
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  if (it->second->state().in_pip) {
    if (active_pip_tab_id_ == tab_id && active_pip_is_automatic_) {
      SnoozeAutoPiP(tab_id);
    }
    it->second->SetAutoPiPActive(false);
    session->ExitPictureInPicture();
    auto* pip_mgr = PictureInPictureWindowManager::GetInstance();
    if (pip_mgr && pip_mgr->GetWebContents() == wc) {
      PictureInPictureWindowManager::ExitPictureInPictureSoon();
    }
    if (active_pip_tab_id_ == tab_id) {
      active_pip_tab_id_.reset();
      active_pip_is_automatic_ = false;
    }
    return true;
  }

  active_pip_tab_id_ = tab_id;
  active_pip_is_automatic_ = false;
  session->EnterPictureInPicture();
  return true;
}

bool OpenMediaBridge::DismissCard(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  if (content::MediaSession* session = it->second->GetMediaSession()) {
    session->Suspend(content::MediaSession::SuspendType::kUI);
  }
  it->second->mutable_state().dismissed = true;
  NotifySessionsChanged();
  return true;
}

// --- AutoPiPPolicy ---

// static
std::string OpenMediaBridge::CanonicalHost(std::string_view host) {
  std::string lower =
      base::ToLowerASCII(base::TrimWhitespaceASCII(host, base::TRIM_ALL));
  if (base::StartsWith(lower, "www.")) {
    lower.erase(0, 4);
  }
  while (!lower.empty() && lower.back() == '.') {
    lower.pop_back();
  }
  return lower;
}

// static
bool OpenMediaBridge::HostMatchesRule(std::string_view host,
                                      std::string_view rule) {
  const std::string norm_host = base::ToLowerASCII(host);
  const std::string norm_rule = base::ToLowerASCII(rule);
  if (norm_host.empty() || norm_rule.empty()) {
    return false;
  }
  if (norm_host == norm_rule) {
    return true;
  }
  return norm_host.size() > norm_rule.size() + 1 &&
         norm_host[norm_host.size() - norm_rule.size() - 1] == '.' &&
         base::EndsWith(norm_host, norm_rule);
}

void OpenMediaBridge::SetAutoPiPEnabled(bool enabled) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto_pip_enabled_ = enabled;
}

void OpenMediaBridge::SetAutoPiPDisabledForHost(std::string_view host,
                                                bool disabled) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  const std::string canonical = CanonicalHost(host);
  if (canonical.empty()) {
    return;
  }
  if (disabled) {
    auto_pip_disabled_hosts_.insert(canonical);
  } else {
    for (auto it = auto_pip_disabled_hosts_.begin();
         it != auto_pip_disabled_hosts_.end();) {
      if (HostMatchesRule(canonical, *it)) {
        it = auto_pip_disabled_hosts_.erase(it);
      } else {
        ++it;
      }
    }
  }
}

bool OpenMediaBridge::IsAutoPiPDisabledForHost(std::string_view host) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  const std::string canonical = CanonicalHost(host);
  if (canonical.empty()) {
    return false;
  }
  for (const std::string& rule : auto_pip_disabled_hosts_) {
    if (HostMatchesRule(canonical, rule)) {
      return true;
    }
  }
  return false;
}

std::vector<std::string> OpenMediaBridge::GetAutoPiPDisabledHosts() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return std::vector<std::string>(auto_pip_disabled_hosts_.begin(),
                                  auto_pip_disabled_hosts_.end());
}

void OpenMediaBridge::SetAutoPiPDisabledHosts(std::vector<std::string> hosts) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto_pip_disabled_hosts_.clear();
  for (const std::string& h : hosts) {
    std::string canonical = CanonicalHost(h);
    if (!canonical.empty()) {
      auto_pip_disabled_hosts_.insert(std::move(canonical));
    }
  }
}

void OpenMediaBridge::SnoozeAutoPiP(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!tab_id.empty()) {
    snoozed_tabs_.insert(tab_id);
  }
}

void OpenMediaBridge::ClearAutoPiPSnooze(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  snoozed_tabs_.erase(tab_id);
}

AutoPiPDecision OpenMediaBridge::EvaluateAutoPiP(const ItemID& tab_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return AutoPiPDecision::kNoPlayingVideo;
  }
  const OpenMediaSessionState& state = it->second->state();
  if (state.in_pip || active_pip_tab_id_ == tab_id) {
    return AutoPiPDecision::kAlreadyInPiP;
  }
  if (!auto_pip_enabled_) {
    return AutoPiPDecision::kSettingOff;
  }
  if (!state.has_video || !state.is_playing) {
    return AutoPiPDecision::kNoPlayingVideo;
  }
  const std::string& host = state.source_host;
  if (!state.is_audible && !ActivatesWhenInaudibleHost(host)) {
    return AutoPiPDecision::kInaudible;
  }
  if (IsBuiltInDisallowedPiPHost(host)) {
    return AutoPiPDecision::kDisallowedSite;
  }
  if (IsAutoPiPDisabledForHost(host)) {
    return AutoPiPDecision::kHostDisabled;
  }
  if (snoozed_tabs_.contains(tab_id)) {
    return AutoPiPDecision::kSnoozed;
  }
  if (active_pip_tab_id_.has_value() && *active_pip_tab_id_ != tab_id &&
      !active_pip_is_automatic_) {
    return AutoPiPDecision::kManualPiPActive;
  }
  if (state.has_chromium_auto_pip) {
    return AutoPiPDecision::kChromiumAutoPiP;
  }
  return AutoPiPDecision::kOpen;
}

bool OpenMediaBridge::ShouldEnterAutoPiP(const ItemID& tab_id) const {
  return EvaluateAutoPiP(tab_id) == AutoPiPDecision::kOpen;
}

bool OpenMediaBridge::MaybeEnterAutoPiP(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!ShouldEnterAutoPiP(tab_id)) {
    return false;
  }
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return false;
  }
  content::MediaSession* session = it->second->GetMediaSession();
  if (!session) {
    return false;
  }
  active_pip_tab_id_ = tab_id;
  active_pip_is_automatic_ = true;
  session->EnterPictureInPicture();
  return true;
}

void OpenMediaBridge::OnTabSelected(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  ClearAutoPiPSnooze(tab_id);
  if (active_pip_tab_id_ == tab_id && active_pip_is_automatic_) {
    auto it = tabs_.find(tab_id);
    if (it != tabs_.end()) {
      it->second->SetAutoPiPActive(false);
      if (content::MediaSession* session = it->second->GetMediaSession()) {
        session->ExitPictureInPicture();
      }
      auto* pip_mgr = PictureInPictureWindowManager::GetInstance();
      if (pip_mgr && pip_mgr->GetWebContents() == it->second->web_contents()) {
        PictureInPictureWindowManager::ExitPictureInPictureSoon();
      }
    }
    active_pip_tab_id_.reset();
    active_pip_is_automatic_ = false;
  }
}

// --- Queries ---

std::vector<OpenMediaSessionState> OpenMediaBridge::GetActiveSessions() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<OpenMediaSessionState> result;
  for (const auto& [_, obs] : tabs_) {
    const OpenMediaSessionState& s = obs->state();
    if (s.dismissed) {
      continue;
    }
    if (s.is_active || s.is_playing || s.is_audible || s.in_pip) {
      result.push_back(s);
    }
  }
  // Playing / PiP tabs first so the Sidebar Media Mini-Player highlights the
  // primary active media source at the top.
  std::sort(result.begin(), result.end(),
            [](const OpenMediaSessionState& a, const OpenMediaSessionState& b) {
              const int rank_a =
                  (a.in_pip ? 4 : 0) + (a.is_playing ? 2 : 0) +
                  (a.is_audible ? 1 : 0);
              const int rank_b =
                  (b.in_pip ? 4 : 0) + (b.is_playing ? 2 : 0) +
                  (b.is_audible ? 1 : 0);
              if (rank_a != rank_b) {
                return rank_a > rank_b;
              }
              return a.tab_id < b.tab_id;
            });
  return result;
}

std::vector<OpenMediaSessionState> OpenMediaBridge::GetAllSessions() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  std::vector<OpenMediaSessionState> result;
  result.reserve(tabs_.size());
  for (const auto& [_, obs] : tabs_) {
    result.push_back(obs->state());
  }
  return result;
}

std::optional<OpenMediaSessionState> OpenMediaBridge::GetSession(
    const ItemID& tab_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return std::nullopt;
  }
  return it->second->state();
}

// --- Internal callbacks ---

void OpenMediaBridge::OnTabStateUpdated(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = tabs_.find(tab_id);
  if (it != tabs_.end()) {
    const OpenMediaSessionState& s = it->second->state();
    if (s.in_pip) {
      if (active_pip_tab_id_ != tab_id) {
        active_pip_tab_id_ = tab_id;
        active_pip_is_automatic_ = false;
      } else if (active_pip_is_automatic_) {
        it->second->SetAutoPiPActive(true);
      }
    } else if (active_pip_tab_id_ == tab_id) {
      // If an automatic PiP closed without the user returning to the tab
      // (dismissed while playing or paused), snooze auto-PiP for this tab
      // until the user returns to it (matches MediaCoordinator.swift §4.5.5).
      if (active_pip_is_automatic_ &&
          (it->second->in_auto_pip() || !s.is_playing)) {
        snoozed_tabs_.insert(tab_id);
      }
      it->second->SetAutoPiPActive(false);
      active_pip_tab_id_.reset();
      active_pip_is_automatic_ = false;
    }
  }
  NotifySessionsChanged();
}

void OpenMediaBridge::OnTabWebContentsDestroyed(const ItemID& tab_id) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  UntrackTab(tab_id);
}

void OpenMediaBridge::NotifySessionsChanged() {
  for (Observer& observer : observers_) {
    observer.OnMediaSessionsChanged();
  }
}

}  // namespace open_unified
