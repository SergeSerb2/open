// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEDIA_OPEN_MEDIA_CONTROLLER_H_
#define OPEN_BROWSER_MEDIA_OPEN_MEDIA_CONTROLLER_H_

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "cef/include/cef_media_controller.h"
#include "cef/libcef/browser/thread_util.h"
#include "content/public/browser/media_player_id.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "services/media_session/public/cpp/media_position.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "ui/gfx/geometry/size.h"

namespace content {
class WebContents;
}

namespace open_engine {

// CefMediaController (cef/include/cef_media_controller.h; media-pip EM-1b,
// EM-2, EM-3, EM-5). One per WebContents, kept alive by WebContents user
// data until the WebContents goes away. It combines two Chromium sources:
//
// - the players (WebContentsObserver media callbacks): playback, video and
//   audio, natural sizes, Picture in Picture. They exist for every player,
//   also muted or MediaStream ("one shot") players that the media session
//   leaves out;
// - the media session (media_session::mojom::MediaSessionObserver):
//   controllable, actions, metadata, position, microphone and camera.
//
// Chromium removes a muted tab's players from its media session, so while
// the tab is muted the session part keeps its last unmuted value and
// commands go to the players directly. Audible is WebContents' own signal
// (OnAudioStateChanged: media elements, Web Audio, WebRTC). UI thread only.
class OpenMediaController : public CefMediaController,
                            public content::WebContentsObserver,
                            public media_session::mojom::MediaSessionObserver {
 public:
  // The controller of |contents|, created on first use.
  static CefRefPtr<OpenMediaController> GetOrCreate(
      content::WebContents* contents);

  explicit OpenMediaController(content::WebContents* contents);
  // Public for content::BrowserThread::DeleteOnUIThread.
  ~OpenMediaController() override;
  OpenMediaController(const OpenMediaController&) = delete;
  OpenMediaController& operator=(const OpenMediaController&) = delete;

  void SetHandler(CefRefPtr<CefMediaControllerHandler> handler);

  // EM-4 (open_video_overlay_window.mm): the controller of |contents| if one
  // exists, nullptr otherwise. Never creates one.
  static OpenMediaController* FromWebContents(content::WebContents* contents);
  // If the handler shows this page's video Picture in Picture in the
  // embedder's own window (ShouldHostPictureInPicture), returns true with the
  // handler and the browser. The window keeps both for its session, so it can
  // report the close also after this controller let go of the page.
  bool GetPictureInPictureHost(CefRefPtr<CefMediaControllerHandler>* handler,
                               CefRefPtr<CefBrowser>* browser);

  // CefMediaController:
  bool IsValid() override;
  bool IsAudible() override;
  CefRefPtr<CefDictionaryValue> GetState() override;
  bool ExecuteAction(const CefString& action,
                     CefRefPtr<CefDictionaryValue> args) override;
  void SetVolume(double volume) override;
  double GetVolume() override;
  bool RequestPictureInPicture() override;
  void ExitPictureInPicture(int behavior) override;

  // content::WebContentsObserver:
  void WebContentsDestroyed() override;
  void OnAudioStateChanged(bool audible) override;
  void MediaSessionCreated(content::MediaSession* media_session) override;
  void MediaMetadataChanged(const MediaPlayerInfo& info,
                            const content::MediaPlayerId& id) override;
  void MediaStartedPlaying(const MediaPlayerInfo& info,
                           const content::MediaPlayerId& id) override;
  void MediaStoppedPlaying(const MediaPlayerInfo& info,
                           const content::MediaPlayerId& id,
                           MediaStoppedReason reason) override;
  void MediaResized(const gfx::Size& size,
                    const content::MediaPlayerId& id) override;
  void MediaDestroyed(const content::MediaPlayerId& id) override;
  void MediaPictureInPictureChanged(bool is_picture_in_picture) override;
  void DidUpdateAudioMutingState(bool muted) override;
  void RenderFrameHostStateChanged(
      content::RenderFrameHost* render_frame_host,
      content::RenderFrameHost::LifecycleState old_state,
      content::RenderFrameHost::LifecycleState new_state) override;

  // media_session::mojom::MediaSessionObserver:
  void MediaSessionInfoChanged(
      media_session::mojom::MediaSessionInfoPtr info) override;
  void MediaSessionMetadataChanged(
      const std::optional<media_session::MediaMetadata>& metadata) override;
  void MediaSessionActionsChanged(
      const std::vector<media_session::mojom::MediaSessionAction>& actions)
      override;
  void MediaSessionImagesChanged(
      const base::flat_map<media_session::mojom::MediaSessionImageType,
                           std::vector<media_session::MediaImage>>& images)
      override {}
  void MediaSessionPositionChanged(
      const std::optional<media_session::MediaPosition>& position) override;

 private:
  struct Player {
    bool has_video = false;
    bool has_audio = false;
    bool playing = false;
    // Started playing at least once and not ended since.
    bool in_progress = false;
    gfx::Size natural_size;
    // Order of the last MediaStartedPlaying (ties of equal size).
    uint64_t started = 0;
  };

  // What GetState reports. Compared to find real changes.
  struct Snapshot {
    bool active = false;
    std::string playback = "none";
    std::string session_state = "inactive";
    bool controllable = false;
    bool has_video = false;
    bool has_audio = false;
    gfx::Size largest_video;
    bool pip_disabled = false;
    std::vector<std::string> actions;
    std::u16string title;
    std::u16string artist;
    std::u16string album;
    std::u16string source_title;
    std::optional<media_session::MediaPosition> position;
    bool pip = false;
    std::string microphone = "unknown";
    std::string camera = "unknown";
    double volume = 1.0;

    bool SameAs(const Snapshot& other) const;
  };

  // Players of this tab's current documents (not in the back-forward cache
  // or being deleted).
  bool IsLive(const content::MediaPlayerId& id) const;
  // The playing video with the largest natural area, or nullptr.
  const content::MediaPlayerId* LargestPlayingVideo() const;
  // The live in-progress player started last, or nullptr.
  const content::MediaPlayerId* MostRecentPlayer() const;
  bool IsPictureInPictureAvailable(const content::MediaPlayerId& id) const;
  // True while the session part must keep its last unmuted value.
  bool SessionFrozen() const;
  bool RunOnPlayers(const std::string& action, double value);

  Snapshot Compute();
  // Recomputes the snapshot; on a real change, schedules one
  // OnMediaStateChanged for this message-loop turn.
  void Update();
  void Deliver();
  void Invalidate();

  CefRefPtr<CefMediaControllerHandler> handler_;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> receiver_{this};
  std::map<content::MediaPlayerId, Player> players_;
  uint64_t next_started_ = 0;
  bool pip_ = false;
  bool audible_ = false;
  double volume_ = 1.0;

  // Last session values (kept while the tab is muted).
  media_session::mojom::MediaSessionInfoPtr session_info_;
  std::vector<media_session::mojom::MediaSessionAction> session_actions_;
  media_session::MediaMetadata metadata_;
  std::optional<media_session::MediaPosition> position_;

  Snapshot snapshot_;
  bool delivery_pending_ = false;
  bool valid_ = true;

  base::WeakPtrFactory<OpenMediaController> weak_ptr_factory_{this};

  IMPLEMENT_REFCOUNTING_DELETE_ON_UIT(OpenMediaController);
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_MEDIA_CONTROLLER_H_
