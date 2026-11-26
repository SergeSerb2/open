// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_browser_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "build/build_config.h"
#include "cc/paint/paint_filter.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/top_container_view.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/design/open_motion.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/views/open_sidebar_view.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_animator.h"
#include "ui/compositor/layer_nine_patch.h"
#include "ui/compositor/paint_recorder.h"
#include "ui/events/event.h"
#include "ui/events/event_observer.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/gfx/geometry/transform.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/animation/animation_builder.h"
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

// Resize band inside the edges of a frameless (Windows / Linux) window.
constexpr int kFrameResizeBorder = 8;
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
      SchedulePaint();
    }
  }
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
    SetCanProcessEventsWithinSubtree(false);
    current_ = AddChildView(std::make_unique<OpenThemeLayerView>());
    incoming_ = AddChildView(std::make_unique<OpenThemeLayerView>());
    incoming_->SetVisible(false);
  }

  const theme::ThemeStyle& current_style() const { return current_->style(); }

  void SetStyle(const theme::ThemeStyle& style) {
    StopFade();
    current_->SetStyle(style);
    target_.reset();
  }

  void SetActive(bool active) {
    current_->SetActive(active);
    incoming_->SetActive(active);
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
    incoming_->SetVisible(true);
  }

  void SetTransitionProgress(double progress) {
    if (!target_) {
      return;
    }
    StopFade();
    incoming_->layer()->SetOpacity(
        static_cast<float>(std::clamp(progress, 0.0, 1.0)));
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
  void FinishFade(bool commit, double duration) {
    const float start = incoming_->layer()->GetTargetOpacity();
    const float end = commit ? 1.0f : 0.0f;
    const double remaining = std::abs(end - start) * duration;
    ++generation_;
    fading_ = true;
    views::AnimationBuilder()
        .SetPreemptionStrategy(ui::LayerAnimator::PreemptionStrategy::
                                   IMMEDIATELY_ANIMATE_TO_NEW_TARGET)
        .OnEnded(base::BindOnce(&ThemeBackgroundView::OnFadeEnded,
                                weak_factory_.GetWeakPtr(), generation_, commit))
        .Once()
        .SetDuration(motion::Seconds(remaining))
        .SetOpacity(incoming_->layer(), end, gfx::Tween::LINEAR);
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
  }

  raw_ptr<OpenThemeLayerView> current_ = nullptr;
  raw_ptr<OpenThemeLayerView> incoming_ = nullptr;
  std::optional<theme::ThemeStyle> target_;
  bool fading_ = false;
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
    SetCanProcessEventsWithinSubtree(false);
    margin_ = static_cast<int>(std::ceil(3 * sigma_ + std::abs(offset_y_))) + 1;
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

 private:
  float Proposed(const ui::MouseEvent& event) const {
    gfx::Point p = event.location();
    views::View::ConvertPointToScreen(this, &p);
    return owner_->drag_start_width_ + static_cast<float>(p.x() - start_x_);
  }

  raw_ptr<OpenBrowserView> owner_;
  int start_x_ = 0;
  bool dragging_ = false;
};

BEGIN_METADATA(OpenBrowserView, ResizeHandle)
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
  // Open's sidebar replaces the tab strip, toolbar and bookmark bar.
  if (TopContainerView* top = browser_view->top_container()) {
    top->SetVisible(false);
  }
  // Keep contents_container as a direct child of BrowserView (reparenting it
  // out/back fires OnViewAddedToWidget a second time on TabModalDialogHost).
  // Place OpenBrowserView behind it (theme, shadow, sidebar, split) and a
  // hit-test-transparent OpenOverlayHostView above it (reveal card, overlays).
  view->browser_contents_container_ = browser_view->contents_container();
  browser_view->AddChildViewAt(std::move(owned), 0);
  view->overlay_host_ =
      browser_view->AddChildView(std::make_unique<OpenOverlayHostView>());
  if (view->card_shadow_ && view->card_shadow_->parent() == view) {
    view->card_shadow_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->card_shadow_.get()));
  }
  if (view->reveal_card_ && view->reveal_card_->parent() == view) {
    view->reveal_card_ = view->overlay_host_->AddChildView(
        view->RemoveChildViewT(view->reveal_card_.get()));
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
    view->card_shadow_ = nullptr;
    view->reveal_card_ = nullptr;
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
  // Native web content is not clipped by the panel layer: its clipping
  // window gets the panel's 6 pt corners.
  if (views::NativeViewHost* holder = ActiveWebHolder()) {
    holder->SetNativeViewCornerRadii(gfx::RoundedCornersF(m::panel::kCornerRadius));
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
#else
      window_controls_(WindowControls::kCustomLeading)
#endif
{
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

  auto sidebar = std::make_unique<OpenSidebarView>(this);
  sidebar->SetPaintToLayer();
  sidebar->layer()->SetFillsBoundsOpaquely(false);
  sidebar_ = AddChildView(std::move(sidebar));
  sidebar_->SetWindowControlsSlot(
      window_controls_ == WindowControls::kCustomLeading
          ? OpenSidebarView::WindowControlsSlot::kCustom
          : OpenSidebarView::WindowControlsSlot::kNativeReserved);
  sidebar_->SetVisible(!sidebar_hidden_);

  resize_handle_ = AddChildView(std::make_unique<ResizeHandle>(this));

  card_shadow_ = AddChildView(std::make_unique<PanelShadowView>(
      m::window::kRevealCardRadius, m::window::kRevealCardShadowRadius,
      m::window::kRevealCardShadowOpacity, 0));
  card_shadow_->SetVisible(false);
  reveal_card_ = AddChildView(std::make_unique<RevealCardView>());
  reveal_card_->SetVisible(false);

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

  GetViewAccessibility().SetRole(ax::mojom::Role::kClient);
  controller_->AddViewObserver(this);
}

OpenBrowserView::~OpenBrowserView() {
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
  }
  UpdatePanelChildren();
  return split_container_;
}

void OpenBrowserView::SetSplitViewActive(bool active) {
  if (split_view_active_ == active) {
    return;
  }
  split_view_active_ = active;
  UpdatePanelChildren();
  sidebar_->OnSplitViewChanged(active);
}

void OpenBrowserView::UpdatePanelChildren() {
  const bool split = split_view_active_ && split_container_;
  if (split_container_) {
    split_container_->SetVisible(split);
  }
  if (web_contents_host_) {
    web_contents_host_->SetVisible(!split);
  }
  if (browser_contents_container_) {
    browser_contents_container_->SetVisible(!split);
  }
  panel_host_->InvalidateLayout();
  panel_host_->SchedulePaint();
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
  // Z order: Find/Toasts < Peek < Command Bar, all above the card.
  for (OverlaySlot s : {OverlaySlot::kFindBarAndToasts, OverlaySlot::kPeek,
                        OverlaySlot::kCommandBar}) {
    if (auto it = overlays_.find(s); it != overlays_.end()) {
      host->ReorderChildView(it->second, host->children().size());
    }
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

void OpenBrowserView::SetSidebarHidden(bool hidden, bool animate) {
  if (hidden == sidebar_hidden_) {
    return;
  }
  sidebar_hidden_ = hidden;
  if (animate && AnimationsEnabled() && !motion::PrefersReducedMotion()) {
    AnimateSidebar(hidden);
  } else {
    sidebar_slide_->JumpTo(hidden ? -sidebar_width_ : 0);
    OnSidebarSlideSettled();
  }
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

gfx::Rect OpenBrowserView::PanelBoundsFor(bool hidden, float width) const {
  const m::Frame f = m::panel::PanelFrame(
      {static_cast<float>(this->width()), static_cast<float>(height())}, width,
      hidden);
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
        sidebar_offset_, -sidebar_width_,
        sidebar_slide_->is_animating() ? sidebar_slide_->velocity() : 0.0);
  }
}

void OpenBrowserView::ApplySidebarOffset(double offset) {
  sidebar_offset_ = offset;
  if (sidebar_->parent() == this) {
    sidebar_->layer()->SetTransform(
        gfx::Transform::MakeTranslation(static_cast<float>(offset), 0));
  }
  const double shown_fraction =
      sidebar_width_ > 0 ? std::clamp(1.0 + offset / sidebar_width_, 0.0, 1.0)
                         : 1.0;
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
    sidebar_offset_ = -sidebar_width_;
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
}

gfx::Rect OpenBrowserView::RevealCardBounds() const {
  const m::Frame f = m::window::RevealCardFrame(
      {static_cast<float>(width()), static_cast<float>(height())},
      sidebar_width_);
  return gfx::ToEnclosingRect(gfx::RectF(f.x, f.y, f.w, f.h));
}

bool OpenBrowserView::PointInRevealZone(const gfx::Point& p) const {
  // Inner left edge (0 .. 0.6 u) and the top-left corner.
  const bool inner = p.x() >= 0 && p.x() < m::reveal::kInnerEdgeWidth &&
                     p.y() >= 0 && p.y() < height();
  const bool top_left = p.x() >= 0 && p.x() < m::reveal::kTopLeftWidth &&
                        p.y() >= m::reveal::kTopLeftMin &&
                        p.y() < m::reveal::kTopLeftMax;
  return inner || top_left;
}

bool OpenBrowserView::PointInHoldZone(const gfx::Point& p) const {
  if (RevealCardBounds().Contains(p)) {
    return true;
  }
  const bool inner_held = p.x() >= m::reveal::kInnerEdgeHeldMin &&
                          p.x() < m::reveal::kInnerEdgeHeldMax;
  const bool lights = p.x() < m::chrome::kSidebarToggleX + m::window::kRevealCardInset &&
                      p.y() < m::reveal::kTrafficLightRegionHeight;
  return inner_held || lights;
}

void OpenBrowserView::OnRevealEvent(const ui::Event& event) {
  if (!sidebar_hidden_ || sliding_ || !reveal_monitor_) {
    return;
  }
  if (event.type() == ui::EventType::kMouseExited) {
    // Leaving through the left edge stays in the held outer-edge zone.
    const bool left_edge =
        last_reveal_point_ && last_reveal_point_->x() < m::reveal::kInnerEdgeHeldMax;
    if (IsRevealCardShown() && !left_edge && !reveal_exit_timer_.IsRunning()) {
      reveal_exit_timer_.Start(FROM_HERE, motion::Seconds(m::reveal::kExitDelay),
                               base::BindOnce(&OpenBrowserView::HideRevealCard,
                                              base::Unretained(this)));
    }
    reveal_dwell_timer_.Stop();
    return;
  }
  gfx::Point p = reveal_monitor_->GetLastMouseLocation();
  views::View::ConvertPointFromScreen(this, &p);
  last_reveal_point_ = p;
  if (card_state_ == CardState::kOff || card_state_ == CardState::kHiding) {
    if (PointInRevealZone(p)) {
      if (!reveal_dwell_timer_.IsRunning()) {
        reveal_dwell_timer_.Start(
            FROM_HERE, motion::Seconds(m::reveal::kDwell),
            base::BindOnce(
                [](OpenBrowserView* self) {
                  if (self->last_reveal_point_ &&
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
  if (PointInHoldZone(p)) {
    reveal_exit_timer_.Stop();
  } else if (!reveal_exit_timer_.IsRunning()) {
    reveal_exit_timer_.Start(FROM_HERE, motion::Seconds(m::reveal::kExitDelay),
                             base::BindOnce(&OpenBrowserView::HideRevealCard,
                                            base::Unretained(this)));
  }
}

void OpenBrowserView::ShowRevealCard() {
  if (!sidebar_hidden_ || card_state_ == CardState::kShown ||
      card_state_ == CardState::kShowing) {
    return;
  }
  ReparentSidebar(true);
  reveal_card_->SetStyle(FocusedThemeState().style);
  reveal_card_->SetWindowSize(size());
  reveal_card_->SetVisible(true);
  card_shadow_->SetVisible(true);
  card_state_ = CardState::kShowing;
  InvalidateLayout();
  const double from = card_motion_->is_animating()
                          ? card_motion_->value()
                          : -(sidebar_width_ + m::window::kRevealCardInset * 2);
  card_motion_->SetSpring(motion::kRevealCardIn);
  card_motion_->SetCompositor(AnimationCompositor());
  card_motion_->AnimateFromTo(from, 0,
                              card_motion_->is_animating() ? card_motion_->velocity()
                                                           : 0.0);
}

void OpenBrowserView::HideRevealCard() {
  if (card_state_ == CardState::kOff || card_state_ == CardState::kHiding) {
    return;
  }
  card_state_ = CardState::kHiding;
  card_motion_->SetCompositor(AnimationCompositor());
  card_motion_->AnimateTimed(card_motion_->value(),
                             -(sidebar_width_ + m::window::kRevealCardInset * 2),
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
  if (!traffic_lights_callback_) {
    return;
  }
  const m::Frame close = m::chrome::kTrafficLightFrames[0];
  gfx::Point origin(static_cast<int>(close.x), static_cast<int>(close.y));
  bool visible = !sidebar_hidden_ || sliding_;
  if (sidebar_->parent() == reveal_card_.get()) {
    // The lights ride on the card: AX close [17, 21].
    visible = card_state_ != CardState::kOff;
    origin.Offset(reveal_card_->x() +
                      static_cast<int>(std::lround(card_motion_->value())),
                  reveal_card_->y());
  } else {
    origin.Offset(static_cast<int>(std::lround(sidebar_offset_)), 0);
  }
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
  theme_background_->EndTransition(commit);
  if (commit && transition_space_) {
    shown_theme_space_ = transition_space_;
    reveal_card_->SetStyle(ThemeStateFor(*transition_space_).style);
  }
  transition_space_.reset();
}

void OpenBrowserView::CrossfadeTheme(const SpaceID& to, bool animated) {
  const theme::ThemeStyle& style = ThemeStateFor(to).style;
  if (animated && AnimationsEnabled()) {
    theme_background_->Crossfade(style);
  } else {
    theme_background_->SetStyle(style);
  }
  reveal_card_->SetStyle(style);
  shown_theme_space_ = to;
}

ui::Compositor* OpenBrowserView::AnimationCompositor() {
  views::Widget* widget = GetWidget();
  return widget ? widget->GetCompositor() : nullptr;
}

bool OpenBrowserView::AnimationsEnabled() const {
  const views::Widget* widget = GetWidget();
  return widget && widget_visible_ && !widget->IsMinimized();
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
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(),
      views::MenuRunner::CONTEXT_MENU | views::MenuRunner::HAS_MNEMONICS);
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
  auto it = favicon_cache_.find(tab.id);
  if (it != favicon_cache_.end() && it->second.png_size == png.size()) {
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
  entry.image = gfx::ImageSkia::CreateFrom1xBitmap(bitmap);
  return entry.image;
}

// --- Frame ----------------------------------------------------------------------------

int OpenBrowserView::NonClientHitTest(const gfx::Point& point) const {
  if (!GetLocalBounds().Contains(point)) {
    return HTNOWHERE;
  }
  const views::Widget* widget = GetWidget();
  // Open removes the native frame (WantsFramelessWindow()), so on Windows and
  // Linux this view supplies the resize edges; macOS keeps the system's
  // resize edges unless Open draws its own window controls.
#if BUILDFLAG(IS_MAC)
  const bool draws_own_frame =
      window_controls_ == WindowControls::kCustomLeading;
#else
  const bool draws_own_frame = WantsFramelessWindow();
#endif
  const bool can_resize =
      widget && !widget->IsMaximized() && !widget->IsFullscreen() &&
      (!widget->widget_delegate() || widget->widget_delegate()->CanResize());
  if (draws_own_frame && can_resize) {
    const bool left = point.x() < kFrameResizeBorder;
    const bool right = point.x() >= width() - kFrameResizeBorder;
    const bool top = point.y() < kFrameResizeBorder;
    const bool bottom = point.y() >= height() - kFrameResizeBorder;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
  views::View* target =
      const_cast<OpenBrowserView*>(this)->GetEventHandlerForPoint(point);
  if (!target || target == this) {
    // The 10 pt frame inset and anything behind the panel: drag the window.
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
  window_controls_ = controls;
  sidebar_->SetWindowControlsSlot(
      controls == WindowControls::kCustomLeading
          ? OpenSidebarView::WindowControlsSlot::kCustom
          : controls == WindowControls::kNativeMac
                ? OpenSidebarView::WindowControlsSlot::kNativeReserved
                : OpenSidebarView::WindowControlsSlot::kNone);
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
  if (clips) {
    SetPaintToLayer();
    layer()->SetFillsBoundsOpaquely(false);
    layer()->SetRoundedCornerRadius(
        gfx::RoundedCornersF(m::window::kCornerRadius));
    layer()->SetIsFastRoundedCorner(true);
  } else if (layer()) {
    layer()->SetRoundedCornerRadius(gfx::RoundedCornersF());
  }
}

// --- Layout -----------------------------------------------------------------------------

void OpenBrowserView::LayoutPanel(const gfx::Rect& panel) {
  panel_host_->SetBoundsRect(panel);
  panel_shadow_->SetContentBounds(panel);
  if (browser_contents_container_) {
    browser_contents_container_->SetBoundsRect(panel);
  }
}

void OpenBrowserView::LayoutOverlays() {
  if (overlay_host_) {
    overlay_host_->SetBoundsRect(bounds());
  }
  for (const auto& [slot, view] : overlays_) {
    view->SetBoundsRect(slot == OverlaySlot::kFindBarAndToasts
                            ? panel_host_->bounds()
                            : GetLocalBounds());
  }
}

void OpenBrowserView::Layout(PassKey) {
  theme_background_->SetBoundsRect(GetLocalBounds());
  const int w = static_cast<int>(std::lround(sidebar_width_));
  if (!sliding_) {
    LayoutPanel(PanelBoundsFor(sidebar_hidden_, sidebar_width_));
  }
  if (sidebar_->parent() == this) {
    sidebar_->SetBounds(0, 0, w, height());
    if (!sliding_) {
      sidebar_->layer()->SetTransform(gfx::Transform());
      sidebar_->SetVisible(!sidebar_hidden_);
    }
  }
  const int handle = static_cast<int>(m::window::kResizeHandleWidth);
  resize_handle_->SetBounds(w - handle / 2, 0, handle, height());
  resize_handle_->SetVisible(!sliding_ && (!sidebar_hidden_ || resizing_));
  const gfx::Rect card = RevealCardBounds();
  reveal_card_->SetBoundsRect(card);
  reveal_card_->SetWindowSize(size());
  card_shadow_->SetContentBounds(card);
  if (sidebar_->parent() == reveal_card_.get()) {
    sidebar_->SetBounds(0, 0, card.width(), card.height());
  }
  LayoutOverlays();
  NotifyTrafficLights();
}

void OpenBrowserView::AddedToWidget() {
  views::Widget* widget = GetWidget();
  widget_observation_.Reset();
  widget_observation_.Observe(widget);
  widget_visible_ = widget->IsVisible();
  window_active_ = widget->IsActive();
  theme_background_->SetActive(window_active_);
  reveal_card_->SetActive(window_active_);
  sidebar_slide_->SetCompositor(widget->GetCompositor());
  card_motion_->SetCompositor(widget->GetCompositor());
  SyncFromWindowState(/*animate=*/false);
  if (sidebar_hidden_) {
    StartRevealMonitor();
  }
}

void OpenBrowserView::RemovedFromWidget() {
  StopRevealMonitor();
  sidebar_slide_->SetCompositor(nullptr);
  card_motion_->SetCompositor(nullptr);
  widget_observation_.Reset();
}

void OpenBrowserView::OnThemeChanged() {
  views::View::OnThemeChanged();
  // Native theme changes (e.g. high contrast) can change roles.
  InvalidateThemeCache();
}

// --- views::WidgetObserver ------------------------------------------------------

void OpenBrowserView::OnWidgetActivationChanged(views::Widget* widget,
                                                bool active) {
  if (window_active_ == active) {
    return;
  }
  window_active_ = active;
  theme_background_->SetActive(active);
  reveal_card_->SetActive(active);
  sidebar_->OnWindowActivationChanged();
}

void OpenBrowserView::OnWidgetVisibilityChanged(views::Widget* widget,
                                                bool visible) {
  widget_visible_ = visible;
}

void OpenBrowserView::OnWidgetDestroying(views::Widget* widget) {
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
    theme_background_->SetStyle(style);
    reveal_card_->SetStyle(style);
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
  if (IsRevealCardShown()) {
    reveal_card_->SetStyle(FocusedThemeState().style);
  }
}

void OpenBrowserView::OnTabLiveStateChanged(const ItemID& tab_id) {
  sidebar_->OnTabLiveStateChanged(tab_id);
}

void OpenBrowserView::OnActiveTabChanged(const WindowID& window_id) {
  if (window_id == window_id_) {
    // Each tab has its own web view: give the new one the panel corners.
    ApplyWebCornerRadii();
    sidebar_->OnActiveTabChanged();
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
}

BEGIN_METADATA(OpenBrowserView)
END_METADATA

}  // namespace open_unified
