// Copyright 2026 The Open Authors. All rights reserved.
//
// Open motion tokens (port of Packages/OpenKit/Sources/OpenDesign/Motion.swift)
// and a display-rate spring animator for Chromium Views.
//
// Springs use SwiftUI-style response R and damping fraction zeta:
//   omega = 2 pi / R, stiffness k = omega^2, damping c = 2 zeta omega (m = 1).
// The animator is driven by ui::CompositorAnimationObserver, so it steps once
// per compositor frame (120 Hz on ProMotion / high refresh panels) and stops
// requesting frames the moment it settles (idle CPU stays at zero).

#ifndef OPEN_UNIFIED_UI_DESIGN_OPEN_MOTION_H_
#define OPEN_UNIFIED_UI_DESIGN_OPEN_MOTION_H_

#include <optional>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/time/time.h"
#include "ui/compositor/compositor_animation_observer.h"
#include "ui/gfx/geometry/cubic_bezier.h"

namespace ui {
class Compositor;
}

namespace open_unified::motion {

struct SpringToken {
  double response = 0.2;          // seconds
  double damping_fraction = 1.0;  // zeta

  double omega() const;
  double stiffness() const;
  double damping() const;
};

struct CubicCurve {
  double x1 = 0, y1 = 0, x2 = 1, y2 = 1;
};

// --- Tokens (Motion.swift; evidence in docs/design.md section 2.4) --------
// Sidebar hide and show (Cmd+S): R 0.10 s, zeta 0.95.
inline constexpr SpringToken kSidebarToggle{0.10, 0.95};
// Show uses an equivalent image fit: 0.075834 s with this curve.
inline constexpr double kSidebarShowDuration = 0.075834;
inline constexpr CubicCurve kSidebarShowCurve{0.01055, 0.50742, 0.55930,
                                              0.98516};
// Space page slide: R 0.20 s, critical (visually settled ~0.27 s).
inline constexpr SpringToken kSpaceSwitch{0.20, 1.0};
// Snap after a two-finger swipe ends.
inline constexpr SpringToken kSpaceSwipeSnap{0.26, 0.92};
// Hover-reveal card in: 2.9 pt overshoot on 223 pt travel. Out: 0.105 s.
inline constexpr SpringToken kRevealCardIn{0.164, 0.81};
inline constexpr double kRevealCardOut = 0.105;
// Background cross-fade between Spaces: linear, 0.21 s.
inline constexpr double kThemeCrossfade = 0.21;
inline constexpr double kSpacePlateRetire = 0.10;
inline constexpr double kHoverFade = 0.08;
inline constexpr double kSelectionFade = 0.12;
inline constexpr double kRowStructure = 0.22;
inline constexpr double kFolderExpand = 0.20;    // ease-out
inline constexpr double kFolderCollapse = 0.25;  // default curve
inline constexpr double kTooltipFade = 0.12;
inline constexpr double kRowAudioReveal = 0.16;
inline constexpr CubicCurve kRowAudioRevealCurve{0.25, 0.46, 0.45, 0.94};
inline constexpr SpringToken kUnreadAppear{0.2, 0.8};
inline constexpr double kUnreadClearFade = 0.12;
inline constexpr double kSplitExpand = 0.22;
inline constexpr double kSplitRemove = 0.14;
inline constexpr double kPeekOpen = 0.10;
inline constexpr double kPeekDismiss = 0.14;
inline constexpr double kPeekExpand = 0.22;
inline constexpr SpringToken kToastIn{0.32, 0.8};
inline constexpr double kToastFadeIn = 0.12;
inline constexpr double kToastOut = 0.16;

base::TimeDelta Seconds(double s);

// --- Spring solver ---------------------------------------------------------
// State of a damped spring whose target is 0: `position` is the displacement
// from the target, `velocity` its derivative (units per second).
struct SpringState {
  double position = 0;
  double velocity = 0;
};
// Exact closed form for under-, critically- and over-damped springs.
SpringState EvaluateSpring(const SpringToken& spring,
                           double initial_position,
                           double initial_velocity,
                           double t);
// Spring progress 0 -> 1 from rest (Motion.springProgress).
double SpringProgress(const SpringToken& spring, double t);
// Time until |position| < epsilon and |velocity| < 10 epsilon (cap 4 s).
double SettlingDuration(const SpringToken& spring,
                        double initial_position,
                        double initial_velocity,
                        double epsilon);

// True when the platform asks for reduced motion.
bool PrefersReducedMotion();

// --- Display-rate animator --------------------------------------------------
// Animates one scalar. Each compositor frame it calls `on_step(value)`; the
// owner applies it (usually a ui::Layer transform, so no relayout and no web
// content resize happens per frame). `on_settled` runs once at rest.
class OpenSpringAnimator : public ui::CompositorAnimationObserver {
 public:
  using StepCallback = base::RepeatingCallback<void(double value)>;

  OpenSpringAnimator(SpringToken spring,
                     StepCallback on_step,
                     base::RepeatingClosure on_settled = {});
  OpenSpringAnimator(const OpenSpringAnimator&) = delete;
  OpenSpringAnimator& operator=(const OpenSpringAnimator&) = delete;
  ~OpenSpringAnimator() override;

  // Animations need a compositor; without one (hidden or detached views)
  // every request jumps to its target.
  void SetCompositor(ui::Compositor* compositor);
  void SetSpring(SpringToken spring) { spring_ = spring; }
  // Settle threshold in value units (default 0.1, i.e. 0.1 pt for offsets).
  void set_epsilon(double epsilon) { epsilon_ = epsilon; }

  // Spring to `target` from the current presentation value, keeping the
  // current velocity (a switch during a switch continues smoothly).
  void AnimateTo(double target);
  void AnimateFromTo(double from, double target, double velocity = 0);
  // Timed curve (used for the sidebar show fit).
  void AnimateTimed(double from,
                    double target,
                    base::TimeDelta duration,
                    CubicCurve curve);
  // Stops and applies `value` at once (calls on_step, not on_settled).
  void JumpTo(double value);
  void Stop();

  bool is_animating() const { return animating_; }
  double value() const { return value_; }
  double target() const { return target_; }
  double velocity() const { return velocity_; }

 private:
  enum class Mode { kSpring, kTimed };

  // ui::CompositorAnimationObserver:
  void OnAnimationStep(base::TimeTicks timestamp) override;
  void OnCompositingShuttingDown(ui::Compositor* compositor) override;

  void Begin();
  void Finish();
  void Detach();

  SpringToken spring_;
  StepCallback on_step_;
  base::RepeatingClosure on_settled_;
  raw_ptr<ui::Compositor> compositor_ = nullptr;
  bool observing_ = false;
  bool animating_ = false;
  Mode mode_ = Mode::kSpring;
  double value_ = 0;
  double target_ = 0;
  double velocity_ = 0;
  double epsilon_ = 0.1;
  // Spring segment parameters.
  double segment_x0_ = 0;
  double segment_v0_ = 0;
  // Timed segment parameters.
  double timed_from_ = 0;
  base::TimeDelta timed_duration_;
  std::optional<gfx::CubicBezier> timed_curve_;
  std::optional<base::TimeTicks> segment_start_;
  std::optional<base::TimeTicks> last_step_;
};

}  // namespace open_unified::motion

#endif  // OPEN_UNIFIED_UI_DESIGN_OPEN_MOTION_H_
