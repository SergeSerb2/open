// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_space_pager_view.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <utility>

#include "base/functional/bind.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/compositor/layer.h"
#include "ui/events/event.h"
#include "ui/events/event_constants.h"
#include "ui/gfx/geometry/transform.h"
#include "ui/views/widget/widget.h"

namespace open_unified {

namespace {

// Flick: mean of the last four deltas above this (points per event).
constexpr double kFlickVelocity = 6;
constexpr double kFlickDistance = 0.08;
constexpr double kSwitchDistance = 0.5;
// Unphased scroll streams (no begin/end phases) end after this idle time.
constexpr base::TimeDelta kUnphasedIdle = base::Milliseconds(120);
// Discrete horizontal wheel: one notch switches one Space.
constexpr double kWheelNotch = 120;
constexpr base::TimeDelta kWheelReset = base::Milliseconds(300);

}  // namespace

// ---------------------------------------------------------------------------
// SwipeHandler: pre-target handler on the pager, so it sees horizontal
// scrolls aimed at any tab list before the vertical ScrollView does.

class OpenSpacePagerView::SwipeHandler : public ui::EventHandler {
 public:
  explicit SwipeHandler(OpenSpacePagerView* pager) : pager_(pager) {}

  void OnScrollEvent(ui::ScrollEvent* event) override {
    if (event->type() == ui::EventType::kScrollFlingStart) {
      if (pager_->is_swiping()) {
        idle_timer_.Stop();
        pager_->OnSwipeEnd(/*cancelled=*/false);
        decided_ = false;
        event->SetHandled();
      }
      return;
    }
    if (event->type() != ui::EventType::kScroll) {
      return;
    }
    // Momentum is ignored; it only must not scroll the list mid-swipe.
    if (event->momentum_phase() != ui::EventMomentumPhase::NONE) {
      if (pager_->is_swiping()) {
        event->SetHandled();
      }
      return;
    }
    const ui::ScrollEventPhase phase = event->scroll_event_phase();
    const double dx = event->x_offset();
    const double dy = event->y_offset();
    if (phase == ui::ScrollEventPhase::kBegan) {
      decided_ = false;
    }
    if (!pager_->is_swiping() && !decided_) {
      if (std::abs(dx) < 0.5 && std::abs(dy) < 0.5) {
        return;
      }
      decided_ = true;
      // Horizontal intent decides on the first meaningful delta.
      if (std::abs(dx) > std::abs(dy) * 1.2) {
        pager_->OnSwipeBegin(dx, dy);
      }
    }
    if (pager_->is_swiping()) {
      if (phase == ui::ScrollEventPhase::kEnd) {
        idle_timer_.Stop();
        pager_->OnSwipeEnd(/*cancelled=*/false);
        decided_ = false;
      } else {
        pager_->OnSwipeUpdate(dx);
        if (phase == ui::ScrollEventPhase::kNone) {
          idle_timer_.Start(FROM_HERE, kUnphasedIdle,
                            base::BindOnce(&SwipeHandler::OnIdle,
                                           base::Unretained(this)));
        }
      }
      event->SetHandled();
      event->StopPropagation();
      return;
    }
    if (phase == ui::ScrollEventPhase::kEnd ||
        phase == ui::ScrollEventPhase::kNone) {
      // Vertical gestures re-decide on their next stream.
      if (phase == ui::ScrollEventPhase::kEnd) {
        decided_ = false;
      } else {
        idle_timer_.Start(FROM_HERE, kUnphasedIdle,
                          base::BindOnce(&SwipeHandler::ResetDecision,
                                         base::Unretained(this)));
      }
    }
  }

 private:
  void OnIdle() {
    if (pager_->is_swiping()) {
      pager_->OnSwipeEnd(/*cancelled=*/false);
    }
    decided_ = false;
  }
  void ResetDecision() { decided_ = false; }

  raw_ptr<OpenSpacePagerView> pager_;
  bool decided_ = false;
  base::OneShotTimer idle_timer_;
};

// ---------------------------------------------------------------------------

OpenSpacePagerView::OpenSpacePagerView(OpenSidebarContext* context)
    : context_(context) {
  SetPaintToLayer();
  layer()->SetFillsBoundsOpaquely(false);
  layer()->SetMasksToBounds(true);
  auto strip = std::make_unique<views::View>();
  strip->SetPaintToLayer();
  strip->layer()->SetFillsBoundsOpaquely(false);
  strip_ = AddChildView(std::move(strip));
  slide_ = std::make_unique<motion::OpenSpringAnimator>(
      motion::kSpaceSwitch,
      base::BindRepeating(
          [](OpenSpacePagerView* self, double value) {
            self->offset_ = value;
            self->PlaceStrip(value);
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenSpacePagerView::OnSlideSettled,
                          base::Unretained(this)));
  slide_->set_epsilon(0.25);
  swipe_handler_ = std::make_unique<SwipeHandler>(this);
  AddPreTargetHandler(swipe_handler_.get());
}

OpenSpacePagerView::~OpenSpacePagerView() {
  RemovePreTargetHandler(swipe_handler_.get());
  slide_->SetCompositor(nullptr);
}

void OpenSpacePagerView::SetSpaces(const std::vector<SpaceID>& space_ids) {
  space_ids_ = space_ids;
  // Destroy pages of Spaces that left this window.
  for (auto it = pages_.begin(); it != pages_.end();) {
    if (std::find(space_ids_.begin(), space_ids_.end(), it->first) ==
        space_ids_.end()) {
      OpenTabTreeView* page = it->second;
      it->second = nullptr;
      it = pages_.erase(it);
      strip_->RemoveChildViewT(page);
    } else {
      ++it;
    }
  }
  const SpaceID focused = context_->FocusedSpaceId();
  if (!focused.empty() && IndexOf(focused) >= 0) {
    shown_space_id_ = focused;
  } else if (IndexOf(shown_space_id_) < 0) {
    shown_space_id_ = space_ids_.empty() ? SpaceID() : space_ids_.front();
  }
  if (!slide_->is_animating() && !swipe_) {
    const int index = std::max(0, IndexOf(shown_space_id_));
    offset_ = index * page_width();
  }
  if (!shown_space_id_.empty()) {
    GetPage(shown_space_id_);
    if (!slide_->is_animating() && !swipe_) {
      const int index = IndexOf(shown_space_id_);
      if (index >= 0) {
        SetPagesVisibleInRange(index, index);
      }
    }
  }
  InvalidateLayout();
}

void OpenSpacePagerView::ShowSpace(const SpaceID& space_id, bool animate) {
  const int index = IndexOf(space_id);
  if (index < 0) {
    return;
  }
  const double w = page_width();
  const double target = index * w;
  if (swipe_) {
    // The model moved focus during a swipe (keyboard): drop the swipe.
    swipe_.reset();
    context_->EndThemeTransition(/*commit=*/false);
  }
  if (space_id == shown_space_id_) {
    // A second request for the moving target continues the running slide.
    if (slide_->is_animating() ? slide_->target() == target
                               : offset_ == target) {
      return;
    }
  }
  shown_space_id_ = space_id;
  GetPage(space_id);
  const bool can_animate = animate && context_->AnimationsEnabled() &&
                           !motion::PrefersReducedMotion() &&
                           context_->AnimationCompositor() && w > 0;
  if (!can_animate) {
    slide_->SetCompositor(context_->AnimationCompositor());
    slide_->JumpTo(target);
    SetPagesVisibleInRange(index, index);
    context_->CrossfadeTheme(space_id, /*animated=*/false);
    return;
  }
  // Arc passes through every page between the old and the new Space.
  const int from = static_cast<int>(std::lround(offset_ / w));
  const int lo = std::min(from, index), hi = std::max(from, index);
  for (int i = lo; i <= hi; ++i) {
    if (i >= 0 && i < static_cast<int>(space_ids_.size())) {
      GetPage(space_ids_[static_cast<size_t>(i)]);
    }
  }
  SetPagesVisibleInRange(lo, hi);
  context_->CrossfadeTheme(space_id, /*animated=*/true);
  SlideTo(index, motion::kSpaceSwitch, offset_);
}

OpenTabTreeView* OpenSpacePagerView::GetPage(const SpaceID& space_id) {
  if (OpenTabTreeView* page = FindPage(space_id)) {
    return page;
  }
  if (IndexOf(space_id) < 0) {
    return nullptr;
  }
  OpenTabTreeView* page =
      strip_->AddChildView(std::make_unique<OpenTabTreeView>(context_, space_id));
  pages_.emplace(space_id, page);
  InvalidateLayout();
  return page;
}

OpenTabTreeView* OpenSpacePagerView::FindPage(const SpaceID& space_id) const {
  auto it = pages_.find(space_id);
  return it == pages_.end() ? nullptr : it->second.get();
}

void OpenSpacePagerView::ForEachPage(
    const std::function<void(OpenTabTreeView*)>& fn) const {
  for (const auto& [id, page] : pages_) {
    fn(page);
  }
}

bool OpenSpacePagerView::is_sliding() const {
  return slide_->is_animating();
}

int OpenSpacePagerView::IndexOf(const SpaceID& space_id) const {
  auto it = std::find(space_ids_.begin(), space_ids_.end(), space_id);
  return it == space_ids_.end() ? -1
                                : static_cast<int>(it - space_ids_.begin());
}

float OpenSpacePagerView::page_width() const {
  return static_cast<float>(width());
}

void OpenSpacePagerView::PlaceStrip(double offset) {
  // Transform only: no relayout and no repaint per frame.
  strip_->layer()->SetTransform(
      gfx::Transform::MakeTranslation(static_cast<float>(-offset), 0));
}

void OpenSpacePagerView::SlideTo(int index,
                                 motion::SpringToken spring,
                                 double from_offset) {
  slide_->SetSpring(spring);
  slide_->SetCompositor(context_->AnimationCompositor());
  slide_->AnimateFromTo(from_offset, index * page_width(),
                        slide_->is_animating() ? slide_->velocity() : 0.0);
}

void OpenSpacePagerView::OnSlideSettled() {
  // Hide the pages the slide passed through; they keep their state.
  const int index = IndexOf(shown_space_id_);
  if (index >= 0 && !swipe_) {
    SetPagesVisibleInRange(index, index);
  }
}

void OpenSpacePagerView::SetPagesVisibleInRange(int lo, int hi) {
  for (const auto& [id, page] : pages_) {
    const int i = IndexOf(id);
    page->SetVisible(i >= lo && i <= hi);
  }
}

void OpenSpacePagerView::Layout(PassKey) {
  const int w = width(), h = height();
  strip_->SetBounds(0, 0, std::max(1, w * static_cast<int>(std::max<size_t>(1, space_ids_.size()))), h);
  for (const auto& [id, page] : pages_) {
    const int i = IndexOf(id);
    page->SetBounds(i * w, 0, w, h);
  }
  if (!slide_->is_animating() && !swipe_) {
    offset_ = std::max(0, IndexOf(shown_space_id_)) * static_cast<double>(w);
  }
  PlaceStrip(offset_);
}

void OpenSpacePagerView::AddedToWidget() {
  slide_->SetCompositor(context_->AnimationCompositor());
}

void OpenSpacePagerView::RemovedFromWidget() {
  slide_->SetCompositor(nullptr);
}

bool OpenSpacePagerView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  // Discrete horizontal wheel (tilt wheels, Shift+wheel): one notch per Space.
  const double dx = event.x_offset();
  if (std::abs(dx) <= std::abs(static_cast<double>(event.y_offset())) ||
      swipe_) {
    return false;
  }
  wheel_accumulator_ += dx;
  wheel_reset_timer_.Start(
      FROM_HERE, kWheelReset,
      base::BindOnce([](double* acc) { *acc = 0; },
                     base::Unretained(&wheel_accumulator_)));
  if (std::abs(wheel_accumulator_) < kWheelNotch) {
    return true;
  }
  if (space_ids_.empty()) {
    wheel_accumulator_ = 0;
    return true;
  }
  const int base_index = IndexOf(shown_space_id_);
  const int target = std::clamp(base_index + (wheel_accumulator_ > 0 ? -1 : 1),
                                0, static_cast<int>(space_ids_.size()) - 1);
  wheel_accumulator_ = 0;
  if (target != base_index && target >= 0) {
    context_->Send(OpenIntent::ForSpace(OpenIntentKind::kSwitchSpace,
                                        space_ids_[static_cast<size_t>(target)]));
  }
  return true;
}

// --- Swipe -------------------------------------------------------------------

double OpenSpacePagerView::Rubber(double x, double w) {
  return (1 - 1 / (x * 0.55 / w + 1)) * w;
}

bool OpenSpacePagerView::OnSwipeBegin(double dx, double dy) {
  if (space_ids_.empty() || page_width() <= 0) {
    return false;
  }
  slide_->Stop();
  SwipeState s;
  s.base_index = std::max(0, IndexOf(shown_space_id_));
  swipe_ = s;
  const int n = static_cast<int>(space_ids_.size());
  for (int i = std::max(0, s.base_index - 1);
       i <= std::min(n - 1, s.base_index + 1); ++i) {
    GetPage(space_ids_[static_cast<size_t>(i)]);
  }
  SetPagesVisibleInRange(s.base_index - 1, s.base_index + 1);
  InvalidateLayout();
  return true;
}

bool OpenSpacePagerView::OnSwipeUpdate(double dx) {
  if (!swipe_) {
    return false;
  }
  SwipeState& s = *swipe_;
  s.last_deltas.push_back(dx);
  while (s.last_deltas.size() > 4) {
    s.last_deltas.pop_front();
  }
  const double w = page_width();
  const double base = s.base_index * w;
  const int n = static_cast<int>(space_ids_.size());
  double next = offset_ - dx;
  // Rubber band past the ends and beyond one neighbor.
  const double lo = std::max(0.0, (s.base_index - 1) * w);
  const double hi = std::min((n - 1) * w, base + w);
  if (next < lo) {
    next = lo - Rubber(lo - next, w);
  } else if (next > hi) {
    next = hi + Rubber(next - hi, w);
  }
  offset_ = next;
  s.past_threshold = std::abs(offset_ - base) / w > kSwitchDistance;
  if (!motion::PrefersReducedMotion()) {
    PlaceStrip(offset_);
  }
  const int dir = offset_ >= base ? 1 : -1;
  const int neighbor = s.base_index + dir;
  if (neighbor >= 0 && neighbor < n) {
    if (s.neighbor != neighbor) {
      context_->BeginThemeTransition(space_ids_[static_cast<size_t>(neighbor)]);
      s.neighbor = neighbor;
    }
    context_->SetThemeTransitionProgress(
        std::min(std::abs(offset_ - base) / w, 1.0));
  }
  return true;
}

bool OpenSpacePagerView::OnSwipeEnd(bool cancelled) {
  if (!swipe_) {
    return false;
  }
  const SwipeState s = *swipe_;
  swipe_.reset();
  const double w = page_width();
  const double velocity =
      s.last_deltas.empty()
          ? 0
          : std::accumulate(s.last_deltas.begin(), s.last_deltas.end(), 0.0) /
                static_cast<double>(s.last_deltas.size());
  const double moved = (offset_ - s.base_index * w) / w;
  int target = s.base_index;
  // std::clamp below needs a non-empty list (hi = size - 1 >= lo = 0).
  if (!cancelled && !space_ids_.empty() &&
      (std::abs(moved) > kSwitchDistance ||
       (std::abs(velocity) > kFlickVelocity &&
        std::abs(moved) > kFlickDistance))) {
    target = std::clamp(s.base_index + (moved > 0 ? 1 : -1), 0,
                        static_cast<int>(space_ids_.size()) - 1);
  }
  const bool animate = context_->AnimationsEnabled() &&
                       !motion::PrefersReducedMotion();
  if (target != s.base_index) {
    // Commit the snap before the synchronous Space switch swaps content.
    shown_space_id_ = space_ids_[static_cast<size_t>(target)];
    if (animate) {
      SlideTo(target, motion::kSpaceSwipeSnap, offset_);
    } else {
      slide_->JumpTo(target * w);
      OnSlideSettled();
    }
    context_->EndThemeTransition(/*commit=*/s.neighbor == target);
    if (s.neighbor != target) {
      context_->CrossfadeTheme(space_ids_[static_cast<size_t>(target)], /*animated=*/true);
    }
    context_->Send(
        OpenIntent::ForSpace(OpenIntentKind::kSwitchSpace, space_ids_[static_cast<size_t>(target)]));
  } else {
    context_->EndThemeTransition(/*commit=*/false);
    if (animate) {
      SlideTo(s.base_index, motion::kSpaceSwipeSnap, offset_);
    } else {
      slide_->JumpTo(s.base_index * w);
      OnSlideSettled();
    }
  }
  return true;
}

BEGIN_METADATA(OpenSpacePagerView)
END_METADATA

}  // namespace open_unified
