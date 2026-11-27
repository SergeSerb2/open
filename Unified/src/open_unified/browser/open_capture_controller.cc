// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_capture_controller.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "base/values.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "skia/ext/image_operations.h"
#include "third_party/skia/include/core/SkCanvas.h"
#include "third_party/skia/include/core/SkImage.h"
#include "third_party/skia/include/core/SkPaint.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "third_party/skia/include/core/SkSurface.h"
#include "third_party/skia/include/effects/SkGradient.h"
#include "third_party/skia/include/effects/SkImageFilters.h"
#include "ui/base/clipboard/clipboard_buffer.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/size_f.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr base::TimeDelta kCopySurfaceTimeout = base::Seconds(10);
constexpr base::TimeDelta kFullPageCdpTimeout = base::Seconds(25);
constexpr size_t kMaxCapturesIndexBytes = 16 * 1024 * 1024;
constexpr size_t kMaxCapturesIndexRows = 50000;

std::string CaptureKindString(CaptureKind kind) {
  switch (kind) {
    case CaptureKind::kRegion:
      return "area";
    case CaptureKind::kFullPage:
      return "fullPage";
    case CaptureKind::kPortrait:
      return "portrait";
  }
  return "area";
}

// Formats Capture-YYYY-MM-DD-HHMMSS.png using local time and avoids collisions.
base::FilePath BuildCaptureFilePath(const base::FilePath& captures_dir,
                                    base::Time now) {
  base::Time::Exploded exploded;
  now.LocalExplode(&exploded);
  const std::string stem = base::StringPrintf(
      "Capture-%04d-%02d-%02d-%02d%02d%02d", exploded.year, exploded.month,
      exploded.day_of_month, exploded.hour, exploded.minute, exploded.second);

  base::FilePath candidate = captures_dir.AppendASCII(stem + ".png");
  for (int suffix = 1; suffix <= 999 && base::PathExists(candidate); ++suffix) {
    candidate = captures_dir.AppendASCII(
        base::StringPrintf("%s-%d.png", stem.c_str(), suffix));
  }
  return candidate;
}

struct DiskSaveOutcome {
  bool ok = false;
  base::FilePath path;
};

// Saves PNG atomically into <data_dir>/Captures/Capture-YYYY-MM-DD-HHMMSS.png
// and appends metadata to <data_dir>/State/captures.json.
DiskSaveOutcome SaveCaptureFileOnIo(base::FilePath data_dir,
                                    std::string capture_id,
                                    CaptureKind kind,
                                    std::string source_url,
                                    std::string title,
                                    TimestampSec created_at,
                                    std::vector<uint8_t> png_bytes) {
  DiskSaveOutcome outcome;
  if (data_dir.empty() || png_bytes.empty()) {
    return outcome;
  }

  const base::FilePath captures_dir = data_dir.AppendASCII("Captures");
  if (!base::CreateDirectory(captures_dir)) {
    return outcome;
  }

  const base::FilePath target =
      BuildCaptureFilePath(captures_dir, base::Time::Now());
  std::string_view raw_view(reinterpret_cast<const char*>(png_bytes.data()),
                            png_bytes.size());
  if (!base::ImportantFileWriter::WriteFileAtomically(target, raw_view)) {
    return outcome;
  }

  outcome.ok = true;
  outcome.path = target;

  // Update <data_dir>/State/captures.json (compatible with macOS Open Library).
  const base::FilePath state_dir = data_dir.AppendASCII("State");
  const base::FilePath index_path = state_dir.AppendASCII("captures.json");
  if (!base::CreateDirectory(state_dir)) {
    return outcome;
  }

  base::ListValue rows;
  if (base::PathExists(index_path)) {
    std::string existing;
    if (!base::ReadFileToStringWithMaxSize(index_path, &existing,
                                           kMaxCapturesIndexBytes)) {
      // Oversized or unreadable index: never replace it with a one-row file.
      return outcome;
    }
    if (auto parsed =
            base::JSONReader::ReadList(existing, base::JSON_PARSE_RFC)) {
      rows = std::move(*parsed);
    } else {
      // Never overwrite a damaged index.
      return outcome;
    }
  }

  if (rows.size() < kMaxCapturesIndexRows) {
    base::DictValue entry;
    entry.Set("id", capture_id);
    entry.Set("fileName", target.BaseName().AsUTF8Unsafe());
    entry.Set("createdAt", created_at);
    entry.Set("kind", CaptureKindString(kind));
    GURL parsed_url(source_url);
    entry.Set("sourceHost", parsed_url.is_valid()
                                ? (parsed_url.host().empty()
                                       ? parsed_url.scheme()
                                       : parsed_url.host())
                                : std::string());
    std::string truncated_title;
    base::TruncateUTF8ToByteSize(title, 4096, &truncated_title);
    entry.Set("title", std::move(truncated_title));
    if (!source_url.empty()) {
      entry.Set("sourceURL", source_url);
    }
    rows.Append(std::move(entry));

    std::string serialized;
    if (base::JSONWriter::Write(rows, &serialized) &&
        serialized.size() <= kMaxCapturesIndexBytes) {
      base::ImportantFileWriter::WriteFileAtomically(index_path, serialized);
    }
  }

  return outcome;
}

void DeleteCaptureOnIo(base::FilePath data_dir,
                       base::FilePath file_path,
                       std::string capture_id) {
  if (!file_path.empty()) {
    base::DeleteFile(file_path);
  }
  if (data_dir.empty() || capture_id.empty()) {
    return;
  }
  const base::FilePath index_path =
      data_dir.AppendASCII("State").AppendASCII("captures.json");
  std::string existing;
  if (!base::ReadFileToStringWithMaxSize(index_path, &existing,
                                         kMaxCapturesIndexBytes)) {
    return;
  }
  auto parsed = base::JSONReader::ReadList(existing, base::JSON_PARSE_RFC);
  if (!parsed) {
    return;
  }
  base::ListValue filtered;
  for (auto& item : *parsed) {
    if (auto* dict = item.GetIfDict()) {
      if (const std::string* id = dict->FindString("id");
          id && *id == capture_id) {
        continue;
      }
    }
    filtered.Append(std::move(item));
  }
  std::string serialized;
  if (base::JSONWriter::Write(filtered, &serialized)) {
    base::ImportantFileWriter::WriteFileAtomically(index_path, serialized);
  }
}

bool WriteRawFileAtomicOnIo(base::FilePath path,
                            std::vector<uint8_t> png_bytes) {
  if (path.empty() || png_bytes.empty()) {
    return false;
  }
  if (!base::CreateDirectory(path.DirName())) {
    return false;
  }
  std::string_view view(reinterpret_cast<const char*>(png_bytes.data()),
                        png_bytes.size());
  return base::ImportantFileWriter::WriteFileAtomically(path, view);
}

// Draws Open's monochrome doorway-and-sun mark onto a frosted corner tile.
void DrawPortraitWatermark(SkCanvas* canvas,
                           float canvas_w,
                           float canvas_h,
                           SkColor tint) {
  constexpr float kWatermarkFrac = 32.f / 239.f;
  constexpr float kInsetFrac = 3.5f / 239.f;
  constexpr float kRadiusFrac = 8.f / 32.f;

  const float side = canvas_w * kWatermarkFrac;
  const float inset = canvas_w * kInsetFrac;
  const SkRect tile =
      SkRect::MakeXYWH(inset, canvas_h - inset - side, side, side);
  const float radius = side * kRadiusFrac;

  SkPaint tile_paint;
  tile_paint.setAntiAlias(true);
  tile_paint.setColor(SkColorSetA(SK_ColorWHITE, 0x26));  // ~15% white
  canvas->drawRRect(SkRRect::MakeRectXY(tile, radius, radius), tile_paint);

  // Doorway proportions (168 x 248) with sun cutout (even-odd).
  const float h = side * 0.62f;
  const float w = h * (168.f / 248.f);
  const SkRect door = SkRect::MakeXYWH(tile.centerX() - w / 2.f,
                                       tile.centerY() - h / 2.f, w, h);
  const float arch_r = w / 2.f;

  SkPathBuilder mark(SkPathFillType::kEvenOdd);
  // Rounded-top doorway arch.
  mark.moveTo(door.left(), door.bottom());
  mark.lineTo(door.left(), door.top() + arch_r);
  mark.arcTo(SkRect::MakeXYWH(door.left(), door.top(), w, w), 180.f, 180.f,
             false);
  mark.lineTo(door.right(), door.bottom());
  mark.close();
  // Sun disc cutout near upper-right interior.
  const float sun_r = w * 0.17f;
  const float sun_cx = door.right() - w * 0.29f;
  const float sun_cy = door.top() + h * 0.30f;
  mark.addOval(SkRect::MakeXYWH(sun_cx - sun_r, sun_cy - sun_r, sun_r * 2.f,
                                sun_r * 2.f));

  SkPaint mark_paint;
  mark_paint.setAntiAlias(true);
  mark_paint.setColor(tint);
  canvas->drawPath(mark.detach(), mark_paint);
}

}  // namespace

// ===========================================================================
// FullPageDevToolsSession — temporary CDP client for full-page capture
// ===========================================================================

class OpenCaptureController::FullPageDevToolsSession
    : public content::DevToolsAgentHostClient {
 public:
  using CompletionCallback =
      base::OnceCallback<void(std::optional<std::vector<uint8_t>> png_bytes,
                              bool truncated,
                              std::string error)>;

  FullPageDevToolsSession(content::WebContents* web_contents,
                          CompletionCallback callback)
      : callback_(std::move(callback)) {
    agent_host_ = content::DevToolsAgentHost::GetOrCreateFor(web_contents);
  }

  ~FullPageDevToolsSession() override { Detach(); }

  bool Start() {
    if (!agent_host_ || !agent_host_->AttachClient(this)) {
      return false;
    }
    attached_ = true;
    timeout_timer_.Start(
        FROM_HERE, kFullPageCdpTimeout,
        base::BindOnce(&FullPageDevToolsSession::FinishError,
                       base::Unretained(this), "Full-page capture timed out."));

    base::DictValue msg;
    msg.Set("id", kMetricsCommandId);
    msg.Set("method", "Page.getLayoutMetrics");
    SendCdpCommand(msg);
    return true;
  }

  void Cancel() {
    timeout_timer_.Stop();
    callback_.Reset();
    Detach();
  }

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost* agent_host,
                               base::span<const uint8_t> message) override {
    if (!attached_ || !callback_) {
      return;
    }
    std::string_view json_text(reinterpret_cast<const char*>(message.data()),
                               message.size());
    auto parsed = base::JSONReader::ReadDict(json_text, base::JSON_PARSE_RFC);
    if (!parsed) {
      return;
    }
    const std::optional<int> id = parsed->FindInt("id");
    if (!id.has_value()) {
      return;  // Ignore async CDP events.
    }

    if (const base::DictValue* error = parsed->FindDict("error")) {
      const std::string* err_msg = error->FindString("message");
      FinishError(err_msg ? *err_msg : "DevTools capture failed.");
      return;
    }

    const base::DictValue* result = parsed->FindDict("result");
    if (!result) {
      FinishError("Empty DevTools capture response.");
      return;
    }

    if (*id == kMetricsCommandId) {
      HandleLayoutMetrics(*result);
    } else if (*id == kScreenshotCommandId) {
      HandleScreenshotResult(*result);
    }
  }

  void AgentHostClosed(content::DevToolsAgentHost* agent_host) override {
    attached_ = false;
    agent_host_.reset();
    FinishError("DevTools session closed before capture completed.");
  }

 private:
  static constexpr int kMetricsCommandId = 1;
  static constexpr int kScreenshotCommandId = 2;

  void SendCdpCommand(const base::DictValue& command) {
    if (!attached_ || !agent_host_) {
      return;
    }
    std::string json;
    if (!base::JSONWriter::Write(command, &json)) {
      FinishError("Failed to serialize DevTools command.");
      return;
    }
    agent_host_->DispatchProtocolMessage(this, base::as_byte_span(json));
  }

  void HandleLayoutMetrics(const base::DictValue& result) {
    const base::DictValue* content_size = result.FindDict("cssContentSize");
    if (!content_size) {
      content_size = result.FindDict("contentSize");
    }

    double width = content_size ? content_size->FindDouble("width").value_or(0)
                                : 0.0;
    double height =
        content_size ? content_size->FindDouble("height").value_or(0) : 0.0;

    base::DictValue params;
    params.Set("format", "png");
    params.Set("fromSurface", true);
    params.Set("captureBeyondViewport", true);

    if (width > 0.0 && height > 0.0) {
      const double max_h = static_cast<double>(kFullPageMaxDevicePixels);
      if (height > max_h) {
        height = max_h;
        truncated_ = true;
      }
      base::DictValue clip;
      clip.Set("x", 0.0);
      clip.Set("y", 0.0);
      clip.Set("width", width);
      clip.Set("height", height);
      clip.Set("scale", 1.0);
      params.Set("clip", std::move(clip));
    }

    base::DictValue msg;
    msg.Set("id", kScreenshotCommandId);
    msg.Set("method", "Page.captureScreenshot");
    msg.Set("params", std::move(params));
    SendCdpCommand(msg);
  }

  void HandleScreenshotResult(const base::DictValue& result) {
    const std::string* b64_data = result.FindString("data");
    if (!b64_data || b64_data->empty()) {
      FinishError("Page.captureScreenshot returned empty image data.");
      return;
    }
    std::optional<std::vector<uint8_t>> decoded = base::Base64Decode(*b64_data);
    if (!decoded || decoded->empty()) {
      FinishError("Failed to decode full-page PNG data.");
      return;
    }

    timeout_timer_.Stop();
    Detach();
    if (callback_) {
      std::move(callback_).Run(std::move(*decoded), truncated_, std::string());
    }
  }

  void FinishError(const std::string& error) {
    timeout_timer_.Stop();
    Detach();
    if (callback_) {
      std::move(callback_).Run(std::nullopt, false, error);
    }
  }

  void Detach() {
    if (attached_ && agent_host_) {
      attached_ = false;
      agent_host_->DetachClient(this);
    }
    agent_host_.reset();
  }

  scoped_refptr<content::DevToolsAgentHost> agent_host_;
  CompletionCallback callback_;
  base::OneShotTimer timeout_timer_;
  bool attached_ = false;
  bool truncated_ = false;
};

// ===========================================================================
// POD Structs
// ===========================================================================

PortraitCaptureOptions::PortraitCaptureOptions() = default;
PortraitCaptureOptions::PortraitCaptureOptions(const PortraitCaptureOptions&) =
    default;
PortraitCaptureOptions::PortraitCaptureOptions(
    PortraitCaptureOptions&&) noexcept = default;
PortraitCaptureOptions& PortraitCaptureOptions::operator=(
    const PortraitCaptureOptions&) = default;
PortraitCaptureOptions& PortraitCaptureOptions::operator=(
    PortraitCaptureOptions&&) noexcept = default;
PortraitCaptureOptions::~PortraitCaptureOptions() = default;

CaptureResult::CaptureResult() = default;
CaptureResult::CaptureResult(const CaptureResult&) = default;
CaptureResult::CaptureResult(CaptureResult&&) noexcept = default;
CaptureResult& CaptureResult::operator=(const CaptureResult&) = default;
CaptureResult& CaptureResult::operator=(CaptureResult&&) noexcept = default;
CaptureResult::~CaptureResult() = default;

// ===========================================================================
// OpenCaptureController
// ===========================================================================

OpenCaptureController::OpenCaptureController(base::FilePath data_dir,
                                             Delegate* delegate)
    : data_dir_(std::move(data_dir)), delegate_(delegate) {}

OpenCaptureController::~OpenCaptureController() {
  Cancel();
}

void OpenCaptureController::CaptureRegion(
    content::WebContents* web_contents,
    views::Widget* parent_widget,
    const gfx::Rect& content_rect_in_widget,
    const secondary::Appearance& appearance) {
  if (!web_contents || !parent_widget || content_rect_in_widget.IsEmpty()) {
    FailCapture("There is no visible page to capture.");
    return;
  }

  Cancel();
  PrepareContext(web_contents, parent_widget, content_rect_in_widget,
                 appearance);

  auto overlay = std::make_unique<OpenCaptureOverlayView>(this);
  overlay->SetAppearance(appearance);
  if (auto* rwhv = web_contents->GetRenderWidgetHostView()) {
    overlay->SetDeviceScaleFactor(rwhv->GetDeviceScaleFactor());
  }
  overlay_view_ = overlay.get();

  overlay_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      parent_widget, std::move(overlay), "OpenCaptureOverlay",
      /*activatable=*/true);
  overlay_host_->SetAnchor(content_rect_in_widget,
                           secondary::OverlayWidgetHost::Alignment::kFill);
  overlay_host_->Show();
  if (overlay_view_) {
    overlay_view_->RequestFocus();
  }
}

void OpenCaptureController::CaptureFullPage(
    content::WebContents* web_contents,
    views::Widget* parent_widget,
    const gfx::Rect& content_rect_in_widget,
    const secondary::Appearance& appearance) {
  if (!web_contents) {
    FailCapture("There is no page to capture.");
    return;
  }

  Cancel();
  PrepareContext(web_contents, parent_widget, content_rect_in_widget,
                 appearance);
  in_flight_ = true;
  const uint64_t gen = ++generation_;

  devtools_session_ = std::make_unique<FullPageDevToolsSession>(
      web_contents,
      base::BindOnce(&OpenCaptureController::OnFullPageDevToolsComplete,
                     weak_factory_.GetWeakPtr(), gen));
  if (!devtools_session_->Start()) {
    devtools_session_.reset();
    // Fallback to visible viewport CopyFromSurface if DevTools cannot attach.
    CaptureViewportSurface(gen, CaptureKind::kFullPage, gfx::Rect());
  }
}

void OpenCaptureController::CapturePortrait(
    content::WebContents* web_contents,
    views::Widget* parent_widget,
    const gfx::Rect& content_rect_in_widget,
    const secondary::Appearance& appearance,
    const PortraitCaptureOptions& options) {
  if (!web_contents) {
    FailCapture("There is no page to capture.");
    return;
  }

  Cancel();
  PrepareContext(web_contents, parent_widget, content_rect_in_widget,
                 appearance);
  active_.portrait_options = options;
  in_flight_ = true;
  const uint64_t gen = ++generation_;
  CaptureViewportSurface(gen, CaptureKind::kPortrait, gfx::Rect());
}

void OpenCaptureController::UpdateContentRect(
    const gfx::Rect& content_rect_in_widget) {
  active_.content_rect = content_rect_in_widget;
  if (overlay_host_ && overlay_host_->IsVisible()) {
    overlay_host_->SetAnchor(content_rect_in_widget,
                             secondary::OverlayWidgetHost::Alignment::kFill);
  }
  if (result_card_host_ && result_card_host_->IsVisible()) {
    result_card_host_->SetAnchor(
        OpenCaptureResultCard::ComputeAnchor(content_rect_in_widget),
        secondary::OverlayWidgetHost::Alignment::kTopRight);
  }
}

void OpenCaptureController::Cancel() {
  ++generation_;
  in_flight_ = false;
  if (devtools_session_) {
    devtools_session_->Cancel();
    devtools_session_.reset();
  }
  DestroyOverlay();
  DismissResultCard();
  parent_widget_observation_.Reset();
  active_.parent_widget = nullptr;
}

void OpenCaptureController::DismissResultCard() {
  if (result_card_view_) {
    result_card_view_->PauseAutoDismissTimer();
  }
  result_card_view_ = nullptr;
  result_card_host_.reset();
}

bool OpenCaptureController::IsOverlayVisible() const {
  return overlay_host_ && overlay_host_->IsVisible();
}

bool OpenCaptureController::IsResultCardVisible() const {
  return result_card_host_ && result_card_host_->IsVisible();
}

// static
void OpenCaptureController::CopyBitmapToClipboard(const SkBitmap& bitmap) {
  if (bitmap.drawsNothing()) {
    return;
  }
  ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
  writer.WriteImage(bitmap);
}

// static
SkBitmap OpenCaptureController::ComposePortraitBitmap(
    const SkBitmap& source,
    const PortraitCaptureOptions& options) {
  if (source.drawsNothing()) {
    return SkBitmap();
  }

  // Layout proportions matching CaptureComposer.portraitLayout (239 x 127
  // aspect ratio, page card height 96/127 of canvas, width <= 86% of canvas).
  constexpr float kAspect = 239.f / 127.f;
  constexpr float kHeightFraction = 96.f / 127.f;
  constexpr float kMaxWidthFraction = 0.86f;
  constexpr float kFrameFraction = 4.f / 239.f;
  constexpr float kFrameRadiusFraction = 8.f / 239.f;
  constexpr float kShadowBlurFraction = 0.03f;
  constexpr float kShadowOffsetFraction = 0.008f;

  const float src_w = static_cast<float>(source.width());
  const float src_h = static_cast<float>(source.height());
  float canvas_h = std::round(src_h / kHeightFraction);
  float canvas_w = std::round(canvas_h * kAspect);
  if (src_w > canvas_w * kMaxWidthFraction) {
    canvas_w = std::round(src_w / kMaxWidthFraction);
    canvas_h = std::round(canvas_w / kAspect);
  }

  const int out_w = std::clamp(static_cast<int>(canvas_w), 1, 8192);
  const int out_h = std::clamp(static_cast<int>(canvas_h), 1, 8192);

  sk_sp<SkSurface> surface =
      SkSurfaces::Raster(SkImageInfo::MakeN32Premul(out_w, out_h));
  if (!surface) {
    return source;
  }
  SkCanvas* canvas = surface->getCanvas();

  // 1. Background: Space theme shader or diagonal gradient.
  SkPaint bg_paint;
  if (options.space_theme.has_value()) {
    sk_sp<SkShader> theme_shader = theme::MakeThemeShader(
        *options.space_theme,
        gfx::RectF(0.f, 0.f, static_cast<float>(out_w),
                   static_cast<float>(out_h)),
        /*is_active=*/true, /*device_scale=*/1.f);
    if (theme_shader) {
      bg_paint.setShader(std::move(theme_shader));
    }
  }
  if (!bg_paint.getShader()) {
    const SkPoint pts[2] = {
        SkPoint::Make(0.f, 0.f),
        SkPoint::Make(static_cast<float>(out_w), static_cast<float>(out_h))};
    const SkColor4f colors[2] = {SkColor4f::FromColor(options.gradient_start),
                                 SkColor4f::FromColor(options.gradient_end)};
    SkGradient grad(SkGradient::Colors(colors, SkTileMode::kClamp),
                    SkGradient::Interpolation{});
    bg_paint.setShader(SkShaders::LinearGradient(pts, grad));
  }
  canvas->drawRect(
      SkRect::MakeIWH(out_w, out_h), bg_paint);

  // 2. Centered page card rect with frosted frame and drop shadow.
  const SkRect image_rect = SkRect::MakeXYWH(
      std::round((static_cast<float>(out_w) - src_w) / 2.f),
      std::round((static_cast<float>(out_h) - src_h) / 2.f), src_w, src_h);
  const float frame_w = static_cast<float>(out_w) * kFrameFraction;
  const float outer_r = static_cast<float>(out_w) * kFrameRadiusFraction;
  const float inner_r = std::max(outer_r - frame_w, outer_r * 0.4f);

  const SkRect outer_rect = image_rect.makeOutset(frame_w, frame_w);
  const SkRRect outer_rrect = SkRRect::MakeRectXY(outer_rect, outer_r, outer_r);
  const SkRRect inner_rrect = SkRRect::MakeRectXY(image_rect, inner_r, inner_r);

  const float shadow_sigma =
      std::max(1.f, static_cast<float>(out_w) * kShadowBlurFraction * 0.5f);
  const float shadow_dy = static_cast<float>(out_w) * kShadowOffsetFraction;

  SkPaint frame_paint;
  frame_paint.setAntiAlias(true);
  frame_paint.setColor(SkColorSetA(SK_ColorWHITE, 0x59));  // ~35% frosted white
  frame_paint.setImageFilter(SkImageFilters::DropShadow(
      0.f, shadow_dy, shadow_sigma, shadow_sigma,
      SkColorSetA(SK_ColorBLACK, 0x38), nullptr));
  canvas->drawRRect(outer_rrect, frame_paint);

  // 3. Clipped rounded viewport image.
  canvas->save();
  canvas->clipRRect(inner_rrect, /*doAntiAlias=*/true);
  sk_sp<SkImage> src_image = SkImages::RasterFromBitmap(source);
  if (src_image) {
    canvas->drawImageRect(
        src_image, image_rect,
        SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear));
  }
  canvas->restore();

  // 4. Optional Open doorway-and-sun watermark.
  if (!options.hide_watermark) {
    const SkColor tint = SkColorSetRGB(
        static_cast<U8CPU>(SkColorGetR(options.gradient_end) * 0.7f),
        static_cast<U8CPU>(SkColorGetG(options.gradient_end) * 0.7f),
        static_cast<U8CPU>(SkColorGetB(options.gradient_end) * 0.7f));
    DrawPortraitWatermark(canvas, static_cast<float>(out_w),
                          static_cast<float>(out_h), tint);
  }

  SkBitmap out_bitmap;
  if (!out_bitmap.tryAllocPixels(SkImageInfo::MakeN32Premul(out_w, out_h))) {
    return source;
  }
  if (!surface->readPixels(out_bitmap, 0, 0)) {
    return source;
  }
  out_bitmap.setImmutable();
  return out_bitmap;
}

void OpenCaptureController::SaveCaptureToPath(
    const base::FilePath& target_path,
    base::OnceCallback<void(bool)> done) {
  if (!last_result_.has_value() || last_result_->png_bytes.empty() ||
      target_path.empty()) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&WriteRawFileAtomicOnIo, target_path,
                     last_result_->png_bytes),
      done ? std::move(done) : base::DoNothing());
}

void OpenCaptureController::OnCaptureRegionSelected(
    const gfx::Rect& selection_in_view) {
  DestroyOverlay();
  if (selection_in_view.IsEmpty()) {
    if (delegate_) {
      delegate_->OnCaptureCancelled();
    }
    return;
  }
  in_flight_ = true;
  const uint64_t gen = ++generation_;
  CaptureViewportSurface(gen, CaptureKind::kRegion, selection_in_view);
}

void OpenCaptureController::OnCaptureOverlayCancelled() {
  DestroyOverlay();
  in_flight_ = false;
  if (delegate_) {
    delegate_->OnCaptureCancelled();
  }
}

void OpenCaptureController::OnCaptureResultAction(CaptureResultAction action) {
  if (action == CaptureResultAction::kDismiss) {
    DismissResultCard();
    return;
  }
  if (!last_result_.has_value()) {
    DismissResultCard();
    return;
  }

  const CaptureResult result = *last_result_;
  switch (action) {
    case CaptureResultAction::kCopy:
      CopyBitmapToClipboard(result.bitmap);
      break;
    case CaptureResultAction::kSaveAs:
      if (delegate_) {
        delegate_->OnCaptureSaveAsRequested(result);
      }
      break;
    case CaptureResultAction::kOpenInLibrary:
      DismissResultCard();
      if (delegate_) {
        delegate_->OnCaptureOpenInLibrary(result);
      }
      break;
    case CaptureResultAction::kAddToEasel:
      if (delegate_) {
        delegate_->OnCaptureAddToEasel(result);
      }
      break;
    case CaptureResultAction::kRetake: {
      if (result.saved_to_library) {
        base::ThreadPool::PostTask(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
            base::BindOnce(&DeleteCaptureOnIo, data_dir_, result.file_path,
                           result.capture_id));
      }
      last_result_.reset();
      DismissResultCard();
      if (active_.web_contents && active_.parent_widget) {
        content::WebContents* wc = active_.web_contents.get();
        views::Widget* parent = active_.parent_widget;
        const gfx::Rect rect = active_.content_rect;
        const secondary::Appearance appearance = active_.appearance;
        CaptureRegion(wc, parent, rect, appearance);
      }
      break;
    }
    case CaptureResultAction::kDelete: {
      if (result.saved_to_library) {
        base::ThreadPool::PostTask(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
            base::BindOnce(&DeleteCaptureOnIo, data_dir_, result.file_path,
                           result.capture_id));
      }
      last_result_.reset();
      DismissResultCard();
      if (delegate_) {
        delegate_->OnCaptureDeleted(result);
      }
      break;
    }
    case CaptureResultAction::kDismiss:
      break;
  }
}

void OpenCaptureController::OnCaptureResultHoverChanged(bool hovered) {
  // OpenCaptureResultCard already pauses/resumes its own auto-dismiss timer.
  (void)hovered;
}

void OpenCaptureController::OnWidgetDestroying(views::Widget* widget) {
  if (widget == active_.parent_widget) {
    parent_widget_observation_.Reset();
    active_.parent_widget = nullptr;
    Cancel();
  }
}

void OpenCaptureController::PrepareContext(
    content::WebContents* web_contents,
    views::Widget* parent_widget,
    const gfx::Rect& content_rect_in_widget,
    const secondary::Appearance& appearance) {
  parent_widget_observation_.Reset();
  active_ = ActiveContext();
  active_.web_contents = web_contents->GetWeakPtr();
  active_.parent_widget = parent_widget;
  if (parent_widget) {
    parent_widget_observation_.Observe(parent_widget);
  }
  active_.content_rect = content_rect_in_widget;
  active_.appearance = appearance;
  active_.off_the_record =
      web_contents->GetBrowserContext() &&
      web_contents->GetBrowserContext()->IsOffTheRecord();
  active_.source_url = web_contents->GetLastCommittedURL().spec();
  active_.title = base::UTF16ToUTF8(web_contents->GetTitle());
}

void OpenCaptureController::DestroyOverlay() {
  overlay_view_ = nullptr;
  overlay_host_.reset();
}

void OpenCaptureController::CaptureViewportSurface(
    uint64_t generation,
    CaptureKind kind,
    const gfx::Rect& src_rect_dip) {
  if (!active_.web_contents) {
    FailCapture("The page closed before capture completed.");
    return;
  }
  content::RenderWidgetHostView* rwhv =
      active_.web_contents->GetRenderWidgetHostView();
  if (!rwhv || !rwhv->IsSurfaceAvailableForCopy()) {
    FailCapture("The page surface is not available for capture.");
    return;
  }

  rwhv->CopyFromSurface(
      src_rect_dip, gfx::Size(), kCopySurfaceTimeout,
      base::BindPostTaskToCurrentDefault(base::BindOnce(
          &OpenCaptureController::OnCopyFromSurfaceComplete,
          weak_factory_.GetWeakPtr(), generation, kind)));
}

void OpenCaptureController::OnCopyFromSurfaceComplete(
    uint64_t generation,
    CaptureKind kind,
    const content::CopyFromSurfaceResult& result) {
  if (generation != generation_) {
    return;
  }
  if (!result.has_value() || result->bitmap.drawsNothing()) {
    FailCapture("Could not copy pixels from the page surface.");
    return;
  }

  SkBitmap bitmap = result->bitmap;
  if (kind == CaptureKind::kPortrait) {
    bitmap = ComposePortraitBitmap(bitmap, active_.portrait_options);
    if (bitmap.drawsNothing()) {
      FailCapture("Could not render Portrait capture.");
      return;
    }
  }

  FinalizeCapturedBitmap(generation, kind, std::move(bitmap), std::nullopt,
                         /*truncated=*/false);
}

void OpenCaptureController::OnFullPageDevToolsComplete(
    uint64_t generation,
    std::optional<std::vector<uint8_t>> png_bytes,
    bool truncated,
    std::string error) {
  devtools_session_.reset();
  if (generation != generation_) {
    return;
  }
  if (!png_bytes.has_value() || png_bytes->empty()) {
    VLOG(1) << "OpenCaptureController full-page CDP failed (" << error
            << "); falling back to viewport CopyFromSurface";
    CaptureViewportSurface(generation, CaptureKind::kFullPage, gfx::Rect());
    return;
  }

  SkBitmap decoded = gfx::PNGCodec::Decode(*png_bytes);
  if (decoded.drawsNothing()) {
    CaptureViewportSurface(generation, CaptureKind::kFullPage, gfx::Rect());
    return;
  }

  FinalizeCapturedBitmap(generation, CaptureKind::kFullPage, std::move(decoded),
                         std::move(png_bytes), truncated);
}

void OpenCaptureController::FinalizeCapturedBitmap(
    uint64_t generation,
    CaptureKind kind,
    SkBitmap bitmap,
    std::optional<std::vector<uint8_t>> pre_encoded,
    bool truncated) {
  if (generation != generation_) {
    return;
  }

  std::vector<uint8_t> png_bytes;
  if (pre_encoded.has_value() && !pre_encoded->empty()) {
    png_bytes = std::move(*pre_encoded);
  } else {
    auto encoded = gfx::PNGCodec::EncodeBGRASkBitmap(
        bitmap, /*discard_transparency=*/false);
    if (!encoded.has_value() || encoded->empty()) {
      FailCapture("Could not encode capture as PNG.");
      return;
    }
    png_bytes = std::move(*encoded);
  }

  // Copy immediately to system clipboard.
  CopyBitmapToClipboard(bitmap);

  CaptureResult result;
  result.kind = kind;
  result.capture_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  result.pixel_width = bitmap.width();
  result.pixel_height = bitmap.height();
  result.truncated = truncated;
  result.thumbnail = BuildThumbnail(bitmap);
  result.bitmap = std::move(bitmap);
  result.png_bytes = std::move(png_bytes);
  result.source_url = active_.source_url;
  result.title = active_.title;
  result.created_at = base::Time::Now().InSecondsFSinceUnixEpoch();

  if (active_.off_the_record || data_dir_.empty()) {
    OnCaptureSavedOnDisk(generation, std::move(result), /*saved_ok=*/false);
    return;
  }

  std::string capture_id = result.capture_id;
  const CaptureKind capture_kind = result.kind;
  std::string source_url = result.source_url;
  std::string title = result.title;
  const TimestampSec created_at = result.created_at;
  std::vector<uint8_t> png_bytes_copy = result.png_bytes;

  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&SaveCaptureFileOnIo, data_dir_, std::move(capture_id),
                     capture_kind, std::move(source_url), std::move(title),
                     created_at, std::move(png_bytes_copy)),
      base::BindOnce(
          [](base::WeakPtr<OpenCaptureController> self, uint64_t gen,
             CaptureResult res, DiskSaveOutcome outcome) {
            if (!self) {
              return;
            }
            res.file_path = std::move(outcome.path);
            self->OnCaptureSavedOnDisk(gen, std::move(res), outcome.ok);
          },
          weak_factory_.GetWeakPtr(), generation, std::move(result)));
}

void OpenCaptureController::OnCaptureSavedOnDisk(uint64_t generation,
                                                 CaptureResult result,
                                                 bool saved_ok) {
  if (generation != generation_) {
    return;
  }
  in_flight_ = false;
  result.saved_to_library = saved_ok;
  last_result_ = result;

  ShowResultCard(*last_result_);
  if (delegate_) {
    delegate_->OnCaptureCompleted(*last_result_);
  }
}

void OpenCaptureController::ShowResultCard(const CaptureResult& result) {
  DismissResultCard();
  if (!active_.parent_widget || active_.content_rect.IsEmpty()) {
    return;
  }

  CaptureResultCardModel model;
  model.thumbnail = result.thumbnail;
  model.pixel_size = gfx::Size(result.pixel_width, result.pixel_height);
  model.saved_path = result.file_path;
  model.saved_to_library = result.saved_to_library;
  model.can_retake = result.kind == CaptureKind::kRegion;
  model.can_add_to_easel = result.saved_to_library;
  model.subtitle =
      result.saved_to_library ? u"Saved to Library" : u"Copied to Clipboard";
  if (result.truncated) {
    model.note = u"Page cut at 32,768 px.";
  }

  auto card = std::make_unique<OpenCaptureResultCard>(this, model,
                                                      active_.appearance);
  result_card_view_ = card.get();
  result_card_host_ = std::make_unique<secondary::OverlayWidgetHost>(
      active_.parent_widget, std::move(card), "OpenCaptureResultCard",
      /*activatable=*/false);
  result_card_host_->SetAnchor(
      OpenCaptureResultCard::ComputeAnchor(active_.content_rect),
      secondary::OverlayWidgetHost::Alignment::kTopRight);
  result_card_host_->Show();
  if (result_card_view_) {
    result_card_view_->StartAutoDismissTimer();
  }
}

void OpenCaptureController::FailCapture(const std::string& message) {
  in_flight_ = false;
  DestroyOverlay();
  if (devtools_session_) {
    devtools_session_->Cancel();
    devtools_session_.reset();
  }
  if (delegate_) {
    delegate_->OnCaptureFailed(message);
  }
}

// static
gfx::ImageSkia OpenCaptureController::BuildThumbnail(const SkBitmap& bitmap) {
  if (bitmap.drawsNothing()) {
    return gfx::ImageSkia();
  }
  const int w = bitmap.width();
  const int h = bitmap.height();
  const int long_side = std::max(w, h);
  if (long_side <= kThumbnailMaxPixels) {
    return gfx::ImageSkia::CreateFrom1xBitmap(bitmap);
  }
  const double scale =
      static_cast<double>(kThumbnailMaxPixels) / static_cast<double>(long_side);
  const int dst_w = std::max(1, static_cast<int>(std::lround(w * scale)));
  const int dst_h = std::max(1, static_cast<int>(std::lround(h * scale)));
  SkBitmap resized = skia::ImageOperations::Resize(
      bitmap, skia::ImageOperations::RESIZE_GOOD, dst_w, dst_h);
  return gfx::ImageSkia::CreateFrom1xBitmap(resized);
}

}  // namespace open_unified
