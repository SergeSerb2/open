// Copyright 2026 The Open Authors. All rights reserved.
//
// The sidebar media mini-player stack (port of OpenSidebar MediaControlsView
// and MiniPlayerCardView; media plan 13, capture session 2 frames E2-E7).
// It goes into OpenSidebarView::SetMediaPlayerStack(), right above the
// bottom bar, at its preferred height (0 without sessions).
//
// Card (MiniPlayerMetrics): 8 pt side inset, 8 pt gap above the stack, rows
// 33 pt, corner radius 10, fill = the Space theme's backgroundExtra
// (ThemeStyle::MiniPlayerFill), shadow black 0.21 / radius 4.
//
//   collapsed (1 row):  [favicon] [previous] [play/pause] [next] [volume]
//                       24 pt buttons in 5 slots spread from x 10 to
//                       w - 10 - 24, y 5.
//   expanded (2 rows):  title row on top: title at x 14 (baseline 22, 13 pt;
//                       "Back to Tab" while hovered), Picture in Picture at
//                       w - 58 (video only), Close at w - 34.
//   drawer (3 rows):    the volume button of an expanded card opens a row
//                       between them: speaker (mute) at x 10, slider from
//                       x 44 to w - 44 (4 pt track, 12 pt knob, 0.05 steps),
//                       full-volume speaker at w - 34.
//
// Stack: collapsed cards pile up 7 pt apart, 5 pt narrower per side and
// 0.2 more transparent per level, only the front card takes input. Hovering
// the stack expands every card (5 pt apart); leaving collapses it after
// 0.3 s. A click on a card's body or title focuses its tab.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_MEDIA_PLAYER_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_MEDIA_PLAYER_VIEW_H_

#include <map>
#include <memory>
#include <set>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "open_unified/browser/open_media_bridge.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/view.h"

namespace views {
class BoundsAnimator;
}

namespace open_unified {

namespace media_metrics {
inline constexpr int kInset = 8;
inline constexpr int kGapAbove = 8;
inline constexpr int kRowHeight = 33;
inline constexpr int kCornerRadius = 10;
inline constexpr int kButton = 24;
inline constexpr int kButtonY = 5;
inline constexpr int kButtonPlateRadius = 5;
inline constexpr int kSlotInset = 10;
inline constexpr int kSlotCount = 5;
inline constexpr int kFaviconSize = 16;
inline constexpr int kTitleX = 14;
inline constexpr int kTitleBaseline = 22;
inline constexpr int kTitleGap = 10;
inline constexpr int kTitleFontSize = 13;
inline constexpr int kCloseTrailing = 34;
inline constexpr int kPipTrailing = 58;
inline constexpr int kStackOffset = 7;
inline constexpr int kStackInset = 5;
inline constexpr float kStackOpacityStep = 0.2f;
inline constexpr int kExpandedGap = 5;
inline constexpr float kShadowOpacity = 0.21f;
inline constexpr float kShadowRadius = 4.f;
inline constexpr base::TimeDelta kCollapseDelay = base::Milliseconds(300);
inline constexpr base::TimeDelta kStackMotion = base::Milliseconds(200);
inline constexpr int kDrawerSliderInset = 44;
inline constexpr int kDrawerTrackHeight = 4;
inline constexpr int kDrawerTrackRadius = 2;
inline constexpr int kDrawerKnob = 12;
inline constexpr float kVolumeStep = 0.05f;
}  // namespace media_metrics

class OpenMiniPlayerCardView;

class OpenMediaPlayerStackView : public views::View {
  METADATA_HEADER(OpenMediaPlayerStackView, views::View)

 public:
  using TabCallback = base::RepeatingCallback<void(const ItemID& tab_id)>;

  struct Callbacks {
    Callbacks();
    Callbacks(const Callbacks&);
    Callbacks& operator=(const Callbacks&);
    ~Callbacks();

    TabCallback on_focus_tab;  // "Back to Tab"
    TabCallback on_toggle_play_pause;
    TabCallback on_previous;
    TabCallback on_next;
    TabCallback on_toggle_mute;
    base::RepeatingCallback<void(const ItemID& tab_id, float volume)>
        on_set_volume;
    TabCallback on_toggle_pip;
    TabCallback on_dismiss;  // "Close Mini Player"
    // Optional: the tab's favicon for the first slot. Null image: the
    // session artwork, else a letter tile of the host.
    base::RepeatingCallback<gfx::ImageSkia(const ItemID& tab_id)> favicon_for;
  };

  explicit OpenMediaPlayerStackView(Callbacks callbacks);
  OpenMediaPlayerStackView(const OpenMediaPlayerStackView&) = delete;
  OpenMediaPlayerStackView& operator=(const OpenMediaPlayerStackView&) =
      delete;
  ~OpenMediaPlayerStackView() override;

  // Shows one card per session, in order (first = front card). Dismissed
  // sessions are skipped. Cards are kept by tab id, so playback updates
  // only repaint them.
  void UpdateSessions(std::vector<OpenMediaSessionState> sessions,
                      const OpenSpaceThemeState& theme);
  // Theme-only change (Space switch, appearance).
  void SetTheme(const OpenSpaceThemeState& theme);
  // Display-rate animations only in a visible window (OpenSidebarContext::
  // AnimationsEnabled). Off: geometry changes apply at once.
  void SetAnimationsEnabled(bool enabled);

  bool is_expanded() const { return expanded_; }
  size_t card_count() const { return cards_.size(); }
  OpenMiniPlayerCardView* card_at(size_t index) const;
  // The stack's height without the gap above it (0 when empty).
  int StackHeight() const;

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnMouseEntered(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;
  void VisibilityChanged(views::View* starting_from, bool is_visible) override;

 private:
  friend class OpenMiniPlayerCardView;

  void SetExpanded(bool expanded);
  void Collapse();
  // A card's height changed (drawer); re-measure and re-layout.
  void OnCardHeightChanged();
  void Remeasure(bool animate);
  std::vector<gfx::Rect> TargetBounds() const;
  float TargetOpacity(size_t level) const;

  Callbacks callbacks_;
  OpenSpaceThemeState theme_;
  std::vector<raw_ptr<OpenMiniPlayerCardView>> cards_;
  // Tabs whose volume drawer is open (kept across updates).
  std::set<ItemID> drawers_;
  bool expanded_ = false;
  bool hovered_ = false;
  bool animations_enabled_ = true;
  bool animate_next_layout_ = false;
  int last_height_ = 0;
  base::OneShotTimer collapse_timer_;
  std::unique_ptr<views::BoundsAnimator> animator_;
};

// One session's card. Created and owned by OpenMediaPlayerStackView.
class OpenMiniPlayerCardView : public views::View {
  METADATA_HEADER(OpenMiniPlayerCardView, views::View)

 public:
  OpenMiniPlayerCardView(OpenMediaPlayerStackView* stack,
                         const OpenMediaSessionState& session);
  OpenMiniPlayerCardView(const OpenMiniPlayerCardView&) = delete;
  OpenMiniPlayerCardView& operator=(const OpenMiniPlayerCardView&) = delete;
  ~OpenMiniPlayerCardView() override;

  const ItemID& tab_id() const { return session_.tab_id; }
  const OpenMediaSessionState& session() const { return session_; }
  void SetSession(const OpenMediaSessionState& session);
  // Expanded (stack hovered) and its level in the collapsed pile.
  void Configure(bool expanded, size_t level);
  bool expanded() const { return expanded_; }
  bool drawer_open() const;
  int CardHeight() const;
  void Retheme();

  // views::View:
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseMoved(const ui::MouseEvent& event) override;
  void OnMouseExited(const ui::MouseEvent& event) override;

 private:
  class MediaButton;
  class VolumeSlider;
  friend class MediaButton;
  friend class VolumeSlider;

  enum class Control {
    kFavicon,
    kPrevious,
    kPlayPause,
    kNext,
    kVolume,
    kPip,
    kClose,
    kVolumeLow,
    kVolumeHigh,
  };

  MediaButton* AddButton(Control control);
  void OnControl(Control control);
  void ToggleDrawer();
  void SetVolume(float volume);
  void SyncControls();
  bool TitleRowContains(const gfx::Point& point) const;
  void SetTitleHovered(bool hovered);
  gfx::ImageSkia Favicon() const;
  SkColor GlyphColor(bool enabled) const;
  SkColor TitleColor() const;
  bool IsDark() const;

  raw_ptr<OpenMediaPlayerStackView> stack_;
  OpenMediaSessionState session_;
  bool expanded_ = false;
  size_t level_ = 0;
  bool title_hovered_ = false;
  bool pressed_ = false;
  std::map<Control, raw_ptr<MediaButton>> buttons_;
  raw_ptr<VolumeSlider> slider_ = nullptr;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_MEDIA_PLAYER_VIEW_H_
