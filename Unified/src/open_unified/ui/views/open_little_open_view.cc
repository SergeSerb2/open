// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_little_open_view.h"

#include <algorithm>
#include <array>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/ptr_util.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "content/public/browser/web_contents.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/hit_test.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/background.h"
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
// Bar mode: the top strip above the embedded bar's input drags the window
// (guess: no capture shows a bar-mode drag).
constexpr int kBarDragStrip = 10;

// Emoji when the icon is one, else the first letter of `name`.
std::u16string GlyphTextFor(const std::optional<SpaceIcon>& icon,
                            const std::u16string& name) {
  if (icon && icon->kind == SpaceIconKind::kEmoji && !icon->value.empty()) {
    return base::UTF8ToUTF16(icon->value);
  }
  return name.empty() ? std::u16string(u"•") : name.substr(0, 1);
}

// --- Frameless frame: drag from the title bar, resize from the edges. ------

class LittleOpenFrameView : public views::FrameView {
  METADATA_HEADER(LittleOpenFrameView, views::FrameView)

 public:
  explicit LittleOpenFrameView(views::Widget* widget) : widget_(widget) {}

  void set_contents(OpenLittleOpenView* contents) { contents_ = contents; }

  // views::FrameView:
  gfx::Rect GetBoundsForClientView() const override { return bounds(); }
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
  using PickCallback = base::RepeatingCallback<void(const SpaceID&)>;

  SpacePickerView(std::vector<LittleOpenSpaceChoice> spaces,
                  PickCallback on_pick)
      : spaces_(std::move(spaces)), on_pick_(std::move(on_pick)) {
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
                                 secondary::WithAlpha(SK_ColorWHITE, 0.07f));
      }
      const gfx::Rect icon(row.x() + 6,
                           row.y() + (row.height() - m::kPickerIconSize) / 2,
                           m::kPickerIconSize, m::kPickerIconSize);
      secondary::FillRoundRect(canvas, gfx::RectF(icon), m::kPickerIconRadius,
                               space.color);
      secondary::DrawText(canvas, GlyphTextFor(space.icon, space.title),
                          secondary::FontOfSize(17), SK_ColorWHITE, icon,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
      secondary::DrawText(
          canvas, space.title, secondary::FontOfSize(m::kFontSize), m::kText,
          gfx::Rect(icon.right() + 10, row.y(), row.right() - icon.right() - 16,
                    row.height()));
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
          Pick(*hovered_);
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

  void Pick(size_t index) {
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
    on_pick.Run(id);
  }

  std::vector<LittleOpenSpaceChoice> spaces_;
  PickCallback on_pick_;
  std::optional<size_t> hovered_;
  size_t scroll_ = 0;
};

BEGIN_METADATA(SpacePickerView)
END_METADATA

}  // namespace

// --- OpenLittleOpenView ------------------------------------------------------

OpenLittleOpenView::OpenLittleOpenView(LittleOpenDelegate* delegate)
    : delegate_(delegate) {
  GetViewAccessibility().SetName(u"Little Open");

  for (int i = 0; i < 3; ++i) {
    static constexpr std::array<const char16_t*, 3> kNames = {
        u"Close", u"Minimize", u"Zoom"};
    window_buttons_[i] = AddChildView(std::make_unique<PaintedButton>(
        base::BindRepeating(&OpenLittleOpenView::PressWindowButton,
                            base::Unretained(this), i),
        base::BindRepeating(&OpenLittleOpenView::PaintWindowButton,
                            base::Unretained(this), i),
        kNames[i]));
  }

  profile_button_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->delegate_) {
              self->delegate_->OnLittleOpenProfile(self->profile_button_);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintProfile,
                          base::Unretained(this)),
      u"Profile"));

  host_button_ = AddChildView(std::make_unique<PaintedButton>(
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

  auto make_glyph = [this](Glyph glyph, const char16_t* name,
                           views::Button::PressedCallback callback) {
    auto button =
        std::make_unique<GlyphButton>(std::move(callback), glyph, name);
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

  pill_button_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenLittleOpenView* self) {
            if (self->delegate_ && self->state_.space_title) {
              self->delegate_->OnLittleOpenOpenInSpace(std::nullopt);
            }
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenLittleOpenView::PaintPill,
                          base::Unretained(this)),
      u"Open in Space"));

  web_view_ = AddChildView(std::make_unique<views::WebView>());
  web_view_->SetBackground(views::CreateSolidBackground(SK_ColorWHITE));

  AddAccelerator(ui::Accelerator(ui::VKEY_O, secondary::kPrimaryModifier));
  SetMode(Mode::kBar);
}

OpenLittleOpenView::~OpenLittleOpenView() {
  web_view_->SetWebContents(nullptr);
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
  // std::clamp needs lo <= hi: a work area smaller than the minimum page
  // size (or empty) caps the minimum instead.
  const int max_width = std::max(0, work_area.width());
  const int max_height = std::max(0, work_area.height());
  const int width = std::clamp(
      m::kPageSize.width(), std::min(m::kMinimumPageSize.width(), max_width),
      max_width);
  const int height = std::clamp(
      m::kPageSize.height(),
      std::min(m::kMinimumPageSize.height() + m::kTitleBarHeight, max_height),
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
  for (auto& button : window_buttons_) {
    button->SetVisible(page);
  }
  profile_button_->SetVisible(page && state_.show_profile);
  host_button_->SetVisible(page);
  copy_button_->SetVisible(page);
  extensions_button_->SetVisible(page && state_.show_extensions);
  pill_button_->SetVisible(page);
  chevron_button_->SetVisible(page);
  web_view_->SetVisible(page && web_view_->web_contents());
  if (bar_contents_) {
    bar_contents_->SetVisible(!page);
  }
  InvalidateLayout();
  SchedulePaint();
}

void OpenLittleOpenView::SetState(const LittleOpenState& state) {
  state_ = state;
  pill_button_->SetEnabled(state_.space_title.has_value());
  pill_button_->GetViewAccessibility().SetName(
      u"Open in " + state_.space_title.value_or(u"Space") + u" " +
      KeycapLabel());
  host_button_->GetViewAccessibility().SetName(state_.host);
  profile_button_->GetViewAccessibility().SetName(u"Profile: " +
                                                  state_.profile_name);
  chevron_button_->SetEnabled(!state_.spaces.empty());
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
  if (web_view_->web_contents() != contents) {
    web_view_->SetWebContents(contents);
  }
  web_view_->SetVisible(mode_ == Mode::kPage && contents);
  InvalidateLayout();
}

int OpenLittleOpenView::NonClientHitTest(const gfx::Point& point) const {
  if (mode_ == Mode::kBar) {
    return point.y() < kBarDragStrip ? HTCAPTION : HTCLIENT;
  }
  if (point.y() >= m::kTitleBarHeight) {
    return HTCLIENT;
  }
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
  const int w = width();
  if (name == "capsule") {
    return m::Capsule(w);
  }
  if (name == "profile") {
    return profile_button_->GetVisible()
               ? std::optional<gfx::Rect>(profile_button_->bounds())
               : std::nullopt;
  }
  if (name == "host") {
    return host_button_->bounds();
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
    return m::Pill(w);
  }
  if (name == "open") {
    return m::PillLabel(w);
  }
  if (name == "chevron") {
    return m::Chevron(w);
  }
  if (name == "divider") {
    return m::Divider(w);
  }
  return std::nullopt;
}

gfx::Size OpenLittleOpenView::GetMinimumSize() const {
  return mode_ == Mode::kPage
             ? gfx::Size(m::kMinimumPageSize.width(),
                         m::kMinimumPageSize.height() + m::kTitleBarHeight)
             : m::kBarSize;
}

bool OpenLittleOpenView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (accelerator.key_code() == ui::VKEY_O && mode_ == Mode::kPage &&
      state_.space_title && delegate_) {
    delegate_->OnLittleOpenOpenInSpace(std::nullopt);
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
  web_view_->SetBoundsRect(
      gfx::Rect(0, m::kTitleBarHeight, bounds.width(),
                std::max(0, bounds.height() - m::kTitleBarHeight)));
  const float r = m::kWindowCornerRadius;
  web_view_->holder()->SetNativeViewCornerRadii(
      gfx::RoundedCornersF(0, 0, r, r));
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
  const int w = width();
  for (int i = 0; i < 3; ++i) {
    window_buttons_[i]->SetBoundsRect(
        gfx::Rect(m::kWindowButtonX[i], m::kWindowButtonY, m::kWindowButtonSize,
                  m::kWindowButtonSize));
  }
  copy_button_->SetBoundsRect(m::Copy(w));
  extensions_button_->SetBoundsRect(m::Extensions(w));
  chevron_button_->SetBoundsRect(m::Chevron(w));
  // The pill's clickable part ends at the divider; the chevron is its own.
  const gfx::Rect pill = m::Pill(w);
  pill_button_->SetBoundsRect(gfx::Rect(
      pill.x(), pill.y(), m::Divider(w).x() - pill.x(), pill.height()));

  // Profile chip, then the host centered between chip and accessories. On a
  // narrow page the chip hides before it can cover the host (guess, as in
  // LittleOpenTitleBarView).
  const gfx::Rect capsule = m::Capsule(w);
  const int accessory_left =
      state_.show_extensions ? m::Extensions(w).x() : m::Copy(w).x();
  const int chip_x = m::kProfileIcon.x();
  const int available = std::max(0, accessory_left - m::kHostGap - chip_x);
  const int profile_width =
      state_.show_profile
          ? std::min(m::kMaximumProfileWidth,
                     ProfileTextWidth() + m::kProfileTextX - chip_x)
          : 0;
  const int chip_width =
      std::min(profile_width, std::max(0, available - m::kMinimumHostWidth));
  const bool chip_visible = profile_width > 0 && chip_width > 0;
  profile_button_->SetVisible(chip_visible);
  profile_button_->SetBoundsRect(
      gfx::Rect(chip_x, m::kHostY, chip_width, m::kHostHeight));

  const int left = chip_visible ? chip_x + chip_width + m::kHostGap
                                : capsule.x() + m::kHostGap;
  const int right = accessory_left - m::kHostGap;
  host_button_->SetBoundsRect(
      gfx::Rect(left, m::kHostY, std::max(0, right - left), m::kHostHeight));
}

void OpenLittleOpenView::OnPaint(gfx::Canvas* canvas) {
  if (mode_ == Mode::kBar) {
    return;  // The embedded bar paints its own 12 pt card.
  }
  const int w = width();
  // Window body (the page covers everything below the title bar).
  secondary::FillRoundRect(canvas, gfx::RectF(GetLocalBounds()),
                           m::kWindowCornerRadius, m::kTitleBarFill);
  secondary::FillRoundRect(canvas, gfx::RectF(m::Capsule(w)), m::kCapsuleRadius,
                           m::kCapsuleFill);
  secondary::FillRoundRect(canvas, gfx::RectF(m::Pill(w)), m::kPillRadius,
                           m::kPillFill);
  canvas->FillRect(m::Divider(w), secondary::WithAlpha(
                                      SK_ColorWHITE, 0.8f * m::kDividerAlpha));
}

void OpenLittleOpenView::PaintPill(gfx::Canvas* canvas,
                                   const gfx::Rect& bounds,
                                   bool hovered) {
  // Coordinates: the button starts at the pill's x; the label box is
  // [w - 191, 15, 148, 17] in window terms, i.e. x + 5, y + 7 here.
  const gfx::FontList regular = secondary::FontOfSize(m::kFontSize);
  const gfx::FontList bold =
      secondary::FontOfSize(m::kFontSize, gfx::Font::Weight::BOLD);
  if (hovered) {
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), m::kPillRadius,
                             secondary::WithAlpha(SK_ColorWHITE, 0.06f));
  }
  const std::u16string keycap = KeycapLabel();
  const int keycap_w =
      std::max(m::kKeycapWidth, secondary::TextWidth(keycap, regular) + 8);
  const gfx::Rect label(bounds.x() + 5, bounds.y() + 7, 148, 17);
  const gfx::Rect cap(label.right() - keycap_w, label.y(), keycap_w,
                      label.height());
  secondary::FillRoundRect(canvas, gfx::RectF(cap), m::kKeycapRadius,
                           m::kCapsuleFill);
  secondary::DrawText(canvas, keycap, regular, m::kText, cap,
                      gfx::Canvas::TEXT_ALIGN_CENTER);

  const SkColor ink = state_.space_title
                          ? m::kText
                          : secondary::WithAlpha(SK_ColorWHITE, 0.35f);
  const std::u16string prefix = u"Open in ";
  const int prefix_w = secondary::TextWidth(prefix, regular);
  const int room = std::max(0, cap.x() - 4 - label.x());
  secondary::DrawText(canvas, prefix, regular, ink,
                      gfx::Rect(label.x(), label.y(), std::min(prefix_w, room),
                                label.height()));
  secondary::DrawText(canvas, state_.space_title.value_or(u"Space"), bold, ink,
                      gfx::Rect(label.x() + prefix_w, label.y(),
                                std::max(0, room - prefix_w), label.height()));
}

void OpenLittleOpenView::PaintProfile(gfx::Canvas* canvas,
                                      const gfx::Rect& bounds,
                                      bool hovered) {
  // Icon [97, 17, 14, 14] in window terms: x + 0, y + 2 here.
  const gfx::Rect icon(bounds.x(), bounds.y() + 2, m::kProfileIcon.width(),
                       m::kProfileIcon.height());
  if (state_.profile_icon &&
      state_.profile_icon->kind == SpaceIconKind::kEmoji) {
    secondary::DrawText(canvas,
                        GlyphTextFor(state_.profile_icon, state_.profile_name),
                        secondary::FontOfSize(12), m::kText, icon,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  } else {
    // Open's own profile mark: the initial in a ring (no SF Symbols here).
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

void OpenLittleOpenView::PaintWindowButton(int index,
                                           gfx::Canvas* canvas,
                                           const gfx::Rect& bounds,
                                           bool hovered) {
#if BUILDFLAG(IS_MAC)
  // 12 pt circles centered in the 16 pt frames (ChromeMetrics traffic
  // lights); system close / minimize / zoom colors; glyphs on hover.
  static constexpr std::array<SkColor, 3> kColors = {
      SkColorSetRGB(0xFF, 0x5F, 0x57), SkColorSetRGB(0xFE, 0xBC, 0x2E),
      SkColorSetRGB(0x28, 0xC8, 0x40)};
  const gfx::RectF circle(bounds.CenterPoint().x() - 6.f,
                          bounds.CenterPoint().y() - 6.f, 12.f, 12.f);
  secondary::FillRoundRect(canvas, circle, 6.f, kColors[index]);
  if (hovered) {
    static constexpr std::array<Glyph, 3> kGlyphs = {
        Glyph::kClose, Glyph::kMinus, Glyph::kPlus};
    gfx::RectF glyph = circle;
    glyph.Inset(2.5f);
    secondary::PaintGlyph(canvas, kGlyphs[index], glyph,
                          secondary::WithAlpha(SK_ColorBLACK, 0.55f), 1.2f);
  }
#else
  // Open's monochrome caption glyphs on Windows and Linux.
  static constexpr std::array<Glyph, 3> kGlyphs = {Glyph::kClose, Glyph::kMinus,
                                                   Glyph::kSquare};
  if (hovered) {
    secondary::FillRoundRect(canvas, gfx::RectF(bounds), 4.f,
                             index == 0
                                 ? SkColorSetRGB(0xC4, 0x2B, 0x1C)
                                 : secondary::WithAlpha(SK_ColorWHITE, 0.12f));
  }
  gfx::RectF glyph(bounds);
  glyph.Inset(3.f);
  secondary::PaintGlyph(canvas, kGlyphs[index], glyph,
                        hovered && index == 0 ? SK_ColorWHITE : m::kText, 1.3f);
#endif
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

void OpenLittleOpenView::ShowSpacePicker() {
  if (state_.spaces.empty() || !delegate_ || picker_widget_) {
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
      state_.spaces,
      base::BindRepeating(
          [](base::WeakPtr<OpenLittleOpenView> self, const SpaceID& id) {
            if (self && self->delegate_) {
              self->delegate_->OnLittleOpenOpenInSpace(id);
            }
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
  // The close can start inside the bubble's own activation handling: hide
  // now, delete on the next task (widget before its delegate).
  if (picker_widget_) {
    picker_widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(picker_widget_));
  }
  if (picker_delegate_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(picker_delegate_));
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
  params.opacity = views::Widget::InitParams::WindowOpacity::kTranslucent;
  params.shadow_type = views::Widget::InitParams::ShadowType::kDrop;
  params.name = "OpenLittleOpen";
  window->delegate_ = std::move(window_delegate);
  window->widget_ = std::make_unique<views::Widget>();
  window->widget_->Init(std::move(params));
  window->view_ = contents;
  return window;
}

void OpenLittleOpenWindow::Show() {
  if (widget_) {
    widget_->Show();
  }
}

}  // namespace open_unified
