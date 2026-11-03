// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/media/open_media_controller.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "content/browser/media/media_web_contents_observer.h"
#include "content/browser/media/session/media_session_controllers_manager.h"
#include "content/browser/media/session/media_session_impl.h"
#include "content/browser/web_contents/web_contents_impl.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"

namespace open_engine {

namespace {

using media_session::mojom::MediaSessionAction;
using SuspendType = content::MediaSession::SuspendType;

// Keeps the controller alive as long as its WebContents.
class MediaControllerHolder
    : public content::WebContentsUserData<MediaControllerHolder> {
 public:
  ~MediaControllerHolder() override = default;
  OpenMediaController* controller() const { return controller_.get(); }

 private:
  friend class content::WebContentsUserData<MediaControllerHolder>;
  explicit MediaControllerHolder(content::WebContents* contents)
      : content::WebContentsUserData<MediaControllerHolder>(*contents),
        controller_(new OpenMediaController(contents)) {}

  CefRefPtr<OpenMediaController> controller_;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(MediaControllerHolder);

// GetState names. Picture in Picture entry and exit are Open's own (players
// and the PiP window), not the session's.
const char* ActionName(MediaSessionAction action) {
  switch (action) {
    case MediaSessionAction::kPlay:
      return "play";
    case MediaSessionAction::kPause:
      return "pause";
    case MediaSessionAction::kPreviousTrack:
      return "previousTrack";
    case MediaSessionAction::kNextTrack:
      return "nextTrack";
    case MediaSessionAction::kSeekBackward:
      return "seekBackward";
    case MediaSessionAction::kSeekForward:
      return "seekForward";
    case MediaSessionAction::kSkipAd:
      return "skipAd";
    case MediaSessionAction::kStop:
      return "stop";
    case MediaSessionAction::kSeekTo:
      return "seekTo";
    case MediaSessionAction::kScrubTo:
      return "scrubTo";
    case MediaSessionAction::kToggleMicrophone:
      return "toggleMicrophone";
    case MediaSessionAction::kToggleCamera:
      return "toggleCamera";
    case MediaSessionAction::kHangUp:
      return "hangUp";
    case MediaSessionAction::kPreviousSlide:
      return "previousSlide";
    case MediaSessionAction::kNextSlide:
      return "nextSlide";
    // MediaSessionImpl adds this when the page handles
    // "enterpictureinpicture" (its browser-initiated variant is off in 156).
    case MediaSessionAction::kEnterAutoPictureInPicture:
      return "enterAutoPictureInPicture";
    default:
      return nullptr;
  }
}

double Seconds(base::TimeDelta delta) {
  return delta.is_max() ? INFINITY : delta.InSecondsF();
}

}  // namespace

// static
CefRefPtr<OpenMediaController> OpenMediaController::GetOrCreate(
    content::WebContents* contents) {
  MediaControllerHolder::CreateForWebContents(contents);
  return MediaControllerHolder::FromWebContents(contents)->controller();
}

// static
OpenMediaController* OpenMediaController::FromWebContents(
    content::WebContents* contents) {
  MediaControllerHolder* holder =
      contents ? MediaControllerHolder::FromWebContents(contents) : nullptr;
  return holder ? holder->controller() : nullptr;
}

bool OpenMediaController::GetPictureInPictureHost(
    CefRefPtr<CefMediaControllerHandler>* handler,
    CefRefPtr<CefBrowser>* browser) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!IsValid() || !handler_) {
    return false;
  }
  auto host = CefBrowserHostBase::GetBrowserForContents(web_contents());
  if (!host || !handler_->ShouldHostPictureInPicture(host.get())) {
    return false;
  }
  *handler = handler_;
  *browser = host.get();
  return true;
}

OpenMediaController::OpenMediaController(content::WebContents* contents)
    : content::WebContentsObserver(contents) {
  audible_ = contents->IsCurrentlyAudible();
  pip_ = contents->HasPictureInPictureVideo();
  if (content::MediaSession* session =
          content::MediaSession::GetIfExists(contents)) {
    MediaSessionCreated(session);
  }
  snapshot_ = Compute();
}

OpenMediaController::~OpenMediaController() = default;

void OpenMediaController::SetHandler(
    CefRefPtr<CefMediaControllerHandler> handler) {
  handler_ = valid_ ? handler : nullptr;
}

bool OpenMediaController::IsValid() {
  CEF_REQUIRE_UIT_RETURN(false);
  return valid_ && web_contents();
}

bool OpenMediaController::IsAudible() {
  CEF_REQUIRE_UIT_RETURN(false);
  return IsValid() && audible_;
}

CefRefPtr<CefDictionaryValue> OpenMediaController::GetState() {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  const Snapshot& s = snapshot_;
  auto state = CefDictionaryValue::Create();
  state->SetBool("active", s.active);
  state->SetString("playbackState", s.playback);
  state->SetString("sessionState", s.session_state);
  state->SetBool("controllable", s.controllable);
  state->SetBool("hasVideo", s.has_video);
  state->SetBool("hasAudio", s.has_audio);
  state->SetInt("largestVideoWidth", s.largest_video.width());
  state->SetInt("largestVideoHeight", s.largest_video.height());
  state->SetBool("pictureInPictureDisabled", s.pip_disabled);
  auto actions = CefListValue::Create();
  for (size_t i = 0; i < s.actions.size(); ++i) {
    actions->SetString(i, s.actions[i]);
  }
  state->SetList("actions", actions);
  state->SetString("title", base::UTF16ToUTF8(s.title));
  state->SetString("artist", base::UTF16ToUTF8(s.artist));
  state->SetString("album", base::UTF16ToUTF8(s.album));
  state->SetString("sourceTitle", base::UTF16ToUTF8(s.source_title));
  if (s.position) {
    auto position = CefDictionaryValue::Create();
    const base::TimeDelta duration = s.position->duration();
    position->SetBool("live", duration.is_max() || duration.is_inf());
    position->SetDouble("duration",
                        position->GetBool("live") ? 0 : Seconds(duration));
    position->SetDouble("position", s.position->GetPosition().InSecondsF());
    position->SetDouble("rate", s.position->playback_rate());
    position->SetBool("ended", s.position->end_of_media());
    position->SetDouble("lastUpdated",
                        base::Time::Now().InSecondsFSinceUnixEpoch());
    state->SetDictionary("position", position);
  }
  state->SetBool("pictureInPicture", s.pip);
  state->SetString("microphoneState", s.microphone);
  state->SetString("cameraState", s.camera);
  state->SetDouble("volume", s.volume);
  return state;
}

bool OpenMediaController::ExecuteAction(const CefString& action_name,
                                        CefRefPtr<CefDictionaryValue> args) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!IsValid()) {
    return false;
  }
  const std::string action = action_name.ToString();
  double value = 0;
  if (args) {
    value = action == "seekBy" ? args->GetDouble("delta")
                               : args->GetDouble("time");
  }
  if (!std::isfinite(value)) {
    return false;
  }
  content::MediaSessionImpl* session =
      content::MediaSessionImpl::Get(web_contents());
  // A muted tab, or only MediaStream ("one shot") players: the session has
  // nothing to control, so the players get the playback commands (as in
  // Chrome's own fallback inside MediaSessionImpl). Track, ad, slide and
  // meeting actions still go to the session: MediaSessionImpl routes them to
  // the page's own handler whether or not it is controllable, and a meeting
  // page (camera or microphone streams only) is never controllable.
  const bool playback_action = action == "play" || action == "pause" ||
                               action == "stop" || action == "seekBy" ||
                               action == "seekTo" || action == "scrubTo";
  if (playback_action && !session->IsControllable()) {
    return RunOnPlayers(action, value);
  }
  if (action == "play") {
    session->Resume(SuspendType::kUI);
  } else if (action == "pause") {
    session->Suspend(SuspendType::kUI);
  } else if (action == "stop") {
    session->Stop(SuspendType::kUI);
  } else if (action == "previousTrack") {
    session->PreviousTrack();
  } else if (action == "nextTrack") {
    session->NextTrack();
  } else if (action == "skipAd") {
    session->SkipAd();
  } else if (action == "seekBy") {
    if (value == 0) {
      return false;
    }
    session->Seek(base::Seconds(value));
  } else if (action == "seekTo") {
    session->SeekTo(base::Seconds(std::max(0.0, value)));
  } else if (action == "scrubTo") {
    session->ScrubTo(base::Seconds(std::max(0.0, value)));
  } else if (action == "toggleMicrophone") {
    session->ToggleMicrophone();
  } else if (action == "toggleCamera") {
    session->ToggleCamera();
  } else if (action == "hangUp") {
    session->HangUp();
  } else if (action == "previousSlide") {
    session->PreviousSlide();
  } else if (action == "nextSlide") {
    session->NextSlide();
  } else {
    return false;
  }
  return true;
}

bool OpenMediaController::RunOnPlayers(const std::string& action,
                                       double value) {
  content::MediaWebContentsObserver* observer =
      static_cast<content::WebContentsImpl*>(web_contents())
          ->media_web_contents_observer();
  bool ran = false;
  auto run = [&](const content::MediaPlayerId& id, auto call) {
    if (observer->IsMediaPlayerRemoteAvailable(id)) {
      call(observer->GetMediaPlayerRemote(id));
      ran = true;
    }
  };
  if (action == "pause" || action == "stop") {
    for (const auto& [id, player] : players_) {
      if (player.playing && IsLive(id)) {
        run(id, [](auto& remote) { remote->RequestPause(true); });
      }
    }
    return ran;
  }
  const content::MediaPlayerId* recent = MostRecentPlayer();
  if (!recent) {
    return false;
  }
  if (action == "play") {
    run(*recent, [](auto& remote) { remote->RequestPlay(true); });
  } else if (action == "seekBy" && value != 0) {
    run(*recent, [value](auto& remote) {
      if (value > 0) {
        remote->RequestSeekForward(base::Seconds(value));
      } else {
        remote->RequestSeekBackward(base::Seconds(-value));
      }
    });
  } else if (action == "seekTo" || action == "scrubTo") {
    run(*recent, [value](auto& remote) {
      remote->RequestSeekTo(base::Seconds(std::max(0.0, value)));
    });
  }
  return ran;
}

void OpenMediaController::SetVolume(double volume) {
  CEF_REQUIRE_UIT();
  if (!IsValid()) {
    return;
  }
  volume_ = std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0;
  // chromium/0401: multiplies every session player's volume (MediaSessionImpl
  // pushes it to players added later too).
  content::MediaSessionImpl::Get(web_contents())
      ->SetOpenVolumeMultiplier(volume_);
  Update();
}

double OpenMediaController::GetVolume() {
  CEF_REQUIRE_UIT_RETURN(1.0);
  return volume_;
}

bool OpenMediaController::RequestPictureInPicture() {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!IsValid()) {
    return false;
  }
  const content::MediaPlayerId* id = LargestPlayingVideo();
  // Blink's browser-initiated entry (HTMLVideoElement::
  // RequestEnterPictureInPicture) checks neither user activation nor the
  // disablePictureInPicture attribute, so the browser checks the player's
  // own availability report first.
  if (!id || !IsPictureInPictureAvailable(*id)) {
    return false;
  }
  content::MediaWebContentsObserver* observer =
      static_cast<content::WebContentsImpl*>(web_contents())
          ->media_web_contents_observer();
  if (!observer->IsMediaPlayerRemoteAvailable(*id)) {
    return false;
  }
  observer->GetMediaPlayerRemote(*id)->RequestEnterPictureInPicture(
      std::nullopt);
  return true;
}

void OpenMediaController::ExitPictureInPicture(int behavior) {
  CEF_REQUIRE_UIT();
  if (!IsValid()) {
    return;
  }
  PictureInPictureWindowManager* manager =
      PictureInPictureWindowManager::GetInstance();
  // One Picture in Picture window app-wide: only close this browser's.
  if (manager->GetWebContents() != web_contents()) {
    return;
  }
  using UiBehavior = PictureInPictureWindowManager::UiBehavior;
  switch (behavior) {
    case 1:
      manager->ExitPictureInPictureViaWindowUi(
          UiBehavior::kCloseWindowAndPauseVideo);
      break;
    case 2:
      manager->ExitPictureInPictureViaWindowUi(
          UiBehavior::kCloseWindowAndFocusOpener);
      break;
    default:
      manager->ExitPictureInPicture();
      break;
  }
}

void OpenMediaController::WebContentsDestroyed() {
  Invalidate();
}

void OpenMediaController::Invalidate() {
  valid_ = false;
  receiver_.reset();
  players_.clear();
  CefRefPtr<CefMediaControllerHandler> handler = std::move(handler_);
  weak_ptr_factory_.InvalidateWeakPtrs();
  Observe(nullptr);
}

void OpenMediaController::OnAudioStateChanged(bool audible) {
  audible_ = audible;
  if (!handler_) {
    return;
  }
  // P6: every change, background tabs included (OpenSleep's contract).
  if (auto browser =
          CefBrowserHostBase::GetBrowserForContents(web_contents())) {
    handler_->OnAudibleChanged(browser.get(), audible);
  }
}

void OpenMediaController::MediaSessionCreated(
    content::MediaSession* media_session) {
  if (receiver_.is_bound()) {
    return;
  }
  media_session->AddObserver(receiver_.BindNewPipeAndPassRemote());
}

void OpenMediaController::MediaMetadataChanged(
    const MediaPlayerInfo& info,
    const content::MediaPlayerId& id) {
  Player& player = players_[id];
  player.has_video = info.has_video;
  player.has_audio = info.has_audio;
  Update();
}

void OpenMediaController::MediaStartedPlaying(
    const MediaPlayerInfo& info,
    const content::MediaPlayerId& id) {
  Player& player = players_[id];
  player.has_video = info.has_video;
  player.has_audio = info.has_audio;
  player.playing = true;
  player.in_progress = true;
  player.started = ++next_started_;
  Update();
}

void OpenMediaController::MediaStoppedPlaying(
    const MediaPlayerInfo& info,
    const content::MediaPlayerId& id,
    MediaStoppedReason reason) {
  auto it = players_.find(id);
  if (it == players_.end()) {
    return;
  }
  it->second.playing = false;
  if (reason == MediaStoppedReason::kReachedEndOfStream) {
    it->second.in_progress = false;
  }
  Update();
}

void OpenMediaController::MediaResized(const gfx::Size& size,
                                       const content::MediaPlayerId& id) {
  players_[id].natural_size = size;
  Update();
}

void OpenMediaController::MediaDestroyed(const content::MediaPlayerId& id) {
  if (players_.erase(id)) {
    Update();
  }
}

void OpenMediaController::MediaPictureInPictureChanged(
    bool is_picture_in_picture) {
  pip_ = is_picture_in_picture;
  Update();
}

void OpenMediaController::DidUpdateAudioMutingState(bool muted) {
  if (!muted) {
    // MediaWebContentsObserver (created before this observer) has put the
    // players back into the session by now.
    MediaSessionInfoChanged(nullptr);
    return;
  }
  Update();
}

void OpenMediaController::RenderFrameHostStateChanged(
    content::RenderFrameHost* render_frame_host,
    content::RenderFrameHost::LifecycleState old_state,
    content::RenderFrameHost::LifecycleState new_state) {
  // A document entering or leaving the back-forward cache takes its players
  // with it (IsLive).
  Update();
}

// The session observer's messages are only change signals: the values are
// read back synchronously, so a message that was queued before a mute or an
// unmute never brings back an older state.
void OpenMediaController::MediaSessionInfoChanged(
    media_session::mojom::MediaSessionInfoPtr info) {
  if (!IsValid() || SessionFrozen()) {
    return;
  }
  content::MediaSession* session =
      content::MediaSession::GetIfExists(web_contents());
  if (!session) {
    return;
  }
  session_info_ = session->GetMediaSessionInfoSync();
  session_actions_ = session->GetMediaSessionActionsSync();
  metadata_ = session->GetMediaSessionMetadata();
  position_ = session->GetMediaSessionPosition();
  Update();
}

void OpenMediaController::MediaSessionMetadataChanged(
    const std::optional<media_session::MediaMetadata>& metadata) {
  MediaSessionInfoChanged(nullptr);
}

void OpenMediaController::MediaSessionActionsChanged(
    const std::vector<media_session::mojom::MediaSessionAction>& actions) {
  MediaSessionInfoChanged(nullptr);
}

void OpenMediaController::MediaSessionPositionChanged(
    const std::optional<media_session::MediaPosition>& position) {
  MediaSessionInfoChanged(nullptr);
}

bool OpenMediaController::IsLive(const content::MediaPlayerId& id) const {
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromID(id.frame_routing_id);
  return frame && frame->IsActive();
}

const content::MediaPlayerId* OpenMediaController::LargestPlayingVideo()
    const {
  const content::MediaPlayerId* best = nullptr;
  const Player* best_player = nullptr;
  for (const auto& [id, player] : players_) {
    if (!player.playing || !player.has_video || !IsLive(id)) {
      continue;
    }
    const uint64_t area = player.natural_size.Area64();
    if (!best_player || area > best_player->natural_size.Area64() ||
        (area == best_player->natural_size.Area64() &&
         player.started > best_player->started)) {
      best = &id;
      best_player = &player;
    }
  }
  return best;
}

const content::MediaPlayerId* OpenMediaController::MostRecentPlayer() const {
  const content::MediaPlayerId* best = nullptr;
  uint64_t started = 0;
  for (const auto& [id, player] : players_) {
    if (player.in_progress && IsLive(id) && player.started >= started) {
      best = &id;
      started = player.started;
    }
  }
  return best;
}

bool OpenMediaController::IsPictureInPictureAvailable(
    const content::MediaPlayerId& id) const {
  content::MediaWebContentsObserver* observer =
      static_cast<content::WebContentsImpl*>(web_contents())
          ->media_web_contents_observer();
  // chromium/0401: the player's own report (Blink SupportsPictureInPicture).
  return observer && observer->OpenIsPictureInPictureAvailable(id);
}

bool OpenMediaController::SessionFrozen() const {
  return web_contents() && web_contents()->IsAudioMuted() && session_info_;
}

OpenMediaController::Snapshot OpenMediaController::Compute() {
  Snapshot s;
  s.volume = volume_;
  if (!IsValid()) {
    return s;
  }
  bool playing = false;
  bool paused = false;
  for (const auto& [id, player] : players_) {
    if (!player.in_progress || !IsLive(id)) {
      continue;
    }
    playing |= player.playing;
    paused |= !player.playing;
    s.has_video |= player.has_video;
    s.has_audio |= player.has_audio;
  }
  const bool session_controllable =
      session_info_ && session_info_->is_controllable;
  s.active = playing || paused || session_controllable;
  if (!s.active) {
    // Nothing to report: changes of an inactive session are not changes.
    return s;
  }
  if (session_info_) {
    using SessionState = media_session::mojom::MediaSessionInfo::SessionState;
    switch (session_info_->state) {
      case SessionState::kActive:
        s.session_state = "active";
        break;
      case SessionState::kDucking:
        s.session_state = "ducking";
        break;
      case SessionState::kSuspended:
        s.session_state = "suspended";
        break;
      case SessionState::kInactive:
        s.session_state = "inactive";
        break;
    }
    switch (session_info_->microphone_state) {
      case media_session::mojom::MicrophoneState::kMuted:
        s.microphone = "muted";
        break;
      case media_session::mojom::MicrophoneState::kUnmuted:
        s.microphone = "unmuted";
        break;
      default:
        break;
    }
    switch (session_info_->camera_state) {
      case media_session::mojom::CameraState::kTurnedOn:
        s.camera = "on";
        break;
      case media_session::mojom::CameraState::kTurnedOff:
        s.camera = "off";
        break;
      default:
        break;
    }
  }
  s.controllable = session_controllable;
  if (playing) {
    s.playback = "playing";
  } else if (paused) {
    s.playback = "paused";
  } else {
    s.playback = session_info_->playback_state ==
                         media_session::mojom::MediaPlaybackState::kPlaying
                     ? "playing"
                     : "paused";
  }
  if (const content::MediaPlayerId* largest = LargestPlayingVideo()) {
    s.largest_video = players_.at(*largest).natural_size;
    s.pip_disabled = !IsPictureInPictureAvailable(*largest);
    if (!s.pip_disabled) {
      s.actions.push_back("enterPictureInPicture");
    }
  }
  if (pip_) {
    s.actions.push_back("exitPictureInPicture");
  }
  for (MediaSessionAction action : session_actions_) {
    if (const char* name = ActionName(action)) {
      s.actions.push_back(name);
    }
  }
  std::sort(s.actions.begin(), s.actions.end());
  s.actions.erase(std::unique(s.actions.begin(), s.actions.end()),
                  s.actions.end());
  s.title = metadata_.title;
  s.artist = metadata_.artist;
  s.album = metadata_.album;
  s.source_title = metadata_.source_title;
  if (position_ && SessionFrozen() && !playing &&
      position_->playback_rate() != 0) {
    // Muted and paused: the frozen session clock stops too.
    position_ = media_session::MediaPosition(
        0, position_->duration(), position_->GetPosition(),
        position_->end_of_media());
  }
  s.position = position_;
  s.pip = pip_;
  return s;
}

bool OpenMediaController::Snapshot::SameAs(const Snapshot& o) const {
  if (active != o.active || playback != o.playback ||
      session_state != o.session_state || controllable != o.controllable ||
      has_video != o.has_video || has_audio != o.has_audio ||
      largest_video != o.largest_video || pip_disabled != o.pip_disabled ||
      actions != o.actions || title != o.title || artist != o.artist ||
      album != o.album || source_title != o.source_title || pip != o.pip ||
      microphone != o.microphone || camera != o.camera ||
      volume != o.volume || position.has_value() != o.position.has_value()) {
    return false;
  }
  if (!position) {
    return true;
  }
  // A position report that continues the clock (a timer-driven update) is
  // not a change; a seek, a rate or duration change, or the end is.
  if (position->playback_rate() != o.position->playback_rate() ||
      position->duration() != o.position->duration() ||
      position->end_of_media() != o.position->end_of_media()) {
    return false;
  }
  const base::TimeDelta drift =
      (position->GetPosition() - o.position->GetPosition()).magnitude();
  return drift < base::Milliseconds(250);
}

void OpenMediaController::Update() {
  if (!IsValid()) {
    return;
  }
  Snapshot now = Compute();
  if (now.SameAs(snapshot_)) {
    // Keep the newest clock reference without reporting a change.
    snapshot_.position = now.position;
    return;
  }
  snapshot_ = std::move(now);
  if (delivery_pending_ || !handler_) {
    return;
  }
  delivery_pending_ = true;
  CEF_POST_TASK(CEF_UIT, base::BindOnce(&OpenMediaController::Deliver,
                                        weak_ptr_factory_.GetWeakPtr()));
}

void OpenMediaController::Deliver() {
  delivery_pending_ = false;
  if (!IsValid() || !handler_) {
    return;
  }
  if (auto browser =
          CefBrowserHostBase::GetBrowserForContents(web_contents())) {
    handler_->OnMediaStateChanged(browser.get());
  }
}

}  // namespace open_engine

// static
CefRefPtr<CefMediaController> CefMediaController::GetForBrowser(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefMediaControllerHandler> handler) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  auto host = CefBrowserHostBase::FromBrowser(browser);
  content::WebContents* contents = host ? host->GetWebContents() : nullptr;
  if (!contents) {
    return nullptr;
  }
  CefRefPtr<open_engine::OpenMediaController> controller =
      open_engine::OpenMediaController::GetOrCreate(contents);
  controller->SetHandler(handler);
  return controller.get();
}
