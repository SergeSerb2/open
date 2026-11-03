// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEDIA_OPEN_VIDEO_OVERLAY_WINDOW_H_
#define OPEN_BROWSER_MEDIA_OPEN_VIDEO_OVERLAY_WINDOW_H_

#include <memory>
#include <optional>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "cef/include/cef_media_controller.h"
#include "components/viz/common/surfaces/frame_sink_id.h"
#include "components/viz/common/surfaces/surface_id.h"
#include "content/public/browser/overlay_window.h"
#include "services/media_session/public/cpp/media_position.h"
#include "ui/accelerated_widget_mac/accelerated_widget_mac.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

#ifdef __OBJC__
@class OpenPiPVideoView;
#else
class OpenPiPVideoView;
#endif

namespace content {
class VideoPictureInPictureWindowController;
}

namespace ui {
class DisplayCALayerTree;
class LayerSolidColor;
class LayerSurface;
class RecyclableCompositorMac;
}  // namespace ui

namespace open_engine {

class OpenPictureInPictureSession;

// EM-4 (docs/plans/media-pip.md §6): video Picture in Picture shown in the
// embedder's own window. Chromium's controller owns this object (as it would
// own VideoOverlayWindowViews) and keeps its own rules: one Picture in Picture
// app-wide, close on navigation, crash and destruction. This class only puts
// the video surface into an NSView that the embedder places in its window,
// and reports the controller's state. Modelled on
// content/browser/renderer_host/unbounded_surface_window_mac.mm (compositor)
// and chrome/browser/ui/views/overlay/video_overlay_window_views.cc
// (semantics). Everything runs on the browser UI thread (the main thread).
class OpenVideoOverlayWindow : public content::VideoOverlayWindow,
                               public ui::AcceleratedWidgetMacNSView {
 public:
  OpenVideoOverlayWindow(
      content::VideoPictureInPictureWindowController* controller,
      CefRefPtr<CefMediaControllerHandler> handler,
      CefRefPtr<CefBrowser> browser);
  ~OpenVideoOverlayWindow() override;
  OpenVideoOverlayWindow(const OpenVideoOverlayWindow&) = delete;
  OpenVideoOverlayWindow& operator=(const OpenVideoOverlayWindow&) = delete;

  // content::VideoOverlayWindow:
  bool IsActive() const override;
  void Close() override;
  void ShowInactive() override;
  void Hide() override;
  bool IsVisible() const override;
  gfx::Rect GetBounds() override;
  void UpdateNaturalSize(const gfx::Size& natural_size) override;
  void SetPlaybackState(PlaybackState playback_state) override;
  void SetPlayPauseButtonVisibility(bool is_visible) override;
  void SetSkipAdButtonVisibility(bool is_visible) override;
  void SetNextTrackButtonVisibility(bool is_visible) override;
  void SetPreviousTrackButtonVisibility(bool is_visible) override;
  void SetHidePictureInPictureButtonVisibility(bool is_visible) override {}
  void SetMicrophoneMuted(bool muted) override;
  void SetCameraState(bool turned_on) override;
  void SetMediaMuted(bool muted) override;
  void SetToggleMicrophoneButtonVisibility(bool is_visible) override;
  void SetToggleCameraButtonVisibility(bool is_visible) override;
  void SetHangUpButtonVisibility(bool is_visible) override;
  void SetNextSlideButtonVisibility(bool is_visible) override;
  void SetPreviousSlideButtonVisibility(bool is_visible) override;
  void SetMediaPosition(const media_session::MediaPosition& position) override;
  void SetSourceTitle(const std::u16string& source_title) override;
  void SetFaviconImages(
      const std::vector<media_session::MediaImage>& images) override {}
  void SetSurfaceId(const viz::SurfaceId& surface_id) override;
  void SetPlaybackControlsVisibility(bool is_visible) override;
  void SetImmersiveVideoOptions(
      const content::ImmersiveOptions& options) override {}

  // ui::AcceleratedWidgetMacNSView:
  void AcceleratedWidgetCALayerParamsUpdated(
      gfx::CALayerParams ca_layer_params) override;

  // From OpenPictureInPictureSession (the embedder's calls).
  OpenPiPVideoView* video_view() const { return view_; }
  CefRefPtr<CefDictionaryValue> GetState() const;
  void SetWindowFrame(const gfx::Rect& frame_in_screen, bool visible);
  void ExecuteAction(const std::string& action,
                     CefRefPtr<CefDictionaryValue> args);

  // From OpenPiPVideoView: its size, backing scale or screen changed.
  void OnViewChanged();

 private:
  // Controls bits, equal to OEPictureInPictureControls in OpenEngine.
  enum Control : uint32_t {
    kPlayPause = 1u << 0,
    kNextTrack = 1u << 1,
    kPreviousTrack = 1u << 2,
    kSkipAd = 1u << 3,
    kToggleMicrophone = 1u << 4,
    kToggleCamera = 1u << 5,
    kHangUp = 1u << 6,
    kNextSlide = 1u << 7,
    kPreviousSlide = 1u << 8,
  };

  void SetControl(Control control, bool visible);
  // Ends the shown session: no more frames, the session object turns invalid.
  // Returns the ended session, or nullptr if none was shown.
  CefRefPtr<OpenPictureInPictureSession> EndSession();
  void RemoveChildFrameSink();
  // Layer sizes from the view's size, scale and display.
  void UpdateLayout();
  // Coalesces state changes into one OnPictureInPictureChanged per turn.
  void ScheduleChanged();
  void DeliverChanged();

  raw_ptr<content::VideoPictureInPictureWindowController> controller_;
  const CefRefPtr<CefMediaControllerHandler> handler_;
  const CefRefPtr<CefBrowser> browser_;

#ifdef __OBJC__
  OpenPiPVideoView* __strong view_ = nil;
#else
  raw_ptr<void> view_ = nullptr;
#endif
  std::unique_ptr<ui::RecyclableCompositorMac> compositor_;
  std::unique_ptr<ui::LayerSolidColor> root_;
  std::unique_ptr<ui::LayerSurface> video_;
  std::unique_ptr<ui::DisplayCALayerTree> ca_layer_tree_;
  std::optional<viz::FrameSinkId> child_frame_sink_;
  std::optional<viz::SurfaceId> surface_id_;

  CefRefPtr<OpenPictureInPictureSession> session_;
  gfx::Rect frame_in_screen_{0, 0, 320, 180};
  bool frame_reported_ = false;
  // Chromium's "visible": the session is shown (ShowInactive, until Hide).
  bool visible_ = false;
  // The embedder's window visibility (SetWindowFrame), reported in GetState.
  bool embedder_visible_ = false;
  bool closed_ = false;

  gfx::Size natural_size_;
  PlaybackState playback_state_ = kPaused;
  uint32_t controls_ = 0;
  bool controls_visible_ = true;
  bool microphone_muted_ = false;
  bool camera_on_ = false;
  bool media_muted_ = false;
  std::optional<media_session::MediaPosition> position_;
  std::u16string source_title_;
  bool changed_pending_ = false;

  base::WeakPtrFactory<OpenVideoOverlayWindow> weak_ptr_factory_{this};
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEDIA_OPEN_VIDEO_OVERLAY_WINDOW_H_
