// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_browser_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/hash/hash.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "cc/paint/paint_canvas.h"
#include "cc/paint/paint_filter.h"
#include "cc/paint/paint_flags.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/multi_contents_view.h"
#include "chrome/browser/ui/views/frame/top_container_view.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/design/open_motion.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_sidebar_view.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "open_unified/ui/views/open_window_controls_view.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/clipboard/clipboard_format_type.h"
#include "ui/base/clipboard/clipboard_url_info.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/dragdrop/drag_drop_types.h"
#include "ui/base/dragdrop/drop_target_event.h"
#include "ui/base/dragdrop/mojom/drag_drop_types.mojom.h"
#include "ui/base/dragdrop/os_exchange_data.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_animator.h"
#include "ui/compositor/layer_nine_patch.h"
#include "ui/compositor/layer_tree_owner.h"
#include "ui/compositor/paint_recorder.h"
#include "ui/events/event.h"
#include "ui/events/event_observer.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/geometry/transform.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/view_utils.h"
#include "ui/views/animation/animation_builder.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/event_monitor.h"
#include "ui/views/paint_info.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/view_observer.h"
#include "ui/views/view_targeter.h"
#include "ui/views/view_targeter_delegate.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/frame_view.h"
#include "ui/views/window/non_client_view.h"

namespace open_unified {

DEFINE_UI_CLASS_PROPERTY_KEY(bool, kOpenWindowDragKey, false)

namespace m = metrics;

namespace {

gfx::Rect Lerp(const gfx::Rect& a, const gfx::Rect& b, double t) {
  auto l = [t](int x, int y) {
    return static_cast<int>(std::lround(x + (y - x) * t));
  };
  return gfx::Rect(l(a.x(), b.x()), l(a.y(), b.y()), l(a.width(), b.width()),
                   l(a.height(), b.height()));
}

views::NativeViewHost* HolderOf(views::View* host) {
  if (auto* web_view = views::AsViewClass<views::WebView>(host)) {
    return web_view->holder();
  }
  return nullptr;
}


theme::ContentAppearance ToAppearance(bool dark) {
  return dark ? theme::ContentAppearance::kDark
              : theme::ContentAppearance::kLight;
}

// Bound the favicon decode cache.
constexpr size_t kFaviconCacheLimit = 512;

}  // namespace

// ---------------------------------------------------------------------------
// OpenIntent factories and controller defaults.

OpenIntent OpenIntent::Of(OpenIntentKind kind) {
  OpenIntent i;
  i.kind = kind;
  return i;
}

OpenIntent OpenIntent::ForNode(OpenIntentKind kind, const ItemID& node_id) {
  OpenIntent i = Of(kind);
  i.node_id = node_id;
  return i;
}

OpenIntent OpenIntent::ForSpace(OpenIntentKind kind, const SpaceID& space_id) {
  OpenIntent i = Of(kind);
  i.space_id = space_id;
  return i;
}

OpenIntent OpenIntent::Select(const ItemID& node_id,
                              const SpaceID& space_id,
                              const ItemID& pane_id) {
  OpenIntent i = Of(OpenIntentKind::kSelectNode);
  i.node_id = node_id;
  i.space_id = space_id;
  i.secondary_id = pane_id;
  return i;
}

OpenIntent OpenIntent::Move(const ItemID& node_id,
                            const NodeParent& parent,
                            std::optional<size_t> index) {
  OpenIntent i = Of(OpenIntentKind::kMove);
  i.node_id = node_id;
  i.parent = parent;
  i.index = index;
  return i;
}

OpenIntent OpenIntent::CommandBar(CommandBarSource source,
                                  std::optional<gfx::Rect> anchor) {
  OpenIntent i = Of(OpenIntentKind::kOpenCommandBar);
  i.command_bar_source = source;
  i.anchor_in_screen = anchor;
  return i;
}

bool OpenViewController::IsIncreaseContrastEnabled() const {
  return false;
}
bool OpenViewController::IsIncognitoWindow(const WindowID&) const {
  return false;
}
std::optional<ItemID> OpenViewController::GetPeekSourceNode(
    const WindowID&) const {
  return std::nullopt;
}
bool OpenViewController::IsNewTabCommandBarOpen(const WindowID&) const {
  return false;
}
std::vector<OpenToolbarActionInfo> OpenViewController::GetPinnedToolbarActions(
    const WindowID&) const {
  return {};
}
gfx::ImageSkia OpenViewController::GetFavicon(const ItemID&) const {
  return gfx::ImageSkia();
}
bool OpenViewController::IsDeveloperModeEnabled() const {
  return false;
}
bool OpenViewController::IsTranslucencyEnabled() const {
  return true;
}
std::unique_ptr<ui::MenuModel> OpenViewController::CreateMenuModel(
    const WindowID&,
    const OpenMenuTarget&) {
  return nullptr;
}

// One full-window theme layer (field + texture), repainted only on resize,
// theme or activation changes.
class OpenThemeLayerView : public views::View {
  METADATA_HEADER(OpenThemeLayerView, views::View)

 public:
  OpenThemeLayerView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(true);
    SetCanProcessEventsWithinSubtree(false);
  }
  void SetStyle(const theme::ThemeStyle& style) {
    if (painter_.SetStyle(style)) {
      UpdateLayerOpacity();
      SchedulePaint();
    }
  }
  // macOS translucent windows: a vibrant theme paints the window tint over
  // the native material, so the layer must not claim to be opaque.
  void SetTranslucentWindow(bool translucent) {
    if (painter_.SetTranslucentWindow(translucent)) {
      UpdateLayerOpacity();
      SchedulePaint();
    }
  }
  bool PaintsOpaque() const { return painter_.PaintsOpaque(); }
  void SetActive(bool active) {
    if (painter_.SetActive(active)) {
      SchedulePaint();
    }
  }
  const theme::ThemeStyle& style() const { return painter_.style(); }

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override {
    painter_.Paint(canvas, GetLocalBounds(), gfx::RectF(GetLocalBounds()));
  }

 private:
  void UpdateLayerOpacity() {
    layer()->SetFillsBoundsOpaquely(painter_.PaintsOpaque());
  }

  theme::ThemePainter painter_;
};

BEGIN_METADATA(OpenThemeLayerView)
END_METADATA

// ---------------------------------------------------------------------------
// ThemeBackgroundView: two theme layers (current, incoming). The incoming
// layer fades in linearly over 0.21 s (compositor animation, no per-frame
// main-thread work), then the layers swap.

class OpenBrowserView::ThemeBackgroundView : public views::View {
  METADATA_HEADER(ThemeBackgroundView, views::View)

 public:
  ThemeBackgroundView() {
    // Dedicated container layer from construction so Linux CSD rounded-corner
    // clipping never dynamically creates a layer on OpenBrowserView over
    // NativeViewHostAura.
    SetPaintToLayer(ui::LAYER_NOT_DRAWN);
    SetCanProcessEventsWithinSubtree(false);
    current_ = AddChildView(std::make_unique<OpenThemeLayerView>());
    incoming_ = AddChildView(std::make_unique<OpenThemeLayerView>());
    incoming_->SetVisible(false);
  }

  void SetWindowCornerRadius(float radius) {
    if (!layer()) {
      return;
    }
    if (radius > 0.0f) {
      layer()->SetRoundedCornerRadius(gfx::RoundedCornersF(radius));
      layer()->SetIsFastRoundedCorner(true);
      layer()->SetMasksToBounds(true);
    } else {
      layer()->SetRoundedCornerRadius(gfx::RoundedCornersF());
      layer()->SetMasksToBounds(false);
    }
  }

  const theme::ThemeStyle& current_style() const { return current_->style(); }

  void SetStyle(const theme::ThemeStyle& style) {
    StopFade();
    current_->SetStyle(style);
    current_->layer()->SetOpacity(1.0f);
    incoming_->SetVisible(false);
    incoming_->layer()->SetOpacity(0.0f);
    target_.reset();
  }

  void SetActive(bool active) {
    current_->SetActive(active);
    incoming_->SetActive(active);
  }

  void SetTranslucentWindow(bool translucent) {
    translucent_ = translucent;
    current_->SetTranslucentWindow(translucent);
    incoming_->SetTranslucentWindow(translucent);
  }

  // Animated switch. A second request for the running target continues it.
  void Crossfade(const theme::ThemeStyle& style) {
    if (target_ && *target_ == style && fading_) {
      return;
    }
    if (!fading_ && current_->style() == style) {
      return;
    }
    if (motion::PrefersReducedMotion()) {
      SetStyle(style);
      return;
    }
    if (!(target_ && *target_ == style)) {
      BeginTransition(style);
    }
    FinishFade(/*commit=*/true, motion::kThemeCrossfade);
  }

  // Swipe-driven transition.
  void BeginTransition(const theme::ThemeStyle& style) {
    StopFade();
    target_ = style;
    incoming_->SetStyle(style);
    incoming_->layer()->SetOpacity(0.0f);
    current_->layer()->SetOpacity(1.0f);
    incoming_->SetVisible(true);
  }

  void SetTransitionProgress(double progress) {
    if (!target_) {
      return;
    }
    StopFade();
    const float t = static_cast<float>(std::clamp(progress, 0.0, 1.0));
    incoming_->layer()->SetOpacity(t);
    if (CrossfadesBothLayers()) {
      current_->layer()->SetOpacity(1.0f - t);
    }
  }

  void EndTransition(bool commit) {
    if (!target_) {
      return;
    }
    FinishFade(commit, motion::kThemeCrossfade);
  }

  // views::View:
  void Layout(PassKey) override {
    current_->SetBoundsRect(GetLocalBounds());
    incoming_->SetBoundsRect(GetLocalBounds());
  }

 private:
  // Two translucent window tints composited source-over would raise the
  // tint coverage mid-fade; fade the current one out as the incoming one
  // fades in (ThemeBackgroundView uses plusL for the same reason).
  bool CrossfadesBothLayers() const {
    return translucent_ &&
           (!current_->PaintsOpaque() || !incoming_->PaintsOpaque());
  }

  void FinishFade(bool commit, double duration) {
    const float start = incoming_->layer()->GetTargetOpacity();
    const float end = commit ? 1.0f : 0.0f;
    const double remaining = std::abs(end - start) * duration;
    ++generation_;
    fading_ = true;
    views::AnimationBuilder builder;
    builder
        .SetPreemptionStrategy(ui::LayerAnimator::PreemptionStrategy::
                                   IMMEDIATELY_ANIMATE_TO_NEW_TARGET)
        .OnEnded(base::BindOnce(&ThemeBackgroundView::OnFadeEnded,
                                weak_factory_.GetWeakPtr(), generation_, commit));
    auto& block = builder.Once()
                      .SetDuration(motion::Seconds(remaining))
                      .SetOpacity(incoming_->layer(), end, gfx::Tween::LINEAR);
    if (CrossfadesBothLayers()) {
      block.SetOpacity(current_->layer(), 1.0f - end, gfx::Tween::LINEAR);
    }
  }

  void OnFadeEnded(int generation, bool commit) {
    if (generation != generation_) {
      return;
    }
    fading_ = false;
    if (commit) {
      // Swap: the incoming layer becomes current; no repaint.
      std::swap(current_, incoming_);
      ReorderChildView(current_, 0);
      current_->layer()->SetOpacity(1.0f);
    }
    incoming_->SetVisible(false);
    incoming_->layer()->SetOpacity(0.0f);
    target_.reset();
  }

  void StopFade() {
    ++generation_;
    fading_ = false;
    incoming_->layer()->GetAnimator()->StopAnimating();
    current_->layer()->GetAnimator()->StopAnimating();
  }

  raw_ptr<OpenThemeLayerView> current_ = nullptr;
  raw_ptr<OpenThemeLayerView> incoming_ = nullptr;
  std::optional<theme::ThemeStyle> target_;
  bool fading_ = false;
  bool translucent_ = false;
  int generation_ = 0;
  base::WeakPtrFactory<ThemeBackgroundView> weak_factory_{this};
};

BEGIN_METADATA(OpenBrowserView, ThemeBackgroundView)
END_METADATA

// ---------------------------------------------------------------------------
// PanelShadowView: a nine-patch Gaussian shadow layer. Moving or resizing it
// per frame costs no repaint (the blurred image is built once per scale).

class OpenBrowserView::PanelShadowView : public views::View {
  METADATA_HEADER(PanelShadowView, views::View)

 public:
  PanelShadowView(float corner_radius,
                  float sigma,
                  float opacity,
                  float offset_y)
      : radius_(corner_radius),
        sigma_(sigma),
        opacity_(opacity),
        offset_y_(offset_y) {
    SetPaintToLayer(ui::LAYER_NINE_PATCH);
    layer()->SetFillsBoundsOpaquely(false);
    SetCanProcessEventsWithinSubtree(false);
    margin_ = static_cast<int>(std::ceil(3 * sigma_ + std::abs(offset_y_))) + 1;
  }

  void SetOpacity(float opacity) {
    if (layer()) {
      layer()->SetOpacity(opacity);
    }
  }

  // Places the shadow around `content` (parent coordinates).
  void SetContentBounds(const gfx::Rect& content) {
    content_ = content;
    gfx::Rect b = content;
    b.Outset(margin_);
    SetBoundsRect(b);
    UpdateImageIfNeeded();
    layer()->AsNinePatch()->UpdateNinePatchOcclusion(
        gfx::Rect(margin_, margin_, content.width(), content.height()));
  }

  // views::View:
  void AddedToWidget() override {
    scale_ = 0;
    UpdateImageIfNeeded();
  }
  void OnDeviceScaleFactorChanged(float old_scale, float new_scale) override {
    scale_ = 0;
    UpdateImageIfNeeded();
  }

 private:
  void UpdateImageIfNeeded() {
    const views::Widget* widget = GetWidget();
    const float scale = widget && widget->GetCompositor()
                            ? widget->GetCompositor()->device_scale_factor()
                            : 1.0f;
    if (scale == scale_) {
      return;
    }
    scale_ = scale;
    const int corner = margin_ + static_cast<int>(std::ceil(radius_));
    const int size = 2 * corner + 1;
    gfx::Canvas canvas(gfx::Size(size, size), scale, /*is_opaque=*/false);
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(SkColorSetA(
        SK_ColorBLACK, static_cast<U8CPU>(std::lround(opacity_ * 255))));
    if (sigma_ > 0) {
      flags.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
          sigma_, sigma_, SkTileMode::kDecal, nullptr));
    }
    canvas.DrawRoundRect(
        gfx::RectF(margin_, margin_ + offset_y_, size - 2 * margin_,
                   size - 2 * margin_),
        radius_, flags);
    layer()->AsNinePatch()->UpdateNinePatchLayerImage(
        gfx::ImageSkia(gfx::ImageSkiaRep(canvas.GetBitmap(), scale)));
    layer()->AsNinePatch()->UpdateNinePatchLayerAperture(gfx::Rect(corner, corner, 1, 1));
    layer()->AsNinePatch()->UpdateNinePatchLayerBorder(
        gfx::Rect(corner, corner, 2 * corner, 2 * corner));
  }

  float radius_;
  float sigma_;
  float opacity_;
  float offset_y_;
  int margin_ = 0;
  float scale_ = 0;
  gfx::Rect content_;
};

BEGIN_METADATA(OpenBrowserView, PanelShadowView)
END_METADATA

// ---------------------------------------------------------------------------
// PanelHostView: the web panel, a 6 pt rounded clip. Shows the single web
// contents host or the split container; an empty panel is white at 10 %.

class OpenBrowserView::PanelHostView : public views::View {
  METADATA_HEADER(PanelHostView, views::View)

 public:
  PanelHostView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    layer()->SetRoundedCornerRadius(
        gfx::RoundedCornersF(m::panel::kCornerRadius));
    layer()->SetIsFastRoundedCorner(true);
    layer()->SetMasksToBounds(true);
    GetViewAccessibility().SetRole(ax::mojom::Role::kPane);
    GetViewAccessibility().SetName(u"Web content");
  }

  // Tab fullscreen: square corners, edge to edge.
  void SetFullBleed(bool full_bleed) {
    if (full_bleed_ == full_bleed) {
      return;
    }
    full_bleed_ = full_bleed;
    UpdateCornerRadii();
    SchedulePaint();
  }

  void SetTopCornersSquare(bool top_square) {
    if (top_corners_square_ == top_square) {
      return;
    }
    top_corners_square_ = top_square;
    UpdateCornerRadii();
    SchedulePaint();
  }

  void SetSplitActive(bool split_active) {
    if (split_active_ == split_active) {
      return;
    }
    split_active_ = split_active;
    SchedulePaint();
  }

  void SetDarkContent(bool dark_content) {
    if (dark_content_ == dark_content) {
      return;
    }
    dark_content_ = dark_content;
    SchedulePaint();
  }

  // views::View:
  void Layout(PassKey) override {
    for (views::View* child : children()) {
      child->SetBoundsRect(GetLocalBounds());
    }
  }

  void OnPaint(gfx::Canvas* canvas) override {
    for (const views::View* child : children()) {
      if (child->GetVisible()) {
        return;
      }
    }
    // Empty panel: white about 10 % over the gradient.
    canvas->FillRect(GetLocalBounds(),
                     SkColorSetA(SK_ColorWHITE,
                                 static_cast<U8CPU>(std::lround(
                                     m::panel::kEmptyFillWhiteAlpha * 255))));
  }

  void PaintChildren(const views::PaintInfo& info) override {
    views::View::PaintChildren(info);
    if (full_bleed_ || split_active_ || GetLocalBounds().IsEmpty()) {
      return;
    }
    ui::PaintRecorder recorder(info.context(), size());
    gfx::Canvas* canvas = recorder.canvas();
    const float dsf = std::max(1.0f, canvas->image_scale());
    const float stroke_w = 1.0f / dsf;
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStyle(cc::PaintFlags::kStroke_Style);
    flags.setStrokeWidth(stroke_w);
    // Crisp 1 physical pixel inner rim: rgba(255,255,255,0.08) on dark Spaces,
    // rgba(0,0,0,0.06) on light Spaces.
    flags.setColor(dark_content_ ? SkColorSetARGB(20, 0xFF, 0xFF, 0xFF)
                                 : SkColorSetARGB(15, 0x00, 0x00, 0x00));
    gfx::RectF r(GetLocalBounds());
    r.Inset(stroke_w * 0.5f);
    canvas->DrawRoundRect(
        r, std::max(0.0f, m::panel::kCornerRadius - stroke_w * 0.5f), flags);
  }

 private:
  void UpdateCornerRadii() {
    if (!layer()) {
      return;
    }
    if (full_bleed_) {
      layer()->SetRoundedCornerRadius(gfx::RoundedCornersF());
    } else if (top_corners_square_) {
      const float r = m::panel::kCornerRadius;
      layer()->SetRoundedCornerRadius(gfx::RoundedCornersF(0, 0, r, r));
    } else {
      layer()->SetRoundedCornerRadius(
          gfx::RoundedCornersF(m::panel::kCornerRadius));
    }
  }

  bool full_bleed_ = false;
  bool top_corners_square_ = false;
  bool split_active_ = false;
  bool dark_content_ = false;
};

BEGIN_METADATA(OpenBrowserView, PanelHostView)
END_METADATA

// ---------------------------------------------------------------------------
// ResizeHandle: 4 pt sash centered on the sidebar edge.

class OpenBrowserView::ResizeHandle : public views::View {
  METADATA_HEADER(ResizeHandle, views::View)

 public:
  explicit ResizeHandle(OpenBrowserView* owner) : owner_(owner) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kSplitter);
    GetViewAccessibility().SetName(u"Resize sidebar");
  }

  // views::View:
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return ui::Cursor(ui::mojom::CursorType::kColumnResize);
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton()) {
      return false;
    }
    if (event.GetClickCount() == 2) {
      owner_->OnResizeDoubleClick();
      dragging_ = false;
      return true;
    }
    gfx::Point p = event.location();
    views::View::ConvertPointToScreen(this, &p);
    start_x_ = p.x();
    dragging_ = true;
    owner_->drag_start_width_ = owner_->sidebar_width_;
    owner_->resizing_ = true;
    return true;
  }

  bool OnMouseDragged(const ui::MouseEvent& event) override {
    if (!dragging_) {
      return false;
    }
    owner_->OnResizeDrag(Proposed(event), /*released=*/false);
    return true;
  }

  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (!dragging_) {
      return;
    }
    dragging_ = false;
    owner_->OnResizeDrag(Proposed(event), /*released=*/true);
  }

  void OnMouseCaptureLost() override {
    if (!dragging_) {
      return;
    }
    dragging_ = false;
    owner_->OnResizeDrag(owner_->sidebar_width_, /*released=*/true);
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    if (!dragging_) {
      if (views::Widget* w = GetWidget()) {
        w->SetCursor(ui::Cursor());
      }
    }
  }

 private:
  float Proposed(const ui::MouseEvent& event) const {
    gfx::Point p = event.location();
    views::View::ConvertPointToScreen(this, &p);
    const float delta = static_cast<float>(p.x() - start_x_);
    return owner_->sidebar_on_right_ ? (owner_->drag_start_width_ - delta)
                                     : (owner_->drag_start_width_ + delta);
  }

  raw_ptr<OpenBrowserView> owner_;
  int start_x_ = 0;
  bool dragging_ = false;
};

BEGIN_METADATA(OpenBrowserView, ResizeHandle)
END_METADATA

// ---------------------------------------------------------------------------
// HiddenSidebarToggleButton: quiet 32 x 28 DIP toggle button shown in the
// top caption strip on Windows/Linux whenever the sidebar is hidden.

class OpenBrowserView::HiddenSidebarToggleButton : public views::Button {
  METADATA_HEADER(HiddenSidebarToggleButton, views::Button)

 public:
  explicit HiddenSidebarToggleButton(PressedCallback callback)
      : views::Button(std::move(callback)) {
    // Composite on its own non-opaque layer so it paints above
    // OpenThemeLayerView's opaque ui::Layer.
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetFocusBehavior(FocusBehavior::ACCESSIBLE_ONLY);
    SetInstallFocusRingOnFocus(false);
    SetRequestFocusOnPress(false);
    SetHasInkDropActionOnClick(false);
    SetTooltipText(u"Toggle Sidebar");
    GetViewAccessibility().SetName(u"Toggle Sidebar");
  }

  void SetThemeState(bool dark_content,
                     bool window_active,
                     bool increase_contrast) {
    if (dark_content_ == dark_content && window_active_ == window_active &&
        increase_contrast_ == increase_contrast) {
      return;
    }
    dark_content_ = dark_content;
    window_active_ = window_active;
    increase_contrast_ = increase_contrast;
    SchedulePaint();
  }

  // views::Button:
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return ui::Cursor(ui::mojom::CursorType::kHand);
  }

  void StateChanged(ButtonState old_state) override {
    views::Button::StateChanged(old_state);
    SchedulePaint();
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const gfx::RectF bounds(GetLocalBounds());
    const ButtonState state = GetState();
    if (state == STATE_HOVERED || state == STATE_PRESSED) {
      cc::PaintFlags plate;
      plate.setAntiAlias(true);
      plate.setStyle(cc::PaintFlags::kFill_Style);
      const uint8_t alpha =
          state == STATE_PRESSED ? (dark_content_ ? 33 : 26)
                                 : (dark_content_ ? 20 : 15);
      plate.setColor(dark_content_ ? SkColorSetARGB(alpha, 0xFF, 0xFF, 0xFF)
                                   : SkColorSetARGB(alpha, 0x00, 0x00, 0x00));
      canvas->DrawRoundRect(bounds, m::chrome::kButtonPlateRadius, plate);
    }
    uint8_t glyph_alpha = 0;
    if (increase_contrast_) {
      glyph_alpha = window_active_ ? 255 : 191;
    } else if (dark_content_) {
      glyph_alpha = window_active_ ? 185 : 105;
    } else {
      glyph_alpha = window_active_ ? 175 : 105;
    }
    const SkColor color =
        dark_content_ ? SkColorSetARGB(glyph_alpha, 0xFF, 0xFF, 0xFF)
                      : SkColorSetARGB(glyph_alpha, 0x00, 0x00, 0x00);
    glyphs::Draw(canvas, glyphs::Glyph::kSidebarToggle, bounds, color);
  }

 private:
  bool dark_content_ = true;
  bool window_active_ = true;
  bool increase_contrast_ = false;
};

BEGIN_METADATA(OpenBrowserView, HiddenSidebarToggleButton)
END_METADATA

// ---------------------------------------------------------------------------
// WindowRimView: subtle 1 DIP outer window rim for restored Linux CSD windows,
// composited on its own non-opaque layer ABOVE theme_background_ and web content.

class OpenBrowserView::WindowRimView : public views::View {
  METADATA_HEADER(WindowRimView, views::View)

 public:
  WindowRimView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetCanProcessEventsWithinSubtree(false);
    GetViewAccessibility().SetIsInvisible(true);
    SetVisible(false);
  }

  void SetDarkContent(bool dark) {
    if (dark_content_ != dark) {
      dark_content_ = dark;
      SchedulePaint();
    }
  }

  void OnPaint(gfx::Canvas* canvas) override {
    if (GetLocalBounds().IsEmpty()) {
      return;
    }
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStyle(cc::PaintFlags::kStroke_Style);
    flags.setStrokeWidth(1.0f);
    flags.setColor(dark_content_ ? SkColorSetARGB(31, 0xFF, 0xFF, 0xFF)
                                 : SkColorSetARGB(36, 0x00, 0x00, 0x00));
    gfx::RectF r(GetLocalBounds());
    r.Inset(0.5f);
    canvas->DrawRoundRect(
        r, static_cast<float>(m::win_controls::kLinuxCornerRadius) - 0.5f,
        flags);
  }

 private:
  bool dark_content_ = true;
};

BEGIN_METADATA(OpenBrowserView, WindowRimView)
END_METADATA

// ---------------------------------------------------------------------------
// BrowserSplitDropOverlayView: transparent drag-to-split overlay positioned
// over the web panel inside overlay_host_ ONLY while dragging a sidebar tab.

class OpenBrowserView::BrowserSplitDropOverlayView : public views::View {
  METADATA_HEADER(BrowserSplitDropOverlayView, views::View)

 public:
  explicit BrowserSplitDropOverlayView(OpenBrowserView* owner)
      : owner_(owner) {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    GetViewAccessibility().SetIsInvisible(true);
    SetVisible(false);
  }

  void ResetPreview() {
    dnd_tab_id_.reset();
    dnd_url_ = GURL();
    zone_.reset();
    target_pane_index_.reset();
    SchedulePaint();
  }

  // views::View:
  bool GetDropFormats(
      int* formats,
      std::set<ui::ClipboardFormatType>* format_types) override {
    *formats = ui::OSExchangeData::URL;
    format_types->insert(sidebar_dnd::NodeFormat());
    return true;
  }

  bool CanDrop(const ui::OSExchangeData& data) override {
    return data.HasCustomFormat(sidebar_dnd::NodeFormat()) ||
           data.HasURL(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
  }

  void OnDragEntered(const ui::DropTargetEvent& event) override {
    dnd_tab_id_ = sidebar_dnd::ReadNode(event.data());
    dnd_url_ = GURL();
    if (!dnd_tab_id_) {
      const std::vector<ui::ClipboardUrlInfo> urls =
          event.data().GetURLs(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
      if (!urls.empty()) {
        dnd_url_ = urls.front().url;
      }
    }
  }

  int OnDragUpdated(const ui::DropTargetEvent& event) override {
    if (!dnd_tab_id_ && !dnd_url_.is_valid()) {
      OnDragEntered(event);
    }
    const SplitDropZone zone =
        OpenSplitContainerView::ComputeDropZoneAt(GetLocalBounds(),
                                                  event.location());
    const std::vector<gfx::Rect> pane_bounds = ActivePaneBounds();
    std::optional<size_t> target_pane;
    if (zone == SplitDropZone::kReplacePane) {
      target_pane = 0;
      for (size_t i = 0; i < pane_bounds.size(); ++i) {
        if (pane_bounds[i].Contains(event.location())) {
          target_pane = i;
          break;
        }
      }
    }
    const bool allowed =
        owner_->delegate_ &&
        owner_->delegate_->CanDropInSplit(dnd_tab_id_, dnd_url_, zone,
                                          target_pane);
    if (!allowed) {
      if (zone_.has_value()) {
        zone_.reset();
        target_pane_index_.reset();
        SchedulePaint();
      }
      return ui::DragDropTypes::DRAG_NONE;
    }
    if (zone_ != zone || target_pane_index_ != target_pane) {
      zone_ = zone;
      target_pane_index_ = target_pane;
      SchedulePaint();
    }
    return dnd_tab_id_ ? ui::DragDropTypes::DRAG_MOVE
                       : ui::DragDropTypes::DRAG_COPY |
                             ui::DragDropTypes::DRAG_LINK;
  }

  void OnDragExited() override { ResetPreview(); }

  views::View::DropCallback GetDropCallback(
      const ui::DropTargetEvent& event) override {
    const std::optional<SplitDropZone> zone = zone_;
    const std::optional<size_t> target_pane = target_pane_index_;
    std::optional<ItemID> tab_id = dnd_tab_id_;
    GURL url = dnd_url_;
    ResetPreview();
    owner_->SetSplitDropOverlayActive(false);
    if (!zone || !owner_->delegate_) {
      return base::NullCallback();
    }
    return base::BindOnce(&BrowserSplitDropOverlayView::PerformDrop,
                          weak_factory_.GetWeakPtr(), std::move(tab_id),
                          std::move(url), *zone, target_pane);
  }

  void OnPaint(gfx::Canvas* canvas) override {
    if (!zone_) {
      return;
    }
    const gfx::Rect preview = OpenSplitContainerView::ComputeDropPreviewRect(
        GetLocalBounds(), ActivePaneBounds(), *zone_, target_pane_index_);
    gfx::RectF card(preview);
    card.Inset(6.0f);
    if (card.IsEmpty()) {
      return;
    }
    const OpenSpaceThemeState& state = owner_->FocusedThemeState();
    const SkColor accent = theme::ToSkColor(state.contrast_accent);
    constexpr float kRadius = 10.0f;
    secondary::FillRoundRect(canvas, card, kRadius,
                             secondary::WithAlpha(accent, 0.16f));
    secondary::StrokeRoundRect(canvas, card, kRadius,
                               secondary::WithAlpha(accent, 0.72f), 2.0f);
    std::u16string label;
    switch (*zone_) {
      case SplitDropZone::kLeft:
        label = u"Split Left";
        break;
      case SplitDropZone::kRight:
        label = u"Split Right";
        break;
      case SplitDropZone::kTop:
        label = u"Split Top";
        break;
      case SplitDropZone::kBottom:
        label = u"Split Bottom";
        break;
      case SplitDropZone::kReplacePane:
        label = u"Open in Pane";
        break;
    }
    const gfx::FontList& font =
        typography::Make(13, gfx::Font::Weight::MEDIUM);
    const int pill_w =
        std::min(static_cast<int>(card.width()) - 24,
                 gfx::Canvas::GetStringWidth(label, font) + 28);
    constexpr int kPillH = 30;
    if (pill_w >= 48 && card.height() >= kPillH + 16) {
      const gfx::Rect pill(
          static_cast<int>(card.x() + (card.width() - pill_w) * 0.5f),
          static_cast<int>(card.y() + (card.height() - kPillH) * 0.5f), pill_w,
          kPillH);
      secondary::FillRoundRect(canvas, gfx::RectF(pill), kPillH * 0.5f,
                               secondary::WithAlpha(accent, 0.90f));
      secondary::DrawText(canvas, label, font, SK_ColorWHITE, pill,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
    }
  }

 private:
  std::vector<gfx::Rect> ActivePaneBounds() const {
    if (owner_->split_view_active_ && owner_->split_container_) {
      if (auto* split = views::AsViewClass<OpenSplitContainerView>(
              owner_->split_container_.get())) {
        return split->GetPaneBounds();
      }
    }
    return {};
  }

  void PerformDrop(std::optional<ItemID> dragged_tab_id,
                   GURL dragged_url,
                   SplitDropZone zone,
                   std::optional<size_t> target_pane_index,
                   const ui::DropTargetEvent& event,
                   ui::mojom::DragOperation& output_drag_op,
                   std::unique_ptr<ui::LayerTreeOwner> drag_image_layer_owner) {
    const bool accepted =
        owner_->delegate_ &&
        owner_->delegate_->OnDropInSplit(dragged_tab_id, dragged_url, zone,
                                         target_pane_index);
    if (!accepted) {
      output_drag_op = ui::mojom::DragOperation::kNone;
      return;
    }
    output_drag_op = dragged_tab_id ? ui::mojom::DragOperation::kMove
                                    : ui::mojom::DragOperation::kCopy;
  }

  raw_ptr<OpenBrowserView> owner_;
  std::optional<ItemID> dnd_tab_id_;
  GURL dnd_url_;
  std::optional<SplitDropZone> zone_;
  std::optional<size_t> target_pane_index_;
  base::WeakPtrFactory<BrowserSplitDropOverlayView> weak_factory_{this};
};

BEGIN_METADATA(OpenBrowserView, BrowserSplitDropOverlayView)
END_METADATA

// ---------------------------------------------------------------------------
// SinglePaneToolbarView: optional 36 DIP top toolbar for single-tab mode
// (Back/Forward/Reload, clickable URL capsule, Copy URL, Site Control).

class OpenBrowserView::SinglePaneToolbarView : public views::View {
  METADATA_HEADER(SinglePaneToolbarView, views::View)

 public:
  explicit SinglePaneToolbarView(OpenBrowserView* owner) : owner_(owner) {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetVisible(false);
    GetViewAccessibility().SetRole(ax::mojom::Role::kToolbar);
    GetViewAccessibility().SetName(u"Page toolbar");

    auto add_btn = [this](secondary::Glyph glyph, const char16_t* name,
                          PaneCommand cmd, float size) {
      auto btn = std::make_unique<secondary::GlyphButton>(
          base::BindRepeating(&SinglePaneToolbarView::OnButtonPressed,
                              base::Unretained(this), cmd),
          glyph, name);
      btn->SetGlyphSize(size);
      btn->SetPlate(secondary::GlyphButton::Plate::kHoverRounded,
                    SK_ColorTRANSPARENT, 6.0f);
      return AddChildView(std::move(btn));
    };
    back_ = add_btn(secondary::Glyph::kBack, u"Go back", PaneCommand::kBack,
                    14.0f);
    forward_ = add_btn(secondary::Glyph::kForward, u"Go forward",
                       PaneCommand::kForward, 14.0f);
    reload_ = add_btn(secondary::Glyph::kReload, u"Reload",
                      PaneCommand::kReload, 14.0f);
    copy_ = add_btn(secondary::Glyph::kLink, u"Copy Current URL",
                    PaneCommand::kCopyUrl, 13.0f);
    site_ = add_btn(secondary::Glyph::kSiteControl, u"Site Control Center",
                    PaneCommand::kSiteControl, 16.0f);
    site_->SetDimsWhenDisabled(false);
    ApplyColors();
  }

  void SetState(const SinglePaneToolbarState& state) {
    if (state_ == state) {
      return;
    }
    state_ = state;
    back_->SetEnabled(state_.can_go_back);
    forward_->SetEnabled(state_.can_go_forward);
    site_->SetEnabled(state_.site_controls_available);
    copy_->SetVisible(!state_.hides_copy);
    reload_->SetGlyph(state_.is_loading ? secondary::Glyph::kStop
                                        : secondary::Glyph::kReload);
    const std::u16string reload_label =
        state_.is_loading ? u"Stop loading" : u"Reload";
    reload_->SetTooltipText(reload_label);
    reload_->GetViewAccessibility().SetName(reload_label);
    ApplyColors();
    InvalidateLayout();
    SchedulePaint();
  }

  views::View* site_control_anchor() const { return site_; }

  // views::View:
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    if (capsule_rect_.Contains(event.location())) {
      return ui::Cursor(ui::mojom::CursorType::kHand);
    }
    return views::View::GetCursor(event);
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    const bool over = capsule_rect_.Contains(event.location());
    if (over != capsule_hovered_) {
      capsule_hovered_ = over;
      SchedulePaint();
    }
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    if (capsule_hovered_) {
      capsule_hovered_ = false;
      SchedulePaint();
    }
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    return event.IsOnlyLeftMouseButton() &&
           capsule_rect_.Contains(event.location());
  }

  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (event.IsOnlyLeftMouseButton() &&
        capsule_rect_.Contains(event.location())) {
      owner_->OnSinglePaneHostClicked(this);
    }
  }

  void Layout(PassKey) override {
    const int w = width();
    const int h = height();
    const int by = (h - 28) / 2;
    back_->SetBounds(6, by, 30, 28);
    forward_->SetBounds(38, by, 30, 28);
    reload_->SetBounds(70, by, 30, 28);

    int right = w - 6;
    site_->SetBounds(right - 30, by, 30, 28);
    right -= 34;
    if (!state_.hides_copy) {
      copy_->SetVisible(true);
      copy_->SetBounds(right - 30, by, 30, 28);
      right -= 34;
    } else {
      copy_->SetVisible(false);
    }

    const int left = 108;
    const int avail = std::max(0, right - left);
    const int cap_w = std::min(avail, 420);
    const int cap_x = left + (avail - cap_w) / 2;
    capsule_rect_ = cap_w >= 48 ? gfx::Rect(cap_x, 5, cap_w, h - 10)
                                : gfx::Rect();
  }

  void OnPaint(gfx::Canvas* canvas) override {
    cc::PaintFlags bg;
    bg.setAntiAlias(true);
    bg.setColor(state_.background);
    const float r = m::panel::kCornerRadius;
    const SkVector radii[4] = {{r, r}, {r, r}, {0, 0}, {0, 0}};
    SkRRect rrect;
    rrect.setRectRadii(gfx::RectFToSkRect(gfx::RectF(GetLocalBounds())), radii);
    canvas->sk_canvas()->drawRRect(rrect, bg);

    const bool dark = secondary::IsDark(state_.background);
    const SkColor ink = dark ? SK_ColorWHITE : SK_ColorBLACK;

    // Subtle 1px bottom hairline separating toolbar from page content.
    canvas->FillRect(gfx::Rect(0, height() - 1, width(), 1),
                     secondary::WithAlpha(ink, dark ? 0.10f : 0.08f));

    if (!capsule_rect_.IsEmpty()) {
      secondary::FillRoundRect(
          canvas, gfx::RectF(capsule_rect_), 8.0f,
          secondary::WithAlpha(ink, capsule_hovered_ ? (dark ? 0.12f : 0.08f)
                                                     : (dark ? 0.07f : 0.045f)));
      gfx::Rect text_rect = capsule_rect_;
      text_rect.Inset(gfx::Insets::VH(0, 10));
      const GURL gurl(state_.url);
      const bool insecure = gurl.is_valid() && gurl.SchemeIs("http") &&
                            gurl.host() != "localhost" &&
                            gurl.host() != "127.0.0.1" &&
                            gurl.host() != "[::1]";
      if (insecure && text_rect.width() > 28) {
        const SkColor warn = dark ? SkColorSetARGB(220, 0xFB, 0xBF, 0x24)
                                  : SkColorSetARGB(230, 0xB4, 0x53, 0x09);
        secondary::PaintGlyph(
            canvas, secondary::Glyph::kLockOpen,
            gfx::RectF(text_rect.x(),
                       text_rect.y() + (text_rect.height() - 13.0f) * 0.5f,
                       13.0f, 13.0f),
            warn);
        text_rect.Inset(gfx::Insets::TLBR(0, 18, 0, 0));
      }
      const std::u16string label =
          state_.host.empty() ? u"Search or Enter URL…" : state_.host;
      secondary::DrawText(canvas, label,
                          typography::Make(13, gfx::Font::Weight::NORMAL),
                          secondary::WithAlpha(ink, state_.host.empty() ? 0.45f : 0.78f),
                          text_rect, gfx::Canvas::TEXT_ALIGN_CENTER);
    }
  }

 private:
  void ApplyColors() {
    const bool dark = secondary::IsDark(state_.background);
    const SkColor ink = dark ? SK_ColorWHITE : SK_ColorBLACK;
    for (secondary::GlyphButton* btn :
         {back_.get(), forward_.get(), reload_.get(), copy_.get(),
          site_.get()}) {
      btn->SetGlyphColor(secondary::WithAlpha(ink, 0.65f));
      btn->SetHoverFill(secondary::WithAlpha(ink, dark ? 0.10f : 0.07f));
    }
  }

  void OnButtonPressed(PaneCommand cmd) {
    views::View* anchor = this;
    if (cmd == PaneCommand::kReload && state_.is_loading) {
      cmd = PaneCommand::kStop;
    }
    switch (cmd) {
      case PaneCommand::kBack:
        anchor = back_;
        break;
      case PaneCommand::kForward:
        anchor = forward_;
        break;
      case PaneCommand::kReload:
      case PaneCommand::kStop:
        anchor = reload_;
        break;
      case PaneCommand::kCopyUrl:
        anchor = copy_;
        break;
      case PaneCommand::kSiteControl:
        anchor = site_;
        break;
      default:
        break;
    }
    owner_->OnSinglePaneToolbarCommand(cmd, anchor);
  }

  raw_ptr<OpenBrowserView> owner_;
  SinglePaneToolbarState state_;
  raw_ptr<secondary::GlyphButton> back_ = nullptr;
  raw_ptr<secondary::GlyphButton> forward_ = nullptr;
  raw_ptr<secondary::GlyphButton> reload_ = nullptr;
  raw_ptr<secondary::GlyphButton> copy_ = nullptr;
  raw_ptr<secondary::GlyphButton> site_ = nullptr;
  gfx::Rect capsule_rect_;
  bool capsule_hovered_ = false;
};

BEGIN_METADATA(OpenBrowserView, SinglePaneToolbarView)
END_METADATA

// ---------------------------------------------------------------------------
// RevealCardView: the floating sidebar card [5, 5, S, H - 10], radius 12.
// Fill: the theme tint at 1 - w (0.885) over the blurred page; stroke 1 pt
// white 0.30 drawn above the sidebar.

class OpenBrowserView::RevealCardView : public views::View {
  METADATA_HEADER(RevealCardView, views::View)

 public:
  RevealCardView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    layer()->SetRoundedCornerRadius(
        gfx::RoundedCornersF(m::window::kRevealCardRadius));
    layer()->SetIsFastRoundedCorner(true);
    layer()->SetMasksToBounds(true);
    // Gaussian page blur under the card (sigma ~25 pt, fitted).
    layer()->SetBackgroundBlur(
        static_cast<float>(theme::window_material::kPageBlurSigma));
    painter_.SetCardTint(true);
  }

  void SetStyle(const theme::ThemeStyle& style) {
    if (painter_.SetStyle(style)) {
      SchedulePaint();
    }
  }
  void SetActive(bool active) {
    if (painter_.SetActive(active)) {
      SchedulePaint();
    }
  }
  void SetWindowSize(const gfx::Size& size) {
    if (window_size_ != size) {
      window_size_ = size;
      SchedulePaint();
    }
  }

  // views::View:
  void Layout(PassKey) override {
    for (views::View* child : children()) {
      child->SetBoundsRect(GetLocalBounds());
    }
  }

  void OnPaint(gfx::Canvas* canvas) override {
    // The tint field is the window's field; the card shows its own part.
    const gfx::RectF window(-x(), -y(), window_size_.width(),
                            window_size_.height());
    canvas->SaveLayerAlpha(static_cast<uint8_t>(std::lround(
        (1 - theme::window_material::kBackdropWeight) * 255)));
    painter_.Paint(canvas, GetLocalBounds(), window);
    canvas->Restore();
  }

  void PaintChildren(const views::PaintInfo& info) override {
    views::View::PaintChildren(info);
    ui::PaintRecorder recorder(info.context(), size());
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStyle(cc::PaintFlags::kStroke_Style);
    flags.setStrokeWidth(m::window::kRevealCardStrokeWidth);
    flags.setColor(SkColorSetA(
        SK_ColorWHITE,
        static_cast<U8CPU>(std::lround(m::window::kRevealCardStroke.alpha * 255))));
    gfx::RectF r(GetLocalBounds());
    r.Inset(m::window::kRevealCardStrokeWidth / 2);
    recorder.canvas()->DrawRoundRect(
        r, m::window::kRevealCardRadius - m::window::kRevealCardStrokeWidth / 2,
        flags);
  }

 private:
  theme::ThemePainter painter_;
  gfx::Size window_size_;
};

BEGIN_METADATA(OpenBrowserView, RevealCardView)
END_METADATA

// ---------------------------------------------------------------------------

class OpenBrowserView::RevealObserver : public ui::EventObserver {
 public:
  explicit RevealObserver(OpenBrowserView* view) : view_(view) {}
  void OnEvent(const ui::Event& event) override { view_->OnRevealEvent(event); }

 private:
  raw_ptr<OpenBrowserView> view_;
};

// Open's default "+" menu when the controller supplies none:
// New Space, New Folder, -, New Easel, New Note.
class OpenBrowserView::PlusMenuDelegate : public ui::SimpleMenuModel::Delegate {
 public:
  enum Command { kNewSpace = 1, kNewFolder, kNewEasel, kNewNote };

  PlusMenuDelegate(OpenBrowserView* view, const SpaceID& space_id)
      : view_(view), space_id_(space_id) {}

  std::unique_ptr<ui::SimpleMenuModel> CreateModel() {
    auto model = std::make_unique<ui::SimpleMenuModel>(this);
    model->AddItem(kNewSpace, u"New Space");
    model->AddItem(kNewFolder, u"New Folder");
    model->AddSeparator(ui::NORMAL_SEPARATOR);
    model->AddItem(kNewEasel, u"New Easel");
    model->AddItem(kNewNote, u"New Note");
    return model;
  }

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override {
    switch (command_id) {
      case kNewSpace:
        view_->Send(OpenIntent::Of(OpenIntentKind::kNewSpace));
        break;
      case kNewFolder: {
        OpenIntent intent = OpenIntent::Of(OpenIntentKind::kNewFolder);
        intent.parent = {NodeParentKind::kSpacePinned, space_id_};
        intent.space_id = space_id_;
        view_->Send(intent);
        break;
      }
      case kNewEasel:
        view_->Send(OpenIntent::Of(OpenIntentKind::kNewEasel));
        break;
      case kNewNote:
        view_->Send(OpenIntent::Of(OpenIntentKind::kNewNote));
        break;
    }
  }

 private:
  raw_ptr<OpenBrowserView> view_;
  SpaceID space_id_;
};

// Transparent overlay layer placed above BrowserView's contents_container so
// Command Bar, Peek, Find/Toasts, and the hover-reveal card sit above web
// content without reparenting contents_container out of BrowserView.
class OpenOverlayHostView : public views::View,
                            public views::ViewTargeterDelegate {
  METADATA_HEADER(OpenOverlayHostView, views::View)

 public:
  OpenOverlayHostView() {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    SetEventTargeter(std::make_unique<views::ViewTargeter>(this));
  }

  // views::ViewTargeterDelegate:
  bool DoesIntersectRect(const views::View* target,
                         const gfx::Rect& rect) const override {
    if (target != this) {
      return views::ViewTargeterDelegate::DoesIntersectRect(target, rect);
    }
    for (const views::View* child : children()) {
      if (!child->GetVisible() || !child->GetCanProcessEventsWithinSubtree()) {
        continue;
      }
      if (child->bounds().Intersects(rect)) {
        return true;
      }
    }
    return false;
  }
};

BEGIN_METADATA(OpenOverlayHostView)
END_METADATA

// Keeps OpenBrowserView sized to the BrowserView it covers.
class OpenBrowserView::BrowserViewTracker : public views::ViewObserver {
 public:
  BrowserViewTracker(OpenBrowserView* owner, views::View* browser_view)
      : owner_(owner) {
    observation_.Observe(browser_view);
  }
  void OnViewBoundsChanged(views::View* observed_view) override {
    owner_->SetBoundsRect(observed_view->GetLocalBounds());
  }
  void OnViewIsDeleting(views::View* observed_view) override {
    observation_.Reset();
  }

 private:
  raw_ptr<OpenBrowserView> owner_;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};

// ---------------------------------------------------------------------------
// Chromium integration (hook 0002)

// static
void OpenBrowserView::Install(BrowserView* browser_view,
                              OpenViewController* controller) {
  if (!browser_view || !controller || FromBrowserView(browser_view)) {
    return;
  }
  const WindowID window_id = controller->WindowIdForBrowserView(browser_view);
  auto owned = std::make_unique<OpenBrowserView>(controller, window_id);
  OpenBrowserView* view = owned.get();
  view->browser_view_ = browser_view;
  // Open's sidebar replaces Chromium's tab strip (horizontal and vertical),
  // toolbar, bookmark bar, side panels, and infobar container. Hide every
  // existing BrowserView child except contents_container so no Chromium 156
  // chrome paints above OpenBrowserView (which sits at child index 0).
  view->browser_contents_container_ = browser_view->contents_container();
  for (views::View* child : browser_view->children()) {
    if (child != view->browser_contents_container_) {
      child->SetVisible(false);
    }
  }
  // Keep contents_container as a direct child of BrowserView (reparenting it
  // out/back fires OnViewAddedToWidget a second time on TabModalDialogHost).
  // Place OpenBrowserView behind it (theme, shadow, sidebar, split) and a
  // hit-test-transparent OpenOverlayHostView above it (reveal card, overlays).
  browser_view->AddChildViewAt(std::move(owned), 0);
  view->overlay_host_ =
      browser_view->AddChildView(std::make_unique<OpenOverlayHostView>());
  if (view->split_drop_overlay_ &&
      view->split_drop_overlay_->parent() == view) {
    view->split_drop_overlay_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->split_drop_overlay_.get()));
  }
  if (view->card_shadow_ && view->card_shadow_->parent() == view) {
    view->card_shadow_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->card_shadow_.get()));
  }
  if (view->reveal_card_ && view->reveal_card_->parent() == view) {
    view->reveal_card_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->reveal_card_.get()));
  }
  if (view->window_rim_ && view->window_rim_->parent() == view) {
    view->window_rim_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->window_rim_.get()));
  }
  const gfx::Rect bounds = browser_view->GetLocalBounds();
  view->SetBoundsRect(bounds);
  view->overlay_host_->SetBoundsRect(bounds);
  view->browser_view_tracker_ =
      std::make_unique<BrowserViewTracker>(view, browser_view);
  view->ApplyWebCornerRadii();
}

// static
void OpenBrowserView::Uninstall(BrowserView* browser_view) {
  OpenBrowserView* view = FromBrowserView(browser_view);
  if (!view) {
    return;
  }
  view->browser_view_tracker_.reset();
  if (view->sidebar_ && view->reveal_card_ &&
      view->sidebar_->parent() == view->reveal_card_.get()) {
    view->ReparentSidebar(false);
  }
  if (view->overlay_host_) {
    views::View* host = view->overlay_host_;
    view->overlay_host_ = nullptr;
    view->split_drop_overlay_ = nullptr;
    view->card_shadow_ = nullptr;
    view->reveal_card_ = nullptr;
    view->window_rim_ = nullptr;
    view->overlays_.clear();
    browser_view->RemoveChildViewT(host);
  }
  if (view->browser_contents_container_) {
    view->browser_contents_container_->SetVisible(true);
    view->browser_contents_container_ = nullptr;
  }
  if (TopContainerView* top = browser_view->top_container()) {
    top->SetVisible(true);
  }
  view->browser_view_ = nullptr;
  browser_view->RemoveChildViewT(view);
}

// static
OpenBrowserView* OpenBrowserView::FromBrowserView(BrowserView* browser_view) {
  if (!browser_view) {
    return nullptr;
  }
  for (views::View* child : browser_view->children()) {
    if (auto* view = views::AsViewClass<OpenBrowserView>(child)) {
      return view;
    }
  }
  return nullptr;
}

// static
bool OpenBrowserView::WantsFramelessWindow() {
  return true;
}

views::View* OpenBrowserView::sidebar_view() {
  return sidebar_;
}

views::NativeViewHost* OpenBrowserView::ActiveWebHolder() const {
  if (browser_view_) {
    if (views::WebView* web_view = browser_view_->GetActiveContentsWebView()) {
      return web_view->holder();
    }
  }
  return HolderOf(web_contents_host_);
}

void OpenBrowserView::ApplyWebCornerRadii() {
  // Native web content is not clipped by the panel layer: apply the panel's
  // 6 pt corners (square in tab fullscreen, or bottom-only when the 36 DIP
  // single-pane top toolbar sits above the page) through MultiContentsView and
  // the active NativeViewHost.
  const float r = m::panel::kCornerRadius;
  const gfx::RoundedCornersF radii =
      tab_fullscreen_applied_
          ? gfx::RoundedCornersF()
          : (ShowsSinglePaneToolbar() ? gfx::RoundedCornersF(0, 0, r, r)
                                      : gfx::RoundedCornersF(r));
  if (auto* multi = views::AsViewClass<MultiContentsView>(
          browser_contents_container_.get())) {
    multi->SetShouldShowTopSeparator(false);
    multi->SetBackgroundRadii(radii);
  }
  if (views::NativeViewHost* holder = ActiveWebHolder()) {
    holder->SetNativeViewCornerRadii(radii);
  }
}

// ---------------------------------------------------------------------------
// OpenBrowserView

OpenBrowserView::OpenBrowserView(OpenViewController* controller,
                                 const WindowID& window_id)
    : controller_(controller),
      window_id_(window_id),
      sidebar_width_(m::window::kDefaultSidebarWidth),
#if BUILDFLAG(IS_MAC)
      window_controls_(WindowControls::kNativeMac)
#elif BUILDFLAG(IS_WIN)
      window_controls_(WindowControls::kWindowsFluent)
#elif BUILDFLAG(IS_LINUX)
      window_controls_(WindowControls::kLinuxCsd)
#else
      window_controls_(WindowControls::kNone)
#endif
{
#if BUILDFLAG(IS_LINUX)
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    const LinuxWindowButtons linux_buttons = platform->GetLinuxWindowButtons();
    if (linux_buttons.leading.empty() && linux_buttons.trailing.empty()) {
      window_controls_ = WindowControls::kNone;
    }
  }
#endif
  if (const BrowserWindowState* state = controller_->GetWindowState(window_id_)) {
    sidebar_width_ = m::window::ClampSidebarWidth(
        static_cast<float>(state->sidebar_width));
    sidebar_hidden_ = state->sidebar_mode == SidebarMode::kHidden;
  }
  sidebar_offset_ = sidebar_hidden_ ? -sidebar_width_ : 0;

  theme_background_ = AddChildView(std::make_unique<ThemeBackgroundView>());
  panel_shadow_ = AddChildView(std::make_unique<PanelShadowView>(
      m::panel::kCornerRadius, m::panel::kShadowBlur / 2,
      m::panel::kShadowOpacity, m::panel::kShadowOffsetY));
  panel_host_ = AddChildView(std::make_unique<PanelHostView>());
  single_pane_toolbar_ =
      AddChildView(std::make_unique<SinglePaneToolbarView>(this));

  auto sidebar = std::make_unique<OpenSidebarView>(this);
  sidebar->SetPaintToLayer();
  sidebar->layer()->SetFillsBoundsOpaquely(false);
  sidebar_ = AddChildView(std::move(sidebar));
  sidebar_->SetWindowControlsSlot(
      window_controls_ == WindowControls::kNativeMac
          ? OpenSidebarView::WindowControlsSlot::kNativeReserved
          : OpenSidebarView::WindowControlsSlot::kNone);
  sidebar_->SetVisible(!sidebar_hidden_);

  resize_handle_ = AddChildView(std::make_unique<ResizeHandle>(this));

  hidden_sidebar_toggle_ =
      AddChildView(std::make_unique<HiddenSidebarToggleButton>(
          base::BindRepeating(&OpenBrowserView::RequestToggleSidebar,
                              base::Unretained(this))));
  hidden_sidebar_toggle_->SetVisible(false);

  split_drop_overlay_ =
      AddChildView(std::make_unique<BrowserSplitDropOverlayView>(this));
  card_shadow_ = AddChildView(std::make_unique<PanelShadowView>(
      m::window::kRevealCardRadius, m::window::kRevealCardShadowRadius,
      m::window::kRevealCardShadowOpacity, 0));
  card_shadow_->SetVisible(false);
  reveal_card_ = AddChildView(std::make_unique<RevealCardView>());
  reveal_card_->SetVisible(false);
  window_rim_ = AddChildView(std::make_unique<WindowRimView>());

  RebuildWindowControls();

  sidebar_slide_ = std::make_unique<motion::OpenSpringAnimator>(
      motion::kSidebarToggle,
      base::BindRepeating(&OpenBrowserView::ApplySidebarOffset,
                          base::Unretained(this)),
      base::BindRepeating(&OpenBrowserView::OnSidebarSlideSettled,
                          base::Unretained(this)));
  sidebar_slide_->set_epsilon(0.25);
  card_motion_ = std::make_unique<motion::OpenSpringAnimator>(
      motion::kRevealCardIn,
      base::BindRepeating(&OpenBrowserView::ApplyCardOffset,
                          base::Unretained(this)),
      base::BindRepeating(&OpenBrowserView::OnCardMotionSettled,
                          base::Unretained(this)));
  card_motion_->set_epsilon(0.25);
  reveal_observer_ = std::make_unique<RevealObserver>(this);

  const OpenSpaceThemeState& focused = ThemeStateFor(FocusedSpaceId());
  theme_background_->SetStyle(focused.style);
  reveal_card_->SetStyle(focused.style);
  shown_theme_space_ = FocusedSpaceId();
  SyncWindowControlsState();

  GetViewAccessibility().SetRole(ax::mojom::Role::kClient);
  controller_->AddViewObserver(this);
}

OpenBrowserView::~OpenBrowserView() {
  ReleaseMenuRevealLock();
  controller_->RemoveViewObserver(this);
  StopRevealMonitor();
  sidebar_slide_->SetCompositor(nullptr);
  card_motion_->SetCompositor(nullptr);
}

const WindowID& OpenBrowserView::window_id() const {
  return window_id_;
}

OpenViewController* OpenBrowserView::controller() const {
  return controller_;
}

void OpenBrowserView::RebindWindowId(const WindowID& window_id) {
  window_id_ = window_id;
  theme_cache_.clear();
  shown_theme_space_.reset();
  transition_space_.reset();
  favicon_cache_.clear();
#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_WIN)
  applied_material_.reset();
#endif
  SyncFromWindowState(/*animate=*/false);
  InvalidateThemeCache();
  sidebar_->OnSpacesChanged();
  sidebar_->OnFavoritesChanged();
  sidebar_->OnWindowStateChanged(/*animate=*/false);
  sidebar_->OnActiveTabChanged();
  SetSplitViewActive(controller_->IsSplitViewActive(window_id_));
  UpdatePanelChildren();
  ApplyWebCornerRadii();
  SyncWindowControlsState();
  InvalidateLayout();
  UpdateWindowMaterial();
}

// --- Panel slots ---------------------------------------------------------------

views::View* OpenBrowserView::SetWebContentsHost(
    std::unique_ptr<views::View> host) {
  if (web_contents_host_) {
    views::View* old = web_contents_host_;
    web_contents_host_ = nullptr;
    panel_host_->RemoveChildViewT(old);
  }
  if (host) {
    web_contents_host_ = panel_host_->AddChildView(std::move(host));
    ApplyWebCornerRadii();
  }
  UpdatePanelChildren();
  // A new child needs its bounds even when no visibility changed.
  panel_host_->InvalidateLayout();
  return web_contents_host_;
}

views::View* OpenBrowserView::SetSplitContainer(
    std::unique_ptr<views::View> container,
    OpenPanelSlideClient* slide_client) {
  if (split_container_) {
    views::View* old = split_container_;
    split_container_ = nullptr;
    split_slide_client_ = nullptr;
    panel_host_->RemoveChildViewT(old);
  }
  if (container) {
    split_container_ = panel_host_->AddChildView(std::move(container));
    split_slide_client_ = slide_client;
    if (auto* split = views::AsViewClass<OpenSplitContainerView>(
            split_container_.get())) {
      split->SetShowFullUrl(show_full_url_);
    }
    SyncWindowControlsState();
  }
  UpdatePanelChildren();
  // A new child needs its bounds even when no visibility changed.
  panel_host_->InvalidateLayout();
  return split_container_;
}

void OpenBrowserView::SetSplitViewActive(bool active) {
  if (split_view_active_ == active) {
    return;
  }
  split_view_active_ = active;
  UpdatePanelChildren();
  ApplyWebCornerRadii();
  sidebar_->OnSplitViewChanged(active);
  InvalidateLayout();
}

void OpenBrowserView::SetSplitDropOverlayActive(bool active) {
  const bool next = active && !tab_fullscreen_applied_;
  if (split_drop_overlay_active_ == next) {
    return;
  }
  split_drop_overlay_active_ = next;
  if (split_drop_overlay_) {
    if (!next) {
      split_drop_overlay_->ResetPreview();
    }
    split_drop_overlay_->SetVisible(next);
    if (next) {
      LayoutOverlays();
    }
  }
}

bool OpenBrowserView::IsSplitDropOverlayActive() const {
  return split_drop_overlay_active_;
}

void OpenBrowserView::SetSinglePaneToolbarVisible(bool visible) {
  if (single_pane_toolbar_visible_ == visible) {
    return;
  }
  single_pane_toolbar_visible_ = visible;
  if (visible) {
    SyncSinglePaneToolbarFromActiveTab();
  }
  ApplyWebCornerRadii();
  InvalidateLayout();
}

void OpenBrowserView::UpdateSinglePaneToolbar(
    const SinglePaneToolbarState& state) {
  if (single_pane_toolbar_) {
    single_pane_toolbar_->SetState(state);
  }
}

views::View* OpenBrowserView::GetSinglePaneSiteControlAnchor() const {
  return single_pane_toolbar_ ? single_pane_toolbar_->site_control_anchor()
                              : nullptr;
}

bool OpenBrowserView::ShowsSinglePaneToolbar() const {
  return single_pane_toolbar_visible_ && !split_view_active_ &&
         !tab_fullscreen_applied_ && HasActiveTab();
}

void OpenBrowserView::SyncSinglePaneToolbarFromActiveTab() {
  if (!single_pane_toolbar_) {
    return;
  }
  SinglePaneToolbarState state;
  const OpenSpaceThemeState& theme = FocusedThemeState();
  const bool dark = theme.roles.content == theme::ContentAppearance::kDark;
  state.background = dark ? SkColorSetRGB(0x1E, 0x20, 0x28) : SK_ColorWHITE;
  if (const Tab* tab = controller_->GetActiveTab(window_id_)) {
    state.can_go_back = tab->live_state.can_go_back;
    state.can_go_forward = tab->live_state.can_go_forward;
    state.is_loading = tab->live_state.is_loading;
    state.url = tab->url;
    const GURL gurl(tab->url);
    state.host = secondary::FormatUrlForDisplay(tab->url, show_full_url_);
    if (gurl.is_valid()) {
      state.hides_copy = gurl.SchemeIs("open") && gurl.host() == "note";
      state.site_controls_available = gurl.SchemeIsHTTPOrHTTPS();
    }
    if (tab->live_state.page_background_color.has_value()) {
      state.background =
          secondary::ToSkColor(*tab->live_state.page_background_color);
    }
  }
  single_pane_toolbar_->SetState(state);
}

void OpenBrowserView::OnSinglePaneToolbarCommand(PaneCommand command,
                                                 views::View* anchor) {
  if (delegate_) {
    delegate_->OnSinglePaneToolbarCommand(command, anchor);
    return;
  }
  switch (command) {
    case PaneCommand::kBack:
      Send(OpenIntent::Of(OpenIntentKind::kGoBack));
      break;
    case PaneCommand::kForward:
      Send(OpenIntent::Of(OpenIntentKind::kGoForward));
      break;
    case PaneCommand::kReload:
      Send(OpenIntent::Of(OpenIntentKind::kReload));
      break;
    case PaneCommand::kStop:
      Send(OpenIntent::Of(OpenIntentKind::kStopLoading));
      break;
    case PaneCommand::kCopyUrl:
      Send(OpenIntent::Of(OpenIntentKind::kCopyCurrentUrl));
      break;
    case PaneCommand::kSiteControl: {
      OpenIntent intent = OpenIntent::Of(OpenIntentKind::kShowSiteControls);
      if (anchor) {
        intent.anchor_in_screen = anchor->GetBoundsInScreen();
      }
      Send(intent);
      break;
    }
    default:
      break;
  }
}

void OpenBrowserView::OnSinglePaneHostClicked(views::View* anchor) {
  if (delegate_) {
    delegate_->OnSinglePaneHostClicked(anchor);
    return;
  }
  Send(OpenIntent::CommandBar(
      CommandBarSource::kUrlField,
      anchor ? std::optional<gfx::Rect>(anchor->GetBoundsInScreen())
             : std::nullopt));
}

bool OpenBrowserView::HasActiveTab() const {
  return controller_->GetActiveTab(window_id_) != nullptr;
}

void OpenBrowserView::UpdatePanelChildren() {
  const bool split = split_view_active_ && split_container_;
  // An empty Space (no active tab) shows the empty-panel canvas: white 10 %
  // over the theme (window-states.png), never Chromium's blank page or NTP.
  const bool has_tab = HasActiveTab();
  bool changed = false;
  auto set_visible = [&changed](views::View* view, bool visible) {
    if (view && view->GetVisible() != visible) {
      view->SetVisible(visible);
      changed = true;
    }
  };
  set_visible(split_container_, split);
  set_visible(web_contents_host_, !split && has_tab);
  set_visible(browser_contents_container_, !split && has_tab);
  // In Split View each split pane renders its own shadow, so hide the outer
  // single-panel shadow and unmask panel_host_ so pane shadows never clip.
  panel_shadow_->SetVisible(!tab_fullscreen_applied_ && !split);
  panel_host_->SetSplitActive(split);
  if (panel_host_->layer()) {
    panel_host_->layer()->SetMasksToBounds(!split);
  }
  if (changed) {
    panel_host_->InvalidateLayout();
    panel_host_->SchedulePaint();
  }
}

views::View* OpenBrowserView::SetOverlay(OverlaySlot slot,
                                         std::unique_ptr<views::View> view) {
  views::View* host = overlay_host_ ? overlay_host_.get() : this;
  if (auto it = overlays_.find(slot); it != overlays_.end()) {
    views::View* old = it->second;
    overlays_.erase(it);
    if (old->parent()) {
      old->parent()->RemoveChildViewT(old);
    }
  }
  if (!view) {
    return nullptr;
  }
  views::View* added = host->AddChildView(std::move(view));
  overlays_[slot] = added;
  // Z order: Find/Toasts < Peek < Command Bar < WindowRim, all above the card.
  for (OverlaySlot s : {OverlaySlot::kFindBarAndToasts, OverlaySlot::kPeek,
                        OverlaySlot::kCommandBar}) {
    if (auto it = overlays_.find(s); it != overlays_.end()) {
      host->ReorderChildView(it->second, host->children().size());
    }
  }
  if (window_rim_ && window_rim_->parent() == host) {
    host->ReorderChildView(window_rim_.get(), host->children().size());
  }
  LayoutOverlays();
  return added;
}

views::View* OpenBrowserView::GetOverlay(OverlaySlot slot) const {
  auto it = overlays_.find(slot);
  return it == overlays_.end() ? nullptr : it->second.get();
}

views::View* OpenBrowserView::GetUrlPillView() const {
  return sidebar_->url_pill();
}

gfx::Rect OpenBrowserView::UrlPillScreenBounds() const {
  views::View* pill = GetUrlPillView();
  return (pill && pill->IsDrawn()) ? pill->GetBoundsInScreen() : gfx::Rect();
}

views::View* OpenBrowserView::GetSiteControlAnchorView() const {
  return sidebar_->site_control_button();
}

gfx::Rect OpenBrowserView::GetPanelBounds() const {
  return panel_host_->bounds();
}

gfx::Rect OpenBrowserView::GetSidebarBounds() const {
  if (sidebar_->parent() == reveal_card_.get()) {
    return reveal_card_->bounds();
  }
  return sidebar_->bounds();
}

// --- Sidebar mode and width ---------------------------------------------------------

void OpenBrowserView::RequestToggleSidebar() {
  Send(OpenIntent::Of(OpenIntentKind::kToggleSidebar));
}

double OpenBrowserView::HiddenSidebarOffset() const {
  return sidebar_on_right_ ? sidebar_width_ : -sidebar_width_;
}

double OpenBrowserView::HiddenCardOffset() const {
  const double distance = sidebar_width_ + m::window::kRevealCardInset * 2;
  return sidebar_on_right_ ? distance : -distance;
}

void OpenBrowserView::SetSidebarHidden(bool hidden, bool animate) {
  if (hidden == sidebar_hidden_) {
    return;
  }
  sidebar_hidden_ = hidden;
  if (animate && AnimationsEnabled() && !motion::PrefersReducedMotion()) {
    AnimateSidebar(hidden);
  } else {
    sidebar_slide_->JumpTo(hidden ? HiddenSidebarOffset() : 0);
    OnSidebarSlideSettled();
  }
}

void OpenBrowserView::SetSidebarOnRight(bool on_right) {
  if (sidebar_on_right_ == on_right) {
    return;
  }
  if (sliding_) {
    sidebar_slide_->Stop();
    EndPanelSlide();
    sliding_ = false;
  } else if (sidebar_slide_) {
    sidebar_slide_->Stop();
  }
  reveal_dwell_timer_.Stop();
  reveal_exit_timer_.Stop();
  reveal_suppressed_by_velocity_ = false;
  prev_reveal_point_.reset();
  prev_reveal_time_ = base::TimeTicks();
  if (card_state_ != CardState::kOff) {
    if (card_motion_) {
      card_motion_->Stop();
    }
    card_state_ = CardState::kOff;
    if (reveal_card_) {
      reveal_card_->SetVisible(false);
      if (reveal_card_->layer()) {
        reveal_card_->layer()->SetTransform(gfx::Transform());
      }
    }
    if (card_shadow_) {
      card_shadow_->SetVisible(false);
      if (card_shadow_->layer()) {
        card_shadow_->layer()->SetTransform(gfx::Transform());
      }
    }
    if (sidebar_ && reveal_card_ && sidebar_->parent() == reveal_card_.get()) {
      ReparentSidebar(false);
    }
  }
  sidebar_on_right_ = on_right;
  sidebar_offset_ = sidebar_hidden_ ? HiddenSidebarOffset() : 0.0;
  if (sidebar_) {
    sidebar_->SetOnRight(on_right);
    if (sidebar_->parent() == this) {
      if (sidebar_->layer()) {
        sidebar_->layer()->SetTransform(gfx::Transform());
      }
      sidebar_->SetVisible(!sidebar_hidden_);
    }
  }
  if (sidebar_hidden_ && !tab_fullscreen_applied_) {
    StartRevealMonitor();
  }
  InvalidateLayout();
  if (!bounds().IsEmpty()) {
    DeprecatedLayoutImmediately();
  }
  SchedulePaint();
  NotifyTrafficLights();
}

void OpenBrowserView::SetShowFullUrl(bool full_url) {
  if (show_full_url_ == full_url) {
    return;
  }
  show_full_url_ = full_url;
  if (sidebar_) {
    sidebar_->SetShowFullUrl(full_url);
  }
  if (auto* split = views::AsViewClass<OpenSplitContainerView>(
          split_container_.get())) {
    split->SetShowFullUrl(full_url);
  }
  SyncSinglePaneToolbarFromActiveTab();
}

bool OpenBrowserView::IsRevealCardShown() const {
  return card_state_ == CardState::kShown || card_state_ == CardState::kShowing;
}

void OpenBrowserView::SyncFromWindowState(bool animate) {
  const BrowserWindowState* state = controller_->GetWindowState(window_id_);
  if (!state || resizing_) {
    return;
  }
  const float width =
      m::window::ClampSidebarWidth(static_cast<float>(state->sidebar_width));
  if (width != sidebar_width_ && !sliding_) {
    SetLiveSidebarWidth(width);
  }
  SetSidebarHidden(state->sidebar_mode == SidebarMode::kHidden, animate);
}

bool OpenBrowserView::HasCaptionStrip() const {
  if (tab_fullscreen_applied_) {
    return false;
  }
  if (window_controls_ != WindowControls::kWindowsFluent &&
      window_controls_ != WindowControls::kLinuxCsd) {
    return false;
  }
  if (const views::Widget* widget = GetWidget();
      widget && widget->IsFullscreen()) {
    return false;
  }
  return true;
}

void OpenBrowserView::RebuildWindowControls() {
  if (window_controls_view_) {
    views::View* doomed = window_controls_view_.ExtractAsDangling();
    RemoveChildViewT(doomed);
  }
  if (leading_window_controls_view_) {
    views::View* doomed = leading_window_controls_view_.ExtractAsDangling();
    RemoveChildViewT(doomed);
  }
  // Keep caption controls above theme_background_/resize_handle_ and below
  // split_drop_overlay_/card_shadow_/reveal_card_ (and overlay_host_).
  size_t insert_index = children().size();
  if (split_drop_overlay_ && split_drop_overlay_->parent() == this) {
    insert_index = GetIndexOf(split_drop_overlay_.get()).value_or(insert_index);
  } else if (card_shadow_ && card_shadow_->parent() == this) {
    insert_index = GetIndexOf(card_shadow_.get()).value_or(insert_index);
  } else if (reveal_card_ && reveal_card_->parent() == this) {
    insert_index = GetIndexOf(reveal_card_.get()).value_or(insert_index);
  }

  if (window_controls_ == WindowControls::kWindowsFluent) {
    window_controls_view_ = AddChildViewAt(
        std::make_unique<OpenWindowControlsView>(
            OpenWindowControlsView::Mode::kWindowsFluent),
        insert_index);
  } else if (window_controls_ == WindowControls::kLinuxCsd) {
    LinuxWindowButtons buttons;
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      buttons = platform->GetLinuxWindowButtons();
    } else {
      buttons.trailing = {WindowControlButton::kMinimize,
                          WindowControlButton::kMaximize,
                          WindowControlButton::kClose};
    }
    if (!buttons.leading.empty()) {
      leading_window_controls_view_ = AddChildViewAt(
          std::make_unique<OpenWindowControlsView>(
              OpenWindowControlsView::Mode::kLinuxCsd, buttons.leading),
          insert_index++);
    }
    if (!buttons.trailing.empty()) {
      window_controls_view_ = AddChildViewAt(
          std::make_unique<OpenWindowControlsView>(
              OpenWindowControlsView::Mode::kLinuxCsd, buttons.trailing),
          insert_index);
    }
  }
  SyncWindowControlsState();
  InvalidateLayout();
}

void OpenBrowserView::SyncWindowControlsState() {
  const OpenSpaceThemeState& state = FocusedThemeState();
  const bool dark_content =
      state.roles.content == theme::ContentAppearance::kDark;
  const bool ic = controller_->IsIncreaseContrastEnabled();
  const bool maximized = GetWidget() && GetWidget()->IsMaximized();

  if (panel_host_) {
    panel_host_->SetDarkContent(dark_content);
  }
  if (auto* split = views::AsViewClass<OpenSplitContainerView>(
          split_container_.get())) {
    split->SetDarkContent(dark_content);
  }
  if (window_controls_view_) {
    window_controls_view_->SetThemeState(dark_content, window_active_, ic);
    window_controls_view_->SetMaximized(maximized);
  }
  if (leading_window_controls_view_) {
    leading_window_controls_view_->SetThemeState(dark_content, window_active_,
                                                 ic);
    leading_window_controls_view_->SetMaximized(maximized);
  }
  if (hidden_sidebar_toggle_) {
    hidden_sidebar_toggle_->SetThemeState(dark_content, window_active_, ic);
  }
  if (window_rim_) {
    window_rim_->SetDarkContent(dark_content);
  }
}

gfx::Rect OpenBrowserView::PanelBoundsFor(bool hidden, float width) const {
  float top_inset = m::panel::kInset;
  if (tab_fullscreen_applied_) {
    top_inset = 0.0f;
  } else if (HasCaptionStrip()) {
    top_inset = static_cast<float>(m::win_controls::kStripHeight);
  } else if (sidebar_on_right_ &&
             window_controls_ == WindowControls::kNativeMac &&
             !(GetWidget() && GetWidget()->IsFullscreen())) {
    top_inset = m::chrome::kTrafficLightStripHeight;
  }
  const m::Frame f = m::panel::PanelFrame(
      {static_cast<float>(this->width()), static_cast<float>(height())}, width,
      hidden, top_inset, sidebar_on_right_);
  return gfx::ToEnclosingRect(gfx::RectF(f.x, f.y, std::max(0.0f, f.w),
                                         std::max(0.0f, f.h)));
}

void OpenBrowserView::BeginPanelSlide(const gfx::Size& stable_content_size) {
  if (views::NativeViewHost* holder = ActiveWebHolder()) {
    holder->SetNativeViewSize(stable_content_size);
  }
  if (split_slide_client_) {
    split_slide_client_->OnPanelSlideBegin(stable_content_size);
  }
}

void OpenBrowserView::EndPanelSlide() {
  if (views::NativeViewHost* holder = ActiveWebHolder()) {
    holder->SetNativeViewSize(gfx::Size());
  }
  if (split_slide_client_) {
    split_slide_client_->OnPanelSlideEnd();
  }
}

void OpenBrowserView::ReparentSidebar(bool into_card) {
  views::View* target_parent =
      into_card ? static_cast<views::View*>(reveal_card_.get()) : this;
  if (sidebar_->parent() == target_parent) {
    return;
  }
  std::unique_ptr<OpenSidebarView> owned =
      sidebar_->parent()->RemoveChildViewT(sidebar_.get());
  if (into_card) {
    sidebar_ = reveal_card_->AddChildView(std::move(owned));
    sidebar_->layer()->SetTransform(gfx::Transform());
    sidebar_->SetPresentation(OpenSidebarView::Presentation::kFloatingCard);
  } else {
    // Anchored: just above the panel, below the resize handle.
    sidebar_ = AddChildViewAt(std::move(owned), GetIndexOf(resize_handle_).value());
    sidebar_->SetPresentation(OpenSidebarView::Presentation::kAnchored);
  }
  sidebar_->SetVisible(true);
  InvalidateLayout();
}

void OpenBrowserView::AnimateSidebar(bool hidden) {
  // Cmd+S while the card shows anchors the sidebar again.
  if (!hidden && sidebar_->parent() == reveal_card_.get()) {
    card_motion_->Stop();
    card_state_ = CardState::kOff;
    reveal_card_->SetVisible(false);
    card_shadow_->SetVisible(false);
    ReparentSidebar(false);
  }
  StopRevealMonitor();
  const gfx::Rect shown = PanelBoundsFor(false, sidebar_width_);
  const gfx::Rect hidden_panel = PanelBoundsFor(true, sidebar_width_);
  sliding_ = true;
  resize_handle_->SetVisible(false);
  sidebar_->SetVisible(true);
  // Web content keeps the wider size during the slide; only the clip moves.
  BeginPanelSlide(gfx::Size(std::max(shown.width(), hidden_panel.width()),
                            shown.height()));
  sidebar_slide_->SetCompositor(AnimationCompositor());
  if (!hidden) {
    sidebar_slide_->AnimateTimed(sidebar_offset_, 0,
                                 motion::Seconds(motion::kSidebarShowDuration),
                                 motion::kSidebarShowCurve);
  } else {
    sidebar_slide_->SetSpring(motion::kSidebarToggle);
    sidebar_slide_->AnimateFromTo(
        sidebar_offset_, HiddenSidebarOffset(),
        sidebar_slide_->is_animating() ? sidebar_slide_->velocity() : 0.0);
  }
}

void OpenBrowserView::ApplySidebarOffset(double offset) {
  sidebar_offset_ = offset;
  if (sidebar_->parent() == this) {
    sidebar_->layer()->SetTransform(
        gfx::Transform::MakeTranslation(static_cast<float>(offset), 0));
  }
  const double signed_ratio =
      sidebar_width_ > 0
          ? (sidebar_on_right_ ? -offset / sidebar_width_
                               : offset / sidebar_width_)
          : 0.0;
  const double shown_fraction =
      sidebar_width_ > 0 ? std::clamp(1.0 + signed_ratio, 0.0, 1.0) : 1.0;
  ApplyPanelSlide(shown_fraction);
  NotifyTrafficLights();
}

void OpenBrowserView::ApplyPanelSlide(double shown_fraction) {
  LayoutPanel(Lerp(PanelBoundsFor(true, sidebar_width_),
                   PanelBoundsFor(false, sidebar_width_), shown_fraction));
  // The Find bar and toasts follow the panel on every slide frame.
  LayoutOverlays();
}

void OpenBrowserView::OnSidebarSlideSettled() {
  if (sliding_) {
    EndPanelSlide();
  }
  sliding_ = false;
  if (sidebar_->parent() == this) {
    sidebar_->SetVisible(!sidebar_hidden_);
  }
  if (sidebar_hidden_) {
    StartRevealMonitor();
  } else {
    StopRevealMonitor();
  }
  InvalidateLayout();
  NotifyTrafficLights();
}

void OpenBrowserView::SetLiveSidebarWidth(float width) {
  width = m::window::ClampSidebarWidth(width);
  if (width == sidebar_width_) {
    return;
  }
  sidebar_width_ = width;
  if (sidebar_hidden_ && !sliding_) {
    sidebar_offset_ = HiddenSidebarOffset();
  }
  InvalidateLayout();
}

void OpenBrowserView::OnResizeDrag(float proposed_width, bool released) {
  // Hide while pressed below the drag-hide point; the pre-drag width is kept.
  const bool below = proposed_width < m::window::kSidebarDragHidePoint;
  if (below && !hidden_by_drag_) {
    hidden_by_drag_ = true;
    SetSidebarHidden(true, /*animate=*/true);
  } else if (!below) {
    if (hidden_by_drag_) {
      hidden_by_drag_ = false;
      SetSidebarHidden(false, /*animate=*/true);
    }
    SetLiveSidebarWidth(proposed_width);
  }
  if (!released) {
    return;
  }
  resizing_ = false;
  if (hidden_by_drag_) {
    hidden_by_drag_ = false;
    SetLiveSidebarWidth(drag_start_width_);
    Send(OpenIntent::Of(OpenIntentKind::kSidebarHiddenByGesture));
    return;
  }
  OpenIntent intent = OpenIntent::Of(OpenIntentKind::kSetSidebarWidth);
  intent.value = sidebar_width_;
  Send(intent);
}

void OpenBrowserView::OnResizeDoubleClick() {
  resizing_ = false;
  SetLiveSidebarWidth(m::window::kDefaultSidebarWidth);
  OpenIntent intent = OpenIntent::Of(OpenIntentKind::kSetSidebarWidth);
  intent.value = m::window::kDefaultSidebarWidth;
  Send(intent);
}

// --- Hover-reveal card -----------------------------------------------------------

void OpenBrowserView::StartRevealMonitor() {
  if (reveal_monitor_ || !GetWidget()) {
    return;
  }
  reveal_monitor_ = views::EventMonitor::CreateWindowMonitor(
      reveal_observer_.get(), GetWidget()->GetNativeWindow(),
      {ui::EventType::kMouseMoved, ui::EventType::kMouseDragged,
       ui::EventType::kMouseEntered, ui::EventType::kMouseExited});
}

void OpenBrowserView::StopRevealMonitor() {
  reveal_monitor_.reset();
  reveal_dwell_timer_.Stop();
  reveal_exit_timer_.Stop();
  last_reveal_point_.reset();
  prev_reveal_point_.reset();
  prev_reveal_time_ = base::TimeTicks();
  reveal_suppressed_by_velocity_ = false;
}

void OpenBrowserView::IncrementRevealHoldLock() {
  ++reveal_hold_locks_;
  reveal_exit_timer_.Stop();
}

void OpenBrowserView::DecrementRevealHoldLock() {
  reveal_hold_locks_ = std::max(0, reveal_hold_locks_ - 1);
  if (reveal_hold_locks_ == 0 && IsRevealCardShown() && !IsRevealHoldLocked() &&
      last_reveal_point_ && !PointInHoldZone(*last_reveal_point_) &&
      !reveal_exit_timer_.IsRunning()) {
    reveal_exit_timer_.Start(FROM_HERE, motion::Seconds(m::reveal::kExitDelay),
                             base::BindOnce(&OpenBrowserView::HideRevealCard,
                                            base::Unretained(this)));
  }
}

bool OpenBrowserView::IsRevealHoldLocked() const {
  if (reveal_hold_locks_ > 0) {
    return true;
  }
  const views::Widget* widget = GetWidget();
  if (widget && widget->GetNativeView()) {
    for (views::Widget* owned :
         views::Widget::GetAllOwnedWidgets(widget->GetNativeView())) {
      if (owned && owned != widget && owned->IsVisible() &&
          owned->widget_delegate() &&
          owned->widget_delegate()->AsBubbleDialogDelegate() != nullptr) {
        return true;
      }
    }
  }
  return false;
}

void OpenBrowserView::ReleaseMenuRevealLock() {
  if (menu_holding_reveal_lock_) {
    menu_holding_reveal_lock_ = false;
    DecrementRevealHoldLock();
  }
}

gfx::Rect OpenBrowserView::RevealCardBounds() const {
#if !BUILDFLAG(IS_MAC)
  if (HasCaptionStrip()) {
    const int inset = static_cast<int>(m::window::kRevealCardInset);
    const int w = static_cast<int>(std::lround(sidebar_width_));
    if (sidebar_on_right_) {
      // On Win/Linux right-sidebar mode, start below the 32 DIP caption strip
      // so the floating card never covers the - [] x window buttons.
      const int y = m::win_controls::kStripHeight;
      return gfx::Rect(std::max(0, width() - w - inset), y, w,
                       std::max(0, height() - y - inset));
    }
    // Align RevealCardView at y = 0 on Win/Linux so its internal sidebar
    // toolbar at y = 2 lines up vertically with HiddenSidebarToggleButton
    // (y = 2) and OpenWindowControlsView (y = 0..32).
    return gfx::Rect(inset, 0, w, std::max(0, height() - inset));
  }
#endif
  const m::Frame f = m::window::RevealCardFrame(
      {static_cast<float>(width()), static_cast<float>(height())},
      sidebar_width_, sidebar_on_right_);
  return gfx::ToEnclosingRect(gfx::RectF(f.x, f.y, f.w, f.h));
}

bool OpenBrowserView::PointInRevealZone(const gfx::Point& p) const {
#if !BUILDFLAG(IS_MAC)
  // Exclude HiddenSidebarToggleButton and the 32 DIP caption strip so hovering
  // the explicit toggle button or window controls never collides with
  // hover-reveal.
  if (hidden_sidebar_toggle_ && hidden_sidebar_toggle_->GetVisible() &&
      hidden_sidebar_toggle_->bounds().Contains(p)) {
    return false;
  }
  if (HasCaptionStrip()) {
    if (sidebar_on_right_) {
      return p.x() >= width() - m::reveal::kInnerEdgeWidth &&
             p.x() <= width() && p.y() >= m::win_controls::kStripHeight &&
             p.y() < height();
    }
    return p.x() >= 0 && p.x() < m::reveal::kInnerEdgeWidth &&
           p.y() >= m::win_controls::kStripHeight && p.y() < height();
  }
#endif
  if (sidebar_on_right_) {
    const bool inner = p.x() >= width() - m::reveal::kInnerEdgeWidth &&
                       p.x() <= width() && p.y() >= 0 && p.y() < height();
    const bool top_right = p.x() >= width() - m::reveal::kTopLeftWidth &&
                           p.x() <= width() &&
                           p.y() >= m::reveal::kTopLeftMin &&
                           p.y() < m::reveal::kTopLeftMax;
    return inner || top_right;
  }
  // Inner left edge (0 .. 0.6 u) and the top-left corner.
  const bool inner = p.x() >= 0 && p.x() < m::reveal::kInnerEdgeWidth &&
                     p.y() >= 0 && p.y() < height();
  const bool top_left = p.x() >= 0 && p.x() < m::reveal::kTopLeftWidth &&
                        p.y() >= m::reveal::kTopLeftMin &&
                        p.y() < m::reveal::kTopLeftMax;
  return inner || top_left;
}

bool OpenBrowserView::PointInHoldZone(const gfx::Point& p) const {
  gfx::Rect card_hold = RevealCardBounds();
  if (sidebar_on_right_) {
    const int margin = static_cast<int>(m::reveal::kHoldRightMargin);
    const int inset = static_cast<int>(m::window::kRevealCardInset);
    card_hold.Inset(gfx::Insets::TLBR(0, -margin, 0, -inset));
    if (card_hold.Contains(p)) {
      return true;
    }
    return p.x() >= width() - m::reveal::kInnerEdgeHeldMax &&
           p.x() <= width() - m::reveal::kInnerEdgeHeldMin;
  }
  card_hold.set_width(card_hold.width() +
                      static_cast<int>(m::reveal::kHoldRightMargin));
  if (card_hold.Contains(p)) {
    return true;
  }
  const bool inner_held = p.x() >= m::reveal::kInnerEdgeHeldMin &&
                          p.x() < m::reveal::kInnerEdgeHeldMax;
#if BUILDFLAG(IS_MAC)
  const bool top_hold =
      p.x() < m::chrome::kSidebarToggleX + m::window::kRevealCardInset &&
      p.y() < m::reveal::kTrafficLightRegionHeight;
#else
  const bool top_hold =
      p.x() >= 0 && p.x() < 56 && p.y() >= 0 &&
      p.y() < m::win_controls::kStripHeight;
#endif
  return inner_held || top_hold;
}

void OpenBrowserView::OnRevealEvent(const ui::Event& event) {
  if (!sidebar_hidden_ || sliding_ || !reveal_monitor_ ||
      tab_fullscreen_applied_) {
    return;
  }
  if (event.type() == ui::EventType::kMouseExited) {
    // Leaving through the sidebar's outer edge stays in the held zone.
    const bool outer_edge =
        last_reveal_point_ &&
        (sidebar_on_right_
             ? last_reveal_point_->x() >= width() - m::reveal::kInnerEdgeHeldMax
             : last_reveal_point_->x() < m::reveal::kInnerEdgeHeldMax);
    if (IsRevealCardShown() && !outer_edge && !IsRevealHoldLocked() &&
        !reveal_exit_timer_.IsRunning()) {
      reveal_exit_timer_.Start(FROM_HERE, motion::Seconds(m::reveal::kExitDelay),
                               base::BindOnce(&OpenBrowserView::HideRevealCard,
                                              base::Unretained(this)));
    }
    reveal_dwell_timer_.Stop();
    prev_reveal_point_.reset();
    prev_reveal_time_ = base::TimeTicks();
    reveal_suppressed_by_velocity_ = false;
    return;
  }
  gfx::Point p = reveal_monitor_->GetLastMouseLocation();
  views::View::ConvertPointFromScreen(this, &p);
  const base::TimeTicks now = event.time_stamp().is_null()
                                  ? base::TimeTicks::Now()
                                  : event.time_stamp();
  const bool in_reveal = PointInRevealZone(p);
  if (prev_reveal_point_ && !prev_reveal_time_.is_null()) {
    const double dt = (now - prev_reveal_time_).InSecondsF();
    if (dt > 0.0005) {
      const double dx = static_cast<double>(p.x() - prev_reveal_point_->x());
      const double dy = static_cast<double>(p.y() - prev_reveal_point_->y());
      const double vx = dx / dt;
      const double speed = std::hypot(dx, dy) / dt;
      const bool pass_through =
          sidebar_on_right_ ? (vx > m::reveal::kPassThroughVelocity)
                            : (vx < -m::reveal::kPassThroughVelocity);
      if (in_reveal && pass_through) {
        reveal_suppressed_by_velocity_ = true;
        reveal_dwell_timer_.Stop();
      } else if (reveal_suppressed_by_velocity_ && speed < 400.0) {
        reveal_suppressed_by_velocity_ = false;
      }
    }
  }
  prev_reveal_point_ = p;
  prev_reveal_time_ = now;
  if (!in_reveal) {
    reveal_suppressed_by_velocity_ = false;
  }
  last_reveal_point_ = p;
  if (card_state_ == CardState::kOff || card_state_ == CardState::kHiding) {
    if (in_reveal) {
      if (!reveal_suppressed_by_velocity_ && !reveal_dwell_timer_.IsRunning()) {
        reveal_dwell_timer_.Start(
            FROM_HERE, motion::Seconds(m::reveal::kDwell),
            base::BindOnce(
                [](OpenBrowserView* self) {
                  if (self->last_reveal_point_ &&
                      !self->reveal_suppressed_by_velocity_ &&
                      (self->PointInRevealZone(*self->last_reveal_point_) ||
                       self->PointInHoldZone(*self->last_reveal_point_))) {
                    self->ShowRevealCard();
                  }
                },
                base::Unretained(this)));
      }
    } else if (!(card_state_ == CardState::kHiding && PointInHoldZone(p))) {
      reveal_dwell_timer_.Stop();
    }
    return;
  }
  if (PointInHoldZone(p) || IsRevealHoldLocked()) {
    reveal_exit_timer_.Stop();
  } else if (!reveal_exit_timer_.IsRunning()) {
    reveal_exit_timer_.Start(FROM_HERE, motion::Seconds(m::reveal::kExitDelay),
                             base::BindOnce(&OpenBrowserView::HideRevealCard,
                                            base::Unretained(this)));
  }
}

void OpenBrowserView::ShowRevealCard() {
  if (!sidebar_hidden_ || tab_fullscreen_applied_ ||
      card_state_ == CardState::kShown || card_state_ == CardState::kShowing) {
    return;
  }
  // Hit testing over the page: the card lives in the overlay host above
  // BrowserView's contents container. On macOS, BridgedContentView's
  // -hitTest: asks Views (NativeWidgetMacNSWindowHost::GetHitTestResult);
  // only a NativeViewHost target sends the click to the WebContents NSView,
  // so the card's views take every click over the page. A child widget is
  // not needed (and would lose the card's page blur).
  ReparentSidebar(true);
  reveal_card_->SetStyle(FocusedThemeState().style);
  reveal_card_->SetWindowSize(size());
  reveal_card_->SetVisible(true);
  card_shadow_->SetVisible(true);
  card_state_ = CardState::kShowing;
  InvalidateLayout();
  const double from = card_motion_->is_animating()
                          ? card_motion_->value()
                          : HiddenCardOffset();
  card_motion_->SetSpring(motion::kRevealCardIn);
  card_motion_->SetCompositor(AnimationCompositor());
  card_motion_->AnimateFromTo(from, 0,
                              card_motion_->is_animating() ? card_motion_->velocity()
                                                           : 0.0);
}

void OpenBrowserView::HideRevealCard() {
  if (card_state_ == CardState::kOff || card_state_ == CardState::kHiding ||
      IsRevealHoldLocked()) {
    return;
  }
  card_state_ = CardState::kHiding;
  card_motion_->SetCompositor(AnimationCompositor());
  card_motion_->AnimateTimed(card_motion_->value(),
                             HiddenCardOffset(),
                             motion::Seconds(motion::kRevealCardOut),
                             motion::CubicCurve{0, 0, 1, 1});
}

void OpenBrowserView::ApplyCardOffset(double offset) {
  const gfx::Transform t =
      gfx::Transform::MakeTranslation(static_cast<float>(offset), 0);
  reveal_card_->layer()->SetTransform(t);
  card_shadow_->layer()->SetTransform(t);
  NotifyTrafficLights();
}

void OpenBrowserView::OnCardMotionSettled() {
  if (card_state_ == CardState::kShowing) {
    card_state_ = CardState::kShown;
  } else if (card_state_ == CardState::kHiding) {
    card_state_ = CardState::kOff;
    reveal_card_->SetVisible(false);
    card_shadow_->SetVisible(false);
  }
  NotifyTrafficLights();
}

void OpenBrowserView::NotifyTrafficLights() {
  // Offset of the group from Arc's resting centers (x 20 / 43 / 66, y 24).
  gfx::Vector2d offset;
  bool visible = !sidebar_hidden_ || sliding_;
  if (sidebar_on_right_) {
    // Right-side sidebar: macOS traffic lights stay anchored in the top-left
    // strip above the web panel and never ride on the right sidebar or card.
    visible = true;
    offset = gfx::Vector2d();
  } else if (sidebar_->parent() == reveal_card_.get()) {
    // The lights ride on the card, 5 pt further in: AX close [17, 21].
    visible = card_state_ != CardState::kOff;
    offset = gfx::Vector2d(
        reveal_card_->x() + static_cast<int>(std::lround(card_motion_->value())),
        reveal_card_->y());
  } else {
    offset = gfx::Vector2d(static_cast<int>(std::lround(sidebar_offset_)), 0);
  }
  // A fullscreen page hides them (native full screen is AppKit's).
  if (tab_fullscreen_applied_) {
    visible = false;
  }
#if BUILDFLAG(IS_MAC)
  if (window_controls_ == WindowControls::kNativeMac && GetWidget()) {
    if (OpenPlatform* platform = OpenPlatform::Get()) {
      // Arc's DimmedWindowControls: grey at rest, lit under the pointer.
      platform->PlaceWindowButtons(GetWidget(),
                                   gfx::Point() + offset, visible,
                                   /*dimmed=*/true);
    }
  }
#endif
  if (!traffic_lights_callback_) {
    return;
  }
  const m::Frame close = m::chrome::kTrafficLightFrames[0];
  gfx::Point origin(static_cast<int>(close.x), static_cast<int>(close.y));
  origin += offset;
  traffic_lights_callback_.Run(origin, visible);
}

// --- Theme --------------------------------------------------------------------------

theme::ContentAppearance OpenBrowserView::SystemAppearance() const {
  return ToAppearance(controller_->IsSystemDarkMode());
}

OpenSpaceThemeState OpenBrowserView::MakeThemeState(
    const SpaceID& space_id) const {
  const theme::ContentAppearance system = SystemAppearance();
  OpenSpaceThemeState state;
  if (controller_->IsIncognitoWindow(window_id_)) {
    state.style = theme::ThemeStyle::Incognito();
  } else if (const Space* space = controller_->GetSpace(space_id)) {
    state.style = theme::ThemeStyle::FromSpaceTheme(space->theme, system);
  } else {
    state.style = theme::ThemeStyle::Default(system);
  }
  const bool ic = controller_->IsIncreaseContrastEnabled();
  state.appearance = ic ? state.style.IncreasedContrastAppearance(system)
                        : state.style.ResolvedAppearance(system);
  state.roles = theme::RolesFor(state.style, state.appearance, ic);
  state.contrast_accent = state.style.ContrastAccent(state.appearance);
  state.accent = state.style.AccentColor(state.appearance);
  return state;
}

const OpenSpaceThemeState& OpenBrowserView::ThemeStateFor(
    const SpaceID& space_id) {
  auto it = theme_cache_.find(space_id);
  if (it == theme_cache_.end()) {
    it = theme_cache_.emplace(space_id, MakeThemeState(space_id)).first;
  }
  return it->second;
}

const OpenSpaceThemeState& OpenBrowserView::FocusedThemeState() {
  return ThemeStateFor(FocusedSpaceId());
}

void OpenBrowserView::InvalidateThemeCache() {
  theme_cache_.clear();
  const OpenSpaceThemeState& focused = FocusedThemeState();
  theme_background_->SetStyle(focused.style);
  reveal_card_->SetStyle(focused.style);
  shown_theme_space_ = FocusedSpaceId();
  sidebar_->OnAppearanceChanged();
  SyncWindowControlsState();
  ApplyWebCornerRadii();
  UpdateWindowMaterial();
}

SpaceID OpenBrowserView::FocusedSpaceId() const {
  const BrowserWindowState* state = controller_->GetWindowState(window_id_);
  return state ? state->focused_space_id : SpaceID();
}

bool OpenBrowserView::IsWindowActive() const {
  return window_active_;
}

float OpenBrowserView::SidebarWidth() const {
  return sidebar_width_;
}

void OpenBrowserView::BeginThemeTransition(const SpaceID& to) {
  transition_space_ = to;
  theme_background_->BeginTransition(ThemeStateFor(to).style);
}

void OpenBrowserView::SetThemeTransitionProgress(double progress) {
  theme_background_->SetTransitionProgress(progress);
}

void OpenBrowserView::EndThemeTransition(bool commit) {
  if (theme_background_) {
    theme_background_->EndTransition(commit);
  }
  if (commit && transition_space_) {
    shown_theme_space_ = transition_space_;
    if (reveal_card_) {
      reveal_card_->SetStyle(ThemeStateFor(*transition_space_).style);
    }
  }
  transition_space_.reset();
  SyncWindowControlsState();
  UpdateWindowMaterial();
}

void OpenBrowserView::CrossfadeTheme(const SpaceID& to, bool animated) {
  const theme::ThemeStyle& style = ThemeStateFor(to).style;
  if (theme_background_) {
    if (animated && AnimationsEnabled()) {
      theme_background_->Crossfade(style);
    } else {
      theme_background_->SetStyle(style);
    }
  }
  if (reveal_card_) {
    reveal_card_->SetStyle(style);
  }
  shown_theme_space_ = to;
  SyncWindowControlsState();
  UpdateWindowMaterial();
}

ui::Compositor* OpenBrowserView::AnimationCompositor() {
  views::Widget* widget = GetWidget();
  return widget ? widget->GetCompositor() : nullptr;
}

bool OpenBrowserView::AnimationsEnabled() const {
  const views::Widget* widget = GetWidget();
  return widget && widget_visible_ && !widget->IsMinimized();
}

void OpenBrowserView::OnAppMenuRequested(views::View* anchor) {
  if (delegate_) {
    delegate_->OnAppMenuRequested(anchor);
  }
}

void OpenBrowserView::OnExtensionContextMenuRequested(
    const std::string& extension_id,
    views::View* anchor,
    const gfx::Point& screen_pt) {
  if (delegate_) {
    delegate_->OnExtensionContextMenuRequested(extension_id, anchor, screen_pt);
    return;
  }
  OpenMenuTarget target;
  target.kind = OpenMenuTarget::Kind::kToolbarAction;
  target.text = extension_id;
  target.space_id = FocusedSpaceId();
  ShowSidebarMenu(target, anchor, screen_pt, ui::mojom::MenuSourceType::kMouse);
}

void OpenBrowserView::OnSpaceReordered(const std::string& space_id,
                                       size_t to_index) {
  if (delegate_) {
    delegate_->OnSpaceReordered(space_id, to_index);
  }
}

void OpenBrowserView::OnResetPinnedTab(const ItemID& id, bool separate) {
  if (delegate_) {
    delegate_->OnResetPinnedTab(id, separate);
    return;
  }
  if (!separate) {
    Send(OpenIntent::ForNode(OpenIntentKind::kResetToPinnedUrl, id));
  }
}

void OpenBrowserView::OnTabDragStateChanged(bool dragging,
                                            const ItemID& tab_id) {
  SetSplitDropOverlayActive(dragging);
  if (delegate_) {
    delegate_->OnTabDragStateChanged(dragging, tab_id);
  }
}

// --- Intents, menus, favicons ---------------------------------------------------

void OpenBrowserView::Send(const OpenIntent& intent) {
  controller_->HandleIntent(window_id_, intent);
}

void OpenBrowserView::ShowSidebarMenu(const OpenMenuTarget& target,
                                      views::View* source,
                                      const gfx::Point& screen_point,
                                      ui::mojom::MenuSourceType source_type) {
  if (!GetWidget()) {
    return;
  }
  ReleaseMenuRevealLock();
  menu_runner_.reset();
  menu_model_ = controller_->CreateMenuModel(window_id_, target);
  if (!menu_model_ && target.kind == OpenMenuTarget::Kind::kPlusButton) {
    plus_menu_delegate_ =
        std::make_unique<PlusMenuDelegate>(this, target.space_id);
    menu_model_ = plus_menu_delegate_->CreateModel();
  }
  if (!menu_model_) {
    return;
  }
  menu_holding_reveal_lock_ = true;
  IncrementRevealHoldLock();
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(),
      views::MenuRunner::CONTEXT_MENU | views::MenuRunner::HAS_MNEMONICS,
      base::BindRepeating(&OpenBrowserView::ReleaseMenuRevealLock,
                          weak_factory_.GetWeakPtr()));
  menu_runner_->RunMenuAt(GetWidget(), nullptr,
                          gfx::Rect(screen_point, gfx::Size()),
                          views::MenuAnchorPosition::kTopLeft, source_type);
}

gfx::ImageSkia OpenBrowserView::FaviconFor(const Tab& tab) {
  gfx::ImageSkia image = controller_->GetFavicon(tab.id);
  if (!image.isNull()) {
    return image;
  }
  const std::vector<uint8_t>& png = tab.live_state.favicon_png;
  if (png.empty()) {
    return gfx::ImageSkia();
  }
  const size_t png_hash = base::FastHash(png);
  auto it = favicon_cache_.find(tab.id);
  if (it != favicon_cache_.end() && it->second.png_size == png.size() &&
      it->second.png_hash == png_hash) {
    return it->second.image;
  }
  const SkBitmap bitmap = gfx::PNGCodec::Decode(png);
  if (bitmap.drawsNothing()) {
    return gfx::ImageSkia();
  }
  if (favicon_cache_.size() >= kFaviconCacheLimit) {
    favicon_cache_.clear();
  }
  FaviconEntry& entry = favicon_cache_[tab.id];
  entry.png_size = png.size();
  entry.png_hash = png_hash;
  const float scale = bitmap.width() >= 32 ? 2.0f : 1.0f;
  entry.image = gfx::ImageSkia(gfx::ImageSkiaRep(bitmap, scale));
  return entry.image;
}

// --- Frame ----------------------------------------------------------------------------

int OpenBrowserView::NonClientHitTest(const gfx::Point& point) const {
  if (!GetLocalBounds().Contains(point)) {
    return HTNOWHERE;
  }
  // When the hover-reveal sidebar card is open inside overlay_host_, let it
  // handle hits before checking caption controls or HTCAPTION strip areas.
  if (IsRevealCardShown() && reveal_card_ && reveal_card_->GetVisible()) {
    gfx::Point card_pt = point;
    views::View::ConvertPointToTarget(this, reveal_card_.get(), &card_pt);
    if (reveal_card_->GetLocalBounds().Contains(card_pt)) {
      views::View* card_target =
          const_cast<RevealCardView*>(reveal_card_.get())
              ->GetEventHandlerForPoint(card_pt);
      if (card_target && card_target->GetProperty(kOpenWindowDragKey)) {
        return HTCAPTION;
      }
      return HTCLIENT;
    }
  }
  // Check client-side caption controls first so HTMINBUTTON / HTMAXBUTTON /
  // HTCLOSE win immediately (enabling Windows 11 Snap Layouts).
  for (const OpenWindowControlsView* controls :
       {window_controls_view_.get(), leading_window_controls_view_.get()}) {
    if (controls && controls->GetVisible()) {
      gfx::Point local = point;
      views::View::ConvertPointToTarget(this, controls, &local);
      const int code = controls->HitTestCode(local);
      if (code != HTNOWHERE) {
        return code;
      }
    }
  }
#if BUILDFLAG(IS_LINUX)
  // On Linux CSD, this view supplies the inner resize edges (Windows uses
  // native DWM borders via BrowserFrameViewWin; macOS keeps system edges).
  const views::Widget* widget = GetWidget();
  const bool can_resize =
      widget && !widget->IsMaximized() && !widget->IsFullscreen() &&
      (!widget->widget_delegate() || widget->widget_delegate()->CanResize());
  if (WantsFramelessWindow() && can_resize) {
    constexpr int kEdge = 6;
    constexpr int kHiddenLeftEdge = 4;
    constexpr int kCorner = 14;
    const int left_edge =
        (!sidebar_on_right_ && sidebar_hidden_) ? kHiddenLeftEdge : kEdge;
    const int right_edge =
        (sidebar_on_right_ && sidebar_hidden_) ? kHiddenLeftEdge : kEdge;
    const bool left = point.x() < left_edge;
    const bool right = point.x() >= width() - right_edge;
    const bool top = point.y() < kEdge;
    const bool bottom = point.y() >= height() - kEdge;
    const bool near_left = point.x() < kCorner;
    const bool near_right = point.x() >= width() - kCorner;
    const bool near_top = point.y() < kCorner;
    const bool near_bottom = point.y() >= height() - kCorner;
    if ((top && near_left) || (left && near_top)) return HTTOPLEFT;
    if ((top && near_right) || (right && near_top)) return HTTOPRIGHT;
    if ((bottom && near_left) || (left && near_bottom)) return HTBOTTOMLEFT;
    if ((bottom && near_right) || (right && near_bottom)) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
#endif  // BUILDFLAG(IS_LINUX)
  if (HasCaptionStrip() && point.y() < m::win_controls::kStripHeight) {
    if (hidden_sidebar_toggle_ && hidden_sidebar_toggle_->GetVisible() &&
        hidden_sidebar_toggle_->bounds().Contains(point)) {
      return HTCLIENT;
    }
  }
  views::View* target =
      const_cast<OpenBrowserView*>(this)->GetEventHandlerForPoint(point);
  if (!target || target == this) {
    // The top caption strip, 10 pt frame inset, and empty frame area drag the
    // window.
    return HTCAPTION;
  }
  // Empty drag regions (the sidebar's top bar background) are tagged; the
  // controls inside them, every other control, and the web content stay
  // client.
  if (target->GetProperty(kOpenWindowDragKey)) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

void OpenBrowserView::SetWindowControls(WindowControls controls) {
  if (window_controls_ == controls) {
    return;
  }
  window_controls_ = controls;
  sidebar_->SetWindowControlsSlot(
      controls == WindowControls::kNativeMac
          ? OpenSidebarView::WindowControlsSlot::kNativeReserved
          : OpenSidebarView::WindowControlsSlot::kNone);
  RebuildWindowControls();
}

void OpenBrowserView::SetTrafficLightsCallback(TrafficLightsCallback callback) {
  traffic_lights_callback_ = std::move(callback);
  NotifyTrafficLights();
}

void OpenBrowserView::SetClipsWindowCorners(bool clips) {
  if (clips_window_corners_ == clips) {
    return;
  }
  clips_window_corners_ = clips;
  // Never call SetPaintToLayer() dynamically on OpenBrowserView while
  // browser_contents_container_ (NativeViewHostAura) is in the widget tree:
  // clip theme_background_'s pre-existing layer instead and let
  // ApplyWebCornerRadii() clip the web panel.
#if BUILDFLAG(IS_LINUX)
  const float radius = static_cast<float>(m::win_controls::kLinuxCornerRadius);
  if (window_rim_) {
    window_rim_->SetVisible(clips);
  }
#else
  const float radius = m::window::kCornerRadius;
#endif
  if (theme_background_) {
    theme_background_->SetWindowCornerRadius(clips ? radius : 0.0f);
  }
  ApplyWebCornerRadii();
  SchedulePaint();
}

void OpenBrowserView::PaintChildren(const views::PaintInfo& info) {
  views::View::PaintChildren(info);
}

// --- Layout -----------------------------------------------------------------------------

void OpenBrowserView::LayoutPanel(const gfx::Rect& requested) {
  // A fullscreen page fills the window edge to edge.
  const gfx::Rect panel =
      tab_fullscreen_applied_ ? GetLocalBounds() : requested;
  const bool show_toolbar = ShowsSinglePaneToolbar();
  const int toolbar_h =
      show_toolbar ? static_cast<int>(m::content_toolbar::kSinglePaneHeight)
                   : 0;
  if (single_pane_toolbar_) {
    single_pane_toolbar_->SetVisible(show_toolbar);
    if (show_toolbar) {
      single_pane_toolbar_->SetBounds(panel.x(), panel.y(), panel.width(),
                                      toolbar_h);
    }
  }
  const gfx::Rect content_rect(panel.x(), panel.y() + toolbar_h, panel.width(),
                               std::max(0, panel.height() - toolbar_h));
  panel_host_->SetTopCornersSquare(show_toolbar);
  panel_host_->SetBoundsRect(content_rect);
  panel_shadow_->SetContentBounds(panel);
  if (browser_contents_container_) {
    browser_contents_container_->SetBoundsRect(content_rect);
  }
}

void OpenBrowserView::LayoutOverlays() {
  if (overlay_host_) {
    overlay_host_->SetBoundsRect(bounds());
  }
  if (split_drop_overlay_) {
    split_drop_overlay_->SetBoundsRect(panel_host_->bounds());
  }
  if (window_rim_) {
    window_rim_->SetBoundsRect(GetLocalBounds());
  }
  for (const auto& [slot, view] : overlays_) {
    view->SetBoundsRect(slot == OverlaySlot::kFindBarAndToasts
                            ? panel_host_->bounds()
                            : GetLocalBounds());
  }
}

void OpenBrowserView::Layout(PassKey) {
  // Keep any Chromium chrome views (such as vertical tab strip, bookmark bar,
  // or side panels) hidden if Chromium re-shows them after Install().
  if (browser_view_) {
    for (views::View* child : browser_view_->children()) {
      if (child != this && child != browser_contents_container_ &&
          child != overlay_host_ && child->GetVisible()) {
        child->SetVisible(false);
      }
    }
  }
  theme_background_->SetBoundsRect(GetLocalBounds());
  UpdatePanelChildren();
  ApplyTabFullscreen(IsTabFullscreen());
  if (tab_fullscreen_applied_) {
    LayoutPanel(GetLocalBounds());
    if (sidebar_->parent() == this) {
      sidebar_->SetVisible(false);
    }
    resize_handle_->SetVisible(false);
    if (window_controls_view_) {
      window_controls_view_->SetVisible(false);
    }
    if (leading_window_controls_view_) {
      leading_window_controls_view_->SetVisible(false);
    }
    if (hidden_sidebar_toggle_) {
      hidden_sidebar_toggle_->SetVisible(false);
    }
    ApplyWebCornerRadii();
    LayoutOverlays();
    NotifyTrafficLights();
    return;
  }
  const bool show_caption_strip = HasCaptionStrip();
  if (window_controls_view_) {
    window_controls_view_->SetVisible(show_caption_strip);
    if (show_caption_strip) {
      if (window_controls_ == WindowControls::kWindowsFluent) {
        window_controls_view_->SetBounds(
            width() - m::win_controls::kWinClusterW, 0,
            m::win_controls::kWinClusterW, m::win_controls::kStripHeight);
      } else {
        const gfx::Size pref = window_controls_view_->GetPreferredSize();
        window_controls_view_->SetBounds(
            width() - pref.width() - m::win_controls::kLinuxOuterMargin, 2,
            pref.width(), m::win_controls::kLinuxButtonSize);
      }
    }
  }
  int leading_controls_inset = 0;
  if (leading_window_controls_view_) {
    leading_window_controls_view_->SetVisible(show_caption_strip);
    if (show_caption_strip) {
      const gfx::Size pref = leading_window_controls_view_->GetPreferredSize();
      leading_window_controls_view_->SetBounds(
          m::win_controls::kLinuxOuterMargin, 2, pref.width(),
          m::win_controls::kLinuxButtonSize);
      leading_controls_inset = leading_window_controls_view_->bounds().right() + 8;
    }
  }
  sidebar_->SetLeadingControlsInset(sidebar_on_right_ ? 0
                                                      : leading_controls_inset);
  if (hidden_sidebar_toggle_) {
    const bool show_toggle = show_caption_strip && sidebar_hidden_ && !sliding_;
    hidden_sidebar_toggle_->SetVisible(show_toggle);
    if (show_toggle) {
      const int toggle_size = static_cast<int>(m::chrome::kToolbarButtonSize);
      const int toggle_y = static_cast<int>(m::chrome::kToolbarButtonY);
      int toggle_x = leading_controls_inset > 0
                         ? leading_controls_inset
                         : static_cast<int>(m::chrome::kSidebarToggleX);
      if (sidebar_on_right_) {
        const int right_anchor =
            (window_controls_view_ && window_controls_view_->GetVisible())
                ? window_controls_view_->x()
                : width();
        toggle_x = std::max(leading_controls_inset,
                            right_anchor - toggle_size - 8);
      }
      hidden_sidebar_toggle_->SetBounds(toggle_x, toggle_y, toggle_size,
                                        toggle_size);
    }
  }
  const int w = static_cast<int>(std::lround(sidebar_width_));
  if (!sliding_) {
    LayoutPanel(PanelBoundsFor(sidebar_hidden_, sidebar_width_));
  }
  // Left sidebar stays at y = 0 (toolbar harmonized inside the 32 DIP caption
  // strip on Win/Linux). Right sidebar starts below the 32 DIP caption strip
  // on Win/Linux so it never collides with - [] x, and starts at y = 0 full
  // height on macOS where traffic lights live at top-left.
  if (sidebar_->parent() == this) {
    if (sidebar_on_right_) {
      const int sidebar_y =
          show_caption_strip ? m::win_controls::kStripHeight : 0;
      sidebar_->SetBounds(width() - w, sidebar_y, w,
                          std::max(0, height() - sidebar_y));
    } else {
      sidebar_->SetBounds(0, 0, w, height());
    }
    if (!sliding_) {
      sidebar_->layer()->SetTransform(gfx::Transform());
      sidebar_->SetVisible(!sidebar_hidden_);
    }
  }
  const int handle = static_cast<int>(m::window::kResizeHandleWidth);
  const gfx::Rect panel = panel_host_->bounds();
  const int handle_x = sidebar_on_right_ ? (width() - w) : (w - handle);
  resize_handle_->SetBounds(handle_x, panel.y(), handle, panel.height());
  resize_handle_->SetVisible(!sliding_ && (!sidebar_hidden_ || resizing_));
  const gfx::Rect card = RevealCardBounds();
  reveal_card_->SetBoundsRect(card);
  reveal_card_->SetWindowSize(size());
  card_shadow_->SetContentBounds(card);
  if (sidebar_->parent() == reveal_card_.get()) {
    sidebar_->SetBounds(0, 0, card.width(), card.height());
  }
  ApplyWebCornerRadii();
  LayoutOverlays();
  NotifyTrafficLights();
}

void OpenBrowserView::AddedToWidget() {
  views::Widget* widget = GetWidget();
  widget_observation_.Reset();
  widget_observation_.Observe(widget);
  widget_visible_ = widget->IsVisible();
  // The active look follows ShouldPaintAsActive(): it stays active while a
  // child overlay (Command Bar, Find bar, Peek) holds a paint-as-active lock.
  window_active_ = widget->ShouldPaintAsActive();
  paint_as_active_subscription_ =
      widget->RegisterPaintAsActiveChangedCallback(base::BindRepeating(
          &OpenBrowserView::OnPaintAsActiveChanged, base::Unretained(this)));
  theme_background_->SetActive(window_active_);
  reveal_card_->SetActive(window_active_);
  panel_shadow_->SetOpacity(window_active_ ? 1.0f : 0.55f);
  sidebar_slide_->SetCompositor(widget->GetCompositor());
  card_motion_->SetCompositor(widget->GetCompositor());
  SyncFromWindowState(/*animate=*/false);
  if (sidebar_hidden_) {
    StartRevealMonitor();
  }
#if BUILDFLAG(IS_LINUX)
  SetClipsWindowCorners(!widget->IsMaximized() && !widget->IsFullscreen());
#endif
  SyncWindowControlsState();
  UpdateWindowMaterial();
  NotifyTrafficLights();
}

void OpenBrowserView::RemovedFromWidget() {
  paint_as_active_subscription_ = {};
  StopRevealMonitor();
  sidebar_slide_->SetCompositor(nullptr);
  card_motion_->SetCompositor(nullptr);
  widget_observation_.Reset();
}

void OpenBrowserView::OnThemeChanged() {
  views::View::OnThemeChanged();
  typography::InvalidateCache();
  // Native theme changes (e.g. high contrast) can change roles.
  InvalidateThemeCache();
  InvalidateLayout();
  if (delegate_) {
    delegate_->OnSystemThemeChanged();
  }
}

void OpenBrowserView::OnDeviceScaleFactorChanged(
    float old_device_scale_factor,
    float new_device_scale_factor) {
  views::View::OnDeviceScaleFactorChanged(old_device_scale_factor,
                                          new_device_scale_factor);
  typography::InvalidateCache();
  InvalidateLayout();
}

// --- views::WidgetObserver ------------------------------------------------------

void OpenBrowserView::OnWidgetActivationChanged(views::Widget* widget,
                                                bool active) {
  // Raw activation also flips when a child overlay takes key status; the
  // paint-as-active state (which honors the overlay's lock) decides.
  OnPaintAsActiveChanged();
}

void OpenBrowserView::OnWidgetBoundsChanged(views::Widget* widget,
                                            const gfx::Rect& new_bounds) {
  if (!widget || widget != GetWidget()) {
    return;
  }
#if BUILDFLAG(IS_LINUX)
  SetClipsWindowCorners(!widget->IsMaximized() && !widget->IsFullscreen());
#endif
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    platform->SetFullscreenCornerState(
        widget, tab_fullscreen_applied_ || widget->IsFullscreen());
  }
  SyncWindowControlsState();
  InvalidateLayout();
}

void OpenBrowserView::OnPaintAsActiveChanged() {
  const views::Widget* widget = GetWidget();
  if (!widget) {
    return;
  }
  const bool active = widget->ShouldPaintAsActive();
  if (window_active_ == active) {
    return;
  }
  window_active_ = active;
  theme_background_->SetActive(active);
  reveal_card_->SetActive(active);
  panel_shadow_->SetOpacity(active ? 1.0f : 0.55f);
  sidebar_->OnWindowActivationChanged();
  SyncWindowControlsState();
  UpdateWindowMaterial();
}

// --- Tab fullscreen ------------------------------------------------------------

void OpenBrowserView::SetTabFullscreen(bool fullscreen) {
  if (tab_fullscreen_ == fullscreen) {
    return;
  }
  tab_fullscreen_ = fullscreen;
  InvalidateLayout();
}

bool OpenBrowserView::IsTabFullscreen() const {
  if (tab_fullscreen_) {
    return true;
  }
  // Browser fullscreen (Cmd+Ctrl+F) keeps Open's frame; only a page that
  // asked for fullscreen goes full-bleed.
  if (!browser_view_ || !browser_view_->IsFullscreen()) {
    return false;
  }
  content::WebContents* contents = browser_view_->GetActiveWebContents();
  return contents && contents->IsFullscreen();
}

void OpenBrowserView::ApplyTabFullscreen(bool fullscreen) {
  if (tab_fullscreen_applied_ == fullscreen) {
    return;
  }
  tab_fullscreen_applied_ = fullscreen;
  panel_host_->SetFullBleed(fullscreen);
  const bool split = split_view_active_ && split_container_;
  panel_shadow_->SetVisible(!fullscreen && !split);
  if (fullscreen) {
    SetSplitDropOverlayActive(false);
    // No card and no reveal while the page is fullscreen.
    reveal_dwell_timer_.Stop();
    reveal_exit_timer_.Stop();
    if (card_state_ != CardState::kOff) {
      card_motion_->Stop();
      card_state_ = CardState::kOff;
      reveal_card_->SetVisible(false);
      card_shadow_->SetVisible(false);
      if (sidebar_->parent() == reveal_card_.get()) {
        ReparentSidebar(false);
      }
    }
    if (sliding_) {
      sidebar_slide_->JumpTo(sidebar_hidden_ ? HiddenSidebarOffset() : 0);
      OnSidebarSlideSettled();
    }
    StopRevealMonitor();
  } else if (sidebar_hidden_) {
    StartRevealMonitor();
  }
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    const bool any_fullscreen =
        tab_fullscreen_applied_ || (GetWidget() && GetWidget()->IsFullscreen());
    platform->SetFullscreenCornerState(GetWidget(), any_fullscreen);
  }
  ApplyWebCornerRadii();
  NotifyTrafficLights();
}

// --- Window material (macOS vibrancy / Windows 11 Mica) --------------------

void OpenBrowserView::EnableTranslucentChrome() {
#if BUILDFLAG(IS_MAC)
  if (translucent_chrome_enabled_ || !browser_view_) {
    return;
  }
  views::Widget* widget = GetWidget();
  views::NonClientView* non_client = widget ? widget->non_client_view() : nullptr;
  views::FrameView* frame = non_client ? non_client->frame_view() : nullptr;
  if (!frame) {
    return;
  }
  translucent_chrome_enabled_ = true;
  // The native browser frame paints an opaque background under the window;
  // give BrowserView a non-opaque layer and mark the frame view LAYER_NOT_DRAWN
  // so macOS vibrancy shows cleanly under theme_background_.
  browser_view_->SetPaintToLayer();
  browser_view_->layer()->SetFillsBoundsOpaquely(false);
  frame->SetPaintToLayer(ui::LAYER_NOT_DRAWN);
#endif
}

void OpenBrowserView::UpdateWindowMaterial() {
#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_WIN)
  views::Widget* widget = GetWidget();
  OpenPlatform* platform = OpenPlatform::Get();
  if (!widget || !platform) {
    return;
  }
#if BUILDFLAG(IS_MAC)
  if (window_controls_ != WindowControls::kNativeMac) {
    return;
  }
#endif
  const OpenSpaceThemeState& state = FocusedThemeState();
#if BUILDFLAG(IS_MAC)
  platform->SetWindowButtonsTone(
      widget, state.roles.content == theme::ContentAppearance::kDark,
      window_active_);
#endif
  const theme::ThemeStyle& style = state.style;
  WindowMaterialSpec spec;
  spec.vibrant = style.is_vibrant && controller_->IsTranslucencyEnabled();
  spec.dark_translucency = style.translucency == theme::Translucency::kDark;
  // Imported JSON keeps its stored translucency when the system appearance
  // changes: the material follows it, the wash follows the window
  // appearance. Editor themes carry their window scheme.
  spec.dark_scheme = style.uses_legacy_intensity
                         ? controller_->IsSystemDarkMode()
                         : style.window_color_scheme ==
                               theme::ContentAppearance::kDark;
  spec.default_theme = style.fill_kind == theme::ThemeStyle::FillKind::kCorners;
  spec.active = window_active_;
  if (applied_material_ && *applied_material_ == spec) {
    return;
  }
  applied_material_ = spec;
#if BUILDFLAG(IS_MAC)
  if (spec.vibrant) {
    // Before the window turns non-opaque: no frame-color flash.
    EnableTranslucentChrome();
  }
  const bool translucent = translucent_chrome_enabled_ &&
                           platform->UpdateWindowEffects(widget, spec);
#else
  // On Windows, UpdateWindowEffects sets immersive dark mode and returns false;
  // do NOT call EnableTranslucentChrome() which creates unmanaged layers over
  // NativeViewHostAura.
  const bool translucent = platform->UpdateWindowEffects(widget, spec);
#endif
  if (translucent != translucent_window_) {
    translucent_window_ = translucent;
    theme_background_->SetTranslucentWindow(translucent);
  }
#endif
}

void OpenBrowserView::OnWidgetVisibilityChanged(views::Widget* widget,
                                                bool visible) {
  widget_visible_ = visible;
}

void OpenBrowserView::OnWidgetDestroying(views::Widget* widget) {
  paint_as_active_subscription_ = {};
  StopRevealMonitor();
  sidebar_slide_->SetCompositor(nullptr);
  card_motion_->SetCompositor(nullptr);
  widget_observation_.Reset();
}

// --- OpenViewObserver -------------------------------------------------------------

void OpenBrowserView::OnTreeChanged(const TreeChange& change) {
  if (change.kind == TreeChange::Kind::kRemove) {
    favicon_cache_.erase(change.node_id);
  }
  sidebar_->OnTreeChanged(change);
}

void OpenBrowserView::OnSpacesChanged(const WindowID& window_id) {
  if (window_id != window_id_) {
    return;
  }
  sidebar_->OnSpacesChanged();
}

void OpenBrowserView::OnSpaceThemeChanged(const SpaceID& space_id) {
  theme_cache_.erase(space_id);
  if (shown_theme_space_ && *shown_theme_space_ == space_id) {
    // Theme edits apply at once (the editor previews live).
    const theme::ThemeStyle& style = ThemeStateFor(space_id).style;
    if (theme_background_) {
      theme_background_->SetStyle(style);
    }
    if (reveal_card_) {
      reveal_card_->SetStyle(style);
    }
    SyncWindowControlsState();
    UpdateWindowMaterial();
  }
  sidebar_->OnSpaceThemeChanged(space_id);
}

void OpenBrowserView::OnFavoritesChanged(const ProfileID& profile_id) {
  sidebar_->OnFavoritesChanged();
}

void OpenBrowserView::OnWindowStateChanged(const WindowID& window_id) {
  if (window_id != window_id_) {
    return;
  }
  const bool animate = AnimationsEnabled();
  SyncFromWindowState(animate);
  // The pager slides the strip and drives the background cross-fade.
  sidebar_->OnWindowStateChanged(animate);
  if (!transition_space_) {
    const SpaceID focused = FocusedSpaceId();
    if (!focused.empty() &&
        (!shown_theme_space_ || *shown_theme_space_ != focused)) {
      CrossfadeTheme(focused, animate);
    }
  }
  UpdatePanelChildren();
  ApplyWebCornerRadii();
  SyncWindowControlsState();
  if (IsRevealCardShown()) {
    reveal_card_->SetStyle(FocusedThemeState().style);
  }
}

void OpenBrowserView::OnTabLiveStateChanged(const ItemID& tab_id) {
  sidebar_->OnTabLiveStateChanged(tab_id);
  if (single_pane_toolbar_visible_) {
    if (const Tab* active = controller_->GetActiveTab(window_id_);
        active && active->id == tab_id) {
      SyncSinglePaneToolbarFromActiveTab();
    }
  }
}

void OpenBrowserView::OnActiveTabChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    // Each tab has its own web view: give the new one the panel corners.
    ApplyWebCornerRadii();
    UpdatePanelChildren();
    sidebar_->OnActiveTabChanged();
    if (single_pane_toolbar_visible_) {
      SyncSinglePaneToolbarFromActiveTab();
      InvalidateLayout();
    }
  }
}

void OpenBrowserView::OnSplitViewChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    SetSplitViewActive(controller_->IsSplitViewActive(window_id_));
  }
}

void OpenBrowserView::OnPeekChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    sidebar_->OnPeekChanged();
  }
}

void OpenBrowserView::OnCommandBarStateChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    sidebar_->OnCommandBarStateChanged();
  }
}

void OpenBrowserView::OnToolbarActionsChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    sidebar_->OnToolbarActionsChanged();
  }
}

void OpenBrowserView::OnSystemAppearanceChanged() {
  InvalidateThemeCache();
  InvalidateLayout();
  SchedulePaint();
}

BEGIN_METADATA(OpenBrowserView)
END_METADATA

}  // namespace open_unified
