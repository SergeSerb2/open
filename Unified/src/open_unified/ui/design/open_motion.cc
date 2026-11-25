// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/design/open_motion.h"

#include <algorithm>
#include <cmath>
#include <numbers>

#include "ui/compositor/compositor.h"
#include "ui/gfx/animation/animation.h"

namespace open_unified::motion {

double SpringToken::omega() const {
  return 2 * std::numbers::pi / std::max(response, 1e-6);
}

double SpringToken::stiffness() const {
  return omega() * omega();
}

double SpringToken::damping() const {
  return 2 * damping_fraction * omega();
}

base::TimeDelta Seconds(double s) {
  return base::Microseconds(static_cast<int64_t>(std::llround(s * 1e6)));
}

SpringState EvaluateSpring(const SpringToken& spring,
                           double x0,
                           double v0,
                           double t) {
  const double w = spring.omega();
  const double z = spring.damping_fraction;
  if (std::abs(z - 1.0) < 1e-6) {
    const double e = std::exp(-w * t);
    const double b = v0 + w * x0;
    return {(x0 + b * t) * e, (v0 - w * b * t) * e};
  }
  if (z < 1.0) {
    const double a = z * w;
    const double wd = w * std::sqrt(1 - z * z);
    const double e = std::exp(-a * t);
    const double c = std::cos(wd * t), s = std::sin(wd * t);
    return {e * (x0 * c + (v0 + a * x0) / wd * s),
            e * (v0 * c - (a * v0 + w * w * x0) / wd * s)};
  }
  const double root = std::sqrt(z * z - 1);
  const double r1 = -w * (z - root);
  const double r2 = -w * (z + root);
  const double c2 = (v0 - r1 * x0) / (r2 - r1);
  const double c1 = x0 - c2;
  const double e1 = std::exp(r1 * t), e2 = std::exp(r2 * t);
  return {c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2};
}

double SpringProgress(const SpringToken& spring, double t) {
  return 1 - EvaluateSpring(spring, 1.0, 0.0, t).position;
}

double SettlingDuration(const SpringToken& spring,
                        double x0,
                        double v0,
                        double epsilon) {
  constexpr double kStep = 1.0 / 240;
  constexpr double kCap = 4.0;
  double settled_since = -1;
  for (double t = 0; t < kCap; t += kStep) {
    const SpringState s = EvaluateSpring(spring, x0, v0, t);
    const bool at_rest =
        std::abs(s.position) < epsilon && std::abs(s.velocity) < 10 * epsilon;
    if (at_rest) {
      if (settled_since < 0) {
        settled_since = t;
      }
      // Stay at rest for a few frames to skip zero crossings.
      if (t - settled_since > 4 * kStep) {
        return settled_since;
      }
    } else {
      settled_since = -1;
    }
  }
  return kCap;
}

bool PrefersReducedMotion() {
  return gfx::Animation::PrefersReducedMotion();
}

// ---------------------------------------------------------------------------

OpenSpringAnimator::OpenSpringAnimator(SpringToken spring,
                                       StepCallback on_step,
                                       base::RepeatingClosure on_settled)
    : spring_(spring),
      on_step_(std::move(on_step)),
      on_settled_(std::move(on_settled)) {}

OpenSpringAnimator::~OpenSpringAnimator() {
  Detach();
}

void OpenSpringAnimator::SetCompositor(ui::Compositor* compositor) {
  if (compositor_ == compositor) {
    return;
  }
  const bool was_animating = animating_;
  Detach();
  compositor_ = compositor;
  if (was_animating) {
    // Without a compositor the animation cannot continue; land on target.
    if (!compositor_) {
      JumpTo(target_);
      if (on_settled_) {
        on_settled_.Run();
      }
    } else {
      Begin();
    }
  }
}

void OpenSpringAnimator::AnimateTo(double target) {
  AnimateFromTo(value_, target, animating_ ? velocity_ : 0.0);
}

void OpenSpringAnimator::AnimateFromTo(double from,
                                       double target,
                                       double velocity) {
  target_ = target;
  if (!compositor_ || PrefersReducedMotion()) {
    JumpTo(target);
    if (on_settled_) {
      on_settled_.Run();
    }
    return;
  }
  mode_ = Mode::kSpring;
  value_ = from;
  velocity_ = velocity;
  segment_x0_ = from - target;
  segment_v0_ = velocity;
  segment_start_.reset();
  Begin();
}

void OpenSpringAnimator::AnimateTimed(double from,
                                      double target,
                                      base::TimeDelta duration,
                                      CubicCurve curve) {
  target_ = target;
  if (!compositor_ || PrefersReducedMotion() || duration.is_zero()) {
    JumpTo(target);
    if (on_settled_) {
      on_settled_.Run();
    }
    return;
  }
  mode_ = Mode::kTimed;
  value_ = from;
  velocity_ = 0;
  timed_from_ = from;
  timed_duration_ = duration;
  timed_curve_.emplace(curve.x1, curve.y1, curve.x2, curve.y2);
  segment_start_.reset();
  Begin();
}

void OpenSpringAnimator::JumpTo(double value) {
  Stop();
  value_ = value;
  target_ = value;
  velocity_ = 0;
  if (on_step_) {
    on_step_.Run(value_);
  }
}

void OpenSpringAnimator::Stop() {
  animating_ = false;
  segment_start_.reset();
  last_step_.reset();
  Detach();
}

void OpenSpringAnimator::Begin() {
  animating_ = true;
  last_step_.reset();
  if (compositor_ && !observing_) {
    compositor_->AddAnimationObserver(this);
    observing_ = true;
  }
}

void OpenSpringAnimator::Finish() {
  value_ = target_;
  velocity_ = 0;
  Stop();
  if (on_step_) {
    on_step_.Run(value_);
  }
  if (on_settled_) {
    on_settled_.Run();
  }
}

void OpenSpringAnimator::Detach() {
  if (compositor_ && observing_) {
    compositor_->RemoveAnimationObserver(this);
  }
  observing_ = false;
}

void OpenSpringAnimator::OnAnimationStep(base::TimeTicks timestamp) {
  if (!animating_) {
    Detach();
    return;
  }
  if (!segment_start_) {
    // The first frame presents the start value, so motion begins within one
    // scheduled frame of the request.
    segment_start_ = timestamp;
  }
  const double t = (timestamp - *segment_start_).InSecondsF();
  if (mode_ == Mode::kTimed) {
    const double total = timed_duration_.InSecondsF();
    const double p = std::clamp(t / total, 0.0, 1.0);
    const double eased = timed_curve_ ? timed_curve_->Solve(p) : p;
    const double previous = value_;
    value_ = timed_from_ + (target_ - timed_from_) * eased;
    if (last_step_) {
      const double dt = (timestamp - *last_step_).InSecondsF();
      velocity_ = dt > 0 ? (value_ - previous) / dt : velocity_;
    }
    last_step_ = timestamp;
    if (p >= 1.0) {
      Finish();
      return;
    }
  } else {
    const SpringState s = EvaluateSpring(spring_, segment_x0_, segment_v0_, t);
    value_ = target_ + s.position;
    velocity_ = s.velocity;
    last_step_ = timestamp;
    if (std::abs(s.position) < epsilon_ &&
        std::abs(s.velocity) < 10 * epsilon_ && t > 0) {
      Finish();
      return;
    }
  }
  if (on_step_) {
    on_step_.Run(value_);
  }
}

void OpenSpringAnimator::OnCompositingShuttingDown(ui::Compositor* compositor) {
  if (compositor != compositor_) {
    return;
  }
  observing_ = false;
  compositor_ = nullptr;
  if (animating_) {
    Finish();
  }
}

}  // namespace open_unified::motion
