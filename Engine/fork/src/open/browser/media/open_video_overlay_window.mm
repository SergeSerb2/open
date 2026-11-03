// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/browser/media/open_video_overlay_window.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "cc/layers/deadline_policy.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "content/public/browser/context_factory.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "content/public/browser/web_contents.h"
#include "open/browser/media/open_media_controller.h"
#include "open/browser/media/open_media_hooks.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/accelerated_widget_mac/display_ca_layer_tree.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_solid_color.h"
#include "ui/compositor/layer_surface.h"
#include "ui/compositor/recyclable_compositor_mac.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/gfx/geometry/dip_util.h"
#include "ui/gfx/geometry/size_conversions.h"

// The view the embedder puts into its Picture in Picture window. It hosts the
// compositor's CALayer tree and takes no events: the embedder's controls
// above it get them.
@interface OpenPiPVideoView : NSView
- (instancetype)initWithOwner:(open_engine::OpenVideoOverlayWindow*)owner;
- (void)detachOwner;
@end

@implementation OpenPiPVideoView {
  raw_ptr<open_engine::OpenVideoOverlayWindow> _owner;
}

- (instancetype)initWithOwner:(open_engine::OpenVideoOverlayWindow*)owner {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 320, 180)])) {
    _owner = owner;
    CALayer* background = [CALayer layer];
    background.backgroundColor = NSColor.blackColor.CGColor;
    // Layer-hosting: the compositor's DisplayCALayerTree adds its layers here.
    self.layer = background;
    self.wantsLayer = YES;
  }
  return self;
}

- (void)detachOwner {
  _owner = nullptr;
}

- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  if (_owner) {
    _owner->OnViewChanged();
  }
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  if (_owner) {
    _owner->OnViewChanged();
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (_owner) {
    _owner->OnViewChanged();
  }
}

@end

namespace open_engine {

// One shown session of the window (CefPictureInPictureWindow). Chromium may
// reuse its window for the next player; each ShowInactive after a Hide gets
// a new session, and an ended session ignores every call.
class OpenPictureInPictureSession : public CefPictureInPictureWindow {
 public:
  explicit OpenPictureInPictureSession(
      base::WeakPtr<OpenVideoOverlayWindow> window)
      : window_(std::move(window)) {}
  OpenPictureInPictureSession(const OpenPictureInPictureSession&) = delete;
  OpenPictureInPictureSession& operator=(const OpenPictureInPictureSession&) =
      delete;

  void Invalidate() { window_ = nullptr; }

  // CefPictureInPictureWindow:
  bool IsValid() override {
    CEF_REQUIRE_UIT_RETURN(false);
    return !!window_;
  }
  CefWindowHandle GetVideoView() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    return window_ ? (__bridge CefWindowHandle)window_->video_view() : nullptr;
  }
  CefRefPtr<CefDictionaryValue> GetState() override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    return window_ ? window_->GetState() : CefDictionaryValue::Create();
  }
  void SetWindowFrame(const CefRect& frame, bool visible) override {
    CEF_REQUIRE_UIT();
    if (window_) {
      window_->SetWindowFrame(
          gfx::Rect(frame.x, frame.y, frame.width, frame.height), visible);
    }
  }
  void ExecuteAction(const CefString& action,
                     CefRefPtr<CefDictionaryValue> args) override {
    CEF_REQUIRE_UIT();
    if (window_) {
      window_->ExecuteAction(action.ToString(), args);
    }
  }

 private:
  ~OpenPictureInPictureSession() override = default;

  base::WeakPtr<OpenVideoOverlayWindow> window_;

  IMPLEMENT_REFCOUNTING(OpenPictureInPictureSession);
};

namespace {

// The largest rectangle of |content|'s aspect ratio inside |bounds|, centered
// (VideoOverlayWindowViews::UpdateLayerBoundsWithLetterboxing).
gfx::Rect Letterbox(const gfx::Size& bounds, const gfx::Size& content) {
  if (content.IsEmpty() || bounds.IsEmpty()) {
    return gfx::Rect(bounds);
  }
  const double scale =
      std::min(static_cast<double>(bounds.width()) / content.width(),
               static_cast<double>(bounds.height()) / content.height());
  const int width = std::max(1, static_cast<int>(std::lround(content.width() * scale)));
  const int height =
      std::max(1, static_cast<int>(std::lround(content.height() * scale)));
  return gfx::Rect((bounds.width() - width) / 2, (bounds.height() - height) / 2,
                   width, height);
}

}  // namespace

std::unique_ptr<content::VideoOverlayWindow> MaybeCreateVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller) {
  OpenMediaController* media =
      controller ? OpenMediaController::FromWebContents(
                       controller->GetWebContents())
                 : nullptr;
  CefRefPtr<CefMediaControllerHandler> handler;
  CefRefPtr<CefBrowser> browser;
  if (!media || !media->GetPictureInPictureHost(&handler, &browser)) {
    return nullptr;
  }
  return std::make_unique<OpenVideoOverlayWindow>(controller, handler, browser);
}

OpenVideoOverlayWindow::OpenVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller,
    CefRefPtr<CefMediaControllerHandler> handler,
    CefRefPtr<CefBrowser> browser)
    : controller_(controller),
      handler_(std::move(handler)),
      browser_(std::move(browser)) {
  view_ = [[OpenPiPVideoView alloc] initWithOwner:this];
  ca_layer_tree_ = std::make_unique<ui::DisplayCALayerTree>(view_.layer);

  compositor_ = std::make_unique<ui::RecyclableCompositorMac>(
      content::GetContextFactory());
  root_ = std::make_unique<ui::LayerSolidColor>();
  root_->SetName("OpenVideoOverlayWindow:Root");
  root_->SetColor(SkColors::kBlack);
  video_ = std::make_unique<ui::LayerSurface>();
  video_->SetName("OpenVideoOverlayWindow:Video");
  video_->SetFallbackBackgroundColor(SkColors::kBlack);
  root_->Add(video_.get());
  compositor_->compositor()->SetRootLayer(root_.get());
  compositor_->compositor()->SetBackgroundColor(SK_ColorBLACK);
  compositor_->widget()->SetNSView(this);
  // The compositor starts suspended; ShowInactive starts the frames.
  UpdateLayout();
}

OpenVideoOverlayWindow::~OpenVideoOverlayWindow() {
  if (CefRefPtr<OpenPictureInPictureSession> ended = EndSession()) {
    CefRefPtr<CefPictureInPictureWindow> window(ended.get());
    CefRefPtr<CefMediaControllerHandler> handler = handler_;
    CefRefPtr<CefBrowser> browser = browser_;
    CEF_POST_TASK(CEF_UIT, base::BindOnce(
                               [](CefRefPtr<CefMediaControllerHandler> handler,
                                  CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefPictureInPictureWindow> window) {
                                 handler->OnPictureInPictureClosed(browser,
                                                                   window);
                               },
                               handler, browser, window));
  }
  [view_ detachOwner];
  compositor_->widget()->ResetNSView();
  compositor_->compositor()->SetRootLayer(nullptr);
  compositor_.reset();
  ca_layer_tree_.reset();
  video_.reset();
  root_.reset();
}

bool OpenVideoOverlayWindow::IsActive() const {
  return view_.window.isKeyWindow;
}

void OpenVideoOverlayWindow::Close() {
  // Only from the controller's WebContentsDestroyed: the controller and its
  // page are going away, so nothing here may call back into them. The
  // embedder hears of the end on the next turn.
  closed_ = true;
  visible_ = false;
  controller_ = nullptr;
  if (CefRefPtr<OpenPictureInPictureSession> ended = EndSession()) {
    CefRefPtr<CefPictureInPictureWindow> window(ended.get());
    CEF_POST_TASK(CEF_UIT, base::BindOnce(
                               [](CefRefPtr<CefMediaControllerHandler> handler,
                                  CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefPictureInPictureWindow> window) {
                                 handler->OnPictureInPictureClosed(browser,
                                                                   window);
                               },
                               handler_, browser_, window));
  }
}

void OpenVideoOverlayWindow::ShowInactive() {
  if (closed_) {
    return;
  }
  visible_ = true;
  compositor_->Unsuspend();
  if (session_) {
    // The same session goes on (a new surface or player state).
    ScheduleChanged();
    return;
  }
  session_ = new OpenPictureInPictureSession(weak_ptr_factory_.GetWeakPtr());
  // Synchronous: the embedder makes its window and calls SetWindowFrame
  // before Chromium reads GetBounds for the renderer's window size.
  handler_->OnPictureInPictureOpened(
      browser_, CefRefPtr<CefPictureInPictureWindow>(session_.get()));
}

void OpenVideoOverlayWindow::Hide() {
  visible_ = false;
  if (CefRefPtr<OpenPictureInPictureSession> ended = EndSession()) {
    handler_->OnPictureInPictureClosed(
        browser_, CefRefPtr<CefPictureInPictureWindow>(ended.get()));
  }
}

bool OpenVideoOverlayWindow::IsVisible() const {
  // Shown since ShowInactive and not hidden since (see SetWindowFrame).
  return visible_;
}

gfx::Rect OpenVideoOverlayWindow::GetBounds() {
  return frame_in_screen_;
}

void OpenVideoOverlayWindow::UpdateNaturalSize(const gfx::Size& natural_size) {
  if (natural_size_ == natural_size) {
    return;
  }
  natural_size_ = natural_size;
  UpdateLayout();
  ScheduleChanged();
}

void OpenVideoOverlayWindow::SetPlaybackState(PlaybackState playback_state) {
  if (playback_state_ != playback_state) {
    playback_state_ = playback_state;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::SetPlayPauseButtonVisibility(bool is_visible) {
  SetControl(kPlayPause, is_visible);
}
void OpenVideoOverlayWindow::SetSkipAdButtonVisibility(bool is_visible) {
  SetControl(kSkipAd, is_visible);
}
void OpenVideoOverlayWindow::SetNextTrackButtonVisibility(bool is_visible) {
  SetControl(kNextTrack, is_visible);
}
void OpenVideoOverlayWindow::SetPreviousTrackButtonVisibility(bool is_visible) {
  SetControl(kPreviousTrack, is_visible);
}
void OpenVideoOverlayWindow::SetToggleMicrophoneButtonVisibility(
    bool is_visible) {
  SetControl(kToggleMicrophone, is_visible);
}
void OpenVideoOverlayWindow::SetToggleCameraButtonVisibility(bool is_visible) {
  SetControl(kToggleCamera, is_visible);
}
void OpenVideoOverlayWindow::SetHangUpButtonVisibility(bool is_visible) {
  SetControl(kHangUp, is_visible);
}
void OpenVideoOverlayWindow::SetNextSlideButtonVisibility(bool is_visible) {
  SetControl(kNextSlide, is_visible);
}
void OpenVideoOverlayWindow::SetPreviousSlideButtonVisibility(
    bool is_visible) {
  SetControl(kPreviousSlide, is_visible);
}

void OpenVideoOverlayWindow::SetMicrophoneMuted(bool muted) {
  if (microphone_muted_ != muted) {
    microphone_muted_ = muted;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::SetCameraState(bool turned_on) {
  if (camera_on_ != turned_on) {
    camera_on_ = turned_on;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::SetMediaMuted(bool muted) {
  if (media_muted_ != muted) {
    media_muted_ = muted;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::SetMediaPosition(
    const media_session::MediaPosition& position) {
  position_ = position;
  ScheduleChanged();
}

void OpenVideoOverlayWindow::SetSourceTitle(
    const std::u16string& source_title) {
  if (source_title_ != source_title) {
    source_title_ = source_title;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::SetSurfaceId(const viz::SurfaceId& surface_id) {
  // A window that stays open may get the surface of the next player: the
  // previous frame sink goes first, or the video stops updating
  // (VideoOverlayWindowViews::SetSurfaceId).
  RemoveChildFrameSink();
  compositor_->compositor()->AddChildFrameSink(surface_id.frame_sink_id());
  child_frame_sink_ = surface_id.frame_sink_id();
  surface_id_ = surface_id;
  video_->SetShowSurface(surface_id, video_->bounds().size(),
                         cc::DeadlinePolicy::UseDefaultDeadline(),
                         /*stretch_content_to_fill_bounds=*/true);
}

void OpenVideoOverlayWindow::SetPlaybackControlsVisibility(bool is_visible) {
  if (controls_visible_ != is_visible) {
    controls_visible_ = is_visible;
    ScheduleChanged();
  }
}

void OpenVideoOverlayWindow::AcceleratedWidgetCALayerParamsUpdated(
    gfx::CALayerParams ca_layer_params) {
  if (ca_layer_tree_) {
    ca_layer_tree_->UpdateCALayerTree(std::move(ca_layer_params));
  }
}

CefRefPtr<CefDictionaryValue> OpenVideoOverlayWindow::GetState() const {
  auto state = CefDictionaryValue::Create();
  state->SetInt("naturalWidth", natural_size_.width());
  state->SetInt("naturalHeight", natural_size_.height());
  const gfx::Rect source =
      controller_ ? controller_->GetSourceBounds() : gfx::Rect();
  state->SetInt("sourceX", source.x());
  state->SetInt("sourceY", source.y());
  state->SetInt("sourceWidth", source.width());
  state->SetInt("sourceHeight", source.height());
  state->SetInt("playbackState", static_cast<int>(playback_state_));
  state->SetInt("controls", static_cast<int>(controls_));
  state->SetBool("controlsVisible", controls_visible_);
  state->SetBool("windowVisible", embedder_visible_);
  state->SetBool("microphoneMuted", microphone_muted_);
  state->SetBool("cameraOn", camera_on_);
  state->SetBool("mediaMuted", media_muted_);
  state->SetString("sourceTitle", base::UTF16ToUTF8(source_title_));
  if (position_) {
    auto position = CefDictionaryValue::Create();
    const base::TimeDelta duration = position_->duration();
    const bool live = duration.is_max() || duration.is_inf();
    position->SetBool("live", live);
    position->SetDouble("duration", live ? 0 : duration.InSecondsF());
    position->SetDouble("position", position_->GetPosition().InSecondsF());
    position->SetDouble("rate", position_->playback_rate());
    position->SetBool("ended", position_->end_of_media());
    position->SetDouble("lastUpdated",
                        base::Time::Now().InSecondsFSinceUnixEpoch());
    state->SetDictionary("position", position);
  }
  return state;
}

void OpenVideoOverlayWindow::SetWindowFrame(const gfx::Rect& frame_in_screen,
                                            bool visible) {
  const bool resized = frame_in_screen.size() != frame_in_screen_.size();
  frame_in_screen_ = frame_in_screen;
  frame_reported_ = true;
  // The embedder's own visibility (a window it hid or is closing) is not
  // Chromium's "visible": that means the session is shown, and Chromium's
  // Close() does nothing for a window that is not visible.
  embedder_visible_ = visible;
  // Tells the renderer the new window size (PiP "resize" event); Chromium
  // reads it back through GetBounds.
  if (resized && controller_ && session_) {
    controller_->UpdateLayerBounds();
  }
}

void OpenVideoOverlayWindow::ExecuteAction(
    const std::string& action,
    CefRefPtr<CefDictionaryValue> args) {
  if (!controller_ || !session_) {
    return;
  }
  if (action == "togglePlayPause") {
    controller_->TogglePlayPause();
  } else if (action == "nextTrack") {
    controller_->NextTrack();
  } else if (action == "previousTrack") {
    controller_->PreviousTrack();
  } else if (action == "skipAd") {
    controller_->SkipAd();
  } else if (action == "toggleMicrophone") {
    controller_->ToggleMicrophone();
  } else if (action == "toggleCamera") {
    controller_->ToggleCamera();
  } else if (action == "hangUp") {
    controller_->HangUp();
  } else if (action == "nextSlide") {
    controller_->NextSlide();
  } else if (action == "previousSlide") {
    controller_->PreviousSlide();
  } else if (action == "seekTo") {
    const double time = args ? args->GetDouble("time") : 0;
    if (std::isfinite(time)) {
      controller_->SeekTo(base::Seconds(std::max(0.0, time)));
    }
  } else if (action == "setMuted") {
    controller_->RequestMute(args && args->GetBool("muted"));
  } else if (action == "close") {
    // Through the manager, so Chromium's auto Picture in Picture keeps its
    // "user closed" bookkeeping. Posted: the close ends in Hide, which calls
    // the embedder, which is inside this call now.
    using UiBehavior = PictureInPictureWindowManager::UiBehavior;
    const int behavior = args ? args->GetInt("behavior") : 0;
    UiBehavior ui = UiBehavior::kCloseWindowOnly;
    if (behavior == 1 && (controls_ & kPlayPause)) {
      ui = UiBehavior::kCloseWindowAndPauseVideo;
    } else if (behavior == 2) {
      ui = UiBehavior::kCloseWindowAndFocusOpener;
    }
    CEF_POST_TASK(
        CEF_UIT,
        base::BindOnce(
            [](base::WeakPtr<OpenVideoOverlayWindow> window, UiBehavior ui) {
              if (window && window->session_) {
                PictureInPictureWindowManager::GetInstance()
                    ->ExitPictureInPictureViaWindowUi(ui);
              }
            },
            weak_ptr_factory_.GetWeakPtr(), ui));
  }
}

void OpenVideoOverlayWindow::OnViewChanged() {
  UpdateLayout();
}

void OpenVideoOverlayWindow::SetControl(Control control, bool visible) {
  const uint32_t controls = visible ? (controls_ | control) : (controls_ & ~control);
  if (controls != controls_) {
    controls_ = controls;
    ScheduleChanged();
  }
}

CefRefPtr<OpenPictureInPictureSession> OpenVideoOverlayWindow::EndSession() {
  RemoveChildFrameSink();
  surface_id_.reset();
  if (compositor_) {
    compositor_->Suspend();
  }
  changed_pending_ = false;
  if (!session_) {
    return nullptr;
  }
  session_->Invalidate();
  return std::move(session_);
}

void OpenVideoOverlayWindow::RemoveChildFrameSink() {
  if (child_frame_sink_ && compositor_) {
    compositor_->compositor()->RemoveChildFrameSink(*child_frame_sink_);
  }
  child_frame_sink_.reset();
}

void OpenVideoOverlayWindow::UpdateLayout() {
  const NSSize size = view_.bounds.size;
  const gfx::Size dip(std::max(1, static_cast<int>(std::lround(size.width))),
                      std::max(1, static_cast<int>(std::lround(size.height))));
  display::Screen* screen = display::Screen::Get();
  const display::Display display =
      view_.window ? screen->GetDisplayNearestView(gfx::NativeView(view_))
                   : screen->GetPrimaryDisplay();
  const float scale = view_.window
                          ? static_cast<float>(view_.window.backingScaleFactor)
                          : display.device_scale_factor();
  compositor_->UpdateSurface(
      gfx::ToRoundedSize(gfx::ConvertSizeToPixels(dip, scale)), scale,
      display.GetColorSpaces(), display.id(), display.display_frequency());
  root_->SetBounds(gfx::Rect(dip));
  video_->SetBounds(Letterbox(dip, natural_size_));
}

void OpenVideoOverlayWindow::ScheduleChanged() {
  if (!session_ || changed_pending_) {
    return;
  }
  changed_pending_ = true;
  CEF_POST_TASK(CEF_UIT,
                base::BindOnce(&OpenVideoOverlayWindow::DeliverChanged,
                               weak_ptr_factory_.GetWeakPtr()));
}

void OpenVideoOverlayWindow::DeliverChanged() {
  if (!changed_pending_ || !session_) {
    return;
  }
  changed_pending_ = false;
  handler_->OnPictureInPictureChanged(
      browser_, CefRefPtr<CefPictureInPictureWindow>(session_.get()));
}

}  // namespace open_engine
