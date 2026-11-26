// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_MEDIA_BRIDGE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_MEDIA_BRIDGE_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/sequence_checker.h"
#include "open_unified/core/model/open_types.h"
#include "ui/gfx/image/image_skia.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}

namespace open_unified {

// Per-tab live media session snapshot for the Sidebar Media Mini-Player and
// Auto-PiP policy.
struct OpenMediaSessionState {
  OpenMediaSessionState();
  OpenMediaSessionState(const OpenMediaSessionState&);
  OpenMediaSessionState(OpenMediaSessionState&&) noexcept;
  OpenMediaSessionState& operator=(const OpenMediaSessionState&);
  OpenMediaSessionState& operator=(OpenMediaSessionState&&) noexcept;
  ~OpenMediaSessionState();

  ItemID tab_id;
  std::string title;
  std::string artist;
  std::string album;
  std::string source_host;
  GURL source_url;
  bool is_playing = false;
  bool is_active = false;
  bool is_audible = false;
  bool is_controllable = false;
  bool is_muted = false;
  float volume = 1.0f;  // 0.0 - 1.0 (patch 0007 per-tab volume multiplier)
  bool can_play_pause = false;
  bool can_next = false;
  bool can_previous = false;
  bool has_video = false;
  bool pip_available = false;
  bool in_pip = false;
  bool has_chromium_auto_pip = false;
  bool dismissed = false;
  gfx::ImageSkia artwork;
};

// Auto Picture-in-Picture policy decision (ported from AutoPiPPolicy.swift).
enum class AutoPiPDecision {
  kOpen,
  kAlreadyInPiP,
  kSettingOff,
  kNoPlayingVideo,
  kInaudible,
  kDisallowedSite,
  kHostDisabled,
  kSnoozed,
  kManualPiPActive,
  kChromiumAutoPiP,
};

// Observes content::MediaSession and WebContents audio/PiP state for every
// tracked Open tab, exposes real playback/volume/PiP controls (using patch
// 0007's content/public/browser/open_media_controls.h for per-tab volume),
// implements AutoPiPPolicy, and notifies observers for the Sidebar Media
// Mini-Player.
class OpenMediaBridge {
 public:
  class Observer : public base::CheckedObserver {
   public:
    virtual void OnMediaSessionsChanged() {}

   protected:
    ~Observer() override = default;
  };

  OpenMediaBridge();
  ~OpenMediaBridge();

  OpenMediaBridge(const OpenMediaBridge&) = delete;
  OpenMediaBridge& operator=(const OpenMediaBridge&) = delete;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Starts/stops observing a tab's WebContents and MediaSession.
  void TrackTab(const ItemID& tab_id, content::WebContents* web_contents);
  void UntrackTab(const ItemID& tab_id);
  void UntrackAll();

  // Playback, audio, volume, PiP, and mini-player card controls.
  bool TogglePlayPause(const ItemID& tab_id);
  bool Play(const ItemID& tab_id);
  bool Pause(const ItemID& tab_id);
  bool NextTrack(const ItemID& tab_id);
  bool PreviousTrack(const ItemID& tab_id);
  bool ToggleMute(const ItemID& tab_id);
  bool SetVolume(const ItemID& tab_id, float volume);
  bool TogglePictureInPicture(const ItemID& tab_id);
  bool DismissCard(const ItemID& tab_id);

  // Auto-PiP policy (ported from OpenMedia AutoPiPPolicy + PiPSiteRules +
  // MediaSettings). Honors advanced.autoPiP / advanced.pictureInPicture pref,
  // built-in site rules (slack.com, meet.google.com, teams.microsoft.com
  // disallowed; youtube.com activatesWhenInaudible), per-site host exclusions,
  // and per-tab snooze.
  void SetAutoPiPEnabled(bool enabled);
  bool IsAutoPiPEnabled() const { return auto_pip_enabled_; }
  void SetAutoPiPDisabledForHost(std::string_view host, bool disabled);
  bool IsAutoPiPDisabledForHost(std::string_view host) const;
  std::vector<std::string> GetAutoPiPDisabledHosts() const;
  void SetAutoPiPDisabledHosts(std::vector<std::string> hosts);

  // Snooze/unsnooze auto-PiP for a tab (e.g., user closed auto-PiP -> snooze
  // until user returns to the tab).
  void SnoozeAutoPiP(const ItemID& tab_id);
  void ClearAutoPiPSnooze(const ItemID& tab_id);

  AutoPiPDecision EvaluateAutoPiP(const ItemID& tab_id) const;
  bool ShouldEnterAutoPiP(const ItemID& tab_id) const;
  // Evaluates ShouldEnterAutoPiP() and enters PiP if allowed.
  bool MaybeEnterAutoPiP(const ItemID& tab_id);
  // Call when returning to |tab_id| (clears snooze and exits auto-PiP).
  void OnTabSelected(const ItemID& tab_id);

  // Queries for Sidebar Media Mini-Player and sleep/status integrations.
  std::vector<OpenMediaSessionState> GetActiveSessions() const;
  std::vector<OpenMediaSessionState> GetAllSessions() const;
  std::optional<OpenMediaSessionState> GetSession(const ItemID& tab_id) const;

  static std::string CanonicalHost(std::string_view host);
  static bool HostMatchesRule(std::string_view host, std::string_view rule);

  base::WeakPtr<OpenMediaBridge> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

 private:
  class TabSessionObserver;

  void OnTabStateUpdated(const ItemID& tab_id);
  void OnTabWebContentsDestroyed(const ItemID& tab_id);
  void NotifySessionsChanged();

  SEQUENCE_CHECKER(sequence_checker_);

  std::map<ItemID, std::unique_ptr<TabSessionObserver>> tabs_;
  bool auto_pip_enabled_ = true;
  std::set<std::string> auto_pip_disabled_hosts_;
  std::set<ItemID> snoozed_tabs_;
  std::optional<ItemID> active_pip_tab_id_;
  bool active_pip_is_automatic_ = false;
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenMediaBridge> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_MEDIA_BRIDGE_H_
