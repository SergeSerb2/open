// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_little_open_view.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/ptr_util.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/views/open_window_controls_view.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/background.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/frame_view.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::GlyphButton;
using secondary::PaintedButton;
namespace m = little_open_metrics;

// Window resize border for the frameless window (guess; platform default).
constexpr int kResizeBorder = 5;
constexpr int kResizeCorner = 12;
// Bar mode: the top strip above the embedded bar's input drags the window.
constexpr int kBarDragStrip = 10;

// Emoji when the icon is one, else the first letter of `name`.
std::u16string GlyphTextFor(const std::optional<SpaceIcon>& icon,
                            const std::u16string& name) {
  if (icon && icon->kind == SpaceIconKind::kEmoji && !icon->value.empty()) {
    return base::UTF8ToUTF16(icon->value);
  }
  return name.empty() ? std::u16string(u"•") : name.substr(0, 1);
}

void DrawIconInBadge(gfx::Canvas* canvas,
                     const std::optional<SpaceIcon>& icon,
                     const std::u16string& fallback_name,
                     const gfx::Rect& badge_rect,
                     SkColor color,
                     int font_size) {
  if (icon && (icon->kind == SpaceIconKind::kSymbol ||
               icon->kind == SpaceIconKind::kNamed)) {
    const std::string_view symbol =
        icon->kind == SpaceIconKind::kNamed
            ? glyphs::NamedSpaceIconSymbol(icon->value)
            : std::string_view(icon->value);
    if (glyphs::DrawSystemSymbol(canvas, symbol, static_cast<float>(font_size),
                                 glyphs::SymbolWeight::kMedium,
                                 gfx::RectF(badge_rect), color)) {
      return;
    }
  }
  secondary::DrawText(canvas, GlyphTextFor(icon, fallback_name),
                      secondary::FontOfSize(font_size), color, badge_rect,
                      gfx::Canvas::TEXT_ALIGN_CENTER);
}

// --- Frameless frame: drag from the title bar, resize from the edges. ------

class LittleOpenFrameView : public views::FrameView {
  METADATA_HEADER(LittleOpenFrameView, views::FrameView)

 public:
  explicit LittleOpenFrameView(views::Widget* widget) : widget_(widget) {}

  void set_contents(OpenLittleOpenView* contents) { contents_ = contents; }

  // views::FrameView:
  gfx::Rect GetBoundsForClientView() const override {
    gfx::Rect client = bounds();
    if (widget_ && widget_->IsMaximized()) {
      if (OpenPlatform* platform = OpenPlatform::Get()) {
        const int inset = platform->MaximizedFrameInsetDip(widget_);
        if (inset > 0) {
          client.Inset(inset);
        }
      }
    }
    return client;
  }
  gfx::Rect GetWindowBoundsForClientBounds(
      const gfx::Rect& client_bounds) const override {
    return client_bounds;
  }
  int NonClientHitTest(const gfx::Point& point) override {
    if (!bounds().Contains(point)) {
      return HTNOWHERE;
    }
    const bool can_resize = widget_ && widget_->widget_delegate() &&
                            widget_->widget_delegate()->CanResize() &&
                            !widget_->IsMaximized();
    const int edge =
        GetHTComponentForFrame(point, gfx::Insets(kResizeBorder), kResizeCorner,
                               kResizeCorner, can_resize);
    if (edge != HTNOWHERE && edge != HTCLIENT && can_resize) {
      return edge;
    }
    if (contents_) {
      gfx::Point local = point;
      views::View::ConvertPointToTarget(this, contents_, &local);
      return contents_->NonClientHitTest(local);
    }
    return HTCLIENT;
  }

 private:
  raw_ptr<views::Widget> widget_;
  raw_ptr<OpenLittleOpenView> contents_ = nullptr;
};

BEGIN_METADATA(LittleOpenFrameView)
END_METADATA

// Client-owned by OpenLittleOpenWindow; outlives the widget.
class LittleOpenWindowDelegate : public views::WidgetDelegate {
 public:
  explicit LittleOpenWindowDelegate(LittleOpenDelegate* delegate)
      : delegate_(delegate) {
    SetCanResize(true);
    SetCanMaximize(true);
    SetCanMinimize(true);
    SetTitle(u"Little Open");
    SetShowTitle(false);
    SetShowCloseButton(false);
    RegisterWindowClosingCallback(base::BindOnce(
        &LittleOpenWindowDelegate::OnWindowClosing, base::Unretained(this)));
  }

  void set_contents(OpenLittleOpenView* contents) {
    contents_ = contents;
    if (frame_) {
      frame_->set_contents(contents);
    }
  }

  // Notifies on the next task, so the owner may delete the window there.
  void OnWindowClosing() {
    if (contents_) {
      contents_->NotifyWindowClosing();
    }
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&LittleOpenWindowDelegate::NotifyClosed,
                                  weak_factory_.GetWeakPtr()));
  }

  void NotifyClosed() {
    if (delegate_) {
      delegate_->OnLittleOpenClosed();
    }
  }

  // views::WidgetDelegate:
  std::unique_ptr<views::FrameView> CreateFrameView(
      views::Widget* widget) override {
    auto frame = std::make_unique<LittleOpenFrameView>(widget);
    frame->set_contents(contents_);
    frame_ = frame.get();
    return frame;
  }

  // Drops every pointer into the widget's view tree before the widget is
  // destroyed (the frame and contents views die with the widget).
  void ReleaseViews() {
    set_contents(nullptr);
    frame_ = nullptr;
  }

 private:
  raw_ptr<LittleOpenDelegate> delegate_;
  raw_ptr<OpenLittleOpenView> contents_ = nullptr;
  raw_ptr<LittleOpenFrameView> frame_ = nullptr;
  base::WeakPtrFactory<LittleOpenWindowDelegate> weak_factory_{this};
};

// --- Space picker ------------------------------------------------------------

class SpacePickerView : public views::View {
  METADATA_HEADER(SpacePickerView, views::View)

 public:
  using PickCallback = base::RepeatingCallback<void(const SpaceID&, bool)>;

  SpacePickerView(std::vector<LittleOpenSpaceChoice> spaces,
                  std::optional<SpaceID> target_space_id,
                  PickCallback on_pick)
      : spaces_(std::move(spaces)),
        target_space_id_(std::move(target_space_id)),
        on_pick_(std::move(on_pick)) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kMenu);
    GetViewAccessibility().SetName(u"Open in Space");
    SetFocusBehavior(FocusBehavior::ALWAYS);
  }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    const int rows = static_cast<int>(
        std::min<size_t>(spaces_.size(), m::kPickerVisibleRows));
    return gfx::Size(
        m::kPickerWidth,
        m::kPickerHeader + rows * m::kPickerRowHeight + m::kPickerInset);
  }

  void OnPaint(gfx::Canvas* canvas) override {
    canvas->DrawColor(m::kTitleBarFill);
    secondary::DrawText(
        canvas, u"Open in Space",
        secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::SEMIBOLD),
        secondary::WithAlpha(SK_ColorWHITE, 0.55f),
        gfx::Rect(m::kPickerInset + 6, 0, width() - 2 * m::kPickerInset,
                  m::kPickerHeader));
    const size_t visible =
        std::min<size_t>(spaces_.size() - scroll_, m::kPickerVisibleRows);
    for (size_t i = 0; i < visible; ++i) {
      const LittleOpenSpaceChoice& space = spaces_[scroll_ + i];
      const gfx::Rect row = RowRect(i);
      if (hovered_ == scroll_ + i) {
        secondary::FillRoundRect(canvas, gfx::RectF(row), 8.f,
                                 secondary::WithAlpha(SK_ColorWHITE, 0.08f));
      }
      const gfx::Rect icon(row.x() + 6,
                           row.y() + (row.height() - m::kPickerIconSize) / 2,
                           m::kPickerIconSize, m::kPickerIconSize);
      secondary::FillRoundRect(canvas, gfx::RectF(icon), m::kPickerIconRadius,
                               space.color);
      DrawIconInBadge(canvas, space.icon, space.title, icon, SK_ColorWHITE, 16);

      const bool is_target =
          space.is_target ||
          (target_space_id_.has_value() && space.id == *target_space_id_);
      const int text_right = row.right() - (is_target ? 30 : 12);
      secondary::DrawText(
          canvas, space.title,
          secondary::FontOfSize(m::kFontSize,
                                is_target ? gfx::Font::Weight::SEMIBOLD
                                          : gfx::Font::Weight::NORMAL),
          is_target ? SK_ColorWHITE : m::kText,
          gfx::Rect(icon.right() + 10, row.y(),
                    std::max(0, text_right - (icon.right() + 10)),
                    row.height()));
      if (is_target) {
        const gfx::RectF check_box(row.right() - 24.f,
                                   row.y() + (row.height() - 14.f) / 2.f, 14.f,
                                   14.f);
        secondary::PaintGlyph(canvas, Glyph::kCheck, check_box, SK_ColorWHITE,
                              1.6f);
      }
    }
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (std::optional<size_t> index = RowAt(event.location())) {
      // Right-click or Alt+click updates the pill target without moving yet;
      // normal left-click opens in that Space immediately.
      const bool target_only =
          event.IsRightMouseButton() || event.IsAltDown();
      Pick(*index, target_only);
      return true;
    }
    return false;
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    const std::optional<size_t> index = RowAt(event.location());
    if (index != hovered_) {
      hovered_ = index;
      SchedulePaint();
    }
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_.reset();
    SchedulePaint();
  }

  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return RowAt(event.location()).has_value()
               ? ui::Cursor(ui::mojom::CursorType::kHand)
               : views::View::GetCursor(event);
  }

  bool OnMouseWheel(const ui::MouseWheelEvent& event) override {
    if (spaces_.size() <= m::kPickerVisibleRows) {
      return true;
    }
    const size_t max_scroll = spaces_.size() - m::kPickerVisibleRows;
    if (event.y_offset() > 0 && scroll_ > 0) {
      --scroll_;
    } else if (event.y_offset() < 0 && scroll_ < max_scroll) {
      ++scroll_;
    }
    SchedulePaint();
    return true;
  }

  bool OnKeyPressed(const ui::KeyEvent& event) override {
    if (spaces_.empty()) {
      return false;
    }
    switch (event.key_code()) {
      case ui::VKEY_DOWN:
        hovered_ = std::min(spaces_.size() - 1, hovered_ ? *hovered_ + 1 : 0);
        break;
      case ui::VKEY_UP:
        hovered_ = hovered_ && *hovered_ > 0 ? *hovered_ - 1 : 0;
        break;
      case ui::VKEY_RETURN:
        if (hovered_) {
          Pick(*hovered_, /*target_only=*/false);
        }
        return true;
      default:
        return false;
    }
    if (*hovered_ < scroll_) {
      scroll_ = *hovered_;
    } else if (*hovered_ >= scroll_ + m::kPickerVisibleRows) {
      scroll_ = *hovered_ + 1 - m::kPickerVisibleRows;
    }
    SchedulePaint();
    return true;
  }

 private:
  gfx::Rect RowRect(size_t visible_index) const {
    return gfx::Rect(m::kPickerInset,
                     m::kPickerHeader +
                         static_cast<int>(visible_index) * m::kPickerRowHeight,
                     width() - 2 * m::kPickerInset, m::kPickerRowHeight);
  }

  std::optional<size_t> RowAt(const gfx::Point& point) const {
    const size_t visible =
        std::min<size_t>(spaces_.size() - scroll_, m::kPickerVisibleRows);
    for (size_t i = 0; i < visible; ++i) {
      if (RowRect(i).Contains(point)) {
        return scroll_ + i;
      }
    }
    return std::nullopt;
  }

  void Pick(size_t index, bool target_only) {
    if (index >= spaces_.size()) {
      return;
    }
    const SpaceID id = spaces_[index].id;
    // Copy the callback and close first: the pick can destroy the owning
    // Little Open view, and with it this picker's widget and delegate.
    PickCallback on_pick = on_pick_;
    if (views::Widget* widget = GetWidget()) {
      widget->Close();
    }
    on_pick.Run(id, target_only);
  }

  std::vector<LittleOpenSpaceChoice> spaces_;
  std::optional<SpaceID> target_space_id_;
  PickCallback on_pick_;
  std::optional<size_t> hovered_;
  size_t scroll_ = 0;
};

BEGIN_METADATA(SpacePickerView)
END_METADATA

// --- Profile picker ----------------------------------------------------------

class ProfilePickerView : public views::View {
  METADATA_HEADER(ProfilePickerView, views::View)

 public:
  using PickCallback = base::RepeatingCallback<void(const ProfileID&)>;

  ProfilePickerView(std::vector<LittleOpenProfileChoice> profiles,
                    PickCallback on_pick)
      : profiles_(std::move(profiles)), on_pick_(std::move(on_pick)) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kMenu);
    GetViewAccessibility().SetName(u"Switch Profile");
    SetFocusBehavior(FocusBehavior::ALWAYS);
  }

  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    const int rows = static_cast<int>(
        std::min<size_t>(profiles_.size(), m::kPickerVisibleRows));
    return gfx::Size(
        m::kPickerWidth,
        m::kPickerHeader + rows * m::kPickerRowHeight + m::kPickerInset);
  }

  void OnPaint(gfx::Canvas* canvas) override {
    canvas->DrawColor(m::kTitleBarFill);
    secondary::DrawText(
        canvas, u"Switch Profile",
        secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::SEMIBOLD),
        secondary::WithAlpha(SK_ColorWHITE, 0.55f),
        gfx::Rect(m::kPickerInset + 6, 0, width() - 2 * m::kPickerInset,
                  m::kPickerHeader));
    const size_t visible =
        std::min<size_t>(profiles_.size() - scroll_, m::kPickerVisibleRows);
    for (size_t i = 0; i < visible; ++i) {
      const LittleOpenProfileChoice& profile = profiles_[scroll_ + i];
      const gfx::Rect row = RowRect(i);
      if (hovered_ == scroll_ + i) {
        secondary::FillRoundRect(canvas, gfx::RectF(row), 8.f,
                                 secondary::WithAlpha(SK_ColorWHITE, 0.08f));
      }
      const gfx::Rect icon(row.x() + 6,
                           row.y() + (row.height() - m::kPickerIconSize) / 2,
                           m::kPickerIconSize, m::kPickerIconSize);
      secondary::FillRoundRect(canvas, gfx::RectF(icon), m::kPickerIconRadius,
                               profile.color);
      DrawIconInBadge(canvas, profile.icon, profile.name, icon, SK_ColorWHITE,
                      15);

      const int text_right = row.right() - (profile.active ? 30 : 12);
      secondary::DrawText(
          canvas, profile.name,
          secondary::FontOfSize(m::kFontSize,
                                profile.active ? gfx::Font::Weight::SEMIBOLD
                                               : gfx::Font::Weight::NORMAL),
          profile.active ? SK_ColorWHITE : m::kText,
          gfx::Rect(icon.right() + 10, row.y(),
                    std::max(0, text_right - (icon.right() + 10)),
                    row.height()));
      if (profile.active) {
        const gfx::RectF check_box(row.right() - 24.f,
                                   row.y() + (row.height() - 14.f) / 2.f, 14.f,
                                   14.f);
        secondary::PaintGlyph(canvas, Glyph::kCheck, check_box, SK_ColorWHITE,
                              1.6f);
      }
    }
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (std::optional<size_t> index = RowAt(event.location())) {
      Pick(*index);
      return true;
    }
    return false;
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    const std::optional<size_t> index = RowAt(event.location());
    if (index != hovered_) {
      hovered_ = index;
      SchedulePaint();
    }
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_.reset();
    SchedulePaint();
  }

  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return RowAt(event.location()).has_value()
               ? ui::Cursor(ui::mojom::CursorType::kHand)
               : views::View::GetCursor(event);
  }

 private:
  gfx::Rect RowRect(size_t visible_index) const {
    return gfx::Rect(m::kPickerInset,
                     m::kPickerHeader +
                         static_cast<int>(visible_index) * m::kPickerRowHeight,
                     width() - 2 * m::kPickerInset, m::kPickerRowHeight);
  }

  std::optional<size_t> RowAt(const gfx::Point& point) const {
    const size_t visible =
        std::min<size_t>(profiles_.size() - scroll_, m::kPickerVisibleRows);
    for (size_t i = 0; i < visible; ++i) {
      if (RowRect(i).Contains(point)) {
        return scroll_ + i;
      }
    }
    return std::nullopt;
  }

  void Pick(size_t index) {
    if (index >= profiles_.size()) {
      return;
    }
    const ProfileID id = profiles_[index].id;
    PickCallback on_pick = on_pick_;
    if (views::Widget* widget = GetWidget()) {
      widget->Close();
    }
    on_pick.Run(id);
  }

  std::vector<LittleOpenProfileChoice> profiles_;
  PickCallback on_pick_;
  std::optional<size_t> hovered_;
  size_t scroll_ = 0;
};

BEGIN_METADATA(ProfilePickerView)
END_METADATA

class LittleOpenHandGlyphButton : public GlyphButton {
  METADATA_HEADER(LittleOpenHandGlyphButton, GlyphButton)

 public:
  using GlyphButton::GlyphButton;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                        : GlyphButton::GetCursor(event);
  }
};

BEGIN_METADATA(LittleOpenHandGlyphButton)
END_METADATA

class LittleOpenHandPaintedButton : public PaintedButton {
  METADATA_HEADER(LittleOpenHandPaintedButton, PaintedButton)

 public:
  using PaintedButton::PaintedButton;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override {
    return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                        : PaintedButton::GetCursor(event);
  }
};

BEGIN_METADATA(LittleOpenHandPaintedButton)
END_METADATA

#if BUILDFLAG(IS_MAC)
// macOS traffic-light button that notifies its siblings on hover state changes
// so all three circles display their glyphs together (group-hover).
class TrafficLightButton : public LittleOpenHandPaintedButton {
  METADATA_HEADER(TrafficLightButton, LittleOpenHandPaintedButton)

 public:
  TrafficLightButton(PressedCallback callback,
                     Painter painter,
                     const std::u16string& accessible_name,
                     base::RepeatingClosure on_hover_change)
      : LittleOpenHandPaintedButton(std::move(callback),
                                    std::move(painter),
                                    accessible_name),
        on_hover_change_(std::move(on_hover_change)) {}

  void StateChanged(ButtonState old_state) override {
    LittleOpenHandPaintedButton::StateChanged(old_state);
    if (on_hover_change_) {
      on_hover_change_.Run();
    }
  }

 private:
  base::RepeatingClosure on_hover_change_;
};

BEGIN_METADATA(TrafficLightButton)
END_METADATA
#endif

}  // namespace

// --- OpenLittleOpenView ------------------------------------------------------

OpenLittleOpenView::OpenLittleOpenView(LittleOpenDelegate* delegate)
    : delegate_(delegate) {
  GetViewAccessibility().SetName(u"Little Open");

#if BUILDFLAG(IS_MAC)
  static constexpr std::array<const char16_t*, 3> kNames = {
      u"Close", u"Minimize", u"Zoom"};
  for (int i = 0; i < 3; ++i) {
    window_buttons_[i] = AddChildView(std::make_unique<TrafficLightButton>(
        base::BindRepeating(&OpenLittleOpenView::PressWindowButton,
                            base::Unretained(this), i),
        base::BindRepeating(&OpenLittleOpenView::PaintWindowButton,
                            base::Unretained(this), i),
        kNames[i],
        base::BindRepeating(&OpenLittleOpenView::RepaintTrafficLights,
                            base::Unretained(this))));
  }
#elif BUILDFLAG(IS_WIN)
  window_controls_view_ = AddChildView(std::make_unique<OpenWindowControlsView>(
      OpenWindowControlsView::Mode::kWindowsFluent));
#else
  LinuxWindowButtons buttons;
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    buttons = platform->GetLinuxWindowButtons();
  } else {
    buttons.trailing = {WindowControlButton::kMinimize,
                        WindowControlButton::kMaximize,
                        WindowControlButton::kClose};
  }
  if (!buttons.leading.empty()) {
    leading_window_controls_view_ =
        AddChildView(std::make_unique<OpenWindowControlsView>(
            OpenWindowControlsView::Mode::kLinuxCsd, buttons.leading));
  }
  if (!buttons.trailing.empty()) {
    window_controls_view_ =
        AddChildView(std::make_unique<OpenWindowControlsView>(
            OpenWindowControlsView::Mode::kLinuxCsd, buttons.trailing));
  }
#endif

  profile_button_ = AddChildView(std::make_unique<LittleOpenHandPaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (!self->state_.profiles.empty()) {
              self->ShowProfilePicker();
            } else if (self->delegate_) {
              self->delegate_->OnLittleOpenProfile(self->profile_button_);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintProfile,
                          base::Unretained(this)),
      u"Profile"));

  host_button_ = AddChildView(std::make_unique<LittleOpenHandPaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->delegate_) {
              self->delegate_->OnLittleOpenEditUrl();
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintHost,
                          base::Unretained(this)),
      u"Edit URL"));

  downloads_button_ = AddChildView(std::make_unique<LittleOpenHandPaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->delegate_) {
              self->delegate_->OnLittleOpenDownloads(self->downloads_button_);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintDownloads,
                          base::Unretained(this)),
      u"Downloads"));
  downloads_button_->SetVisible(false);

  auto make_glyph = [this](Glyph glyph, const char16_t* name,
                           views::Button::PressedCallback callback) {
    auto button = std::make_unique<LittleOpenHandGlyphButton>(
        std::move(callback), glyph, name);
    button->SetGlyphColor(m::kText);
    button->SetGlyphSize(14.f);
    button->SetPlate(GlyphButton::Plate::kHoverRounded, SK_ColorTRANSPARENT,
                     4.f);
    button->SetHoverFill(secondary::WithAlpha(SK_ColorWHITE, 0.10f));
    return AddChildView(std::move(button));
  };
  copy_button_ = make_glyph(Glyph::kLink, u"Copy Current URL",
                            base::BindRepeating(
                                [](OpenLittleOpenView* self) {
                                  if (self->delegate_) {
                                    self->delegate_->OnLittleOpenCopyUrl();
                                  }
                                },
                                base::Unretained(this)));
  extensions_button_ = make_glyph(
      Glyph::kPuzzle, u"Extensions",
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->delegate_) {
              self->delegate_->OnLittleOpenExtensions(self->extensions_button_);
            }
          },
          base::Unretained(this)));
  extensions_button_->SetVisible(false);
  chevron_button_ =
      make_glyph(Glyph::kChevronDown, u"More Spaces",
                 base::BindRepeating(&OpenLittleOpenView::ShowSpacePicker,
                                     base::Unretained(this)));

  pill_button_ = AddChildView(std::make_unique<LittleOpenHandPaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->state_.space_title) {
              self->TriggerOpenInSpace(self->state_.target_space_id);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintPill,
                          base::Unretained(this)),
      u"Open in Space"));

  web_view_ = AddChildView(std::make_unique<views::WebView>());
  web_view_->SetBackground(views::CreateSolidBackground(SK_ColorWHITE));

  AddAccelerator(ui::Accelerator(ui::VKEY_O, secondary::kPrimaryModifier));
  SyncWindowControlsState();
  SetMode(Mode::kBar);
}

OpenLittleOpenView::~OpenLittleOpenView() {
  widget_observation_.Reset();
  Observe(nullptr);
  web_view_->SetWebContents(nullptr);
  owned_contents_.reset();
}

// static
gfx::Rect OpenLittleOpenView::DefaultBarBounds(const gfx::Rect& work_area) {
  return gfx::Rect(work_area.right() - m::kScreenInset - m::kBarSize.width(),
                   work_area.y() + m::kScreenInset, m::kBarSize.width(),
                   m::kBarSize.height());
}

// static
gfx::Rect OpenLittleOpenView::PageBoundsFromBar(const gfx::Rect& bar_bounds,
                                                const gfx::Rect& work_area) {
  const int max_width = std::max(0, work_area.width());
  const int max_height = std::max(0, work_area.height());
  const int width = std::clamp(
      m::kPageSize.width(), std::min(m::kMinimumPageSize.width(), max_width),
      max_width);
  const int height = std::clamp(
      m::kPageSize.height(),
      std::min(m::kMinimumPageSize.height() + m::EffectiveTitleBarHeight(),
               max_height),
      max_height);
  int x = bar_bounds.right() - width;
  int y = bar_bounds.y();
  x = std::clamp(x, work_area.x(),
                 std::max(work_area.x(), work_area.right() - width));
  y = std::clamp(y, work_area.y(),
                 std::max(work_area.y(), work_area.bottom() - height));
  return gfx::Rect(x, y, width, height);
}

void OpenLittleOpenView::SetMode(Mode mode) {
  mode_ = mode;
  const bool page = mode_ == Mode::kPage;
#if BUILDFLAG(IS_MAC)
  for (auto& button : window_buttons_) {
    button->SetVisible(page);
  }
#else
  if (leading_window_controls_view_) {
    leading_window_controls_view_->SetVisible(page);
  }
  if (window_controls_view_) {
    window_controls_view_->SetVisible(page);
  }
#endif
  profile_button_->SetVisible(page && state_.show_profile);
  host_button_->SetVisible(page);
  downloads_button_->SetVisible(page && (state_.show_downloads ||
                                         state_.downloads_running));
  for (auto& ext_btn : extension_action_buttons_) {
    ext_btn->SetVisible(page);
  }
  copy_button_->SetVisible(page);
  extensions_button_->SetVisible(page && state_.show_extensions);
  pill_button_->SetVisible(page);
  chevron_button_->SetVisible(page);
  web_view_->SetVisible(page && web_view_->web_contents());
  if (bar_contents_) {
    bar_contents_->SetVisible(!page);
  }
  UpdateWindowTitle();
  InvalidateLayout();
  SchedulePaint();
}

void OpenLittleOpenView::SetState(const LittleOpenState& state) {
  state_ = state;
  // Sync target_space_color / icon from matching choice if not explicitly set.
  if (state_.target_space_id) {
    for (const LittleOpenSpaceChoice& choice : state_.spaces) {
      if (choice.id == *state_.target_space_id) {
        state_.target_space_color = choice.color;
        if (!state_.target_space_icon) {
          state_.target_space_icon = choice.icon;
        }
        break;
      }
    }
  } else if (state_.space_title) {
    for (const LittleOpenSpaceChoice& choice : state_.spaces) {
      if (choice.title == *state_.space_title) {
        state_.target_space_color = choice.color;
        if (!state_.target_space_icon) {
          state_.target_space_icon = choice.icon;
        }
        break;
      }
    }
  }

  pill_button_->SetEnabled(state_.space_title.has_value());
  pill_button_->GetViewAccessibility().SetName(
      u"Open in " + state_.space_title.value_or(u"Space") + u" " +
      KeycapLabel());
  host_button_->GetViewAccessibility().SetName(state_.host);
  profile_button_->GetViewAccessibility().SetName(u"Profile: " +
                                                  state_.profile_name);
  chevron_button_->SetEnabled(!state_.spaces.empty());
  RebuildExtensionActionButtons();
  SetMode(mode_);
}

void OpenLittleOpenView::SetBarContents(std::unique_ptr<views::View> contents) {
  if (bar_contents_) {
    RemoveChildViewT(bar_contents_.ExtractAsDangling());
  }
  if (contents) {
    bar_contents_ = AddChildView(std::move(contents));
  }
  SetMode(mode_);
}

void OpenLittleOpenView::SetWebContents(content::WebContents* contents) {
  if (owned_contents_ && owned_contents_.get() != contents) {
    web_view_->SetWebContents(nullptr);
    owned_contents_.reset();
  }
  if (web_view_->web_contents() != contents) {
    web_view_->SetWebContents(contents);
  }
  Observe(contents);
  page_loading_ = contents && contents->IsLoading();
  load_progress_ = page_loading_ ? 0.15 : 0.0;
  promoted_to_main_ = false;
  web_view_->SetVisible(mode_ == Mode::kPage && contents);
  UpdateWindowTitle();
  InvalidateLayout();
  SchedulePaint();
}

void OpenLittleOpenView::SetOwnedWebContents(
    std::unique_ptr<content::WebContents> contents) {
  web_view_->SetWebContents(nullptr);
  owned_contents_ = std::move(contents);
  Observe(owned_contents_.get());
  page_loading_ = owned_contents_ && owned_contents_->IsLoading();
  load_progress_ = page_loading_ ? 0.15 : 0.0;
  promoted_to_main_ = false;
  web_view_->SetWebContents(owned_contents_.get());
  web_view_->SetVisible(mode_ == Mode::kPage && owned_contents_ != nullptr);
  UpdateWindowTitle();
  InvalidateLayout();
  SchedulePaint();
}

std::unique_ptr<content::WebContents>
OpenLittleOpenView::ReleaseWebContents() {
  Observe(nullptr);
  page_loading_ = false;
  load_progress_ = 0.0;
  promoted_to_main_ = true;
  web_view_->SetWebContents(nullptr);
  web_view_->SetVisible(false);
  return std::move(owned_contents_);
}

content::WebContents* OpenLittleOpenView::DetachWebContents() {
  Observe(nullptr);
  page_loading_ = false;
  load_progress_ = 0.0;
  promoted_to_main_ = true;
  content::WebContents* contents = web_view_->web_contents();
  web_view_->SetWebContents(nullptr);
  web_view_->SetVisible(false);
  return contents;
}

void OpenLittleOpenView::SetMoveToSpaceCallback(MoveToSpaceCallback callback) {
  move_to_space_callback_ = std::move(callback);
}

void OpenLittleOpenView::SetArchiveOnCloseCallback(
    ArchiveOnCloseCallback callback) {
  archive_on_close_callback_ = std::move(callback);
}

void OpenLittleOpenView::NotifyWindowClosing() {
  if (archive_notified_ || promoted_to_main_) {
    return;
  }
  archive_notified_ = true;
  content::WebContents* contents =
      owned_contents_ ? owned_contents_.get() : web_view_->web_contents();
  if (!contents) {
    return;
  }
  const GURL& committed = contents->GetLastCommittedURL();
  const GURL& url =
      committed.is_valid() ? committed : contents->GetVisibleURL();
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  const std::u16string title = contents->GetTitle();
  if (archive_on_close_callback_) {
    archive_on_close_callback_.Run(url, title, state_.active_profile_id);
  }
  if (delegate_) {
    delegate_->OnLittleOpenArchiveOnClose(url, title, state_.active_profile_id);
  }
}

void OpenLittleOpenView::TriggerOpenInSpace(std::optional<SpaceID> space_id) {
  if (move_to_space_callback_ && owned_contents_) {
    move_to_space_callback_.Run(ReleaseWebContents(), std::move(space_id));
    return;
  }
  if (delegate_) {
    delegate_->OnLittleOpenOpenInSpace(std::move(space_id));
  }
}

void OpenLittleOpenView::RebuildExtensionActionButtons() {
  for (auto& btn : extension_action_buttons_) {
    RemoveChildViewT(btn.ExtractAsDangling());
  }
  extension_action_buttons_.clear();
  const size_t count = std::min<size_t>(state_.extension_actions.size(),
                                        m::kMaxExtensionStripButtons);
  extension_action_buttons_.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    const LittleOpenExtensionAction& action = state_.extension_actions[i];
    auto button = std::make_unique<LittleOpenHandPaintedButton>(
        base::BindRepeating(
            [](OpenLittleOpenView* self, size_t idx) {
              if (self->delegate_ &&
                  idx < self->state_.extension_actions.size() &&
                  idx < self->extension_action_buttons_.size()) {
                self->delegate_->OnLittleOpenExtensionAction(
                    self->state_.extension_actions[idx].id,
                    self->extension_action_buttons_[idx]);
              }
            },
            base::Unretained(this), i),
        base::BindRepeating(&OpenLittleOpenView::PaintExtensionAction,
                            base::Unretained(this), i),
        action.name.empty() ? u"Extension" : action.name);
    button->SetEnabled(action.enabled);
    extension_action_buttons_.push_back(AddChildView(std::move(button)));
  }
}

int OpenLittleOpenView::TitleBarHeight() const {
  return m::EffectiveTitleBarHeight();
}

int OpenLittleOpenView::NonClientHitTest(const gfx::Point& point) const {
  if (mode_ == Mode::kBar) {
    return point.y() < kBarDragStrip ? HTCAPTION : HTCLIENT;
  }
  if (point.y() >= TitleBarHeight()) {
    return HTCLIENT;
  }
#if !BUILDFLAG(IS_MAC)
  // Forward caption control hit-tests directly to OpenWindowControlsView so
  // Windows 11 Snap Layouts (HTMINBUTTON/HTMAXBUTTON/HTCLOSE) and Linux CSD
  // leading/trailing button clusters work natively.
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
#endif
  for (const views::View* child : children()) {
    if (child != web_view_ && child->GetVisible() &&
        child->bounds().Contains(point)) {
      return HTCLIENT;
    }
  }
  return HTCAPTION;
}

std::optional<gfx::Rect> OpenLittleOpenView::GetElementBounds(
    std::string_view name) const {
  if (name == "capsule") {
    return CapsuleRect();
  }
  if (name == "profile") {
    return profile_button_->GetVisible()
               ? std::optional<gfx::Rect>(profile_button_->bounds())
               : std::nullopt;
  }
  if (name == "host") {
    return host_button_->bounds();
  }
  if (name == "downloads") {
    return downloads_button_->GetVisible()
               ? std::optional<gfx::Rect>(downloads_button_->bounds())
               : std::nullopt;
  }
  if (name == "copy") {
    return copy_button_->bounds();
  }
  if (name == "extensions") {
    return extensions_button_->GetVisible()
               ? std::optional<gfx::Rect>(extensions_button_->bounds())
               : std::nullopt;
  }
  if (name == "pill") {
    return PillRect();
  }
  if (name == "open") {
    return PillLabelRect();
  }
  if (name == "chevron") {
    return ChevronRect();
  }
  if (name == "divider") {
    return DividerRect();
  }
  return std::nullopt;
}

void OpenLittleOpenView::AddedToWidget() {
  widget_observation_.Reset();
  if (views::Widget* widget = GetWidget()) {
    widget_observation_.Observe(widget);
    window_active_ = widget->ShouldPaintAsActive();
  }
  SyncWindowControlsState();
  UpdateWindowTitle();
}

void OpenLittleOpenView::OnWidgetActivationChanged(views::Widget* widget,
                                                   bool active) {
  window_active_ = active || (widget && widget->ShouldPaintAsActive());
  SyncWindowControlsState();
  RepaintTrafficLights();
}

void OpenLittleOpenView::OnWidgetShowStateChanged(views::Widget* widget) {
  SyncWindowControlsState();
}

void OpenLittleOpenView::OnWidgetDestroying(views::Widget* widget) {
  widget_observation_.Reset();
}

void OpenLittleOpenView::SyncWindowControlsState() {
#if !BUILDFLAG(IS_MAC)
  const bool maximized = GetWidget() && GetWidget()->IsMaximized();
  const bool high_contrast =
      OpenPlatform::Get() && OpenPlatform::Get()->IsIncreaseContrastEnabled();
  for (OpenWindowControlsView* controls :
       {window_controls_view_.get(), leading_window_controls_view_.get()}) {
    if (controls) {
      controls->SetThemeState(/*dark_content=*/true, window_active_,
                              high_contrast);
      controls->SetMaximized(maximized);
    }
  }
#endif
}

void OpenLittleOpenView::RepaintTrafficLights() {
#if BUILDFLAG(IS_MAC)
  for (auto& button : window_buttons_) {
    if (button) {
      button->SchedulePaint();
    }
  }
#endif
}

void OpenLittleOpenView::TitleWasSet(content::NavigationEntry* entry) {
  UpdateWindowTitle();
}

void OpenLittleOpenView::DidFinishNavigation(
    content::NavigationHandle* handle) {
  UpdateWindowTitle();
}

void OpenLittleOpenView::DidStartLoading() {
  page_loading_ = true;
  if (load_progress_ < 0.15) {
    load_progress_ = 0.15;
  }
  SchedulePaint();
}

void OpenLittleOpenView::DidStopLoading() {
  page_loading_ = false;
  load_progress_ = 0.0;
  SchedulePaint();
}

void OpenLittleOpenView::LoadProgressChanged(double progress) {
  page_loading_ = web_contents() && web_contents()->IsLoading();
  load_progress_ = std::clamp(progress, 0.0, 1.0);
  SchedulePaint();
}

void OpenLittleOpenView::UpdateWindowTitle() {
  std::u16string title = u"Little Open";
  if (mode_ == Mode::kPage) {
    content::WebContents* wc =
        owned_contents_ ? owned_contents_.get()
                        : (web_view_ ? web_view_->web_contents() : nullptr);
    std::u16string page_title = wc ? wc->GetTitle() : std::u16string();
    if (page_title.empty()) {
      page_title = state_.host;
    }
    if (!page_title.empty()) {
      title = page_title + u" \u2014 Little Open";
    }
  }
  if (views::Widget* widget = GetWidget()) {
    if (views::WidgetDelegate* wd = widget->widget_delegate()) {
      wd->SetTitle(title);
    }
    widget->UpdateWindowTitle();
  }
}

#if BUILDFLAG(IS_MAC)
gfx::Rect OpenLittleOpenView::WindowButtonRect(int index) const {
  return gfx::Rect(m::kWindowButtonX[index], m::kWindowButtonY,
                   m::kWindowButtonSize, m::kWindowButtonSize);
}
#endif

int OpenLittleOpenView::DesiredPillWidth() const {
  const gfx::FontList regular = secondary::FontOfSize(m::kFontSize);
  const gfx::FontList bold =
      secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::BOLD);
  const std::u16string keycap = KeycapLabel();
  const int keycap_w =
      std::max(m::kKeycapWidth, secondary::TextWidth(keycap, regular) + 8);
  const int dot_w = state_.space_title ? 14 : 0;
  const int text_w =
      secondary::TextWidth(u"Open in ", regular) +
      secondary::TextWidth(state_.space_title.value_or(u"Space"), bold);
  // Left padding (10) + color dot + label + gap (6) + keycap + inner pad (8) +
  // divider/chevron section (30).
  const int desired = 10 + dot_w + text_w + 6 + keycap_w + 8 + 30;
  return std::clamp(desired, m::kPillMinWidth, m::kPillMaxWidth);
}

gfx::Rect OpenLittleOpenView::PillRect() const {
  constexpr int kGapToPill = 8;
#if BUILDFLAG(IS_MAC)
  const int left_edge = 84;
  const int right_edge = width() - 8;
  const int pill_y = 8;
  const int pill_h = 30;
#elif BUILDFLAG(IS_WIN)
  const int left_edge = 8;
  const int controls_w = window_controls_view_
                             ? window_controls_view_->GetPreferredSize().width()
                             : metrics::win_controls::kWinClusterW;
  const int right_edge = width() - controls_w - 8;
  const int pill_y = 4;
  const int pill_h = 32;
#else
  const int leading_w =
      leading_window_controls_view_
          ? leading_window_controls_view_->GetPreferredSize().width()
          : 0;
  const int trailing_w =
      window_controls_view_ ? window_controls_view_->GetPreferredSize().width()
                            : 0;
  const int left_edge =
      leading_w > 0 ? metrics::win_controls::kLinuxOuterMargin + leading_w + 8
                    : 8;
  const int right_edge =
      trailing_w > 0
          ? width() - metrics::win_controls::kLinuxOuterMargin - trailing_w - 8
          : width() - 8;
  const int pill_y = 4;
  const int pill_h = 32;
#endif
  const int total_avail = std::max(0, right_edge - left_edge);
  const int desired = DesiredPillWidth();
  const int max_pill_with_capsule =
      std::max(0, total_avail - kGapToPill - m::kMinCapsuleWidth);
  const int pill_w =
      total_avail >= m::kMinCapsuleWidth + kGapToPill + 40
          ? std::min(desired, max_pill_with_capsule)
          : std::min(desired, std::max(0, total_avail / 2));
  const int pill_x = std::max(left_edge, right_edge - pill_w);
  return gfx::Rect(pill_x, pill_y, pill_w, pill_h);
}

gfx::Rect OpenLittleOpenView::DividerRect() const {
  const gfx::Rect pill = PillRect();
  const int divider_y = pill.y() + (pill.height() - 18) / 2;
  return gfx::Rect(std::max(pill.x(), pill.right() - 29), divider_y, 1, 18);
}

gfx::Rect OpenLittleOpenView::PillLabelRect() const {
  const gfx::Rect pill = PillRect();
  const gfx::Rect divider = DividerRect();
  const int label_y = pill.y() + (pill.height() - m::kHostHeight) / 2;
  return gfx::Rect(pill.x() + 10, label_y,
                   std::max(0, divider.x() - pill.x() - 18), m::kHostHeight);
}

gfx::Rect OpenLittleOpenView::ChevronRect() const {
  const gfx::Rect pill = PillRect();
  const int chevron_y = pill.y() + (pill.height() - 16) / 2;
  return gfx::Rect(std::max(pill.x(), pill.right() - 22), chevron_y, 16, 16);
}

gfx::Rect OpenLittleOpenView::CapsuleRect() const {
  const gfx::Rect pill = PillRect();
  constexpr int kGapToPill = 8;
#if BUILDFLAG(IS_MAC)
  const int left_edge = 84;
  const int capsule_y = 8;
  const int capsule_h = 31;
#elif BUILDFLAG(IS_WIN)
  const int left_edge = 8;
  const int capsule_y = 4;
  const int capsule_h = 32;
#else
  const int leading_w =
      leading_window_controls_view_
          ? leading_window_controls_view_->GetPreferredSize().width()
          : 0;
  const int left_edge =
      leading_w > 0 ? metrics::win_controls::kLinuxOuterMargin + leading_w + 8
                    : 8;
  const int capsule_y = 4;
  const int capsule_h = 32;
#endif
  return gfx::Rect(left_edge, capsule_y,
                   std::max(0, pill.x() - kGapToPill - left_edge), capsule_h);
}

gfx::Rect OpenLittleOpenView::CopyRect() const {
  const gfx::Rect capsule = CapsuleRect();
  const int icon_y = capsule.y() + (capsule.height() - 16) / 2;
  const int copy_x = std::max(capsule.x() + 4, capsule.right() - 24);
  const int copy_w = std::min(16, std::max(0, capsule.right() - copy_x - 4));
  return gfx::Rect(copy_x, icon_y, copy_w, 16);
}

gfx::Rect OpenLittleOpenView::ExtensionsRect() const {
  const gfx::Rect copy = CopyRect();
  return gfx::Rect(std::max(CapsuleRect().x() + 4, copy.x() - m::kAccessoryPitch),
                   copy.y(), 16, 16);
}

gfx::Size OpenLittleOpenView::GetMinimumSize() const {
  return mode_ == Mode::kPage
             ? gfx::Size(m::kMinimumPageSize.width(),
                         m::kMinimumPageSize.height() + TitleBarHeight())
             : m::kBarSize;
}

bool OpenLittleOpenView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (accelerator.key_code() == ui::VKEY_O && mode_ == Mode::kPage &&
      state_.space_title) {
    TriggerOpenInSpace(state_.target_space_id);
    return true;
  }
  return false;
}

void OpenLittleOpenView::Layout(PassKey) {
  const gfx::Rect bounds = GetLocalBounds();
  if (mode_ == Mode::kBar) {
    if (bar_contents_) {
      bar_contents_->SetBoundsRect(bounds);
    }
    return;
  }
  LayoutTitleBar();
  const int bar_h = TitleBarHeight();
  web_view_->SetBoundsRect(
      gfx::Rect(0, bar_h, bounds.width(), std::max(0, bounds.height() - bar_h)));
#if BUILDFLAG(IS_WIN)
  // On Windows the widget is opaque and DWM (DWMWCP_ROUND) rounds the outer
  // corners cleanly, so keep web_view_ square to avoid dark corner wedges.
  web_view_->holder()->SetNativeViewCornerRadii(gfx::RoundedCornersF());
#else
  const float r = m::kWindowCornerRadius;
  web_view_->holder()->SetNativeViewCornerRadii(
      gfx::RoundedCornersF(0, 0, r, r));
#endif
}

int OpenLittleOpenView::ProfileTextWidth() const {
  return secondary::TextWidth(
      state_.profile_name,
      secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::MEDIUM));
}

std::u16string OpenLittleOpenView::KeycapLabel() const {
  return secondary::PrimaryShortcutLabel(u'O');
}

void OpenLittleOpenView::LayoutTitleBar() {
#if BUILDFLAG(IS_MAC)
  for (int i = 0; i < 3; ++i) {
    window_buttons_[i]->SetBoundsRect(WindowButtonRect(i));
  }
#elif BUILDFLAG(IS_WIN)
  const int bar_h = TitleBarHeight();
  if (window_controls_view_) {
    const gfx::Size pref = window_controls_view_->GetPreferredSize();
    window_controls_view_->SetBoundsRect(
        gfx::Rect(width() - pref.width(), 0, pref.width(), bar_h));
  }
#else
  const int bar_h = TitleBarHeight();
  if (leading_window_controls_view_) {
    const gfx::Size pref = leading_window_controls_view_->GetPreferredSize();
    leading_window_controls_view_->SetBoundsRect(gfx::Rect(
        metrics::win_controls::kLinuxOuterMargin, 0, pref.width(), bar_h));
  }
  if (window_controls_view_) {
    const gfx::Size pref = window_controls_view_->GetPreferredSize();
    window_controls_view_->SetBoundsRect(gfx::Rect(
        width() - metrics::win_controls::kLinuxOuterMargin - pref.width(), 0,
        pref.width(), bar_h));
  }
#endif

  const gfx::Rect capsule = CapsuleRect();
  const int icon_y = capsule.y() + (capsule.height() - 16) / 2;
  const int ext_action_y = capsule.y() + (capsule.height() - 20) / 2;
  const int host_y = capsule.y() + (capsule.height() - m::kHostHeight) / 2;

  const gfx::Rect copy_rect = CopyRect();
  copy_button_->SetBoundsRect(copy_rect);
  chevron_button_->SetBoundsRect(ChevronRect());
  // The pill's clickable part ends at the divider; the chevron is its own.
  const gfx::Rect pill = PillRect();
  const gfx::Rect divider = DividerRect();
  pill_button_->SetBoundsRect(gfx::Rect(
      pill.x(), pill.y(), std::max(0, divider.x() - pill.x()), pill.height()));

  // Lay out right-side accessories inside the capsule from right to left:
  // Copy URL <- Extensions overflow <- Extension Action strip <- Downloads.
  int next_x = copy_rect.x();
  if (state_.show_extensions) {
    next_x -= m::kAccessoryPitch;
    extensions_button_->SetBoundsRect(gfx::Rect(next_x, icon_y, 16, 16));
  } else {
    extensions_button_->SetBoundsRect(ExtensionsRect());
  }

  for (size_t i = extension_action_buttons_.size(); i > 0; --i) {
    next_x -= m::kAccessoryPitch;
    extension_action_buttons_[i - 1]->SetBoundsRect(
        gfx::Rect(next_x - 2, ext_action_y, 20, 20));
  }

  const bool show_downloads = state_.show_downloads || state_.downloads_running;
  if (show_downloads) {
    next_x -= m::kAccessoryPitch;
    downloads_button_->SetBoundsRect(gfx::Rect(next_x, icon_y, 16, 16));
  }
  downloads_button_->SetVisible(mode_ == Mode::kPage && show_downloads);

  // Profile chip, then the host centered between chip and accessories. On a
  // narrow page the chip hides before it can cover the host.
  const int accessory_left = next_x;
  const int chip_x = capsule.x() + 13;
  const int available = std::max(0, accessory_left - m::kHostGap - chip_x);
  const int profile_width =
      state_.show_profile
          ? std::min(m::kMaximumProfileWidth,
                     ProfileTextWidth() +
                         (m::kProfileTextX - m::kProfileIcon.x()))
          : 0;
  const int chip_width =
      std::min(profile_width, std::max(0, available - m::kMinimumHostWidth));
  const bool chip_visible = profile_width > 0 && chip_width > 0;
  profile_button_->SetVisible(chip_visible);
  profile_button_->SetBoundsRect(
      gfx::Rect(chip_x, host_y, chip_width, m::kHostHeight));

  const int left = chip_visible ? chip_x + chip_width + m::kHostGap
                                : capsule.x() + m::kHostGap;
  const int right = accessory_left - m::kHostGap;
  host_button_->SetBoundsRect(
      gfx::Rect(left, host_y, std::max(0, right - left), m::kHostHeight));
}

void OpenLittleOpenView::OnPaint(gfx::Canvas* canvas) {
  if (mode_ == Mode::kBar) {
#if BUILDFLAG(IS_WIN)
    // Match Windows 11 DWMWCP_ROUND (8 DIP) so opaque Bar Mode never shows dark
    // corner wedges under the embedded command bar.
    canvas->DrawColor(m::kTitleBarFill);
    secondary::FillRoundRect(canvas, gfx::RectF(GetLocalBounds()), 8.f,
                             m::kTitleBarFill);
#endif
    return;
  }
  // Window body (the page covers everything below the title bar).
#if BUILDFLAG(IS_WIN)
  // Opaque Win32 widget: fill edge-to-edge so DWM DWMWCP_ROUND clips corners
  // without leaving dark notches in restored or maximized states.
  canvas->DrawColor(m::kTitleBarFill);
#else
  secondary::FillRoundRect(canvas, gfx::RectF(GetLocalBounds()),
                           m::kWindowCornerRadius, m::kTitleBarFill);
#endif
  secondary::FillRoundRect(canvas, gfx::RectF(CapsuleRect()), m::kCapsuleRadius,
                           m::kCapsuleFill);
  const gfx::Rect pill = PillRect();
  secondary::FillRoundRect(canvas, gfx::RectF(pill), pill.height() / 2.f,
                           m::kPillFill);
  canvas->FillRect(DividerRect(), secondary::WithAlpha(
                                      SK_ColorWHITE, 0.8f * m::kDividerAlpha));

  // Thin 2 DIP loading progress bar along the bottom edge of the top bar.
  if (page_loading_) {
    const float frac =
        static_cast<float>(std::clamp(load_progress_, 0.12, 1.0));
    const int bar_w =
        std::max(24, static_cast<int>(std::lround(width() * frac)));
    const SkColor bar_color = SkColorGetA(state_.target_space_color) > 0
                                  ? state_.target_space_color
                                  : SkColorSetRGB(0x6F, 0x66, 0xD9);
    canvas->FillRect(gfx::Rect(0, TitleBarHeight() - 2, bar_w, 2), bar_color);
  }
}

void OpenLittleOpenView::PaintPill(gfx::Canvas* canvas,
                                   const gfx::Rect& bounds,
                                   bool hovered) {
  const gfx::FontList regular = secondary::FontOfSize(m::kFontSize);
  const gfx::FontList bold =
      secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::BOLD);
  if (hovered) {
    // Round only the outer left corners so the straight inner edge against the
    // vertical divider stays crisp and flush.
    const float r = bounds.height() / 2.f;
    const SkVector radii[4] = {{r, r}, {0.f, 0.f}, {0.f, 0.f}, {r, r}};
    SkRRect rrect;
    rrect.setRectRadii(gfx::RectToSkRect(bounds), radii);
    SkPathBuilder path;
    path.addRRect(rrect);
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setStyle(cc::PaintFlags::kFill_Style);
    flags.setColor(secondary::WithAlpha(SK_ColorWHITE, 0.08f));
    canvas->DrawPath(path.detach(), flags);
  }
  const std::u16string keycap = KeycapLabel();
  const int keycap_w =
      std::max(m::kKeycapWidth, secondary::TextWidth(keycap, regular) + 8);
  const int label_y = bounds.y() + (bounds.height() - m::kHostHeight) / 2;
  const gfx::Rect label(bounds.x() + 10, label_y,
                        std::max(0, bounds.width() - 18), m::kHostHeight);
  const bool show_keycap = label.width() >= keycap_w + 24;
  const gfx::Rect cap = show_keycap
                            ? gfx::Rect(label.right() - keycap_w, label.y(),
                                        keycap_w, label.height())
                            : gfx::Rect(label.right(), label.y(), 0,
                                        label.height());
  if (show_keycap) {
    secondary::FillRoundRect(canvas, gfx::RectF(cap), m::kKeycapRadius,
                             m::kCapsuleFill);
    secondary::DrawText(canvas, keycap, regular, m::kText, cap,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  // Leading Space color dot inside the pill (matches Space target swatch).
  int text_x = label.x();
  if (state_.space_title && label.width() > 28) {
    const gfx::RectF dot(label.x(), label.y() + 4.5f, 8.f, 8.f);
    secondary::FillRoundRect(canvas, dot, 4.f, state_.target_space_color);
    text_x += 14;
  }

  const SkColor ink = state_.space_title
                          ? m::kText
                          : secondary::WithAlpha(SK_ColorWHITE, 0.35f);
  const std::u16string prefix = u"Open in ";
  const int prefix_w = secondary::TextWidth(prefix, regular);
  const int room =
      std::max(0, (show_keycap ? cap.x() - 6 : label.right()) - text_x);
  secondary::DrawText(canvas, prefix, regular, ink,
                      gfx::Rect(text_x, label.y(), std::min(prefix_w, room),
                                label.height()));
  if (room > prefix_w) {
    secondary::DrawText(canvas, state_.space_title.value_or(u"Space"), bold,
                        ink,
                        gfx::Rect(text_x + prefix_w, label.y(),
                                  room - prefix_w, label.height()));
  }
}

void OpenLittleOpenView::PaintProfile(gfx::Canvas* canvas,
                                      const gfx::Rect& bounds,
                                      bool hovered) {
  if (hovered) {
    gfx::RectF plate(bounds);
    plate.Inset(-2.f);
    secondary::FillRoundRect(canvas, plate, 5.f,
                             secondary::WithAlpha(SK_ColorWHITE, 0.08f));
  }
  const gfx::Rect icon(bounds.x(), bounds.y() + 2, m::kProfileIcon.width(),
                       m::kProfileIcon.height());
  if (state_.profile_icon &&
      state_.profile_icon->kind == SpaceIconKind::kEmoji) {
    secondary::DrawText(canvas,
                        GlyphTextFor(state_.profile_icon, state_.profile_name),
                        secondary::FontOfSize(12), m::kText, icon,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  } else {
    secondary::StrokeRoundRect(canvas, gfx::RectF(icon), icon.width() / 2.f,
                               m::kText, 1.2f);
    secondary::DrawText(canvas, GlyphTextFor(std::nullopt, state_.profile_name),
                        secondary::FontOfSize(8, gfx::Font::Weight::BOLD),
                        m::kText, icon, gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  const int text_x = bounds.x() + (m::kProfileTextX - m::kProfileIcon.x());
  secondary::DrawText(
      canvas, state_.profile_name,
      secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::MEDIUM),
      hovered ? SK_ColorWHITE : m::kText,
      gfx::Rect(text_x, bounds.y(), std::max(0, bounds.right() - text_x),
                bounds.height()));
}

void OpenLittleOpenView::PaintHost(gfx::Canvas* canvas,
                                   const gfx::Rect& bounds,
                                   bool hovered) {
  const gfx::FontList font = secondary::FontOfSize(m::kFontSize);
  const int text =
      std::min(secondary::TextWidth(state_.host, font), bounds.width());
  secondary::DrawText(canvas, state_.host, font,
                      hovered ? SK_ColorWHITE : m::kText,
                      gfx::Rect(bounds.x() + (bounds.width() - text) / 2,
                                bounds.y(), text, bounds.height()));
}

void OpenLittleOpenView::PaintDownloads(gfx::Canvas* canvas,
                                        const gfx::Rect& bounds,
                                        bool hovered) {
  if (hovered) {
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 4.f,
                             secondary::WithAlpha(SK_ColorWHITE, 0.10f));
  }
  const SkColor ink = hovered ? SK_ColorWHITE : m::kText;
  gfx::RectF glyph_box(bounds);
  glyph_box.Inset(2.f);
  secondary::PaintGlyph(canvas, Glyph::kDownload, glyph_box, ink, 1.3f);

  if (!state_.downloads_running) {
    return;
  }
  // Progress ring around the button (port of LittleOpenDownloadsButton.draw).
  gfx::RectF ring(bounds);
  ring.Inset(0.75f);
  secondary::StrokeRoundRect(canvas, ring, ring.width() / 2.f,
                             secondary::WithAlpha(SK_ColorWHITE, 0.25f), 1.5f);
  if (state_.download_progress) {
    const float sweep =
        static_cast<float>(std::clamp(*state_.download_progress, 0.0, 1.0)) *
        360.f;
    if (sweep > 0.f) {
      cc::PaintFlags flags;
      flags.setAntiAlias(true);
      flags.setStyle(cc::PaintFlags::kStroke_Style);
      flags.setStrokeWidth(1.5f);
      flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
      flags.setColor(SK_ColorWHITE);
      SkPathBuilder arc;
      arc.addArc(gfx::RectFToSkRect(ring), -90.f, sweep);
      canvas->DrawPath(arc.detach(), flags);
    }
  } else {
    // Indeterminate active indicator dot at top-right.
    secondary::FillRoundRect(
        canvas, gfx::RectF(bounds.right() - 5.f, bounds.y(), 5.f, 5.f), 2.5f,
        state_.target_space_color);
  }
}

void OpenLittleOpenView::PaintExtensionAction(size_t index,
                                              gfx::Canvas* canvas,
                                              const gfx::Rect& bounds,
                                              bool hovered) {
  if (index >= state_.extension_actions.size()) {
    return;
  }
  if (hovered) {
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 4.f,
                             secondary::WithAlpha(SK_ColorWHITE, 0.12f));
  }
  const LittleOpenExtensionAction& action = state_.extension_actions[index];
  if (!action.icon.isNull()) {
    gfx::Rect icon_rect = bounds;
    icon_rect.Inset(2);
    secondary::DrawImageInRect(canvas, action.icon, icon_rect);
  } else {
    gfx::RectF box(bounds);
    box.Inset(3.f);
    secondary::PaintGlyph(canvas, Glyph::kPuzzle, box,
                          hovered ? SK_ColorWHITE : m::kText, 1.3f);
  }
  if (!action.badge_text.empty()) {
    const gfx::RectF badge(bounds.right() - 7.f, bounds.bottom() - 7.f, 6.f,
                           6.f);
    secondary::FillRoundRect(canvas, badge, 3.f, state_.target_space_color);
  }
}

#if BUILDFLAG(IS_MAC)
void OpenLittleOpenView::PaintWindowButton(int index,
                                           gfx::Canvas* canvas,
                                           const gfx::Rect& bounds,
                                           bool hovered) {
  static constexpr std::array<SkColor, 3> kColors = {
      SkColorSetRGB(0xFF, 0x5F, 0x57), SkColorSetRGB(0xFE, 0xBC, 0x2E),
      SkColorSetRGB(0x28, 0xC8, 0x40)};
  const bool group_hovered =
      hovered ||
      std::any_of(window_buttons_.begin(), window_buttons_.end(),
                  [](const auto& b) {
                    return b &&
                           (b->GetState() == views::Button::STATE_HOVERED ||
                            b->GetState() == views::Button::STATE_PRESSED);
                  });
  const bool active =
      window_active_ && (!GetWidget() || GetWidget()->ShouldPaintAsActive());
  const SkColor fill =
      (active || group_hovered)
          ? kColors[index]
          : secondary::WithAlpha(SK_ColorWHITE, 0.24f);
  const gfx::RectF circle(bounds.CenterPoint().x() - 6.f,
                          bounds.CenterPoint().y() - 6.f, 12.f, 12.f);
  secondary::FillRoundRect(canvas, circle, 6.f, fill);
  if (group_hovered) {
    static constexpr std::array<Glyph, 3> kGlyphs = {
        Glyph::kClose, Glyph::kMinus, Glyph::kPlus};
    gfx::RectF glyph = circle;
    glyph.Inset(2.5f);
    secondary::PaintGlyph(canvas, kGlyphs[index], glyph,
                          secondary::WithAlpha(SK_ColorBLACK, 0.55f), 1.2f);
  }
}

void OpenLittleOpenView::PressWindowButton(int index) {
  views::Widget* widget = GetWidget();
  if (!widget) {
    return;
  }
  switch (index) {
    case 0:
      widget->Close();
      break;
    case 1:
      widget->Minimize();
      break;
    default:
      if (widget->IsMaximized()) {
        widget->Restore();
      } else {
        widget->Maximize();
      }
      break;
  }
}
#endif

void OpenLittleOpenView::ShowSpacePicker() {
  if (state_.spaces.empty() || picker_widget_) {
    return;
  }
  picker_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      chevron_button_.get(), views::BubbleBorder::TOP_RIGHT,
      views::BubbleBorder::DIALOG_SHADOW, /*autosize=*/true);
  picker_delegate_->set_margins(gfx::Insets());
  picker_delegate_->set_fixed_width(m::kPickerWidth);
  picker_delegate_->set_corner_radius(m::kWindowCornerRadius);
  picker_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  picker_delegate_->SetShowCloseButton(false);
  picker_delegate_->SetShowTitle(false);
  picker_delegate_->SetBackgroundColor(m::kTitleBarFill);
  picker_delegate_->SetContentsView(std::make_unique<SpacePickerView>(
      state_.spaces, state_.target_space_id,
      base::BindRepeating(
          [](base::WeakPtr<OpenLittleOpenView> self, const SpaceID& id,
             bool target_only) {
            if (!self) {
              return;
            }
            if (target_only) {
              self->state_.target_space_id = id;
              for (const LittleOpenSpaceChoice& choice : self->state_.spaces) {
                if (choice.id == id) {
                  self->state_.space_title = choice.title;
                  self->state_.target_space_color = choice.color;
                  self->state_.target_space_icon = choice.icon;
                  break;
                }
              }
              self->InvalidateLayout();
              self->SchedulePaint();
              if (self->delegate_) {
                self->delegate_->OnLittleOpenTargetSpaceChanged(id);
              }
              return;
            }
            self->TriggerOpenInSpace(id);
          },
          weak_factory_.GetWeakPtr())));
  picker_widget_ = views::BubbleDialogDelegate::CreateBubble(
      picker_delegate_.get(), base::BindOnce(
                                  [](base::WeakPtr<OpenLittleOpenView> self,
                                     views::Widget::ClosedReason reason) {
                                    if (self) {
                                      self->OnSpacePickerClosed();
                                    }
                                  },
                                  weak_factory_.GetWeakPtr()));
  picker_widget_->Show();
}

void OpenLittleOpenView::OnSpacePickerClosed() {
  if (picker_widget_) {
    picker_widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(picker_widget_));
  }
  if (picker_delegate_) {
    picker_delegate_->SetAnchorView(nullptr);
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(picker_delegate_));
  }
}

void OpenLittleOpenView::ShowProfilePicker() {
  if (state_.profiles.empty() || profile_picker_widget_) {
    return;
  }
  profile_picker_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      profile_button_.get(), views::BubbleBorder::TOP_LEFT,
      views::BubbleBorder::DIALOG_SHADOW, /*autosize=*/true);
  profile_picker_delegate_->set_margins(gfx::Insets());
  profile_picker_delegate_->set_fixed_width(m::kPickerWidth);
  profile_picker_delegate_->set_corner_radius(m::kWindowCornerRadius);
  profile_picker_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  profile_picker_delegate_->SetShowCloseButton(false);
  profile_picker_delegate_->SetShowTitle(false);
  profile_picker_delegate_->SetBackgroundColor(m::kTitleBarFill);
  profile_picker_delegate_->SetContentsView(std::make_unique<ProfilePickerView>(
      state_.profiles,
      base::BindRepeating(
          [](base::WeakPtr<OpenLittleOpenView> self, const ProfileID& id) {
            if (!self) {
              return;
            }
            if (self->delegate_) {
              self->delegate_->OnLittleOpenProfileSelected(id);
            }
          },
          weak_factory_.GetWeakPtr())));
  profile_picker_widget_ = views::BubbleDialogDelegate::CreateBubble(
      profile_picker_delegate_.get(),
      base::BindOnce(
          [](base::WeakPtr<OpenLittleOpenView> self,
             views::Widget::ClosedReason reason) {
            if (self) {
              self->OnProfilePickerClosed();
            }
          },
          weak_factory_.GetWeakPtr()));
  profile_picker_widget_->Show();
}

void OpenLittleOpenView::OnProfilePickerClosed() {
  if (profile_picker_widget_) {
    profile_picker_widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(profile_picker_widget_));
  }
  if (profile_picker_delegate_) {
    profile_picker_delegate_->SetAnchorView(nullptr);
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(profile_picker_delegate_));
  }
}

BEGIN_METADATA(OpenLittleOpenView)
END_METADATA

// --- OpenLittleOpenWindow ----------------------------------------------------

OpenLittleOpenWindow::OpenLittleOpenWindow() = default;

OpenLittleOpenWindow::~OpenLittleOpenWindow() {
  view_ = nullptr;
  // The widget owns the contents and frame views: drop the delegate's raw
  // pointers to them before the widget destroys them.
  if (delegate_) {
    static_cast<LittleOpenWindowDelegate*>(delegate_.get())->ReleaseViews();
  }
  widget_.reset();  // Then the widget: it refers to its delegate.
  delegate_.reset();
}

// static
std::unique_ptr<OpenLittleOpenWindow> OpenLittleOpenWindow::Create(
    LittleOpenDelegate* delegate,
    const gfx::Rect& bounds_in_screen,
    OpenLittleOpenView::Mode mode) {
  auto window = base::WrapUnique(new OpenLittleOpenWindow());
  auto window_delegate = std::make_unique<LittleOpenWindowDelegate>(delegate);
  OpenLittleOpenView* contents = window_delegate->SetContentsView(
      std::make_unique<OpenLittleOpenView>(delegate));
  window_delegate->set_contents(contents);
  contents->SetMode(mode);

  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET,
      views::Widget::InitParams::TYPE_WINDOW);
  params.delegate = window_delegate.get();
  params.bounds = bounds_in_screen;
  params.remove_standard_frame = true;
#if BUILDFLAG(IS_WIN)
  // On Windows, kOpaque + kNone preserves WS_THICKFRAME/WS_CAPTION for Aero
  // Snap and taskbar-safe maximize while avoiding legacy XP CS_DROPSHADOW;
  // ApplyWindowEffects() below enables Windows 11 DWMWCP_ROUND shadow.
  params.opacity = views::Widget::InitParams::WindowOpacity::kOpaque;
  params.shadow_type = views::Widget::InitParams::ShadowType::kNone;
#else
  params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
  params.shadow_type = views::Widget::InitParams::ShadowType::kDrop;
#endif
  params.name = "OpenLittleOpen";
  window->delegate_ = std::move(window_delegate);
  window->widget_ = std::make_unique<views::Widget>();
  window->widget_->Init(std::move(params));
#if BUILDFLAG(IS_WIN)
  if (OpenPlatform* platform = OpenPlatform::Get()) {
    platform->ApplyWindowEffects(window->widget_.get(), /*dark_mode=*/true);
  }
#endif
  window->view_ = contents;
  return window;
}

void OpenLittleOpenWindow::Show() {
  if (widget_) {
    widget_->Show();
  }
}

}  // namespace open_unified
