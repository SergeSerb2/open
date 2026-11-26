// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_sidebar_view.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <numbers>
#include <set>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_filter.h"
#include "cc/paint/paint_flags.h"
#include "cc/paint/paint_shader.h"
#include "cc/paint/path_effect.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/design/open_motion.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/views/open_space_pager_view.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "third_party/skia/include/core/SkBlendMode.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/dragdrop/drag_drop_types.h"
#include "ui/base/dragdrop/drop_target_event.h"
#include "ui/base/dragdrop/mojom/drag_drop_types.mojom.h"
#include "ui/base/dragdrop/os_exchange_data.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer.h"
#include "ui/compositor/layer_tree_owner.h"
#include "ui/compositor/paint_recorder.h"
#include "ui/events/event.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets_f.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/context_menu_controller.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/drag_controller.h"
#include "ui/views/paint_info.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

namespace open_unified {

namespace m = metrics;
using theme::Rgba;
using typography::OpenFont;

namespace {

SkColor Sk(const Rgba& c, float alpha = 1.0f) {
  return theme::ToSkColor(c.WithAlpha(c.a * alpha));
}

bool IsDark(const OpenSpaceThemeState& s) {
  return s.roles.content == theme::ContentAppearance::kDark;
}

// Measured chrome tokens not in SidebarRoles (Palette.swift SidebarRole).
// Toolbar/bottom hover plate GrayA4, pressed GrayA6.
Rgba ButtonHover(const OpenSpaceThemeState& s) {
  return IsDark(s) ? Rgba::White(0.08) : Rgba::Black(0.07);
}
Rgba ButtonPressed(const OpenSpaceThemeState& s) {
  return IsDark(s) ? Rgba::White(0.13) : Rgba::Black(0.11);
}
// Enabled toolbar glyph GrayA11 (with Increase Contrast: roles).
Rgba ToolbarGlyph(const OpenSpaceThemeState& s, bool increase_contrast) {
  if (increase_contrast) {
    return s.roles.toolbar_glyph;
  }
  return IsDark(s) ? Rgba::White(0.59) : Rgba::Black(0.56);
}
// URL field magnifier: fitted black 0.40; dark guess white 0.40.
Rgba Magnifier(const OpenSpaceThemeState& s) {
  return IsDark(s) ? Rgba::White(0.40) : Rgba::Black(0.40);
}
// Favorite tile hover (SidebarColors.itemHoveredBackground; guess).
Rgba TileHover(const OpenSpaceThemeState& s) {
  return IsDark(s) ? Rgba::Hex(0xFAFBFF, 0.15) : Rgba::Hex(0x0E0F10, 0.10);
}
// Peek dims the toolbar row and the bottom bar. guess: 0.4.
constexpr float kPeekDimOpacity = 0.4f;
// Incognito URL field: white 15 % (docs/incognito.md S10-P5, measured).
constexpr Rgba kIncognitoFieldFill = Rgba::White(0.15);

// SelectionShadow (SidebarRows.swift): light content only, black 0.20,
// radius 1.5, 1 pt down. Dark content uses the borderless frosted plate.
void DrawSelectionShadow(gfx::Canvas* canvas,
                         const gfx::RectF& rect,
                         float radius,
                         float alpha) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SkColorSetA(
      SK_ColorBLACK, static_cast<U8CPU>(std::lround(0.20f * alpha * 255))));
  flags.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
      0.75f, 0.75f, SkTileMode::kDecal, nullptr));
  gfx::RectF shadow = rect;
  shadow.Offset(0, 1);
  canvas->DrawRoundRect(shadow, radius, flags);
}

gfx::Rect ToRect(const m::Frame& f) {
  return gfx::ToEnclosingRect(gfx::RectF(f.x, f.y, f.w, f.h));
}

void FillRoundRect(gfx::Canvas* canvas,
                   const gfx::RectF& rect,
                   float radius,
                   SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

std::u16string DisplayHost(const std::string& url) {
  const GURL gurl(url);
  if (!gurl.is_valid()) {
    return base::UTF8ToUTF16(url);
  }
  std::string host(gurl.host());
  if (host.rfind("www.", 0) == 0) {
    host = host.substr(4);
  }
  if (host.empty()) {
    return base::UTF8ToUTF16(gurl.spec());
  }
  return base::UTF8ToUTF16(host);
}

bool IsBlankPage(const Tab* tab) {
  if (!tab || tab->url.empty()) {
    return true;
  }
  const GURL gurl(tab->url);
  return gurl.SchemeIs("about") || gurl.spec() == "open://newtab/" ||
         gurl.spec() == "chrome://newtab/";
}

float DeviceScale(const views::View* view) {
  const views::Widget* widget = view->GetWidget();
  return widget && widget->GetCompositor()
             ? widget->GetCompositor()->device_scale_factor()
             : 1.0f;
}

}  // namespace

// ---------------------------------------------------------------------------
// ToolbarButton: a 32 x 32 (or 28 / 30) plate-on-hover icon button used for
// the toolbar, the URL pill accessories and the bottom bar.

class OpenSidebarView::ToolbarButton : public views::Button {
  METADATA_HEADER(ToolbarButton, views::Button)

 public:
  enum class Role { kToolbar, kBottom, kAccessory };

  ToolbarButton(OpenSidebarContext* context,
                PressedCallback callback,
                glyphs::Glyph glyph,
                std::u16string name,
                Role role)
      : views::Button(std::move(callback)),
        context_(context),
        glyph_(glyph),
        role_(role) {
    SetFocusBehavior(FocusBehavior::ACCESSIBLE_ONLY);
    SetTooltipText(name);
    GetViewAccessibility().SetName(name);
    SetNotifyEnterExitOnChild(true);
  }

  void SetGlyph(glyphs::Glyph glyph) {
    if (glyph_ != glyph || !image_.isNull()) {
      glyph_ = glyph;
      image_ = gfx::ImageSkia();
      SchedulePaint();
    }
  }
  void SetImage(const gfx::ImageSkia& image) {
    image_ = image;
    SchedulePaint();
  }
  void SetDimmedLook(bool dimmed) {
    if (dimmed_ != dimmed) {
      dimmed_ = dimmed;
      SchedulePaint();
    }
  }
  // Download progress ring (Library button): 0..1, nullopt hides it.
  void SetProgressRing(std::optional<double> progress) {
    if (progress) {
      progress = std::clamp(*progress, 0.0, 1.0);
    }
    if (progress_ != progress) {
      progress_ = progress;
      SchedulePaint();
    }
  }

  // views::Button:
  void PaintButtonContents(gfx::Canvas* canvas) override {
    const OpenSpaceThemeState& s =
        context_->ThemeStateFor(context_->FocusedSpaceId());
    const gfx::RectF bounds(GetLocalBounds());
    const ButtonState state = GetState();
    if (GetEnabled() && (state == STATE_HOVERED || state == STATE_PRESSED)) {
      FillRoundRect(canvas, bounds, m::chrome::kButtonPlateRadius,
                    Sk(state == STATE_PRESSED ? ButtonPressed(s)
                                              : ButtonHover(s)));
    }
    const bool ic = context_->controller()->IsIncreaseContrastEnabled();
    Rgba color;
    switch (role_) {
      case Role::kToolbar:
        color = ToolbarGlyph(s, ic);
        break;
      case Role::kBottom:
        color = s.roles.bottom_glyph;
        break;
      case Role::kAccessory:
        color = s.roles.url_text;
        break;
    }
    // Inactive windows and disabled buttons take the disabled tone.
    if (!GetEnabled() || dimmed_ || !context_->IsWindowActive()) {
      color = s.roles.toolbar_glyph_disabled;
    }
    if (!image_.isNull()) {
      const int size = 16;
      const gfx::Rect r((width() - size) / 2, (height() - size) / 2, size,
                        size);
      cc::PaintFlags flags;
      flags.setAlphaf(dimmed_ ? 0.5f : 1.0f);
      canvas->DrawImageInt(image_, 0, 0, image_.width(), image_.height(), r.x(),
                           r.y(), r.width(), r.height(), true, flags);
      return;
    }
    // Arrows and reload sit 1 pt low (icon map).
    const bool low = glyph_ == glyphs::Glyph::kBack ||
                     glyph_ == glyphs::Glyph::kForward ||
                     glyph_ == glyphs::Glyph::kReload ||
                     glyph_ == glyphs::Glyph::kStop;
    glyphs::Draw(canvas, glyph_, bounds, Sk(color),
                 gfx::Vector2dF(0, low ? 1 : 0));
    PaintProgressRing(canvas, s);
  }

 private:
  // guess: a 2 pt ring at r 13 inside the 32 pt plate, the track at the
  // glyph color 0.20, progress in the Space's contrast accent clockwise from
  // 12 o'clock (Arc's Library download ring; capture pending).
  void PaintProgressRing(gfx::Canvas* canvas, const OpenSpaceThemeState& s) {
    if (!progress_) {
      return;
    }
    const gfx::PointF c = gfx::RectF(GetLocalBounds()).CenterPoint();
    const float r = std::min(width(), height()) / 2.0f - 3.0f;
    cc::PaintFlags pen;
    pen.setAntiAlias(true);
    pen.setStyle(cc::PaintFlags::kStroke_Style);
    pen.setStrokeWidth(2);
    pen.setStrokeCap(cc::PaintFlags::kRound_Cap);
    pen.setColor(Sk(s.roles.bottom_glyph, 0.20f));
    canvas->DrawCircle(c, r, pen);
    pen.setColor(Sk(s.contrast_accent));
    SkPathBuilder arc;
    arc.arcTo(SkRect::MakeLTRB(c.x() - r, c.y() - r, c.x() + r, c.y() + r),
              -90, static_cast<float>(360 * *progress_), /*forceMoveTo=*/true);
    canvas->DrawPath(arc.detach(), pen);
  }

  raw_ptr<OpenSidebarContext> context_;
  glyphs::Glyph glyph_;
  Role role_;
  gfx::ImageSkia image_;
  bool dimmed_ = false;
  std::optional<double> progress_;
};

BEGIN_METADATA(OpenSidebarView, ToolbarButton)
END_METADATA

// ---------------------------------------------------------------------------
// ToolbarView: y 0..46.

class OpenSidebarView::ToolbarView : public views::View {
  METADATA_HEADER(ToolbarView, views::View)

 public:
  explicit ToolbarView(OpenSidebarView* sidebar) : sidebar_(sidebar) {
    OpenSidebarContext* ctx = sidebar->context_;
    SetProperty(kOpenWindowDragKey, true);
    auto send = [](OpenSidebarContext* c, OpenIntentKind kind) {
      c->Send(OpenIntent::Of(kind));
    };
    toggle_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx, base::BindRepeating(send, base::Unretained(ctx), OpenIntentKind::kToggleSidebar),
        glyphs::Glyph::kSidebarToggle, u"Toggle Sidebar",
        ToolbarButton::Role::kToolbar));
    back_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx, base::BindRepeating(send, base::Unretained(ctx), OpenIntentKind::kGoBack),
        glyphs::Glyph::kBack, u"Back", ToolbarButton::Role::kToolbar));
    forward_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx, base::BindRepeating(send, base::Unretained(ctx), OpenIntentKind::kGoForward),
        glyphs::Glyph::kForward, u"Forward", ToolbarButton::Role::kToolbar));
    reload_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(&ToolbarView::OnReloadPressed,
                            base::Unretained(this)),
        glyphs::Glyph::kReload, u"Reload", ToolbarButton::Role::kToolbar));
    more_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(&ToolbarView::OnMorePressed,
                            base::Unretained(this)),
        glyphs::Glyph::kMore, u"More Options", ToolbarButton::Role::kToolbar));
  }

  void SetWindowControls(WindowControlsSlot slot) {
    if (slot_ != slot) {
      slot_ = slot;
      InvalidateLayout();
    }
  }

  void Refresh() {
    const Tab* tab = sidebar_->context_->controller()->GetActiveTab(
        sidebar_->context_->window_id());
    back_->SetEnabled(tab && tab->live_state.can_go_back);
    forward_->SetEnabled(tab && tab->live_state.can_go_forward);
    loading_ = tab && tab->live_state.is_loading;
    reload_->SetGlyph(loading_ ? glyphs::Glyph::kStop : glyphs::Glyph::kReload);
    reload_->SetTooltipText(loading_ ? u"Stop" : u"Reload");
    reload_->SetEnabled(tab != nullptr);
    InvalidateLayout();
    SchedulePaint();
    for (views::View* child : children()) {
      child->SchedulePaint();
    }
  }

  void SetDimmed(bool dimmed) {
    for (ToolbarButton* b : {toggle_.get(), back_.get(), forward_.get(),
                             reload_.get(), more_.get()}) {
      b->SetDimmedLook(dimmed);
    }
  }

  // views::View:
  void Layout(PassKey) override {
    const float w = width();
    const bool split = sidebar_->split_view_active_;
    const bool compact = m::chrome::IsCompact(w);
    const bool native_controls =
        slot_ == WindowControlsSlot::kNativeReserved;
    const int b = static_cast<int>(m::chrome::kToolbarButtonSize);
    const int y = static_cast<int>(m::chrome::kToolbarButtonY);
    // macOS: the system traffic lights (x 12..70) own the leading 77 pt, so
    // the toggle starts at kSidebarToggleX. Windows and Linux have no window
    // controls in the sidebar: the toggle's plate lines up with the URL
    // pill's leading edge.
    const int toggle_x = static_cast<int>(
        native_controls ? m::chrome::kSidebarToggleX : m::url_field::kInsetX);
    toggle_->SetBounds(toggle_x, y, b, b);
    if (split) {
      // Split View keeps only the sidebar toggle (F0081, F0082).
      toggle_->SetVisible(true);
      back_->SetVisible(false);
      forward_->SetVisible(false);
      reload_->SetVisible(false);
      more_->SetVisible(false);
      return;
    }
    if (compact) {
      // Back, Forward, More: 28 x 28 at y 9, pitch 28 (completion 3.16).
      const int cb = static_cast<int>(m::compact_toolbar::kButtonSize);
      const int cy = static_cast<int>(m::compact_toolbar::kY);
      // With the traffic lights in the leading slot the compact row has no
      // room for the toggle (Arc). Without them it stays while it clears
      // Back by the 2 pt nav gap.
      toggle_->SetVisible(!native_controls &&
                          toggle_x + b + 2 <=
                              static_cast<int>(m::compact_toolbar::BackX(w)));
      back_->SetVisible(true);
      forward_->SetVisible(true);
      reload_->SetVisible(false);
      more_->SetVisible(true);
      back_->SetBounds(static_cast<int>(m::compact_toolbar::BackX(w)), cy, cb, cb);
      forward_->SetBounds(static_cast<int>(m::compact_toolbar::ForwardX(w)), cy,
                          cb, cb);
      more_->SetBounds(static_cast<int>(m::compact_toolbar::MoreX(w)), cy, cb,
                       cb);
      return;
    }
    toggle_->SetVisible(true);
    back_->SetVisible(true);
    forward_->SetVisible(true);
    reload_->SetVisible(true);
    more_->SetVisible(false);
    back_->SetBounds(static_cast<int>(m::chrome::BackX(w)), y, b, b);
    forward_->SetBounds(static_cast<int>(m::chrome::ForwardX(w)), y, b, b);
    reload_->SetBounds(static_cast<int>(m::chrome::ReloadX(w)), y, b, b);
  }

 private:
  void OnReloadPressed() {
    sidebar_->context_->Send(OpenIntent::Of(
        loading_ ? OpenIntentKind::kStopLoading : OpenIntentKind::kReload));
  }
  void OnMorePressed() {
    OpenIntent intent = OpenIntent::Of(OpenIntentKind::kShowToolbarMore);
    intent.anchor_in_screen = more_->GetBoundsInScreen();
    sidebar_->context_->Send(intent);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  WindowControlsSlot slot_ = WindowControlsSlot::kNone;
  raw_ptr<ToolbarButton> toggle_ = nullptr;
  raw_ptr<ToolbarButton> back_ = nullptr;
  raw_ptr<ToolbarButton> forward_ = nullptr;
  raw_ptr<ToolbarButton> reload_ = nullptr;
  raw_ptr<ToolbarButton> more_ = nullptr;
  bool loading_ = false;
};

BEGIN_METADATA(OpenSidebarView, ToolbarView)
END_METADATA

// ---------------------------------------------------------------------------
// UrlPillView: [8, 46, W - 16, 36], radius 10. Coordinates below are local
// to the pill (sidebar x - 8, y - 46).

class OpenSidebarView::UrlPillView : public views::View,
                                     public views::ContextMenuController {
  METADATA_HEADER(UrlPillView, views::View)

 public:
  explicit UrlPillView(OpenSidebarView* sidebar) : sidebar_(sidebar) {
    OpenSidebarContext* ctx = sidebar->context_;
    SetNotifyEnterExitOnChild(true);
    // Right-click: the URL field menu (Copy URL, Site Controls, ...).
    set_context_menu_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kTextField);
    GetViewAccessibility().SetName(u"Address and search bar");
    copy_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(
            [](OpenSidebarContext* c) {
              c->Send(OpenIntent::Of(OpenIntentKind::kCopyCurrentUrl));
            },
            base::Unretained(ctx)),
        glyphs::Glyph::kLink, u"Copy URL", ToolbarButton::Role::kAccessory));
    site_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(&UrlPillView::OnSiteControlsPressed,
                            base::Unretained(this)),
        glyphs::Glyph::kSiteControls, u"Site Controls",
        ToolbarButton::Role::kAccessory));
  }

  views::View* site_button() const { return site_; }

  void SetControlsVisible(bool visible) {
    if (controls_visible_ != visible) {
      controls_visible_ = visible;
      InvalidateLayout();
      SchedulePaint();
    }
  }

  void Refresh() {
    RebuildExtensions();
    InvalidateLayout();
    SchedulePaint();
  }

  void RebuildExtensions() {
    OpenSidebarContext* ctx = sidebar_->context_;
    const auto actions =
        ctx->controller()->GetPinnedToolbarActions(ctx->window_id());
    std::vector<ToolbarButton*> old_extensions;
    old_extensions.reserve(extensions_.size());
    for (ToolbarButton* b : extensions_) {
      old_extensions.push_back(b);
    }
    extensions_.clear();
    for (ToolbarButton* b : old_extensions) {
      RemoveChildViewT(b);
    }
    for (const OpenToolbarActionInfo& action : actions) {
      const size_t index = extensions_.size();
      auto button = std::make_unique<ToolbarButton>(
          ctx,
          base::BindRepeating(&UrlPillView::OnExtensionPressed,
                              base::Unretained(this), action.id, index),
          glyphs::Glyph::kPuzzle, action.tooltip,
          ToolbarButton::Role::kAccessory);
      if (!action.icon.isNull()) {
        button->SetImage(action.icon);
      }
      extensions_.push_back(AddChildView(std::move(button)));
    }
  }

  // views::View:
  void Layout(PassKey) override {
    const float w = width();
    const int a = static_cast<int>(m::url_field::kAccessorySize);
    const int ay = static_cast<int>(m::url_field::kAccessoryY - m::url_field::kY);
    const bool page = !IsBlankPage(ActiveTab());
    // Accessories stack leftward from the trailing edge, but never into the
    // leading text: the host (or the magnifier and placeholder) keeps at
    // least kMinTextWidth, and an extension button that does not fit hides.
    const int min_left =
        TextLeft(page) + kMinTextWidth +
        static_cast<int>(m::url_field::kControlsTextGap);
    // Sidebar frames [W - 42, 49] and [W - 70, 49] in pill coordinates: the
    // pill is W - 16 wide at x 8, so Site Control sits at w + 8 - 12 - 30.
    int x = static_cast<int>(w + m::url_field::kInsetX -
                             m::url_field::kSiteControlsTrailing - a);
    const int pitch = static_cast<int>(m::url_field::kAccessoryPitch);
    site_->SetVisible(controls_visible_ && page && x >= min_left);
    site_->SetBounds(x, ay, a, a);
    x -= pitch;
    copy_->SetVisible(controls_visible_ && page && x >= min_left);
    copy_->SetBounds(x, ay, a, a);
    for (ToolbarButton* b : extensions_) {
      x -= pitch;
      b->SetVisible(controls_visible_ && x >= min_left);
      b->SetBounds(x, ay, a, a);
    }
  }

  void OnPaint(gfx::Canvas* canvas) override {
    const OpenSpaceThemeState& s =
        sidebar_->context_->ThemeStateFor(sidebar_->context_->FocusedSpaceId());
    const gfx::RectF bounds(GetLocalBounds());
    // Incognito: the measured white 15 % at rest and on hover.
    const Rgba fill = sidebar_->IsIncognito()
                          ? kIncognitoFieldFill
                          : (hovered_ ? s.roles.field_hover : s.roles.field_fill);
    FillRoundRect(canvas, bounds, m::url_field::kCornerRadius, Sk(fill));
    const Tab* tab = ActiveTab();
    const float text_y_frame = m::url_field::kTextY - m::url_field::kY;
    if (IsBlankPage(tab)) {
      const m::Frame mag = m::url_field::kMagnifierFrame;
      glyphs::Draw(canvas, glyphs::Glyph::kMagnifier,
                   gfx::RectF(mag.x - m::url_field::kInsetX,
                              mag.y - m::url_field::kY, mag.w, mag.h),
                   Sk(Magnifier(s)));
      const gfx::FontList& font = typography::Get(OpenFont::kUrlPlaceholder);
      const int x = TextLeft(/*page=*/false);
      const int top = typography::TextTopForBaseline(
          font, text_y_frame + m::url_field::kTextBaselineOffset);
      canvas->DrawStringRect(
          u"Search or Enter URL…", font, Sk(s.roles.placeholder),
          gfx::Rect(x, top, std::max(0, TextRight() - x), font.GetHeight()));
      return;
    }
    const std::u16string host = DisplayHost(tab->url);
    const gfx::FontList& font = typography::Get(OpenFont::kUrlHost);
    const int x0 = TextLeft(/*page=*/true);
    const int available = std::max(0, TextRight() - x0);
    const int text_w = gfx::Canvas::GetStringWidth(host, font);
    const int top = typography::TextTopForBaseline(
        font, text_y_frame + m::url_field::kTextBaselineOffset);
    const SkColor color = Sk(s.roles.url_text);
    if (text_w <= available) {
      canvas->DrawStringRectWithFlags(host, font, color,
                                      gfx::Rect(x0, top, available, font.GetHeight()),
                                      gfx::Canvas::NO_ELLIPSIS);
      return;
    }
    // A long host keeps its end visible; its leading 34 pt fade to clear.
    const gfx::Rect clip(x0, top, available, font.GetHeight());
    cc::PaintCanvas* sk = canvas->sk_canvas();
    sk->saveLayer(gfx::RectToSkRect(clip), cc::PaintFlags());
    canvas->Save();
    canvas->ClipRect(clip);
    canvas->DrawStringRectWithFlags(
        host, font, color,
        gfx::Rect(x0 + available - text_w, top, text_w, font.GetHeight()),
        gfx::Canvas::NO_ELLIPSIS);
    canvas->Restore();
    const float fade = m::url_field::kLongHostFade;
    const SkPoint points[2] = {SkPoint::Make(x0, 0),
                               SkPoint::Make(x0 + fade, 0)};
    const SkColor4f colors[2] = {SkColors::kTransparent, SkColors::kBlack};
    cc::PaintFlags mask;
    mask.setShader(cc::PaintShader::MakeLinearGradient(
        points, colors, nullptr, 2, SkTileMode::kClamp));
    mask.setBlendMode(SkBlendMode::kDstIn);
    canvas->DrawRect(gfx::RectF(clip), mask);
    sk->restore();
  }

  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    SchedulePaint();
  }
  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    SchedulePaint();
  }
  bool OnMousePressed(const ui::MouseEvent& event) override {
    return event.IsOnlyLeftMouseButton();
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton() || !HitTestPoint(event.location())) {
      return;
    }
    sidebar_->context_->Send(OpenIntent::CommandBar(
        CommandBarSource::kUrlField, GetBoundsInScreen()));
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kUrlField;
    target.space_id = sidebar_->context_->FocusedSpaceId();
    if (const Tab* tab = ActiveTab()) {
      target.node_id = tab->id;
    }
    sidebar_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

 private:
  // guess: the host keeps room for about six characters before pinned
  // extension buttons start to hide.
  static constexpr int kMinTextWidth = 48;

  // Pill-local x where the text starts: the host at sidebar x 20, or the
  // placeholder at sidebar x 41, right of the magnifier [14, 52, 24, 24].
  static int TextLeft(bool page) {
    return static_cast<int>((page ? m::url_field::kHostX
                                  : m::url_field::kPlaceholderX) -
                            m::url_field::kInsetX + 1);
  }
  // Pill-local x where the text must end: the trailing inset, or the gap
  // before the leftmost visible accessory.
  int TextRight() const {
    int right = width() - static_cast<int>(m::url_field::kTextTrailingInset);
    for (const views::View* child : children()) {
      if (child->GetVisible()) {
        right = std::min(
            right,
            child->x() - static_cast<int>(m::url_field::kControlsTextGap));
      }
    }
    return right;
  }

  const Tab* ActiveTab() const {
    return sidebar_->context_->controller()->GetActiveTab(
        sidebar_->context_->window_id());
  }
  void OnSiteControlsPressed() {
    OpenIntent intent = OpenIntent::Of(OpenIntentKind::kShowSiteControls);
    intent.anchor_in_screen = site_->GetBoundsInScreen();
    sidebar_->context_->Send(intent);
  }
  void OnExtensionPressed(const std::string& id, size_t index) {
    OpenIntent intent = OpenIntent::Of(OpenIntentKind::kRunToolbarAction);
    intent.text = id;
    if (index < extensions_.size()) {
      intent.anchor_in_screen = extensions_[index]->GetBoundsInScreen();
    } else {
      intent.anchor_in_screen = GetBoundsInScreen();
    }
    sidebar_->context_->Send(intent);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  raw_ptr<ToolbarButton> copy_ = nullptr;
  raw_ptr<ToolbarButton> site_ = nullptr;
  std::vector<raw_ptr<ToolbarButton>> extensions_;
  bool hovered_ = false;
  bool controls_visible_ = false;
};

BEGIN_METADATA(OpenSidebarView, UrlPillView)
END_METADATA

// ---------------------------------------------------------------------------
// Favorites: balanced 3..4 column grid of 47 pt tiles from y 82.

class OpenSidebarView::FavoriteTileView : public views::View,
                                          public views::ContextMenuController,
                                          public views::DragController {
  METADATA_HEADER(FavoriteTileView, views::View)

 public:
  FavoriteTileView(OpenSidebarView* sidebar, const ItemID& tab_id)
      : sidebar_(sidebar), tab_id_(tab_id) {
    set_context_menu_controller(this);
    set_drag_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kButton);
  }

  const ItemID& tab_id() const { return tab_id_; }

  void Refresh() {
    if (const Tab* tab = FavoriteTab()) {
      GetViewAccessibility().SetName(base::UTF8ToUTF16(tab->display_title()));
    }
    SchedulePaint();
  }

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override { PaintTile(canvas, false); }

  std::u16string GetRenderedTooltipText(const gfx::Point& p) const override {
    const Tab* tab = FavoriteTab();
    return tab ? base::UTF8ToUTF16(tab->display_title()) : std::u16string();
  }
  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    SchedulePaint();
  }
  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    SchedulePaint();
  }
  bool OnMousePressed(const ui::MouseEvent& event) override {
    return event.IsOnlyLeftMouseButton();
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (event.IsOnlyLeftMouseButton() && HitTestPoint(event.location())) {
      sidebar_->context_->Send(
          OpenIntent::ForNode(OpenIntentKind::kSelectFavorite, tab_id_));
    }
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kFavorite;
    target.node_id = tab_id_;
    if (const Profile* p = sidebar_->focused_profile()) {
      target.profile_id = p->id;
    }
    sidebar_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

  // views::DragController:
  void WriteDragDataForView(views::View* sender,
                            const gfx::Point& press_pt,
                            ui::OSExchangeData* data) override {
    const Tab* tab = FavoriteTab();
    sidebar_dnd::WriteNode(data, tab_id_, tab ? tab->url : std::string(),
                           tab ? base::UTF8ToUTF16(tab->display_title())
                               : std::u16string());
    const float scale = DeviceScale(this);
    gfx::Canvas canvas(size(), scale, false);
    PaintTile(&canvas, true);
    data->provider().SetDragImage(
        gfx::ImageSkia(gfx::ImageSkiaRep(canvas.GetBitmap(), scale)),
        press_pt.OffsetFromOrigin());
  }
  int GetDragOperationsForView(views::View* sender,
                               const gfx::Point& p) override {
    return ui::DragDropTypes::DRAG_MOVE | ui::DragDropTypes::DRAG_COPY |
           ui::DragDropTypes::DRAG_LINK;
  }
  bool CanStartDragForView(views::View* sender,
                           const gfx::Point& press_pt,
                           const gfx::Point& p) override {
    return views::View::ExceededDragThreshold(p - press_pt);
  }

 private:
  const Tab* FavoriteTab() const {
    const Profile* profile = sidebar_->focused_profile();
    if (!profile) {
      return nullptr;
    }
    for (const Tab& t : profile->favorites) {
      if (t.id == tab_id_) {
        return &t;
      }
    }
    return nullptr;
  }

  void PaintTile(gfx::Canvas* canvas, bool for_drag) {
    OpenSidebarContext* ctx = sidebar_->context_;
    const OpenSpaceThemeState& s = ctx->ThemeStateFor(ctx->FocusedSpaceId());
    const gfx::RectF bounds(GetLocalBounds());
    const Tab* active =
        ctx->controller()->GetActiveTab(ctx->window_id());
    const bool selected = active && active->id == tab_id_;
    Rgba fill = s.roles.tile_fill;
    if (selected || for_drag) {
      fill = s.roles.active_plate;
      // Light content: the selected card lifts with the row shadow; dark
      // content keeps the borderless frosted plate.
      if (!IsDark(s)) {
        DrawSelectionShadow(canvas, bounds, m::favorites::kCornerRadius, 1.0f);
      }
    } else if (hovered_) {
      fill = TileHover(s);
    }
    FillRoundRect(canvas, bounds, m::favorites::kCornerRadius, Sk(fill));
    const Tab* tab = FavoriteTab();
    if (!tab) {
      return;
    }
    const std::u16string* subtitle = sidebar_->FavoriteSubtitle(tab_id_);
    const float ink = m::favorites::kIconInkSize;
    // With a Live Calendar countdown the icon moves up (0.40 of the tile)
    // and the plate sits under it (FavoritesView.swift; guess, capture
    // pending).
    const float icon_cy =
        subtitle ? bounds.height() * 0.40f : bounds.CenterPoint().y();
    const gfx::RectF icon(bounds.CenterPoint().x() - ink / 2, icon_cy - ink / 2,
                          ink, ink);
    const gfx::ImageSkia image = ctx->FaviconFor(*tab);
    if (!image.isNull()) {
      const gfx::Rect r = gfx::ToEnclosingRect(icon);
      canvas->DrawImageInt(image, 0, 0, image.width(), image.height(), r.x(),
                           r.y(), r.width(), r.height(), true);
    } else {
      glyphs::DrawLetterTile(canvas, icon, DisplayHost(tab->url),
                             Sk(s.roles.title, 0.15f), Sk(s.roles.title));
    }
    if (subtitle && !for_drag) {
      PaintSubtitle(canvas, *subtitle, selected, IsDark(s));
    }
    const std::u16string* badge = sidebar_->FavoriteBadge(tab_id_);
    if (badge && !hovered_ && !for_drag) {
      PaintBadge(canvas, *badge, s);
    } else if (tab->live_state.is_audible && !tab->is_muted) {
      glyphs::Draw(canvas, glyphs::Glyph::kSpeaker,
                   gfx::RectF(bounds.right() - 18, 3, 15, 11),
                   Sk(s.roles.title, 0.6f));
    }
  }

  // LiveCalendarSubtitleView: 13 pt capsule, 9.5 pt semibold digits (9 here),
  // 4 pt above the bottom; selected white 0.90 / ink #212121, else black or
  // white 0.07.
  void PaintSubtitle(gfx::Canvas* canvas,
                     const std::u16string& text,
                     bool selected,
                     bool dark) {
    const gfx::FontList& font =
        typography::Make(9, gfx::Font::Weight::SEMIBOLD);
    const float w = gfx::Canvas::GetStringWidth(text, font) + 10.0f;
    const float h = 13;
    const gfx::RectF plate((width() - w) / 2, height() - h - 4, w, h);
    Rgba fill, ink;
    if (selected) {
      fill = Rgba{0.963, 0.976, 0.996, 0.90};
      ink = Rgba{0.13, 0.13, 0.13, 1};
    } else if (dark) {
      fill = Rgba::White(0.07);
      ink = Rgba{0.87, 0.89, 0.92, 0.70};
    } else {
      fill = Rgba::Black(0.07);
      ink = Rgba{0.13, 0.13, 0.13, 1};
    }
    FillRoundRect(canvas, plate, h / 2, Sk(fill));
    canvas->DrawStringRectWithFlags(text, font, Sk(ink),
                                    gfx::ToEnclosingRect(plate),
                                    gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  // FavoriteBadgeView: a 14 pt capsule at the top-right, inset 3 pt, white
  // 9 pt bold digits. The app badge fills are Wave B's (guess: the Space's
  // contrast accent until then).
  void PaintBadge(gfx::Canvas* canvas,
                  const std::u16string& text,
                  const OpenSpaceThemeState& s) {
    const gfx::FontList& font = typography::Make(9, gfx::Font::Weight::BOLD);
    const float h = 14;
    const float w =
        std::max(h, static_cast<float>(gfx::Canvas::GetStringWidth(text, font)) + 8);
    const gfx::RectF plate(width() - w - 3, 3, w, h);
    FillRoundRect(canvas, plate, h / 2, Sk(s.contrast_accent));
    canvas->DrawStringRectWithFlags(text, font, SK_ColorWHITE,
                                    gfx::ToEnclosingRect(plate),
                                    gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  ItemID tab_id_;
  bool hovered_ = false;
};

BEGIN_METADATA(OpenSidebarView, FavoriteTileView)
END_METADATA

// "Drag to add Favorites" (FavoritesEmptyStateView.swift, measured A3 /
// C-report-s10): [7, 7, W - 14, 95], radius 12, dashed 5/5 outline, a star
// disc, title 13 Semibold, body at 0.70, an "x" at [W - 23, 9, 14, 14] in
// card coordinates. Held-over drop target: content at half, solid border.

class OpenSidebarView::FavoritesEmptyStateView : public views::View {
  METADATA_HEADER(FavoritesEmptyStateView, views::View)

 public:
  explicit FavoritesEmptyStateView(OpenSidebarView* sidebar)
      : sidebar_(sidebar) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
    GetViewAccessibility().SetName(kTitle);
    GetViewAccessibility().SetDescription(std::u16string(kBody));
  }

  void SetDropTarget(bool drop_target) {
    if (drop_target_ != drop_target) {
      drop_target_ = drop_target;
      SchedulePaint();
    }
  }

  // views::View:
  void OnPaint(gfx::Canvas* canvas) override {
    OpenSidebarContext* ctx = sidebar_->context_;
    const OpenSpaceThemeState& s = ctx->ThemeStateFor(ctx->FocusedSpaceId());
    const bool dark = IsDark(s);
    const float fade = drop_target_ ? 0.5f : 1.0f;
    const Rgba title = s.roles.title;
    // Light content: the title ink x 3.35 per channel (the bright accent).
    const Rgba disc =
        dark ? title
             : Rgba{std::min(1.0, title.r * 3.35), std::min(1.0, title.g * 3.35),
                    std::min(1.0, title.b * 3.35), 1};
    gfx::RectF card(GetLocalBounds());
    card.Inset(0.5f);
    FillRoundRect(canvas, card, 12,
                  Sk(dark ? Rgba::Black(0.12) : Rgba::White(0.14)));
    cc::PaintFlags outline;
    outline.setAntiAlias(true);
    outline.setStyle(cc::PaintFlags::kStroke_Style);
    outline.setStrokeWidth(1);
    if (drop_target_) {
      outline.setColor(Sk(Rgba::White(dark ? 0.35 : 0.55)));
    } else {
      outline.setColor(Sk(dark ? Rgba::White(0.28) : disc.WithAlpha(0.30)));
      static constexpr float kDash[2] = {5, 5};
      outline.setPathEffect(cc::PathEffect::MakeDash(kDash, 2, 0));
    }
    canvas->DrawRoundRect(card, 12, outline);

    // Star disc, 16.5 pt at the top center (card y 12.5).
    const float d = 16.5f;
    const gfx::PointF c(width() / 2.0f, 12.5f + d / 2);
    cc::PaintFlags disc_fill;
    disc_fill.setAntiAlias(true);
    disc_fill.setColor(Sk(disc, fade));
    canvas->DrawCircle(c, d / 2, disc_fill);
    SkPathBuilder star;
    for (int i = 0; i < 10; ++i) {
      const float r = (i % 2 == 0) ? 5.2f : 2.2f;
      const float a = static_cast<float>(-std::numbers::pi / 2 + i * std::numbers::pi / 5);
      const SkPoint p = SkPoint::Make(c.x() + r * std::cos(a),
                                      c.y() + r * std::sin(a));
      i == 0 ? star.moveTo(p) : star.lineTo(p);
    }
    star.close();
    cc::PaintFlags star_fill;
    star_fill.setAntiAlias(true);
    star_fill.setColor(
        Sk(dark ? Rgba::Hex(0x262471) : Rgba::White(1), fade));
    canvas->DrawPath(star.detach(), star_fill);

    const gfx::FontList& title_font =
        typography::Make(13, gfx::Font::Weight::SEMIBOLD);
    canvas->DrawStringRectWithFlags(
        kTitle, title_font, Sk(title, fade),
        gfx::Rect(11, 34, std::max(0, width() - 22), 17),
        gfx::Canvas::TEXT_ALIGN_CENTER);
    const gfx::FontList& body_font =
        typography::Make(12, gfx::Font::Weight::NORMAL);
    const int body_w = std::min(150, std::max(0, width() - 22));
    canvas->DrawStringRectWithFlags(
        std::u16string(kBody), body_font, Sk(title, 0.70f * fade),
        gfx::Rect((width() - body_w) / 2, 54, body_w, 32),
        gfx::Canvas::TEXT_ALIGN_CENTER | gfx::Canvas::MULTI_LINE);

    const gfx::RectF dismiss = DismissRect();
    if (dismiss_hovered_) {
      cc::PaintFlags plate;
      plate.setAntiAlias(true);
      plate.setColor(Sk(dark ? Rgba::White(0.12) : Rgba::Black(0.06)));
      canvas->DrawCircle(dismiss.CenterPoint(), dismiss.width() / 2, plate);
    }
    cc::PaintFlags x;
    x.setAntiAlias(true);
    x.setStyle(cc::PaintFlags::kStroke_Style);
    x.setStrokeWidth(1.4f);
    x.setStrokeCap(cc::PaintFlags::kRound_Cap);
    x.setColor(Sk(title, 0.70f * fade));
    gfx::RectF ink = dismiss;
    ink.Inset(4.0f);
    canvas->DrawLine(ink.origin(), ink.bottom_right(), x);
    canvas->DrawLine(ink.top_right(), ink.bottom_left(), x);
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    const bool over = DismissRect().Contains(gfx::PointF(event.location()));
    if (over != dismiss_hovered_) {
      dismiss_hovered_ = over;
      SchedulePaint();
    }
  }
  void OnMouseExited(const ui::MouseEvent& event) override {
    if (dismiss_hovered_) {
      dismiss_hovered_ = false;
      SchedulePaint();
    }
  }
  bool OnMousePressed(const ui::MouseEvent& event) override {
    return event.IsOnlyLeftMouseButton() &&
           DismissRect().Contains(gfx::PointF(event.location()));
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (event.IsOnlyLeftMouseButton() &&
        DismissRect().Contains(gfx::PointF(event.location()))) {
      sidebar_->DismissFavoritesEmptyState();
    }
  }

 private:
  static constexpr char16_t kTitle[] = u"Drag to add Favorites";
  static constexpr char16_t kBody[] =
      u"Favorites keep your most used sites and apps close";

  gfx::RectF DismissRect() const {
    return gfx::RectF(width() - 23, 9, 14, 14);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  bool drop_target_ = false;
  bool dismiss_hovered_ = false;
};

BEGIN_METADATA(OpenSidebarView, FavoritesEmptyStateView)
END_METADATA

class OpenSidebarView::FavoritesView : public views::View {
  METADATA_HEADER(FavoritesView, views::View)

 public:
  explicit FavoritesView(OpenSidebarView* sidebar) : sidebar_(sidebar) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
    GetViewAccessibility().SetName(u"Favorites");
    empty_card_ = AddChildView(
        std::make_unique<FavoritesEmptyStateView>(sidebar));
    empty_card_->SetVisible(false);
  }

  void SyncEmptyCard() {
    const bool visible = sidebar_->IsFavoritesEmptyStateVisible();
    if (empty_card_->GetVisible() != visible) {
      empty_card_->SetVisible(visible);
      InvalidateLayout();
    }
    empty_card_->SchedulePaint();
  }

  int count() const { return static_cast<int>(tiles_.size()); }

  void Rebuild() {
    const Profile* profile = sidebar_->focused_profile();
    std::vector<ItemID> ids;
    if (profile) {
      for (const Tab& t : profile->favorites) {
        ids.push_back(t.id);
      }
    }
    // Keyed reuse, like the tree.
    std::map<ItemID, raw_ptr<FavoriteTileView>> next;
    for (const ItemID& id : ids) {
      auto it = by_id_.find(id);
      if (it != by_id_.end()) {
        next.emplace(id, it->second);
        by_id_.erase(it);
      } else {
        next.emplace(id, AddChildView(
                             std::make_unique<FavoriteTileView>(sidebar_, id)));
      }
    }
    for (auto& [id, tile] : by_id_) {
      FavoriteTileView* t = tile;
      tile = nullptr;
      RemoveChildViewT(t);
    }
    by_id_ = std::move(next);
    tiles_.clear();
    for (size_t i = 0; i < ids.size(); ++i) {
      FavoriteTileView* tile = by_id_[ids[i]];
      ReorderChildView(tile, i);
      tile->Refresh();
      tiles_.push_back(tile);
    }
    SyncEmptyCard();
    PreferredSizeChanged();
    InvalidateLayout();
  }

  void RefreshTiles() {
    for (FavoriteTileView* t : tiles_) {
      t->SchedulePaint();
    }
    empty_card_->SchedulePaint();
  }

  void RefreshTile(const ItemID& id) {
    if (auto it = by_id_.find(id); it != by_id_.end()) {
      it->second->SchedulePaint();
    }
  }

  float SectionHeight(float sidebar_width) const {
    return m::favorites::SectionHeight(count(), sidebar_width);
  }

  // views::View:
  void Layout(PassKey) override {
    const float w = width();
    const int n = count();
    if (empty_card_->GetVisible()) {
      const m::Frame f = m::favorites::EmptyCardFrame(w);
      empty_card_->SetBoundsRect(ToRect(f));
    }
    if (n == 0) {
      return;
    }
    const int cols = m::favorites::Columns(n, w);
    const float tile_w = m::favorites::TileWidth(w, cols);
    for (int i = 0; i < n; ++i) {
      const int row = i / cols, col = i % cols;
      const float x = m::favorites::kInset + col * (tile_w + m::favorites::kColumnGap);
      const float y = m::favorites::kInset +
                      row * (m::favorites::kTileHeight + m::favorites::kRowGap);
      tiles_[static_cast<size_t>(i)]->SetBoundsRect(gfx::ToEnclosingRect(
          gfx::RectF(x, y, tile_w, m::favorites::kTileHeight)));
    }
  }

  void PaintChildren(const views::PaintInfo& info) override {
    views::View::PaintChildren(info);
    // The empty-state card shows the drop target itself.
    if (drop_index_ < 0 || empty_card_->GetVisible()) {
      return;
    }
    ui::PaintRecorder recorder(info.context(), size());
    const OpenSpaceThemeState& s =
        sidebar_->context_->ThemeStateFor(sidebar_->context_->FocusedSpaceId());
    const gfx::RectF r = InsertionRect(drop_index_);
    FillRoundRect(recorder.canvas(), r, 1,
                  Sk(IsDark(s) ? Rgba::White(0.5) : Rgba::Black(0.5)));
  }

  // Drop target: tabs from the tree (add) or tiles (reorder).
  bool GetDropFormats(int* formats,
                      std::set<ui::ClipboardFormatType>* format_types) override {
    *formats = 0;
    format_types->insert(sidebar_dnd::NodeFormat());
    return true;
  }
  bool CanDrop(const ui::OSExchangeData& data) override {
    return data.HasCustomFormat(sidebar_dnd::NodeFormat());
  }
  int OnDragUpdated(const ui::DropTargetEvent& event) override {
    const std::optional<ItemID> id = sidebar_dnd::ReadNode(event.data());
    if (!id) {
      return ui::DragDropTypes::DRAG_NONE;
    }
    // Folders and splits are refused (model rule).
    const SidebarNode* node = sidebar_->context_->controller()->FindNode(*id);
    if (node && !node->as_tab()) {
      drop_index_ = -1;
      SchedulePaint();
      return ui::DragDropTypes::DRAG_NONE;
    }
    drop_index_ = IndexAt(event.location());
    empty_card_->SetDropTarget(true);
    SchedulePaint();
    return ui::DragDropTypes::DRAG_MOVE;
  }
  void OnDragExited() override {
    drop_index_ = -1;
    empty_card_->SetDropTarget(false);
    SchedulePaint();
  }
  views::View::DropCallback GetDropCallback(
      const ui::DropTargetEvent& event) override {
    const std::optional<ItemID> id = sidebar_dnd::ReadNode(event.data());
    const int index = drop_index_;
    drop_index_ = -1;
    empty_card_->SetDropTarget(false);
    SchedulePaint();
    if (!id || index < 0) {
      return base::NullCallback();
    }
    return base::BindOnce(&FavoritesView::PerformDrop,
                          weak_factory_.GetWeakPtr(), *id, index);
  }

 private:
  void PerformDrop(const ItemID& id,
                   int index,
                   const ui::DropTargetEvent& event,
                   ui::mojom::DragOperation& output_drag_op,
                   std::unique_ptr<ui::LayerTreeOwner> drag_image_layer_owner) {
    const bool is_favorite = by_id_.contains(id);
    size_t target = static_cast<size_t>(index);
    if (is_favorite) {
      // Same-list downward move: the model counts after removal.
      for (size_t i = 0; i < tiles_.size(); ++i) {
        if (tiles_[i]->tab_id() == id && i < target) {
          --target;
          break;
        }
      }
    }
    OpenIntent intent = OpenIntent::ForNode(
        is_favorite ? OpenIntentKind::kMoveFavorite : OpenIntentKind::kAddFavorite,
        id);
    intent.index = target;
    sidebar_->context_->Send(intent);
    output_drag_op = ui::mojom::DragOperation::kMove;
  }

  int IndexAt(const gfx::Point& p) const {
    const int n = count();
    if (n == 0) {
      return 0;
    }
    for (int i = 0; i < n; ++i) {
      const gfx::Rect r = tiles_[static_cast<size_t>(i)]->bounds();
      if (p.y() < r.bottom() + m::favorites::kRowGap / 2 &&
          p.x() < r.CenterPoint().x() && p.y() >= r.y() - m::favorites::kRowGap / 2) {
        return i;
      }
      if (p.y() < r.y() - m::favorites::kRowGap / 2) {
        return i;
      }
    }
    return n;
  }

  gfx::RectF InsertionRect(int index) const {
    const int n = count();
    if (n == 0) {
      return gfx::RectF(m::favorites::kInset, 2, width() - 2 * m::favorites::kInset,
                        2);
    }
    const bool after = index >= n;
    const gfx::Rect r =
        tiles_[static_cast<size_t>(after ? n - 1 : index)]->bounds();
    const float x = after ? r.right() + m::favorites::kColumnGap / 2
                          : r.x() - m::favorites::kColumnGap / 2;
    return gfx::RectF(x - 1, r.y() + 6, 2, r.height() - 12);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  raw_ptr<FavoritesEmptyStateView> empty_card_ = nullptr;
  std::map<ItemID, raw_ptr<FavoriteTileView>> by_id_;
  std::vector<raw_ptr<FavoriteTileView>> tiles_;
  int drop_index_ = -1;
  base::WeakPtrFactory<FavoritesView> weak_factory_{this};
};

BEGIN_METADATA(OpenSidebarView, FavoritesView)
END_METADATA

// ---------------------------------------------------------------------------
// Space switcher strip [42, 0, W - 84, 50]: items 36 x 34 at pitch 34, y 8,
// centered when they fit, else scrolled with 28 pt edge fades.

class OpenSidebarView::SwitcherStripView : public views::View,
                                           public views::ContextMenuController {
  METADATA_HEADER(SwitcherStripView, views::View)

 public:
  explicit SwitcherStripView(OpenSidebarView* sidebar) : sidebar_(sidebar) {
    set_context_menu_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kTabList);
    GetViewAccessibility().SetName(u"Spaces");
    reveal_ = std::make_unique<motion::OpenSpringAnimator>(
        motion::SpringToken{m::bottom_bar::kSwitcherRevealDuration, 1.0},
        base::BindRepeating(
            [](SwitcherStripView* self, double v) {
              self->scroll_x_ = static_cast<float>(v);
              self->SchedulePaint();
            },
            base::Unretained(this)));
  }

  void Refresh() {
    spaces_ = sidebar_->context_->controller()->GetWindowSpaceIds(
        sidebar_->context_->window_id());
    RevealFocused(false);
    SchedulePaint();
  }

  void RevealFocused(bool animate) {
    const float content = ContentWidth();
    const float w = width();
    if (content <= w) {
      scroll_x_ = 0;
      return;
    }
    const int index = IndexOf(sidebar_->context_->FocusedSpaceId());
    if (index < 0) {
      return;
    }
    const float fade = m::bottom_bar::kSwitcherFadeWidth;
    const float item_x = index * m::bottom_bar::kSwitcherPitch;
    float target = scroll_x_;
    if (item_x - target < fade) {
      target = item_x - fade;
    } else if (item_x + m::bottom_bar::kSwitcherItemSize.w - target > w - fade) {
      target = item_x + m::bottom_bar::kSwitcherItemSize.w - (w - fade);
    }
    target = std::clamp(target, 0.0f, content - w);
    if (animate && GetWidget()) {
      reveal_->SetCompositor(GetWidget()->GetCompositor());
      reveal_->AnimateFromTo(scroll_x_, target);
    } else {
      reveal_->JumpTo(target);
    }
  }

  // views::View:
  void RemovedFromWidget() override {
    // The widget's compositor may die after this view leaves it.
    reveal_->SetCompositor(nullptr);
  }

  void OnPaint(gfx::Canvas* canvas) override {
    OpenSidebarContext* ctx = sidebar_->context_;
    const OpenSpaceThemeState& focused = ctx->ThemeStateFor(ctx->FocusedSpaceId());
    const float w = width();
    if (w <= 0.0f) {
      return;
    }
    const float content = ContentWidth();
    const bool fits = content <= w;
    const float x0 = fits ? (w - content) / 2 - 1 : -1 - scroll_x_;
    cc::PaintCanvas* sk = canvas->sk_canvas();
    const bool fade_left = !fits && scroll_x_ > 0.5f;
    const bool fade_right = !fits && scroll_x_ < content - w - 0.5f;
    if (fade_left || fade_right) {
      sk->saveLayer(gfx::RectToSkRect(GetLocalBounds()), cc::PaintFlags());
    }
    const SpaceID focused_id = ctx->FocusedSpaceId();
    for (size_t i = 0; i < spaces_.size(); ++i) {
      const Space* space = ctx->controller()->GetSpace(spaces_[static_cast<size_t>(i)]);
      if (!space) {
        continue;
      }
      const gfx::RectF item(x0 + i * m::bottom_bar::kSwitcherPitch,
                            m::bottom_bar::kSwitcherItemY,
                            m::bottom_bar::kSwitcherItemSize.w,
                            m::bottom_bar::kSwitcherItemSize.h);
      if (item.right() < 0 || item.x() > w) {
        continue;
      }
      gfx::RectF plate = item;
      plate.Inset(gfx::InsetsF::VH(m::bottom_bar::kSwitcherPlateInset.h,
                                   m::bottom_bar::kSwitcherPlateInset.w));
      if (static_cast<int>(i) == hovered_) {
        FillRoundRect(canvas, plate, m::bottom_bar::kPlateRadius,
                      Sk(pressed_ ? ButtonPressed(focused) : ButtonHover(focused)));
      }
      const bool current = space->id == focused_id;
      // Current Space in color, others gray at 0.55 (F0001).
      glyphs::DrawSpaceIcon(
          canvas, space->icon ? &*space->icon : nullptr,
          base::UTF8ToUTF16(space->title.value_or(std::string())), plate,
          typography::Get(OpenFont::kSwitcherEmoji),
          Sk(current ? focused.roles.title : focused.roles.bottom_glyph),
          current ? 1.0f : m::bottom_bar::kInactiveIconOpacity, !current);
    }
    if ((fade_left || fade_right) && w > 0.0f) {
      const float fade = std::min(m::bottom_bar::kSwitcherFadeWidth, w * 0.5f);
      const float stop = fade / w;
      const SkPoint points[4] = {SkPoint::Make(0, 0), SkPoint::Make(fade, 0),
                                 SkPoint::Make(w - fade, 0), SkPoint::Make(w, 0)};
      const SkColor4f colors[4] = {
          fade_left ? SkColors::kTransparent : SkColors::kBlack, SkColors::kBlack,
          SkColors::kBlack, fade_right ? SkColors::kTransparent : SkColors::kBlack};
      const SkScalar pos[4] = {0, stop, 1.0f - stop, 1.0f};
      cc::PaintFlags mask;
      mask.setShader(cc::PaintShader::MakeLinearGradient(points, colors, pos, 4,
                                                         SkTileMode::kClamp));
      mask.setBlendMode(SkBlendMode::kDstIn);
      canvas->DrawRect(gfx::RectF(GetLocalBounds()), mask);
      sk->restore();
    }
  }

  std::u16string GetRenderedTooltipText(const gfx::Point& p) const override {
    const int i = IndexAt(p);
    if (i < 0) {
      return std::u16string();
    }
    const Space* space = sidebar_->context_->controller()->GetSpace(spaces_[static_cast<size_t>(i)]);
    return space ? base::UTF8ToUTF16(space->title.value_or("Space"))
                 : std::u16string();
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    SetHovered(IndexAt(event.location()));
  }
  void OnMouseExited(const ui::MouseEvent& event) override { SetHovered(-1); }
  bool OnMousePressed(const ui::MouseEvent& event) override {
    pressed_ = event.IsOnlyLeftMouseButton() && IndexAt(event.location()) >= 0;
    SchedulePaint();
    return pressed_;
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    const int i = IndexAt(event.location());
    const bool was_pressed = pressed_;
    pressed_ = false;
    SchedulePaint();
    if (was_pressed && i >= 0) {
      sidebar_->context_->Send(
          OpenIntent::ForSpace(OpenIntentKind::kSwitchSpace, spaces_[static_cast<size_t>(i)]));
    }
  }
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override {
    const float content = ContentWidth();
    if (content <= width()) {
      return false;
    }
    const float delta = event.x_offset() != 0 ? -event.x_offset() : -event.y_offset();
    reveal_->JumpTo(std::clamp(scroll_x_ + delta / 3, 0.0f, content - width()));
    return true;
  }

  // Drop a tab on a Space icon: move it to that Space's Today.
  bool GetDropFormats(int* formats,
                      std::set<ui::ClipboardFormatType>* format_types) override {
    *formats = 0;
    format_types->insert(sidebar_dnd::NodeFormat());
    return true;
  }
  bool CanDrop(const ui::OSExchangeData& data) override {
    return data.HasCustomFormat(sidebar_dnd::NodeFormat());
  }
  int OnDragUpdated(const ui::DropTargetEvent& event) override {
    SetHovered(IndexAt(event.location()));
    return hovered_ >= 0 ? ui::DragDropTypes::DRAG_MOVE
                         : ui::DragDropTypes::DRAG_NONE;
  }
  void OnDragExited() override { SetHovered(-1); }
  views::View::DropCallback GetDropCallback(
      const ui::DropTargetEvent& event) override {
    const std::optional<ItemID> id = sidebar_dnd::ReadNode(event.data());
    const int i = IndexAt(event.location());
    SetHovered(-1);
    if (!id || i < 0) {
      return base::NullCallback();
    }
    const SpaceID space = spaces_[static_cast<size_t>(i)];
    return base::BindOnce(
        [](OpenSidebarContext* ctx, ItemID node, SpaceID space_id,
           const ui::DropTargetEvent&, ui::mojom::DragOperation& op,
           std::unique_ptr<ui::LayerTreeOwner>) {
          ctx->Send(OpenIntent::Move(
              node, NodeParent{NodeParentKind::kSpaceToday, space_id}, 0));
          op = ui::mojom::DragOperation::kMove;
        },
        base::Unretained(sidebar_->context_.get()), *id, space);
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    gfx::Point local = point;
    views::View::ConvertPointFromScreen(this, &local);
    const int i = IndexAt(local);
    if (i < 0) {
      return;
    }
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kSwitcherItem;
    target.space_id = spaces_[static_cast<size_t>(i)];
    sidebar_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

 private:
  float ContentWidth() const {
    return spaces_.size() * m::bottom_bar::kSwitcherPitch + 2;
  }
  int IndexOf(const SpaceID& id) const {
    auto it = std::find(spaces_.begin(), spaces_.end(), id);
    return it == spaces_.end() ? -1 : static_cast<int>(it - spaces_.begin());
  }
  int IndexAt(const gfx::Point& p) const {
    const float w = width();
    const float content = ContentWidth();
    const float x0 = content <= w ? (w - content) / 2 - 1 : -1 - scroll_x_;
    if (p.y() < m::bottom_bar::kSwitcherItemY ||
        p.y() >= m::bottom_bar::kSwitcherItemY + m::bottom_bar::kSwitcherItemSize.h) {
      return -1;
    }
    const float rel = p.x() - x0 - 1;
    if (rel < 0) {
      return -1;
    }
    const int i = static_cast<int>(rel / m::bottom_bar::kSwitcherPitch);
    return i < static_cast<int>(spaces_.size()) ? i : -1;
  }
  void SetHovered(int i) {
    if (i != hovered_) {
      hovered_ = i;
      SchedulePaint();
    }
  }

  raw_ptr<OpenSidebarView> sidebar_;
  std::vector<SpaceID> spaces_;
  int hovered_ = -1;
  bool pressed_ = false;
  float scroll_x_ = 0;
  std::unique_ptr<motion::OpenSpringAnimator> reveal_;
};

BEGIN_METADATA(OpenSidebarView, SwitcherStripView)
END_METADATA

// ---------------------------------------------------------------------------
// BottomBarView: 50 pt.

class OpenSidebarView::BottomBarView : public views::View,
                                       public views::ContextMenuController {
  METADATA_HEADER(BottomBarView, views::View)

 public:
  explicit BottomBarView(OpenSidebarView* sidebar) : sidebar_(sidebar) {
    OpenSidebarContext* ctx = sidebar->context_;
    SetProperty(kOpenWindowDragKey, true);
    home_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(
            [](OpenSidebarContext* c) {
              c->Send(OpenIntent::Of(OpenIntentKind::kShowLibrary));
            },
            base::Unretained(ctx)),
        glyphs::Glyph::kLibrary, u"Library", ToolbarButton::Role::kBottom));
    // Right-click: Library media sources (OpenMenuTarget::Kind::kLibrary).
    home_->set_context_menu_controller(this);
    strip_ = AddChildView(std::make_unique<SwitcherStripView>(sidebar));
    plus_ = AddChildView(std::make_unique<ToolbarButton>(
        ctx,
        base::BindRepeating(&BottomBarView::OnPlusPressed,
                            base::Unretained(this)),
        glyphs::Glyph::kBottomPlus, u"New…", ToolbarButton::Role::kBottom));
  }

  SwitcherStripView* strip() const { return strip_; }
  ToolbarButton* home() const { return home_; }

  // Incognito: no Library and no Space switcher; "+" opens a new tab.
  void SetIncognito(bool incognito) {
    if (incognito_ == incognito) {
      return;
    }
    incognito_ = incognito;
    home_->SetVisible(!incognito);
    strip_->SetVisible(!incognito);
    plus_->SetTooltipText(incognito ? u"New Tab" : u"New…");
    plus_->GetViewAccessibility().SetName(incognito ? u"New Tab" : u"New…");
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kLibrary;
    target.space_id = sidebar_->context_->FocusedSpaceId();
    sidebar_->context_->ShowSidebarMenu(target, home_, point, source_type);
  }

  void Refresh() {
    strip_->Refresh();
    SchedulePaint();
    for (views::View* child : children()) {
      child->SchedulePaint();
    }
  }

  void SetDimmed(bool dimmed) {
    home_->SetDimmedLook(dimmed);
    plus_->SetDimmedLook(dimmed);
  }

  // views::View:
  void Layout(PassKey) override {
    const float w = width();
    home_->SetBoundsRect(ToRect(m::bottom_bar::Home()));
    plus_->SetBoundsRect(ToRect(m::bottom_bar::Plus(w)));
    strip_->SetBoundsRect(ToRect(m::bottom_bar::Switcher(w)));
  }

 private:
  void OnPlusPressed() {
    if (incognito_) {
      sidebar_->context_->Send(OpenIntent::CommandBar(
          CommandBarSource::kPlusButton, plus_->GetBoundsInScreen()));
      return;
    }
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kPlusButton;
    target.space_id = sidebar_->context_->FocusedSpaceId();
    const gfx::Rect b = plus_->GetBoundsInScreen();
    sidebar_->context_->ShowSidebarMenu(target, plus_, b.top_center(),
                                        ui::mojom::MenuSourceType::kMouse);
  }

  raw_ptr<OpenSidebarView> sidebar_;
  raw_ptr<ToolbarButton> home_ = nullptr;
  raw_ptr<SwitcherStripView> strip_ = nullptr;
  raw_ptr<ToolbarButton> plus_ = nullptr;
  bool incognito_ = false;
};

BEGIN_METADATA(OpenSidebarView, BottomBarView)
END_METADATA

// ---------------------------------------------------------------------------
// OpenSidebarView

OpenSidebarView::OpenSidebarView(OpenSidebarContext* context)
    : context_(context) {
  SetNotifyEnterExitOnChild(true);
  GetViewAccessibility().SetRole(ax::mojom::Role::kNavigation);
  GetViewAccessibility().SetName(u"Sidebar");
  toolbar_ = AddChildView(std::make_unique<ToolbarView>(this));
  toolbar_->SetPaintToLayer();
  toolbar_->layer()->SetFillsBoundsOpaquely(false);
  url_pill_ = AddChildView(std::make_unique<UrlPillView>(this));
  favorites_ = AddChildView(std::make_unique<FavoritesView>(this));
  pager_ = AddChildView(std::make_unique<OpenSpacePagerView>(context));
  bottom_bar_ = AddChildView(std::make_unique<BottomBarView>(this));
  bottom_bar_->SetPaintToLayer();
  bottom_bar_->layer()->SetFillsBoundsOpaquely(false);
  OnSpacesChanged();
  OnFavoritesChanged();
  OnActiveTabChanged();
  ApplyIncognitoChrome();
}

OpenSidebarView::~OpenSidebarView() = default;

void OpenSidebarView::SetPresentation(Presentation presentation) {
  if (presentation_ == presentation) {
    return;
  }
  presentation_ = presentation;
  SchedulePaint();
}

void OpenSidebarView::SetWindowControlsSlot(WindowControlsSlot slot) {
  toolbar_->SetWindowControls(slot);
}

const Space* OpenSidebarView::focused_space() const {
  return context_->controller()->GetSpace(context_->FocusedSpaceId());
}

const Profile* OpenSidebarView::focused_profile() const {
  const Space* space = focused_space();
  return space ? context_->controller()->GetProfile(space->profile_id) : nullptr;
}

float OpenSidebarView::favorites_section_height() const {
  // Incognito windows show no Favorites (capture C10).
  if (IsIncognito()) {
    return m::favorites::kInset;
  }
  if (IsFavoritesEmptyStateVisible()) {
    return m::favorites::kEmptyStateSectionHeight;
  }
  return favorites_->SectionHeight(static_cast<float>(width()));
}

bool OpenSidebarView::IsIncognito() const {
  return context_->controller()->IsIncognitoWindow(context_->window_id());
}

void OpenSidebarView::ApplyIncognitoChrome() {
  const bool incognito = IsIncognito();
  favorites_->SetVisible(!incognito);
  bottom_bar_->SetIncognito(incognito);
  InvalidateLayout();
}

bool OpenSidebarView::IsFavoritesEmptyStateVisible() const {
  return favorites_empty_state_enabled_ && !favorites_empty_state_dismissed_ &&
         !IsIncognito() && focused_profile() &&
         focused_profile()->favorites.empty();
}

void OpenSidebarView::SetFavoritesEmptyStateEnabled(bool enabled) {
  if (favorites_empty_state_enabled_ == enabled) {
    return;
  }
  favorites_empty_state_enabled_ = enabled;
  OnFavoritesChanged();
}

void OpenSidebarView::SetFavoritesEmptyStateDismissedCallback(
    base::RepeatingClosure callback) {
  favorites_empty_state_dismissed_callback_ = std::move(callback);
}

void OpenSidebarView::DismissFavoritesEmptyState() {
  favorites_empty_state_dismissed_ = true;
  OnFavoritesChanged();
  if (favorites_empty_state_dismissed_callback_) {
    favorites_empty_state_dismissed_callback_.Run();
  }
}

void OpenSidebarView::SetLibraryDownloadProgress(
    std::optional<double> progress) {
  bottom_bar_->home()->SetProgressRing(progress);
}

views::View* OpenSidebarView::SetMediaPlayerStack(
    std::unique_ptr<views::View> stack) {
  if (media_stack_) {
    views::View* old = media_stack_;
    media_stack_ = nullptr;
    RemoveChildViewT(old);
  }
  if (stack) {
    // Above the pager, below the bottom bar's layer.
    media_stack_ = AddChildViewAt(std::move(stack),
                                  GetIndexOf(bottom_bar_.get()).value());
  }
  InvalidateLayout();
  return media_stack_;
}

void OpenSidebarView::SetFavoriteSubtitle(const ItemID& tab_id,
                                          const std::u16string& text) {
  if (text.empty()) {
    favorite_subtitles_.erase(tab_id);
  } else {
    favorite_subtitles_[tab_id] = text;
  }
  favorites_->RefreshTile(tab_id);
}

void OpenSidebarView::SetFavoriteBadge(const ItemID& tab_id,
                                       const std::u16string& text) {
  if (text.empty()) {
    favorite_badges_.erase(tab_id);
  } else {
    favorite_badges_[tab_id] = text;
  }
  favorites_->RefreshTile(tab_id);
}

const std::u16string* OpenSidebarView::FavoriteSubtitle(
    const ItemID& tab_id) const {
  auto it = favorite_subtitles_.find(tab_id);
  return it == favorite_subtitles_.end() ? nullptr : &it->second;
}

const std::u16string* OpenSidebarView::FavoriteBadge(
    const ItemID& tab_id) const {
  auto it = favorite_badges_.find(tab_id);
  return it == favorite_badges_.end() ? nullptr : &it->second;
}

// --- Notifications -------------------------------------------------------------

void OpenSidebarView::OnTreeChanged(const TreeChange& change) {
  if (change.parent.kind == NodeParentKind::kFavorites ||
      change.to_parent.kind == NodeParentKind::kFavorites) {
    OnFavoritesChanged();
  }
  if (change.kind == TreeChange::Kind::kSpaceProfileChanged) {
    OnFavoritesChanged();
  }
  if (!change.space_id.empty()) {
    if (OpenTabTreeView* page = pager_->FindPage(change.space_id)) {
      page->ApplyTreeChange(change);
    }
    return;
  }
  pager_->ForEachPage(
      [&](OpenTabTreeView* page) { page->ApplyTreeChange(change); });
}

void OpenSidebarView::OnSpacesChanged() {
  pager_->SetSpaces(context_->controller()->GetWindowSpaceIds(
      context_->window_id()));
  pager_->ForEachPage([](OpenTabTreeView* page) { page->OnSpaceChanged(); });
  bottom_bar_->Refresh();
  ApplyIncognitoChrome();
}

void OpenSidebarView::OnSpaceThemeChanged(const SpaceID& space_id) {
  if (OpenTabTreeView* page = pager_->FindPage(space_id)) {
    page->OnSpaceThemeChanged();
  }
  if (space_id == context_->FocusedSpaceId()) {
    SchedulePaint();
    for (views::View* v : {static_cast<views::View*>(toolbar_.get()),
                           static_cast<views::View*>(url_pill_.get()),
                           static_cast<views::View*>(favorites_.get()),
                           static_cast<views::View*>(bottom_bar_.get())}) {
      v->SchedulePaint();
    }
    toolbar_->Refresh();
    favorites_->RefreshTiles();
    bottom_bar_->Refresh();
  }
}

void OpenSidebarView::OnFavoritesChanged() {
  favorites_->Rebuild();
  InvalidateLayout();
}

void OpenSidebarView::OnWindowStateChanged(bool animate) {
  const SpaceID focused = context_->FocusedSpaceId();
  const bool space_changed = pager_->shown_space_id() != focused;
  pager_->ShowSpace(focused, animate);
  pager_->ForEachPage([](OpenTabTreeView* page) { page->OnSelectionChanged(); });
  if (space_changed) {
    // A new Space may belong to another Profile (other Favorites) and
    // recolors the chrome.
    OnFavoritesChanged();
    OnSpaceThemeChanged(focused);
    bottom_bar_->strip()->RevealFocused(animate);
  }
  bottom_bar_->SchedulePaint();
  bottom_bar_->strip()->SchedulePaint();
}

void OpenSidebarView::OnTabLiveStateChanged(const ItemID& tab_id) {
  pager_->ForEachPage(
      [&](OpenTabTreeView* page) { page->OnTabLiveStateChanged(tab_id); });
  favorites_->RefreshTiles();
  const Tab* active =
      context_->controller()->GetActiveTab(context_->window_id());
  if (active && active->id == tab_id) {
    toolbar_->Refresh();
    url_pill_->Refresh();
  }
}

void OpenSidebarView::OnActiveTabChanged() {
  toolbar_->Refresh();
  url_pill_->Refresh();
  favorites_->RefreshTiles();
}

void OpenSidebarView::OnSplitViewChanged(bool active) {
  if (split_view_active_ == active) {
    return;
  }
  split_view_active_ = active;
  toolbar_->InvalidateLayout();
  toolbar_->SchedulePaint();
}

void OpenSidebarView::OnPeekChanged() {
  const std::optional<ItemID> source =
      context_->controller()->GetPeekSourceNode(context_->window_id());
  pager_->ForEachPage([&](OpenTabTreeView* page) {
    page->SetPeekSourceNode(page->space_id() == context_->FocusedSpaceId()
                                ? source
                                : std::nullopt);
  });
  SetPeekDimmed(source.has_value());
  url_pill_->Refresh();
  toolbar_->Refresh();
}

void OpenSidebarView::OnCommandBarStateChanged() {
  const bool open =
      context_->controller()->IsNewTabCommandBarOpen(context_->window_id());
  pager_->ForEachPage([&](OpenTabTreeView* page) {
    page->SetNewTabCommandBarOpen(open &&
                                  page->space_id() == context_->FocusedSpaceId());
  });
}

void OpenSidebarView::OnToolbarActionsChanged() {
  url_pill_->Refresh();
}

void OpenSidebarView::OnWindowActivationChanged() {
  toolbar_->Refresh();
  bottom_bar_->Refresh();
  pager_->ForEachPage(
      [](OpenTabTreeView* page) { page->OnWindowActivationChanged(); });
}

void OpenSidebarView::OnAppearanceChanged() {
  pager_->ForEachPage(
      [](OpenTabTreeView* page) { page->OnSpaceThemeChanged(); });
  OnSpaceThemeChanged(context_->FocusedSpaceId());
}

// --- Accessors -------------------------------------------------------------------

views::View* OpenSidebarView::url_pill() const {
  return url_pill_;
}

views::View* OpenSidebarView::site_control_button() const {
  return url_pill_->site_button();
}

OpenTabTreeView* OpenSidebarView::GetTreeForSpace(const SpaceID& space_id) const {
  return pager_->FindPage(space_id);
}

void OpenSidebarView::SetPeekDimmed(bool dimmed) {
  if (peek_dimmed_ == dimmed) {
    return;
  }
  peek_dimmed_ = dimmed;
  toolbar_->layer()->SetOpacity(dimmed ? kPeekDimOpacity : 1.0f);
  bottom_bar_->layer()->SetOpacity(dimmed ? kPeekDimOpacity : 1.0f);
}

bool OpenSidebarView::IsPointInDragRegion(const gfx::Point& point) const {
  const views::View* target =
      const_cast<OpenSidebarView*>(this)->GetEventHandlerForPoint(point);
  return target && target->GetProperty(kOpenWindowDragKey);
}

// --- views::View ---------------------------------------------------------------------

void OpenSidebarView::Layout(PassKey) {
  const int w = width(), h = height();
  toolbar_->SetBounds(0, 0, w, static_cast<int>(m::url_field::kY));
  url_pill_->SetBoundsRect(ToRect(m::url_field::Pill(static_cast<float>(w))));
  const int fav_top = static_cast<int>(m::favorites::kSectionTop);
  const int fav_h = static_cast<int>(std::ceil(favorites_section_height()));
  favorites_->SetBounds(0, fav_top, w, fav_h);
  const int bar_h = static_cast<int>(m::bottom_bar::kHeight);
  const int pager_top = fav_top + fav_h;
  int media_h = 0;
  if (media_stack_ && media_stack_->GetVisible()) {
    media_h = std::min(media_stack_->GetHeightForWidth(w),
                       std::max(0, h - bar_h - pager_top));
    media_stack_->SetBounds(0, h - bar_h - media_h, w, media_h);
  }
  pager_->SetBounds(0, pager_top, w,
                    std::max(0, h - bar_h - media_h - pager_top));
  bottom_bar_->SetBounds(0, h - bar_h, w, bar_h);
}

void OpenSidebarView::OnPaint(gfx::Canvas* canvas) {
  // Light content: the last 3 pt at the right edge, black 0.07 (anchored).
  if (presentation_ != Presentation::kAnchored) {
    return;
  }
  const OpenSpaceThemeState& s = context_->ThemeStateFor(context_->FocusedSpaceId());
  if (s.roles.edge_band) {
    const float band = theme::SidebarRoles::kEdgeBandWidth;
    canvas->FillRect(gfx::ToEnclosingRect(gfx::RectF(width() - band, 0, band,
                                                     height())),
                     Sk(*s.roles.edge_band));
  }
}

void OpenSidebarView::OnMouseEntered(const ui::MouseEvent& event) {
  UpdateHover(true);
}

void OpenSidebarView::OnMouseExited(const ui::MouseEvent& event) {
  UpdateHover(false);
}

void OpenSidebarView::UpdateHover(bool hovered) {
  if (sidebar_hovered_ == hovered) {
    return;
  }
  sidebar_hovered_ = hovered;
  // guess: URL field controls show while the pointer is over the sidebar.
  url_pill_->SetControlsVisible(hovered);
}

BEGIN_METADATA(OpenSidebarView)
END_METADATA

}  // namespace open_unified
