// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_find_bar_and_toasts.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "cc/paint/paint_flags.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/border.h"
#include "ui/views/controls/textfield/textfield.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::GlyphButton;
using secondary::PaintedButton;

// BaseAssets PopoverBackground: P3 light (0.980, 0.984, 1), dark
// (0.082, 0.110, 0.188) (page-chrome.md §1).
constexpr SkColor kPopoverLight = SkColorSetRGB(0xFA, 0xFB, 0xFF);
constexpr SkColor kPopoverDark = SkColorSetRGB(0x15, 0x1C, 0x30);
// PopoverShadow (0.082, 0.110, 0.196) at 0.30 light / 0.80 dark.
constexpr SkColor kPopoverShadowLight = SkColorSetARGB(0x4D, 0x15, 0x1C, 0x32);
constexpr SkColor kPopoverShadowDark = SkColorSetARGB(0xCC, 0x15, 0x1C, 0x32);
// ARCUI PopoverInputText: light (0.055, 0.059, 0.063, 0.80), dark
// (0.980, 0.984, 1, 0.90).
constexpr SkColor kInputTextLight = SkColorSetARGB(0xCC, 0x0E, 0x0F, 0x10);
constexpr SkColor kInputTextDark = SkColorSetARGB(0xE6, 0xFA, 0xFB, 0xFF);
// FindInPageError (0.788, 0.200, 0.200), no dark variant.
constexpr SkColor kFindError = SkColorSetRGB(0xC9, 0x33, 0x33);
// FindInPageSeparator: black 10 %, no dark variant.
constexpr SkColor kFindSeparator = SkColorSetARGB(0x1A, 0x00, 0x00, 0x00);
constexpr int kQueryFontSize = 13;
constexpr int kCountFontSize = 12;

}  // namespace

// ===========================================================================
// OpenFindBarView.
// ===========================================================================

OpenFindBarView::OpenFindBarView(FindBarDelegate* delegate)
    : delegate_(delegate) {
  namespace m = find_bar_metrics;
  SetBorder(views::CreateEmptyBorder(gfx::Insets(m::kShadowMargin)));
  GetViewAccessibility().SetRole(ax::mojom::Role::kSearch);
  GetViewAccessibility().SetName(u"Find in page");

  auto field = std::make_unique<views::Textfield>();
  field->set_controller(this);
  field->SetBorder(views::CreateEmptyBorder(gfx::Insets()));
  field->SetBackgroundEnabled(false);
  field->SetFontList(secondary::FontOfSize(kQueryFontSize));
  field->SetPlaceholderText(u"Find in page...");
  field->GetViewAccessibility().SetName(u"Find in page");
  field_ = AddChildView(std::move(field));

  auto make_button = [this](Glyph glyph, const char16_t* name,
                            views::Button::PressedCallback callback) {
    auto button =
        std::make_unique<GlyphButton>(std::move(callback), glyph, name);
    button->SetGlyphSize(find_bar_metrics::kButtonGlyph);
    button->SetPlate(GlyphButton::Plate::kHoverRounded, SK_ColorTRANSPARENT,
                     4.f);
    return AddChildView(std::move(button));
  };
  previous_ = make_button(Glyph::kChevronUp, u"Previous",
                          base::BindRepeating(
                              [](OpenFindBarView* self) {
                                if (self->delegate_) {
                                  self->delegate_->OnFindNext(false);
                                }
                              },
                              base::Unretained(this)));
  next_ = make_button(Glyph::kChevronDown, u"Next",
                      base::BindRepeating(
                          [](OpenFindBarView* self) {
                            if (self->delegate_) {
                              self->delegate_->OnFindNext(true);
                            }
                          },
                          base::Unretained(this)));
  close_ = make_button(
      Glyph::kClose, u"Close",
      base::BindRepeating(&OpenFindBarView::Close, base::Unretained(this)));
  SetAppearance(appearance_);
  UpdateButtons();
}

OpenFindBarView::~OpenFindBarView() {
  field_->set_controller(nullptr);
}

// static
gfx::Rect OpenFindBarView::ComputeAnchor(const gfx::Rect& page_container,
                                         bool has_content_toolbar) {
  namespace m = find_bar_metrics;
  const int top = has_content_toolbar ? m::kTopInsetWithToolbar : m::kInset;
  return gfx::Rect(page_container.x() + m::kInset, page_container.y() + top,
                   std::max(0, page_container.width() - 2 * m::kInset),
                   std::max(0, page_container.height() - top - m::kInset));
}

// static
int OpenFindBarView::ComputeBottom(const gfx::Rect& page_container,
                                   bool has_content_toolbar) {
  return ComputeAnchor(page_container, has_content_toolbar).y() +
         find_bar_metrics::kHeight;
}

void OpenFindBarView::Activate(const std::u16string& seed_query) {
  if (!seed_query.empty() && seed_query != field_->GetText()) {
    field_->SetText(seed_query);
    if (delegate_) {
      delegate_->OnFindQueryChanged(seed_query);
    }
  }
  field_->RequestFocus();
  field_->SelectAll(false);
}

void OpenFindBarView::SetResult(int active_ordinal, int total) {
  active_ordinal_ = active_ordinal;
  total_ = total;
  result_type_ =
      field_->GetText().empty()
          ? ResultType::kEmpty
          : (total > 0 ? ResultType::kResults : ResultType::kNoResults);
  UpdateButtons();
  InvalidateLayout();
  SchedulePaint();
}

void OpenFindBarView::ClearResult() {
  result_type_ = ResultType::kEmpty;
  active_ordinal_ = 0;
  total_ = 0;
  UpdateButtons();
  InvalidateLayout();
  SchedulePaint();
}

std::u16string_view OpenFindBarView::query() const {
  return field_->GetText();
}

void OpenFindBarView::SetAppearance(const secondary::Appearance& appearance) {
  appearance_ = appearance;
  const SkColor tint = appearance_.dark ? kInputTextDark : kInputTextLight;
  for (GlyphButton* button : {previous_.get(), next_.get(), close_.get()}) {
    button->SetGlyphColor(tint);
    button->SetHoverFill(secondary::WithAlpha(
        appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK, 0.07f));
  }
  SchedulePaint();
}

gfx::Rect OpenFindBarView::inner_bounds() const {
  gfx::Rect r = GetLocalBounds();
  r.Inset(GetInsets());
  return r;
}

gfx::Size OpenFindBarView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  // Preferred width 300 at low priority: never wider than the anchor.
  int width = find_bar_metrics::kWidth;
  if (available_size.width().is_bounded()) {
    // Never negative, even when the anchor is narrower than the insets.
    width = std::max(
        0, std::min(width,
                    available_size.width().value() - GetInsets().width()));
  }
  return gfx::Size(width + GetInsets().width(),
                   find_bar_metrics::kHeight + GetInsets().height());
}

void OpenFindBarView::UpdateButtons() {
  const bool results = result_type_ == ResultType::kResults;
  previous_->SetVisible(results);
  next_->SetVisible(results);
}

void OpenFindBarView::Layout(PassKey) {
  namespace m = find_bar_metrics;
  const gfx::Rect inner = inner_bounds();
  const int button = m::kButtonGlyph + 2 * m::kButtonInset;
  const int button_y = inner.y() + (inner.height() - button) / 2;
  close_->SetBoundsRect(gfx::Rect(inner.right() - m::kCloseTrailing - button,
                                  button_y, button, button));
  separator_x_ = close_->x() - 2;  // close.minX − 1.5, on the pixel grid.

  int results_left = separator_x_;
  count_rect_ = gfx::Rect();
  const gfx::FontList count_font = secondary::FontOfSize(kCountFontSize);
  if (result_type_ == ResultType::kResults) {
    next_->SetBoundsRect(
        gfx::Rect(separator_x_ - 2 - button, button_y, button, button));
    previous_->SetBoundsRect(
        gfx::Rect(next_->x() - button, button_y, button, button));
    const std::u16string count = base::NumberToString16(active_ordinal_) +
                                 u"/" + base::NumberToString16(total_);
    const int w = secondary::TextWidth(count, count_font);
    count_rect_ =
        gfx::Rect(previous_->x() - 2 - w, inner.y(), w, inner.height());
    results_left = count_rect_.x();
  } else if (result_type_ == ResultType::kNoResults) {
    const int w = secondary::TextWidth(u"Not Found", count_font);
    count_rect_ = gfx::Rect(separator_x_ - 6 - w, inner.y(), w, inner.height());
    results_left = count_rect_.x();
  }
  const int field_x = inner.x() + m::kQueryX;
  const int field_h = field_->GetFontList().GetHeight() + 4;
  field_->SetBoundsRect(gfx::Rect(
      field_x, inner.y() + (inner.height() - field_h) / 2,
      std::max(0, results_left - m::kQueryTrailingGap - field_x), field_h));
}

void OpenFindBarView::OnPaint(gfx::Canvas* canvas) {
  namespace m = find_bar_metrics;
  const gfx::Rect inner = inner_bounds();
  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(inner), m::kCornerRadius,
      appearance_.dark ? kPopoverDark : kPopoverLight,
      appearance_.dark ? kPopoverShadowDark : kPopoverShadowLight, 3.f, 5.f);
  const SkColor tint = appearance_.dark ? kInputTextDark : kInputTextLight;
  const int icon_y = inner.y() + (inner.height() - m::kSearchIconBox) / 2;
  const gfx::Rect icon(inner.x() + m::kSearchIconX, icon_y, m::kSearchIconBox,
                       m::kSearchIconBox);
  const float g = m::kSearchGlyph;
  secondary::PaintGlyph(canvas, Glyph::kSearch,
                        gfx::RectF(icon.CenterPoint().x() - g / 2.f,
                                   icon.CenterPoint().y() - g / 2.f, g, g),
                        tint);
  const gfx::FontList count_font = secondary::FontOfSize(kCountFontSize);
  if (result_type_ == ResultType::kResults) {
    secondary::DrawText(canvas,
                        base::NumberToString16(active_ordinal_) + u"/" +
                            base::NumberToString16(total_),
                        count_font, tint, count_rect_);
  } else if (result_type_ == ResultType::kNoResults) {
    secondary::DrawText(canvas, u"Not Found", count_font, kFindError,
                        count_rect_);
  }
  // Separator: hidden when the results container is empty.
  if (result_type_ != ResultType::kEmpty) {
    canvas->FillRect(
        gfx::Rect(separator_x_, inner.y() + m::kSeparatorVerticalInset, 1,
                  inner.height() - 2 * m::kSeparatorVerticalInset),
        appearance_.dark ? secondary::WithAlpha(SK_ColorWHITE, 0.10f)
                         : kFindSeparator);
  }
}

void OpenFindBarView::ContentsChanged(views::Textfield* sender,
                                      const std::u16string& new_contents) {
  if (field_->HasCompositionText()) {
    return;
  }
  if (new_contents.empty()) {
    ClearResult();
  }
  if (delegate_) {
    delegate_->OnFindQueryChanged(new_contents);
  }
}

bool OpenFindBarView::HandleKeyEvent(views::Textfield* sender,
                                     const ui::KeyEvent& event) {
  if (event.type() != ui::EventType::kKeyPressed ||
      field_->HasCompositionText()) {
    return false;
  }
  switch (event.key_code()) {
    case ui::VKEY_ESCAPE:
      Close();
      return true;
    case ui::VKEY_RETURN:
      if (delegate_ && !field_->GetText().empty()) {
        delegate_->OnFindNext(!event.IsShiftDown());
      }
      return true;
    default:
      return false;
  }
}

void OpenFindBarView::Close() {
  if (delegate_) {
    delegate_->OnFindClosed();
  }
}

BEGIN_METADATA(OpenFindBarView)
END_METADATA

// ===========================================================================
// Toasts.
// ===========================================================================

// static
ToastSpec ToastSpec::CopiedUrl() {
  ToastSpec spec;
  spec.title = u"Copied Current URL";
  spec.glyph = Glyph::kLink;
  return spec;
}

// static
ToastSpec ToastSpec::TabArchived(base::OnceClosure undo) {
  ToastSpec spec;
  spec.title = u"Tab Archived";
  spec.glyph = Glyph::kCheck;
  spec.button_label = u"Undo";
  spec.button_action = std::move(undo);
  return spec;
}

// static
ToastSpec ToastSpec::SpaceSwitched(const std::u16string& space_title,
                                   const std::u16string& icon_text) {
  ToastSpec spec;
  spec.title = space_title;
  spec.leading_text = icon_text;
  return spec;
}

namespace toast_internal {

class ToastView : public views::View {
  METADATA_HEADER(ToastView, views::View)

 public:
  ToastView(OpenToastStackView* stack,
            ToastSpec spec,
            const secondary::Appearance& appearance)
      : stack_(stack), spec_(std::move(spec)), appearance_(appearance) {
    namespace m = toast_metrics;
    GetViewAccessibility().SetRole(ax::mojom::Role::kAlert);
    GetViewAccessibility().SetName(spec_.title);
    if (!spec_.button_label.empty()) {
      button_ = AddChildView(std::make_unique<PaintedButton>(
          base::BindRepeating(&ToastView::PressButton, base::Unretained(this)),
          base::BindRepeating(&ToastView::PaintButton, base::Unretained(this)),
          spec_.button_label));
    }
    lifetime_ = spec_.lifetime.value_or(
        spec_.button_label.empty() ? m::kLifetime : m::kLifetimeWithButton);
    timer_.Start(FROM_HERE, lifetime_,
                 base::BindOnce(&ToastView::Expire, base::Unretained(this)));
  }

  int PreferredWidth() const {
    namespace m = toast_metrics;
    int width = m::kLeadingPadding;
    if (!spec_.leading_text.empty() || spec_.glyph != Glyph::kNone) {
      width += m::kSymbolSize + m::kSymbolToTitle;
    }
    width += secondary::TextWidth(spec_.title, title_font());
    width += button_ ? m::kLabelToButton + ButtonWidth() + m::kButtonTrailing
                     : m::kTrailingPadding;
    return std::clamp(width, m::kMinWidth, m::kMaxWidth);
  }

  int PreferredHeight() const {
    return button_ ? toast_metrics::kHeightWithButton : toast_metrics::kHeight;
  }

  void SetAppearance(const secondary::Appearance& appearance) {
    appearance_ = appearance;
    SchedulePaint();
  }

  // views::View:
  void Layout(PassKey) override {
    namespace m = toast_metrics;
    if (button_) {
      const int w = ButtonWidth();
      button_->SetBoundsRect(gfx::Rect(width() - m::kButtonTrailing - w,
                                       (height() - m::kButtonHeight) / 2, w,
                                       m::kButtonHeight));
    }
  }

  void OnPaint(gfx::Canvas* canvas) override {
    namespace m = toast_metrics;
    const gfx::RectF body(GetLocalBounds());
    // Shadow 0.10, radius 8, 2 pt down; vertical gradient fill; 1 px inner
    // rim black 0.20 (ToastMetrics, fitted on the hint toast).
    secondary::FillRoundRectWithShadow(
        canvas, body, m::kCornerRadius, appearance_.toast_fill_top,
        secondary::WithAlpha(SK_ColorBLACK, 0.10f), 2.f, 16.f);
    secondary::FillRoundRectGradient(canvas, body, m::kCornerRadius,
                                     appearance_.toast_fill_top,
                                     appearance_.toast_fill_bottom);
    secondary::StrokeRoundRect(canvas, body, m::kCornerRadius,
                               secondary::WithAlpha(SK_ColorBLACK, 0.20f), 1.f);
    int x = m::kLeadingPadding;
    const gfx::Rect symbol(x, (height() - m::kSymbolSize) / 2, m::kSymbolSize,
                           m::kSymbolSize);
    if (!spec_.leading_text.empty()) {
      secondary::DrawText(canvas, spec_.leading_text, secondary::FontOfSize(13),
                          appearance_.toast_text, symbol,
                          gfx::Canvas::TEXT_ALIGN_CENTER);
      x += m::kSymbolSize + m::kSymbolToTitle;
    } else if (spec_.glyph != Glyph::kNone) {
      secondary::PaintGlyph(canvas, spec_.glyph, gfx::RectF(symbol),
                            appearance_.toast_text);
      x += m::kSymbolSize + m::kSymbolToTitle;
    }
    const int right = button_ ? button_->x() - m::kLabelToButton
                              : width() - m::kTrailingPadding;
    secondary::DrawText(canvas, spec_.title, title_font(),
                        appearance_.toast_text,
                        gfx::Rect(x, 0, std::max(0, right - x), height()));
  }

  void OnMouseEntered(const ui::MouseEvent& event) override { timer_.Stop(); }

  void OnMouseExited(const ui::MouseEvent& event) override {
    timer_.Start(FROM_HERE, toast_metrics::kHoverResume,
                 base::BindOnce(&ToastView::Expire, base::Unretained(this)));
  }

 private:
  gfx::FontList title_font() const {
    return secondary::FontOfSize(toast_metrics::kFontSize,
                                 gfx::Font::Weight::MEDIUM);
  }

  int ButtonWidth() const {
    return std::max(32, secondary::TextWidth(spec_.button_label,
                                             secondary::FontOfSize(13)) +
                            16);
  }

  void PaintButton(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered) {
    secondary::FillRoundRect(
        canvas, gfx::RectF(bounds), toast_metrics::kButtonRadius,
        secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.32f : 0.22f));
    secondary::DrawText(canvas, spec_.button_label,
                        secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM),
                        appearance_.toast_text, bounds,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }

  void PressButton() {
    if (spec_.button_action) {
      std::move(spec_.button_action).Run();
    }
    Expire();
  }

  void Expire() {
    timer_.Stop();
    stack_->ScheduleRemove(this);
  }

  raw_ptr<OpenToastStackView> stack_;
  ToastSpec spec_;
  secondary::Appearance appearance_;
  raw_ptr<PaintedButton> button_ = nullptr;
  base::TimeDelta lifetime_;
  base::OneShotTimer timer_;
};

BEGIN_METADATA(ToastView)
END_METADATA

}  // namespace toast_internal

OpenToastStackView::OpenToastStackView() {
  SetBorder(
      views::CreateEmptyBorder(gfx::Insets(toast_metrics::kShadowMargin)));
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Notifications");
}

OpenToastStackView::~OpenToastStackView() = default;

// static
gfx::Rect OpenToastStackView::ComputeAnchor(
    const gfx::Rect& content_panel,
    std::optional<int> find_bar_bottom) {
  namespace m = toast_metrics;
  int top = content_panel.y() + m::kTopInset;
  if (find_bar_bottom) {
    top = std::max(top, *find_bar_bottom + m::kStackGap);
  }
  top = std::min(top, content_panel.bottom());
  return gfx::Rect(content_panel.x(), top,
                   std::max(0, content_panel.width() - m::kTrailingInset),
                   std::max(0, content_panel.bottom() - top));
}

void OpenToastStackView::Show(ToastSpec spec) {
  const bool was_empty = toasts_.empty();
  auto* toast = AddChildViewAt(std::make_unique<toast_internal::ToastView>(
                                   this, std::move(spec), appearance_),
                               0);
  toasts_.insert(toasts_.begin(), toast);
  while (toasts_.size() > toast_metrics::kMaxVisible) {
    toast_internal::ToastView* oldest = toasts_.back().get();
    toasts_.pop_back();
    RemoveChildViewT(oldest);
  }
  PreferredSizeChanged();
  InvalidateLayout();
  if (was_empty && visibility_callback_) {
    visibility_callback_.Run(true);
  }
}

void OpenToastStackView::DismissAll() {
  if (toasts_.empty()) {
    return;
  }
  while (!toasts_.empty()) {
    toast_internal::ToastView* toast = toasts_.back().get();
    toasts_.pop_back();
    RemoveChildViewT(toast);
  }
  PreferredSizeChanged();
  if (visibility_callback_) {
    visibility_callback_.Run(false);
  }
}

void OpenToastStackView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  for (auto& toast : toasts_) {
    toast->SetAppearance(appearance);
  }
}

void OpenToastStackView::SetVisibilityCallback(
    base::RepeatingCallback<void(bool)> callback) {
  visibility_callback_ = std::move(callback);
}

void OpenToastStackView::ScheduleRemove(toast_internal::ToastView* toast) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenToastStackView> stack,
                        toast_internal::ToastView* target) {
                       if (stack) {
                         stack->Remove(target);
                       }
                     },
                     weak_factory_.GetWeakPtr(), toast));
}

void OpenToastStackView::Remove(toast_internal::ToastView* toast) {
  auto it = std::find(toasts_.begin(), toasts_.end(), toast);
  if (it == toasts_.end()) {
    return;  // Already dropped (stack overflow or DismissAll).
  }
  toasts_.erase(it);
  RemoveChildViewT(toast);
  PreferredSizeChanged();
  InvalidateLayout();
  if (toasts_.empty() && visibility_callback_) {
    visibility_callback_.Run(false);
  }
}

gfx::Size OpenToastStackView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  int width = 0;
  int height = 0;
  for (const auto& toast : toasts_) {
    width = std::max(width, toast->PreferredWidth());
    height += toast->PreferredHeight();
  }
  if (!toasts_.empty()) {
    height += static_cast<int>(toasts_.size() - 1) * toast_metrics::kStackGap;
  }
  return gfx::Size(width + GetInsets().width(), height + GetInsets().height());
}

void OpenToastStackView::Layout(PassKey) {
  gfx::Rect inner = GetLocalBounds();
  inner.Inset(GetInsets());
  int y = inner.y();
  for (auto& toast : toasts_) {
    const int w = toast->PreferredWidth();
    const int h = toast->PreferredHeight();
    // Right-aligned: the stack's right edge is the panel's trailing inset.
    toast->SetBoundsRect(gfx::Rect(inner.right() - w, y, w, h));
    y += h + toast_metrics::kStackGap;
  }
}

BEGIN_METADATA(OpenToastStackView)
END_METADATA

// ===========================================================================
// OpenTabSwitcherView.
// ===========================================================================

OpenTabSwitcherView::OpenTabSwitcherView(TabSwitcherDelegate* delegate)
    : delegate_(delegate) {
  SetBorder(views::CreateEmptyBorder(
      gfx::Insets(tab_switcher_metrics::kShadowMargin)));
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kListBox);
  GetViewAccessibility().SetName(u"Switch Tabs");
}

OpenTabSwitcherView::~OpenTabSwitcherView() = default;

void OpenTabSwitcherView::Begin(std::vector<TabSwitcherItem> items,
                                bool reverse) {
  if (items.size() < 2) {
    return;  // Nothing to switch to.
  }
  items_ = std::move(items);
  active_ = true;
  shown_ = false;
  highlight_ = reverse ? items_.size() - 1 : 1;
  PreferredSizeChanged();
  if (delegate_) {
    delegate_->OnTabSwitcherHighlight(items_[highlight_].tab_id);
  }
  // A quick Ctrl+Tab tap switches without showing the HUD.
  present_timer_.Start(
      FROM_HERE, tab_switcher_metrics::kPresentationDelay,
      base::BindOnce(&OpenTabSwitcherView::Present, base::Unretained(this)));
}

void OpenTabSwitcherView::Advance(bool reverse) {
  if (!active_ || items_.empty()) {
    return;
  }
  const size_t n = items_.size();
  SetHighlight(reverse ? (highlight_ + n - 1) % n : (highlight_ + 1) % n);
}

void OpenTabSwitcherView::Commit() {
  if (!active_ || highlight_ >= items_.size()) {
    return;
  }
  const ItemID id = items_[highlight_].tab_id;
  Finish();
  if (delegate_) {
    delegate_->OnTabSwitcherCommit(id);
  }
}

void OpenTabSwitcherView::Cancel() {
  if (!active_) {
    return;
  }
  Finish();
  if (delegate_) {
    delegate_->OnTabSwitcherCancel();
  }
}

void OpenTabSwitcherView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  SchedulePaint();
}

void OpenTabSwitcherView::Present() {
  if (!active_ || shown_) {
    return;
  }
  shown_ = true;
  if (delegate_) {
    delegate_->OnTabSwitcherVisibilityChanged(true);
  }
  RequestFocus();
  SchedulePaint();
}

void OpenTabSwitcherView::Finish() {
  present_timer_.Stop();
  active_ = false;
  if (shown_) {
    shown_ = false;
    if (delegate_) {
      delegate_->OnTabSwitcherVisibilityChanged(false);
    }
  }
}

void OpenTabSwitcherView::SetHighlight(size_t index) {
  if (index >= items_.size() || index == highlight_) {
    return;
  }
  highlight_ = index;
  if (delegate_) {
    delegate_->OnTabSwitcherHighlight(items_[highlight_].tab_id);
  }
  SchedulePaint();
}

bool OpenTabSwitcherView::HandleKeyEvent(const ui::KeyEvent& event) {
  if (!active_) {
    return false;
  }
  if (event.type() == ui::EventType::kKeyReleased) {
    // Commit on the Ctrl release (also robust to a missed key-up: any
    // release without Ctrl held commits).
    if (event.key_code() == ui::VKEY_CONTROL ||
        event.key_code() == ui::VKEY_LCONTROL ||
        event.key_code() == ui::VKEY_RCONTROL || !event.IsControlDown()) {
      Commit();
      return true;
    }
    return false;
  }
  if (event.type() != ui::EventType::kKeyPressed) {
    return false;
  }
  switch (event.key_code()) {
    case ui::VKEY_TAB:
      Advance(event.IsShiftDown());
      return true;
    case ui::VKEY_RIGHT:
      Advance(false);
      return true;
    case ui::VKEY_LEFT:
      Advance(true);
      return true;
    case ui::VKEY_ESCAPE:
      Cancel();
      return true;
    case ui::VKEY_RETURN:
      Commit();
      return true;
    default:
      return false;
  }
}

bool OpenTabSwitcherView::OnKeyPressed(const ui::KeyEvent& event) {
  return HandleKeyEvent(event);
}

bool OpenTabSwitcherView::OnKeyReleased(const ui::KeyEvent& event) {
  return HandleKeyEvent(event);
}

gfx::Rect OpenTabSwitcherView::inner_bounds() const {
  gfx::Rect r = GetLocalBounds();
  r.Inset(GetInsets());
  return r;
}

size_t OpenTabSwitcherView::first_visible() const {
  namespace m = tab_switcher_metrics;
  if (items_.size() <= m::kMaximumVisible) {
    return 0;
  }
  // Keep the highlight inside the visible window, centered when possible.
  const size_t half = m::kMaximumVisible / 2;
  const size_t max_first = items_.size() - m::kMaximumVisible;
  return std::min(highlight_ > half ? highlight_ - half : 0, max_first);
}

gfx::Rect OpenTabSwitcherView::ItemRect(size_t visible_index) const {
  namespace m = tab_switcher_metrics;
  const gfx::Rect inner = inner_bounds();
  return gfx::Rect(
      inner.x() + m::kInset +
          static_cast<int>(visible_index) * (m::kItemWidth + m::kGap),
      inner.y() + m::kInset + m::kHeadingHeight, m::kItemWidth, m::kItemHeight);
}

gfx::Size OpenTabSwitcherView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  namespace m = tab_switcher_metrics;
  const int n = static_cast<int>(
      std::max<size_t>(1, std::min(items_.size(), m::kMaximumVisible)));
  return gfx::Size(2 * m::kInset + n * m::kItemWidth + (n - 1) * m::kGap +
                       GetInsets().width(),
                   2 * m::kInset + m::kHeadingHeight + m::kItemHeight +
                       GetInsets().height());
}

void OpenTabSwitcherView::OnPaint(gfx::Canvas* canvas) {
  namespace m = tab_switcher_metrics;
  if (!shown_ || items_.empty()) {
    return;
  }
  const bool dark = appearance_.dark;
  const SkColor text = dark ? kInputTextDark : kInputTextLight;
  const gfx::Rect inner = inner_bounds();
  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(inner), m::kCornerRadius,
      dark ? kPopoverDark : kPopoverLight,
      dark ? kPopoverShadowDark : kPopoverShadowLight, 8.f, 30.f);

  // Heading: the highlighted tab's title (Open choice; no capture).
  secondary::DrawText(
      canvas, items_[highlight_].title,
      secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD), text,
      gfx::Rect(inner.x() + m::kInset, inner.y() + m::kInset,
                inner.width() - 2 * m::kInset, m::kHeadingHeight - 8));

  const size_t first = first_visible();
  const size_t count = std::min(items_.size() - first, m::kMaximumVisible);
  constexpr int kTitleRow = 34;
  constexpr float kCardRadius = 10.f;
  for (size_t i = 0; i < count; ++i) {
    const TabSwitcherItem& item = items_[first + i];
    const gfx::Rect card = ItemRect(i);
    const bool selected = first + i == highlight_;
    secondary::FillRoundRect(
        canvas, gfx::RectF(card), kCardRadius,
        secondary::WithAlpha(dark ? SK_ColorWHITE : SK_ColorBLACK,
                             selected ? 0.10f : 0.04f));
    const gfx::Rect preview(card.x() + 6, card.y() + 6, card.width() - 12,
                            card.height() - kTitleRow - 6);
    if (!item.thumbnail.isNull()) {
      canvas->Save();
      SkRRect clip = SkRRect::MakeRectXY(
          gfx::RectFToSkRect(gfx::RectF(preview)), 6.f, 6.f);
      canvas->sk_canvas()->clipRRect(clip, true);
      secondary::DrawImageInRect(canvas, item.thumbnail, preview);
      canvas->Restore();
    } else {
      secondary::FillRoundRect(
          canvas, gfx::RectF(preview), 6.f,
          secondary::WithAlpha(dark ? SK_ColorWHITE : SK_ColorBLACK, 0.05f));
      const gfx::Rect icon(preview.CenterPoint().x() - 16,
                           preview.CenterPoint().y() - 16, 32, 32);
      if (item.favicon.isNull()) {
        secondary::PaintGlyph(canvas, Glyph::kGlobe, gfx::RectF(icon),
                              secondary::WithAlpha(text, 0.5f));
      } else {
        secondary::DrawImageInRect(canvas, item.favicon, icon);
      }
    }
    // Title row: favicon 16 + title.
    const int row_y = card.bottom() - kTitleRow;
    int text_x = card.x() + 10;
    if (!item.favicon.isNull()) {
      secondary::DrawImageInRect(
          canvas, item.favicon,
          gfx::Rect(text_x, row_y + (kTitleRow - 16) / 2, 16, 16));
      text_x += 22;
    }
    secondary::DrawText(
        canvas, item.title.empty() ? item.host : item.title,
        secondary::FontOfSize(12, selected ? gfx::Font::Weight::SEMIBOLD
                                           : gfx::Font::Weight::NORMAL),
        text, gfx::Rect(text_x, row_y, card.right() - 10 - text_x, kTitleRow));
    if (selected) {
      secondary::StrokeRoundRect(canvas, gfx::RectF(card), kCardRadius,
                                 appearance_.ActiveAccent(), 2.5f);
    }
  }
}

bool OpenTabSwitcherView::OnMousePressed(const ui::MouseEvent& event) {
  if (!shown_) {
    return false;
  }
  const size_t first = first_visible();
  const size_t count =
      std::min(items_.size() - first, tab_switcher_metrics::kMaximumVisible);
  for (size_t i = 0; i < count; ++i) {
    if (ItemRect(i).Contains(event.location())) {
      SetHighlight(first + i);
      Commit();
      return true;
    }
  }
  return true;
}

void OpenTabSwitcherView::OnMouseMoved(const ui::MouseEvent& event) {
  if (!shown_) {
    return;
  }
  const size_t first = first_visible();
  const size_t count =
      std::min(items_.size() - first, tab_switcher_metrics::kMaximumVisible);
  for (size_t i = 0; i < count; ++i) {
    if (ItemRect(i).Contains(event.location())) {
      SetHighlight(first + i);
      return;
    }
  }
}

BEGIN_METADATA(OpenTabSwitcherView)
END_METADATA

}  // namespace open_unified
