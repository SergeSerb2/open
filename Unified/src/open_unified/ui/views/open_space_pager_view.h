// Copyright 2026 The Open Authors. All rights reserved.
//
// Horizontal Space pager (port of OpenSidebar SpacePagerView, docs/design.md
// section 5.4). Pages (one OpenTabTreeView per Space, built on first use and
// kept) sit at `index * W` in a strip. A focus change slides the strip with
// the Space spring (R 0.20 s, zeta 1.0; ~0.27 s visual settle) from its
// current presentation offset, passing through every page between, while
// the window background cross-fades linearly over 0.21 s.
//
// A two-finger horizontal scroll drags the strip at most one page, with
// rubber banding at the ends, and drives the cross-fade interactively. On
// release it switches when the drag passed half a page, or 8 % with a fast
// flick (mean of the last four deltas > 6 pt), then snaps with the swipe
// spring (R 0.26 s, zeta 0.92).
//
// The strip moves by ui::Layer transform only: no relayout per frame.

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_PAGER_VIEW_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_PAGER_VIEW_H_

#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/timer/timer.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_motion.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/events/event_handler.h"
#include "ui/views/view.h"

namespace open_unified {

class OpenSidebarContext;
class OpenTabTreeView;

class OpenSpacePagerView : public views::View {
  METADATA_HEADER(OpenSpacePagerView, views::View)

 public:
  explicit OpenSpacePagerView(OpenSidebarContext* context);
  OpenSpacePagerView(const OpenSpacePagerView&) = delete;
  OpenSpacePagerView& operator=(const OpenSpacePagerView&) = delete;
  ~OpenSpacePagerView() override;

  // Space order for this window. Pages of removed Spaces are destroyed.
  void SetSpaces(const std::vector<SpaceID>& space_ids);
  const std::vector<SpaceID>& space_ids() const { return space_ids_; }

  // Shows `space_id`: slides (spring + background cross-fade) when
  // `animate`, else jumps. A second request for the moving target continues
  // the running slide.
  void ShowSpace(const SpaceID& space_id, bool animate);
  const SpaceID& shown_space_id() const { return shown_space_id_; }

  // Page for a Space, built on first use.
  OpenTabTreeView* GetPage(const SpaceID& space_id);
  // Existing page or null (never builds).
  OpenTabTreeView* FindPage(const SpaceID& space_id) const;
  void ForEachPage(const std::function<void(OpenTabTreeView*)>& fn) const;

  bool is_sliding() const;
  bool is_swiping() const { return swipe_.has_value(); }
  double presentation_offset() const { return offset_; }

  // views::View:
  void Layout(PassKey) override;
  void AddedToWidget() override;
  void RemovedFromWidget() override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;

 private:
  class SwipeHandler;
  friend class SwipeHandler;

  struct SwipeState {
    int base_index = 0;
    std::optional<int> neighbor;
    std::deque<double> last_deltas;  // last four horizontal deltas
    bool past_threshold = false;
  };

  int IndexOf(const SpaceID& space_id) const;
  float page_width() const;
  void PlaceStrip(double offset);
  void SlideTo(int index, motion::SpringToken spring, double from_offset);
  void OnSlideSettled();
  void SetPagesVisibleInRange(int lo, int hi);

  // Swipe (called by SwipeHandler). Return true when handled.
  bool OnSwipeBegin(double dx, double dy);
  bool OnSwipeUpdate(double dx);
  bool OnSwipeEnd(bool cancelled);
  static double Rubber(double x, double w);

  raw_ptr<OpenSidebarContext> context_;
  raw_ptr<views::View> strip_ = nullptr;
  std::vector<SpaceID> space_ids_;
  std::map<SpaceID, raw_ptr<OpenTabTreeView>> pages_;
  SpaceID shown_space_id_;
  // Strip offset in points: index * W at rest.
  double offset_ = 0;
  std::unique_ptr<motion::OpenSpringAnimator> slide_;
  std::optional<SwipeState> swipe_;
  std::unique_ptr<SwipeHandler> swipe_handler_;
  double wheel_accumulator_ = 0;
  base::OneShotTimer wheel_reset_timer_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SPACE_PAGER_VIEW_H_
