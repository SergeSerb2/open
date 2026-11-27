// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_sidebar_popovers.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <map>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "open_unified/ui/views/open_tab_tree_view.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/accessibility/ax_action_data.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/menu_model.h"
#include "ui/base/models/menu_separator_types.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/text_elider.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/context_menu_controller.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

namespace pm = popover_metrics;
using theme::ContentAppearance;
using theme::Rgba;

SkColor Sk(const Rgba& c) {
  return theme::ToSkColor(c);
}

SkColor Alpha(SkColor c, float a) {
  return SkColorSetA(c, static_cast<U8CPU>(std::lround(
                            std::clamp(a, 0.f, 1.f) * SkColorGetA(c))));
}

const gfx::FontList& Font(int size, gfx::Font::Weight weight) {
  // FontOfSize builds a new list; cache per (size, weight).
  static base::NoDestructor<std::map<std::pair<int, int>, gfx::FontList>>
      cache;
  const auto key = std::make_pair(size, static_cast<int>(weight));
  auto it = cache->find(key);
  if (it == cache->end()) {
    it = cache->emplace(key, secondary::FontOfSize(size, weight)).first;
  }
  return it->second;
}

// One line of text, vertically centered in `rect`, elided with `behavior`.
void DrawLine(gfx::Canvas* canvas,
              std::u16string_view text,
              const gfx::FontList& font,
              SkColor color,
              const gfx::Rect& rect,
              int align = gfx::Canvas::TEXT_ALIGN_LEFT,
              gfx::ElideBehavior behavior = gfx::ELIDE_TAIL) {
  if (text.empty() || rect.width() <= 0 || rect.height() <= 0) {
    return;
  }
  const std::u16string elided =
      gfx::ElideText(std::u16string(text), font, rect.width(), behavior);
  const int line = font.GetHeight();
  const gfx::Rect line_rect(rect.x(), rect.y() + (rect.height() - line) / 2,
                            rect.width(), line);
  canvas->DrawStringRectWithFlags(elided, font, color, line_rect,
                                  align | gfx::Canvas::NO_SUBPIXEL_RENDERING);
}

void FillRound(gfx::Canvas* canvas,
               const gfx::RectF& rect,
               float radius,
               SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setStyle(cc::PaintFlags::kFill_Style);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

// Open's own symbols for the "+" rows (PlusPopoverView.symbols; no Arc art).
const char* PlusSymbolFor(std::u16string_view title) {
  if (title == u"New Space") return "plus.square.on.square";
  if (title == u"New Folder") return "folder";
  if (title == u"New Easel") return "scribble";
  if (title == u"New Note") return "note.text";
  if (title == u"New Boost") return "paintbrush";
  if (title == u"New Split") return "rectangle.split.2x1";
  if (title == u"New Tab") return "plus.app";
  return "plus";
}

// Windows / Linux: Open's Skia glyphs for the same rows.
void PaintPlusFallback(gfx::Canvas* canvas,
                       std::u16string_view title,
                       const gfx::RectF& box,
                       SkColor ink) {
  if (title == u"New Folder") {
    glyphs::Draw(canvas, glyphs::Glyph::kFolderClosed, box, ink);
    return;
  }
  secondary::Glyph g = secondary::Glyph::kPlus;
  if (title == u"New Space") {
    g = secondary::Glyph::kSquare;
  } else if (title == u"New Easel") {
    g = secondary::Glyph::kCapture;
  } else if (title == u"New Note") {
    g = secondary::Glyph::kCopy;
  } else if (title == u"New Boost") {
    g = secondary::Glyph::kBoost;
  } else if (title == u"New Split") {
    g = secondary::Glyph::kSplit;
  }
  gfx::RectF square = box;
  square.ClampToCenteredSize(gfx::SizeF(16, 16));
  secondary::PaintGlyph(canvas, g, square, ink);
}

std::u16string ShortcutText(const ui::MenuModel* model, size_t index) {
  ui::Accelerator accelerator;
  if (!model->GetAcceleratorAt(index, &accelerator)) {
    return std::u16string();
  }
  return accelerator.GetShortcutText();
}

}  // namespace

// ---------------------------------------------------------------------------
// OpenPopoverColors

// static
OpenPopoverColors OpenPopoverColors::ForTheme(const theme::ThemeStyle& style,
                                              ContentAppearance system) {
  OpenPopoverColors c;
  const ContentAppearance scheme =
      style.uses_legacy_intensity ? system : style.window_color_scheme;
  c.dark = scheme == ContentAppearance::kDark;
  // Fill = the theme's backgroundExtra (default: #FDFDFF / #050627).
  c.fill = Sk(style.MiniPlayerFill(scheme));
  if (const theme::SemanticPalette* palette = style.PaletteFor(scheme)) {
    c.highlight = Sk(palette->hover.WithAlpha(1));  // guess for themes
  } else {
    c.highlight = c.dark ? SkColorSetRGB(0x2E, 0x33, 0x91)
                         : SkColorSetRGB(0xD3, 0xD4, 0xFF);
  }
  c.separator = c.highlight;  // the line measures the highlight color
  c.label = c.dark ? SK_ColorWHITE : SK_ColorBLACK;
  c.secondary_label = c.dark ? SkColorSetARGB(0x99, 0xFF, 0xFF, 0xFF)
                             : SkColorSetARGB(0x8C, 0x00, 0x00, 0x00);
  c.disabled = c.dark ? SkColorSetRGB(0x79, 0x78, 0x81)
                      : SkColorSetRGB(0xAB, 0xAB, 0xAB);
  c.shortcut = c.dark ? SkColorSetRGB(0x76, 0x77, 0x80)
                      : SkColorSetRGB(0xA5, 0xAA, 0xFF);
  c.shortcut_highlighted = c.shortcut;
  c.track = c.dark ? SkColorSetARGB(0x29, 0xFF, 0xFF, 0xFF)
                   : SkColorSetARGB(0x1A, 0x00, 0x00, 0x00);
  c.progress = Sk(style.AccentColor(scheme));
  return c;
}

// static
OpenPopoverColors OpenPopoverColors::ForThemeState(
    const OpenSpaceThemeState& state,
    ContentAppearance system) {
  return ForTheme(state.style, system);
}

// static
OpenPopoverColors OpenPopoverColors::ToolbarMore(bool dark) {
  OpenPopoverColors c;
  c.dark = dark;
  // Card #FDFDFF, hovered row #D3D4FD, title black, disabled #B2B2B2
  // (capture session 9, light). Dark: Swift's guesses.
  c.fill = dark ? SkColorSetRGB(0x2A, 0x2A, 0x2E) : SkColorSetRGB(0xFD, 0xFD, 0xFF);
  c.highlight = dark ? SkColorSetARGB(0x1F, 0xFF, 0xFF, 0xFF)
                     : SkColorSetRGB(0xD3, 0xD4, 0xFD);
  c.separator = c.highlight;
  c.label = dark ? SkColorSetARGB(0xEB, 0xFF, 0xFF, 0xFF) : SK_ColorBLACK;
  c.secondary_label = dark ? SkColorSetARGB(0x99, 0xFF, 0xFF, 0xFF)
                           : SkColorSetARGB(0x8C, 0x00, 0x00, 0x00);
  c.disabled = dark ? SkColorSetARGB(0x4D, 0xFF, 0xFF, 0xFF)
                    : SkColorSetRGB(0xB2, 0xB2, 0xB2);
  c.shortcut = dark ? SkColorSetARGB(0x59, 0xFF, 0xFF, 0xFF)
                    : SkColorSetRGB(0xB2, 0xB2, 0xB2);
  c.shortcut_highlighted = dark ? c.shortcut : SkColorSetRGB(0xA6, 0xAA, 0xFB);
  return c;
}

// ---------------------------------------------------------------------------
// OpenPopoverHost

OpenPopoverHost::OpenPopoverHost() = default;

OpenPopoverHost::~OpenPopoverHost() {
  DiscardBubble(/*synchronous=*/true);
}

void OpenPopoverHost::DiscardBubble(bool synchronous) {
  weak_factory_.InvalidateWeakPtrs();
  contents_ = nullptr;
  if (synchronous) {
    if (widget_) {
      widget_->CloseNow();
    }
    widget_.reset();
    bubble_delegate_.reset();
    return;
  }
  // Posted in order: the widget is deleted before its delegate.
  if (widget_) {
    widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(widget_));
  }
  if (bubble_delegate_) {
    bubble_delegate_->SetAnchorView(nullptr);
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(bubble_delegate_));
  }
}

views::View* OpenPopoverHost::Show(views::View* anchor,
                                   views::BubbleBorder::Arrow arrow,
                                   std::unique_ptr<views::View> contents,
                                   SkColor fill,
                                   int corner_radius,
                                   int fixed_width,
                                   std::string_view name,
                                   base::OnceClosure on_closed) {
  DiscardBubble(/*synchronous=*/false);
  on_closed_ = std::move(on_closed);
  bubble_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      anchor, arrow, views::BubbleBorder::DIALOG_SHADOW, /*autosize=*/true);
  bubble_delegate_->set_margins(gfx::Insets());
  if (fixed_width > 0) {
    bubble_delegate_->set_fixed_width(fixed_width);
  }
  bubble_delegate_->set_corner_radius(corner_radius);
  bubble_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  bubble_delegate_->SetShowCloseButton(false);
  bubble_delegate_->SetShowTitle(false);
  bubble_delegate_->set_close_on_deactivate(true);
  bubble_delegate_->set_highlight_button_when_shown(false);
  bubble_delegate_->set_internal_name(std::string(name));
  contents_ = bubble_delegate_->SetContentsView(std::move(contents));
  if (contents_->GetFocusBehavior() != views::View::FocusBehavior::NEVER) {
    // Keyboard rows (Up / Down / Return) need key focus on open.
    bubble_delegate_->SetInitiallyFocusedView(contents_);
  }
  bubble_delegate_->SetBackgroundColor(fill);
  widget_ = views::BubbleDialogDelegate::CreateBubble(
      bubble_delegate_.get(), base::BindOnce(&OpenPopoverHost::OnWidgetClosed,
                                             weak_factory_.GetWeakPtr()));
  widget_->Show();
  return contents_;
}

void OpenPopoverHost::Close() {
  if (widget_) {
    widget_->CloseWithReason(views::Widget::ClosedReason::kUnspecified);
  }
}

bool OpenPopoverHost::IsShowing() const {
  return widget_ && widget_->IsVisible();
}

void OpenPopoverHost::SizeToContents() {
  if (bubble_delegate_ && widget_) {
    bubble_delegate_->SizeToContents();
  }
}

bool OpenPopoverHost::JustClosed() const {
  return !last_closed_.is_null() &&
         base::TimeTicks::Now() - last_closed_ < base::Milliseconds(300);
}

void OpenPopoverHost::OnWidgetClosed(views::Widget::ClosedReason reason) {
  last_closed_ = base::TimeTicks::Now();
  base::OnceClosure on_closed = std::move(on_closed_);
  // The close can start inside the widget's own event handling: hide now,
  // delete on the next task (widget first, then its delegate).
  DiscardBubble(/*synchronous=*/false);
  if (on_closed) {
    std::move(on_closed).Run();
  }
}

// ---------------------------------------------------------------------------
// OpenMenuCardView

// One accessibility menu item per drawn row; mouse events go to the card.
class OpenMenuCardView::RowAccessibilityView : public views::View {
  METADATA_HEADER(RowAccessibilityView, views::View)

 public:
  RowAccessibilityView(OpenMenuCardView* card,
                       size_t row,
                       const std::u16string& title,
                       bool enabled)
      : card_(card), row_(row) {
    SetCanProcessEventsWithinSubtree(false);
    GetViewAccessibility().SetRole(ax::mojom::Role::kMenuItem);
    GetViewAccessibility().SetName(title);
    GetViewAccessibility().SetIsEnabled(enabled);
  }

  bool HandleAccessibleAction(const ui::AXActionData& action_data) override {
    if (action_data.action == ax::mojom::Action::kDoDefault) {
      card_->Run(row_, ui::EF_NONE);
      return true;
    }
    return views::View::HandleAccessibleAction(action_data);
  }

 private:
  raw_ptr<OpenMenuCardView> card_;
  size_t row_;
};

OpenMenuCardView::OpenMenuCardView(Style style,
                                   ui::MenuModel* model,
                                   const OpenPopoverColors& colors,
                                   RunCallback on_run)
    : style_(style), colors_(colors), on_run_(std::move(on_run)) {
  SetFocusBehavior(FocusBehavior::ALWAYS);
  GetViewAccessibility().SetRole(ax::mojom::Role::kMenu);
  GetViewAccessibility().SetName(style == Style::kPlus ? u"New"
                                                       : u"More options");
  Rebuild(model);
  if (style_ == Style::kPlus) {
    // Opens with the last enabled row ("New Tab") highlighted.
    for (size_t i = rows_.size(); i > 0; --i) {
      if (rows_[i - 1].enabled) {
        SetHighlighted(i - 1);
        break;
      }
    }
  }
}

OpenMenuCardView::~OpenMenuCardView() = default;

void OpenMenuCardView::Rebuild(ui::MenuModel* model) {
  rows_.clear();
  separator_ys_.clear();
  RemoveAllChildViews();
  if (!model) {
    content_height_ = 0;
    return;
  }
  const bool plus = style_ == Style::kPlus;
  int y = plus ? pm::kPlusRowInset : pm::kMorePadding;
  const int x = plus ? pm::kPlusRowInset : pm::kMorePadding;
  const int width = plus ? pm::kPlusRowWidth
                         : pm::kMoreWidth - 2 * pm::kMorePadding;
  const int height = plus ? pm::kPlusRowHeight : pm::kMoreRowHeight;
  bool pending_separator = false;
  for (size_t i = 0; i < model->GetItemCount(); ++i) {
    if (!model->IsVisibleAt(i)) {
      continue;
    }
    const ui::MenuModel::ItemType type = model->GetTypeAt(i);
    if (type == ui::MenuModel::TYPE_SEPARATOR) {
      pending_separator = !rows_.empty();
      continue;
    }
    if (type != ui::MenuModel::TYPE_COMMAND &&
        type != ui::MenuModel::TYPE_CHECK) {
      continue;
    }
    if (!rows_.empty()) {
      if (pending_separator && plus) {
        // The 1 pt line sits 8 pt under the row above; 17 pt per group gap.
        separator_ys_.push_back(y + pm::kPlusSeparatorOffset);
        y += pm::kPlusGroupGap;
      } else if (!plus) {
        y += pm::kMoreRowGap;
      }
    }
    pending_separator = false;
    Row row;
    row.model_index = i;
    row.title = model->GetLabelAt(i);
    row.shortcut = ShortcutText(model, i);
    row.enabled = model->IsEnabledAt(i);
    row.bounds = gfx::Rect(x, y, width, height);
    rows_.push_back(row);
    y += height;
  }
  content_height_ = y + (plus ? pm::kPlusRowInset : pm::kMorePadding);
  for (size_t r = 0; r < rows_.size(); ++r) {
    AddChildView(std::make_unique<RowAccessibilityView>(
        this, r, rows_[r].title, rows_[r].enabled));
  }
}

void OpenMenuCardView::SetColors(const OpenPopoverColors& colors) {
  colors_ = colors;
  SchedulePaint();
}

void OpenMenuCardView::SetHighlighted(std::optional<size_t> row) {
  if (row && (*row >= rows_.size() || !rows_[*row].enabled)) {
    row.reset();
  }
  if (highlighted_ == row) {
    return;
  }
  if (highlighted_ && *highlighted_ < children().size()) {
    children()[*highlighted_]->GetViewAccessibility().SetIsSelected(false);
  }
  highlighted_ = row;
  if (highlighted_ && *highlighted_ < children().size()) {
    // Posts the selection event too.
    children()[*highlighted_]->GetViewAccessibility().SetIsSelected(true);
  }
  SchedulePaint();
}

void OpenMenuCardView::MoveHighlight(int delta) {
  std::vector<size_t> enabled;
  for (size_t i = 0; i < rows_.size(); ++i) {
    if (rows_[i].enabled) {
      enabled.push_back(i);
    }
  }
  if (enabled.empty()) {
    return;
  }
  const int n = static_cast<int>(enabled.size());
  int position = delta > 0 ? -1 : 0;
  if (highlighted_) {
    auto it = std::find(enabled.begin(), enabled.end(), *highlighted_);
    if (it != enabled.end()) {
      position = static_cast<int>(it - enabled.begin());
    }
  }
  const int next = ((position + delta) % n + n) % n;
  SetHighlighted(enabled[static_cast<size_t>(next)]);
}

void OpenMenuCardView::RunHighlighted(int event_flags) {
  if (highlighted_) {
    Run(*highlighted_, event_flags);
  }
}

void OpenMenuCardView::Run(size_t row, int event_flags) {
  if (row >= rows_.size() || !rows_[row].enabled || !on_run_) {
    return;
  }
  // The callback closes the popover; this view goes away on a later task.
  RunCallback callback = on_run_;
  callback.Run(rows_[row].model_index, event_flags);
}

std::u16string OpenMenuCardView::RowTitle(size_t row) const {
  return row < rows_.size() ? rows_[row].title : std::u16string();
}

gfx::Size OpenMenuCardView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const int width =
      style_ == Style::kPlus ? pm::kPlusBodyWidth : pm::kMoreWidth;
  return gfx::Size(width, content_height_);
}

void OpenMenuCardView::Layout(PassKey) {
  for (size_t r = 0; r < rows_.size() && r < children().size(); ++r) {
    children()[r]->SetBoundsRect(rows_[r].bounds);
  }
}

void OpenMenuCardView::OnThemeChanged() {
  views::View::OnThemeChanged();
  SchedulePaint();
}

std::optional<size_t> OpenMenuCardView::RowAt(const gfx::Point& point) const {
  for (size_t i = 0; i < rows_.size(); ++i) {
    if (rows_[i].bounds.Contains(point)) {
      return i;
    }
  }
  return std::nullopt;
}

void OpenMenuCardView::PaintRowIcon(gfx::Canvas* canvas,
                                    const Row& row,
                                    const gfx::RectF& box,
                                    SkColor ink) {
  if (style_ == Style::kPlus) {
    if (!glyphs::DrawSystemSymbol(canvas, PlusSymbolFor(row.title),
                                  pm::kPlusIconPointSize,
                                  glyphs::SymbolWeight::kMedium, box, ink)) {
      PaintPlusFallback(canvas, row.title, box, ink);
    }
    return;
  }
  // More options rows: Reload (or Stop Loading) and Toggle Sidebar.
  glyphs::Glyph glyph;
  if (row.title == u"Reload") {
    glyph = glyphs::Glyph::kReload;
  } else if (row.title == u"Stop Loading") {
    glyph = glyphs::Glyph::kStop;
  } else if (row.title == u"Toggle Sidebar") {
    glyph = glyphs::Glyph::kSidebarToggle;
  } else {
    return;
  }
  glyphs::Draw(canvas, glyph, box, ink);
}

void OpenMenuCardView::PaintRow(gfx::Canvas* canvas,
                                const Row& row,
                                bool highlighted) {
  const bool plus = style_ == Style::kPlus;
  const gfx::RectF bounds(row.bounds);
  if (highlighted && row.enabled) {
    FillRound(canvas, bounds,
              plus ? pm::kPlusRowRadius : pm::kMoreRowRadius,
              colors_.highlight);
  }
  const SkColor ink = row.enabled ? colors_.label : colors_.disabled;
  // Icon box: 24 x 24 centered on the measured icon center.
  const float icon_cx = plus ? bounds.x() + pm::kPlusIconCenterX
                             : pm::kMoreIconCenterX;
  const gfx::RectF icon_box(icon_cx - 12, bounds.CenterPoint().y() - 12, 24,
                            24);
  PaintRowIcon(canvas, row, icon_box, ink);

  const gfx::FontList& title_font =
      plus ? Font(pm::kPlusLabelFontSize, gfx::Font::Weight::SEMIBOLD)
           : Font(pm::kMoreTitleFontSize, gfx::Font::Weight::MEDIUM);
  const gfx::FontList& key_font =
      plus ? Font(pm::kPlusShortcutFontSize, gfx::Font::Weight::MEDIUM)
           : Font(pm::kMoreShortcutFontSize, gfx::Font::Weight::NORMAL);
  const int title_x = plus ? row.bounds.x() + pm::kPlusLabelX : pm::kMoreTitleX;
  const int key_right = plus ? row.bounds.right() - pm::kPlusShortcutTrailing
                             : width() - pm::kMoreShortcutInset;
  int key_width = 0;
  if (!row.shortcut.empty()) {
    key_width = secondary::TextWidth(row.shortcut, key_font);
    SkColor key_ink = colors_.disabled;
    if (row.enabled) {
      key_ink = highlighted ? colors_.shortcut_highlighted : colors_.shortcut;
    }
    DrawLine(canvas, row.shortcut, key_font, key_ink,
             gfx::Rect(key_right - key_width, row.bounds.y(), key_width,
                       row.bounds.height()),
             gfx::Canvas::TEXT_ALIGN_RIGHT);
  }
  const int title_right = key_width > 0 ? key_right - key_width - 8
                                        : row.bounds.right() - 8;
  DrawLine(canvas, row.title, title_font, ink,
           gfx::Rect(title_x, row.bounds.y(), std::max(0, title_right - title_x),
                     row.bounds.height()));
}

void OpenMenuCardView::OnPaint(gfx::Canvas* canvas) {
  // The body fill is the bubble background (SetBackgroundColor).
  for (int y : separator_ys_) {
    canvas->FillRect(gfx::Rect(pm::kPlusSeparatorInset, y,
                               pm::kPlusBodyWidth - 2 * pm::kPlusSeparatorInset,
                               1),
                     colors_.separator);
  }
  for (size_t i = 0; i < rows_.size(); ++i) {
    PaintRow(canvas, rows_[i], highlighted_ == i);
  }
}

bool OpenMenuCardView::OnKeyPressed(const ui::KeyEvent& event) {
  switch (event.key_code()) {
    case ui::VKEY_DOWN:
      MoveHighlight(1);
      return true;
    case ui::VKEY_UP:
      MoveHighlight(-1);
      return true;
    case ui::VKEY_RETURN:
      RunHighlighted(event.flags());
      return true;
    default:
      return false;
  }
}

bool OpenMenuCardView::OnMousePressed(const ui::MouseEvent& event) {
  pressed_ = RowAt(event.location());
  return pressed_.has_value();
}

void OpenMenuCardView::OnMouseReleased(const ui::MouseEvent& event) {
  const std::optional<size_t> row = RowAt(event.location());
  const std::optional<size_t> pressed = pressed_;
  pressed_.reset();
  if (row && row == pressed && rows_[*row].enabled) {
    SetHighlighted(row);
    Run(*row, event.flags());
  }
}

void OpenMenuCardView::OnMouseMoved(const ui::MouseEvent& event) {
  const std::optional<size_t> row = RowAt(event.location());
  if (row && rows_[*row].enabled) {
    pointer_seen_ = true;
    SetHighlighted(row);
  } else if (style_ == Style::kToolbarMore) {
    SetHighlighted(std::nullopt);
  }
}

void OpenMenuCardView::OnMouseExited(const ui::MouseEvent& event) {
  // More options highlights on hover only; "+" keeps the keyboard row.
  if (style_ == Style::kToolbarMore) {
    SetHighlighted(std::nullopt);
  }
}

BEGIN_METADATA(OpenMenuCardView, RowAccessibilityView)
END_METADATA

BEGIN_METADATA(OpenMenuCardView)
END_METADATA

// ---------------------------------------------------------------------------
// OpenPlusPopover

OpenPlusPopover::OpenPlusPopover() = default;
OpenPlusPopover::~OpenPlusPopover() = default;

void OpenPlusPopover::Show(views::View* plus_button,
                           std::unique_ptr<ui::MenuModel> model,
                           const OpenPopoverColors& colors,
                           base::OnceClosure on_closed) {
  if (!plus_button || !model) {
    return;
  }
  model_ = std::move(model);
  auto card = std::make_unique<OpenMenuCardView>(
      OpenMenuCardView::Style::kPlus, model_.get(), colors,
      base::BindRepeating(&OpenPlusPopover::Run, weak_factory_.GetWeakPtr()));
  host_.Show(plus_button, views::BubbleBorder::BOTTOM_RIGHT, std::move(card),
             colors.fill, pm::kPlusBodyRadius, pm::kPlusBodyWidth,
             "OpenPlusPopover", std::move(on_closed));
}

void OpenPlusPopover::Toggle(views::View* plus_button,
                             std::unique_ptr<ui::MenuModel> model,
                             const OpenPopoverColors& colors,
                             base::OnceClosure on_closed) {
  if (IsShowing()) {
    Close();
    return;
  }
  // The click on "+" deactivated (and closed) the card: only close.
  if (host_.JustClosed()) {
    return;
  }
  Show(plus_button, std::move(model), colors, std::move(on_closed));
}

void OpenPlusPopover::Close() {
  host_.Close();
}

bool OpenPlusPopover::IsShowing() const {
  return host_.IsShowing();
}

OpenMenuCardView* OpenPlusPopover::card() const {
  return static_cast<OpenMenuCardView*>(host_.contents());
}

void OpenPlusPopover::Run(size_t model_index, int event_flags) {
  // Keep the model alive until its row ran; closing drops the card.
  std::unique_ptr<ui::MenuModel> model = std::move(model_);
  host_.Close();
  if (model && model_index < model->GetItemCount() &&
      model->IsEnabledAt(model_index)) {
    model->ActivatedAt(model_index, event_flags);
  }
}

// ---------------------------------------------------------------------------
// OpenToolbarMorePopover

OpenToolbarMorePopover::OpenToolbarMorePopover() = default;
OpenToolbarMorePopover::~OpenToolbarMorePopover() = default;

void OpenToolbarMorePopover::Show(views::View* more_button,
                                  std::unique_ptr<ui::MenuModel> model,
                                  const OpenPopoverColors& colors,
                                  base::OnceClosure on_closed) {
  if (!more_button || !model) {
    return;
  }
  model_ = std::move(model);
  auto card = std::make_unique<OpenMenuCardView>(
      OpenMenuCardView::Style::kToolbarMore, model_.get(), colors,
      base::BindRepeating(&OpenToolbarMorePopover::Run,
                          weak_factory_.GetWeakPtr()));
  host_.Show(more_button, views::BubbleBorder::TOP_CENTER, std::move(card),
             colors.fill, pm::kMoreCardRadius, pm::kMoreWidth,
             "OpenToolbarMorePopover", std::move(on_closed));
}

void OpenToolbarMorePopover::Toggle(views::View* more_button,
                                    std::unique_ptr<ui::MenuModel> model,
                                    const OpenPopoverColors& colors,
                                    base::OnceClosure on_closed) {
  if (IsShowing()) {
    Close();
    return;
  }
  if (host_.JustClosed()) {
    return;
  }
  Show(more_button, std::move(model), colors, std::move(on_closed));
}

void OpenToolbarMorePopover::Close() {
  host_.Close();
}

bool OpenToolbarMorePopover::IsShowing() const {
  return host_.IsShowing();
}

OpenMenuCardView* OpenToolbarMorePopover::card() const {
  return static_cast<OpenMenuCardView*>(host_.contents());
}

void OpenToolbarMorePopover::Run(size_t model_index, int event_flags) {
  std::unique_ptr<ui::MenuModel> model = std::move(model_);
  host_.Close();
  if (model && model_index < model->GetItemCount() &&
      model->IsEnabledAt(model_index)) {
    model->ActivatedAt(model_index, event_flags);
  }
}

// ---------------------------------------------------------------------------
// Downloads

std::u16string RevealInFolderLabel() {
#if BUILDFLAG(IS_MAC)
  return u"Show in Finder";
#else
  return u"Show in Folder";
#endif
}

std::u16string FormatDownloadBytes(int64_t bytes) {
  if (bytes < 0) {
    bytes = 0;
  }
  constexpr const char16_t* kUnits[] = {u"bytes", u"KB", u"MB", u"GB", u"TB"};
  double value = static_cast<double>(bytes);
  size_t unit = 0;
  while (value >= 1000.0 && unit + 1 < std::size(kUnits)) {
    value /= 1000.0;
    ++unit;
  }
  if (unit == 0) {
    return base::NumberToString16(bytes) + u" " + kUnits[0];
  }
  // One decimal below 10 (Finder: "4.5 MB", "820 KB", "12 MB").
  const int decimals = value < 10.0 ? 1 : 0;
  return base::UTF8ToUTF16(base::NumberToString(
             std::round(value * std::pow(10, decimals)) /
             std::pow(10, decimals))) +
         u" " + kUnits[unit];
}

namespace {

enum class DownloadState { kActive, kPaused, kCompleted, kCancelled, kFailed };

DownloadState StateOf(const RecentDownloadEntry& e) {
  const std::string& s = e.record.state;
  if (s == "in_progress") return DownloadState::kActive;
  if (s == "paused") return DownloadState::kPaused;
  if (s == "completed") return DownloadState::kCompleted;
  if (s == "cancelled") return DownloadState::kCancelled;
  return DownloadState::kFailed;
}

bool IsFinished(const RecentDownloadEntry& e) {
  const DownloadState s = StateOf(e);
  return s != DownloadState::kActive && s != DownloadState::kPaused;
}

std::u16string HostOf(const std::string& url) {
  const GURL gurl(url);
  if (!gurl.is_valid() || gurl.host().empty()) {
    return std::u16string();
  }
  std::string host(gurl.host());
  if (host.starts_with("www.")) {
    host.erase(0, 4);
  }
  return base::UTF8ToUTF16(host);
}

std::u16string FileNameOf(const RecentDownloadEntry& e) {
  if (!e.record.filename.empty()) {
    return base::UTF8ToUTF16(e.record.filename);
  }
  const size_t slash = e.record.target_path.find_last_of("/\\");
  if (slash != std::string::npos) {
    return base::UTF8ToUTF16(e.record.target_path.substr(slash + 1));
  }
  return u"Download";
}

// "PDF", "ZIP", "DMG": up to four characters of the extension.
std::u16string ExtensionBadge(const std::u16string& name) {
  const size_t dot = name.find_last_of(u'.');
  if (dot == std::u16string::npos || dot + 1 >= name.size()) {
    return std::u16string();
  }
  std::u16string ext = name.substr(dot + 1, 4);
  return base::ToUpperASCII(ext);
}

std::u16string RemainingText(int64_t s) {
  if (s < 60) {
    return base::NumberToString16(s) + u" s left";
  }
  if (s < 3600) {
    return base::NumberToString16((s + 30) / 60) + u" min left";
  }
  return base::NumberToString16((s + 1800) / 3600) + u" h left";
}

std::u16string Subtitle(const RecentDownloadEntry& e) {
  const std::u16string host = HostOf(e.record.url);
  const std::u16string dot = u" · ";
  const int64_t received = e.record.received_bytes;
  const int64_t total = e.record.total_bytes;
  switch (StateOf(e)) {
    case DownloadState::kActive: {
      std::u16string text = FormatDownloadBytes(received);
      if (total > 0) {
        text += u" of " + FormatDownloadBytes(total);
      }
      if (e.bytes_per_second > 0) {
        text += dot + FormatDownloadBytes(e.bytes_per_second) + u"/s";
        if (total > received) {
          text += dot + RemainingText((total - received) / e.bytes_per_second);
        }
      }
      return text;
    }
    case DownloadState::kPaused: {
      std::u16string text = u"Paused" + dot + FormatDownloadBytes(received);
      if (total > 0) {
        text += u" of " + FormatDownloadBytes(total);
      }
      return text;
    }
    case DownloadState::kCompleted: {
      std::u16string text = e.file_exists
                                ? FormatDownloadBytes(total > 0 ? total
                                                                : received)
                                : u"Deleted";
      return host.empty() ? text : text + dot + host;
    }
    case DownloadState::kCancelled:
      return host.empty() ? u"Cancelled" : u"Cancelled" + dot + host;
    case DownloadState::kFailed:
      return host.empty() ? u"Failed" : u"Failed" + dot + host;
  }
  return std::u16string();
}

enum class RowGlyph { kPause, kResume, kCancel, kRetry, kReveal };

// Row context menu commands.
enum : int {
  kMenuOpen = 1,
  kMenuReveal,
  kMenuPause,
  kMenuResume,
  kMenuCancel,
  kMenuRetry,
  kMenuCopyLink,
  kMenuRemove,
};

// A small round glyph button in a download row.
class RowActionButton : public views::Button {
  METADATA_HEADER(RowActionButton, views::Button)

 public:
  RowActionButton(PressedCallback callback,
                  RowGlyph glyph,
                  const std::u16string& name,
                  const OpenPopoverColors* colors)
      : views::Button(std::move(callback)), glyph_(glyph), colors_(colors) {
    SetTooltipText(name);
    GetViewAccessibility().SetName(name);
    SetPreferredSize(gfx::Size(pm::kDownloadsButton, pm::kDownloadsButton));
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const gfx::RectF b(GetLocalBounds());
    const bool hovered =
        GetState() == STATE_HOVERED || GetState() == STATE_PRESSED;
    if (hovered) {
      FillRound(canvas, b, b.width() / 2, colors_->highlight);
    }
    const SkColor ink = colors_->label;
    gfx::RectF box = b;
    box.ClampToCenteredSize(gfx::SizeF(12, 12));
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(ink);
    switch (glyph_) {
      case RowGlyph::kPause: {
        flags.setStyle(cc::PaintFlags::kFill_Style);
        const float bar = 3.f;
        canvas->DrawRoundRect(
            gfx::RectF(box.x() + 2, box.y() + 1, bar, box.height() - 2), 1,
            flags);
        canvas->DrawRoundRect(gfx::RectF(box.right() - 2 - bar, box.y() + 1,
                                         bar, box.height() - 2),
                              1, flags);
        break;
      }
      case RowGlyph::kResume: {
        flags.setStyle(cc::PaintFlags::kFill_Style);
        SkPathBuilder path;
        path.moveTo(box.x() + 2.5f, box.y() + 1);
        path.lineTo(box.right() - 1, box.CenterPoint().y());
        path.lineTo(box.x() + 2.5f, box.bottom() - 1);
        path.close();
        canvas->DrawPath(path.detach(), flags);
        break;
      }
      case RowGlyph::kCancel:
        secondary::PaintGlyph(canvas, secondary::Glyph::kClose, box, ink);
        break;
      case RowGlyph::kRetry:
        secondary::PaintGlyph(canvas, secondary::Glyph::kReload, box, ink);
        break;
      case RowGlyph::kReveal:
        secondary::PaintGlyph(canvas, secondary::Glyph::kSearch, box, ink);
        break;
    }
  }

 private:
  RowGlyph glyph_;
  raw_ptr<const OpenPopoverColors> colors_;
};

BEGIN_METADATA(RowActionButton)
END_METADATA

}  // namespace

// A full-width or trailing text button ("Clear", "View All Downloads").
class OpenDownloadsView::TextButton : public views::Button {
  METADATA_HEADER(TextButton, views::Button)

 public:
  TextButton(PressedCallback callback,
             std::u16string label,
             int align,
             const OpenPopoverColors* colors)
      : views::Button(std::move(callback)),
        label_(std::move(label)),
        align_(align),
        colors_(colors) {
    GetViewAccessibility().SetName(label_);
  }

  int TextWidth() const {
    return secondary::TextWidth(label_, Font(13, gfx::Font::Weight::MEDIUM));
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const bool hovered =
        GetEnabled() &&
        (GetState() == STATE_HOVERED || GetState() == STATE_PRESSED);
    if (hovered) {
      FillRound(canvas, gfx::RectF(GetLocalBounds()), 8, colors_->highlight);
    }
    gfx::Rect text = GetLocalBounds();
    text.Inset(gfx::Insets::VH(0, 8));
    DrawLine(canvas, label_, Font(13, gfx::Font::Weight::MEDIUM),
             GetEnabled() ? colors_->label : colors_->disabled, text, align_);
  }

 private:
  std::u16string label_;
  int align_;
  raw_ptr<const OpenPopoverColors> colors_;
};

// One download: icon tile, name, status, progress, trailing actions. A click
// opens a finished file; right-click shows the row menu.
class OpenDownloadsView::RowView : public views::Button,
                                   public views::ContextMenuController {
  METADATA_HEADER(RowView, views::Button)

 public:
  RowView(OpenDownloadsView* owner, std::string id)
      : views::Button(base::BindRepeating(&RowView::OnPressed,
                                          base::Unretained(this))),
        owner_(owner),
        id_(std::move(id)) {
    SetNotifyEnterExitOnChild(true);
    set_context_menu_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kListItem);
    Refresh();
  }

  const std::string& id() const { return id_; }

  // Rebuilds the trailing buttons for the entry's state and repaints.
  void Refresh() {
    const RecentDownloadEntry* e = owner_->Find(id_);
    if (!e) {
      return;
    }
    const DownloadState state = StateOf(*e);
    std::vector<std::pair<RowGlyph, DownloadPopoverAction>> wanted;
    switch (state) {
      case DownloadState::kActive:
        wanted = {{RowGlyph::kPause, DownloadPopoverAction::kPause},
                  {RowGlyph::kCancel, DownloadPopoverAction::kCancel}};
        break;
      case DownloadState::kPaused:
        wanted = {{RowGlyph::kResume, DownloadPopoverAction::kResume},
                  {RowGlyph::kCancel, DownloadPopoverAction::kCancel}};
        break;
      case DownloadState::kCompleted:
        if (e->file_exists) {
          wanted = {{RowGlyph::kReveal, DownloadPopoverAction::kReveal}};
        } else {
          wanted = {{RowGlyph::kRetry, DownloadPopoverAction::kRetry}};
        }
        break;
      case DownloadState::kCancelled:
      case DownloadState::kFailed:
        if (e->can_resume) {
          wanted = {{RowGlyph::kResume, DownloadPopoverAction::kResume}};
        } else {
          wanted = {{RowGlyph::kRetry, DownloadPopoverAction::kRetry}};
        }
        break;
    }
    if (wanted != shown_) {
      shown_ = wanted;
      RemoveAllChildViews();
      for (const auto& [glyph, action] : wanted) {
        AddChildView(std::make_unique<RowActionButton>(
            base::BindRepeating(&OpenDownloadsView::Run,
                                base::Unretained(owner_.get()), action, id_),
            glyph, ActionName(action), &owner_->colors_));
      }
      InvalidateLayout();
    }
    const std::u16string name = FileNameOf(*e);
    GetViewAccessibility().SetName(name + u", " + Subtitle(*e));
    SchedulePaint();
  }

  static std::u16string ActionName(DownloadPopoverAction action) {
    switch (action) {
      case DownloadPopoverAction::kPause:
        return u"Pause";
      case DownloadPopoverAction::kResume:
        return u"Resume";
      case DownloadPopoverAction::kCancel:
        return u"Cancel";
      case DownloadPopoverAction::kRetry:
        return u"Retry";
      case DownloadPopoverAction::kReveal:
        return RevealInFolderLabel();
      default:
        return std::u16string();
    }
  }

  void Layout(PassKey) override {
    int x = width() - pm::kDownloadsPadding;
    const int y = (height() - pm::kDownloadsButton) / 2;
    for (auto it = children().rbegin(); it != children().rend(); ++it) {
      x -= pm::kDownloadsButton;
      (*it)->SetBounds(x, y, pm::kDownloadsButton, pm::kDownloadsButton);
      x -= 2;
    }
  }

  void PaintButtonContents(gfx::Canvas* canvas) override {
    const RecentDownloadEntry* e = owner_->Find(id_);
    if (!e) {
      return;
    }
    const OpenPopoverColors& c = owner_->colors_;
    const bool hovered =
        GetState() == STATE_HOVERED || GetState() == STATE_PRESSED;
    if (hovered) {
      FillRound(canvas, gfx::RectF(GetLocalBounds()), pm::kDownloadsRowRadius,
                Alpha(c.highlight, 0.6f));
    }
    // Icon tile with the extension.
    const int pad = pm::kDownloadsPadding;
    const gfx::Rect icon(pad, (height() - pm::kDownloadsIcon) / 2,
                         pm::kDownloadsIcon, pm::kDownloadsIcon);
    FillRound(canvas, gfx::RectF(icon), pm::kDownloadsIconRadius, c.track);
    const std::u16string name = FileNameOf(*e);
    const std::u16string badge = ExtensionBadge(name);
    if (!badge.empty()) {
      DrawLine(canvas, badge, Font(10, gfx::Font::Weight::SEMIBOLD),
               c.secondary_label, icon, gfx::Canvas::TEXT_ALIGN_CENTER);
    } else {
      gfx::RectF glyph_box(icon);
      glyph_box.ClampToCenteredSize(gfx::SizeF(14, 14));
      secondary::PaintGlyph(canvas, secondary::Glyph::kSquare, glyph_box,
                            c.secondary_label);
    }
    // Text column.
    const int text_x = icon.right() + 10;
    int text_right = width() - pad;
    if (!children().empty()) {
      text_right = children().front()->x() - 6;
    }
    const int text_w = std::max(0, text_right - text_x);
    const DownloadState state = StateOf(*e);
    const bool dim = state == DownloadState::kCancelled ||
                     state == DownloadState::kFailed ||
                     (state == DownloadState::kCompleted && !e->file_exists);
    DrawLine(canvas, name, Font(13, gfx::Font::Weight::MEDIUM),
             dim ? c.secondary_label : c.label,
             gfx::Rect(text_x, 8, text_w, 18), gfx::Canvas::TEXT_ALIGN_LEFT,
             gfx::ELIDE_MIDDLE);
    DrawLine(canvas, Subtitle(*e), Font(12, gfx::Font::Weight::NORMAL),
             c.secondary_label, gfx::Rect(text_x, 26, text_w, 16));
    // Live progress bar for active and paused transfers.
    if (state == DownloadState::kActive || state == DownloadState::kPaused) {
      const gfx::RectF track(text_x, height() - 7, text_w,
                             pm::kDownloadsProgressHeight);
      const float radius = pm::kDownloadsProgressHeight / 2.f;
      FillRound(canvas, track, radius, c.track);
      if (e->record.total_bytes > 0) {
        const double f = std::clamp(
            static_cast<double>(e->record.received_bytes) /
                static_cast<double>(e->record.total_bytes),
            0.0, 1.0);
        gfx::RectF fill = track;
        fill.set_width(static_cast<float>(track.width() * f));
        if (fill.width() > 0) {
          FillRound(canvas, fill, radius,
                    state == DownloadState::kPaused ? c.disabled : c.progress);
        }
      }
    }
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    owner_->ShowRowMenu(id_, source, point, source_type);
  }

 private:
  void OnPressed(const ui::Event& event) {
    const RecentDownloadEntry* e = owner_->Find(id_);
    if (e && StateOf(*e) == DownloadState::kCompleted && e->file_exists) {
      owner_->Run(DownloadPopoverAction::kOpen, id_);
    }
  }

  raw_ptr<OpenDownloadsView> owner_;
  std::string id_;
  std::vector<std::pair<RowGlyph, DownloadPopoverAction>> shown_;
};

OpenDownloadsView::OpenDownloadsView(std::vector<RecentDownloadEntry> entries,
                                     const OpenPopoverColors& colors,
                                     DownloadPopoverCallback on_action)
    : colors_(colors), on_action_(std::move(on_action)) {
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Downloads");
  clear_button_ = AddChildView(std::make_unique<TextButton>(
      base::BindRepeating(&OpenDownloadsView::Run, base::Unretained(this),
                          DownloadPopoverAction::kClearCompleted,
                          std::string()),
      u"Clear", gfx::Canvas::TEXT_ALIGN_RIGHT, &colors_));
  view_all_button_ = AddChildView(std::make_unique<TextButton>(
      base::BindRepeating(&OpenDownloadsView::Run, base::Unretained(this),
                          DownloadPopoverAction::kViewAllDownloads,
                          std::string()),
      u"View All Downloads", gfx::Canvas::TEXT_ALIGN_LEFT, &colors_));
  UpdateDownloads(std::move(entries));
}

OpenDownloadsView::~OpenDownloadsView() = default;

const RecentDownloadEntry* OpenDownloadsView::Find(
    const std::string& id) const {
  for (const RecentDownloadEntry& e : entries_) {
    if (e.record.id == id) {
      return &e;
    }
  }
  return nullptr;
}

void OpenDownloadsView::UpdateDownloads(
    std::vector<RecentDownloadEntry> entries) {
  if (entries.size() > static_cast<size_t>(pm::kDownloadsMaxRows)) {
    entries.resize(static_cast<size_t>(pm::kDownloadsMaxRows));
  }
  bool same_ids = entries.size() == rows_.size();
  for (size_t i = 0; same_ids && i < entries.size(); ++i) {
    same_ids = rows_[i]->id() == entries[i].record.id;
  }
  entries_ = std::move(entries);
  clear_button_->SetEnabled(std::any_of(entries_.begin(), entries_.end(),
                                        &IsFinished));
  if (same_ids) {
    for (RowView* row : rows_) {
      row->Refresh();
    }
    return;
  }
  RebuildRows();
}

void OpenDownloadsView::RebuildRows() {
  // Drop each raw_ptr before its view is deleted.
  std::vector<raw_ptr<RowView>> old;
  old.swap(rows_);
  for (raw_ptr<RowView>& entry : old) {
    RowView* row = entry.get();
    entry = nullptr;
    RemoveChildViewT(row);
  }
  for (const RecentDownloadEntry& e : entries_) {
    rows_.push_back(AddChildView(std::make_unique<RowView>(this, e.record.id)));
  }
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

void OpenDownloadsView::SetColors(const OpenPopoverColors& colors) {
  colors_ = colors;
  SchedulePaint();
  for (views::View* child : children()) {
    child->SchedulePaint();
  }
}

gfx::Size OpenDownloadsView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  const int rows = std::max<int>(1, static_cast<int>(rows_.size()));
  return gfx::Size(pm::kDownloadsWidth,
                   2 * pm::kDownloadsPadding + pm::kDownloadsHeaderHeight +
                       rows * pm::kDownloadsRowHeight + 1 + 4 +
                       pm::kDownloadsFooterHeight);
}

void OpenDownloadsView::Layout(PassKey) {
  const int pad = pm::kDownloadsPadding;
  const int inner = width() - 2 * pad;
  const int clear_w = clear_button_->TextWidth() + 16;
  clear_button_->SetBounds(width() - pad - clear_w,
                           pad + (pm::kDownloadsHeaderHeight - 28) / 2, clear_w,
                           28);
  int y = pad + pm::kDownloadsHeaderHeight;
  for (RowView* row : rows_) {
    row->SetBounds(pad, y, inner, pm::kDownloadsRowHeight);
    y += pm::kDownloadsRowHeight;
  }
  if (rows_.empty()) {
    y += pm::kDownloadsRowHeight;
  }
  y += 1 + 4;
  view_all_button_->SetBounds(pad, y, inner, pm::kDownloadsFooterHeight);
}

void OpenDownloadsView::OnPaint(gfx::Canvas* canvas) {
  const int pad = pm::kDownloadsPadding;
  DrawLine(canvas, u"Downloads", Font(14, gfx::Font::Weight::SEMIBOLD),
           colors_.label,
           gfx::Rect(pad + 8, pad, width() / 2, pm::kDownloadsHeaderHeight));
  int y = pad + pm::kDownloadsHeaderHeight;
  if (rows_.empty()) {
    DrawLine(canvas, u"No Recent Downloads",
             Font(13, gfx::Font::Weight::NORMAL), colors_.secondary_label,
             gfx::Rect(pad, y, width() - 2 * pad, pm::kDownloadsRowHeight),
             gfx::Canvas::TEXT_ALIGN_CENTER);
    y += pm::kDownloadsRowHeight;
  } else {
    y += static_cast<int>(rows_.size()) * pm::kDownloadsRowHeight;
  }
  canvas->FillRect(gfx::Rect(12, y + 2, width() - 24, 1), colors_.separator);
}

void OpenDownloadsView::Run(DownloadPopoverAction action,
                            const std::string& id) {
  if (on_action_) {
    DownloadPopoverCallback callback = on_action_;
    callback.Run(action, id);
  }
}

void OpenDownloadsView::ShowRowMenu(const std::string& id,
                                    views::View* source,
                                    const gfx::Point& screen_point,
                                    ui::mojom::MenuSourceType source_type) {
  const RecentDownloadEntry* e = Find(id);
  if (!e || (menu_runner_ && menu_runner_->IsRunning())) {
    return;
  }
  menu_download_id_ = id;
  const DownloadState state = StateOf(*e);
  menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  menu_model_->AddItem(kMenuOpen, u"Open");
  menu_model_->AddItem(kMenuReveal, RevealInFolderLabel());
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  if (state == DownloadState::kActive) {
    menu_model_->AddItem(kMenuPause, u"Pause");
  } else if (state == DownloadState::kPaused ||
             (e->can_resume && (state == DownloadState::kFailed ||
                                state == DownloadState::kCancelled))) {
    menu_model_->AddItem(kMenuResume, u"Resume");
  }
  if (state == DownloadState::kActive || state == DownloadState::kPaused) {
    menu_model_->AddItem(kMenuCancel, u"Cancel");
  } else if (state != DownloadState::kCompleted || !e->file_exists) {
    menu_model_->AddItem(kMenuRetry, u"Retry");
  }
  menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
  menu_model_->AddItem(kMenuCopyLink, u"Copy Link");
  menu_model_->AddItem(kMenuRemove, u"Remove from List");
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(),
      views::MenuRunner::CONTEXT_MENU | views::MenuRunner::HAS_MNEMONICS);
  menu_runner_->RunMenuAt(GetWidget(), nullptr,
                          gfx::Rect(screen_point, gfx::Size()),
                          views::MenuAnchorPosition::kTopLeft, source_type);
}

bool OpenDownloadsView::IsCommandIdEnabled(int command_id) const {
  const RecentDownloadEntry* e = Find(menu_download_id_);
  if (!e) {
    return false;
  }
  const bool finished_file =
      StateOf(*e) == DownloadState::kCompleted && e->file_exists;
  switch (command_id) {
    case kMenuOpen:
    case kMenuReveal:
      return finished_file;
    case kMenuCopyLink:
      return !e->record.url.empty();
    case kMenuRemove:
      return IsFinished(*e);
    default:
      return true;
  }
}

void OpenDownloadsView::ExecuteCommand(int command_id, int event_flags) {
  DownloadPopoverAction action = DownloadPopoverAction::kOpen;
  switch (command_id) {
    case kMenuOpen:
      action = DownloadPopoverAction::kOpen;
      break;
    case kMenuReveal:
      action = DownloadPopoverAction::kReveal;
      break;
    case kMenuPause:
      action = DownloadPopoverAction::kPause;
      break;
    case kMenuResume:
      action = DownloadPopoverAction::kResume;
      break;
    case kMenuCancel:
      action = DownloadPopoverAction::kCancel;
      break;
    case kMenuRetry:
      action = DownloadPopoverAction::kRetry;
      break;
    case kMenuCopyLink:
      action = DownloadPopoverAction::kCopyLink;
      break;
    case kMenuRemove:
      action = DownloadPopoverAction::kRemove;
      break;
    default:
      return;
  }
  Run(action, menu_download_id_);
}

BEGIN_METADATA(OpenDownloadsView, TextButton)
END_METADATA

BEGIN_METADATA(OpenDownloadsView, RowView)
END_METADATA

BEGIN_METADATA(OpenDownloadsView)
END_METADATA

OpenDownloadsPopover::OpenDownloadsPopover(DownloadPopoverCallback on_action)
    : on_action_(std::move(on_action)) {}

OpenDownloadsPopover::~OpenDownloadsPopover() = default;

void OpenDownloadsPopover::Show(views::View* library_button,
                                std::vector<RecentDownloadEntry> entries,
                                const OpenPopoverColors& colors,
                                base::OnceClosure on_closed) {
  if (!library_button) {
    return;
  }
  auto view = std::make_unique<OpenDownloadsView>(
      std::move(entries), colors,
      base::BindRepeating(&OpenDownloadsPopover::OnAction,
                          weak_factory_.GetWeakPtr()));
  host_.Show(library_button, views::BubbleBorder::BOTTOM_LEFT, std::move(view),
             colors.fill, pm::kPlusBodyRadius, pm::kDownloadsWidth,
             "OpenDownloadsPopover", std::move(on_closed));
}

void OpenDownloadsPopover::Close() {
  host_.Close();
}

bool OpenDownloadsPopover::IsShowing() const {
  return host_.IsShowing();
}

void OpenDownloadsPopover::UpdateDownloads(
    std::vector<RecentDownloadEntry> entries) {
  if (OpenDownloadsView* view = contents()) {
    view->UpdateDownloads(std::move(entries));
  }
}

OpenDownloadsView* OpenDownloadsPopover::contents() const {
  return static_cast<OpenDownloadsView*>(host_.contents());
}

void OpenDownloadsPopover::OnAction(DownloadPopoverAction action,
                                    const std::string& id) {
  // Opening a file, revealing it or leaving for the Library ends the card;
  // row controls (pause, resume, cancel, retry, remove) keep it open so the
  // live refresh shows their result.
  const bool closes = action == DownloadPopoverAction::kOpen ||
                      action == DownloadPopoverAction::kReveal ||
                      action == DownloadPopoverAction::kViewAllDownloads;
  DownloadPopoverCallback callback = on_action_;
  if (closes) {
    Close();
  }
  if (callback) {
    callback.Run(action, id);
  }
}

}  // namespace open_unified
