// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenCaptureController: Page Capture orchestrator for Open Unified.
// Supports Region Capture (OpenCaptureOverlayView + RWHV::CopyFromSurface),
// Full-Page Capture (DevToolsAgentHost CDP Page.getLayoutMetrics +
// Page.captureScreenshot with captureBeyondViewport: true, falling back to
// viewport CopyFromSurface), and Portrait / Framed Capture (viewport with
// rounded corners, frosted frame, drop shadow, and Space theme gradient).
// Saves PNG atomically into <data_dir>/Captures/Capture-YYYY-MM-DD-HHMMSS.png,
// copies PNG bitmap to system clipboard, and shows OpenCaptureResultCard.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_CAPTURE_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_CAPTURE_CONTROLLER_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "content/public/browser/render_widget_host_view.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_theme_math.h"
#include "open_unified/ui/views/open_capture_overlay_view.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"

namespace content {
class WebContents;
}  // namespace content

namespace views {
class Widget;
}  // namespace views

namespace open_unified {

enum class CaptureKind {
  kRegion,
  kFullPage,
  kPortrait,
};

struct PortraitCaptureOptions {
  PortraitCaptureOptions();
  PortraitCaptureOptions(const PortraitCaptureOptions&);
  PortraitCaptureOptions(PortraitCaptureOptions&&) noexcept;
  PortraitCaptureOptions& operator=(const PortraitCaptureOptions&);
  PortraitCaptureOptions& operator=(PortraitCaptureOptions&&) noexcept;
  ~PortraitCaptureOptions();

  // Optional Space theme rendered onto the portrait canvas background.
  // When absent, uses a diagonal gradient from gradient_start to gradient_end.
  std::optional<theme::ThemeStyle> space_theme;
  SkColor gradient_start = SkColorSetRGB(0x7B, 0x8D, 0xF7);
  SkColor gradient_end = SkColorSetRGB(0x31, 0x39, 0xC8);
  bool hide_watermark = false;
};

struct CaptureResult {
  CaptureResult();
  CaptureResult(const CaptureResult&);
  CaptureResult(CaptureResult&&) noexcept;
  CaptureResult& operator=(const CaptureResult&);
  CaptureResult& operator=(CaptureResult&&) noexcept;
  ~CaptureResult();

  CaptureKind kind = CaptureKind::kRegion;
  std::string capture_id;
  base::FilePath file_path;
  std::vector<uint8_t> png_bytes;
  SkBitmap bitmap;
  gfx::ImageSkia thumbnail;
  int pixel_width = 0;
  int pixel_height = 0;
  bool truncated = false;
  bool saved_to_library = false;
  std::string source_url;
  std::string title;
  TimestampSec created_at = 0.0;
};

class OpenCaptureController : public CaptureOverlayDelegate,
                              public CaptureResultCardDelegate,
                              public views::WidgetObserver {
 public:
  // Full-page height cap in device pixels (matching CaptureMetrics).
  static constexpr int kFullPageMaxDevicePixels = 32768;
  // Result card thumbnail long-side cap in pixels (2x of 224 pt).
  static constexpr int kThumbnailMaxPixels = 448;

  class Delegate {
   public:
    virtual ~Delegate() = default;

    virtual void OnCaptureCompleted(const CaptureResult& result) {}
    virtual void OnCaptureFailed(const std::string& error_message) {}
    virtual void OnCaptureCancelled() {}
    virtual void OnCaptureOpenInLibrary(const CaptureResult& result) {}
    virtual void OnCaptureAddToEasel(const CaptureResult& result) {}
    virtual void OnCaptureSaveAsRequested(const CaptureResult& result) {}
    virtual void OnCaptureDeleted(const CaptureResult& result) {}
  };

  explicit OpenCaptureController(base::FilePath data_dir,
                                 Delegate* delegate = nullptr);
  OpenCaptureController(const OpenCaptureController&) = delete;
  OpenCaptureController& operator=(const OpenCaptureController&) = delete;
  ~OpenCaptureController() override;

  void SetDelegate(Delegate* delegate) { delegate_ = delegate; }
  void SetDataDir(base::FilePath data_dir) { data_dir_ = std::move(data_dir); }

  // 1. Region capture: shows OpenCaptureOverlayView over content_rect_in_widget
  //    and captures the dragged selection via RWHV::CopyFromSurface.
  void CaptureRegion(content::WebContents* web_contents,
                     views::Widget* parent_widget,
                     const gfx::Rect& content_rect_in_widget,
                     const secondary::Appearance& appearance);

  // 2. Full-page capture: attaches a temporary DevToolsAgentHost client,
  //    queries Page.getLayoutMetrics, calls Page.captureScreenshot with
  //    captureBeyondViewport: true, decodes PNG, and detaches. Falls back to
  //    viewport CopyFromSurface if DevTools attach or CDP fails.
  void CaptureFullPage(content::WebContents* web_contents,
                       views::Widget* parent_widget,
                       const gfx::Rect& content_rect_in_widget,
                       const secondary::Appearance& appearance);

  // 3. Portrait / framed capture: captures viewport via CopyFromSurface and
  //    renders it with rounded corners, frosted border, drop shadow, and Space
  //    theme gradient padding.
  void CapturePortrait(content::WebContents* web_contents,
                       views::Widget* parent_widget,
                       const gfx::Rect& content_rect_in_widget,
                       const secondary::Appearance& appearance,
                       const PortraitCaptureOptions& options = {});

  // Updates overlay/card anchors when the browser window resizes.
  void UpdateContentRect(const gfx::Rect& content_rect_in_widget);

  // Cancels any in-progress region selection, DevTools session, or hides card.
  void Cancel();
  void DismissResultCard();

  bool IsOverlayVisible() const;
  bool IsResultCardVisible() const;
  bool IsBusy() const { return in_flight_; }
  const std::optional<CaptureResult>& last_result() const {
    return last_result_;
  }

  // Copies a bitmap to the system clipboard.
  static void CopyBitmapToClipboard(const SkBitmap& bitmap);

  // Composes a portrait-framed SkBitmap from a viewport snapshot.
  static SkBitmap ComposePortraitBitmap(const SkBitmap& source,
                                        const PortraitCaptureOptions& options);

  // Writes |png_bytes| atomically to |target_path| on a background thread.
  void SaveCaptureToPath(const base::FilePath& target_path,
                         base::OnceCallback<void(bool)> done = {});

  // CaptureOverlayDelegate:
  void OnCaptureRegionSelected(const gfx::Rect& selection_in_view) override;
  void OnCaptureOverlayCancelled() override;

  // CaptureResultCardDelegate:
  void OnCaptureResultAction(CaptureResultAction action) override;
  void OnCaptureResultHoverChanged(bool hovered) override;

  // views::WidgetObserver:
  void OnWidgetDestroying(views::Widget* widget) override;

 private:
  class FullPageDevToolsSession;

  struct ActiveContext {
    base::WeakPtr<content::WebContents> web_contents;
    raw_ptr<views::Widget> parent_widget = nullptr;
    gfx::Rect content_rect;
    secondary::Appearance appearance;
    PortraitCaptureOptions portrait_options;
    bool off_the_record = false;
    std::string source_url;
    std::string title;
  };

  void PrepareContext(content::WebContents* web_contents,
                      views::Widget* parent_widget,
                      const gfx::Rect& content_rect_in_widget,
                      const secondary::Appearance& appearance);
  void DestroyOverlay();
  void CaptureViewportSurface(uint64_t generation,
                              CaptureKind kind,
                              const gfx::Rect& src_rect_dip);
  void OnCopyFromSurfaceComplete(
      uint64_t generation,
      CaptureKind kind,
      const content::CopyFromSurfaceResult& result);
  void OnFullPageDevToolsComplete(uint64_t generation,
                                  std::optional<std::vector<uint8_t>> png_bytes,
                                  bool truncated,
                                  std::string error);
  void FinalizeCapturedBitmap(uint64_t generation,
                              CaptureKind kind,
                              SkBitmap bitmap,
                              std::optional<std::vector<uint8_t>> pre_encoded,
                              bool truncated);
  void OnCaptureSavedOnDisk(uint64_t generation,
                            CaptureResult result,
                            bool saved_ok);
  void ShowResultCard(const CaptureResult& result);
  void FailCapture(const std::string& message);

  static gfx::ImageSkia BuildThumbnail(const SkBitmap& bitmap);

  base::FilePath data_dir_;
  raw_ptr<Delegate> delegate_ = nullptr;
  ActiveContext active_;
  uint64_t generation_ = 0;
  bool in_flight_ = false;

  std::unique_ptr<secondary::OverlayWidgetHost> overlay_host_;
  raw_ptr<OpenCaptureOverlayView> overlay_view_ = nullptr;

  std::unique_ptr<secondary::OverlayWidgetHost> result_card_host_;
  raw_ptr<OpenCaptureResultCard> result_card_view_ = nullptr;

  std::unique_ptr<FullPageDevToolsSession> devtools_session_;
  std::optional<CaptureResult> last_result_;

  base::ScopedObservation<views::Widget, views::WidgetObserver>
      parent_widget_observation_{this};

  base::WeakPtrFactory<OpenCaptureController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_CAPTURE_CONTROLLER_H_
