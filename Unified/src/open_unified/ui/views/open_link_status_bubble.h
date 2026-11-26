// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenLinkStatusBubbleView: the hovered-link URL capsule (port of
// App/PageChrome/LinkStatusBubble.swift; S2 04/0021, 0033,
// docs/re/page-platform.md, interaction-states.md).
//
// Hovering a link shows its URL without "http(s)://" in a capsule at the
// bottom-left of that page's own area: 10 pt from its left edge, 12 pt above
// its bottom edge, 23 pt tall (radius 11.5), in the Space's tooltip fill
// (#0A0D4F on the default theme) with the tooltip text color and Open's
// tooltip font (13 Medium). The text is middle-truncated; text padding 9 pt
// (guess); the capsule never takes more than 2/3 of the page width (guess).
// It appears at once and fades out over 0.12 s ease-out (guess) when the
// pointer leaves the link. Once hidden it keeps no URL (an Incognito link
// leaves nothing behind). It never takes mouse events and has no
// accessibility node (Arc has none).
//
// It changes only when the page reports a new target URL or the page area
// moves: nothing runs per frame.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_LINK_STATUS_BUBBLE_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_LINK_STATUS_BUBBLE_H_

#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/view.h"

class GURL;

namespace open_unified {

struct OpenSpaceThemeState;

namespace link_status_metrics {
inline constexpr int kHeight = 23;
inline constexpr int kLeadingInset = 10;
inline constexpr int kBottomInset = 12;
inline constexpr int kPadding = 9;                       // guess
inline constexpr double kMaxWidthShare = 2.0 / 3.0;      // guess
inline constexpr base::TimeDelta kFadeOut = base::Milliseconds(120);  // guess
}  // namespace link_status_metrics

class OpenLinkStatusBubbleView : public views::View {
  METADATA_HEADER(OpenLinkStatusBubbleView, views::View)

 public:
  OpenLinkStatusBubbleView();
  OpenLinkStatusBubbleView(const OpenLinkStatusBubbleView&) = delete;
  OpenLinkStatusBubbleView& operator=(const OpenLinkStatusBubbleView&) =
      delete;
  ~OpenLinkStatusBubbleView() override;

  // The URL as shown: the spec without "http://" or "https://".
  static std::u16string DisplayText(const GURL& url);

  // Shows `url` (WebContentsDelegate::UpdateTargetURL). An empty or invalid
  // URL means the pointer left the link: the capsule fades out.
  void SetTargetUrl(const GURL& url, const OpenSpaceThemeState& theme);
  // Same with ready-made status text (trimmed; empty fades out).
  void SetStatusText(const std::u16string& text,
                     const OpenSpaceThemeState& theme);
  // `animated`: fade (pointer left the link); otherwise at once (tab
  // switch, page close, crash, HTML fullscreen, Peek change).
  void Hide(bool animated);

  bool IsShowing() const;
  const std::u16string& text() const { return text_; }

  // The capsule's bounds for a page area in the parent's coordinates: the
  // bottom-left placement above, clamped to min(area width - 20, 2/3 of the
  // area width). Empty when the area is too small to show any text.
  gfx::Rect PreferredBoundsInParent(const gfx::Rect& parent_bounds) const;
  // Optional: remembers the page area and applies PreferredBoundsInParent()
  // itself now and on every text change. Call again when the area moves
  // (sidebar toggle, Split View drag, window resize).
  void SetPageArea(const gfx::Rect& page_area_in_parent);

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void OnPaint(gfx::Canvas* canvas) override;

 private:
  void Show(const std::u16string& text, const OpenSpaceThemeState& theme);
  void FinishHide(int generation);
  void ApplyPageArea();
  int TextWidth() const;

  std::u16string text_;
  SkColor fill_ = SkColorSetRGB(0x0A, 0x0D, 0x4F);
  SkColor text_color_ = SK_ColorWHITE;
  std::optional<gfx::Rect> page_area_;
  bool showing_ = false;
  // Bumped on every show and hide so a superseded fade never hides a newer
  // capsule.
  int generation_ = 0;
  base::WeakPtrFactory<OpenLinkStatusBubbleView> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_LINK_STATUS_BUBBLE_H_
